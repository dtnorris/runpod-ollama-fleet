# frozen_string_literal: true

require_relative "test_helper"
require "runpod_ollama_fleet/ollama_capability_request"

class OllamaCapabilityRequestTest < Minitest::Test
  FINGERPRINT = "9121fe00d663bad2e5bd6f2ff4d6b492e66ba71b0843585c547321172dce5ae4"

  def test_accepts_the_normative_shape_and_matches_wlo_fingerprint
    request = build_request(document)

    assert_equal "qualified-model:latest", request.ollama.fetch("model")
    assert_equal "NVIDIA A40", request.required_gpu_id
    assert_equal FINGERPRINT, request.fingerprint
    assert_equal profile, request.validate_profile!(profile:, hardware:)
  end

  def test_fingerprint_is_independent_of_wire_key_order
    reordered = {
      "ollama" => document.fetch("ollama").to_a.reverse.to_h,
      "contract_version" => RunpodOllamaFleet::OllamaCapabilityRequest::CONTRACT_VERSION
    }

    assert_equal build_request(document).fingerprint, build_request(reordered).fingerprint
  end

  def test_rejects_legacy_adventurefinder_input
    legacy = {
      "contract_version" => "adventurefinder-model-requirement/v0.1",
      "batch_handle" => "39",
      "ollama" => document.fetch("ollama")
    }

    error = assert_raises(RunpodOllamaFleet::OllamaCapabilityRequest::Error) do
      build_request(legacy)
    end
    assert_includes error.message, "unknown fields"
  end

  def test_rejects_authority_and_provenance_fields
    %w[
      workload batch alias pool plan provenance provider fleet pod campaign
      budget deadline lease authority worker generation endpoint
    ].each do |field|
      error = assert_raises(RunpodOllamaFleet::OllamaCapabilityRequest::Error, field) do
        build_request(document.merge(field => "forbidden"))
      end
      assert_includes error.message, "unknown fields", field
    end
  end

  def test_rejects_unknown_nested_fields_and_duplicate_keys
    nested = document.merge("ollama" => document.fetch("ollama").merge("alias" => "qwen"))
    error = assert_raises(RunpodOllamaFleet::OllamaCapabilityRequest::Error) { build_request(nested) }
    assert_includes error.message, "unknown fields"

    duplicate = <<~JSON
      {"contract_version":"ollama-capability-request/v0.1",
       "contract_version":"ollama-capability-request/v0.1","ollama":{}}
    JSON
    error = assert_raises(RunpodOllamaFleet::OllamaCapabilityRequest::Error) do
      RunpodOllamaFleet::OllamaCapabilityRequest.new(duplicate)
    end
    assert_includes error.message, "duplicate"
  end

  def test_rejects_malformed_runtime_fields
    mutations = {
      "model" => "",
      "expected_digest" => "A" * 64,
      "required_context_length" => 0,
      "require_fully_gpu_resident" => "true",
      "required_gpu_id" => " NVIDIA A40"
    }
    mutations.each do |field, value|
      changed = document.merge("ollama" => document.fetch("ollama").merge(field => value))
      assert_raises(RunpodOllamaFleet::OllamaCapabilityRequest::Error, field) do
        build_request(changed)
      end
    end
  end

  private

  def build_request(value)
    RunpodOllamaFleet::OllamaCapabilityRequest.new(JSON.generate(value))
  end

  def document
    {
      "contract_version" => "ollama-capability-request/v0.1",
      "ollama" => {
        "model" => "qualified-model:latest",
        "expected_digest" => "a" * 64,
        "required_context_length" => 131_072,
        "require_fully_gpu_resident" => true,
        "required_gpu_id" => "NVIDIA A40"
      }
    }
  end

  def profile
    {
      "profile_id" => "profile-1",
      "model" => "qualified-model:latest",
      "expected_digest" => "a" * 64,
      "required_context_length" => 131_072,
      "require_fully_gpu_resident" => true
    }
  end

  def hardware
    { "qualified_gpu_ids" => ["NVIDIA A40"] }
  end
end
