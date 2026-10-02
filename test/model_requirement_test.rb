# frozen_string_literal: true

require_relative "test_helper"
require "runpod_ollama_fleet/model_requirement"
require "runpod_ollama_fleet/campaign_runpod_runtime"

class ModelRequirementTest < Minitest::Test
  DIGEST = "a" * 64

  class Provider
    attr_reader :calls
    def initialize = @calls = []
    def available_gpus(**) = @calls << :available_gpus
  end

  def test_exact_preflight_object_is_accepted
    requirement = RunpodOllamaFleet::ModelRequirement.new(document)
    assert_equal profile, requirement.validate_profile!(profile:, hardware:)
  end

  def test_exact_runtime_requirement_is_accepted_without_provider_access
    provider = Provider.new
    runtime = RunpodOllamaFleet::CampaignRunpodRuntime.new(
      root: Dir.tmpdir, repo_root: File.expand_path("..", __dir__), profile:, hardware:,
      client: provider, model_requirement: RunpodOllamaFleet::ModelRequirement.new(document)
    )

    assert_instance_of RunpodOllamaFleet::CampaignRunpodRuntime, runtime
    assert_empty provider.calls
  end

  def test_model_digest_context_and_residency_mismatches_fail_before_provider_access
    mutations = {
      "model" => ->(row) { row["model"] = "wrong:model" },
      "expected_digest" => ->(row) { row["expected_digest"] = "b" * 64 },
      "required_context_length" => ->(row) { row["required_context_length"] = 65_536 },
      "require_fully_gpu_resident" => ->(row) { row["require_fully_gpu_resident"] = false }
    }

    mutations.each do |field, mutation|
      provider = Provider.new
      changed = profile
      mutation.call(changed)
      error = assert_raises(RunpodOllamaFleet::ModelRequirement::Error, field) do
        RunpodOllamaFleet::CampaignRunpodRuntime.new(
          root: Dir.tmpdir, repo_root: File.expand_path("..", __dir__), profile: changed,
          hardware:, client: provider, model_requirement: RunpodOllamaFleet::ModelRequirement.new(document)
        )
      end
      assert_includes error.message, "mismatch", field
      assert_empty provider.calls, field
    end
  end

  def test_gpu_constraint_mismatch_fails_before_provider_access
    provider = Provider.new
    changed = hardware.merge("qualified_gpu_ids" => ["NVIDIA RTX 4090"])

    error = assert_raises(RunpodOllamaFleet::ModelRequirement::Error) do
      RunpodOllamaFleet::CampaignRunpodRuntime.new(
        root: Dir.tmpdir, repo_root: File.expand_path("..", __dir__), profile:, hardware: changed,
        client: provider, model_requirement: RunpodOllamaFleet::ModelRequirement.new(document)
      )
    end

    assert_includes error.message, "required GPU identity mismatch"
    assert_empty provider.calls
  end

  def test_alias_is_retained_only_as_provenance_not_reinterpreted
    changed = document.merge("alias" => "whatever-the-operator-typed")
    requirement = RunpodOllamaFleet::ModelRequirement.new(changed)

    assert_equal profile, requirement.validate_profile!(profile:, hardware:)
    assert_equal "whatever-the-operator-typed", requirement.document.fetch("alias")
  end

  private

  def document
    {
      "contract_version" => "adventurefinder-model-requirement/v0.1",
      "batch_handle" => "39",
      "production_batch_id" => "production-batch-039",
      "plan_id" => "production-batch-039",
      "plan_sha256" => "c" * 64,
      "alias" => "qwen27",
      "pool_id" => "qwen27",
      "required_labels" => ["inference"],
      "ollama" => {
        "model" => "qwen3.6:27b",
        "expected_digest" => DIGEST,
        "required_context_length" => 131_072,
        "require_fully_gpu_resident" => true,
        "required_gpu_id" => "NVIDIA A40"
      }
    }
  end

  def profile
    {
      "profile_id" => "qwen27-a40",
      "model" => "qwen3.6:27b",
      "expected_digest" => DIGEST,
      "required_context_length" => 131_072,
      "require_fully_gpu_resident" => true,
      "min_workers" => 1,
      "desired_workers" => 1,
      "max_workers" => 1
    }
  end

  def hardware
    {
      "cloud" => "SECURE",
      "qualified_gpu_ids" => ["NVIDIA A40", "NVIDIA RTX A6000"],
      "global_volume_id" => "volume-fixture"
    }
  end
end
