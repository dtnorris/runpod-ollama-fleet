# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require_relative "../lib/local_model_evaluation/runpod_budget"

class RunpodBudgetTest < Minitest::Test
  PLAN = "a" * 64

  def setup
    @tmp = Dir.mktmpdir("rpof-budget-")
    @now = Time.utc(2026, 9, 18, 20, 0, 0)
    @budget = LocalModelEvaluation::RunpodBudget.new(
      root: @tmp,
      budget_id: "batch034",
      plan_sha256: PLAN,
      wall_clock: -> { @now }
    )
  end

  def teardown
    FileUtils.remove_entry(@tmp) if @tmp && File.exist?(@tmp)
  end

  def test_arm_persists_immutable_deadline_and_resume_does_not_reset_it
    first = @budget.arm!(budget: budget_config, guardian_heartbeat_at_utc: @now)
    assert_equal "ARMED", first.fetch("state")
    deadline = first.fetch("deadline_at_utc")

    @now += 60
    resumed = @budget.arm!(budget: budget_config, guardian_heartbeat_at_utc: @now)
    assert_equal deadline, resumed.fetch("deadline_at_utc")
    assert_equal "2026-09-18T20:00:00Z", resumed.fetch("armed_at_utc")
    assert_equal "2026-09-18T20:01:00Z", resumed.fetch("last_orchestrator_heartbeat_at_utc")
  end

  def test_arm_rejects_budget_limit_change
    @budget.arm!(budget: budget_config, guardian_heartbeat_at_utc: @now)
    changed = budget_config.merge("max_cumulative_compute_usd" => 6.0)

    error = assert_raises(LocalModelEvaluation::RunpodBudget::Error) do
      @budget.arm!(budget: changed, guardian_heartbeat_at_utc: @now)
    end
    assert_includes error.message, "immutable limits"
  end

  def test_reservation_uses_committed_liability_and_rejects_oversubscription
    config = budget_config.merge("max_cumulative_compute_usd" => 0.05)
    @budget.arm!(budget: config, guardian_heartbeat_at_utc: @now)

    first = @budget.reserve_mutation!(
      operation_type: "scale_up",
      fleet_key: "qwen35",
      logical_resource_id: "burst_1",
      max_hourly_rate_delta_usd: 1.0,
      reservation_id: "r1"
    )
    assert_equal "pending", first.fetch("status")

    error = assert_raises(LocalModelEvaluation::RunpodBudget::Error) do
      @budget.reserve_mutation!(
        operation_type: "scale_up",
        fleet_key: "qwen35",
        logical_resource_id: "burst_2",
        max_hourly_rate_delta_usd: 1.0,
        reservation_id: "r2"
      )
    end
    assert_includes error.message, "exceed cumulative cap"

    status = @budget.status
    assert_equal ["r1"], status.fetch("reservations").keys
    assert_in_delta 1.0, status.fetch("committed_rate_usd_per_hour"), 0.000001
  end

  def test_commit_replaces_reserved_rate_with_actual_rate_and_accrues_from_reservation_time
    @budget.arm!(budget: budget_config, guardian_heartbeat_at_utc: @now)
    reservation = @budget.reserve_mutation!(
      operation_type: "create",
      fleet_key: "qwen35",
      logical_resource_id: "burst_1",
      max_hourly_rate_delta_usd: 3.0,
      reservation_id: "r1"
    )

    @now += 120
    @budget.heartbeat!(source: "guardian")
    @budget.heartbeat!(source: "orchestrator")
    @budget.commit_mutation!(
      reservation_id: "r1",
      provider_resource_id: "pod-1",
      actual_hourly_rate_usd: 0.50,
      started_at_utc: reservation.fetch("created_at_utc")
    )

    status = @budget.status
    assert_in_delta 0.5, status.fetch("committed_rate_usd_per_hour"), 0.000001
    assert_in_delta(0.5 * 120 / 3600.0, status.fetch("accrued_compute_usd"), 0.000001)
    assert_equal "committed", status.dig("reservations", "r1", "status")
    assert_equal "active", status.dig("owned_resources", "pod-1", "status")
  end

  def test_pending_reservation_accrues_at_reserved_rate_until_reconciled
    @budget.arm!(budget: budget_config, guardian_heartbeat_at_utc: @now)
    @budget.reserve_mutation!(
      operation_type: "create",
      fleet_key: "qwen35",
      logical_resource_id: "burst_1",
      max_hourly_rate_delta_usd: 2.0,
      reservation_id: "r1"
    )

    @now += 90
    @budget.heartbeat!(source: "guardian")
    @budget.heartbeat!(source: "orchestrator")
    status = @budget.status
    assert_in_delta(2.0 * 90 / 3600.0, status.fetch("accrued_compute_usd"), 0.000001)
    assert_in_delta 2.0, status.fetch("committed_rate_usd_per_hour"), 0.000001
  end

  def test_actual_rate_above_reservation_forces_teardown
    @budget.arm!(budget: budget_config, guardian_heartbeat_at_utc: @now)
    @budget.reserve_mutation!(
      operation_type: "create",
      fleet_key: "qwen35",
      logical_resource_id: "burst_1",
      max_hourly_rate_delta_usd: 0.50,
      reservation_id: "r1"
    )

    error = assert_raises(LocalModelEvaluation::RunpodBudget::Error) do
      @budget.commit_mutation!(
        reservation_id: "r1",
        provider_resource_id: "pod-1",
        actual_hourly_rate_usd: 0.60
      )
    end
    assert_includes error.message, "exceeds reserved maximum"

    status = @budget.status
    assert_equal "TEARDOWN_REQUIRED", status.fetch("state")
    assert_equal "provider_rate_exceeded_reservation", status.fetch("teardown_reason")
    assert_equal "active", status.dig("owned_resources", "pod-1", "status")
  end

  def test_release_requires_proof_that_no_provider_resource_remains
    @budget.arm!(budget: budget_config, guardian_heartbeat_at_utc: @now)
    @budget.reserve_mutation!(
      operation_type: "create",
      fleet_key: "qwen35",
      logical_resource_id: "burst_1",
      max_hourly_rate_delta_usd: 1.0,
      reservation_id: "r1"
    )

    error = assert_raises(LocalModelEvaluation::RunpodBudget::Error) do
      @budget.release_reservation!(reservation_id: "r1", reason: "guess")
    end
    assert_includes error.message, "requires proof"

    released = @budget.release_reservation!(
      reservation_id: "r1",
      reason: "provider call was never attempted",
      mutation_not_attempted: true
    )
    assert_equal "released", released.fetch("status")
  end

  def test_verified_absence_release_preserves_conservative_pending_accrual
    @budget.arm!(budget: budget_config, guardian_heartbeat_at_utc: @now)
    @budget.reserve_mutation!(
      operation_type: "create",
      fleet_key: "qwen35",
      logical_resource_id: "burst_1",
      max_hourly_rate_delta_usd: 2.0,
      reservation_id: "r1"
    )
    @now += 90
    @budget.release_reservation!(
      reservation_id: "r1",
      reason: "provider absence verified after uncertain create",
      provider_absence_verified: true
    )

    accrued = @budget.status.fetch("accrued_compute_usd")
    assert_in_delta(2.0 * 90 / 3600.0, accrued, 0.000001)
    @now += 300
    assert_in_delta accrued, @budget.status.fetch("accrued_compute_usd"), 0.000001
  end

  def test_mark_absent_stops_accrual_and_close_requires_no_active_or_pending_liability
    @budget.arm!(budget: budget_config, guardian_heartbeat_at_utc: @now)
    reservation = @budget.reserve_mutation!(
      operation_type: "create",
      fleet_key: "qwen35",
      logical_resource_id: "burst_1",
      max_hourly_rate_delta_usd: 1.0,
      reservation_id: "r1"
    )
    @budget.commit_mutation!(
      reservation_id: "r1",
      provider_resource_id: "pod-1",
      actual_hourly_rate_usd: 0.50,
      started_at_utc: reservation.fetch("created_at_utc")
    )

    assert_raises(LocalModelEvaluation::RunpodBudget::Error) { @budget.close! }
    @now += 60
    @budget.mark_resource_absent!(provider_resource_id: "pod-1", verified_absent: true)
    accrued = @budget.status.fetch("accrued_compute_usd")
    @now += 300
    assert_in_delta accrued, @budget.status.fetch("accrued_compute_usd"), 0.000001

    closed = @budget.close!
    assert_equal "CLOSED", closed.fetch("state")
  end

  def test_stale_orchestrator_heartbeat_transitions_to_teardown_and_blocks_mutation
    @budget.arm!(budget: budget_config, guardian_heartbeat_at_utc: @now)
    @now += 31
    @budget.heartbeat!(source: "guardian")

    status = @budget.evaluate!
    assert_equal "TEARDOWN_REQUIRED", status.fetch("state")
    assert_equal "stale_orchestrator_heartbeat", status.fetch("teardown_reason")

    error = assert_raises(LocalModelEvaluation::RunpodBudget::Error) do
      @budget.reserve_mutation!(
        operation_type: "create",
        fleet_key: "qwen35",
        logical_resource_id: "burst_1",
        max_hourly_rate_delta_usd: 1.0
      )
    end
    assert_includes error.message, "TEARDOWN_REQUIRED"
  end

  def test_stale_guardian_blocks_positive_mutation
    @budget.arm!(budget: budget_config, guardian_heartbeat_at_utc: @now)
    @now += 11
    @budget.heartbeat!(source: "orchestrator")

    status = @budget.evaluate!
    assert_equal "TEARDOWN_REQUIRED", status.fetch("state")
    assert_equal "stale_guardian_heartbeat", status.fetch("teardown_reason")
  end

  def test_deadline_is_absolute_and_heartbeat_does_not_extend_it
    config = budget_config.merge("max_runtime_seconds" => 60.0)
    first = @budget.arm!(budget: config, guardian_heartbeat_at_utc: @now)
    deadline = first.fetch("deadline_at_utc")

    @now += 59
    @budget.heartbeat!(source: "guardian")
    @budget.heartbeat!(source: "orchestrator")
    assert_equal deadline, @budget.status.fetch("deadline_at_utc")

    @now += 2
    status = @budget.evaluate!
    assert_equal "TEARDOWN_REQUIRED", status.fetch("state")
    assert_equal "runtime_expired", status.fetch("teardown_reason")
  end

  def test_child_lease_uses_parent_deadline_and_only_shrinks
    config = budget_config.merge(
      "max_cumulative_compute_usd" => 0.70,
      "max_runtime_seconds" => 3600.0
    )
    first = @budget.arm!(budget: config, guardian_heartbeat_at_utc: @now)
    @budget.reserve_mutation!(
      operation_type: "create",
      fleet_key: "qwen27",
      logical_resource_id: "burst_1",
      max_hourly_rate_delta_usd: 0.60,
      reservation_id: "r1"
    )

    lease = @budget.child_lease_limits!(max_fleet_hourly_usd: 0.60)
    assert_equal first.fetch("deadline_at_utc"), lease.fetch("deadline_at_utc")
    assert_in_delta 3600.0, lease.fetch("remaining_runtime_seconds"), 0.001
    assert_in_delta 0.60, lease.fetch("max_spend_usd"), 0.000001

    @now += 60
    @budget.heartbeat!(source: "guardian")
    @budget.heartbeat!(source: "orchestrator")
    later = @budget.child_lease_limits!(max_fleet_hourly_usd: 0.60)

    assert_equal lease.fetch("deadline_at_utc"), later.fetch("deadline_at_utc")
    assert_in_delta 3540.0, later.fetch("remaining_runtime_seconds"), 0.001
    assert_operator later.fetch("max_spend_usd"), :<, lease.fetch("max_spend_usd")
    assert_in_delta 0.59, later.fetch("max_spend_usd"), 0.000001
  end

  def test_file_lock_serializes_two_reservations_against_same_remaining_budget
    config = budget_config.merge("max_cumulative_compute_usd" => 0.05)
    @budget.arm!(budget: config, guardian_heartbeat_at_utc: @now)
    outcomes = Queue.new

    threads = 2.times.map do |index|
      Thread.new do
        begin
          @budget.reserve_mutation!(
            operation_type: "scale_up",
            fleet_key: "qwen35",
            logical_resource_id: "burst_#{index + 1}",
            max_hourly_rate_delta_usd: 1.0,
            reservation_id: "r#{index + 1}"
          )
          outcomes << :ok
        rescue LocalModelEvaluation::RunpodBudget::Error
          outcomes << :blocked
        end
      end
    end
    threads.each(&:join)

    values = 2.times.map { outcomes.pop }.sort
    assert_equal %i[blocked ok], values
    pending = @budget.status.fetch("reservations").values.count { |row| row.fetch("status") == "pending" }
    assert_equal 1, pending
  end

  private

  def budget_config
    {
      "contract_version" => "afio-production-burst-budget/v0.1",
      "budget_id" => "batch034",
      "plan_sha256" => PLAN,
      "max_cumulative_compute_usd" => 5.0,
      "max_runtime_seconds" => 2700.0,
      "guardian_poll_seconds" => 5.0,
      "orchestrator_heartbeat_timeout_seconds" => 30.0,
      "teardown_reserve_seconds" => 60.0
    }
  end
end
