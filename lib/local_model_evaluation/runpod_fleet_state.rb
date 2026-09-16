# frozen_string_literal: true

require "fileutils"
require "json"
require "time"
require_relative "runpod_workers"

module LocalModelEvaluation
  class RunpodFleetState
    SCHEMA_VERSION = 1
    STATE_FILE = "fleet.json"
    CURRENT_FILE = "current"
    ARTIFACT_DIRS = %w[bootstrap tunnels lease].freeze
    DEFAULT_LOCAL_PORT_BASE = 11_441

    class Error < StandardError; end

    def initialize(root:, clock: nil, local_port_base: DEFAULT_LOCAL_PORT_BASE)
      @root = File.expand_path(root)
      @clock = clock || -> { Time.now.utc }
      @local_port_base = Integer(local_port_base)
      max_base = 65_535 - RunpodWorkers::MAX_WORKERS + 1
      unless @local_port_base.between?(1, max_base)
        raise Error, "local port base must leave room for #{RunpodWorkers::MAX_WORKERS} managed workers"
      end
    rescue ArgumentError, TypeError
      raise Error, "local port base must be an integer"
    end

    attr_reader :root

    def current_id
      return nil unless File.file?(current_path)

      value = File.read(current_path).strip
      return nil if value.empty?

      validate_fleet_id!(value)
      value
    end

    def current
      id = current_id
      id ? load(id) : nil
    end

    def assert_no_active!
      record = current
      return unless record

      if record["status"] == "active"
        raise Error,
              "active RunPod fleet state already exists: #{record.fetch('fleet_id')}; " \
              "destroy or reconcile it before creating another fleet"
      end

      clear_current(record.fetch("fleet_id"))
    end

    def activate(workers:, cloud:, gpu_id:, image:, lease: nil, provisioning: nil)
      assert_no_active!

      workers = Array(workers).sort_by(&:index)
      raise Error, "cannot activate an empty RunPod fleet" if workers.empty?
      validate_worker_indices!(workers.map(&:index))
      lease = normalize_lease(lease)
      provisioning = normalize_provisioning(provisioning)

      timestamp = utc_now
      fleet_id = build_fleet_id(timestamp, workers.first.pod_id)
      dir = fleet_dir(fleet_id)
      raise Error, "fleet state directory already exists: #{dir}" if File.exist?(dir)

      worker_started_at = lease ? Time.parse(lease.fetch("started_at_utc")).utc : timestamp
      worker_records = workers.map do |worker|
        worker_record(worker, created_at: worker_started_at, generation: 1, gpu_id: gpu_id)
      end

      record = {
        "schema_version" => SCHEMA_VERSION,
        "fleet_id" => fleet_id,
        "status" => "active",
        "created_at_utc" => timestamp.iso8601,
        "destroyed_at_utc" => nil,
        "cloud" => cloud,
        "gpu" => {
          "id" => gpu_id,
          "count_per_worker" => 1
        },
        "image" => image,
        "worker_count" => worker_records.length,
        "fleet_hourly_rate_usd" => workers.sum(&:hourly_rate),
        "workers" => worker_records,
        "artifact_dirs" => {
          "bootstrap" => "bootstrap",
          "tunnels" => "tunnels",
          "lease" => "lease"
        }
      }
      record["lease"] = lease if lease
      record["provisioning"] = provisioning if provisioning

      begin
        ARTIFACT_DIRS.each { |name| FileUtils.mkdir_p(File.join(dir, name)) }
        write_record(record)
        atomic_write(current_path, "#{fleet_id}\n")
      rescue StandardError
        FileUtils.rm_rf(dir)
        raise
      end

      record
    end

    def add_workers(workers:, created_at_utc_by_index:, gpu_id: nil)
      record = active_record!
      workers = Array(workers).sort_by(&:index)
      raise Error, "cannot add an empty worker set" if workers.empty?
      existing_count = Integer(record.fetch("worker_count"))
      expected_indices = ((existing_count + 1)..(existing_count + workers.length)).to_a
      actual_indices = workers.map { |worker| Integer(worker.index) }
      unless actual_indices == expected_indices
        raise Error, "scaled workers must extend contiguous slots #{expected_indices.join(', ')}"
      end

      created_at_utc_by_index = created_at_utc_by_index.transform_keys { |key| Integer(key) }
      worker_records = workers.map do |worker|
        index = Integer(worker.index)
        started_at = parse_time(created_at_utc_by_index.fetch(index), "burst_#{worker.index} created_at_utc")
        retired = latest_retired_worker(record, index)
        generation = retired ? Integer(retired.fetch("generation", 1)) + 1 : 1
        entry = worker_record(worker, created_at: started_at, generation:, gpu_id:)
        if retired
          history = Array(retired["history"]).map(&:dup)
          history << historical_worker(retired)
          entry["history"] = history
        end
        entry
      end
      record.fetch("workers").concat(worker_records)
      record["workers"].sort_by! { |worker| Integer(worker.fetch("index")) }
      refresh_fleet_totals!(record)
      write_record(record)
      record
    rescue KeyError, ArgumentError, TypeError => e
      raise Error, "could not add workers: #{e.message}"
    end

    def retire_tail_worker(index, destroyed_at_utc:)
      record = active_record!
      index = RunpodWorkers.validate_index(index)
      workers = record.fetch("workers")
      raise Error, "cannot retire the final RunPod worker" if workers.length <= 1

      highest = workers.map { |worker| Integer(worker.fetch("index")) }.max
      unless index == highest
        raise Error, "can only retire highest contiguous slot burst_#{highest}; got burst_#{index}"
      end

      worker = fetch_worker!(record, index)
      unless %w[active destroyed].include?(worker.fetch("status").to_s)
        raise Error, "burst_#{index} cannot be retired from state #{worker.fetch('status').inspect}"
      end

      retired = Marshal.load(Marshal.dump(worker))
      retired["status"] = "destroyed"
      retired["destroyed_at_utc"] ||= parse_time(
        destroyed_at_utc,
        "burst_#{index} destroyed_at_utc"
      ).iso8601
      retired.delete("replacement_pending")
      retired.delete("replacement_previous_status")
      retired.delete("replacement_started_at_utc")

      record["retired_workers"] ||= []
      record.fetch("retired_workers") << retired
      workers.delete(worker)
      refresh_fleet_totals!(record)
      write_record(record)
      record
    rescue RunpodWorkers::Error, ArgumentError, TypeError => e
      raise Error, "could not retire worker: #{e.message}"
    end

    def begin_replacement(index)
      record = active_record!
      worker = fetch_worker!(record, index)
      return record if worker["status"] == "replacing"
      unless %w[active destroyed].include?(worker["status"].to_s)
        raise Error, "burst_#{index} cannot enter replacement from state #{worker['status'].inspect}"
      end

      worker["replacement_previous_status"] = worker.fetch("status")
      worker["status"] = "replacing"
      worker["replacement_started_at_utc"] = utc_now.iso8601
      refresh_fleet_totals!(record)
      write_record(record)
      record
    end

    def cancel_replacement(index)
      record = active_record!
      worker = fetch_worker!(record, index)
      return record unless worker["status"] == "replacing"

      previous = worker.delete("replacement_previous_status") || "active"
      worker.delete("replacement_started_at_utc")
      worker["status"] = previous
      refresh_fleet_totals!(record)
      write_record(record)
      record
    end

    def mark_replacement_destroyed(index)
      record = active_record!
      worker = fetch_worker!(record, index)
      unless worker["status"] == "replacing"
        raise Error, "burst_#{index} is not in replacement state"
      end

      worker["status"] = "destroyed"
      worker["destroyed_at_utc"] ||= utc_now.iso8601
      worker["replacement_pending"] = true
      worker.delete("replacement_previous_status")
      worker.delete("replacement_started_at_utc")
      refresh_fleet_totals!(record)
      write_record(record)
      record
    end

    def complete_replacement(worker:, created_at_utc:, gpu_id: nil)
      record = active_record!
      index = Integer(worker.index)
      old = fetch_worker!(record, index)
      unless old["status"] == "destroyed" && old["replacement_pending"]
        raise Error, "burst_#{index} is not waiting for a replacement"
      end

      stopped_at = parse_time(old.fetch("destroyed_at_utc"), "burst_#{index} destroyed_at_utc")
      started_at = worker_started_at(old, record)
      accrued_offset = Float(old.fetch("accrued_cost_offset_usd", 0.0)) +
                       (Float(old.fetch("hourly_rate_usd")) * nonnegative_seconds(started_at, stopped_at) / 3600.0)
      lease_offset = Float(old.fetch("lease_spend_offset_usd", 0.0))
      if record["lease"]
        lease_started_at = parse_time(record.dig("lease", "started_at_utc"), "lease started_at_utc")
        lease_worker_start = [started_at, lease_started_at].max
        lease_offset += Float(old.fetch("hourly_rate_usd")) * nonnegative_seconds(lease_worker_start, stopped_at) / 3600.0
      end

      history = Array(old["history"]).map(&:dup)
      history << historical_worker(old)
      replacement = worker_record(
        worker,
        created_at: parse_time(created_at_utc, "burst_#{index} replacement created_at_utc"),
        generation: Integer(old.fetch("generation", 1)) + 1,
        gpu_id: gpu_id || old["gpu_id"] || record.dig("gpu", "id")
      )
      replacement["history"] = history
      replacement["accrued_cost_offset_usd"] = accrued_offset.round(6)
      replacement["lease_spend_offset_usd"] = lease_offset.round(6) if record["lease"]

      workers = record.fetch("workers")
      workers[workers.index(old)] = replacement
      refresh_fleet_totals!(record)
      write_record(record)
      record
    rescue ArgumentError, TypeError => e
      raise Error, "could not complete replacement: #{e.message}"
    end

    def mark_destroyed(indices, reason: nil)
      record = current
      return nil unless record

      requested = Array(indices).map { |value| Integer(value) }.uniq
      timestamp = utc_now.iso8601
      known = record.fetch("workers").to_h { |worker| [worker.fetch("index"), worker] }
      unknown = requested.reject { |index| known.key?(index) }
      raise Error, "fleet state does not contain worker index(es): #{unknown.join(', ')}" unless unknown.empty?

      teardown_reason = reason.to_s.strip
      requested.each do |index|
        worker = known.fetch(index)
        worker["status"] = "destroyed"
        worker["destroyed_at_utc"] ||= timestamp
        worker["teardown_reason"] = teardown_reason unless teardown_reason.empty?
      end
      refresh_fleet_totals!(record)

      if record.fetch("workers").all? { |worker| worker["status"] == "destroyed" }
        record["status"] = "destroyed"
        record["destroyed_at_utc"] ||= timestamp
        record["teardown_reason"] = teardown_reason unless teardown_reason.empty?
      end

      write_record(record)
      clear_current(record.fetch("fleet_id")) if record["status"] == "destroyed"
      record
    rescue ArgumentError, TypeError
      raise Error, "worker indices must be integers"
    end

    def discard(fleet_id)
      return unless fleet_id

      validate_fleet_id!(fleet_id)
      clear_current(fleet_id)
      FileUtils.rm_rf(fleet_dir(fleet_id))
    end

    def load(fleet_id)
      path = state_path(fleet_id)
      raise Error, "fleet state file is missing: #{path}" unless File.file?(path)

      record = JSON.parse(File.read(path))
      unless record["fleet_id"] == fleet_id
        raise Error, "fleet state id mismatch in #{path}"
      end
      validate_record!(record)

      record
    rescue JSON::ParserError => e
      raise Error, "fleet state file is invalid JSON: #{path}: #{e.message}"
    end

    def fleet_dir(fleet_id)
      validate_fleet_id!(fleet_id)
      File.join(@root, fleet_id)
    end

    def state_path(fleet_id)
      File.join(fleet_dir(fleet_id), STATE_FILE)
    end

    def artifact_dir(fleet_id, name)
      key = name.to_s
      raise Error, "unknown fleet artifact directory: #{key}" unless ARTIFACT_DIRS.include?(key)

      File.join(fleet_dir(fleet_id), key)
    end

    private

    def current_path
      File.join(@root, CURRENT_FILE)
    end

    def write_record(record)
      atomic_write(
        state_path(record.fetch("fleet_id")),
        JSON.pretty_generate(record) + "\n"
      )
    end

    def atomic_write(path, content)
      FileUtils.mkdir_p(File.dirname(path))
      tmp = "#{path}.tmp.#{$$}.#{Thread.current.object_id}"
      File.write(tmp, content)
      File.rename(tmp, path)
    ensure
      File.delete(tmp) if defined?(tmp) && tmp && File.exist?(tmp)
    end

    def clear_current(fleet_id)
      return unless File.file?(current_path)
      return unless File.read(current_path).strip == fleet_id

      File.delete(current_path)
    end

    def build_fleet_id(timestamp, pod_id)
      suffix = pod_id.to_s.gsub(/[^A-Za-z0-9_-]/, "")[0, 12].to_s
      raise Error, "cannot build fleet id from empty pod id" if suffix.empty?

      "#{timestamp.strftime('%Y%m%dT%H%M%SZ')}-#{suffix}"
    end

    def utc_now
      value = @clock.call
      value = Time.parse(value.to_s) unless value.is_a?(Time)
      value.utc
    end

    def validate_fleet_id!(fleet_id)
      return if fleet_id.to_s.match?(/\A\d{8}T\d{6}Z-[A-Za-z0-9_-]{1,32}\z/)

      raise Error, "invalid fleet id: #{fleet_id.inspect}"
    end

    def active_record!
      record = current
      raise Error, "no current RunPod fleet state exists; provision a fleet first" unless record
      raise Error, "current RunPod fleet #{record.fetch('fleet_id')} is not active" unless record["status"] == "active"
      record
    end

    def fetch_worker!(record, index)
      index = RunpodWorkers.validate_index(index)
      worker = record.fetch("workers").find { |candidate| Integer(candidate.fetch("index")) == index }
      raise Error, "current fleet does not contain burst_#{index}" unless worker
      worker
    rescue RunpodWorkers::Error => e
      raise Error, e.message
    end

    def latest_retired_worker(record, index)
      Array(record["retired_workers"])
        .select { |worker| Integer(worker.fetch("index")) == index }
        .max_by { |worker| Integer(worker.fetch("generation", 1)) }
    end

    def worker_record(worker, created_at:, generation:, gpu_id: nil)
      record = {
        "index" => Integer(worker.index),
        "name" => worker.name,
        "pod_id" => worker.pod_id,
        "host" => worker.host,
        "ssh_port" => Integer(worker.ssh_port),
        "hourly_rate_usd" => Float(worker.hourly_rate),
        "local_ollama_url" => "http://127.0.0.1:#{@local_port_base + Integer(worker.index) - 1}",
        "status" => "active",
        "generation" => Integer(generation),
        "created_at_utc" => created_at.utc.iso8601
      }
      selected_gpu = gpu_id.to_s.strip
      record["gpu_id"] = selected_gpu unless selected_gpu.empty?
      record
    end

    def historical_worker(worker)
      %w[generation name pod_id host ssh_port hourly_rate_usd gpu_id created_at_utc destroyed_at_utc].each_with_object({}) do |key, out|
        out[key] = worker[key] if worker.key?(key)
      end
    end

    def worker_started_at(worker, record)
      value = worker["created_at_utc"] || record.fetch("created_at_utc")
      parse_time(value, "burst_#{worker.fetch('index')} created_at_utc")
    end

    def refresh_fleet_totals!(record)
      workers = record.fetch("workers")
      record["worker_count"] = workers.length
      record["fleet_hourly_rate_usd"] = workers.sum do |worker|
        worker["status"] == "active" ? Float(worker.fetch("hourly_rate_usd")) : 0.0
      end
    end

    def normalize_provisioning(value)
      return nil if value.nil?
      raise Error, "provisioning metadata must be a hash" unless value.is_a?(Hash)
      data = value.transform_keys(&:to_s)
      disk = positive_integer(data.fetch("container_disk_gb"), "provisioning container_disk_gb")
      if data["network_volume_id"]
        id = data.fetch("network_volume_id").to_s
        raise Error, "invalid provisioning network_volume_id" unless id.match?(/\A[A-Za-z0-9_-]+\z/)
        raise Error, "network volume conflicts with provisioning volume_gb" unless data["volume_gb"].nil?
        raise Error, "network volume must mount at /workspace" unless data["volume_mount_path"] == "/workspace"

        { "container_disk_gb" => disk, "volume_gb" => nil,
          "network_volume_id" => id, "volume_mount_path" => "/workspace" }
      else
        { "container_disk_gb" => disk,
          "volume_gb" => positive_integer(data.fetch("volume_gb"), "provisioning volume_gb") }
      end
    rescue KeyError => e
      raise Error, "invalid provisioning metadata: #{e.message}"
    end

    def positive_integer(value, label)
      number = Integer(value)
      raise Error, "#{label} must be a positive integer" unless number.positive?
      number
    rescue ArgumentError, TypeError
      raise Error, "#{label} must be a positive integer"
    end

    def parse_time(value, label)
      time = value.is_a?(Time) ? value : Time.parse(value.to_s)
      time.utc
    rescue ArgumentError
      raise Error, "#{label} is invalid: #{value.inspect}"
    end

    def nonnegative_seconds(start_time, end_time)
      [end_time - start_time, 0.0].max
    end

    def normalize_lease(value)
      return nil if value.nil?
      raise Error, "lease must be a hash" unless value.is_a?(Hash)

      lease = value.transform_keys(&:to_s)
      started_at = Time.parse(lease.fetch("started_at_utc").to_s).utc
      max_runtime_seconds = optional_positive_float(lease["max_runtime_seconds"], "lease max_runtime_seconds")
      max_spend_usd = optional_positive_float(lease["max_spend_usd"], "lease max_spend_usd")
      if max_runtime_seconds.nil? && max_spend_usd.nil?
        raise Error, "lease must define max_runtime_seconds and/or max_spend_usd"
      end

      {
        "started_at_utc" => started_at.iso8601,
        "max_runtime_seconds" => max_runtime_seconds,
        "expires_at_utc" => max_runtime_seconds ? (started_at + max_runtime_seconds).iso8601 : nil,
        "max_spend_usd" => max_spend_usd
      }
    rescue KeyError, ArgumentError => e
      raise Error, "invalid lease: #{e.message}"
    end

    def optional_positive_float(value, label)
      return nil if value.nil?

      number = Float(value)
      raise Error, "#{label} must be positive" unless number.positive?

      number
    rescue ArgumentError, TypeError
      raise Error, "#{label} must be numeric"
    end

    def validate_record!(record)
      workers = Array(record.fetch("workers"))
      validate_worker_indices!(workers.map { |worker| worker.fetch("index") })
      expected_count = RunpodWorkers.validate_count(record.fetch("worker_count"))
      unless expected_count == workers.length
        raise Error, "fleet worker_count #{expected_count} does not match #{workers.length} worker records"
      end
      normalize_lease(record["lease"]) if record["lease"]
      normalize_provisioning(record["provisioning"]) if record["provisioning"]
      tracked_workers = workers + Array(record["retired_workers"])
      tracked_workers.each do |worker|
        RunpodWorkers.validate_index(worker.fetch("index"))
        Integer(worker.fetch("generation", 1))
        if worker.key?("gpu_id") && worker.fetch("gpu_id").to_s.strip.empty?
          raise Error, "worker gpu_id must not be empty"
        end
        parse_time(worker["created_at_utc"], "worker created_at_utc") if worker["created_at_utc"]
        if worker["status"] == "destroyed" && worker["destroyed_at_utc"]
          parse_time(worker.fetch("destroyed_at_utc"), "worker destroyed_at_utc")
        end
        Array(worker["history"]).each do |prior|
          Integer(prior.fetch("generation", 1))
          prior.fetch("pod_id")
        end
      end
    rescue KeyError, ArgumentError, TypeError, RunpodWorkers::Error => e
      raise Error, "invalid fleet state: #{e.message}"
    end

    def validate_worker_indices!(values)
      indices = values.map { |value| RunpodWorkers.validate_index(value) }
      raise Error, "fleet worker indices must be unique" unless indices.uniq.length == indices.length
    rescue RunpodWorkers::Error => e
      raise Error, e.message
    end
  end
end
