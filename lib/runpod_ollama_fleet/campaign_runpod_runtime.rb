# frozen_string_literal: true

require_relative "../local_model_evaluation/runpod_fleet"
require_relative "../local_model_evaluation/runpod_fleet_lifecycle"
require_relative "../local_model_evaluation/runpod_fleet_namespace"
require_relative "../local_model_evaluation/runpod_capacity_policy"
require_relative "../local_model_evaluation/process_supervisor"
require_relative "../local_model_evaluation/runpod_bootstrap"
require_relative "../local_model_evaluation/runpod_tunnels"
require_relative "availability_fallback"
require_relative "capability_check"
require_relative "dynamic_worker_registry"
require_relative "ollama_capability_request"
require_relative "worker_bringup_adapters"
require_relative "worker_bringup_reconciler"

module RunpodOllamaFleet
  # Adapter from campaign intent to the existing fleet mutation paths. It has
  # no provider-create implementation of its own.
  class CampaignRunpodRuntime
    class Error < StandardError; end

    def initialize(root:, repo_root:, profile:, hardware:, client:, admission: nil, out: $stdout,
                   wall_clock: nil, readiness_observer: nil, capability_request: nil,
                   campaign_identity_sha256: nil, readiness_gate: nil, binding: nil,
                   availability_fallback: nil,
                   bringup_reconciler_factory: nil)
      @root = File.expand_path(root)
      @repo_root = File.expand_path(repo_root)
      @profile = profile
      @hardware = hardware
      @client = client
      @admission = admission
      @out = out
      @wall_clock = wall_clock
      @readiness_observer = readiness_observer
      @capability_request = capability_request
      @campaign_identity_sha256 = campaign_identity_sha256
      @readiness_gate = readiness_gate
      @bringup_reconciler_factory = bringup_reconciler_factory
      @binding = binding
      @availability_fallback = availability_fallback || build_availability_fallback
      @fallback_retry_pending = false
      @capability_request&.validate_profile!(profile: @profile, hardware: @hardware)
    end

    def current_worker_count
      record = current_record
      return 0 unless record && record["status"] == "active"
      record.fetch("workers").count { |worker| worker.dig("lifecycle", "phase") != "retired" }
    end

    def status
      record = current_record
      workers = record && record["status"] == "active" ? Array(record.fetch("workers")) : []
      provider_active = workers.count { |row| row["status"] == "active" }
      readiness = readiness_status
      counts = readiness["counts"] || {}
      result = {
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
        "worker_lifecycle" => workers.map do |worker|
          lifecycle = worker["lifecycle"] || { "phase" => "active", "revision" => 0 }
          worker.slice("index", "worker_id", "generation_id", "pod_id").merge(
            lifecycle.except("registry_worker").merge(
              "next_action" => case lifecycle["phase"]
                               when "active" then "drain exact generation before removal"
                               when "draining" then "lower desired capacity, then explicitly confirm remove"
                               when "retired" then "none; provider absence verified"
                               when "delete_ambiguous", "delete_in_progress" then "verify provider absence; campaign stop delegates unresolved teardown to guardian"
                               else "wait for supervised retirement; inspect campaign status"
                               end
            )
          )
        end,
        "worker_readiness" => workers.group_by { |row| row.fetch("status") }.transform_values(&:length)
      }
      fallback = @availability_fallback&.current
      result["availability_fallback"] = fallback if fallback
      result
    end

    def ensure_workers!(desired_workers:, ssh_public_key_path:, original_deadline_at_utc:,
                        max_hourly_rate_usd:)
      raise Error, "campaign provider client is unavailable" unless @client
      raise Error, "campaign admission is required for a paid mutation" unless @admission
      restore_retired_workers!(desired_workers:, ssh_public_key_path:, max_hourly_rate_usd:)
      return true if current_worker_count >= desired_workers
      return ensure_workers_with_fallback!(
        desired_workers:, ssh_public_key_path:, original_deadline_at_utc:, max_hourly_rate_usd:
      ) if @availability_fallback

      provision_with_gpu!(
        selected_gpu: qualified_gpu_id(
          max_hourly_rate_usd: max_hourly_rate_usd,
          desired_workers: desired_workers
        ),
        desired_workers:, ssh_public_key_path:, original_deadline_at_utc:, max_hourly_rate_usd:
      )
    rescue LocalModelEvaluation::RunpodFleet::Error,
           LocalModelEvaluation::RunpodFleetLifecycle::Error,
           LocalModelEvaluation::RunpodFleetNamespace::Error,
           AvailabilityFallback::Error => e
      raise Error, e.message
    end

    def select_worker!(**options)
      assert_selected_candidate_settled!(options.fetch(:worker_id), options.fetch(:operation))
      provider_lifecycle.select_worker!(
        **options,
        registry: DynamicWorkerRegistry.new(state_root: @root, repo_root: @repo_root, clock: @wall_clock)
      )
    rescue LocalModelEvaluation::RunpodFleetLifecycle::Error,
           LocalModelEvaluation::RunpodFleetState::Error, DynamicWorkerRegistry::Error => e
      raise Error, e.message
    end

    def reconcile_retirements!
      return [] unless current_record

      provider_lifecycle.reconcile_retirements!
    rescue LocalModelEvaluation::RunpodFleetLifecycle::Error,
           LocalModelEvaluation::RunpodFleetState::Error => e
      raise Error, e.message
    end

    def fallback_retry_pending?
      @fallback_retry_pending == true
    end

    def fallback_candidate_limit
      required_gpu_ids.length
    end

    def reconcile_bringup!(desired_workers:, transition_guard:)
      desired = Integer(desired_workers)
      return [] if desired.zero?
      raise Error, "exact Ollama capability request is required for automatic bring-up" unless @capability_request
      unless @campaign_identity_sha256.to_s.match?(/\A[0-9a-f]{64}\z/)
        raise Error, "campaign identity is required for automatic bring-up"
      end

      fleet = current_record
      return [] unless fleet && fleet["status"] == "active"
      adopt_provisioned_fallback!(fleet)
      workers = Array(fleet.fetch("workers")).select do |worker|
        worker["status"] == "active" && !worker["lifecycle"]
      end.sort_by { |worker| Integer(worker.fetch("index")) }.first(desired)
      reconciler = bringup_reconciler(transition_guard)
      states = workers.map do |worker|
        reconciler.reconcile!(
          campaign_identity_sha256: @campaign_identity_sha256,
          profile: @profile,
          worker:,
          generation_id: worker.fetch("generation_id"),
          capability_request: @capability_request,
          retry_bootstrap: true
        )
      end
      reconcile_fallback_bringup!(fleet, states)
      states
    rescue WorkerBringupReconciler::Error, LocalModelEvaluation::RunpodFleetState::Error,
           AvailabilityFallback::Error, KeyError, ArgumentError, TypeError => e
      raise Error, e.message
    end

    private

    def build_availability_fallback
      return unless @binding && @capability_request

      AvailabilityFallback.new(
        binding: @binding, profile: @profile, hardware: @hardware,
        capability_request: @capability_request, wall_clock: @wall_clock
      )
    end

    def ensure_workers_with_fallback!(desired_workers:, ssh_public_key_path:,
                                      original_deadline_at_utc:, max_hourly_rate_usd:)
      desired = Integer(desired_workers)
      from = current_worker_count
      candidates = fallback_candidates
      @availability_fallback.prepare!(
        from_workers: from,
        target_workers: desired,
        original_deadline_at_utc:,
        candidates:
      )
      @fallback_retry_pending = false

      loop do
        candidate = @availability_fallback.next_candidate!
        unless candidate
          raise Error, "authorized fallback candidate set is exhausted"
        end
        selected_gpu = candidate.fetch("gpu_id")
        begin
          # This transition is deliberately conservative: once the live
          # provisioning path is entered, absence must be proved before a
          # different candidate can be admitted.
          @availability_fallback.mark_provider_mutation_started!
          provision_with_gpu!(
            selected_gpu:, desired_workers: desired, ssh_public_key_path:,
            original_deadline_at_utc:, max_hourly_rate_usd:
          )
          @availability_fallback.mark_provisioned!
          return true
        rescue StandardError => e
          safe = fallback_liability_matches_workers?(from)
          retryable = retryable_capacity_failure?(e)
          if retryable && safe
            @availability_fallback.reject_current!(
              reason: e.message,
              cleanup_status: "verified_absent"
            )
            next
          end

          @availability_fallback.block_current!(
            reason: retryable ?
              "candidate cleanup or liability remains unresolved: #{e.message}" :
              "non-retryable candidate failure: #{e.message}",
            cleanup_status: safe ? "verified_absent" : "unresolved"
          )
          raise
        end
      end
    rescue ArgumentError, TypeError => e
      raise Error, e.message
    end

    def provision_with_gpu!(selected_gpu:, desired_workers:, ssh_public_key_path:,
                            original_deadline_at_utc:, max_hourly_rate_usd:)
      namespace = LocalModelEvaluation::RunpodFleetNamespace.new(
        root: @root, repo_root: @repo_root, fleet_key: profile_id, create: true
      )
      fleet = LocalModelEvaluation::RunpodFleet.new(
        client: @client, env_path: namespace.env_path, state_root: namespace.state_root,
        fleet_key: namespace.fleet_key, local_port_base: namespace.local_port_base,
        capacity_admission: @admission, out: @out, wall_clock: @wall_clock
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
      true
    end

    def fallback_candidates
      ranking = LocalModelEvaluation::RunpodCapacityPolicy.new(client: @client).rank(
        gpu_ids: required_gpu_ids,
        cloud: @hardware.fetch("cloud")
      )
      rows = ranking.candidates.map do |candidate|
        {
          "gpu_id" => candidate.gpu_id,
          "cloud" => ranking.cloud,
          "hourly_rate_usd" => candidate.hourly_rate_usd,
          "eligible" => true,
          "reason" => nil
        }
      end
      rows.concat(ranking.rejections.map do |rejection|
        {
          "gpu_id" => rejection.gpu_id,
          "cloud" => ranking.cloud,
          "hourly_rate_usd" => rejection.hourly_rate_usd,
          "eligible" => false,
          "reason" => rejection.reason
        }
      end)
      rows.sort_by do |row|
        [row["hourly_rate_usd"].nil? ? 1 : 0, row["hourly_rate_usd"] || 0.0, row.fetch("gpu_id")]
      end
    rescue LocalModelEvaluation::RunpodCapacityPolicy::Error, KeyError => e
      raise Error, "could not fix authorized fallback candidates before provider mutation: #{e.message}"
    end

    def retryable_capacity_failure?(error)
      message = error.message.to_s
      return false if message.match?(
        /(?:budget|deadline|guardian|binding|campaign identity|worker ceiling|profile .* ceiling|aggregate hourly|cumulative|safety cap|fleet cost|malformed|corrupt)/i
      )

      message.match?(
        /(?:catalog did not return|not available on .* cloud|availability is (?:NONE|unknown)|capacity unavailable|insufficient capacity|requested hardware|GPU mismatch|cloud mismatch|entered terminal status|timed out waiting for RunPod SSH|readiness ended)/i
      )
    end

    def fallback_liability_matches_workers?(expected_workers)
      return false unless current_worker_count == Integer(expected_workers)

      authority = @binding.status
      committed = Integer(
        authority.dig("authority", "committed_workers_by_profile", profile_id) || 0
      )
      pending = authority.fetch("parent_budget").fetch("reservations").values.count do |row|
        row["fleet_key"] == profile_id && row["status"] == "pending"
      end
      committed == Integer(expected_workers) && pending.zero?
    rescue CampaignBudgetBinding::Error, KeyError, ArgumentError, TypeError
      false
    end

    def adopt_provisioned_fallback!(fleet)
      document = @availability_fallback&.current
      return unless document && document.fetch("state") == "active"
      gpu_id = document["current_candidate"]
      candidate = document.fetch("candidates").find { |row| row.fetch("gpu_id") == gpu_id }
      return unless candidate && candidate.fetch("status") == "in_progress"
      target = document.fetch("target_workers")
      return unless Integer(fleet.fetch("worker_count")) == target
      unless fallback_liability_matches_workers?(target)
        @availability_fallback.block_current!(
          reason: "retained provider capacity does not match parent budget liability",
          cleanup_status: "unresolved"
        )
        raise Error, "retained fallback provider capacity is ambiguous"
      end

      @availability_fallback.mark_provisioned!
    end

    def reconcile_fallback_bringup!(fleet, states)
      @fallback_retry_pending = false
      document = @availability_fallback&.current
      return unless document && document.fetch("state") == "active"
      gpu_id = document["current_candidate"]
      candidate = document.fetch("candidates").find { |row| row.fetch("gpu_id") == gpu_id }
      return unless candidate && candidate.fetch("status") == "provisioned"

      indices = ((Integer(document.fetch("from_workers")) + 1)..Integer(document.fetch("target_workers"))).to_a
      worker_ids = Array(fleet.fetch("workers")).filter_map do |worker|
        worker.fetch("worker_id") if indices.include?(Integer(worker.fetch("index")))
      end
      acquired = states.select { |state| worker_ids.include?(state.dig("identity", "worker_id")) }
      if worker_ids.length != indices.length || acquired.length != worker_ids.length
        @availability_fallback.block_current!(
          reason: "generation-bound bring-up evidence is incomplete for the current fallback candidate",
          cleanup_status: "unresolved"
        )
        raise Error, "current fallback candidate has incomplete FO-11 bring-up evidence"
      end

      if acquired.all? { |state| state.fetch("readiness_prerequisites_satisfied") == true }
        @availability_fallback.mark_accepted!
        return
      end

      reason = retryable_bringup_failure(acquired)
      terminal = acquired.any? { |state| state.fetch("overall_status") == "failed_terminal" }
      return unless terminal

      unless reason
        @availability_fallback.block_current!(
          reason: "FO-11 terminal failure is not a classified candidate-unsuitability condition",
          cleanup_status: "unresolved"
        )
        raise Error, "FO-11 terminal failure is not eligible for automatic candidate fallback"
      end

      cleanup_current_candidate!(document, reason:)
      @fallback_retry_pending = true
    end

    def retryable_bringup_failure(states)
      states.each do |state|
        capability = state.fetch("capability")
        if capability.fetch("status") == "failed_terminal" &&
           capability["error"].to_s.match?(/does not match exact capability request/i)
          return capability.fetch("error")
        end
        %w[tunnel bootstrap capability].each do |stage|
          row = state.fetch(stage)
          next unless row.fetch("status") == "failed_terminal"
          error = row["error"].to_s
          return error if error.match?(/does not match exact capability request/i)
          return error if error.match?(/provider resource.*(?:unavailable|terminated|unusable|missing)/i)
        end
      end
      nil
    end

    def cleanup_current_candidate!(document, reason:)
      from = Integer(document.fetch("from_workers"))
      target = Integer(document.fetch("target_workers"))
      namespace = LocalModelEvaluation::RunpodFleetNamespace.new(
        root: @root, repo_root: @repo_root, fleet_key: profile_id, create: true
      )
      fleet = LocalModelEvaluation::RunpodFleet.new(
        client: @client, env_path: namespace.env_path, state_root: namespace.state_root,
        fleet_key: namespace.fleet_key, local_port_base: namespace.local_port_base,
        capacity_admission: @admission, out: @out, wall_clock: @wall_clock
      )
      if from.zero?
        fleet.destroy(
          worker_indices: (1..target).to_a,
          verify_absent: true,
          destroy_reason: "FO-15 candidate unsuitable after FO-11 proof"
        )
      else
        lifecycle = LocalModelEvaluation::RunpodFleetLifecycle.new(
          client: @client, fleet_state: fleet.fleet_state, env_path: namespace.env_path,
          fleet_key: namespace.fleet_key, local_port_base: namespace.local_port_base,
          capacity_admission: @admission, out: @out, wall_clock: @wall_clock
        )
        preflight = lifecycle.preflight_scale(target_worker_count: from)
        lifecycle.shrink(target_worker_count: from, preflight:)
      end
      unless fallback_liability_matches_workers?(from)
        raise Error, "candidate cleanup completed locally but parent liability is unresolved"
      end
      @availability_fallback.reject_current!(reason:, cleanup_status: "verified_absent")
    rescue StandardError => e
      begin
        @availability_fallback.block_current!(
          reason: "candidate cleanup failed: #{e.message}", cleanup_status: "unresolved"
        )
      rescue AvailabilityFallback::Error
        nil
      end
      raise Error, "candidate cleanup failed; fallback is blocked: #{e.message}"
    end

    def provider_lifecycle
      namespace = LocalModelEvaluation::RunpodFleetNamespace.new(
        root: @root, repo_root: @repo_root, fleet_key: profile_id
      )
      LocalModelEvaluation::RunpodFleetLifecycle.new(
        client: @client, fleet_state: current_state, env_path: namespace.env_path,
        fleet_key: profile_id, local_port_base: namespace.local_port_base,
        capacity_admission: @admission, out: @out, wall_clock: @wall_clock
      )
    end

    # A retired slot uses the existing exact-GPU replacement primitive. It is
    # not an appended FO-15 candidate range and must not enter candidate cleanup.
    def restore_retired_workers!(desired_workers:, ssh_public_key_path:, max_hourly_rate_usd:)
      fleet = current_record
      return unless fleet && fleet["status"] == "active"
      missing = Integer(desired_workers) - current_worker_count
      return unless missing.positive?
      retired = fleet.fetch("workers").select { |worker| worker.dig("lifecycle", "phase") == "retired" }.first(missing)
      return if retired.empty?
      fallback = @availability_fallback&.current
      if fallback && !%w[accepted exhausted].include?(fallback["state"])
        raise Error, "resolve retained availability fallback before reusing retired slots"
      end
      namespace = LocalModelEvaluation::RunpodFleetNamespace.new(root: @root, repo_root: @repo_root, fleet_key: profile_id)
      provider = LocalModelEvaluation::RunpodFleet.new(
        client: @client, env_path: namespace.env_path, state_root: namespace.state_root,
        fleet_key: profile_id, capacity_admission: @admission, out: @out
      )
      ssh_key = provider.read_ssh_public_key(ssh_public_key_path)
      lifecycle = provider_lifecycle
      retired.each do |worker|
        preflight = lifecycle.preflight_replace(worker_index: worker.fetch("index"), max_fleet_hourly_usd: max_hourly_rate_usd)
        lifecycle.replace(worker_index: worker.fetch("index"), ssh_public_key: ssh_key, preflight:,
                          max_fleet_hourly_usd: max_hourly_rate_usd)
      end
    end

    def assert_selected_candidate_settled!(worker_id, operation)
      fallback = @availability_fallback&.current
      return unless fallback && %w[active blocked].include?(fallback["state"])
      if operation == "remove"
        raise Error, "resolve retained availability fallback before selected removal, or stop campaign"
      end
      worker = current_record&.fetch("workers")&.find { |row| row["worker_id"] == worker_id }
      return unless worker
      if worker.fetch("index") > fallback.fetch("from_workers") && worker.fetch("index") <= fallback.fetch("target_workers")
        raise Error, "selected worker belongs to an unresolved FO-15 candidate; resolve candidate or stop campaign"
      end
    end

    def readiness_status
      if @campaign_identity_sha256 && !@readiness_gate && !@readiness_observer
        return {
          "status" => "unavailable",
          "error" => "exact generation-bound bring-up readiness binding is unavailable"
        }
      end
      observer = @readiness_observer || DynamicWorkerRegistry.new(
        state_root: @root,
        repo_root: @repo_root,
        fleet_sources: [{ "fleet_key" => profile_id, "state" => current_state }],
        readiness_gate: @readiness_gate
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
      required = @capability_request&.required_gpu_id
      required ? [required] : @hardware.fetch("qualified_gpu_ids")
    end

    def bringup_reconciler(transition_guard)
      return @bringup_reconciler_factory.call(transition_guard) if @bringup_reconciler_factory

      state = current_state
      tunnels = LocalModelEvaluation::RunpodTunnels.new(
        fleet_state: state, repo_root: @repo_root, out: @out, wall_clock: @wall_clock
      )
      process = LocalModelEvaluation::ProcessSupervisor.new
      WorkerBringupReconciler.new(
        root: @root,
        tunnel: WorkerBringupAdapters::Tunnel.new(
          tunnels:, requirement: @capability_request, transition_guard:
        ),
        bootstrap: WorkerBringupAdapters::Bootstrap.new(
          root: @root, repo_root: @repo_root, fleet_state: state,
          shared_store_path: @hardware.fetch("ollama_store_path"),
          process_supervisor: process, requirement: @capability_request,
          transition_guard:, clock: @wall_clock
        ),
        capability: WorkerBringupAdapters::Capability.new(
          checker: CapabilityCheck.new(
            fleet_state: state, fleet_key: profile_id, wall_clock: @wall_clock
          ),
          requirement: @capability_request, transition_guard:
        ),
        process_inspector: process,
        clock: @wall_clock
      )
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
