# frozen_string_literal: true

require_relative "test_helper"
require "open3"
require "rbconfig"
require "time"
require_relative "../lib/runpod_ollama_fleet/dynamic_worker_registry"
require_relative "fixtures/dynamic-worker-registry-v0.1/conformance"

class DynamicWorkerRegistryProducerTest < Minitest::Test
  DIGEST = "a" * 64
  NOW = Time.utc(2026, 9, 29, 18, 0, 0)
  CANONICAL_TIMESTAMP = /\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z\z/
  REPO_ROOT = File.expand_path("..", __dir__)
  FleetWorker = Struct.new(:index, :pod_id, :name, :host, :ssh_port, :hourly_rate, keyword_init: true)

  class FakeState
    attr_accessor :fleet
    attr_reader :identities, :identity_observations

    def initialize(root, fleet)
      @root = root
      @fleet = fleet
      @identities = {}
      @identity_observations = []
    end

    def current = Marshal.load(Marshal.dump(fleet))

    def artifact_dir(fleet_id, name)
      raise "wrong fleet" unless fleet_id == fleet.fetch("fleet_id")
      File.join(@root, fleet_id, name)
    end

    def registry_identity(index:, observed_pod_id:)
      worker = fleet.fetch("workers").find { |candidate| candidate.fetch("index") == index }
      raise LocalModelEvaluation::RunpodFleetState::Error, "missing worker" unless worker
      unless worker.fetch("pod_id") == observed_pod_id
        raise LocalModelEvaluation::RunpodFleetState::Error, "provider pod identity mismatch"
      end

      identity_observations << { "index" => index, "pod_id" => observed_pod_id }
      identities.fetch(index)
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

  Gate = Struct.new(:allowed, :error) do
    def satisfied?(fleet_key:, worker:)
      raise error if error
      raise "wrong fleet" unless fleet_key == "main"
      raise "wrong generation" unless worker.fetch("generation_id") == "state-generation-1-1"
      allowed
    end
  end

  def setup
    @tmp = Dir.mktmpdir("rpof-worker-registry-")
    @publisher_root = File.join(@tmp, "publisher")
    @fleet = fleet
    @state = FakeState.new(File.join(@tmp, "fleet-state"), @fleet)
    @state.identities[1] = identity(1, 1)
    @process = FakeProcess.new
    @health = FakeHealth.new
    @now = NOW + 0.987654
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
    assert_operator Time.iso8601(snapshot.fetch("published_at")), :<=, @now
    assert_equal %w[contract_version expires_at published_at registry_id revision workers], snapshot.keys.sort
    assert_equal %w[capabilities capability_fingerprint endpoint generation_id labels state worker_id], worker.keys.sort
    assert_equal @state.identities.fetch(1), worker.slice("worker_id", "generation_id")
    assert_equal [{ "index" => 1, "pod_id" => "pod-1" }], @state.identity_observations
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
    assert_equal snapshot, DynamicWorkerRegistryV01::Conformance.validate_document!(snapshot, now: @now)
  end

  def test_generation_bound_gate_is_authoritative_for_ready_publication
    blocked = registry(readiness_gate: Gate.new(false, nil)).snapshot
    assert_equal "NOT_READY", blocked.dig("workers", 0, "state")

    @now += 1
    ready = registry(readiness_gate: Gate.new(true, nil)).snapshot
    assert_equal "READY", ready.dig("workers", 0, "state")
  end

  def test_generation_bound_gate_tamper_refuses_publication
    error = assert_raises(RunpodOllamaFleet::DynamicWorkerRegistry::Error) do
      registry(readiness_gate: Gate.new(false, RuntimeError.new("tampered"))).snapshot
    end
    assert_includes error.message, "refused publication"
  end

  def test_bootstrap_incomplete_worker_is_not_ready
    record = bootstrap_record
    record["status"] = "running"
    write_bootstrap(record)

    assert_equal "NOT_READY", registry.snapshot.dig("workers", 0, "state")
  end

  def test_readiness_status_distinguishes_bootstrap_tunnel_and_registry_state
    record = bootstrap_record
    record["status"] = "running"
    write_bootstrap(record)

    waiting = registry.readiness_status
    assert_equal "available", waiting.fetch("status")
    assert_equal 1, waiting.dig("counts", "bootstrap_passed")
    assert_equal 1, waiting.dig("counts", "tunnel_established")
    assert_equal 1, waiting.dig("counts", "NOT_READY")
    assert_equal "NOT_READY", waiting.dig("workers", 0, "registry_state")

    record["status"] = "passed"
    write_bootstrap(record)
    @now += 1

    ready = registry.readiness_status
    assert_equal 1, ready.dig("counts", "READY")
    assert_equal 0, ready.dig("counts", "NOT_READY")
    assert_equal "READY", ready.dig("workers", 0, "registry_state")
  end

  def test_readiness_status_marks_worker_unpublished_when_registry_evidence_is_incomplete
    File.delete(File.join(@state.artifact_dir(@fleet.fetch("fleet_id"), "tunnels"), "tunnels.json"))

    status = registry.readiness_status

    assert_equal 0, status.dig("counts", "READY")
    assert_equal 1, status.dig("counts", "registry_unpublished")
    refute status.dig("workers", 0, "tunnel_established")
    assert_nil status.dig("workers", 0, "registry_state")
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
    @now += 1
    assert_equal "UNAVAILABLE", registry.snapshot.dig("workers", 0, "state")
  end

  def test_missing_tunnel_omits_worker_and_stale_tunnel_is_not_ready
    File.delete(File.join(@state.artifact_dir(@fleet.fetch("fleet_id"), "tunnels"), "tunnels.json"))

    assert_empty registry.snapshot.fetch("workers")

    write_tunnels
    @process.alive = false
    @now += 1
    assert_equal "NOT_READY", registry.snapshot.dig("workers", 0, "state")
  end

  def test_stale_provider_pod_observation_fails_closed
    write_tunnels(pod_id: "replacement-pod")

    error = assert_raises(RunpodOllamaFleet::DynamicWorkerRegistry::Error) { registry.snapshot }

    assert_includes error.message, "provider pod identity mismatch"
  end

  def test_conflicting_model_evidence_fails_closed
    record = bootstrap_record
    record.dig("workers", 0, "provenance", "models", "qualified-model:latest")["digest"] = "b" * 64
    write_bootstrap(record)

    error = assert_raises(RunpodOllamaFleet::DynamicWorkerRegistry::Error) { registry.snapshot }

    assert_includes error.message, "digest evidence conflicts"
  end

  def test_replacement_changes_generation_when_endpoint_is_reused
    @state = LocalModelEvaluation::RunpodFleetState.new(
      root: File.join(@tmp, "persisted-fleet-state"),
      clock: -> { NOW }
    )
    @fleet = @state.activate(
      workers: [fleet_worker("pod-1")],
      cloud: "SECURE",
      gpu_id: "NVIDIA A40",
      image: "example/image"
    )
    write_bootstrap
    write_tunnels

    expected_first = @state.registry_identity(index: 1, observed_pod_id: "pod-1")
    first = registry.snapshot.fetch("workers").first
    ordinary_read = registry.snapshot.fetch("workers").first

    assert_equal expected_first, first.slice("worker_id", "generation_id")
    assert_equal expected_first, ordinary_read.slice("worker_id", "generation_id")
    endpoint = first.fetch("endpoint")

    @state.begin_replacement(1)
    @state.mark_replacement_destroyed(1)
    @state.complete_replacement(
      worker: fleet_worker("pod-replacement"),
      created_at_utc: (NOW + 60).iso8601
    )
    @fleet = @state.current
    write_bootstrap(bootstrap_record(pod_id: "pod-replacement"))
    write_tunnels(pod_id: "pod-replacement")
    expected_second = @state.registry_identity(index: 1, observed_pod_id: "pod-replacement")
    @now += 1
    second_snapshot = registry.snapshot
    second = second_snapshot.fetch("workers").first

    assert_equal 2, second_snapshot.fetch("revision")
    assert_equal expected_second, second.slice("worker_id", "generation_id")
    assert_equal first.fetch("worker_id"), second.fetch("worker_id")
    assert_equal endpoint, second.fetch("endpoint")
    refute_equal first.fetch("generation_id"), second.fetch("generation_id")
  end

  def test_ordinary_reads_keep_fleet_state_identities_and_deterministic_order
    worker_two = @fleet.fetch("workers").first.merge(
      "index" => 2,
      "name" => "burst-2",
      "pod_id" => "pod-2",
      "worker_id" => "state-worker-2",
      "generation_id" => "state-generation-2-1",
      "local_ollama_url" => "http://127.0.0.1:11442"
    )
    @fleet.fetch("workers").unshift(worker_two)
    @state.identities[2] = identity(2, 1)
    record = bootstrap_record
    record.fetch("workers") << bootstrap_worker(index: 2, pod_id: "pod-2")
    write_bootstrap(record)
    write_tunnels(workers: [tunnel_worker(index: 2, pod_id: "pod-2", endpoint: "http://127.0.0.1:11442"), tunnel_worker])

    first_snapshot = registry.snapshot
    second_snapshot = registry.snapshot
    first = first_snapshot.fetch("workers")
    second = second_snapshot.fetch("workers")

    assert_equal first_snapshot, second_snapshot
    assert_equal 1, second_snapshot.fetch("revision")
    assert_equal %w[state-worker-1 state-worker-2], first.map { |row| row.fetch("worker_id") }
    assert_equal first, second
    assert_equal @state.identities.values.sort_by { |row| row.fetch("worker_id") },
                 first.map { |row| row.slice("worker_id", "generation_id") }
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

  def test_publication_changes_only_its_durable_revision_state
    before = provider_owned_files

    snapshot = registry.snapshot

    assert_equal before, provider_owned_files
    assert_equal "READY", snapshot.dig("workers", 0, "state")
    assert File.file?(File.join(
      @publisher_root,
      RunpodOllamaFleet::DynamicWorkerRegistry::PUBLISHER_STATE_FILE
    ))
  end

  def test_canonical_dw01_fixture_uses_the_producer_fingerprint
    fixture = JSON.parse(File.read(File.join(
      __dir__, "fixtures", "dynamic-worker-registry-v0.1", "minimal-valid.json"
    )))
    worker = fixture.fetch("workers").first

    assert_equal worker.fetch("capability_fingerprint"),
                 RunpodOllamaFleet::DynamicWorkerRegistry.capability_fingerprint(worker)
  end

  def test_next_second_advances_revision_and_clock_rollback_fails_closed
    first = registry.snapshot
    @now += 1
    second = registry.snapshot
    state_path = File.join(@publisher_root, RunpodOllamaFleet::DynamicWorkerRegistry::PUBLISHER_STATE_FILE)
    state_before_rollback = File.binread(state_path)

    assert_equal first.fetch("registry_id"), second.fetch("registry_id")
    assert_equal first.fetch("revision") + 1, second.fetch("revision")
    assert_operator Time.iso8601(second.fetch("published_at")), :>,
                    Time.iso8601(first.fetch("published_at"))

    @now -= 2
    error = assert_raises(RunpodOllamaFleet::DynamicWorkerRegistry::Error) { registry.snapshot }
    assert_includes error.message, "clock moved backwards"
    assert_equal state_before_rollback, File.binread(state_path)
  end

  def test_legacy_publisher_state_migrates_fail_closed_to_cached_snapshot
    FileUtils.mkdir_p(@publisher_root)
    state_path = File.join(@publisher_root, RunpodOllamaFleet::DynamicWorkerRegistry::PUBLISHER_STATE_FILE)
    File.write(
      state_path,
      JSON.generate("schema_version" => 1, "registry_id" => "legacy-registry", "revision" => 7) + "\n"
    )
    File.utime(@now, @now, state_path)

    error = assert_raises(RunpodOllamaFleet::DynamicWorkerRegistry::Error) { registry.snapshot }
    assert_includes error.message, "cannot safely advance in the current second"

    @now = Time.at(@now.to_i + 1).utc
    snapshot = registry.snapshot
    state = JSON.parse(File.read(state_path))

    assert_equal "legacy-registry", snapshot.fetch("registry_id")
    assert_equal 8, snapshot.fetch("revision")
    assert_equal 2, state.fetch("schema_version")
    assert_equal snapshot, state.fetch("snapshot")
  end

  def test_cached_snapshot_tampering_fails_closed
    registry.snapshot
    state_path = File.join(@publisher_root, RunpodOllamaFleet::DynamicWorkerRegistry::PUBLISHER_STATE_FILE)
    state = JSON.parse(File.read(state_path))
    state.fetch("snapshot")["revision"] += 1
    File.write(state_path, JSON.generate(state) + "\n")

    error = assert_raises(RunpodOllamaFleet::DynamicWorkerRegistry::Error) { registry.snapshot }

    assert_includes error.message, "snapshot identity is invalid"
  end

  def test_workers_json_cli_emits_canonical_monotonic_or_reused_snapshots
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
    [first, second].each do |snapshot|
      assert_match CANONICAL_TIMESTAMP, snapshot.fetch("published_at")
      assert_match CANONICAL_TIMESTAMP, snapshot.fetch("expires_at")
    end
    if first.fetch("published_at") == second.fetch("published_at")
      assert_equal first, second
    else
      assert_equal first.fetch("revision") + 1, second.fetch("revision")
      assert_operator Time.iso8601(second.fetch("published_at")), :>,
                      Time.iso8601(first.fetch("published_at"))
    end
  end

  private

  def provider_owned_files
    publisher_prefix = "#{File.expand_path(@publisher_root)}/"
    Dir[File.join(@tmp, "**", "*")].select { |path| File.file?(path) }.filter_map do |path|
      expanded = File.expand_path(path)
      next if expanded.start_with?(publisher_prefix)

      [expanded.delete_prefix("#{File.expand_path(@tmp)}/"), Digest::SHA256.file(expanded).hexdigest]
    end.to_h
  end

  def identity(index, generation)
    {
      "worker_id" => "state-worker-#{index}",
      "generation_id" => "state-generation-#{index}-#{generation}"
    }
  end

  def fleet_worker(pod_id)
    FleetWorker.new(
      index: 1,
      pod_id:,
      name: "af-lme-burst-1",
      host: "198.51.100.11",
      ssh_port: 22_001,
      hourly_rate: 0.50
    )
  end

  def registry(readiness_gate: nil)
    RunpodOllamaFleet::DynamicWorkerRegistry.new(
      state_root: @publisher_root,
      repo_root: @tmp,
      clock: -> { @now },
      process_adapter: @process,
      health_checker: @health,
      fleet_sources: [{ "fleet_key" => "main", "state" => @state }],
      id_generator: -> { "rpof-test" },
      readiness_gate:
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
        "worker_id" => "state-worker-1",
        "generation_id" => "state-generation-1-1",
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
    worker = @fleet.fetch("workers").find { |candidate| candidate.fetch("index") == index }
    {
      "index" => index,
      "pod_id" => pod_id,
      "worker_id" => worker.fetch("worker_id"),
      "generation_id" => worker.fetch("generation_id"),
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
    worker = @fleet.fetch("workers").find { |candidate| candidate.fetch("index") == index }
    {
      "index" => index,
      "pod_id" => pod_id,
      "worker_id" => worker.fetch("worker_id"),
      "generation_id" => worker.fetch("generation_id"),
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
