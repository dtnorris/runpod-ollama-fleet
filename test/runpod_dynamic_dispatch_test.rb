# frozen_string_literal: true

require_relative "test_helper"
require_relative "../lib/local_model_evaluation/runpod_dispatch_admission"
require_relative "../lib/local_model_evaluation/runpod_dispatcher"

class RunpodDynamicDispatchTest < Minitest::Test
  Health = Struct.new(:healthy, :detail, keyword_init: true)

  class FakeFleetState
    attr_reader :fleet

    def initialize
      @fleet = {
        "fleet_id" => "20260918T120000Z-dynamic",
        "status" => "active",
        "workers" => (1..2).map do |index|
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

  class HealthyEndpoints
    def check(_endpoint)
      Health.new(healthy: true)
    end
  end

  class SlowRunner
    attr_reader :worker_indices

    def initialize
      @worker_indices = []
      @mutex = Mutex.new
    end

    def run(argv:, env:, stdout_path:, stderr_path:, chdir:)
      index = Integer(env.fetch("LME_WORKER_INDEX"))
      @mutex.synchronize { @worker_indices << index }
      sleep 0.03
      File.write(stdout_path, "#{env.fetch('LME_JOB_ID')} via burst_#{index} in #{chdir}\n")
      File.write(stderr_path, "")
      0
    end
  end

  def setup
    @tmp = Dir.mktmpdir("rpof-dynamic-dispatch-")
  end

  def teardown
    FileUtils.remove_entry(@tmp) if @tmp && File.exist?(@tmp)
  end

  def test_running_dispatch_admits_prepared_worker_and_uses_it
    state = FakeFleetState.new
    runner = SlowRunner.new
    output = File.join(@tmp, "dispatch")
    dispatcher = LocalModelEvaluation::RunpodDispatcher.new(
      fleet_state: state,
      output_dir: output,
      repo_root: @tmp,
      workdir: @tmp,
      endpoint_checker: HealthyEndpoints.new,
      command_runner: runner,
      fleet_key: "fixture",
      admission_poll_seconds: 0.005,
      out: StringIO.new
    )

    thread = Thread.new do
      dispatcher.run(
        jobs: jobs(30),
        worker_indices: [1],
        dynamic_worker_admission: true
      )
    end
    wait_for_control(output)

    control = LocalModelEvaluation::RunpodDispatchAdmission.new(
      output_dir: output,
      fleet_state: state,
      fleet_key: "fixture"
    )
    result = control.admit!(worker_index: 2)
    assert_equal "admitted", result.fetch("status")
    control.close!

    summary = thread.value
    assert_equal "completed", summary.fetch("status")
    assert_equal [1, 2], summary.fetch("worker_indices")
    assert_equal 30, summary.fetch("completed_count")
    assert_includes runner.worker_indices, 2
    assert_operator runner.worker_indices.count(2), :>, 0
  end

  def test_closed_control_rejects_late_admission
    state = FakeFleetState.new
    output = File.join(@tmp, "closed")
    control = LocalModelEvaluation::RunpodDispatchAdmission.new(
      output_dir: output,
      fleet_state: state,
      fleet_key: "fixture"
    )
    control.open!(
      fleet_id: state.current.fetch("fleet_id"),
      initial_worker_indices: [1]
    )
    control.close!

    error = assert_raises(LocalModelEvaluation::RunpodDispatchAdmission::Error) do
      control.admit!(worker_index: 2)
    end
    assert_includes error.message, "closed"
  end

  private

  def jobs(count)
    (1..count).map do |index|
      {
        "job_id" => format("job-%03d", index),
        "argv" => ["fake-workload", index.to_s],
        "env" => {}
      }
    end
  end

  def wait_for_control(output)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 2.0
    path = File.join(output, LocalModelEvaluation::RunpodDispatchAdmission::STATE_FILE)
    until File.file?(path)
      raise "timed out waiting for dispatch admission control" if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
      sleep 0.005
    end
  end
end
