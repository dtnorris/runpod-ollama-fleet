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

  class CoordinatedRunner
    attr_reader :worker_indices

    def initialize
      @worker_indices = []
      @mutex = Mutex.new
      @condition = ConditionVariable.new
      @release_worker_one = false
    end

    def run(argv:, env:, stdout_path:, stderr_path:, chdir:)
      index = Integer(env.fetch("LME_WORKER_INDEX"))
      @mutex.synchronize do
        @worker_indices << index
        @condition.broadcast
        @condition.wait(@mutex) while index == 1 && !@release_worker_one
      end
      File.write(stdout_path, "#{env.fetch('LME_JOB_ID')} via burst_#{index} in #{chdir}\n")
      File.write(stderr_path, "")
      0
    end

    def wait_for_worker(index, timeout: 2.0)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
      @mutex.synchronize do
        until @worker_indices.include?(index)
          remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
          raise "timed out waiting for burst_#{index} to start" unless remaining.positive?

          @condition.wait(@mutex, remaining)
        end
      end
    end

    def release_worker_one
      @mutex.synchronize do
        @release_worker_one = true
        @condition.broadcast
      end
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
    runner = CoordinatedRunner.new
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
        jobs: jobs(2),
        worker_indices: [1],
        dynamic_worker_admission: true
      )
    end
    runner.wait_for_worker(1)

    control = LocalModelEvaluation::RunpodDispatchAdmission.new(
      output_dir: output,
      fleet_state: state,
      fleet_key: "fixture"
    )
    begin
      result = control.admit!(worker_index: 2)
      assert_equal "admitted", result.fetch("status")
      runner.wait_for_worker(2)
    ensure
      control.close! rescue nil
      runner.release_worker_one
    end

    summary = thread.value
    assert_equal "completed", summary.fetch("status")
    assert_equal [1, 2], summary.fetch("worker_indices")
    assert_equal 2, summary.fetch("completed_count")
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
end
