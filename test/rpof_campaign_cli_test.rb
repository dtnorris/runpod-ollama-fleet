# frozen_string_literal: true

require_relative "test_helper"
require "json"
require "open3"

class RpofCampaignCliTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)
  CAMPAIGN = File.join(ROOT, "test", "fixtures", "rpof-capacity-campaign-v0.1.json")
  BUDGET = File.join(ROOT, "test", "fixtures", "rpof-capacity-campaign-budget-v0.1.json")

  def setup
    @tmp = Dir.mktmpdir("rpof-campaign-cli-")
  end

  def teardown
    FileUtils.remove_entry(@tmp) if @tmp && File.exist?(@tmp)
  end

  def test_plan_json_is_read_only_without_credentials
    stdout, stderr, status = run_cli("plan", "--json")

    assert status.success?, stderr
    result = JSON.parse(stdout)
    assert result.fetch("read_only")
    refute result.fetch("paid_resources_created")
    assert_equal "production-batch-039", result.dig("campaign", "campaign_id")
    refute File.exist?(File.join(@tmp, "campaign-budgets"))
  end

  def test_start_without_authorization_prints_plan_and_exits_before_mutation
    stdout, stderr, status = run_cli("start", "--json")

    assert_equal 2, status.exitstatus, stderr
    assert JSON.parse(stdout).fetch("authorization_required")
    refute File.exist?(File.join(@tmp, "campaign-budgets"))
  end

  def test_top_level_campaign_dispatch_preserves_command_surface
    stdout, stderr, status = run_cli("plan", "--json", top_level: true)
    assert status.success?, stderr
    assert_equal "campaign plan", JSON.parse(stdout).fetch("command")
  end

  private

  def run_cli(command, *extra, top_level: false)
    executable = File.join(ROOT, "bin", top_level ? "rpof" : "rpof-campaign")
    argv = [RbConfig.ruby, executable]
    argv << "campaign" if top_level
    argv.concat([
      command, "--campaign", CAMPAIGN, "--budget", BUDGET,
      "--state-root", @tmp, *extra
    ])
    env = { "RUNPOD_API_KEY" => nil, "RUNPOD_API_BASE_URL" => nil }
    Open3.capture3(env, *argv, chdir: ROOT)
  end
end
