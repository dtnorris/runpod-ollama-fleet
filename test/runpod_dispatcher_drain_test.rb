# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "stringio"
require_relative "../lib/local_model_evaluation/runpod_dispatcher"

class RunpodDispatcherDrainTest < Minitest::Test
  Health = Struct.new(:healthy, :detail, keyword_init: true)

  class FakeState
    def current
      {
        "fleet_id" => "20260916T170000Z-pod_a",
        "status" => "active",
        "workers" => [
          {
            "index" => 1,
            "status" => "active",
            "pod_id" => "pod_a",
            "local_ollama_url" => "http://127.0.0.1:11441"
          }
        ]
      }
    end
  end

  class HealthyEndpoint
    def check(_endpoint)
      Health.new(healthy: true, detail: "ok")
    end
  end

  class CountingRunner
    attr_reader :completed

    def initialize
      @completed = 0
    end

    def run(argv:, env:, stdout_path:, stderr_path:, chdir:)
      @completed += 1
      File.write(stdout_path, "ok\n")
      File.write(stderr_path, "")
      0
    end
  end

  def test_drain_stops_assignment_between_jobs_without_interrupting_current_job
    Dir.mktmpdir("rpof-drain-") do |root|
      runner = CountingRunner.new
      dispatcher = LocalModelEvaluation::RunpodDispatcher.new(
        fleet_state: FakeState.new,
        output_dir: File.join(root, "evidence"),
        repo_root: root,
        out: StringIO.new,
        endpoint_checker: HealthyEndpoint.new,
        command_runner: runner,
        drain_checker: -> { runner.completed.positive? }
      )
      jobs = 3.times.map do |index|
        { "job_id" => "job-#{index + 1}", "argv" => ["true"], "env" => {} }
      end

      summary = dispatcher.run(jobs: jobs, worker_indices: [1])

      assert_equal "drained", summary.fetch("status")
      assert_equal 1, summary.fetch("completed_count")
      assert_equal 0, summary.fetch("failed_count")
      assert_equal 2, summary.fetch("not_started_count")
      assert_equal %w[job-2 job-3], summary.fetch("not_started_job_ids")
    end
  end
end
