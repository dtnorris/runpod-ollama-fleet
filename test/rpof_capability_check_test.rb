# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "fileutils"
require "json"
require_relative "../lib/runpod_ollama_fleet/capability_check"

class RpofCapabilityCheckTest < Minitest::Test
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

  def test_matching_capability_is_read_only
    Dir.mktmpdir("rpof-capability-") do |root|
      fleet = {
        "fleet_id" => "20260914T120000Z-fixture",
        "status" => "active",
        "created_at_utc" => "2026-09-14T12:00:00Z",
        "cloud" => "SECURE",
        "gpu" => { "id" => "NVIDIA A40" },
        "fleet_hourly_rate_usd" => 0.44,
        "workers" => [{
          "index" => 1, "status" => "active", "pod_id" => "pod-1",
          "hourly_rate_usd" => 0.44, "created_at_utc" => "2026-09-14T12:00:00Z",
          "local_ollama_url" => "http://127.0.0.1:11441"
        }]
      }
      state = FakeState.new(root, fleet)
      bootstrap_root = state.artifact_dir(fleet.fetch("fleet_id"), "bootstrap")
      run_id = "bootstrap-fixture"
      FileUtils.mkdir_p(File.join(bootstrap_root, run_id))
      File.write(File.join(bootstrap_root, "current"), "#{run_id}\n")
      File.write(File.join(bootstrap_root, run_id, "bootstrap.json"), JSON.pretty_generate({
        "fleet_id" => fleet.fetch("fleet_id"), "status" => "passed", "context" => 32_768,
        "workers" => [{
          "index" => 1, "status" => "passed",
          "provenance" => {
            "gpu" => { "name" => "NVIDIA A40" },
            "models" => { "fixture-model" => {
              "digest" => DIGEST, "context_length" => 32_768,
              "size_bytes" => 100, "size_vram_bytes" => 100, "fully_gpu_resident" => true
            } }
          }
        }]
      }) + "\n")
      tunnel_root = state.artifact_dir(fleet.fetch("fleet_id"), "tunnels")
      FileUtils.mkdir_p(tunnel_root)
      File.write(File.join(tunnel_root, "tunnels.json"), JSON.pretty_generate({
        "fleet_id" => fleet.fetch("fleet_id"),
        "workers" => [{
          "index" => 1, "pod_id" => "pod-1", "pid" => 123,
          "endpoint" => "http://127.0.0.1:11441",
          "process_identity" => { "forward" => "fixture", "ssh_port" => 22001, "target" => "root@fixture" }
        }]
      }) + "\n")

      before = Dir.glob(File.join(root, "**", "*"), File::FNM_DOTMATCH)
                  .select { |path| File.file?(path) }
                  .to_h { |path| [path, File.binread(path)] }
      request = {
        "contract_version" => "afio-rpof-capability-check-request/v0.1",
        "fleet_key" => "default",
        "worker_selector" => { "mode" => "indices", "indices" => [1] },
        "requirements" => {
          "models" => [{ "name" => "fixture-model", "expected_digest" => DIGEST }],
          "required_context_length" => 32_768,
          "require_fully_gpu_resident" => true,
          "required_gpu_id" => "NVIDIA A40"
        }
      }
      result = RunpodOllamaFleet::CapabilityCheck.new(
        fleet_state: state, fleet_key: "default", process_adapter: FakeProcess.new,
        health_checker: FakeHealth.new, wall_clock: -> { Time.utc(2026, 9, 14, 12, 5, 0) }
      ).check(request)
      assert result.fetch("ready"), result.fetch("diagnostics").inspect
      assert_equal DIGEST, result.dig("capabilities", "models", 0, "digest")
      after = before.keys.to_h { |path| [path, File.binread(path)] }
      assert_equal before, after
    end
  end

  def test_mixed_gpu_capability_uses_each_worker_gpu_contract
    Dir.mktmpdir("rpof-capability-mixed-") do |root|
      state = mixed_gpu_state(root)
      checker = RunpodOllamaFleet::CapabilityCheck.new(
        fleet_state: state, fleet_key: "default", process_adapter: FakeProcess.new,
        health_checker: FakeHealth.new, wall_clock: -> { Time.utc(2026, 9, 14, 12, 5, 0) }
      )

      request = mixed_gpu_request
      result = checker.check(request)
      assert result.fetch("ready"), result.fetch("diagnostics").inspect
      assert_equal "mixed", result.dig("capabilities", "gpu_id")
      assert_equal DIGEST, result.dig("capabilities", "models", 0, "digest")

      exact_request = Marshal.load(Marshal.dump(request))
      exact_request.fetch("requirements")["required_gpu_id"] = "NVIDIA A40"
      rejected = checker.check(exact_request)
      refute rejected.fetch("ready")
      diagnostic = rejected.fetch("diagnostics").find { |row| row.fetch("code") == "bootstrap.provenance" }
      assert_equal "FAIL", diagnostic.fetch("status")
      assert_includes diagnostic.fetch("detail"), 'burst_2="NVIDIA RTX A6000"'
    end
  end

  private

  def mixed_gpu_state(root)
    fleet = {
      "fleet_id" => "20260914T120000Z-mixedfixture",
      "status" => "active",
      "created_at_utc" => "2026-09-14T12:00:00Z",
      "cloud" => "SECURE",
      "gpu" => { "id" => "NVIDIA A40" },
      "fleet_hourly_rate_usd" => 1.04,
      "workers" => [
        {
          "index" => 1, "status" => "active", "pod_id" => "pod-1",
          "hourly_rate_usd" => 0.44, "created_at_utc" => "2026-09-14T12:00:00Z",
          "local_ollama_url" => "http://127.0.0.1:11441"
        },
        {
          "index" => 2, "status" => "active", "pod_id" => "pod-2",
          "gpu_id" => "NVIDIA RTX A6000",
          "hourly_rate_usd" => 0.60, "created_at_utc" => "2026-09-14T12:00:00Z",
          "local_ollama_url" => "http://127.0.0.1:11442"
        }
      ]
    }
    state = FakeState.new(root, fleet)
    bootstrap_root = state.artifact_dir(fleet.fetch("fleet_id"), "bootstrap")
    run_id = "bootstrap-mixed-fixture"
    FileUtils.mkdir_p(File.join(bootstrap_root, run_id))
    File.write(File.join(bootstrap_root, "current"), "#{run_id}\n")
    File.write(File.join(bootstrap_root, run_id, "bootstrap.json"), JSON.pretty_generate({
      "fleet_id" => fleet.fetch("fleet_id"), "status" => "passed", "context" => 32_768,
      "workers" => [
        mixed_bootstrap_worker(1, "NVIDIA A40"),
        mixed_bootstrap_worker(2, "NVIDIA RTX A6000")
      ]
    }) + "\n")

    tunnel_root = state.artifact_dir(fleet.fetch("fleet_id"), "tunnels")
    FileUtils.mkdir_p(tunnel_root)
    File.write(File.join(tunnel_root, "tunnels.json"), JSON.pretty_generate({
      "fleet_id" => fleet.fetch("fleet_id"),
      "workers" => [1, 2].map do |index|
        {
          "index" => index, "pod_id" => "pod-#{index}", "pid" => 120 + index,
          "endpoint" => "http://127.0.0.1:#{11_440 + index}",
          "process_identity" => {
            "forward" => "fixture-#{index}", "ssh_port" => 22_000 + index, "target" => "root@fixture-#{index}"
          }
        }
      end
    }) + "\n")
    state
  end

  def mixed_bootstrap_worker(index, gpu_id)
    {
      "index" => index,
      "status" => "passed",
      "provenance" => {
        "gpu" => { "name" => gpu_id },
        "models" => {
          "fixture-model" => {
            "digest" => DIGEST,
            "context_length" => 32_768,
            "size_bytes" => 100,
            "size_vram_bytes" => 100,
            "fully_gpu_resident" => true
          }
        }
      }
    }
  end

  def mixed_gpu_request
    {
      "contract_version" => "afio-rpof-capability-check-request/v0.1",
      "fleet_key" => "default",
      "worker_selector" => { "mode" => "indices", "indices" => [1, 2] },
      "requirements" => {
        "models" => [{ "name" => "fixture-model", "expected_digest" => DIGEST }],
        "required_context_length" => 32_768,
        "require_fully_gpu_resident" => true
      }
    }
  end
end
