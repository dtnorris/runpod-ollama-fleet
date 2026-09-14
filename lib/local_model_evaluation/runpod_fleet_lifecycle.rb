# frozen_string_literal: true

require "set"
require "time"
require_relative "runpod_client"
require_relative "runpod_fleet"
require_relative "runpod_fleet_state"
require_relative "runpod_lease"
require_relative "runpod_workers"

module LocalModelEvaluation
  class RunpodFleetLifecycle
    class Error < StandardError; end

    Preflight = Struct.new(
      :operation,
      :scale_direction,
      :fleet_id,
      :worker_indices,
      :target_worker_count,
      :current_worker_count,
      :gpu,
      :cloud,
      :availability,
      :hourly_rate,
      :current_fleet_hourly_rate,
      :projected_fleet_hourly_rate,
      :max_fleet_hourly_rate,
      :container_disk_gb,
      :volume_gb,
      :current_worker,
      keyword_init: true
    )

    def initialize(client:, fleet_state:, env_path:, fleet_key:, local_port_base:, out: $stdout,
                   sleeper: nil, monotonic_clock: nil, wall_clock: nil)
      @client = client
      @fleet_state = fleet_state
      @env_file = RunpodFleet::EnvFile.new(File.expand_path(env_path))
      @fleet_key = fleet_key.to_s
      @local_port_base = Integer(local_port_base)
      @out = out
      @sleeper = sleeper || ->(seconds) { sleep seconds }
      @monotonic_clock = monotonic_clock || -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) }
      @wall_clock = wall_clock || -> { Time.now.utc }
    rescue ArgumentError, TypeError
      raise Error, "local port base must be an integer"
    end

    def preflight_scale(target_worker_count:, max_fleet_hourly_usd: RunpodFleet::DEFAULT_MAX_FLEET_HOURLY_USD)
      target = validate_worker_count(target_worker_count)
      fleet = lifecycle_fleet!(enforce_lease: false)
      current_count = Integer(fleet.fetch("worker_count"))
      raise Error, "scale target already equals current worker count #{current_count}" if target == current_count

      assert_contiguous_slots!(fleet, current_count)
      current_rate = active_hourly_rate(fleet)
      cap = positive_float(max_fleet_hourly_usd, "max fleet hourly cost")

      if target > current_count
        ensure_lease_active!(fleet)
        inactive = Array(fleet.fetch("workers")).reject { |worker| worker["status"] == "active" }
        unless inactive.empty?
          slots = inactive.map { |worker| "burst_#{worker.fetch('index')}=#{worker.fetch('status')}" }.join(", ")
          raise Error, "replace inactive slot(s) before scaling up: #{slots}"
        end

        indices = ((current_count + 1)..target).to_a
        profile = provisioning_profile!(fleet)
        reject_duplicate_names!(indices)
        gpu, availability, rate = capacity!(fleet, count: indices.length)
        projected_rate = current_rate + (rate * indices.length)
        enforce_fleet_cap!(projected_rate, cap)

        return Preflight.new(
          operation: "scale",
          scale_direction: "up",
          fleet_id: fleet.fetch("fleet_id"),
          worker_indices: indices,
          target_worker_count: target,
          current_worker_count: current_count,
          gpu:,
          cloud: fleet.fetch("cloud"),
          availability:,
          hourly_rate: rate,
          current_fleet_hourly_rate: current_rate,
          projected_fleet_hourly_rate: projected_rate,
          max_fleet_hourly_rate: cap,
          container_disk_gb: profile.fetch("container_disk_gb"),
          volume_gb: profile.fetch("volume_gb")
        )
      end

      retained = Array(fleet.fetch("workers")).select { |worker| Integer(worker.fetch("index")) <= target }
      inactive_retained = retained.reject { |worker| worker["status"] == "active" }
      unless inactive_retained.empty?
        slots = inactive_retained.map { |worker| "burst_#{worker.fetch('index')}=#{worker.fetch('status')}" }.join(", ")
        raise Error, "cannot scale down while retained slot(s) are inactive: #{slots}"
      end

      indices = ((target + 1)..current_count).to_a.reverse
      removable = indices.map { |index| worker_by_index(fleet, index) }
      invalid = removable.reject { |worker| %w[active destroyed].include?(worker.fetch("status").to_s) }
      unless invalid.empty?
        slots = invalid.map { |worker| "burst_#{worker.fetch('index')}=#{worker.fetch('status')}" }.join(", ")
        raise Error, "cannot scale down slot(s) in transitional state: #{slots}"
      end
      removable.each { |worker| reject_unexpected_replacement_name!(worker) }

      removed_active_rate = removable.sum do |worker|
        worker["status"] == "active" ? Float(worker.fetch("hourly_rate_usd")) : 0.0
      end
      projected_rate = [current_rate - removed_active_rate, 0.0].max

      Preflight.new(
        operation: "scale",
        scale_direction: "down",
        fleet_id: fleet.fetch("fleet_id"),
        worker_indices: indices,
        target_worker_count: target,
        current_worker_count: current_count,
        gpu: fleet.fetch("gpu"),
        cloud: fleet.fetch("cloud"),
        availability: nil,
        hourly_rate: nil,
        current_fleet_hourly_rate: current_rate,
        projected_fleet_hourly_rate: projected_rate,
        max_fleet_hourly_rate: cap,
        container_disk_gb: nil,
        volume_gb: nil
      )
    end

    def preflight_replace(worker_index:, max_fleet_hourly_usd: RunpodFleet::DEFAULT_MAX_FLEET_HOURLY_USD)
      fleet = lifecycle_fleet!
      index = validate_worker_index(worker_index)
      worker = worker_by_index(fleet, index)
      raise Error, "current fleet does not contain burst_#{index}" unless worker
      unless %w[active destroyed replacing].include?(worker.fetch("status").to_s)
        raise Error, "burst_#{index} cannot be replaced from state #{worker.fetch('status').inspect}"
      end

      profile = provisioning_profile!(fleet)
      reject_unexpected_replacement_name!(worker)
      gpu, availability, rate = capacity!(fleet, count: 1)
      current_rate = active_hourly_rate(fleet)
      existing_rate = worker.fetch("status") == "active" ? Float(worker.fetch("hourly_rate_usd")) : 0.0
      cap = positive_float(max_fleet_hourly_usd, "max fleet hourly cost")
      projected_rate = current_rate - existing_rate + rate
      enforce_fleet_cap!(projected_rate, cap)

      Preflight.new(
        operation: "replace",
        fleet_id: fleet.fetch("fleet_id"),
        worker_indices: [index],
        target_worker_count: Integer(fleet.fetch("worker_count")),
        current_worker_count: Integer(fleet.fetch("worker_count")),
        gpu:,
        cloud: fleet.fetch("cloud"),
        availability:,
        hourly_rate: rate,
        current_fleet_hourly_rate: current_rate,
        projected_fleet_hourly_rate: projected_rate,
        max_fleet_hourly_rate: cap,
        container_disk_gb: profile.fetch("container_disk_gb"),
        volume_gb: profile.fetch("volume_gb"),
        current_worker: Marshal.load(Marshal.dump(worker))
      )
    end

    def scale(target_worker_count:, ssh_public_key:, preflight:, max_fleet_hourly_usd: RunpodFleet::DEFAULT_MAX_FLEET_HOURLY_USD,
              wait_seconds: RunpodFleet::DEFAULT_WAIT_SECONDS, poll_seconds: RunpodFleet::DEFAULT_POLL_SECONDS)
      verify_preflight!(preflight, operation: "scale")
      raise Error, "scale-up requires an up preflight" unless preflight.scale_direction == "up"

      with_lifecycle_lock(preflight.fleet_id) do
        fleet = lifecycle_fleet!(expected_fleet_id: preflight.fleet_id)
        current_count = Integer(fleet.fetch("worker_count"))
        target = validate_worker_count(target_worker_count)
        unless current_count == preflight.current_worker_count && target == preflight.target_worker_count
          raise Error, "fleet changed since scale preflight; run preflight again"
        end
        reject_duplicate_names!(preflight.worker_indices)

        profile = provisioning_profile!(fleet)
        validate_public_key_value!(ssh_public_key)
        cap = positive_float(max_fleet_hourly_usd, "max fleet hourly cost")
        wait_seconds = nonnegative_float(wait_seconds, "wait seconds")
        poll_seconds = positive_float(poll_seconds, "poll seconds")
        created = []
        created_at = {}
        pending_rates = {}
        env_written = false

        begin
          preflight.worker_indices.each do |index|
            current = lifecycle_fleet!(expected_fleet_id: preflight.fleet_id)
            ensure_lease_capacity!(current, pending_started_at: created_at, pending_rates:)
            created_at[index] = utc_now
            pod = @client.create_pod(
              create_body(index, ssh_public_key, fleet.fetch("cloud"), profile:)
            )
            pod_id = pod["id"].to_s
            raise Error, "RunPod create response for #{worker_name(index)} did not include a pod id" if pod_id.empty?

            created << [index, pod_id]
            pending_rates[index] = preflight.hourly_rate
            @out.puts "Created #{worker_name(index)}: #{pod_id}"
            ensure_lease_capacity!(current, pending_started_at: created_at, pending_rates:)
          end

          current = lifecycle_fleet!(expected_fleet_id: preflight.fleet_id)
          effective_wait = lease_limited_wait_seconds(
            current,
            wait_seconds,
            pending_started_at: created_at,
            pending_rates:
          )
          workers = wait_until_ready(created, cloud: fleet.fetch("cloud"), wait_seconds: effective_wait, poll_seconds:)
          current = lifecycle_fleet!(expected_fleet_id: preflight.fleet_id)
          actual_pending_rates = workers.to_h { |worker| [worker.index, worker.hourly_rate] }
          ensure_lease_capacity!(current, pending_started_at: created_at, pending_rates: actual_pending_rates)
          projected_rate = active_hourly_rate(current) + workers.sum(&:hourly_rate)
          enforce_fleet_cap!(projected_rate, cap)

          write_worker_env(workers, fleet_id: preflight.fleet_id)
          env_written = true
          @fleet_state.add_workers(workers:, created_at_utc_by_index: created_at)
          workers
        rescue Interrupt, StandardError => e
          remove_worker_env(preflight.worker_indices) if env_written
          rollback(created)
          raise e if e.is_a?(Interrupt) || e.is_a?(Error)
          raise Error, e.message
        end
      end
    end

    def shrink(target_worker_count:, preflight:)
      verify_preflight!(preflight, operation: "scale")
      raise Error, "scale-down requires a down preflight" unless preflight.scale_direction == "down"

      with_lifecycle_lock(preflight.fleet_id) do
        fleet = lifecycle_fleet!(expected_fleet_id: preflight.fleet_id, enforce_lease: false)
        current_count = Integer(fleet.fetch("worker_count"))
        target = validate_worker_count(target_worker_count)
        unless current_count == preflight.current_worker_count && target == preflight.target_worker_count
          raise Error, "fleet changed since scale preflight; run preflight again"
        end

        retired = []
        preflight.worker_indices.each do |index|
          current = lifecycle_fleet!(expected_fleet_id: preflight.fleet_id, enforce_lease: false)
          highest = Array(current.fetch("workers")).map { |worker| Integer(worker.fetch("index")) }.max
          unless highest == index
            raise Error, "scale-down must retire contiguous tail slots; expected burst_#{highest}, got burst_#{index}"
          end

          worker = worker_by_index(current, index)
          raise Error, "current fleet no longer contains burst_#{index}" unless worker
          unless %w[active destroyed].include?(worker.fetch("status").to_s)
            raise Error, "burst_#{index} cannot be retired from state #{worker.fetch('status').inspect}"
          end

          reject_unexpected_replacement_name!(worker)
          delete_scaled_worker_pod(worker)
          @fleet_state.retire_tail_worker(index, destroyed_at_utc: utc_now)
          remove_worker_env([index])
          retired << index
        end
        retired
      end
    end

    def replace(worker_index:, ssh_public_key:, preflight:, max_fleet_hourly_usd: RunpodFleet::DEFAULT_MAX_FLEET_HOURLY_USD,
                wait_seconds: RunpodFleet::DEFAULT_WAIT_SECONDS, poll_seconds: RunpodFleet::DEFAULT_POLL_SECONDS)
      verify_preflight!(preflight, operation: "replace")
      index = validate_worker_index(worker_index)
      raise Error, "replace worker does not match preflight" unless preflight.worker_indices == [index]

      with_lifecycle_lock(preflight.fleet_id) do
        fleet = lifecycle_fleet!(expected_fleet_id: preflight.fleet_id)
        provisioning_profile!(fleet)
        validate_public_key_value!(ssh_public_key)
        cap = positive_float(max_fleet_hourly_usd, "max fleet hourly cost")
        wait_seconds = nonnegative_float(wait_seconds, "wait seconds")
        poll_seconds = positive_float(poll_seconds, "poll seconds")

        old_worker = worker_by_index(fleet, index)
        raise Error, "current fleet no longer contains burst_#{index}" unless old_worker
        unless old_worker.fetch("pod_id").to_s == preflight.current_worker.fetch("pod_id").to_s
          raise Error, "burst_#{index} changed since replacement preflight; run preflight again"
        end
        reject_unexpected_replacement_name!(old_worker)

        @fleet_state.begin_replacement(index)
        begin
          delete_replaced_pod(old_worker)
        rescue Interrupt, StandardError => e
          begin
            @fleet_state.cancel_replacement(index)
          rescue RunpodFleetState::Error
            nil
          end
          raise e if e.is_a?(Interrupt) || e.is_a?(Error)
          raise Error, e.message
        end
        @fleet_state.mark_replacement_destroyed(index)
        remove_worker_env([index])

        created = []
        env_written = false
        begin
          current = lifecycle_fleet!(expected_fleet_id: preflight.fleet_id)
          ensure_lease_capacity!(current)
          started_at = utc_now
          profile = provisioning_profile!(current)
          pod = @client.create_pod(
            create_body(index, ssh_public_key, fleet.fetch("cloud"), profile:)
          )
          pod_id = pod["id"].to_s
          raise Error, "RunPod create response for #{worker_name(index)} did not include a pod id" if pod_id.empty?
          created << [index, pod_id]
          pending_rates = { index => preflight.hourly_rate }
          pending_started_at = { index => started_at }
          @out.puts "Created replacement #{worker_name(index)}: #{pod_id}"
          ensure_lease_capacity!(current, pending_started_at:, pending_rates:)

          effective_wait = lease_limited_wait_seconds(
            current,
            wait_seconds,
            pending_started_at:,
            pending_rates:
          )
          worker = wait_until_ready(created, cloud: fleet.fetch("cloud"), wait_seconds: effective_wait, poll_seconds:).fetch(0)
          current = lifecycle_fleet!(expected_fleet_id: preflight.fleet_id)
          ensure_lease_capacity!(
            current,
            pending_started_at:,
            pending_rates: { index => worker.hourly_rate }
          )
          projected_rate = active_hourly_rate(current) + worker.hourly_rate
          enforce_fleet_cap!(projected_rate, cap)

          write_worker_env([worker], fleet_id: preflight.fleet_id)
          env_written = true
          @fleet_state.complete_replacement(worker:, created_at_utc: started_at)
          worker
        rescue Interrupt, StandardError => e
          remove_worker_env([index]) if env_written
          rollback(created)
          raise e if e.is_a?(Interrupt) || e.is_a?(Error)
          raise Error, e.message
        end
      end
    end

    private

    def with_lifecycle_lock(fleet_id)
      path = File.join(@fleet_state.fleet_dir(fleet_id), ".lifecycle.lock")
      File.open(path, File::RDWR | File::CREAT, 0o600) do |lock|
        unless lock.flock(File::LOCK_EX | File::LOCK_NB)
          raise Error, "another RunPod lifecycle mutation is already running for fleet #{fleet_id}"
        end
        yield
      ensure
        lock.flock(File::LOCK_UN) rescue nil
      end
    rescue RunpodFleetState::Error => e
      raise Error, e.message
    end

    def lifecycle_fleet!(expected_fleet_id: nil, enforce_lease: true)
      fleet = @fleet_state.current
      raise Error, "no current RunPod fleet state exists; provision a fleet first" unless fleet
      raise Error, "current RunPod fleet #{fleet.fetch('fleet_id')} is not active" unless fleet["status"] == "active"
      if expected_fleet_id && fleet.fetch("fleet_id") != expected_fleet_id
        raise Error, "current fleet changed from #{expected_fleet_id} to #{fleet.fetch('fleet_id')}; run preflight again"
      end
      @fleet_gpu_id = fleet.dig("gpu", "id").to_s.strip
      raise Error, "current fleet does not record an exact GPU id" if @fleet_gpu_id.empty?
      unless fleet.fetch("image").to_s == RunpodFleet::IMAGE
        raise Error, "current fleet image does not match configured RunPod image"
      end
      ensure_lease_active!(fleet) if enforce_lease
      fleet
    rescue RunpodFleetState::Error, KeyError, ArgumentError, TypeError => e
      raise Error, e.message
    end

    def fleet_gpu_id!(fleet)
      gpu_id = fleet.dig("gpu", "id").to_s.strip
      raise Error, "current fleet does not record an exact GPU id" if gpu_id.empty?

      gpu_id
    end

    def current_gpu_id!
      gpu_id = @fleet_gpu_id.to_s.strip
      raise Error, "current fleet does not record an exact GPU id" if gpu_id.empty?

      gpu_id
    end

    def provisioning_profile!(fleet)
      profile = fleet["provisioning"]
      unless profile.is_a?(Hash)
        raise Error,
              "current fleet predates recorded provisioning metadata; destroy/recreate it before scale/replace rather than guessing storage sizes"
      end
      {
        "container_disk_gb" => positive_integer(profile["container_disk_gb"], "recorded container disk size"),
        "volume_gb" => positive_integer(profile["volume_gb"], "recorded workspace volume size")
      }
    end

    def capacity!(fleet, count:)
      cloud = normalize_cloud(fleet.fetch("cloud"))
      gpu = @client.list_gpu_types(cloud:, count:).find { |candidate| candidate["id"] == fleet_gpu_id!(fleet) }
      raise Error, "RunPod catalog did not return #{fleet_gpu_id!(fleet)}" unless gpu
      if gpu["memory"].to_i < RunpodFleet::GPU_MEMORY_GB
        raise Error, "#{fleet_gpu_id!(fleet)} reports only #{gpu['memory']} GB VRAM; #{RunpodFleet::GPU_MEMORY_GB} GB is required"
      end
      raise Error, "#{fleet_gpu_id!(fleet)} is not available on #{cloud} cloud" unless gpu[cloud.downcase] == true

      availability = gpu["availability"].to_s
      if availability.empty? || availability == "NONE"
        raise Error, "#{fleet_gpu_id!(fleet)} #{cloud} availability is #{availability.empty? ? 'unknown' : availability}"
      end
      rate = positive_float(gpu.dig("price", cloud.downcase), "#{fleet_gpu_id!(fleet)} #{cloud} hourly rate")
      [gpu, availability, rate]
    end

    def reject_duplicate_names!(indices)
      desired = indices.map { |index| worker_name(index) }.to_set
      duplicates = @client.list_pods.select { |pod| desired.include?(pod["name"].to_s) }
      return if duplicates.empty?

      names = duplicates.map { |pod| "#{pod['name']} (#{pod['id']})" }.join(", ")
      raise Error, "refusing to scale over existing managed pod name(s): #{names}"
    end

    def reject_unexpected_replacement_name!(worker)
      expected_name = worker_name(Integer(worker.fetch("index")))
      matches = @client.list_pods.select { |pod| pod["name"].to_s == expected_name }
      raise Error, "multiple live pods match #{expected_name}; refusing ambiguous replacement" if matches.length > 1
      return if matches.empty?
      return if matches.first["id"].to_s == worker.fetch("pod_id").to_s

      raise Error,
            "#{expected_name} resolves to unexpected pod #{matches.first['id']}; recorded pod is #{worker.fetch('pod_id')}"
    end

    def delete_scaled_worker_pod(worker)
      pod_id = worker.fetch("pod_id").to_s
      expected_name = worker_name(Integer(worker.fetch("index")))
      begin
        pod = @client.get_pod(pod_id)
      rescue RunpodClient::Error => e
        return if e.status == 404
        raise
      end
      unless pod["name"].to_s == expected_name
        raise Error, "refusing to delete #{pod_id}: expected name #{expected_name.inspect}, got #{pod['name'].inspect}"
      end

      @client.delete_pod(pod_id)
      @out.puts "Deleted scaled-down #{expected_name}: #{pod_id}"
    rescue RunpodClient::Error => e
      raise Error, e.message
    end

    def delete_replaced_pod(worker)
      pod_id = worker.fetch("pod_id").to_s
      expected_name = worker_name(Integer(worker.fetch("index")))
      begin
        pod = @client.get_pod(pod_id)
      rescue RunpodClient::Error => e
        return if e.status == 404
        raise
      end
      unless pod["name"].to_s == expected_name
        raise Error, "refusing to delete #{pod_id}: expected name #{expected_name.inspect}, got #{pod['name'].inspect}"
      end

      @client.delete_pod(pod_id)
      @out.puts "Deleted replaced #{expected_name}: #{pod_id}"
    rescue RunpodClient::Error => e
      raise Error, e.message
    end

    def create_body(index, ssh_public_key, cloud, profile:)
      {
        "name" => worker_name(index),
        "image" => RunpodFleet::IMAGE,
        "disk" => profile.fetch("container_disk_gb"),
        "ports" => ["22/tcp"],
        "env" => { "PUBLIC_KEY" => ssh_public_key },
        "mounts" => {
          "persistent" => {
            "size" => profile.fetch("volume_gb"),
            "path" => RunpodFleet::VOLUME_MOUNT_PATH
          }
        },
        "cloud" => cloud,
        "gpu" => { "id" => current_gpu_id!, "count" => 1 }
      }
    end

    def wait_until_ready(created, cloud:, wait_seconds:, poll_seconds:)
      pending = created.to_h
      ready = {}
      deadline = @monotonic_clock.call + wait_seconds

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
          ready[index] = RunpodFleet::Worker.new(
            index:,
            pod_id:,
            name: worker_name(index),
            host: endpoint.fetch(:host),
            ssh_port: endpoint.fetch(:port),
            hourly_rate: rate
          )
          pending.delete(index)
          @out.puts format(
            "Ready %s: %s:%d at $%.4f/hr",
            worker_name(index),
            endpoint.fetch(:host),
            endpoint.fetch(:port),
            rate
          )
        end

        break if pending.empty?
        raise Error, "timed out waiting for RunPod SSH endpoints: #{pending.keys.map { |i| worker_name(i) }.join(', ')}" if @monotonic_clock.call >= deadline
        @sleeper.call(poll_seconds)
      end

      ready.keys.sort.map { |index| ready.fetch(index) }
    rescue RunpodClient::Error => e
      raise Error, e.message
    end

    def validate_pod!(pod, index, pod_id, cloud:)
      expected_name = worker_name(index)
      raise Error, "pod #{pod_id} name mismatch: expected #{expected_name.inspect}, got #{pod['name'].inspect}" unless pod["name"] == expected_name
      raise Error, "#{expected_name} cloud mismatch: expected #{cloud}, got #{pod['cloud'].inspect}" unless pod["cloud"] == cloud
      gpu = pod["gpu"] || {}
      unless gpu["id"] == current_gpu_id! && gpu["count"].to_i == 1
        raise Error, "#{expected_name} GPU mismatch: expected 1x #{current_gpu_id!}, got #{gpu.inspect}"
      end
    end

    def ssh_endpoint(pod)
      mapping = Array(pod.dig("runtime", "ports")).find do |entry|
        entry["private"].to_i == 22 && entry["type"].to_s.downcase == "tcp"
      end
      return nil unless mapping
      host = mapping["ip"].to_s
      port = mapping["public"].to_i
      return nil if host.empty? || port <= 0
      { host:, port: }
    end

    def write_worker_env(workers, fleet_id:)
      updates = {
        "LME_RUNPOD_FLEET_ID" => fleet_id,
        "LME_RUNPOD_FLEET_DIR" => @fleet_state.fleet_dir(fleet_id)
      }
      workers.each do |worker|
        index = worker.index
        updates["LME_BURST_#{index}_URL"] = "http://127.0.0.1:#{@local_port_base + index - 1}"
        updates[env_key(index, "POD_ID")] = worker.pod_id
        updates[env_key(index, "HOST")] = worker.host
        updates[env_key(index, "SSH_PORT")] = worker.ssh_port
        updates[env_key(index, "HOURLY_RATE")] = format("%.6f", worker.hourly_rate)
      end
      @env_file.update(updates)
      @out.puts "Updated #{@env_file.path} with RunPod worker routing."
    end

    def remove_worker_env(indices)
      keys = Array(indices).flat_map do |index|
        %w[POD_ID HOST SSH_PORT HOURLY_RATE].map { |suffix| env_key(index, suffix) }
      end
      @env_file.update({}, remove: keys)
    end

    def rollback(created)
      return if created.empty?
      @out.puts "Lifecycle operation failed; deleting #{created.length} newly-created pod(s)."
      created.reverse_each do |index, pod_id|
        begin
          @client.delete_pod(pod_id)
          @out.puts "Rolled back #{worker_name(index)}: #{pod_id}"
        rescue StandardError => e
          @out.puts "WARNING: rollback failed for #{worker_name(index)} #{pod_id}: #{e.message}"
        end
      end
    end

    def ensure_lease_active!(fleet)
      ensure_lease_capacity!(fleet)
    end

    def ensure_lease_capacity!(fleet, pending_started_at: {}, pending_rates: {})
      return unless fleet["lease"]
      lease = RunpodLease.snapshot_for(fleet:, now: utc_now)
      if lease["status"] == "expired"
        raise Error, "current fleet lease is expired (#{lease.fetch('expiration_reasons').join('+')}); refusing paid lifecycle mutation"
      end

      max_spend = lease["max_spend_usd"]
      return lease unless max_spend
      pending_spend = pending_lease_spend(pending_started_at:, pending_rates:)
      total = lease.fetch("estimated_spend_usd") + pending_spend
      return lease if total < max_spend

      raise Error, format(
        "current fleet spend lease would be exhausted at conservative $%.4f including pending lifecycle pods; newly-created pods will be rolled back",
        total
      )
    rescue RunpodLease::Error => e
      raise Error, e.message
    end

    def lease_limited_wait_seconds(fleet, requested_wait_seconds, pending_started_at:, pending_rates:)
      requested = nonnegative_float(requested_wait_seconds, "wait seconds")
      return requested unless fleet["lease"]
      lease = ensure_lease_capacity!(fleet, pending_started_at:, pending_rates:)
      limits = [requested]
      limits << lease.fetch("runtime_remaining_seconds") if lease["runtime_remaining_seconds"]
      if lease["budget_remaining_usd"]
        remaining_budget = lease.fetch("budget_remaining_usd") - pending_lease_spend(
          pending_started_at:,
          pending_rates:
        )
        burn_rate = active_hourly_rate(fleet) + pending_rates.values.sum { |rate| Float(rate) }
        limits << (remaining_budget * 3600.0 / burn_rate) if burn_rate.positive?
      end
      [limits.min, 0.0].max
    end

    def pending_lease_spend(pending_started_at:, pending_rates:)
      now = utc_now
      pending_rates.sum do |index, rate|
        started_at = pending_started_at[index]
        next 0.0 unless started_at
        started_at = Time.parse(started_at.to_s) unless started_at.is_a?(Time)
        Float(rate) * [now - started_at.utc, 0.0].max / 3600.0
      end
    rescue ArgumentError, TypeError => e
      raise Error, "invalid pending lifecycle lease accounting: #{e.message}"
    end

    def verify_preflight!(preflight, operation:)
      unless preflight.is_a?(Preflight) && preflight.operation == operation
        raise Error, "#{operation} requires a matching lifecycle preflight"
      end
    end

    def active_hourly_rate(fleet)
      Array(fleet.fetch("workers")).sum do |worker|
        worker["status"] == "active" ? Float(worker.fetch("hourly_rate_usd")) : 0.0
      end
    end

    def enforce_fleet_cap!(rate, cap)
      return if rate <= cap
      raise Error, format(
        "projected fleet cost $%.4f/hr exceeds safety cap $%.4f/hr; no new pod was retained",
        rate,
        cap
      )
    end

    def assert_contiguous_slots!(fleet, worker_count)
      indices = Array(fleet.fetch("workers")).map { |worker| Integer(worker.fetch("index")) }.sort
      expected = (1..worker_count).to_a
      return if indices == expected
      raise Error, "current fleet slots are not contiguous 1-#{worker_count}; reconcile state before scaling"
    end

    def worker_by_index(fleet, index)
      Array(fleet.fetch("workers")).find { |worker| Integer(worker.fetch("index")) == index }
    end

    def worker_name(index)
      return "af-lme-burst-#{index}" if @fleet_key == "default"
      "af-lme-#{@fleet_key}-burst-#{index}"
    end

    def env_key(index, suffix)
      "RUNPOD_BURST_#{index}_#{suffix}"
    end

    def normalize_cloud(value)
      cloud = value.to_s.upcase
      return cloud if RunpodFleet::SUPPORTED_CLOUDS.include?(cloud)
      raise Error, "cloud must be one of: #{RunpodFleet::SUPPORTED_CLOUDS.join(', ')}"
    end

    def validate_worker_count(value)
      RunpodWorkers.validate_count(value)
    rescue RunpodWorkers::Error => e
      raise Error, e.message
    end

    def validate_worker_index(value)
      RunpodWorkers.validate_index(value)
    rescue RunpodWorkers::Error => e
      raise Error, e.message
    end

    def validate_public_key_value!(value)
      key = value.to_s
      raise Error, "SSH public key is empty" if key.empty?
      raise Error, "refusing to send a private key to RunPod" if key.include?("PRIVATE KEY")
    end

    def positive_integer(value, label)
      number = Integer(value)
      raise Error, "#{label} must be a positive integer" unless number.positive?
      number
    rescue ArgumentError, TypeError
      raise Error, "#{label} must be a positive integer"
    end

    def positive_float(value, label)
      number = Float(value)
      raise Error, "#{label} must be positive" unless number.positive?
      number
    rescue ArgumentError, TypeError
      raise Error, "#{label} must be numeric"
    end

    def nonnegative_float(value, label)
      number = Float(value)
      raise Error, "#{label} must be non-negative" if number.negative?
      number
    rescue ArgumentError, TypeError
      raise Error, "#{label} must be numeric"
    end

    def utc_now
      value = @wall_clock.call
      value = Time.parse(value.to_s) unless value.is_a?(Time)
      value.utc
    rescue ArgumentError
      raise Error, "wall clock returned invalid time: #{value.inspect}"
    end
  end
end
