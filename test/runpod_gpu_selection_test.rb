# frozen_string_literal: true

require_relative "test_helper"
require "stringio"
require "tmpdir"
require "fileutils"
require_relative "../lib/local_model_evaluation/runpod_fleet"
require_relative "../lib/local_model_evaluation/runpod_fleet_lifecycle"

class RunpodGpuSelectionTest < Minitest::Test
  class FakeClient
    attr_reader :created_bodies, :deleted_ids

    def initialize
      @created_bodies = []
      @deleted_ids = []
      @pods = {}
      @sequence = 0
    end

    def list_pods
      @pods.values.map { |pod| Marshal.load(Marshal.dump(pod)) }
    end

    def list_gpu_types(cloud:, count:)
      [
        gpu("NVIDIA A40", cloud, 0.69),
        gpu("NVIDIA RTX A6000", cloud, 0.53)
      ]
    end

    def create_pod(body)
      @created_bodies << Marshal.load(Marshal.dump(body))
      @sequence += 1
      index = body.fetch("name")[/burst-(\d+)\z/, 1].to_i
      pod_id = "pod_#{index}_#{@sequence}"
      @pods[pod_id] = ready_pod(
        index:,
        pod_id:,
        cloud: body.fetch("cloud"),
        gpu_id: body.dig("gpu", "id"),
        rate: body.dig("gpu", "id") == "NVIDIA RTX A6000" ? 0.53 : 0.69
      )
      { "id" => pod_id }
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

    def seed(index:, pod_id:, cloud:, gpu_id:, rate:)
      @pods[pod_id] = ready_pod(index:, pod_id:, cloud:, gpu_id:, rate:)
    end

    private

    def gpu(id, cloud, rate)
      {
        "id" => id,
        "memory" => 48,
        cloud.downcase => true,
        "availability" => "HIGH",
        "price" => { cloud.downcase => rate }
      }
    end

    def ready_pod(index:, pod_id:, cloud:, gpu_id:, rate:)
      {
        "id" => pod_id,
        "name" => "af-lme-burst-#{index}",
        "status" => "RUNNING",
        "cloud" => cloud,
        "gpu" => { "id" => gpu_id, "count" => 1 },
        "cost" => rate,
        "runtime" => {
          "ports" => [{ "private" => 22, "public" => 22_000 + index, "type" => "tcp", "ip" => "198.51.100.#{index}" }]
        }
      }
    end
  end

  def setup
    @tmp = Dir.mktmpdir("runpod-gpu-selection-")
    @env_path = File.join(@tmp, ".env")
    @state_root = File.join(@tmp, "state")
    File.write(@env_path, "RUNPOD_API_KEY=test\n")
    @client = FakeClient.new
    @out = StringIO.new
  end

  def teardown
    FileUtils.remove_entry(@tmp) if @tmp && File.exist?(@tmp)
  end

  def test_explicit_gpu_selects_and_persists_a6000_while_default_remains_a40
    fleet = build_fleet
    assert_equal LocalModelEvaluation::RunpodFleet::GPU_ID, fleet.gpu_id

    fleet.gpu_id = "NVIDIA RTX A6000"
    preflight = fleet.preflight(worker_count: 1, max_fleet_hourly_usd: 1.0)
    assert_equal "NVIDIA RTX A6000", preflight.gpu.fetch("id")
    assert_in_delta 0.53, preflight.hourly_rate, 0.0001

    fleet.create(
      worker_count: 1,
      ssh_public_key: public_key,
      preflight:,
      max_fleet_hourly_usd: 1.0,
      wait_seconds: 0
    )

    assert_equal "NVIDIA RTX A6000", @client.created_bodies.fetch(0).dig("gpu", "id")
    assert_equal "NVIDIA RTX A6000", fleet.fleet_state.current.dig("gpu", "id")
  end

  def test_create_rejects_preflight_from_a_different_gpu_before_paid_mutation
    fleet = build_fleet
    preflight = fleet.preflight(worker_count: 1, max_fleet_hourly_usd: 1.0)
    fleet.gpu_id = "NVIDIA RTX A6000"

    error = assert_raises(LocalModelEvaluation::RunpodFleet::Error) do
      fleet.create(
        worker_count: 1,
        ssh_public_key: public_key,
        preflight:,
        max_fleet_hourly_usd: 1.0
      )
    end

    assert_includes error.message, "preflight GPU"
    assert_empty @client.created_bodies
  end

  def test_scale_uses_gpu_recorded_in_fleet_state_not_process_default
    state = LocalModelEvaluation::RunpodFleetState.new(root: @state_root)
    worker = LocalModelEvaluation::RunpodFleet::Worker.new(
      index: 1,
      pod_id: "old_1",
      name: "af-lme-burst-1",
      host: "198.51.100.1",
      ssh_port: 22_001,
      hourly_rate: 0.53
    )
    @client.seed(index: 1, pod_id: "old_1", cloud: "SECURE", gpu_id: "NVIDIA RTX A6000", rate: 0.53)
    state.activate(
      workers: [worker],
      cloud: "SECURE",
      gpu_id: "NVIDIA RTX A6000",
      image: LocalModelEvaluation::RunpodFleet::IMAGE,
      provisioning: { "container_disk_gb" => 50, "volume_gb" => 150 }
    )

    lifecycle = LocalModelEvaluation::RunpodFleetLifecycle.new(
      client: @client,
      fleet_state: state,
      env_path: @env_path,
      fleet_key: "default",
      local_port_base: 11_441,
      out: @out,
      sleeper: ->(_seconds) {},
      monotonic_clock: -> { 0.0 }
    )
    preflight = lifecycle.preflight_scale(target_worker_count: 2, max_fleet_hourly_usd: 2.0)
    assert_equal "NVIDIA RTX A6000", preflight.gpu.fetch("id")

    lifecycle.scale(
      target_worker_count: 2,
      ssh_public_key: public_key,
      preflight:,
      max_fleet_hourly_usd: 2.0,
      wait_seconds: 0
    )

    assert_equal "NVIDIA RTX A6000", @client.created_bodies.last.dig("gpu", "id")

    replace_preflight = lifecycle.preflight_replace(worker_index: 1, max_fleet_hourly_usd: 2.0)
    lifecycle.replace(
      worker_index: 1,
      ssh_public_key: public_key,
      preflight: replace_preflight,
      max_fleet_hourly_usd: 2.0,
      wait_seconds: 0
    )

    assert_equal "NVIDIA RTX A6000", @client.created_bodies.last.dig("gpu", "id")
    assert_equal "NVIDIA RTX A6000", state.current.dig("gpu", "id")
  end

  private

  def build_fleet
    LocalModelEvaluation::RunpodFleet.new(
      client: @client,
      env_path: @env_path,
      state_root: @state_root,
      out: @out,
      sleeper: ->(_seconds) {},
      clock: -> { 0.0 }
    )
  end

  def public_key
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAITest gpu@example"
  end
end
