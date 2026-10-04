# frozen_string_literal: true

require "digest"
require "fileutils"
require "json"
require "time"
require_relative "capacity_campaign"
require_relative "../local_model_evaluation/runpod_budget"
require_relative "../local_model_evaluation/runpod_budget_guardian_supervisor"

module RunpodOllamaFleet
  # Durable one-to-one binding between a capacity campaign and the existing
  # parent RunpodBudget/guardian authority. It does not select or provision
  # provider resources.
  class CampaignBudgetBinding
    CONTRACT_VERSION = "rpof-capacity-campaign-budget/v0.1"
    STATE_CONTRACT_VERSION = "rpof-capacity-campaign-budget-state/v0.1"
    MUTATION_AUTHORITY_VERSION = "rpof-capacity-campaign-mutation-authority/v0.1"
    SAFETY_REPORT_VERSION = "rpof-capacity-campaign-safety-report/v0.1"
    RETAINED_SAFETY_REPORT_VERSION = "rpof-retained-capacity-campaign-safety-report/v0.1"
    PHASES = %w[BOUND ARMING ARMED].freeze
    DIGEST = /\A[0-9a-f]{64}\z/i
    DECLARATION_KEYS = %w[
      contract_version campaign_identity campaign_identity_sha256 budget_id
      max_cumulative_compute_usd max_aggregate_hourly_rate_usd max_workers
      max_runtime_seconds guardian_poll_seconds
      orchestrator_heartbeat_timeout_seconds teardown_reserve_seconds
    ].freeze
    IDENTITY_KEYS = %w[
      contract_version campaign_id campaign_sha256 hardware_qualification_sha256
    ].freeze
    STATE_KEYS = %w[
      contract_version binding_sha256 binding phase bound_at_utc
      arm_started_at_utc armed_at_utc deadline_at_utc last_resume_at_utc
      last_error
    ].freeze

    class Error < StandardError; end

    attr_reader :campaign, :declaration, :normalized_bytes, :binding_sha256,
                :state_path, :safety_report_path, :parent_budget

    def initialize(root:, repo_root:, campaign:, declaration:, wall_clock: nil,
                   budget_factory: nil, guardian_supervisor: nil)
      unless campaign.is_a?(CapacityCampaign)
        raise Error, "campaign must be a validated CapacityCampaign"
      end

      @root = File.expand_path(root)
      @repo_root = File.expand_path(repo_root)
      @campaign = campaign
      @wall_clock = wall_clock || -> { Time.now.utc }
      @declaration = normalize_declaration(declaration)
      deep_freeze(@declaration)
      @normalized_bytes = JSON.generate(@declaration).freeze
      @binding_sha256 = Digest::SHA256.hexdigest(@normalized_bytes).freeze
      campaign_key = Digest::SHA256.hexdigest(campaign.campaign_id)
      @binding_dir = File.join(@root, "campaign-budgets", campaign_key)
      @state_path = File.join(@binding_dir, "binding.json")
      @safety_report_path = File.join(@binding_dir, "latest-safety-report.json")
      @lock_path = File.join(@binding_dir, ".lock")
      factory = budget_factory || lambda do |**keywords|
        LocalModelEvaluation::RunpodBudget.new(**keywords)
      end
      @parent_budget = factory.call(
        root: @root,
        budget_id: @declaration.fetch("budget_id"),
        plan_sha256: @binding_sha256,
        wall_clock: @wall_clock
      )
      @guardian_supervisor = guardian_supervisor ||
                             LocalModelEvaluation::RunpodBudgetGuardianSupervisor.new(
                               root: @root,
                               repo_root: @repo_root
                             )
    rescue ArgumentError, TypeError => e
      raise Error, "invalid campaign budget binding: #{e.message}"
    end

    # Persist the immutable binding before any paid mutation is allowed. A
    # matching existing binding is reused; any mismatch fails closed.
    def bind!
      with_lock do
        if File.file?(@state_path)
          return binding_snapshot(load_state!)
        end
        if File.file?(@parent_budget.state_path)
          raise Error, "parent budget state exists without its durable campaign binding"
        end

        now = utc_now
        document = {
          "contract_version" => STATE_CONTRACT_VERSION,
          "binding_sha256" => binding_sha256,
          "binding" => declaration,
          "phase" => "BOUND",
          "bound_at_utc" => now.iso8601,
          "arm_started_at_utc" => nil,
          "armed_at_utc" => nil,
          "deadline_at_utc" => nil,
          "last_resume_at_utc" => nil,
          "last_error" => nil
        }
        persist!(document)
        binding_snapshot(document)
      end
    end

    # Starts the independent guardian and arms the existing parent ledger. A
    # resume uses the same ledger and verifies that its original deadline did
    # not move. ARMING is intentionally sticky after an uncertain result.
    def arm!
      bind!
      initial = false
      with_lock do
        document = load_state!
        case document.fetch("phase")
        when "ARMING"
          raise Error, "campaign budget has an ambiguous prior arm result; inspect it before recovery"
        when "BOUND"
          initial = true
          document["phase"] = "ARMING"
          document["arm_started_at_utc"] = utc_now.iso8601
          document["last_error"] = nil
          persist!(document)
        when "ARMED"
          # Resume below using the same immutable authority.
        end
      end

      ledger = @guardian_supervisor.arm!(budget: @parent_budget, request: parent_budget_request)
      verify_ledger!(ledger)
      guardian = guardian_status
      ensure_guardian_healthy!(guardian)

      with_lock do
        document = load_state!
        if initial
          unless document.fetch("phase") == "ARMING"
            raise Error, "campaign budget arm phase changed unexpectedly"
          end
          document["phase"] = "ARMED"
          document["armed_at_utc"] = ledger.fetch("armed_at_utc")
          document["deadline_at_utc"] = ledger.fetch("deadline_at_utc")
        else
          verify_original_times!(document, ledger)
          document["last_resume_at_utc"] = utc_now.iso8601
        end
        document["last_error"] = nil
        persist!(document)
      end
      status
    rescue Error, LocalModelEvaluation::RunpodBudget::Error,
           LocalModelEvaluation::RunpodBudgetGuardianSupervisor::Error,
           KeyError, ArgumentError, TypeError, SystemCallError => e
      retain_arm_error(e.message, initial:)
      raise Error, e.message
    end

    # Read-only evidence for operators, including ambiguous ARMING outcomes.
    def inspect_authority
      binding = with_read_lock { binding_snapshot(load_state!) }
      ledger = safe_parent_status
      guardian = safe_guardian_status
      binding.merge(
        "parent_budget" => ledger,
        "guardian" => guardian,
        "guardian_healthy" => guardian.fetch("healthy", false)
      )
    end

    def status
      binding = with_read_lock { binding_snapshot(load_state!) }
      unless binding.fetch("phase") == "ARMED"
        raise Error, "campaign budget is #{binding.fetch('phase')}; it is not armed"
      end

      ledger = @parent_budget.status
      verify_ledger!(ledger)
      verify_original_times!(binding, ledger)
      guardian = guardian_status
      authority = authority_snapshot(ledger, guardian:)
      binding.merge(
        "parent_budget" => ledger,
        "guardian" => guardian,
        "guardian_healthy" => guardian.fetch("healthy"),
        "authority" => authority
      )
    rescue LocalModelEvaluation::RunpodBudget::Error,
           LocalModelEvaluation::RunpodBudgetGuardianSupervisor::Error,
           KeyError, ArgumentError, TypeError => e
      raise Error, e.message
    end

    # Verified retained authority even when the independent guardian cannot be
    # observed. This does not evaluate or persist a mutation decision.
    def planning_authority
      binding = with_read_lock { binding_snapshot(load_state!) }
      ledger = @parent_budget.status
      verify_ledger!(ledger)
      verify_original_times!(binding, ledger)
      binding.merge("parent_budget" => ledger)
    rescue LocalModelEvaluation::RunpodBudget::Error, KeyError, ArgumentError, TypeError => e
      raise Error, e.message
    end

    # Authoritative, read-only paid-start proof. The calculation consumes the
    # same durable ledger and guardian evidence used by live mutation admission;
    # it neither refreshes a heartbeat nor changes budget state.
    def safety_report(projected_workers:, projected_hourly_rate_usd:)
      binding = with_read_lock { binding_snapshot(load_state!) }
      ledger = @parent_budget.status
      verify_ledger!(ledger)
      verify_original_times!(binding, ledger)
      guardian = guardian_status
      authority = authority_snapshot(ledger, guardian:)
      workers = nonnegative_integer!(projected_workers, "projected workers")
      rate = optional_nonnegative_float!(projected_hourly_rate_usd, "projected hourly rate")
      limits = ledger.fetch("limits")
      deadline = parse_time(ledger.fetch("deadline_at_utc"), "parent deadline_at_utc")
      now = utc_now
      horizon = LocalModelEvaluation::RunpodBudget.crash_horizon_seconds(limits)
      projected_additional = rate &&
                             LocalModelEvaluation::RunpodBudget.maximum_additional_compute_liability_usd(
                               hourly_rate_usd: rate,
                               limits:
                             )
      accrued = Float(ledger.fetch("accrued_compute_usd"))
      current_maximum = Float(ledger.fetch("committed_maximum_liability_usd"))
      projected_maximum = projected_additional && accrued + projected_additional
      cap = declaration.fetch("max_cumulative_compute_usd")
      active_resources = ledger.fetch("owned_resources").values.select { |row| row.fetch("status") == "active" }
      pending_reservations = ledger.fetch("reservations").values.select { |row| row.fetch("status") == "pending" }
      active_rate = active_resources.sum { |row| Float(row.fetch("hourly_rate_usd")) }
      pending_rate = pending_reservations.sum { |row| Float(row.fetch("max_hourly_rate_delta_usd")) }
      refusal_reasons = authority.fetch("violations").dup
      refusal_reasons << "binding_not_armed" unless binding.fetch("phase") == "ARMED"
      refusal_reasons << "guardian_identity_mismatch" unless guardian.fetch("identity_matches")
      refusal_reasons << "original_deadline_expired" unless deadline > now
      refusal_reasons << "projected_workers_below_committed" if workers < authority.fetch("committed_workers")
      refusal_reasons << "projected_worker_ceiling_exceeded" if workers > declaration.fetch("max_workers")
      refusal_reasons << "projected_hourly_rate_unavailable" unless rate
      if rate
        refusal_reasons << "projected_rate_below_committed" if rate + 1e-9 < authority.fetch("committed_hourly_rate_usd")
        if rate > declaration.fetch("max_aggregate_hourly_rate_usd") + 1e-9
          refusal_reasons << "projected_hourly_rate_ceiling_exceeded"
        end
      end
      if projected_maximum && projected_maximum > cap + 1e-9
        refusal_reasons << "projected_cumulative_compute_authority_exceeded"
      end
      refusal_reasons.uniq!

      {
        "contract_version" => SAFETY_REPORT_VERSION,
        "safety_gate" => refusal_reasons.empty? ? "PASS" : "FAIL",
        "refusal_reasons" => refusal_reasons.freeze,
        "campaign_id" => campaign.campaign_id,
        "campaign_identity_sha256" => campaign.identity_sha256,
        "binding_sha256" => binding_sha256,
        "budget_id" => declaration.fetch("budget_id"),
        "workers" => {
          "active" => active_resources.length,
          "pending_or_ambiguous" => pending_reservations.length,
          "committed_and_pending" => authority.fetch("committed_workers"),
          "projected" => workers,
          "maximum" => declaration.fetch("max_workers")
        },
        "hourly_compute_usd" => {
          "active" => active_rate.round(6),
          "pending_or_ambiguous" => pending_rate.round(6),
          "committed_and_pending" => authority.fetch("committed_hourly_rate_usd"),
          "projected" => rate&.round(6),
          "maximum" => declaration.fetch("max_aggregate_hourly_rate_usd")
        },
        "cumulative_compute_usd" => {
          "maximum" => cap,
          "accrued" => accrued.round(6),
          "committed_and_pending_maximum_liability" => current_maximum.round(6),
          "remaining_uncommitted_authority" => Float(
            ledger.fetch("remaining_uncommitted_budget_usd")
          ).round(6),
          "projected_maximum_liability" => projected_maximum&.round(6),
          "remaining_after_projection" => projected_maximum && [cap - projected_maximum, 0.0].max.round(6)
        },
        "runtime" => {
          "maximum_seconds" => declaration.fetch("max_runtime_seconds"),
          "armed_at_utc" => ledger.fetch("armed_at_utc"),
          "original_deadline_at_utc" => ledger.fetch("deadline_at_utc"),
          "remaining_seconds" => [deadline - now, 0.0].max.round(6)
        },
        "crash_liability" => {
          "guardian_poll_seconds" => declaration.fetch("guardian_poll_seconds"),
          "orchestrator_heartbeat_timeout_seconds" => declaration.fetch(
            "orchestrator_heartbeat_timeout_seconds"
          ),
          "teardown_reserve_seconds" => declaration.fetch("teardown_reserve_seconds"),
          "horizon_seconds" => horizon,
          "maximum_additional_compute_usd_after_orchestrator_loss" => projected_additional&.round(6),
          "derivation" => "projected_hourly_compute_usd * " \
                          "(guardian_poll_seconds + orchestrator_heartbeat_timeout_seconds + " \
                          "teardown_reserve_seconds) / 3600"
        },
        "enforcement" => enforcement_evidence(guardian),
        "billing_scope" => billing_scope_evidence,
        "absolute_refusal_conditions" => absolute_refusal_conditions
      }.freeze
    rescue LocalModelEvaluation::RunpodBudget::Error,
           LocalModelEvaluation::RunpodBudgetGuardianSupervisor::Error,
           KeyError, ArgumentError, TypeError => e
      raise Error, e.message
    end

    def assert_safety_gate!(projected_workers:, projected_hourly_rate_usd:)
      report = safety_report(projected_workers:, projected_hourly_rate_usd:)
      retain_safety_report!(report)
      return report if report.fetch("safety_gate") == "PASS"

      raise Error, "paid campaign start safety gate failed: #{report.fetch('refusal_reasons').join(', ')}"
    end

    # Read-only immutable-authority summary for an operator preview before a
    # guardian or ledger exists. Live paid admission remains safety_report.
    def authority_preview
      limits = declaration.slice(
        "max_cumulative_compute_usd", "max_aggregate_hourly_rate_usd", "max_workers",
        "max_runtime_seconds", "guardian_poll_seconds",
        "orchestrator_heartbeat_timeout_seconds", "teardown_reserve_seconds"
      )
      hourly = declaration.fetch("max_aggregate_hourly_rate_usd")
      {
        "budget_id" => declaration.fetch("budget_id"),
        "limits" => limits,
        "deadline" => {
          "derivation" => "armed_at_utc + max_runtime_seconds",
          "absolute_value" => "established once by the existing parent budget at first arm"
        },
        "crash_liability" => {
          "horizon_seconds" => LocalModelEvaluation::RunpodBudget.crash_horizon_seconds(limits),
          "maximum_additional_compute_usd_at_hourly_ceiling" =>
            LocalModelEvaluation::RunpodBudget.maximum_additional_compute_liability_usd(
              hourly_rate_usd: hourly, limits:
            ).round(6)
        },
        "billing_scope" => billing_scope_evidence,
        "paid_start_gate" => "not evaluated until retained authority and guardian evidence exist"
      }.freeze
    rescue LocalModelEvaluation::RunpodBudget::Error, KeyError, ArgumentError, TypeError => e
      raise Error, e.message
    end

    # Returns the last report evaluated by paid-start admission. Reading this
    # artifact never refreshes guardian/provider state and never recomputes the
    # FO-08 liability proof.
    def retained_safety_report
      return nil unless File.file?(safety_report_path)

      artifact = JSON.parse(File.read(safety_report_path))
      unless artifact.keys.sort == %w[binding_sha256 campaign_identity_sha256 contract_version recorded_at_utc report].sort &&
             artifact.fetch("contract_version") == RETAINED_SAFETY_REPORT_VERSION &&
             artifact.fetch("binding_sha256") == binding_sha256 &&
             artifact.fetch("campaign_identity_sha256") == campaign.identity_sha256 &&
             artifact.fetch("report").fetch("contract_version") == SAFETY_REPORT_VERSION
        raise Error, "retained paid-start safety report identity is invalid"
      end
      parse_time(artifact.fetch("recorded_at_utc"), "retained safety report timestamp")
      artifact
    rescue JSON::ParserError, KeyError, TypeError => e
      raise Error, "retained paid-start safety report is invalid: #{e.message}"
    end

    # Produces an immutable proof that a proposed capacity mutation is within
    # the parent authority. DW-06 will wire this seam into live admission.
    def mutation_authority!(expected_binding_sha256:, additional_workers:,
                            additional_hourly_rate_usd:, profile_id: nil)
      with_lock do
        mutation_authority_locked!(
          expected_binding_sha256:,
          additional_workers:,
          additional_hourly_rate_usd:,
          profile_id:
        )
      end
    rescue LocalModelEvaluation::RunpodBudget::Error,
           LocalModelEvaluation::RunpodBudgetGuardianSupervisor::Error => e
      raise Error, e.message
    end

    # Durable reservation seam for DW-06. All campaign callers using this seam
    # are serialized across the worker/rate check and the existing cumulative
    # liability reservation. No provider operation is performed here.
    def reserve_capacity_mutation!(expected_binding_sha256:, operation_type:, profile_id:,
                                   logical_resource_id:, max_hourly_rate_delta_usd:,
                                   additional_workers: 1, reservation_id: nil)
      profile = profile_id.to_s
      profile_definition!(profile)
      unless additional_workers == 1
        raise Error, "one durable campaign reservation must represent exactly one worker"
      end

      with_lock do
        proof = mutation_authority_locked!(
          expected_binding_sha256:,
          additional_workers:,
          additional_hourly_rate_usd: max_hourly_rate_delta_usd,
          profile_id: profile
        )
        reservation = @parent_budget.reserve_mutation!(
          operation_type:,
          fleet_key: profile,
          logical_resource_id:,
          max_hourly_rate_delta_usd:,
          reservation_id:
        )
        {
          "binding_sha256" => binding_sha256,
          "campaign_identity_sha256" => campaign.identity_sha256,
          "authority" => proof,
          "reservation" => reservation
        }
      end
    rescue LocalModelEvaluation::RunpodBudget::Error => e
      raise Error, e.message
    end

    def commit_capacity_mutation!(expected_binding_sha256:, profile_id:, reservation_id:,
                                  provider_resource_id:, actual_hourly_rate_usd:,
                                  started_at_utc: nil)
      with_lock do
        verify_expected_binding!(expected_binding_sha256)
        verify_capacity_reservation!(reservation_id, profile_id:, expected_status: "pending")
        @parent_budget.commit_mutation!(
          reservation_id:,
          provider_resource_id:,
          actual_hourly_rate_usd:,
          started_at_utc:
        )
      end
    rescue LocalModelEvaluation::RunpodBudget::Error => e
      raise Error, e.message
    end

    def release_capacity_reservation!(expected_binding_sha256:, profile_id:, reservation_id:,
                                      reason:, mutation_not_attempted: false,
                                      provider_absence_verified: false)
      with_lock do
        verify_expected_binding!(expected_binding_sha256)
        verify_capacity_reservation!(reservation_id, profile_id:, expected_status: "pending")
        @parent_budget.release_reservation!(
          reservation_id:,
          reason:,
          mutation_not_attempted:,
          provider_absence_verified:
        )
      end
    rescue LocalModelEvaluation::RunpodBudget::Error => e
      raise Error, e.message
    end

    def mark_capacity_resource_absent!(expected_binding_sha256:, profile_id:,
                                       provider_resource_id:, stopped_at_utc: nil)
      with_lock do
        verify_expected_binding!(expected_binding_sha256)
        ledger = @parent_budget.status
        resource = ledger.fetch("owned_resources").fetch(provider_resource_id.to_s) do
          raise Error, "provider resource is not owned by this campaign authority"
        end
        unless resource.fetch("fleet_key") == profile_id.to_s
          raise Error, "provider resource belongs to a different campaign profile"
        end
        @parent_budget.mark_resource_absent!(
          provider_resource_id:,
          verified_absent: true,
          stopped_at_utc:
        )
      end
    rescue LocalModelEvaluation::RunpodBudget::Error, KeyError => e
      raise Error, e.message
    end

    private

    def retain_safety_report!(report)
      artifact = {
        "contract_version" => RETAINED_SAFETY_REPORT_VERSION,
        "campaign_identity_sha256" => campaign.identity_sha256,
        "binding_sha256" => binding_sha256,
        "recorded_at_utc" => utc_now.iso8601,
        "report" => report
      }
      with_lock { write_json_atomic(safety_report_path, artifact) }
      artifact
    end

    def normalize_declaration(value)
      document = value.respond_to?(:transform_keys) ? value.transform_keys(&:to_s) : nil
      exact_keys!(document, DECLARATION_KEYS, "campaign budget")
      unless document.fetch("contract_version") == CONTRACT_VERSION
        raise Error, "campaign budget contract must be #{CONTRACT_VERSION.inspect}"
      end

      identity = document.fetch("campaign_identity")
      exact_keys!(identity, IDENTITY_KEYS, "campaign_identity")
      identity = identity.transform_keys(&:to_s)
      unless identity == campaign.identity
        raise Error, "campaign identity or hardware qualification binding does not match"
      end

      identity_sha = digest!(document.fetch("campaign_identity_sha256"), "campaign identity sha256")
      unless identity_sha == campaign.identity_sha256
        raise Error, "campaign identity sha256 does not match"
      end

      max_workers = positive_integer!(document.fetch("max_workers"), "maximum workers")
      unless max_workers == campaign.max_workers
        raise Error, "campaign budget maximum workers must equal the campaign maximum"
      end
      max_rate = positive_float!(
        document.fetch("max_aggregate_hourly_rate_usd"),
        "maximum aggregate hourly rate"
      )
      unless max_rate == campaign.max_hourly_rate_usd
        raise Error, "campaign budget hourly ceiling must equal the campaign hourly ceiling"
      end

      normalized = {
        "contract_version" => CONTRACT_VERSION,
        "campaign_identity" => campaign.identity,
        "campaign_identity_sha256" => campaign.identity_sha256,
        "budget_id" => nonempty_string!(document.fetch("budget_id"), "budget id"),
        "max_cumulative_compute_usd" => positive_float!(
          document.fetch("max_cumulative_compute_usd"),
          "maximum cumulative compute cost"
        ),
        "max_aggregate_hourly_rate_usd" => max_rate,
        "max_workers" => max_workers,
        "max_runtime_seconds" => positive_float!(document.fetch("max_runtime_seconds"), "maximum runtime"),
        "guardian_poll_seconds" => positive_float!(
          document.fetch("guardian_poll_seconds"),
          "guardian poll interval"
        ),
        "orchestrator_heartbeat_timeout_seconds" => positive_float!(
          document.fetch("orchestrator_heartbeat_timeout_seconds"),
          "orchestrator heartbeat timeout"
        ),
        "teardown_reserve_seconds" => positive_float!(
          document.fetch("teardown_reserve_seconds"),
          "teardown reserve"
        )
      }
      if normalized.fetch("orchestrator_heartbeat_timeout_seconds") <
         2 * normalized.fetch("guardian_poll_seconds")
        raise Error, "orchestrator heartbeat timeout must be at least twice the guardian poll interval"
      end
      normalized
    end

    def parent_budget_request
      {
        "contract_version" => LocalModelEvaluation::RunpodBudget::CAMPAIGN_CONTRACT_VERSION,
        "budget_id" => declaration.fetch("budget_id"),
        "plan_sha256" => binding_sha256,
        "campaign_binding_sha256" => binding_sha256,
        "max_cumulative_compute_usd" => declaration.fetch("max_cumulative_compute_usd"),
        "max_aggregate_hourly_rate_usd" => declaration.fetch("max_aggregate_hourly_rate_usd"),
        "max_workers" => declaration.fetch("max_workers"),
        "max_runtime_seconds" => declaration.fetch("max_runtime_seconds"),
        "guardian_poll_seconds" => declaration.fetch("guardian_poll_seconds"),
        "orchestrator_heartbeat_timeout_seconds" => declaration.fetch(
          "orchestrator_heartbeat_timeout_seconds"
        ),
        "teardown_reserve_seconds" => declaration.fetch("teardown_reserve_seconds")
      }
    end

    def mutation_authority_locked!(expected_binding_sha256:, additional_workers:,
                                   additional_hourly_rate_usd:, profile_id: nil)
      verify_expected_binding!(expected_binding_sha256)

      binding = load_state!
      unless binding.fetch("phase") == "ARMED"
        raise Error, "campaign budget is #{binding.fetch('phase')}; positive mutations are blocked"
      end
      workers = nonnegative_integer!(additional_workers, "additional workers")
      rate = nonnegative_float!(additional_hourly_rate_usd, "additional hourly rate")
      ledger = @parent_budget.assert_positive_mutation_ready!
      verify_ledger!(ledger)
      verify_original_times!(binding, ledger)
      guardian = guardian_status
      ensure_guardian_healthy!(guardian)
      authority = authority_snapshot(ledger, guardian:)
      unless authority.fetch("violations").empty?
        raise Error, "campaign authority is exceeded: #{authority.fetch('violations').join(', ')}"
      end

      projected_workers = authority.fetch("committed_workers") + workers
      projected_rate = authority.fetch("committed_hourly_rate_usd") + rate
      if projected_workers > declaration.fetch("max_workers")
        raise Error, "capacity mutation would exceed campaign worker ceiling"
      end
      if projected_rate > declaration.fetch("max_aggregate_hourly_rate_usd") + 1e-9
        raise Error, "capacity mutation would exceed campaign aggregate hourly ceiling"
      end
      profile = profile_id && profile_definition!(profile_id.to_s)
      if profile
        current_profile_workers = authority.fetch("committed_workers_by_profile").fetch(profile_id.to_s, 0)
        if current_profile_workers + workers > profile.fetch("max_workers")
          raise Error, "capacity mutation would exceed profile #{profile_id.inspect} worker ceiling"
        end
      end

      projected_additional = LocalModelEvaluation::RunpodBudget.maximum_additional_compute_liability_usd(
        hourly_rate_usd: projected_rate,
        limits: ledger.fetch("limits")
      )
      projected_total = ledger.fetch("accrued_compute_usd") + projected_additional
      if projected_total > declaration.fetch("max_cumulative_compute_usd") + 1e-9
        raise Error, "capacity mutation would exceed remaining cumulative authority"
      end

      proof = {
        "contract_version" => MUTATION_AUTHORITY_VERSION,
        "binding_sha256" => binding_sha256,
        "campaign_identity_sha256" => campaign.identity_sha256,
        "budget_id" => declaration.fetch("budget_id"),
        "original_deadline_at_utc" => binding.fetch("deadline_at_utc"),
        "max_cumulative_compute_usd" => declaration.fetch("max_cumulative_compute_usd"),
        "max_aggregate_hourly_rate_usd" => declaration.fetch("max_aggregate_hourly_rate_usd"),
        "max_workers" => declaration.fetch("max_workers"),
        "projected_workers" => projected_workers,
        "projected_hourly_rate_usd" => projected_rate.round(6),
        "projected_maximum_liability_usd" => projected_total.round(6)
      }
      if profile
        proof["profile_id"] = profile_id.to_s
        proof["profile_max_workers"] = profile.fetch("max_workers")
        proof["projected_profile_workers"] =
          authority.fetch("committed_workers_by_profile").fetch(profile_id.to_s, 0) + workers
      end
      deep_freeze(proof)
    end

    def authority_snapshot(ledger, guardian:)
      active = ledger.fetch("owned_resources").values.count { |row| row.fetch("status") == "active" }
      pending = ledger.fetch("reservations").values.count { |row| row.fetch("status") == "pending" }
      workers = active + pending
      by_profile = Hash.new(0)
      ledger.fetch("owned_resources").each_value do |row|
        by_profile[row.fetch("fleet_key")] += 1 if row.fetch("status") == "active"
      end
      ledger.fetch("reservations").each_value do |row|
        by_profile[row.fetch("fleet_key")] += 1 if row.fetch("status") == "pending"
      end
      rate = Float(ledger.fetch("committed_rate_usd_per_hour"))
      horizon = LocalModelEvaluation::RunpodBudget.crash_horizon_seconds(ledger.fetch("limits"))
      additional = LocalModelEvaluation::RunpodBudget.maximum_additional_compute_liability_usd(
        hourly_rate_usd: rate,
        limits: ledger.fetch("limits")
      )
      violations = []
      violations << "worker_ceiling_exceeded" if workers > declaration.fetch("max_workers")
      if rate > declaration.fetch("max_aggregate_hourly_rate_usd") + 1e-9
        violations << "aggregate_hourly_rate_exceeded"
      end
      if Float(ledger.fetch("committed_maximum_liability_usd")) >=
         declaration.fetch("max_cumulative_compute_usd")
        violations << "cumulative_liability_exhausted"
      end
      violations << "parent_budget_not_armed" unless ledger.fetch("state") == "ARMED"
      violations << "parent_budget_mutation_blocked" unless ledger.fetch("mutation_allowed") == true
      violations << "guardian_not_independent_or_fresh" unless guardian.fetch("healthy")

      {
        "max_cumulative_compute_usd" => declaration.fetch("max_cumulative_compute_usd"),
        "max_aggregate_hourly_rate_usd" => declaration.fetch("max_aggregate_hourly_rate_usd"),
        "max_workers" => declaration.fetch("max_workers"),
        "original_deadline_at_utc" => ledger.fetch("deadline_at_utc"),
        "committed_workers" => workers,
        "committed_workers_by_profile" => by_profile.sort.to_h.freeze,
        "committed_hourly_rate_usd" => rate.round(6),
        "accrued_compute_usd" => Float(ledger.fetch("accrued_compute_usd")),
        "crash_liability_horizon_seconds" => horizon,
        "maximum_additional_compute_liability_usd" => additional.round(6),
        "committed_maximum_liability_usd" => Float(ledger.fetch("committed_maximum_liability_usd")),
        "violations" => violations.freeze,
        "mutation_allowed" => violations.empty?
      }.freeze
    end

    def verify_expected_binding!(value)
      expected = digest!(value, "expected binding sha256")
      return true if expected == binding_sha256

      raise Error, "mutation authority belongs to a different campaign budget"
    end

    def profile_definition!(profile_id)
      campaign.profiles.find { |row| row.fetch("profile_id") == profile_id } ||
        raise(Error, "unknown campaign profile_id #{profile_id.inspect}")
    end

    def verify_capacity_reservation!(reservation_id, profile_id:, expected_status:)
      reservation = @parent_budget.status.fetch("reservations").fetch(reservation_id.to_s) do
        raise Error, "unknown campaign reservation #{reservation_id.inspect}"
      end
      unless reservation.fetch("fleet_key") == profile_id.to_s
        raise Error, "campaign reservation belongs to a different profile"
      end
      unless reservation.fetch("status") == expected_status
        raise Error, "campaign reservation is #{reservation.fetch('status').inspect}, not #{expected_status}"
      end
      reservation
    end

    def verify_ledger!(ledger)
      unless ledger.fetch("budget_id") == declaration.fetch("budget_id") &&
             ledger.fetch("plan_sha256").to_s.downcase == binding_sha256
        raise Error, "parent budget identity does not match campaign binding"
      end
      @parent_budget.verify_limits!(parent_budget_request)
      true
    end

    def verify_original_times!(binding, ledger)
      unless binding.fetch("armed_at_utc") == ledger.fetch("armed_at_utc") &&
             binding.fetch("deadline_at_utc") == ledger.fetch("deadline_at_utc")
        raise Error, "parent budget original arm time or deadline changed"
      end
      armed = parse_time(ledger.fetch("armed_at_utc"), "parent armed_at_utc")
      deadline = parse_time(ledger.fetch("deadline_at_utc"), "parent deadline_at_utc")
      expected = armed + declaration.fetch("max_runtime_seconds")
      raise Error, "parent budget original deadline does not match maximum runtime" if (deadline - expected).abs > 0.001
      true
    end

    def guardian_status
      status = @guardian_supervisor.status(budget: @parent_budget)
      errors = []
      errors << "not enabled" unless status["enabled"] == true
      errors << "not loaded" unless status["launchd_loaded"] == true
      errors << "not ready" unless status["ready"] == true
      pid = Integer(status["pid"])
      errors << "not independent" unless pid.positive? && pid != Process.pid
      identity_matches = status["budget_id"] == declaration.fetch("budget_id") &&
                         status["plan_sha256"].to_s.downcase == binding_sha256
      errors << "budget/campaign identity mismatch" unless identity_matches
      heartbeat = parse_time(status.fetch("ledger_heartbeat_at_utc"), "guardian ledger heartbeat")
      now = utc_now
      errors << "future heartbeat" if heartbeat > now
      age = [now - heartbeat, 0.0].max
      errors << "stale heartbeat" if age > 2 * declaration.fetch("guardian_poll_seconds")
      errors << "guardian is not enforcing ARMED state" unless status["state"] == "ARMED"
      status.merge(
        "healthy" => errors.empty?,
        "identity_matches" => identity_matches,
        "health_errors" => errors,
        "ledger_heartbeat_age_seconds" => age.round(6)
      )
    rescue KeyError, ArgumentError, TypeError => e
      raise Error, "guardian status is incomplete or invalid: #{e.message}"
    end

    def ensure_guardian_healthy!(guardian)
      return true if guardian.fetch("healthy")
      raise Error, "guardian is not independently loaded and fresh: #{guardian.fetch('health_errors').join(', ')}"
    end

    def safe_parent_status
      @parent_budget.status
    rescue LocalModelEvaluation::RunpodBudget::Error => e
      { "unavailable" => true, "error" => e.message }
    end

    def safe_guardian_status
      guardian_status
    rescue Error, LocalModelEvaluation::RunpodBudgetGuardianSupervisor::Error => e
      { "healthy" => false, "error" => e.message }
    end

    def enforcement_evidence(guardian)
      {
        "mechanism" => "per-user macOS launchd KeepAlive(PathState) rpof-budget-guardian",
        "guardian_healthy_and_armed" => guardian.fetch("healthy") && guardian.fetch("state") == "ARMED",
        "guardian_identity_matches" => guardian.fetch("identity_matches"),
        "guardian_pid" => guardian.fetch("pid"),
        "launchd_label" => guardian["launchd_label"],
        "survives" => {
          "initiating_cli_exit" => true,
          "wlo_exit" => true,
          "initiating_agent_exit" => true,
          "shell_or_terminal_exit" => true,
          "guardian_process_restart_via_launchd_when_user_service_available" => true
        },
        "does_not_guarantee" => {
          "guardian_restart_within_modeled_crash_horizon" => true,
          "launchd_or_user_service_unavailable" => true,
          "host_power_loss_or_reboot_before_service_restoration" => true,
          "host_sleep" => true,
          "host_network_loss" => true,
          "provider_api_unavailability" => true,
          "provider_delete_failure_or_unverifiable_absence" => true
        },
        "statement" => "The compute-liability bound survives loss of the initiating CLI, WLO, " \
                       "agent, shell, and terminal while the healthy guardian continues. Launchd is " \
                       "configured to restart the guardian, but restart latency is not bounded by the " \
                       "modeled crash horizon. Teardown requires an awake networked host, a reachable " \
                       "RunPod API, successful deletion, and verifiable provider absence."
      }
    end

    def billing_scope_evidence
      {
        "label" => "runpod_pod_compute_only",
        "bounded" => [
          "RunPod pod compute represented by catalog/observed pod hourly cost and the campaign ledger"
        ],
        "not_proven_bounded" => [
          "container or persistent-disk storage charges",
          "pre-existing network or Global Volume charges",
          "snapshot or retained-storage charges",
          "network or egress charges",
          "provider billing granularity, taxes, credits, and other provider charges"
        ],
        "requested_resources" => {
          "pod_compute" => {
            "created_or_retained_by_rpof" => true,
            "hourly_admission" => true,
            "cumulative_liability" => true,
            "guardian_teardown_owned" => true,
            "provider_absence_verifiable" => true
          },
          "container_disk" => {
            "created_with_pod" => true,
            "separately_priced_in_ledger" => false,
            "destroyed_with_pod_assumed_but_not_separately_verified" => true
          },
          "global_volume" => {
            "pre_existing_and_attached_only" => true,
            "created_by_campaign" => false,
            "priced_in_ledger" => false,
            "guardian_teardown_owned" => false,
            "provider_absence_verifiable_by_campaign" => false
          }
        },
        "charges_may_continue_outside_cap" => true
      }
    end

    def absolute_refusal_conditions
      %w[
        invalid_or_nonfinite_bound binding_not_armed ambiguous_durable_authority
        budget_or_campaign_identity_mismatch worker_ceiling_exceeded
        aggregate_hourly_rate_exceeded cumulative_liability_exhausted
        parent_budget_not_armed parent_budget_mutation_blocked
        guardian_not_independent_or_fresh guardian_identity_mismatch
        original_deadline_expired projected_workers_below_committed
        projected_worker_ceiling_exceeded projected_hourly_rate_unavailable
        projected_rate_below_committed projected_hourly_rate_ceiling_exceeded
        projected_cumulative_compute_authority_exceeded
      ]
    end

    def retain_arm_error(message, initial:)
      return unless File.file?(@state_path)
      with_lock do
        document = load_state!
        document["last_error"] = {
          "at_utc" => utc_now.iso8601,
          "operation" => initial ? "arm" : "resume",
          "message" => message.to_s
        }
        persist!(document)
      end
    rescue Error, SystemCallError
      nil
    end

    def load_state!
      raise Error, "campaign budget binding is missing" unless File.file?(@state_path)
      document = JSON.parse(File.read(@state_path))
      exact_keys!(document, STATE_KEYS, "campaign budget state")
      unless document.fetch("contract_version") == STATE_CONTRACT_VERSION
        raise Error, "campaign budget state has unsupported contract version"
      end
      unless PHASES.include?(document.fetch("phase"))
        raise Error, "campaign budget state phase is invalid"
      end
      unless document.fetch("binding_sha256") == binding_sha256 && document.fetch("binding") == declaration
        raise Error, "durable campaign budget binding does not match requested campaign, qualification, or limits"
      end
      document
    rescue JSON::ParserError, SystemCallError => e
      raise Error, "campaign budget binding is unreadable: #{e.message}"
    end

    def binding_snapshot(document)
      Marshal.load(Marshal.dump(document))
    end

    def with_read_lock
      File.open(@lock_path, File::RDONLY) do |lock|
        lock.flock(File::LOCK_SH)
        yield
      ensure
        lock.flock(File::LOCK_UN) rescue nil
      end
    rescue SystemCallError => e
      raise Error, "retained authority is unavailable: #{e.message}"
    end

    def with_lock
      FileUtils.mkdir_p(@binding_dir)
      File.open(@lock_path, File::RDWR | File::CREAT, 0o600) do |lock|
        lock.flock(File::LOCK_EX)
        yield
      ensure
        lock.flock(File::LOCK_UN) rescue nil
      end
    end

    def persist!(document)
      write_json_atomic(@state_path, document)
    end

    def write_json_atomic(path, document)
      FileUtils.mkdir_p(File.dirname(path))
      tmp = "#{path}.tmp.#{$$}.#{Thread.current.object_id}"
      File.write(tmp, JSON.pretty_generate(document) + "\n")
      File.chmod(0o600, tmp)
      File.rename(tmp, path)
    ensure
      File.delete(tmp) if defined?(tmp) && tmp && File.exist?(tmp)
    end

    def exact_keys!(value, required, label)
      raise Error, "#{label} must be an object" unless value.is_a?(Hash)
      keys = value.keys.map(&:to_s)
      missing = required - keys
      unknown = keys - required
      raise Error, "#{label} missing required field(s): #{missing.join(', ')}" unless missing.empty?
      raise Error, "#{label} unknown field(s): #{unknown.sort.join(', ')}" unless unknown.empty?
    end

    def digest!(value, label)
      unless value.is_a?(String)
        raise Error, "#{label} must be a full SHA-256 digest"
      end
      text = value.downcase
      raise Error, "#{label} must be a full SHA-256 digest" unless text.match?(DIGEST)
      text
    end

    def nonempty_string!(value, label)
      unless value.is_a?(String)
        raise Error, "#{label} must be a non-empty trimmed string without control characters"
      end
      text = value
      unless !text.empty? && text == text.strip && !text.include?("\0") && !text.match?(/[[:cntrl:]]/)
        raise Error, "#{label} must be a non-empty trimmed string without control characters"
      end
      raise Error, "#{label} exceeds 256 characters" if text.length > 256
      text
    end

    def positive_integer!(value, label)
      return value if value.is_a?(Integer) && value.positive?
      raise Error, "#{label} must be a positive integer"
    end

    def nonnegative_integer!(value, label)
      return value if value.is_a?(Integer) && !value.negative?
      raise Error, "#{label} must be a non-negative integer"
    end

    def positive_float!(value, label)
      number = value.to_f if value.is_a?(Numeric)
      raise Error, "#{label} must be positive and finite" unless number.positive? && number.finite?
      number
    rescue NoMethodError
      raise Error, "#{label} must be positive and finite"
    end

    def nonnegative_float!(value, label)
      number = value.to_f if value.is_a?(Numeric)
      raise Error, "#{label} must be non-negative and finite" unless !number.negative? && number.finite?
      number
    rescue NoMethodError
      raise Error, "#{label} must be non-negative and finite"
    end

    def optional_nonnegative_float!(value, label)
      return nil if value.nil?
      nonnegative_float!(value, label)
    end

    def parse_time(value, label)
      time = value.is_a?(Time) ? value : Time.parse(value.to_s)
      time.utc
    rescue ArgumentError
      raise Error, "#{label} is invalid"
    end

    def utc_now
      value = @wall_clock.call
      value = Time.parse(value.to_s) unless value.is_a?(Time)
      value.utc
    rescue ArgumentError
      raise Error, "campaign budget clock returned invalid time"
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
