# frozen_string_literal: true

require "tmpdir"
require "stringio"
require_relative "../../lib/local_model_evaluation/runpod_fleet_lifecycle"
require_relative "../../lib/runpod_ollama_fleet/dynamic_worker_registry"

# Offline provider/qualification evidence. No sockets, subprocesses, or consumers.
class SelectedWorkerFixture
  class Provider
    attr_reader :deleted, :observed
    attr_accessor :ambiguous, :retain, :before_delete

    def initialize
      @pods = { "pod-1" => { "id" => "pod-1", "name" => "af-lme-burst-1" } }
      @deleted = []
      @observed = []
    end

    def get_pod(id)
      observed << id
      @pods.fetch(id) { raise LocalModelEvaluation::RunpodClient::Error.new(404, "absent") }
    end

    def delete_pod(id)
      before_delete&.call
      deleted << id
      raise "delete result lost" if ambiguous
      @pods.delete(id) unless retain
    end

    def disappear!
      @pods.clear
    end
  end

  class Admission
    attr_reader :absent
    def initialize = @absent = []
    def profile_id = "default"
    def authority_identity
      {
        "contract_version" => LocalModelEvaluation::RunpodFleetState::CAMPAIGN_AUTHORITY_VERSION,
        "binding_sha256" => "a" * 64, "campaign_identity_sha256" => "b" * 64,
        "budget_id" => "original-budget", "profile_id" => profile_id
      }
    end
    def assert_matches!(identity)
      raise "wrong campaign" unless identity == authority_identity
    end
    def mark_resource_absent!(provider_resource_id:) = absent << provider_resource_id
    def reserve!(**) = raise "unexpected create"
    def attempt_provider_create!(*) = raise "unexpected create"
    def commit!(**) = raise "unexpected create"
    def provider_absence_verified!(**) = raise "unexpected create"
  end

  attr_reader :root, :state, :client, :admission, :fleet_id, :initial_worker
  attr_accessor :now

  def initialize
    @root = Dir.mktmpdir("fo14-selected-")
    @now = Time.utc(2030, 1, 1, 0, 1, 0)
    @client = Provider.new
    @admission = Admission.new
    @state = LocalModelEvaluation::RunpodFleetState.new(root: File.join(root, "state"), clock: -> { now })
    worker = LocalModelEvaluation::RunpodFleet::Worker.new(
      index: 1, pod_id: "pod-1", name: "af-lme-burst-1", host: "198.51.100.1",
      ssh_port: 22001, hourly_rate: 0.5
    )
    fleet = state.activate(
      workers: [worker], cloud: "SECURE", gpu_id: "NVIDIA A40", image: LocalModelEvaluation::RunpodFleet::IMAGE,
      provisioning: { "container_disk_gb" => 50, "volume_gb" => 150 },
      campaign_authority: admission.authority_identity
    )
    @fleet_id = fleet.fetch("fleet_id")
    @initial_worker = fleet.fetch("workers").first
    write_evidence
    @monotonic = 0
  end

  def close = FileUtils.remove_entry(root)
  def worker = state.current.fetch("workers").first

  def lifecycle
    LocalModelEvaluation::RunpodFleetLifecycle.new(
      client:, fleet_state: state, env_path: File.join(root, "env"), fleet_key: "default",
      local_port_base: 11441, capacity_admission: admission, out: StringIO.new,
      wall_clock: -> { now }, sleeper: ->(*) {}, monotonic_clock: -> { @monotonic += 31 }
    )
  end

  def registry
    process = Object.new
    def process.alive?(*) = true
    def process.matches?(*) = true
    health = Object.new
    def health.check(*) = Struct.new(:healthy).new(true)
    RunpodOllamaFleet::DynamicWorkerRegistry.new(
      state_root: root, repo_root: root, clock: -> { now }, process_adapter: process, health_checker: health,
      fleet_sources: [{ "fleet_key" => "default", "state" => state }], id_generator: -> { "fo14-registry" }
    )
  end

  def select(operation, revision: worker.dig("lifecycle", "revision") || 0, **overrides)
    lifecycle.select_worker!(
      operation:, fleet_id:, worker_id: initial_worker.fetch("worker_id"),
      generation_id: initial_worker.fetch("generation_id"), pod_id: initial_worker.fetch("pod_id"),
      expected_revision: revision, reason: "explicit operator request", registry:, confirm: true, **overrides
    )
  end

  def write_evidence
    tunnel = initial_worker.slice("index", "pod_id", "worker_id", "generation_id").merge(
      "endpoint" => initial_worker.fetch("local_ollama_url"), "pid" => 123, "process_identity" => "fixture"
    )
    File.write(File.join(state.artifact_dir(fleet_id, "tunnels"), "tunnels.json"), JSON.generate(
      "fleet_id" => fleet_id, "workers" => [tunnel]
    ))
    path = File.join(state.artifact_dir(fleet_id, "bootstrap"), "proof")
    FileUtils.mkdir_p(path)
    File.write(File.join(File.dirname(path), "current"), "proof\n")
    File.write(File.join(path, "bootstrap.json"), JSON.generate(
      "fleet_id" => fleet_id, "status" => "passed", "models" => ["model:latest"],
      "expected_digests" => { "model:latest" => "c" * 64 }, "context" => 4096,
      "workers" => [initial_worker.slice("index", "pod_id", "worker_id", "generation_id").merge(
        "status" => "passed", "provenance" => {
          "gpu" => { "name" => "NVIDIA A40" }, "models" => {
            "model:latest" => { "digest" => "c" * 64, "context_length" => 4096, "fully_gpu_resident" => true,
                                "size_bytes" => 1024, "size_vram_bytes" => 1024 }
          }
        }
      )]
    ))
  end
end
