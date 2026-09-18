# frozen_string_literal: true

require "digest"
require "fileutils"
require "json"
require "securerandom"
require "time"

module LocalModelEvaluation
  # Authoritative parent-budget ledger for automated RunPod production bursts.
  #
  # This class owns accounting, reservation and mutation-authorization semantics.
  # It intentionally does not spawn or supervise the independent guardian; that
  # lifecycle belongs to the guardian integration layer. The guardian records its
  # heartbeat here and calls evaluate! on its own cadence.
  class RunpodBudget
    CONTRACT_VERSION = "afio-production-burst-budget/v0.1"
    STATE_CONTRACT_VERSION = "rpof-production-burst-budget-state/v0.1"
    STATES = %w[ARMED TEARDOWN_REQUIRED CLOSED].freeze
    SOURCES = %w[guardian orchestrator].freeze
    DIGEST = /\A[0-9a-f]{64}\z/i

    class Error < StandardError; end

    def initialize(root:, budget_id:, plan_sha256:, wall_clock: nil)
      @root = File.expand_path(root)
      @budget_id = nonempty_string(budget_id, "budget id")
      @plan_sha256 = plan_sha256.to_s.downcase
      raise Error, "plan sha256 must be 64 hex characters" unless @plan_sha256.match?(DIGEST)

      identity = Digest::SHA256.hexdigest("#{@budget_id}\0#{@plan_sha256}")
      @budget_dir = File.join(@root, "budgets", identity)
      @state_path = File.join(@budget_dir, "budget.json")
      @lock_path = File.join(@budget_dir, ".lock")
      @wall_clock = wall_clock || -> { Time.now.utc }
    end

    attr_reader :budget_id, :plan_sha256, :state_path

    def arm!(budget:, guardian_heartbeat_at_utc:)
      normalized = normalize_budget(budget)
      guardian_at = parse_time(guardian_heartbeat_at_utc, "guardian heartbeat")
      now = utc_now
      raise Error, "guardian heartbeat cannot be in the future" if guardian_at > now
      ensure_guardian_fresh!(normalized, guardian_at, now)

      with_lock do
        if File.file?(@state_path)
          document = load_state!
          verify_immutable_budget!(document, normalized)
          raise Error, "closed budget cannot be reopened" if document.fetch("state") == "CLOSED"
          if document.fetch("state") == "TEARDOWN_REQUIRED"
            raise Error, "budget requires teardown and cannot be re-armed"
          end

          document["last_guardian_heartbeat_at_utc"] = later_time(
            document["last_guardian_heartbeat_at_utc"], guardian_at
          ).iso8601
          document["last_orchestrator_heartbeat_at_utc"] = now.iso8601
          persist!(document, now:)
          return snapshot(document, now:)
        end

        document = {
          "contract_version" => STATE_CONTRACT_VERSION,
          "budget_id" => @budget_id,
          "plan_sha256" => @plan_sha256,
          "state" => "ARMED",
          "armed_at_utc" => now.iso8601,
          "deadline_at_utc" => (now + normalized.fetch("max_runtime_seconds")).iso8601,
          "last_orchestrator_heartbeat_at_utc" => now.iso8601,
          "last_guardian_heartbeat_at_utc" => guardian_at.iso8601,
          "limits" => normalized,
          "accrued_compute_usd" => 0.0,
          "committed_rate_usd_per_hour" => 0.0,
          "committed_maximum_liability_usd" => 0.0,
          "reservations" => {},
          "owned_resources" => {},
          "teardown_reason" => nil,
          "teardown_required_at_utc" => nil,
          "closed_at_utc" => nil
        }
        persist!(document, now:)
        snapshot(document, now:)
      end
    end

    def verify_limits!(budget)
      normalized = normalize_budget(budget)
      with_lock do
        document = load_state!
        verify_immutable_budget!(document, normalized)
        true
      end
    end

    def heartbeat!(source:)
      source = source.to_s
      raise Error, "heartbeat source must be guardian or orchestrator" unless SOURCES.include?(source)

      with_lock do
        document = load_state!
        raise Error, "closed budget does not accept heartbeats" if document.fetch("state") == "CLOSED"
        now = utc_now
        document["last_#{source}_heartbeat_at_utc"] = now.iso8601
        persist!(document, now:)
        snapshot(document, now:)
      end
    end

    # Evaluate time/heartbeat/liability conditions and transition ARMED budgets
    # to TEARDOWN_REQUIRED when a hard stop condition has become true.
    def evaluate!
      with_lock do
        document = load_state!
        now = utc_now
        evaluate_document!(document, now:)
        persist!(document, now:)
        snapshot(document, now:)
      end
    end

    def status
      with_lock do
        document = load_state!
        snapshot(document, now: utc_now)
      end
    end

    def assert_positive_mutation_ready!
      with_lock do
        document = load_state!
        now = utc_now
        evaluate_document!(document, now:)
        persist!(document, now:)
        assert_mutation_ready!(document, now:)
        snapshot(document, now:)
      end
    end

    def reserve_mutation!(operation_type:, fleet_key:, logical_resource_id:, max_hourly_rate_delta_usd:,
                          reservation_id: nil)
      operation = nonempty_string(operation_type, "operation type")
      fleet = nonempty_string(fleet_key, "fleet key")
      logical = nonempty_string(logical_resource_id, "logical resource id")
      rate = positive_float(max_hourly_rate_delta_usd, "maximum reserved hourly-rate delta")
      reservation_id ||= SecureRandom.uuid
      reservation_id = nonempty_string(reservation_id, "reservation id")

      with_lock do
        document = load_state!
        now = utc_now
        evaluate_document!(document, now:)
        assert_mutation_ready!(document, now:)
        if document.fetch("reservations").key?(reservation_id)
          raise Error, "reservation #{reservation_id.inspect} already exists"
        end
        duplicate_pending = document.fetch("reservations").values.find do |row|
          row.fetch("status") == "pending" && row.fetch("fleet_key") == fleet &&
            row.fetch("logical_resource_id") == logical
        end
        if duplicate_pending
          raise Error,
                "pending reservation #{duplicate_pending.fetch('reservation_id').inspect} already owns #{fleet}/#{logical}"
        end
        unless operation == "replace"
          duplicate_active = document.fetch("owned_resources").values.find do |row|
            row.fetch("status") == "active" && row.fetch("fleet_key") == fleet &&
              row.fetch("logical_resource_id") == logical
          end
          raise Error, "active budget-owned resource already occupies #{fleet}/#{logical}" if duplicate_active
        end

        reservation = {
          "reservation_id" => reservation_id,
          "status" => "pending",
          "operation_type" => operation,
          "fleet_key" => fleet,
          "logical_resource_id" => logical,
          "max_hourly_rate_delta_usd" => rate,
          "created_at_utc" => now.iso8601,
          "committed_at_utc" => nil,
          "released_at_utc" => nil,
          "release_reason" => nil,
          "released_accrued_compute_usd" => 0.0,
          "provider_resource_id" => nil,
          "actual_hourly_rate_usd" => nil
        }
        document.fetch("reservations")[reservation_id] = reservation
        derived = derived_values(document, now:)
        limit = Float(document.dig("limits", "max_cumulative_compute_usd"))
        if derived.fetch("committed_maximum_liability_usd") > limit
          document.fetch("reservations").delete(reservation_id)
          raise Error, format(
            "budget reservation would exceed cumulative cap: committed liability $%.6f > $%.6f",
            derived.fetch("committed_maximum_liability_usd"),
            limit
          )
        end

        persist!(document, now:)
        Marshal.load(Marshal.dump(reservation))
      end
    end

    def commit_mutation!(reservation_id:, provider_resource_id:, actual_hourly_rate_usd:, started_at_utc: nil)
      reservation_id = nonempty_string(reservation_id, "reservation id")
      provider_resource_id = nonempty_string(provider_resource_id, "provider resource id")
      actual_rate = positive_float(actual_hourly_rate_usd, "actual hourly rate")

      with_lock do
        document = load_state!
        now = utc_now
        reservation = document.fetch("reservations").fetch(reservation_id) do
          raise Error, "unknown reservation #{reservation_id.inspect}"
        end
        unless reservation.fetch("status") == "pending"
          raise Error, "reservation #{reservation_id.inspect} is #{reservation.fetch('status').inspect}, not pending"
        end
        if document.fetch("owned_resources").key?(provider_resource_id)
          raise Error, "provider resource #{provider_resource_id.inspect} is already budget-owned"
        end

        started_at = started_at_utc ? parse_time(started_at_utc, "provider lifecycle start") :
                     parse_time(reservation.fetch("created_at_utc"), "reservation created_at_utc")
        resource = {
          "provider_resource_id" => provider_resource_id,
          "reservation_id" => reservation_id,
          "fleet_key" => reservation.fetch("fleet_key"),
          "logical_resource_id" => reservation.fetch("logical_resource_id"),
          "operation_type" => reservation.fetch("operation_type"),
          "hourly_rate_usd" => actual_rate,
          "started_at_utc" => started_at.iso8601,
          "stopped_at_utc" => nil,
          "status" => "active"
        }
        document.fetch("owned_resources")[provider_resource_id] = resource
        reservation["status"] = "committed"
        reservation["committed_at_utc"] = now.iso8601
        reservation["provider_resource_id"] = provider_resource_id
        reservation["actual_hourly_rate_usd"] = actual_rate

        reserved_rate = Float(reservation.fetch("max_hourly_rate_delta_usd"))
        if actual_rate > reserved_rate + 1e-9
          transition_to_teardown!(document, "provider_rate_exceeded_reservation", now:)
          persist!(document, now:)
          raise Error, format(
            "actual provider rate $%.6f/hr exceeds reserved maximum $%.6f/hr; budget requires teardown",
            actual_rate,
            reserved_rate
          )
        end

        persist!(document, now:)
        Marshal.load(Marshal.dump(resource))
      end
    end

    def release_reservation!(reservation_id:, reason:, mutation_not_attempted: false,
                             provider_absence_verified: false)
      reservation_id = nonempty_string(reservation_id, "reservation id")
      reason = nonempty_string(reason, "release reason")
      unless mutation_not_attempted || provider_absence_verified
        raise Error, "reservation release requires proof that no paid provider resource remains"
      end

      with_lock do
        document = load_state!
        reservation = document.fetch("reservations").fetch(reservation_id) do
          raise Error, "unknown reservation #{reservation_id.inspect}"
        end
        unless reservation.fetch("status") == "pending"
          raise Error, "only pending reservations may be released"
        end

        now = utc_now
        released_accrued = if provider_absence_verified && !mutation_not_attempted
                             started = parse_time(reservation.fetch("created_at_utc"), "reservation created_at_utc")
                             Float(reservation.fetch("max_hourly_rate_delta_usd")) * [now - started, 0.0].max / 3600.0
                           else
                             0.0
                           end
        reservation["status"] = "released"
        reservation["released_at_utc"] = now.iso8601
        reservation["release_reason"] = reason
        reservation["released_accrued_compute_usd"] = released_accrued
        persist!(document, now:)
        Marshal.load(Marshal.dump(reservation))
      end
    end

    def mark_resource_absent!(provider_resource_id:, verified_absent:, stopped_at_utc: nil)
      raise Error, "provider absence must be independently verified before releasing resource liability" unless verified_absent == true
      provider_resource_id = nonempty_string(provider_resource_id, "provider resource id")

      with_lock do
        document = load_state!
        resource = document.fetch("owned_resources").fetch(provider_resource_id) do
          raise Error, "unknown provider resource #{provider_resource_id.inspect}"
        end
        return Marshal.load(Marshal.dump(resource)) if resource.fetch("status") == "absent"

        stopped = stopped_at_utc ? parse_time(stopped_at_utc, "provider stop time") : utc_now
        started = parse_time(resource.fetch("started_at_utc"), "provider start time")
        raise Error, "provider stop time predates provider start time" if stopped < started

        resource["status"] = "absent"
        resource["stopped_at_utc"] = stopped.iso8601
        persist!(document, now: utc_now)
        Marshal.load(Marshal.dump(resource))
      end
    end

    def begin_teardown!(reason:)
      reason = nonempty_string(reason, "teardown reason")
      with_lock do
        document = load_state!
        now = utc_now
        transition_to_teardown!(document, reason, now:) unless document.fetch("state") == "CLOSED"
        persist!(document, now:)
        snapshot(document, now:)
      end
    end

    def close!
      with_lock do
        document = load_state!
        now = utc_now
        active = document.fetch("owned_resources").values.select { |row| row.fetch("status") == "active" }
        pending = document.fetch("reservations").values.select { |row| row.fetch("status") == "pending" }
        raise Error, "cannot close budget while #{active.length} provider resource(s) remain active" unless active.empty?
        raise Error, "cannot close budget while #{pending.length} mutation reservation(s) remain pending" unless pending.empty?

        document["state"] = "CLOSED"
        document["closed_at_utc"] ||= now.iso8601
        persist!(document, now:)
        snapshot(document, now:)
      end
    end

    private

    def normalize_budget(value)
      budget = value.respond_to?(:transform_keys) ? value.transform_keys(&:to_s) : nil
      raise Error, "budget must be an object" unless budget.is_a?(Hash)

      required = %w[
        contract_version budget_id plan_sha256 max_cumulative_compute_usd
        max_runtime_seconds guardian_poll_seconds
        orchestrator_heartbeat_timeout_seconds teardown_reserve_seconds
      ]
      missing = required.reject { |key| budget.key?(key) }
      raise Error, "budget is missing required field(s): #{missing.join(', ')}" unless missing.empty?
      unknown = budget.keys - required
      raise Error, "budget has unknown field(s): #{unknown.sort.join(', ')}" unless unknown.empty?
      unless budget.fetch("contract_version") == CONTRACT_VERSION
        raise Error, "unsupported budget contract_version #{budget.fetch('contract_version').inspect}"
      end
      unless budget.fetch("budget_id").to_s == @budget_id
        raise Error, "budget id does not match budget ledger identity"
      end
      unless budget.fetch("plan_sha256").to_s.downcase == @plan_sha256
        raise Error, "budget plan sha256 does not match budget ledger identity"
      end

      normalized = {
        "contract_version" => CONTRACT_VERSION,
        "budget_id" => @budget_id,
        "plan_sha256" => @plan_sha256,
        "max_cumulative_compute_usd" => positive_float(budget.fetch("max_cumulative_compute_usd"), "maximum cumulative compute cost"),
        "max_runtime_seconds" => positive_float(budget.fetch("max_runtime_seconds"), "maximum runtime"),
        "guardian_poll_seconds" => positive_float(budget.fetch("guardian_poll_seconds"), "guardian poll interval"),
        "orchestrator_heartbeat_timeout_seconds" => positive_float(
          budget.fetch("orchestrator_heartbeat_timeout_seconds"),
          "orchestrator heartbeat timeout"
        ),
        "teardown_reserve_seconds" => positive_float(budget.fetch("teardown_reserve_seconds"), "teardown reserve")
      }
      if normalized.fetch("orchestrator_heartbeat_timeout_seconds") < 2 * normalized.fetch("guardian_poll_seconds")
        raise Error, "orchestrator heartbeat timeout must be at least twice the guardian poll interval"
      end
      normalized
    end

    def verify_immutable_budget!(document, normalized)
      unless document.fetch("contract_version") == STATE_CONTRACT_VERSION &&
             document.fetch("budget_id") == @budget_id &&
             document.fetch("plan_sha256").to_s.downcase == @plan_sha256
        raise Error, "budget ledger identity does not match requested budget"
      end
      persisted = document.fetch("limits")
      unless persisted == normalized
        raise Error, "budget immutable limits do not match the armed budget"
      end
      true
    end

    def evaluate_document!(document, now:)
      return document unless document.fetch("state") == "ARMED"

      reason = if now >= parse_time(document.fetch("deadline_at_utc"), "budget deadline")
                 "runtime_expired"
               elsif heartbeat_age(document, "orchestrator", now:) > Float(document.dig("limits", "orchestrator_heartbeat_timeout_seconds"))
                 "stale_orchestrator_heartbeat"
               elsif heartbeat_age(document, "guardian", now:) > 2 * Float(document.dig("limits", "guardian_poll_seconds"))
                 "stale_guardian_heartbeat"
               else
                 derived = derived_values(document, now:)
                 limit = Float(document.dig("limits", "max_cumulative_compute_usd"))
                 "cumulative_budget_threshold" if derived.fetch("committed_maximum_liability_usd") >= limit
               end
      transition_to_teardown!(document, reason, now:) if reason
      document
    end

    def assert_mutation_ready!(document, now:)
      unless document.fetch("state") == "ARMED"
        raise Error, "budget is #{document.fetch('state')}; positive paid mutations are blocked"
      end
      guardian_age = heartbeat_age(document, "guardian", now:)
      guardian_limit = 2 * Float(document.dig("limits", "guardian_poll_seconds"))
      raise Error, "guardian heartbeat is stale; positive paid mutations are blocked" if guardian_age > guardian_limit

      orchestrator_age = heartbeat_age(document, "orchestrator", now:)
      orchestrator_limit = Float(document.dig("limits", "orchestrator_heartbeat_timeout_seconds"))
      raise Error, "orchestrator heartbeat is stale; positive paid mutations are blocked" if orchestrator_age > orchestrator_limit
      if now >= parse_time(document.fetch("deadline_at_utc"), "budget deadline")
        raise Error, "budget runtime deadline has expired; positive paid mutations are blocked"
      end

      true
    end

    def transition_to_teardown!(document, reason, now:)
      return if document.fetch("state") == "CLOSED"
      document["state"] = "TEARDOWN_REQUIRED"
      document["teardown_reason"] ||= reason
      document["teardown_required_at_utc"] ||= now.iso8601
    end

    def persist!(document, now:)
      update_derived!(document, now:)
      write_json_atomic(@state_path, document)
      document
    end

    def snapshot(document, now:)
      copy = Marshal.load(Marshal.dump(document))
      update_derived!(copy, now:)
      limits = copy.fetch("limits")
      copy["remaining_uncommitted_budget_usd"] = [
        Float(limits.fetch("max_cumulative_compute_usd")) - Float(copy.fetch("committed_maximum_liability_usd")),
        0.0
      ].max.round(6)
      copy["orchestrator_heartbeat_age_seconds"] = heartbeat_age(copy, "orchestrator", now:).round(6)
      copy["guardian_heartbeat_age_seconds"] = heartbeat_age(copy, "guardian", now:).round(6)
      copy["mutation_allowed"] = copy.fetch("state") == "ARMED" &&
                                   copy.fetch("orchestrator_heartbeat_age_seconds") <= Float(limits.fetch("orchestrator_heartbeat_timeout_seconds")) &&
                                   copy.fetch("guardian_heartbeat_age_seconds") <= 2 * Float(limits.fetch("guardian_poll_seconds")) &&
                                   now < parse_time(copy.fetch("deadline_at_utc"), "budget deadline") &&
                                   Float(copy.fetch("committed_maximum_liability_usd")) < Float(limits.fetch("max_cumulative_compute_usd"))
      copy
    end

    def update_derived!(document, now:)
      values = derived_values(document, now:)
      document["accrued_compute_usd"] = values.fetch("accrued_compute_usd").round(6)
      document["committed_rate_usd_per_hour"] = values.fetch("committed_rate_usd_per_hour").round(6)
      document["committed_maximum_liability_usd"] = values.fetch("committed_maximum_liability_usd").round(6)
    end

    def derived_values(document, now:)
      resources = document.fetch("owned_resources").values
      accrued = resources.sum do |resource|
        started = parse_time(resource.fetch("started_at_utc"), "provider start time")
        stopped = resource["stopped_at_utc"] ? parse_time(resource.fetch("stopped_at_utc"), "provider stop time") : now
        elapsed = [stopped - started, 0.0].max
        Float(resource.fetch("hourly_rate_usd")) * elapsed / 3600.0
      end
      reservations = document.fetch("reservations").values
      accrued += reservations.sum do |reservation|
        reservation.fetch("status") == "released" ? Float(reservation.fetch("released_accrued_compute_usd", 0.0)) : 0.0
      end
      pending_reservations = reservations.select do |reservation|
        reservation.fetch("status") == "pending"
      end
      # A reservation becomes durable immediately before the provider mutation.
      # Until it is committed or safely released, conservatively accrue it at
      # the full reserved rate from reservation time. This closes the crash gap
      # where a pod may exist but provider identity has not yet been committed.
      accrued += pending_reservations.sum do |reservation|
        started = parse_time(reservation.fetch("created_at_utc"), "reservation created_at_utc")
        Float(reservation.fetch("max_hourly_rate_delta_usd")) * [now - started, 0.0].max / 3600.0
      end
      active_rate = resources.sum do |resource|
        resource.fetch("status") == "active" ? Float(resource.fetch("hourly_rate_usd")) : 0.0
      end
      pending_rate = pending_reservations.sum { |reservation| Float(reservation.fetch("max_hourly_rate_delta_usd")) }
      committed_rate = active_rate + pending_rate
      limits = document.fetch("limits")
      horizon = Float(limits.fetch("guardian_poll_seconds")) +
                Float(limits.fetch("orchestrator_heartbeat_timeout_seconds")) +
                Float(limits.fetch("teardown_reserve_seconds"))
      reserve = committed_rate * horizon / 3600.0
      {
        "accrued_compute_usd" => accrued,
        "committed_rate_usd_per_hour" => committed_rate,
        "committed_maximum_liability_usd" => accrued + reserve
      }
    rescue KeyError, ArgumentError, TypeError => e
      raise Error, "invalid budget accounting state: #{e.message}"
    end

    def heartbeat_age(document, source, now:)
      value = document.fetch("last_#{source}_heartbeat_at_utc")
      [now - parse_time(value, "#{source} heartbeat"), 0.0].max
    end

    def ensure_guardian_fresh!(budget, guardian_at, now)
      age = [now - guardian_at, 0.0].max
      max_age = 2 * Float(budget.fetch("guardian_poll_seconds"))
      raise Error, "guardian heartbeat is stale; budget cannot be armed" if age > max_age
    end

    def later_time(existing, candidate)
      return candidate unless existing
      [parse_time(existing, "existing heartbeat"), candidate].max
    end

    def load_state!
      raise Error, "budget is not armed: #{@budget_id}" unless File.file?(@state_path)
      document = JSON.parse(File.read(@state_path))
      unless document.is_a?(Hash) && document["contract_version"] == STATE_CONTRACT_VERSION
        raise Error, "budget state has unsupported contract version"
      end
      unless STATES.include?(document["state"].to_s)
        raise Error, "budget state is invalid: #{document['state'].inspect}"
      end
      unless document["budget_id"].to_s == @budget_id && document["plan_sha256"].to_s.downcase == @plan_sha256
        raise Error, "budget state identity mismatch"
      end
      document
    rescue JSON::ParserError, SystemCallError => e
      raise Error, "budget state is unreadable: #{e.message}"
    end

    def with_lock
      FileUtils.mkdir_p(@budget_dir)
      File.open(@lock_path, File::RDWR | File::CREAT, 0o600) do |lock|
        lock.flock(File::LOCK_EX)
        yield
      ensure
        lock.flock(File::LOCK_UN) rescue nil
      end
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

    def nonempty_string(value, label)
      text = value.to_s.strip
      raise Error, "#{label} cannot be empty" if text.empty? || text.include?("\0")
      text
    end

    def positive_float(value, label)
      number = Float(value)
      raise Error, "#{label} must be positive and finite" unless number.positive? && number.finite?
      number
    rescue ArgumentError, TypeError
      raise Error, "#{label} must be positive and finite"
    end

    def parse_time(value, label)
      time = value.is_a?(Time) ? value : Time.parse(value.to_s)
      time.utc
    rescue ArgumentError
      raise Error, "#{label} is invalid: #{value.inspect}"
    end

    def utc_now
      value = @wall_clock.call
      value = Time.parse(value.to_s) unless value.is_a?(Time)
      value.utc
    rescue ArgumentError
      raise Error, "budget clock returned invalid time"
    end
  end
end
