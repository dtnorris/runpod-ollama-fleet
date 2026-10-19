# frozen_string_literal: true

require_relative "test_helper"
require "stringio"
require_relative "../lib/runpod_ollama_fleet/campaign_runpod_runtime"

# Exercises source-selected provider outcomes with fake catalog data only.
class ProviderOutcomeTest < Minitest::Test
  Outcome = RunpodOllamaFleet::ProviderOutcome

  # Supplies synthetic inventory and counts forbidden provisioning attempts.
  class Client
    attr_accessor :catalog
    attr_reader :creates

    # Takes catalog rows; initializes an offline client with no resources.
    def initialize(catalog)
      @catalog = catalog
      @creates = 0
    end

    # Returns no existing resources; accepts no inputs and performs no I/O.
    def list_pods = []

    # Returns the supplied rows for any requested cloud/count, without I/O.
    def list_gpu_types(cloud:, count:) = catalog

    # Counts and rejects any creation request; no provider is reachable.
    def create_pod(_body)
      @creates += 1
      raise "unexpected fixture provisioning"
    end
  end

  # Proves the vocabulary is closed and codes do not depend on diagnostic text.
  def test_codes_are_explicit_and_unknown_inputs_supply_no_typed_classification
    Outcome::CODES.each do |code|
      error = Outcome::Failure.new("arbitrary diagnostic", outcome_code: code)
      assert_equal code, Outcome.code_for(error)
      assert_equal "arbitrary diagnostic", error.message
    end
    [nil, "capacity unavailable", StandardError.new("capacity unavailable; outcome ambiguous")].each do |input|
      assert_equal :unknown, Outcome.code_for(input)
    end
    assert_equal :unknown, Outcome.code_for(Outcome::Failure.new("budget exceeded"))
    assert_raises(ArgumentError) { Outcome::Failure.new("capacity unavailable", outcome_code: :invented) }
    assert_raises(ArgumentError) { Outcome::Failure.new("capacity unavailable", outcome_code: "capacity_unavailable") }
  end

  # Exercises both actual capacity adapters, retaining their original diagnostics
  # and legacy classification; no provisioning or real provider call occurs.
  def test_catalog_failures_carry_the_same_outcome_in_create_and_scale_adapters
    rows = [[], [gpu.merge("secure" => false)], [gpu.merge("availability" => "NONE")], [gpu.merge("availability" => nil)]]
    rows.each do |catalog|
      client = Client.new(catalog)
      Dir.mktmpdir do |root|
        fleet = LocalModelEvaluation::RunpodFleet.new(client: client, env_path: File.join(root, ".env"), out: StringIO.new)
        lifecycle = LocalModelEvaluation::RunpodFleetLifecycle.allocate
        lifecycle.instance_variable_set(:@client, client)
        first = assert_raises(LocalModelEvaluation::RunpodFleet::Error) { fleet.preflight(worker_count: 1) }
        second = assert_raises(LocalModelEvaluation::RunpodFleetLifecycle::Error) do
          lifecycle.send(:capacity!, { "cloud" => "SECURE" }, count: 1, gpu_id: "NVIDIA A40")
        end
        assert_equal first.message, second.message
        [first, second].each do |error|
          assert_equal :capacity_unavailable, Outcome.code_for(error)
          assert RunpodOllamaFleet::CampaignRunpodRuntime.allocate.send(:retryable_capacity_failure?, error)
        end
        assert_equal 0, client.creates
      end
    end
  end

  # Exercises identity/hardware observations in both adapters without contacting
  # a provider. Identity remains denied and hardware remains allowed by legacy policy.
  def test_observed_pod_mismatch_codes_preserve_the_existing_policy
    runtime = RunpodOllamaFleet::CampaignRunpodRuntime.allocate
    [LocalModelEvaluation::RunpodFleet, LocalModelEvaluation::RunpodFleetLifecycle].each do |adapter_class|
      adapter = adapter_class.allocate
      adapter.instance_variable_set(:@fleet_key, "test")
      adapter.instance_variable_set(:@gpu_id, "NVIDIA A40")
      valid = { "name" => "af-lme-test-burst-1", "cloud" => "SECURE", "gpu" => { "id" => "NVIDIA A40", "count" => 1 } }
      [["name", "wrong", :identity_mismatch, false], ["cloud", "COMMUNITY", :hardware_mismatch, true], ["gpu", {}, :hardware_mismatch, true]].each do |field, value, code, retryable|
        keywords = { cloud: "SECURE" }
        keywords[:gpu_id] = "NVIDIA A40" if adapter_class == LocalModelEvaluation::RunpodFleetLifecycle
        error = assert_raises(adapter_class::Error) { adapter.send(:validate_pod!, valid.merge(field => value), 1, "pod-1", **keywords) }
        assert_equal code, Outcome.code_for(error)
        assert_equal retryable, runtime.send(:retryable_capacity_failure?, error)
      end
    end
  end

  # Polls fake terminal/pending pods in both adapters, proving the source code
  # distinguishes resource loss from readiness timeout without provisioning.
  def test_terminal_resource_and_readiness_timeout_have_source_selected_codes
    [LocalModelEvaluation::RunpodFleet, LocalModelEvaluation::RunpodFleetLifecycle].each do |adapter_class|
      adapter = adapter_class.allocate
      adapter.instance_variable_set(:@fleet_key, "test")
      adapter.instance_variable_set(:@gpu_id, "NVIDIA A40")
      adapter.instance_variable_set(:@clock, -> { 0.0 })
      adapter.instance_variable_set(:@monotonic_clock, -> { 0.0 })
      adapter.instance_variable_set(:@out, StringIO.new)
      [["ERROR", :resource_unusable], ["PENDING", :readiness_unavailable]].each do |status, code|
        pod = { "name" => "af-lme-test-burst-1", "cloud" => "SECURE", "gpu" => { "id" => "NVIDIA A40", "count" => 1 }, "status" => status }
        client = Object.new
        client.define_singleton_method(:get_pod) { |_id| pod }
        adapter.instance_variable_set(:@client, client)
        keywords = { cloud: "SECURE", wait_seconds: 0, poll_seconds: 1 }
        if adapter_class == LocalModelEvaluation::RunpodFleet
          keywords[:min_ready_workers] = 1
        else
          keywords[:gpu_id] = "NVIDIA A40"
        end
        error = assert_raises(adapter_class::Error) { adapter.send(:wait_until_ready, [[1, "pod-1"]], **keywords) }
        assert_equal code, Outcome.code_for(error)
        assert RunpodOllamaFleet::CampaignRunpodRuntime.allocate.send(:retryable_capacity_failure?, error)
      end
    end
  end

  private

  # Returns one available synthetic GPU catalog row; takes no inputs.
  def gpu
    { "id" => "NVIDIA A40", "memory" => 48, "secure" => true, "availability" => "HIGH", "price" => { "secure" => 0.5 } }
  end
end
