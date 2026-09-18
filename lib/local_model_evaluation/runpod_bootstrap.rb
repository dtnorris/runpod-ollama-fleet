# frozen_string_literal: true

require "securerandom"
require "time"
require_relative "bootstrap_store"
require_relative "process_supervisor"
require_relative "runpod_workers"

module LocalModelEvaluation
  class RunpodBootstrap
    DEFAULT_HEARTBEAT_SECONDS = 10.0
    DEFAULT_PULL_TIMEOUT_SECONDS = 360
    DEFAULT_POLL_SECONDS = 0.25
    LOG_TAIL_BYTES = 131_072
    TERMINATION_GRACE_SECONDS = 3.0

    class Error < StandardError; end

    def initialize(fleet_state:, remote_setup_path:, repo_root:, out: $stdout,
                   wall_clock: nil, monotonic_clock: nil, sleeper: nil,
                   store: nil, process_supervisor: nil)
      @fleet_state = fleet_state
      @remote_setup_path = File.expand_path(remote_setup_path)
      @repo_root = File.expand_path(repo_root)
      @out = out
      @wall_clock = wall_clock || -> { Time.now.utc }
      @monotonic_clock = monotonic_clock || -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) }
      @sleeper = sleeper || ->(seconds) { sleep seconds }
      @store = store || BootstrapStore.new
      @process_supervisor = process_supervisor || ProcessSupervisor.new
      @out.sync = true if @out.respond_to?(:sync=)
    end

    def run(worker_indices:, models:, expected_digests: [], clean: false, reuse_existing: false,
            copy_to_workspace: false, copy_from_shared_store: nil, keep_root_models: false,
            context: nil, state_root: nil,
            pull_timeout_seconds: DEFAULT_PULL_TIMEOUT_SECONDS,
            heartbeat_seconds: DEFAULT_HEARTBEAT_SECONDS, poll_seconds: DEFAULT_POLL_SECONDS)
      fleet = active_fleet!
      workers = selected_workers(fleet, worker_indices)
      models = normalize_models(models)
      digests = normalize_digests(expected_digests, models)
      expected_gpus = workers.to_h do |worker|
        [Integer(worker.fetch("index")), worker_gpu_id(fleet, worker)]
      end
      if clean && reuse_existing
        raise Error, "--clean cannot be combined with --reuse-existing"
      end
      if copy_to_workspace && reuse_existing
        raise Error, "--copy-to-workspace cannot be combined with --reuse-existing"
      end
      if copy_from_shared_store
        copy_from_shared_store = copy_from_shared_store.to_s
        unless copy_from_shared_store.start_with?("/")
          raise Error, "--copy-from-shared-store must be an absolute remote path"
        end
        if reuse_existing
          raise Error, "--copy-from-shared-store cannot be combined with --reuse-existing"
        end
        if copy_to_workspace
          raise Error, "--copy-from-shared-store cannot be combined with --copy-to-workspace"
        end
        if keep_root_models
          raise Error, "--copy-from-shared-store cannot be combined with --keep-root-models"
        end
        if clean
          raise Error, "--copy-from-shared-store cannot be combined with --clean"
        end
        if models.length != 1
          raise Error, "--copy-from-shared-store requires exactly one model"
        end
      end
      if copy_to_workspace && keep_root_models
        raise Error, "--copy-to-workspace cannot be combined with --keep-root-models"
      end
      if keep_root_models && reuse_existing
        raise Error, "--keep-root-models cannot be combined with --reuse-existing"
      end
      if keep_root_models && models.length != 1
        raise Error, "--keep-root-models requires exactly one model"
      end
      if !reuse_existing && !copy_to_workspace && models.length != 1
        raise Error, "fresh root-storage bootstrap requires exactly one model; use --copy-to-workspace for multiple models"
      end

      if state_root && !state_root.to_s.start_with?("/")
        raise Error, "--state-root must be an absolute remote path"
      end
      if fleet.dig("provisioning", "network_volume_id")
        raise Error, "network-volume bootstrap requires --reuse-existing or --copy-from-shared-store" unless reuse_existing || copy_from_shared_store
        remote_state = File.expand_path(state_root || "/workspace/lme-worker-state")
        if remote_state == "/workspace" || remote_state.start_with?("/workspace/")
          raise Error, "network-volume bootstrap requires --state-root outside /workspace (e.g. /root/lme-worker-state)"
        end
      end

      heartbeat_seconds = positive_float(heartbeat_seconds, "heartbeat seconds")
      poll_seconds = positive_float(poll_seconds, "poll seconds")
      context = context ? positive_integer(context, "context") : 131_072
      pull_timeout_seconds = positive_integer(pull_timeout_seconds, "pull timeout seconds")
      validate_remote_setup!

      bootstrap_root = @fleet_state.artifact_dir(fleet.fetch("fleet_id"), "bootstrap")
      @store.with_lock(bootstrap_root) do
        execute_run(
          fleet:,
          workers:,
          models:,
          digests:,
          expected_gpus:,
          clean:,
          reuse_existing:,
          copy_to_workspace:,
          copy_from_shared_store:,
          keep_root_models:,
          state_root:,
          context:,
          pull_timeout_seconds:,
          heartbeat_seconds:,
          poll_seconds:,
          bootstrap_root:
        )
      end
    rescue BootstrapStore::LockUnavailable
      raise Error, "another bootstrap is already running for fleet #{fleet.fetch('fleet_id')}"
    end

    private

    def execute_run(fleet:, workers:, models:, digests:, expected_gpus:, clean:, reuse_existing:,
                    copy_to_workspace:, copy_from_shared_store:, keep_root_models:, state_root:, context:,
                    pull_timeout_seconds:, heartbeat_seconds:, poll_seconds:, bootstrap_root:)
      started_wall = utc_now
      started_mono = @monotonic_clock.call
      run_id = build_run_id(started_wall)
      run_dir = @store.start_run(root: bootstrap_root, run_id:)

      record = initial_record(
        fleet:,
        workers:,
        models:,
        digests:,
        expected_gpus:,
        clean:,
        reuse_existing:,
        copy_to_workspace:,
        copy_from_shared_store:,
        keep_root_models:,
        state_root:,
        context:,
        pull_timeout_seconds:,
        heartbeat_seconds:,
        started_wall:,
        run_id:
      )
      record_path = @store.record_path(run_dir)
      write_record(record_path, record)

      children = {}
      begin
        workers.each do |worker|
          child = spawn_worker(
            worker:,
            models:,
            digests:,
            expected_gpu: expected_gpus.fetch(Integer(worker.fetch("index"))),
            clean:,
            reuse_existing:,
            copy_to_workspace:,
            copy_from_shared_store:,
            keep_root_models:,
            state_root:,
            context:,
            pull_timeout_seconds:,
            run_dir:
          )
          children[worker.fetch("index")] = child
          worker_record = worker_record(record, worker.fetch("index"))
          worker_record["pid"] = child.fetch(:pid)
          worker_record["status"] = "running"
          worker_record["started_at_utc"] = utc_now.iso8601
          @out.puts format(
            "Starting %s bootstrap on burst_%d (%s:%d)...",
            models.join(", "),
            worker.fetch("index"),
            worker.fetch("host"),
            worker.fetch("ssh_port")
          )
        end
        write_record(record_path, record)
      rescue Interrupt
        interrupt_children(children, record, record_path)
        raise
      rescue StandardError => e
        terminate_children(children)
        record["status"] = "failed"
        record["error"] = "launcher error: #{e.message}"
        record["finished_at_utc"] = utc_now.iso8601
        record.fetch("workers").each do |worker|
          next unless worker["status"] == "running"

          worker["status"] = "aborted"
          worker["finished_at_utc"] = record["finished_at_utc"]
        end
        write_record(record_path, record)
        raise
      end

      next_heartbeat = started_mono + heartbeat_seconds
      last_stage = {}

      begin
        until children.empty?
          children.keys.sort.each do |index|
            child = children.fetch(index)
            progress = progress_for(child.fetch(:log_path))
            worker = worker_record(record, index)
            worker["stage"] = progress.fetch(:stage)
            worker["progress"] = progress[:detail]
            worker["last_log_line"] = progress[:latest_line]

            if last_stage[index] != progress[:stage]
              @out.puts progress_line(index, progress)
              last_stage[index] = progress[:stage]
            end

            waited_pid, status = wait_nonblocking(child.fetch(:pid))
            next unless waited_pid

            progress = progress_for(child.fetch(:log_path))
            worker["stage"] = progress.fetch(:stage)
            worker["progress"] = progress[:detail]
            worker["last_log_line"] = progress[:latest_line]
            worker["exit_status"] = status.exitstatus
            worker["finished_at_utc"] = utc_now.iso8601
            provenance = provenance_for(child.fetch(:log_path))
            worker["provenance"] = provenance
            provenance_error = provenance_error_for(
              provenance,
              models:,
              digests:,
              context:,
              expected_gpu: expected_gpus.fetch(index)
            )
            worker["provenance_error"] = provenance_error

            if status.success? && progress[:passed] && provenance_error.nil?
              worker["status"] = "passed"
              @out.puts "PASS: burst_#{index} bootstrap"
            else
              worker["status"] = "failed"
              detail = provenance_error ? " -- provenance: #{provenance_error}" : ""
              @out.puts(
                "FAIL: burst_#{index} bootstrap (exit #{status.exitstatus || 'signal'})#{detail} -- #{child.fetch(:log_path)}"
              )
            end
            children.delete(index)
            write_record(record_path, record)
          end

          now = @monotonic_clock.call
          if !children.empty? && now >= next_heartbeat
            emit_heartbeat(record, fleet, started_mono, now)
            write_record(record_path, record)
            next_heartbeat = now + heartbeat_seconds
          end

          @sleeper.call(poll_seconds) unless children.empty?
        end
      rescue Interrupt
        interrupt_children(children, record, record_path)
        raise
      end

      failures = record.fetch("workers").count { |worker| worker["status"] == "failed" }
      passes = record.fetch("workers").count { |worker| worker["status"] == "passed" }
      record["status"] = failures.zero? ? "passed" : "failed"
      record["finished_at_utc"] = utc_now.iso8601
      record["elapsed_seconds"] = (@monotonic_clock.call - started_mono).round(3)
      record["bootstrap_window_cost_usd"] = bootstrap_window_cost(fleet, record["elapsed_seconds"])
      write_record(record_path, record)

      @out.puts format(
        "Bootstrap complete: %d passed, %d failed. Fleet %s; run %s; bootstrap-window cost approx. $%.4f.",
        passes,
        failures,
        fleet.fetch("fleet_id"),
        run_id,
        record.fetch("bootstrap_window_cost_usd")
      )
      @out.puts "Bootstrap evidence: #{run_dir}"

      raise Error, "bootstrap failed on #{failures} worker(s); inspect #{run_dir}" unless failures.zero?

      record
    end

    def active_fleet!
      fleet = @fleet_state.current
      raise Error, "no current RunPod fleet state exists; provision a fleet first" unless fleet
      raise Error, "current RunPod fleet #{fleet.fetch('fleet_id')} is not active" unless fleet["status"] == "active"

      fleet
    rescue RunpodFleetState::Error => e
      raise Error, e.message
    end

    def selected_workers(fleet, values)
      indices = Array(values).map { |value| RunpodWorkers.validate_index(value) }.uniq.sort
      raise Error, "no workers selected" if indices.empty?

      by_index = fleet.fetch("workers").to_h { |worker| [Integer(worker.fetch("index")), worker] }
      unknown = indices.reject { |index| by_index.key?(index) }
      raise Error, "current fleet does not contain worker index(es): #{unknown.join(', ')}" unless unknown.empty?

      selected = indices.map { |index| by_index.fetch(index) }
      inactive = selected.reject { |worker| worker["status"] == "active" }
      unless inactive.empty?
        raise Error, "selected worker(s) are not active: #{inactive.map { |worker| "burst_#{worker.fetch('index')}" }.join(', ')}"
      end

      selected
    rescue RunpodWorkers::Error => e
      raise Error, e.message
    rescue ArgumentError, TypeError
      raise Error, "worker indices must be integers"
    end

    def worker_gpu_id(fleet, worker)
      selected = worker["gpu_id"].to_s.strip
      selected = fleet.dig("gpu", "id").to_s.strip if selected.empty?
      raise Error, "burst_#{worker.fetch('index')} does not record an exact GPU id" if selected.empty?
      selected
    end

    def normalize_models(values)
      models = Array(values).map { |value| value.to_s.strip }.reject(&:empty?).uniq
      raise Error, "at least one --model is required" if models.empty?

      models
    end

    def normalize_digests(values, models)
      digests = Array(values).each_with_object({}) do |value, out|
        model, digest = value.to_s.split("=", 2)
        if model.to_s.empty? || digest.to_s.empty?
          raise Error, "expected digest must use MODEL=DIGEST"
        end
        raise Error, "expected digest names unrequested model #{model.inspect}" unless models.include?(model)
        unless digest.match?(/\A[0-9a-fA-F]{64}\z/)
          raise Error, "expected digest for #{model} must be exactly 64 hexadecimal characters"
        end

        out[model] = digest.downcase
      end

      missing = models - digests.keys
      unless missing.empty?
        raise Error, "exact expected digest required for model(s): #{missing.join(', ')}"
      end

      digests
    end

    def spawn_worker(worker:, models:, digests:, expected_gpu:, clean:, reuse_existing:, copy_to_workspace:,
                     copy_from_shared_store:, keep_root_models:, context:, pull_timeout_seconds:, state_root:, run_dir:)
      index = worker.fetch("index")
      command = [@remote_setup_path, "--worker", index.to_s]
      command.concat(["--expect-gpu", expected_gpu])
      command.concat(["--min-vram-gb", ENV.fetch("RUNPOD_GPU_MEMORY_GB", "40")])
      command << "--clean" if clean
      command << "--reuse-existing" if reuse_existing
      command << "--copy-to-workspace" if copy_to_workspace
      command.concat(["--copy-from-shared-store", copy_from_shared_store]) if copy_from_shared_store
      command << "--keep-root-models" if keep_root_models
      command.concat(["--state-root", state_root]) if state_root
      models.each do |model|
        command.concat(["--model", model])
        command.concat(["--expect-digest", "#{model}=#{digests.fetch(model)}"])
      end
      command.concat(["--pull-timeout-seconds", pull_timeout_seconds.to_s])
      command.concat(["--context", context.to_s])

      log = @store.open_worker_log(run_dir:, worker_index: index)
      pid = @process_supervisor.spawn(command:, chdir: @repo_root, output: log.io)
      { pid:, log_path: log.path }
    ensure
      @store.close_worker_log(log) if defined?(log) && log
    end

    def wait_nonblocking(pid)
      @process_supervisor.poll(pid)
    end

    def progress_for(path)
      text = log_tail(path)
      events = [
        [/Worker setup PASS\./, "FINALIZING"],
        [/verification PASS: context=/, "VERIFIED"],
        [/\[6\/8\] Warm each model/, "WARMING"],
        [/Warming /, "WARMING"],
        [/LME_COPY_PROGRESS\t/, "COPYING"],
        [/Copying completed Ollama store/, "COPYING"],
        [/Copy requested model from shared store/, "COPYING"],
        [/\b\d+(?:\.\d+)?[KMGT]\s+\d+%\s+\d+(?:\.\d+)?[KMGT]?B\/s/i, "COPYING"],
        [/Pulling /, "PULLING"],
        [/pulling [0-9a-f]{8,}:/i, "PULLING"],
        [/\[3\/8\] Reuse existing workspace model cache/, "REUSING"],
        [/\[3\/8\] Pull requested model to fast local\/root store/, "STAGING"],
        [/\[3\/8\] Stage requested models/, "STAGING"],
        [/\[2\/8\] Normalize Ollama state/, "PREPARING"],
        [/\[1\/8\] Preflight host/, "PREFLIGHT"],
        [/Streaming setup_runpod_ollama_worker\.sh/, "CONNECTING"],
        [/Direct SSH PASS\./, "SSH"],
        [/Loading worker /, "STARTING"]
      ]

      winner = events.filter_map do |pattern, stage|
        match = nil
        text.to_enum(:scan, pattern).each { match = Regexp.last_match }
        [match.begin(0), stage] if match
      end.max_by(&:first)

      stage = winner ? winner[1] : "STARTING"
      segment = winner ? text[winner[0]..] : text
      detail = case stage
               when "COPYING"
                 copy_progress_detail(text)
               when "PULLING"
                 percentages = segment.scan(/(?<!\d)(100|[1-9]?\d)%/).flatten
                 "#{percentages.last}%" unless percentages.empty?
               end
      passed = text.include?("remote setup PASS")
      stage = "READY" if passed

      {
        stage:,
        detail:,
        latest_line: latest_meaningful_line(text),
        passed:
      }
    end

    def copy_progress_detail(text)
      latest = nil
      text.each_line do |line|
        payload = line.split("LME_COPY_PROGRESS\t", 2)[1]
        next unless payload

        model, copied_text, total_text, percent_text = payload.strip.split("\t", 4)
        next if model.to_s.empty? || copied_text.nil? || total_text.nil? || percent_text.nil?

        copied = Integer(copied_text, 10)
        total = Integer(total_text, 10)
        percent = Float(percent_text)
        next unless total.positive? && copied.between?(0, total)
        next unless percent.finite? && percent.between?(0.0, 100.0)

        expected_percent = (copied * 100.0) / total
        next if (percent - expected_percent).abs > 0.05

        latest = "#{percent.round}%"
      rescue ArgumentError, TypeError
        next
      end
      latest
    end

    def provenance_for(path)
      text = log_tail(path)
      gpu = nil
      model_records = {}

      text.each_line do |line|
        if (payload = line.split("LME_PROVENANCE_GPU\t", 2)[1])
          name, vram = payload.strip.split("\t", 2)
          gpu = {
            "name" => name,
            "vram_mib" => integer_or_nil(vram)
          }
        elsif (payload = line.split("LME_PROVENANCE_MODEL\t", 2)[1])
          model, digest, actual_context, size, size_vram = payload.strip.split("\t", 5)
          next unless model && digest

          parsed_size = integer_or_nil(size)
          parsed_size_vram = integer_or_nil(size_vram)
          model_records[model] = {
            "digest" => digest.downcase,
            "context_length" => integer_or_nil(actual_context),
            "size_bytes" => parsed_size,
            "size_vram_bytes" => parsed_size_vram,
            "fully_gpu_resident" => !parsed_size.nil? && parsed_size == parsed_size_vram
          }
        end
      end

      {
        "gpu" => gpu,
        "models" => model_records
      }
    end

    def provenance_error_for(provenance, models:, digests:, context:, expected_gpu:)
      errors = []
      gpu = provenance["gpu"]
      if gpu.nil?
        errors << "missing GPU provenance marker"
      elsif gpu["name"] != expected_gpu
        errors << "GPU mismatch: expected #{expected_gpu.inspect}, got #{gpu['name'].inspect}"
      end

      observed_models = provenance.fetch("models", {})
      models.each do |model|
        observed = observed_models[model]
        unless observed
          errors << "missing model provenance for #{model}"
          next
        end

        expected_digest = digests.fetch(model)
        if observed["digest"] != expected_digest
          errors << "#{model} digest mismatch: expected #{expected_digest}, got #{observed['digest'].inspect}"
        end
        if observed["context_length"] != context
          errors << "#{model} context mismatch: expected #{context}, got #{observed['context_length'].inspect}"
        end
        unless observed["fully_gpu_resident"] == true &&
               observed["size_bytes"] &&
               observed["size_bytes"] == observed["size_vram_bytes"]
          errors << "#{model} is not proven fully GPU-resident"
        end
      end

      errors.empty? ? nil : errors.join("; ")
    end

    def integer_or_nil(value)
      Integer(value)
    rescue ArgumentError, TypeError
      nil
    end

    def log_tail(path)
      sanitize_text(@store.log_tail(path, max_bytes: LOG_TAIL_BYTES))
    end

    def sanitize_text(value)
      value.encode("UTF-8", invalid: :replace, undef: :replace, replace: "?")
           .gsub(/\e\[[0-?]*[ -\/]*[@-~]/, "")
           .tr("\r", "\n")
    end

    def latest_meaningful_line(text)
      text.lines.reverse_each do |line|
        cleaned = line.strip
        next if cleaned.empty?
        next unless cleaned.match?(/[[:alnum:]]/)

        return cleaned[-300, 300] || cleaned
      end
      nil
    end

    def progress_line(index, progress)
      suffix = progress[:detail] ? " #{progress[:detail]}" : ""
      "[#{utc_now.strftime('%H:%M:%S')}] burst_#{index} #{progress.fetch(:stage)}#{suffix}"
    end

    def emit_heartbeat(record, fleet, started_mono, now)
      counts = record.fetch("workers").group_by { |worker| worker.fetch("status") }.transform_values(&:length)
      active = record.fetch("workers").select { |worker| worker["status"] == "running" }
      states = active.map do |worker|
        suffix = worker["progress"] ? " #{worker['progress']}" : ""
        "burst_#{worker.fetch('index')} #{worker.fetch('stage')}#{suffix}"
      end
      elapsed = now - started_mono
      cost = bootstrap_window_cost(fleet, elapsed)
      summary = format(
        "[%s] heartbeat: %d running, %d passed, %d failed | fleet $%.4f/hr | elapsed %s | bootstrap-window ~$%.4f",
        utc_now.strftime("%H:%M:%S"),
        counts.fetch("running", 0),
        counts.fetch("passed", 0),
        counts.fetch("failed", 0),
        Float(fleet.fetch("fleet_hourly_rate_usd")),
        format_duration(elapsed),
        cost
      )
      summary += " | #{states.join(' | ')}" unless states.empty?
      @out.puts summary
    end

    def interrupt_children(children, record, record_path)
      @out.puts "Interrupt received; stopping #{children.length} bootstrap process group(s)..."
      terminate_children(children)
      timestamp = utc_now.iso8601
      record["status"] = "interrupted"
      record["finished_at_utc"] = timestamp
      record.fetch("workers").each do |worker|
        next unless worker["status"] == "running"

        worker["status"] = "interrupted"
        worker["finished_at_utc"] = timestamp
      end
      write_record(record_path, record)
      @out.puts "Bootstrap interrupted. Local bootstrap/SSH process groups stopped; remote worker state may require inspection."
    end

    def terminate_children(children)
      remaining = children.values.map { |child| child.fetch(:pid) }.uniq
      remaining.each { |pid| @process_supervisor.signal_group("TERM", pid) }
      deadline = @monotonic_clock.call + TERMINATION_GRACE_SECONDS

      until remaining.empty? || @monotonic_clock.call >= deadline
        remaining.delete_if do |pid|
          waited, = wait_nonblocking(pid)
          !waited.nil?
        end
        @sleeper.call(0.05) unless remaining.empty?
      end

      remaining.each { |pid| @process_supervisor.signal_group("KILL", pid) }
      remaining.each { |pid| @process_supervisor.wait(pid) }
    end

    def initial_record(fleet:, workers:, models:, digests:, expected_gpus:, clean:, reuse_existing:,
                       copy_to_workspace:, copy_from_shared_store:, keep_root_models:, state_root:, context:,
                       pull_timeout_seconds:, heartbeat_seconds:, started_wall:, run_id:)
      gpu_ids = expected_gpus.values.uniq
      {
        "schema_version" => 2,
        "bootstrap_run_id" => run_id,
        "fleet_id" => fleet.fetch("fleet_id"),
        "status" => "running",
        "started_at_utc" => started_wall.iso8601,
        "finished_at_utc" => nil,
        "models" => models,
        "expected_digests" => digests,
        "expected_gpu" => gpu_ids.length == 1 ? gpu_ids.first : nil,
        "expected_gpus" => expected_gpus.transform_keys(&:to_s),
        "clean" => clean,
        "reuse_existing" => reuse_existing,
        "copy_to_workspace" => copy_to_workspace,
        "copy_from_shared_store" => copy_from_shared_store,
        "model_store_mode" => (copy_from_shared_store ? "shared_copy_to_root" : (reuse_existing ? "workspace_reuse" : (copy_to_workspace ? "workspace" : "root"))),
        "keep_root_models" => keep_root_models,
        "state_root" => state_root || "/workspace/lme-worker-state",
        "context" => context,
        "pull_timeout_seconds" => pull_timeout_seconds,
        "heartbeat_seconds" => heartbeat_seconds,
        "fleet_hourly_rate_usd" => fleet.fetch("fleet_hourly_rate_usd"),
        "workers" => workers.map do |worker|
          {
            "index" => worker.fetch("index"),
            "pod_id" => worker.fetch("pod_id"),
            "host" => worker.fetch("host"),
            "ssh_port" => worker.fetch("ssh_port"),
            "expected_gpu" => expected_gpus.fetch(Integer(worker.fetch("index"))),
            "status" => "pending",
            "stage" => "PENDING",
            "progress" => nil,
            "pid" => nil,
            "log" => "burst_#{worker.fetch('index')}.log",
            "started_at_utc" => nil,
            "finished_at_utc" => nil,
            "exit_status" => nil,
            "provenance" => nil,
            "provenance_error" => nil
          }
        end
      }
    end

    def worker_record(record, index)
      record.fetch("workers").find { |worker| worker.fetch("index") == index } ||
        raise(Error, "bootstrap state lost worker burst_#{index}")
    end

    def write_record(path, record)
      @store.write_record(path:, record:)
    end

    def build_run_id(timestamp)
      "#{timestamp.strftime('%Y%m%dT%H%M%SZ')}-#{$$}-#{SecureRandom.hex(2)}"
    end

    def validate_remote_setup!
      unless @process_supervisor.file?(@remote_setup_path)
        raise Error, "remote bootstrap wrapper not found: #{@remote_setup_path}"
      end
      unless @process_supervisor.executable?(@remote_setup_path)
        raise Error, "remote bootstrap wrapper is not executable: #{@remote_setup_path}"
      end
    end

    def positive_float(value, label)
      number = Float(value)
      raise Error, "#{label} must be positive" unless number.positive?

      number
    rescue ArgumentError, TypeError
      raise Error, "#{label} must be numeric"
    end

    def positive_integer(value, label)
      number = Integer(value)
      raise Error, "#{label} must be positive" unless number.positive?

      number
    rescue ArgumentError, TypeError
      raise Error, "#{label} must be an integer"
    end

    def utc_now
      value = @wall_clock.call
      value = Time.parse(value.to_s) unless value.is_a?(Time)
      value.utc
    end

    def bootstrap_window_cost(fleet, elapsed_seconds)
      (Float(fleet.fetch("fleet_hourly_rate_usd")) * Float(elapsed_seconds) / 3600.0).round(6)
    end

    def format_duration(seconds)
      total = seconds.to_i
      hours = total / 3600
      minutes = (total % 3600) / 60
      secs = total % 60
      format("%02d:%02d:%02d", hours, minutes, secs)
    end
  end
end
