# frozen_string_literal: true

require "json"
require "net/http"
require "uri"

module LocalModelEvaluation
  class RunpodClient
    DEFAULT_BASE_URL = "https://api.runpod.io/v2"

    class Error < StandardError
      attr_reader :status

      def initialize(status, detail)
        @status = Integer(status)
        super("RunPod API #{@status}: #{detail}")
      end
    end

    Response = Struct.new(:status, :body, keyword_init: true)

    def initialize(api_key:, base_url: DEFAULT_BASE_URL, open_timeout: 5, read_timeout: 30, transport: nil)
      @api_key = api_key.to_s
      raise ArgumentError, "RUNPOD_API_KEY is empty" if @api_key.empty?

      @base_url = base_url.to_s.sub(%r{/+\z}, "")
      @open_timeout = open_timeout
      @read_timeout = read_timeout
      @transport = transport
    end

    def list_pods
      data = request("GET", "/pods")
      Array(data.fetch("pods"))
    end

    def get_pod(pod_id)
      request("GET", "/pods/#{safe_id(pod_id)}")
    end

    def list_gpu_types(cloud:, count: 1)
      data = request(
        "GET",
        "/catalog/gpus",
        query: {
          "include" => "AVAILABILITY",
          "product" => "POD",
          "count" => Integer(count),
          "cloud" => cloud.to_s
        }
      )
      Array(data.fetch("gpus"))
    end

    def create_pod(body)
      request("POST", "/pods", body:)
    end

    def delete_pod(pod_id)
      request("DELETE", "/pods/#{safe_id(pod_id)}")
    end

    private

    def safe_id(value)
      id = value.to_s
      raise ArgumentError, "invalid RunPod resource id" unless id.match?(/\A[A-Za-z0-9_-]+\z/)

      id
    end

    def request(method, path, query: nil, body: nil)
      uri = URI.parse("#{@base_url}#{path}")
      uri.query = URI.encode_www_form(query) if query && !query.empty?
      headers = {
        "Authorization" => "Bearer #{@api_key}",
        "Accept" => "application/json"
      }
      headers["Content-Type"] = "application/json" if body
      encoded_body = body && JSON.generate(body)

      response = if @transport
                   @transport.call(method:, uri:, headers:, body: encoded_body)
                 else
                   perform_http(method:, uri:, headers:, body: encoded_body)
                 end

      status = response.respond_to?(:code) ? response.code.to_i : Integer(response.status)
      raw_body = response.body.to_s
      return parse_success(raw_body) if status.between?(200, 299)

      raise Error.new(status, error_detail(raw_body))
    end

    def perform_http(method:, uri:, headers:, body:)
      request_class = {
        "GET" => Net::HTTP::Get,
        "POST" => Net::HTTP::Post,
        "DELETE" => Net::HTTP::Delete
      }.fetch(method)
      req = request_class.new(uri)
      headers.each { |key, value| req[key] = value }
      req.body = body if body

      Net::HTTP.start(
        uri.host,
        uri.port,
        use_ssl: uri.scheme == "https",
        open_timeout: @open_timeout,
        read_timeout: @read_timeout
      ) { |http| http.request(req) }
    end

    def parse_success(raw_body)
      return {} if raw_body.strip.empty?

      JSON.parse(raw_body)
    rescue JSON::ParserError => e
      raise Error.new(502, "non-JSON success response: #{e.message}")
    end

    def error_detail(raw_body)
      parsed = JSON.parse(raw_body) rescue nil
      if parsed.is_a?(Hash)
        parsed["detail"] || parsed["error"] || parsed["message"] || parsed["title"] || raw_body.strip
      else
        raw_body.strip.empty? ? "request failed" : raw_body.strip
      end
    end
  end
end
