# frozen_string_literal: true

require_relative "test_helper"

class RunpodDispatcherTest < Minitest::Test
  Health = Struct.new(:healthy, :detail, keyword_init: true)

  class FakeFleetState
    attr_reader :fleet

    def initialize(worker_count)
      @fleet = {
        "fleet_id" => "20260905T120000Z-podabc",
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

  class WorkerDiesAfterSelectionFleetState < FakeFleetState
    def initialize(worker_count, failed_index)
      super(worker_count)
      @failed_index = failed_index
      @reads = 0
      @failure_mutex = Mutex.new
    end

    def current
      @failure_mutex.synchronize do
        @reads += 1
        if @reads > 1
          worker = @fleet.fetch("workers").find { |candidate| candidate.fetch("index") == @failed_index }
          worker["status"] = "destroyed"
        end
        super
      end
    end
  end

  class HealthyEndpoints
    def check(_endpoint)
      Health.new(healthy: true)
    end
  end

  class TrackingRunner
    attr_reader :calls, :max_active_by_worker, :environments

    def initialize(fail_ids: [], after: nil)
      @fail_ids = fail_ids
      @after = after
      @calls = []
      @environments = {}
      @active_by_worker = Hash.new(0)
      @max_active_by_worker = Hash.new(0)
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
      end
      sleep 0.003
      File.write(stdout_path, "#{job_id} via #{env.fetch('LME_OLLAMA_URL')} in #{chdir}\n")
      File.write(stderr_path, @fail_ids.include?(job_id) ? "simulated failure\n" : "")
      @fail_ids.include?(job_id) ? 7 : 0
    ensure
      @mutex.synchronize { @active_by_worker[worker] -= 1 } if worker
      @after&.call(job_id)
    end
  end

  def setup
    @tmp = Dir.mktmpdir("lme-runpod-dispatcher-")
  end

  def teardown
    FileUtils.remove_entry(@tmp) if @tmp && File.exist?(@tmp)
  end

  def test_twelve_jobs_execute_exactly_once_without_overlapping_a_worker
    [4, 6, 8, 12].each do |worker_count|
      fleet_state = FakeFleetState.new(worker_count)
      runner = TrackingRunner.new
      dispatcher = build_dispatcher(fleet_state, runner, "twelve-on-#{worker_count}")

      summary = dispatcher.run(jobs: jobs(12), worker_indices: (1..worker_count).to_a)

      assert_equal "completed", summary.fetch("status")
      assert_equal 12, summary.fetch("completed_count")
      assert_equal 0, summary.fetch("not_started_count")
      assert_equal jobs(12).map { |job| job.fetch("job_id") }.sort, runner.calls.sort
      assert runner.max_active_by_worker.values.all? { |maximum| maximum == 1 },
             "a worker ran overlapping jobs with #{worker_count} workers"
    end
  end

  def test_fewer_jobs_than_workers_execute_once
    fleet_state = FakeFleetState.new(6)
    runner = TrackingRunner.new
    dispatcher = build_dispatcher(fleet_state, runner, "three-on-six")

    summary = dispatcher.run(jobs: jobs(3), worker_indices: (1..6).to_a)

    assert_equal "completed", summary.fetch("status")
    assert_equal 3, summary.fetch("completed_count")
    assert_equal %w[job-01 job-02 job-03], runner.calls.sort
    assert runner.max_active_by_worker.values.all? { |maximum| maximum == 1 }
  end

  def test_workload_failure_preserves_all_job_evidence_and_continues
    fleet_state = FakeFleetState.new(2)
    runner = TrackingRunner.new(fail_ids: ["job-02"])
    dispatcher = build_dispatcher(fleet_state, runner, "workload-failure")

    summary = dispatcher.run(jobs: jobs(5), worker_indices: [1, 2])

    assert_equal "workload_failed", summary.fetch("status")
    assert_equal 4, summary.fetch("completed_count")
    assert_equal 1, summary.fetch("failed_count")
    assert_equal 0, summary.fetch("not_started_count")
    assert_equal 5, runner.calls.uniq.length
    failed = JSON.parse(File.read(File.join(dispatcher.output_dir, "jobs", "job-02", "metadata.json")))
    assert_equal "failed", failed.fetch("status")
    assert_equal 7, failed.fetch("exit_status")
    assert_equal "simulated failure\n", File.read(File.join(dispatcher.output_dir, failed.fetch("stderr_path")))
    assert File.file?(File.join(dispatcher.output_dir, "jobs", "job-01", "stdout.log"))
  end

  def test_infrastructure_failure_quarantines_only_worker_and_preserves_completion
    fleet_state = FakeFleetState.new(1)
    runner = TrackingRunner.new(after: lambda do |job_id|
      fleet_state.fleet.fetch("workers").first["status"] = "destroyed" if job_id == "job-01"
    end)
    dispatcher = build_dispatcher(fleet_state, runner, "infrastructure-failure")

    summary = dispatcher.run(jobs: jobs(3), worker_indices: [1])

    assert_equal "infrastructure_failed", summary.fetch("status")
    assert_equal 1, summary.fetch("completed_count")
    assert_equal 2, summary.fetch("not_started_count")
    assert_equal ["job-01"], runner.calls
    assert_includes summary.fetch("infrastructure_failures").first.fetch("error"), "is not active"
    assert File.file?(File.join(dispatcher.output_dir, "jobs", "job-01", "metadata.json"))
  end

  def test_one_worker_failure_is_quarantined_while_other_fifteen_finish_queue
    fleet_state = WorkerDiesAfterSelectionFleetState.new(16, 16)
    runner = TrackingRunner.new
    dispatcher = build_dispatcher(fleet_state, runner, "quarantine-one-of-sixteen")

    summary = dispatcher.run(jobs: jobs(64), worker_indices: (1..16).to_a)

    assert_equal "completed", summary.fetch("status")
    assert_equal 64, summary.fetch("completed_count")
    assert_equal 0, summary.fetch("failed_count")
    assert_equal 0, summary.fetch("not_started_count")
    assert_equal 64, runner.calls.length
    assert_equal 64, runner.calls.uniq.length
    refute_includes runner.max_active_by_worker.keys, 16
    failures = summary.fetch("infrastructure_failures")
    assert_equal [16], failures.map { |failure| failure.fetch("worker_index") }
    assert_includes failures.first.fetch("error"), "is not active"
  end

  def test_existing_output_resumes_only_unstarted_jobs_and_rebuilds_summary
    fleet_state = FakeFleetState.new(1)
    first_runner = TrackingRunner.new(after: lambda do |job_id|
      fleet_state.fleet.fetch("workers").first["status"] = "destroyed" if job_id == "job-01"
    end)
    first_dispatcher = build_dispatcher(fleet_state, first_runner, "resume-after-infrastructure-failure")

    first_summary = first_dispatcher.run(jobs: jobs(4), worker_indices: [1])
    manifest_before = File.read(File.join(first_dispatcher.output_dir, "manifest.json"))
    job_one_before = File.read(File.join(first_dispatcher.output_dir, "jobs", "job-01", "metadata.json"))

    assert_equal "infrastructure_failed", first_summary.fetch("status")
    assert_equal %w[job-02 job-03 job-04], first_summary.fetch("not_started_job_ids")

    replacement_fleet = FakeFleetState.new(16)
    replacement_fleet.fleet["fleet_id"] = "20260905T130000Z-replacement"
    resume_runner = TrackingRunner.new
    resumed = build_dispatcher(replacement_fleet, resume_runner, "resume-after-infrastructure-failure")
    resumed_summary = resumed.run(jobs: jobs(4), worker_indices: (1..16).to_a)

    assert_equal "completed", resumed_summary.fetch("status")
    assert_equal "20260905T130000Z-replacement", resumed_summary.fetch("fleet_id")
    assert_equal 4, resumed_summary.fetch("completed_count")
    assert_equal 0, resumed_summary.fetch("failed_count")
    assert_equal 0, resumed_summary.fetch("not_started_count")
    assert_equal %w[job-02 job-03 job-04], resume_runner.calls.sort
    assert_equal manifest_before, File.read(File.join(resumed.output_dir, "manifest.json"))
    assert_equal job_one_before, File.read(File.join(resumed.output_dir, "jobs", "job-01", "metadata.json"))
  end

  def test_resume_preserves_failed_jobs_and_does_not_retry_them
    fleet_state = FakeFleetState.new(1)
    first_runner = TrackingRunner.new(fail_ids: ["job-02"], after: lambda do |job_id|
      fleet_state.fleet.fetch("workers").first["status"] = "destroyed" if job_id == "job-02"
    end)
    first_dispatcher = build_dispatcher(fleet_state, first_runner, "resume-with-workload-failure")

    first_summary = first_dispatcher.run(jobs: jobs(4), worker_indices: [1])

    assert_equal "infrastructure_failed", first_summary.fetch("status")
    assert_equal 1, first_summary.fetch("completed_count")
    assert_equal 1, first_summary.fetch("failed_count")
    assert_equal %w[job-03 job-04], first_summary.fetch("not_started_job_ids")

    fleet_state.fleet.fetch("workers").first["status"] = "active"
    resume_runner = TrackingRunner.new
    resumed = build_dispatcher(fleet_state, resume_runner, "resume-with-workload-failure")
    resumed_summary = resumed.run(jobs: jobs(4), worker_indices: [1])

    assert_equal "workload_failed", resumed_summary.fetch("status")
    assert_equal 3, resumed_summary.fetch("completed_count")
    assert_equal 1, resumed_summary.fetch("failed_count")
    assert_equal %w[job-03 job-04], resume_runner.calls
  end

  def test_resume_rejects_changed_job_plan_before_running_any_job
    fleet_state = FakeFleetState.new(1)
    first_runner = TrackingRunner.new
    first_dispatcher = build_dispatcher(fleet_state, first_runner, "resume-plan-mismatch")
    first_dispatcher.run(jobs: jobs(2), worker_indices: [1])

    changed_jobs = jobs(2)
    changed_jobs.last["argv"] = ["different-workload", "2"]
    resume_runner = TrackingRunner.new
    resumed = build_dispatcher(fleet_state, resume_runner, "resume-plan-mismatch")

    error = assert_raises(LocalModelEvaluation::RunpodDispatcher::Error) do
      resumed.run(jobs: changed_jobs, worker_indices: [1])
    end

    assert_includes error.message, "manifest does not match requested jobs"
    assert_empty resume_runner.calls
  end

  def test_resume_refuses_ambiguous_running_job
    fleet_state = FakeFleetState.new(1)
    first_runner = TrackingRunner.new
    first_dispatcher = build_dispatcher(fleet_state, first_runner, "resume-running")
    first_dispatcher.run(jobs: jobs(1), worker_indices: [1])

    metadata_path = File.join(first_dispatcher.output_dir, "jobs", "job-01", "metadata.json")
    metadata = JSON.parse(File.read(metadata_path))
    metadata["status"] = "running"
    File.write(metadata_path, JSON.pretty_generate(metadata) + "\n")

    resume_runner = TrackingRunner.new
    resumed = build_dispatcher(fleet_state, resume_runner, "resume-running")
    error = assert_raises(LocalModelEvaluation::RunpodDispatcher::Error) do
      resumed.run(jobs: jobs(1), worker_indices: [1])
    end

    assert_includes error.message, "recorded as running"
    assert_empty resume_runner.calls
  end

  def test_generic_identity_and_endpoint_are_injected_without_shell_interpolation
    fleet_state = FakeFleetState.new(16)
    runner = TrackingRunner.new
    dispatcher = build_dispatcher(fleet_state, runner, "worker-sixteen")
    job = {
      "job_id" => "portable-job",
      "argv" => ["fake-workload", "argument with spaces", "; not shell"],
      "env" => { "WORKLOAD_SETTING" => "kept" }
    }

    summary = dispatcher.run(jobs: [job], worker_indices: [16])

    assert_equal "completed", summary.fetch("status")
    env = runner.environments.fetch("portable-job")
    assert_equal "portable-job", env.fetch("LME_JOB_ID")
    assert_equal "16", env.fetch("LME_WORKER_INDEX")
    assert_equal "http://127.0.0.1:11456", env.fetch("LME_OLLAMA_URL")
    assert_equal "kept", env.fetch("WORKLOAD_SETTING")
    metadata = summary.fetch("jobs").first
    assert_equal 16, metadata.fetch("worker_index")
    assert_equal "http://127.0.0.1:11456", metadata.fetch("worker_url")
  end

  def test_affinity_grouping_is_opt_in_stable_and_preserves_fifo_within_each_group
    mixed_jobs = [
      { "job_id" => "a-1", "argv" => ["fake-workload", "a-1"], "env" => {}, "affinity" => "model:a" },
      { "job_id" => "b-1", "argv" => ["fake-workload", "b-1"], "env" => {}, "affinity" => "model:b" },
      { "job_id" => "a-2", "argv" => ["fake-workload", "a-2"], "env" => {}, "affinity" => "model:a" },
      { "job_id" => "b-2", "argv" => ["fake-workload", "b-2"], "env" => {}, "affinity" => "model:b" },
      { "job_id" => "plain", "argv" => ["fake-workload", "plain"], "env" => {} }
    ]
    fleet_state = FakeFleetState.new(1)

    fifo_runner = TrackingRunner.new
    fifo = build_dispatcher(fleet_state, fifo_runner, "affinity-fifo")
    fifo.run(jobs: mixed_jobs, worker_indices: [1])

    assert_equal %w[a-1 b-1 a-2 b-2 plain], fifo_runner.calls
    fifo_manifest = JSON.parse(File.read(File.join(fifo.output_dir, "manifest.json")))
    refute fifo_manifest.key?("affinity_grouping")
    assert_equal "model:a", fifo_manifest.fetch("jobs").first.fetch("affinity")

    grouped_runner = TrackingRunner.new
    grouped = build_dispatcher(fleet_state, grouped_runner, "affinity-grouped")
    grouped.run(jobs: mixed_jobs, worker_indices: [1], group_by_affinity: true)

    assert_equal %w[a-1 a-2 b-1 b-2 plain], grouped_runner.calls
    grouped_manifest = JSON.parse(File.read(File.join(grouped.output_dir, "manifest.json")))
    assert_equal true, grouped_manifest.fetch("affinity_grouping")
    assert_equal(
      ["model:a", "model:b", "model:a", "model:b", nil],
      grouped_manifest.fetch("jobs").map { |job| job["affinity"] }
    )
  end

  def test_resume_refuses_to_change_affinity_grouping_mode
    affinity_jobs = [
      { "job_id" => "a-1", "argv" => ["fake-workload", "a-1"], "env" => {}, "affinity" => "model:a" },
      { "job_id" => "b-1", "argv" => ["fake-workload", "b-1"], "env" => {}, "affinity" => "model:b" }
    ]
    fleet_state = FakeFleetState.new(1)
    first_runner = TrackingRunner.new
    first = build_dispatcher(fleet_state, first_runner, "affinity-resume-mode")
    first.run(jobs: affinity_jobs, worker_indices: [1], group_by_affinity: true)

    resume_runner = TrackingRunner.new
    resumed = build_dispatcher(fleet_state, resume_runner, "affinity-resume-mode")
    error = assert_raises(LocalModelEvaluation::RunpodDispatcher::Error) do
      resumed.run(jobs: affinity_jobs, worker_indices: [1])
    end

    assert_includes error.message, "affinity grouping does not match requested dispatch"
    assert_empty resume_runner.calls
  end

  def test_affinity_must_be_a_bounded_non_empty_string
    fleet_state = FakeFleetState.new(1)
    dispatcher = build_dispatcher(fleet_state, TrackingRunner.new, "invalid-affinity")
    invalid_job = {
      "job_id" => "bad-affinity",
      "argv" => ["fake-workload"],
      "env" => {},
      "affinity" => ""
    }

    error = assert_raises(LocalModelEvaluation::RunpodDispatcher::Error) do
      dispatcher.run(jobs: [invalid_job], worker_indices: [1], group_by_affinity: true)
    end
    assert_includes error.message, "affinity must be a non-empty string"
  end

  private

  def jobs(count)
    (1..count).map do |index|
      { "job_id" => format("job-%02d", index), "argv" => ["fake-workload", index.to_s], "env" => {} }
    end
  end

  def build_dispatcher(fleet_state, runner, name)
    LocalModelEvaluation::RunpodDispatcher.new(
      fleet_state:,
      output_dir: File.join(@tmp, name),
      repo_root: @tmp,
      out: StringIO.new,
      endpoint_checker: HealthyEndpoints.new,
      command_runner: runner
    )
  end
end
