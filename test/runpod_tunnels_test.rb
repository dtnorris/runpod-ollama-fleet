# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "fileutils"
require "json"
require "stringio"
require_relative "../lib/local_model_evaluation/runpod_tunnels"

class RunpodTunnelsTest < Minitest::Test
  class FakeFleetState
    def initialize(root:, fleet:)
      @root = root
      @fleet = fleet
    end
    def current = Marshal.load(Marshal.dump(@fleet))
    def artifact_dir(fleet_id, name)
      raise "wrong fleet" unless fleet_id == @fleet.fetch("fleet_id")
      File.join(@root, fleet_id, name)
    end
  end

  class FakeProcess
    attr_reader :spawns, :terminated
    def initialize
      @next_pid = 2000
      @alive = {}
      @matches = {}
      @spawns = []
      @terminated = []
    end
    def spawn(command:, log_path:, chdir:)
      @next_pid += 1
      pid = @next_pid
      @alive[pid] = true
      @matches[pid] = true
      @spawns << { pid: pid, command: command, log_path: log_path, chdir: chdir }
      FileUtils.mkdir_p(File.dirname(log_path)); File.write(log_path, "fake ssh\n")
      pid
    end
    def alive?(pid) = @alive.fetch(Integer(pid), false)
    def matches?(pid, _identity) = @matches.fetch(Integer(pid), false)
    def terminate_group(pid, grace_seconds:)
      @terminated << [Integer(pid), grace_seconds]
      @alive[Integer(pid)] = false
    end
    def kill(pid) = @alive[Integer(pid)] = false
    def mismatch(pid) = @matches[Integer(pid)] = false
  end

  class FakeHealth
    def initialize(results = {})
      @results = results
    end
    def check(endpoint)
      value = @results.fetch(endpoint, true)
      value = value.call if value.respond_to?(:call)
      if value == true
        LocalModelEvaluation::RunpodTunnels::Health.new(healthy: true, version: "0.33.2")
      elsif value == false
        LocalModelEvaluation::RunpodTunnels::Health.new(healthy: false, detail: "connection refused")
      else
        value
      end
    end
  end

  class FakePorts
    def initialize(unavailable = []) = @unavailable = unavailable
    def available?(port) = !@unavailable.include?(Integer(port))
  end

  def setup
    @tmp = Dir.mktmpdir("lme-tunnels-")
    @repo = File.join(@tmp, "repo")
    FileUtils.mkdir_p(@repo)
    @identity = File.join(@tmp, "id_ed25519")
    File.write(@identity, "fake")
    @fleet = {
      "fleet_id" => "20260829T230000Z-podabc",
      "status" => "active",
      "workers" => (1..3).map do |i|
        {
          "index" => i,
          "pod_id" => "pod_#{i}",
          "host" => "198.51.100.#{i}",
          "ssh_port" => 22_000 + i,
          "local_ollama_url" => "http://127.0.0.1:#{11_440 + i}",
          "status" => "active"
        }
      end
    }
    @state = FakeFleetState.new(root: File.join(@repo, "output", "runpod-fleets"), fleet: @fleet)
    @process = FakeProcess.new
    @out = StringIO.new
  end

  def teardown
    FileUtils.remove_entry(@tmp) if @tmp && File.exist?(@tmp)
  end

  def build_manager(health: FakeHealth.new, ports: FakePorts.new)
    LocalModelEvaluation::RunpodTunnels.new(
      fleet_state: @state,
      repo_root: @repo,
      out: @out,
      identity_path: @identity,
      process_adapter: @process,
      health_checker: health,
      port_checker: ports,
      sleeper: ->(_seconds) {},
      monotonic_clock: sequential_clock,
      wall_clock: -> { Time.utc(2026, 8, 29, 23, 1, 0) }
    )
  end

  def sequential_clock
    value = -0.01
    -> { value += 0.01 }
  end

  def test_start_spawns_all_workers_directly_and_records_healthy_fleet_scoped_state
    manager = build_manager
    state = manager.start(worker_indices: [1, 2, 3], wait_seconds: 1, poll_seconds: 0.01)

    assert_equal 3, @process.spawns.length
    @process.spawns.each_with_index do |spawn, offset|
      index = offset + 1
      command = spawn.fetch(:command)
      assert_equal "ssh", command.first
      assert_includes command, "127.0.0.1:#{11_440 + index}:127.0.0.1:11434"
      assert_includes command, "UserKnownHostsFile=#{File.join(@repo, 'output', 'runpod-fleets', @fleet['fleet_id'], 'tunnels', "known_hosts-burst_#{index}")}"
      assert_includes command, "root@198.51.100.#{index}"
      assert_match %r{/tunnels/burst_#{index}\.log\z}, spawn.fetch(:log_path)
    end
    assert_equal ["healthy"], state.fetch("workers").map { |w| w.fetch("health_status") }.uniq
    assert_includes @out.string, "PASS: burst_1 tunnel healthy"
    assert_includes @out.string, "Tunnel start complete: 3/3"

    path = File.join(@repo, "output", "runpod-fleets", @fleet.fetch("fleet_id"), "tunnels", "tunnels.json")
    persisted = JSON.parse(File.read(path))
    assert_equal @fleet.fetch("fleet_id"), persisted.fetch("fleet_id")
    assert_equal 3, persisted.fetch("workers").length
  end

  def test_start_status_and_stop_address_worker_twelve
    @fleet.fetch("workers") << {
      "index" => 12,
      "pod_id" => "pod_12",
      "host" => "198.51.100.12",
      "ssh_port" => 22_012,
      "local_ollama_url" => "http://127.0.0.1:11452",
      "status" => "active"
    }
    manager = build_manager

    manager.start(worker_indices: [12], wait_seconds: 1, poll_seconds: 0.01)
    command = @process.spawns.fetch(0).fetch(:command)
    assert_includes command, "127.0.0.1:11452:127.0.0.1:11434"
    assert_includes command, "root@198.51.100.12"
    assert_equal "healthy", manager.status(worker_indices: [12]).first.fetch("health_status")

    manager.stop(worker_indices: [12])
    assert_includes @out.string, "Stopped: burst_12 tunnel"
  end

  def test_start_refuses_unmanaged_occupied_local_port_without_spawning_that_worker
    manager = build_manager(ports: FakePorts.new([11_442]))
    error = assert_raises(LocalModelEvaluation::RunpodTunnels::Error) do
      manager.start(worker_indices: [2], wait_seconds: 0)
    end
    assert_includes error.message, "local port 11442 is already in use by an unmanaged process"
    assert_empty @process.spawns
  end

  def test_partial_health_failure_preserves_healthy_tunnels_and_records_failure
    health = FakeHealth.new("http://127.0.0.1:11442" => false)
    manager = build_manager(health: health)
    error = assert_raises(LocalModelEvaluation::RunpodTunnels::Error) do
      manager.start(worker_indices: [1, 2], wait_seconds: 0.03, poll_seconds: 0.01)
    end
    assert_includes error.message, "burst_2"
    root = File.join(@repo, "output", "runpod-fleets", @fleet.fetch("fleet_id"), "tunnels")
    state = JSON.parse(File.read(File.join(root, "tunnels.json")))
    by_index = state.fetch("workers").to_h { |w| [w.fetch("index"), w] }
    assert_equal "healthy", by_index.fetch(1).fetch("health_status")
    assert_equal "unhealthy", by_index.fetch(2).fetch("health_status")
    assert @process.alive?(by_index.fetch(1).fetch("pid"))
    assert @process.alive?(by_index.fetch(2).fetch("pid"))
  end

  def test_status_health_checks_live_processes_and_marks_dead_pid_stale
    manager = build_manager
    state = manager.start(worker_indices: [1, 2], wait_seconds: 1, poll_seconds: 0.01)
    pid2 = state.fetch("workers").find { |w| w["index"] == 2 }.fetch("pid")
    @process.kill(pid2)

    rows = manager.status(worker_indices: [1, 2])
    by = rows.to_h { |row| [row.fetch("index"), row] }
    assert_equal "running", by.fetch(1).fetch("process_status")
    assert_equal "healthy", by.fetch(1).fetch("health_status")
    assert_equal "stale", by.fetch(2).fetch("process_status")
    assert_equal "unhealthy", by.fetch(2).fetch("health_status")
    output = manager.render_status(rows)
    assert_includes output, "HEALTHY"
    assert_includes output, "STALE"
  end

  def test_repair_restarts_only_live_unhealthy_tunnel_and_preserves_healthy_peer
    checks = 0
    health = FakeHealth.new(
      "http://127.0.0.1:11442" => lambda do
        checks += 1
        checks == 2 ? false : true
      end
    )
    manager = build_manager(health: health)
    initial = manager.start(worker_indices: [1, 2], wait_seconds: 1, poll_seconds: 0.01)
    initial_by = initial.fetch("workers").to_h { |worker| [worker.fetch("index"), worker] }
    pid1 = initial_by.fetch(1).fetch("pid")
    pid2 = initial_by.fetch(2).fetch("pid")

    rows = manager.repair(worker_indices: [1, 2], wait_seconds: 1, poll_seconds: 0.01)
    by = rows.to_h { |row| [row.fetch("index"), row] }

    assert_equal 3, @process.spawns.length
    assert_equal pid1, by.fetch(1).fetch("pid")
    refute_equal pid2, by.fetch(2).fetch("pid")
    assert_equal [[pid2, 3.0]], @process.terminated
    assert_equal ["healthy"], rows.map { |row| row.fetch("health_status") }.uniq
    assert_includes @out.string, "Repairing tunnel(s): burst_2"
    assert_includes @out.string, "Tunnel repair complete: 2/2 selected workers healthy."
  end

  def test_repair_refuses_pid_identity_mismatch_without_restarting_anything
    manager = build_manager
    state = manager.start(worker_indices: [1], wait_seconds: 1, poll_seconds: 0.01)
    pid = state.fetch("workers").first.fetch("pid")
    @process.mismatch(pid)

    error = assert_raises(LocalModelEvaluation::RunpodTunnels::Error) do
      manager.repair(worker_indices: [1], wait_seconds: 1, poll_seconds: 0.01)
    end

    assert_includes error.message, "managed pid identity does not match"
    assert_equal 1, @process.spawns.length
    assert_empty @process.terminated
    assert @process.alive?(pid)
  end

  def test_stop_verifies_process_identity_before_killing
    manager = build_manager
    state = manager.start(worker_indices: [1, 2], wait_seconds: 1, poll_seconds: 0.01)
    pid1 = state.fetch("workers").find { |w| w["index"] == 1 }.fetch("pid")
    pid2 = state.fetch("workers").find { |w| w["index"] == 2 }.fetch("pid")
    @process.mismatch(pid2)

    error = assert_raises(LocalModelEvaluation::RunpodTunnels::Error) do
      manager.stop(worker_indices: [1, 2])
    end
    assert_includes error.message, "refusing to kill pid #{pid2}"
    assert_equal [[pid1, 3.0]], @process.terminated
    refute @process.alive?(pid1)
    assert @process.alive?(pid2)

    root = File.join(@repo, "output", "runpod-fleets", @fleet.fetch("fleet_id"), "tunnels")
    persisted = JSON.parse(File.read(File.join(root, "tunnels.json")))
    by = persisted.fetch("workers").to_h { |w| [w.fetch("index"), w] }
    assert_nil by.fetch(1)["pid"]
    assert_equal "stopped", by.fetch(1).fetch("process_status")
    assert_equal "mismatch", by.fetch(2).fetch("process_status")
  end

  def test_only_current_fleet_tunnel_state_is_considered
    stale_root = File.join(@repo, "output", "runpod-fleets", "20260828T000000Z-old", "tunnels")
    FileUtils.mkdir_p(stale_root)
    File.write(File.join(stale_root, "tunnels.json"), JSON.generate({"fleet_id"=>"20260828T000000Z-old","workers"=>[{"index"=>1,"pid"=>9999}]}))

    rows = build_manager.status(worker_indices: [1])
    assert_equal "missing", rows.first.fetch("process_status")
    assert_equal "missing", rows.first.fetch("health_status")
  end
end
