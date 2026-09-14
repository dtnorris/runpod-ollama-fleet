# frozen_string_literal: true

require "fileutils"
require "set"
require "time"
require_relative "runpod_fleet_state"
require_relative "runpod_workers"

module LocalModelEvaluation
  class RunpodFleet
    MIN_WORKERS = RunpodWorkers::MIN_WORKERS
    MAX_WORKERS = RunpodWorkers::MAX_WORKERS
    GPU_ID = ENV.fetch("RUNPOD_GPU_ID", "NVIDIA A40")
    GPU_MEMORY_GB = Integer(ENV.fetch("RUNPOD_GPU_MEMORY_GB", "48"))
    DEFAULT_CLOUD = "SECURE"
    SUPPORTED_CLOUDS = %w[COMMUNITY SECURE].freeze
    CLOUD = DEFAULT_CLOUD # Backward-compatible alias; new code should use preflight.cloud.
    IMAGE = "runpod/pytorch:1.0.2-cu1281-torch280-ubuntu2404"
    DEFAULT_CONTAINER_DISK_GB = 30
    DEFAULT_VOLUME_GB = 60
    CONTAINER_DISK_GB = DEFAULT_CONTAINER_DISK_GB # Backward-compatible alias.
    VOLUME_GB = DEFAULT_VOLUME_GB # Backward-compatible alias.
    VOLUME_MOUNT_PATH = "/workspace"
    DEFAULT_MAX_FLEET_HOURLY_USD = 3.0
    DEFAULT_WAIT_SECONDS = 300
    DEFAULT_POLL_SECONDS = 3.0

    class Error < StandardError; end

    Preflight = Struct.new(
      :worker_count,
      :gpu,
      :cloud,
      :availability,
      :hourly_rate,
      :fleet_hourly_rate,
      :max_fleet_hourly_rate,
      :container_disk_gb,
      :volume_gb,
      :max_runtime_seconds,
      :max_spend_usd,
      keyword_init: true
    )

    Worker = Struct.new(
      :index,
      :pod_id,
      :name,
      :host,
      :ssh_port,
      :hourly_rate,
      keyword_init: true
    )

    class EnvFile
      def initialize(path)
        @path = path
      end

      attr_reader :path

      def values
        return {} unless File.file?(@path)

        File.readlines(@path, chomp: true).each_with_object({}) do |line, out|
          next if line.lstrip.start_with?("#")
          next unless (match = line.match(/\A([A-Za-z_][A-Za-z0-9_]*)=(.*)\z/))

          out[match[1]] = match[2]
        end
      end

      def update(updates = {}, remove: [])
        updates = updates.transform_keys(&:to_s).transform_values(&:to_s)
        remove = remove.map(&:to_s).to_set
        lines = File.file?(@path) ? File.readlines(@path) : []
        seen = Set.new
        output = []

        lines.each do |line|
          match = line.match(/\A([A-Za-z_][A-Za-z0-9_]*)=/)
          unless match
            output << line
            next
          end

          key = match[1]
          next if remove.include?(key)

          if updates.key?(key)
            next if seen.include?(key)

            output << "#{key}=#{updates.fetch(key)}\n"
            seen << key
          else
            output << line
          end
        end

        missing = updates.keys.reject { |key| seen.include?(key) || remove.include?(key) }
        unless missing.empty?
          output << "\n" unless output.empty? || output.last.end_with?("\n\n")
          missing.each { |key| output << "#{key}=#{updates.fetch(key)}\n" }
        end

        FileUtils.mkdir_p(File.dirname(@path))
        tmp = "#{@path}.tmp.#{$$}.#{Thread.current.object_id}"
        mode = File.stat(@path).mode if File.file?(@path)
        File.write(tmp, output.join)
        File.chmod(mode & 0o777, tmp) if mode
        File.rename(tmp, @path)
      ensure
        File.delete(tmp) if defined?(tmp) && tmp && File.exist?(tmp)
      end
    end

    def initialize(client:, env_path:, out: $stdout, sleeper: nil, clock: nil, state_root: nil, wall_clock: nil,
                   fleet_key: "default", local_port_base: RunpodFleetState::DEFAULT_LOCAL_PORT_BASE)
      @client = client
      @fleet_key = fleet_key.to_s
      unless @fleet_key.match?(/\A[a-z0-9][a-z0-9_-]{0,31}\z/)
        raise Error, "invalid fleet key: #{@fleet_key.inspect}"
      end
      env_path = File.expand_path(env_path)
      @env_file = EnvFile.new(env_path)
      @wall_clock = wall_clock || -> { Time.now.utc }
      @fleet_state = RunpodFleetState.new(
        root: state_root || File.join(File.dirname(env_path), "output", "runpod-fleets"),
        clock: @wall_clock,
        local_port_base:
      )
      @out = out
      @sleeper = sleeper || ->(seconds) { sleep seconds }
      @clock = clock || -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) }
    end

    attr_reader :env_file, :fleet_state, :fleet_key

    def gpu_id
      @gpu_id || GPU_ID
    end

    def gpu_id=(value)
      selected = value.to_s.strip
      raise Error, "GPU id must not be empty" if selected.empty?

      @gpu_id = selected
    end

    def preflight(worker_count:, cloud: DEFAULT_CLOUD, max_fleet_hourly_usd: DEFAULT_MAX_FLEET_HOURLY_USD,
                  container_disk_gb: DEFAULT_CONTAINER_DISK_GB, volume_gb: DEFAULT_VOLUME_GB,
                  max_runtime_seconds: nil, max_spend_usd: nil)
      worker_count = validate_worker_count(worker_count)
      cloud = normalize_cloud(cloud)
      container_disk_gb = positive_integer(container_disk_gb, "container disk size")
      volume_gb = positive_integer(volume_gb, "workspace volume size")
      max_runtime_seconds = optional_positive_float(max_runtime_seconds, "max runtime")
      max_spend_usd = optional_positive_float(max_spend_usd, "max spend")
      with_fleet_state { @fleet_state.assert_no_active! }
      max_fleet_hourly_usd = positive_float(max_fleet_hourly_usd, "max fleet hourly cost")
      desired_names = (1..worker_count).map { |index| worker_name(index) }
      duplicates = @client.list_pods.select { |pod| desired_names.include?(pod["name"]) }
      unless duplicates.empty?
        names = duplicates.map { |pod| "#{pod['name']} (#{pod['id']})" }.join(", ")
        raise Error, "refusing to create duplicate managed pods: #{names}; destroy the existing fleet first"
      end

      gpu = @client.list_gpu_types(cloud:, count: worker_count).find { |candidate| candidate["id"] == gpu_id }
      raise Error, "RunPod catalog did not return #{gpu_id}" unless gpu
      raise Error, "#{gpu_id} reports only #{gpu['memory']} GB VRAM; #{GPU_MEMORY_GB} GB is required" if gpu["memory"].to_i < GPU_MEMORY_GB
      raise Error, "#{gpu_id} is not available on #{cloud} cloud" unless gpu[cloud.downcase] == true

      availability = gpu["availability"].to_s
      raise Error, "#{gpu_id} #{cloud} availability is #{availability.empty? ? 'unknown' : availability}" if availability.empty? || availability == "NONE"

      rate = positive_float(gpu.dig("price", cloud.downcase), "#{gpu_id} #{cloud} hourly rate")
      fleet_rate = rate * worker_count
      if fleet_rate > max_fleet_hourly_usd
        raise Error, format(
          "projected fleet cost $%.4f/hr exceeds safety cap $%.4f/hr; no pods were created",
          fleet_rate,
          max_fleet_hourly_usd
        )
      end

      Preflight.new(
        worker_count:,
        gpu:,
        cloud:,
        availability:,
        hourly_rate: rate,
        fleet_hourly_rate: fleet_rate,
        max_fleet_hourly_rate: max_fleet_hourly_usd,
        container_disk_gb:,
        volume_gb:,
        max_runtime_seconds:,
        max_spend_usd:
      )
    end

    def read_ssh_public_key(path)
      expanded = File.expand_path(path.to_s)
      raise Error, "SSH public key not found: #{expanded}" unless File.file?(expanded)

      lines = File.readlines(expanded, chomp: true).map(&:strip).reject(&:empty?)
      raise Error, "SSH public key file is empty: #{expanded}" if lines.empty?

      lines.each do |line|
        if line.include?("PRIVATE KEY") || !line.match?(/\A(?:ssh-(?:ed25519|rsa)|ecdsa-sha2-\S+|sk-ssh-ed25519@openssh\.com|sk-ecdsa-sha2-\S+)\s+[A-Za-z0-9+\/=]+(?:\s+.*)?\z/)
          raise Error, "#{expanded} does not contain a valid OpenSSH public key"
        end
      end

      lines.join("\n")
    end

    def create(worker_count:, ssh_public_key:, preflight: nil, cloud: DEFAULT_CLOUD,
               max_fleet_hourly_usd: DEFAULT_MAX_FLEET_HOURLY_USD,
               container_disk_gb: DEFAULT_CONTAINER_DISK_GB, volume_gb: DEFAULT_VOLUME_GB,
               max_runtime_seconds: nil, max_spend_usd: nil,
               wait_seconds: DEFAULT_WAIT_SECONDS, poll_seconds: DEFAULT_POLL_SECONDS)
      worker_count = validate_worker_count(worker_count)
      cloud = normalize_cloud(cloud)
      container_disk_gb = positive_integer(container_disk_gb, "container disk size")
      volume_gb = positive_integer(volume_gb, "workspace volume size")
      max_runtime_seconds = optional_positive_float(max_runtime_seconds, "max runtime")
      max_spend_usd = optional_positive_float(max_spend_usd, "max spend")
      preflight ||= self.preflight(
        worker_count:, cloud:, max_fleet_hourly_usd:, container_disk_gb:, volume_gb:,
        max_runtime_seconds:, max_spend_usd:
      )
      if preflight.worker_count != worker_count
        raise Error, "preflight worker count does not match requested worker count"
      end
      if preflight.cloud != cloud
        raise Error, "preflight cloud #{preflight.cloud} does not match requested cloud #{cloud}"
      end
      if preflight.gpu.fetch("id").to_s != gpu_id
        raise Error, "preflight GPU #{preflight.gpu.fetch('id').inspect} does not match selected GPU #{gpu_id.inspect}"
      end
      if preflight.container_disk_gb != container_disk_gb
        raise Error,
              "preflight container disk #{preflight.container_disk_gb} GB does not match requested #{container_disk_gb} GB"
      end
      if preflight.volume_gb != volume_gb
        raise Error,
              "preflight workspace volume #{preflight.volume_gb} GB does not match requested #{volume_gb} GB"
      end
      if preflight.max_runtime_seconds != max_runtime_seconds
        raise Error,
              "preflight max runtime #{preflight.max_runtime_seconds.inspect} does not match requested #{max_runtime_seconds.inspect}"
      end
      if preflight.max_spend_usd != max_spend_usd
        raise Error,
              "preflight max spend #{preflight.max_spend_usd.inspect} does not match requested #{max_spend_usd.inspect}"
      end

      max_fleet_hourly_usd = positive_float(max_fleet_hourly_usd, "max fleet hourly cost")
      wait_seconds = positive_float(wait_seconds, "wait seconds", allow_zero: true)
      poll_seconds = positive_float(poll_seconds, "poll seconds")
      validate_public_key_value!(ssh_public_key)

      created = []
      workers = []
      fleet_record = nil
      lease_started_at = lease_configured?(max_runtime_seconds, max_spend_usd) ? utc_now : nil
      lease = build_lease(
        started_at: lease_started_at,
        max_runtime_seconds:,
        max_spend_usd:
      )

      begin
        (1..worker_count).each do |index|
          pod = @client.create_pod(
            create_body(index, ssh_public_key, cloud, container_disk_gb:, volume_gb:)
          )
          pod_id = pod["id"].to_s
          raise Error, "RunPod create response for #{worker_name(index)} did not include a pod id" if pod_id.empty?

          created << [index, pod_id]
          @out.puts "Created #{worker_name(index)}: #{pod_id}"
          validate_initial_lease!(lease, preflight.fleet_hourly_rate) if lease
        end

        effective_wait_seconds = if lease
                                   [wait_seconds, lease_remaining_seconds(lease, preflight.fleet_hourly_rate)].min
                                 else
                                   wait_seconds
                                 end
        workers = wait_until_ready(created, cloud:, wait_seconds: effective_wait_seconds, poll_seconds:)
        actual_fleet_rate = workers.sum(&:hourly_rate)
        if actual_fleet_rate > max_fleet_hourly_usd
          raise Error, format(
            "actual fleet cost $%.4f/hr exceeds safety cap $%.4f/hr",
            actual_fleet_rate,
            max_fleet_hourly_usd
          )
        end
        validate_initial_lease!(lease, actual_fleet_rate) if lease

        fleet_record = with_fleet_state do
          @fleet_state.activate(
            workers:,
            cloud:,
            gpu_id: gpu_id,
            image: IMAGE,
            lease:,
            provisioning: {
              "container_disk_gb" => container_disk_gb,
              "volume_gb" => volume_gb
            }
          )
        end
        write_worker_env(workers, fleet_record:)
        @out.puts "Current fleet: #{fleet_record.fetch('fleet_id')}"
        @out.puts "Fleet-scoped artifacts: #{@fleet_state.fleet_dir(fleet_record.fetch('fleet_id'))}"
        workers
      rescue Interrupt, StandardError
        if fleet_record
          begin
            @fleet_state.discard(fleet_record["fleet_id"])
          rescue RunpodFleetState::Error => e
            @out.puts "WARNING: could not discard failed fleet state: #{e.message}"
          end
          remove_worker_env(workers.map(&:index), clear_fleet: true)
        end
        rollback(created)
        raise
      end
    end

    def destroy(worker_indices:)
      indices = Array(worker_indices).map { |value| Integer(value) }.uniq.sort
      raise Error, "no workers selected" if indices.empty?
      indices.each { |index| validate_worker_index(index) }

      state = @env_file.values
      live_pods = @client.list_pods
      cleared = []
      errors = []

      indices.each do |index|
        expected_name = worker_name(index)
        pod_id = state[env_key(index, "POD_ID")].to_s

        begin
          pod = resolve_pod_for_destroy(index, pod_id, live_pods)
          unless pod
            @out.puts "Already absent #{expected_name}"
            cleared << index
            next
          end

          actual_id = pod["id"].to_s
          raise Error, "#{expected_name} has no pod id" if actual_id.empty?
          if pod["name"] != expected_name
            raise Error, "refusing to delete #{actual_id}: expected name #{expected_name.inspect}, got #{pod['name'].inspect}"
          end

          @client.delete_pod(actual_id)
          @out.puts "Deleted #{expected_name}: #{actual_id}"
          cleared << index
        rescue RunpodClient::Error => e
          if e.status == 404
            @out.puts "Already absent #{expected_name}: #{pod_id}"
            cleared << index
          else
            errors << "burst_#{index}: #{e.message}"
          end
        rescue StandardError => e
          errors << "burst_#{index}: #{e.message}"
        end
      end

      unless cleared.empty?
        fleet_record = with_fleet_state { @fleet_state.mark_destroyed(cleared) }
        clear_fleet = fleet_record && fleet_record["status"] == "destroyed"
        remove_worker_env(cleared, clear_fleet:)
      end
      raise Error, "one or more pods were not deleted: #{errors.join('; ')}" unless errors.empty?

      cleared
    end

    private

    def create_body(index, ssh_public_key, cloud, container_disk_gb:, volume_gb:)
      {
        "name" => worker_name(index),
        "image" => IMAGE,
        "disk" => container_disk_gb,
        "ports" => ["22/tcp"],
        "env" => { "PUBLIC_KEY" => ssh_public_key },
        "mounts" => {
          "persistent" => {
            "size" => volume_gb,
            "path" => VOLUME_MOUNT_PATH
          }
        },
        "cloud" => cloud,
        "gpu" => {
          "id" => gpu_id,
          "count" => 1
        }
      }
    end

    def wait_until_ready(created, cloud:, wait_seconds:, poll_seconds:)
      pending = created.to_h
      ready = {}
      deadline = @clock.call + wait_seconds

      until pending.empty?
        pending.keys.each do |index|
          pod_id = pending.fetch(index)
          pod = @client.get_pod(pod_id)
          validate_pod!(pod, index, pod_id, cloud:)

          status = pod["status"].to_s
          raise Error, "#{worker_name(index)} entered terminal status #{status}" if %w[ERROR TERMINATED].include?(status)

          next unless status == "RUNNING"

          endpoint = ssh_endpoint(pod)
          next unless endpoint

          rate = positive_float(pod["cost"], "#{worker_name(index)} hourly cost")
          worker = Worker.new(
            index:,
            pod_id:,
            name: worker_name(index),
            host: endpoint.fetch(:host),
            ssh_port: endpoint.fetch(:port),
            hourly_rate: rate
          )
          ready[index] = worker
          pending.delete(index)
          @out.puts format(
            "Ready %s: %s:%d at $%.4f/hr",
            worker.name,
            worker.host,
            worker.ssh_port,
            worker.hourly_rate
          )
        end

        break if pending.empty?
        raise Error, "timed out waiting for RunPod SSH endpoints: #{pending.keys.map { |i| worker_name(i) }.join(', ')}" if @clock.call >= deadline

        @sleeper.call(poll_seconds)
      end

      ready.keys.sort.map { |index| ready.fetch(index) }
    end

    def validate_pod!(pod, index, pod_id, cloud:)
      expected_name = worker_name(index)
      raise Error, "pod #{pod_id} name mismatch: expected #{expected_name.inspect}, got #{pod['name'].inspect}" unless pod["name"] == expected_name
      raise Error, "#{expected_name} cloud mismatch: expected #{cloud}, got #{pod['cloud'].inspect}" unless pod["cloud"] == cloud

      gpu = pod["gpu"] || {}
      unless gpu["id"] == gpu_id && gpu["count"].to_i == 1
        raise Error, "#{expected_name} GPU mismatch: expected 1x #{gpu_id}, got #{gpu.inspect}"
      end
    end

    def ssh_endpoint(pod)
      ports = Array(pod.dig("runtime", "ports"))
      mapping = ports.find do |entry|
        entry["private"].to_i == 22 && entry["type"].to_s.downcase == "tcp"
      end
      return nil unless mapping

      host = mapping["ip"].to_s
      port = mapping["public"].to_i
      return nil if host.empty? || port <= 0

      { host:, port: }
    end

    def write_worker_env(workers, fleet_record:)
      fleet_id = fleet_record.fetch("fleet_id")
      state_workers = fleet_record.fetch("workers").to_h { |worker| [Integer(worker.fetch("index")), worker] }
      updates = {
        "LME_RUNPOD_FLEET_ID" => fleet_id,
        "LME_RUNPOD_FLEET_DIR" => @fleet_state.fleet_dir(fleet_id)
      }
      workers.each do |worker|
        index = worker.index
        updates["LME_BURST_#{index}_URL"] = state_workers.fetch(index).fetch("local_ollama_url")
        updates[env_key(index, "POD_ID")] = worker.pod_id
        updates[env_key(index, "HOST")] = worker.host
        updates[env_key(index, "SSH_PORT")] = worker.ssh_port
        updates[env_key(index, "HOURLY_RATE")] = format("%.6f", worker.hourly_rate)
      end
      @env_file.update(updates)
      @out.puts "Updated #{@env_file.path} with RunPod worker routing."
    end

    def remove_worker_env(indices, clear_fleet: false)
      keys = indices.flat_map do |index|
        %w[POD_ID HOST SSH_PORT HOURLY_RATE].map { |suffix| env_key(index, suffix) }
      end
      keys.concat(%w[LME_RUNPOD_FLEET_ID LME_RUNPOD_FLEET_DIR]) if clear_fleet
      @env_file.update({}, remove: keys)
    end

    def rollback(created)
      return if created.empty?

      @out.puts "Provisioning failed; deleting #{created.length} newly-created pod(s)."
      created.reverse_each do |index, pod_id|
        begin
          @client.delete_pod(pod_id)
          @out.puts "Rolled back #{worker_name(index)}: #{pod_id}"
        rescue StandardError => e
          @out.puts "WARNING: rollback failed for #{worker_name(index)} #{pod_id}: #{e.message}"
        end
      end
      @out.puts "Local .env was not updated."
    end

    def resolve_pod_for_destroy(index, pod_id, live_pods)
      expected_name = worker_name(index)

      unless pod_id.empty?
        begin
          return @client.get_pod(pod_id)
        rescue RunpodClient::Error => e
          raise unless e.status == 404
        end
      end

      matches = Array(live_pods).select { |pod| pod["name"] == expected_name }
      raise Error, "multiple live pods match #{expected_name}; refusing ambiguous delete" if matches.length > 1

      matches.first
    end

    def worker_name(index)
      return "af-lme-burst-#{index}" if @fleet_key == "default"

      "af-lme-#{@fleet_key}-burst-#{index}"
    end

    def env_key(index, suffix)
      "RUNPOD_BURST_#{index}_#{suffix}"
    end

    def validate_worker_count(value)
      RunpodWorkers.validate_count(value)
    rescue RunpodWorkers::Error => e
      raise Error, e.message
    end

    def validate_worker_index(index)
      RunpodWorkers.validate_index(index)
    rescue RunpodWorkers::Error => e
      raise Error, e.message
    end

    def normalize_cloud(value)
      cloud = value.to_s.upcase
      return cloud if SUPPORTED_CLOUDS.include?(cloud)

      raise Error, "cloud must be one of: #{SUPPORTED_CLOUDS.join(', ')}"
    end

    def positive_integer(value, label)
      number = Integer(value)
      raise Error, "#{label} must be a positive integer" unless number.positive?

      number
    rescue ArgumentError, TypeError
      raise Error, "#{label} must be a positive integer"
    end

    def positive_float(value, label, allow_zero: false)
      number = Float(value)
      valid = allow_zero ? number >= 0 : number.positive?
      raise Error, "#{label} must be #{allow_zero ? 'non-negative' : 'positive'}" unless valid

      number
    rescue ArgumentError, TypeError
      raise Error, "#{label} must be numeric"
    end

    def optional_positive_float(value, label)
      return nil if value.nil?

      positive_float(value, label)
    end

    def lease_configured?(max_runtime_seconds, max_spend_usd)
      !max_runtime_seconds.nil? || !max_spend_usd.nil?
    end

    def build_lease(started_at:, max_runtime_seconds:, max_spend_usd:)
      return nil unless started_at

      {
        "started_at_utc" => started_at.iso8601,
        "max_runtime_seconds" => max_runtime_seconds,
        "max_spend_usd" => max_spend_usd
      }
    end

    def validate_initial_lease!(lease, fleet_hourly_rate)
      started_at = Time.parse(lease.fetch("started_at_utc")).utc
      elapsed = [utc_now - started_at, 0.0].max
      max_runtime_seconds = lease["max_runtime_seconds"]
      if max_runtime_seconds && elapsed >= max_runtime_seconds
        raise Error, format(
          "runtime lease expired during provisioning after %.1f seconds; newly-created pods will be rolled back",
          elapsed
        )
      end

      max_spend_usd = lease["max_spend_usd"]
      conservative_spend = fleet_hourly_rate * elapsed / 3600.0
      if max_spend_usd && conservative_spend >= max_spend_usd
        raise Error, format(
          "spend lease exhausted during provisioning at estimated $%.4f; newly-created pods will be rolled back",
          conservative_spend
        )
      end
    end

    def lease_remaining_seconds(lease, fleet_hourly_rate)
      started_at = Time.parse(lease.fetch("started_at_utc")).utc
      elapsed = [utc_now - started_at, 0.0].max
      limits = []
      if lease["max_runtime_seconds"]
        limits << lease.fetch("max_runtime_seconds") - elapsed
      end
      if lease["max_spend_usd"]
        spent = fleet_hourly_rate * elapsed / 3600.0
        remaining_budget = lease.fetch("max_spend_usd") - spent
        limits << remaining_budget * 3600.0 / fleet_hourly_rate
      end
      [limits.min, 0.0].max
    end

    def utc_now
      value = @wall_clock.call
      value = Time.parse(value.to_s) unless value.is_a?(Time)
      value.utc
    rescue ArgumentError
      raise Error, "wall clock returned invalid time: #{value.inspect}"
    end

    def with_fleet_state
      yield
    rescue RunpodFleetState::Error => e
      raise Error, e.message
    end

    def validate_public_key_value!(value)
      key = value.to_s
      raise Error, "SSH public key is empty" if key.empty?
      raise Error, "refusing to send a private key to RunPod" if key.include?("PRIVATE KEY")
    end
  end
end
