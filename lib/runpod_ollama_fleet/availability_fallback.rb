# frozen_string_literal: true

require "digest"
require "fileutils"
require "json"
require "time"

module RunpodOllamaFleet
  # Durable, finite candidate progress for one campaign-owned capacity
  # acquisition decision. Candidate authority comes only from the immutable
  # campaign hardware binding and the exact generic capability request.
  class AvailabilityFallback
    CONTRACT_VERSION = "rpof-availability-fallback-state/v0.1"
    STATES = %w[active accepted exhausted blocked].freeze
    ATTEMPT_STATES = %w[not_attempted in_progress provisioned rejected accepted blocked].freeze
    CLEANUP_STATES = %w[not_required verified_absent unresolved].freeze
    AUTHORITY_KEYS = %w[
      campaign_identity_sha256 binding_sha256 budget_id armed_at_utc
      original_deadline_at_utc max_cumulative_compute_usd
      max_aggregate_hourly_rate_usd campaign_max_workers profile_max_workers
    ].freeze
    DECISION_IDENTITY_KEYS = (AUTHORITY_KEYS + %w[
      profile_id capability_fingerprint from_workers target_workers
      authorized_gpu_ids candidate_order candidate_evidence_sha256
    ]).freeze

    class Error < StandardError; end

    def initialize(binding:, profile:, hardware:, capability_request:, wall_clock: nil)
      @binding = binding
      @profile = profile
      @hardware = hardware
      @capability_request = capability_request
      @wall_clock = wall_clock || -> { Time.now.utc }
      @profile_id = profile.fetch("profile_id").to_s
      @root = File.join(File.dirname(binding.state_path), "availability-fallback", @profile_id)
      @lock_path = File.join(@root, ".lock")
      @pointer_path = File.join(@root, "current")
      capability_request.validate_profile!(profile:, hardware:)
    rescue KeyError, ArgumentError, TypeError => e
      raise Error, "invalid availability fallback authority: #{e.message}"
    end

    # Persists the complete ordered candidate set before the first provider
    # mutation. A restart reuses the retained decision byte-for-value rather
    # than reranking live inventory or restarting the series.
    def prepare!(from_workers:, target_workers:, original_deadline_at_utc:, candidates:)
      from = nonnegative_integer!(from_workers, "current worker count")
      target = positive_integer!(target_workers, "target worker count")
      raise Error, "fallback target must exceed current worker count" unless target > from
      deadline = timestamp!(original_deadline_at_utc, "original deadline")
      rows = normalize_candidates(candidates)
      identity = decision_identity(from:, target:, deadline:, candidates: rows)
      decision_sha = Digest::SHA256.hexdigest(JSON.generate(identity))

      with_lock do
        current = load_current
        if current && current.fetch("decision_sha256") == decision_sha
          verify_document!(current)
          return deep_copy(current)
        end
        if current && !%w[accepted exhausted].include?(current.fetch("state"))
          raise Error,
                "prior fallback decision is #{current.fetch('state')} and must be resolved before a new decision"
        end

        document = identity.merge(
          "contract_version" => CONTRACT_VERSION,
          "decision_sha256" => decision_sha,
          "state" => rows.any? { |row| row.fetch("status") == "not_attempted" } ? "active" : "exhausted",
          "current_candidate" => nil,
          "selected_candidate" => nil,
          "stop_reason" => rows.any? { |row| row.fetch("status") == "not_attempted" } ? nil :
            "no authorized candidate was currently eligible",
          "created_at_utc" => timestamp,
          "updated_at_utc" => timestamp,
          "candidates" => rows
        )
        write_document(document)
        write_atomic(@pointer_path, "#{decision_sha}\n")
        deep_copy(document)
      end
    end

    def current
      return nil unless File.file?(@pointer_path)

      with_lock do
        document = load_current
        document && deep_copy(document)
      end
    end

    def next_candidate!
      transition do |document|
        unless document.fetch("state") == "active"
          raise Error, "fallback decision is #{document.fetch('state')}: #{document['stop_reason']}"
        end
        unresolved = document.fetch("candidates").find do |row|
          %w[in_progress provisioned].include?(row.fetch("status"))
        end
        if unresolved
          raise Error,
                "fallback candidate #{unresolved.fetch('gpu_id').inspect} has unresolved " \
                "#{unresolved.fetch('status')} state"
        end

        candidate = document.fetch("candidates").find { |row| row.fetch("status") == "not_attempted" }
        unless candidate
          document["state"] = "exhausted"
          document["stop_reason"] = "authorized candidate set exhausted"
          next nil
        end
        candidate["status"] = "in_progress"
        candidate["attempted_at_utc"] = timestamp
        candidate["provider_mutated"] = false
        candidate["cleanup_status"] = "not_required"
        candidate["reason"] = nil
        document["current_candidate"] = candidate.fetch("gpu_id")
        deep_copy(candidate)
      end
    end

    def mark_provider_mutation_started!
      transition do |document|
        candidate = current_candidate!(document, expected: "in_progress")
        candidate["provider_mutated"] = true
        deep_copy(document)
      end
    end

    def mark_provisioned!
      transition do |document|
        candidate = current_candidate!(document, expected: "in_progress")
        candidate["status"] = "provisioned"
        candidate["provisioned_at_utc"] = timestamp
        deep_copy(document)
      end
    end

    def mark_accepted!
      transition do |document|
        candidate = current_candidate!(document, expected: "provisioned")
        candidate["status"] = "accepted"
        candidate["finished_at_utc"] = timestamp
        document["state"] = "accepted"
        document["selected_candidate"] = candidate.fetch("gpu_id")
        document["current_candidate"] = nil
        document["stop_reason"] = nil
        deep_copy(document)
      end
    end

    def reject_current!(reason:, cleanup_status:)
      cleanup = cleanup_status.to_s
      unless %w[not_required verified_absent].include?(cleanup)
        raise Error, "a rejected candidate requires no provider mutation or verified provider absence"
      end
      transition do |document|
        candidate = current_candidate!(document, expected: %w[in_progress provisioned])
        if candidate.fetch("provider_mutated") && cleanup != "verified_absent"
          raise Error, "provider-mutated candidate cannot be rejected without verified absence"
        end
        candidate["status"] = "rejected"
        candidate["reason"] = nonempty_string!(reason, "candidate rejection reason")
        candidate["cleanup_status"] = cleanup
        candidate["finished_at_utc"] = timestamp
        document["current_candidate"] = nil
        if document.fetch("candidates").none? { |row| row.fetch("status") == "not_attempted" }
          document["state"] = "exhausted"
          document["stop_reason"] = "authorized candidate set exhausted"
        end
        deep_copy(document)
      end
    end

    def block_current!(reason:, cleanup_status: "unresolved")
      cleanup = cleanup_status.to_s
      raise Error, "invalid cleanup status #{cleanup.inspect}" unless CLEANUP_STATES.include?(cleanup)
      transition do |document|
        candidate = current_candidate!(document, expected: %w[in_progress provisioned])
        candidate["status"] = "blocked"
        candidate["reason"] = nonempty_string!(reason, "candidate block reason")
        candidate["cleanup_status"] = cleanup
        candidate["finished_at_utc"] = timestamp
        document["state"] = "blocked"
        document["stop_reason"] = candidate.fetch("reason")
        deep_copy(document)
      end
    end

    private

    def transition
      with_lock do
        document = load_current
        raise Error, "fallback decision has not been prepared" unless document
        verify_document!(document)
        result = yield document
        document["updated_at_utc"] = timestamp
        write_document(document)
        result
      end
    end

    def decision_identity(from:, target:, deadline:, candidates:)
      authority = retained_authority
      unless deadline == authority.fetch("original_deadline_at_utc")
        raise Error, "fallback deadline does not match the original parent deadline"
      end
      authority.merge(
        "profile_id" => @profile_id,
        "capability_fingerprint" => @capability_request.fingerprint,
        "from_workers" => from,
        "target_workers" => target,
        "authorized_gpu_ids" => expected_gpu_ids,
        "candidate_order" => candidates.map { |row| row.fetch("gpu_id") },
        "candidate_evidence_sha256" => candidate_evidence_sha256(candidates)
      )
    end

    def normalize_candidates(values)
      rows = Array(values).map.with_index do |value, index|
        raise Error, "candidate #{index} must be an object" unless value.is_a?(Hash)
        row = value.transform_keys(&:to_s)
        gpu_id = nonempty_string!(row.fetch("gpu_id"), "candidate #{index} GPU id")
        rate = row["hourly_rate_usd"]
        if rate
          rate = Float(rate)
          raise Error, "candidate #{gpu_id.inspect} hourly rate must be positive and finite" unless rate.positive? && rate.finite?
        end
        eligible = row.fetch("eligible") == true
        reason = row["reason"] && nonempty_string!(row.fetch("reason"), "candidate #{gpu_id.inspect} reason")
        if !eligible && !reason
          raise Error, "ineligible candidate #{gpu_id.inspect} requires a reason"
        end
        {
          "gpu_id" => gpu_id,
          "cloud" => nonempty_string!(row.fetch("cloud"), "candidate #{gpu_id.inspect} cloud").upcase,
          "hourly_rate_usd" => rate,
          "catalog_status" => eligible ? "eligible" : "rejected",
          "catalog_reason" => reason,
          "status" => eligible ? "not_attempted" : "rejected",
          "reason" => reason,
          "provider_mutated" => false,
          "cleanup_status" => "not_required",
          "attempted_at_utc" => nil,
          "provisioned_at_utc" => nil,
          "finished_at_utc" => eligible ? nil : timestamp
        }
      rescue KeyError, ArgumentError, TypeError => e
        raise Error, "invalid fallback candidate #{index}: #{e.message}"
      end
      ids = rows.map { |row| row.fetch("gpu_id") }
      raise Error, "fallback candidate GPU identities must be unique" unless ids.uniq == ids
      unless ids.sort == expected_gpu_ids.sort
        raise Error, "fallback candidates must equal the exact pre-authorized GPU set"
      end
      expected_order = rows.sort_by do |row|
        [row["hourly_rate_usd"].nil? ? 1 : 0, row["hourly_rate_usd"] || 0.0, row.fetch("gpu_id")]
      end
      unless rows == expected_order
        raise Error, "fallback candidates must be deterministically ordered by hourly rate then GPU id"
      end
      rows
    end

    def expected_gpu_ids
      required = @capability_request.required_gpu_id
      ids = required ? [required] : Array(@hardware.fetch("qualified_gpu_ids"))
      ids.map(&:to_s).uniq.sort
    end

    def verify_document!(document)
      unless document.fetch("contract_version") == CONTRACT_VERSION &&
             document.slice(*AUTHORITY_KEYS) == retained_authority &&
             document.fetch("profile_id") == @profile_id &&
             document.fetch("capability_fingerprint") == @capability_request.fingerprint &&
             document.fetch("authorized_gpu_ids") == expected_gpu_ids
        raise Error, "retained fallback state does not match immutable campaign authority"
      end
      identity = document.slice(*DECISION_IDENTITY_KEYS)
      unless Digest::SHA256.hexdigest(JSON.generate(identity)) == document.fetch("decision_sha256")
        raise Error, "retained fallback decision identity is invalid"
      end
      raise Error, "retained fallback state is invalid" unless STATES.include?(document.fetch("state"))
      candidates = document.fetch("candidates")
      unless candidates.is_a?(Array) && candidates.map { |row| row.fetch("gpu_id") } == document.fetch("candidate_order")
        raise Error, "retained fallback candidate order is invalid"
      end
      unless candidate_evidence_sha256(candidates) == document.fetch("candidate_evidence_sha256")
        raise Error, "retained fallback candidate evidence is invalid"
      end
      candidates.each do |row|
        raise Error, "retained fallback attempt state is invalid" unless ATTEMPT_STATES.include?(row.fetch("status"))
        raise Error, "retained fallback cleanup state is invalid" unless CLEANUP_STATES.include?(row.fetch("cleanup_status"))
        raise Error, "retained fallback provider mutation flag is invalid" unless [true, false].include?(row.fetch("provider_mutated"))
      end
      document
    rescue KeyError, TypeError => e
      raise Error, "retained fallback state is invalid: #{e.message}"
    end

    def current_candidate!(document, expected:)
      gpu_id = document.fetch("current_candidate")
      candidate = document.fetch("candidates").find { |row| row.fetch("gpu_id") == gpu_id }
      raise Error, "fallback current candidate is missing" unless candidate
      allowed = Array(expected)
      unless allowed.include?(candidate.fetch("status"))
        raise Error, "fallback candidate #{gpu_id.inspect} is #{candidate.fetch('status')}, expected #{allowed.join(' or ')}"
      end
      candidate
    end

    def retained_authority
      binding = @binding.inspect_authority
      raise Error, "campaign budget must be armed before fallback" unless binding.fetch("phase") == "ARMED"

      declaration = @binding.declaration
      {
        "campaign_identity_sha256" => @binding.campaign.identity_sha256,
        "binding_sha256" => @binding.binding_sha256,
        "budget_id" => declaration.fetch("budget_id"),
        "armed_at_utc" => timestamp!(binding.fetch("armed_at_utc"), "original armed time"),
        "original_deadline_at_utc" => timestamp!(binding.fetch("deadline_at_utc"), "original deadline"),
        "max_cumulative_compute_usd" => declaration.fetch("max_cumulative_compute_usd"),
        "max_aggregate_hourly_rate_usd" => declaration.fetch("max_aggregate_hourly_rate_usd"),
        "campaign_max_workers" => @binding.campaign.max_workers,
        "profile_max_workers" => @profile.fetch("max_workers")
      }
    rescue CampaignBudgetBinding::Error, KeyError, ArgumentError, TypeError => e
      raise Error, "could not verify immutable fallback authority: #{e.message}"
    end

    def candidate_evidence_sha256(candidates)
      evidence = candidates.map do |row|
        row.slice("gpu_id", "cloud", "hourly_rate_usd", "catalog_status", "catalog_reason")
      end
      Digest::SHA256.hexdigest(JSON.generate(evidence))
    end

    def load_current
      return nil unless File.file?(@pointer_path)
      decision_sha = File.binread(@pointer_path).strip
      raise Error, "fallback current pointer is invalid" unless decision_sha.match?(/\A[0-9a-f]{64}\z/)
      path = document_path(decision_sha)
      raise Error, "fallback retained decision is missing" unless File.file?(path)
      document = JSON.parse(File.binread(path))
      unless document.fetch("decision_sha256") == decision_sha
        raise Error, "fallback pointer does not match retained decision"
      end
      verify_document!(document)
    rescue JSON::ParserError, SystemCallError, KeyError => e
      raise Error, "fallback state is unreadable: #{e.message}"
    end

    def write_document(document)
      verify_document!(document)
      write_atomic(document_path(document.fetch("decision_sha256")), JSON.pretty_generate(document) + "\n")
    end

    def document_path(decision_sha)
      File.join(@root, "decisions", "#{decision_sha}.json")
    end

    def with_lock
      FileUtils.mkdir_p(@root)
      File.open(@lock_path, File::RDWR | File::CREAT, 0o600) do |lock|
        lock.flock(File::LOCK_EX)
        yield
      ensure
        lock.flock(File::LOCK_UN) rescue nil
      end
    rescue SystemCallError => e
      raise Error, "fallback state lock failed: #{e.message}"
    end

    def write_atomic(path, bytes)
      FileUtils.mkdir_p(File.dirname(path))
      temporary = "#{path}.tmp.#{$$}.#{Thread.current.object_id}"
      File.open(temporary, File::WRONLY | File::CREAT | File::TRUNC, 0o600) do |file|
        file.write(bytes)
        file.flush
        file.fsync
      end
      File.rename(temporary, path)
    ensure
      File.delete(temporary) if defined?(temporary) && temporary && File.exist?(temporary)
    end

    def nonnegative_integer!(value, label)
      number = Integer(value)
      raise Error, "#{label} must be non-negative" if number.negative?
      number
    rescue ArgumentError, TypeError
      raise Error, "#{label} must be a non-negative integer"
    end

    def positive_integer!(value, label)
      number = Integer(value)
      raise Error, "#{label} must be positive" unless number.positive?
      number
    rescue ArgumentError, TypeError
      raise Error, "#{label} must be a positive integer"
    end

    def nonempty_string!(value, label)
      result = value.to_s.strip
      raise Error, "#{label} must not be empty" if result.empty?
      result
    end

    def timestamp!(value, label)
      parsed = value.is_a?(Time) ? value : Time.iso8601(value.to_s)
      parsed.utc.iso8601
    rescue ArgumentError
      raise Error, "#{label} is invalid"
    end

    def timestamp
      value = @wall_clock.call
      value = Time.parse(value.to_s) unless value.is_a?(Time)
      value.utc.iso8601
    rescue ArgumentError
      raise Error, "fallback clock returned invalid time"
    end

    def deep_copy(value)
      JSON.parse(JSON.generate(value))
    end
  end
end
