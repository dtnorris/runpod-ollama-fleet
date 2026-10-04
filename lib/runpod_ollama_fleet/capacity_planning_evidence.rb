# frozen_string_literal: true

require_relative "campaign_budget_binding"
require_relative "authorized_candidates"
require_relative "ollama_capability_request"

module RunpodOllamaFleet
  # Advisory observations only. Actual acquisition must repeat normal admission.
  class CapacityPlanningEvidence
    CONTRACT_VERSION = "rpof-capacity-planning-evidence/v0.1"
    MAX_PROPOSED_WORKERS = 1_000_000
    class Error < StandardError; end

    # The policy still performs the single catalog request and all qualification.
    # Retaining that response lets us distinguish missing/invalid price and
    # availability independently from the policy's first rejection reason.
    class CatalogObservation
      attr_reader :rows
      def initialize(client)
        @client = client
      end

      def list_gpu_types(**options)
        @rows = @client.list_gpu_types(**options)
      end
    end
    private_constant :CatalogObservation

    def initialize(binding:, profile_id:, capability_request:, client:, clock: -> { Time.now.utc })
      raise Error, "binding must be a CampaignBudgetBinding" unless binding.is_a?(CampaignBudgetBinding)
      raise Error, "exact capability request required" unless capability_request.is_a?(OllamaCapabilityRequest)

      @binding = binding
      @profile = binding.campaign.profiles.find { |row| row.fetch("profile_id") == profile_id }
      raise Error, "unknown campaign profile_id #{profile_id.inspect}" unless @profile
      @hardware = binding.campaign.hardware_bindings.find { |row| row.fetch("profile_id") == profile_id }
      capability_request.validate_profile!(profile: @profile, hardware: @hardware)
      @request = capability_request
      @client = client
      @clock = clock
    end

    # proposed_workers is an absolute target for this profile, including its
    # already committed/pending workers. Other profiles' commitments are kept.
    # A lower target never grants a credit for speculative retirement.
    def document(proposed_workers:)
      unless proposed_workers.is_a?(Integer) && proposed_workers.between?(1, MAX_PROPOSED_WORKERS)
        raise Error, "proposed_workers must be an integer between 1 and #{MAX_PROPOSED_WORKERS}"
      end
      retained = @binding.planning_authority
      ledger = retained.fetch("parent_budget")
      active = ledger.fetch("owned_resources").values.select { |row| row.fetch("status") == "active" }
      pending = ledger.fetch("reservations").values.select { |row| row.fetch("status") == "pending" }
      committed = active + pending
      profile_count = committed.count { |row| row.fetch("fleet_key") == @profile.fetch("profile_id") }
      additional = [proposed_workers - profile_count, 0].max
      projected_workers = committed.length + additional
      ids = @request.required_gpu_id ? [@request.required_gpu_id] : @hardware.fetch("qualified_gpu_ids")
      catalog = CatalogObservation.new(@client)
      catalog_error = nil
      begin
        rows = AuthorizedCandidates.observe(client: catalog, gpu_ids: ids, cloud: @hardware.fetch("cloud"))
      rescue LocalModelEvaluation::RunpodCapacityPolicy::Error => e
        catalog_error = e.message
        # No ranking can be asserted without an observation. Retained identity
        # order is used only for reporting; no eligible candidate is invented.
        rows = ids.sort.map do |id|
          { "gpu_id" => id, "cloud" => @hardware.fetch("cloud"), "hourly_rate_usd" => nil,
            "eligible" => false, "reason" => "provider_catalog_unavailable" }
        end
      end
      candidates = rows.map.with_index do |row, index|
        candidate_evidence(row, index, catalog, ledger, [proposed_workers, profile_count].max, projected_workers, additional, catalog_error)
      end
      previews = candidates.map { |row| row.fetch("admission_preview") }
      overall = if previews.any? { |row| row.fetch("status") == "admissible_under_current_authority" }
                  "admissible_under_current_authority"
                elsif previews.any? { |row| row.fetch("status") == "insufficient_evidence" }
                  "insufficient_evidence"
                else
                  "not_admissible"
                end
      reasons = overall == "admissible_under_current_authority" ? [] : previews.flat_map { |row| row.fetch("reasons") }.uniq
      reasons << "no_currently_eligible_authorized_candidate" unless rows.any? { |row| row.fetch("eligible") }
      {
        "contract_version" => CONTRACT_VERSION, "read_only" => true,
        "observed_at_utc" => @clock.call.utc.iso8601,
        "campaign_id" => @binding.campaign.campaign_id,
        "campaign_identity_sha256" => @binding.campaign.identity_sha256,
        "binding_sha256" => @binding.binding_sha256,
        "budget_id" => @binding.declaration.fetch("budget_id"),
        "profile_id" => @profile.fetch("profile_id"), "capability_fingerprint" => @request.fingerprint,
        "proposal" => { "profile_workers" => proposed_workers, "additional_workers" => additional,
                        "projected_campaign_workers" => projected_workers,
                        "basis" => "absolute profile target; preserve all active and pending commitments; no retirement credit" },
        "authority" => @binding.authority_preview.merge(
          "phase" => retained.fetch("phase"), "parent_budget_state" => ledger.fetch("state"),
          "original_deadline_at_utc" => retained.fetch("deadline_at_utc"),
          "profile_max_workers" => @profile.fetch("max_workers"),
          "active_workers" => active.length, "pending_or_ambiguous_workers" => pending.length,
          "committed_profile_workers" => profile_count,
          "committed_hourly_rate_usd" => ledger.fetch("committed_rate_usd_per_hour"),
          "accrued_compute_usd" => ledger.fetch("accrued_compute_usd"),
          "committed_maximum_liability_usd" => ledger.fetch("committed_maximum_liability_usd"),
          "remaining_uncommitted_compute_usd" => ledger.fetch("remaining_uncommitted_budget_usd")
        ),
        "catalog_error" => catalog_error, "candidates" => candidates,
        "admission_preview" => { "status" => overall, "reasons" => reasons.uniq, "mutation_permission" => false },
        "availability_semantics" => "current catalog observation for one GPU; not reserved, guaranteed, or proof of proposed-count capacity",
        "projection_semantics" => "committed campaign rate plus additional profile workers at candidate rate; existing FO-08 crash horizon, not completion cost",
        "consistency" => "point-in-time observations; actual admission must recheck current authority"
      }
    rescue CampaignBudgetBinding::Error => e
      raise Error, e.message
    end

    private

    def candidate_evidence(row, index, catalog, ledger, proposed, total, additional, catalog_error)
      raw = Array(catalog.rows).reverse.find { |item| item["id"].to_s == row.fetch("gpu_id") }
      value = raw&.dig("price", row.fetch("cloud").downcase)
      price_state = if value.nil?
                      "unavailable"
                    else
                      begin
                        rate = Float(value)
                        rate.positive? && rate.finite? ? "observed" : "invalid"
                      rescue ArgumentError, TypeError
                        "invalid"
                      end
                    end
      # FO-15 qualification remains authoritative; never replace a rejected rate.
      rate = price_state == "observed" ? row["hourly_rate_usd"] : nil
      availability = if !raw || raw["availability"].to_s.empty?
                       "unknown"
                     elsif raw[row.fetch("cloud").downcase] != true || raw["availability"] == "NONE"
                       "unavailable"
                     else
                       "reported_available"
                     end
      projected = rate && Float(ledger.fetch("committed_rate_usd_per_hour")) + additional * rate
      reasons = []
      reasons << "profile_worker_ceiling_exceeded" if proposed > @profile.fetch("max_workers")
      reasons << "projected_worker_ceiling_exceeded" if total > @binding.declaration.fetch("max_workers")
      reasons << "original_deadline_expired" unless Time.iso8601(ledger.fetch("deadline_at_utc")) > @clock.call
      reasons << "candidate_rejected_by_fo15" unless row.fetch("eligible")
      reasons << "price_#{price_state}" unless price_state == "observed"
      reasons << "availability_#{availability}" unless availability == "reported_available"
      report = nil
      safety_error = nil
      begin
        report = @binding.safety_report(projected_workers: total, projected_hourly_rate_usd: projected)
        reasons.concat(report.fetch("refusal_reasons"))
        if report.dig("workers", "committed_and_pending") != ledger.fetch("committed_worker_count") ||
           report.dig("hourly_compute_usd", "committed_and_pending") != ledger.fetch("committed_rate_usd_per_hour")
          reasons << "authority_changed_during_observation"
        end
      rescue CampaignBudgetBinding::Error => e
        safety_error = e.message
        reasons << "guardian_or_safety_evidence_unavailable"
      end
      unknown = catalog_error || safety_error || price_state != "observed" || availability == "unknown" ||
                reasons.include?("authority_changed_during_observation")
      hard_refusal = reasons.any? { |reason| reason.match?(/ceiling_exceeded|authority_exceeded|deadline_expired/) }
      status = if reasons.empty?
                 "admissible_under_current_authority"
               elsif unknown && !hard_refusal
                 "insufficient_evidence"
               else
                 "not_admissible"
               end
      row.merge(
        "rank" => catalog_error ? nil : index + 1, "authorized" => true,
        "hourly_rate_usd" => rate, "price_status" => price_state,
        "availability" => availability, "provider_availability" => raw && raw["availability"],
        "projected_aggregate_hourly_rate_usd" => projected&.round(6),
        "admission_preview" => { "status" => status, "reasons" => reasons.uniq,
                                 "mutation_permission" => false, "safety_report" => report, "error" => safety_error }
      )
    end
  end
end
