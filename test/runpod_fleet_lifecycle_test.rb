# frozen_string_literal: true

require_relative "test_helper"
require "stringio"
require_relative "../lib/local_model_evaluation/runpod_fleet_lifecycle"

class RunpodFleetLifecycleTest < Minitest::Test
  class FakeClient
    attr_reader :created_bodies, :deleted_ids, :events, :catalog_calls

    def initialize
      @created_bodies = []
      @deleted_ids = []
      @events = []
      @catalog_calls = []
      @pods = {}
      @sequence = 0
      @fail_next_create = false
      @fail_create_on_call = nil
    end

    attr_writer :fail_next_create, :fail_create_on_call

    def seed(worker)
      @pods[worker.pod_id] = ready_pod(
        worker.index,
        worker.pod_id,
        worker.host,
        worker.ssh_port,
        worker.hourly_rate
      )
    end

    def list_pods
      @pods.values.map { |pod| Marshal.load(Marshal.dump(pod)) }
    end

    def list_gpu_types(cloud:, count:)
      @catalog_calls << [cloud, count]
      [
        {
          "id" => "NVIDIA A40",
          "memory" => 48,
          cloud.downcase => true,
          "availability" => "HIGH",
          "price" => { cloud.downcase => 0.50 }
        },
        {
          "id" => "NVIDIA RTX A6000",
          "memory" => 48,
          cloud.downcase => true,
          "availability" => "HIGH",
          "price" => { cloud.downcase => 0.60 }
        }
      ]
    end

    def create_pod(body)
      @created_bodies << Marshal.load(Marshal.dump(body))
      @events << ["create", body.fetch("name")]
      if @fail_next_create || @fail_create_on_call == @created_bodies.length
        @fail_next_create = false
        @fail_create_on_call = nil
        raise LocalModelEvaluation::RunpodClient::Error.new(400, "capacity disappeared")
      end

      @sequence += 1
      index = body.fetch("name")[/burst-(\d+)\z/, 1].to_i
      id = "new_#{index}_#{@sequence}"
      gpu_id = body.dig("gpu", "id") || "NVIDIA A40"
      rate = gpu_id == "NVIDIA RTX A6000" ? 0.60 : 0.50
      @pods[id] = ready_pod(
        index, id, "198.51.100.#{50 + index}", 23_000 + index, rate,
        cloud: body.fetch("cloud"), gpu_id:
      )
      { "id" => id }
    end

    def get_pod(pod_id)
      @pods.fetch(pod_id) { raise LocalModelEvaluation::RunpodClient::Error.new(404, "not found") }
    end

    def delete_pod(pod_id)
      @events << ["delete", pod_id]
      @deleted_ids << pod_id
      @pods.delete(pod_id)
      { "id" => pod_id, "status" => "TERMINATED" }
    end

    private

    def ready_pod(index, id, host, port, rate, cloud: "SECURE", gpu_id: "NVIDIA A40")
      {
        "id" => id,
        "name" => "af-lme-burst-#{index}",
        "status" => "RUNNING",
        "cloud" => cloud,
        "gpu" => { "id" => gpu_id, "count" => 1 },
        "cost" => rate,
        "runtime" => {
          "ports" => [{ "private" => 22, "public" => port, "type" => "tcp", "ip" => host }]
        }
      }
    end
  end

  def setup
    @tmp = Dir.mktmpdir("runpod-lifecycle-")
    @state_root = File.join(@tmp, "state")
    @env_path = File.join(@tmp, ".env")
    File.write(@env_path, "RUNPOD_API_KEY=test\n")
    @now = Time.utc(2026, 9, 13, 20, 0, 0)
    @clock = -> { @now }
    @client = FakeClient.new
    @state = LocalModelEvaluation::RunpodFleetState.new(root: @state_root, clock: @clock)
    @out = StringIO.new
    @lifecycle = LocalModelEvaluation::RunpodFleetLifecycle.new(
      client: @client,
      fleet_state: @state,
      env_path: @env_path,
      fleet_key: "default",
      local_port_base: 11_441,
      out: @out,
      sleeper: ->(_seconds) {},
      monotonic_clock: -> { 0.0 },
      wall_clock: @clock
    )
  end

  def teardown
    FileUtils.remove_entry(@tmp) if @tmp && File.exist?(@tmp)
  end

  def test_initial_create_persists_provisioning_profile_for_future_lifecycle_operations
    fleet = LocalModelEvaluation::RunpodFleet.new(
      client: @client,
      env_path: @env_path,
      out: @out,
      sleeper: ->(_seconds) {},
      clock: -> { 0.0 },
      state_root: @state_root,
      wall_clock: @clock
    )
    preflight = fleet.preflight(
      worker_count: 1,
      container_disk_gb: 50,
      volume_gb: 150,
      max_fleet_hourly_usd: 1.0
    )
    fleet.create(
      worker_count: 1,
      ssh_public_key: public_key,
      preflight:,
      container_disk_gb: 50,
      volume_gb: 150,
      max_fleet_hourly_usd: 1.0
    )

    assert_equal(
      { "container_disk_gb" => 50, "volume_gb" => 150 },
      @state.current.fetch("provisioning")
    )
  end

  def test_scale_grows_contiguous_slots_with_recorded_storage_profile
    activate([worker(1, "old_1"), worker(2, "old_2")])

    preflight = @lifecycle.preflight_scale(target_worker_count: 4, max_fleet_hourly_usd: 3.0)
    assert_equal [3, 4], preflight.worker_indices
    assert_equal 50, preflight.container_disk_gb
    assert_equal 150, preflight.volume_gb
    assert_in_delta 2.0, preflight.projected_fleet_hourly_rate, 0.0001

    added = @lifecycle.scale(
      target_worker_count: 4,
      ssh_public_key: public_key,
      preflight:,
      max_fleet_hourly_usd: 3.0
    )

    assert_equal [3, 4], added.map(&:index)
    state = @state.current
    assert_equal [1, 2, 3, 4], state.fetch("workers").map { |entry| entry.fetch("index") }
    assert_equal 4, state.fetch("worker_count")
    assert_in_delta 2.0, state.fetch("fleet_hourly_rate_usd"), 0.0001
    assert @client.created_bodies.last(2).all? { |body| body.fetch("disk") == 50 }
    assert @client.created_bodies.last(2).all? { |body| body.dig("mounts", "persistent", "size") == 150 }
    env = File.read(@env_path)
    assert_includes env, "RUNPOD_BURST_4_POD_ID=new_4_2"
    assert_includes env, "LME_BURST_4_URL=http://127.0.0.1:11444"
  end



  def test_scale_can_add_different_gpu_workers_on_existing_network_volume
    initial = [worker(1, "old_1"), worker(2, "old_2")]
    initial.each { |entry| @client.seed(entry) }
    @state.activate(
      workers: initial,
      cloud: "SECURE",
      gpu_id: "NVIDIA A40",
      image: LocalModelEvaluation::RunpodFleet::IMAGE,
      provisioning: {
        "container_disk_gb" => 50,
        "volume_gb" => nil,
        "network_volume_id" => "nv-shared-001",
        "volume_mount_path" => LocalModelEvaluation::RunpodFleet::VOLUME_MOUNT_PATH
      }
    )

    preflight = @lifecycle.preflight_scale(
      target_worker_count: 3,
      gpu_id: "NVIDIA RTX A6000",
      max_fleet_hourly_usd: 3.0
    )
    assert_equal "NVIDIA RTX A6000", preflight.gpu.fetch("id")
    assert_equal "nv-shared-001", preflight.network_volume_id
    assert_nil preflight.volume_gb

    added = @lifecycle.scale(
      target_worker_count: 3,
      ssh_public_key: public_key,
      preflight:,
      max_fleet_hourly_usd: 3.0
    )

    assert_equal [3], added.map(&:index)
    body = @client.created_bodies.last
    assert_equal "NVIDIA RTX A6000", body.dig("gpu", "id")
    assert_equal(
      [{ "volumeId" => "nv-shared-001", "path" => LocalModelEvaluation::RunpodFleet::VOLUME_MOUNT_PATH }],
      body.dig("mounts", "network")
    )
    refute body.fetch("mounts").key?("persistent")

    record = @state.current.fetch("workers").find { |entry| entry.fetch("index") == 3 }
    assert_equal "NVIDIA RTX A6000", record.fetch("gpu_id")
  end

  def test_scale_rolls_back_only_newly_created_pods_and_leaves_state_unchanged
    activate([worker(1, "old_1"), worker(2, "old_2")])
    before = Marshal.load(Marshal.dump(@state.current))
    @client.fail_create_on_call = 2
    preflight = @lifecycle.preflight_scale(target_worker_count: 4, max_fleet_hourly_usd: 3.0)

    error = assert_raises(LocalModelEvaluation::RunpodFleetLifecycle::Error) do
      @lifecycle.scale(
        target_worker_count: 4,
        ssh_public_key: public_key,
        preflight:,
        max_fleet_hourly_usd: 3.0
      )
    end

    assert_includes error.message, "capacity disappeared"
    assert_equal ["new_3_1"], @client.deleted_ids
    assert_equal before, @state.current
    assert_nil env_value("RUNPOD_BURST_3_POD_ID")
    assert_nil env_value("RUNPOD_BURST_4_POD_ID")
  end

  def test_scale_refuses_to_grow_around_an_inactive_existing_slot
    activate([worker(1, "old_1"), worker(2, "old_2")])
    @state.mark_destroyed([2])

    error = assert_raises(LocalModelEvaluation::RunpodFleetLifecycle::Error) do
      @lifecycle.preflight_scale(target_worker_count: 3, max_fleet_hourly_usd: 3.0)
    end

    assert_includes error.message, "replace inactive slot(s) before scaling"
    assert_empty @client.created_bodies
  end

  def test_replace_preserves_logical_slot_and_records_physical_generation
    activate([worker(1, "old_1"), worker(2, "old_2")])
    preflight = @lifecycle.preflight_replace(worker_index: 2, max_fleet_hourly_usd: 3.0)
    @client.events.clear

    replacement = @lifecycle.replace(
      worker_index: 2,
      ssh_public_key: public_key,
      preflight:,
      max_fleet_hourly_usd: 3.0
    )

    assert_equal 2, replacement.index
    assert_equal ["delete", "old_2"], @client.events.fetch(0)
    assert_equal ["create", "af-lme-burst-2"], @client.events.fetch(1)
    state = @state.current
    current = state.fetch("workers").find { |entry| entry.fetch("index") == 2 }
    assert_equal "new_2_1", current.fetch("pod_id")
    assert_equal 2, current.fetch("generation")
    assert_equal "old_2", current.fetch("history").last.fetch("pod_id")
    assert_equal "http://127.0.0.1:11442", current.fetch("local_ollama_url")
    assert_equal "new_2_1", env_value("RUNPOD_BURST_2_POD_ID")
  end

  def test_failed_replacement_leaves_slot_explicitly_destroyed_and_retryable
    activate([worker(1, "old_1"), worker(2, "old_2")])
    preflight = @lifecycle.preflight_replace(worker_index: 2, max_fleet_hourly_usd: 3.0)
    @client.fail_next_create = true

    error = assert_raises(LocalModelEvaluation::RunpodFleetLifecycle::Error) do
      @lifecycle.replace(
        worker_index: 2,
        ssh_public_key: public_key,
        preflight:,
        max_fleet_hourly_usd: 3.0
      )
    end
    assert_includes error.message, "capacity disappeared"

    state = @state.current
    slot = state.fetch("workers").find { |entry| entry.fetch("index") == 2 }
    assert_equal "destroyed", slot.fetch("status")
    assert_equal true, slot.fetch("replacement_pending")
    assert_in_delta 0.5, state.fetch("fleet_hourly_rate_usd"), 0.0001
    assert_nil env_value("RUNPOD_BURST_2_POD_ID")
  end

  def test_lifecycle_refuses_legacy_fleet_without_provisioning_metadata
    @state.activate(
      workers: [worker(1, "old_1")],
      cloud: "SECURE",
      gpu_id: "NVIDIA A40",
      image: LocalModelEvaluation::RunpodFleet::IMAGE
    )
    @client.seed(worker(1, "old_1"))

    error = assert_raises(LocalModelEvaluation::RunpodFleetLifecycle::Error) do
      @lifecycle.preflight_scale(target_worker_count: 2)
    end
    assert_includes error.message, "predates recorded provisioning metadata"
    assert_empty @client.created_bodies
  end

  def test_scale_and_replace_keep_spend_lease_conservative_across_generations
    activate(
      [worker(1, "old_1")],
      lease: {
        "started_at_utc" => @now.iso8601,
        "max_runtime_seconds" => 3600.0,
        "max_spend_usd" => 10.0
      }
    )
    @now += 600
    scale_preflight = @lifecycle.preflight_scale(target_worker_count: 2, max_fleet_hourly_usd: 3.0)
    @lifecycle.scale(target_worker_count: 2, ssh_public_key: public_key, preflight: scale_preflight, max_fleet_hourly_usd: 3.0)
    @now += 600
    replace_preflight = @lifecycle.preflight_replace(worker_index: 1, max_fleet_hourly_usd: 3.0)
    @lifecycle.replace(worker_index: 1, ssh_public_key: public_key, preflight: replace_preflight, max_fleet_hourly_usd: 3.0)
    @now += 600

    lease = LocalModelEvaluation::RunpodLease.snapshot_for(fleet: @state.current, now: @now)
    # burst_1: 30 minutes total at $0.50/hr = $0.25; burst_2: 20 minutes at $0.50/hr = $0.166667
    assert_in_delta 0.416667, lease.fetch("estimated_spend_usd"), 0.00001
  end

  private

  def activate(workers, lease: nil)
    workers.each { |entry| @client.seed(entry) }
    @state.activate(
      workers:,
      cloud: "SECURE",
      gpu_id: "NVIDIA A40",
      image: LocalModelEvaluation::RunpodFleet::IMAGE,
      lease:,
      provisioning: {
        "container_disk_gb" => 50,
        "volume_gb" => 150
      }
    )
  end

  def worker(index, pod_id)
    LocalModelEvaluation::RunpodFleet::Worker.new(
      index:,
      pod_id:,
      name: "af-lme-burst-#{index}",
      host: "198.51.100.#{10 + index}",
      ssh_port: 22_000 + index,
      hourly_rate: 0.50
    )
  end

  def public_key
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAITest lifecycle@example"
  end

  def env_value(key)
    File.readlines(@env_path, chomp: true).reverse_each do |line|
      return line.split("=", 2).last if line.start_with?("#{key}=")
    end
    nil
  end
end
