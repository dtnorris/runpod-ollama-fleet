# frozen_string_literal: true

require_relative "test_helper"
require_relative "support/selected_worker_fixture"
require_relative "../lib/runpod_ollama_fleet/consumer_capacity"

class ConsumerCapacityTest < Minitest::Test
  Campaign = Struct.new(:identity_sha256, :profiles, :hardware_bindings)
  Binding = Struct.new(:state_path, :campaign, :binding_sha256)

  class Runtime
    attr_reader :fixture
    def initialize(fixture) = @fixture = fixture
    def current_worker_count = fixture.worker.dig("lifecycle", "phase") == "retired" ? 0 : 1
    def status
      worker = fixture.worker
      lifecycle = worker["lifecycle"] || { "phase" => "active", "revision" => 0 }
      { "fleet_id" => fixture.fleet_id,
        "worker_lifecycle" => [worker.slice("worker_id", "generation_id", "pod_id").merge(lifecycle)] }
    end
    def select_worker!(**options) = fixture.lifecycle.select_worker!(**options, registry: fixture.registry)
    def reconcile_retirements! = fixture.lifecycle.reconcile_retirements!
  end

  def setup
    @fixture = SelectedWorkerFixture.new
    @runtime = Runtime.new(@fixture)
    @request = {
      "contract_version" => "ollama-capability-request/v0.1",
      "ollama" => { "model" => "model:latest", "expected_digest" => "c" * 64,
                    "required_context_length" => 4096, "require_fully_gpu_resident" => true }
    }
    @profile = @request.fetch("ollama").merge("profile_id" => "default", "desired_workers" => 1, "max_workers" => 1)
    campaign = Campaign.new("b" * 64, [@profile], [{ "profile_id" => "default" }])
    @binding = Binding.new(File.join(@fixture.root, "campaign", "binding.json"), campaign, "a" * 64)
    @document = {
      "contract_version" => RunpodOllamaFleet::ConsumerCapacity::CONTRACT,
      "campaign_identity_sha256" => "b" * 64, "binding_sha256" => "a" * 64, "idle_grace_seconds" => 10,
      "profiles" => [{ "profile_id" => "default", "consumer_id" => "d" * 64, "plan_sha256" => "e" * 64,
                       "pool_id" => "pool", "capability_request" => @request, "source_argv" => ["/offline-demand"] }]
    }
    @demand = {
      "contract_version" => "wlo-consumer-demand/v0.1", "consumer_id" => "d" * 64,
      "plan_sha256" => "e" * 64, "pool_id" => "pool",
      "capability_fingerprint" => RunpodOllamaFleet::OllamaCapabilityRequest.new(JSON.generate(@request)).fingerprint,
      "fresh" => true, "state" => "active", "runnable_count" => 1,
      "bound_count" => 0, "uncertain_count" => 0, "quiescent" => true
    }
    @capacity = capacity
    @capacity.bind!(@document)
    @fixture.registry.snapshot
  end

  def teardown = @fixture.close

  def test_explicit_binding_is_idempotent_and_rejects_conflicts
    assert_equal @document, @capacity.bind!(@document)
    changed = Marshal.load(Marshal.dump(@document))
    changed["profiles"][0]["consumer_id"] = "f" * 64
    assert_raises(RunpodOllamaFleet::ConsumerCapacity::Error) { @capacity.bind!(changed) }
    changed["campaign_identity_sha256"] = "f" * 64
    assert_raises(RunpodOllamaFleet::ConsumerCapacity::Error) { @capacity.bind!(changed) }
  end

  def test_demand_caps_operator_target_but_cannot_raise_it
    assert_equal 1, reconcile
    @demand["runnable_count"] = 10
    assert_equal 1, reconcile
    @profile["desired_workers"] = 0
    assert_equal 0, reconcile
    assert_empty @fixture.client.deleted
  end

  def test_grace_survives_restart_and_demand_recovery_cancels_before_drain
    @demand["runnable_count"] = 0
    reconcile
    @fixture.now += 9
    @capacity = capacity
    reconcile
    assert_nil @fixture.worker["lifecycle"]
    @demand["runnable_count"] = 1
    reconcile
    @fixture.now += 2
    @demand["runnable_count"] = 0
    reconcile
    assert_nil @fixture.worker["lifecycle"]
    @fixture.now += 10
    reconcile
    assert_equal "draining", @fixture.worker.dig("lifecycle", "phase")
  end

  def test_drain_then_expiry_then_fresh_quiescence_then_verified_retirement
    drop_and_drain
    assert_equal "draining", @fixture.worker.dig("lifecycle", "phase")
    @fixture.now += 1
    assert_equal "UNAVAILABLE", @fixture.registry.snapshot.fetch("workers").first.fetch("state")
    reconcile
    assert_empty @fixture.client.deleted
    assert_equal "draining", @fixture.worker.dig("lifecycle", "phase")
    @fixture.now += 30
    @capacity = capacity
    reconcile
    assert_equal "retirement_requested", @fixture.worker.dig("lifecycle", "phase")
    @runtime.reconcile_retirements!
    @runtime.reconcile_retirements!
    assert_equal ["pod-1"], @fixture.client.deleted
    assert_equal "retired", @fixture.worker.dig("lifecycle", "phase")
    assert @fixture.worker.dig("lifecycle", "provider_absence_verified_at_utc")
  end

  def test_bound_uncertain_and_unavailable_sources_cannot_prove_quiescence
    drop_and_drain
    @fixture.now += 40
    @demand.merge!("bound_count" => 1, "uncertain_count" => 1, "quiescent" => false)
    reconcile
    assert_equal "draining", @fixture.worker.dig("lifecycle", "phase")
    @missing = true
    reconcile
    assert_equal "draining", @fixture.worker.dig("lifecycle", "phase")
    assert_empty @fixture.client.deleted
  end

  def test_identity_mismatch_is_unavailable_not_quiescence
    @demand["consumer_id"] = "f" * 64
    assert_equal 0, reconcile
    @fixture.now += 60
    reconcile
    @fixture.now += 60
    reconcile
    assert_equal "draining", @fixture.worker.dig("lifecycle", "phase")
    assert_empty @fixture.client.deleted
  end

  def test_paused_completed_failed_stale_and_missing_sources_begin_release
    %w[paused completed workload_failed stale missing_heartbeat].each do |state|
      @demand.merge!("state" => state, "fresh" => false)
      assert_equal 0, reconcile
    end
    @fixture.now += 10
    reconcile
    assert_equal "draining", @fixture.worker.dig("lifecycle", "phase")
  end

  def test_stale_observation_cannot_authorize_retirement
    drop_and_drain
    @fixture.now += 40
    @capacity = capacity(source: ->(*) { @demand.merge("observed_at" => (@fixture.now - 60).iso8601) })
    reconcile
    assert_equal "draining", @fixture.worker.dig("lifecycle", "phase")
    assert_empty @fixture.client.deleted
  end

  def test_recovered_demand_never_undrains_or_retires_required_generation
    drop_and_drain
    @fixture.now += 60
    @demand["runnable_count"] = 1
    assert_equal 1, reconcile
    assert_equal "draining", @fixture.worker.dig("lifecycle", "phase")
    assert_empty @fixture.client.deleted
  end

  def test_missing_source_from_start_preserves_grace_across_restart
    @missing = true
    assert_equal 0, reconcile
    @fixture.now += 10
    @capacity = capacity
    reconcile
    assert_equal "draining", @fixture.worker.dig("lifecycle", "phase")
    @fixture.now += 90
    reconcile
    assert_empty @fixture.client.deleted
  end

  def test_ttl_change_does_not_shorten_established_expiry_watermark
    original = @fixture.registry.snapshot.fetch("expires_at")
    @fixture.now += 1
    short = @fixture.registry
    short.instance_variable_set(:@ttl_seconds, 1)
    short.snapshot
    drop_and_drain
    expiry = @fixture.worker.dig("lifecycle", "ready_snapshots_expire_at_utc")
    assert_equal original, expiry
    @fixture.now += 1
    @capacity = capacity
    reconcile
    assert_equal expiry, @fixture.worker.dig("lifecycle", "ready_snapshots_expire_at_utc")
    assert_equal "draining", @fixture.worker.dig("lifecycle", "phase")
  end

  def test_production_boundary_does_not_read_consumer_private_files
    text = File.read(File.expand_path("../lib/runpod_ollama_fleet/consumer_capacity.rb", __dir__))
    refute_match(/execution\.json|jobs\.json|metadata\.json|\.execution\.lock|WorkloadOrchestrator|require.*workload_orchestrator/, text)
  end

  def test_historical_publisher_with_unknown_expiry_history_cannot_authorize_retirement
    path = File.join(@fixture.root, RunpodOllamaFleet::DynamicWorkerRegistry::PUBLISHER_STATE_FILE)
    historical = JSON.parse(File.read(path)).except("expiry_history_known", "ready_snapshots_expire_at_utc")
    File.write(path, JSON.generate(historical))
    @fixture.now += 1
    @fixture.registry.snapshot
    drop_and_drain
    assert_nil @fixture.worker.dig("lifecycle", "ready_snapshots_expire_at_utc")
    @fixture.now += 120
    reconcile
    assert_equal "draining", @fixture.worker.dig("lifecycle", "phase")
    assert_empty @fixture.client.deleted
  end

  def test_public_command_source_uses_argv_and_rejects_failed_response
    reader = RunpodOllamaFleet::ConsumerCapacity.new(binding: @binding)
    result = reader.send(:command_document, [RbConfig.ruby, "-e", "puts ARGV.first", JSON.generate(@demand)])
    assert_equal @demand, result
    assert_raises(RunpodOllamaFleet::ConsumerCapacity::Error) do
      reader.send(:command_document, [RbConfig.ruby, "-e", "exit 1"])
    end
  end

  private

  def capacity(source: nil)
    source ||= lambda do |_argv|
      raise "source unavailable" if @missing
      @demand.merge("observed_at" => @fixture.now.iso8601(6), "heartbeat_at" => @fixture.now.iso8601(6))
    end
    RunpodOllamaFleet::ConsumerCapacity.new(binding: @binding, wall_clock: -> { @fixture.now }, source:)
  end

  def reconcile
    @capacity.reconcile(profiles: [@profile], runtime_factory: ->(*) { @runtime }).first.fetch("desired_workers")
  end

  def drop_and_drain
    @demand["runnable_count"] = 0
    reconcile
    @fixture.now += 10
    reconcile
  end
end
