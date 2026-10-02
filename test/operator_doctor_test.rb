# frozen_string_literal: true

require_relative "test_helper"
require "runpod_ollama_fleet"

class OperatorDoctorTest < Minitest::Test
  FakeCampaign = Struct.new(:campaign_id)

  class FakeFleetState
    def initialize(root, fleet)
      @root = root
      @fleet = fleet
    end

    def current = @fleet
    def artifact_dir(fleet_id, name) = File.join(@root, fleet_id, name)
  end

  FakeReadiness = Struct.new(:document) do
    def readiness_status = document
  end

  class FakeBinding
    attr_reader :campaign, :safety_report_path

    def initialize(authority:, retained: nil)
      @authority = authority
      @retained = retained
      @campaign = FakeCampaign.new("campaign-39")
      @safety_report_path = "/state/campaign-budgets/report.json"
    end

    def inspect_authority = Marshal.load(Marshal.dump(@authority))
    def retained_safety_report = Marshal.load(Marshal.dump(@retained))
  end

  def test_pod_stage_precedence_and_healthy_state
    assert_stage "provider_creation", worker("-", lme_status: "provisioning")
    assert_stage "bootstrap", worker("FAILED")
    assert_stage "capability_verification", worker("PASSED", models: [])
    assert_stage "tunnel", worker("PASSED", tunnel: "ABSENT")
    assert_stage "tunnel", worker("-", tunnel: "ABSENT")
    assert_stage "registry_publication", worker("PASSED", registry: "NOT_READY")

    result = doctor(worker("PASSED")).pod("A2")
    assert_equal "healthy", result.fetch("stage")
    assert_nil result.fetch("next_action")
  end

  def test_pod_alias_canonical_id_and_unknown_handle_resolution
    row = worker("PASSED")
    instance = doctor(row)

    assert_equal "A2", instance.pod("worker-2").dig("subject", "handle")
    assert_equal "A2", instance.pod("pod-2").dig("subject", "handle")
    assert_raises(RunpodOllamaFleet::OperatorDoctor::Error) { instance.pod("A9") }
  end

  def test_fleet_points_to_exactly_one_unhealthy_pod
    result = doctor(worker("FAILED")).fleet("A")

    assert_equal "bootstrap", result.fetch("stage")
    assert_equal({ "action" => "inspect_pod", "handle" => "A2" }, result.fetch("next_action"))
  end

  def test_campaign_uses_retained_failed_safety_report_without_recomputation
    retained = {
      "recorded_at_utc" => "2026-10-02T12:00:00Z",
      "report" => {
        "safety_gate" => "FAIL",
        "refusal_reasons" => ["guardian_identity_mismatch"]
      }
    }
    binding = FakeBinding.new(authority: authority, retained:)
    result = RunpodOllamaFleet::OperatorDoctor.new(
      state_root: "/state", campaign_binding: binding
    ).campaign

    assert_equal "paid_start_safety_gate", result.fetch("stage")
    assert_equal ["guardian_identity_mismatch"], result.dig("evidence", 0, "refusal_reasons")
    assert_equal "inspect_campaign_safety", result.dig("next_action", "action")
  end

  def test_campaign_teardown_failure_pending_and_verified_closed
    failed = authority("parent_budget" => {
                         "state" => "TEARDOWN_REQUIRED", "teardown_failures" => [{ "error" => "delete failed" }]
                       })
    result = campaign_doctor(failed)
    assert_equal "teardown", result.fetch("stage")
    assert_equal "repeat_teardown_status", result.dig("next_action", "action")

    pending = authority("parent_budget" => { "state" => "TEARDOWN_REQUIRED", "teardown_failures" => [] })
    assert_equal "provider_absence_verification", campaign_doctor(pending).fetch("stage")

    closed = authority("parent_budget" => {
                         "state" => "CLOSED", "teardown_failures" => [],
                         "provider_absence_verified_at_utc" => "2026-10-02T12:05:00Z"
                       })
    assert_equal "healthy", campaign_doctor(closed).fetch("status")
  end

  def test_campaign_guardian_failure_and_armed_authority
    unhealthy = authority("guardian_healthy" => false, "guardian" => { "healthy" => false })
    assert_equal "guardian", campaign_doctor(unhealthy).fetch("stage")
    assert_equal "healthy", campaign_doctor(authority).fetch("status")
  end

  def test_pod_log_tail_is_bounded_and_redacts_known_credentials
    Dir.mktmpdir("rpof-doctor-") do |root|
      log = File.join(root, "fleet", "bootstrap.log")
      FileUtils.mkdir_p(File.dirname(log))
      File.write(log, "old\nRUNPOD_API_KEY=secret\nnew\n")
      row = worker("FAILED").merge("bootstrap_log" => log)

      result = RunpodOllamaFleet::OperatorDoctor.new(
        snapshot: snapshot(row), state_root: root
      ).pod_logs("A2", lines: 2)

      assert_equal ["RUNPOD_API_KEY=[REDACTED]", "new"], result.fetch("lines")
      assert_raises(RunpodOllamaFleet::OperatorDoctor::Error) do
        RunpodOllamaFleet::OperatorDoctor.new(snapshot: snapshot(row), state_root: root)
                                             .pod_logs("A2", lines: 201)
      end
    end
  end

  def test_retained_readiness_matches_exact_generation_and_bootstrap
    Dir.mktmpdir("rpof-readiness-") do |root|
      fleet = {
        "fleet_id" => "fleet-1",
        "workers" => [{ "index" => 2, "pod_id" => "pod-2", "worker_id" => "worker-2",
                         "generation_id" => "generation-2" }]
      }
      registry = {
        "contract_version" => RunpodOllamaFleet::DynamicWorkerRegistry::CONTRACT_VERSION,
        "revision" => 9, "published_at" => "2026-10-02T12:00:00Z",
        "workers" => [{ "worker_id" => "worker-2", "generation_id" => "generation-2",
                         "state" => "READY", "capabilities" => { "ollama" => { "models" => ["qwen:27b"] } } }]
      }
      File.write(
        File.join(root, RunpodOllamaFleet::DynamicWorkerRegistry::PUBLISHER_STATE_FILE),
        JSON.generate("snapshot" => registry)
      )
      readiness = FakeReadiness.new({
        "workers" => [{ "index" => 2, "bootstrap_passed" => true,
                         "capability_evidence_valid" => true, "tunnel_established" => true }]
      })

      result = RunpodOllamaFleet::RetainedReadiness.new(
        state_root: root, repo_root: root, fleet_key: "fleet-a",
        fleet_state: FakeFleetState.new(root, fleet), readiness_observer: readiness
      ).readiness_status

      assert_equal "available", result.fetch("status")
      assert_equal 9, result.fetch("retained_revision")
      assert result.dig("workers", 0, "bootstrap_passed")
      assert result.dig("workers", 0, "capability_evidence_valid")
      assert_equal "READY", result.dig("workers", 0, "registry_state")
    end
  end

  def test_retained_readiness_fails_closed_without_fleet_or_valid_snapshot
    Dir.mktmpdir("rpof-readiness-") do |root|
      empty = FakeFleetState.new(root, nil)
      result = RunpodOllamaFleet::RetainedReadiness.new(
        state_root: root, repo_root: root, fleet_key: "fleet-a", fleet_state: empty,
        readiness_observer: FakeReadiness.new({ "workers" => [] })
      ).readiness_status
      assert_equal "unavailable", result.fetch("status")

      fleet = { "fleet_id" => "fleet-1", "workers" => [] }
      File.write(File.join(root, RunpodOllamaFleet::DynamicWorkerRegistry::PUBLISHER_STATE_FILE), "bad")
      result = RunpodOllamaFleet::RetainedReadiness.new(
        state_root: root, repo_root: root, fleet_key: "fleet-a", fleet_state: FakeFleetState.new(root, fleet),
        readiness_observer: FakeReadiness.new({ "workers" => [] })
      ).readiness_status
      assert_equal "unavailable", result.fetch("status")
      assert_includes result.fetch("error"), "invalid"
    end
  end

  private

  def assert_stage(expected, row)
    result = doctor(row).pod("A2")
    assert_equal expected, result.fetch("stage")
    assert_equal 1, result.fetch("next_action").keys.count { |key| key == "action" }
  end

  def doctor(row)
    RunpodOllamaFleet::OperatorDoctor.new(snapshot: snapshot(row))
  end

  def campaign_doctor(value)
    binding = FakeBinding.new(authority: value)
    RunpodOllamaFleet::OperatorDoctor.new(campaign_binding: binding).campaign
  end

  def snapshot(row)
    { "workers" => [row] }
  end

  def worker(bootstrap, models: ["qwen:27b"], tunnel: "ESTABLISHED", registry: "READY",
             lme_status: "active")
    {
      "fleet_key" => "fleet-a", "fleet_alias" => "A", "index" => 2,
      "pod_id" => "pod-2", "worker_id" => "worker-2", "generation_id" => "generation-2",
      "lme_status" => lme_status, "provider_status" => "NOT_CHECKED",
      "bootstrap_status" => bootstrap, "bootstrap_log" => nil,
      "available_models" => models, "tunnel_status" => tunnel, "registry_state" => registry
    }
  end

  def authority(overrides = {})
    {
      "guardian_healthy" => true,
      "guardian" => { "healthy" => true },
      "parent_budget" => { "state" => "ARMED", "teardown_failures" => [] }
    }.merge(overrides)
  end
end
