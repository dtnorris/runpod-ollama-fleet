# frozen_string_literal: true

require_relative "../local_model_evaluation/runpod_fleet"
require_relative "../local_model_evaluation/runpod_fleet_lifecycle"
require_relative "../local_model_evaluation/runpod_fleet_namespace"

module RunpodOllamaFleet
  # Adapter from campaign intent to the existing fleet mutation paths. It has
  # no provider-create implementation of its own.
  class CampaignRunpodRuntime
    class Error < StandardError; end

    def initialize(root:, repo_root:, profile:, hardware:, client:, admission: nil, out: $stdout,
                   wall_clock: nil)
      @root = File.expand_path(root)
      @repo_root = File.expand_path(repo_root)
      @profile = profile
      @hardware = hardware
      @client = client
      @admission = admission
      @out = out
      @wall_clock = wall_clock
    end

    def current_worker_count
      record = current_record
      record && record["status"] == "active" ? Integer(record.fetch("worker_count")) : 0
    end

    def status
      record = current_record
      workers = record && record["status"] == "active" ? Array(record.fetch("workers")) : []
      {
        "current_workers" => workers.length,
        "ready_workers" => workers.count { |row| row["status"] == "active" },
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
      fleet.gpu_id = @hardware.fetch("qualified_gpu_ids").first
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
          gpu_id: @hardware.fetch("qualified_gpu_ids").first,
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

    def profile_id
      @profile.fetch("profile_id")
    end

    def current_record
      root = File.join(@root, "fleets", profile_id)
      LocalModelEvaluation::RunpodFleetState.new(root:, clock: @wall_clock).current
    rescue LocalModelEvaluation::RunpodFleetState::Error => e
      raise Error, e.message
    end
  end
end
