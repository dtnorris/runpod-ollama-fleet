# frozen_string_literal: true

require_relative "test_helper"
require "digest"
require "time"
require "uri"
require_relative "../lib/runpod_ollama_fleet/dynamic_worker_registry"

class DynamicWorkerRegistryContractTest < Minitest::Test
  FIXTURE = File.expand_path("fixtures/dynamic-worker-registry-v0.1.json", __dir__)
  INVALID_ROOT = File.expand_path("fixtures/dynamic-worker-registry-v0.1-invalid", __dir__)
  AUTHORITATIVE_SHA256 = {
    "fixtures/dynamic-worker-registry-v0.1.json" =>
      "58c8f7e79b61bb454948ee045a6f7df89453a7805b54ed438df8d8b8dcb2ba26",
    "fixtures/dynamic-worker-registry-v0.1-invalid/bad-contract-version.json" =>
      "2d2d1de94283ac2694b717b5a21817c4be02292296321660d4616fadf1630f45",
    "fixtures/dynamic-worker-registry-v0.1-invalid/bad-endpoint.json" =>
      "06c53db11ff489ba30f49fa24d444aadd82c5b64f4fffb4ec092b9c7b000f4bd",
    "fixtures/dynamic-worker-registry-v0.1-invalid/bad-fingerprint.json" =>
      "7d9afb6834594fbc85dab591a09ed4bca82735e6856c0060fdc732dcdeedf417",
    "fixtures/dynamic-worker-registry-v0.1-invalid/bad-publication-window.json" =>
      "833b303395e8cd46329d40ac63c52922ded9239f9d352a7c392efdbb98e59b1c",
    "fixtures/dynamic-worker-registry-v0.1-invalid/bad-state.json" =>
      "e90a4ed6e4907595479c231467a723aee4e35c7d872a6fbe507f03c7ea2a6127",
    "fixtures/dynamic-worker-registry-v0.1-invalid/duplicate-worker-id.json" =>
      "fb334f5f996a0e6f16bb4880303b027443cfa16ce9f9f1693e96aced65816dbb",
    "fixtures/dynamic-worker-registry-v0.1-invalid/missing-generation.json" =>
      "c0d0b86037813f05e08df80789d00152d0e086d9fd403aca9b200ab789aa8ddf"
  }.freeze

  def test_fixture_bytes_match_the_authoritative_contract
    actual_paths = [FIXTURE] + Dir[File.join(INVALID_ROOT, "*.json")]
    expected_paths = AUTHORITATIVE_SHA256.keys.map { |path| File.expand_path(path, __dir__) }

    assert_equal expected_paths.sort, actual_paths.sort
    AUTHORITATIVE_SHA256.each do |path, expected_hash|
      assert_equal expected_hash, Digest::SHA256.file(File.expand_path(path, __dir__)).hexdigest
    end
  end

  def test_canonical_fixture_identity_publication_and_capabilities
    document = fixture
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

  def test_invalid_fixtures_cover_required_fail_closed_cases
    version = invalid_fixture("bad-contract-version.json")
    missing = invalid_fixture("missing-generation.json").fetch("workers").first
    endpoint = URI.parse(invalid_fixture("bad-endpoint.json").dig("workers", 0, "endpoint"))
    bad_fingerprint = invalid_fixture("bad-fingerprint.json").fetch("workers").first
    publication = invalid_fixture("bad-publication-window.json")
    state = invalid_fixture("bad-state.json").dig("workers", 0, "state")
    duplicate_ids = invalid_fixture("duplicate-worker-id.json").fetch("workers").map do |worker|
      worker.fetch("worker_id")
    end

    refute_equal "dynamic-worker-registry/v0.1", version.fetch("contract_version")
    refute missing.key?("generation_id")
    refute_nil endpoint.userinfo
    refute_nil endpoint.query
    refute_equal RunpodOllamaFleet::DynamicWorkerRegistry.capability_fingerprint(bad_fingerprint),
                 bad_fingerprint.fetch("capability_fingerprint")
    refute_operator Time.iso8601(publication.fetch("expires_at")), :>,
                    Time.iso8601(publication.fetch("published_at"))
    refute_includes %w[READY NOT_READY UNAVAILABLE], state
    refute_equal duplicate_ids.uniq, duplicate_ids
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

  def fixture
    JSON.parse(File.read(FIXTURE))
  end

  def invalid_fixture(name)
    JSON.parse(File.read(File.join(INVALID_ROOT, name)))
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
