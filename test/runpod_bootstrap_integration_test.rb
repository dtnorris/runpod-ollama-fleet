# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "stringio"
require "fileutils"
require "json"
require_relative "../lib/local_model_evaluation/runpod_bootstrap"

module LocalModelEvaluation
  class RunpodFleetState
    class Error < StandardError; end
  end unless const_defined?(:RunpodFleetState)
end

class RunpodBootstrapIntegrationTest < Minitest::Test
  DIGEST = "a" * 64

  class FakeFleetState
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

  def test_default_adapters_execute_one_worker_and_persist_evidence
    Dir.mktmpdir("bootstrap-integration-") do |root|
      repo_root = File.join(root, "repo")
      FileUtils.mkdir_p(repo_root)
      script = File.join(repo_root, "remote.sh")
      body = <<~'SH'
        #!/bin/sh
        set -eu
        worker=""
        previous=""
        for arg in "$@"; do
          if [ "$previous" = "--worker" ]; then
            worker="$arg"
            break
          fi
          previous="$arg"
        done
        printf 'LME_PROVENANCE_GPU\tNVIDIA A40\t46068\n'
        printf 'LME_PROVENANCE_MODEL\tgemma4:26b\t__DIGEST__\t131072\t2566893074\t2566893074\n'
        printf 'Worker setup PASS.\n'
        printf 'Worker %s remote setup PASS.\n' "$worker"
      SH
      File.write(script, body.sub("__DIGEST__", DIGEST))
      File.chmod(0o755, script)

      fleet = {
        "fleet_id" => "integration-fleet",
        "status" => "active",
        "fleet_hourly_rate_usd" => 0.44,
        "gpu" => {"id" => "NVIDIA A40", "count_per_worker" => 1},
        "workers" => [{
          "index" => 1,
          "name" => "af-lme-burst-1",
          "pod_id" => "pod_1",
          "host" => "198.51.100.1",
          "ssh_port" => 22_001,
          "hourly_rate_usd" => 0.44,
          "status" => "active"
        }]
      }
      fleet_state = FakeFleetState.new(
        root: File.join(repo_root, "output", "runpod-fleets"),
        fleet:
      )
      out = StringIO.new
      runner = LocalModelEvaluation::RunpodBootstrap.new(
        fleet_state:,
        remote_setup_path: script,
        repo_root:,
        out:
      )

      record = runner.run(
        worker_indices: [1],
        models: ["gemma4:26b"],
        expected_digests: ["gemma4:26b=#{DIGEST}"],
        poll_seconds: 0.005
      )

      assert_equal "passed", record.fetch("status")
      bootstrap_root = fleet_state.artifact_dir("integration-fleet", "bootstrap")
      run_id = File.read(File.join(bootstrap_root, "current")).strip
      persisted = JSON.parse(File.read(File.join(bootstrap_root, run_id, "bootstrap.json")))
      assert_equal "passed", persisted.fetch("status")
      assert_includes File.read(File.join(bootstrap_root, run_id, "burst_1.log")), "Worker 1 remote setup PASS"
    end
  end
end
