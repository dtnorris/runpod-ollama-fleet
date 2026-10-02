# frozen_string_literal: true

require "time"
require_relative "campaign_capacity_admission"
require_relative "desired_capacity"

module RunpodOllamaFleet
  # Human-facing orchestration for one immutable capacity campaign. Provider
  # mutations remain in RunpodFleet/RunpodFleetLifecycle and therefore pass
  # through CampaignCapacityAdmission.
  class CampaignLifecycle
    class Error < StandardError; end
    class TransientReconciliationError < Error; end

    def initialize(campaign:, binding:, runtime_factory:, price_resolver: nil, wall_clock: nil,
                   desired_capacity: nil, controller_supervisor: nil)
      @campaign = campaign
      @binding = binding
      @runtime_factory = runtime_factory
      @price_resolver = price_resolver
      @wall_clock = wall_clock || -> { Time.now.utc }
      @desired_capacity = desired_capacity || DesiredCapacity.new(binding:, wall_clock: @wall_clock)
      @controller_supervisor = controller_supervisor
      unless binding.campaign.identity_sha256 == campaign.identity_sha256
        raise Error, "campaign binding does not match the requested campaign"
      end
    end

    def plan
      desired_state = @desired_capacity.current
      profiles = profiles_for(desired_state)
      projections = profiles.map do |profile|
        hardware = hardware_for(profile)
        rate = @price_resolver&.call(profile, hardware)
        profile_intent(profile, hardware).merge(
          "projected_worker_hourly_rate_usd" => rate,
          "projected_desired_hourly_rate_usd" => rate && rate * profile.fetch("desired_workers")
        )
      end
      projected = projections.filter_map { |row| row["projected_desired_hourly_rate_usd"] }
      {
        "command" => "campaign plan",
        "read_only" => true,
        "paid_resources_created" => false,
        "campaign" => campaign_identity,
        "binding_sha256" => @binding.binding_sha256,
        "desired_capacity" => desired_state,
        "budget" => budget_intent,
        "profiles" => projections,
        "expected_desired_workers" => profiles.sum { |p| p.fetch("desired_workers") },
        "projected_desired_hourly_rate_usd" => projected.length == projections.length ? projected.sum : nil
      }
    rescue StandardError => e
      raise e if e.is_a?(Error)
      raise Error, e.message
    end

    def start(authorize_paid:, ssh_public_key_path: nil, safety_reporter: nil)
      unless authorize_paid
        return plan.merge(
          "authorization_required" => true,
          "message" => "no paid mutation attempted; repeat with --authorize-paid"
        )
      end

      desired_state = @desired_capacity.current
      profiles = profiles_for(desired_state)
      existing = existing_authority
      if existing && existing.dig("parent_budget", "state") == "CLOSED"
        raise Error, "campaign is closed and cannot be restarted under the same binding"
      end

      @binding.bind!
      authority = reusable_authority(existing) || @binding.arm!
      verify_started_authority!(authority)
      prepared = prepare_start(authority, profiles:)
      safety_report = @binding.assert_safety_gate!(
        projected_workers: prepared.fetch("projected_workers"),
        projected_hourly_rate_usd: prepared.fetch("projected_hourly_rate_usd")
      )
      safety_reporter&.call(safety_report)
      unless @controller_supervisor
        raise Error, "authorized campaign start requires a continuing controller supervisor"
      end
      controller = @controller_supervisor.ensure_running!(
        binding: @binding,
        ssh_public_key_path: ssh_public_key_path,
        heartbeat_timeout_seconds: @binding.declaration.fetch("orchestrator_heartbeat_timeout_seconds")
      )

      status(desired_state:).merge(
        "command" => "campaign start",
        "paid_authorized" => true,
        "safety_report" => safety_report,
        "controller" => controller
      )
    rescue CampaignBudgetBinding::Error, CampaignCapacityAdmission::Error,
           CampaignControllerSupervisor::Error, DesiredCapacity::Error => e
      raise Error, e.message
    end

    def status(desired_state: nil)
      desired_state ||= @desired_capacity.current
      profiles = profiles_for(desired_state)
      authority = existing_authority
      raise Error, "campaign has not been bound; run campaign plan or campaign start" unless authority

      ledger = authority["parent_budget"] || {}
      now = utc_now
      armed_at = parse_optional_time(authority["armed_at_utc"] || ledger["armed_at_utc"])
      deadline = parse_optional_time(authority["deadline_at_utc"] || ledger["deadline_at_utc"])
      reservations = ledger.fetch("reservations", {}).values
      resources = ledger.fetch("owned_resources", {}).values
      pending = reservations.select { |row| row["status"] == "pending" }
      active = resources.select { |row| row["status"] == "active" }
      profile_rows = profiles.map do |profile|
        runtime = @runtime_factory.call(profile, hardware_for(profile), nil)
        runtime.status.merge(
          "profile_id" => profile.fetch("profile_id"),
          "desired_workers" => profile.fetch("desired_workers"),
          "max_workers" => profile.fetch("max_workers"),
          "pending_reservations" => pending.count { |row| row["fleet_key"] == profile.fetch("profile_id") }
        )
      end
      result = {
        "command" => "campaign status",
        "read_only" => true,
        "campaign" => campaign_identity,
        "binding_sha256" => @binding.binding_sha256,
        "desired_capacity" => desired_state,
        "binding_phase" => authority["phase"],
        "budget_state" => ledger["state"],
        "guardian_healthy" => authority.fetch("guardian_healthy", false),
        "guardian" => authority["guardian"],
        "armed_at_utc" => armed_at&.iso8601,
        "deadline_at_utc" => deadline&.iso8601,
        "elapsed_runtime_seconds" => armed_at && [now - armed_at, 0.0].max.round(6),
        "remaining_runtime_seconds" => deadline && [deadline - now, 0.0].max.round(6),
        "accrued_compute_usd" => ledger["accrued_compute_usd"],
        "reserved_maximum_liability_usd" => ledger["committed_maximum_liability_usd"],
        "max_cumulative_compute_usd" => @binding.declaration.fetch("max_cumulative_compute_usd"),
        "active_workers" => active.length,
        "pending_workers" => pending.length,
        "active_plus_pending_workers" => active.length + pending.length,
        "max_workers" => @binding.declaration.fetch("max_workers"),
        "active_hourly_rate_usd" => active.sum { |row| Float(row.fetch("hourly_rate_usd")) },
        "pending_hourly_rate_usd" => pending.sum { |row| Float(row.fetch("max_hourly_rate_delta_usd")) },
        "active_plus_pending_hourly_rate_usd" => active.sum { |row| Float(row.fetch("hourly_rate_usd")) } +
                                                  pending.sum { |row| Float(row.fetch("max_hourly_rate_delta_usd")) },
        "max_aggregate_hourly_rate_usd" => @binding.declaration.fetch("max_aggregate_hourly_rate_usd"),
        "pending_ambiguous_reservations" => pending,
        "teardown_reason" => ledger["teardown_reason"],
        "teardown_failures" => ledger.fetch("teardown_failures", []),
        "provider_absence_verified_at_utc" => ledger["provider_absence_verified_at_utc"],
        "profiles" => profile_rows
      }
      result["controller"] = @controller_supervisor.status(binding: @binding) if @controller_supervisor
      result
    rescue CampaignBudgetBinding::Error, DesiredCapacity::Error, KeyError, ArgumentError, TypeError => e
      raise Error, e.message
    end

    def desired
      state = @desired_capacity.current
      {
        "command" => "campaign desired",
        "read_only" => true,
        "provider_mutations" => 0,
        "actual_capacity_unchanged" => true,
        "campaign" => campaign_identity,
        "binding_sha256" => @binding.binding_sha256,
        "desired_capacity" => state,
        "profiles" => profiles_for(state).map do |profile|
          profile.slice("profile_id", "desired_workers", "max_workers")
        end
      }
    rescue DesiredCapacity::Error => e
      raise Error, e.message
    end

    def set_desired(profile_counts:, expected_revision:, reason:)
      state = @desired_capacity.update!(profile_counts:, expected_revision:, reason:)
      {
        "command" => "campaign desired-set",
        "updated" => state.fetch("changed"),
        "provider_mutations" => 0,
        "actual_capacity_unchanged" => true,
        "campaign" => campaign_identity,
        "binding_sha256" => @binding.binding_sha256,
        "desired_capacity" => state.except("changed"),
        "profiles" => profiles_for(state).map do |profile|
          profile.slice("profile_id", "desired_workers", "max_workers")
        end
      }
    rescue DesiredCapacity::Error => e
      raise Error, e.message
    end

    def stop(reason: "operator requested campaign stop")
      authority = existing_authority
      raise Error, "campaign has not been bound" unless authority
      ledger = authority["parent_budget"]
      raise Error, "campaign parent budget state is unavailable" unless ledger

      result = if ledger.fetch("state") == "CLOSED"
                 ledger
               else
                 @binding.parent_budget.begin_teardown!(reason:)
               end
      controller = @controller_supervisor&.disable!(binding: @binding)
      {
        "command" => "campaign stop",
        "teardown_requested" => result.fetch("state") != "CLOSED",
        "budget_state" => result.fetch("state"),
        "provider_absence_verified" => !result["provider_absence_verified_at_utc"].nil?,
        "provider_absence_verified_at_utc" => result["provider_absence_verified_at_utc"],
        "teardown_failures" => result.fetch("teardown_failures", []),
        "controller" => controller,
        "message" => result.fetch("state") == "CLOSED" ?
          "campaign is closed with provider absence verified" :
          "teardown is guardian-owned and is not complete until provider absence is verified"
      }
    rescue CampaignBudgetBinding::Error, CampaignControllerSupervisor::Error,
           LocalModelEvaluation::RunpodBudget::Error, KeyError => e
      raise Error, e.message
    end

    # One controller-owned reconciliation pass. Each pass reads FO-13's current
    # identity-bound desired-capacity revision before calculating admission.
    def reconcile_once(ssh_public_key_path:)
      authority = @binding.status
      verify_started_authority!(authority)
      desired_state = @desired_capacity.current
      profiles = profiles_for(desired_state)
      prepared = prepare_start(authority, profiles:)
      safety_report = @binding.assert_safety_gate!(
        projected_workers: prepared.fetch("projected_workers"),
        projected_hourly_rate_usd: prepared.fetch("projected_hourly_rate_usd")
      )
      results = prepared.fetch("profiles").map do |row|
        reconcile_profile(row, authority, ssh_public_key_path)
      end
      { "desired_capacity" => desired_state, "safety_report" => safety_report, "profiles" => results }
    rescue CampaignBudgetBinding::Error, CampaignCapacityAdmission::Error, DesiredCapacity::Error => e
      raise Error, e.message
    end

    private

    def reconcile_profile(row, authority, ssh_public_key_path)
      profile = row.fetch("profile")
      runtime = row.fetch("runtime")
      current = row.fetch("current_workers")
      desired = desired_workers_for(profile)
      maximum = profile.fetch("max_workers")
      raise Error, "profile #{profile.fetch('profile_id').inspect} has #{current} workers above max #{maximum}" if current > maximum

      committed = Integer(
        authority.dig("authority", "committed_workers_by_profile", profile.fetch("profile_id")) || 0
      )
      # A pending/ambiguous reservation is already conservative capacity. Never
      # create around it; the guardian/provider-absence path must resolve it.
      if current < desired && committed <= current
        runtime.ensure_workers!(
          desired_workers: desired,
          ssh_public_key_path:,
          original_deadline_at_utc: authority.fetch("deadline_at_utc"),
          max_hourly_rate_usd: @campaign.max_hourly_rate_usd
        )
      end
      runtime.status.merge(
        "profile_id" => profile.fetch("profile_id"),
        "desired_workers" => desired,
        "max_workers" => maximum,
        "action" => current < desired && committed <= current ? "ensure_desired_capacity" : "none"
      )
    rescue CampaignRunpodRuntime::Error => e
      raise TransientReconciliationError,
            "campaign reconciliation failed at #{profile.fetch('profile_id')}: #{e.message}"
    rescue StandardError => e
      raise Error, "campaign reconciliation failed at #{profile.fetch('profile_id')}: #{e.message}"
    end

    def desired_workers_for(profile)
      profile.fetch("desired_workers")
    end

    def reusable_authority(existing)
      return unless existing
      return unless existing["phase"] == "ARMED" && existing["guardian_healthy"] == true
      return unless existing.dig("parent_budget", "state") == "ARMED"

      @binding.status
    end

    def existing_authority
      return nil unless File.file?(@binding.state_path)
      @binding.inspect_authority
    end

    def verify_started_authority!(authority)
      raise Error, "campaign binding is not ARMED" unless authority.fetch("phase") == "ARMED"
      raise Error, "campaign guardian is unhealthy" unless authority.fetch("guardian_healthy")
      ledger = authority.fetch("parent_budget")
      raise Error, "campaign parent budget is not ARMED" unless ledger.fetch("state") == "ARMED"
      deadline = Time.parse(authority.fetch("deadline_at_utc")).utc
      raise Error, "campaign original deadline has expired" unless deadline > utc_now
    end

    def prepare_start(authority, profiles:)
      committed_by_profile = authority.dig("authority", "committed_workers_by_profile") || {}
      committed_workers = Integer(authority.dig("authority", "committed_workers"))
      committed_rate = Float(authority.dig("authority", "committed_hourly_rate_usd"))
      additions = 0
      additional_rate = 0.0
      rate_available = true
      rows = profiles.map do |profile|
        hardware = hardware_for(profile)
        admission = CampaignCapacityAdmission.new(binding: @binding, profile_id: profile.fetch("profile_id"))
        runtime = @runtime_factory.call(profile, hardware, admission)
        current = runtime.current_worker_count
        maximum = profile.fetch("max_workers")
        if current > maximum
          raise Error, "profile #{profile.fetch('profile_id').inspect} has #{current} workers above max #{maximum}"
        end

        committed_profile = Integer(committed_by_profile.fetch(profile.fetch("profile_id"), 0))
        if current > committed_profile
          raise Error, "profile #{profile.fetch('profile_id').inspect} has paid workers outside the campaign ledger"
        end
        accounted = [current, committed_profile].max
        missing = [profile.fetch("desired_workers") - accounted, 0].max
        if missing.positive?
          rate = @price_resolver&.call(profile, hardware)
          if rate.nil?
            rate_available = false
          else
            rate = Float(rate)
            unless rate.positive? && rate.finite?
              raise Error, "profile #{profile.fetch('profile_id').inspect} projected hourly rate must be positive and finite"
            end
            additional_rate += rate * missing
          end
          additions += missing
        end
        { "profile" => profile, "runtime" => runtime, "current_workers" => current }
      end
      {
        "profiles" => rows,
        "projected_workers" => committed_workers + additions,
        "projected_hourly_rate_usd" => rate_available ? committed_rate + additional_rate : nil
      }
    rescue KeyError, ArgumentError, TypeError => e
      raise Error, "could not calculate paid-start projection: #{e.message}"
    end

    def profiles_for(desired_state)
      counts = desired_state.fetch("profiles").to_h do |row|
        [row.fetch("profile_id"), row.fetch("desired_workers")]
      end
      @campaign.profiles.map do |profile|
        profile.merge("desired_workers" => counts.fetch(profile.fetch("profile_id")))
      end
    end

    def hardware_for(profile)
      @campaign.hardware_bindings.find { |row| row.fetch("profile_id") == profile.fetch("profile_id") } or
        raise Error, "campaign profile has no hardware qualification"
    end

    def profile_intent(profile, hardware)
      profile.merge(
        "qualified_gpu_ids" => hardware.fetch("qualified_gpu_ids"),
        "cloud" => hardware.fetch("cloud"),
        "global_volume_id" => hardware.fetch("global_volume_id")
      )
    end

    def campaign_identity
      @campaign.identity.merge("identity_sha256" => @campaign.identity_sha256)
    end

    def budget_intent
      @binding.declaration.slice(
        "budget_id", "max_workers", "max_aggregate_hourly_rate_usd",
        "max_cumulative_compute_usd", "max_runtime_seconds"
      )
    end

    def parse_optional_time(value)
      value && Time.parse(value.to_s).utc
    end

    def utc_now
      value = @wall_clock.call
      value = Time.parse(value.to_s) unless value.is_a?(Time)
      value.utc
    end
  end
end
