# frozen_string_literal: true

require_relative "test_helper"
require_relative "../lib/runpod_ollama_fleet/campaign_runpod_runtime"

class CampaignRunpodRuntimeTest < Minitest::Test
  BLACKWELL = "NVIDIA RTX PRO 6000 Blackwell Server Edition"

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

  private

  def build_runtime(rows)
    RunpodOllamaFleet::CampaignRunpodRuntime.new(
      root: Dir.tmpdir,
      repo_root: File.expand_path("..", __dir__),
      profile: { "profile_id" => "gptoss" },
      hardware: {
        "qualified_gpu_ids" => ["NVIDIA A40", BLACKWELL],
        "cloud" => "SECURE",
        "global_volume_id" => "test-volume"
      },
      client: FakeClient.new(rows)
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
