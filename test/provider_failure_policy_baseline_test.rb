# frozen_string_literal: true

require_relative "test_helper"
require_relative "../lib/runpod_ollama_fleet/campaign_runpod_runtime"

# Frozen phase-A observations of the existing diagnostic-based policy. These
# synthetic messages exercise the classifiers without constructing a provider.
class ProviderFailurePolicyBaselineTest < Minitest::Test
  CAPACITY_ALLOW = [
    "RunPod catalog did not return NVIDIA A40",
    "NVIDIA A40 is not available on SECURE cloud",
    "NVIDIA A40 SECURE availability is NONE",
    "NVIDIA A40 SECURE availability is unknown",
    "RunPod API 409: capacity unavailable for requested hardware",
    "insufficient capacity",
    "burst-1 GPU mismatch: expected A40",
    "burst-1 cloud mismatch: expected SECURE",
    "burst-1 entered terminal status ERROR",
    "timed out waiting for RunPod SSH endpoints: burst-1",
    "RunPod readiness ended with only 0 contiguous ready worker(s)"
  ].freeze
  CAPACITY_DENY = [
    "provider result lost", "unknown provider failure", "ambiguous outcome",
    "pod pod-1 name mismatch", "identity mismatch", "permission denied",
    "NVIDIA A40 reports only 24 GB VRAM; 48 GB is required",
    "does not match exact capability request",
    "provider resource unavailable"
  ].freeze
  DENY_WORDS = [
    "budget", "deadline", "guardian", "binding", "campaign identity",
    "worker ceiling", "profile gptoss ceiling", "aggregate hourly",
    "cumulative", "safety cap", "fleet cost", "malformed", "corrupt"
  ].freeze

  # Records exact true/false decisions, including denial precedence when a
  # safety diagnostic also contains an availability phrase. Returns no value.
  def test_capacity_allow_deny_matrix
    runtime = RunpodOllamaFleet::CampaignRunpodRuntime.allocate
    CAPACITY_ALLOW.each do |message|
      assert runtime.send(:retryable_capacity_failure?, StandardError.new(message)), message
    end
    (CAPACITY_DENY + DENY_WORDS.map { |word| "capacity unavailable: #{word}" }).each do |message|
      refute runtime.send(:retryable_capacity_failure?, StandardError.new(message)), message
    end
  end

  # Records terminal-stage decisions and the original returned diagnostic;
  # unknown, ambiguous and identity-only messages do not qualify by themselves.
  def test_bringup_allow_deny_matrix
    runtime = RunpodOllamaFleet::CampaignRunpodRuntime.allocate
    allowed = [
      "capability evidence digest does not match exact capability request",
      "provider resource pod-1 unavailable", "provider resource terminated",
      "provider resource unusable", "provider resource missing"
    ]
    denied = ["provider result lost", "ambiguous outcome", "identity mismatch", "budget exceeded", "safety cap exceeded"]
    %w[tunnel bootstrap capability].each do |stage|
      allowed.each do |message|
        assert_equal message, runtime.send(:retryable_bringup_failure, [state(stage, message)]), stage
        assert_nil runtime.send(:retryable_bringup_failure, [state(stage, message, status: "failed_retryable")]), stage
      end
      denied.each do |message|
        assert_nil runtime.send(:retryable_bringup_failure, [state(stage, message)]), message
      end
    end
  end

  # Preserves surprising existing decisions for later explicit policy review.
  # Phase A must not silently add deny rules or interpret types as authority.
  def test_existing_bringup_identity_and_mixed_diagnostic_decisions
    runtime = RunpodOllamaFleet::CampaignRunpodRuntime.allocate
    [
      "capability evidence worker_id does not match exact capability request",
      "provider resource unavailable; budget binding corrupt",
      "provider resource unavailable; result ambiguous"
    ].each do |message|
      assert_equal message, runtime.send(:retryable_bringup_failure, [state("capability", message)])
    end
  end

  private

  # Builds one offline terminal-stage observation; takes stage/message strings
  # and an optional status, returning the existing three-stage document shape.
  def state(stage, message, status: "failed_terminal")
    %w[tunnel bootstrap capability].to_h do |name|
      [name, { "status" => name == stage ? status : "passed", "error" => name == stage ? message : nil }]
    end
  end
end
