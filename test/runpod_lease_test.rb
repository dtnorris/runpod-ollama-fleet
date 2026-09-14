# frozen_string_literal: true

require "minitest/autorun"
require "stringio"
require_relative "../lib/local_model_evaluation/runpod_lease"

class RunpodLeaseTest < Minitest::Test
  class FakeFleetState
    attr_accessor :current_record

    def initialize(current_record)
      @current_record = current_record
    end

    def current
      @current_record
    end
  end

  class FakeFleet
    attr_reader :destroyed

    def initialize
      @destroyed = []
    end

    def destroy(worker_indices:)
      @destroyed << worker_indices
      worker_indices
    end
  end

  def test_runtime_expiry_destroys_active_workers
    state = FakeFleetState.new(fleet_record(max_runtime_seconds: 600, max_spend_usd: nil))
    fleet = FakeFleet.new
    out = StringIO.new
    lease = LocalModelEvaluation::RunpodLease.new(
      fleet_state: state,
      fleet:,
      out:,
      wall_clock: -> { Time.utc(2026, 9, 13, 20, 11, 0) }
    )

    result = lease.enforce_once

    assert_equal "expired", result.fetch("status")
    assert_equal ["runtime"], result.fetch("expiration_reasons")
    assert_equal "destroyed", result.fetch("action")
    assert_equal [[1, 2]], fleet.destroyed
    assert_includes out.string, "lease expired (runtime)"
  end

  def test_spend_expiry_uses_conservative_clock_and_destroyed_worker_stop_time
    record = fleet_record(max_runtime_seconds: nil, max_spend_usd: 0.14)
    record.fetch("workers").first["status"] = "destroyed"
    record.fetch("workers").first["destroyed_at_utc"] = "2026-09-13T20:10:00Z"
    state = FakeFleetState.new(record)
    lease = LocalModelEvaluation::RunpodLease.new(
      fleet_state: state,
      fleet: FakeFleet.new,
      wall_clock: -> { Time.utc(2026, 9, 13, 20, 20, 0) }
    )

    snapshot = lease.snapshot

    # burst_1: $0.30/hr for 10m = $0.05; burst_2: $0.30/hr for 20m = $0.10.
    assert_in_delta 0.15, snapshot.fetch("estimated_spend_usd"), 0.000001
    assert_equal ["spend"], snapshot.fetch("expiration_reasons")
    assert_equal [2], snapshot.fetch("active_worker_indices")
    assert_in_delta 0.0, snapshot.fetch("budget_remaining_usd"), 0.000001
  end

  def test_watchdog_bound_to_old_fleet_exits_without_touching_replacement
    replacement = fleet_record(max_runtime_seconds: 1, max_spend_usd: nil)
    replacement["fleet_id"] = "20260913T210000Z-pod_new"
    state = FakeFleetState.new(replacement)
    fleet = FakeFleet.new
    out = StringIO.new
    lease = LocalModelEvaluation::RunpodLease.new(
      fleet_state: state,
      fleet:,
      expected_fleet_id: "20260913T200000Z-pod_old",
      out:,
      wall_clock: -> { Time.utc(2026, 9, 13, 22, 0, 0) }
    )

    result = lease.watch(poll_seconds: 1)

    assert_equal "fleet_replaced", result.fetch("status")
    assert_empty fleet.destroyed
    assert_includes out.string, "is no longer current"
  end

  def test_active_lease_reports_remaining_runtime_and_budget
    state = FakeFleetState.new(fleet_record(max_runtime_seconds: 3600, max_spend_usd: 1.0))
    lease = LocalModelEvaluation::RunpodLease.new(
      fleet_state: state,
      wall_clock: -> { Time.utc(2026, 9, 13, 20, 30, 0) }
    )

    snapshot = lease.snapshot

    assert_equal "active", snapshot.fetch("status")
    assert_equal "2026-09-13T21:00:00Z", snapshot.fetch("expires_at_utc")
    assert_in_delta 1800.0, snapshot.fetch("runtime_remaining_seconds"), 0.001
    assert_in_delta 0.30, snapshot.fetch("estimated_spend_usd"), 0.000001
    assert_in_delta 0.70, snapshot.fetch("budget_remaining_usd"), 0.000001
    assert_empty snapshot.fetch("expiration_reasons")

    output = lease.render(snapshot)
    assert_includes output, "Deadline: 2026-09-13T21:00:00Z"
    assert_includes output, "Runtime remaining: 00:30:00"
    assert_includes output, "Budget remaining: $0.7000"
  end

  private

  def fleet_record(max_runtime_seconds:, max_spend_usd:)
    {
      "fleet_id" => "20260913T200000Z-pod_a",
      "status" => "active",
      "lease" => {
        "started_at_utc" => "2026-09-13T20:00:00Z",
        "max_runtime_seconds" => max_runtime_seconds,
        "max_spend_usd" => max_spend_usd
      },
      "workers" => [
        worker(1, 0.30),
        worker(2, 0.30)
      ]
    }
  end

  def worker(index, rate)
    {
      "index" => index,
      "status" => "active",
      "hourly_rate_usd" => rate
    }
  end
end
