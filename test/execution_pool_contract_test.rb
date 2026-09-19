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
      "budget" => {
        "contract_version" => "afio-production-burst-budget/v0.1",
        "budget_id" => "batch034",
        "plan_sha256" => "b" * 64,
        "max_cumulative_compute_usd" => 5.0,
        "max_runtime_seconds" => 2700,
        "guardian_poll_seconds" => 5,
        "orchestrator_heartbeat_timeout_seconds" => 30,
        "teardown_reserve_seconds" => 60
      },
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

  def test_rejects_legacy_v0_1_execution_pool_request
    document = request
    document["contract_version"] = "afio-rpof-execution-pool-fulfill-request/v0.1"

    error = assert_raises(RunpodOllamaFleet::ContractV01::Error) do
      RunpodOllamaFleet::ContractV01.validate_execution_pool_request!(document)
    end
    assert_includes error.message, "unsupported contract_version"
    assert_includes error.message, "v0.2"
  end

  def test_requires_parent_production_burst_budget
    document = request
    document.delete("budget")

    error = assert_raises(RunpodOllamaFleet::ContractV01::Error) do
      RunpodOllamaFleet::ContractV01.validate_execution_pool_request!(document)
    end
    assert_includes error.message, "missing required field(s): budget"
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

  def test_rejects_budget_identity_that_does_not_match_plan
    document = request
    document.fetch("budget")["plan_sha256"] = "c" * 64

    error = assert_raises(RunpodOllamaFleet::ContractV01::Error) do
      RunpodOllamaFleet::ContractV01.validate_execution_pool_request!(document)
    end
    assert_includes error.message, "must match request plan_sha256"
  end
end
