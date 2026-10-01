# frozen_string_literal: true

require_relative "test_helper"
require "open3"
require "rbconfig"

class OperatorProcessOwnershipTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)

  def test_top_level_help_distinguishes_observation_work_and_teardown
    stdout, stderr, status = Open3.capture3(RbConfig.ruby, File.join(ROOT, "bin", "rpof"), chdir: ROOT)

    assert status.success?, stderr
    assert_includes stderr, "ONE-SHOT INSPECTION/PUBLICATION"
    assert_includes stderr, "campaign start"
    assert_includes stderr, "RESOURCE MUTATION"
    assert_includes stderr, "campaign stop"
    assert_includes stderr, "TEARDOWN REQUEST"
    assert_includes stderr, "guardian is a safety enforcer, not a campaign controller"
    assert_includes stderr, "Ctrl-C interrupts only this request"
    assert_includes stderr, "complete until campaign status reports CLOSED"
    assert_includes stderr, "WLO pause and RPOF teardown are separate lifecycle actions"
    assert_empty stdout
  end

  def test_campaign_help_states_short_lived_cli_and_verified_teardown_rule
    stdout, stderr, status = Open3.capture3(
      RbConfig.ruby, File.join(ROOT, "bin", "rpof"), "campaign", "--help", chdir: ROOT
    )

    assert status.success?, stderr
    assert_includes stdout, "plan/status  ONE-SHOT INSPECTION"
    assert_includes stdout, "start        RESOURCE MUTATION"
    assert_includes stdout, "independent guardian continue"
    assert_includes stdout, "guardian is not a campaign controller"
    assert_includes stdout, "stop         TEARDOWN REQUEST"
    assert_includes stdout, "provider absence and CLOSED"
    assert_includes stdout, "use `wlo pause` to pause work"
  end
end
