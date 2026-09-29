# frozen_string_literal: true

require "digest"
require "json"
require_relative "execution_pool_hardware"

module RunpodOllamaFleet
  # Validated, provider-neutral desired-capacity declaration. This class only
  # parses and binds intent to RPOF's hardware qualification registry; it does
  # not inspect or mutate provider resources.
  class CapacityCampaign
    CONTRACT_VERSION = "rpof-capacity-campaign/v0.1"
    QUALIFICATION_BINDING_VERSION = "rpof-capacity-campaign-hardware-binding/v0.1"
    IDENTITY_VERSION = "rpof-capacity-campaign-identity/v0.1"
    ROOT_KEYS = %w[
      contract_version campaign_id max_workers max_hourly_rate_usd profiles
    ].freeze
    PROFILE_KEYS = %w[
      profile_id model expected_digest required_context_length
      require_fully_gpu_resident min_workers desired_workers max_workers
    ].freeze
    ID = /\A[A-Za-z0-9][A-Za-z0-9._-]{0,127}\z/
    DIGEST = /\A[0-9a-fA-F]{64}\z/

    class Error < StandardError; end

    class DuplicateKeyHash < Hash
      def []=(key, value)
        raise JSON::ParserError, "duplicate object key #{key.inspect}" if key?(key)

        super
      end
    end
    private_constant :DuplicateKeyHash

    attr_reader :campaign_id, :max_workers, :max_hourly_rate_usd, :profiles,
                :normalized_document, :normalized_bytes, :sha256,
                :hardware_bindings, :hardware_qualification_sha256,
                :identity, :identity_sha256

    def self.load(path:, hardware:)
      new(File.binread(File.expand_path(path)), hardware:)
    rescue SystemCallError => e
      raise Error, "cannot read capacity campaign #{path}: #{e.message}"
    end

    def initialize(bytes, hardware:)
      raise Error, "capacity campaign must be JSON bytes" unless bytes.is_a?(String)
      unless hardware.respond_to?(:profile_for)
        raise Error, "capacity campaign hardware registry must implement #profile_for"
      end

      document = JSON.parse(bytes, object_class: DuplicateKeyHash)
      @normalized_document, @hardware_bindings = validate_and_normalize(document, hardware)
      deep_freeze(@normalized_document)
      deep_freeze(@hardware_bindings)
      assign_identity!
      freeze
    rescue JSON::ParserError => e
      raise Error, "invalid capacity campaign JSON: #{e.message}"
    rescue ExecutionPoolHardware::Error => e
      raise Error, e.message
    end

    private

    def validate_and_normalize(document, hardware)
      exact_keys!(document, ROOT_KEYS, "capacity campaign")
      unless document.fetch("contract_version") == CONTRACT_VERSION
        raise Error, "capacity campaign contract must be #{CONTRACT_VERSION.inspect}"
      end

      @campaign_id = id!(document.fetch("campaign_id"), "campaign_id")
      @max_workers = positive_integer!(document.fetch("max_workers"), "max_workers")
      @max_hourly_rate_usd = positive_number!(
        document.fetch("max_hourly_rate_usd"), "max_hourly_rate_usd"
      )
      raw_profiles = document.fetch("profiles")
      unless raw_profiles.is_a?(Array) && !raw_profiles.empty?
        raise Error, "capacity campaign profiles must be a non-empty array"
      end

      normalized, bindings = normalize_profiles(raw_profiles, hardware)
      validate_profile_set!(normalized)
      [build_normalized_document(normalized), bindings.sort_by { |row| row.fetch("profile_id") }]
    end

    def normalize_profiles(raw_profiles, hardware)
      normalized = []
      bindings = []
      raw_profiles.each_with_index do |profile, index|
        label = "profiles[#{index}]"
        exact_keys!(profile, PROFILE_KEYS, label)
        row = normalize_profile(profile, label)
        normalized << row
        bindings << qualification_binding(row, hardware)
      end
      [normalized.sort_by { |row| row.fetch("profile_id") }, bindings]
    end

    def normalize_profile(profile, label)
      minimum = positive_integer!(profile.fetch("min_workers"), "#{label}.min_workers")
      desired = positive_integer!(profile.fetch("desired_workers"), "#{label}.desired_workers")
      maximum = positive_integer!(profile.fetch("max_workers"), "#{label}.max_workers")
      unless minimum <= desired && desired <= maximum
        raise Error, "#{label} worker counts must satisfy min_workers <= desired_workers <= max_workers"
      end
      unless profile.fetch("require_fully_gpu_resident") == true
        raise Error, "#{label}.require_fully_gpu_resident must be true"
      end

      {
        "profile_id" => id!(profile.fetch("profile_id"), "#{label}.profile_id"),
        "model" => string!(profile.fetch("model"), "#{label}.model", max: 256),
        "expected_digest" => digest!(profile.fetch("expected_digest"), "#{label}.expected_digest"),
        "required_context_length" => positive_integer!(
          profile.fetch("required_context_length"), "#{label}.required_context_length"
        ),
        "require_fully_gpu_resident" => true,
        "min_workers" => minimum,
        "desired_workers" => desired,
        "max_workers" => maximum
      }
    end

    def qualification_binding(profile, hardware)
      qualification = hardware.profile_for(profile.fetch("model"))
      unless qualification.model == profile.fetch("model")
        raise Error, "hardware qualification model does not match #{profile.fetch('model').inspect}"
      end

      gpu_ids = Array(qualification.gpu_ids).map do |gpu_id|
        string!(gpu_id, "qualified GPU identity", max: 256)
      end
      raise Error, "hardware qualification has no qualified GPU identities" if gpu_ids.empty?

      {
        "profile_id" => profile.fetch("profile_id"),
        "model" => profile.fetch("model"),
        "cloud" => string!(qualification.cloud, "hardware cloud", max: 64),
        "qualified_gpu_ids" => gpu_ids.uniq.sort,
        "shared_model" => string!(qualification.shared_model, "shared model", max: 256),
        "global_volume_id" => string!(qualification.global_volume_id, "global volume ID", max: 256),
        "ollama_store_path" => string!(qualification.ollama_store_path, "Ollama store path", max: 1024)
      }
    end

    def validate_profile_set!(normalized)
      ids = normalized.map { |profile| profile.fetch("profile_id") }
      raise Error, "capacity campaign profile_id values must be unique" unless ids.uniq == ids

      maximum = normalized.sum { |profile| profile.fetch("max_workers") }
      if maximum > max_workers
        raise Error, "sum of profile max_workers #{maximum} exceeds campaign max_workers #{max_workers}"
      end

      requirements = {}
      normalized.each do |profile|
        model = profile.fetch("model")
        signature = profile.values_at(
          "expected_digest", "required_context_length", "require_fully_gpu_resident"
        )
        if requirements.key?(model) && requirements.fetch(model) != signature
          raise Error, "model #{model.inspect} has conflicting digest or capability requirements"
        end
        requirements[model] = signature
      end
    end

    def build_normalized_document(normalized_profiles)
      {
        "contract_version" => CONTRACT_VERSION,
        "campaign_id" => campaign_id,
        "max_workers" => max_workers,
        "max_hourly_rate_usd" => max_hourly_rate_usd,
        "profiles" => normalized_profiles
      }
    end

    def assign_identity!
      @profiles = normalized_document.fetch("profiles")
      @normalized_bytes = JSON.generate(normalized_document).freeze
      @sha256 = Digest::SHA256.hexdigest(normalized_bytes).freeze
      qualification_bytes = JSON.generate(
        "contract_version" => QUALIFICATION_BINDING_VERSION,
        "profiles" => hardware_bindings
      )
      @hardware_qualification_sha256 = Digest::SHA256.hexdigest(qualification_bytes).freeze
      @identity = {
        "contract_version" => IDENTITY_VERSION,
        "campaign_id" => campaign_id,
        "campaign_sha256" => sha256,
        "hardware_qualification_sha256" => hardware_qualification_sha256
      }
      deep_freeze(@identity)
      @identity_sha256 = Digest::SHA256.hexdigest(JSON.generate(identity)).freeze
    end

    def exact_keys!(value, required, label)
      raise Error, "#{label} must be an object" unless value.is_a?(Hash)

      missing = required - value.keys
      unknown = value.keys - required
      raise Error, "#{label} missing required field(s): #{missing.join(', ')}" unless missing.empty?
      raise Error, "#{label} unknown field(s): #{unknown.sort.join(', ')}" unless unknown.empty?
    end

    def id!(value, label)
      string!(value, label, max: 128)
      raise Error, "#{label} has invalid format" unless value.match?(ID)

      value
    end

    def digest!(value, label)
      unless value.is_a?(String) && value.match?(DIGEST)
        raise Error, "#{label} must be a full SHA-256 digest"
      end

      value.downcase
    end

    def string!(value, label, max:)
      unless value.is_a?(String) && !value.empty? && value == value.strip && !value.match?(/[[:cntrl:]]/)
        raise Error, "#{label} must be a non-empty trimmed string without control characters"
      end
      raise Error, "#{label} exceeds #{max} characters" if value.length > max

      value
    end

    def positive_integer!(value, label)
      return value if value.is_a?(Integer) && value.positive?

      raise Error, "#{label} must be a positive integer"
    end

    def positive_number!(value, label)
      number = value.to_f if value.is_a?(Numeric)
      return number if number&.finite? && number.positive?

      raise Error, "#{label} must be a positive finite number"
    rescue RangeError
      raise Error, "#{label} must be a positive finite number"
    end

    def deep_freeze(value)
      case value
      when Hash
        value.each do |key, item|
          deep_freeze(key)
          deep_freeze(item)
        end
      when Array then value.each { |item| deep_freeze(item) }
      end
      value.freeze
    end
  end
end
