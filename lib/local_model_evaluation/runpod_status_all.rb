# frozen_string_literal: true

module LocalModelEvaluation
  class RunpodStatusAll
    INFERENCE_STATUSES = %w[active idle unavailable unknown].freeze

    def snapshot(entries)
      fleets = Array(entries).filter_map do |entry|
        fleet_key = entry.fetch("fleet_key").to_s
        fleet_snapshot = entry["snapshot"]
        next unless fleet_snapshot
        next unless fleet_snapshot.fetch("lme_status").to_s == "active"

        { "fleet_key" => fleet_key, "snapshot" => fleet_snapshot }
      end.sort_by { |entry| entry.fetch("fleet_key") }

      workers = fleets.flat_map do |entry|
        fleet_snapshot = entry.fetch("snapshot")
        Array(fleet_snapshot.fetch("workers")).filter_map do |worker|
          next unless worker.fetch("lme_status").to_s == "active"

          worker_row(entry.fetch("fleet_key"), fleet_snapshot, worker)
        end
      end

      inference_statuses = workers.map { |worker| worker.fetch("inference_status") }

      {
        "active_fleet_count" => fleets.length,
        "active_worker_count" => workers.length,
        "current_tracked_hourly_rate_usd" => fleets.sum do |entry|
          Float(entry.fetch("snapshot").fetch("current_tracked_hourly_rate_usd"))
        end,
        "estimated_accrued_cost_usd" => fleets.sum do |entry|
          Float(entry.fetch("snapshot").fetch("estimated_accrued_cost_usd"))
        end,
        "inference_counts" => INFERENCE_STATUSES.to_h do |status|
          [status, inference_statuses.count(status)]
        end,
        "workers" => workers
      }
    rescue KeyError, ArgumentError, TypeError => e
      raise ArgumentError, "invalid aggregate RunPod status state: #{e.message}"
    end

    def render(snapshot)
      return "No active managed RunPod fleets.\n" if snapshot.fetch("active_fleet_count").zero?

      counts = snapshot.fetch("inference_counts")
      lines = []
      lines << "RunPod aggregate status"
      lines << "  Active fleets: #{snapshot.fetch('active_fleet_count')}"
      lines << "  Active workers: #{snapshot.fetch('active_worker_count')}"
      lines << format("  Current managed rate: $%.4f/hr", snapshot.fetch("current_tracked_hourly_rate_usd"))
      lines << format("  Estimated accrued cost: $%.4f", snapshot.fetch("estimated_accrued_cost_usd"))
      lines << format(
        "  Ollama inference: %d active; %d idle; %d unavailable; %d unknown",
        counts.fetch("active"),
        counts.fetch("idle"),
        counts.fetch("unavailable"),
        counts.fetch("unknown")
      )
      lines << ""
      lines << format(
        "%-26s %-9s %-27s %-30s %-30s %-12s %-10s %-11s %s",
        "FLEET", "WORKER", "GPU", "AVAILABLE", "LOADED", "RUNPOD", "RATE", "INFERENCE", "BOOTSTRAP"
      )

      snapshot.fetch("workers").each do |worker|
        lines << format(
          "%-26s %-9s %-27s %-30s %-30s %-12s $%-9.4f %-11s %s",
          worker.fetch("fleet_key"),
          "burst_#{worker.fetch('index')}",
          worker.fetch("gpu_id"),
          available_model_label(worker),
          loaded_model_label(worker),
          worker.fetch("provider_status"),
          worker.fetch("hourly_rate_usd"),
          inference_label(worker.fetch("inference_status")),
          worker.fetch("bootstrap_status")
        )
      end

      lines << ""
      lines << "AVAILABLE is passed bootstrap evidence for that worker in its current fleet generation."
      lines << "LOADED is live Ollama /api/ps residency at this snapshot."
      lines << "Current managed rate sums active workers across the displayed fleets."
      lines.join("\n") + "\n"
    end

    private

    def worker_row(fleet_key, fleet_snapshot, worker)
      {
        "fleet_key" => fleet_key,
        "index" => Integer(worker.fetch("index")),
        "gpu_id" => worker.fetch("gpu_id").to_s,
        "available_models" => Array(worker["available_models"]),
        "loaded_models" => Array(worker["loaded_models"]),
        "model_status" => worker["model_status"].to_s,
        "provider_status" => worker.fetch("provider_status").to_s,
        "hourly_rate_usd" => Float(worker.fetch("hourly_rate_usd")),
        "inference_status" => normalize_inference_status(worker["inference_status"]),
        "bootstrap_status" => bootstrap_label(fleet_snapshot["bootstrap"], worker)
      }
    end

    def normalize_inference_status(value)
      status = value.to_s
      INFERENCE_STATUSES.include?(status) ? status : "unknown"
    end

    def available_model_label(worker)
      models = Array(worker["available_models"])
      models.empty? ? "-" : models.join(",")
    end

    def loaded_model_label(worker)
      case worker["model_status"].to_s
      when "ok"
        models = Array(worker["loaded_models"])
        models.empty? ? "-" : models.join(",")
      when "unavailable"
        "UNAVAILABLE"
      when "not_applicable"
        "-"
      else
        "UNKNOWN"
      end
    end

    def inference_label(status)
      status.to_s.upcase
    end

    def bootstrap_label(bootstrap, worker)
      return "-" unless bootstrap && bootstrap["status"] != "unavailable"

      record = Array(bootstrap["workers"]).find do |candidate|
        Integer(candidate.fetch("index")) == Integer(worker.fetch("index"))
      rescue KeyError, ArgumentError, TypeError
        false
      end
      return "-" unless record

      if record["pod_id"] && record["pod_id"].to_s != worker.fetch("pod_id").to_s
        return "-"
      end

      case record["status"].to_s
      when "passed" then "READY"
      when "failed" then "FAILED"
      when "interrupted" then "INTERRUPTED"
      else
        stage = record["stage"].to_s
        stage.empty? ? record["status"].to_s.upcase : stage
      end
    end
  end
end
