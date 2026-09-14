# frozen_string_literal: true

require_relative "test_helper"
require "open3"
require "rbconfig"

class RunpodBootstrapCliTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)
  BIN = File.join(ROOT, "bin", "lme-runpod-bootstrap")

  def test_help_advertises_cache_reuse
    out, err, status = Open3.capture3(RbConfig.ruby, BIN, "--help")

    assert status.success?, err
    assert_includes out, "--reuse-existing"
  end

  def test_clean_and_reuse_existing_fail_before_fleet_access
    out, err, status = Open3.capture3(
      RbConfig.ruby,
      BIN,
      "--workers", "1",
      "--model", "gemma4:26b",
      "--clean",
      "--reuse-existing"
    )

    refute status.success?, out + err
    assert_equal 2, status.exitstatus
    assert_includes err, "--clean cannot be combined with --reuse-existing"
  end
end
