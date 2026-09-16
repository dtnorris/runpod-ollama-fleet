# frozen_string_literal: true

require "yaml"

module RunpodOllamaFleet
  class ExecutionPoolHardware
    CONTRACT_VERSION = "rpof-execution-pool-hardware/v0.1"
    SUPPORTED_CLOUDS = %w[SECURE COMMUNITY].freeze

    class Error < StandardError; end

    Profile = Struct.new(:model, :cloud, :gpu_ids, keyword_init: true)

    def initialize(path:)
      @path = File.expand_path(path)
    end

    def profile_for(model)
      document = load_document
      model_name = model.to_s.strip
      raise Error, "model must not be empty" if model_name.empty?

      entry = document.fetch("models")[model_name]
      raise Error, "no qualified RPOF hardware profile for #{model_name.inspect}" unless entry.is_a?(Hash)

      cloud = (entry["cloud"] || document.fetch("default_cloud")).to_s.upcase
      unless SUPPORTED_CLOUDS.include?(cloud)
        raise Error, "hardware profile cloud must be one of: #{SUPPORTED_CLOUDS.join(', ')}"
      end

      gpu_ids = Array(entry["qualified_gpus"]).map { |value| value.to_s.strip }.reject(&:empty?).uniq
      raise Error, "hardware profile for #{model_name.inspect} has no qualified_gpus" if gpu_ids.empty?

      Profile.new(model: model_name, cloud:, gpu_ids:)
    rescue KeyError => e
      raise Error, "hardware qualification config is missing required key: #{e.message}"
    end

    private

    def load_document
      data = YAML.safe_load_file(@path, aliases: false)
      raise Error, "hardware qualification config must contain a mapping" unless data.is_a?(Hash)
      data = data.transform_keys(&:to_s)
      unless data["contract_version"] == CONTRACT_VERSION
        raise Error, "hardware qualification contract must be #{CONTRACT_VERSION.inspect}"
      end
      default_cloud = data["default_cloud"].to_s.upcase
      unless SUPPORTED_CLOUDS.include?(default_cloud)
        raise Error, "default_cloud must be one of: #{SUPPORTED_CLOUDS.join(', ')}"
      end
      models = data["models"]
      raise Error, "hardware qualification models must be a non-empty mapping" unless models.is_a?(Hash) && !models.empty?

      normalized = models.to_h do |key, value|
        [key.to_s, value.is_a?(Hash) ? value.transform_keys(&:to_s) : value]
      end
      data.merge("models" => normalized, "default_cloud" => default_cloud)
    rescue Psych::Exception => e
      raise Error, "invalid hardware qualification YAML: #{e.message}"
    rescue SystemCallError => e
      raise Error, "cannot read hardware qualification config #{@path}: #{e.message}"
    end
  end
end
