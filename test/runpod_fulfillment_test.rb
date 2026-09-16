# frozen_string_literal: true

require "minitest/autorun"
require "stringio"
require_relative "../lib/local_model_evaluation/runpod_fulfillment"

class RunpodFulfillmentTest < Minitest::Test
  class FakePolicy
    attr_reader :calls

    def initialize(rankings)
      @rankings = rankings
      @calls = []
    end

    def rank(gpu_ids:, cloud:, max_hourly_per_worker_usd:)
      @calls << [gpu_ids, cloud, max_hourly_per_worker_usd]
      value = @rankings.shift || @rankings.last
      value.call if value.respond_to?(:call)
      value
    end
  end

  def test_refreshes_capacity_after_each_success_and_falls_back_to_next_qualified_gpu
    a40 = candidate("NVIDIA A40", 0.49)
    a6000 = candidate("NVIDIA RTX A6000", 0.53)
    policy = FakePolicy.new([
      ranking(a40, a6000),
      ranking(a40, a6000)
    ])
    fulfillment = LocalModelEvaluation::RunpodFulfillment.new(
      capacity_policy: policy,
      out: StringIO.new
    )
    count = 0
    attempts = []

    result = fulfillment.run(
      target_workers: 2,
      minimum_workers: 1,
      gpu_ids: [a40.gpu_id, a6000.gpu_id],
      cloud: "SECURE",
      current_workers: 0,
      max_hourly_per_worker_usd: 0.60
    ) do |selected|
      attempts << selected.gpu_id
      if count.zero? && selected.gpu_id == "NVIDIA A40"
        raise LocalModelEvaluation::RunpodFulfillment::CandidateUnavailable, "capacity disappeared"
      end
      count += 1
    end

    assert_equal "fulfilled", result.status
    assert_equal 2, result.final_workers
    assert_equal ["NVIDIA A40", "NVIDIA RTX A6000", "NVIDIA A40"], attempts
    assert_equal 2, policy.calls.length
    assert_equal %w[unavailable provisioned provisioned], result.attempts.map(&:status)
  end

  def test_retains_minimum_useful_capacity_when_no_candidate_can_fill_target
    a40 = candidate("NVIDIA A40", 0.49)
    policy = FakePolicy.new([
      ranking(a40),
      LocalModelEvaluation::RunpodCapacityPolicy::Ranking.new(
        cloud: "SECURE",
        candidates: [],
        rejections: []
      )
    ])
    fulfillment = LocalModelEvaluation::RunpodFulfillment.new(
      capacity_policy: policy,
      out: StringIO.new
    )
    count = 0

    result = fulfillment.run(
      target_workers: 3,
      minimum_workers: 1,
      gpu_ids: [a40.gpu_id],
      cloud: "SECURE",
      current_workers: 0,
      max_hourly_per_worker_usd: 0.60
    ) do |_selected|
      count += 1
    end

    assert_equal "minimum_met", result.status
    assert_equal 1, result.final_workers
    assert_includes result.stopped_reason, "no qualified GPU"
  end

  def test_returns_unfulfilled_when_minimum_useful_capacity_is_not_reached
    policy = FakePolicy.new([
      LocalModelEvaluation::RunpodCapacityPolicy::Ranking.new(
        cloud: "SECURE",
        candidates: [],
        rejections: []
      )
    ])
    fulfillment = LocalModelEvaluation::RunpodFulfillment.new(
      capacity_policy: policy,
      out: StringIO.new
    )

    result = fulfillment.run(
      target_workers: 2,
      minimum_workers: 1,
      gpu_ids: ["NVIDIA A40"],
      cloud: "SECURE",
      current_workers: 0,
      max_hourly_per_worker_usd: 0.60
    ) { flunk "should not provision" }

    assert_equal "unfulfilled", result.status
    assert_equal 0, result.final_workers
  end

  def test_dry_run_never_invokes_provision_callback
    a40 = candidate("NVIDIA A40", 0.49)
    policy = FakePolicy.new([ranking(a40)])
    fulfillment = LocalModelEvaluation::RunpodFulfillment.new(
      capacity_policy: policy,
      out: StringIO.new
    )

    result = fulfillment.run(
      target_workers: 4,
      minimum_workers: 1,
      gpu_ids: [a40.gpu_id],
      cloud: "SECURE",
      current_workers: 0,
      max_hourly_per_worker_usd: 0.60,
      dry_run: true
    )

    assert_equal "planned", result.status
    assert_empty result.attempts
  end

  private

  def candidate(gpu_id, rate)
    LocalModelEvaluation::RunpodCapacityPolicy::Candidate.new(
      gpu_id:,
      memory_gb: 48,
      availability: "HIGH",
      hourly_rate_usd: rate,
      catalog: {}
    )
  end

  def ranking(*candidates)
    LocalModelEvaluation::RunpodCapacityPolicy::Ranking.new(
      cloud: "SECURE",
      candidates:,
      rejections: []
    )
  end
end
