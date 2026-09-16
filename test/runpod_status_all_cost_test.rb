# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/local_model_evaluation/runpod_status_all"

class RunpodStatusAllCostTest < Minitest::Test
  def test_reports_productive_and_unproductive_hourly_burn
    workers = [
      worker(1, 1.00, "active"),
      worker(2, 2.00, "idle"),
      worker(3, 3.00, "unavailable"),
      worker(4, 4.00, "unknown")
    ]
    entries = [{
      "fleet_key" => "main",
      "snapshot" => {
        "lme_status" => "active",
        "created_at_utc" => "2026-09-16T17:00:00Z",
        "current_tracked_hourly_rate_usd" => 10.0,
        "estimated_accrued_cost_usd" => 1.5,
        "workers" => workers,
        "bootstrap" => nil
      }
    }]

    overview = LocalModelEvaluation::RunpodStatusAll.new
    snapshot = overview.snapshot(entries)

    assert_in_delta 1.0, snapshot.fetch("productive_hourly_rate_usd"), 0.000001
    assert_in_delta 9.0, snapshot.fetch("unproductive_hourly_rate_usd"), 0.000001
    output = overview.render(snapshot)
    assert_includes output, "Productive ACTIVE rate: $1.0000/hr"
    assert_includes output, "Unproductive burn: $9.0000/hr"
    assert_includes output, "unavailable $3.0000/hr"
  end

  private

  def worker(index, rate, inference)
    {
      "index" => index,
      "pod_id" => "pod_#{index}",
      "gpu_id" => "GPU",
      "available_models" => [],
      "loaded_models" => [],
      "model_status" => "ok",
      "lme_status" => "active",
      "provider_status" => "RUNNING",
      "hourly_rate_usd" => rate,
      "inference_status" => inference
    }
  end
end
