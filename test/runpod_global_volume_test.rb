# frozen_string_literal: true

require "json"
require "minitest/autorun"
require "stringio"
require "tmpdir"
require_relative "../lib/local_model_evaluation/runpod_client"
require_relative "../lib/local_model_evaluation/runpod_fleet"
require_relative "../lib/local_model_evaluation/runpod_fleet_lifecycle"

class RunpodGlobalVolumeTest < Minitest::Test
  GLOBAL_VOLUME_ID = "cmu4n7zhq000007lb6u7f43m9"
  PUBLIC_KEY = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAITest global@example"

  Response = Struct.new(:status, :body, keyword_init: true)

  class FakeFleetClient
    attr_reader :created_bodies

    def initialize
      @created_bodies = []
    end

    def list_pods
      []
    end

    def list_gpu_types(cloud:, count:)
      [{
        "id" => "NVIDIA A40",
        "name" => "A40",
        "memory" => 48,
        "secure" => true,
        "community" => true,
        "availability" => "HIGH",
        "price" => { "secure" => 0.49, "community" => 0.49 }
      }]
    end

    def create_pod(body)
      @created_bodies << Marshal.load(Marshal.dump(body))
      { "id" => "pod_global" }
    end

    def get_pod(pod_id)
      raise "unexpected pod id" unless pod_id == "pod_global"

      {
        "id" => pod_id,
        "name" => "af-lme-burst-1",
        "cloud" => "SECURE",
        "gpu" => { "id" => "NVIDIA A40", "count" => 1 },
        "status" => "RUNNING",
        "cost" => 0.49,
        "runtime" => {
          "ports" => [{
            "private" => 22,
            "public" => 22022,
            "type" => "tcp",
            "ip" => "198.51.100.20"
          }]
        }
      }
    end

    def delete_pod(_pod_id)
      {}
    end
  end

  def test_fleet_create_attaches_global_volume_without_default_workspace_volume
    Dir.mktmpdir("rpof-global-volume-") do |dir|
      client = FakeFleetClient.new
      fleet = LocalModelEvaluation::RunpodFleet.new(
        client:,
        env_path: File.join(dir, ".env"),
        state_root: File.join(dir, "state"),
        out: StringIO.new
      )

      preflight = fleet.preflight(
        worker_count: 1,
        global_volume_id: GLOBAL_VOLUME_ID,
        max_fleet_hourly_usd: 1.0
      )
      assert_nil preflight.volume_gb
      assert_nil preflight.network_volume_id
      assert_equal GLOBAL_VOLUME_ID, preflight.global_volume_id

      workers = fleet.create(
        worker_count: 1,
        ssh_public_key: PUBLIC_KEY,
        preflight:,
        global_volume_id: GLOBAL_VOLUME_ID,
        max_fleet_hourly_usd: 1.0,
        wait_seconds: 1,
        poll_seconds: 0.01
      )

      assert_equal 1, workers.length
      body = client.created_bodies.fetch(0)
      assert_equal({}, body.fetch("mounts"))
      assert_equal(
        [{
          "volumeId" => GLOBAL_VOLUME_ID,
          "volumeType" => "OBJECT_STORE_VOLUME",
          "mountPath" => "/workspace-global"
        }],
        body.fetch("volumeMounts")
      )

      provisioning = fleet.fleet_state.current.fetch("provisioning")
      assert_equal GLOBAL_VOLUME_ID, provisioning.fetch("global_volume_id")
      assert_equal "OBJECT_STORE_VOLUME", provisioning.fetch("global_volume_type")
      assert_equal "/workspace-global", provisioning.fetch("global_volume_mount_path")
    end
  end

  def test_global_volume_can_coexist_with_network_volume
    Dir.mktmpdir("rpof-global-network-volume-") do |dir|
      client = FakeFleetClient.new
      fleet = LocalModelEvaluation::RunpodFleet.new(
        client:,
        env_path: File.join(dir, ".env"),
        state_root: File.join(dir, "state"),
        out: StringIO.new
      )

      preflight = fleet.preflight(
        worker_count: 1,
        network_volume_id: "regional_cache",
        global_volume_id: GLOBAL_VOLUME_ID,
        max_fleet_hourly_usd: 1.0
      )
      fleet.create(
        worker_count: 1,
        ssh_public_key: PUBLIC_KEY,
        preflight:,
        network_volume_id: "regional_cache",
        global_volume_id: GLOBAL_VOLUME_ID,
        max_fleet_hourly_usd: 1.0,
        wait_seconds: 1,
        poll_seconds: 0.01
      )

      body = client.created_bodies.fetch(0)
      assert_equal(
        { "network" => [{ "volumeId" => "regional_cache", "path" => "/workspace" }] },
        body.fetch("mounts")
      )
      assert_equal "/workspace-global", body.fetch("volumeMounts").fetch(0).fetch("mountPath")
    end
  end

  def test_lifecycle_preserves_global_volume_for_scaled_workers
    Dir.mktmpdir("rpof-global-volume-lifecycle-") do |dir|
      lifecycle = LocalModelEvaluation::RunpodFleetLifecycle.new(
        client: Object.new,
        fleet_state: Object.new,
        env_path: File.join(dir, ".env"),
        fleet_key: "fixture",
        local_port_base: 11_441,
        out: StringIO.new
      )
      fleet = {
        "provisioning" => {
          "container_disk_gb" => 30,
          "volume_gb" => nil,
          "global_volume_id" => GLOBAL_VOLUME_ID,
          "global_volume_type" => "OBJECT_STORE_VOLUME",
          "global_volume_mount_path" => "/workspace-global"
        }
      }

      profile = lifecycle.send(:provisioning_profile!, fleet)
      assert_nil profile.fetch("volume_gb")
      assert_nil profile.fetch("network_volume_id")
      assert_equal GLOBAL_VOLUME_ID, profile.fetch("global_volume_id")

      body = lifecycle.send(
        :create_body,
        2,
        PUBLIC_KEY,
        "SECURE",
        profile:,
        gpu_id: "NVIDIA A40"
      )
      assert_equal({}, body.fetch("mounts"))
      assert_equal(
        [{
          "volumeId" => GLOBAL_VOLUME_ID,
          "volumeType" => "OBJECT_STORE_VOLUME",
          "mountPath" => "/workspace-global"
        }],
        body.fetch("volumeMounts")
      )
    end
  end

  def test_global_volume_rejects_explicit_per_pod_workspace_volume
    Dir.mktmpdir("rpof-global-volume-invalid-") do |dir|
      fleet = LocalModelEvaluation::RunpodFleet.new(
        client: FakeFleetClient.new,
        env_path: File.join(dir, ".env"),
        state_root: File.join(dir, "state"),
        out: StringIO.new
      )

      error = assert_raises(LocalModelEvaluation::RunpodFleet::Error) do
        fleet.preflight(
          worker_count: 1,
          volume_gb: 60,
          global_volume_id: GLOBAL_VOLUME_ID
        )
      end
      assert_includes error.message, "--global-volume-id cannot be combined with --volume-gb"
    end
  end

  def test_client_uses_graphql_and_exact_object_store_mount_for_global_volume
    seen = nil
    transport = lambda do |request|
      seen = request
      Response.new(
        status: 200,
        body: JSON.generate(
          "data" => { "podFindAndDeployOnDemand" => { "id" => "pod_global" } }
        )
      )
    end
    client = LocalModelEvaluation::RunpodClient.new(api_key: "rpa_test", transport:)
    body = {
      "name" => "af-lme-burst-1",
      "image" => "runpod/pytorch:test",
      "disk" => 40,
      "ports" => ["22/tcp"],
      "env" => { "PUBLIC_KEY" => PUBLIC_KEY },
      "mounts" => {},
      "cloud" => "SECURE",
      "gpu" => { "id" => "NVIDIA A40", "count" => 1 },
      "volumeMounts" => [{
        "volumeId" => GLOBAL_VOLUME_ID,
        "volumeType" => "OBJECT_STORE_VOLUME",
        "mountPath" => "/workspace-global"
      }]
    }

    pod = client.create_pod(body)
    assert_equal "pod_global", pod.fetch("id")
    assert_equal "POST", seen.fetch(:method)
    assert_equal "https://api.runpod.io/graphql", seen.fetch(:uri).to_s
    assert_equal "Bearer rpa_test", seen.fetch(:headers).fetch("Authorization")

    document = JSON.parse(seen.fetch(:body))
    assert_includes document.fetch("query"), "podFindAndDeployOnDemand"
    input = document.dig("variables", "input")
    assert_equal "SECURE", input.fetch("cloudType")
    assert_equal 40, input.fetch("containerDiskInGb")
    assert_equal 0, input.fetch("volumeInGb")
    assert_equal "NVIDIA A40", input.fetch("gpuTypeId")
    assert_equal 1, input.fetch("gpuCount")
    assert_equal "22/tcp", input.fetch("ports")
    assert_equal [{ "key" => "PUBLIC_KEY", "value" => PUBLIC_KEY }], input.fetch("env")
    assert_equal body.fetch("volumeMounts"), input.fetch("volumeMounts")
  end
end
