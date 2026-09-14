# frozen_string_literal: true

require "fileutils"
require "json"
require "time"
require_relative "runpod_workers"

module LocalModelEvaluation
  class RunpodFleetNamespace
    DEFAULT_KEY = "default"
    KEY_PATTERN = /\A[a-z0-9][a-z0-9_-]{0,31}\z/
    DEFAULT_LOCAL_PORT_BASE = 11_441
    PORT_BLOCK_SIZE = RunpodWorkers::MAX_WORKERS
    MAX_NAMED_FLEETS = 100
    DEFAULT_MAX_TOTAL_HOURLY_USD = 6.0
    REGISTRY_FILE = "registry.json"
    REGISTRY_LOCK = ".registry.lock"

    class Error < StandardError; end

    def self.normalize_key(value)
      key = value.to_s.strip.downcase
      key = DEFAULT_KEY if key.empty?
      raise Error, "fleet key must match #{KEY_PATTERN.inspect}" unless key.match?(KEY_PATTERN)

      key
    end

    def initialize(root:, repo_root:, fleet_key: DEFAULT_KEY, create: false, provisional: false, clock: nil)
      @root = File.expand_path(root)
      @repo_root = File.expand_path(repo_root)
      @fleet_key = self.class.normalize_key(fleet_key)
      @clock = clock || -> { Time.now.utc }
      @slot = resolve_slot(create:, provisional:)
    end

    attr_reader :root, :repo_root, :fleet_key, :slot

    def default?
      fleet_key == DEFAULT_KEY
    end

    def state_root
      default? ? root : File.join(root, "fleets", fleet_key)
    end

    def env_path
      default? ? File.join(repo_root, ".env") : File.join(state_root, "fleet.env")
    end

    def local_port_base
      DEFAULT_LOCAL_PORT_BASE + (slot * PORT_BLOCK_SIZE)
    end

    def total_active_hourly_usd
      fleet_roots.sum { |fleet_root| active_hourly_rate(fleet_root) }
    end

    def registered_fleet_keys
      registry.fetch("fleets").keys.sort
    end

    private

    def resolve_slot(create:, provisional:)
      return 0 if default?

      data = registry
      existing = data.fetch("fleets")[fleet_key]
      return Integer(existing.fetch("slot")) if existing

      return next_available_slot(data) if provisional
      raise Error, "unknown RunPod fleet #{fleet_key.inspect}; create it first with runpod-create --fleet #{fleet_key}" unless create

      with_registry_lock do
        data = registry
        existing = data.fetch("fleets")[fleet_key]
        next Integer(existing.fetch("slot")) if existing

        slot = next_available_slot(data)
        data.fetch("fleets")[fleet_key] = {
          "slot" => slot,
          "registered_at_utc" => utc_now.iso8601
        }
        write_registry(data)
        slot
      end
    end

    def registry
      return empty_registry unless File.file?(registry_path)

      data = JSON.parse(File.read(registry_path))
      data["fleets"] = {} unless data["fleets"].is_a?(Hash)
      data
    rescue JSON::ParserError => e
      raise Error, "RunPod fleet registry is invalid JSON: #{e.message}"
    end

    def empty_registry
      { "schema_version" => 1, "fleets" => {} }
    end

    def next_available_slot(data)
      used = data.fetch("fleets").values.map { |entry| Integer(entry.fetch("slot")) }
      slot = (1..MAX_NAMED_FLEETS).find { |candidate| !used.include?(candidate) }
      raise Error, "no RunPod fleet namespace slots remain" unless slot

      slot
    rescue KeyError, ArgumentError, TypeError
      raise Error, "RunPod fleet registry contains an invalid slot"
    end

    def fleet_roots
      [root] + registry.fetch("fleets").keys.sort.map { |key| File.join(root, "fleets", key) }
    end

    def active_hourly_rate(fleet_root)
      current_path = File.join(fleet_root, "current")
      return 0.0 unless File.file?(current_path)

      fleet_id = File.read(current_path).strip
      return 0.0 if fleet_id.empty?

      state_path = File.join(fleet_root, fleet_id, "fleet.json")
      raise Error, "active fleet pointer references missing state: #{state_path}" unless File.file?(state_path)

      record = JSON.parse(File.read(state_path))
      return 0.0 unless record["status"] == "active"

      Float(record.fetch("fleet_hourly_rate_usd"))
    rescue JSON::ParserError, KeyError, ArgumentError, TypeError => e
      raise Error, "cannot determine aggregate managed RunPod cost for #{fleet_root}: #{e.message}"
    end

    def registry_path
      File.join(root, REGISTRY_FILE)
    end

    def lock_path
      File.join(root, REGISTRY_LOCK)
    end

    def with_registry_lock
      FileUtils.mkdir_p(root)
      File.open(lock_path, File::RDWR | File::CREAT, 0o600) do |lock|
        lock.flock(File::LOCK_EX)
        yield
      ensure
        lock.flock(File::LOCK_UN) rescue nil
      end
    end

    def write_registry(data)
      FileUtils.mkdir_p(root)
      tmp = "#{registry_path}.tmp.#{$$}.#{Thread.current.object_id}"
      File.write(tmp, JSON.pretty_generate(data) + "\n")
      File.rename(tmp, registry_path)
    ensure
      File.delete(tmp) if defined?(tmp) && tmp && File.exist?(tmp)
    end

    def utc_now
      value = @clock.call
      value = Time.parse(value.to_s) unless value.is_a?(Time)
      value.utc
    end
  end
end
