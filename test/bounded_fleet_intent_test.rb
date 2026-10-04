# frozen_string_literal: true

require_relative "test_helper"
require "json"
require_relative "../lib/runpod_ollama_fleet"

class BoundedFleetIntentTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)
  DIGEST = "a" * 64

  def setup
    @tmp = Dir.mktmpdir("bounded-fleet-intent-")
    @state_root = File.join(@tmp, "state")
    @hardware = RunpodOllamaFleet::ExecutionPoolHardware.new(
      path: File.join(ROOT, "config", "execution_pool_hardware.yml")
    )
  end

  def teardown
    FileUtils.remove_entry(@tmp) if @tmp && File.exist?(@tmp)
  end

  def test_preview_is_read_only_and_exposes_exact_bounded_authority
    intent = build_intent
    result = intent.preview

    refute File.exist?(@state_root)
    assert result.fetch("read_only")
    assert_equal 0, result.fetch("provider_mutations")
    assert_equal 0, result.fetch("guardian_mutations")
    assert_equal 0, result.fetch("controller_mutations")
    assert_equal 0, result.fetch("registry_publications")
    assert_equal request.fingerprint, result.dig("capability", "fingerprint")
    assert_equal "qwen3.6:27b", result.dig("capability", "model")
    assert_equal true, result.dig("capability", "require_fully_gpu_resident")
    assert_equal 2, result.dig("profile", "desired_workers")
    assert_equal 3, result.dig("profile", "max_workers")
    assert_includes result.dig("profile", "qualified_gpu_ids"), "NVIDIA A40"
    assert_equal 20.0, result.dig("authority", "limits", "max_cumulative_compute_usd")
    assert_equal 155.0, result.dig("authority", "crash_liability", "horizon_seconds")
    assert_equal 0.258333,
                 result.dig("authority", "crash_liability",
                            "maximum_additional_compute_usd_at_hourly_ceiling")
    assert_equal "runpod_pod_compute_only", result.dig("authority", "billing_scope", "label")
    assert_equal "NOT_RUN", result.dig("validation", "paid_start_gate")
  end

  def test_persist_is_idempotent_and_uses_existing_campaign_and_budget_contracts
    first = build_intent
    paths = first.persist!
    bytes = paths.slice(:campaign, :budget, :capability_request).transform_values { |path| File.binread(path) }

    second = build_intent(capability_request: request(pretty: false))
    assert_equal paths, second.persist!
    assert_equal bytes,
                 paths.slice(:campaign, :budget, :capability_request).transform_values { |path| File.binread(path) }
    assert_equal RunpodOllamaFleet::CapacityCampaign::CONTRACT_VERSION,
                 JSON.parse(bytes.fetch(:campaign)).fetch("contract_version")
    assert_equal RunpodOllamaFleet::CampaignBudgetBinding::CONTRACT_VERSION,
                 JSON.parse(bytes.fetch(:budget)).fetch("contract_version")
  end

  def test_partial_exact_initialization_is_completed_without_rewriting_existing_artifact
    intent = build_intent
    paths = intent.artifact_paths
    FileUtils.mkdir_p(paths.fetch(:directory))
    File.binwrite(paths.fetch(:campaign), intent.campaign_bytes)
    before = File.stat(paths.fetch(:campaign)).mtime

    intent.persist!

    assert_equal intent.campaign_bytes, File.binread(paths.fetch(:campaign))
    assert_equal before, File.stat(paths.fetch(:campaign)).mtime
    assert_equal intent.budget_bytes, File.binread(paths.fetch(:budget))
    assert_equal intent.capability_bytes, File.binread(paths.fetch(:capability_request))
  end

  def test_conflicting_or_malformed_retained_artifact_fails_before_writing_missing_artifacts
    intent = build_intent
    paths = intent.artifact_paths
    FileUtils.mkdir_p(paths.fetch(:directory))
    File.binwrite(paths.fetch(:budget), "not the retained budget\n")

    error = assert_raises(RunpodOllamaFleet::BoundedFleetIntent::Error) { intent.persist! }

    assert_includes error.message, "conflicts with requested authority"
    refute File.exist?(paths.fetch(:campaign))
    refute File.exist?(paths.fetch(:capability_request))
  end

  def test_same_campaign_id_with_wider_or_different_intent_is_rejected
    build_intent.persist!
    conflict = build_intent(max_workers: 4)

    error = assert_raises(RunpodOllamaFleet::BoundedFleetIntent::Error) { conflict.persist! }

    assert_includes error.message, "conflicts with requested authority"
  end

  def test_invalid_counts_and_paid_bounds_fail_closed
    invalid = [
      [{ desired_workers: 0 }, "positive integer"],
      [{ desired_workers: 4 }, "min_workers <= desired_workers <= max_workers"],
      [{ max_workers: 0 }, "positive integer"],
      [{ max_hourly_rate_usd: 0.0 }, "positive finite"],
      [{ max_cumulative_compute_usd: Float::INFINITY }, "positive and finite"],
      [{ max_runtime_seconds: 0.0 }, "positive and finite"],
      [{ guardian_poll_seconds: 0.0 }, "positive and finite"],
      [{ orchestrator_heartbeat_timeout_seconds: 9.0 }, "at least twice"],
      [{ teardown_reserve_seconds: 0.0 }, "positive and finite"]
    ]
    invalid.each do |overrides, message|
      error = assert_raises(RunpodOllamaFleet::BoundedFleetIntent::Error) do
        build_intent(**overrides)
      end
      assert_includes error.message, message
    end
  end

  def test_malformed_capability_and_unsupported_hardware_fail_before_state
    error = assert_raises(RunpodOllamaFleet::OllamaCapabilityRequest::Error) do
      RunpodOllamaFleet::OllamaCapabilityRequest.new("{}")
    end
    assert_includes error.message, "missing fields"

    unsupported = request(model: "not-qualified:1")
    error = assert_raises(RunpodOllamaFleet::BoundedFleetIntent::Error) do
      build_intent(capability_request: unsupported)
    end
    assert_includes error.message, "no qualified RPOF hardware profile"
    refute File.exist?(@state_root)
  end

  def test_exact_residency_boolean_is_not_coerced
    not_resident = request(require_fully_gpu_resident: false)
    error = assert_raises(RunpodOllamaFleet::BoundedFleetIntent::Error) do
      build_intent(capability_request: not_resident)
    end
    assert_includes error.message, "require_fully_gpu_resident must be true"
  end

  private

  def build_intent(**overrides)
    arguments = {
      state_root: @state_root,
      repo_root: ROOT,
      hardware: @hardware,
      capability_request: request,
      campaign_id: "fleet-a-production",
      profile_id: "qwen27",
      desired_workers: 2,
      max_workers: 3,
      max_hourly_rate_usd: 6.0,
      max_cumulative_compute_usd: 20.0,
      max_runtime_seconds: 3600.0,
      guardian_poll_seconds: 5.0,
      orchestrator_heartbeat_timeout_seconds: 30.0,
      teardown_reserve_seconds: 120.0
    }.merge(overrides)
    RunpodOllamaFleet::BoundedFleetIntent.new(**arguments)
  end

  def request(model: "qwen3.6:27b", require_fully_gpu_resident: true, pretty: true)
    document = {
      "contract_version" => "ollama-capability-request/v0.1",
      "ollama" => {
        "model" => model,
        "expected_digest" => DIGEST,
        "required_context_length" => 131_072,
        "require_fully_gpu_resident" => require_fully_gpu_resident
      }
    }
    bytes = pretty ? JSON.pretty_generate(document) : JSON.generate(document)
    RunpodOllamaFleet::OllamaCapabilityRequest.new(bytes)
  end
end
