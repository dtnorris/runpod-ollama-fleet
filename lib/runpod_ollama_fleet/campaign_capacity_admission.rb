# frozen_string_literal: true

require_relative "campaign_budget_binding"

module RunpodOllamaFleet
  # Provider-neutral mutation ordering for campaign-owned paid capacity. It
  # persists authority before yielding to a provider create call and keeps an
  # attempted-but-uncommitted reservation pending unless absence is proven.
  class CampaignCapacityAdmission
    AUTHORITY_VERSION = "rpof-capacity-campaign-fleet-authority/v0.1"

    class Error < StandardError; end

    Handle = Struct.new(
      :binding_sha256, :profile_id, :reservation_id, :created_at_utc,
      :provider_attempted, :finished,
      keyword_init: true
    )
    private_constant :Handle

    attr_reader :binding, :profile_id

    def initialize(binding:, profile_id:, event_sink: nil)
      unless binding.is_a?(CampaignBudgetBinding)
        raise Error, "binding must be a CampaignBudgetBinding"
      end

      @binding = binding
      @profile_id = profile_id.to_s
      @profile = binding.campaign.profiles.find { |row| row.fetch("profile_id") == @profile_id }
      raise Error, "unknown campaign profile_id #{profile_id.inspect}" unless @profile

      @hardware = binding.campaign.hardware_bindings.find do |row|
        row.fetch("profile_id") == @profile_id
      end
      raise Error, "campaign profile has no hardware qualification binding" unless @hardware

      @event_sink = event_sink || ->(_event, _detail) {}
    end

    def authority_identity
      @authority_identity ||= deep_freeze(
        "contract_version" => AUTHORITY_VERSION,
        "binding_sha256" => binding.binding_sha256,
        "campaign_identity_sha256" => binding.campaign.identity_sha256,
        "budget_id" => binding.declaration.fetch("budget_id"),
        "profile_id" => profile_id
      )
    end

    def assert_matches!(value)
      normalized = value.respond_to?(:transform_keys) ? value.transform_keys(&:to_s) : nil
      unless normalized == authority_identity
        raise Error, "fleet campaign authority does not match the supplied campaign binding and profile"
      end
      true
    end

    def reserve!(operation_type:, logical_resource_id:, max_hourly_rate_delta_usd:,
                 gpu_id:, cloud:, reservation_id: nil)
      verify_qualified_hardware!(gpu_id:, cloud:)
      result = binding.reserve_capacity_mutation!(
        expected_binding_sha256: binding.binding_sha256,
        operation_type:,
        profile_id:,
        logical_resource_id:,
        max_hourly_rate_delta_usd:,
        additional_workers: 1,
        reservation_id:
      )
      reservation = result.fetch("reservation")
      handle = Handle.new(
        binding_sha256: binding.binding_sha256,
        profile_id:,
        reservation_id: reservation.fetch("reservation_id"),
        created_at_utc: reservation.fetch("created_at_utc"),
        provider_attempted: false,
        finished: false
      )
      emit("reservation_persisted", handle)
      handle
    rescue CampaignBudgetBinding::Error, KeyError => e
      raise Error, e.message
    end

    # The reservation is already durable when this method is entered. Any
    # exception from the provider block is ambiguous and intentionally leaves
    # the reservation pending.
    def attempt_provider_create!(handle)
      verify_open_handle!(handle)
      handle.provider_attempted = true
      emit("provider_create_invoked", handle)
      yield
    end

    def commit!(handle, provider_resource_id:, actual_hourly_rate_usd:)
      verify_open_handle!(handle)
      raise Error, "provider create was not attempted" unless handle.provider_attempted

      result = binding.commit_capacity_mutation!(
        expected_binding_sha256: binding.binding_sha256,
        profile_id:,
        reservation_id: handle.reservation_id,
        provider_resource_id:,
        actual_hourly_rate_usd:,
        started_at_utc: handle.created_at_utc
      )
      handle.finished = true
      emit("provider_identity_committed", handle, "provider_resource_id" => provider_resource_id.to_s)
      result
    rescue CampaignBudgetBinding::Error => e
      # RunpodBudget deliberately persists the provider identity and moves the
      # parent authority to TEARDOWN_REQUIRED before raising when the provider
      # rate exceeds the reserved maximum. Keep the in-memory handle aligned
      # with that durable fact so verified rollback can mark the exact resource
      # absent instead of incorrectly treating the reservation as pending.
      if provider_resource_committed?(handle, provider_resource_id)
        handle.finished = true
        emit("provider_identity_committed_teardown_required", handle,
             "provider_resource_id" => provider_resource_id.to_s)
      end
      raise Error, e.message
    end

    def release_not_attempted!(handle, reason:)
      verify_open_handle!(handle)
      raise Error, "attempted provider mutation cannot be released without absence proof" if handle.provider_attempted

      result = binding.release_capacity_reservation!(
        expected_binding_sha256: binding.binding_sha256,
        profile_id:,
        reservation_id: handle.reservation_id,
        reason:,
        mutation_not_attempted: true
      )
      handle.finished = true
      emit("reservation_released_not_attempted", handle)
      result
    rescue CampaignBudgetBinding::Error => e
      raise Error, e.message
    end

    def release_verified_absent!(handle, reason:)
      verify_open_handle!(handle)
      raise Error, "provider absence release requires an attempted mutation" unless handle.provider_attempted

      result = binding.release_capacity_reservation!(
        expected_binding_sha256: binding.binding_sha256,
        profile_id:,
        reservation_id: handle.reservation_id,
        reason:,
        provider_absence_verified: true
      )
      handle.finished = true
      emit("reservation_released_provider_absent", handle)
      result
    rescue CampaignBudgetBinding::Error => e
      raise Error, e.message
    end

    def mark_resource_absent!(provider_resource_id:, stopped_at_utc: nil)
      binding.mark_capacity_resource_absent!(
        expected_binding_sha256: binding.binding_sha256,
        profile_id:,
        provider_resource_id:,
        stopped_at_utc:
      )
    rescue CampaignBudgetBinding::Error => e
      raise Error, e.message
    end

    def provider_absence_verified!(handle, provider_resource_id:, reason:)
      verify_handle!(handle)
      if handle.finished
        mark_resource_absent!(provider_resource_id:)
      else
        release_verified_absent!(handle, reason:)
      end
    end

    private

    def verify_qualified_hardware!(gpu_id:, cloud:)
      gpu = gpu_id.to_s
      unless @hardware.fetch("qualified_gpu_ids").include?(gpu)
        raise Error, "GPU #{gpu_id.inspect} is not qualified for campaign profile #{profile_id.inspect}"
      end
      unless @hardware.fetch("cloud") == cloud.to_s.upcase
        raise Error, "cloud #{cloud.inspect} does not match campaign profile qualification"
      end
      true
    end

    def verify_open_handle!(handle)
      verify_handle!(handle)
      raise Error, "campaign mutation handle is already finished" if handle.finished
      true
    end

    def verify_handle!(handle)
      unless handle.is_a?(Handle) && handle.binding_sha256 == binding.binding_sha256 &&
             handle.profile_id == profile_id
        raise Error, "mutation handle belongs to a different campaign authority"
      end
      true
    end

    def provider_resource_committed?(handle, provider_resource_id)
      status = binding.parent_budget.status
      reservation = status.fetch("reservations").fetch(handle.reservation_id, nil)
      resource = status.fetch("owned_resources").fetch(provider_resource_id.to_s, nil)
      reservation && resource && reservation.fetch("status") == "committed" &&
        reservation.fetch("provider_resource_id") == provider_resource_id.to_s &&
        resource.fetch("reservation_id") == handle.reservation_id
    rescue LocalModelEvaluation::RunpodBudget::Error, KeyError
      false
    end

    def emit(event, handle, detail = {})
      @event_sink.call(
        event,
        {
          "binding_sha256" => handle.binding_sha256,
          "profile_id" => handle.profile_id,
          "reservation_id" => handle.reservation_id
        }.merge(detail)
      )
    end

    def deep_freeze(value)
      case value
      when Hash
        value.each { |key, item| deep_freeze(key); deep_freeze(item) }
      when Array then value.each { |item| deep_freeze(item) }
      end
      value.freeze
    end
  end
end
