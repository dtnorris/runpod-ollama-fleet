# frozen_string_literal: true

require "fileutils"
require "minitest/autorun"
require "stringio"
require "tmpdir"
require_relative "../lib/local_model_evaluation/runpod_client"
require_relative "../lib/local_model_evaluation/runpod_fleet"
require_relative "../lib/local_model_evaluation/runpod_lease"

class RunpodLeaseIntegrationTest < Minitest::Test
  class FakeClient
    attr_reader :created_bodies, :deleted_ids, :catalog_calls

    def initialize
      @created_bodies = []
      @deleted_ids = []
      @catalog_calls = []
      @pods = {}
    end

    def list_pods
      []
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
      @created_bodies << body
      index = @created_bodies.length
      pod_id = "pod_#{index}"
      @pods[pod_id] = {
        "id" => pod_id,
        "name" => body.fetch("name"),
        "status" => "RUNNING",
        "cloud" => body.fetch("cloud"),
        "gpu" => body.fetch("gpu"),
        "cost" => 0.50,
        "runtime" => {
          "ports" => [{ "private" => 22, "public" => 22_000 + index, "type" => "tcp", "ip" => "198.51.100.#{index}" }]
        }
      }
      { "id" => pod_id }
    end

    def get_pod(pod_id)
      @pods.fetch(pod_id)
    end

    def delete_pod(pod_id)
      @deleted_ids << pod_id
      { "id" => pod_id, "status" => "TERMINATED" }
    end
  end

  def setup
    @tmp = Dir.mktmpdir("lme-runpod-lease-")
    @env_path = File.join(@tmp, ".env")
    File.write(@env_path, "RUNPOD_API_KEY=test\n")
    @state_root = File.join(@tmp, "state")
    @now = Time.utc(2026, 9, 13, 20, 0, 0)
    @client = FakeClient.new
    @fleet = LocalModelEvaluation::RunpodFleet.new(
      client: @client,
      env_path: @env_path,
      state_root: @state_root,
      out: StringIO.new,
      sleeper: ->(_seconds) {},
      clock: -> { 0.0 },
      wall_clock: -> { @now }
    )
  end

  def teardown
    FileUtils.remove_entry(@tmp) if @tmp && File.exist?(@tmp)
  end

  def test_create_persists_runtime_and_spend_lease_from_first_paid_create
    preflight = @fleet.preflight(
      worker_count: 2,
      max_fleet_hourly_usd: 2.0,
      max_runtime_seconds: 3600,
      max_spend_usd: 1.25
    )

    @fleet.create(
      worker_count: 2,
      ssh_public_key: "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAITest test@example",
      preflight:,
      max_fleet_hourly_usd: 2.0,
      max_runtime_seconds: 3600,
      max_spend_usd: 1.25
    )

    lease = @fleet.fleet_state.current.fetch("lease")
    assert_equal "2026-09-13T20:00:00Z", lease.fetch("started_at_utc")
    assert_equal "2026-09-13T21:00:00Z", lease.fetch("expires_at_utc")
    assert_in_delta 3600.0, lease.fetch("max_runtime_seconds"), 0.001
    assert_in_delta 1.25, lease.fetch("max_spend_usd"), 0.001
    assert File.directory?(@fleet.fleet_state.artifact_dir(@fleet.fleet_state.current.fetch("fleet_id"), "lease"))
  end

  def test_preflight_rejects_invalid_lease_before_runpod_api_calls
    error = assert_raises(LocalModelEvaluation::RunpodFleet::Error) do
      @fleet.preflight(worker_count: 1, max_runtime_seconds: 0)
    end
    assert_includes error.message, "max runtime must be positive"

    error = assert_raises(LocalModelEvaluation::RunpodFleet::Error) do
      @fleet.preflight(worker_count: 1, max_spend_usd: -1)
    end
    assert_includes error.message, "max spend must be positive"
    assert_empty @client.catalog_calls
  end

  def test_create_rejects_lease_mismatch_before_paid_mutation
    preflight = @fleet.preflight(
      worker_count: 1,
      max_runtime_seconds: 3600,
      max_spend_usd: 5.0
    )

    error = assert_raises(LocalModelEvaluation::RunpodFleet::Error) do
      @fleet.create(
        worker_count: 1,
        ssh_public_key: "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAITest test@example",
        preflight:,
        max_runtime_seconds: 7200,
        max_spend_usd: 5.0
      )
    end

    assert_includes error.message, "preflight max runtime"
    assert_empty @client.created_bodies
  end
end
