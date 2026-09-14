# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/runpod_ollama_fleet/contract_v0_1"

class RpofContractV01Test < Minitest::Test
  def test_capability_request_accepts_worker_indices_above_sixteen
    request = {
      "contract_version" => "afio-rpof-capability-check-request/v0.1",
      "fleet_key" => "fixture",
      "worker_selector" => { "mode" => "indices", "indices" => [1, 32] },
      "requirements" => {
        "models" => [{ "name" => "fixture-model" }],
        "required_context_length" => 32_768,
        "require_fully_gpu_resident" => true
      }
    }
    assert_same request, RunpodOllamaFleet::ContractV01.validate_capability_request!(request)
  end

  def test_unknown_contract_version_fails_closed
    request = {
      "contract_version" => "afio-rpof-capability-check-request/v9",
      "fleet_key" => "fixture",
      "worker_selector" => { "mode" => "all" },
      "requirements" => {
        "models" => [{ "name" => "fixture-model" }],
        "required_context_length" => 32_768,
        "require_fully_gpu_resident" => true
      }
    }
    assert_raises(RunpodOllamaFleet::ContractV01::Error) do
      RunpodOllamaFleet::ContractV01.validate_capability_request!(request)
    end
  end

  def test_dispatch_rejects_extra_fields_and_duplicate_job_ids
    request = {
      "contract_version" => "afio-rpof-dispatch-request/v0.1",
      "target" => { "fleet_key" => "fixture", "expected_fleet_id" => "opaque", "worker_indices" => [1] },
      "group_by_affinity" => false,
      "jobs" => [
        { "job_id" => "same", "argv" => ["true"] },
        { "job_id" => "same", "argv" => ["true"] }
      ]
    }
    assert_raises(RunpodOllamaFleet::ContractV01::Error) do
      RunpodOllamaFleet::ContractV01.validate_dispatch_request!(request)
    end
    request["jobs"] = [{ "job_id" => "one", "argv" => ["true"], "extra" => true }]
    assert_raises(RunpodOllamaFleet::ContractV01::Error) do
      RunpodOllamaFleet::ContractV01.validate_dispatch_request!(request)
    end
  end
end
