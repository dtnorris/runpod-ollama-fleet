# frozen_string_literal: true

require_relative "test_helper"
require "json"
require_relative "../lib/runpod_ollama_fleet"

class WorkerBringupAdaptersTest < Minitest::Test
  DIGEST = "a" * 64
  CAMPAIGN_SHA = "b" * 64

  class State
    attr_reader :root

    def initialize(root, fleet)
      @root = root
      @fleet = fleet
    end

    def current = @fleet

    def artifact_dir(fleet_id, name)
      raise "wrong fleet" unless fleet_id == @fleet.fetch("fleet_id")
      File.join(root, fleet_id, name)
    end
  end

  class Process
    attr_reader :commands

    def initialize
      @commands = []
    end

    def spawn(command:, chdir:, output:)
      @commands << { command:, chdir: }
      output.write("offline fixture\n")
      9_001
    end

    def process_identity(pid:, command:)
      {
        "pid" => pid, "process_group_id" => pid, "start_token" => "fixture-start",
        "command_sha256" => Digest::SHA256.hexdigest(JSON.generate(command))
      }
    end

    def same_process?(identity) = identity.fetch("pid") == 9_001
  end

  class Checker
    attr_accessor :ready
    attr_reader :requests

    def initialize
      @ready = true
      @requests = []
    end

    def check(request)
      requests << request
      return { "ready" => false, "diagnostics" => [{ "status" => "FAIL" }] } unless ready

      {
        "ready" => true,
        "capabilities" => {
          "gpu_id" => "NVIDIA A40",
          "models" => [{
            "name" => "qualified-model:latest", "digest" => DIGEST,
            "context_length" => 131_072, "fully_gpu_resident" => true
          }]
        },
        "diagnostics" => []
      }
    end
  end

  def setup
    @tmp = Dir.mktmpdir("bringup-adapters-")
    @requirement = RunpodOllamaFleet::ModelRequirement.new(requirement_document)
    @worker = {
      "index" => 1, "generation" => 1, "status" => "active", "pod_id" => "pod-1",
      "worker_id" => "worker-1", "generation_id" => "generation-1",
      "host" => "203.0.113.1", "ssh_port" => 22_001,
      "local_ollama_url" => "http://127.0.0.1:11441", "gpu_id" => "NVIDIA A40"
    }
    @fleet = { "fleet_id" => "fleet-1", "status" => "active", "workers" => [@worker] }
    @state = State.new(@tmp, @fleet)
    @identity = RunpodOllamaFleet::WorkerBringupIdentity.new(
      campaign_identity_sha256: CAMPAIGN_SHA, profile:, worker: @worker,
      generation_id: "generation-1", capability_request: @requirement
    ).document
    @attempt = { "attempt_id" => "attempt-1", "launch_identity" => nil,
                 "created_at_utc" => "2030-01-01T00:00:00Z" }
  end

  def teardown
    FileUtils.remove_entry(@tmp) if @tmp && File.exist?(@tmp)
  end

  def test_bootstrap_adapter_launches_exact_bound_nonblocking_command
    process = Process.new
    adapter = bootstrap_adapter(process)

    result = adapter.start!(identity: @identity, attempt: @attempt)

    assert_equal "in_progress", result.fetch("status")
    assert_equal 9_001, result.dig("launch_identity", "pid")
    command = process.commands.fetch(0).fetch(:command)
    assert_option command, "--model", "qualified-model:latest"
    assert_option command, "--copy-from-shared-store", "/workspace-global/ollama-models"
    assert_option command, "--shared-source-model", "qualified-model:q4_K_M"
    assert_option command, "--expect-digest", "qualified-model:latest=#{DIGEST}"
    assert_option command, "--context", "131072"
    assert_includes command, "--bringup-identity"
    assert_includes command, @requirement.fingerprint
  end

  def test_bootstrap_adapter_adopts_exact_passed_artifact
    process = Process.new
    adapter = bootstrap_adapter(process)
    adapter.start!(identity: @identity, attempt: @attempt)
    write_bootstrap("passed")

    result = adapter.inspect(identity: @identity, attempt: @attempt)

    assert_equal "passed", result.fetch("status")
    assert_equal DIGEST, result.dig("evidence", "digest")
    assert_equal "generation-1", result.dig("evidence", "generation_id")
  end

  def test_bootstrap_adapter_serializes_workers_within_one_fleet
    process = Process.new
    adapter = bootstrap_adapter(process)
    adapter.start!(identity: @identity, attempt: @attempt)
    second_worker = @worker.merge(
      "index" => 2, "worker_id" => "worker-2", "pod_id" => "pod-2",
      "generation_id" => "generation-2", "local_ollama_url" => "http://127.0.0.1:11442"
    )
    second_identity = RunpodOllamaFleet::WorkerBringupIdentity.new(
      campaign_identity_sha256: CAMPAIGN_SHA, profile:, worker: second_worker,
      generation_id: "generation-2", capability_request: @requirement
    ).document

    result = adapter.start!(
      identity: second_identity,
      attempt: @attempt.merge("attempt_id" => "attempt-2")
    )

    assert_equal "failed_retryable", result.fetch("status")
    assert_equal 1, process.commands.length
  end

  def test_bootstrap_adapter_rejects_wrong_attempt_artifact_without_relaunch
    process = Process.new
    adapter = bootstrap_adapter(process)
    adapter.start!(identity: @identity, attempt: @attempt)
    write_bootstrap("passed", attempt_id: "wrong-attempt")

    result = adapter.inspect(identity: @identity, attempt: @attempt)

    assert_equal "in_progress", result.fetch("status")
    assert_equal 1, process.commands.length
  end

  def test_capability_adapter_binds_exact_request_and_evidence
    checker = Checker.new
    adapter = RunpodOllamaFleet::WorkerBringupAdapters::Capability.new(
      checker:, requirement: @requirement, transition_guard: -> { true }
    )

    result = adapter.verify!(identity: @identity)

    assert_equal "passed", result.fetch("status")
    assert_equal DIGEST, result.dig("evidence", "digest")
    assert_equal [1], checker.requests.fetch(0).dig("worker_selector", "indices")
    requested = checker.requests.fetch(0).fetch("requirements")
    assert_equal "qualified-model:latest", requested.dig("models", 0, "name")
    assert_equal DIGEST, requested.dig("models", 0, "expected_digest")
    assert_equal 131_072, requested.fetch("required_context_length")
    assert_equal "NVIDIA A40", requested.fetch("required_gpu_id")
  end

  def test_capability_adapter_retains_retryable_failure_and_guard_refusal
    checker = Checker.new
    checker.ready = false
    adapter = RunpodOllamaFleet::WorkerBringupAdapters::Capability.new(
      checker:, requirement: @requirement, transition_guard: -> { true }
    )
    assert_equal "failed_retryable", adapter.inspect(identity: @identity).fetch("status")

    blocked = RunpodOllamaFleet::WorkerBringupAdapters::Capability.new(
      checker:, requirement: @requirement, transition_guard: -> { raise "teardown" }
    )
    error = assert_raises(RunpodOllamaFleet::WorkerBringupReconciler::RetryableTransitionError) do
      blocked.verify!(identity: @identity)
    end
    assert_includes error.message, "teardown"
  end

  private

  def bootstrap_adapter(process)
    RunpodOllamaFleet::WorkerBringupAdapters::Bootstrap.new(
      root: @tmp, repo_root: File.expand_path("..", __dir__), fleet_state: @state,
      shared_store_path: "/workspace-global/ollama-models",
      shared_source_model: "qualified-model:q4_K_M", process_supervisor: process,
      requirement: @requirement, transition_guard: -> { true },
      clock: -> { Time.utc(2030, 1, 1) }
    )
  end

  def assert_option(command, option, expected)
    index = command.index(option)
    refute_nil index
    assert_equal expected, command.fetch(index + 1)
  end

  def write_bootstrap(status, attempt_id: "attempt-1")
    root = @state.artifact_dir("fleet-1", "bootstrap")
    run_id = "run-1"
    FileUtils.mkdir_p(File.join(root, run_id))
    File.write(File.join(root, "current"), "#{run_id}\n")
    document = {
      "fleet_id" => "fleet-1", "status" => status,
      "bringup_identity_sha256" => Digest::SHA256.hexdigest(JSON.generate(@identity)),
      "bringup_attempt_id" => attempt_id,
      "model_requirement_sha256" => @requirement.fingerprint,
      "workers" => [{
        "index" => 1, "status" => status, "pod_id" => "pod-1", "worker_id" => "worker-1",
        "generation_id" => "generation-1", "finished_at_utc" => "2030-01-01T00:00:00Z",
        "provenance" => {
          "gpu" => { "name" => "NVIDIA A40" },
          "models" => { "qualified-model:latest" => {
            "digest" => DIGEST, "context_length" => 131_072, "fully_gpu_resident" => true
          } }
        }
      }]
    }
    File.write(File.join(root, run_id, "bootstrap.json"), JSON.pretty_generate(document) + "\n")
  end

  def profile
    {
      "profile_id" => "pool-a", "model" => "qualified-model:latest",
      "expected_digest" => DIGEST, "required_context_length" => 131_072,
      "require_fully_gpu_resident" => true
    }
  end

  def requirement_document
    {
      "contract_version" => RunpodOllamaFleet::ModelRequirement::CONTRACT_VERSION,
      "batch_handle" => "batch-1", "production_batch_id" => "production-1",
      "plan_id" => "plan-1", "plan_sha256" => "e" * 64, "alias" => "operator-alias",
      "pool_id" => "pool-a", "required_labels" => %w[inference ollama remote],
      "ollama" => {
        "model" => "qualified-model:latest", "expected_digest" => DIGEST,
        "required_context_length" => 131_072, "require_fully_gpu_resident" => true,
        "required_gpu_id" => "NVIDIA A40"
      }
    }
  end
end
