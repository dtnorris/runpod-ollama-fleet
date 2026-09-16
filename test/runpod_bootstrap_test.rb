# frozen_string_literal: true

require "minitest/autorun"
require "stringio"
require_relative "../lib/local_model_evaluation/runpod_bootstrap"

module LocalModelEvaluation
  class RunpodFleetState
    class Error < StandardError; end
  end unless const_defined?(:RunpodFleetState)
end

class RunpodBootstrapTest < Minitest::Test
  DIGEST = "a" * 64
  OTHER_DIGEST = "b" * 64

  class FakeFleetState
    attr_reader :root

    def initialize(root:, fleet:)
      @root = root
      @fleet = fleet
    end

    def current
      Marshal.load(Marshal.dump(@fleet))
    end

    def artifact_dir(fleet_id, name)
      raise "wrong fleet" unless fleet_id == @fleet.fetch("fleet_id")
      raise "wrong artifact" unless name.to_s == "bootstrap"

      File.join(@root, fleet_id, "bootstrap")
    end
  end

  class MemoryBootstrapStore
    attr_reader :run_dirs

    def initialize
      @locks = {}
      @current = {}
      @records = {}
      @logs = {}
      @run_dirs = []
    end

    def with_lock(root)
      raise LocalModelEvaluation::BootstrapStore::LockUnavailable if @locks[root]

      @locks[root] = true
      yield
    ensure
      @locks.delete(root)
    end

    def start_run(root:, run_id:)
      run_dir = File.join(root, run_id)
      @current[root] = run_id
      @run_dirs << run_dir
      run_dir
    end

    def record_path(run_dir)
      File.join(run_dir, "bootstrap.json")
    end

    def write_record(path:, record:)
      run_dir = File.dirname(path)
      @records[run_dir] = Marshal.load(Marshal.dump(record))
    end

    def open_worker_log(run_dir:, worker_index:)
      path = File.join(run_dir, "burst_#{worker_index}.log")
      io = StringIO.new
      @logs[path] = io
      LocalModelEvaluation::BootstrapStore::LogTarget.new(path:, io:)
    end

    def close_worker_log(_target)
      nil
    end

    def log_tail(path, max_bytes:)
      text = @logs.fetch(path, StringIO.new).string
      text.byteslice(-[text.bytesize, max_bytes].min, max_bytes).to_s
    end

    def seed_log(path, text)
      @logs[path] = StringIO.new(text)
    end

    def current_run_id(root)
      @current[root]
    end

    def latest_record
      Marshal.load(Marshal.dump(@records.fetch(@run_dirs.last)))
    end

    def log_for(worker_index)
      path = @logs.keys.reverse.find { |candidate| candidate.end_with?("/burst_#{worker_index}.log") }
      path ? @logs.fetch(path).string : nil
    end
  end

  class FakeClock
    attr_reader :now

    def initialize
      @now = 0.0
    end

    def advance(seconds)
      @now += seconds
    end
  end

  class FakeProcessSupervisor
    Status = Struct.new(:exitstatus) do
      def success? = exitstatus == 0
    end

    attr_accessor :scenario
    attr_reader :commands, :signals

    def initialize
      @scenario = :success
      @commands = []
      @signals = []
      @children = {}
      @next_pid = 10_000
    end

    def file?(_path) = true
    def executable?(_path) = true

    def spawn(command:, chdir:, output:)
      worker_index = command.fetch(command.index("--worker") + 1).to_i
      plan = plan_for(worker_index, command)
      raise "fake remote process must not spawn" if plan.fetch(:must_not_run, false)

      output.write(plan.fetch(:output))
      pid = @next_pid
      @next_pid += 1
      @children[pid] = {
        polls: plan.fetch(:polls, 0),
        status: Status.new(plan.fetch(:exitstatus, 0))
      }
      @commands << {command:, chdir:, pid:, worker_index:}
      pid
    end

    def poll(pid)
      child = @children.fetch(pid)
      if child[:polls].positive?
        child[:polls] -= 1
        return nil
      end

      [pid, child.fetch(:status)]
    end

    def signal_group(signal, pid)
      @signals << [signal, pid]
      child = @children[pid]
      return unless child

      child[:polls] = 0
      child[:status] = Status.new(nil)
    end

    def wait(pid)
      @children.delete(pid)
      pid
    end

    private

    def plan_for(worker_index, command)
      case scenario
      when :parallel
        {output: success_output(worker_index, prefix: parallel_prefix(worker_index)), polls: 6}
      when :worker_failure
        if worker_index == 2
          {output: "Pulling gemma4:26b to fast local/root disk.\nsimulated worker failure\n", exitstatus: 7, polls: 2}
        else
          {output: success_output(worker_index), polls: 2}
        end
      when :echo_args
        {
          output: "ARGS=#{command.drop(1).join('|')}\nSTDIN_BYTES=0\n#{success_output(worker_index, context: 262_144)}"
        }
      when :interrupt
        {output: "[1/8] Preflight host, GPU, and required utilities\n", polls: 1_000}
      when :bad_provenance
        {output: success_output(worker_index, digest: OTHER_DIGEST)}
      when :heterogeneous_gpu
        gpu = command.fetch(command.index("--expect-gpu") + 1)
        {output: success_output(worker_index, gpu:)}
      when :must_not_run
        {output: "", must_not_run: true}
      else
        {output: success_output(worker_index)}
      end
    end

    def parallel_prefix(worker_index)
      <<~TEXT
        [1/4] Loading worker #{worker_index} connection settings
        Direct SSH PASS.
        [1/8] Preflight host, GPU, and required utilities
        Pulling gemma4:26b to fast local/root disk.
        pulling blob: 42%
        Copying completed Ollama store into /workspace/ollama-models.
        10.0G 61%
        [6/8] Warm each model and verify context plus full GPU residency
      TEXT
    end

    def success_output(worker_index, digest: DIGEST, context: 131_072, prefix: "", gpu: "NVIDIA A40")
      <<~TEXT
        #{prefix}gemma4:26b verification PASS: context=#{context} and 100% model residency in VRAM.
        LME_PROVENANCE_GPU\t#{gpu}\t46068
        LME_PROVENANCE_MODEL\tgemma4:26b\t#{digest}\t#{context}\t2566893074\t2566893074
        Worker setup PASS.
        Worker #{worker_index} remote setup PASS.
      TEXT
    end
  end

  def setup
    @repo_root = "/virtual/repo"
    @state_root = "/virtual/runpod-fleets"
    @fleet = {
      "fleet_id" => "20260829T200000Z-podabc",
      "status" => "active",
      "fleet_hourly_rate_usd" => 2.20,
      "gpu" => { "id" => "NVIDIA A40", "count_per_worker" => 1 },
      "workers" => (1..3).map do |index|
        {
          "index" => index,
          "name" => "af-lme-burst-#{index}",
          "pod_id" => "pod_#{index}",
          "host" => "198.51.100.#{index}",
          "ssh_port" => 22_000 + index,
          "hourly_rate_usd" => 0.44,
          "status" => "active"
        }
      end
    }
    @fleet_state = FakeFleetState.new(root: @state_root, fleet: @fleet)
    @out = StringIO.new
    @store = MemoryBootstrapStore.new
    @process_supervisor = FakeProcessSupervisor.new
    @clock = FakeClock.new
  end

  def test_parallel_bootstrap_emits_heartbeats_and_writes_only_current_fleet_run
    script = fake_remote_script(<<~'RUBY')
      worker = ARGV[ARGV.index("--worker") + 1]
      puts "[1/4] Loading worker #{worker} connection settings"
      STDOUT.flush
      sleep 0.03
      puts "Direct SSH PASS."
      puts "[1/8] Preflight host, GPU, and required utilities"
      puts "Pulling gemma4:26b to fast local/root disk."
      puts "pulling blob: 42%"
      STDOUT.flush
      sleep 0.03
      puts "Copying completed Ollama store into /workspace/ollama-models."
      puts "10.0G 61%"
      puts "[6/8] Warm each model and verify context plus full GPU residency"
      STDOUT.flush
      sleep 0.03
      puts "gemma4:26b verification PASS: context=131072 and 100% model residency in VRAM."
      puts "[16:09:59] LME_PROVENANCE_GPU\tNVIDIA A40\t46068"
      puts "[16:09:59] LME_PROVENANCE_MODEL\tgemma4:26b\t#{"a" * 64}\t131072\t2566893074\t2566893074"
      puts "Worker setup PASS."
      puts "[16:10:00] Worker #{worker} remote setup PASS."
    RUBY

    stale = File.join(@state_root, "old-fleet", "bootstrap", "old-run", "burst_1.log")
    @store.seed_log(stale, "qwen3.6:27b old stale log\n")

    runner = build_runner(script)
    record = runner.run(
      worker_indices: [1, 2, 3],
      models: ["gemma4:26b"],
      expected_digests: ["gemma4:26b=#{DIGEST}"],
      clean: true,
      heartbeat_seconds: 0.02,
      poll_seconds: 0.005
    )

    assert_equal "passed", record.fetch("status")
    assert_equal 3, record.fetch("workers").count { |worker| worker["status"] == "passed" }
    assert_includes @out.string, "Starting gemma4:26b bootstrap on burst_1"
    assert_includes @out.string, "heartbeat:"
    assert_includes @out.string, "PASS: burst_1 bootstrap"
    assert_includes @out.string, "PASS: burst_2 bootstrap"
    assert_includes @out.string, "PASS: burst_3 bootstrap"
    refute_includes @out.string, "qwen3.6:27b"

    bootstrap_root = File.join(@state_root, @fleet.fetch("fleet_id"), "bootstrap")
    assert_equal 1, @store.run_dirs.length
    assert_equal @store.run_dirs.first.split("/").last, @store.current_run_id(bootstrap_root)
    assert_equal "passed", @store.latest_record.fetch("status")
    (1..3).each do |index|
      log = @store.log_for(index)
      assert_includes log, "gemma4:26b"
      assert_includes log, "remote setup PASS"
    end
  end

  def test_failure_is_visible_and_preserved_without_hiding_successful_workers
    script = fake_remote_script(<<~'RUBY')
      worker = ARGV[ARGV.index("--worker") + 1]
      puts "Pulling gemma4:26b to fast local/root disk."
      STDOUT.flush
      sleep 0.02
      if worker == "2"
        warn "simulated worker failure"
        exit 7
      end
      puts "gemma4:26b verification PASS: context=131072 and 100% model residency in VRAM."
      puts "LME_PROVENANCE_GPU\tNVIDIA A40\t46068"
      puts "LME_PROVENANCE_MODEL\tgemma4:26b\t#{"a" * 64}\t131072\t2566893074\t2566893074"
      puts "Worker setup PASS."
      puts "Worker #{worker} remote setup PASS."
    RUBY

    error = assert_raises(LocalModelEvaluation::RunpodBootstrap::Error) do
      build_runner(script).run(
        worker_indices: [1, 2, 3],
        models: ["gemma4:26b"],
        expected_digests: ["gemma4:26b=#{DIGEST}"],
        heartbeat_seconds: 0.01,
        poll_seconds: 0.005
      )
    end

    assert_includes error.message, "1 worker(s)"
    assert_includes @out.string, "PASS: burst_1 bootstrap"
    assert_includes @out.string, "FAIL: burst_2 bootstrap (exit 7)"
    assert_includes @out.string, "PASS: burst_3 bootstrap"

    record = @store.latest_record
    assert_equal "failed", record.fetch("status")
    statuses = record.fetch("workers").to_h { |worker| [worker.fetch("index"), worker.fetch("status")] }
    assert_equal({ 1 => "passed", 2 => "failed", 3 => "passed" }, statuses)
  end

  def test_builds_exact_remote_command_without_shell_interpolation
    script = fake_remote_script(<<~'RUBY')
      puts "ARGS=#{ARGV.join('|')}"
      puts "Worker setup PASS."
      worker = ARGV[ARGV.index("--worker") + 1]
      puts "Worker #{worker} remote setup PASS."
    RUBY

    record = build_runner(script).run(
      worker_indices: [2],
      models: ["gemma4:26b"],
      expected_digests: ["gemma4:26b=#{DIGEST}"],
      clean: true,
      context: 262_144,
      heartbeat_seconds: 1,
      poll_seconds: 0.005
    )

    assert_equal "passed", record.fetch("status")
    assert_equal(
      [
        script,
        "--worker", "2",
        "--expect-gpu", "NVIDIA A40",
        "--min-vram-gb", "40",
        "--clean",
        "--model", "gemma4:26b",
        "--expect-digest", "gemma4:26b=#{DIGEST}",
        "--context", "262144"
      ],
      @process_supervisor.commands.fetch(0).fetch(:command)
    )
  end


  def test_bootstrap_uses_per_worker_gpu_contracts_in_mixed_fleet
    @fleet.fetch("workers")[1]["gpu_id"] = "NVIDIA RTX A6000"
    script = fake_remote_script("puts 'heterogeneous gpu fixture'\n")

    record = build_runner(script).run(
      worker_indices: [1, 2],
      models: ["gemma4:26b"],
      expected_digests: ["gemma4:26b=#{DIGEST}"],
      poll_seconds: 0.005
    )

    commands = @process_supervisor.commands.to_h do |entry|
      [entry.fetch(:worker_index), entry.fetch(:command)]
    end
    assert_equal "NVIDIA A40", commands.fetch(1).fetch(commands.fetch(1).index("--expect-gpu") + 1)
    assert_equal "NVIDIA RTX A6000", commands.fetch(2).fetch(commands.fetch(2).index("--expect-gpu") + 1)
    assert_nil record.fetch("expected_gpu")
    assert_equal(
      { "1" => "NVIDIA A40", "2" => "NVIDIA RTX A6000" },
      record.fetch("expected_gpus")
    )
    recorded_workers = record.fetch("workers").to_h { |worker| [worker.fetch("index"), worker] }
    assert_equal "NVIDIA A40", recorded_workers.fetch(1).fetch("expected_gpu")
    assert_equal "NVIDIA RTX A6000", recorded_workers.fetch(2).fetch("expected_gpu")
  end

  def test_reuse_existing_is_forwarded_and_recorded_without_clean
    script = fake_remote_script("puts 'reuse existing fixture'\n")

    record = build_runner(script).run(
      worker_indices: [2],
      models: ["gemma4:26b"],
      expected_digests: ["gemma4:26b=#{DIGEST}"],
      reuse_existing: true,
      poll_seconds: 0.005
    )

    command = @process_supervisor.commands.fetch(0).fetch(:command)
    assert_includes command, "--reuse-existing"
    refute_includes command, "--clean"
    assert_equal true, record.fetch("reuse_existing")
  end

  def test_copy_to_workspace_is_forwarded_and_recorded
    script = fake_remote_script("puts 'copy model fixture'\n")

    record = build_runner(script).run(
      worker_indices: [2],
      models: ["gemma4:26b"],
      expected_digests: ["gemma4:26b=#{DIGEST}"],
      copy_to_workspace: true,
      poll_seconds: 0.005
    )

    command = @process_supervisor.commands.fetch(0).fetch(:command)
    assert_includes command, "--copy-to-workspace"
    refute_includes command, "--keep-root-models"
    refute_includes command, "--reuse-existing"
    assert_equal true, record.fetch("copy_to_workspace")
    assert_equal "workspace", record.fetch("model_store_mode")
  end

  def test_keep_root_models_is_forwarded_and_recorded
    script = fake_remote_script("puts 'root model fixture'\n")

    record = build_runner(script).run(
      worker_indices: [2],
      models: ["gemma4:26b"],
      expected_digests: ["gemma4:26b=#{DIGEST}"],
      keep_root_models: true,
      poll_seconds: 0.005
    )

    command = @process_supervisor.commands.fetch(0).fetch(:command)
    assert_includes command, "--keep-root-models"
    refute_includes command, "--reuse-existing"
    assert_equal true, record.fetch("keep_root_models")
  end

  def test_reuse_existing_rejects_clean_before_spawning
    script = fake_remote_script("raise 'must not run'\n")

    error = assert_raises(LocalModelEvaluation::RunpodBootstrap::Error) do
      build_runner(script).run(
        worker_indices: [1],
        models: ["gemma4:26b"],
        expected_digests: ["gemma4:26b=#{DIGEST}"],
        clean: true,
        reuse_existing: true
      )
    end

    assert_includes error.message, "--clean cannot be combined with --reuse-existing"
    assert_empty @process_supervisor.commands
  end

  def test_keep_root_models_rejects_reuse_existing_before_spawning
    script = fake_remote_script("raise 'must not run'\n")

    error = assert_raises(LocalModelEvaluation::RunpodBootstrap::Error) do
      build_runner(script).run(
        worker_indices: [1],
        models: ["gemma4:26b"],
        expected_digests: ["gemma4:26b=#{DIGEST}"],
        reuse_existing: true,
        keep_root_models: true
      )
    end

    assert_includes error.message, "--keep-root-models cannot be combined with --reuse-existing"
    assert_empty @process_supervisor.commands
  end

  def test_keep_root_models_rejects_multiple_models_before_spawning
    script = fake_remote_script("raise 'must not run'\n")

    error = assert_raises(LocalModelEvaluation::RunpodBootstrap::Error) do
      build_runner(script).run(
        worker_indices: [1],
        models: ["gemma4:26b", "qwen3.6:27b"],
        expected_digests: [
          "gemma4:26b=#{DIGEST}",
          "qwen3.6:27b=#{OTHER_DIGEST}"
        ],
        keep_root_models: true
      )
    end

    assert_includes error.message, "--keep-root-models requires exactly one model"
    assert_empty @process_supervisor.commands
  end

  def test_bootstrap_addresses_worker_twelve
    @fleet.fetch("workers") << {
      "index" => 12,
      "name" => "af-lme-burst-12",
      "pod_id" => "pod_12",
      "host" => "198.51.100.12",
      "ssh_port" => 22_012,
      "hourly_rate_usd" => 0.44,
      "status" => "active"
    }
    script = fake_remote_script(<<~'RUBY')
      worker = ARGV[ARGV.index("--worker") + 1]
      puts "LME_PROVENANCE_GPU\tNVIDIA A40\t46068"
      puts "LME_PROVENANCE_MODEL\tgemma4:26b\t#{"a" * 64}\t131072\t2566893074\t2566893074"
      puts "Worker setup PASS."
      puts "Worker #{worker} remote setup PASS."
    RUBY

    record = build_runner(script).run(
      worker_indices: [12],
      models: ["gemma4:26b"],
      expected_digests: ["gemma4:26b=#{DIGEST}"],
      poll_seconds: 0.005
    )

    assert_equal "passed", record.fetch("status")
    assert_equal 12, record.fetch("workers").first.fetch("index")
    assert_includes @out.string, "burst_12"
  end

  def test_refuses_non_active_or_unknown_workers_before_spawning
    @fleet["workers"][1]["status"] = "destroyed"
    script = fake_remote_script("raise 'must not run'\n")
    runner = build_runner(script)

    error = assert_raises(LocalModelEvaluation::RunpodBootstrap::Error) do
      runner.run(worker_indices: [2], models: ["gemma4:26b"])
    end
    assert_includes error.message, "not active"

    error = assert_raises(LocalModelEvaluation::RunpodBootstrap::Error) do
      runner.run(worker_indices: [5], models: ["gemma4:26b"])
    end
    assert_includes error.message, "does not contain worker"
  end

  def test_interrupt_quarantines_children_and_records_interrupted_state
    script = fake_remote_script(<<~'RUBY')
      worker = ARGV[ARGV.index("--worker") + 1]
      puts "[1/8] Preflight host, GPU, and required utilities"
      sleep 30
      puts "Worker #{worker} remote setup PASS."
    RUBY

    runner = build_runner(script, sleeper: ->(_seconds) { raise Interrupt })

    assert_raises(Interrupt) do
      runner.run(
        worker_indices: [1],
        models: ["gemma4:26b"],
        expected_digests: ["gemma4:26b=#{DIGEST}"],
        heartbeat_seconds: 0.05,
        poll_seconds: 0.005
      )
    end

    state = @store.latest_record
    worker = state.fetch("workers").first
    assert_equal "interrupted", state.fetch("status")
    assert_equal "interrupted", worker.fetch("status")
    assert_includes @process_supervisor.signals, ["TERM", worker.fetch("pid")]
    assert_includes @out.string, "Interrupt received; stopping 1 bootstrap process group(s)"
    assert_includes @out.string, "Local bootstrap/SSH process groups stopped"
  end

  def test_requires_exact_digest_for_every_model_before_spawning
    script = fake_remote_script("raise 'must not run'\n")
    runner = build_runner(script)

    error = assert_raises(LocalModelEvaluation::RunpodBootstrap::Error) do
      runner.run(worker_indices: [1], models: ["gemma4:26b"])
    end
    assert_includes error.message, "exact expected digest required"

    error = assert_raises(LocalModelEvaluation::RunpodBootstrap::Error) do
      runner.run(
        worker_indices: [1],
        models: ["gemma4:26b"],
        expected_digests: ["gemma4:26b=deadbeef"]
      )
    end
    assert_includes error.message, "exactly 64 hexadecimal"
  end

  def test_successful_remote_exit_fails_closed_when_provenance_mismatches
    script = fake_remote_script(<<~'RUBY')
      worker = ARGV[ARGV.index("--worker") + 1]
      puts "gemma4:26b verification PASS: context=131072 and 100% model residency in VRAM."
      puts "LME_PROVENANCE_GPU\tNVIDIA A40\t46068"
      puts "LME_PROVENANCE_MODEL\tgemma4:26b\t#{"b" * 64}\t131072\t2566893074\t2566893074"
      puts "Worker setup PASS."
      puts "Worker #{worker} remote setup PASS."
    RUBY

    error = assert_raises(LocalModelEvaluation::RunpodBootstrap::Error) do
      build_runner(script).run(
        worker_indices: [1],
        models: ["gemma4:26b"],
        expected_digests: ["gemma4:26b=#{DIGEST}"],
        poll_seconds: 0.005
      )
    end

    assert_includes error.message, "1 worker(s)"
    assert_includes @out.string, "provenance: gemma4:26b digest mismatch"
  end


  private

  def build_runner(script, sleeper: nil)
    LocalModelEvaluation::RunpodBootstrap.new(
      fleet_state: @fleet_state,
      remote_setup_path: script,
      repo_root: @repo_root,
      out: @out,
      store: @store,
      process_supervisor: @process_supervisor,
      monotonic_clock: -> { @clock.now },
      sleeper: sleeper || ->(seconds) { @clock.advance(seconds) }
    )
  end

  def fake_remote_script(body)
    @process_supervisor.scenario =
      if body.include?("ARGS=#{'#{'}ARGV.join('|')}")
        :echo_args
      elsif body.include?('sleep 30')
        :interrupt
      elsif body.include?('simulated worker failure')
        :worker_failure
      elsif body.include?('"b" * 64')
        :bad_provenance
      elsif body.include?("heterogeneous gpu fixture")
        :heterogeneous_gpu
      elsif body.include?("raise 'must not run'")
        :must_not_run
      elsif body.include?('[1/4] Loading worker')
        :parallel
      else
        :success
      end

    File.join(@repo_root, "fake-remote-#{@process_supervisor.scenario}.sh")
  end
end
