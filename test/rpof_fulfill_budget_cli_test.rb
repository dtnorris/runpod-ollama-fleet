# frozen_string_literal: true

require "minitest/autorun"
require "open3"
require "rbconfig"
require_relative "../lib/local_model_evaluation/runpod_fulfill_options"

class RpofFulfillBudgetCliTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)
  PLAN = "b" * 64

  def base_command
    [
      RbConfig.ruby,
      File.join(ROOT, "bin", "rpof-fulfill"),
      *base_args
    ]
  end

  def base_args
    [
      "--target-workers", "1",
      "--minimum-workers", "1",
      "--gpu", "NVIDIA A40",
      "--max-hourly-per-worker", "1.0",
      "--yes"
    ]
  end

  def budget_args
    [
      "--budget-id", "batch034",
      "--budget-plan-sha256", PLAN,
      "--budget-max-cumulative-compute-usd", "5.0",
      "--budget-max-runtime-seconds", "2700",
      "--budget-guardian-poll-seconds", "5",
      "--budget-orchestrator-heartbeat-timeout-seconds", "30",
      "--budget-teardown-reserve-seconds", "60"
    ]
  end

  def budget_options
    {
      budget_id: "batch034",
      budget_plan_sha256: PLAN,
      budget_max_cumulative_compute_usd: 5.0,
      budget_max_runtime_seconds: 2700.0,
      budget_guardian_poll_seconds: 5.0,
      budget_orchestrator_heartbeat_timeout_seconds: 30.0,
      budget_teardown_reserve_seconds: 60.0
    }
  end

  def test_noninteractive_paid_fulfillment_requires_parent_budget
    assert_invalid("parent burst budget options are required")
  end

  def test_complete_budget_options_pass_parser_before_provider_key_gate
    _stdout, stderr, status = Open3.capture3(
      { "RUNPOD_API_KEY" => "" },
      *base_command,
      *budget_args,
      chdir: ROOT
    )

    assert_equal 1, status.exitstatus
    assert_includes stderr, "RUNPOD_API_KEY is missing"
    refute_includes stderr, "parent burst budget options are required"
  end

  def test_partial_budget_options_fail_closed
    assert_invalid("budget options must be supplied together", budget_id: "batch034")
  end

  def test_parent_budget_rejects_independent_child_lease_options
    assert_invalid(
      "parent burst budget derives the child fleet runtime/spend lease",
      **budget_options,
      max_runtime_seconds: 600.0,
      max_spend_usd: 1.0
    )
  end

  private

  def valid_options
    {
      target_workers: 1,
      minimum_workers: 1,
      gpu_ids: ["NVIDIA A40"],
      max_hourly_per_worker_usd: 1.0,
      expect_initial_workers: nil,
      network_volume_id: nil,
      global_volume_id: nil,
      volume_gb: nil,
      max_runtime_seconds: nil,
      max_spend_usd: nil,
      budget_id: nil,
      budget_plan_sha256: nil,
      budget_max_cumulative_compute_usd: nil,
      budget_max_runtime_seconds: nil,
      budget_guardian_poll_seconds: nil,
      budget_orchestrator_heartbeat_timeout_seconds: nil,
      budget_teardown_reserve_seconds: nil,
      yes: true,
      dry_run: false
    }
  end

  def assert_invalid(expected_message, **overrides)
    error = assert_raises(OptionParser::ParseError) do
      LocalModelEvaluation::RunpodFulfillOptions.validate!(
        valid_options.merge(overrides),
        []
      )
    end
    assert_includes error.message, expected_message
  end
end
