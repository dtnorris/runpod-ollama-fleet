# frozen_string_literal: true

require "digest"
require "json"
require "uri"
require_relative "ollama_capability_request"

module RunpodOllamaFleet
  # Immutable identity for one concrete worker bring-up. Every piece of
  # retained evidence is scoped to this fingerprint.
  class WorkerBringupIdentity
    CONTRACT_VERSION = "rpof-worker-bringup-identity/v0.1"
    LEGACY_REQUEST_CLASS = "RunpodOllamaFleet::ModelRequirement"
    LEGACY_REQUEST_VERSION = "adventurefinder-model-requirement/v0.1"
    LEGACY_REQUEST_ERROR = "RunpodOllamaFleet::ModelRequirement::Error"
    SHA256 = /\A[0-9a-f]{64}\z/
    ID = /\A[A-Za-z0-9][A-Za-z0-9._-]{0,255}\z/

    class Error < StandardError; end

    attr_reader :document, :sha256, :capability_request

    def initialize(campaign_identity_sha256:, profile:, worker:, generation_id:, capability_request:)
      @capability_request = capability_request
      validate_capability_request!(profile, worker)
      @document = build_document(campaign_identity_sha256, profile, worker, generation_id)
      @sha256 = Digest::SHA256.hexdigest(JSON.generate(@document))
      deep_freeze(@document)
      freeze
    rescue KeyError, ArgumentError, TypeError, URI::InvalidURIError => e
      raise Error, "invalid worker bring-up identity: #{e.message}"
    end

    private

    def validate_capability_request!(profile, worker)
      unless capability_request.is_a?(OllamaCapabilityRequest) || legacy_request?
        raise Error, "worker bring-up requires an exact Ollama capability request"
      end
      gpu_id = nonempty(worker.fetch("gpu_id"), "worker GPU identity")
      capability_request.validate_profile!(
        profile:,
        hardware: { "qualified_gpu_ids" => [gpu_id] }
      )
    rescue OllamaCapabilityRequest::Error => e
      raise Error, e.message
    rescue StandardError => e
      raise unless legacy_request? && e.class.name == LEGACY_REQUEST_ERROR

      raise Error, e.message
    end

    def legacy_request?
      capability_request.class.name == LEGACY_REQUEST_CLASS &&
        capability_request.respond_to?(:document) &&
        capability_request.document.is_a?(Hash) &&
        capability_request.document["contract_version"] == LEGACY_REQUEST_VERSION
    end

    def build_document(campaign_identity_sha256, profile, worker, generation_id)
      campaign_sha = campaign_identity_sha256.to_s
      raise Error, "campaign identity must be a lowercase SHA-256" unless campaign_sha.match?(SHA256)

      worker_generation = nonempty(worker.fetch("generation_id"), "worker generation identity")
      requested_generation = nonempty(generation_id, "requested generation identity")
      unless requested_generation == worker_generation
        raise Error, "requested generation does not match durable worker generation"
      end

      endpoint = normalized_endpoint(worker.fetch("local_ollama_url"))
      {
        "contract_version" => CONTRACT_VERSION,
        "campaign_identity_sha256" => campaign_sha,
        "profile_id" => nonempty(profile.fetch("profile_id"), "profile identity"),
        "logical_worker_slot" => positive_integer(worker.fetch("index"), "logical worker slot"),
        "worker_generation" => positive_integer(worker.fetch("generation"), "worker generation"),
        "provider_resource_id" => nonempty(worker.fetch("pod_id"), "provider resource identity"),
        "worker_id" => identifier(worker.fetch("worker_id"), "worker identity"),
        "generation_id" => identifier(worker_generation, "worker generation identity"),
        "tunnel_target" => {
          "host" => nonempty(worker.fetch("host"), "tunnel host"),
          "ssh_port" => positive_integer(worker.fetch("ssh_port"), "tunnel SSH port"),
          "ollama_endpoint" => endpoint
        },
        # Historical v0.1 field name; the value is the supplied request's
        # fingerprint. On the generic path this is the WLO semantic fingerprint.
        "model_requirement_sha256" => capability_request.fingerprint
      }
    end

    def identifier(value, label)
      result = nonempty(value, label)
      raise Error, "#{label} has invalid syntax" unless result.match?(ID)
      result
    end

    def nonempty(value, label)
      result = value.to_s
      if result.empty? || result != result.strip || result.match?(/[[:cntrl:]]/)
        raise Error, "#{label} must be a non-empty trimmed string"
      end
      result
    end

    def positive_integer(value, label)
      number = Integer(value)
      raise Error, "#{label} must be positive" unless number.positive?
      number
    end

    def normalized_endpoint(value)
      uri = URI.parse(nonempty(value, "Ollama endpoint"))
      valid_path = uri.path.nil? || uri.path.empty? || uri.path == "/"
      unless uri.is_a?(URI::HTTP) && uri.host && !uri.host.empty? && uri.userinfo.nil? &&
             uri.query.nil? && uri.fragment.nil? && valid_path
        raise Error, "Ollama endpoint must be an HTTP(S) origin"
      end
      "#{uri.scheme.downcase}://#{uri.host.downcase}:#{uri.port}"
    end

    def deep_freeze(value)
      value.each { |key, item| deep_freeze(key); deep_freeze(item) } if value.is_a?(Hash)
      value.each { |item| deep_freeze(item) } if value.is_a?(Array)
      value.freeze
    end
  end
end
