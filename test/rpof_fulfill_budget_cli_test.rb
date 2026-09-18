# frozen_string_literal: true

require "minitest/autorun"
require "open3"
require "rbconfig"

class RpofFulfillBudgetCliTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)
  PLAN = "b" * 64

  def base_command
    [
      RbConfig.ruby,
      File.join(ROOT, "bin", "rpof-fulfill"),
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

  def test_noninteractive_paid_fulfillment_requires_parent_budget
    _stdout, stderr, status = Open3.capture3(
      { "RUNPOD_API_KEY" => "" },
      *base_command,
      chdir: ROOT
    )

    assert_equal 2, status.exitstatus
    assert_includes stderr, "parent burst budget options are required"
    refute_includes stderr, "RUNPOD_API_KEY is missing"
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
    _stdout, stderr, status = Open3.capture3(
      { "RUNPOD_API_KEY" => "" },
      *base_command,
      "--budget-id", "batch034",
      chdir: ROOT
    )

    assert_equal 2, status.exitstatus
    assert_includes stderr, "budget options must be supplied together"
  end
end
