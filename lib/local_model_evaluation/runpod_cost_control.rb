# frozen_string_literal: true

require "fileutils"
require "json"
require "time"
require_relative "runpod_activity"
require_relative "runpod_client"
require_relative "runpod_fleet"
require_relative "runpod_fleet_namespace"
require_relative "runpod_fleet_state"
require_relative "runpod_status"
require_relative "runpod_tunnels"

module LocalModelEvaluation
  # Runtime cost guard for all managed RunPod fleets.
  #
  # The legacy per-fleet lease remains the hard backwards-compatible breaker.
  # This control plane adds graceful draining, ephemeral reaping, an aggregate
  # dispatch cap, and short-lived aggregate-cap overrides without changing the
  # frozen AFIO/RPOF request contract.
  class RunpodCostControl
    SCHEMA_VERSION = 1
    POLICY_FILE = "cost-policy.json"
    STATE_FILE = "cost-control-state.json"
    EVENTS_FILE = "cost-events.jsonl"
    LOCK_FILE = ".cost-control.lock"
    PID_FILE = "cost-watchdog.pid"
    LOG_FILE = "cost-watchdog.log"
    DEFAULT_POLL_SECONDS = 15.0
    DEFAULT_IDLE_TIMEOUT_SECONDS = 180.0
    DEFAULT_UNAVAILABLE_TIMEOUT_SECONDS = 90.0
    LIFECYCLES = %w[persistent ephemeral].freeze

    class Error < StandardError; end

    def initialize(root:, repo_root:, client: nil, out: $stdout, wall_clock: nil, sleeper: nil)
      @root = File.expand_path(root)
      @repo_root = File.expand_path(repo_root)
      @client = client
      @out = out
      @wall_clock = wall_clock || -> { Time.now.utc }
      @sleeper = sleeper || ->(seconds) { sleep seconds }
    end

    attr_reader :root, :repo_root

    def enabled?
      policy.fetch("enabled") == true
    end

    def enable!(max_total_hourly_usd: nil)
      update_policy do |data|
        data["enabled"] = true
        data["max_total_hourly_usd"] = positive_float(max_total_hourly_usd, "max total hourly cost") if max_total_hourly_usd
      end
    end

    def disable!
      update_policy { |data| data["enabled"] = false }
      update_state do |data|
        data["draining_fleets"] = {}
        data["worker_observations"] = {}
        data["policy_baselines"] = {}
      end
    end

    def set_limit!(max_total_hourly_usd)
      value = positive_float(max_total_hourly_usd, "max total hourly cost")
      update_policy { |data| data["max_total_hourly_usd"] = value }
    end

    def set_override!(max_total_hourly_usd:, minutes:)
      limit = positive_float(max_total_hourly_usd, "override max total hourly cost")
      seconds = positive_float(minutes, "override minutes") * 60.0
      now = utc_now
      update_policy do |data|
        data["override"] = {
          "max_total_hourly_usd" => limit,
          "started_at_utc" => now.iso8601,
          "expires_at_utc" => (now + seconds).iso8601
        }
      end
    end

    def clear_override!
      update_policy { |data| data.delete("override") }
    end

    def configure_fleet!(fleet_key:, lifecycle:, idle_timeout_seconds: nil, unavailable_timeout_seconds: nil,
                         soft_max_runtime_seconds: nil, hard_max_runtime_seconds: nil,
                         soft_max_spend_usd: nil, hard_max_spend_usd: nil)
      key = RunpodFleetNamespace.normalize_key(fleet_key)
      lifecycle = lifecycle.to_s.downcase
      raise Error, "lifecycle must be one of: #{LIFECYCLES.join(', ')}" unless LIFECYCLES.include?(lifecycle)

      values = {
        "lifecycle" => lifecycle,
        "idle_timeout_seconds" => optional_positive_float(idle_timeout_seconds, "idle timeout"),
        "unavailable_timeout_seconds" => optional_positive_float(unavailable_timeout_seconds, "unavailable timeout"),
        "soft_max_runtime_seconds" => optional_positive_float(soft_max_runtime_seconds, "soft max runtime"),
        "hard_max_runtime_seconds" => optional_positive_float(hard_max_runtime_seconds, "hard max runtime"),
        "soft_max_spend_usd" => optional_positive_float(soft_max_spend_usd, "soft max spend"),
        "hard_max_spend_usd" => optional_positive_float(hard_max_spend_usd, "hard max spend")
      }
      if lifecycle == "ephemeral"
        values["idle_timeout_seconds"] ||= DEFAULT_IDLE_TIMEOUT_SECONDS
        values["unavailable_timeout_seconds"] ||= DEFAULT_UNAVAILABLE_TIMEOUT_SECONDS
      end
      validate_threshold_order!(values, "runtime", "soft_max_runtime_seconds", "hard_max_runtime_seconds")
      validate_threshold_order!(values, "spend", "soft_max_spend_usd", "hard_max_spend_usd")

      update_policy do |data|
        data["fleets"] ||= {}
        data.fetch("fleets")[key] = values.compact
      end
      update_state do |data|
        data.fetch("draining_fleets", {}).delete(key)
        data.fetch("worker_observations", {}).delete(key)
        data.fetch("policy_baselines", {}).delete(key)
      end
    end

    def unconfigure_fleet!(fleet_key)
      key = RunpodFleetNamespace.normalize_key(fleet_key)
      update_policy { |data| data.fetch("fleets", {}).delete(key) }
      update_state do |data|
        data.fetch("draining_fleets", {}).delete(key)
        data.fetch("worker_observations", {}).delete(key)
        data.fetch("policy_baselines", {}).delete(key)
      end
    end

    def effective_max_total_hourly_usd(now: utc_now)
      data = policy
      override = valid_override(data["override"], now:)
      return Float(override.fetch("max_total_hourly_usd")) if override

      Float(data.fetch("max_total_hourly_usd", RunpodFleetNamespace::DEFAULT_MAX_TOTAL_HOURLY_USD))
    rescue ArgumentError, TypeError
      raise Error, "cost policy contains an invalid aggregate hourly limit"
    end

    def current_total_hourly_usd
      root_namespace.total_active_hourly_usd
    rescue RunpodFleetNamespace::Error => e
      raise Error, e.message
    end

    # Cost control may only tighten a provisioning command's existing cap. A
    # temporary runtime override never silently raises a caller-provided cap.
    def provisioning_cap(requested_max_total_hourly_usd)
      requested = positive_float(requested_max_total_hourly_usd, "requested aggregate hourly cap")
      return requested unless enabled?

      [requested, effective_max_total_hourly_usd].min
    end

    def dispatch_gate(fleet_key:, fleet_id: nil)
      return { "allowed" => true, "code" => "cost.disabled", "detail" => "runtime cost control is disabled" } unless enabled?

      key = RunpodFleetNamespace.normalize_key(fleet_key)
      if draining?(key, fleet_id:)
        return {
          "allowed" => false,
          "code" => "cost.draining",
          "detail" => "fleet #{key} is draining; existing inference may finish but no new jobs may start"
        }
      end

      rate = current_total_hourly_usd
      limit = effective_max_total_hourly_usd
      if rate > limit
        return {
          "allowed" => false,
          "code" => "cost.aggregate_cap",
          "detail" => format("managed rate $%.4f/hr exceeds runtime cap $%.4f/hr", rate, limit)
        }
      end

      {
        "allowed" => true,
        "code" => "cost.ready",
        "detail" => format("managed rate $%.4f/hr is within runtime cap $%.4f/hr", rate, limit)
      }
    rescue RunpodFleetNamespace::Error => e
      { "allowed" => false, "code" => "cost.policy", "detail" => e.message }
    end

    def draining?(fleet_key, fleet_id: nil)
      key = RunpodFleetNamespace.normalize_key(fleet_key)
      entry = state.fetch("draining_fleets", {})[key]
      return false unless entry
      return true unless fleet_id

      entry["fleet_id"].to_s == fleet_id.to_s
    end

    def watch_once
      return status_snapshot.merge("action" => "disabled") unless enabled?
      raise Error, "RUNPOD_API_KEY is required for destructive cost-control enforcement" unless @client

      now = utc_now
      policy_data = policy
      state_data = state
      active = active_entries
      active_by_key = active.to_h { |entry| [entry.fetch("fleet_key"), entry] }
      clean_stale_state!(state_data, active_by_key)

      policy_data.fetch("fleets", {}).each do |fleet_key, fleet_policy|
        entry = active_by_key[fleet_key]
        next unless entry

        ensure_policy_baseline!(entry, state_data, now)
        apply_fleet_policy!(entry, fleet_policy, state_data, now)
      end

      write_state(state_data)
      status_snapshot(now: now)
    end

    def watch(poll_seconds: DEFAULT_POLL_SECONDS)
      poll_seconds = positive_float(poll_seconds, "poll seconds")
      @out.puts format("RunPod cost watchdog started (poll %.1fs).", poll_seconds)
      loop do
        begin
          snapshot = watch_once
          if snapshot["over_aggregate_cap"]
            @out.puts format(
              "WARNING: managed RunPod rate $%.4f/hr exceeds runtime cap $%.4f/hr; new dispatch is blocked.",
              snapshot.fetch("current_total_hourly_usd"),
              snapshot.fetch("effective_max_total_hourly_usd")
            )
          end
        rescue Error => e
          @out.puts "WARNING: #{e.message}; cost watchdog will retry."
        end
        @sleeper.call(poll_seconds)
      end
    end

    def status_snapshot(now: utc_now)
      data = policy
      override = valid_override(data["override"], now:)
      rate = current_total_hourly_usd
      limit = effective_max_total_hourly_usd(now:)
      state_data = state
      {
        "enabled" => data.fetch("enabled") == true,
        "current_total_hourly_usd" => rate,
        "effective_max_total_hourly_usd" => limit,
        "over_aggregate_cap" => data.fetch("enabled") == true && rate > limit,
        "override" => override,
        "configured_fleets" => data.fetch("fleets", {}),
        "draining_fleets" => state_data.fetch("draining_fleets", {}),
        "watchdog_pid" => watchdog_pid
      }
    end

    def render(snapshot = status_snapshot)
      lines = []
      lines << "RunPod cost control"
      lines << "  State: #{snapshot.fetch('enabled') ? 'ENABLED' : 'DISABLED'}"
      lines << format("  Managed rate: $%.4f/hr", snapshot.fetch("current_total_hourly_usd"))
      lines << format("  Runtime aggregate cap: $%.4f/hr", snapshot.fetch("effective_max_total_hourly_usd"))
      lines << "  Dispatch gate: #{snapshot.fetch('over_aggregate_cap') ? 'BLOCKED (over cap)' : 'OPEN'}"
      if (override = snapshot["override"])
        lines << format("  Temporary override: $%.4f/hr until %s",
                        override.fetch("max_total_hourly_usd"), override.fetch("expires_at_utc"))
      end
      lines << "  Watchdog PID: #{snapshot['watchdog_pid'] || '-'}"
      draining = snapshot.fetch("draining_fleets")
      lines << "  Draining fleets: #{draining.empty? ? '-' : draining.keys.sort.join(', ')}"
      lines << "  Fleet policies: #{snapshot.fetch('configured_fleets').length}"
      lines.join("\n") + "\n"
    end

    def record_event(action:, fleet_key:, fleet_id:, worker_indices:, reason:, detail: nil)
      event = {
        "at_utc" => utc_now.iso8601,
        "action" => action.to_s,
        "fleet_key" => fleet_key.to_s,
        "fleet_id" => fleet_id.to_s,
        "worker_indices" => Array(worker_indices).map { |value| Integer(value) }.sort,
        "reason" => reason.to_s
      }
      event["detail"] = detail.to_s unless detail.to_s.empty?
      FileUtils.mkdir_p(root)
      File.open(events_path, "a", 0o600) { |file| file.write(JSON.generate(event) + "\n") }
      event
    rescue ArgumentError, TypeError => e
      raise Error, "could not record cost event: #{e.message}"
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

    def policy
      return default_policy unless File.file?(policy_path)
      normalize_policy(JSON.parse(File.read(policy_path)))
    rescue JSON::ParserError, SystemCallError => e
      raise Error, "cost policy is unreadable: #{e.message}"
    end

    def state
      return default_state unless File.file?(state_path)
      normalize_state(JSON.parse(File.read(state_path)))
    rescue JSON::ParserError, SystemCallError => e
      raise Error, "cost control state is unreadable: #{e.message}"
    end

    def update_policy
      with_lock do
        data = policy
        yield data
        write_json(policy_path, normalize_policy(data))
      end
      policy
    end

    def update_state
      with_lock do
        data = state
        yield data
        write_json(state_path, normalize_state(data))
      end
      state
    end

    def write_state(data)
      with_lock { write_json(state_path, normalize_state(data)) }
    end

    def default_policy
      {
        "schema_version" => SCHEMA_VERSION,
        "enabled" => false,
        "max_total_hourly_usd" => RunpodFleetNamespace::DEFAULT_MAX_TOTAL_HOURLY_USD,
        "fleets" => {}
      }
    end

    def default_state
      {
        "schema_version" => SCHEMA_VERSION,
        "draining_fleets" => {},
        "worker_observations" => {},
        "policy_baselines" => {}
      }
    end

    def normalize_policy(data)
      raise Error, "cost policy must be an object" unless data.is_a?(Hash)
      schema = Integer(data.fetch("schema_version", SCHEMA_VERSION))
      raise Error, "unsupported cost policy schema_version #{schema}" unless schema == SCHEMA_VERSION

      result = default_policy.merge(data.transform_keys(&:to_s))
      result["max_total_hourly_usd"] = positive_float(result["max_total_hourly_usd"], "max total hourly cost")
      fleets = result.fetch("fleets", {})
      raise Error, "cost policy fleets must be an object" unless fleets.is_a?(Hash)
      result["fleets"] = fleets.transform_keys { |key| RunpodFleetNamespace.normalize_key(key) }
      result
    rescue KeyError, ArgumentError, TypeError => e
      raise Error, "invalid cost policy: #{e.message}"
    end

    def normalize_state(data)
      raise Error, "cost control state must be an object" unless data.is_a?(Hash)
      result = default_state.merge(data.transform_keys(&:to_s))
      result["draining_fleets"] = result.fetch("draining_fleets", {}).to_h
      result["worker_observations"] = result.fetch("worker_observations", {}).to_h
      result["policy_baselines"] = result.fetch("policy_baselines", {}).to_h
      result
    rescue ArgumentError, TypeError => e
      raise Error, "invalid cost control state: #{e.message}"
    end

    def valid_override(value, now:)
      return nil unless value.is_a?(Hash)
      limit = positive_float(value["max_total_hourly_usd"], "override max total hourly cost")
      expires = parse_time(value["expires_at_utc"], "override expires_at_utc")
      return nil if now >= expires

      value.merge("max_total_hourly_usd" => limit, "expires_at_utc" => expires.iso8601)
    rescue Error
      nil
    end

    def active_entries
      keys = [RunpodFleetNamespace::DEFAULT_KEY, *root_namespace.registered_fleet_keys].uniq
      keys.filter_map do |fleet_key|
        namespace = namespace_for(fleet_key)
        fleet_state = RunpodFleetState.new(root: namespace.state_root, local_port_base: namespace.local_port_base)
        fleet = fleet_state.current
        next unless fleet && fleet["status"] == "active"

        activity = RunpodActivity.new(fleet_state: fleet_state)
        status = RunpodStatus.new(fleet_state: fleet_state, client: @client, activity_monitor: activity).snapshot
        {
          "fleet_key" => fleet_key,
          "namespace" => namespace,
          "fleet_state" => fleet_state,
          "fleet" => fleet,
          "status" => status
        }
      end
    end

    def apply_fleet_policy!(entry, fleet_policy, state_data, now)
      fleet_key = entry.fetch("fleet_key")
      fleet = entry.fetch("fleet")
      fleet_id = fleet.fetch("fleet_id")
      snapshot = entry.fetch("status")
      policy = fleet_policy.transform_keys(&:to_s)
      lifecycle = policy.fetch("lifecycle", "persistent").to_s
      raise Error, "invalid lifecycle #{lifecycle.inspect} for fleet #{fleet_key}" unless LIFECYCLES.include?(lifecycle)

      baseline = state_data.fetch("policy_baselines").fetch(fleet_key)
      hard_reasons = threshold_reasons(snapshot, baseline, policy, prefix: "hard")
      unless hard_reasons.empty?
        destroy_entry!(entry, active_worker_indices(fleet), reason: hard_reasons.join("+"), state_data: state_data)
        return
      end

      soft_reasons = threshold_reasons(snapshot, baseline, policy, prefix: "soft")
      if !soft_reasons.empty? && mark_draining!(state_data, fleet_key, fleet_id, soft_reasons, now)
        write_state(state_data)
      end

      if draining_entry?(state_data, fleet_key, fleet_id) && all_active_workers_idle?(snapshot)
        destroy_entry!(entry, active_worker_indices(fleet), reason: "soft_limit_drained", state_data: state_data)
        return
      end

      apply_ephemeral_reaping!(entry, policy, state_data, now) if lifecycle == "ephemeral"
    end

    def threshold_reasons(snapshot, baseline, policy, prefix:)
      reasons = []
      runtime = optional_positive_float(policy["#{prefix}_max_runtime_seconds"], "#{prefix} max runtime")
      spend = optional_positive_float(policy["#{prefix}_max_spend_usd"], "#{prefix} max spend")
      elapsed = [Float(snapshot.fetch("tracked_elapsed_seconds")) - Float(baseline.fetch("tracked_elapsed_seconds")), 0.0].max
      accrued = [Float(snapshot.fetch("estimated_accrued_cost_usd")) - Float(baseline.fetch("estimated_accrued_cost_usd")), 0.0].max
      reasons << "#{prefix}_runtime_limit" if runtime && elapsed >= runtime
      reasons << "#{prefix}_spend_limit" if spend && accrued >= spend
      reasons
    end

    def ensure_policy_baseline!(entry, state_data, now)
      fleet_key = entry.fetch("fleet_key")
      fleet_id = entry.fetch("fleet").fetch("fleet_id")
      baselines = state_data.fetch("policy_baselines")
      current = baselines[fleet_key]
      return if current && current["fleet_id"].to_s == fleet_id.to_s

      snapshot = entry.fetch("status")
      baselines[fleet_key] = {
        "fleet_id" => fleet_id,
        "observed_at_utc" => now.iso8601,
        "tracked_elapsed_seconds" => Float(snapshot.fetch("tracked_elapsed_seconds")),
        "estimated_accrued_cost_usd" => Float(snapshot.fetch("estimated_accrued_cost_usd"))
      }
    end

    def mark_draining!(state_data, fleet_key, fleet_id, reasons, now)
      drains = state_data.fetch("draining_fleets")
      current = drains[fleet_key]
      return false if current && current["fleet_id"].to_s == fleet_id.to_s

      drains[fleet_key] = {
        "fleet_id" => fleet_id,
        "since_utc" => now.iso8601,
        "reasons" => reasons
      }
      record_event(
        action: "drain",
        fleet_key:,
        fleet_id:,
        worker_indices: [],
        reason: reasons.join("+")
      )
      @out.puts "Cost control: draining #{fleet_key} (#{reasons.join('+')}); no new jobs will be assigned."
      true
    end

    def apply_ephemeral_reaping!(entry, policy, state_data, now)
      fleet_key = entry.fetch("fleet_key")
      fleet = entry.fetch("fleet")
      fleet_id = fleet.fetch("fleet_id")
      observations = state_data.fetch("worker_observations")
      fleet_observations = observations[fleet_key] ||= {}
      live_pod_ids = []
      by_reason = Hash.new { |hash, key| hash[key] = [] }

      Array(entry.fetch("status").fetch("workers")).each do |worker|
        next unless worker.fetch("lme_status") == "active"
        pod_id = worker.fetch("pod_id").to_s
        live_pod_ids << pod_id
        inference = worker["inference_status"].to_s
        timeout = case inference
                  when "idle" then optional_positive_float(policy["idle_timeout_seconds"], "idle timeout")
                  when "unavailable" then optional_positive_float(policy["unavailable_timeout_seconds"], "unavailable timeout")
                  end
        unless timeout
          fleet_observations.delete(pod_id)
          next
        end

        observed = fleet_observations[pod_id]
        if !observed || observed["fleet_id"].to_s != fleet_id.to_s || observed["status"].to_s != inference
          fleet_observations[pod_id] = {
            "fleet_id" => fleet_id,
            "index" => Integer(worker.fetch("index")),
            "status" => inference,
            "since_utc" => now.iso8601
          }
          next
        end

        since = parse_time(observed.fetch("since_utc"), "worker observation since_utc")
        next if now - since < timeout

        by_reason["#{inference}_timeout"] << Integer(worker.fetch("index"))
      end

      fleet_observations.delete_if { |pod_id, _| !live_pod_ids.include?(pod_id) }
      by_reason.each do |reason, indices|
        if mark_draining!(state_data, fleet_key, fleet_id, [reason], now)
          write_state(state_data)
        end
        # An unavailable tunnel cannot be serving inference through RPOF, so it
        # is safe to stop billing immediately after the drain gate is durable.
        # Idle workers are allowed one more watchdog pass so any request that
        # raced the snapshot can finish before teardown.
        destroy_entry!(entry, indices, reason:, state_data: state_data) if reason == "unavailable_timeout"
      end
    end

    def destroy_entry!(entry, indices, reason:, state_data:)
      indices = Array(indices).map { |value| Integer(value) }.uniq.sort
      return if indices.empty?

      fleet_key = entry.fetch("fleet_key")
      fleet_id = entry.fetch("fleet").fetch("fleet_id")
      begin
        tunnel_root = entry.fetch("fleet_state").artifact_dir(fleet_id, "tunnels")
        tunnel_state = File.join(tunnel_root, RunpodTunnels::STATE_FILE)
        if File.file?(tunnel_state)
          RunpodTunnels.new(
            fleet_state: entry.fetch("fleet_state"),
            repo_root: repo_root
          ).stop(worker_indices: indices)
        end
      rescue RunpodTunnels::Error => e
        @out.puts "WARNING: could not stop managed tunnel(s) before cost teardown: #{e.message}"
      end

      fleet = RunpodFleet.new(
        client: @client,
        env_path: entry.fetch("namespace").env_path,
        state_root: entry.fetch("namespace").state_root,
        fleet_key:,
        local_port_base: entry.fetch("namespace").local_port_base
      )
      cleared = fleet.destroy(worker_indices: indices)
      record_event(action: "destroy", fleet_key:, fleet_id:, worker_indices: cleared, reason:)
      @out.puts "Cost control: destroyed #{cleared.map { |index| "burst_#{index}" }.join(', ')} in #{fleet_key} (#{reason})."
      state_data.fetch("worker_observations", {}).fetch(fleet_key, {}).delete_if do |_pod_id, observation|
        cleared.include?(Integer(observation.fetch("index")))
      rescue KeyError, ArgumentError, TypeError
        true
      end
      current = entry.fetch("fleet_state").current
      unless current && current["fleet_id"].to_s == fleet_id.to_s && current["status"] == "active"
        state_data.fetch("draining_fleets", {}).delete(fleet_key)
        state_data.fetch("worker_observations", {}).delete(fleet_key)
        state_data.fetch("policy_baselines", {}).delete(fleet_key)
      end
    rescue RunpodFleet::Error, RunpodClient::Error => e
      raise Error, "cost-control teardown failed for #{fleet_key}: #{e.message}"
    end

    def all_active_workers_idle?(snapshot)
      workers = Array(snapshot.fetch("workers")).select { |worker| worker.fetch("lme_status") == "active" }
      !workers.empty? && workers.all? { |worker| worker["inference_status"].to_s == "idle" }
    end

    def active_worker_indices(fleet)
      Array(fleet.fetch("workers")).filter_map do |worker|
        Integer(worker.fetch("index")) if worker["status"] == "active"
      end
    end

    def draining_entry?(state_data, fleet_key, fleet_id)
      value = state_data.fetch("draining_fleets", {})[fleet_key]
      value && value["fleet_id"].to_s == fleet_id.to_s
    end

    def clean_stale_state!(state_data, active_by_key)
      state_data.fetch("draining_fleets").delete_if do |fleet_key, drain|
        entry = active_by_key[fleet_key]
        !entry || entry.fetch("fleet").fetch("fleet_id").to_s != drain["fleet_id"].to_s
      end
      state_data.fetch("worker_observations").delete_if { |fleet_key, _| !active_by_key.key?(fleet_key) }
      state_data.fetch("policy_baselines").delete_if { |fleet_key, _| !active_by_key.key?(fleet_key) }
    end

    def root_namespace
      @root_namespace ||= RunpodFleetNamespace.new(
        root: root,
        repo_root: repo_root,
        fleet_key: RunpodFleetNamespace::DEFAULT_KEY
      )
    end

    def namespace_for(fleet_key)
      return root_namespace if fleet_key == RunpodFleetNamespace::DEFAULT_KEY

      RunpodFleetNamespace.new(root: root, repo_root: repo_root, fleet_key: fleet_key)
    end

    def policy_path
      File.join(root, POLICY_FILE)
    end

    def state_path
      File.join(root, STATE_FILE)
    end

    def events_path
      File.join(root, EVENTS_FILE)
    end

    def lock_path
      File.join(root, LOCK_FILE)
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

    def parse_time(value, label)
      time = value.is_a?(Time) ? value : Time.parse(value.to_s)
      time.utc
    rescue ArgumentError
      raise Error, "#{label} is invalid: #{value.inspect}"
    end

    def optional_positive_float(value, label)
      return nil if value.nil?
      positive_float(value, label)
    end

    def positive_float(value, label)
      number = Float(value)
      raise Error, "#{label} must be positive" unless number.positive?
      number
    rescue ArgumentError, TypeError
      raise Error, "#{label} must be numeric"
    end

    def validate_threshold_order!(values, label, soft_key, hard_key)
      soft = values[soft_key]
      hard = values[hard_key]
      return unless soft && hard
      raise Error, "soft #{label} limit must be less than hard #{label} limit" unless soft < hard
    end

    def utc_now
      value = @wall_clock.call
      value = Time.parse(value.to_s) unless value.is_a?(Time)
      value.utc
    rescue ArgumentError
      raise Error, "cost-control clock is invalid"
    end
  end
end
