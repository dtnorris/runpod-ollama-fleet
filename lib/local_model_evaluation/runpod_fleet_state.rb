# frozen_string_literal: true

require "digest"
require "fileutils"
require "json"
require "time"
require_relative "runpod_workers"

module LocalModelEvaluation
  class RunpodFleetState
    SCHEMA_VERSION = 2
    LEGACY_SCHEMA_VERSION = 1
    STATE_FILE = "fleet.json"
    CURRENT_FILE = "current"
    ARTIFACT_DIRS = %w[bootstrap tunnels lease runtime-alias].freeze
    DEFAULT_LOCAL_PORT_BASE = 11_441
    CAMPAIGN_AUTHORITY_VERSION = "rpof-capacity-campaign-fleet-authority/v0.1"
    CAMPAIGN_AUTHORITY_KEYS = %w[
      contract_version binding_sha256 campaign_identity_sha256 budget_id profile_id
    ].freeze
    SHA256 = /\A[0-9a-f]{64}\z/

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

    def activate(workers:, cloud:, gpu_id:, image:, lease: nil, provisioning: nil,
                 campaign_authority: nil)
      assert_no_active!

      workers = Array(workers).sort_by(&:index)
      raise Error, "cannot activate an empty RunPod fleet" if workers.empty?
      validate_worker_indices!(workers.map(&:index))
      lease = normalize_lease(lease)
      provisioning = normalize_provisioning(provisioning)
      campaign_authority = normalize_campaign_authority(campaign_authority)

      timestamp = utc_now
      fleet_id = build_fleet_id(timestamp, workers.first.pod_id)
      dir = fleet_dir(fleet_id)
      raise Error, "fleet state directory already exists: #{dir}" if File.exist?(dir)

      worker_started_at = lease ? Time.parse(lease.fetch("started_at_utc")).utc : timestamp
      worker_records = workers.map do |worker|
        worker_record(
          worker,
          fleet_id:,
          created_at: worker_started_at,
          generation: 1,
          gpu_id:
        )
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
          "lease" => "lease",
          "runtime-alias" => "runtime-alias"
        }
      }
      record["lease"] = lease if lease
      record["provisioning"] = provisioning if provisioning
      record["campaign_authority"] = campaign_authority if campaign_authority

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
      record = identity_record!
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
        entry = worker_record(
          worker,
          fleet_id: record.fetch("fleet_id"),
          created_at: started_at,
          generation:,
          worker_id: retired && retired.fetch("worker_id"),
          gpu_id:
        )
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
      record = identity_record!
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
      record = identity_record!
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
        fleet_id: record.fetch("fleet_id"),
        created_at: parse_time(created_at_utc, "burst_#{index} replacement created_at_utc"),
        generation: Integer(old.fetch("generation", 1)) + 1,
        worker_id: old.fetch("worker_id"),
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

    # Caller holds the existing fleet lifecycle lock. Identity is checked again
    # at each durable transition, including recovery after an uncertain delete.
    def transition_worker_lifecycle!(fleet_id:, worker_id:, generation_id:, pod_id:,
                                     phase:, reason:, registry_worker: nil, error: nil)
      record = load(fleet_id)
      worker = record.fetch("workers").find { |row| row["worker_id"] == worker_id }
      unless worker && worker["generation_id"] == generation_id && worker["pod_id"] == pod_id
        raise Error, "selected worker generation/provider identity changed"
      end
      previous = worker["lifecycle"] || {}
      allowed = {
        nil => %w[draining], "draining" => %w[retirement_requested],
        "retirement_requested" => %w[delete_in_progress],
        "delete_in_progress" => %w[delete_ambiguous retired],
        "delete_ambiguous" => %w[delete_ambiguous retired], "retired" => []
      }
      unless allowed.fetch(previous["phase"]).include?(phase)
        raise Error, "invalid worker lifecycle transition #{previous['phase'].inspect} -> #{phase}"
      end
      lifecycle = previous.merge(
        "worker_id" => worker_id, "generation_id" => generation_id, "pod_id" => pod_id,
        "phase" => phase, "revision" => previous.fetch("revision", 0) + 1,
        "mutation_id" => previous["mutation_id"] || "retire-#{Digest::SHA256.hexdigest(generation_id)}",
        "reason" => reason, "updated_at_utc" => utc_now.iso8601, "error" => error
      )
      lifecycle["registry_worker"] = registry_worker if registry_worker
      lifecycle["history"] = Array(previous["history"]) + [lifecycle.except("history", "registry_worker")]
      if phase == "retired"
        lifecycle["provider_absence_verified_at_utc"] = utc_now.iso8601
        worker["status"] = "destroyed"
        worker["destroyed_at_utc"] ||= utc_now.iso8601
      end
      worker["lifecycle"] = lifecycle
      refresh_fleet_totals!(record)
      write_record(record)
      lifecycle
    end

    def mark_destroyed(indices, reason: nil)
      id = current_id
      return nil unless id
      File.open(File.join(fleet_dir(id), ".lifecycle.lock"), File::RDWR | File::CREAT, 0o600) do |lock|
        unless lock.flock(File::LOCK_EX | File::LOCK_NB)
          raise Error, "fleet lifecycle mutation is running; retry destruction state reconciliation"
        end
        mark_destroyed_locked(indices, reason:)
      end
    end

    def mark_destroyed_locked(indices, reason: nil)
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

    # Returns the provider-neutral identities that DW-02 may place in a
    # dynamic-worker-registry/v0.1 record. Provider observation is mandatory:
    # authoritative state must never be projected onto a replacement pod that
    # happens to reuse the same slot or local endpoint.
    def registry_identity(index:, observed_pod_id:)
      record = identity_record!
      worker = fetch_worker!(record, index)
      observed = nonempty_string(observed_pod_id, "observed provider pod id")
      persisted = nonempty_string(worker.fetch("pod_id"), "persisted provider pod id")
      unless observed == persisted
        raise Error,
              "burst_#{index} provider pod identity mismatch: state records #{persisted.inspect}, " \
              "observation reports #{observed.inspect}"
      end

      {
        "worker_id" => worker.fetch("worker_id"),
        "generation_id" => worker.fetch("generation_id")
      }
    rescue KeyError => e
      raise Error, "worker identity is incomplete: #{e.message}"
    end

    def assert_durable_worker_identity!
      identity_record!
      true
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
      File.open(tmp, File::WRONLY | File::CREAT | File::TRUNC, 0o600) do |file|
        file.write(content)
        file.flush
        file.fsync
      end
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

    def identity_record!
      record = active_record!
      version = Integer(record.fetch("schema_version"))
      return record if version == SCHEMA_VERSION

      raise Error,
            "fleet state schema #{version} predates durable worker identity; " \
            "destroy/recreate the fleet before identity-sensitive lifecycle or registry publication"
    rescue KeyError, ArgumentError, TypeError => e
      raise Error, "fleet state lacks unambiguous durable worker identity: #{e.message}"
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

    def worker_record(worker, fleet_id:, created_at:, generation:, worker_id: nil, gpu_id: nil)
      index = Integer(worker.index)
      pod_id = nonempty_string(worker.pod_id, "provider pod id")
      generation = Integer(generation)
      raise Error, "worker generation must be positive" unless generation.positive?
      worker_id ||= build_worker_id(fleet_id, index)
      generation_id = build_generation_id(worker_id, generation, pod_id)
      record = {
        "index" => index,
        "name" => worker.name,
        "pod_id" => pod_id,
        "host" => worker.host,
        "ssh_port" => Integer(worker.ssh_port),
        "hourly_rate_usd" => Float(worker.hourly_rate),
        "local_ollama_url" => "http://127.0.0.1:#{@local_port_base + index - 1}",
        "status" => "active",
        "generation" => generation,
        "worker_id" => worker_id,
        "generation_id" => generation_id,
        "created_at_utc" => created_at.utc.iso8601
      }
      selected_gpu = gpu_id.to_s.strip
      record["gpu_id"] = selected_gpu unless selected_gpu.empty?
      record
    end

    def historical_worker(worker)
      %w[
        generation worker_id generation_id name pod_id host ssh_port hourly_rate_usd gpu_id
        created_at_utc destroyed_at_utc lifecycle
      ].each_with_object({}) do |key, out|
        out[key] = worker[key] if worker.key?(key)
      end
    end

    def build_worker_id(fleet_id, index)
      digest = Digest::SHA256.hexdigest(JSON.generate(["rpof-worker", fleet_id, index]))
      "worker-#{digest}"
    end

    def build_generation_id(worker_id, generation, pod_id)
      digest = Digest::SHA256.hexdigest(
        JSON.generate(["rpof-generation", worker_id, generation, pod_id])
      )
      "generation-#{digest}"
    end

    def nonempty_string(value, label)
      result = value.to_s
      raise Error, "#{label} must not be empty" if result.empty?

      result
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

      global_volume = nil
      if data["global_volume_id"]
        id = data.fetch("global_volume_id").to_s
        raise Error, "invalid provisioning global_volume_id" unless id.match?(/\A[A-Za-z0-9_-]+\z/)
        unless data["global_volume_type"] == "OBJECT_STORE_VOLUME"
          raise Error, "global volume must use OBJECT_STORE_VOLUME"
        end
        unless data["global_volume_mount_path"] == "/workspace-global"
          raise Error, "global volume must mount at /workspace-global"
        end
        raise Error, "global volume conflicts with provisioning volume_gb" unless data["volume_gb"].nil?

        global_volume = {
          "global_volume_id" => id,
          "global_volume_type" => "OBJECT_STORE_VOLUME",
          "global_volume_mount_path" => "/workspace-global"
        }
      end

      if data["network_volume_id"]
        id = data.fetch("network_volume_id").to_s
        raise Error, "invalid provisioning network_volume_id" unless id.match?(/\A[A-Za-z0-9_-]+\z/)
        raise Error, "network volume conflicts with provisioning volume_gb" unless data["volume_gb"].nil?
        raise Error, "network volume must mount at /workspace" unless data["volume_mount_path"] == "/workspace"

        normalized = {
          "container_disk_gb" => disk,
          "volume_gb" => nil,
          "network_volume_id" => id,
          "volume_mount_path" => "/workspace"
        }
        normalized.merge!(global_volume) if global_volume
        normalized
      elsif global_volume
        { "container_disk_gb" => disk, "volume_gb" => nil }.merge(global_volume)
      else
        { "container_disk_gb" => disk,
          "volume_gb" => positive_integer(data.fetch("volume_gb"), "provisioning volume_gb") }
      end
    rescue KeyError => e
      raise Error, "invalid provisioning metadata: #{e.message}"
    end

    def normalize_campaign_authority(value)
      return nil if value.nil?
      raise Error, "campaign authority must be a hash" unless value.is_a?(Hash)

      data = value.transform_keys(&:to_s)
      missing = CAMPAIGN_AUTHORITY_KEYS - data.keys
      unknown = data.keys - CAMPAIGN_AUTHORITY_KEYS
      raise Error, "campaign authority missing field(s): #{missing.join(', ')}" unless missing.empty?
      raise Error, "campaign authority has unknown field(s): #{unknown.sort.join(', ')}" unless unknown.empty?
      unless data.fetch("contract_version") == CAMPAIGN_AUTHORITY_VERSION
        raise Error, "campaign authority contract version is unsupported"
      end
      %w[binding_sha256 campaign_identity_sha256].each do |key|
        unless data.fetch(key).is_a?(String) && data.fetch(key).match?(SHA256)
          raise Error, "campaign authority #{key} must be a lowercase SHA-256 digest"
        end
      end
      %w[budget_id profile_id].each do |key|
        text = data.fetch(key)
        unless text.is_a?(String) && text.match?(/\A[A-Za-z0-9][A-Za-z0-9._-]{0,127}\z/)
          raise Error, "campaign authority #{key} has invalid format"
        end
      end
      data
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
      schema_version = Integer(record.fetch("schema_version"))
      unless [LEGACY_SCHEMA_VERSION, SCHEMA_VERSION].include?(schema_version)
        raise Error, "unsupported fleet state schema #{schema_version}"
      end
      workers = Array(record.fetch("workers"))
      validate_worker_indices!(workers.map { |worker| worker.fetch("index") })
      expected_count = RunpodWorkers.validate_count(record.fetch("worker_count"))
      unless expected_count == workers.length
        raise Error, "fleet worker_count #{expected_count} does not match #{workers.length} worker records"
      end
      normalize_lease(record["lease"]) if record["lease"]
      normalize_provisioning(record["provisioning"]) if record["provisioning"]
      normalize_campaign_authority(record["campaign_authority"]) if record["campaign_authority"]
      if schema_version == SCHEMA_VERSION
        worker_ids = workers.map { |worker| worker.fetch("worker_id") }
        raise Error, "active worker_id values must be unique" unless worker_ids.uniq.length == worker_ids.length
      end

      tracked_workers = workers + Array(record["retired_workers"])
      tracked_workers.each do |worker|
        index = RunpodWorkers.validate_index(worker.fetch("index"))
        generation = Integer(worker.fetch("generation", 1))
        validate_worker_identity!(record, worker, index, generation) if schema_version == SCHEMA_VERSION
        if worker.key?("gpu_id") && worker.fetch("gpu_id").to_s.strip.empty?
          raise Error, "worker gpu_id must not be empty"
        end
        parse_time(worker["created_at_utc"], "worker created_at_utc") if worker["created_at_utc"]
        if worker["status"] == "destroyed" && worker["destroyed_at_utc"]
          parse_time(worker.fetch("destroyed_at_utc"), "worker destroyed_at_utc")
        end
        if (lifecycle = worker["lifecycle"])
          unless lifecycle.slice("worker_id", "generation_id", "pod_id") ==
                 worker.slice("worker_id", "generation_id", "pod_id") &&
                 %w[draining retirement_requested delete_in_progress delete_ambiguous retired].include?(lifecycle["phase"]) &&
                 lifecycle["revision"].is_a?(Integer) && lifecycle["revision"].positive?
            raise Error, "invalid generation-bound worker lifecycle"
          end
          retained = lifecycle["registry_worker"]
          if retained && (retained.slice("worker_id", "generation_id") != worker.slice("worker_id", "generation_id") ||
                          retained["endpoint"] != worker["local_ollama_url"] || retained["state"] != "UNAVAILABLE")
            raise Error, "retained drain publication conflicts with worker identity"
          end
          if lifecycle["phase"] == "retired" && !lifecycle["provider_absence_verified_at_utc"]
            raise Error, "retired worker lacks provider absence evidence"
          end
        end
        Array(worker["history"]).each do |prior|
          prior_generation = Integer(prior.fetch("generation", 1))
          prior.fetch("pod_id")
          validate_historical_identity!(worker, prior, prior_generation) if schema_version == SCHEMA_VERSION
        end
      end
    rescue KeyError, ArgumentError, TypeError, RunpodWorkers::Error => e
      raise Error, "invalid fleet state: #{e.message}"
    end

    def validate_worker_identity!(record, worker, index, generation)
      raise Error, "worker generation must be positive" unless generation.positive?

      worker_id = nonempty_string(worker.fetch("worker_id"), "worker_id")
      unless worker_id.match?(/\A[A-Za-z0-9][A-Za-z0-9._-]{0,127}\z/)
        raise Error, "worker_id has invalid contract syntax"
      end
      expected_worker_id = build_worker_id(record.fetch("fleet_id"), index)
      raise Error, "worker_id does not match its durable fleet slot" unless worker_id == expected_worker_id

      validate_generation_identity!(worker, worker_id, generation)
    end

    def validate_historical_identity!(worker, prior, generation)
      worker_id = prior.fetch("worker_id")
      unless worker_id == worker.fetch("worker_id")
        raise Error, "worker history changes logical worker_id"
      end

      validate_generation_identity!(prior, worker_id, generation)
    end

    def validate_generation_identity!(worker, worker_id, generation)
      pod_id = nonempty_string(worker.fetch("pod_id"), "provider pod id")
      generation_id = nonempty_string(worker.fetch("generation_id"), "generation_id")
      raise Error, "generation_id exceeds 256 characters" if generation_id.length > 256
      expected = build_generation_id(worker_id, generation, pod_id)
      raise Error, "generation_id does not match durable generation evidence" unless generation_id == expected
    end

    def validate_worker_indices!(values)
      indices = values.map { |value| RunpodWorkers.validate_index(value) }
      raise Error, "fleet worker indices must be unique" unless indices.uniq.length == indices.length
    rescue RunpodWorkers::Error => e
      raise Error, e.message
    end
  end
end
