# frozen_string_literal: true

require "digest"
require "fileutils"
require "json"
require "time"
require_relative "campaign_budget_binding"

module RunpodOllamaFleet
  # Durable, revisioned desired capacity inside one immutable campaign/budget
  # authority. Updating this state never inspects or mutates provider resources.
  class DesiredCapacity
    CONTRACT_VERSION = "rpof-desired-capacity/v0.1"
    ROOT_KEYS = %w[
      contract_version campaign_identity_sha256 binding_sha256 budget_id
      revision previous_sha256 updated_at_utc reason profiles
    ].freeze
    PROFILE_KEYS = %w[profile_id desired_workers].freeze
    DIGEST = /\A[0-9a-f]{64}\z/
    TIMESTAMP = /\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z\z/

    class Error < StandardError; end

    attr_reader :binding, :current_path, :history_dir

    def initialize(binding:, wall_clock: nil)
      unless binding.is_a?(CampaignBudgetBinding)
        raise Error, "binding must be a CampaignBudgetBinding"
      end

      @binding = binding
      @wall_clock = wall_clock || -> { Time.now.utc }
      @state_dir = File.join(File.dirname(binding.state_path), "desired-capacity")
      @current_path = File.join(@state_dir, "current.json")
      @history_dir = File.join(@state_dir, "revisions")
      @lock_path = File.join(@state_dir, ".lock")
    end

    # Revision zero is a deterministic compatibility baseline derived from the
    # frozen v0.1 campaign. Reading it creates no files.
    def current
      return state_view(initial_document, persisted: false) unless persisted_current?

      with_lock { state_view(load_current!, persisted: true) }
    end

    # Compare-and-set one or more profile counts. Identical state is a no-op;
    # stale expected revisions always fail, including for an identical request.
    def update!(profile_counts:, expected_revision:, reason:)
      requested = normalize_requested_counts(profile_counts)
      expected = nonnegative_integer!(expected_revision, "expected revision")
      mutation_reason = string!(reason, "reason", max: 1024)

      with_lock do
        current_persisted = persisted_current?
        previous = current_persisted ? load_current! : initial_document
        actual = previous.fetch("revision")
        unless expected == actual
          raise Error, "stale desired-capacity revision: expected #{expected}, current #{actual}"
        end

        counts = previous.fetch("profiles").to_h do |row|
          [row.fetch("profile_id"), row.fetch("desired_workers")]
        end
        requested.each { |profile_id, count| counts[profile_id] = count }
        if counts == desired_counts(previous)
          return state_view(previous, persisted: current_persisted).merge("changed" => false)
        end

        document = build_document(
          revision: actual + 1,
          previous_sha256: document_sha256(previous),
          updated_at_utc: utc_now.iso8601,
          reason: mutation_reason,
          counts:
        )
        persist!(document)
        state_view(document, persisted: true).merge("changed" => true)
      end
    rescue SystemCallError, JSON::ParserError => e
      raise Error, "desired-capacity state update failed: #{e.message}"
    end

    private

    def initial_document
      build_document(
        revision: 0,
        previous_sha256: nil,
        updated_at_utc: nil,
        reason: "rpof-capacity-campaign/v0.1 initial desired capacity",
        counts: binding.campaign.profiles.to_h do |profile|
          [profile.fetch("profile_id"), profile.fetch("desired_workers")]
        end
      )
    end

    def build_document(revision:, previous_sha256:, updated_at_utc:, reason:, counts:)
      document = {
        "contract_version" => CONTRACT_VERSION,
        "campaign_identity_sha256" => binding.campaign.identity_sha256,
        "binding_sha256" => binding.binding_sha256,
        "budget_id" => binding.declaration.fetch("budget_id"),
        "revision" => revision,
        "previous_sha256" => previous_sha256,
        "updated_at_utc" => updated_at_utc,
        "reason" => reason,
        "profiles" => counts.sort.map do |profile_id, desired_workers|
          { "profile_id" => profile_id, "desired_workers" => desired_workers }
        end
      }
      validate_document!(document, persisted: revision.positive?)
    end

    def load_current!
      document = JSON.parse(File.binread(current_path))
      normalized = validate_document!(document, persisted: true)
      history_path = history_path_for(normalized.fetch("revision"))
      raise Error, "desired-capacity revision history is missing" unless File.file?(history_path)

      history = validate_document!(JSON.parse(File.binread(history_path)), persisted: true)
      unless history == normalized
        raise Error, "desired-capacity current state does not match retained revision history"
      end
      verify_previous_revision!(normalized)
      normalized
    rescue JSON::ParserError, SystemCallError => e
      raise Error, "desired-capacity state is unreadable: #{e.message}"
    end

    def verify_previous_revision!(document)
      revision = document.fetch("revision")
      previous = if revision == 1
                   initial_document
                 else
                   path = history_path_for(revision - 1)
                   raise Error, "desired-capacity previous revision is missing" unless File.file?(path)
                   validate_document!(JSON.parse(File.binread(path)), persisted: true)
                 end
      unless document.fetch("previous_sha256") == document_sha256(previous)
        raise Error, "desired-capacity previous revision hash does not match"
      end
      true
    end

    def validate_document!(value, persisted:)
      exact_keys!(value, ROOT_KEYS, "desired-capacity state")
      unless value.fetch("contract_version") == CONTRACT_VERSION
        raise Error, "desired-capacity contract must be #{CONTRACT_VERSION.inspect}"
      end
      unless digest!(value.fetch("campaign_identity_sha256"), "campaign identity sha256") ==
             binding.campaign.identity_sha256
        raise Error, "desired-capacity campaign identity does not match immutable authority"
      end
      unless digest!(value.fetch("binding_sha256"), "binding sha256") == binding.binding_sha256
        raise Error, "desired-capacity budget binding does not match immutable authority"
      end
      unless value.fetch("budget_id") == binding.declaration.fetch("budget_id")
        raise Error, "desired-capacity budget ID does not match immutable authority"
      end

      revision = nonnegative_integer!(value.fetch("revision"), "revision")
      if persisted && !revision.positive?
        raise Error, "persisted desired-capacity revision must be positive"
      end
      previous = value.fetch("previous_sha256")
      if revision.zero?
        raise Error, "initial desired-capacity previous_sha256 must be null" unless previous.nil?
      else
        digest!(previous, "previous sha256")
      end
      timestamp = value.fetch("updated_at_utc")
      if revision.zero?
        raise Error, "initial desired-capacity timestamp must be null" unless timestamp.nil?
      else
        timestamp!(timestamp)
      end

      reason = string!(value.fetch("reason"), "reason", max: 1024)
      profiles = normalize_profiles(value.fetch("profiles"))
      {
        "contract_version" => CONTRACT_VERSION,
        "campaign_identity_sha256" => binding.campaign.identity_sha256,
        "binding_sha256" => binding.binding_sha256,
        "budget_id" => binding.declaration.fetch("budget_id"),
        "revision" => revision,
        "previous_sha256" => previous,
        "updated_at_utc" => timestamp,
        "reason" => reason,
        "profiles" => profiles
      }
    end

    def normalize_profiles(value)
      raise Error, "desired-capacity profiles must be a non-empty array" unless value.is_a?(Array) && !value.empty?

      profiles = value.map.with_index do |row, index|
        exact_keys!(row, PROFILE_KEYS, "profiles[#{index}]")
        profile_id = string!(row.fetch("profile_id"), "profiles[#{index}].profile_id", max: 128)
        profile = authority_profiles.fetch(profile_id) do
          raise Error, "unknown campaign profile_id #{profile_id.inspect}"
        end
        desired = nonnegative_integer!(row.fetch("desired_workers"), "profiles[#{index}].desired_workers")
        if desired > profile.fetch("max_workers")
          raise Error, "desired workers for #{profile_id.inspect} exceed immutable profile maximum"
        end
        { "profile_id" => profile_id, "desired_workers" => desired }
      end
      ids = profiles.map { |row| row.fetch("profile_id") }
      raise Error, "desired-capacity profile_id values must be unique" unless ids.uniq == ids
      unless ids.sort == authority_profiles.keys.sort
        raise Error, "desired-capacity state must contain every immutable campaign profile exactly once"
      end

      profiles.sort_by { |row| row.fetch("profile_id") }
    end

    def normalize_requested_counts(value)
      unless value.is_a?(Hash) && !value.empty?
        raise Error, "desired-capacity update must include at least one profile"
      end

      value.each_with_object({}) do |(raw_id, raw_count), counts|
        profile_id = string!(raw_id.to_s, "profile_id", max: 128)
        profile = authority_profiles.fetch(profile_id) do
          raise Error, "unknown campaign profile_id #{profile_id.inspect}"
        end
        desired = nonnegative_integer!(raw_count, "desired workers for #{profile_id.inspect}")
        if desired > profile.fetch("max_workers")
          raise Error, "desired workers for #{profile_id.inspect} exceed immutable profile maximum"
        end
        counts[profile_id] = desired
      end
    end

    def authority_profiles
      @authority_profiles ||= binding.campaign.profiles.to_h { |row| [row.fetch("profile_id"), row] }.freeze
    end

    def desired_counts(document)
      document.fetch("profiles").to_h { |row| [row.fetch("profile_id"), row.fetch("desired_workers")] }
    end

    def persist!(document)
      FileUtils.mkdir_p(history_dir)
      history_path = history_path_for(document.fetch("revision"))
      if File.exist?(history_path)
        raise Error, "desired-capacity revision #{document.fetch('revision')} already exists"
      end

      bytes = JSON.pretty_generate(document) + "\n"
      write_exclusive!(history_path, bytes)
      atomic_replace!(current_path, bytes)
    end

    def persisted_current?
      return false unless File.exist?(current_path)
      return true if File.file?(current_path)

      raise Error, "desired-capacity current state is not a regular file"
    end

    def write_exclusive!(path, bytes)
      File.open(path, File::WRONLY | File::CREAT | File::EXCL, 0o600) do |file|
        file.write(bytes)
        file.flush
        file.fsync
      end
    end

    def atomic_replace!(path, bytes)
      tmp = "#{path}.tmp.#{$$}.#{Thread.current.object_id}"
      File.open(tmp, File::WRONLY | File::CREAT | File::TRUNC, 0o600) do |file|
        file.write(bytes)
        file.flush
        file.fsync
      end
      File.rename(tmp, path)
    ensure
      File.delete(tmp) if defined?(tmp) && tmp && File.exist?(tmp)
    end

    def history_path_for(revision)
      File.join(history_dir, format("%010d.json", revision))
    end

    def state_view(document, persisted:)
      Marshal.load(Marshal.dump(document)).merge(
        "sha256" => document_sha256(document),
        "persisted" => persisted
      )
    end

    def document_sha256(document)
      Digest::SHA256.hexdigest(JSON.generate(document))
    end

    def with_lock
      FileUtils.mkdir_p(@state_dir)
      File.open(@lock_path, File::RDWR | File::CREAT, 0o600) do |lock|
        lock.flock(File::LOCK_EX)
        yield
      ensure
        lock.flock(File::LOCK_UN) rescue nil
      end
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
      text = value.to_s.downcase
      raise Error, "#{label} must be a full SHA-256 digest" unless value.is_a?(String) && text.match?(DIGEST)

      text
    end

    def timestamp!(value)
      unless value.is_a?(String) && value.match?(TIMESTAMP) && Time.iso8601(value).utc.iso8601 == value
        raise Error, "updated_at_utc must be a canonical whole-second UTC timestamp"
      end
      value
    rescue ArgumentError
      raise Error, "updated_at_utc must be a canonical whole-second UTC timestamp"
    end

    def string!(value, label, max:)
      unless value.is_a?(String) && !value.empty? && value == value.strip && !value.match?(/[[:cntrl:]]/)
        raise Error, "#{label} must be a non-empty trimmed string without control characters"
      end
      raise Error, "#{label} exceeds #{max} characters" if value.length > max

      value
    end

    def nonnegative_integer!(value, label)
      return value if value.is_a?(Integer) && !value.negative?

      raise Error, "#{label} must be a non-negative integer"
    end

    def utc_now
      value = @wall_clock.call
      value = Time.parse(value.to_s) unless value.is_a?(Time)
      Time.at(value.to_i).utc
    rescue ArgumentError
      raise Error, "desired-capacity clock returned invalid time"
    end
  end
end
