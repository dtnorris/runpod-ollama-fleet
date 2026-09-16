# frozen_string_literal: true

require "fileutils"
require "json"
require "time"
require_relative "runpod_activity"
require_relative "runpod_client"
require_relative "runpod_cost_control"
require_relative "runpod_fleet"
require_relative "runpod_fleet_namespace"
require_relative "runpod_fleet_state"
require_relative "runpod_tunnels"
require_relative "runpod_workers"

module LocalModelEvaluation
  # Durable, workload-aware RunPod retirement state.
  #
  # AFIO may arm a terminal gate after a campaign reaches a terminal result.
  # The gate remains dispatch-open while it observes activity. Five continuous
  # minutes without managed inference activity (by default) transition the selected workers to DRAINING.
  # DRAINING blocks new work but never interrupts active inference. If active
  # inference does not clear within the drain timeout, the gate becomes
  # TIMED_OUT and requires explicit operator input. Force shutdown is a separate
  # explicit path handled by the CLI.
  class RunpodShutdownControl
    SCHEMA_VERSION = 1
    STATE_FILE = "shutdown-state.json"
    EVENTS_FILE = "shutdown-events.jsonl"
    LOCK_FILE = ".shutdown.lock"
    PID_FILE = "shutdown-watchdog.pid"
    LOG_FILE = "shutdown-watchdog.log"

    DEFAULT_TERMINAL_IDLE_SECONDS = 300.0
    DEFAULT_DRAIN_TIMEOUT_SECONDS = 600.0
    DEFAULT_POLL_SECONDS = 5.0
    PROVIDER_VERIFY_SECONDS = 30.0
    PROVIDER_VERIFY_POLL_SECONDS = 1.0

    TERMINAL_STATUSES = %w[pending draining timed_out].freeze

    class Error < StandardError; end

    def initialize(root:, repo_root:, client: nil, out: $stdout, wall_clock: nil, sleeper: nil,
                   lifecycle_reader: nil, activity_reader: nil, destroyer: nil, tunnel_stopper: nil)
      @root = File.expand_path(root)
      @repo_root = File.expand_path(repo_root)
      @client = client
      @out = out
      @wall_clock = wall_clock || -> { Time.now.utc }
      @sleeper = sleeper || ->(seconds) { sleep seconds }
      @lifecycle_reader = lifecycle_reader
      @activity_reader = activity_reader
      @destroyer = destroyer
      @tunnel_stopper = tunnel_stopper
    end

    attr_reader :root, :repo_root

    def schedule_terminal!(fleet_key:, worker_indices:, idle_seconds: DEFAULT_TERMINAL_IDLE_SECONDS,
                           drain_timeout_seconds: DEFAULT_DRAIN_TIMEOUT_SECONDS,
                           reason: "afio_campaign_terminal")
      key = RunpodFleetNamespace.normalize_key(fleet_key)
      if lifecycle_for(key) == "persistent"
        record_event(action: "terminal_gate_skipped", fleet_key: key, fleet_id: current_fleet_id(key),
                     worker_indices: worker_indices, reason: "persistent_lifecycle")
        return { "status" => "persistent", "fleet_key" => key }
      end

      idle_seconds = positive_float(idle_seconds, "terminal idle seconds")
      drain_timeout_seconds = positive_float(drain_timeout_seconds, "drain timeout seconds")
      fleet, indices = active_selection!(key, worker_indices)
      now = utc_now

      gate = nil
      with_lock do
        data = state
        current = data.fetch("gates")[key]
        indices = (indices + Array(current && current["worker_indices"])).map { |value| Integer(value) }.uniq.sort if current && current["fleet_id"].to_s == fleet.fetch("fleet_id").to_s
        gate = {
          "fleet_id" => fleet.fetch("fleet_id"),
          "worker_indices" => indices,
          "status" => "pending",
          "reason" => reason.to_s,
          "requested_at_utc" => now.iso8601,
          "idle_since_utc" => nil,
          "idle_seconds" => idle_seconds,
          "drain_started_at_utc" => nil,
          "drain_timeout_seconds" => drain_timeout_seconds,
          "last_error" => nil
        }
        data.fetch("gates")[key] = gate
        write_state(data)
      end
      record_event(action: "terminal_gate_armed", fleet_key: key, fleet_id: fleet.fetch("fleet_id"),
                   worker_indices: indices, reason: reason)
      gate.merge("fleet_key" => key)
    end

    def begin_graceful!(fleet_key:, worker_indices:, drain_timeout_seconds: DEFAULT_DRAIN_TIMEOUT_SECONDS,
                        reason: "operator_graceful_shutdown")
      key = RunpodFleetNamespace.normalize_key(fleet_key)
      drain_timeout_seconds = positive_float(drain_timeout_seconds, "drain timeout seconds")
      fleet, indices = active_selection!(key, worker_indices)
      now = utc_now
      gate = {
        "fleet_id" => fleet.fetch("fleet_id"),
        "worker_indices" => indices,
        "status" => "draining",
        "reason" => reason.to_s,
        "requested_at_utc" => now.iso8601,
        "idle_since_utc" => nil,
        "idle_seconds" => 0.0,
        "drain_started_at_utc" => now.iso8601,
        "drain_timeout_seconds" => drain_timeout_seconds,
        "last_error" => nil
      }
      with_lock do
        data = state
        data.fetch("gates")[key] = gate
        write_state(data)
      end
      record_event(action: "drain", fleet_key: key, fleet_id: fleet.fetch("fleet_id"),
                   worker_indices: indices, reason: reason)
      gate.merge("fleet_key" => key)
    end

    def keep!(fleet_key)
      key = RunpodFleetNamespace.normalize_key(fleet_key)
      removed = nil
      with_lock do
        data = state
        removed = data.fetch("gates").delete(key)
        write_state(data)
      end
      if removed
        record_event(action: "keep", fleet_key: key, fleet_id: removed.fetch("fleet_id"),
                     worker_indices: removed.fetch("worker_indices"), reason: "operator_keep")
      end
      removed
    end

    def dispatch_gate(fleet_key:, fleet_id: nil, worker_indices: [])
      key = RunpodFleetNamespace.normalize_key(fleet_key)
      gate = state.fetch("gates")[key]
      return allowed_gate("shutdown.ready", "no lifecycle shutdown gate is active") unless gate
      return allowed_gate("shutdown.ready", "shutdown gate belongs to a different fleet generation") if fleet_id && gate["fleet_id"].to_s != fleet_id.to_s

      selected = Array(worker_indices).map { |value| Integer(value) }.uniq
      overlap = selected.empty? || !(selected & gate.fetch("worker_indices").map { |value| Integer(value) }).empty?
      return allowed_gate("shutdown.ready", "selected workers do not overlap the lifecycle shutdown gate") unless overlap

      case gate.fetch("status")
      when "pending"
        allowed_gate("shutdown.pending", "terminal gate is armed but still admits work; activity resets its inactivity countdown")
      when "draining"
        blocked_gate("shutdown.draining", "selected workers are draining; in-flight inference may finish but no new jobs may start")
      when "timed_out"
        blocked_gate("shutdown.timed_out", "graceful drain timed out; operator input is required before new work may start")
      else
        blocked_gate("shutdown.state", "unsupported shutdown gate state #{gate['status'].inspect}")
      end
    rescue ArgumentError, TypeError => e
      blocked_gate("shutdown.state", "invalid shutdown gate: #{e.message}")
    end

    def run_graceful!(fleet_key:, worker_indices:, drain_timeout_seconds: DEFAULT_DRAIN_TIMEOUT_SECONDS,
                      reason: "operator_graceful_shutdown", poll_seconds: DEFAULT_POLL_SECONDS)
      key = RunpodFleetNamespace.normalize_key(fleet_key)
      begin_graceful!(fleet_key: key, worker_indices:, drain_timeout_seconds:, reason:)
      poll_seconds = positive_float(poll_seconds, "poll seconds")
      loop do
        result = process_gate!(key)
        return true if result == "destroyed" || result == "gone"
        return false if result == "timed_out"
        @sleeper.call(poll_seconds)
      end
    end

    def force_shutdown!(fleet_key:, worker_indices:, reason: "operator_force_shutdown")
      key = RunpodFleetNamespace.normalize_key(fleet_key)
      gate = begin_graceful!(fleet_key: key, worker_indices:, drain_timeout_seconds: DEFAULT_DRAIN_TIMEOUT_SECONDS,
                             reason: reason)
      destroy_gate!(key, gate, force: true)
      true
    end

    def watch_once
      keys = state.fetch("gates").keys.sort
      keys.each { |key| process_gate!(key) }
      status_snapshot
    end

    def watch(poll_seconds: DEFAULT_POLL_SECONDS)
      poll_seconds = positive_float(poll_seconds, "poll seconds")
      @out.puts format("RunPod shutdown watchdog started (poll %.1fs).", poll_seconds)
      loop do
        snapshot = watch_once
        return snapshot if snapshot.fetch("gates").empty?
        @sleeper.call(poll_seconds)
      end
    end

    def status_snapshot(now: utc_now)
      gates = state.fetch("gates").transform_values do |gate|
        copy = Marshal.load(Marshal.dump(gate))
        if copy["status"] == "pending" && copy["idle_since_utc"]
          elapsed = [now - parse_time(copy.fetch("idle_since_utc"), "idle_since_utc"), 0.0].max
          copy["idle_remaining_seconds"] = [Float(copy.fetch("idle_seconds")) - elapsed, 0.0].max
        end
        if %w[draining timed_out].include?(copy["status"]) && copy["drain_started_at_utc"]
          elapsed = [now - parse_time(copy.fetch("drain_started_at_utc"), "drain_started_at_utc"), 0.0].max
          copy["drain_remaining_seconds"] = [Float(copy.fetch("drain_timeout_seconds")) - elapsed, 0.0].max
        end
        copy
      end
      { "gates" => gates, "watchdog_pid" => watchdog_pid }
    end

    def render(snapshot = status_snapshot, fleet_aliases: [])
      aliases = Array(fleet_aliases).to_h { |row| [row.fetch("fleet_key").to_s, row.fetch("alias").to_s] }
      gates = snapshot.fetch("gates")
      lines = ["RunPod shutdown lifecycle"]
      if gates.empty?
        lines << "  Pending shutdown gates: none"
      else
        gates.sort.each do |fleet_key, gate|
          alias_label = aliases[fleet_key]
          prefix = alias_label.to_s.empty? ? fleet_key : "#{alias_label} #{fleet_key}"
          workers = gate.fetch("worker_indices").map { |index| "burst_#{index}" }.join(",")
          keep = "bin/rpof keep #{fleet_key}"
          selector = "--workers #{gate.fetch('worker_indices').join(',')}"
          force = "bin/rpof shutdown --fleet #{fleet_key} #{selector} --force"
          case gate.fetch("status")
          when "pending"
            if gate["idle_remaining_seconds"]
              lines << "  #{prefix}: TERMINAL -> shutdown in #{format_duration(gate.fetch('idle_remaining_seconds'))} idle (#{workers})"
            else
              lines << "  #{prefix}: TERMINAL waiting for inactivity; activity resets #{format_duration(gate.fetch("idle_seconds"))} countdown (#{workers})"
            end
            lines << "    KEEP: #{keep}"
          when "draining"
            lines << "  #{prefix}: DRAINING; no new work; #{format_duration(gate.fetch('drain_remaining_seconds', 0.0))} until timeout (#{workers})"
            lines << "    KEEP: #{keep}"
          when "timed_out"
            lines << "  #{prefix}: DRAIN TIMEOUT — INPUT REQUIRED (#{workers})"
            lines << "    KEEP: #{keep}"
            lines << "    FORCE: #{force}"
          end
          lines << "    Last error: #{gate['last_error']}" if gate["last_error"]
        end
      end
      lines << "  Watchdog PID: #{snapshot['watchdog_pid'] || '-'}"
      lines.join("\n") + "\n"
    end

    def empty?
      state.fetch("gates").empty?
    end

    def watchdog_pid
      return nil unless File.file?(pid_path)
      pid = Integer(File.read(pid_path).strip)
      Process.kill(0, pid)
      pid
    rescue Errno::ESRCH, ArgumentError, TypeError
      nil
    rescue Errno::EPERM
      pid
    end

    def pid_path
      File.join(root, PID_FILE)
    end

    def log_path
      File.join(root, LOG_FILE)
    end

    private

    def process_gate!(fleet_key)
      gate = state.fetch("gates")[fleet_key]
      return "gone" unless gate
      namespace = namespace_for(fleet_key)
      fleet_state = RunpodFleetState.new(root: namespace.state_root, local_port_base: namespace.local_port_base)
      fleet = fleet_state.current
      unless fleet && fleet["status"] == "active" && fleet.fetch("fleet_id").to_s == gate.fetch("fleet_id").to_s
        clear_gate!(fleet_key)
        return "gone"
      end

      active_indices = active_selected_indices(fleet, gate.fetch("worker_indices"))
      if active_indices.empty?
        clear_gate!(fleet_key)
        return "gone"
      end

      now = utc_now
      statuses = inference_statuses(fleet_key, fleet_state, fleet, active_indices)
      no_activity = !statuses.empty? && statuses.values.none? { |status| status == "active" }
      safely_quiescent = !statuses.empty? && statuses.values.all? { |status| %w[idle unavailable].include?(status) }

      case gate.fetch("status")
      when "pending"
        if no_activity
          if gate["idle_since_utc"]
            idle_elapsed = now - parse_time(gate.fetch("idle_since_utc"), "idle_since_utc")
            if idle_elapsed >= Float(gate.fetch("idle_seconds"))
              transitioned = transition_to_draining!(fleet_key, gate, now)
              return "cancelled" unless transitioned
              gate = state.fetch("gates").fetch(fleet_key)
              return destroy_gate!(fleet_key, gate) if safely_quiescent
            end
          else
            update_gate!(fleet_key) { |value| value["idle_since_utc"] = now.iso8601 }
          end
        elsif gate["idle_since_utc"]
          update_gate!(fleet_key) { |value| value["idle_since_utc"] = nil }
        end
      when "draining"
        return destroy_gate!(fleet_key, gate) if safely_quiescent

        elapsed = now - parse_time(gate.fetch("drain_started_at_utc"), "drain_started_at_utc")
        if elapsed >= Float(gate.fetch("drain_timeout_seconds"))
          update_gate!(fleet_key) { |value| value["status"] = "timed_out" }
          record_event(action: "drain_timeout", fleet_key:, fleet_id: gate.fetch("fleet_id"),
                       worker_indices: active_indices, reason: gate.fetch("reason"))
          return "timed_out"
        end
      when "timed_out"
        return "timed_out"
      end
      gate.fetch("status")
    rescue Error => e
      update_gate!(fleet_key) { |value| value["last_error"] = e.message } rescue nil
      @out.puts "WARNING: shutdown gate #{fleet_key}: #{e.message}"
      "error"
    end

    def transition_to_draining!(fleet_key, gate, now)
      updated = update_gate!(fleet_key) do |value|
        value["status"] = "draining"
        value["drain_started_at_utc"] = now.iso8601
        value["last_error"] = nil
      end
      return false unless updated

      record_event(action: "drain", fleet_key:, fleet_id: gate.fetch("fleet_id"),
                   worker_indices: gate.fetch("worker_indices"), reason: gate.fetch("reason"))
      true
    end

    def destroy_gate!(fleet_key, gate, force: false)
      unless force
        current_gate = state.fetch("gates")[fleet_key]
        return "cancelled" unless current_gate
        return "cancelled" unless current_gate.fetch("fleet_id").to_s == gate.fetch("fleet_id").to_s
        return current_gate.fetch("status") unless current_gate.fetch("status") == "draining"
        gate = current_gate
      end
      namespace = namespace_for(fleet_key)
      fleet_state = RunpodFleetState.new(root: namespace.state_root, local_port_base: namespace.local_port_base)
      fleet = fleet_state.current
      return clear_gate!(fleet_key) || "gone" unless fleet && fleet.fetch("fleet_id").to_s == gate.fetch("fleet_id").to_s

      indices = active_selected_indices(fleet, gate.fetch("worker_indices"))
      return clear_gate!(fleet_key) || "gone" if indices.empty?
      unless force
        statuses = inference_statuses(fleet_key, fleet_state, fleet, indices)
        safely_quiescent = !statuses.empty? && statuses.values.all? { |status| %w[idle unavailable].include?(status) }
        return "draining" unless safely_quiescent
      end

      stop_tunnels(fleet_state, fleet, indices)
      destroyed = destroy_workers(namespace, indices, gate.fetch("reason"))
      record_event(action: force ? "force_destroy" : "destroy", fleet_key:, fleet_id: gate.fetch("fleet_id"),
                   worker_indices: destroyed, reason: gate.fetch("reason"))
      clear_gate!(fleet_key)
      "destroyed"
    rescue RunpodFleet::Error, RunpodClient::Error, RunpodFleetState::Error => e
      raise Error, "verified shutdown failed for #{fleet_key}: #{e.message}"
    end

    def destroy_workers(namespace, indices, reason)
      return Array(@destroyer.call(namespace, indices, reason)) if @destroyer
      raise Error, "RUNPOD_API_KEY is required for shutdown" unless @client

      RunpodFleet.new(
        client: @client,
        env_path: namespace.env_path,
        state_root: namespace.state_root,
        fleet_key: namespace.fleet_key,
        local_port_base: namespace.local_port_base
      ).destroy(
        worker_indices: indices,
        verify_absent: true,
        destroy_reason: reason,
        verify_wait_seconds: PROVIDER_VERIFY_SECONDS,
        verify_poll_seconds: PROVIDER_VERIFY_POLL_SECONDS
      )
    end

    def stop_tunnels(fleet_state, fleet, indices)
      return @tunnel_stopper.call(fleet_state, fleet, indices) if @tunnel_stopper
      tunnel_root = fleet_state.artifact_dir(fleet.fetch("fleet_id"), "tunnels")
      return unless File.file?(File.join(tunnel_root, RunpodTunnels::STATE_FILE))

      RunpodTunnels.new(fleet_state:, repo_root: repo_root).stop(worker_indices: indices)
    rescue RunpodTunnels::Error => e
      @out.puts "WARNING: could not stop managed tunnel(s) before shutdown: #{e.message}; continuing provider teardown."
    end

    def inference_statuses(fleet_key, fleet_state, fleet, indices)
      if @activity_reader
        return @activity_reader.call(fleet_key, fleet, indices).transform_keys { |key| Integer(key) }
      end
      activity = RunpodActivity.new(fleet_state:).snapshot(fleet)
      observations = activity.fetch("workers")
      indices.to_h do |index|
        observation = observations.fetch(index) { { "status" => "unknown" } }
        [index, observation.fetch("status").to_s]
      end
    rescue KeyError, ArgumentError, TypeError => e
      raise Error, "could not observe shutdown activity: #{e.message}"
    end

    def lifecycle_for(fleet_key)
      return @lifecycle_reader.call(fleet_key).to_s if @lifecycle_reader
      RunpodCostControl.new(root:, repo_root:).fleet_lifecycle(fleet_key)
    rescue RunpodCostControl::Error => e
      raise Error, e.message
    end

    def active_selection!(fleet_key, worker_indices)
      namespace = namespace_for(fleet_key)
      fleet_state = RunpodFleetState.new(root: namespace.state_root, local_port_base: namespace.local_port_base)
      fleet = fleet_state.current
      raise Error, "no current active RunPod fleet exists for #{fleet_key}" unless fleet && fleet["status"] == "active"

      requested = Array(worker_indices).map { |value| RunpodWorkers.validate_index(value) }.uniq.sort
      raise Error, "no workers selected" if requested.empty?
      by_index = Array(fleet.fetch("workers")).to_h { |worker| [Integer(worker.fetch("index")), worker] }
      missing = requested.reject { |index| by_index.key?(index) }
      raise Error, "fleet #{fleet_key} does not contain worker index(es): #{missing.join(', ')}" unless missing.empty?
      active = requested.select { |index| by_index.fetch(index)["status"] == "active" }
      raise Error, "selected workers are already terminal" if active.empty?
      [fleet, active]
    rescue RunpodFleetNamespace::Error, RunpodFleetState::Error, RunpodWorkers::Error,
           KeyError, ArgumentError, TypeError => e
      raise Error, e.message
    end

    def active_selected_indices(fleet, requested)
      requested = Array(requested).map { |value| Integer(value) }
      Array(fleet.fetch("workers")).filter_map do |worker|
        index = Integer(worker.fetch("index"))
        index if requested.include?(index) && worker["status"] == "active"
      end
    end

    def current_fleet_id(fleet_key)
      namespace = namespace_for(fleet_key)
      RunpodFleetState.new(root: namespace.state_root, local_port_base: namespace.local_port_base).current&.fetch("fleet_id", nil)
    rescue StandardError
      nil
    end

    def allowed_gate(code, detail)
      { "allowed" => true, "code" => code, "detail" => detail }
    end

    def blocked_gate(code, detail)
      { "allowed" => false, "code" => code, "detail" => detail }
    end

    def clear_gate!(fleet_key)
      with_lock do
        data = state
        data.fetch("gates").delete(fleet_key)
        write_state(data)
      end
      true
    end

    def update_gate!(fleet_key)
      with_lock do
        data = state
        gate = data.fetch("gates").fetch(fleet_key)
        yield gate
        write_state(data)
      end
    rescue KeyError
      nil
    end

    def state
      return default_state unless File.file?(state_path)
      normalize_state(JSON.parse(File.read(state_path)))
    rescue JSON::ParserError, SystemCallError => e
      raise Error, "shutdown state is unreadable: #{e.message}"
    end

    def default_state
      { "schema_version" => SCHEMA_VERSION, "gates" => {} }
    end

    def normalize_state(data)
      raise Error, "shutdown state must be an object" unless data.is_a?(Hash)
      result = default_state.merge(data.transform_keys(&:to_s))
      schema = Integer(result.fetch("schema_version"))
      raise Error, "unsupported shutdown schema_version #{schema}" unless schema == SCHEMA_VERSION
      gates = result.fetch("gates")
      raise Error, "shutdown gates must be an object" unless gates.is_a?(Hash)
      result["gates"] = gates.transform_keys { |key| RunpodFleetNamespace.normalize_key(key) }
      result
    rescue ArgumentError, TypeError, RunpodFleetNamespace::Error => e
      raise Error, "invalid shutdown state: #{e.message}"
    end

    def write_state(data)
      write_json(state_path, normalize_state(data))
    end

    def record_event(action:, fleet_key:, fleet_id:, worker_indices:, reason:)
      event = {
        "at_utc" => utc_now.iso8601,
        "action" => action.to_s,
        "fleet_key" => fleet_key.to_s,
        "fleet_id" => fleet_id.to_s,
        "worker_indices" => Array(worker_indices).map { |value| Integer(value) }.sort,
        "reason" => reason.to_s
      }
      FileUtils.mkdir_p(root)
      File.open(events_path, "a", 0o600) { |file| file.write(JSON.generate(event) + "\n") }
      event
    end

    def namespace_for(fleet_key)
      RunpodFleetNamespace.new(root:, repo_root:, fleet_key:)
    end

    def with_lock
      FileUtils.mkdir_p(root)
      File.open(lock_path, File::RDWR | File::CREAT, 0o600) do |lock|
        lock.flock(File::LOCK_EX)
        yield
      ensure
        lock.flock(File::LOCK_UN) rescue nil
      end
    end

    def write_json(path, data)
      FileUtils.mkdir_p(File.dirname(path))
      tmp = "#{path}.tmp.#{$$}.#{Thread.current.object_id}"
      File.write(tmp, JSON.pretty_generate(data) + "\n")
      File.chmod(0o600, tmp)
      File.rename(tmp, path)
    ensure
      File.delete(tmp) if defined?(tmp) && tmp && File.exist?(tmp)
    end

    def state_path = File.join(root, STATE_FILE)
    def events_path = File.join(root, EVENTS_FILE)
    def lock_path = File.join(root, LOCK_FILE)

    def parse_time(value, label)
      time = value.is_a?(Time) ? value : Time.parse(value.to_s)
      time.utc
    rescue ArgumentError
      raise Error, "#{label} is invalid: #{value.inspect}"
    end

    def positive_float(value, label)
      number = Float(value)
      raise Error, "#{label} must be positive" unless number.positive?
      number
    rescue ArgumentError, TypeError
      raise Error, "#{label} must be numeric"
    end

    def format_duration(seconds)
      total = [Float(seconds), 0.0].max.ceil
      minutes = total / 60
      secs = total % 60
      format("%02d:%02d", minutes, secs)
    end

    def utc_now
      value = @wall_clock.call
      value = Time.parse(value.to_s) unless value.is_a?(Time)
      value.utc
    rescue ArgumentError
      raise Error, "shutdown clock is invalid"
    end
  end
end
