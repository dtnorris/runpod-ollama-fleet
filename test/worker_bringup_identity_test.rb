# frozen_string_literal: true

require_relative "test_helper"
require "fileutils"
require "json"
require "open3"
require "rbconfig"
require_relative "../lib/runpod_ollama_fleet/worker_bringup_identity"
require_relative "../lib/runpod_ollama_fleet/worker_bringup_state"

class WorkerBringupIdentityTest < Minitest::Test
  CAMPAIGN_SHA = "a" * 64
  DIGEST = "b" * 64

  def test_equivalent_generic_semantics_have_one_identity_without_provenance
    reordered = {
      "ollama" => {
        "required_gpu_id" => "NVIDIA A40",
        "require_fully_gpu_resident" => true,
        "required_context_length" => 131_072,
        "expected_digest" => DIGEST,
        "model" => "qualified-model:latest"
      },
      "contract_version" => RunpodOllamaFleet::OllamaCapabilityRequest::CONTRACT_VERSION
    }
    first = identity(capability_request)
    second = identity(request(reordered))

    assert_equal capability_request.fingerprint, request(reordered).fingerprint
    assert_equal first.document, second.document
    assert_equal first.sha256, second.sha256
    assert_equal capability_request.fingerprint, first.document.fetch("model_requirement_sha256")
    refute_match(/adventure|alias|batch|plan|pool/i, JSON.generate(first.document))
  end

  def test_every_runtime_capability_field_changes_the_identity
    cases = {
      "model" => ["other-model:latest", { "model" => "other-model:latest" }, {}],
      "expected_digest" => ["c" * 64, { "expected_digest" => "c" * 64 }, {}],
      "required_context_length" => [65_536, { "required_context_length" => 65_536 }, {}],
      "require_fully_gpu_resident" => [false, { "require_fully_gpu_resident" => false }, {}],
      "required_gpu_id" => ["NVIDIA L40S", {}, { "gpu_id" => "NVIDIA L40S" }]
    }
    baseline = identity(capability_request)

    cases.each do |field, (value, profile_changes, worker_changes)|
      document = capability_request_document
      document.fetch("ollama")[field] = value
      changed = identity(
        request(document),
        profile: profile.merge(profile_changes),
        worker: worker.merge(worker_changes)
      )

      refute_equal baseline.document.fetch("model_requirement_sha256"),
                   changed.document.fetch("model_requirement_sha256"), field
      refute_equal baseline.sha256, changed.sha256, field
    end

    without_gpu = capability_request_document
    without_gpu.fetch("ollama").delete("required_gpu_id")
    unconstrained = identity(request(without_gpu))
    refute_equal baseline.document.fetch("model_requirement_sha256"),
                 unconstrained.document.fetch("model_requirement_sha256"), "required_gpu_id removal"
    refute_equal baseline.sha256, unconstrained.sha256, "required_gpu_id removal"
  end

  def test_legitimate_rpof_and_provider_generation_inputs_change_identity
    baseline = identity(capability_request)
    changed_campaign = identity(capability_request, campaign_identity_sha256: "d" * 64)
    changed_provider = identity(capability_request, worker: worker.merge("pod_id" => "pod-2"))
    next_worker = worker.merge("generation" => 2, "generation_id" => "generation-2")
    changed_generation = identity(capability_request, worker: next_worker, generation_id: "generation-2")

    [changed_campaign, changed_provider, changed_generation].each do |changed|
      refute_equal baseline.sha256, changed.sha256
    end
  end

  def test_budget_deadline_and_adventurefinder_provenance_are_not_identity_inputs
    error = assert_raises(ArgumentError) do
      identity(capability_request, budget_id: "budget-1")
    end
    assert_includes error.message, "unknown keyword"

    document = capability_request_document.merge("operator_alias" => "qualified")
    request_error = assert_raises(RunpodOllamaFleet::OllamaCapabilityRequest::Error) { request(document) }
    assert_includes request_error.message, "unknown fields"
  end

  def test_generic_identity_and_state_do_not_load_model_requirement_runtime
    lib = File.expand_path("../lib", __dir__)
    script = <<~RUBY
      require "json"
      require "tmpdir"
      require "runpod_ollama_fleet/worker_bringup_identity"
      require "runpod_ollama_fleet/worker_bringup_state"
      request = RunpodOllamaFleet::OllamaCapabilityRequest.new(#{JSON.generate(JSON.generate(capability_request_document))})
      profile = JSON.parse(#{JSON.generate(JSON.generate(profile))})
      worker = JSON.parse(#{JSON.generate(JSON.generate(worker))})
      identity = RunpodOllamaFleet::WorkerBringupIdentity.new(
        campaign_identity_sha256: #{CAMPAIGN_SHA.inspect}, profile: profile, worker: worker,
        generation_id: worker.fetch("generation_id"), capability_request: request
      )
      Dir.mktmpdir do |root|
        RunpodOllamaFleet::WorkerBringupState.new(root: root).with_current(identity) { |_state, _checkpoint| }
      end
      abort "legacy runtime loaded" if defined?(RunpodOllamaFleet::ModelRequirement)
    RUBY

    _stdout, stderr, status = Open3.capture3(RbConfig.ruby, "-I#{lib}", "-e", script)

    assert status.success?, stderr
  end

  def test_retained_legacy_state_is_read_without_rewrite
    Dir.mktmpdir("retained-bringup-") do |root|
      worker_root = File.join(root, "worker-bringup-v0.1", "worker-legacy")
      FileUtils.mkdir_p(worker_root)
      legacy_request = retained_legacy_request
      identity_document = {
        "contract_version" => RunpodOllamaFleet::WorkerBringupIdentity::CONTRACT_VERSION,
        "campaign_identity_sha256" => CAMPAIGN_SHA,
        "profile_id" => "qualified-a40",
        "logical_worker_slot" => 1,
        "worker_generation" => 1,
        "provider_resource_id" => "pod-legacy",
        "worker_id" => "worker-legacy",
        "generation_id" => "generation-legacy",
        "tunnel_target" => {
          "host" => "198.51.100.9",
          "ssh_port" => 22_009,
          "ollama_endpoint" => "http://127.0.0.1:11449"
        },
        "model_requirement_sha256" => Digest::SHA256.hexdigest(JSON.generate(legacy_request))
      }
      identity_sha = Digest::SHA256.hexdigest(JSON.generate(identity_document))
      state = retained_legacy_state(identity_document, identity_sha, legacy_request)
      state_path = File.join(worker_root, "#{identity_sha}.json")
      bytes = JSON.pretty_generate(state) + "\n"
      File.binwrite(state_path, bytes)
      File.binwrite(File.join(worker_root, "current"), "#{identity_sha}\n")

      loaded = RunpodOllamaFleet::WorkerBringupState.new(root:).read_current(worker_id: "worker-legacy")

      assert_equal "adventurefinder-model-requirement/v0.1",
                   loaded.dig("model_requirement", "contract_version")
      assert_equal bytes, File.binread(state_path)
    end
  end

  private

  def identity(capability, campaign_identity_sha256: CAMPAIGN_SHA, profile: self.profile,
               worker: self.worker, generation_id: worker.fetch("generation_id"), **unknown)
    RunpodOllamaFleet::WorkerBringupIdentity.new(
      campaign_identity_sha256:, profile:, worker:, generation_id:,
      capability_request: capability, **unknown
    )
  end

  def capability_request
    @capability_request ||= request(capability_request_document)
  end

  def request(document)
    RunpodOllamaFleet::OllamaCapabilityRequest.new(JSON.generate(document))
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

  def retained_legacy_request
    {
      "contract_version" => "adventurefinder-model-requirement/v0.1",
      "batch_handle" => "39",
      "production_batch_id" => "production-batch-039",
      "plan_id" => "production-batch-039",
      "plan_sha256" => "e" * 64,
      "alias" => "qualified",
      "pool_id" => "qualified-a40",
      "required_labels" => ["inference"],
      "ollama" => capability_request_document.fetch("ollama")
    }
  end

  def retained_legacy_state(identity_document, identity_sha, legacy_request)
    now = "2030-01-01T00:00:00Z"
    stage = { "status" => "passed", "updated_at_utc" => now, "evidence" => { "retained" => true } }
    {
      "contract_version" => RunpodOllamaFleet::WorkerBringupState::CONTRACT_VERSION,
      "identity_sha256" => identity_sha,
      "identity" => identity_document,
      "model_requirement" => legacy_request,
      "overall_status" => "prerequisites_passed",
      "readiness_prerequisites_satisfied" => true,
      "created_at_utc" => now,
      "updated_at_utc" => now,
      "superseded_at_utc" => nil,
      "tunnel" => stage,
      "bootstrap" => stage.merge("attempt" => nil),
      "capability" => stage
    }
  end
end
