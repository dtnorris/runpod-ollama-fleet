# frozen_string_literal: true

require "minitest/autorun"
require "open3"
require "rbconfig"
require "tmpdir"
require_relative "../lib/local_model_evaluation/runpod_cost_control"

class Dw33CompatibilityRemovalTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)

  def test_workload_dispatch_routes_and_direct_executables_are_removed
    %w[dispatch dispatch-admit dispatch-close dispatch-legacy execution-pool-fulfill].each do |command|
      out, err, status = Open3.capture3(
        { "RUNPOD_API_KEY" => nil }, RbConfig.ruby, File.join(ROOT, "bin/rpof"), command
      )

      assert_equal 2, status.exitstatus, command
      assert_empty out
      assert_includes err, "Usage: bin/rpof COMMAND"
      executable = command == "dispatch-legacy" ? "lme-runpod-dispatch" : "rpof-#{command}"
      refute_path_exists File.join(ROOT, "bin", executable)
    end
  end

  def test_status_all_reads_cost_policy_from_the_workers_custom_state_root
    Dir.mktmpdir("dw33-status-") do |root|
      state_root = File.join(root, "custom-state")
      control = LocalModelEvaluation::RunpodCostControl.new(root: state_root, repo_root: root)
      control.enable!(max_total_hourly_usd: 1.25)
      env = {
        "RUNPOD_API_KEY" => nil,
        "RPOF_STATE_ROOT" => " #{state_root} ",
        "RPOF_STATE_REPO_ROOT" => root
      }
      out, err, status = Open3.capture3(
        env, RbConfig.ruby, File.join(ROOT, "bin/rpof"), "status", "--all", "--verbose"
      )

      assert status.success?, err
      assert_includes out, "Runtime aggregate cap: $1.2500/hr"
      assert_includes out, "No active managed RunPod fleets."
    end
  end
end
