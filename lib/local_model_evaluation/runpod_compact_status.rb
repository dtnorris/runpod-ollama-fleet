# frozen_string_literal: true

module LocalModelEvaluation
  # Width-bounded presentation over FO-04 status snapshots. It derives no
  # provider or registry state; it only abbreviates and formats retained truth.
  class RunpodCompactStatus
    DEFAULT_WIDTH = 72
    MINIMUM_WIDTH = 60
    ID_WIDTH = 9
    PROVIDER_WIDTH = 5
    REGISTRY_WIDTH = 11
    RATE_WIDTH = 9

    PROVIDER_LABELS = {
      "RUNNING" => "UP",
      "NOT_CHECKED" => "N/C",
      "MISSING" => "DOWN",
      "ERROR" => "ERR",
      "UNKNOWN" => "?",
      "-" => "-"
    }.freeze

    def initialize(width: DEFAULT_WIDTH)
      @width = [Integer(width), MINIMUM_WIDTH].max
    rescue ArgumentError, TypeError
      raise ArgumentError, "status width must be an integer"
    end

    def render_fleet(snapshot)
      return "No current RunPod fleet.\n" unless snapshot

      rows = snapshot.fetch("workers").map do |worker|
        compact_row(worker, "burst_#{worker.fetch('index')}")
      end
      render_rows(rows)
    end

    def render_all(snapshot)
      return "No active managed RunPod fleets.\n" if snapshot.fetch("active_fleet_count").zero?

      rows = snapshot.fetch("workers").map do |worker|
        compact_row(worker, "#{worker.fetch('fleet_alias')}#{worker.fetch('index')}")
      end
      render_rows(rows)
    end

    private

    def render_rows(rows)
      gpu_width, model_width = flexible_widths
      lines = [format_row("ID", "GPU", "MODEL", "PROV", "REG", "RATE", gpu_width, model_width)]
      rows.each do |row|
        lines << format_row(*row, gpu_width, model_width)
      end
      lines.join("\n") + "\n"
    end

    def compact_row(worker, id)
      [
        id,
        compact_gpu(worker.fetch("gpu_id", "-")),
        model_label(worker),
        PROVIDER_LABELS.fetch(worker.fetch("provider_status", "-").to_s.upcase) do |status|
          truncate(status, PROVIDER_WIDTH)
        end,
        worker.fetch("registry_state", "-").to_s.upcase,
        rate_label(worker["hourly_rate_usd"])
      ]
    end

    def format_row(id, gpu, model, provider, registry, rate, gpu_width, model_width)
      format(
        "%-#{ID_WIDTH}s %-#{gpu_width}s %-#{model_width}s %-#{PROVIDER_WIDTH}s %-#{REGISTRY_WIDTH}s %#{RATE_WIDTH}s",
        truncate(id, ID_WIDTH), truncate(gpu, gpu_width), truncate(model, model_width),
        truncate(provider, PROVIDER_WIDTH), truncate(registry, REGISTRY_WIDTH), truncate(rate, RATE_WIDTH)
      )[0, @width].rstrip
    end

    def flexible_widths
      flexible = @width - ID_WIDTH - PROVIDER_WIDTH - REGISTRY_WIDTH - RATE_WIDTH - 5
      gpu = [[(flexible * 0.4).floor, 10].max, 20].min
      [gpu, flexible - gpu]
    end

    def compact_gpu(value)
      value.to_s.sub(/\ANVIDIA\s+/, "")
    end

    def model_label(worker)
      models = Array(worker["available_models"])
      models = Array(worker["loaded_models"]) if models.empty?
      models.empty? ? "-" : models.join(",")
    end

    def rate_label(value)
      value.nil? ? "-" : format("$%.4f/h", Float(value))
    rescue ArgumentError, TypeError
      "-"
    end

    def truncate(value, width)
      text = value.to_s
      return text if text.length <= width

      "#{text[0, width - 1]}~"
    end
  end
end
