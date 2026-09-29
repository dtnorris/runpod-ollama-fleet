# frozen_string_literal: true

require_relative "test_helper"
require "open3"
require "rbconfig"
require "time"
require_relative "../lib/runpod_ollama_fleet/dynamic_worker_registry"

class DynamicWorkerRegistryProducerTest < Minitest::Test
  DIGEST = "a" * 64
  NOW = Time.utc(2026, 9, 29, 18, 0, 0)
  REPO_ROOT = File.expand_path("..", __dir__)

  class FakeState
    attr_accessor :fleet

    def initialize(root, fleet)
      @root = root
      @fleet = fleet
    end

    def current = Marshal.load(Marshal.dump(fleet))

    def artifact_dir(fleet_id, name)
      raise "wrong fleet" unless fleet_id == fleet.fetch("fleet_id")
      File.join(@root, fleet_id, name)
    end
  end

  class FakeProcess
    attr_accessor :alive, :matches

    def initialize(alive: true, matches: true)
      @alive = alive
      @matches = matches
    end

    def alive?(_pid) = alive
    def matches?(_pid, _identity) = matches
  end

  class FakeHealth
    Result = Struct.new(:healthy, :version, :detail, keyword_init: true)
    attr_accessor :healthy

    def initialize(healthy: true)
      @healthy = healthy
    end

    def check(_endpoint) = Result.new(healthy:, version: "fixture")
  end

  def setup
    @tmp = Dir.mktmpdir("rpof-worker-registry-")
    @publisher_root = File.join(@tmp, "publisher")
    @fleet = fleet
    @state = FakeState.new(File.join(@tmp, "fleet-state"), @fleet)
    @process = FakeProcess.new
    @health = FakeHealth.new
    write_bootstrap
    write_tunnels
  end

  def teardown
    FileUtils.remove_entry(@tmp) if @tmp && File.exist?(@tmp)
  end

  def test_ready_worker_projects_exact_capabilities_and_contract_shape
    snapshot = registry.snapshot
    worker = snapshot.fetch("workers").fetch(0)

    assert_equal "dynamic-worker-registry/v0.1", snapshot.fetch("contract_version")
    assert_equal "rpof-test", snapshot.fetch("registry_id")
    assert_equal 1, snapshot.fetch("revision")
    assert_equal "2026-09-29T18:00:00Z", snapshot.fetch("published_at")
    assert_equal "2026-09-29T18:00:30Z", snapshot.fetch("expires_at")
    assert_equal %w[contract_version expires_at published_at registry_id revision workers], snapshot.keys.sort
    assert_equal %w[capabilities capability_fingerprint endpoint generation_id labels state worker_id], worker.keys.sort
    assert_equal "main.burst-1", worker.fetch("worker_id")
    assert_equal "http://127.0.0.1:11441", worker.fetch("endpoint")
    assert_equal "READY", worker.fetch("state")
    assert_equal %w[inference ollama remote], worker.fetch("labels")
    assert_equal "NVIDIA A40", worker.dig("capabilities", "gpu_id")
    assert_equal [{
      "model" => "qualified-model:latest",
      "digest" => DIGEST,
      "context_length" => 131_072,
      "fully_gpu_resident" => true
    }], worker.dig("capabilities", "ollama", "models")
    assert_equal RunpodOllamaFleet::DynamicWorkerRegistry.capability_fingerprint(worker),
                 worker.fetch("capability_fingerprint")
  end

  def test_bootstrap_incomplete_worker_is_not_ready
    record = bootstrap_record
    record["status"] = "running"
    write_bootstrap(record)

    assert_equal "NOT_READY", registry.snapshot.dig("workers", 0, "state")
  end

  def test_missing_capability_evidence_omits_worker
    record = bootstrap_record
    record["status"] = "running"
    record.fetch("workers").first.merge!("status" => "running", "provenance" => nil)
    write_bootstrap(record)

    assert_empty registry.snapshot.fetch("workers")
  end

  def test_unhealthy_worker_is_not_ready_and_unavailable_worker_is_explicit
    @health.healthy = false
    assert_equal "NOT_READY", registry.snapshot.dig("workers", 0, "state")

    @fleet.fetch("workers").first["status"] = "destroyed"
    assert_equal "UNAVAILABLE", registry.snapshot.dig("workers", 0, "state")
  end

  def test_missing_or_stale_tunnel_is_not_ready
    File.delete(File.join(@state.artifact_dir(@fleet.fetch("fleet_id"), "tunnels"), "tunnels.json"))
    assert_equal "NOT_READY", registry.snapshot.dig("workers", 0, "state")

    write_tunnels
    @process.alive = false
    assert_equal "NOT_READY", registry.snapshot.dig("workers", 0, "state")
  end

  def test_conflicting_model_evidence_fails_closed
    record = bootstrap_record
    record.dig("workers", 0, "provenance", "models", "qualified-model:latest")["digest"] = "b" * 64
    write_bootstrap(record)

    error = assert_raises(RunpodOllamaFleet::DynamicWorkerRegistry::Error) { registry.snapshot }

    assert_includes error.message, "digest evidence conflicts"
  end

  def test_replacement_changes_generation_when_endpoint_is_reused
    first = registry.snapshot.fetch("workers").first

    worker = @fleet.fetch("workers").first
    worker.merge!(
      "pod_id" => "pod-replacement",
      "generation" => 2,
      "created_at_utc" => "2026-09-29T18:01:00Z"
    )
    write_bootstrap(bootstrap_record(pod_id: "pod-replacement"))
    write_tunnels(pod_id: "pod-replacement")
    second_snapshot = registry.snapshot
    second = second_snapshot.fetch("workers").first

    assert_equal 2, second_snapshot.fetch("revision")
    assert_equal first.fetch("worker_id"), second.fetch("worker_id")
    assert_equal first.fetch("endpoint"), second.fetch("endpoint")
    refute_equal first.fetch("generation_id"), second.fetch("generation_id")
  end

  def test_worker_order_and_fingerprint_are_deterministic
    worker_two = @fleet.fetch("workers").first.merge(
      "index" => 2,
      "name" => "burst-2",
      "pod_id" => "pod-2",
      "local_ollama_url" => "http://127.0.0.1:11442"
    )
    @fleet.fetch("workers").unshift(worker_two)
    record = bootstrap_record
    record.fetch("workers") << bootstrap_worker(index: 2, pod_id: "pod-2")
    write_bootstrap(record)
    write_tunnels(workers: [tunnel_worker(index: 2, pod_id: "pod-2", endpoint: "http://127.0.0.1:11442"), tunnel_worker])

    first = registry.snapshot.fetch("workers")
    second = registry.snapshot.fetch("workers")

    assert_equal %w[main.burst-1 main.burst-2], first.map { |row| row.fetch("worker_id") }
    assert_equal first, second
  end

  def test_malformed_source_state_fails_before_revision_is_published
    path = bootstrap_path
    File.write(path, "{not-json\n")

    error = assert_raises(RunpodOllamaFleet::DynamicWorkerRegistry::Error) { registry.snapshot }

    assert_includes error.message, "invalid source state"
    refute File.exist?(File.join(
      @publisher_root,
      RunpodOllamaFleet::DynamicWorkerRegistry::PUBLISHER_STATE_FILE
    ))
  end

  def test_canonical_dw01_fixture_uses_the_producer_fingerprint
    fixture = JSON.parse(File.read(File.join(__dir__, "fixtures", "dynamic-worker-registry-v0.1.json")))
    worker = fixture.fetch("workers").first

    assert_equal worker.fetch("capability_fingerprint"),
                 RunpodOllamaFleet::DynamicWorkerRegistry.capability_fingerprint(worker)
  end

  def test_workers_json_cli_emits_empty_valid_snapshots_and_advances_revision
    state_root = File.join(@tmp, "cli-state")
    env = {
      "RPOF_STATE_ROOT" => state_root,
      "RPOF_STATE_REPO_ROOT" => @tmp
    }
    first = run_cli(env, "workers", "--json")
    second = run_cli(env, "workers", "--json")

    assert_equal "dynamic-worker-registry/v0.1", first.fetch("contract_version")
    assert_empty first.fetch("workers")
    assert_equal first.fetch("registry_id"), second.fetch("registry_id")
    assert_equal first.fetch("revision") + 1, second.fetch("revision")
  end

  private

  def registry
    RunpodOllamaFleet::DynamicWorkerRegistry.new(
      state_root: @publisher_root,
      repo_root: @tmp,
      clock: -> { NOW },
      process_adapter: @process,
      health_checker: @health,
      fleet_sources: [{ "fleet_key" => "main", "state" => @state }],
      id_generator: -> { "rpof-test" }
    )
  end

  def fleet
    {
      "fleet_id" => "20260929T175500Z-pod-1",
      "status" => "active",
      "created_at_utc" => "2026-09-29T17:55:00Z",
      "gpu" => { "id" => "NVIDIA A40" },
      "workers" => [{
        "index" => 1,
        "name" => "burst-1",
        "pod_id" => "pod-1",
        "generation" => 1,
        "created_at_utc" => "2026-09-29T17:55:00Z",
        "status" => "active",
        "gpu_id" => "NVIDIA A40",
        "local_ollama_url" => "http://127.0.0.1:11441"
      }]
    }
  end

  def bootstrap_record(pod_id: "pod-1")
    {
      "schema_version" => 2,
      "bootstrap_run_id" => "bootstrap-fixture",
      "fleet_id" => @fleet.fetch("fleet_id"),
      "status" => "passed",
      "models" => ["qualified-model:latest"],
      "expected_digests" => { "qualified-model:latest" => DIGEST },
      "context" => 131_072,
      "workers" => [bootstrap_worker(pod_id:)]
    }
  end

  def bootstrap_worker(index: 1, pod_id: "pod-1")
    {
      "index" => index,
      "pod_id" => pod_id,
      "status" => "passed",
      "provenance_error" => nil,
      "provenance" => {
        "gpu" => { "name" => "NVIDIA A40" },
        "models" => {
          "qualified-model:latest" => {
            "digest" => DIGEST,
            "context_length" => 131_072,
            "size_bytes" => 20_000,
            "size_vram_bytes" => 20_000,
            "fully_gpu_resident" => true
          }
        }
      }
    }
  end

  def write_bootstrap(record = bootstrap_record)
    FileUtils.mkdir_p(File.dirname(bootstrap_path))
    File.write(File.join(File.dirname(File.dirname(bootstrap_path)), "current"), "bootstrap-fixture\n")
    File.write(bootstrap_path, JSON.pretty_generate(record) + "\n")
  end

  def bootstrap_path
    File.join(
      @state.artifact_dir(@fleet.fetch("fleet_id"), "bootstrap"),
      "bootstrap-fixture",
      "bootstrap.json"
    )
  end

  def write_tunnels(pod_id: "pod-1", workers: nil)
    root = @state.artifact_dir(@fleet.fetch("fleet_id"), "tunnels")
    FileUtils.mkdir_p(root)
    File.write(
      File.join(root, "tunnels.json"),
      JSON.pretty_generate(
        "fleet_id" => @fleet.fetch("fleet_id"),
        "workers" => workers || [tunnel_worker(pod_id:)]
      ) + "\n"
    )
  end

  def tunnel_worker(index: 1, pod_id: "pod-1", endpoint: "http://127.0.0.1:11441")
    {
      "index" => index,
      "pod_id" => pod_id,
      "pid" => 123,
      "endpoint" => endpoint,
      "process_identity" => {
        "forward" => "fixture",
        "ssh_port" => 22_001,
        "target" => "root@fixture"
      }
    }
  end

  def run_cli(env, *arguments)
    stdout, stderr, status = Open3.capture3(
      env,
      RbConfig.ruby,
      File.join(REPO_ROOT, "bin", "rpof"),
      *arguments,
      chdir: REPO_ROOT
    )
    assert status.success?, stderr
    JSON.parse(stdout)
  end
end
