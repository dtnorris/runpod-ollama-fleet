# frozen_string_literal: true

require "time"

module LocalModelEvaluation
  class RunpodLease
    DEFAULT_POLL_SECONDS = 15.0
    PID_FILE = "watchdog.pid"
    LOG_FILE = "watchdog.log"

    class Error < StandardError; end

    def self.snapshot_for(fleet:, now: Time.now.utc)
      lease = fleet["lease"]
      return { "status" => "unconfigured" } unless lease

      now = parse_time(now, "lease clock")
      started_at = parse_time(lease.fetch("started_at_utc"), "lease started_at_utc")
      max_runtime_seconds = optional_positive_float(lease["max_runtime_seconds"], "lease max_runtime_seconds")
      max_spend_usd = optional_positive_float(lease["max_spend_usd"], "lease max_spend_usd")
      if max_runtime_seconds.nil? && max_spend_usd.nil?
        raise Error, "lease must define max_runtime_seconds and/or max_spend_usd"
      end

      elapsed_seconds = [now - started_at, 0.0].max
      tracked_workers = Array(fleet.fetch("workers")) + Array(fleet["retired_workers"])
      estimated_spend_usd = tracked_workers.sum do |worker|
        worker_stop = if worker.fetch("status") == "destroyed" && worker["destroyed_at_utc"]
                        parse_time(worker["destroyed_at_utc"], "worker destroyed_at_utc")
                      else
                        now
                      end
        worker_start = worker["created_at_utc"] ? parse_time(worker["created_at_utc"], "worker created_at_utc") : started_at
        worker_start = [worker_start, started_at].max
        worker_elapsed = [worker_stop - worker_start, 0.0].max
        offset = Float(worker.fetch("lease_spend_offset_usd", 0.0))
        offset + (Float(worker.fetch("hourly_rate_usd")) * worker_elapsed / 3600.0)
      end

      runtime_remaining_seconds = max_runtime_seconds && [max_runtime_seconds - elapsed_seconds, 0.0].max
      budget_remaining_usd = max_spend_usd && [max_spend_usd - estimated_spend_usd, 0.0].max
      reasons = []
      reasons << "runtime" if max_runtime_seconds && elapsed_seconds >= max_runtime_seconds
      reasons << "spend" if max_spend_usd && estimated_spend_usd >= max_spend_usd

      {
        "status" => reasons.empty? ? "active" : "expired",
        "started_at_utc" => started_at.iso8601,
        "elapsed_seconds" => elapsed_seconds,
        "max_runtime_seconds" => max_runtime_seconds,
        "expires_at_utc" => max_runtime_seconds ? (started_at + max_runtime_seconds).iso8601 : nil,
        "runtime_remaining_seconds" => runtime_remaining_seconds,
        "max_spend_usd" => max_spend_usd,
        "estimated_spend_usd" => estimated_spend_usd.round(6),
        "budget_remaining_usd" => budget_remaining_usd&.round(6),
        "expiration_reasons" => reasons,
        "active_worker_indices" => Array(fleet.fetch("workers")).filter_map do |worker|
          Integer(worker.fetch("index")) if worker.fetch("status") == "active"
        end
      }
    rescue KeyError, ArgumentError, TypeError => e
      raise Error, "invalid lease state: #{e.message}"
    end

    def initialize(fleet_state:, fleet: nil, expected_fleet_id: nil, out: $stdout, sleeper: nil, wall_clock: nil)
      @fleet_state = fleet_state
      @fleet = fleet
      @expected_fleet_id = expected_fleet_id&.to_s
      @out = out
      @sleeper = sleeper || ->(seconds) { sleep seconds }
      @wall_clock = wall_clock || -> { Time.now.utc }
    end

    def snapshot
      fleet = @fleet_state.current
      return { "status" => "no_fleet" } unless fleet

      fleet_id = fleet.fetch("fleet_id").to_s
      if @expected_fleet_id && fleet_id != @expected_fleet_id
        return {
          "status" => "fleet_replaced",
          "expected_fleet_id" => @expected_fleet_id,
          "current_fleet_id" => fleet_id
        }
      end

      self.class.snapshot_for(fleet:, now: utc_now).merge("fleet_id" => fleet_id)
    rescue RunpodFleetState::Error => e
      raise Error, e.message
    end

    def enforce_once
      current = snapshot
      return current unless current["status"] == "expired"

      indices = current.fetch("active_worker_indices")
      return current.merge("action" => "already_stopped") if indices.empty?
      raise Error, "cannot enforce an expired lease without a RunpodFleet" unless @fleet

      @out.puts "RunPod lease expired (#{current.fetch('expiration_reasons').join('+')}); destroying #{indices.map { |i| "burst_#{i}" }.join(', ')}."
      @fleet.destroy(worker_indices: indices)
      current.merge("action" => "destroyed", "destroyed_worker_indices" => indices)
    rescue RunpodFleet::Error, RunpodClient::Error => e
      raise Error, "lease teardown failed: #{e.message}"
    end

    def watch(poll_seconds: DEFAULT_POLL_SECONDS)
      poll_seconds = positive_float(poll_seconds, "poll seconds")
      initial = snapshot
      if initial["status"] == "no_fleet"
        @out.puts "RunPod lease watchdog exiting: no current fleet."
        return initial
      end
      if initial["status"] == "fleet_replaced"
        @out.puts "RunPod lease watchdog exiting: expected fleet #{initial.fetch('expected_fleet_id')} is no longer current."
        return initial
      end
      if initial["status"] == "unconfigured"
        raise Error, "current RunPod fleet has no runtime/spend lease"
      end

      @out.puts format("RunPod lease watchdog started (poll %.1fs).", poll_seconds)
      loop do
        begin
          current = enforce_once
        rescue Error => e
          @out.puts "WARNING: #{e.message}; watchdog will retry."
          @sleeper.call(poll_seconds)
          next
        end

        if current["status"] == "no_fleet"
          @out.puts "RunPod lease watchdog exiting: no current fleet."
          return current
        end
        if current["status"] == "fleet_replaced"
          @out.puts "RunPod lease watchdog exiting: expected fleet #{current.fetch('expected_fleet_id')} is no longer current."
          return current
        end
        if current["status"] == "unconfigured"
          raise Error, "current RunPod fleet no longer has a runtime/spend lease"
        end
        return current if current["status"] == "expired" && %w[destroyed already_stopped].include?(current["action"])

        @sleeper.call(poll_seconds)
      end
    end

    def render(snapshot)
      case snapshot.fetch("status")
      when "no_fleet"
        return "No current RunPod fleet.\n"
      when "unconfigured"
        return "Current RunPod fleet has no runtime/spend lease.\n"
      when "fleet_replaced"
        return "Expected RunPod fleet #{snapshot.fetch('expected_fleet_id')} is no longer current.\n"
      end

      lines = []
      lines << "RunPod fleet lease"
      lines << "  Fleet: #{snapshot['fleet_id']}" if snapshot["fleet_id"]
      lines << "  State: #{snapshot.fetch('status').upcase}"
      lines << "  Started: #{snapshot.fetch('started_at_utc')}"
      lines << "  Elapsed: #{format_duration(snapshot.fetch('elapsed_seconds'))}"
      if snapshot["max_runtime_seconds"]
        lines << "  Deadline: #{snapshot.fetch('expires_at_utc')}"
        lines << "  Runtime limit: #{format_duration(snapshot.fetch('max_runtime_seconds'))}"
        lines << "  Runtime remaining: #{format_duration(snapshot.fetch('runtime_remaining_seconds'))}"
      end
      if snapshot["max_spend_usd"]
        lines << format("  Spend limit: $%.4f", snapshot.fetch("max_spend_usd"))
        lines << format("  Conservative tracked spend: $%.4f", snapshot.fetch("estimated_spend_usd"))
        lines << format("  Budget remaining: $%.4f", snapshot.fetch("budget_remaining_usd"))
      end
      unless snapshot.fetch("expiration_reasons").empty?
        lines << "  Expired by: #{snapshot.fetch('expiration_reasons').join(', ')}"
      end
      lines.join("\n") + "\n"
    end

    class << self
      private

      def parse_time(value, label)
        time = value.is_a?(Time) ? value : Time.parse(value.to_s)
        time.utc
      rescue ArgumentError
        raise Error, "#{label} is invalid: #{value.inspect}"
      end

      def optional_positive_float(value, label)
        return nil if value.nil?

        number = Float(value)
        raise Error, "#{label} must be positive" unless number.positive?

        number
      end
    end

    private

    def utc_now
      value = @wall_clock.call
      value = Time.parse(value.to_s) unless value.is_a?(Time)
      value.utc
    rescue ArgumentError
      raise Error, "lease clock is invalid: #{value.inspect}"
    end

    def positive_float(value, label)
      number = Float(value)
      raise Error, "#{label} must be positive" unless number.positive?

      number
    rescue ArgumentError, TypeError
      raise Error, "#{label} must be numeric"
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
