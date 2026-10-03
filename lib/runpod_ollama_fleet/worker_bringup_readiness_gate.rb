# frozen_string_literal: true

require "digest"
require "json"
require "uri"
require_relative "worker_bringup_state"

module RunpodOllamaFleet
  # The dynamic registry may publish READY only when the exact current worker
  # generation has completed the durable FO-11 prerequisite state machine.
  class WorkerBringupReadinessGate
    class Error < StandardError; end

    def initialize(root:, campaign_identity_sha256:, requirements:)
      @state = WorkerBringupState.new(root:)
      @campaign_identity_sha256 = campaign_identity_sha256.to_s
      @requirements = requirements.to_h.transform_keys(&:to_s)
    end

    def satisfied?(fleet_key:, worker:)
      requirement = @requirements.fetch(fleet_key.to_s) do
        raise Error, "no exact model requirement is bound to profile #{fleet_key.inspect}"
      end
      document = @state.read_current(worker_id: worker.fetch("worker_id"))
      return false unless document

      identity = document.fetch("identity")
      return false unless Digest::SHA256.hexdigest(JSON.generate(identity)) == document.fetch("identity_sha256")
      expected = {
        "campaign_identity_sha256" => @campaign_identity_sha256,
        "profile_id" => fleet_key.to_s,
        "logical_worker_slot" => Integer(worker.fetch("index")),
        "worker_generation" => Integer(worker.fetch("generation")),
        "provider_resource_id" => worker.fetch("pod_id").to_s,
        "worker_id" => worker.fetch("worker_id").to_s,
        "generation_id" => worker.fetch("generation_id").to_s,
        "model_requirement_sha256" => requirement.fingerprint
      }
      expected.each { |field, value| return false unless identity[field] == value }
      return false unless identity.dig("tunnel_target", "host") == worker.fetch("host").to_s
      return false unless identity.dig("tunnel_target", "ssh_port") == Integer(worker.fetch("ssh_port"))
      return false unless identity.dig("tunnel_target", "ollama_endpoint") == endpoint(worker.fetch("local_ollama_url"))
      return false unless document.fetch("model_requirement") == requirement.document
      return false unless document.fetch("readiness_prerequisites_satisfied") == true
      return false unless document.fetch("overall_status") == "prerequisites_passed"

      WorkerBringupState::STAGES.all? { |stage| document.dig(stage, "status") == "passed" }
    rescue WorkerBringupState::Error, KeyError, ArgumentError, TypeError, URI::InvalidURIError => e
      raise Error, "worker bring-up readiness evidence is invalid: #{e.message}"
    end

    private

    def endpoint(value)
      uri = URI.parse(value.to_s)
      valid_path = uri.path.nil? || uri.path.empty? || uri.path == "/"
      unless uri.is_a?(URI::HTTP) && uri.host && !uri.host.empty? && uri.userinfo.nil? &&
             uri.query.nil? && uri.fragment.nil? && valid_path
        raise Error, "worker Ollama endpoint is invalid"
      end
      "#{uri.scheme.downcase}://#{uri.host.downcase}:#{uri.port}"
    end
  end
end
