# frozen_string_literal: true

require_relative "test_helper"
require_relative "../lib/local_model_evaluation/runpod_bootstrap_options"
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
    assert_invalid("--clean cannot be combined with --reuse-existing", clean: true, reuse_existing: true)
  end

  def test_copy_to_workspace_and_reuse_existing_fail_before_fleet_access
    assert_invalid(
      "--copy-to-workspace cannot be combined with --reuse-existing",
      copy_to_workspace: true,
      reuse_existing: true
    )
  end

  def test_keep_root_models_and_reuse_existing_fail_before_fleet_access
    assert_invalid(
      "--keep-root-models cannot be combined with --reuse-existing",
      keep_root_models: true,
      reuse_existing: true
    )
  end

  def test_copy_from_shared_store_requires_absolute_path_before_fleet_access
    assert_invalid(
      "--copy-from-shared-store must be an absolute remote path",
      copy_from_shared_store: "workspace-global/ollama-models"
    )
  end

  def test_copy_from_shared_store_rejects_pull_or_mutating_storage_modes_before_fleet_access
    [
      [{ reuse_existing: true }, "--copy-from-shared-store cannot be combined with --reuse-existing"],
      [{ copy_to_workspace: true }, "--copy-from-shared-store cannot be combined with --copy-to-workspace"],
      [{ keep_root_models: true }, "--copy-from-shared-store cannot be combined with --keep-root-models"],
      [{ clean: true }, "--copy-from-shared-store cannot be combined with --clean"]
    ].each do |overrides, expected_message|
      assert_invalid(
        expected_message,
        **overrides,
        copy_from_shared_store: "/workspace-global/ollama-models"
      )
    end
  end

  def test_copy_from_shared_store_requires_exactly_one_model_before_fleet_access
    assert_invalid(
      "--copy-from-shared-store requires exactly one --model",
      models: ["qwen3.6:35b-a3b-q4_K_M", "qwen3.6:27b-q4_K_M"],
      copy_from_shared_store: "/workspace-global/ollama-models"
    )
  end

  def test_keep_root_models_requires_exactly_one_model_before_fleet_access
    assert_invalid(
      "--keep-root-models requires exactly one --model",
      models: ["gemma4:26b", "qwen3.6:27b"],
      keep_root_models: true
    )
  end

  def test_default_root_storage_requires_exactly_one_model_before_fleet_access
    assert_invalid(
      "fresh root-storage bootstrap requires exactly one --model",
      models: ["gemma4:26b", "qwen3.6:27b"]
    )
  end

  private

  def valid_options
    {
      workers: [1],
      models: ["gemma4:26b"],
      pull_timeout_seconds: 360,
      clean: false,
      reuse_existing: false,
      copy_to_workspace: false,
      copy_from_shared_store: nil,
      keep_root_models: false
    }
  end

  def assert_invalid(expected_message, **overrides)
    error = assert_raises(OptionParser::ParseError) do
      LocalModelEvaluation::RunpodBootstrapOptions.validate!(
        valid_options.merge(overrides),
        []
      )
    end
    assert_includes error.message, expected_message
  end
end
