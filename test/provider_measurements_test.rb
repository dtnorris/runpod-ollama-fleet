# frozen_string_literal: true

require_relative "test_helper"
require "runpod_ollama_fleet"

class ProviderMeasurementsTest < Minitest::Test
  NOW = Time.iso8601("2026-10-04T12:00:00Z")
  SHA = "a" * 64

  def test_no_active_capacity_is_measured_without_provider_access
    result = measure(budget)

    assert_equal "rpof-provider-cost-measurements/v0.1", result.fetch("contract_version")
    assert result.fetch("read_only")
    assert_equal 0, result.dig("capacity", "tracked_active_paid_resources")
    assert_equal "unavailable", result.dig("capacity", "provider_active_workers", "status")
    assert_equal 0.0, result.dig("cost", "accrued_tracked_compute_usd")
    assert_includes result.fetch("billing_scope"), "tracked RunPod compute only"
  end

  def test_active_not_ready_is_cold_start_and_ready_idle_remains_unavailable
    source = budget(resources: [resource(rate: 2.0)])
    state = bringup("overall_status" => "not_started")

    result = measure(source, [state])

    assert_equal 1, result.dig("capacity", "bringup_in_progress_workers")
    assert_equal 3600.0, result.dig("timing", "cold_start", "total_seconds")
    assert_equal 2.0, result.dig("cost", "cold_start_compute_usd")
    assert_equal "unavailable", result.dig("timing", "paid_idle_duration", "status")
    assert_equal "unavailable", result.dig("cost", "useful_work_compute_usd", "status")
  end

  def test_passed_bringup_splits_cold_start_and_usable_capacity_estimate
    source = budget(resources: [resource(rate: 2.0)])
    state = bringup(
      "overall_status" => "prerequisites_passed",
      "readiness_prerequisites_satisfied" => true,
      "tunnel" => stage("passed", "2026-10-04T11:10:00Z"),
      "bootstrap" => stage("passed", "2026-10-04T11:20:00Z"),
      "capability" => stage("passed", "2026-10-04T11:30:00Z")
    )

    result = measure(source, [state])

    assert_equal 1800.0, result.dig("timing", "cold_start", "total_seconds")
    assert_equal 1800.0, result.dig("timing", "usable_capacity", "total_seconds")
    assert_equal 1.0, result.dig("cost", "cold_start_compute_usd")
    assert_equal "estimated", result.dig("cost", "usable_capacity_compute_estimate", "status")
    assert_equal 1.0, result.dig("cost", "usable_capacity_compute_estimate", "usd")
    assert_equal 1, result.dig("cost", "allocation_coverage", "resource_count")
    assert_equal({ "worker_id" => "worker-1", "generation_id" => "gen-1" },
                 result.dig("timing", "tracked_resource_intervals", 0, "worker_identity"))
  end

  def test_failed_bringup_keeps_failure_time_and_cost_visible
    source = budget(resources: [resource(rate: 3.0)])
    state = bringup(
      "overall_status" => "failed",
      "bootstrap" => stage("failed_terminal", "2026-10-04T11:20:00Z")
    )

    result = measure(source, [state])

    assert_equal 1, result.dig("samples", "failed_bringup_samples")
    assert_equal 1200.0, result.dig("timing", "cold_start", "total_seconds")
    assert_equal 3600.0, result.dig("failures", "failed_bringup_tracked_seconds")
    assert_equal 3.0, result.dig("failures", "failed_bringup_compute_usd")
  end

  def test_missing_rate_and_historical_missing_bringup_are_explicit
    row = resource(rate: 2.0)
    row.delete("hourly_rate_usd")
    result = measure(budget(resources: [row]))

    refute result.dig("rates", "rate_evidence_known_for_every_included_resource")
    assert_equal "unavailable", result.dig("rates", "active_paid_resources_hourly_usd", "status")
    assert_equal 1, result.dig("samples", "resources_without_correlated_bringup_evidence")
    assert_equal 0, result.dig("cost", "allocation_coverage", "resource_count")
  end

  def test_pending_liability_registry_counts_and_teardown_are_exposed
    source = budget(
      reservations: [{
        "reservation_id" => "pending", "status" => "pending",
        "max_hourly_rate_delta_usd" => 4.0, "created_at_utc" => "2026-10-04T11:50:00Z"
      }],
      extra: {
        "committed_rate_usd_per_hour" => 4.0,
        "committed_maximum_liability_usd" => 8.0,
        "teardown_started_at_utc" => "2026-10-04T11:40:00Z",
        "provider_absence_verified_at_utc" => "2026-10-04T11:55:00Z"
      }
    )
    registry = { "workers" => [{ "state" => "READY" }, { "state" => "NOT_READY" }] }
    result = measure(source, [], registry:)

    assert_equal 1, result.dig("capacity", "pending_or_ambiguous_paid_reservations")
    assert_equal 1, result.dig("capacity", "registry_ready_workers", "count")
    assert_equal 1, result.dig("capacity", "registry_not_ready_workers", "count")
    assert_equal 8.0, result.dig("cost", "committed_and_pending_maximum_liability_usd")
    assert_equal 900.0, result.dig("timing", "teardown", "elapsed_seconds")
  end

  def test_measurement_does_not_mutate_inputs
    source = budget(resources: [resource(rate: 2.0)])
    states = [bringup("overall_status" => "not_started")]
    before = JSON.generate([source, states])

    measure(source, states)

    assert_equal before, JSON.generate([source, states])
  end

  private

  def measure(source, states = [], registry: nil)
    RunpodOllamaFleet::ProviderMeasurements.new(
      budget: source, bringup_states: states, registry:, clock: -> { NOW }
    ).document
  end

  def budget(resources: [], reservations: [], extra: {})
    {
      "budget_id" => "budget-1", "plan_sha256" => SHA, "state" => "ARMED",
      "armed_at_utc" => "2026-10-04T11:00:00Z", "closed_at_utc" => nil,
      "provider_absence_verified_at_utc" => nil, "teardown_started_at_utc" => nil,
      "owned_resources" => resources.to_h { |row| [row.fetch("provider_resource_id"), row] },
      "reservations" => reservations.to_h { |row| [row.fetch("reservation_id"), row] },
      "accrued_compute_usd" => resources.sum { |row| row["hourly_rate_usd"].to_f },
      "committed_rate_usd_per_hour" => resources.sum { |row| row["hourly_rate_usd"].to_f },
      "committed_maximum_liability_usd" => resources.sum { |row| row["hourly_rate_usd"].to_f }
    }.merge(extra)
  end

  def resource(rate:)
    {
      "provider_resource_id" => "pod-1", "status" => "active",
      "hourly_rate_usd" => rate, "started_at_utc" => "2026-10-04T11:00:00Z",
      "stopped_at_utc" => nil
    }
  end

  def bringup(extra)
    {
      "identity" => {
        "provider_resource_id" => "pod-1", "worker_id" => "worker-1", "generation_id" => "gen-1"
      },
      "overall_status" => "not_started", "readiness_prerequisites_satisfied" => false,
      "updated_at_utc" => "2026-10-04T11:00:00Z",
      "tunnel" => stage("not_started", "2026-10-04T11:00:00Z"),
      "bootstrap" => stage("not_started", "2026-10-04T11:00:00Z"),
      "capability" => stage("not_started", "2026-10-04T11:00:00Z")
    }.merge(extra)
  end

  def stage(status, at)
    { "status" => status, "updated_at_utc" => at }
  end
end
