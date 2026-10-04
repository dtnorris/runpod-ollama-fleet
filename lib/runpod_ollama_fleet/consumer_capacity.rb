# frozen_string_literal: true

require "json"
require "fileutils"
require "tempfile"
require "time"
require_relative "ollama_capability_request"

module RunpodOllamaFleet
  # Provider-owned binding and retention. Only public demand JSON crosses the boundary.
  # Called inside CampaignLifecycle's shared capacity-control lock.
  class ConsumerCapacity
    CONTRACT = "rpof-consumer-binding/v0.1"
    class Error < StandardError; end

    attr_reader :path

    def initialize(binding:, wall_clock: -> { Time.now.utc }, source: nil)
      @binding = binding
      @clock = wall_clock
      @source = source || method(:command_document)
      @path = File.join(File.dirname(binding.state_path), "consumer-binding.json")
      @state_path = File.join(File.dirname(binding.state_path), "consumer-retention.json")
    end

    def bind!(document)
      validate_binding!(document)
      if File.exist?(path)
        raise Error, "consumer binding conflicts with retained identity" unless read(path) == document
      else
        write(path, document)
      end
      document
    end

    def reconcile(profiles:, runtime_factory:)
      return profiles unless File.file?(path)

      binding = validate_binding!(read(path))
      state = File.file?(@state_path) ? read(@state_path) : { "binding" => binding, "profiles" => {} }
      raise Error, "consumer retention identity changed" unless state["binding"] == binding
      profiles.map do |profile|
        row = binding.fetch("profiles").find { |item| item["profile_id"] == profile.fetch("profile_id") }
        raise Error, "consumer binding does not cover profile" unless row
        runtime = runtime_factory.call(profile)
        retained = state.fetch("profiles")[profile.fetch("profile_id")] ||= {}
        demand = observe(row)
        requested = demand && demand["fresh"] && demand["state"] == "active" ?
          demand.fetch("runnable_count") + demand.fetch("bound_count") : 0
        target = [profile.fetch("desired_workers"), requested].min
        current = runtime.current_worker_count
        if target < current
          retained["release_at"] ||= (@clock.call + binding.fetch("idle_grace_seconds")).utc.iso8601(6)
          write(@state_path, state)
          release(runtime, current - target, demand) if @clock.call >= Time.iso8601(retained.fetch("release_at"))
        else
          retained.delete("release_at")
        end
        retained["effective_target"] = target
        retained["consumer_state"] = demand ? demand.fetch("state") : "unavailable"
        write(@state_path, state)
        profile.merge("desired_workers" => target)
      end
    rescue JSON::ParserError, KeyError, ArgumentError, TypeError, SystemCallError => e
      raise Error, "invalid consumer retention: #{e.message}"
    end

    private

    def validate_binding!(document)
      expected = %w[contract_version campaign_identity_sha256 binding_sha256 idle_grace_seconds profiles]
      unless document.is_a?(Hash) && document.keys.sort == expected.sort && document["contract_version"] == CONTRACT &&
             document["campaign_identity_sha256"] == @binding.campaign.identity_sha256 &&
             document["binding_sha256"] == @binding.binding_sha256
        raise Error, "consumer binding identity/contract mismatch"
      end
      grace = document["idle_grace_seconds"]
      raise Error, "idle grace must be a nonnegative integer" unless grace.is_a?(Integer) && grace >= 0
      profiles = document.fetch("profiles")
      ids = @binding.campaign.profiles.map { |profile| profile.fetch("profile_id") }.sort
      unless profiles.is_a?(Array) && profiles.all?(Hash) && profiles.map { |row| row["profile_id"] }.sort == ids
        raise Error, "consumer binding must cover exact campaign profiles"
      end
      profiles.each { |row| validate_profile_binding!(row) }
      document
    end

    def validate_profile_binding!(row)
      keys = %w[profile_id consumer_id plan_sha256 pool_id capability_request source_argv]
      raise Error, "invalid consumer profile binding fields" unless row.keys.sort == keys.sort
      %w[consumer_id plan_sha256].each do |key|
        raise Error, "invalid consumer identity" unless row[key].is_a?(String) && row[key].match?(/\A[0-9a-f]{64}\z/)
      end
      raise Error, "consumer pool is required" unless row["pool_id"].is_a?(String) && !row["pool_id"].empty?
      argv = row["source_argv"]
      unless argv.is_a?(Array) && !argv.empty? && argv.all? { |arg| arg.is_a?(String) && !arg.empty? } && argv.first.start_with?("/")
        raise Error, "public demand command must be an absolute executable argv"
      end
      request = OllamaCapabilityRequest.new(JSON.generate(row.fetch("capability_request")))
      profile = @binding.campaign.profiles.find { |item| item["profile_id"] == row.fetch("profile_id") }
      hardware = @binding.campaign.hardware_bindings.find { |item| item["profile_id"] == row.fetch("profile_id") }
      request.validate_profile!(profile:, hardware:)
    rescue OllamaCapabilityRequest::Error => e
      raise Error, e.message
    end

    def observe(row)
      demand = @source.call(row.fetch("source_argv"))
      request = OllamaCapabilityRequest.new(JSON.generate(row.fetch("capability_request")))
      unless demand.is_a?(Hash) && demand["contract_version"] == "wlo-consumer-demand/v0.1" &&
             %w[consumer_id plan_sha256 pool_id].all? { |key| demand[key] == row[key] } &&
             demand["capability_fingerprint"] == request.fingerprint
        return nil
      end
      return nil unless %w[runnable_count bound_count uncertain_count].all? do |key|
        demand[key].is_a?(Integer) && demand[key] >= 0
      end
      return nil unless demand["uncertain_count"] <= demand["bound_count"]
      return nil unless [true, false].include?(demand["fresh"]) && [true, false].include?(demand["quiescent"])
      age = @clock.call - Time.iso8601(demand.fetch("observed_at"))
      return nil unless age >= 0 && age <= 30
      if demand["fresh"]
        heartbeat_age = @clock.call - Time.iso8601(demand.fetch("heartbeat_at"))
        return nil unless heartbeat_age >= 0 && heartbeat_age <= 30
      end
      demand
    rescue StandardError
      nil # Source failure is not evidence of quiescence, nor authority to add.
    end

    def release(runtime, excess, demand)
      status = runtime.status
      candidates = status.fetch("worker_lifecycle").reject { |row| row["phase"] == "retired" }
      candidates.sort_by { |row| [row["phase"] == "active" ? 1 : 0, row.fetch("worker_id")] }.first(excess).each do |worker|
        options = worker.slice("worker_id", "generation_id", "pod_id").transform_keys(&:to_sym).merge(
          fleet_id: status.fetch("fleet_id"), expected_revision: worker.fetch("revision"), reason: "consumer demand release"
        )
        if worker["phase"] == "active"
          runtime.select_worker!(operation: "drain", **options)
          next # A later observation must follow the drain/expiry barrier.
        end
        expiry = worker["ready_snapshots_expire_at_utc"]
        next unless worker["phase"] == "draining" && expiry && demand
        next unless demand["quiescent"] && demand["bound_count"].zero? && demand["uncertain_count"].zero?
        next unless Time.iso8601(demand.fetch("observed_at")) > Time.iso8601(expiry)

        runtime.select_worker!(operation: "remove", confirm: true, **options)
      end
    end

    def command_document(argv)
      Tempfile.create("rpof-consumer-") do |output|
        pid = Process.spawn(*argv, in: File::NULL, out: output, err: File::NULL, pgroup: true)
        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 5
        status = nil
        until (result = Process.waitpid2(pid, Process::WNOHANG))
          raise Error, "consumer source timeout" if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
          sleep 0.01
        end
        status = result.last
        pid = nil
        raise Error, "consumer source failed" unless status.success?
        raise Error, "consumer response too large" if output.size > 65_536
        output.rewind
        JSON.parse(output.read)
      ensure
        if pid
          Process.kill("KILL", -pid)
          Process.waitpid(pid)
        end
      end
    end

    def read(file)
      JSON.parse(File.binread(file))
    end

    def write(file, document)
      FileUtils.mkdir_p(File.dirname(file))
      temp = "#{file}.tmp.#{$$}.#{Thread.current.object_id}"
      File.open(temp, "w", 0o600) do |io|
        io.write(JSON.generate(document) + "\n")
        io.flush
        io.fsync
      end
      File.rename(temp, file)
    ensure
      File.delete(temp) if temp && File.exist?(temp)
    end
  end
end
