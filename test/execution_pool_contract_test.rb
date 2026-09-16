# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/runpod_ollama_fleet/contract_v0_1"

class ExecutionPoolContractTest < Minitest::Test
  DIGEST = "a" * 64

  def request
    {
      "contract_version" => RunpodOllamaFleet::ContractV01::EXECUTION_POOL_REQUEST_VERSION,
      "plan_sha256" => "b" * 64,
      "pool_id" => "qwen35",
      "requirements" => {
        "ollama_model" => "qwen3.6:35b-a3b",
        "pull_model" => "qwen3.6:35b-a3b-q4_K_M",
        "expected_digest" => DIGEST,
        "required_context_length" => 131_072,
        "require_fully_gpu_resident" => true
      },
      "capacity" => {
        "desired_workers" => 4,
        "minimum_workers" => 2,
        "max_pool_hourly_usd" => 3.0,
        "max_total_hourly_usd" => 6.0
      }
    }
  end

  def test_accepts_provider_agnostic_execution_pool_request
    document = request
    assert_same document, RunpodOllamaFleet::ContractV01.validate_execution_pool_request!(document)
  end

  def test_rejects_hardware_fields_from_afio_request
    document = request
    document.fetch("capacity")["gpu_ids"] = ["NVIDIA A40"]

    error = assert_raises(RunpodOllamaFleet::ContractV01::Error) do
      RunpodOllamaFleet::ContractV01.validate_execution_pool_request!(document)
    end
    assert_includes error.message, "unknown field"
  end

  def test_rejects_minimum_above_desired
    document = request
    document.fetch("capacity")["minimum_workers"] = 5

    error = assert_raises(RunpodOllamaFleet::ContractV01::Error) do
      RunpodOllamaFleet::ContractV01.validate_execution_pool_request!(document)
    end
    assert_includes error.message, "cannot exceed"
  end
end
