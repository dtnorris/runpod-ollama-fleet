# frozen_string_literal: true

require "json"
require "net/http"
require "timeout"
require "uri"

module LocalModelEvaluation
  class RunpodRuntimeAlias
    class Error < StandardError; end

    Response = Struct.new(:status, :body, keyword_init: true)

    def initialize(fleet_state:, open_timeout: 2.0, read_timeout: 180.0, transport: nil)
      @fleet_state = fleet_state
      @open_timeout = Float(open_timeout)
      @read_timeout = Float(read_timeout)
      @transport = transport
    end

    def ensure_alias(worker_indices:, source_model:, runtime_model:, expected_digest:, context:)
      fleet = active_fleet!
      workers = selected_workers(fleet, worker_indices)
      source = nonempty(source_model, "source model")
      runtime = nonempty(runtime_model, "runtime model")
      digest = expected_digest.to_s.downcase
      raise Error, "expected digest must be exactly 64 hexadecimal characters" unless digest.match?(/\A[0-9a-f]{64}\z/)
      required_context = positive_integer(context, "context")

      workers.map do |worker|
        verify_worker_alias(
          worker:,
          source_model: source,
          runtime_model: runtime,
          expected_digest: digest,
          context: required_context
        )
      end
    end

    private

    def active_fleet!
      fleet = @fleet_state.current
      raise Error, "no current RunPod fleet state exists" unless fleet
      raise Error, "current RunPod fleet is not active" unless fleet["status"] == "active"
      fleet
    rescue StandardError => e
      raise e if e.is_a?(Error)
      raise Error, e.message
    end

    def selected_workers(fleet, values)
      indices = Array(values).map { |value| Integer(value) }.uniq.sort
      raise Error, "no workers selected" if indices.empty? || indices.any? { |index| index <= 0 }
      by_index = Array(fleet.fetch("workers")).to_h { |worker| [Integer(worker.fetch("index")), worker] }
      unknown = indices.reject { |index| by_index.key?(index) }
      raise Error, "current fleet does not contain worker index(es): #{unknown.join(', ')}" unless unknown.empty?
      selected = indices.map { |index| by_index.fetch(index) }
      inactive = selected.reject { |worker| worker["status"] == "active" }
      unless inactive.empty?
        raise Error, "selected worker(s) are not active: #{inactive.map { |worker| "burst_#{worker.fetch('index')}" }.join(', ')}"
      end
      selected
    rescue KeyError, ArgumentError, TypeError => e
      raise Error, "invalid worker state: #{e.message}"
    end

    def verify_worker_alias(worker:, source_model:, runtime_model:, expected_digest:, context:)
      index = Integer(worker.fetch("index"))
      endpoint = nonempty(worker["local_ollama_url"], "burst_#{index} local_ollama_url")

      tags = get_json(endpoint, "/api/tags")
      source_digest = digest_for(tags, source_model)
      unless source_digest == expected_digest
        raise Error,
              "burst_#{index}: source model #{source_model.inspect} digest mismatch: expected #{expected_digest}, got #{source_digest.inspect}"
      end

      runtime_digest = digest_for(tags, runtime_model)
      if runtime_digest && runtime_digest != expected_digest
        raise Error,
              "burst_#{index}: runtime alias #{runtime_model.inspect} already exists with unexpected digest #{runtime_digest}"
      end

      if runtime_model != source_model && runtime_digest.nil?
        post_json(endpoint, "/api/copy", "source" => source_model, "destination" => runtime_model)
        tags = get_json(endpoint, "/api/tags")
        runtime_digest = digest_for(tags, runtime_model)
      end
      runtime_digest ||= source_digest if runtime_model == source_model
      unless runtime_digest == expected_digest
        raise Error,
              "burst_#{index}: runtime alias #{runtime_model.inspect} did not resolve to expected digest #{expected_digest}"
      end

      post_json(
        endpoint,
        "/api/generate",
        "model" => runtime_model,
        "prompt" => "",
        "stream" => false,
        "keep_alive" => "5m"
      )
      ps = get_json(endpoint, "/api/ps")
      row = model_row(ps, runtime_model)
      raise Error, "burst_#{index}: runtime model #{runtime_model.inspect} did not appear in /api/ps after warmup" unless row

      actual_context = Integer(row.fetch("context_length"))
      size = Integer(row.fetch("size"))
      size_vram = Integer(row.fetch("size_vram"))
      if actual_context != context
        raise Error,
              "burst_#{index}: runtime model context mismatch: expected #{context}, got #{actual_context}"
      end
      unless size == size_vram
        raise Error,
              "burst_#{index}: runtime model is not fully GPU-resident: size=#{size} size_vram=#{size_vram}"
      end

      {
        "worker_index" => index,
        "runtime_model" => runtime_model,
        "source_model" => source_model,
        "digest" => runtime_digest,
        "context_length" => actual_context,
        "size_bytes" => size,
        "size_vram_bytes" => size_vram,
        "fully_gpu_resident" => true
      }
    rescue KeyError, ArgumentError, TypeError => e
      raise Error, "burst_#{index}: invalid Ollama runtime evidence: #{e.message}"
    end

    def digest_for(tags, model)
      row = Array(tags["models"]).find do |entry|
        entry["name"].to_s == model || entry["model"].to_s == model
      end
      digest = row && row["digest"].to_s.downcase
      digest && !digest.empty? ? digest : nil
    end

    def model_row(ps, model)
      Array(ps["models"]).find do |entry|
        entry["name"].to_s == model || entry["model"].to_s == model
      end
    end

    def get_json(endpoint, path)
      request_json("GET", endpoint, path)
    end

    def post_json(endpoint, path, body)
      request_json("POST", endpoint, path, body)
    end

    def request_json(method, endpoint, path, body = nil)
      uri = URI.join("#{endpoint.sub(%r{/+\z}, "")}/", path.sub(%r{\A/+}, ""))
      response = if @transport
                   @transport.call(method:, uri:, body: body && JSON.generate(body))
                 else
                   perform_http(method:, uri:, body:)
                 end
      status = response.respond_to?(:code) ? response.code.to_i : Integer(response.status)
      raw = response.body.to_s
      raise Error, "#{method} #{path} returned HTTP #{status}: #{raw.strip}" unless status.between?(200, 299)
      raw.strip.empty? ? {} : JSON.parse(raw)
    rescue JSON::ParserError => e
      raise Error, "#{method} #{path} returned invalid JSON: #{e.message}"
    rescue URI::InvalidURIError, SystemCallError, IOError, Timeout::Error => e
      raise Error, "#{method} #{path} failed: #{e.class}: #{e.message}"
    end

    def perform_http(method:, uri:, body:)
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = uri.scheme == "https"
      http.open_timeout = @open_timeout
      http.read_timeout = @read_timeout
      request = case method
                when "GET" then Net::HTTP::Get.new(uri.request_uri)
                when "POST" then Net::HTTP::Post.new(uri.request_uri)
                else raise Error, "unsupported HTTP method #{method}"
                end
      if body
        request["Content-Type"] = "application/json"
        request.body = JSON.generate(body)
      end
      http.request(request)
    end

    def nonempty(value, label)
      text = value.to_s.strip
      raise Error, "#{label} must not be empty" if text.empty?
      text
    end

    def positive_integer(value, label)
      number = Integer(value)
      raise ArgumentError unless number.positive?
      number
    rescue ArgumentError, TypeError
      raise Error, "#{label} must be a positive integer"
    end
  end
end
