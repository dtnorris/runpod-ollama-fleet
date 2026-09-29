# frozen_string_literal: true

require "minitest/autorun"
require "fileutils"
require "json"
require "tmpdir"
require_relative "../lib/runpod_ollama_fleet/campaign_budget_binding"

class CampaignBudgetBindingTest < Minitest::Test
  FIXTURE = File.expand_path("fixtures/rpof-capacity-campaign-v0.1.json", __dir__)
  BUDGET_FIXTURE = File.expand_path("fixtures/rpof-capacity-campaign-budget-v0.1.json", __dir__)
  HARDWARE = File.expand_path("../config/execution_pool_hardware.yml", __dir__)
  BINDING_SHA256 = "6352abb4d2272033f44d112341a385df8c368008366cc0391c52f9587c952509"

  class FakeGuardianSupervisor
    attr_accessor :healthy, :fail_after_arm
    attr_reader :arm_count

    def initialize(clock)
      @clock = clock
      @healthy = true
      @fail_after_arm = false
      @arm_count = 0
      @armed = false
    end

    def arm!(budget:, request:)
      @arm_count += 1
      snapshot = budget.arm!(budget: request, guardian_heartbeat_at_utc: @clock.call)
      @armed = true
      if fail_after_arm
        raise LocalModelEvaluation::RunpodBudgetGuardianSupervisor::Error,
              "fixture lost the arm result"
      end
      snapshot
    end

    def status(budget:)
      state = budget.status.fetch("state")
      now = @clock.call
      {
        "enabled" => healthy,
        "launchd_loaded" => healthy,
        "ready" => healthy,
        "pid" => Process.pid + 10_000,
        "provider_probe_at_utc" => now.iso8601,
        "ledger_heartbeat_at_utc" => now.iso8601,
        "state" => (@armed ? state : "WAITING_FOR_ARM"),
        "last_error" => nil
      }
    end
  end

  def setup
    @tmp = Dir.mktmpdir("campaign-budget-")
    @now = Time.utc(2026, 9, 29, 12, 0, 0)
    @campaign = load_campaign
    @supervisor = FakeGuardianSupervisor.new(-> { @now })
  end

  def teardown
    FileUtils.remove_entry(@tmp) if @tmp && File.exist?(@tmp)
  end

  def test_valid_arm_has_one_finite_parent_authority_and_deterministic_identity
    binding = build_binding
    status = binding.arm!
    authority = status.fetch("authority")

    assert_equal "ARMED", status.fetch("phase")
    assert_equal "batch039-parent", status.dig("parent_budget", "budget_id")
    assert_equal binding.binding_sha256, status.dig("parent_budget", "plan_sha256")
    assert_equal @campaign.identity_sha256,
                 status.dig("binding", "campaign_identity_sha256")
    assert_equal 30.0, authority.fetch("max_cumulative_compute_usd")
    assert_equal 6.0, authority.fetch("max_aggregate_hourly_rate_usd")
    assert_equal 6, authority.fetch("max_workers")
    assert_equal 155.0, authority.fetch("crash_liability_horizon_seconds")
    assert authority.fetch("maximum_additional_compute_liability_usd").finite?
    assert_equal true, authority.fetch("mutation_allowed")
    assert_equal binding.normalized_bytes, JSON.generate(binding.declaration)
    assert_equal JSON.parse(File.read(BUDGET_FIXTURE)), binding.declaration
    assert_equal BINDING_SHA256, binding.binding_sha256
    assert_equal binding.binding_sha256, Digest::SHA256.hexdigest(binding.normalized_bytes)
  end

  def test_resume_reuses_budget_and_preserves_original_arm_time_and_deadline
    binding = build_binding
    first = binding.arm!
    @now += 60
    resumed = binding.arm!

    assert_equal 2, @supervisor.arm_count
    assert_equal first.fetch("armed_at_utc"), resumed.fetch("armed_at_utc")
    assert_equal first.fetch("deadline_at_utc"), resumed.fetch("deadline_at_utc")
    assert_equal first.dig("parent_budget", "armed_at_utc"),
                 resumed.dig("parent_budget", "armed_at_utc")
    assert_equal first.dig("parent_budget", "deadline_at_utc"),
                 resumed.dig("parent_budget", "deadline_at_utc")
    assert_equal @now.iso8601, resumed.fetch("last_resume_at_utc")
  end

  def test_changed_campaign_qualification_budget_or_limits_cannot_reuse_binding
    original = build_binding
    original.bind!

    changed_document = JSON.parse(File.read(FIXTURE))
    changed_document.fetch("profiles").first["desired_workers"] = 2
    changed_campaign = load_campaign(document: changed_document)
    assert_binding_mismatch(build_binding(campaign: changed_campaign))

    changed_hardware = Class.new do
      def profile_for(model)
        RunpodOllamaFleet::ExecutionPoolHardware::Profile.new(
          model:, cloud: "SECURE", gpu_ids: ["different-qualified-gpu"],
          shared_model: "shared/#{model}", global_volume_id: "volume",
          ollama_store_path: "/workspace-global/models"
        )
      end
    end.new
    qualified_differently = load_campaign(hardware: changed_hardware)
    assert_binding_mismatch(build_binding(campaign: qualified_differently))

    assert_binding_mismatch(build_binding(overrides: { "budget_id" => "different" }))
    assert_binding_mismatch(
      build_binding(overrides: { "max_cumulative_compute_usd" => 31.0 })
    )
  end

  def test_malformed_nonfinite_and_unknown_budget_declarations_fail_closed
    assert_error("unknown field") do
      build_binding(overrides: { "provider" => "runpod" })
    end
    assert_error("positive and finite") do
      build_binding(overrides: { "max_cumulative_compute_usd" => 0 })
    end
    assert_error("positive and finite") do
      build_binding(overrides: { "max_cumulative_compute_usd" => Float::INFINITY })
    end
    assert_error("positive and finite") do
      build_binding(overrides: { "max_cumulative_compute_usd" => "30" })
    end
    assert_error("must equal the campaign maximum") do
      build_binding(overrides: { "max_workers" => 7 })
    end
    assert_error("must equal the campaign hourly ceiling") do
      build_binding(overrides: { "max_aggregate_hourly_rate_usd" => 7.0 })
    end
  end

  def test_replacement_and_scaling_proofs_inherit_original_authority
    binding = build_binding
    first = binding.arm!
    proof = binding.mutation_authority!(
      expected_binding_sha256: binding.binding_sha256,
      additional_workers: 1,
      additional_hourly_rate_usd: 0.75
    )

    assert_equal binding.binding_sha256, proof.fetch("binding_sha256")
    assert_equal first.fetch("deadline_at_utc"), proof.fetch("original_deadline_at_utc")
    assert_equal 30.0, proof.fetch("max_cumulative_compute_usd")
    assert_equal 6.0, proof.fetch("max_aggregate_hourly_rate_usd")
    assert_equal 6, proof.fetch("max_workers")
    assert proof.frozen?

    reserved = binding.reserve_capacity_mutation!(
      expected_binding_sha256: binding.binding_sha256,
      operation_type: "replace",
      profile_id: "qwen35",
      logical_resource_id: "burst_1",
      max_hourly_rate_delta_usd: 0.75,
      reservation_id: "replacement-1"
    )
    assert_equal "pending", reserved.dig("reservation", "status")
    assert_equal binding.binding_sha256, reserved.fetch("binding_sha256")
  end

  def test_worker_rate_and_cumulative_authority_reject_projected_mutations
    binding = build_binding
    binding.arm!

    assert_error("worker ceiling") do
      binding.mutation_authority!(
        expected_binding_sha256: binding.binding_sha256,
        additional_workers: 7,
        additional_hourly_rate_usd: 1.0
      )
    end
    assert_error("aggregate hourly ceiling") do
      binding.mutation_authority!(
        expected_binding_sha256: binding.binding_sha256,
        additional_workers: 1,
        additional_hourly_rate_usd: 6.01
      )
    end

    constrained = build_binding(
      root: File.join(@tmp, "constrained"),
      supervisor: FakeGuardianSupervisor.new(-> { @now }),
      overrides: { "max_cumulative_compute_usd" => 0.01 }
    )
    constrained.arm!
    assert_error("remaining cumulative authority") do
      constrained.mutation_authority!(
        expected_binding_sha256: constrained.binding_sha256,
        additional_workers: 1,
        additional_hourly_rate_usd: 1.0
      )
    end
  end

  def test_parent_ledger_independently_reserves_worker_and_rate_ceilings
    binding = build_binding
    binding.arm!
    6.times do |index|
      binding.parent_budget.reserve_mutation!(
        operation_type: "scale_up",
        fleet_key: "qwen35",
        logical_resource_id: "burst_#{index + 1}",
        max_hourly_rate_delta_usd: 0.5,
        reservation_id: "worker-#{index + 1}"
      )
    end
    error = assert_raises(LocalModelEvaluation::RunpodBudget::Error) do
      binding.parent_budget.reserve_mutation!(
        operation_type: "replace",
        fleet_key: "qwen35",
        logical_resource_id: "burst_7",
        max_hourly_rate_delta_usd: 0.5,
        reservation_id: "worker-7"
      )
    end
    assert_includes error.message, "worker ceiling"

    rate_binding = build_binding(
      root: File.join(@tmp, "rate"),
      supervisor: FakeGuardianSupervisor.new(-> { @now })
    )
    rate_binding.arm!
    error = assert_raises(LocalModelEvaluation::RunpodBudget::Error) do
      rate_binding.parent_budget.reserve_mutation!(
        operation_type: "scale_up",
        fleet_key: "qwen35",
        logical_resource_id: "burst_1",
        max_hourly_rate_delta_usd: 6.01,
        reservation_id: "over-rate"
      )
    end
    assert_includes error.message, "aggregate hourly ceiling"
  end

  def test_ambiguous_arm_outcome_requires_inspection_and_cannot_silently_rearm
    @supervisor.fail_after_arm = true
    binding = build_binding
    error = assert_raises(RunpodOllamaFleet::CampaignBudgetBinding::Error) { binding.arm! }
    assert_includes error.message, "lost the arm result"

    inspection = binding.inspect_authority
    assert_equal "ARMING", inspection.fetch("phase")
    assert_equal "ARMED", inspection.dig("parent_budget", "state")
    assert_equal "arm", inspection.dig("last_error", "operation")

    @supervisor.fail_after_arm = false
    error = assert_raises(RunpodOllamaFleet::CampaignBudgetBinding::Error) { binding.arm! }
    assert_includes error.message, "ambiguous prior arm result"
    assert_equal 1, @supervisor.arm_count
  end

  def test_guardian_loss_blocks_mutation_without_changing_original_lease
    binding = build_binding
    armed = binding.arm!
    deadline = armed.fetch("deadline_at_utc")
    @supervisor.healthy = false

    status = binding.status
    assert_equal false, status.fetch("guardian_healthy")
    assert_equal false, status.dig("authority", "mutation_allowed")
    assert_includes status.dig("authority", "violations"), "guardian_not_independent_or_fresh"
    assert_equal deadline, status.fetch("deadline_at_utc")

    assert_error("guardian is not independently loaded and fresh") do
      binding.mutation_authority!(
        expected_binding_sha256: binding.binding_sha256,
        additional_workers: 1,
        additional_hourly_rate_usd: 0.5
      )
    end
  end

  def test_expired_original_deadline_transitions_parent_to_teardown
    binding = build_binding
    deadline = binding.arm!.fetch("deadline_at_utc")
    @now = Time.parse(deadline) + 1

    assert_error("TEARDOWN_REQUIRED") do
      binding.mutation_authority!(
        expected_binding_sha256: binding.binding_sha256,
        additional_workers: 1,
        additional_hourly_rate_usd: 0.5
      )
    end
    status = binding.parent_budget.status
    assert_equal "TEARDOWN_REQUIRED", status.fetch("state")
    assert_equal "runtime_expired", status.fetch("teardown_reason")
    assert_equal deadline, status.fetch("deadline_at_utc")
  end

  def test_deadline_tampering_and_missing_or_unreadable_binding_state_fail_closed
    binding = build_binding
    binding.arm!
    budget_state = JSON.parse(File.read(binding.parent_budget.state_path))
    budget_state["deadline_at_utc"] = (Time.parse(budget_state.fetch("deadline_at_utc")) + 60).iso8601
    File.write(binding.parent_budget.state_path, JSON.pretty_generate(budget_state) + "\n")
    assert_error("original arm time or deadline changed") { binding.status }

    File.delete(binding.parent_budget.state_path)
    assert_error("budget is not armed") { binding.status }

    File.write(binding.state_path, "{broken")
    assert_error("binding is unreadable") { binding.inspect_authority }

    File.delete(binding.state_path)
    assert_error("binding is missing") { binding.status }
  end

  def test_status_detects_preexisting_over_worker_and_rate_state
    binding = build_binding
    binding.arm!
    6.times do |index|
      binding.parent_budget.reserve_mutation!(
        operation_type: "scale_up",
        fleet_key: "qwen35",
        logical_resource_id: "burst_#{index + 1}",
        max_hourly_rate_delta_usd: 0.9,
        reservation_id: "external-#{index + 1}"
      )
    end
    ledger = JSON.parse(File.read(binding.parent_budget.state_path))
    seventh = Marshal.load(Marshal.dump(ledger.dig("reservations", "external-6")))
    seventh["reservation_id"] = "external-7"
    seventh["logical_resource_id"] = "burst_7"
    seventh["max_hourly_rate_delta_usd"] = 0.9
    ledger.fetch("reservations")["external-7"] = seventh
    File.write(binding.parent_budget.state_path, JSON.pretty_generate(ledger) + "\n")

    status = binding.status
    assert_equal 7, status.dig("authority", "committed_workers")
    assert_includes status.dig("authority", "violations"), "worker_ceiling_exceeded"
    assert_includes status.dig("authority", "violations"), "aggregate_hourly_rate_exceeded"
    assert_equal false, status.dig("authority", "mutation_allowed")

    enforced = binding.parent_budget.evaluate!
    assert_equal "TEARDOWN_REQUIRED", enforced.fetch("state")
    assert_equal "aggregate_hourly_rate_ceiling", enforced.fetch("teardown_reason")
  end

  private

  def build_binding(campaign: @campaign, overrides: {}, root: @tmp, supervisor: @supervisor)
    declaration = budget_declaration(campaign).merge(overrides)
    RunpodOllamaFleet::CampaignBudgetBinding.new(
      root:,
      repo_root: File.expand_path("..", __dir__),
      campaign:,
      declaration:,
      wall_clock: -> { @now },
      guardian_supervisor: supervisor
    )
  end

  def budget_declaration(campaign)
    {
      "contract_version" => "rpof-capacity-campaign-budget/v0.1",
      "campaign_identity" => campaign.identity,
      "campaign_identity_sha256" => campaign.identity_sha256,
      "budget_id" => "batch039-parent",
      "max_cumulative_compute_usd" => 30.0,
      "max_aggregate_hourly_rate_usd" => campaign.max_hourly_rate_usd,
      "max_workers" => campaign.max_workers,
      "max_runtime_seconds" => 5400.0,
      "guardian_poll_seconds" => 5.0,
      "orchestrator_heartbeat_timeout_seconds" => 30.0,
      "teardown_reserve_seconds" => 120.0
    }
  end

  def load_campaign(document: JSON.parse(File.read(FIXTURE)), hardware: nil)
    hardware ||= RunpodOllamaFleet::ExecutionPoolHardware.new(path: HARDWARE)
    RunpodOllamaFleet::CapacityCampaign.new(JSON.generate(document), hardware:)
  end

  def assert_binding_mismatch(binding)
    assert_error("does not match requested campaign, qualification, or limits") { binding.bind! }
  end

  def assert_error(message, &)
    error = assert_raises(RunpodOllamaFleet::CampaignBudgetBinding::Error, &)
    assert_includes error.message, message
  end
end
