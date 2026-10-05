# frozen_string_literal: true

require_relative "test_helper"
require_relative "../lib/runpod_ollama_fleet/campaign_runpod_runtime"

class CampaignRunpodRuntimeTest < Minitest::Test
  BLACKWELL = "NVIDIA RTX PRO 6000 Blackwell Server Edition"

  FakeReadiness = Struct.new(:document) do
    def readiness_status
      document
    end
  end

  class FakeClient
    def initialize(rows)
      @rows = rows
    end

    def list_gpu_types(cloud:, count:)
      raise "unexpected cloud" unless cloud == "SECURE"
      raise "unexpected count" unless count == 1

      @rows
    end
  end

  def test_selects_cheapest_currently_available_qualified_gpu
    runtime = build_runtime([
      gpu("NVIDIA A40", "HIGH", 0.49, 48),
      gpu(BLACKWELL, "MEDIUM", 2.09, 96)
    ])

    assert_equal(
      "NVIDIA A40",
      runtime.send(:qualified_gpu_id, max_hourly_rate_usd: 6.0, desired_workers: 1)
    )
  end

  def test_falls_back_to_blackwell_when_cheaper_qualified_gpu_is_unavailable
    runtime = build_runtime([
      gpu("NVIDIA A40", "NONE", 0.49, 48),
      gpu(BLACKWELL, "MEDIUM", 2.09, 96)
    ])

    assert_equal(
      BLACKWELL,
      runtime.send(:qualified_gpu_id, max_hourly_rate_usd: 6.0, desired_workers: 1)
    )
  end

  def test_provider_active_is_not_mislabeled_registry_ready
    readiness = {
      "status" => "available",
      "counts" => {
        "bootstrap_passed" => 1,
        "capability_evidence_valid" => 1,
        "tunnel_established" => 1,
        "READY" => 0,
        "NOT_READY" => 1,
        "UNAVAILABLE" => 0,
        "registry_unpublished" => 0
      }
    }
    runtime = build_runtime([], readiness_observer: FakeReadiness.new(readiness))
    runtime.define_singleton_method(:current_record) do
      {
        "fleet_id" => "fleet-1",
        "status" => "active",
        "workers" => [{ "status" => "active" }]
      }
    end

    status = runtime.status

    assert_equal 1, status.fetch("provider_active_workers")
    assert_equal 0, status.fetch("registry_ready_workers")
    assert_equal 1, status.fetch("registry_not_ready_workers")
    assert_equal "provider_active_workers", status.fetch("ready_workers_legacy_meaning")
    assert_equal 1, status.fetch("ready_workers")
  end

  def test_registry_observation_failure_is_explicit
    observer = Object.new
    observer.define_singleton_method(:readiness_status) do
      raise RunpodOllamaFleet::DynamicWorkerRegistry::Error, "readiness evidence is invalid"
    end
    runtime = build_runtime([], readiness_observer: observer)

    status = runtime.status

    assert_equal "unavailable", status.fetch("registry_status")
    assert_nil status.fetch("registry_ready_workers")
    assert_equal "readiness evidence is invalid", status.fetch("registry_error")
  end

  def test_automatic_bootstrap_receives_frozen_shared_model_binding
    captured = nil
    bootstrap = Object.new
    builder = lambda do |**keywords|
      captured = keywords
      bootstrap
    end
    runtime = build_runtime([])

    RunpodOllamaFleet::WorkerBringupAdapters::Bootstrap.stub(:new, builder) do
      runtime.send(:bringup_reconciler, -> { true })
    end

    refute_nil captured
    assert_equal "/workspace-global/ollama-models", captured.fetch(:shared_store_path)
    assert_equal "qwen3.6:35b-a3b-q4_K_M", captured.fetch(:shared_source_model)
  end

  private

  def build_runtime(rows, readiness_observer: nil)
    RunpodOllamaFleet::CampaignRunpodRuntime.new(
      root: Dir.tmpdir,
      repo_root: File.expand_path("..", __dir__),
      profile: { "profile_id" => "gptoss" },
      hardware: {
        "qualified_gpu_ids" => ["NVIDIA A40", BLACKWELL],
        "cloud" => "SECURE",
        "global_volume_id" => "test-volume",
        "ollama_store_path" => "/workspace-global/ollama-models",
        "shared_model" => "qwen3.6:35b-a3b-q4_K_M"
      },
      client: FakeClient.new(rows),
      readiness_observer:
    )
  end

  def gpu(id, availability, rate, memory)
    {
      "id" => id,
      "memory" => memory,
      "secure" => true,
      "availability" => availability,
      "price" => { "secure" => rate }
    }
  end
end
