# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require_relative "../lib/runpod_ollama_fleet/execution_pool_hardware"

class ExecutionPoolHardwareTest < Minitest::Test
  def test_resolves_only_explicit_rpof_owned_qualification
    Dir.mktmpdir do |root|
      path = File.join(root, "hardware.yml")
      File.write(path, <<~YAML)
        ---
        contract_version: rpof-execution-pool-hardware/v0.1
        default_cloud: SECURE
        models:
          qwen3.6:35b-a3b:
            qualified_gpus:
              - NVIDIA A40
              - NVIDIA RTX A6000
      YAML
      profile = RunpodOllamaFleet::ExecutionPoolHardware.new(path:).profile_for("qwen3.6:35b-a3b")
      assert_equal "SECURE", profile.cloud
      assert_equal ["NVIDIA A40", "NVIDIA RTX A6000"], profile.gpu_ids

      assert_raises(RunpodOllamaFleet::ExecutionPoolHardware::Error) do
        RunpodOllamaFleet::ExecutionPoolHardware.new(path:).profile_for("unknown-model")
      end
    end
  end
end
