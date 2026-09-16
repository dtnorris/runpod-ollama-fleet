# frozen_string_literal: true

require_relative "runpod_client"

module LocalModelEvaluation
  class RunpodCapacityPolicy
    DEFAULT_CLOUD = "SECURE"
    SUPPORTED_CLOUDS = %w[COMMUNITY SECURE].freeze
    DEFAULT_MIN_VRAM_GB = Integer(ENV.fetch("RUNPOD_GPU_MEMORY_GB", "48"))

    class Error < StandardError; end

    Candidate = Struct.new(
      :gpu_id,
      :memory_gb,
      :availability,
      :hourly_rate_usd,
      :catalog,
      keyword_init: true
    )

    Rejection = Struct.new(:gpu_id, :reason, keyword_init: true)
    Ranking = Struct.new(:cloud, :candidates, :rejections, keyword_init: true)

    def initialize(client:)
      @client = client
    end

    def rank(gpu_ids:, cloud: DEFAULT_CLOUD,
             max_hourly_per_worker_usd: nil,
             min_vram_gb: DEFAULT_MIN_VRAM_GB)
      ids = normalize_gpu_ids(gpu_ids)
      cloud = normalize_cloud(cloud)
      price_cap = optional_positive_float(max_hourly_per_worker_usd, "max hourly per worker")
      min_vram = positive_integer(min_vram_gb, "minimum VRAM")
      catalog = @client.list_gpu_types(cloud:, count: 1)
      by_id = Array(catalog).to_h { |row| [row["id"].to_s, row] }
      candidates = []
      rejections = []

      ids.each do |gpu_id|
        row = by_id[gpu_id]
        unless row
          rejections << Rejection.new(gpu_id:, reason: "catalog did not return GPU")
          next
        end

        memory = row["memory"].to_i
        if memory < min_vram
          rejections << Rejection.new(
            gpu_id:,
            reason: "#{memory} GB VRAM is below required #{min_vram} GB"
          )
          next
        end

        unless row[cloud.downcase] == true
          rejections << Rejection.new(gpu_id:, reason: "not available on #{cloud} cloud")
          next
        end

        availability = row["availability"].to_s
        if availability.empty? || availability == "NONE"
          label = availability.empty? ? "unknown" : availability
          rejections << Rejection.new(gpu_id:, reason: "#{cloud} availability is #{label}")
          next
        end

        begin
          rate = positive_float(row.dig("price", cloud.downcase), "#{gpu_id} #{cloud} hourly rate")
        rescue Error => e
          rejections << Rejection.new(gpu_id:, reason: e.message)
          next
        end
        if price_cap && rate > price_cap
          rejections << Rejection.new(
            gpu_id:,
            reason: format("$%.4f/hr exceeds per-worker cap $%.4f/hr", rate, price_cap)
          )
          next
        end

        candidates << Candidate.new(
          gpu_id:,
          memory_gb: memory,
          availability:,
          hourly_rate_usd: rate,
          catalog: row
        )
      end

      Ranking.new(
        cloud:,
        candidates: candidates.sort_by { |candidate| [candidate.hourly_rate_usd, candidate.gpu_id] },
        rejections:
      )
    rescue RunpodClient::Error => e
      raise Error, e.message
    end

    private

    def normalize_gpu_ids(values)
      ids = Array(values).map { |value| value.to_s.strip }.reject(&:empty?).uniq
      raise Error, "at least one qualified GPU id is required" if ids.empty?
      ids
    end

    def normalize_cloud(value)
      cloud = value.to_s.upcase
      return cloud if SUPPORTED_CLOUDS.include?(cloud)
      raise Error, "cloud must be one of: #{SUPPORTED_CLOUDS.join(', ')}"
    end

    def positive_integer(value, label)
      number = Integer(value)
      raise ArgumentError unless number.positive?
      number
    rescue ArgumentError, TypeError
      raise Error, "#{label} must be a positive integer"
    end

    def positive_float(value, label)
      number = Float(value)
      raise ArgumentError unless number.positive?
      number
    rescue ArgumentError, TypeError
      raise Error, "#{label} must be a positive number"
    end

    def optional_positive_float(value, label)
      return nil if value.nil?
      positive_float(value, label)
    end
  end
end
