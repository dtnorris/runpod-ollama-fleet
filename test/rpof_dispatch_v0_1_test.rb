# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "fileutils"
require "json"
require_relative "../lib/runpod_ollama_fleet/dispatch_v0_1"

class RpofDispatchV01Test < Minitest::Test
  class FakeState
    def current
      {
        "fleet_id" => "20260914T120000Z-fixture", "status" => "active",
        "workers" => [{ "index" => 1, "status" => "active" }]
      }
    end
  end

  class FakeDispatcher
    class << self
      attr_accessor :last_init
    end
    def initialize(**kwargs)
      self.class.last_init = kwargs
      @output_dir = kwargs.fetch(:output_dir)
    end
    def run(jobs:, worker_indices:, group_by_affinity:)
      FileUtils.mkdir_p(@output_dir)
      File.write(File.join(@output_dir, "manifest.json"), JSON.generate({
        "fleet_id" => "20260914T120000Z-fixture", "worker_indices" => worker_indices,
        "job_count" => jobs.length, "jobs" => jobs, "affinity_grouping" => group_by_affinity
      }))
      {
        "schema_version" => 1,
        "fleet_id" => "20260914T120000Z-fixture",
        "started_at_utc" => "2026-09-14T12:00:00Z",
        "finished_at_utc" => "2026-09-14T12:00:01Z",
        "status" => "completed", "worker_count" => 1, "job_count" => 1,
        "completed_count" => 1, "failed_count" => 0, "not_started_count" => 0,
        "not_started_job_ids" => [], "infrastructure_failures" => [],
        "jobs" => [{
          "job_id" => "one", "worker_index" => 1, "worker_url" => "http://127.0.0.1:11441",
          "started_at_utc" => "2026-09-14T12:00:00Z", "finished_at_utc" => "2026-09-14T12:00:01Z",
          "elapsed_seconds" => 1.0, "status" => "completed", "exit_status" => 0,
          "stdout_path" => "jobs/one/stdout.log", "stderr_path" => "jobs/one/stderr.log"
        }]
      }
    end
  end

  def test_public_summary_hides_physical_endpoint_and_uses_caller_workdir
    Dir.mktmpdir("rpof-dispatch-") do |root|
      workdir = File.join(root, "caller")
      output = File.join(root, "evidence")
      FileUtils.mkdir_p(workdir)
      request = {
        "contract_version" => "afio-rpof-dispatch-request/v0.1",
        "target" => {
          "fleet_key" => "default", "expected_fleet_id" => "20260914T120000Z-fixture",
          "worker_indices" => [1]
        },
        "group_by_affinity" => false,
        "jobs" => [{ "job_id" => "one", "argv" => ["true"] }]
      }
      summary = RunpodOllamaFleet::DispatchV01.new(
        fleet_state: FakeState.new, fleet_key: "default", workdir: workdir,
        output_dir: output, provider_repo_root: root, dispatcher_class: FakeDispatcher
      ).run(request)
      assert_equal "afio-rpof-dispatch-summary/v0.1", summary.fetch("contract_version")
      refute summary.fetch("jobs").first.key?("worker_url")
      assert_equal File.expand_path(workdir), FakeDispatcher.last_init.fetch(:workdir)
      persisted = JSON.parse(File.read(File.join(output, "summary.json")))
      assert_equal summary, persisted
    end
  end
end
