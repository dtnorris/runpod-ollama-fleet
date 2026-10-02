# frozen_string_literal: true

require_relative "../local_model_evaluation/runpod_fleet"
require_relative "../local_model_evaluation/runpod_fleet_lifecycle"
require_relative "../local_model_evaluation/runpod_fleet_namespace"
require_relative "../local_model_evaluation/runpod_capacity_policy"
require_relative "dynamic_worker_registry"
require_relative "model_requirement"

module RunpodOllamaFleet
  # Adapter from campaign intent to the existing fleet mutation paths. It has
  # no provider-create implementation of its own.
  class CampaignRunpodRuntime
    class Error < StandardError; end

    def initialize(root:, repo_root:, profile:, hardware:, client:, admission: nil, out: $stdout,
                   wall_clock: nil, readiness_observer: nil, model_requirement: nil)
      @root = File.expand_path(root)
      @repo_root = File.expand_path(repo_root)
      @profile = profile
      @hardware = hardware
      @client = client
      @admission = admission
      @out = out
      @wall_clock = wall_clock
      @readiness_observer = readiness_observer
      @model_requirement = model_requirement
      @model_requirement&.validate_profile!(profile: @profile, hardware: @hardware)
    end

    def current_worker_count
      record = current_record
      record && record["status"] == "active" ? Integer(record.fetch("worker_count")) : 0
    end

    def status
      record = current_record
      workers = record && record["status"] == "active" ? Array(record.fetch("workers")) : []
      provider_active = workers.count { |row| row["status"] == "active" }
      readiness = readiness_status
      counts = readiness["counts"] || {}
      {
        "current_workers" => workers.length,
        # Compatibility field: historically this meant active fleet-state rows,
        # not dynamic-worker-registry READY.
        "ready_workers" => provider_active,
        "ready_workers_legacy_meaning" => "provider_active_workers",
        "provider_active_workers" => provider_active,
        "bootstrap_passed_workers" => counts["bootstrap_passed"],
        "capability_evidence_workers" => counts["capability_evidence_valid"],
        "tunnel_established_workers" => counts["tunnel_established"],
        "registry_status" => readiness.fetch("status"),
        "registry_ready_workers" => counts["READY"],
        "registry_not_ready_workers" => counts["NOT_READY"],
        "registry_unavailable_workers" => counts["UNAVAILABLE"],
        "registry_unpublished_workers" => counts["registry_unpublished"],
        "registry_error" => readiness["error"],
        "fleet_id" => record && record["fleet_id"],
        "fleet_status" => record && record["status"],
        "worker_readiness" => workers.group_by { |row| row.fetch("status") }.transform_values(&:length)
      }
    end

    def ensure_workers!(desired_workers:, ssh_public_key_path:, original_deadline_at_utc:,
                        max_hourly_rate_usd:)
      raise Error, "campaign provider client is unavailable" unless @client
      raise Error, "campaign admission is required for a paid mutation" unless @admission
      namespace = LocalModelEvaluation::RunpodFleetNamespace.new(
        root: @root, repo_root: @repo_root, fleet_key: profile_id, create: true
      )
      fleet = LocalModelEvaluation::RunpodFleet.new(
        client: @client, env_path: namespace.env_path, state_root: namespace.state_root,
        fleet_key: namespace.fleet_key, local_port_base: namespace.local_port_base,
        capacity_admission: @admission, out: @out, wall_clock: @wall_clock
      )
      selected_gpu = qualified_gpu_id(
        max_hourly_rate_usd: max_hourly_rate_usd,
        desired_workers: desired_workers
      )
      fleet.gpu_id = selected_gpu
      ssh_key = fleet.read_ssh_public_key(ssh_public_key_path)
      current = fleet.fleet_state.current
      if current && current["status"] == "active"
        lifecycle = LocalModelEvaluation::RunpodFleetLifecycle.new(
          client: @client, fleet_state: fleet.fleet_state, env_path: namespace.env_path,
          fleet_key: namespace.fleet_key, local_port_base: namespace.local_port_base,
          capacity_admission: @admission, out: @out, wall_clock: @wall_clock
        )
        preflight = lifecycle.preflight_scale(
          target_worker_count: desired_workers,
          gpu_id: selected_gpu,
          max_fleet_hourly_usd: max_hourly_rate_usd
        )
        lifecycle.scale(
          target_worker_count: desired_workers, ssh_public_key: ssh_key, preflight:,
          max_fleet_hourly_usd: max_hourly_rate_usd
        )
      else
        preflight = fleet.preflight(
          worker_count: desired_workers, cloud: @hardware.fetch("cloud"),
          max_fleet_hourly_usd: max_hourly_rate_usd,
          global_volume_id: @hardware.fetch("global_volume_id")
        )
        fleet.create(
          worker_count: desired_workers, ssh_public_key: ssh_key, preflight:,
          cloud: @hardware.fetch("cloud"), max_fleet_hourly_usd: max_hourly_rate_usd,
          global_volume_id: @hardware.fetch("global_volume_id"),
          lease_deadline_at_utc: original_deadline_at_utc,
          min_ready_workers: desired_workers
        )
      end
    rescue LocalModelEvaluation::RunpodFleet::Error,
           LocalModelEvaluation::RunpodFleetLifecycle::Error,
           LocalModelEvaluation::RunpodFleetNamespace::Error => e
      raise Error, e.message
    end

    private

    def readiness_status
      observer = @readiness_observer || DynamicWorkerRegistry.new(
        state_root: @root,
        repo_root: @repo_root,
        fleet_sources: [{ "fleet_key" => profile_id, "state" => current_state }]
      )
      observer.readiness_status
    rescue DynamicWorkerRegistry::Error => e
      { "status" => "unavailable", "error" => e.message }
    end

    def qualified_gpu_id(max_hourly_rate_usd:, desired_workers:)
      worker_count = Integer(desired_workers)
      raise Error, "desired worker count must be positive" unless worker_count.positive?

      per_worker_cap = Float(max_hourly_rate_usd) / worker_count
      ranking = LocalModelEvaluation::RunpodCapacityPolicy.new(client: @client).rank(
        gpu_ids: required_gpu_ids,
        cloud: @hardware.fetch("cloud"),
        max_hourly_per_worker_usd: per_worker_cap
      )

      candidate = ranking.candidates.first
      return candidate.gpu_id if candidate

      detail = ranking.rejections.map do |row|
        "#{row.gpu_id}: #{row.reason}"
      end.join("; ")
      suffix = detail.empty? ? "" : ": #{detail}"
      raise Error, "no currently available qualified GPU#{suffix}"
    rescue LocalModelEvaluation::RunpodCapacityPolicy::Error, ArgumentError, TypeError => e
      raise Error, e.message
    end

    def required_gpu_ids
      required = @model_requirement&.required_gpu_id
      required ? [required] : @hardware.fetch("qualified_gpu_ids")
    end

    def profile_id
      @profile.fetch("profile_id")
    end

    def current_record
      current_state.current
    rescue LocalModelEvaluation::RunpodFleetState::Error => e
      raise Error, e.message
    end

    def current_state
      root = File.join(@root, "fleets", profile_id)
      LocalModelEvaluation::RunpodFleetState.new(root:, clock: @wall_clock)
    end
  end
end
