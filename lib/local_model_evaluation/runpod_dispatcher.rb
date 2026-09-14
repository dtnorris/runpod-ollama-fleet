# frozen_string_literal: true

require "fileutils"
require "json"
require "time"
require "uri"
require_relative "runpod_fleet_state"
require_relative "runpod_tunnels"
require_relative "runpod_workers"

module LocalModelEvaluation
  class RunpodDispatcher
    SCHEMA_VERSION = 1
    JOB_ID_PATTERN = /\A[A-Za-z0-9][A-Za-z0-9._-]{0,127}\z/
    INJECTED_ENV = %w[LME_JOB_ID LME_WORKER_INDEX LME_OLLAMA_URL].freeze

    class Error < StandardError; end
    class InfrastructureError < Error; end

    class SystemCommandRunner
      TERMINATION_GRACE_SECONDS = 1.0
      TERMINATION_POLL_SECONDS = 0.05

      def initialize
        @active_mutex = Mutex.new
        @active_process_groups = {}
      end

      def run(argv:, env:, stdout_path:, stderr_path:, chdir:)
        pid = nil
        status = nil
        File.open(stdout_path, "w") do |stdout|
          File.open(stderr_path, "w") do |stderr|
            pid = Process.spawn(
              env,
              *argv,
              chdir:,
              in: File::NULL,
              out: stdout,
              err: stderr,
              pgroup: true
            )
            register_process_group(pid)
            _pid, status = Process.wait2(pid)
            return status.exitstatus || 128 + status.termsig.to_i
          end
        end
      ensure
        terminate_process_groups([pid]) if pid && status.nil?
        unregister_process_group(pid) if pid
      end

      def cancel_all
        pids = @active_mutex.synchronize { @active_process_groups.keys.dup }
        terminate_process_groups(pids)
      end

      private

      def register_process_group(pid)
        @active_mutex.synchronize { @active_process_groups[pid] = true }
      end

      def unregister_process_group(pid)
        @active_mutex.synchronize { @active_process_groups.delete(pid) }
      end

      def terminate_process_groups(pids)
        pids = Array(pids).compact.uniq
        return if pids.empty?

        pids.each { |pid| signal_group("TERM", pid) }
        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + TERMINATION_GRACE_SECONDS
        loop do
          remaining = pids.select { |pid| process_group_alive?(pid) }
          return if remaining.empty?
          break if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline

          sleep TERMINATION_POLL_SECONDS
        end
        pids.select { |pid| process_group_alive?(pid) }.each { |pid| signal_group("KILL", pid) }
      end

      def signal_group(signal, pid)
        Process.kill(signal, -pid)
      rescue Errno::ESRCH
        nil
      end

      def process_group_alive?(pid)
        Process.kill(0, -pid)
        true
      rescue Errno::ESRCH
        false
      rescue Errno::EPERM
        true
      end
    end

    def initialize(fleet_state:, output_dir:, repo_root:, out: $stdout,
                   endpoint_checker: nil, command_runner: nil,
                   wall_clock: nil, monotonic_clock: nil, workdir: nil)
      @fleet_state = fleet_state
      @output_dir = File.expand_path(output_dir)
      @repo_root = File.expand_path(repo_root)
      @workdir = File.expand_path(workdir || repo_root)
      @out = out
      @endpoint_checker = endpoint_checker || RunpodTunnels::HttpHealthChecker.new
      @command_runner = command_runner || SystemCommandRunner.new
      @wall_clock = wall_clock || -> { Time.now.utc }
      @monotonic_clock = monotonic_clock || -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) }
      @state_mutex = Mutex.new
      @results = []
      @infrastructure_failures = []
    end

    attr_reader :output_dir

    def run(jobs:, worker_indices:, group_by_affinity: false)
      reset_run_state!
      jobs = normalize_jobs(jobs)
      raise Error, "at least one job is required" if jobs.empty?

      fleet = active_fleet!
      workers = selected_workers(fleet, worker_indices)
      started_at = utc_now
      pending_jobs = prepare_output!(fleet:, workers:, jobs:, started_at:, group_by_affinity:)

      queue = Queue.new
      ordered_jobs(pending_jobs, group_by_affinity:).each { |job| queue << job }
      threads = []
      begin
        workers.each do |worker|
          threads << Thread.new do
            begin
              worker_loop(queue, fleet.fetch("fleet_id"), worker)
            rescue StandardError => e
              record_infrastructure_failure(
                worker,
                InfrastructureError.new("dispatcher worker loop crashed: #{e.class}: #{e.message}")
              )
            end
          end
        end
        threads.each(&:join)
      rescue Interrupt
        request_stop!
        @command_runner.cancel_all if @command_runner.respond_to?(:cancel_all)
        threads.each do |thread|
          thread.join
        rescue StandardError
          nil
        end

        summary = build_summary(
          fleet_id: fleet.fetch("fleet_id"),
          jobs:,
          workers:,
          started_at:
        )
        summary["status"] = "interrupted"
        summary["interrupted"] = true
        write_json(File.join(output_dir, "summary.json"), summary)
        raise
      end

      summary = build_summary(
        fleet_id: fleet.fetch("fleet_id"),
        jobs:,
        workers:,
        started_at:
      )
      write_json(File.join(output_dir, "summary.json"), summary)
      summary
    rescue RunpodFleetState::Error, RunpodWorkers::Error => e
      raise InfrastructureError, e.message
    end

    private

    def reset_run_state!
      @state_mutex.synchronize do
        @results.clear
        @infrastructure_failures.clear
        @stop_requested = false
      end
    end

    def request_stop!
      @state_mutex.synchronize { @stop_requested = true }
    end

    def stop_requested?
      @state_mutex.synchronize { @stop_requested == true }
    end

    def normalize_jobs(values)
      jobs = Array(values).map do |value|
        hash = value.respond_to?(:transform_keys) ? value.transform_keys(&:to_s) : {}
        job_id = hash["job_id"].to_s
        raise Error, "invalid job_id: #{job_id.inspect}" unless job_id.match?(JOB_ID_PATTERN)

        argv = Array(hash["argv"])
        if argv.empty? || argv.any? { |argument| !argument.is_a?(String) || argument.include?("\0") }
          raise Error, "job #{job_id} argv must be a non-empty array of strings"
        end

        env = hash.fetch("env", {})
        unless env.is_a?(Hash) && env.all? { |key, value| key.to_s.match?(/\A[A-Za-z_][A-Za-z0-9_]*\z/) && value.is_a?(String) }
          raise Error, "job #{job_id} env must map environment-variable names to strings"
        end
        env = env.transform_keys(&:to_s)
        reserved = env.keys & INJECTED_ENV
        unless reserved.empty?
          raise Error, "job #{job_id} may not override dispatcher environment: #{reserved.join(', ')}"
        end

        affinity = hash["affinity"]
        if hash.key?("affinity")
          unless affinity.is_a?(String) && !affinity.empty? && !affinity.include?("\0") && affinity.bytesize <= 256
            raise Error, "job #{job_id} affinity must be a non-empty string of at most 256 bytes"
          end
        end

        job = { "job_id" => job_id, "argv" => argv, "env" => env }
        job["affinity"] = affinity if hash.key?("affinity")
        job
      end

      duplicates = jobs.group_by { |job| job.fetch("job_id") }.select { |_id, group| group.length > 1 }.keys
      raise Error, "job_id values must be unique: #{duplicates.sort.join(', ')}" unless duplicates.empty?

      jobs
    end

    def ordered_jobs(jobs, group_by_affinity:)
      return jobs unless group_by_affinity

      groups = {}
      group_order = []
      jobs.each do |job|
        affinity = job["affinity"]
        unless groups.key?(affinity)
          groups[affinity] = []
          group_order << affinity
        end
        groups.fetch(affinity) << job
      end
      group_order.flat_map { |affinity| groups.fetch(affinity) }
    end

    def active_fleet!
      fleet = @fleet_state.current
      raise InfrastructureError, "no current RunPod fleet state exists" unless fleet
      unless fleet["status"] == "active"
        raise InfrastructureError, "current RunPod fleet #{fleet.fetch('fleet_id')} is not active"
      end

      fleet
    end

    def selected_workers(fleet, values)
      indices = Array(values).map { |value| RunpodWorkers.validate_index(value) }.uniq.sort
      raise Error, "no workers selected" if indices.empty?

      by_index = fleet.fetch("workers").to_h do |worker|
        [RunpodWorkers.validate_index(worker.fetch("index")), worker]
      end
      unknown = indices.reject { |index| by_index.key?(index) }
      unless unknown.empty?
        raise InfrastructureError, "current fleet does not contain worker index(es): #{unknown.join(', ')}"
      end

      selected = indices.map { |index| by_index.fetch(index) }
      inactive = selected.reject { |worker| worker["status"] == "active" }
      unless inactive.empty?
        labels = inactive.map { |worker| "burst_#{worker.fetch('index')}" }
        raise InfrastructureError, "selected worker(s) are not active: #{labels.join(', ')}"
      end
      selected.each { |worker| validate_endpoint!(worker.fetch("local_ollama_url")) }
      selected
    rescue KeyError, ArgumentError, TypeError => e
      raise InfrastructureError, "invalid fleet worker state: #{e.message}"
    end

    def worker_loop(queue, fleet_id, planned_worker)
      loop do
        break if stop_requested?

        begin
          worker = ready_worker!(fleet_id, planned_worker)
        rescue InfrastructureError => e
          record_infrastructure_failure(planned_worker, e)
          break
        end

        break if stop_requested?
        job = next_job(queue)
        break unless job

        break if stop_requested?

        execute(job, worker)
      end
    end

    def next_job(queue)
      queue.pop(true)
    rescue ThreadError
      nil
    end

    def ready_worker!(fleet_id, expected)
      fleet = active_fleet!
      unless fleet.fetch("fleet_id") == fleet_id
        raise InfrastructureError, "active fleet changed during dispatch"
      end

      index = RunpodWorkers.validate_index(expected.fetch("index"))
      current = fleet.fetch("workers").find { |worker| Integer(worker.fetch("index")) == index }
      raise InfrastructureError, "worker burst_#{index} disappeared from fleet state" unless current
      raise InfrastructureError, "worker burst_#{index} is not active" unless current["status"] == "active"
      unless current["pod_id"] == expected["pod_id"] && current["local_ollama_url"] == expected["local_ollama_url"]
        raise InfrastructureError, "worker burst_#{index} routing changed during dispatch"
      end

      endpoint = current.fetch("local_ollama_url")
      validate_endpoint!(endpoint)
      health = @endpoint_checker.check(endpoint)
      unless health.respond_to?(:healthy) && health.healthy
        detail = health.respond_to?(:detail) ? health.detail : "unknown health response"
        raise InfrastructureError, "worker burst_#{index} tunnel is unavailable: #{detail}"
      end
      current
    rescue RunpodFleetState::Error, RunpodWorkers::Error, KeyError, ArgumentError, TypeError => e
      raise InfrastructureError, e.message
    end

    def execute(job, worker)
      job_id = job.fetch("job_id")
      index = Integer(worker.fetch("index"))
      endpoint = worker.fetch("local_ollama_url")
      run_dir = File.join(output_dir, "jobs", job_id)
      FileUtils.mkdir_p(run_dir)
      stdout_path = File.join(run_dir, "stdout.log")
      stderr_path = File.join(run_dir, "stderr.log")
      metadata_path = File.join(run_dir, "metadata.json")
      started_wall = utc_now
      started_mono = @monotonic_clock.call
      relative_stdout = File.join("jobs", job_id, "stdout.log")
      relative_stderr = File.join("jobs", job_id, "stderr.log")
      metadata = {
        "schema_version" => SCHEMA_VERSION,
        "job_id" => job_id,
        "worker_index" => index,
        "worker_url" => endpoint,
        "argv" => job.fetch("argv"),
        "env_keys" => job.fetch("env").keys.sort,
        "started_at_utc" => started_wall.iso8601,
        "finished_at_utc" => nil,
        "elapsed_seconds" => nil,
        "status" => "running",
        "exit_status" => nil,
        "stdout_path" => relative_stdout,
        "stderr_path" => relative_stderr
      }
      write_json(metadata_path, metadata)
      @out.puts "[burst_#{index}] #{job_id}"

      env = job.fetch("env").merge(
        "LME_JOB_ID" => job_id,
        "LME_WORKER_INDEX" => index.to_s,
        "LME_OLLAMA_URL" => endpoint
      )
      exit_status = @command_runner.run(
        argv: job.fetch("argv"),
        env:,
        stdout_path:,
        stderr_path:,
        chdir: @workdir
      )
      metadata["exit_status"] = exit_status
      metadata["status"] = exit_status.zero? ? "completed" : "failed"
    rescue StandardError => e
      FileUtils.mkdir_p(run_dir) if run_dir
      File.open(stderr_path, "a") { |file| file.write("#{e.class}: #{e.message}\n") } if stderr_path
      metadata ||= {
        "schema_version" => SCHEMA_VERSION,
        "job_id" => job_id,
        "worker_index" => index,
        "worker_url" => endpoint,
        "stdout_path" => relative_stdout,
        "stderr_path" => relative_stderr,
        "started_at_utc" => started_wall&.iso8601
      }
      metadata["status"] = "failed"
      metadata["error"] = "#{e.class}: #{e.message}"
    ensure
      if metadata
        finished_wall = utc_now
        metadata["finished_at_utc"] = finished_wall.iso8601
        metadata["elapsed_seconds"] = (@monotonic_clock.call - started_mono).round(6) if started_mono
        write_json(metadata_path, metadata) if metadata_path
        @state_mutex.synchronize { @results << metadata }
      end
    end

    def record_infrastructure_failure(worker, error)
      record = {
        "worker_index" => Integer(worker.fetch("index")),
        "worker_url" => worker["local_ollama_url"],
        "at_utc" => utc_now.iso8601,
        "error" => "#{error.class}: #{error.message}"
      }
      @state_mutex.synchronize { @infrastructure_failures << record }
      @out.puts "WARN: quarantining burst_#{record.fetch('worker_index')} after infrastructure failure: " \
                "#{record.fetch('error')}"
    end

    def prepare_output!(fleet:, workers:, jobs:, started_at:, group_by_affinity:)
      return prepare_resume!(jobs, group_by_affinity:) if File.exist?(output_dir)

      FileUtils.mkdir_p(File.join(output_dir, "jobs"))
      write_json(
        File.join(output_dir, "manifest.json"),
        manifest(fleet:, workers:, jobs:, started_at:, group_by_affinity:)
      )
      jobs
    end

    def prepare_resume!(jobs, group_by_affinity:)
      unless File.directory?(output_dir)
        raise Error, "output path exists but is not a directory: #{output_dir}"
      end

      manifest_path = File.join(output_dir, "manifest.json")
      unless File.file?(manifest_path)
        raise Error, "cannot resume output without manifest.json: #{output_dir}"
      end

      existing_manifest = read_json!(manifest_path, label: "existing manifest")
      validate_resume_manifest!(existing_manifest, jobs, group_by_affinity:)

      prior_results = []
      pending_jobs = []
      jobs.each do |job|
        metadata_path = File.join(output_dir, "jobs", job.fetch("job_id"), "metadata.json")
        unless File.file?(metadata_path)
          pending_jobs << job
          next
        end

        metadata = read_json!(metadata_path, label: "metadata for #{job.fetch('job_id')}")
        validate_resume_metadata!(metadata, job)
        case metadata.fetch("status")
        when "completed", "failed"
          prior_results << metadata
        when "running"
          raise Error,
                "job #{job.fetch('job_id')} is recorded as running; " \
                "refusing to retry a possibly-started job automatically"
        else
          raise Error,
                "job #{job.fetch('job_id')} has unsupported resume status: #{metadata.fetch('status').inspect}"
        end
      end

      @state_mutex.synchronize { @results.concat(prior_results) }
      @out.puts "Resuming dispatch: #{prior_results.length} terminal job(s) preserved; " \
                "#{pending_jobs.length} unstarted job(s) pending."
      pending_jobs
    end

    def validate_resume_manifest!(existing_manifest, jobs, group_by_affinity:)
      unless existing_manifest.is_a?(Hash) && existing_manifest["schema_version"] == SCHEMA_VERSION
        raise Error, "existing manifest has unsupported schema_version"
      end

      existing_grouping = existing_manifest["affinity_grouping"] == true
      unless existing_grouping == group_by_affinity
        raise Error,
              "existing output manifest affinity grouping does not match requested dispatch; " \
              "use the original grouping mode or a new --output path"
      end

      expected_jobs = manifest_jobs(jobs)
      unless existing_manifest["job_count"] == jobs.length && existing_manifest["jobs"] == expected_jobs
        raise Error,
              "existing output manifest does not match requested jobs; use a new --output path"
      end
    end

    def validate_resume_metadata!(metadata, job)
      unless metadata.is_a?(Hash) && metadata["schema_version"] == SCHEMA_VERSION
        raise Error, "metadata for #{job.fetch('job_id')} has unsupported schema_version"
      end
      unless metadata["job_id"] == job.fetch("job_id")
        raise Error, "metadata job_id mismatch for #{job.fetch('job_id')}"
      end
      raise Error, "metadata for #{job.fetch('job_id')} is missing status" unless metadata.key?("status")

      return unless metadata.fetch("status") == "completed"

      required = %w[
        worker_index worker_url argv env_keys started_at_utc finished_at_utc
        elapsed_seconds exit_status stdout_path stderr_path
      ]
      missing = required.reject { |key| metadata.key?(key) }
      unless missing.empty?
        raise Error,
              "completed metadata for #{job.fetch('job_id')} is missing durable evidence: #{missing.join(', ')}"
      end

      unless metadata.fetch("argv") == job.fetch("argv")
        raise Error, "completed metadata argv mismatch for #{job.fetch('job_id')}"
      end
      unless metadata.fetch("env_keys") == job.fetch("env").keys.sort
        raise Error, "completed metadata env_keys mismatch for #{job.fetch('job_id')}"
      end
      unless metadata.fetch("exit_status") == 0
        raise Error, "completed metadata for #{job.fetch('job_id')} must have exit_status 0"
      end
      elapsed = metadata.fetch("elapsed_seconds")
      unless elapsed.is_a?(Numeric) && elapsed >= 0
        raise Error, "completed metadata for #{job.fetch('job_id')} has invalid elapsed_seconds"
      end
      %w[started_at_utc finished_at_utc].each do |key|
        begin
          Time.iso8601(metadata.fetch(key).to_s)
        rescue ArgumentError
          raise Error, "completed metadata for #{job.fetch('job_id')} has invalid #{key}"
        end
      end
      begin
        RunpodWorkers.validate_index(metadata.fetch("worker_index"))
        validate_endpoint!(metadata.fetch("worker_url"))
      rescue RunpodWorkers::Error, InfrastructureError => e
        raise Error, "completed metadata for #{job.fetch('job_id')} has invalid worker evidence: #{e.message}"
      end
      %w[stdout_path stderr_path].each do |key|
        value = metadata.fetch(key)
        unless value.is_a?(String) && !value.empty?
          raise Error, "completed metadata for #{job.fetch('job_id')} has invalid #{key}"
        end
      end
    end

    def read_json!(path, label:)
      JSON.parse(File.read(path))
    rescue JSON::ParserError => e
      raise Error, "#{label} is invalid JSON: #{e.message}"
    rescue SystemCallError => e
      raise Error, "could not read #{label}: #{e.message}"
    end

    def manifest(fleet:, workers:, jobs:, started_at:, group_by_affinity:)
      document = {
        "schema_version" => SCHEMA_VERSION,
        "fleet_id" => fleet.fetch("fleet_id"),
        "started_at_utc" => started_at.iso8601,
        "worker_indices" => workers.map { |worker| Integer(worker.fetch("index")) },
        "job_count" => jobs.length,
        "jobs" => manifest_jobs(jobs)
      }
      document["affinity_grouping"] = true if group_by_affinity
      document
    end

    def manifest_jobs(jobs)
      jobs.map do |job|
        projected = {
          "job_id" => job.fetch("job_id"),
          "argv" => job.fetch("argv"),
          "env_keys" => job.fetch("env").keys.sort
        }
        projected["affinity"] = job.fetch("affinity") if job.key?("affinity")
        projected
      end
    end

    def build_summary(fleet_id:, jobs:, workers:, started_at:)
      finished_at = utc_now
      results = @state_mutex.synchronize { @results.sort_by { |result| result.fetch("job_id") } }
      infrastructure_failures = @state_mutex.synchronize { @infrastructure_failures.dup }
      planned_ids = jobs.map { |job| job.fetch("job_id") }
      planned_lookup = planned_ids.to_h { |job_id| [job_id, true] }
      result_counts = results.map { |result| result.fetch("job_id") }.tally
      duplicate_ids = result_counts.select { |_job_id, count| count > 1 }.keys.sort
      unknown_ids = result_counts.keys.reject { |job_id| planned_lookup.key?(job_id) }.sort
      invalid_status_ids = results.filter_map do |result|
        result.fetch("job_id") unless %w[completed failed].include?(result["status"])
      end.uniq.sort

      integrity_errors = []
      unless duplicate_ids.empty?
        integrity_errors << "duplicate result job_id(s): #{duplicate_ids.join(', ')}"
      end
      unless unknown_ids.empty?
        integrity_errors << "unknown result job_id(s): #{unknown_ids.join(', ')}"
      end
      unless invalid_status_ids.empty?
        integrity_errors << "nonterminal result job_id(s): #{invalid_status_ids.join(', ')}"
      end

      countable_results = results.select do |result|
        job_id = result.fetch("job_id")
        planned_lookup.key?(job_id) && result_counts.fetch(job_id) == 1
      end
      observed_ids = result_counts.keys.select { |job_id| planned_lookup.key?(job_id) }
      not_started_job_ids = planned_ids - observed_ids
      summary = {
        "schema_version" => SCHEMA_VERSION,
        "fleet_id" => fleet_id,
        "started_at_utc" => started_at.iso8601,
        "finished_at_utc" => finished_at.iso8601,
        "status" => if integrity_errors.any?
                      "integrity_failed"
                    elsif not_started_job_ids.any?
                      "infrastructure_failed"
                    elsif countable_results.any? { |result| result["status"] == "failed" }
                      "workload_failed"
                    else
                      "completed"
                    end,
        "worker_count" => workers.length,
        "job_count" => jobs.length,
        "completed_count" => countable_results.count { |result| result["status"] == "completed" },
        "failed_count" => countable_results.count { |result| result["status"] == "failed" },
        "not_started_count" => not_started_job_ids.length,
        "not_started_job_ids" => not_started_job_ids,
        "infrastructure_failures" => infrastructure_failures,
        "jobs" => results.map do |result|
          result.slice(
            "job_id", "worker_index", "worker_url", "started_at_utc", "finished_at_utc",
            "elapsed_seconds", "status", "exit_status", "stdout_path", "stderr_path", "error"
          )
        end
      }
      summary["integrity_errors"] = integrity_errors unless integrity_errors.empty?
      summary
    end

    def validate_endpoint!(value)
      uri = URI.parse(value.to_s)
      unless uri.scheme == "http" && %w[127.0.0.1 localhost].include?(uri.host) && uri.port.positive?
        raise InfrastructureError, "worker URL must be a localhost HTTP tunnel, got #{value.inspect}"
      end
      value
    rescue URI::InvalidURIError
      raise InfrastructureError, "invalid worker URL: #{value.inspect}"
    end

    def write_json(path, value)
      FileUtils.mkdir_p(File.dirname(path))
      tmp = "#{path}.tmp.#{$$}.#{Thread.current.object_id}"
      File.write(tmp, JSON.pretty_generate(value) + "\n")
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
