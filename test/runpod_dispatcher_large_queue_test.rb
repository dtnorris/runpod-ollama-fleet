# frozen_string_literal: true

require_relative "test_helper"

class RunpodDispatcherLargeQueueTest < Minitest::Test
  Health = Struct.new(:healthy, :detail, keyword_init: true)

  class FakeFleetState
    attr_reader :fleet

    def initialize(worker_count)
      @fleet = {
        "fleet_id" => "20260913T200000Z-large-queue",
        "status" => "active",
        "worker_count" => worker_count,
        "workers" => (1..worker_count).map do |index|
          {
            "index" => index,
            "pod_id" => "pod_#{index}",
            "status" => "active",
            "local_ollama_url" => "http://127.0.0.1:#{11_440 + index}"
          }
        end
      }
    end

    def current
      Marshal.load(Marshal.dump(@fleet))
    end
  end

  class StaticFleetState < FakeFleetState
    def current
      @fleet
    end
  end

  class HealthyEndpoints
    def check(_endpoint)
      Health.new(healthy: true)
    end
  end

  class TrackingRunner
    attr_reader :calls, :max_active_by_worker, :environments

    def initialize(delay: 0.0, barrier_size: nil, write_logs: true)
      @delay = delay
      @barrier_size = barrier_size
      @write_logs = write_logs
      @calls = []
      @environments = {}
      @active_by_worker = Hash.new(0)
      @max_active_by_worker = Hash.new(0)
      @barrier_workers = {}
      @barrier = ConditionVariable.new
      @mutex = Mutex.new
    end

    def run(argv:, env:, stdout_path:, stderr_path:, chdir:)
      job_id = env.fetch("LME_JOB_ID")
      worker = Integer(env.fetch("LME_WORKER_INDEX"))
      @mutex.synchronize do
        @calls << job_id
        @environments[job_id] = env.dup
        @active_by_worker[worker] += 1
        @max_active_by_worker[worker] = [@max_active_by_worker[worker], @active_by_worker[worker]].max
        wait_for_first_wave(worker) if @barrier_size
      end
      sleep @delay if @delay.positive?
      if @write_logs
        File.write(stdout_path, "#{job_id} via #{env.fetch('LME_OLLAMA_URL')} in #{chdir}\n")
        File.write(stderr_path, "")
      end
      0
    ensure
      @mutex.synchronize { @active_by_worker[worker] -= 1 } if worker
    end

    private

    def wait_for_first_wave(worker)
      return if @barrier_workers.length >= @barrier_size

      @barrier_workers[worker] = true
      if @barrier_workers.length >= @barrier_size
        @barrier.broadcast
      else
        @barrier.wait(@mutex) while @barrier_workers.length < @barrier_size
      end
    end
  end

  class SchedulingOnlyDispatcher < LocalModelEvaluation::RunpodDispatcher
    private

    def execute(job, worker)
      job_id = job.fetch("job_id")
      index = Integer(worker.fetch("index"))
      endpoint = worker.fetch("local_ollama_url")
      env = job.fetch("env").merge(
        "LME_JOB_ID" => job_id,
        "LME_WORKER_INDEX" => index.to_s,
        "LME_OLLAMA_URL" => endpoint
      )
      exit_status = @command_runner.run(
        argv: job.fetch("argv"),
        env:,
        stdout_path: File::NULL,
        stderr_path: File::NULL,
        chdir: @repo_root
      )
      result = {
        "job_id" => job_id,
        "worker_index" => index,
        "worker_url" => endpoint,
        "status" => exit_status.zero? ? "completed" : "failed",
        "exit_status" => exit_status
      }
      @state_mutex.synchronize { @results << result }
    end
  end

  class CancellableRunner
    attr_reader :calls

    def initialize
      @calls = []
      @cancelled = false
      @mutex = Mutex.new
      @started = ConditionVariable.new
      @release = ConditionVariable.new
    end

    def run(argv:, env:, stdout_path:, stderr_path:, chdir:)
      job_id = env.fetch("LME_JOB_ID")
      @mutex.synchronize do
        @calls << job_id
        @started.broadcast
        @release.wait(@mutex) until @cancelled
      end
      File.write(stdout_path, "cancelled #{job_id} in #{chdir}\n")
      File.write(stderr_path, "cancelled\n")
      143
    end

    def wait_until_started(count)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 2
      @mutex.synchronize do
        while @calls.length < count
          remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
          raise "timed out waiting for #{count} active jobs" unless remaining.positive?

          @started.wait(@mutex, remaining)
        end
      end
    end

    def cancel_all
      @mutex.synchronize do
        @cancelled = true
        @release.broadcast
      end
    end
  end

  def setup
    @tmp = Dir.mktmpdir("lme-runpod-large-queue-")
  end

  def teardown
    FileUtils.remove_entry(@tmp) if @tmp && File.exist?(@tmp)
  end

  def test_system_command_runner_cancel_all_terminates_active_process_group
    script = File.join(@tmp, "blocking-workload.sh")
    marker = File.join(@tmp, "workload-ready")
    File.write(script, <<~'SH')
      #!/bin/sh
      set -eu
      printf ready > "$1"
      exec sleep 30
    SH
    FileUtils.chmod(0o755, script)

    runner = LocalModelEvaluation::RunpodDispatcher::SystemCommandRunner.new
    thread = Thread.new do
      runner.run(
        argv: [script, marker],
        env: {},
        stdout_path: File.join(@tmp, "blocking.stdout"),
        stderr_path: File.join(@tmp, "blocking.stderr"),
        chdir: @tmp
      )
    end

    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 2
    until File.file?(marker)
      flunk "blocking workload did not start" if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
      sleep 0.01
    end

    runner.cancel_all
    assert_equal 143, thread.value
  ensure
    runner&.cancel_all
    thread&.join(1)
  end

  def test_nine_hundred_jobs_complete_exactly_once_across_sixteen_workers
    fleet_state = StaticFleetState.new(16)
    runner = TrackingRunner.new(barrier_size: 16, write_logs: false)
    dispatcher = build_dispatcher(
      fleet_state,
      runner,
      "nine-hundred-on-sixteen",
      dispatcher_class: SchedulingOnlyDispatcher
    )
    planned_jobs = jobs(900)

    summary = dispatcher.run(jobs: planned_jobs, worker_indices: (1..16).to_a)

    assert_equal "completed", summary.fetch("status")
    assert_equal 900, summary.fetch("job_count")
    assert_equal 900, summary.fetch("completed_count")
    assert_equal 0, summary.fetch("failed_count")
    assert_equal 0, summary.fetch("not_started_count")
    assert_equal planned_jobs.map { |job| job.fetch("job_id") }.sort, runner.calls.sort
    assert_equal 900, runner.calls.uniq.length
    assert_equal(
      (1..16).to_a,
      runner.environments.values.map { |env| Integer(env.fetch("LME_WORKER_INDEX")) }.uniq.sort
    )
    assert runner.max_active_by_worker.values.all? { |maximum| maximum == 1 }
    assert_equal 900, summary.fetch("jobs").length

    manifest = JSON.parse(File.read(File.join(dispatcher.output_dir, "manifest.json")))
    persisted_summary = JSON.parse(File.read(File.join(dispatcher.output_dir, "summary.json")))
    assert_equal 900, manifest.fetch("job_count")
    assert_equal 900, persisted_summary.fetch("completed_count")
  end

  def test_unexpected_worker_loop_crash_is_quarantined_and_queue_resumes
    fleet_state = FakeFleetState.new(1)
    planned_jobs = jobs(3)
    first_runner = TrackingRunner.new
    dispatcher = build_dispatcher(fleet_state, first_runner, "worker-loop-crash")
    dispatcher.define_singleton_method(:worker_loop) do |_queue, _fleet_id, _worker|
      raise "simulated worker-loop crash"
    end

    first_summary = dispatcher.run(jobs: planned_jobs, worker_indices: [1])

    assert_equal "infrastructure_failed", first_summary.fetch("status")
    assert_equal 3, first_summary.fetch("not_started_count")
    assert_empty first_runner.calls
    failure = first_summary.fetch("infrastructure_failures").fetch(0)
    assert_includes failure.fetch("error"), "dispatcher worker loop crashed: RuntimeError: simulated worker-loop crash"

    resume_runner = TrackingRunner.new
    resumed = build_dispatcher(fleet_state, resume_runner, "worker-loop-crash")
    resumed_summary = resumed.run(jobs: planned_jobs, worker_indices: [1])

    assert_equal "completed", resumed_summary.fetch("status")
    assert_equal 3, resumed_summary.fetch("completed_count")
    assert_equal planned_jobs.map { |job| job.fetch("job_id") }, resume_runner.calls
  end

  def test_interrupt_cancels_active_work_stops_new_claims_and_persists_summary
    fleet_state = FakeFleetState.new(2)
    runner = CancellableRunner.new
    dispatcher = build_dispatcher(fleet_state, runner, "interrupt-dispatch")
    planned_jobs = jobs(5)
    observed_interrupt = nil
    dispatch_thread = Thread.new do
      begin
        dispatcher.run(jobs: planned_jobs, worker_indices: [1, 2])
      rescue Interrupt => e
        observed_interrupt = e
      end
    end

    runner.wait_until_started(2)
    dispatch_thread.raise(Interrupt, "simulated interrupt")
    dispatch_thread.join

    assert_instance_of Interrupt, observed_interrupt
    assert_equal 2, runner.calls.length
    summary = JSON.parse(File.read(File.join(dispatcher.output_dir, "summary.json")))
    assert_equal "interrupted", summary.fetch("status")
    assert_equal true, summary.fetch("interrupted")
    assert_equal 2, summary.fetch("failed_count")
    assert_equal 3, summary.fetch("not_started_count")
  end

  def test_resume_rejects_completed_metadata_missing_durable_evidence
    fleet_state = FakeFleetState.new(1)
    first = build_dispatcher(fleet_state, TrackingRunner.new, "resume-incomplete-evidence")
    first.run(jobs: jobs(1), worker_indices: [1])

    metadata_path = File.join(first.output_dir, "jobs", "job-0001", "metadata.json")
    metadata = JSON.parse(File.read(metadata_path))
    metadata.delete("worker_url")
    File.write(metadata_path, JSON.pretty_generate(metadata) + "\n")

    resume_runner = TrackingRunner.new
    resumed = build_dispatcher(fleet_state, resume_runner, "resume-incomplete-evidence")
    error = assert_raises(LocalModelEvaluation::RunpodDispatcher::Error) do
      resumed.run(jobs: jobs(1), worker_indices: [1])
    end

    assert_includes error.message, "missing durable evidence: worker_url"
    assert_empty resume_runner.calls
  end

  def test_summary_fails_closed_on_duplicate_result_identity
    fleet_state = FakeFleetState.new(1)
    dispatcher = build_dispatcher(fleet_state, TrackingRunner.new, "duplicate-result-integrity")
    planned_jobs = jobs(2)
    duplicate = {
      "job_id" => "job-0001",
      "worker_index" => 1,
      "worker_url" => "http://127.0.0.1:11441",
      "started_at_utc" => Time.now.utc.iso8601,
      "finished_at_utc" => Time.now.utc.iso8601,
      "elapsed_seconds" => 0.1,
      "status" => "completed",
      "exit_status" => 0,
      "stdout_path" => "jobs/job-0001/stdout.log",
      "stderr_path" => "jobs/job-0001/stderr.log"
    }
    dispatcher.instance_variable_set(:@results, [duplicate, duplicate.dup])

    summary = dispatcher.send(
      :build_summary,
      fleet_id: fleet_state.fleet.fetch("fleet_id"),
      jobs: planned_jobs,
      workers: fleet_state.fleet.fetch("workers"),
      started_at: Time.now.utc
    )

    assert_equal "integrity_failed", summary.fetch("status")
    assert_equal 1, summary.fetch("not_started_count")
    assert_equal ["job-0002"], summary.fetch("not_started_job_ids")
    assert_includes summary.fetch("integrity_errors"), "duplicate result job_id(s): job-0001"
    assert_equal 0, summary.fetch("completed_count")
  end

  private

  def jobs(count)
    (1..count).map do |index|
      {
        "job_id" => format("job-%04d", index),
        "argv" => ["fake-workload", index.to_s],
        "env" => {}
      }
    end
  end

  def build_dispatcher(fleet_state, runner, name, dispatcher_class: LocalModelEvaluation::RunpodDispatcher)
    dispatcher_class.new(
      fleet_state:,
      output_dir: File.join(@tmp, name),
      repo_root: @tmp,
      out: StringIO.new,
      endpoint_checker: HealthyEndpoints.new,
      command_runner: runner
    )
  end
end
