# frozen_string_literal: true

require_relative "test_helper"
require "digest"
require "time"
require "uri"
require_relative "../lib/runpod_ollama_fleet/dynamic_worker_registry"
require_relative "fixtures/dynamic-worker-registry-v0.1/conformance"

class DynamicWorkerRegistryContractTest < Minitest::Test
  FIXTURE_ROOT = File.expand_path("fixtures/dynamic-worker-registry-v0.1", __dir__)
  FIXTURE = File.join(FIXTURE_ROOT, "minimal-valid.json")
  INVALID_ROOT = File.join(FIXTURE_ROOT, "invalid")
  NOW = Time.iso8601("2030-01-01T00:01:00Z")

  def test_fixture_bytes_match_the_authoritative_contract
    manifest = File.readlines(File.join(FIXTURE_ROOT, "SHA256SUMS"), chomp: true)
    manifest_paths = manifest.to_h do |line|
      expected, relative = line.split(/\s+/, 2)
      [relative, expected]
    end
    copied_paths = Dir[File.join(FIXTURE_ROOT, "**", "*")].select { |path| File.file?(path) }
    copied_paths = copied_paths.reject { |path| path.end_with?("SHA256SUMS") }
    copied_paths.map! { |path| path.delete_prefix("#{FIXTURE_ROOT}/") }

    assert_equal copied_paths.sort, manifest_paths.keys.sort
    manifest_paths.each do |relative, expected|
      assert_equal expected, Digest::SHA256.file(File.join(FIXTURE_ROOT, relative)).hexdigest, relative
    end
  end

  def test_canonical_fixture_identity_publication_and_capabilities
    document = fixture
    assert_same document, DynamicWorkerRegistryV01::Conformance.validate_document!(document, now: NOW)
    worker = document.fetch("workers").first
    model = worker.dig("capabilities", "ollama", "models").first

    assert_equal %w[contract_version expires_at published_at registry_id revision workers],
                 document.keys.sort
    assert_equal "dynamic-worker-registry/v0.1", document.fetch("contract_version")
    assert_equal "rpof-fixture", document.fetch("registry_id")
    assert_equal 7, document.fetch("revision")
    assert_equal "2030-01-01T00:00:00Z", document.fetch("published_at")
    assert_equal "2030-01-01T00:05:00Z", document.fetch("expires_at")
    assert_equal %w[
      capabilities capability_fingerprint endpoint generation_id labels state worker_id
    ], worker.keys.sort
    assert_equal "worker-1", worker.fetch("worker_id")
    assert_equal "generation-2029-12-31T23:58:00Z", worker.fetch("generation_id")
    assert_equal "http://127.0.0.1:11441", worker.fetch("endpoint")
    assert_equal "READY", worker.fetch("state")
    assert_equal %w[inference ollama remote], worker.fetch("labels")
    assert_equal %w[gpu_id ollama], worker.fetch("capabilities").keys.sort
    assert_equal ["models"], worker.dig("capabilities", "ollama").keys
    assert_equal %w[context_length digest fully_gpu_resident model], model.keys.sort
    assert_equal "NVIDIA A40", worker.dig("capabilities", "gpu_id")
    assert_equal "qualified-model:latest", model.fetch("model")
    assert_equal "a" * 64, model.fetch("digest")
    assert_equal 131_072, model.fetch("context_length")
    assert model.fetch("fully_gpu_resident")
    assert_operator Time.iso8601(document.fetch("expires_at")), :>,
                    Time.iso8601(document.fetch("published_at"))
    assert_equal RunpodOllamaFleet::DynamicWorkerRegistry.capability_fingerprint(worker),
                 worker.fetch("capability_fingerprint")
  end

  def test_invalid_fixtures_fail_closed_for_the_intended_reason
    invalid_expectations.each do |relative, expected_message|
      error = assert_raises(DynamicWorkerRegistryV01::Conformance::Error, relative) do
        DynamicWorkerRegistryV01::Conformance.validate_bytes!(
          File.binread(File.join(FIXTURE_ROOT, relative)), now: NOW
        )
      end
      assert_includes error.message, expected_message
    end
  end

  def test_every_capability_change_invalidates_the_fingerprint
    mutations = {
      "labels" => ->(worker) { worker.fetch("labels") << "changed" },
      "gpu_id" => ->(worker) { worker.fetch("capabilities")["gpu_id"] = "changed" },
      "model" => ->(worker) { model_for(worker)["model"] = "changed" },
      "digest" => ->(worker) { model_for(worker)["digest"] = "b" * 64 },
      "context_length" => ->(worker) { model_for(worker)["context_length"] = 65_536 },
      "fully_gpu_resident" => ->(worker) { model_for(worker)["fully_gpu_resident"] = false }
    }

    mutations.each do |field, mutate|
      worker = deep_copy(fixture.fetch("workers").first)
      mutate.call(worker)
      refute_equal worker.fetch("capability_fingerprint"),
                   RunpodOllamaFleet::DynamicWorkerRegistry.capability_fingerprint(worker), field
    end
  end

  def test_missing_model_capability_fields_fail_closed
    %w[model digest context_length fully_gpu_resident].each do |field|
      worker = deep_copy(fixture.fetch("workers").first)
      model_for(worker).delete(field)

      assert_raises(KeyError) do
        RunpodOllamaFleet::DynamicWorkerRegistry.capability_fingerprint(worker)
      end
    end
  end

  def test_existing_rpof_capability_evidence_maps_without_provider_fields
    worker = fixture.fetch("workers").first
    existing_capability_result = {
      "gpu_id" => "NVIDIA A40",
      "models" => [{
        "name" => "qualified-model:latest",
        "digest" => "a" * 64,
        "context_length" => 131_072,
        "fully_gpu_resident" => true
      }]
    }
    expected_models = existing_capability_result.fetch("models").map do |model|
      {
        "model" => model.fetch("name"),
        "digest" => model.fetch("digest"),
        "context_length" => model.fetch("context_length"),
        "fully_gpu_resident" => model.fetch("fully_gpu_resident")
      }
    end

    assert_equal existing_capability_result.fetch("gpu_id"), worker.dig("capabilities", "gpu_id")
    assert_equal expected_models, worker.dig("capabilities", "ollama", "models")
    refute worker.key?("pod_id")
    refute worker.key?("fleet_id")
  end

  def test_binding_identity_detects_worker_generation_endpoint_and_fingerprint_changes
    registry = fixture
    worker = registry.fetch("workers").first

    %w[worker_id generation_id endpoint capability_fingerprint].each do |field|
      changed = worker.merge(field => "changed")
      refute_equal binding_identity(registry, worker), binding_identity(registry, changed), field
    end
  end

  private

  def invalid_expectations
    path = File.join(FIXTURE_ROOT, "INVALID_EXPECTATIONS.tsv")
    File.readlines(path, chomp: true).to_h { |line| line.split("\t", 2) }
  end

  def fixture
    JSON.parse(File.read(FIXTURE))
  end

  def deep_copy(value)
    JSON.parse(JSON.generate(value))
  end

  def model_for(worker)
    worker.dig("capabilities", "ollama", "models").first
  end

  def binding_identity(registry, worker)
    [registry.fetch("registry_id")] +
      %w[worker_id generation_id endpoint capability_fingerprint].map { |key| worker.fetch(key) }
  end
end
