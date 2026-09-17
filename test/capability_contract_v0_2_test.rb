# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/runpod_ollama_fleet/contract_v0_1"

class CapabilityContractV02Test < Minitest::Test
  DIGEST = "a" * 64

  def base(version:, model:)
    {
      "contract_version" => version,
      "fleet_key" => "fixture",
      "worker_selector" => { "mode" => "indices", "indices" => [1] },
      "requirements" => {
        "models" => [model],
        "required_context_length" => 131_072,
        "require_fully_gpu_resident" => true
      }
    }
  end

  def test_v0_1_remains_backward_compatible_without_digest
    document = base(
      version: RunpodOllamaFleet::ContractV01::CAPABILITY_REQUEST_VERSION,
      model: { "name" => "runtime:model" }
    )
    assert_same document, RunpodOllamaFleet::ContractV01.validate_capability_request!(document)
  end

  def test_v0_2_requires_exact_digest
    document = base(
      version: RunpodOllamaFleet::ContractV01::CAPABILITY_REQUEST_V2_VERSION,
      model: { "name" => "runtime:model" }
    )
    error = assert_raises(RunpodOllamaFleet::ContractV01::Error) do
      RunpodOllamaFleet::ContractV01.validate_capability_request!(document)
    end
    assert_includes error.message, "expected_digest"
  end

  def test_v0_2_accepts_exact_runtime_identity
    document = base(
      version: RunpodOllamaFleet::ContractV01::CAPABILITY_REQUEST_V2_VERSION,
      model: { "name" => "runtime:model", "expected_digest" => DIGEST }
    )
    assert_same document, RunpodOllamaFleet::ContractV01.validate_capability_request!(document)
  end
end
