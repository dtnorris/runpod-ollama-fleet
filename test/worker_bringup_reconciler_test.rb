# frozen_string_literal: true

require_relative "test_helper"
require "json"
require_relative "../lib/runpod_ollama_fleet"

class WorkerBringupReconcilerTest < Minitest::Test
  DIGEST = "a" * 64
  CAMPAIGN_SHA = "b" * 64
  COMMAND_SHA = "c" * 64

  class TunnelAdapter
    attr_reader :ensures

    def initialize(result: nil)
      @result = result
      @ensures = 0
    end

    def inspect(identity:) = nil

    def ensure!(identity:)
      @ensures += 1
      @result || {
        "identity_sha256" => fingerprint(identity),
        "status" => "passed",
        "evidence" => {
          "worker_id" => identity.fetch("worker_id"),
          "generation_id" => identity.fetch("generation_id"),
          "provider_resource_id" => identity.fetch("provider_resource_id"),
          "endpoint" => identity.dig("tunnel_target", "ollama_endpoint")
        }
      }
    end

    private

    def fingerprint(identity) = Digest::SHA256.hexdigest(JSON.generate(identity))
  end

  class BootstrapAdapter
    attr_reader :starts
    attr_accessor :observed, :start_result

    def initialize(start_result: nil)
      @starts = 0
      @observed = nil
      @start_result = start_result
    end

    def inspect(identity:, attempt:) = observed

    def start!(identity:, attempt:)
      @starts += 1
      value = start_result
      return passed(identity, attempt.fetch("attempt_id")) unless value
      return value.call(identity, attempt.fetch("attempt_id")) if value.respond_to?(:call)

      value
    end

    def passed(identity, attempt_id)
      requirement = requirement_for(identity)
      {
        "identity_sha256" => fingerprint(identity),
        "attempt_id" => attempt_id,
        "status" => "passed",
        "evidence" => evidence(identity, requirement)
      }
    end

    def in_progress(identity, attempt_id)
      {
        "identity_sha256" => fingerprint(identity),
        "attempt_id" => attempt_id,
        "status" => "in_progress",
        "evidence" => nil,
        "launch_identity" => {
          "pid" => 12_345,
          "process_group_id" => 12_345,
          "start_token" => "proc:987654",
          "command_sha256" => COMMAND_SHA
        }
      }
    end

    private

    def requirement_for(_identity)
      {
        "model" => "qualified-model:latest",
        "expected_digest" => DIGEST,
        "required_context_length" => 131_072,
        "require_fully_gpu_resident" => true,
        "required_gpu_id" => "NVIDIA A40"
      }
    end

    def evidence(identity, requirement)
      {
        "worker_id" => identity.fetch("worker_id"),
        "generation_id" => identity.fetch("generation_id"),
        "provider_resource_id" => identity.fetch("provider_resource_id"),
        "model" => requirement.fetch("model"),
        "digest" => requirement.fetch("expected_digest"),
        "context_length" => requirement.fetch("required_context_length"),
        "fully_gpu_resident" => true,
        "gpu_id" => requirement.fetch("required_gpu_id"),
        "observed_at_utc" => "2030-01-01T00:00:00Z"
      }
    end

    def fingerprint(identity) = Digest::SHA256.hexdigest(JSON.generate(identity))
  end

  class CapabilityAdapter
    attr_reader :verifications

    def initialize(result: nil)
      @result = result
      @verifications = 0
    end

    def inspect(identity:) = nil

    def verify!(identity:)
      @verifications += 1
      @result || {
        "identity_sha256" => Digest::SHA256.hexdigest(JSON.generate(identity)),
        "status" => "passed",
        "evidence" => {
          "worker_id" => identity.fetch("worker_id"),
          "generation_id" => identity.fetch("generation_id"),
          "provider_resource_id" => identity.fetch("provider_resource_id"),
          "model" => "qualified-model:latest",
          "digest" => DIGEST,
          "context_length" => 131_072,
          "fully_gpu_resident" => true,
          "gpu_id" => "NVIDIA A40"
        }
      }
    end
  end

  ProcessInspector = Struct.new(:alive) do
    def same_process?(_identity) = alive
  end

  def setup
    @tmp = Dir.mktmpdir("worker-bringup-")
    @now = Time.utc(2030, 1, 1)
    @tunnel = TunnelAdapter.new
    @bootstrap = BootstrapAdapter.new
    @capability = CapabilityAdapter.new
    @process = ProcessInspector.new(true)
    @attempts = 0
  end

  def teardown
    FileUtils.remove_entry(@tmp) if @tmp && File.exist?(@tmp)
  end

  def test_reconciles_all_prerequisites_and_persists_exact_identity
    result = reconciler.reconcile!(**arguments)

    assert_equal "prerequisites_passed", result.fetch("overall_status")
    assert result.fetch("readiness_prerequisites_satisfied")
    assert_equal %w[passed passed passed],
                 %w[tunnel bootstrap capability].map { |stage| result.dig(stage, "status") }
    assert_equal capability_request.fingerprint, result.dig("identity", "model_requirement_sha256")
    assert_equal capability_request.document, result.fetch("model_requirement")
    assert_equal 1, @tunnel.ensures
    assert_equal 1, @bootstrap.starts
    assert_equal 1, @capability.verifications

    persisted = JSON.parse(File.binread(state_files.fetch(0)))
    assert_equal result.fetch("identity_sha256"), persisted.fetch("identity_sha256")
    refute persisted.key?("registry_state")
  end

  def test_running_bootstrap_is_adopted_without_duplicate_launch
    bootstrap = @bootstrap
    @bootstrap.start_result = ->(identity, attempt_id) { bootstrap.in_progress(identity, attempt_id) }
    first = reconciler.reconcile!(**arguments)
    attempt_id = first.dig("bootstrap", "attempt", "attempt_id")
    @bootstrap.observed = @bootstrap.in_progress(first.fetch("identity"), attempt_id)

    second = reconciler.reconcile!(**arguments)

    assert_equal "in_progress", second.dig("bootstrap", "status")
    assert_equal 1, @bootstrap.starts
    assert_equal 0, @capability.verifications
  end

  def test_vanished_owned_bootstrap_fails_closed_without_relaunch
    bootstrap = @bootstrap
    @bootstrap.start_result = ->(identity, attempt_id) { bootstrap.in_progress(identity, attempt_id) }
    first = reconciler.reconcile!(**arguments)
    attempt_id = first.dig("bootstrap", "attempt", "attempt_id")
    @bootstrap.observed = @bootstrap.in_progress(first.fetch("identity"), attempt_id)
    @process.alive = false

    second = reconciler.reconcile!(**arguments)

    assert_equal "failed_terminal", second.fetch("overall_status")
    assert_includes second.dig("bootstrap", "error"), "vanished"
    assert_equal 1, @bootstrap.starts
  end

  def test_new_generation_stales_old_state_and_old_generation_cannot_return
    first = reconciler.reconcile!(**arguments)
    replacement = worker.merge(
      "generation" => 2,
      "pod_id" => "pod-2",
      "generation_id" => "generation-2"
    )

    second = reconciler.reconcile!(**arguments(worker: replacement, generation_id: "generation-2"))
    old = JSON.parse(File.binread(state_files.find { |path| path.include?(first.fetch("identity_sha256")) }))

    assert_equal "prerequisites_passed", second.fetch("overall_status")
    assert_equal "stale", old.fetch("overall_status")
    assert_equal %w[stale stale stale],
                 %w[tunnel bootstrap capability].map { |stage| old.dig(stage, "status") }
    error = assert_raises(RunpodOllamaFleet::WorkerBringupReconciler::Error) do
      reconciler.reconcile!(**arguments)
    end
    assert_includes error.message, "superseded"
  end

  def test_same_generation_with_different_exact_capability_fails_closed
    reconciler.reconcile!(**arguments)
    changed = capability_request_document
    changed["ollama"]["expected_digest"] = "d" * 64
    changed_request = RunpodOllamaFleet::OllamaCapabilityRequest.new(JSON.generate(changed))
    changed_profile = profile.merge("expected_digest" => "d" * 64)

    error = assert_raises(RunpodOllamaFleet::WorkerBringupReconciler::Error) do
      reconciler.reconcile!(**arguments(profile: changed_profile, capability_request: changed_request))
    end

    assert_includes error.message, "conflicts"
  end

  def test_generation_mismatches_are_rejected_before_adapters
    error = assert_raises(RunpodOllamaFleet::WorkerBringupReconciler::Error) do
      reconciler.reconcile!(**arguments(generation_id: "generation-other"))
    end

    assert_includes error.message, "requested generation"
    assert_equal 0, @tunnel.ensures
  end

  def test_residency_evidence_is_compared_to_the_exact_generic_boolean
    document = capability_request_document
    document["ollama"]["require_fully_gpu_resident"] = false
    request = RunpodOllamaFleet::OllamaCapabilityRequest.new(JSON.generate(document))
    changed_profile = profile.merge("require_fully_gpu_resident" => false)

    result = reconciler.reconcile!(**arguments(profile: changed_profile, capability_request: request))

    assert_equal "failed_terminal", result.fetch("overall_status")
    assert_includes result.dig("bootstrap", "error"), "fully_gpu_resident"
  end

  def test_historical_model_requirement_remains_an_explicit_compatibility_input
    legacy = RunpodOllamaFleet::ModelRequirement.new(legacy_requirement_document)

    result = reconciler.reconcile!(**arguments(capability_request: legacy))

    assert_equal legacy.fingerprint, result.dig("identity", "model_requirement_sha256")
    assert_equal legacy.document, result.fetch("model_requirement")
  end

  private

  def reconciler
    @reconciler ||= RunpodOllamaFleet::WorkerBringupReconciler.new(
      root: @tmp,
      tunnel: @tunnel,
      bootstrap: @bootstrap,
      capability: @capability,
      process_inspector: @process,
      clock: -> { @now },
      attempt_id_generator: -> { @attempts += 1; "attempt-#{@attempts}" }
    )
  end

  def arguments(overrides = {})
    {
      campaign_identity_sha256: CAMPAIGN_SHA,
      profile:,
      worker:,
      generation_id: worker.fetch("generation_id"),
      capability_request:
    }.merge(overrides)
  end

  def profile
    {
      "profile_id" => "qualified-a40",
      "model" => "qualified-model:latest",
      "expected_digest" => DIGEST,
      "required_context_length" => 131_072,
      "require_fully_gpu_resident" => true
    }
  end

  def worker
    {
      "index" => 1,
      "generation" => 1,
      "pod_id" => "pod-1",
      "worker_id" => "worker-1",
      "generation_id" => "generation-1",
      "host" => "198.51.100.1",
      "ssh_port" => 22_001,
      "local_ollama_url" => "http://127.0.0.1:11441",
      "gpu_id" => "NVIDIA A40"
    }
  end

  def capability_request
    @capability_request ||= RunpodOllamaFleet::OllamaCapabilityRequest.new(
      JSON.generate(capability_request_document)
    )
  end

  def capability_request_document
    {
      "contract_version" => RunpodOllamaFleet::OllamaCapabilityRequest::CONTRACT_VERSION,
      "ollama" => {
        "model" => "qualified-model:latest",
        "expected_digest" => DIGEST,
        "required_context_length" => 131_072,
        "require_fully_gpu_resident" => true,
        "required_gpu_id" => "NVIDIA A40"
      }
    }
  end

  def legacy_requirement_document
    {
      "contract_version" => RunpodOllamaFleet::ModelRequirement::CONTRACT_VERSION,
      "batch_handle" => "39",
      "production_batch_id" => "production-batch-039",
      "plan_id" => "production-batch-039",
      "plan_sha256" => "e" * 64,
      "alias" => "qualified",
      "pool_id" => "qualified-a40",
      "required_labels" => ["inference"],
      "ollama" => {
        "model" => "qualified-model:latest",
        "expected_digest" => DIGEST,
        "required_context_length" => 131_072,
        "require_fully_gpu_resident" => true,
        "required_gpu_id" => "NVIDIA A40"
      }
    }
  end

  def state_files
    Dir.glob(File.join(@tmp, "worker-bringup-v0.1", "worker-1", "*.json")).sort
  end
end
