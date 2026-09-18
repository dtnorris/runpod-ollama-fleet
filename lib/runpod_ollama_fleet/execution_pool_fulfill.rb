# frozen_string_literal: true

require "json"
require "open3"
require "tempfile"
require_relative "contract_v0_1"
require_relative "execution_pool_hardware"

module RunpodOllamaFleet
  class ExecutionPoolFulfill
    class Error < StandardError; end

    class SystemCommandRunner
      def initialize(repo_root:, out: $stdout)
        @repo_root = File.expand_path(repo_root)
        @out = out
      end

      def run(argv, env: {})
        status = nil
        Open3.popen2e(env, *argv, chdir: @repo_root) do |stdin, output, wait|
          stdin.close
          output.each { |line| @out.write(line) }
          status = wait.value
        end
        status.exitstatus
      rescue SystemCallError => e
        raise Error, "could not execute #{argv.first}: #{e.message}"
      end
    end

    def initialize(repo_root:, executable:, hardware:, command_runner: nil, out: $stdout)
      @repo_root = File.expand_path(repo_root)
      @executable = File.expand_path(executable)
      @hardware = hardware
      @out = out
      @runner = command_runner || SystemCommandRunner.new(repo_root: @repo_root, out:)
    end

    def run(request, dry_run: false, assume_yes: false)
      ContractV01.validate_execution_pool_request!(request)
      requirements = request.fetch("requirements")
      capacity = request.fetch("capacity")
      profile = @hardware.profile_for(requirements.fetch("ollama_model"))
      handle = execution_handle(request)

      capacity_result = invoke_capacity(
        handle:,
        profile:,
        capacity:,
        dry_run:,
        assume_yes:
      )

      if dry_run
        return result_document(
          request:,
          handle:,
          ready: false,
          status: capacity_result.fetch("status") == "planned" ? "planned" : "unavailable",
          capacity_result:,
          worker_indices: [],
          profile:,
          detail: capacity_result.fetch("stopped_reason"),
          runtime_alias_evidence: [],
          capability: nil
        )
      end

      initial_workers = Integer(capacity_result.fetch("initial_workers"))
      final_workers = Integer(capacity_result.fetch("final_workers"))
      minimum_workers = Integer(capacity.fetch("minimum_workers"))

      if final_workers < minimum_workers
        cleanup_error = cleanup_new_capacity(handle, initial_workers, final_workers)
        detail = capacity_result.fetch("stopped_reason").to_s
        detail = "#{detail}; cleanup failed: #{cleanup_error}" if cleanup_error
        return result_document(
          request:,
          handle:,
          ready: false,
          status: "unfulfilled",
          capacity_result:,
          worker_indices: [],
          profile:,
          detail:,
          runtime_alias_evidence: [],
          capability: nil
        )
      end

      worker_indices = (1..final_workers).to_a
      begin
        invoke_keep(handle)
        invoke_bootstrap(handle, worker_indices, requirements, profile)
        invoke_tunnels(handle, worker_indices)
        alias_evidence = invoke_runtime_alias(handle, worker_indices, requirements, profile)
        capability = invoke_capability(handle, worker_indices, requirements)
        unless capability.fetch("ready")
          failures = Array(capability["diagnostics"]).select { |row| row["status"] == "FAIL" }
          detail = failures.map { |row| "#{row['code']}: #{row['detail']}" }.join("; ")
          raise Error, "execution capability check failed: #{detail.empty? ? 'not ready' : detail}"
        end
        selected = Array(capability.fetch("selected_worker_indices")).map { |value| Integer(value) }.sort
        unless selected == worker_indices
          raise Error,
                "capability check returned workers #{selected.inspect}, expected #{worker_indices.inspect}"
        end

        status = final_workers >= Integer(capacity.fetch("desired_workers")) ? "ready" : "partial_ready"
        result_document(
          request:,
          handle:,
          ready: true,
          status:,
          capacity_result:,
          worker_indices:,
          profile:,
          detail: status == "ready" ? "desired execution capacity is ready" : "minimum execution capacity is ready",
          runtime_alias_evidence: alias_evidence,
          capability:
        )
      rescue StandardError => e
        cleanup_error = cleanup_new_capacity(handle, initial_workers, final_workers)
        detail = e.message.to_s
        detail = "#{detail}; cleanup failed: #{cleanup_error}" if cleanup_error
        result_document(
          request:,
          handle:,
          ready: false,
          status: "failed",
          capacity_result:,
          worker_indices: [],
          profile:,
          detail:,
          runtime_alias_evidence: [],
          capability: nil
        )
      end
    rescue ContractV01::Error, ExecutionPoolHardware::Error => e
      raise Error, e.message
    rescue KeyError, ArgumentError, TypeError => e
      raise Error, "invalid execution-pool fulfillment request: #{e.message}"
    end

    private

    def execution_handle(request)
      slug = request.fetch("pool_id").to_s.downcase.gsub(/[^a-z0-9_-]+/, "-")
      slug = slug.gsub(/\A[-_]+|[-_]+\z/, "")
      slug = "pool" if slug.empty?
      "ep-#{slug[0, 16]}-#{request.fetch('plan_sha256')[0, 10].downcase}"
    end

    def invoke_capacity(handle:, profile:, capacity:, dry_run:, assume_yes:)
      with_tempfile("capacity-result") do |path|
        argv = [
          @executable, "fulfill",
          "--fleet", handle,
          "--target-workers", capacity.fetch("desired_workers").to_s,
          "--minimum-workers", capacity.fetch("minimum_workers").to_s,
          "--cloud", profile.cloud,
          "--global-volume-id", profile.global_volume_id,
          "--max-hourly-per-worker", capacity.fetch("max_pool_hourly_usd").to_s,
          "--max-hourly-usd", capacity.fetch("max_pool_hourly_usd").to_s,
          "--max-total-hourly-usd", capacity.fetch("max_total_hourly_usd").to_s,
          "--output", path
        ]
        profile.gpu_ids.each { |gpu_id| argv.concat(["--gpu", gpu_id]) }
        argv << "--dry-run" if dry_run
        argv << "--yes" if !dry_run && assume_yes
        if !dry_run && !assume_yes
          raise Error, "paid execution-pool fulfillment requires explicit assume_yes authorization"
        end

        exit_status = @runner.run(argv)
        document = read_json_result(path, "capacity fulfillment")
        unless document["contract_version"] == "rpof-capacity-fulfillment-result/v0.1"
          raise Error, "unsupported capacity fulfillment result version: #{document['contract_version'].inspect}"
        end
        if exit_status != 0 && !%w[unfulfilled unavailable].include?(document["status"])
          raise Error, "capacity fulfillment failed with exit #{exit_status}: #{document['stopped_reason']}"
        end
        document
      end
    end

    def invoke_keep(handle)
      exit_status = @runner.run([@executable, "keep", handle])
      raise Error, "could not reopen execution handle #{handle} for new work" unless exit_status.zero?
    end

    def invoke_bootstrap(handle, worker_indices, requirements, profile)
      shared_model = profile.shared_model
      digest = requirements.fetch("expected_digest")
      argv = [
        @executable, "bootstrap",
        "--fleet", handle,
        "--workers", worker_indices.join(","),
        "--model", shared_model,
        "--expect-digest", "#{shared_model}=#{digest}",
        "--copy-from-shared-store", profile.ollama_store_path,
        "--context", requirements.fetch("required_context_length").to_s
      ]
      exit_status = @runner.run(argv)
      raise Error, "model bootstrap failed with exit #{exit_status}" unless exit_status.zero?
    end

    def invoke_tunnels(handle, worker_indices)
      exit_status = @runner.run(
        [@executable, "tunnels", "start", "--workers", worker_indices.join(",")],
        env: { "LME_RUNPOD_FLEET" => handle }
      )
      raise Error, "tunnel startup failed with exit #{exit_status}" unless exit_status.zero?
    end

    def invoke_runtime_alias(handle, worker_indices, requirements, profile)
      with_tempfile("runtime-alias-result") do |path|
        argv = [
          @executable, "runtime-alias",
          "--fleet", handle,
          "--workers", worker_indices.join(","),
          "--source-model", profile.shared_model,
          "--runtime-model", requirements.fetch("ollama_model"),
          "--expect-digest", requirements.fetch("expected_digest"),
          "--context", requirements.fetch("required_context_length").to_s,
          "--output", path
        ]
        exit_status = @runner.run(argv)
        document = read_json_result(path, "runtime alias")
        unless document["contract_version"] == "rpof-runtime-alias-result/v0.1"
          raise Error, "unsupported runtime alias result version: #{document['contract_version'].inspect}"
        end
        raise Error, "runtime alias verification failed with exit #{exit_status}" unless exit_status.zero? && document["ready"] == true
        Array(document.fetch("workers"))
      end
    end

    def invoke_capability(handle, worker_indices, requirements)
      request = {
        "contract_version" => ContractV01::CAPABILITY_REQUEST_V2_VERSION,
        "fleet_key" => handle,
        "worker_selector" => { "mode" => "indices", "indices" => worker_indices },
        "requirements" => {
          "models" => [{
            "name" => requirements.fetch("ollama_model"),
            "expected_digest" => requirements.fetch("expected_digest")
          }],
          "required_context_length" => requirements.fetch("required_context_length"),
          "require_fully_gpu_resident" => true
        }
      }
      with_json_request(request) do |request_path|
        with_tempfile("capability-result") do |result_path|
          exit_status = @runner.run([
            @executable, "capability-check",
            "--request", request_path,
            "--output", result_path
          ])
          document = read_json_result(result_path, "capability check")
          unless document["contract_version"] == ContractV01::CAPABILITY_RESULT_VERSION
            raise Error, "unsupported capability result version: #{document['contract_version'].inspect}"
          end
          if exit_status != 0 && document["ready"] == true
            raise Error, "capability-check exited #{exit_status} despite ready result"
          end
          return document
        end
      end
    end

    def cleanup_new_capacity(handle, initial_workers, final_workers)
      return nil unless final_workers > initial_workers

      argv = if initial_workers.zero?
               [@executable, "destroy", "--fleet", handle, "--all", "--yes"]
             else
               [@executable, "scale", "--fleet", handle, "--workers", initial_workers.to_s, "--yes"]
             end
      exit_status = @runner.run(argv)
      return nil if exit_status.zero?

      "cleanup command exited #{exit_status}"
    rescue StandardError => e
      e.message
    end

    def result_document(request:, handle:, ready:, status:, capacity_result:, worker_indices:, profile:, detail:,
                        runtime_alias_evidence:, capability:)
      {
        "contract_version" => ContractV01::EXECUTION_POOL_RESULT_VERSION,
        "ready" => ready,
        "status" => status,
        "plan_sha256" => request.fetch("plan_sha256").downcase,
        "pool_id" => request.fetch("pool_id"),
        "execution_handle" => handle,
        "worker_indices" => worker_indices,
        "requirements" => request.fetch("requirements"),
        "capacity" => {
          "status" => capacity_result.fetch("status"),
          "desired_workers" => request.dig("capacity", "desired_workers"),
          "minimum_workers" => request.dig("capacity", "minimum_workers"),
          "initial_workers" => capacity_result.fetch("initial_workers"),
          "final_workers" => capacity_result.fetch("final_workers"),
          "max_pool_hourly_usd" => request.dig("capacity", "max_pool_hourly_usd"),
          "max_total_hourly_usd" => request.dig("capacity", "max_total_hourly_usd")
        },
        "hardware_policy" => {
          "cloud" => profile.cloud,
          "qualified_gpu_ids" => profile.gpu_ids,
          "global_volume_id" => profile.global_volume_id,
          "shared_model" => profile.shared_model,
          "ollama_store_path" => profile.ollama_store_path
        },
        "runtime_alias_evidence" => runtime_alias_evidence,
        "capabilities" => capability && capability["capabilities"],
        "detail" => detail
      }
    end

    def with_tempfile(prefix)
      Tempfile.create([prefix, ".json"]) do |file|
        path = file.path
        file.close
        yield path
      end
    end

    def with_json_request(document)
      Tempfile.create(["execution-pool-request", ".json"]) do |file|
        file.write(JSON.pretty_generate(document) + "\n")
        file.flush
        yield file.path
      end
    end

    def read_json_result(path, label)
      unless File.file?(path) && File.size?(path)
        raise Error, "#{label} did not write a result artifact"
      end
      JSON.parse(File.read(path))
    rescue JSON::ParserError => e
      raise Error, "#{label} result is invalid JSON: #{e.message}"
    end
  end
end
