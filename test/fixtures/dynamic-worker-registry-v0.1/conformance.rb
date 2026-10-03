# frozen_string_literal: true

require "digest"
require "json"
require "time"
require "uri"

# Standalone public conformance implementation for dynamic-worker-registry/v0.1.
# It deliberately has no dependency on workload-orchestrator runtime code.
module DynamicWorkerRegistryV01
  module Conformance
    VERSION = "dynamic-worker-registry/v0.1"
    ROOT_KEYS = %w[contract_version registry_id revision published_at expires_at workers].freeze
    WORKER_KEYS = %w[
      worker_id generation_id endpoint state labels capabilities capability_fingerprint
    ].freeze
    CAPABILITY_KEYS = %w[gpu_id ollama].freeze
    OLLAMA_KEYS = %w[models].freeze
    MODEL_KEYS = %w[model digest context_length fully_gpu_resident].freeze
    STATES = %w[READY NOT_READY UNAVAILABLE].freeze
    ID = /\A[A-Za-z0-9][A-Za-z0-9._-]{0,127}\z/
    SHA256 = /\A[0-9a-f]{64}\z/
    TIMESTAMP = /\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z\z/

    class Error < StandardError; end

    class DuplicateKeyHash < Hash
      def []=(key, value)
        raise JSON::ParserError, "duplicate object key #{key.inspect}" if key?(key)

        super
      end
    end
    private_constant :DuplicateKeyHash

    module_function

    def validate_bytes!(bytes, now: Time.now.utc, previous_bytes: nil)
      raise Error, "worker registry must be JSON bytes" unless bytes.is_a?(String)

      document = parse(bytes)
      validate_document!(document, now: now)
      validate_previous!(bytes, document, previous_bytes) if previous_bytes
      document
    end

    def validate_document!(document, now: Time.now.utc)
      exact_keys!(document, ROOT_KEYS, "worker registry")
      unless document.fetch("contract_version") == VERSION
        raise Error, "worker registry contract must be #{VERSION}"
      end

      id!(document.fetch("registry_id"), "registry_id")
      revision!(document.fetch("revision"))
      published_at = timestamp!(document.fetch("published_at"), "published_at")
      expires_at = timestamp!(document.fetch("expires_at"), "expires_at")
      current = time!(now, "current time")
      raise Error, "worker registry published_at is future-dated" if published_at > current
      raise Error, "worker registry expires_at must follow published_at" unless expires_at > published_at
      raise Error, "worker registry snapshot is expired" unless expires_at > current

      workers = document.fetch("workers")
      raise Error, "worker registry workers must be an array" unless workers.is_a?(Array)

      worker_ids = {}
      endpoints = {}
      workers.each_with_index do |worker, index|
        label = "worker[#{index}]"
        validate_worker!(worker, label: label)
        worker_id = worker.fetch("worker_id")
        endpoint = normalized_endpoint(worker.fetch("endpoint"), "#{label}.endpoint")
        raise Error, "duplicate worker_id #{worker_id.inspect}" if worker_ids.key?(worker_id)
        raise Error, "duplicate worker endpoint #{worker.fetch('endpoint').inspect}" if endpoints.key?(endpoint)

        worker_ids[worker_id] = true
        endpoints[endpoint] = true
      end
      document
    end

    def validate_worker!(worker, label: "worker")
      exact_keys!(worker, WORKER_KEYS, label)
      id!(worker.fetch("worker_id"), "#{label}.worker_id")
      nonempty!(worker.fetch("generation_id"), "#{label}.generation_id", max: 256)
      normalized_endpoint(worker.fetch("endpoint"), "#{label}.endpoint")
      state = worker.fetch("state")
      raise Error, "#{label}.state must be one of #{STATES.join(', ')}" unless STATES.include?(state)

      labels!(worker.fetch("labels"), label)
      capabilities!(worker.fetch("capabilities"), label)
      supplied = worker.fetch("capability_fingerprint")
      unless supplied.is_a?(String) && SHA256.match?(supplied)
        raise Error, "#{label}.capability_fingerprint must be a lowercase SHA-256"
      end
      unless supplied == capability_fingerprint(worker)
        raise Error, "#{label}.capability_fingerprint does not match capabilities"
      end

      worker
    end

    def capability_fingerprint(worker)
      Digest::SHA256.hexdigest(capability_payload(worker))
    end

    def capability_payload(worker)
      capabilities = worker.fetch("capabilities")
      models = capabilities.dig("ollama", "models").map do |model|
        {
          "context_length" => model.fetch("context_length"),
          "digest" => model.fetch("digest"),
          "fully_gpu_resident" => model.fetch("fully_gpu_resident"),
          "model" => model.fetch("model")
        }
      end
      JSON.generate(
        "gpu_id" => capabilities.fetch("gpu_id"),
        "labels" => worker.fetch("labels"),
        "ollama_models" => models
      )
    end

    def parse(bytes)
      JSON.parse(bytes, object_class: DuplicateKeyHash)
    rescue JSON::ParserError => e
      raise Error, "invalid dynamic worker registry JSON: #{e.message}"
    end

    def validate_previous!(bytes, document, previous_bytes)
      previous = parse(previous_bytes)
      previous_published_at = timestamp!(previous["published_at"], "previous published_at")
      validate_document!(previous, now: previous_published_at)
      registry_id = document.fetch("registry_id")
      previous_registry_id = previous.fetch("registry_id")
      unless registry_id == previous_registry_id
        raise Error, "worker registry identity changed from #{previous_registry_id.inspect} to #{registry_id.inspect}"
      end

      revision = document.fetch("revision")
      previous_revision = previous.fetch("revision")
      if revision < previous_revision
        raise Error, "worker registry revision rolled back from #{previous_revision} to #{revision}"
      end
      if revision == previous_revision
        return if Digest::SHA256.hexdigest(bytes) == Digest::SHA256.hexdigest(previous_bytes)

        raise Error, "worker registry revision #{revision} changed contents"
      end

      current_time = timestamp!(document.fetch("published_at"), "published_at")
      previous_time = previous_published_at
      return if current_time > previous_time

      raise Error, "worker registry publication time did not advance with revision"
    end

    def exact_keys!(value, expected, label)
      raise Error, "#{label} must be an object" unless value.is_a?(Hash)

      missing = expected - value.keys
      unknown = value.keys - expected
      raise Error, "#{label} missing fields: #{missing.join(', ')}" unless missing.empty?
      raise Error, "#{label} unknown fields: #{unknown.join(', ')}" unless unknown.empty?
    end

    def id!(value, label)
      raise Error, "#{label} is invalid" unless value.is_a?(String) && ID.match?(value)

      value
    end

    def nonempty!(value, label, max: nil)
      valid = value.is_a?(String) && !value.empty? && value == value.strip && !value.match?(/[[:cntrl:]]/)
      valid &&= value.length <= max if max
      raise Error, "#{label} must be a non-empty trimmed string" unless valid

      value
    end

    def revision!(revision)
      return revision if revision.is_a?(Integer) && !revision.negative?

      raise Error, "worker registry revision must be a non-negative integer"
    end

    def timestamp!(value, label)
      unless value.is_a?(String) && TIMESTAMP.match?(value)
        raise Error, "#{label} must use canonical UTC second precision"
      end

      parsed = Time.iso8601(value)
      raise Error, "#{label} must use canonical UTC second precision" unless parsed.utc.iso8601(0) == value

      parsed
    rescue ArgumentError
      raise Error, "#{label} must use canonical UTC second precision"
    end

    def time!(value, label)
      raise Error, "#{label} must be a Time" unless value.is_a?(Time)

      value.utc
    end

    def normalized_endpoint(value, label)
      nonempty!(value, label)
      uri = URI.parse(value)
      valid_path = uri.path.nil? || uri.path.empty? || uri.path == "/"
      valid = uri.is_a?(URI::HTTP) && uri.host && !uri.host.empty? && uri.userinfo.nil? &&
              uri.query.nil? && uri.fragment.nil? && valid_path
      raise Error, "#{label} must be an HTTP(S) origin" unless valid

      "#{uri.scheme.downcase}://#{uri.host.downcase}:#{uri.port}"
    rescue URI::InvalidURIError
      raise Error, "#{label} must be an HTTP(S) origin"
    end

    def labels!(labels, label)
      strings!(labels, "#{label}.labels")
      raise Error, "#{label}.labels must be unique" unless labels.uniq == labels
      raise Error, "#{label}.labels must be sorted" unless labels.sort == labels
    end

    def capabilities!(capabilities, label)
      exact_keys!(capabilities, CAPABILITY_KEYS, "#{label}.capabilities")
      nonempty!(capabilities.fetch("gpu_id"), "#{label}.capabilities.gpu_id", max: 256)
      ollama = capabilities.fetch("ollama")
      exact_keys!(ollama, OLLAMA_KEYS, "#{label}.capabilities.ollama")
      models = ollama.fetch("models")
      unless models.is_a?(Array) && !models.empty?
        raise Error, "#{label}.capabilities.ollama.models must be a nonempty array"
      end

      model_ids = models.each_with_index.map do |model, index|
        validate_model!(model, "#{label}.capabilities.ollama.models[#{index}]")
        model.fetch("model")
      end
      unless model_ids.uniq == model_ids
        raise Error, "#{label}.capabilities.ollama model identifiers must be unique"
      end

      sorted = models.sort_by { |model| canonical_model_key(model) }
      raise Error, "#{label}.capabilities.ollama.models must be sorted" unless sorted == models
    end

    def validate_model!(model, label)
      exact_keys!(model, MODEL_KEYS, label)
      nonempty!(model.fetch("model"), "#{label}.model", max: 256)
      digest = model.fetch("digest")
      unless digest.is_a?(String) && SHA256.match?(digest)
        raise Error, "#{label}.digest must be a lowercase SHA-256"
      end

      context = model.fetch("context_length")
      unless context.is_a?(Integer) && context.positive?
        raise Error, "#{label}.context_length must be a positive integer"
      end

      residency = model.fetch("fully_gpu_resident")
      raise Error, "#{label}.fully_gpu_resident must be boolean" unless [true, false].include?(residency)
    end

    def canonical_model_key(model)
      [
        model.fetch("model"), model.fetch("digest"), model.fetch("context_length"),
        model.fetch("fully_gpu_resident") ? 1 : 0
      ]
    end

    def strings!(value, label)
      valid = value.is_a?(Array) && value.all? do |item|
        item.is_a?(String) && !item.empty? && item == item.strip && !item.match?(/[[:cntrl:]]/)
      end
      raise Error, "#{label} must be an array of non-empty trimmed strings" unless valid
    end
  end
end

if $PROGRAM_NAME == __FILE__
  begin
    path, now_value = ARGV
    abort "usage: ruby conformance.rb SNAPSHOT.json [NOW_RFC3339]" unless path && ARGV.length <= 2

    now = now_value ? Time.iso8601(now_value) : Time.now.utc
    DynamicWorkerRegistryV01::Conformance.validate_bytes!(File.binread(path), now: now)
    puts "PASS #{path}"
  rescue DynamicWorkerRegistryV01::Conformance::Error, ArgumentError, Errno::ENOENT => e
    warn "FAIL #{path}: #{e.message}"
    exit 1
  end
end
