# frozen_string_literal: true

require "time"
require_relative "campaign_capacity_admission"

module RunpodOllamaFleet
  # Human-facing orchestration for one immutable capacity campaign. Provider
  # mutations remain in RunpodFleet/RunpodFleetLifecycle and therefore pass
  # through CampaignCapacityAdmission.
  class CampaignLifecycle
    class Error < StandardError; end

    def initialize(campaign:, binding:, runtime_factory:, price_resolver: nil, wall_clock: nil)
      @campaign = campaign
      @binding = binding
      @runtime_factory = runtime_factory
      @price_resolver = price_resolver
      @wall_clock = wall_clock || -> { Time.now.utc }
      unless binding.campaign.identity_sha256 == campaign.identity_sha256
        raise Error, "campaign binding does not match the requested campaign"
      end
    end

    def plan
      projections = @campaign.profiles.map do |profile|
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
        "budget" => budget_intent,
        "profiles" => projections,
        "expected_desired_workers" => @campaign.profiles.sum { |p| p.fetch("desired_workers") },
        "projected_desired_hourly_rate_usd" => projected.length == projections.length ? projected.sum : nil
      }
    rescue StandardError => e
      raise e if e.is_a?(Error)
      raise Error, e.message
    end

    def start(authorize_paid:, ssh_public_key_path: nil)
      unless authorize_paid
        return plan.merge(
          "authorization_required" => true,
          "message" => "no paid mutation attempted; repeat with --authorize-paid"
        )
      end

      existing = existing_authority
      if existing && existing.dig("parent_budget", "state") == "CLOSED"
        raise Error, "campaign is closed and cannot be restarted under the same binding"
      end

      @binding.bind!
      authority = @binding.arm!
      verify_started_authority!(authority)
      results = []
      @campaign.profiles.each do |profile|
        admission = CampaignCapacityAdmission.new(binding: @binding, profile_id: profile.fetch("profile_id"))
        runtime = @runtime_factory.call(profile, hardware_for(profile), admission)
        current = runtime.current_worker_count
        desired = profile.fetch("desired_workers")
        maximum = profile.fetch("max_workers")
        raise Error, "profile #{profile.fetch('profile_id').inspect} has #{current} workers above max #{maximum}" if current > maximum

        if current < desired
          runtime.ensure_workers!(
            desired_workers: desired,
            ssh_public_key_path:,
            original_deadline_at_utc: authority.fetch("deadline_at_utc"),
            max_hourly_rate_usd: @campaign.max_hourly_rate_usd
          )
        end
        results << runtime.status.merge(
          "profile_id" => profile.fetch("profile_id"),
          "desired_workers" => desired,
          "max_workers" => maximum
        )
      rescue StandardError => e
        raise Error, "partial campaign startup at #{profile.fetch('profile_id')}: #{e.message}"
      end

      status.merge("command" => "campaign start", "paid_authorized" => true, "profiles" => results)
    rescue CampaignBudgetBinding::Error, CampaignCapacityAdmission::Error => e
      raise Error, e.message
    end

    def status
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
      profile_rows = @campaign.profiles.map do |profile|
        runtime = @runtime_factory.call(profile, hardware_for(profile), nil)
        runtime.status.merge(
          "profile_id" => profile.fetch("profile_id"),
          "desired_workers" => profile.fetch("desired_workers"),
          "max_workers" => profile.fetch("max_workers"),
          "pending_reservations" => pending.count { |row| row["fleet_key"] == profile.fetch("profile_id") }
        )
      end
      {
        "command" => "campaign status",
        "read_only" => true,
        "campaign" => campaign_identity,
        "binding_sha256" => @binding.binding_sha256,
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
    rescue CampaignBudgetBinding::Error, KeyError, ArgumentError, TypeError => e
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
      {
        "command" => "campaign stop",
        "teardown_requested" => result.fetch("state") != "CLOSED",
        "budget_state" => result.fetch("state"),
        "provider_absence_verified" => !result["provider_absence_verified_at_utc"].nil?,
        "provider_absence_verified_at_utc" => result["provider_absence_verified_at_utc"],
        "teardown_failures" => result.fetch("teardown_failures", []),
        "message" => result.fetch("state") == "CLOSED" ?
          "campaign is closed with provider absence verified" :
          "teardown is guardian-owned and is not complete until provider absence is verified"
      }
    rescue CampaignBudgetBinding::Error, LocalModelEvaluation::RunpodBudget::Error, KeyError => e
      raise Error, e.message
    end

    private

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
