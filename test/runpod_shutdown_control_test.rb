# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require_relative "../lib/local_model_evaluation/runpod_shutdown_control"

class RunpodShutdownControlTest < Minitest::Test
  FakeWorker = Struct.new(:index, :pod_id, :name, :host, :ssh_port, :hourly_rate, keyword_init: true)

  def setup
    @tmp = Dir.mktmpdir("rpof-shutdown-")
    @now = Time.utc(2026, 9, 16, 20, 0, 0)
    @activity = Hash.new("idle")
    @destroyed = []
    create_fleet("main", [1, 2])
  end

  def teardown
    FileUtils.remove_entry(@tmp) if File.exist?(@tmp)
  end

  def test_terminal_countdown_resets_on_activity_then_destroys_after_five_idle_minutes
    control = build_control
    control.schedule_terminal!(fleet_key: "main", worker_indices: [1, 2], idle_seconds: 300, drain_timeout_seconds: 600)

    control.watch_once
    advance(240)
    @activity[1] = "active"
    control.watch_once
    @activity[1] = "idle"
    control.watch_once
    advance(299)
    control.watch_once
    assert_empty @destroyed

    advance(2)
    control.watch_once
    assert_equal [[1, 2]], @destroyed
    assert_empty control.status_snapshot.fetch("gates")
  end

  def test_unavailable_counts_as_inactive_and_can_retire_without_force
    @activity[1] = "unavailable"
    control = build_control
    control.schedule_terminal!(fleet_key: "main", worker_indices: [1], idle_seconds: 300)

    control.watch_once
    advance(301)
    control.watch_once

    assert_equal [[1]], @destroyed
    assert_empty control.status_snapshot.fetch("gates")
  end

  def test_pending_terminal_gate_allows_dispatch_but_draining_blocks_overlap
    control = build_control
    control.schedule_terminal!(fleet_key: "main", worker_indices: [1], idle_seconds: 300)
    assert control.dispatch_gate(fleet_key: "main", worker_indices: [1]).fetch("allowed")

    control.begin_graceful!(fleet_key: "main", worker_indices: [1], drain_timeout_seconds: 600)
    refute control.dispatch_gate(fleet_key: "main", worker_indices: [1]).fetch("allowed")
    assert control.dispatch_gate(fleet_key: "main", worker_indices: [2]).fetch("allowed")
  end

  def test_keep_cancels_current_event_but_does_not_create_permanent_exemption
    control = build_control
    control.schedule_terminal!(fleet_key: "main", worker_indices: [1])
    refute_nil control.keep!("main")
    assert_empty control.status_snapshot.fetch("gates")

    control.schedule_terminal!(fleet_key: "main", worker_indices: [1])
    refute_empty control.status_snapshot.fetch("gates")
  end

  def test_keep_wins_over_a_stale_watchdog_destroy_snapshot
    control = build_control
    gate = control.begin_graceful!(fleet_key: "main", worker_indices: [1], drain_timeout_seconds: 600)
    control.keep!("main")

    result = control.send(:destroy_gate!, "main", gate)

    assert_equal "cancelled", result
    assert_empty @destroyed
  end

  def test_persistent_lifecycle_skips_automatic_terminal_gate
    control = build_control(lifecycle_reader: ->(_key) { "persistent" })
    result = control.schedule_terminal!(fleet_key: "main", worker_indices: [1])
    assert_equal "persistent", result.fetch("status")
    assert_empty control.status_snapshot.fetch("gates")
  end

  def test_graceful_timeout_never_calls_force_destroy
    @activity[1] = "active"
    control = build_control
    control.begin_graceful!(fleet_key: "main", worker_indices: [1], drain_timeout_seconds: 60)
    advance(61)
    assert_equal "timed_out", control.send(:process_gate!, "main")
    assert_empty @destroyed
    gate = control.status_snapshot.fetch("gates").fetch("main")
    assert_equal "timed_out", gate.fetch("status")
  end

  def test_status_renders_countdown_and_copy_paste_keep_command
    control = build_control
    control.schedule_terminal!(fleet_key: "main", worker_indices: [1], idle_seconds: 300)
    control.watch_once
    advance(60)
    output = control.render(fleet_aliases: [{ "alias" => "A", "fleet_key" => "main" }])
    assert_includes output, "A main: TERMINAL -> shutdown in 04:00"
    assert_includes output, "KEEP: bin/rpof keep main"
  end

  private

  def build_control(lifecycle_reader: ->(_key) { "managed" })
    LocalModelEvaluation::RunpodShutdownControl.new(
      root: @tmp,
      repo_root: @tmp,
      wall_clock: -> { @now },
      sleeper: ->(_seconds) {},
      lifecycle_reader: lifecycle_reader,
      activity_reader: ->(_key, _fleet, indices) { indices.to_h { |i| [i, @activity[i]] } },
      destroyer: ->(_namespace, indices, _reason) { @destroyed << indices; indices },
      tunnel_stopper: ->(_state, _fleet, _indices) {}
    )
  end

  def create_fleet(key, indices)
    namespace = LocalModelEvaluation::RunpodFleetNamespace.new(root: @tmp, repo_root: @tmp, fleet_key: key, create: true)
    state = LocalModelEvaluation::RunpodFleetState.new(root: namespace.state_root, clock: -> { @now }, local_port_base: namespace.local_port_base)
    workers = indices.map do |index|
      FakeWorker.new(index: index, pod_id: "pod_#{index}", name: "burst_#{index}", host: "host", ssh_port: 2200 + index, hourly_rate: 1.0)
    end
    state.activate(workers: workers, cloud: "SECURE", gpu_id: "GPU", image: "image", provisioning: { "container_disk_gb" => 30, "volume_gb" => 60 })
  end

  def advance(seconds)
    @now += seconds
  end
end
