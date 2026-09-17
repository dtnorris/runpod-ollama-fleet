# frozen_string_literal: true

require_relative "test_helper"
require "open3"
require "rbconfig"

class RunpodBootstrapCliTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)
  BIN = File.join(ROOT, "bin", "lme-runpod-bootstrap")

  def test_help_advertises_bootstrap_storage_modes
    out, err, status = Open3.capture3(RbConfig.ruby, BIN, "--help")

    assert status.success?, err
    assert_includes out, "--reuse-existing"
    assert_includes out, "--copy-to-workspace"
    assert_includes out, "--copy-from-shared-store"
    assert_includes out, "--keep-root-models"
    assert_includes out, "--pull-timeout-seconds"
  end

  def test_pull_timeout_must_be_positive_before_fleet_access
    out, err, status = Open3.capture3(
      RbConfig.ruby,
      BIN,
      "--workers", "1",
      "--model", "gemma4:26b",
      "--pull-timeout-seconds", "0"
    )

    refute status.success?, out + err
    assert_equal 2, status.exitstatus
    assert_includes err, "--pull-timeout-seconds must be a positive integer"
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

  def test_copy_to_workspace_and_reuse_existing_fail_before_fleet_access
    out, err, status = Open3.capture3(
      RbConfig.ruby,
      BIN,
      "--workers", "1",
      "--model", "gemma4:26b",
      "--copy-to-workspace",
      "--reuse-existing"
    )

    refute status.success?, out + err
    assert_equal 2, status.exitstatus
    assert_includes err, "--copy-to-workspace cannot be combined with --reuse-existing"
  end

  def test_keep_root_models_and_reuse_existing_fail_before_fleet_access
    out, err, status = Open3.capture3(
      RbConfig.ruby,
      BIN,
      "--workers", "1",
      "--model", "gemma4:26b",
      "--keep-root-models",
      "--reuse-existing"
    )

    refute status.success?, out + err
    assert_equal 2, status.exitstatus
    assert_includes err, "--keep-root-models cannot be combined with --reuse-existing"
  end

  def test_copy_from_shared_store_requires_absolute_path_before_fleet_access
    out, err, status = Open3.capture3(
      RbConfig.ruby,
      BIN,
      "--workers", "1",
      "--model", "qwen3.6:35b-a3b-q4_K_M",
      "--copy-from-shared-store", "workspace-global/ollama-models"
    )

    refute status.success?, out + err
    assert_equal 2, status.exitstatus
    assert_includes err, "--copy-from-shared-store must be an absolute remote path"
  end

  def test_copy_from_shared_store_rejects_pull_or_mutating_storage_modes_before_fleet_access
    [
      ["--reuse-existing", "--copy-from-shared-store cannot be combined with --reuse-existing"],
      ["--copy-to-workspace", "--copy-from-shared-store cannot be combined with --copy-to-workspace"],
      ["--keep-root-models", "--copy-from-shared-store cannot be combined with --keep-root-models"],
      ["--clean", "--copy-from-shared-store cannot be combined with --clean"]
    ].each do |conflicting_flag, expected_message|
      out, err, status = Open3.capture3(
        RbConfig.ruby,
        BIN,
        "--workers", "1",
        "--model", "qwen3.6:35b-a3b-q4_K_M",
        "--copy-from-shared-store", "/workspace-global/ollama-models",
        conflicting_flag
      )

      refute status.success?, out + err
      assert_equal 2, status.exitstatus
      assert_includes err, expected_message
    end
  end

  def test_copy_from_shared_store_requires_exactly_one_model_before_fleet_access
    out, err, status = Open3.capture3(
      RbConfig.ruby,
      BIN,
      "--workers", "1",
      "--model", "qwen3.6:35b-a3b-q4_K_M",
      "--model", "qwen3.6:27b-q4_K_M",
      "--copy-from-shared-store", "/workspace-global/ollama-models"
    )

    refute status.success?, out + err
    assert_equal 2, status.exitstatus
    assert_includes err, "--copy-from-shared-store requires exactly one --model"
  end

  def test_keep_root_models_requires_exactly_one_model_before_fleet_access
    out, err, status = Open3.capture3(
      RbConfig.ruby,
      BIN,
      "--workers", "1",
      "--model", "gemma4:26b",
      "--model", "qwen3.6:27b",
      "--keep-root-models"
    )

    refute status.success?, out + err
    assert_equal 2, status.exitstatus
    assert_includes err, "--keep-root-models requires exactly one --model"
  end

  def test_default_root_storage_requires_exactly_one_model_before_fleet_access
    out, err, status = Open3.capture3(
      RbConfig.ruby,
      BIN,
      "--workers", "1",
      "--model", "gemma4:26b",
      "--model", "qwen3.6:27b"
    )

    refute status.success?, out + err
    assert_equal 2, status.exitstatus
    assert_includes err, "fresh root-storage bootstrap requires exactly one --model"
  end
end
