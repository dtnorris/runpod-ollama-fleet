# frozen_string_literal: true

module LocalModelEvaluation
  class RunpodStatusAll
    FLEET_WIDTH = 5
    BURST_WIDTH = 5
    GPU_WIDTH = 18
    MODEL_WIDTH = 18
    RUNPOD_WIDTH = 8

    INFERENCE_STATUSES = %w[active idle unavailable unknown].freeze

    def snapshot(entries)
      fleets = Array(entries).filter_map do |entry|
        fleet_key = entry.fetch("fleet_key").to_s
        fleet_snapshot = entry["snapshot"]
        next unless fleet_snapshot
        next unless fleet_snapshot.fetch("lme_status").to_s == "active"

        { "fleet_key" => fleet_key, "snapshot" => fleet_snapshot }
      end.sort_by do |entry|
        [entry.fetch("snapshot")["created_at_utc"].to_s, entry.fetch("fleet_key")]
      end.each_with_index.map do |entry, index|
        entry.merge("fleet_alias" => fleet_alias(index))
      end

      workers = fleets.flat_map do |entry|
        fleet_snapshot = entry.fetch("snapshot")
        Array(fleet_snapshot.fetch("workers")).filter_map do |worker|
          next unless worker.fetch("lme_status").to_s == "active"

          worker_row(entry.fetch("fleet_key"), entry.fetch("fleet_alias"), fleet_snapshot, worker)
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
        "fleet_aliases" => fleets.map do |entry|
          { "alias" => entry.fetch("fleet_alias"), "fleet_key" => entry.fetch("fleet_key") }
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
      lines << "  Fleet aliases (current active set):"
      snapshot.fetch("fleet_aliases").each do |fleet|
        lines << "    #{fleet.fetch('alias')}: #{fleet.fetch('fleet_key')}"
      end
      lines << ""
      lines << format(
        "%-5s %-5s %-18s %-18s %-18s %-8s %-8s %-11s %s",
        "FLEET", "BURST", "GPU", "AVAILABLE", "LOADED", "RUNPOD", "RATE", "INFERENCE", "BOOTSTRAP"
      )

      snapshot.fetch("workers").each do |worker|
        lines << format(
          "%-5s %-5s %-18s %-18s %-18s %-8s $%-7.4f %-11s %s",
          truncate(worker.fetch("fleet_alias"), FLEET_WIDTH),
          truncate(worker.fetch("index"), BURST_WIDTH),
          truncate(worker.fetch("gpu_id"), GPU_WIDTH),
          truncate(available_model_label(worker), MODEL_WIDTH),
          truncate(loaded_model_label(worker), MODEL_WIDTH),
          truncate(worker.fetch("provider_status"), RUNPOD_WIDTH),
          worker.fetch("hourly_rate_usd"),
          inference_label(worker.fetch("inference_status")),
          worker.fetch("bootstrap_status")
        )
      end

      lines << ""
      lines << "FLEET aliases are listed above; BURST is the worker index within that fleet."
      lines << "AVAILABLE=bootstrap-qualified; LOADED=live Ollama residency; rate=active managed workers."
      lines.join("\n") + "\n"
    end

    private

    def worker_row(fleet_key, fleet_alias, fleet_snapshot, worker)
      {
        "fleet_key" => fleet_key,
        "fleet_alias" => fleet_alias,
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

    def fleet_alias(index)
      value = Integer(index) + 1
      label = +""
      while value.positive?
        value -= 1
        label.prepend((65 + (value % 26)).chr)
        value /= 26
      end
      label
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

    def truncate(value, width)
      text = value.to_s
      return text if text.length <= width
      return text[0, width] if width <= 3

      "#{text[0, width - 3]}..."
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
