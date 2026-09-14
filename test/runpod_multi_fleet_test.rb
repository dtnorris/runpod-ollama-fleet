# frozen_string_literal: true

require "fileutils"
require "minitest/autorun"
require "stringio"
require "tmpdir"
require_relative "../lib/local_model_evaluation/runpod_fleet_namespace"
require_relative "../lib/local_model_evaluation/runpod_client"
require_relative "../lib/local_model_evaluation/runpod_fleet"

class RunpodMultiFleetTest < Minitest::Test
  class FakeClient
    attr_reader :pods, :created_bodies, :deleted_ids

    def initialize
      @pods = []
      @created_bodies = []
      @deleted_ids = []
    end

    def list_pods
      @pods.map(&:dup)
    end

    def list_gpu_types(cloud:, count:)
      [{
        "id" => "NVIDIA A40",
        "memory" => 48,
        cloud.downcase => true,
        "availability" => "HIGH",
        "price" => { cloud.downcase => 0.44 }
      }]
    end

    def create_pod(body)
      @created_bodies << Marshal.load(Marshal.dump(body))
      id = "pod_#{@created_bodies.length}"
      index = Integer(body.fetch("name").split("-").last)
      @pods << {
        "id" => id,
        "name" => body.fetch("name"),
        "status" => "RUNNING",
        "cloud" => body.fetch("cloud"),
        "gpu" => { "id" => "NVIDIA A40", "count" => 1 },
        "cost" => 0.44,
        "runtime" => {
          "ports" => [{
            "private" => 22,
            "public" => 22_000 + @created_bodies.length,
            "type" => "tcp",
            "ip" => "198.51.100.#{10 + index}"
          }]
        }
      }
      { "id" => id }
    end

    def get_pod(pod_id)
      pod = @pods.find { |candidate| candidate.fetch("id") == pod_id }
      raise LocalModelEvaluation::RunpodClient::Error.new(404, "not found") unless pod

      pod.dup
    end

    def delete_pod(pod_id)
      @deleted_ids << pod_id
      @pods.reject! { |candidate| candidate.fetch("id") == pod_id }
      { "id" => pod_id, "status" => "TERMINATED" }
    end
  end

  def setup
    @tmp = Dir.mktmpdir("lme-multi-fleet-")
    @state_root = File.join(@tmp, "output", "runpod-fleets")
    @client = FakeClient.new
    @out = StringIO.new
  end

  def teardown
    FileUtils.remove_entry(@tmp) if @tmp && File.exist?(@tmp)
  end

  def test_two_named_fleets_can_be_active_with_isolated_state_ports_env_and_pod_names
    qwen_ns = namespace("qwen", create: true)
    gptoss_ns = namespace("gptoss", create: true)

    assert_equal 11_457, qwen_ns.local_port_base
    assert_equal 11_473, gptoss_ns.local_port_base
    assert_operator qwen_ns.local_port_base + LocalModelEvaluation::RunpodWorkers::MAX_WORKERS - 1,
                    :<, gptoss_ns.local_port_base
    refute_equal qwen_ns.state_root, gptoss_ns.state_root
    refute_equal qwen_ns.env_path, gptoss_ns.env_path

    qwen = fleet(qwen_ns)
    gptoss = fleet(gptoss_ns)

    qwen_preflight = qwen.preflight(worker_count: 1)
    qwen.create(
      worker_count: 1,
      ssh_public_key: "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAITest test@example",
      preflight: qwen_preflight
    )

    gptoss_preflight = gptoss.preflight(worker_count: 1)
    gptoss.create(
      worker_count: 1,
      ssh_public_key: "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAITest test@example",
      preflight: gptoss_preflight
    )

    assert_equal ["af-lme-qwen-burst-1", "af-lme-gptoss-burst-1"], @client.created_bodies.map { |body| body.fetch("name") }

    qwen_state = qwen.fleet_state.current
    gptoss_state = gptoss.fleet_state.current
    assert_equal "active", qwen_state.fetch("status")
    assert_equal "active", gptoss_state.fetch("status")
    assert_equal "http://127.0.0.1:11457", qwen_state.fetch("workers").first.fetch("local_ollama_url")
    assert_equal "http://127.0.0.1:11473", gptoss_state.fetch("workers").first.fetch("local_ollama_url")

    assert_includes File.read(qwen_ns.env_path), "LME_BURST_1_URL=http://127.0.0.1:11457"
    assert_includes File.read(gptoss_ns.env_path), "LME_BURST_1_URL=http://127.0.0.1:11473"
    assert_in_delta 0.88, qwen_ns.total_active_hourly_usd, 0.0001

    assert_equal [1], qwen.destroy(worker_indices: [1])
    assert_nil qwen.fleet_state.current
    assert_equal "active", gptoss.fleet_state.current.fetch("status")
    assert_in_delta 0.44, gptoss_ns.total_active_hourly_usd, 0.0001
  end

  def test_provisional_namespace_does_not_persist_registry
    provisional = namespace("dryrun", provisional: true)

    assert_equal 11_457, provisional.local_port_base
    refute File.exist?(File.join(@state_root, LocalModelEvaluation::RunpodFleetNamespace::REGISTRY_FILE))
    refute File.exist?(File.join(@state_root, LocalModelEvaluation::RunpodFleetNamespace::REGISTRY_LOCK))
  end

  private

  def namespace(key, create: false, provisional: false)
    LocalModelEvaluation::RunpodFleetNamespace.new(
      root: @state_root,
      repo_root: @tmp,
      fleet_key: key,
      create:,
      provisional:
    )
  end

  def fleet(namespace)
    LocalModelEvaluation::RunpodFleet.new(
      client: @client,
      env_path: namespace.env_path,
      state_root: namespace.state_root,
      fleet_key: namespace.fleet_key,
      local_port_base: namespace.local_port_base,
      out: @out,
      sleeper: ->(_seconds) {},
      clock: -> { 0.0 }
    )
  end
end
