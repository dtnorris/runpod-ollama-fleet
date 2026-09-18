# frozen_string_literal: true

require "fileutils"
require "json"
require "time"
require_relative "contract_v0_1"
require_relative "../local_model_evaluation/runpod_dispatcher"
require_relative "../local_model_evaluation/runpod_cost_control"
require_relative "../local_model_evaluation/runpod_shutdown_control"

module RunpodOllamaFleet
  class DispatchV01
    def initialize(fleet_state:, fleet_key:, workdir:, output_dir:, provider_repo_root:, out: $stdout,
                   dispatcher_class: LocalModelEvaluation::RunpodDispatcher, wall_clock: nil)
      @fleet_state = fleet_state
      @fleet_key = fleet_key
      @workdir = File.expand_path(workdir)
      @output_dir = File.expand_path(output_dir)
      @provider_repo_root = File.expand_path(provider_repo_root)
      @out = out
      @dispatcher_class = dispatcher_class
      @wall_clock = wall_clock || -> { Time.now.utc }
    end

    attr_reader :output_dir

    def run(request, dynamic_worker_admission: false)
      ContractV01.validate_dispatch_request!(request)
      started = utc_now
      target = request.fetch("target")
      fleet, _workers = validate_target!(target)
      validate_resume_target!(target)
      cost = cost_control
      shutdown = shutdown_control
      validate_cost_gate!(cost, fleet)
      validate_shutdown_gate!(shutdown, fleet, target.fetch("worker_indices"))
      drain_checker = lambda do
        cost_gate = cost.dispatch_gate(fleet_key: @fleet_key, fleet_id: fleet.fetch("fleet_id"))
        shutdown_gate = shutdown.dispatch_gate(
          fleet_key: @fleet_key,
          fleet_id: fleet.fetch("fleet_id"),
          worker_indices: target.fetch("worker_indices")
        )
        !cost_gate.fetch("allowed") || !shutdown_gate.fetch("allowed")
      end
      dispatcher = @dispatcher_class.new(
        fleet_state: @fleet_state,
        output_dir: output_dir,
        repo_root: @provider_repo_root,
        workdir: @workdir,
        out: @out,
        drain_checker: drain_checker,
        fleet_key: @fleet_key
      )
      run_args = {
        jobs: request.fetch("jobs"),
        worker_indices: target.fetch("worker_indices"),
        group_by_affinity: request.fetch("group_by_affinity")
      }
      run_args[:dynamic_worker_admission] = true if dynamic_worker_admission
      private_summary = dispatcher.run(**run_args)
      public_summary = public_summary(private_summary)
      write_summary(public_summary)
      public_summary
    rescue LocalModelEvaluation::RunpodDispatcher::InfrastructureError,
           LocalModelEvaluation::RunpodFleetState::Error,
           LocalModelEvaluation::RunpodCostControl::Error,
           LocalModelEvaluation::RunpodShutdownControl::Error,
           KeyError, ArgumentError, TypeError => e
      summary = infrastructure_failure_summary(request, started || utc_now, e)
      write_summary(summary)
      summary
    rescue Interrupt
      path = File.join(output_dir, "summary.json")
      if File.file?(path)
        begin
          summary = public_summary(JSON.parse(File.read(path)))
          summary["status"] = "interrupted"
          write_summary(summary)
        rescue StandardError
          nil
        end
      end
      raise
    end

    private

    def validate_target!(target)
      fleet = @fleet_state.current
      raise LocalModelEvaluation::RunpodDispatcher::InfrastructureError, "no current active RunPod fleet exists" unless fleet && fleet["status"] == "active"
      unless fleet.fetch("fleet_id") == target.fetch("expected_fleet_id")
        raise LocalModelEvaluation::RunpodDispatcher::InfrastructureError,
              "active fleet id changed: expected #{target.fetch('expected_fleet_id')}, got #{fleet.fetch('fleet_id')}"
      end
      by_index = Array(fleet.fetch("workers")).to_h { |worker| [Integer(worker.fetch("index")), worker] }
      workers = target.fetch("worker_indices").map do |index|
        worker = by_index[index]
        raise LocalModelEvaluation::RunpodDispatcher::InfrastructureError, "current fleet does not contain burst_#{index}" unless worker
        raise LocalModelEvaluation::RunpodDispatcher::InfrastructureError, "burst_#{index} is not active" unless worker["status"] == "active"
        worker
      end
      [fleet, workers]
    end

    def validate_resume_target!(target)
      return unless File.exist?(output_dir)
      manifest_path = File.join(output_dir, "manifest.json")
      return unless File.file?(manifest_path)
      manifest = JSON.parse(File.read(manifest_path))
      unless manifest["fleet_id"] == target.fetch("expected_fleet_id")
        raise LocalModelEvaluation::RunpodDispatcher::InfrastructureError,
              "existing dispatch evidence belongs to a different fleet"
      end
      existing = Array(manifest["worker_indices"]).map { |value| Integer(value) }.sort
      requested = target.fetch("worker_indices").sort
      unless existing == requested
        raise LocalModelEvaluation::RunpodDispatcher::InfrastructureError,
              "existing dispatch evidence uses different logical workers"
      end
    rescue JSON::ParserError, ArgumentError, TypeError => e
      raise LocalModelEvaluation::RunpodDispatcher::InfrastructureError,
            "existing dispatch target evidence is invalid: #{e.message}"
    end

    def cost_control
      LocalModelEvaluation::RunpodCostControl.new(
        root: File.join(@provider_repo_root, "output", "runpod-fleets"),
        repo_root: @provider_repo_root
      )
    end

    def validate_cost_gate!(cost, fleet)
      gate = cost.dispatch_gate(fleet_key: @fleet_key, fleet_id: fleet.fetch("fleet_id"))
      return if gate.fetch("allowed")

      raise LocalModelEvaluation::RunpodDispatcher::InfrastructureError,
            "#{gate.fetch('code')}: #{gate.fetch('detail')}"
    end

    def shutdown_control
      LocalModelEvaluation::RunpodShutdownControl.new(
        root: File.join(@provider_repo_root, "output", "runpod-fleets"),
        repo_root: @provider_repo_root
      )
    end

    def validate_shutdown_gate!(shutdown, fleet, worker_indices)
      gate = shutdown.dispatch_gate(
        fleet_key: @fleet_key,
        fleet_id: fleet.fetch("fleet_id"),
        worker_indices: worker_indices
      )
      return if gate.fetch("allowed")

      raise LocalModelEvaluation::RunpodDispatcher::InfrastructureError,
            "#{gate.fetch('code')}: #{gate.fetch('detail')}"
    end

    def public_summary(private_summary)
      summary = {
        "contract_version" => ContractV01::DISPATCH_SUMMARY_VERSION,
        "fleet_key" => @fleet_key,
        "fleet_id" => private_summary.fetch("fleet_id"),
        "started_at_utc" => private_summary.fetch("started_at_utc"),
        "finished_at_utc" => private_summary.fetch("finished_at_utc"),
        "status" => private_summary.fetch("status"),
        "worker_count" => Integer(private_summary.fetch("worker_count")),
        "worker_indices" => Array(private_summary["worker_indices"]).map { |value| Integer(value) }.uniq.sort,
        "job_count" => Integer(private_summary.fetch("job_count")),
        "completed_count" => Integer(private_summary.fetch("completed_count")),
        "failed_count" => Integer(private_summary.fetch("failed_count")),
        "not_started_count" => Integer(private_summary.fetch("not_started_count")),
        "not_started_job_ids" => Array(private_summary.fetch("not_started_job_ids")),
        "infrastructure_failures" => Array(private_summary.fetch("infrastructure_failures")).map do |failure|
          failure.slice("worker_index", "at_utc", "error")
        end,
        "jobs" => Array(private_summary.fetch("jobs")).map do |job|
          job.slice(
            "job_id", "worker_index", "started_at_utc", "finished_at_utc",
            "elapsed_seconds", "status", "exit_status", "stdout_path", "stderr_path", "error"
          )
        end
      }
      summary["integrity_errors"] = Array(private_summary["integrity_errors"]) if private_summary.key?("integrity_errors")
      summary
    end

    def infrastructure_failure_summary(request, started, error)
      target = request.fetch("target", {})
      jobs = Array(request["jobs"])
      {
        "contract_version" => ContractV01::DISPATCH_SUMMARY_VERSION,
        "fleet_key" => target["fleet_key"].to_s,
        "fleet_id" => target["expected_fleet_id"].to_s,
        "started_at_utc" => started.iso8601,
        "finished_at_utc" => utc_now.iso8601,
        "status" => "infrastructure_failed",
        "worker_count" => [Array(target["worker_indices"]).length, 1].max,
        "job_count" => [jobs.length, 1].max,
        "completed_count" => 0,
        "failed_count" => 0,
        "not_started_count" => jobs.length,
        "not_started_job_ids" => jobs.filter_map { |job| job["job_id"] },
        "infrastructure_failures" => [],
        "jobs" => [],
        "integrity_errors" => ["#{error.class}: #{error.message}"]
      }
    end

    def write_summary(summary)
      FileUtils.mkdir_p(output_dir)
      path = File.join(output_dir, "summary.json")
      tmp = "#{path}.tmp.#{$$}"
      File.write(tmp, JSON.pretty_generate(summary) + "\n")
      File.rename(tmp, path)
    ensure
      File.delete(tmp) if defined?(tmp) && tmp && File.exist?(tmp)
    end

    def utc_now
      value = @wall_clock.call
      value = Time.parse(value.to_s) unless value.is_a?(Time)
      value.utc
    end
  end
end
