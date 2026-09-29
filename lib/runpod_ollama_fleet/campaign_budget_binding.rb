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
                :state_path, :parent_budget

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
      binding = with_lock { binding_snapshot(load_state!) }
      ledger = safe_parent_status
      guardian = safe_guardian_status
      binding.merge(
        "parent_budget" => ledger,
        "guardian" => guardian,
        "guardian_healthy" => guardian.fetch("healthy", false)
      )
    end

    def status
      binding = with_lock { binding_snapshot(load_state!) }
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

    # Produces an immutable proof that a proposed capacity mutation is within
    # the parent authority. DW-06 will wire this seam into live admission.
    def mutation_authority!(expected_binding_sha256:, additional_workers:,
                            additional_hourly_rate_usd:)
      with_lock do
        mutation_authority_locked!(
          expected_binding_sha256:,
          additional_workers:,
          additional_hourly_rate_usd:
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
      unless campaign.profiles.any? { |row| row.fetch("profile_id") == profile }
        raise Error, "unknown campaign profile_id #{profile_id.inspect}"
      end

      with_lock do
        proof = mutation_authority_locked!(
          expected_binding_sha256:,
          additional_workers:,
          additional_hourly_rate_usd: max_hourly_rate_delta_usd
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

    private

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
                                   additional_hourly_rate_usd:)
      expected = digest!(expected_binding_sha256, "expected binding sha256")
      raise Error, "mutation authority belongs to a different campaign budget" unless expected == binding_sha256

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

      projected_additional = projected_rate * authority.fetch("crash_liability_horizon_seconds") / 3600.0
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
      deep_freeze(proof)
    end

    def authority_snapshot(ledger, guardian:)
      active = ledger.fetch("owned_resources").values.count { |row| row.fetch("status") == "active" }
      pending = ledger.fetch("reservations").values.count { |row| row.fetch("status") == "pending" }
      workers = active + pending
      rate = Float(ledger.fetch("committed_rate_usd_per_hour"))
      horizon = declaration.fetch("guardian_poll_seconds") +
                declaration.fetch("orchestrator_heartbeat_timeout_seconds") +
                declaration.fetch("teardown_reserve_seconds")
      additional = rate * horizon / 3600.0
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
        "committed_hourly_rate_usd" => rate.round(6),
        "accrued_compute_usd" => Float(ledger.fetch("accrued_compute_usd")),
        "crash_liability_horizon_seconds" => horizon,
        "maximum_additional_compute_liability_usd" => additional.round(6),
        "committed_maximum_liability_usd" => Float(ledger.fetch("committed_maximum_liability_usd")),
        "violations" => violations.freeze,
        "mutation_allowed" => violations.empty?
      }.freeze
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
      heartbeat = parse_time(status.fetch("ledger_heartbeat_at_utc"), "guardian ledger heartbeat")
      now = utc_now
      errors << "future heartbeat" if heartbeat > now
      age = [now - heartbeat, 0.0].max
      errors << "stale heartbeat" if age > 2 * declaration.fetch("guardian_poll_seconds")
      errors << "guardian is not enforcing ARMED state" unless status["state"] == "ARMED"
      status.merge(
        "healthy" => errors.empty?,
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
      FileUtils.mkdir_p(File.dirname(@state_path))
      tmp = "#{@state_path}.tmp.#{$$}.#{Thread.current.object_id}"
      File.write(tmp, JSON.pretty_generate(document) + "\n")
      File.chmod(0o600, tmp)
      File.rename(tmp, @state_path)
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
