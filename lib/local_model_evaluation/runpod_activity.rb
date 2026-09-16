# frozen_string_literal: true

require "json"
require "net/http"
require "open3"
require "uri"

module LocalModelEvaluation
  # Read-only, control-plane observation of live Ollama request traffic.
  #
  # RPOF deliberately does not interpret AFIO job semantics here. Instead it
  # observes whether an active worker has a healthy managed tunnel and whether
  # a local client currently has an ESTABLISHED TCP connection to that tunnel.
  # In the normal AFIO scorer path, a long-lived Ollama request corresponds to
  # active inference. Short requests can fall between status snapshots.
  class RunpodActivity
    ACTIVE_STATUSES = %w[active idle unavailable unknown].freeze

    class ConnectionProbe
      def initialize(command_runner: nil, lsof_path: nil)
        @command_runner = command_runner || ->(argv) { Open3.capture3(*argv) }
        @lsof_path = lsof_path || detect_lsof
      end

      def check(endpoint)
        uri = URI.parse(endpoint.to_s)
        unless uri.host && uri.port
          return observation("unknown", "managed tunnel endpoint has no host/port")
        end

        _stdout, stderr, status = @command_runner.call(
          [
            @lsof_path,
            "-nP",
            "-a",
            "-iTCP@#{uri.host}:#{uri.port}",
            "-sTCP:ESTABLISHED"
          ]
        )

        return observation("active", "established client connection observed") if status.success?

        detail = stderr.to_s.strip
        if status.exitstatus == 1 && detail.empty?
          return observation("idle", "no established client connection observed")
        end

        detail = "lsof exit #{status.exitstatus.inspect}" if detail.empty?
        observation("unknown", detail)
      rescue Errno::ENOENT
        observation("unknown", "lsof is unavailable on the control plane")
      rescue URI::InvalidURIError, ArgumentError => e
        observation("unknown", "invalid managed tunnel endpoint: #{e.message}")
      rescue StandardError => e
        observation("unknown", "#{e.class}: #{e.message}")
      end

      private

      def detect_lsof
        %w[/usr/sbin/lsof /usr/bin/lsof].find { |path| File.executable?(path) } || "lsof"
      end

      def observation(status, detail)
        { "status" => status, "detail" => detail }
      end
    end

    class OllamaProbe
      def initialize(http_get: nil)
        @http_get = http_get || method(:get)
      end

      def check(endpoint)
        uri = URI.join("#{endpoint}/", "api/ps")
        response = @http_get.call(uri)
        code = Integer(response.code)
        unless (200..299).cover?(code)
          return observation("unknown", [], "HTTP #{code}")
        end

        data = JSON.parse(response.body.to_s)
        models = Array(data["models"]).filter_map do |model|
          name = model["name"].to_s
          name = model["model"].to_s if name.empty?
          name unless name.empty?
        end.uniq.sort
        observation("ok", models, nil)
      rescue JSON::ParserError => e
        observation("unknown", [], "invalid /api/ps JSON: #{e.message}")
      rescue URI::InvalidURIError, ArgumentError, TypeError => e
        observation("unknown", [], "invalid Ollama endpoint: #{e.message}")
      rescue StandardError => e
        observation("unknown", [], "#{e.class}: #{e.message}")
      end

      private

      def get(uri)
        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl = uri.scheme == "https"
        http.open_timeout = 0.5
        http.read_timeout = 1.0
        http.get(uri.request_uri)
      end

      def observation(status, models, detail)
        {
          "status" => status,
          "loaded_models" => Array(models),
          "detail" => detail
        }
      end
    end

    def initialize(fleet_state:, connection_probe: nil, ollama_probe: nil, process_alive: nil)
      @fleet_state = fleet_state
      @connection_probe = connection_probe || ConnectionProbe.new
      @ollama_probe = ollama_probe || OllamaProbe.new
      @process_alive = process_alive || method(:process_alive?)
    end

    def snapshot(fleet)
      tunnel_workers, tunnel_error = tunnel_workers(fleet)
      observations = {}

      Array(fleet.fetch("workers")).each do |worker|
        index = Integer(worker.fetch("index"))
        observations[index] = worker_activity(
          worker,
          tunnel_workers[index],
          tunnel_error
        )
      end

      active_indices = Array(fleet.fetch("workers")).filter_map do |worker|
        Integer(worker.fetch("index")) if worker.fetch("status").to_s == "active"
      end
      statuses = active_indices.map { |index| observations.fetch(index).fetch("status") }

      {
        "workers" => observations,
        "counts" => ACTIVE_STATUSES.to_h { |status| [status, statuses.count(status)] }
      }
    rescue KeyError, ArgumentError, TypeError => e
      raise ArgumentError, "invalid fleet activity state: #{e.message}"
    end

    private

    def worker_activity(worker, tunnel, tunnel_error)
      unless worker.fetch("status").to_s == "active"
        return observation("not_applicable", "worker is not active")
      end
      return observation("unavailable", tunnel_error) if tunnel_error
      return observation("unavailable", "managed tunnel record is missing") unless tunnel
      unless tunnel["pod_id"].to_s == worker.fetch("pod_id").to_s
        return observation("unavailable", "managed tunnel belongs to a different pod generation")
      end
      unless tunnel["process_status"].to_s == "running" && tunnel["health_status"].to_s == "healthy"
        return observation(
          "unavailable",
          "managed tunnel is #{tunnel['process_status'].inspect}/#{tunnel['health_status'].inspect}"
        )
      end

      pid = tunnel["pid"]
      unless pid && @process_alive.call(pid)
        return observation("unavailable", "managed tunnel process is not running")
      end

      endpoint = tunnel["endpoint"].to_s
      return observation("unavailable", "managed tunnel endpoint is missing") if endpoint.empty?

      result = @connection_probe.check(endpoint)
      status = result["status"].to_s
      status = "unknown" unless %w[active idle unknown].include?(status)
      model_result = @ollama_probe.check(endpoint)
      observation(
        status,
        result["detail"],
        endpoint: endpoint,
        loaded_models: model_result["loaded_models"],
        model_status: model_result["status"],
        model_detail: model_result["detail"]
      )
    rescue KeyError, ArgumentError, TypeError => e
      observation("unknown", "invalid worker/tunnel activity state: #{e.message}")
    end

    def tunnel_workers(fleet)
      root = @fleet_state.artifact_dir(fleet.fetch("fleet_id"), "tunnels")
      path = File.join(root, "tunnels.json")
      return [{}, "managed tunnel state is missing"] unless File.file?(path)

      state = JSON.parse(File.read(path))
      unless state["fleet_id"].to_s == fleet.fetch("fleet_id").to_s
        return [{}, "managed tunnel state belongs to a different fleet"]
      end

      workers = Array(state["workers"]).each_with_object({}) do |worker, out|
        out[Integer(worker.fetch("index"))] = worker
      end
      [workers, nil]
    rescue JSON::ParserError => e
      [{}, "managed tunnel state is invalid JSON: #{e.message}"]
    rescue KeyError, ArgumentError, TypeError, SystemCallError => e
      [{}, "managed tunnel state could not be read: #{e.message}"]
    end

    def process_alive?(pid)
      Process.kill(0, Integer(pid))
      true
    rescue Errno::ESRCH
      false
    rescue Errno::EPERM
      true
    rescue ArgumentError, TypeError
      false
    end

    def observation(status, detail, endpoint: nil, loaded_models: [], model_status: nil, model_detail: nil)
      result = { "status" => status, "detail" => detail.to_s }
      result["endpoint"] = endpoint if endpoint
      result["loaded_models"] = Array(loaded_models)
      result["model_status"] = model_status || default_model_status(status)
      result["model_detail"] = model_detail if model_detail
      result
    end

    def default_model_status(inference_status)
      case inference_status.to_s
      when "not_applicable"
        "not_applicable"
      else
        "unavailable"
      end
    end
  end
end
