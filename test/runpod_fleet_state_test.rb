# frozen_string_literal: true

require "fileutils"
require "minitest/autorun"
require "stringio"
require "tmpdir"
require_relative "../lib/local_model_evaluation/runpod_fleet"

class RunpodFleetStateTest < Minitest::Test
  class FakeClient
    attr_reader :deleted_ids, :list_pods_calls

    def initialize
      @deleted_ids = []
      @list_pods_calls = 0
      @pod_details = {}
      @next_id = "pod_a"
    end

    attr_writer :next_id

    def list_pods
      @list_pods_calls += 1
      []
    end

    def list_gpu_types(cloud:, count:)
      [
        {
          "id" => "NVIDIA A40",
          "memory" => 48,
          cloud.downcase => true,
          "availability" => "HIGH",
          "price" => { cloud.downcase => 0.44 }
        }
      ]
    end

    def create_pod(body)
      id = @next_id
      @pod_details[id] = ready_pod(id, cloud: body.fetch("cloud"))
      { "id" => id }
    end

    def get_pod(pod_id)
      @pod_details.fetch(pod_id)
    end

    def delete_pod(pod_id)
      @deleted_ids << pod_id
      { "id" => pod_id, "status" => "TERMINATED" }
    end

    private

    def ready_pod(pod_id, cloud:)
      {
        "id" => pod_id,
        "name" => "af-lme-burst-1",
        "status" => "RUNNING",
        "cloud" => cloud,
        "gpu" => { "id" => "NVIDIA A40", "count" => 1 },
        "cost" => 0.44,
        "runtime" => {
          "ports" => [
            { "private" => 22, "public" => 22_011, "type" => "tcp", "ip" => "198.51.100.11" }
          ]
        }
      }
    end
  end

  def setup
    @tmp = Dir.mktmpdir("lme-fleet-state-")
    @state_root = File.join(@tmp, "output", "runpod-fleets")
    @now = Time.utc(2026, 8, 29, 18, 45, 1)
    @clock = -> { @now }
  end

  def teardown
    FileUtils.remove_entry(@tmp) if @tmp && File.exist?(@tmp)
  end

  def test_successive_fleets_keep_artifacts_isolated_and_only_new_fleet_is_current
    store = LocalModelEvaluation::RunpodFleetState.new(root: @state_root, clock: @clock)

    first = store.activate(
      workers: [worker("pod_old")],
      cloud: "SECURE",
      gpu_id: "NVIDIA A40",
      image: "example/image"
    )
    first_id = first.fetch("fleet_id")
    first_log = File.join(store.artifact_dir(first_id, :bootstrap), "burst_1.log")
    File.write(first_log, "old qwen bootstrap\n")

    store.mark_destroyed([1])
    assert_nil store.current_id
    assert_equal "destroyed", store.load(first_id).fetch("status")

    @now += 60
    second = store.activate(
      workers: [worker("pod_new")],
      cloud: "SECURE",
      gpu_id: "NVIDIA A40",
      image: "example/image"
    )
    second_id = second.fetch("fleet_id")

    refute_equal first_id, second_id
    assert_equal second_id, store.current_id
    assert File.file?(first_log)
    refute File.exist?(File.join(store.artifact_dir(second_id, :bootstrap), "burst_1.log"))
    refute_equal store.artifact_dir(first_id, :bootstrap), store.artifact_dir(second_id, :bootstrap)
  end

  def test_partial_destroy_keeps_current_pointer_until_all_workers_are_destroyed
    store = LocalModelEvaluation::RunpodFleetState.new(root: @state_root, clock: @clock)
    record = store.activate(
      workers: [worker("pod_a", 1), worker("pod_b", 2)],
      cloud: "SECURE",
      gpu_id: "NVIDIA A40",
      image: "example/image"
    )
    fleet_id = record.fetch("fleet_id")

    partial = store.mark_destroyed([1])
    assert_equal "active", partial.fetch("status")
    assert_equal fleet_id, store.current_id
    assert_equal %w[destroyed active], partial.fetch("workers").map { |w| w.fetch("status") }

    complete = store.mark_destroyed([2])
    assert_equal "destroyed", complete.fetch("status")
    assert_nil store.current_id
    assert File.file?(store.state_path(fleet_id))
  end

  def test_state_represents_and_routes_workers_twelve_and_sixteen
    store = LocalModelEvaluation::RunpodFleetState.new(root: @state_root, clock: @clock)
    record = store.activate(
      workers: (1..16).map { |index| worker("pod_#{index}", index) },
      cloud: "SECURE",
      gpu_id: "NVIDIA A40",
      image: "example/image"
    )

    by_index = record.fetch("workers").to_h { |entry| [entry.fetch("index"), entry] }
    assert_equal 16, record.fetch("worker_count")
    assert_equal "http://127.0.0.1:11452", by_index.fetch(12).fetch("local_ollama_url")
    assert_equal "http://127.0.0.1:11456", by_index.fetch(16).fetch("local_ollama_url")
    assert_equal 16, store.current.fetch("workers").length
  end

  def test_state_rejects_worker_index_above_canonical_bound
    store = LocalModelEvaluation::RunpodFleetState.new(root: @state_root, clock: @clock)

    error = assert_raises(LocalModelEvaluation::RunpodFleetState::Error) do
      store.activate(
        workers: [worker("pod_17", 17)],
        cloud: "SECURE",
        gpu_id: "NVIDIA A40",
        image: "example/image"
      )
    end
    assert_includes error.message, "between 1 and 16"
  end

  def test_runpod_fleet_create_persists_current_state_and_destroy_archives_it
    env_path = File.join(@tmp, ".env")
    File.write(env_path, "RUNPOD_API_KEY=keep\n")
    client = FakeClient.new
    out = StringIO.new
    fleet = LocalModelEvaluation::RunpodFleet.new(
      client:,
      env_path:,
      out:,
      sleeper: ->(_seconds) {},
      clock: -> { 0.0 },
      state_root: @state_root,
      wall_clock: @clock
    )

    preflight = fleet.preflight(worker_count: 1)
    workers = fleet.create(
      worker_count: 1,
      ssh_public_key: "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAITest test@example",
      preflight:
    )

    assert_equal 1, workers.length
    state = fleet.fleet_state.current
    fleet_id = state.fetch("fleet_id")
    env = File.read(env_path)
    assert_includes env, "LME_RUNPOD_FLEET_ID=#{fleet_id}"
    assert_includes env, "LME_RUNPOD_FLEET_DIR=#{fleet.fleet_state.fleet_dir(fleet_id)}"
    assert_equal "pod_a", state.fetch("workers").first.fetch("pod_id")
    assert_equal "SECURE", state.fetch("cloud")
    assert_equal "active", state.fetch("status")
    assert_includes out.string, "Current fleet: #{fleet_id}"
    assert File.directory?(fleet.fleet_state.artifact_dir(fleet_id, :bootstrap))

    assert_equal [1], fleet.destroy(worker_indices: [1])

    assert_nil fleet.fleet_state.current_id
    archived = fleet.fleet_state.load(fleet_id)
    assert_equal "destroyed", archived.fetch("status")
    env = File.read(env_path)
    refute_includes env, "LME_RUNPOD_FLEET_ID="
    refute_includes env, "LME_RUNPOD_FLEET_DIR="
    assert_equal ["pod_a"], client.deleted_ids
  end

  def test_preflight_fails_closed_on_existing_active_fleet_before_runpod_api_call
    env_path = File.join(@tmp, ".env")
    File.write(env_path, "RUNPOD_API_KEY=keep\n")
    client = FakeClient.new
    fleet = LocalModelEvaluation::RunpodFleet.new(
      client:,
      env_path:,
      out: StringIO.new,
      state_root: @state_root,
      wall_clock: @clock
    )
    fleet.fleet_state.activate(
      workers: [worker("pod_existing")],
      cloud: "SECURE",
      gpu_id: "NVIDIA A40",
      image: "example/image"
    )

    error = assert_raises(LocalModelEvaluation::RunpodFleet::Error) do
      fleet.preflight(worker_count: 1)
    end

    assert_includes error.message, "active RunPod fleet state already exists"
    assert_equal 0, client.list_pods_calls
  end

  private

  def worker(pod_id, index = 1)
    LocalModelEvaluation::RunpodFleet::Worker.new(
      index:,
      pod_id:,
      name: "af-lme-burst-#{index}",
      host: "198.51.100.#{10 + index}",
      ssh_port: 22_000 + index,
      hourly_rate: 0.44
    )
  end
end
