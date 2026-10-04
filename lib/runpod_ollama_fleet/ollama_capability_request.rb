# frozen_string_literal: true

require "digest"
require "json"

module RunpodOllamaFleet
  # Independent strict implementation of WLO's public
  # ollama-capability-request/v0.1 contract.
  class OllamaCapabilityRequest
    CONTRACT_VERSION = "ollama-capability-request/v0.1"
    ROOT_KEYS = %w[contract_version ollama].freeze
    OLLAMA_REQUIRED_KEYS = %w[
      model expected_digest required_context_length require_fully_gpu_resident
    ].freeze
    OLLAMA_OPTIONAL_KEYS = %w[required_gpu_id].freeze
    SHA256 = /\A[0-9a-f]{64}\z/
    MAX_IDENTITY_LENGTH = 256

    class Error < StandardError; end

    class DuplicateKeyHash < Hash
      def []=(key, value)
        raise JSON::ParserError, "duplicate object key #{key.inspect}" if key?(key)

        super
      end
    end
    private_constant :DuplicateKeyHash

    attr_reader :document, :ollama, :normalized_request, :normalized_json, :fingerprint

    def self.load(path)
      new(File.binread(File.expand_path(path)))
    rescue SystemCallError => e
      raise Error, "cannot read Ollama capability request #{path}: #{e.message}"
    end

    def initialize(bytes)
      raise Error, "Ollama capability request must be JSON bytes" unless bytes.is_a?(String)

      @document = JSON.parse(bytes, object_class: DuplicateKeyHash)
      validate!
      @normalized_request = { "ollama" => normalized_ollama }.freeze
      @normalized_json = JSON.generate(normalized_request).encode(Encoding::UTF_8).freeze
      @fingerprint = Digest::SHA256.hexdigest(normalized_json).freeze
      deep_freeze(@document)
      freeze
    rescue JSON::ParserError, EncodingError => e
      raise Error, "invalid Ollama capability-request JSON: #{e.message}"
    end

    def required_gpu_id
      ollama["required_gpu_id"]
    end

    def validate_profile!(profile:, hardware:)
      raise Error, "campaign profile must be an object" unless profile.is_a?(Hash)

      compare!(profile, "model", ollama.fetch("model"))
      compare!(profile, "expected_digest", ollama.fetch("expected_digest"))
      compare!(profile, "required_context_length", ollama.fetch("required_context_length"))
      compare!(profile, "require_fully_gpu_resident", ollama.fetch("require_fully_gpu_resident"))
      validate_gpu!(hardware, required_gpu_id) unless required_gpu_id.nil?
      profile
    end

    private

    def validate!
      exact_keys!(document, ROOT_KEYS, "Ollama capability request")
      unless document.fetch("contract_version") == CONTRACT_VERSION
        raise Error, "Ollama capability request contract must be #{CONTRACT_VERSION}"
      end

      value = document.fetch("ollama")
      exact_keys!(value, OLLAMA_REQUIRED_KEYS, "ollama", optional: OLLAMA_OPTIONAL_KEYS)
      @ollama = {
        "model" => identity!(value.fetch("model"), "ollama.model"),
        "expected_digest" => digest!(value.fetch("expected_digest")),
        "required_context_length" => positive_integer!(
          value.fetch("required_context_length"), "ollama.required_context_length"
        ),
        "require_fully_gpu_resident" => boolean!(
          value.fetch("require_fully_gpu_resident"), "ollama.require_fully_gpu_resident"
        )
      }
      if value.key?("required_gpu_id")
        @ollama["required_gpu_id"] = identity!(value.fetch("required_gpu_id"), "ollama.required_gpu_id")
      end
      deep_freeze(@ollama)
    end

    def normalized_ollama
      output = {
        "model" => ollama.fetch("model"),
        "expected_digest" => ollama.fetch("expected_digest"),
        "required_context_length" => ollama.fetch("required_context_length"),
        "require_fully_gpu_resident" => ollama.fetch("require_fully_gpu_resident")
      }
      output["required_gpu_id"] = required_gpu_id unless required_gpu_id.nil?
      output.freeze
    end

    def exact_keys!(value, required, label, optional: [])
      raise Error, "#{label} must be an object" unless value.is_a?(Hash)

      missing = required - value.keys
      unknown = value.keys - required - optional
      raise Error, "#{label} missing fields: #{missing.join(', ')}" unless missing.empty?
      raise Error, "#{label} unknown fields: #{unknown.join(', ')}" unless unknown.empty?
    end

    def identity!(value, label)
      valid = value.is_a?(String) && !value.empty? && value == value.strip &&
              !value.match?(/[[:cntrl:]]/) && value.length <= MAX_IDENTITY_LENGTH
      return value.freeze if valid

      raise Error, "#{label} must be a non-empty trimmed string of at most #{MAX_IDENTITY_LENGTH} characters"
    end

    def digest!(value)
      return value.freeze if value.is_a?(String) && SHA256.match?(value)

      raise Error, "ollama.expected_digest must be an exact lowercase 64-hex digest"
    end

    def positive_integer!(value, label)
      return value if value.is_a?(Integer) && value.positive?

      raise Error, "#{label} must be a positive integer"
    end

    def boolean!(value, label)
      return value if value == true || value == false

      raise Error, "#{label} must be boolean"
    end

    def validate_gpu!(hardware, required)
      raise Error, "hardware binding must be an object" unless hardware.is_a?(Hash)

      qualified = hardware["qualified_gpu_ids"]
      return if qualified.is_a?(Array) && qualified.include?(required)

      raise Error, "required GPU identity mismatch: expected #{required.inspect}"
    end

    def compare!(profile, field, expected)
      actual = profile[field]
      return if actual == expected

      raise Error, "#{field} mismatch: expected #{expected.inspect}, got #{actual.inspect}"
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
