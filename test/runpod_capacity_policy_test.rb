# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/local_model_evaluation/runpod_capacity_policy"

class RunpodCapacityPolicyTest < Minitest::Test
  class FakeClient
    attr_reader :calls

    def initialize(rows)
      @rows = rows
      @calls = []
    end

    def list_gpu_types(cloud:, count:)
      @calls << [cloud, count]
      @rows
    end
  end

  def test_ranks_only_qualified_currently_available_profiles_cheapest_first
    client = FakeClient.new([
      gpu("NVIDIA L40S", 48, 0.69),
      gpu("NVIDIA RTX A6000", 48, 0.53),
      gpu("NVIDIA A40", 48, 0.49),
      gpu("NVIDIA L4", 24, 0.39),
      gpu("NVIDIA RTX 6000 Ada", 48, 0.55, availability: "NONE")
    ])
    policy = LocalModelEvaluation::RunpodCapacityPolicy.new(client:)

    ranking = policy.rank(
      gpu_ids: ["NVIDIA L40S", "NVIDIA RTX A6000", "NVIDIA A40", "NVIDIA L4", "NVIDIA RTX 6000 Ada"],
      cloud: "SECURE",
      max_hourly_per_worker_usd: 0.60
    )

    assert_equal [["SECURE", 1]], client.calls
    assert_equal ["NVIDIA A40", "NVIDIA RTX A6000"], ranking.candidates.map(&:gpu_id)
    assert_equal [0.49, 0.53], ranking.candidates.map(&:hourly_rate_usd)
    rejections = ranking.rejections.to_h { |row| [row.gpu_id, row.reason] }
    assert_includes rejections.fetch("NVIDIA L40S"), "exceeds per-worker cap"
    assert_includes rejections.fetch("NVIDIA L4"), "below required 48 GB"
    assert_includes rejections.fetch("NVIDIA RTX 6000 Ada"), "availability is NONE"
  end

  def test_reports_missing_qualified_gpu_without_substituting_unapproved_hardware
    client = FakeClient.new([gpu("NVIDIA H100 PCIe", 80, 1.99)])
    policy = LocalModelEvaluation::RunpodCapacityPolicy.new(client:)

    ranking = policy.rank(gpu_ids: ["NVIDIA A40"], cloud: "SECURE")

    assert_empty ranking.candidates
    assert_equal ["NVIDIA A40"], ranking.rejections.map(&:gpu_id)
    assert_includes ranking.rejections.first.reason, "catalog did not return"
  end

  private

  def gpu(id, memory, rate, availability: "HIGH")
    {
      "id" => id,
      "memory" => memory,
      "secure" => true,
      "availability" => availability,
      "price" => { "secure" => rate }
    }
  end
end
