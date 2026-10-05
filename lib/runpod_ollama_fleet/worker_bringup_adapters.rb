# frozen_string_literal: true

require "digest"
require "fileutils"
require "json"
require "rbconfig"
require "time"
require_relative "../local_model_evaluation/process_supervisor"
require_relative "../local_model_evaluation/runpod_bootstrap"
require_relative "../local_model_evaluation/runpod_tunnels"
require_relative "capability_check"
require_relative "contract_v0_1"
require_relative "worker_bringup_reconciler"

module RunpodOllamaFleet
  # Production adapters from the durable reconciler protocol to the existing
  # tunnel, bootstrap, and capability implementations.
  module WorkerBringupAdapters
    class Base
      def initialize(requirement:, transition_guard:)
        @requirement = requirement
        @transition_guard = transition_guard
      end

      private

      attr_reader :requirement

      def fingerprint(identity)
        Digest::SHA256.hexdigest(JSON.generate(identity))
      end

      def guard!
        @transition_guard.call
      rescue StandardError => e
        raise WorkerBringupReconciler::RetryableTransitionError,
              "campaign authority no longer permits bring-up: #{e.message}"
      end

      def result(identity, status, evidence: nil, **extra)
        {
          "identity_sha256" => fingerprint(identity),
          "status" => status,
          "evidence" => evidence
        }.merge(extra.transform_keys(&:to_s))
      end
    end

    class Tunnel < Base
      def initialize(tunnels:, **keywords)
        super(**keywords)
        @tunnels = tunnels
      end

      def inspect(identity:)
        row = @tunnels.status(worker_indices: [identity.fetch("logical_worker_slot")]).fetch(0)
        return result(identity, "not_started") if row.fetch("process_status") == "missing"
        if row.fetch("process_status") == "stale_generation"
          return result(identity, "failed_retryable", evidence: { "detail" => row["detail"] })
        end
        validate_identity!(row, identity)
        if row.fetch("process_status") == "mismatch"
          raise WorkerBringupReconciler::TerminalTransitionError,
                "retained tunnel process does not match its owned process identity"
        end
        healthy = row.fetch("process_status") == "running" && row.fetch("health_status") == "healthy"
        result(identity, healthy ? "passed" : "failed_retryable", evidence: healthy && evidence(row, identity))
      rescue LocalModelEvaluation::RunpodTunnels::Error => e
        raise WorkerBringupReconciler::RetryableTransitionError, e.message
      end

      def ensure!(identity:)
        guard!
        @tunnels.start(worker_indices: [identity.fetch("logical_worker_slot")], wait_seconds: 0)
        inspect(identity:)
      rescue LocalModelEvaluation::RunpodTunnels::Error => e
        if e.message.include?("process identity does not match") || e.message.include?("pid identity does not match")
          raise WorkerBringupReconciler::TerminalTransitionError, e.message
        end
        result(identity, "failed_retryable", evidence: { "detail" => e.message })
      end

      private

      def validate_identity!(row, identity)
        expected = {
          "pod_id" => identity.fetch("provider_resource_id"),
          "worker_id" => identity.fetch("worker_id"),
          "generation_id" => identity.fetch("generation_id"),
          "endpoint" => identity.dig("tunnel_target", "ollama_endpoint")
        }
        expected.each do |field, value|
          next if row[field].to_s == value.to_s
          raise WorkerBringupReconciler::TerminalTransitionError,
                "retained tunnel #{field} belongs to another worker generation"
        end
      end

      def evidence(row, identity)
        {
          "worker_id" => identity.fetch("worker_id"),
          "generation_id" => identity.fetch("generation_id"),
          "provider_resource_id" => identity.fetch("provider_resource_id"),
          "endpoint" => row.fetch("endpoint")
        }
      end
    end

    class Bootstrap < Base
      LAUNCH_CONTRACT = "rpof-worker-bootstrap-launch/v0.1"

      def initialize(root:, repo_root:, fleet_state:, shared_store_path:, shared_source_model:,
                     process_supervisor: nil,
                     clock: nil, **keywords)
        super(**keywords)
        @root = File.expand_path(root)
        @repo_root = File.expand_path(repo_root)
        @fleet_state = fleet_state
        @shared_store_path = shared_store_path.to_s
        @shared_source_model = shared_source_model.to_s
        @process = process_supervisor || LocalModelEvaluation::ProcessSupervisor.new
        @clock = clock || -> { Time.now.utc }
      end

      def inspect(identity:, attempt:)
        return nil unless attempt

        record = bootstrap_record
        return from_bootstrap(record, identity, attempt) if matching_bootstrap?(record, identity, attempt)

        launch = launch_record(identity, attempt)
        return result(identity, "failed_terminal", attempt_id: attempt.fetch("attempt_id")) if launch.nil?
        if %w[waiting_for_fleet_bootstrap launch_blocked launch_failed].include?(launch["status"])
          return result(identity, "failed_retryable", attempt_id: attempt.fetch("attempt_id"))
        end
        unless launch["process_identity"]
          return result(identity, "failed_terminal", attempt_id: attempt.fetch("attempt_id"))
        end
        result(
          identity, "in_progress", attempt_id: attempt.fetch("attempt_id"),
          launch_identity: launch.fetch("process_identity")
        )
      rescue JSON::ParserError, SystemCallError, KeyError, ArgumentError, TypeError => e
        raise WorkerBringupReconciler::TerminalTransitionError,
              "bootstrap retained evidence is invalid: #{e.message}"
      end

      def start!(identity:, attempt:)
        guard!
        path = launch_path(identity, attempt)
        with_launch_lock do
          if another_bootstrap_running?(identity, path)
            write_launch(path, launch_document(identity, attempt, "waiting_for_fleet_bootstrap"))
            return result(identity, "failed_retryable", attempt_id: attempt.fetch("attempt_id"))
          end

          write_launch(path, launch_document(identity, attempt, "launching"))
          guard!
          command = bootstrap_command(identity, attempt)
          log_path = path.sub(/\.json\z/, ".log")
          FileUtils.mkdir_p(File.dirname(log_path))
          pid = File.open(log_path, "a", 0o600) do |log|
            @process.spawn(command:, chdir: @repo_root, output: log)
          end
          process_identity = @process.process_identity(pid:, command:)
          write_launch(path, launch_document(identity, attempt, "running").merge(
            "pid" => pid, "process_identity" => process_identity
          ))
          return result(
            identity, "in_progress", attempt_id: attempt.fetch("attempt_id"),
            launch_identity: process_identity
          )
        end
      rescue WorkerBringupReconciler::RetryableTransitionError
        if path && File.file?(path)
          write_launch(path, launch_document(identity, attempt, "launch_blocked"))
        end
        raise
      rescue StandardError => e
        write_launch(path, launch_document(identity, attempt, "launch_failed").merge("error" => e.message)) if path
        raise WorkerBringupReconciler::RetryableTransitionError, "bootstrap launch failed: #{e.message}"
      end

      private

      def bootstrap_command(identity, attempt)
        exact = requirement.ollama
        [
          RbConfig.ruby, File.join(@repo_root, "bin", "lme-runpod-bootstrap"),
          "--workers", identity.fetch("logical_worker_slot").to_s,
          "--model", exact.fetch("model"),
          "--expect-digest", "#{exact.fetch('model')}=#{exact.fetch('expected_digest')}",
          "--context", exact.fetch("required_context_length").to_s,
          "--copy-from-shared-store", @shared_store_path,
          "--shared-source-model", @shared_source_model,
          "--fleet", identity.fetch("profile_id"),
          "--local-state-root", @root,
          "--bringup-identity", fingerprint(identity),
          "--bringup-attempt", attempt.fetch("attempt_id"),
          "--model-requirement", requirement.fingerprint
        ]
      end

      def bootstrap_record
        fleet = @fleet_state.current
        return nil unless fleet
        root = @fleet_state.artifact_dir(fleet.fetch("fleet_id"), "bootstrap")
        pointer = File.join(root, "current")
        return nil unless File.file?(pointer)
        run_id = File.binread(pointer).strip
        return nil unless run_id.match?(/\A[A-Za-z0-9_.-]+\z/) && !run_id.include?("..")

        path = File.join(root, run_id, "bootstrap.json")
        File.file?(path) ? JSON.parse(File.binread(path)) : nil
      end

      def matching_bootstrap?(record, identity, attempt)
        record && record["bringup_identity_sha256"] == fingerprint(identity) &&
          record["bringup_attempt_id"] == attempt.fetch("attempt_id") &&
          record["model_requirement_sha256"] == requirement.fingerprint
      end

      def from_bootstrap(record, identity, attempt)
        worker = Array(record.fetch("workers")).find do |row|
          Integer(row.fetch("index")) == Integer(identity.fetch("logical_worker_slot"))
        end
        raise KeyError, "bound bootstrap worker evidence is missing" unless worker
        validate_worker!(worker, identity)
        case worker.fetch("status")
        when "passed"
          result(identity, "passed", attempt_id: attempt.fetch("attempt_id"),
                 evidence: bootstrap_evidence(worker, identity))
        when "failed"
          result(identity, "failed_retryable", attempt_id: attempt.fetch("attempt_id"))
        when "interrupted", "aborted"
          result(identity, "failed_terminal", attempt_id: attempt.fetch("attempt_id"))
        else
          launch = launch_record(identity, attempt)
          process_identity = launch && launch["process_identity"]
          return result(identity, "failed_terminal", attempt_id: attempt.fetch("attempt_id")) unless process_identity

          result(identity, "in_progress", attempt_id: attempt.fetch("attempt_id"),
                 launch_identity: process_identity)
        end
      end

      def validate_worker!(worker, identity)
        {
          "pod_id" => identity.fetch("provider_resource_id"),
          "worker_id" => identity.fetch("worker_id"),
          "generation_id" => identity.fetch("generation_id")
        }.each do |field, expected|
          raise KeyError, "bootstrap #{field} is stale" unless worker.fetch(field).to_s == expected.to_s
        end
      end

      def bootstrap_evidence(worker, identity)
        exact = requirement.ollama
        observed = worker.fetch("provenance").fetch("models").fetch(exact.fetch("model"))
        {
          "worker_id" => identity.fetch("worker_id"),
          "generation_id" => identity.fetch("generation_id"),
          "provider_resource_id" => identity.fetch("provider_resource_id"),
          "model" => exact.fetch("model"),
          "digest" => observed.fetch("digest").to_s.downcase,
          "context_length" => Integer(observed.fetch("context_length")),
          "fully_gpu_resident" => observed.fetch("fully_gpu_resident"),
          "gpu_id" => worker.fetch("provenance").dig("gpu", "name"),
          "observed_at_utc" => worker.fetch("finished_at_utc")
        }
      end

      def launch_path(identity, attempt)
        File.join(
          @root, "worker-bringup-launches-v0.1", identity.fetch("worker_id"),
          "#{Digest::SHA256.hexdigest(attempt.fetch('attempt_id').to_s)}.json"
        )
      end

      def launch_record(identity, attempt)
        path = launch_path(identity, attempt)
        return nil unless File.file?(path)
        document = JSON.parse(File.binread(path))
        expected = launch_document(identity, attempt, document.fetch("status")).except("updated_at_utc")
        expected.each do |field, value|
          raise KeyError, "bootstrap launch #{field} mismatch" unless document[field] == value
        end
        Time.iso8601(document.fetch("updated_at_utc"))
        document
      end

      def launch_document(identity, attempt, status)
        {
          "contract_version" => LAUNCH_CONTRACT,
          "identity_sha256" => fingerprint(identity),
          "attempt_id" => attempt.fetch("attempt_id"),
          "model_requirement_sha256" => requirement.fingerprint,
          "profile_id" => identity.fetch("profile_id"),
          "worker_id" => identity.fetch("worker_id"),
          "generation_id" => identity.fetch("generation_id"),
          "provider_resource_id" => identity.fetch("provider_resource_id"),
          "status" => status,
          "updated_at_utc" => timestamp
        }
      end

      def write_launch(path, document)
        FileUtils.mkdir_p(File.dirname(path))
        temporary = "#{path}.tmp.#{$$}.#{Thread.current.object_id}"
        File.open(temporary, File::WRONLY | File::CREAT | File::TRUNC, 0o600) do |file|
          file.write(JSON.pretty_generate(document) + "\n")
          file.flush
          file.fsync
        end
        File.rename(temporary, path)
      ensure
        File.delete(temporary) if defined?(temporary) && temporary && File.exist?(temporary)
      end

      def with_launch_lock
        root = File.join(@root, "worker-bringup-launches-v0.1")
        FileUtils.mkdir_p(root)
        File.open(File.join(root, ".lock"), File::RDWR | File::CREAT, 0o600) do |lock|
          lock.flock(File::LOCK_EX)
          yield
        end
      end

      def another_bootstrap_running?(identity, own_path)
        pattern = File.join(@root, "worker-bringup-launches-v0.1", "*", "*.json")
        Dir.glob(pattern).any? do |path|
          next false if path == own_path

          document = JSON.parse(File.binread(path))
          next false unless document["contract_version"] == LAUNCH_CONTRACT
          next false unless document["profile_id"] == identity.fetch("profile_id")
          next false unless document["status"] == "running" && document["process_identity"].is_a?(Hash)

          @process.same_process?(document.fetch("process_identity"))
        rescue JSON::ParserError, SystemCallError, KeyError, ArgumentError, TypeError
          false
        end
      end

      def timestamp
        value = @clock.call
        value = Time.parse(value.to_s) unless value.is_a?(Time)
        value.utc.iso8601
      end
    end

    class Capability < Base
      def initialize(checker:, **keywords)
        super(**keywords)
        @checker = checker
      end

      def inspect(identity:)
        check(identity)
      end

      def verify!(identity:)
        guard!
        check(identity)
      end

      private

      def check(identity)
        checked = @checker.check(request(identity))
        return result(identity, "failed_retryable", evidence: { "diagnostics" => checked["diagnostics"] }) unless checked["ready"]

        model = checked.fetch("capabilities").fetch("models").fetch(0)
        result(identity, "passed", evidence: {
          "worker_id" => identity.fetch("worker_id"),
          "generation_id" => identity.fetch("generation_id"),
          "provider_resource_id" => identity.fetch("provider_resource_id"),
          "model" => model.fetch("name"),
          "digest" => model.fetch("digest").downcase,
          "context_length" => model.fetch("context_length"),
          "fully_gpu_resident" => model.fetch("fully_gpu_resident"),
          "gpu_id" => checked.fetch("capabilities").fetch("gpu_id")
        })
      rescue KeyError, ArgumentError, TypeError => e
        raise WorkerBringupReconciler::TerminalTransitionError,
              "capability result is invalid: #{e.message}"
      end

      def request(identity)
        exact = requirement.ollama
        requirements = {
          "models" => [{ "name" => exact.fetch("model"), "expected_digest" => exact.fetch("expected_digest") }],
          "required_context_length" => exact.fetch("required_context_length"),
          "require_fully_gpu_resident" => true
        }
        requirements["required_gpu_id"] = exact.fetch("required_gpu_id") if exact.key?("required_gpu_id")
        {
          "contract_version" => ContractV01::CAPABILITY_REQUEST_VERSION,
          "fleet_key" => identity.fetch("profile_id"),
          "worker_selector" => { "mode" => "indices", "indices" => [identity.fetch("logical_worker_slot")] },
          "requirements" => requirements
        }
      end
    end
  end
end
