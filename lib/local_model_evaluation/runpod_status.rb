# frozen_string_literal: true

require "json"
require "time"
require_relative "runpod_fleet_state"
require_relative "runpod_lease"

module LocalModelEvaluation
  class RunpodStatus
    class Error < StandardError; end

    def initialize(fleet_state:, client: nil, wall_clock: nil)
      @fleet_state = fleet_state
      @client = client
      @wall_clock = wall_clock || -> { Time.now.utc }
    end

    def snapshot
      fleet = @fleet_state.current
      return nil unless fleet

      now = utc_now
      created_at = parse_time(fleet.fetch("created_at_utc"), "fleet created_at_utc")
      workers = fleet.fetch("workers").sort_by { |worker| Integer(worker.fetch("index")) }.map do |worker|
        worker_snapshot(worker, created_at, now)
      end
      active_workers = workers.select { |worker| worker.fetch("lme_status") == "active" }
      stopped_at = if fleet["status"] == "destroyed" && fleet["destroyed_at_utc"]
                     parse_time(fleet["destroyed_at_utc"], "fleet destroyed_at_utc")
                   else
                     now
                   end
      lease = RunpodLease.snapshot_for(fleet:, now:)
      lease = nil if lease["status"] == "unconfigured"

      {
        "fleet_id" => fleet.fetch("fleet_id"),
        "lme_status" => fleet.fetch("status"),
        "created_at_utc" => created_at.iso8601,
        "tracked_elapsed_seconds" => nonnegative_seconds(created_at, stopped_at),
        "cloud" => fleet.fetch("cloud"),
        "gpu_id" => fleet.dig("gpu", "id").to_s,
        "worker_count" => workers.length,
        "active_worker_count" => active_workers.length,
        "destroyed_worker_count" => workers.count { |worker| worker.fetch("lme_status") == "destroyed" },
        "recorded_fleet_hourly_rate_usd" => Float(fleet.fetch("fleet_hourly_rate_usd")),
        "current_tracked_hourly_rate_usd" => active_workers.sum { |worker| worker.fetch("hourly_rate_usd") },
        "estimated_accrued_cost_usd" => workers.sum { |worker| worker.fetch("estimated_cost_usd") }.round(6),
        "provider_checked" => !@client.nil?,
        "workers" => workers,
        "lease" => lease,
        "bootstrap" => bootstrap_snapshot(fleet, now)
      }
    rescue KeyError, ArgumentError, TypeError => e
      raise Error, "invalid current fleet state: #{e.message}"
    rescue RunpodLease::Error => e
      raise Error, e.message
    rescue RunpodFleetState::Error => e
      raise Error, e.message
    end

    def render(snapshot)
      return "No current RunPod fleet.\n" unless snapshot

      lines = []
      lines << "RunPod fleet status"
      lines << "  Fleet: #{snapshot.fetch('fleet_id')}"
      lines << "  LME state: #{snapshot.fetch('lme_status').upcase}"
      lines << "  Created: #{snapshot.fetch('created_at_utc')}"
      lines << "  Cloud/GPU: #{snapshot.fetch('cloud')} / #{snapshot.fetch('gpu_id')}"
      lines << format(
        "  Workers: %d total; %d active; %d destroyed",
        snapshot.fetch("worker_count"),
        snapshot.fetch("active_worker_count"),
        snapshot.fetch("destroyed_worker_count")
      )
      lines << format("  Recorded fleet rate: $%.4f/hr", snapshot.fetch("recorded_fleet_hourly_rate_usd"))
      lines << format("  Current tracked rate: $%.4f/hr", snapshot.fetch("current_tracked_hourly_rate_usd"))
      lines << "  Tracked elapsed: #{format_duration(snapshot.fetch('tracked_elapsed_seconds'))}"
      lines << format("  Estimated accrued cost: $%.4f", snapshot.fetch("estimated_accrued_cost_usd"))
      append_lease(lines, snapshot["lease"])
      lines << "  Provider check: #{snapshot.fetch('provider_checked') ? 'enabled' : 'not checked (RUNPOD_API_KEY unavailable)'}"
      lines << ""
      lines << format("%-9s %-10s %-12s %-10s %-10s %-10s %s", "WORKER", "LME", "RUNPOD", "RATE", "ELAPSED", "EST.COST", "BOOTSTRAP")

      bootstrap_workers = bootstrap_workers_by_index(snapshot["bootstrap"])
      snapshot.fetch("workers").each do |worker|
        boot = bootstrap_worker_label(bootstrap_workers[worker.fetch("index")])
        lines << format(
          "%-9s %-10s %-12s $%-9.4f %-10s $%-9.4f %s",
          "burst_#{worker.fetch('index')}",
          worker.fetch("lme_status").upcase,
          worker.fetch("provider_status"),
          worker.fetch("hourly_rate_usd"),
          format_duration(worker.fetch("tracked_elapsed_seconds")),
          worker.fetch("estimated_cost_usd"),
          boot
        )
      end

      append_bootstrap(lines, snapshot["bootstrap"])
      append_provider_warnings(lines, snapshot)
      lines << ""
      lines << "Billing estimate uses per-worker lifecycle timestamps when available; legacy fleets fall back to LME fleet activation."
      lines << "It remains an estimate and can differ because of provider billing granularity, storage/network charges, credits, or rate changes."
      if snapshot["lease"]
        lines << "Lease spend is a conservative guard estimate that starts before the first paid pod create and uses recorded worker rates."
        lines << "Lease enforcement is a local watchdog, not a provider-side billing cap; it cannot enforce limits while the control-plane Mac is offline."
      end
      lines.join("\n") + "\n"
    end

    private

    def worker_snapshot(worker, fleet_created_at, now)
      status = worker.fetch("status").to_s
      stopped_at = if status == "destroyed"
                     value = worker["destroyed_at_utc"]
                     value ? parse_time(value, "burst_#{worker.fetch('index')} destroyed_at_utc") : now
                   else
                     now
                   end
      started_at = if worker["created_at_utc"]
                     parse_time(worker["created_at_utc"], "burst_#{worker.fetch('index')} created_at_utc")
                   else
                     fleet_created_at
                   end
      elapsed = nonnegative_seconds(started_at, stopped_at)
      rate = Float(worker.fetch("hourly_rate_usd"))
      offset = Float(worker.fetch("accrued_cost_offset_usd", 0.0))
      provider = provider_snapshot(worker)

      {
        "index" => Integer(worker.fetch("index")),
        "pod_id" => worker.fetch("pod_id").to_s,
        "lme_status" => status,
        "provider_status" => provider.fetch("status"),
        "provider_detail" => provider["detail"],
        "provider_hourly_rate_usd" => provider["hourly_rate_usd"],
        "hourly_rate_usd" => rate,
        "tracked_elapsed_seconds" => elapsed,
        "estimated_cost_usd" => (offset + (rate * elapsed / 3600.0)).round(6)
      }
    end

    def provider_snapshot(worker)
      return { "status" => "NOT_CHECKED" } unless @client
      return { "status" => "-" } unless worker.fetch("status") == "active"

      pod = @client.get_pod(worker.fetch("pod_id"))
      rate = Float(pod["cost"]) if pod.key?("cost") && !pod["cost"].nil?
      {
        "status" => pod["status"].to_s.empty? ? "UNKNOWN" : pod["status"].to_s.upcase,
        "hourly_rate_usd" => rate
      }
    rescue StandardError => e
      missing = e.respond_to?(:status) && e.status.to_i == 404
      {
        "status" => missing ? "MISSING" : "ERROR",
        "detail" => e.message
      }
    end

    def bootstrap_snapshot(fleet, now)
      root = @fleet_state.artifact_dir(fleet.fetch("fleet_id"), "bootstrap")
      current_path = File.join(root, "current")
      return nil unless File.file?(current_path)

      run_id = File.read(current_path).strip
      return bootstrap_unavailable("bootstrap current pointer is empty") if run_id.empty?
      unless safe_run_id?(run_id)
        return bootstrap_unavailable("bootstrap current pointer contains unsafe run id")
      end

      run_dir = File.join(root, run_id)
      record_path = File.join(run_dir, "bootstrap.json")
      return bootstrap_unavailable("bootstrap state file is missing: #{record_path}") unless File.file?(record_path)

      record = JSON.parse(File.read(record_path))
      if record["fleet_id"] != fleet.fetch("fleet_id")
        return bootstrap_unavailable("bootstrap fleet id does not match current fleet")
      end

      started = record["started_at_utc"] && parse_time(record["started_at_utc"], "bootstrap started_at_utc")
      finished = record["finished_at_utc"] && parse_time(record["finished_at_utc"], "bootstrap finished_at_utc")
      elapsed = started ? nonnegative_seconds(started, finished || now) : 0.0
      workers = Array(record["workers"])
      counts = workers.group_by { |worker| worker["status"].to_s }.transform_values(&:length)

      {
        "run_id" => run_id,
        "status" => record["status"].to_s.empty? ? "unknown" : record["status"].to_s,
        "models" => Array(record["models"]),
        "context" => record["context"],
        "started_at_utc" => record["started_at_utc"],
        "finished_at_utc" => record["finished_at_utc"],
        "elapsed_seconds" => elapsed,
        "counts" => counts,
        "workers" => workers,
        "evidence_dir" => run_dir
      }
    rescue JSON::ParserError => e
      bootstrap_unavailable("bootstrap state is invalid JSON: #{e.message}")
    rescue StandardError => e
      bootstrap_unavailable("bootstrap state could not be read: #{e.message}")
    end

    def bootstrap_unavailable(detail)
      { "status" => "unavailable", "error" => detail, "workers" => [] }
    end

    def safe_run_id?(value)
      value.match?(/\A[A-Za-z0-9_.-]+\z/) && !value.include?("..")
    end

    def bootstrap_workers_by_index(bootstrap)
      return {} unless bootstrap

      Array(bootstrap["workers"]).each_with_object({}) do |worker, out|
        index = Integer(worker.fetch("index")) rescue nil
        out[index] = worker if index
      end
    end

    def bootstrap_worker_label(worker)
      return "-" unless worker

      status = worker["status"].to_s
      return "READY" if status == "passed"
      return "FAILED" if status == "failed"
      return "INTERRUPTED" if status == "interrupted"

      stage = worker["stage"].to_s
      stage.empty? ? status.upcase : stage
    end

    def append_bootstrap(lines, bootstrap)
      lines << ""
      unless bootstrap
        lines << "Bootstrap: none recorded for current fleet."
        return
      end

      if bootstrap["status"] == "unavailable"
        lines << "Bootstrap: UNAVAILABLE -- #{bootstrap['error']}"
        return
      end

      counts = bootstrap.fetch("counts", {})
      lines << "Bootstrap:"
      lines << "  Run: #{bootstrap.fetch('run_id')}"
      lines << "  State: #{bootstrap.fetch('status').upcase}"
      lines << "  Models: #{bootstrap.fetch('models').join(', ')}"
      lines << "  Context: #{bootstrap['context']}" if bootstrap["context"]
      lines << "  Elapsed: #{format_duration(bootstrap.fetch('elapsed_seconds'))}"
      lines << format(
        "  Workers: %d running; %d passed; %d failed; %d interrupted",
        counts.fetch("running", 0),
        counts.fetch("passed", 0),
        counts.fetch("failed", 0),
        counts.fetch("interrupted", 0)
      )
      lines << "  Evidence: #{bootstrap.fetch('evidence_dir')}"
    end

    def append_lease(lines, lease)
      return unless lease

      lines << "  Lease: #{lease.fetch('status').upcase}"
      lines << "  Lease started: #{lease.fetch('started_at_utc')}"
      if lease["max_runtime_seconds"]
        lines << "  Lease deadline: #{lease.fetch('expires_at_utc')}"
        lines << "  Runtime lease: #{format_duration(lease.fetch('max_runtime_seconds'))} max; #{format_duration(lease.fetch('runtime_remaining_seconds'))} remaining"
      end
      if lease["max_spend_usd"]
        lines << format(
          "  Spend lease: $%.4f max; $%.4f conservative tracked",
          lease.fetch("max_spend_usd"), lease.fetch("estimated_spend_usd")
        )
        lines << format("  Budget remaining: $%.4f", lease.fetch("budget_remaining_usd"))
      end
      unless lease.fetch("expiration_reasons").empty?
        lines << "  Lease expired by: #{lease.fetch('expiration_reasons').join(', ')}"
      end
    end

    def append_provider_warnings(lines, snapshot)
      warnings = snapshot.fetch("workers").filter_map do |worker|
        next unless worker.fetch("lme_status") == "active"
        next unless %w[MISSING ERROR].include?(worker.fetch("provider_status"))

        detail = worker["provider_detail"]
        suffix = detail.to_s.empty? ? "" : " (#{detail})"
        "WARNING: burst_#{worker.fetch('index')} is ACTIVE in LME state but RunPod status is #{worker.fetch('provider_status')}#{suffix}."
      end
      return if warnings.empty?

      lines << ""
      lines.concat(warnings)
    end

    def parse_time(value, label)
      Time.parse(value.to_s).utc
    rescue ArgumentError
      raise Error, "#{label} is invalid: #{value.inspect}"
    end

    def utc_now
      value = @wall_clock.call
      value = Time.parse(value.to_s) unless value.is_a?(Time)
      value.utc
    end

    def nonnegative_seconds(start_time, end_time)
      [end_time - start_time, 0.0].max
    end

    def format_duration(seconds)
      total = Float(seconds).to_i
      hours = total / 3600
      minutes = (total % 3600) / 60
      secs = total % 60
      format("%02d:%02d:%02d", hours, minutes, secs)
    end
  end
end
