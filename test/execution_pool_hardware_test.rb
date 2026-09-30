# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require_relative "../lib/runpod_ollama_fleet/execution_pool_hardware"

class ExecutionPoolHardwareTest < Minitest::Test
  def test_production_registry_qualifies_blackwell_for_qwen35
    path = File.expand_path("../config/execution_pool_hardware.yml", __dir__)

    profile = RunpodOllamaFleet::ExecutionPoolHardware.new(path:).profile_for("qwen3.6:35b-a3b")

    assert_includes profile.gpu_ids, "NVIDIA A40"
    assert_includes profile.gpu_ids, "NVIDIA RTX PRO 6000 Blackwell Server Edition"
    assert_equal "qwen3.6:35b-a3b-q4_K_M", profile.shared_model
    assert_equal "SECURE", profile.cloud
  end

  def test_production_registry_has_blackwell_fallback_for_all_four_models
    path = File.expand_path("../config/execution_pool_hardware.yml", __dir__)
    hardware = RunpodOllamaFleet::ExecutionPoolHardware.new(path:)
    blackwell = "NVIDIA RTX PRO 6000 Blackwell Server Edition"

    [
      "qwen3.6:35b-a3b",
      "qwen3.6:27b",
      "gemma4:26b",
      "gpt-oss:20b"
    ].each do |model|
      assert_includes hardware.profile_for(model).gpu_ids, blackwell, model
    end
  end

  def test_resolves_only_explicit_rpof_owned_qualification
    Dir.mktmpdir do |root|
      path = File.join(root, "hardware.yml")
      File.write(path, <<~YAML)
        ---
        contract_version: rpof-execution-pool-hardware/v0.1
        default_cloud: SECURE
        global_volume:
          id: global-123
          ollama_store_path: /workspace-global/ollama-models
        models:
          qwen3.6:35b-a3b:
            shared_model: qwen3.6:35b-a3b-q4_K_M
            qualified_gpus:
              - NVIDIA A40
              - NVIDIA RTX A6000
      YAML
      profile = RunpodOllamaFleet::ExecutionPoolHardware.new(path:).profile_for("qwen3.6:35b-a3b")
      assert_equal "SECURE", profile.cloud
      assert_equal ["NVIDIA A40", "NVIDIA RTX A6000"], profile.gpu_ids
      assert_equal "qwen3.6:35b-a3b-q4_K_M", profile.shared_model
      assert_equal "global-123", profile.global_volume_id
      assert_equal "/workspace-global/ollama-models", profile.ollama_store_path

      assert_raises(RunpodOllamaFleet::ExecutionPoolHardware::Error) do
        RunpodOllamaFleet::ExecutionPoolHardware.new(path:).profile_for("unknown-model")
      end
    end
  end

  def test_reuses_the_validated_document_for_multiple_profile_lookups
    Dir.mktmpdir do |root|
      source = File.expand_path("../config/execution_pool_hardware.yml", __dir__)
      path = File.join(root, "hardware.yml")
      File.binwrite(path, File.binread(source))
      hardware = RunpodOllamaFleet::ExecutionPoolHardware.new(path:)

      first = hardware.profile_for("qwen3.6:35b-a3b")
      File.binwrite(path, "invalid: [")
      second = hardware.profile_for("qwen3.6:27b")

      assert_equal "qwen3.6:35b-a3b-q4_K_M", first.shared_model
      assert_equal "qwen3.6:27b-q4_K_M", second.shared_model
    end
  end
end
