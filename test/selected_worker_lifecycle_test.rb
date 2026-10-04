# frozen_string_literal: true

require_relative "test_helper"
require_relative "support/selected_worker_fixture"
require_relative "fixtures/dynamic-worker-registry-v0.1/conformance"

class SelectedWorkerLifecycleTest < Minitest::Test
  def setup = @fixture = SelectedWorkerFixture.new
  def teardown = @fixture.close

  def test_drain_preserves_published_tuple_and_excludes_new_placement_after_restart
    before = @fixture.registry.snapshot
    draining = @fixture.select("drain")
    assert_equal "draining", draining.fetch("phase")
    assert_empty @fixture.client.deleted
    assert_empty @fixture.client.observed
    assert_equal @fixture.initial_worker.slice("worker_id", "generation_id", "pod_id"),
                 @fixture.worker.slice("worker_id", "generation_id", "pod_id")
    # Same-second caching must not resurrect READY. No fabricated future time.
    assert_raises(RunpodOllamaFleet::DynamicWorkerRegistry::Error) { @fixture.registry.snapshot }
    @fixture.now += 1
    after = @fixture.registry.snapshot
    assert_equal before.fetch("workers").first.merge("state" => "UNAVAILABLE"), after.fetch("workers").first
    assert_operator after.fetch("revision"), :>, before.fetch("revision")
    assert_equal after, DynamicWorkerRegistryV01::Conformance.validate_document!(after, now: @fixture.now)
    # Even later qualification artifacts cannot erase a bound tuple during drain.
    FileUtils.rm_rf(@fixture.state.artifact_dir(@fixture.fleet_id, "bootstrap"))
    FileUtils.rm_rf(@fixture.state.artifact_dir(@fixture.fleet_id, "tunnels"))
    @fixture.now += 1
    assert_equal after.fetch("workers"), @fixture.registry.snapshot.fetch("workers")
    assert_equal draining, @fixture.select("drain")
  end

  def test_stale_revision_and_generation_fail_closed
    @fixture.select("drain")
    assert_raises(LocalModelEvaluation::RunpodFleetLifecycle::Error) { @fixture.select("drain", revision: 0) }
    assert_raises(LocalModelEvaluation::RunpodFleetLifecycle::Error) do
      @fixture.select("remove", generation_id: "replacement")
    end
    assert_empty @fixture.client.deleted
  end

  def test_remove_requires_drain_and_confirmation
    assert_raises(LocalModelEvaluation::RunpodFleetLifecycle::Error) { @fixture.select("remove") }
    @fixture.select("drain")
    assert_raises(LocalModelEvaluation::RunpodFleetLifecycle::Error) { @fixture.select("remove", confirm: false) }
    assert_equal "draining", @fixture.worker.dig("lifecycle", "phase")
  end

  def test_remove_is_supervised_exact_verified_and_repeatable_including_final_worker
    @fixture.registry.snapshot
    @fixture.select("drain")
    @fixture.select("remove")
    assert_equal "retirement_requested", @fixture.worker.dig("lifecycle", "phase")
    assert_empty @fixture.client.deleted
    @fixture.client.before_delete = lambda do
      assert_equal "delete_in_progress", @fixture.worker.dig("lifecycle", "phase")
    end
    @fixture.lifecycle.reconcile_retirements!
    retired = @fixture.worker.fetch("lifecycle")
    assert_equal "retired", retired.fetch("phase")
    assert retired.fetch("provider_absence_verified_at_utc")
    assert_equal ["pod-1"], @fixture.client.deleted
    assert_operator @fixture.client.observed.count("pod-1"), :>=, 2
    assert_includes @fixture.admission.absent, "pod-1"
    assert_equal %w[draining retirement_requested delete_in_progress retired], retired.fetch("history").map { |r| r["phase"] }
    assert_equal retired, @fixture.select("remove")
    @fixture.lifecycle.reconcile_retirements!
    assert_equal ["pod-1"], @fixture.client.deleted
    @fixture.now += 1
    assert_empty @fixture.registry.snapshot.fetch("workers")
    assert_equal "destroyed", @fixture.worker.fetch("status")
  end

  def test_ambiguous_delete_is_retained_and_recovery_only_verifies_absence
    @fixture.select("drain")
    @fixture.select("remove")
    @fixture.client.ambiguous = true
    assert_raises(LocalModelEvaluation::RunpodFleetLifecycle::Error) { @fixture.lifecycle.reconcile_retirements! }
    assert_equal "delete_ambiguous", @fixture.worker.dig("lifecycle", "phase")
    assert_includes @fixture.worker.dig("lifecycle", "error"), "result lost"
    assert_empty @fixture.admission.absent
    assert_raises(LocalModelEvaluation::RunpodFleetLifecycle::Error) { @fixture.lifecycle.reconcile_retirements! }
    assert_equal ["pod-1"], @fixture.client.deleted
    assert_equal "active", @fixture.worker.fetch("status")
    @fixture.client.disappear!
    @fixture.lifecycle.reconcile_retirements!
    assert_equal "retired", @fixture.worker.dig("lifecycle", "phase")
    assert_equal ["pod-1"], @fixture.client.deleted
  end

  def test_successful_delete_response_without_absence_is_not_retirement
    @fixture.select("drain")
    @fixture.select("remove")
    @fixture.client.retain = true
    assert_raises(LocalModelEvaluation::RunpodFleetLifecycle::Error) { @fixture.lifecycle.reconcile_retirements! }
    assert_equal "delete_ambiguous", @fixture.worker.dig("lifecycle", "phase")
    assert_empty @fixture.admission.absent
  end

  def test_crash_after_persisting_delete_intent_does_not_send_a_delete
    @fixture.select("drain")
    @fixture.select("remove")
    @fixture.state.transition_worker_lifecycle!(
      fleet_id: @fixture.fleet_id, **@fixture.initial_worker.slice("worker_id", "generation_id", "pod_id").transform_keys(&:to_sym),
      phase: "delete_in_progress", reason: "crash before send"
    )
    assert_raises(LocalModelEvaluation::RunpodFleetLifecycle::Error) { @fixture.lifecycle.reconcile_retirements! }
    assert_empty @fixture.client.deleted
    assert_empty @fixture.admission.absent
  end

  def test_replacement_has_fresh_generation_and_old_command_cannot_touch_it
    @fixture.select("drain")
    @fixture.select("remove")
    @fixture.lifecycle.reconcile_retirements!
    @fixture.state.begin_replacement(1)
    @fixture.state.mark_replacement_destroyed(1)
    replacement = LocalModelEvaluation::RunpodFleet::Worker.new(
      index: 1, pod_id: "pod-2", name: "af-lme-burst-1", host: "198.51.100.2", ssh_port: 22002, hourly_rate: 0.5
    )
    @fixture.state.complete_replacement(worker: replacement, created_at_utc: @fixture.now)
    assert_equal 2, @fixture.worker.fetch("generation")
    refute @fixture.worker.key?("lifecycle")
    assert_equal "retired", @fixture.worker.dig("history", 0, "lifecycle", "phase")
    assert_raises(LocalModelEvaluation::RunpodFleetLifecycle::Error) { @fixture.select("remove") }
    assert_equal ["pod-1"], @fixture.client.deleted
  end

  def test_two_terminals_and_controller_share_the_existing_durable_fleet_lock
    @fixture.select("drain")
    @fixture.select("remove")
    entered = Queue.new
    release = Queue.new
    @fixture.client.before_delete = -> { entered << true; release.pop }
    first = Thread.new { @fixture.lifecycle.reconcile_retirements! }
    entered.pop
    assert_raises(LocalModelEvaluation::RunpodFleetLifecycle::Error) { @fixture.select("remove") }
    assert_raises(LocalModelEvaluation::RunpodFleetLifecycle::Error) { @fixture.lifecycle.reconcile_retirements! }
    release << true
    first.value
    assert_equal ["pod-1"], @fixture.client.deleted
  ensure
    release << true if release && first&.alive?
    first&.join
  end

  def test_production_controls_have_no_consumer_storage_or_implementation_dependency
    paths = %w[bin/rpof-campaign lib/runpod_ollama_fleet/campaign_lifecycle.rb
               lib/runpod_ollama_fleet/campaign_runpod_runtime.rb lib/local_model_evaluation/runpod_fleet_lifecycle.rb
               lib/local_model_evaluation/runpod_fleet_state.rb lib/runpod_ollama_fleet/dynamic_worker_registry.rb]
    paths.each do |path|
      source = File.read(File.expand_path("../#{path}", __dir__))
      refute_match(/execution\.json|jobs\.json|attempt_metadata|pause_state|adventure_finder|require.*workload_orchestrator/, source, path)
    end
  end
end
