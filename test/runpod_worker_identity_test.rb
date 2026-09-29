# frozen_string_literal: true

require "digest"
require "fileutils"
require "json"
require "minitest/autorun"
require "tmpdir"
require_relative "../lib/local_model_evaluation/runpod_fleet_state"

class RunpodWorkerIdentityTest < Minitest::Test
  Worker = Struct.new(:index, :pod_id, :name, :host, :ssh_port, :hourly_rate, keyword_init: true)

  def setup
    @tmp = Dir.mktmpdir("rpof-worker-identity-")
    @now = Time.utc(2026, 9, 29, 18, 0, 0)
    @state = LocalModelEvaluation::RunpodFleetState.new(
      root: File.join(@tmp, "fleets"),
      clock: -> { @now }
    )
  end

  def teardown
    FileUtils.remove_entry(@tmp) if @tmp && File.exist?(@tmp)
  end

  def test_identity_is_stable_across_repeated_reads_and_artifact_restarts
    fleet = activate([worker(1, "pod-a")])
    first = identity(1, "pod-a")

    %w[bootstrap tunnels].each do |artifact|
      path = File.join(@state.artifact_dir(fleet.fetch("fleet_id"), artifact), "restart.json")
      File.write(path, JSON.generate("pid" => 100))
      File.write(path, JSON.generate("pid" => 200))
    end

    assert_equal first, identity(1, "pod-a")
    assert_equal first, reloaded_state.registry_identity(index: 1, observed_pod_id: "pod-a")
  end

  def test_initial_identity_is_deterministic_and_registry_ready
    fleet = activate([worker(1, "pod-a")])
    projected = identity(1, "pod-a")
    expected_worker_id = "worker-#{Digest::SHA256.hexdigest(JSON.generate(["rpof-worker", fleet.fetch("fleet_id"), 1]))}"
    expected_generation_id = "generation-#{Digest::SHA256.hexdigest(JSON.generate(["rpof-generation", expected_worker_id, 1, "pod-a"]))}"

    assert_equal(
      { "worker_id" => expected_worker_id, "generation_id" => expected_generation_id },
      projected
    )
    assert_match(/\A[A-Za-z0-9][A-Za-z0-9._-]{0,127}\z/, projected.fetch("worker_id"))
    assert_operator projected.fetch("generation_id").length, :<=, 256
  end

  def test_explicit_replacement_preserves_worker_and_rotates_generation_despite_endpoint_reuse
    activate([worker(1, "pod-a")])
    before = identity(1, "pod-a")
    endpoint = current_worker(1).fetch("local_ollama_url")

    @state.begin_replacement(1)
    @state.mark_replacement_destroyed(1)
    @now += 1
    @state.complete_replacement(worker: worker(1, "pod-b"), created_at_utc: @now.iso8601)

    after = identity(1, "pod-b")
    assert_equal before.fetch("worker_id"), after.fetch("worker_id")
    refute_equal before.fetch("generation_id"), after.fetch("generation_id")
    assert_equal endpoint, current_worker(1).fetch("local_ollama_url")
    assert_equal before.fetch("generation_id"), current_worker(1).fetch("history").last.fetch("generation_id")
  end

  def test_destroy_and_recreate_same_slot_preserves_worker_and_rotates_generation
    activate([worker(1, "pod-a"), worker(2, "pod-b")])
    before = identity(2, "pod-b")

    @state.retire_tail_worker(2, destroyed_at_utc: @now.iso8601)
    @now += 1
    @state.add_workers(
      workers: [worker(2, "pod-c")],
      created_at_utc_by_index: { 2 => @now.iso8601 }
    )

    after = identity(2, "pod-c")
    assert_equal before.fetch("worker_id"), after.fetch("worker_id")
    refute_equal before.fetch("generation_id"), after.fetch("generation_id")
    assert_equal 2, current_worker(2).fetch("generation")
  end

  def test_new_fleet_changes_both_worker_and_generation_identity
    activate([worker(1, "pod-a")])
    before = identity(1, "pod-a")
    @state.mark_destroyed([1])
    @now += 1
    activate([worker(1, "pod-b")])
    after = identity(1, "pod-b")

    refute_equal before.fetch("worker_id"), after.fetch("worker_id")
    refute_equal before.fetch("generation_id"), after.fetch("generation_id")
  end

  def test_stale_provider_observation_is_rejected_even_when_slot_endpoint_is_reused
    activate([worker(1, "pod-a")])

    error = assert_raises(LocalModelEvaluation::RunpodFleetState::Error) do
      identity(1, "replacement-pod")
    end

    assert_includes error.message, "provider pod identity mismatch"
  end

  def test_schema_two_state_missing_generation_identity_is_rejected
    fleet = activate([worker(1, "pod-a")])
    path = @state.state_path(fleet.fetch("fleet_id"))
    record = JSON.parse(File.read(path))
    record.fetch("workers").first.delete("generation_id")
    File.write(path, JSON.pretty_generate(record))

    error = assert_raises(LocalModelEvaluation::RunpodFleetState::Error) { @state.current }

    assert_includes error.message, "generation_id"
  end

  def test_legacy_state_can_be_destroyed_but_cannot_publish_or_replace_identity
    fleet = activate([worker(1, "pod-a")])
    path = @state.state_path(fleet.fetch("fleet_id"))
    record = JSON.parse(File.read(path))
    record["schema_version"] = 1
    record.fetch("workers").each do |entry|
      entry.delete("worker_id")
      entry.delete("generation_id")
    end
    File.write(path, JSON.pretty_generate(record))

    assert_equal 1, @state.current.fetch("schema_version")
    publish_error = assert_raises(LocalModelEvaluation::RunpodFleetState::Error) do
      identity(1, "pod-a")
    end
    replace_error = assert_raises(LocalModelEvaluation::RunpodFleetState::Error) do
      @state.begin_replacement(1)
    end
    assert_includes publish_error.message, "predates durable worker identity"
    assert_includes replace_error.message, "predates durable worker identity"

    assert_equal "destroyed", @state.mark_destroyed([1]).fetch("status")
  end

  private

  def activate(workers)
    @state.activate(
      workers:,
      cloud: "SECURE",
      gpu_id: "NVIDIA A40",
      image: "example/image"
    )
  end

  def identity(index, pod_id)
    @state.registry_identity(index:, observed_pod_id: pod_id)
  end

  def current_worker(index)
    @state.current.fetch("workers").find { |entry| entry.fetch("index") == index }
  end

  def reloaded_state
    LocalModelEvaluation::RunpodFleetState.new(root: @state.root, clock: -> { @now })
  end

  def worker(index, pod_id)
    Worker.new(
      index:,
      pod_id:,
      name: "af-lme-burst-#{index}",
      host: "198.51.100.#{10 + index}",
      ssh_port: 22_000 + index,
      hourly_rate: 0.50
    )
  end
end
