# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "stringio"
require "fileutils"
require_relative "../lib/local_model_evaluation/runpod_client"
require_relative "../lib/local_model_evaluation/runpod_fleet"

class RunpodFleetTest < Minitest::Test
  class FakeClient
    attr_accessor :pods, :gpu_types, :create_responses, :pod_details, :create_error_at, :create_interrupt_at
    attr_reader :created_bodies, :deleted_ids, :catalog_calls

    def initialize
      @pods = []
      @gpu_types = [
        {
          "id" => "NVIDIA A40",
          "name" => "A40",
          "memory" => 48,
          "community" => true,
          "secure" => true,
          "availability" => "HIGH",
          "price" => { "community" => 0.44, "secure" => 0.69 }
        }
      ]
      @create_responses = []
      @pod_details = {}
      @created_bodies = []
      @deleted_ids = []
      @catalog_calls = []
      @create_error_at = nil
      @create_interrupt_at = nil
    end

    def list_pods
      @pods
    end

    def list_gpu_types(cloud:, count:)
      @catalog_calls << [cloud, count]
      @gpu_types
    end

    def create_pod(body)
      @created_bodies << Marshal.load(Marshal.dump(body))
      raise Interrupt if @create_interrupt_at == @created_bodies.length
      if @create_error_at == @created_bodies.length
        raise LocalModelEvaluation::RunpodClient::Error.new(400, "capacity disappeared")
      end
      @create_responses.shift || { "id" => "pod_#{@created_bodies.length}" }
    end

    def get_pod(pod_id)
      value = @pod_details.fetch(pod_id) do
        raise LocalModelEvaluation::RunpodClient::Error.new(404, "not found")
      end
      value.respond_to?(:call) ? value.call : value
    end

    def delete_pod(pod_id)
      @deleted_ids << pod_id
      { "id" => pod_id, "status" => "TERMINATED" }
    end
  end

  def setup
    @tmp = Dir.mktmpdir("lme-runpod-fleet-")
    @env_path = File.join(@tmp, ".env")
    File.write(@env_path, <<~ENV)
      RUNPOD_API_KEY=rpa_keep_me
      LME_BURST_1_URL=http://127.0.0.1:11441
      RUNPOD_BURST_1_HOST=stale.example
      RUNPOD_BURST_1_SSH_PORT=29999
      LME_HEARTBEAT_SECONDS=10
    ENV
    @client = FakeClient.new
    @out = StringIO.new
    @fleet = LocalModelEvaluation::RunpodFleet.new(
      client: @client,
      env_path: @env_path,
      out: @out,
      sleeper: ->(_seconds) {},
      clock: -> { 0.0 }
    )
  end

  def teardown
    FileUtils.remove_entry(@tmp) if @tmp && File.exist?(@tmp)
  end

  def test_preflight_defaults_to_secure
    result = @fleet.preflight(worker_count: 5, max_fleet_hourly_usd: 4.0)

    assert_equal 5, result.worker_count
    assert_equal "NVIDIA A40", result.gpu.fetch("id")
    assert_equal "SECURE", result.cloud
    assert_equal "HIGH", result.availability
    assert_in_delta 0.69, result.hourly_rate, 0.0001
    assert_in_delta 3.45, result.fleet_hourly_rate, 0.0001
    assert_equal 30, result.container_disk_gb
    assert_equal 60, result.volume_gb
    assert_equal [["SECURE", 5]], @client.catalog_calls
    assert_empty @client.created_bodies
  end

  def test_preflight_supports_canonical_bounds_and_computes_twelve_worker_cost
    [1, 8, 12, 16].each do |worker_count|
      result = @fleet.preflight(worker_count:, cloud: "COMMUNITY", max_fleet_hourly_usd: 8.0)
      assert_equal worker_count, result.worker_count
    end
    twelve = @fleet.preflight(worker_count: 12, cloud: "COMMUNITY", max_fleet_hourly_usd: 8.0)
    assert_in_delta 0.44 * 12, twelve.fleet_hourly_rate, 0.0001
    assert_includes @client.catalog_calls, ["COMMUNITY", 12]

    [0, 17].each do |worker_count|
      error = assert_raises(LocalModelEvaluation::RunpodFleet::Error) do
        @fleet.preflight(worker_count:, max_fleet_hourly_usd: 8.0)
      end
      assert_includes error.message, "between 1 and 16"
    end
  end

  def test_destroy_safely_addresses_workers_twelve_and_sixteen
    @client.pods = [
      ready_pod(12, "pod_12", "198.51.100.12", 22_012, 0.44),
      ready_pod(16, "pod_16", "198.51.100.16", 22_016, 0.44)
    ]

    assert_equal [12, 16], @fleet.destroy(worker_indices: [12, 16])
    assert_equal ["pod_12", "pod_16"], @client.deleted_ids
  end

  def test_preflight_allows_community_when_explicitly_requested
    result = @fleet.preflight(worker_count: 5, cloud: "community", max_fleet_hourly_usd: 3.0)

    assert_equal "COMMUNITY", result.cloud
    assert_in_delta 0.44, result.hourly_rate, 0.0001
    assert_in_delta 2.20, result.fleet_hourly_rate, 0.0001
    assert_equal [["COMMUNITY", 5]], @client.catalog_calls
    assert_empty @client.created_bodies
  end

  def test_preflight_never_silently_falls_back_from_community_to_secure
    @client.gpu_types.first["community"] = false
    @client.gpu_types.first["secure"] = true

    error = assert_raises(LocalModelEvaluation::RunpodFleet::Error) do
      @fleet.preflight(worker_count: 1, cloud: "COMMUNITY")
    end

    assert_includes error.message, "not available on COMMUNITY cloud"
    assert_equal [["COMMUNITY", 1]], @client.catalog_calls
    assert_empty @client.created_bodies
  end

  def test_preflight_rejects_unknown_cloud_before_any_api_call
    error = assert_raises(LocalModelEvaluation::RunpodFleet::Error) do
      @fleet.preflight(worker_count: 1, cloud: "AUTO")
    end

    assert_includes error.message, "cloud must be one of: COMMUNITY, SECURE"
    assert_empty @client.catalog_calls
    assert_empty @client.created_bodies
  end

  def test_preflight_rejects_non_positive_storage_before_any_api_call
    error = assert_raises(LocalModelEvaluation::RunpodFleet::Error) do
      @fleet.preflight(worker_count: 1, container_disk_gb: 0)
    end
    assert_includes error.message, "container disk size must be a positive integer"

    error = assert_raises(LocalModelEvaluation::RunpodFleet::Error) do
      @fleet.preflight(worker_count: 1, volume_gb: -1)
    end
    assert_includes error.message, "workspace volume size must be a positive integer"

    assert_empty @client.catalog_calls
    assert_empty @client.created_bodies
  end

  def test_preflight_preserves_requested_storage_sizes
    result = @fleet.preflight(worker_count: 1, container_disk_gb: 50, volume_gb: 150)

    assert_equal 50, result.container_disk_gb
    assert_equal 150, result.volume_gb
    assert_empty @client.created_bodies
  end

  def test_preflight_aborts_before_creation_when_cost_exceeds_cap
    error = assert_raises(LocalModelEvaluation::RunpodFleet::Error) do
      @fleet.preflight(worker_count: 5, max_fleet_hourly_usd: 2.00)
    end

    assert_includes error.message, "exceeds safety cap"
    assert_empty @client.created_bodies
  end

  def test_preflight_refuses_duplicate_managed_pod
    @client.pods = [{ "id" => "pod_existing", "name" => "af-lme-burst-1" }]

    error = assert_raises(LocalModelEvaluation::RunpodFleet::Error) do
      @fleet.preflight(worker_count: 2)
    end

    assert_includes error.message, "duplicate managed pods"
    assert_empty @client.created_bodies
  end

  def test_successful_create_uses_pinned_v2_shape_and_atomically_hydrates_env
    @client.create_responses = [{ "id" => "pod_a" }, { "id" => "pod_b" }]
    @client.pod_details = {
      "pod_a" => ready_pod(1, "pod_a", "198.51.100.11", 22011, 0.44, cloud: "SECURE"),
      "pod_b" => ready_pod(2, "pod_b", "198.51.100.12", 22012, 0.45, cloud: "SECURE")
    }
    before_key = File.read(@env_path).lines.first
    preflight = @fleet.preflight(worker_count: 2)

    workers = @fleet.create(
      worker_count: 2,
      ssh_public_key: "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAITest test@example",
      preflight:,
      max_fleet_hourly_usd: 3.0
    )

    assert_equal 2, workers.length
    first_body = @client.created_bodies.first
    assert_equal "af-lme-burst-1", first_body.fetch("name")
    assert_equal LocalModelEvaluation::RunpodFleet::IMAGE, first_body.fetch("image")
    assert_equal 30, first_body.fetch("disk")
    assert_equal ["22/tcp"], first_body.fetch("ports")
    assert_equal "SECURE", first_body.fetch("cloud")
    assert_equal({ "id" => "NVIDIA A40", "count" => 1 }, first_body.fetch("gpu"))
    assert_equal({ "persistent" => { "size" => 60, "path" => "/workspace" } }, first_body.fetch("mounts"))
    assert first_body.dig("env", "PUBLIC_KEY").start_with?("ssh-ed25519 ")

    env = File.read(@env_path)
    assert_includes env, before_key.strip
    assert_includes env, "RUNPOD_BURST_1_POD_ID=pod_a"
    assert_includes env, "RUNPOD_BURST_1_HOST=198.51.100.11"
    assert_includes env, "RUNPOD_BURST_1_SSH_PORT=22011"
    assert_includes env, "RUNPOD_BURST_1_HOURLY_RATE=0.440000"
    assert_includes env, "LME_BURST_2_URL=http://127.0.0.1:11442"
    assert_includes env, "RUNPOD_BURST_2_POD_ID=pod_b"
    refute_includes env, "RUNPOD_BURST_1_HOST=stale.example"
  end

  def test_create_uses_requested_storage_sizes
    @client.create_responses = [{ "id" => "pod_storage" }]
    @client.pod_details = {
      "pod_storage" => ready_pod(1, "pod_storage", "198.51.100.31", 22031, 0.69, cloud: "SECURE")
    }
    preflight = @fleet.preflight(
      worker_count: 1,
      max_fleet_hourly_usd: 1.0,
      container_disk_gb: 50,
      volume_gb: 150
    )

    @fleet.create(
      worker_count: 1,
      ssh_public_key: "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAITest test@example",
      preflight:,
      max_fleet_hourly_usd: 1.0,
      container_disk_gb: 50,
      volume_gb: 150
    )

    body = @client.created_bodies.fetch(0)
    assert_equal 50, body.fetch("disk")
    assert_equal 150, body.dig("mounts", "persistent", "size")
  end

  def test_secure_create_preserves_explicit_tier_in_request_and_readiness
    @client.create_responses = [{ "id" => "pod_secure" }]
    @client.pod_details = {
      "pod_secure" => ready_pod(1, "pod_secure", "198.51.100.21", 22021, 0.69, cloud: "SECURE")
    }
    preflight = @fleet.preflight(worker_count: 1, cloud: "SECURE", max_fleet_hourly_usd: 1.0)

    workers = @fleet.create(
      worker_count: 1,
      cloud: "SECURE",
      ssh_public_key: "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAITest test@example",
      preflight:,
      max_fleet_hourly_usd: 1.0
    )

    assert_equal "SECURE", @client.created_bodies.first.fetch("cloud")
    assert_equal 1, workers.length
    assert_empty @client.deleted_ids
  end

  def test_create_rejects_preflight_for_a_different_cloud_before_paid_mutation
    preflight = @fleet.preflight(worker_count: 1, cloud: "SECURE", max_fleet_hourly_usd: 1.0)

    error = assert_raises(LocalModelEvaluation::RunpodFleet::Error) do
      @fleet.create(
        worker_count: 1,
        cloud: "COMMUNITY",
        ssh_public_key: "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAITest test@example",
        preflight:
      )
    end

    assert_includes error.message, "preflight cloud SECURE does not match requested cloud COMMUNITY"
    assert_empty @client.created_bodies
  end

  def test_create_rejects_preflight_for_different_storage_before_paid_mutation
    preflight = @fleet.preflight(
      worker_count: 1,
      max_fleet_hourly_usd: 1.0,
      container_disk_gb: 50,
      volume_gb: 150
    )

    error = assert_raises(LocalModelEvaluation::RunpodFleet::Error) do
      @fleet.create(
        worker_count: 1,
        ssh_public_key: "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAITest test@example",
        preflight:,
        max_fleet_hourly_usd: 1.0,
        container_disk_gb: 50,
        volume_gb: 160
      )
    end

    assert_includes error.message, "preflight workspace volume 150 GB does not match requested 160 GB"
    assert_empty @client.created_bodies
  end

  def test_partial_create_failure_rolls_back_and_leaves_env_unchanged
    original = File.read(@env_path)
    @client.create_responses = [{ "id" => "pod_a" }]
    @client.create_error_at = 2
    preflight = @fleet.preflight(worker_count: 2)

    assert_raises(LocalModelEvaluation::RunpodClient::Error) do
      @fleet.create(
        worker_count: 2,
        ssh_public_key: "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAITest test@example",
        preflight:
      )
    end

    assert_equal ["pod_a"], @client.deleted_ids
    assert_equal original, File.read(@env_path)
    assert_includes @out.string, "Local .env was not updated"
  end

  def test_interrupt_during_creation_rolls_back_paid_pods_and_leaves_env_unchanged
    original = File.read(@env_path)
    @client.create_responses = [{ "id" => "pod_a" }]
    @client.create_interrupt_at = 2
    preflight = @fleet.preflight(worker_count: 2)

    assert_raises(Interrupt) do
      @fleet.create(
        worker_count: 2,
        ssh_public_key: "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAITest test@example",
        preflight:
      )
    end

    assert_equal ["pod_a"], @client.deleted_ids
    assert_equal original, File.read(@env_path)
  end

  def test_wrong_cloud_during_readiness_rolls_back_every_created_pod
    original = File.read(@env_path)
    @client.create_responses = [{ "id" => "pod_a" }]
    @client.pod_details = {
      "pod_a" => ready_pod(1, "pod_a", "198.51.100.11", 22011, 0.44, cloud: "COMMUNITY")
    }
    preflight = @fleet.preflight(worker_count: 1)

    error = assert_raises(LocalModelEvaluation::RunpodFleet::Error) do
      @fleet.create(
        worker_count: 1,
        ssh_public_key: "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAITest test@example",
        preflight:
      )
    end

    assert_includes error.message, "cloud mismatch"
    assert_equal ["pod_a"], @client.deleted_ids
    assert_equal original, File.read(@env_path)
  end

  def test_wrong_gpu_during_readiness_rolls_back_every_created_pod
    original = File.read(@env_path)
    @client.create_responses = [{ "id" => "pod_a" }]
    bad = ready_pod(1, "pod_a", "198.51.100.11", 22011, 0.44, cloud: "SECURE")
    bad["gpu"] = { "id" => "NVIDIA A100", "count" => 1 }
    @client.pod_details = { "pod_a" => bad }
    preflight = @fleet.preflight(worker_count: 1)

    error = assert_raises(LocalModelEvaluation::RunpodFleet::Error) do
      @fleet.create(
        worker_count: 1,
        ssh_public_key: "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAITest test@example",
        preflight:
      )
    end

    assert_includes error.message, "GPU mismatch"
    assert_equal ["pod_a"], @client.deleted_ids
    assert_equal original, File.read(@env_path)
  end

  def test_destroy_verifies_name_deletes_and_clears_generated_routing_metadata
    File.open(@env_path, "a") do |f|
      f.puts "RUNPOD_BURST_1_POD_ID=pod_a"
      f.puts "RUNPOD_BURST_1_HOURLY_RATE=0.440000"
    end
    @client.pods = [{ "id" => "pod_a", "name" => "af-lme-burst-1" }]
    @client.pod_details = {
      "pod_a" => { "id" => "pod_a", "name" => "af-lme-burst-1" }
    }

    assert_equal [1], @fleet.destroy(worker_indices: [1])
    assert_equal ["pod_a"], @client.deleted_ids

    env = File.read(@env_path)
    assert_includes env, "RUNPOD_API_KEY=rpa_keep_me"
    assert_includes env, "LME_BURST_1_URL=http://127.0.0.1:11441"
    refute_includes env, "RUNPOD_BURST_1_POD_ID="
    refute_includes env, "RUNPOD_BURST_1_HOST="
    refute_includes env, "RUNPOD_BURST_1_SSH_PORT="
    refute_includes env, "RUNPOD_BURST_1_HOURLY_RATE="
  end

  def test_destroy_can_recover_a_managed_pod_by_exact_name_when_env_was_never_hydrated
    @client.pods = [{ "id" => "pod_recovery", "name" => "af-lme-burst-2" }]
    @client.pod_details = {}

    assert_equal [2], @fleet.destroy(worker_indices: [2])
    assert_equal ["pod_recovery"], @client.deleted_ids
  end

  def test_destroy_refuses_name_mismatch_from_env_pod_id
    File.open(@env_path, "a") { |f| f.puts "RUNPOD_BURST_1_POD_ID=pod_wrong" }
    @client.pod_details = {
      "pod_wrong" => { "id" => "pod_wrong", "name" => "someone-elses-pod" }
    }

    error = assert_raises(LocalModelEvaluation::RunpodFleet::Error) do
      @fleet.destroy(worker_indices: [1])
    end

    assert_includes error.message, "refusing to delete"
    assert_empty @client.deleted_ids
    assert_includes File.read(@env_path), "RUNPOD_BURST_1_POD_ID=pod_wrong"
  end

  def test_public_key_reader_rejects_private_or_invalid_content
    private_path = File.join(@tmp, "id_ed25519")
    File.write(private_path, "-----BEGIN OPENSSH PRIVATE KEY-----\nsecret\n")
    invalid_path = File.join(@tmp, "invalid.pub")
    File.write(invalid_path, "not-a-key\n")

    assert_raises(LocalModelEvaluation::RunpodFleet::Error) { @fleet.read_ssh_public_key(private_path) }
    assert_raises(LocalModelEvaluation::RunpodFleet::Error) { @fleet.read_ssh_public_key(invalid_path) }
  end

  private

  def ready_pod(index, pod_id, host, port, cost, cloud: "COMMUNITY")
    {
      "id" => pod_id,
      "name" => "af-lme-burst-#{index}",
      "status" => "RUNNING",
      "cloud" => cloud,
      "gpu" => { "id" => "NVIDIA A40", "count" => 1 },
      "cost" => cost,
      "runtime" => {
        "ports" => [
          { "private" => 22, "public" => port, "type" => "tcp", "ip" => host }
        ]
      }
    }
  end
end
