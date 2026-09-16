# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "fileutils"
require "json"
require_relative "../lib/local_model_evaluation/runpod_activity"

class RunpodActivityTest < Minitest::Test
  class FakeFleetState
    def initialize(root:)
      @root = root
    end

    def artifact_dir(fleet_id, name)
      File.join(@root, fleet_id, name)
    end
  end

  class FakeProbe
    attr_reader :checked

    def initialize(results = {})
      @results = results
      @checked = []
    end

    def check(endpoint)
      @checked << endpoint
      @results.fetch(endpoint) do
        { "status" => "idle", "detail" => "no established client connection observed" }
      end
    end
  end

  class FakeCommandStatus
    attr_reader :exitstatus

    def initialize(success:, exitstatus:)
      @success = success
      @exitstatus = exitstatus
    end

    def success?
      @success
    end
  end

  def setup
    @tmp = Dir.mktmpdir("rpof-activity-")
    @state = FakeFleetState.new(root: @tmp)
    @fleet = {
      "fleet_id" => "20260916T100910Z-test",
      "workers" => [
        worker(1, "pod_a"),
        worker(2, "pod_b")
      ]
    }
  end

  def teardown
    FileUtils.remove_entry(@tmp) if @tmp && File.exist?(@tmp)
  end

  def test_reports_active_and_idle_workers_from_healthy_managed_tunnels
    write_tunnel_state(
      @fleet,
      [
        tunnel(1, "pod_a", "http://127.0.0.1:11489"),
        tunnel(2, "pod_b", "http://127.0.0.1:11490")
      ]
    )
    probe = FakeProbe.new(
      "http://127.0.0.1:11489" => {
        "status" => "active",
        "detail" => "established client connection observed"
      }
    )
    monitor = LocalModelEvaluation::RunpodActivity.new(
      fleet_state: @state,
      connection_probe: probe,
      process_alive: ->(_pid) { true }
    )

    snapshot = monitor.snapshot(@fleet)

    assert_equal "active", snapshot.fetch("workers").fetch(1).fetch("status")
    assert_equal "idle", snapshot.fetch("workers").fetch(2).fetch("status")
    assert_equal 1, snapshot.fetch("counts").fetch("active")
    assert_equal 1, snapshot.fetch("counts").fetch("idle")
    assert_equal 0, snapshot.fetch("counts").fetch("unavailable")
    assert_equal 0, snapshot.fetch("counts").fetch("unknown")
    assert_equal ["http://127.0.0.1:11489", "http://127.0.0.1:11490"], probe.checked
  end

  def test_reports_unavailable_without_managed_tunnel_state_and_does_not_probe
    probe = FakeProbe.new
    monitor = LocalModelEvaluation::RunpodActivity.new(
      fleet_state: @state,
      connection_probe: probe,
      process_alive: ->(_pid) { true }
    )

    snapshot = monitor.snapshot(@fleet)

    assert_equal 2, snapshot.fetch("counts").fetch("unavailable")
    assert_equal "unavailable", snapshot.fetch("workers").fetch(1).fetch("status")
    assert_includes snapshot.fetch("workers").fetch(1).fetch("detail"), "tunnel state is missing"
    assert_empty probe.checked
  end

  def test_reports_unavailable_for_stale_or_wrong_generation_tunnel
    write_tunnel_state(
      @fleet,
      [
        tunnel(1, "old_pod", "http://127.0.0.1:11489"),
        tunnel(2, "pod_b", "http://127.0.0.1:11490", process_status: "stale")
      ]
    )
    probe = FakeProbe.new
    monitor = LocalModelEvaluation::RunpodActivity.new(
      fleet_state: @state,
      connection_probe: probe,
      process_alive: ->(_pid) { true }
    )

    snapshot = monitor.snapshot(@fleet)

    assert_equal 2, snapshot.fetch("counts").fetch("unavailable")
    assert_includes snapshot.fetch("workers").fetch(1).fetch("detail"), "different pod generation"
    assert_includes snapshot.fetch("workers").fetch(2).fetch("detail"), "stale"
    assert_empty probe.checked
  end

  def test_connection_probe_maps_lsof_established_and_empty_results
    calls = []
    responses = [
      ["COMMAND PID USER FD TYPE DEVICE SIZE/OFF NODE NAME\n", "", FakeCommandStatus.new(success: true, exitstatus: 0)],
      ["", "", FakeCommandStatus.new(success: false, exitstatus: 1)]
    ]
    probe = LocalModelEvaluation::RunpodActivity::ConnectionProbe.new(
      lsof_path: "/test/lsof",
      command_runner: lambda do |argv|
        calls << argv
        responses.shift
      end
    )

    assert_equal "active", probe.check("http://127.0.0.1:11489").fetch("status")
    assert_equal "idle", probe.check("http://127.0.0.1:11489").fetch("status")
    assert_equal 2, calls.length
    assert_equal "/test/lsof", calls.first.first
    assert_includes calls.first, "-iTCP@127.0.0.1:11489"
    assert_includes calls.first, "-sTCP:ESTABLISHED"
  end

  private

  def worker(index, pod_id)
    {
      "index" => index,
      "pod_id" => pod_id,
      "status" => "active"
    }
  end

  def tunnel(index, pod_id, endpoint, process_status: "running", health_status: "healthy")
    {
      "index" => index,
      "pod_id" => pod_id,
      "pid" => 20_000 + index,
      "process_status" => process_status,
      "health_status" => health_status,
      "endpoint" => endpoint
    }
  end

  def write_tunnel_state(fleet, workers)
    root = @state.artifact_dir(fleet.fetch("fleet_id"), "tunnels")
    FileUtils.mkdir_p(root)
    File.write(
      File.join(root, "tunnels.json"),
      JSON.pretty_generate(
        {
          "fleet_id" => fleet.fetch("fleet_id"),
          "workers" => workers
        }
      )
    )
  end
end
