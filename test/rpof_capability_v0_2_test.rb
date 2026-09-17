# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "fileutils"
require "json"
require_relative "../lib/runpod_ollama_fleet/capability_check"
require_relative "../lib/local_model_evaluation/runpod_runtime_alias"

class RpofCapabilityV02Test < Minitest::Test
  DIGEST = "a" * 64

  class FakeState
    def initialize(root, fleet)
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
    def alive?(_pid) = true
    def matches?(_pid, _identity) = true
  end

  class FakeHealth
    Result = Struct.new(:healthy, :version, :detail, keyword_init: true)
    def check(_endpoint) = Result.new(healthy: true, version: "fixture")
  end

  def test_v0_2_proves_runtime_alias_identity_for_current_pod_generation
    Dir.mktmpdir("rpof-capability-v02-") do |root|
      fleet = {
        "fleet_id" => "fixture-fleet",
        "status" => "active",
        "created_at_utc" => "2026-09-16T20:00:00Z",
        "cloud" => "SECURE",
        "gpu" => { "id" => "NVIDIA A40" },
        "fleet_hourly_rate_usd" => 0.49,
        "workers" => [{
          "index" => 1,
          "status" => "active",
          "pod_id" => "pod-1",
          "hourly_rate_usd" => 0.49,
          "created_at_utc" => "2026-09-16T20:00:00Z",
          "local_ollama_url" => "http://127.0.0.1:11441"
        }]
      }
      state = FakeState.new(root, fleet)
      runtime_root = state.artifact_dir(fleet.fetch("fleet_id"), "runtime-alias")
      FileUtils.mkdir_p(runtime_root)
      File.write(
        File.join(runtime_root, LocalModelEvaluation::RunpodRuntimeAlias::EVIDENCE_FILE),
        JSON.pretty_generate(
          "schema_version" => 1,
          "fleet_id" => fleet.fetch("fleet_id"),
          "workers" => [{
            "worker_index" => 1,
            "pod_id" => "pod-1",
            "runtime_model" => "runtime:model",
            "source_model" => "pull/model",
            "digest" => DIGEST,
            "context_length" => 131_072,
            "size_bytes" => 20_000,
            "size_vram_bytes" => 20_000,
            "fully_gpu_resident" => true
          }]
        ) + "\n"
      )
      tunnel_root = state.artifact_dir(fleet.fetch("fleet_id"), "tunnels")
      FileUtils.mkdir_p(tunnel_root)
      File.write(
        File.join(tunnel_root, "tunnels.json"),
        JSON.pretty_generate(
          "fleet_id" => fleet.fetch("fleet_id"),
          "workers" => [{
            "index" => 1,
            "pod_id" => "pod-1",
            "pid" => 123,
            "endpoint" => "http://127.0.0.1:11441",
            "process_identity" => {
              "forward" => "fixture",
              "ssh_port" => 22_001,
              "target" => "root@fixture"
            }
          }]
        ) + "\n"
      )

      request = {
        "contract_version" => "afio-rpof-capability-check-request/v0.2",
        "fleet_key" => "fixture",
        "worker_selector" => { "mode" => "indices", "indices" => [1] },
        "requirements" => {
          "models" => [{ "name" => "runtime:model", "expected_digest" => DIGEST }],
          "required_context_length" => 131_072,
          "require_fully_gpu_resident" => true
        }
      }
      result = RunpodOllamaFleet::CapabilityCheck.new(
        fleet_state: state,
        fleet_key: "fixture",
        process_adapter: FakeProcess.new,
        health_checker: FakeHealth.new,
        wall_clock: -> { Time.utc(2026, 9, 16, 20, 5, 0) }
      ).check(request)

      assert result.fetch("ready"), result.fetch("diagnostics").inspect
      assert_equal DIGEST, result.dig("capabilities", "models", 0, "digest")
      diagnostic = result.fetch("diagnostics").find { |row| row.fetch("code") == "runtime.provenance" }
      assert_equal "PASS", diagnostic.fetch("status")
    end
  end
end
