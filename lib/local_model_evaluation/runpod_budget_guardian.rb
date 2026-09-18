# frozen_string_literal: true

require "fileutils"
require "json"
require "time"
require_relative "runpod_budget"
require_relative "runpod_client"
require_relative "runpod_fleet"
require_relative "runpod_fleet_namespace"

module LocalModelEvaluation
  class RunpodBudgetGuardian
    class Error < StandardError; end

    def initialize(root:, repo_root:, budget_id:, plan_sha256:, budget: nil, provider_client: nil,
                   fleet_state_root: nil, fleet_state_repo_root: nil,
                   namespace_factory: nil, fleet_factory: nil, sleeper: nil, wall_clock: nil,
                   monotonic_clock: nil, out: $stdout, err: $stderr)
      @root = File.expand_path(root)
      @repo_root = File.expand_path(repo_root)
      @budget = budget || RunpodBudget.new(root: @root, budget_id:, plan_sha256:)
      @client = provider_client || build_client
      @fleet_state_root = File.expand_path(fleet_state_root || @root)
      @fleet_state_repo_root = File.expand_path(fleet_state_repo_root || @repo_root)
      @namespace_factory = namespace_factory || lambda do |fleet_key|
        RunpodFleetNamespace.new(
          root: @fleet_state_root,
          repo_root: @fleet_state_repo_root,
          fleet_key:
        )
      end
      @fleet_factory = fleet_factory || lambda do |namespace|
        RunpodFleet.new(
          client: @client,
          env_path: namespace.env_path,
          state_root: namespace.state_root,
          fleet_key: namespace.fleet_key,
          local_port_base: namespace.local_port_base
        )
      end
      @sleeper = sleeper || ->(seconds) { sleep seconds }
      @wall_clock = wall_clock || -> { Time.now.utc }
      @monotonic_clock = monotonic_clock || -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) }
      @out = out
      @err = err
    end

    attr_reader :budget

    def provider_probe!
      @client.list_pods
      true
    rescue RunpodClient::Error, ArgumentError => e
      raise Error, "RunPod provider probe failed: #{e.message}"
    end

    def tick
      @budget.heartbeat!(source: "guardian")
      status = @budget.evaluate!
      case status.fetch("state")
      when "ARMED"
        reconcile_absent_committed!(status)
        @budget.status
      when "TEARDOWN_REQUIRED"
        teardown!(status)
      when "CLOSED"
        status
      else
        raise Error, "unsupported budget state #{status.fetch('state').inspect}"
      end
    rescue RunpodBudget::Error, RunpodClient::Error, RunpodFleet::Error,
           RunpodFleetNamespace::Error, KeyError, ArgumentError, TypeError => e
      raise Error, e.message
    end

    def run(enabled_path:, runtime_path:)
      enabled = File.expand_path(enabled_path)
      runtime = File.expand_path(runtime_path)
      probe_at = utc_now
      provider_probe!
      write_runtime(
        runtime,
        "ready" => true,
        "pid" => Process.pid,
        "provider_probe_at_utc" => probe_at.iso8601,
        "ledger_heartbeat_at_utc" => nil,
        "state" => "WAITING_FOR_ARM",
        "last_error" => nil
      )

      while File.file?(enabled)
        begin
          status = tick
          now = utc_now
          write_runtime(
            runtime,
            "ready" => true,
            "pid" => Process.pid,
            "provider_probe_at_utc" => probe_at.iso8601,
            "ledger_heartbeat_at_utc" => now.iso8601,
            "state" => status.fetch("state"),
            "last_error" => nil
          )
          if status.fetch("state") == "CLOSED"
            File.delete(enabled) if File.file?(enabled)
            return status
          end
          @sleeper.call(Float(status.dig("limits", "guardian_poll_seconds")))
        rescue RunpodBudget::Error => e
          if e.message.start_with?("budget is not armed:")
            write_runtime(
              runtime,
              "ready" => true,
              "pid" => Process.pid,
              "provider_probe_at_utc" => probe_at.iso8601,
              "ledger_heartbeat_at_utc" => nil,
              "state" => "WAITING_FOR_ARM",
              "last_error" => nil
            )
            @sleeper.call(0.25)
            next
          end
          record_error(runtime, probe_at, e)
          @sleeper.call(1.0)
        rescue Error, RunpodClient::Error, RunpodFleet::Error,
               RunpodFleetNamespace::Error, SystemCallError => e
          if e.message.start_with?("budget is not armed:")
            write_runtime(
              runtime,
              "ready" => true,
              "pid" => Process.pid,
              "provider_probe_at_utc" => probe_at.iso8601,
              "ledger_heartbeat_at_utc" => nil,
              "state" => "WAITING_FOR_ARM",
              "last_error" => nil
            )
            @sleeper.call(0.25)
            next
          end
          record_error(runtime, probe_at, e)
          @sleeper.call(1.0)
        end
      end
      @budget.status
    end

    private

    def reconcile_absent_committed!(status)
      Array(status.fetch("owned_resources").values).each do |resource|
        next unless resource.fetch("status") == "active"

        provider_id = resource.fetch("provider_resource_id")
        begin
          @client.get_pod(provider_id)
        rescue RunpodClient::Error => e
          raise unless e.status == 404
          @budget.mark_resource_absent!(
            provider_resource_id: provider_id,
            verified_absent: true
          )
        end
      end
    end

    def teardown!(status)
      reason = status.fetch("teardown_reason").to_s
      reason = "budget_guardian" if reason.empty?
      active = status.fetch("owned_resources").values.select { |row| row.fetch("status") == "active" }
      pending = status.fetch("reservations").values.select { |row| row.fetch("status") == "pending" }
      grouped = Hash.new { |hash, key| hash[key] = [] }

      active.each do |resource|
        grouped[resource.fetch("fleet_key")] << logical_index(resource.fetch("logical_resource_id"))
      end
      pending.each do |reservation|
        grouped[reservation.fetch("fleet_key")] << logical_index(reservation.fetch("logical_resource_id"))
      end

      # Send every provider deletion before waiting for any one pod to disappear.
      # The A0 liability formula reserves one global teardown window, not one
      # window per worker/fleet, so verification must share a single deadline.
      grouped.each do |fleet_key, indices|
        namespace = @namespace_factory.call(fleet_key)
        fleet = @fleet_factory.call(namespace)
        fleet.destroy(
          worker_indices: indices.uniq.sort,
          verify_absent: false,
          destroy_reason: "budget_guardian:#{reason}"
        )
      end

      wait_for_provider_absence!(status, active:, pending:)

      active.each do |row|
        @budget.mark_resource_absent!(
          provider_resource_id: row.fetch("provider_resource_id"),
          verified_absent: true
        )
      end
      pending.each do |row|
        @budget.release_reservation!(
          reservation_id: row.fetch("reservation_id"),
          reason: "budget guardian verified provider absence",
          provider_absence_verified: true
        )
      end

      latest = @budget.status
      active_remaining = latest.fetch("owned_resources").values.any? { |row| row.fetch("status") == "active" }
      pending_remaining = latest.fetch("reservations").values.any? { |row| row.fetch("status") == "pending" }
      return latest if active_remaining || pending_remaining

      @budget.close!
    end

    def wait_for_provider_absence!(status, active:, pending:)
      wait_seconds = Float(status.dig("limits", "teardown_reserve_seconds"))
      poll_seconds = [Float(status.dig("limits", "guardian_poll_seconds")), 1.0].min
      deadline = @monotonic_clock.call + wait_seconds
      active_ids = active.map { |row| row.fetch("provider_resource_id").to_s }
      pending_names = pending.map do |row|
        expected_worker_name(row.fetch("fleet_key"), logical_index(row.fetch("logical_resource_id")))
      end

      loop do
        live = @client.list_pods
        remaining_ids = live.filter_map do |pod|
          id = pod["id"].to_s
          id if active_ids.include?(id)
        end
        remaining_names = live.filter_map do |pod|
          name = pod["name"].to_s
          name if pending_names.include?(name)
        end
        return true if remaining_ids.empty? && remaining_names.empty?

        if @monotonic_clock.call >= deadline
          detail = (remaining_ids + remaining_names).uniq.join(", ")
          raise Error, "provider still reports budget-owned pod(s) after #{wait_seconds.round(1)} seconds: #{detail}"
        end
        @sleeper.call(poll_seconds)
      end
    end

    def expected_worker_name(fleet_key, index)
      fleet = fleet_key.to_s
      return "af-lme-burst-#{index}" if fleet == "default"

      "af-lme-#{fleet}-burst-#{index}"
    end

    def logical_index(value)
      match = value.to_s.match(/\Aburst_(\d+)\z/)
      raise Error, "budget logical resource id is not a worker slot: #{value.inspect}" unless match

      index = Integer(match[1])
      raise Error, "budget worker index must be positive" unless index.positive?
      index
    end

    def build_client
      key = ENV["RUNPOD_API_KEY"].to_s
      raise Error, "RUNPOD_API_KEY is missing; guardian cannot verify or destroy paid resources" if key.empty?

      RunpodClient.new(
        api_key: key,
        base_url: ENV.fetch("RUNPOD_API_BASE_URL", RunpodClient::DEFAULT_BASE_URL)
      )
    end

    def record_error(runtime_path, probe_at, error)
      @err.puts "Budget guardian: #{error.class}: #{error.message}"
      @err.flush if @err.respond_to?(:flush)
      write_runtime(
        runtime_path,
        "ready" => true,
        "pid" => Process.pid,
        "provider_probe_at_utc" => probe_at.iso8601,
        "ledger_heartbeat_at_utc" => nil,
        "state" => "ERROR_RETRYING",
        "last_error" => "#{error.class}: #{error.message}"
      )
    rescue SystemCallError
      nil
    end

    def write_runtime(path, document)
      FileUtils.mkdir_p(File.dirname(path))
      tmp = "#{path}.tmp.#{$$}"
      File.write(tmp, JSON.pretty_generate(document) + "\n")
      File.chmod(0o600, tmp)
      File.rename(tmp, path)
    ensure
      File.delete(tmp) if defined?(tmp) && tmp && File.exist?(tmp)
    end

    def utc_now
      value = @wall_clock.call
      value = Time.parse(value.to_s) unless value.is_a?(Time)
      value.utc
    rescue ArgumentError
      raise Error, "guardian clock returned invalid time"
    end
  end
end
