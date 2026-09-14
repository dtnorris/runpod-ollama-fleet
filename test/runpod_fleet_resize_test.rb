# frozen_string_literal: true

require_relative "test_helper"
require "stringio"
require_relative "../lib/local_model_evaluation/runpod_fleet_lifecycle"

class RunpodFleetResizeTest < Minitest::Test
  class FakeClient
    attr_reader :created_bodies, :deleted_ids, :catalog_calls

    def initialize
      @created_bodies = []
      @deleted_ids = []
      @catalog_calls = []
      @pods = {}
      @sequence = 0
    end

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
      [{
        "id" => "NVIDIA A40",
        "memory" => 48,
        cloud.downcase => true,
        "availability" => "HIGH",
        "price" => { cloud.downcase => 0.50 }
      }]
    end

    def create_pod(body)
      @created_bodies << Marshal.load(Marshal.dump(body))
      @sequence += 1
      index = body.fetch("name")[/burst-(\d+)\z/, 1].to_i
      id = "new_#{index}_#{@sequence}"
      @pods[id] = ready_pod(
        index,
        id,
        "198.51.100.#{50 + index}",
        23_000 + index,
        0.50,
        cloud: body.fetch("cloud")
      )
      { "id" => id }
    end

    def get_pod(pod_id)
      @pods.fetch(pod_id) do
        raise LocalModelEvaluation::RunpodClient::Error.new(404, "not found")
      end
    end

    def delete_pod(pod_id)
      @deleted_ids << pod_id
      @pods.delete(pod_id)
      { "id" => pod_id, "status" => "TERMINATED" }
    end

    private

    def ready_pod(index, id, host, port, rate, cloud: "SECURE")
      {
        "id" => id,
        "name" => "af-lme-burst-#{index}",
        "status" => "RUNNING",
        "cloud" => cloud,
        "gpu" => { "id" => "NVIDIA A40", "count" => 1 },
        "cost" => rate,
        "runtime" => {
          "ports" => [{ "private" => 22, "public" => port, "type" => "tcp", "ip" => host }]
        }
      }
    end
  end

  def setup
    @tmp = Dir.mktmpdir("runpod-resize-")
    @state_root = File.join(@tmp, "state")
    @env_path = File.join(@tmp, ".env")
    File.write(@env_path, "RUNPOD_API_KEY=test\n")
    @now = Time.utc(2026, 9, 13, 22, 0, 0)
    @clock = -> { @now }
    @client = FakeClient.new
    @state = LocalModelEvaluation::RunpodFleetState.new(root: @state_root, clock: @clock)
    @lifecycle = LocalModelEvaluation::RunpodFleetLifecycle.new(
      client: @client,
      fleet_state: @state,
      env_path: @env_path,
      fleet_key: "default",
      local_port_base: 11_441,
      out: StringIO.new,
      sleeper: ->(_seconds) {},
      monotonic_clock: -> { 0.0 },
      wall_clock: @clock
    )
  end

  def teardown
    FileUtils.remove_entry(@tmp) if @tmp && File.exist?(@tmp)
  end

  def test_shrink_retires_only_tail_slots_and_regrow_preserves_generation_history
    activate((1..4).map { |index| worker(index, "old_#{index}") })

    down = @lifecycle.preflight_scale(target_worker_count: 2, max_fleet_hourly_usd: 0.25)
    assert_equal "down", down.scale_direction
    assert_equal [4, 3], down.worker_indices
    assert_in_delta 1.0, down.projected_fleet_hourly_rate, 0.0001
    assert_empty @client.catalog_calls

    retired = @lifecycle.shrink(target_worker_count: 2, preflight: down)

    assert_equal [4, 3], retired
    assert_equal %w[old_4 old_3], @client.deleted_ids
    state = @state.current
    assert_equal [1, 2], state.fetch("workers").map { |entry| entry.fetch("index") }
    assert_equal 2, state.fetch("worker_count")
    assert_in_delta 1.0, state.fetch("fleet_hourly_rate_usd"), 0.0001
    assert_equal [4, 3], state.fetch("retired_workers").map { |entry| entry.fetch("index") }

    up = @lifecycle.preflight_scale(target_worker_count: 4, max_fleet_hourly_usd: 3.0)
    assert_equal "up", up.scale_direction
    @lifecycle.scale(
      target_worker_count: 4,
      ssh_public_key: public_key,
      preflight: up,
      max_fleet_hourly_usd: 3.0
    )

    current = @state.current.fetch("workers").to_h { |entry| [entry.fetch("index"), entry] }
    assert_equal [1, 2, 3, 4], current.keys.sort
    assert_equal 2, current.fetch(3).fetch("generation")
    assert_equal "old_3", current.fetch(3).fetch("history").last.fetch("pod_id")
    assert_equal 2, current.fetch(4).fetch("generation")
    assert_equal "old_4", current.fetch(4).fetch("history").last.fetch("pod_id")
  end

  def test_shrink_preserves_retired_spend_and_is_allowed_after_lease_expiry
    activate(
      (1..4).map { |index| worker(index, "old_#{index}") },
      lease: {
        "started_at_utc" => @now.iso8601,
        "max_runtime_seconds" => 300.0,
        "max_spend_usd" => 10.0
      }
    )
    @now += 600

    preflight = @lifecycle.preflight_scale(target_worker_count: 2, max_fleet_hourly_usd: 0.25)
    @lifecycle.shrink(target_worker_count: 2, preflight:)

    lease = LocalModelEvaluation::RunpodLease.snapshot_for(fleet: @state.current, now: @now)
    assert_equal "expired", lease.fetch("status")
    assert_equal [1, 2], lease.fetch("active_worker_indices")
    assert_in_delta 0.333333, lease.fetch("estimated_spend_usd"), 0.00001
  end

  def test_shrink_refuses_to_leave_inactive_slot_in_retained_prefix
    activate((1..4).map { |index| worker(index, "old_#{index}") })
    @state.mark_destroyed([2])

    error = assert_raises(LocalModelEvaluation::RunpodFleetLifecycle::Error) do
      @lifecycle.preflight_scale(target_worker_count: 3, max_fleet_hourly_usd: 3.0)
    end

    assert_includes error.message, "retained slot(s) are inactive"
    assert_empty @client.deleted_ids
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
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAITest resize@example"
  end
end
