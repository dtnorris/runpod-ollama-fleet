# frozen_string_literal: true

require "securerandom"
require "time"
require_relative "worker_bringup_identity"
require_relative "worker_bringup_state"

module RunpodOllamaFleet
  # Advances one generation through tunnel, bootstrap, and capability evidence.
  # It deliberately stops before registry publication.
  class WorkerBringupReconciler
    class Error < StandardError; end
    class RetryableTransitionError < Error; end
    class TerminalTransitionError < Error; end

    def initialize(root:, tunnel:, bootstrap:, capability:, process_inspector:, clock: nil,
                   attempt_id_generator: nil)
      @state = WorkerBringupState.new(root:, clock:)
      @tunnel = tunnel
      @bootstrap = bootstrap
      @capability = capability
      @process_inspector = process_inspector
      @clock = clock || -> { Time.now.utc }
      @attempt_id_generator = attempt_id_generator || -> { SecureRandom.uuid }
    end

    def reconcile!(campaign_identity_sha256:, profile:, worker:, generation_id:, requirement:,
                   retry_bootstrap: false)
      identity = WorkerBringupIdentity.new(
        campaign_identity_sha256:, profile:, worker:, generation_id:, requirement:
      )
      @state.with_current(identity) do |document, checkpoint|
        reconcile_tunnel(identity, document, checkpoint)
        if stage_passed?(document, "tunnel")
          reconcile_bootstrap(identity, document, checkpoint, retry_bootstrap:)
        end
        if stage_passed?(document, "bootstrap")
          reconcile_capability(identity, document, checkpoint)
        end
        finalize(document)
      end
    rescue WorkerBringupIdentity::Error, WorkerBringupState::Error => e
      raise Error, e.message
    end

    private

    def reconcile_tunnel(identity, document, checkpoint)
      observed = invoke(@tunnel, :inspect, identity: identity.document)
      result = if observed.nil? || %w[not_started failed_retryable].include?(observed["status"])
                 invoke(@tunnel, :ensure!, identity: identity.document)
               else
                 observed
               end
      update_stage(document, "tunnel", validate_result(result, identity, "tunnel"))
      checkpoint.call
    rescue RetryableTransitionError => e
      fail_stage(document, "tunnel", "failed_retryable", e.message, checkpoint)
    rescue TerminalTransitionError => e
      fail_stage(document, "tunnel", "failed_terminal", e.message, checkpoint)
    end

    def reconcile_bootstrap(identity, document, checkpoint, retry_bootstrap:)
      stage = document.fetch("bootstrap")
      attempt = stage["attempt"]
      observed = invoke(@bootstrap, :inspect, identity: identity.document, attempt: attempt)
      if observed
        result = validate_result(observed, identity, "bootstrap")
        verify_attempt!(result, attempt) if attempt
        update_bootstrap(document, result)
        checkpoint.call
        return classify_retained_process(document, checkpoint) if result.fetch("status") == "in_progress"
        return unless result.fetch("status") == "not_started" ||
                      (result.fetch("status") == "failed_retryable" && retry_bootstrap)
      end

      if stage.fetch("status") == "in_progress"
        fail_stage(document, "bootstrap", "failed_terminal",
                   "bootstrap outcome is ambiguous and no owned process/evidence can be adopted", checkpoint)
        return
      end
      return if stage.fetch("status") == "failed_terminal"
      return if stage.fetch("status") == "failed_retryable" && !retry_bootstrap

      attempt = {
        "attempt_id" => @attempt_id_generator.call.to_s,
        "launch_identity" => nil,
        "created_at_utc" => timestamp
      }
      raise TerminalTransitionError, "bootstrap attempt identity is empty" if attempt.fetch("attempt_id").empty?
      stage["attempt"] = attempt
      stage["status"] = "in_progress"
      stage["evidence"] = nil
      checkpoint.call

      result = validate_result(
        invoke(@bootstrap, :start!, identity: identity.document, attempt: attempt),
        identity,
        "bootstrap"
      )
      verify_attempt!(result, attempt)
      update_bootstrap(document, result)
      checkpoint.call
    rescue RetryableTransitionError => e
      fail_stage(document, "bootstrap", "failed_retryable", e.message, checkpoint)
    rescue TerminalTransitionError => e
      fail_stage(document, "bootstrap", "failed_terminal", e.message, checkpoint)
    end

    def reconcile_capability(identity, document, checkpoint)
      observed = invoke(@capability, :inspect, identity: identity.document)
      result = if observed.nil? || %w[not_started failed_retryable].include?(observed["status"])
                 invoke(@capability, :verify!, identity: identity.document)
               else
                 observed
               end
      result = validate_result(result, identity, "capability")
      validate_capability_evidence!(result.fetch("evidence"), identity) if result.fetch("status") == "passed"
      update_stage(document, "capability", result)
      checkpoint.call
    rescue RetryableTransitionError => e
      fail_stage(document, "capability", "failed_retryable", e.message, checkpoint)
    rescue TerminalTransitionError => e
      fail_stage(document, "capability", "failed_terminal", e.message, checkpoint)
    end

    def classify_retained_process(document, checkpoint)
      attempt = document.dig("bootstrap", "attempt")
      launch_identity = attempt && attempt["launch_identity"]
      unless launch_identity
        fail_stage(document, "bootstrap", "failed_terminal",
                   "bootstrap launch identity is missing; refusing an ambiguous relaunch", checkpoint)
        return
      end
      return if @process_inspector.same_process?(launch_identity)

      fail_stage(document, "bootstrap", "failed_terminal",
                 "owned bootstrap process vanished without durable terminal evidence", checkpoint)
    rescue KeyError, ArgumentError, TypeError => e
      fail_stage(document, "bootstrap", "failed_terminal",
                 "bootstrap launch identity is invalid: #{e.message}", checkpoint)
    end

    def validate_result(result, identity, stage)
      raise TerminalTransitionError, "#{stage} reconciler returned no result" unless result.is_a?(Hash)
      unless result["identity_sha256"] == identity.sha256
        raise TerminalTransitionError, "#{stage} evidence belongs to another bring-up generation"
      end
      status = result["status"]
      unless WorkerBringupState::STAGE_STATUSES.include?(status) && status != "stale"
        raise TerminalTransitionError, "#{stage} reconciler returned invalid status"
      end
      validate_tunnel_evidence!(result.fetch("evidence"), identity) if stage == "tunnel" && status == "passed"
      validate_bootstrap_evidence!(result.fetch("evidence"), identity) if stage == "bootstrap" && status == "passed"
      validate_launch_identity!(result.fetch("launch_identity")) if stage == "bootstrap" && status == "in_progress"
      result
    end

    def verify_attempt!(result, attempt)
      unless result["attempt_id"] == attempt.fetch("attempt_id")
        raise TerminalTransitionError, "bootstrap evidence belongs to another attempt"
      end
    end

    def validate_capability_evidence!(evidence, identity)
      raise TerminalTransitionError, "capability evidence is missing" unless evidence.is_a?(Hash)
      bringup = identity.document
      required = identity.requirement.ollama
      comparisons = {
        "worker_id" => bringup.fetch("worker_id"),
        "generation_id" => bringup.fetch("generation_id"),
        "provider_resource_id" => bringup.fetch("provider_resource_id"),
        "model" => required.fetch("model"),
        "digest" => required.fetch("expected_digest"),
        "context_length" => required.fetch("required_context_length"),
        "fully_gpu_resident" => true
      }
      comparisons["gpu_id"] = required.fetch("required_gpu_id") if required.key?("required_gpu_id")
      comparisons.each do |field, expected|
        next if evidence[field] == expected
        raise TerminalTransitionError, "capability evidence #{field} does not match exact model requirement"
      end
    end

    def validate_tunnel_evidence!(evidence, identity)
      raise TerminalTransitionError, "tunnel evidence is missing" unless evidence.is_a?(Hash)
      expected = identity.document
      comparisons = {
        "worker_id" => expected.fetch("worker_id"),
        "generation_id" => expected.fetch("generation_id"),
        "provider_resource_id" => expected.fetch("provider_resource_id"),
        "endpoint" => expected.dig("tunnel_target", "ollama_endpoint")
      }
      comparisons.each do |field, value|
        next if evidence[field] == value
        raise TerminalTransitionError, "tunnel evidence #{field} does not match bring-up identity"
      end
    end

    def validate_bootstrap_evidence!(evidence, identity)
      raise TerminalTransitionError, "bootstrap evidence is missing" unless evidence.is_a?(Hash)
      expected = identity.document
      comparisons = {
        "worker_id" => expected.fetch("worker_id"),
        "generation_id" => expected.fetch("generation_id"),
        "provider_resource_id" => expected.fetch("provider_resource_id")
      }
      comparisons.each do |field, value|
        next if evidence[field] == value
        raise TerminalTransitionError, "bootstrap evidence #{field} does not match bring-up identity"
      end
      validate_capability_evidence!(evidence, identity)
      Time.iso8601(evidence.fetch("observed_at_utc").to_s)
    rescue ArgumentError
      raise TerminalTransitionError, "bootstrap evidence observed_at_utc is invalid"
    end

    def validate_launch_identity!(identity)
      raise TerminalTransitionError, "bootstrap process launch identity is missing" unless identity.is_a?(Hash)
      %w[pid process_group_id].each do |field|
        value = Integer(identity.fetch(field))
        raise TerminalTransitionError, "bootstrap process #{field} must be positive" unless value.positive?
      end
      token = identity.fetch("start_token").to_s
      raise TerminalTransitionError, "bootstrap process start token is missing" if token.empty?
      command_sha = identity.fetch("command_sha256").to_s
      unless command_sha.match?(/\A[0-9a-f]{64}\z/)
        raise TerminalTransitionError, "bootstrap process command fingerprint is invalid"
      end
    rescue KeyError, ArgumentError, TypeError => e
      raise TerminalTransitionError, "bootstrap process launch identity is invalid: #{e.message}"
    end

    def update_bootstrap(document, result)
      update_stage(document, "bootstrap", result)
      launch_identity = result["launch_identity"]
      document.fetch("bootstrap").fetch("attempt")["launch_identity"] = launch_identity if launch_identity
    end

    def update_stage(document, name, result)
      stage = document.fetch(name)
      stage["status"] = result.fetch("status")
      stage["evidence"] = result["evidence"]
      stage["updated_at_utc"] = timestamp
      stage.delete("error")
    end

    def fail_stage(document, name, status, message, checkpoint)
      stage = document.fetch(name)
      stage["status"] = status
      stage["error"] = message
      stage["updated_at_utc"] = timestamp
      checkpoint.call
    end

    def finalize(document)
      passed = WorkerBringupState::STAGES.all? { |stage| stage_passed?(document, stage) }
      document["readiness_prerequisites_satisfied"] = passed
      document["overall_status"] = if passed
                                     "prerequisites_passed"
                                   elsif WorkerBringupState::STAGES.any? do |stage|
                                           document.dig(stage, "status") == "failed_terminal"
                                         end
                                     "failed_terminal"
                                   elsif WorkerBringupState::STAGES.any? do |stage|
                                           document.dig(stage, "status") == "failed_retryable"
                                         end
                                     "failed_retryable"
                                   else
                                     "in_progress"
                                   end
    end

    def stage_passed?(document, stage)
      document.dig(stage, "status") == "passed"
    end

    def invoke(adapter, method, **keywords)
      unless adapter.respond_to?(method)
        raise TerminalTransitionError, "bring-up adapter does not implement ##{method}"
      end
      adapter.public_send(method, **keywords)
    end

    def timestamp
      value = @clock.call
      value = Time.parse(value.to_s) unless value.is_a?(Time)
      value.utc.iso8601
    end
  end
end
