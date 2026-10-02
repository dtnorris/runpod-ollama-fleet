# frozen_string_literal: true

require "json"

module RunpodOllamaFleet
  class ModelRequirement
    CONTRACT_VERSION = "adventurefinder-model-requirement/v0.1"
    ROOT_KEYS = %w[
      contract_version batch_handle production_batch_id plan_id plan_sha256
      alias pool_id required_labels ollama
    ].freeze
    OLLAMA_REQUIRED_KEYS = %w[
      model expected_digest required_context_length require_fully_gpu_resident
    ].freeze
    OLLAMA_OPTIONAL_KEYS = %w[required_gpu_id].freeze
    SHA256 = /\A[0-9a-f]{64}\z/

    class Error < StandardError; end

    attr_reader :document

    def self.load(path)
      new(JSON.parse(File.binread(File.expand_path(path))))
    rescue JSON::ParserError => e
      raise Error, "invalid model requirement JSON: #{e.message}"
    rescue SystemCallError => e
      raise Error, "cannot read model requirement #{path}: #{e.message}"
    end

    def initialize(document)
      @document = normalize(document)
      deep_freeze(@document)
      freeze
    end

    def validate_profile!(profile:, hardware:)
      raise Error, "campaign profile must be an object" unless profile.is_a?(Hash)
      expected = ollama
      compare!(profile, "model", expected.fetch("model"))
      compare!(profile, "expected_digest", expected.fetch("expected_digest"))
      compare!(profile, "required_context_length", expected.fetch("required_context_length"))
      compare!(profile, "require_fully_gpu_resident", true)
      validate_gpu!(hardware, expected["required_gpu_id"]) if expected.key?("required_gpu_id")
      profile
    end

    def ollama
      document.fetch("ollama")
    end

    def required_gpu_id
      ollama["required_gpu_id"]
    end

    private

    def normalize(value)
      exact_keys!(value, ROOT_KEYS, "model requirement")
      unless value.fetch("contract_version") == CONTRACT_VERSION
        raise Error, "model requirement contract must be #{CONTRACT_VERSION}"
      end
      normalized = {}
      ROOT_KEYS.each { |key| normalized[key] = value.fetch(key) }
      %w[batch_handle production_batch_id plan_id alias pool_id].each do |key|
        normalized[key] = string!(normalized.fetch(key), key)
      end
      %w[plan_sha256].each { |key| normalized[key] = digest!(normalized.fetch(key), key) }
      normalized["required_labels"] = labels!(normalized.fetch("required_labels"))
      normalized["ollama"] = normalize_ollama(normalized.fetch("ollama"))
      normalized
    end

    def normalize_ollama(value)
      exact_keys!(value, OLLAMA_REQUIRED_KEYS, "model requirement ollama", optional: OLLAMA_OPTIONAL_KEYS)
      output = {
        "model" => string!(value.fetch("model"), "ollama.model"),
        "expected_digest" => digest!(value.fetch("expected_digest"), "ollama.expected_digest"),
        "required_context_length" => positive_integer!(
          value.fetch("required_context_length"), "ollama.required_context_length"
        ),
        "require_fully_gpu_resident" => value.fetch("require_fully_gpu_resident")
      }
      unless output.fetch("require_fully_gpu_resident") == true
        raise Error, "ollama.require_fully_gpu_resident must be true"
      end
      if value.key?("required_gpu_id")
        output["required_gpu_id"] = string!(value.fetch("required_gpu_id"), "ollama.required_gpu_id")
      end
      output
    end

    def validate_gpu!(hardware, required)
      raise Error, "hardware binding must be an object" unless hardware.is_a?(Hash)
      qualified = hardware["qualified_gpu_ids"]
      unless qualified.is_a?(Array) && qualified.include?(required)
        raise Error, "required GPU identity mismatch: expected #{required.inspect}"
      end
    end

    def compare!(profile, field, expected)
      actual = profile[field]
      return if actual == expected
      raise Error, "#{field} mismatch: expected #{expected.inspect}, got #{actual.inspect}"
    end

    def exact_keys!(value, required, label, optional: [])
      raise Error, "#{label} must be an object" unless value.is_a?(Hash)
      missing = required - value.keys
      unknown = value.keys - required - optional
      raise Error, "#{label} missing field(s): #{missing.join(', ')}" unless missing.empty?
      raise Error, "#{label} unknown field(s): #{unknown.sort.join(', ')}" unless unknown.empty?
    end

    def string!(value, label)
      return value if value.is_a?(String) && !value.empty? && value == value.strip && !value.match?(/[[:cntrl:]]/)
      raise Error, "#{label} must be a non-empty trimmed string"
    end

    def digest!(value, label)
      return value if value.is_a?(String) && SHA256.match?(value)
      raise Error, "#{label} must be a lowercase SHA-256"
    end

    def positive_integer!(value, label)
      return value if value.is_a?(Integer) && value.positive?
      raise Error, "#{label} must be a positive integer"
    end

    def labels!(value)
      valid = value.is_a?(Array) && value.all? do |item|
        item.is_a?(String) && !item.empty? && item == item.strip
      end
      valid &&= value.uniq == value
      raise Error, "required_labels must be unique non-empty strings" unless valid
      value.dup
    end

    def deep_freeze(value)
      value.each { |key, item| deep_freeze(key); deep_freeze(item) } if value.is_a?(Hash)
      value.each { |item| deep_freeze(item) } if value.is_a?(Array)
      value.freeze
    end
  end
end
