# frozen_string_literal: true

require "json"
require "time"
require_relative "../local_model_evaluation/runpod_budget"

module RunpodOllamaFleet
  # Read-only provider timing and tracked-compute-cost measurements.
  class ProviderMeasurements
    CONTRACT_VERSION = "rpof-provider-cost-measurements/v0.1"
    BILLING_SCOPE = "tracked RunPod compute only; storage, network, taxes, credits, and other external charges are not included"

    class Error < StandardError; end

    def self.from_root(root:, budget_id:, plan_sha256:, bringup_root: root,
                       desired_workers: nil, registry: nil, clock: nil)
      clock ||= -> { Time.now.utc }
      budget = LocalModelEvaluation::RunpodBudget.new(
        root:, budget_id:, plan_sha256:, wall_clock: clock
      ).status
      new(
        budget:, bringup_states: load_bringup_states(bringup_root),
        desired_workers:, registry:, clock:
      )
    rescue LocalModelEvaluation::RunpodBudget::Error => e
      raise Error, e.message
    end

    def self.load_bringup_states(root)
      pattern = File.join(File.expand_path(root), "worker-bringup-v0.1", "*", "current")
      Dir.glob(pattern).sort.map do |pointer|
        sha = File.binread(pointer).strip
        raise Error, "invalid worker bring-up current pointer" unless sha.match?(/\A[0-9a-f]{64}\z/)

        path = File.join(File.dirname(pointer), "#{sha}.json")
        raise Error, "worker bring-up current state is missing" unless File.file?(path)

        JSON.parse(File.binread(path))
      end
    rescue SystemCallError, JSON::ParserError => e
      raise Error, "cannot read worker bring-up evidence: #{e.message}"
    end

    def initialize(budget:, bringup_states:, desired_workers: nil, registry: nil,
                   clock: -> { Time.now.utc })
      @budget = deep_copy(budget)
      @bringup_states = deep_copy(Array(bringup_states))
      @desired_workers = desired_workers
      @registry = registry && deep_copy(registry)
      @clock = clock
    end

    def document
      measured_at = utc_now
      resources = @budget.fetch("owned_resources", {}).values
      reservations = @budget.fetch("reservations", {}).values
      active = resources.select { |row| row.fetch("status") == "active" }
      pending = reservations.select { |row| row.fetch("status") == "pending" }
      allocations = allocate_resources(resources, measured_at)
      registry = registry_counts

      {
        "contract_version" => CONTRACT_VERSION,
        "read_only" => true,
        "measured_at_utc" => measured_at.iso8601,
        "measurement_window" => measurement_window(measured_at),
        "capacity" => capacity_measurement(active, pending, registry),
        "samples" => sample_counts(resources, pending, allocations),
        "timing" => timing_measurements(resources, allocations, measured_at),
        "rates" => rate_measurements(active, pending, resources),
        "cost" => cost_measurements(allocations),
        "failures" => failure_measurements(allocations),
        "billing_scope" => BILLING_SCOPE
      }
    rescue KeyError, ArgumentError, TypeError => e
      raise Error, "cannot measure provider cost: #{e.message}"
    end

    private

    def measurement_window(measured_at)
      start_value = @budget["armed_at_utc"]
      end_value = @budget["closed_at_utc"] || @budget["provider_absence_verified_at_utc"]
      return unavailable("budget arm timestamp is unavailable") unless start_value

      started = parse_time(start_value)
      ended = end_value ? parse_time(end_value) : measured_at
      {
        "status" => "available",
        "started_at_utc" => started.iso8601,
        "ended_at_utc" => ended.iso8601,
        "end_basis" => end_value ? "retained_terminal_evidence" : "measurement_clock",
        "elapsed_seconds" => seconds(ended - started)
      }
    end

    def capacity_measurement(active, pending, registry)
      desired = if @desired_workers.nil?
                  unavailable("desired capacity was not supplied to this measurement")
                else
                  { "status" => "available", "count" => Integer(@desired_workers) }
                end
      {
        "desired_workers" => desired,
        "tracked_active_paid_resources" => active.length,
        "pending_or_ambiguous_paid_reservations" => pending.length,
        "provider_active_workers" => unavailable(
          "read-only retained measurements do not contact the provider; tracked active paid resources are reported separately"
        ),
        "registry_ready_workers" => registry.fetch("ready"),
        "registry_not_ready_workers" => registry.fetch("not_ready"),
        "registry_unavailable_workers" => registry.fetch("unavailable"),
        "bringup_in_progress_workers" => @bringup_states.count { |row| in_progress?(row) },
        "failed_bringup_workers" => @bringup_states.count { |row| failed?(row) }
      }
    end

    def registry_counts
      return {
        "ready" => unavailable("registry snapshot was not supplied"),
        "not_ready" => unavailable("registry snapshot was not supplied"),
        "unavailable" => unavailable("registry snapshot was not supplied")
      } unless @registry

      workers = Array(@registry["workers"])
      value = ->(state) { { "status" => "available", "count" => workers.count { |row| row["state"] == state || row["registry_state"] == state } } }
      { "ready" => value.call("READY"), "not_ready" => value.call("NOT_READY"), "unavailable" => value.call("UNAVAILABLE") }
    end

    def sample_counts(resources, pending, allocations)
      {
        "tracked_paid_resources" => resources.length,
        "active_paid_resources" => resources.count { |row| row.fetch("status") == "active" },
        "pending_paid_reservations" => pending.length,
        "bringup_states" => @bringup_states.length,
        "cold_start_samples" => allocations.count { |row| row["cold_start_seconds"] },
        "usable_capacity_samples" => allocations.count { |row| row["usable_seconds"] },
        "failed_bringup_samples" => allocations.count { |row| row["classification"] == "failed_bringup" },
        "resources_without_correlated_bringup_evidence" => allocations.count { |row| row["classification"] == "unallocated" }
      }
    end

    def timing_measurements(resources, allocations, measured_at)
      durations = resources.filter_map { |resource| resource_duration(resource, measured_at) }
      cold = allocations.filter_map { |row| row["cold_start_seconds"] }
      usable = allocations.filter_map { |row| row["usable_seconds"] }
      {
        "provider_paid_duration" => duration_summary(durations),
        "cold_start" => duration_summary(cold).merge(
          "definition" => "tracked provider-resource start through FO-11 bring-up prerequisites passing or a retained terminal bring-up failure"
        ),
        "usable_capacity" => duration_summary(usable).merge(
          "definition" => "FO-11 bring-up prerequisites passed through tracked resource stop or measurement time; registry publication and workload activity are not implied"
        ),
        "ready_duration" => unavailable(
          "retained registry evidence does not provide a durable READY transition interval"
        ),
        "paid_idle_duration" => unavailable(
          "continuous retained activity intervals are unavailable; point-in-time activity cannot establish idle duration"
        ),
        "teardown" => teardown_measurement,
        "tracked_resource_intervals" => public_resource_intervals(resources, allocations, measured_at)
      }
    end

    def rate_measurements(active, pending, resources)
      known = resources.all? { |row| finite_nonnegative?(row["hourly_rate_usd"]) } &&
              pending.all? { |row| finite_nonnegative?(row["max_hourly_rate_delta_usd"]) }
      active_rate = if active.all? { |row| finite_nonnegative?(row["hourly_rate_usd"]) }
                      active.sum { |row| Float(row.fetch("hourly_rate_usd")) }.round(6)
                    else
                      unavailable("hourly rate is missing or invalid for an active paid resource")
                    end
      pending_rate = if pending.all? { |row| finite_nonnegative?(row["max_hourly_rate_delta_usd"]) }
                       pending.sum { |row| Float(row.fetch("max_hourly_rate_delta_usd")) }.round(6)
                     else
                       unavailable("maximum hourly rate is missing or invalid for a pending reservation")
                     end
      {
        "active_paid_resources_hourly_usd" => active_rate,
        "pending_maximum_hourly_usd" => pending_rate,
        "aggregate_current_committed_hourly_usd" => Float(@budget.fetch("committed_rate_usd_per_hour", 0.0)).round(6),
        "rate_evidence_known_for_every_included_resource" => known
      }
    end

    def cost_measurements(allocations)
      cold = allocations.sum { |row| row.fetch("cold_start_cost_usd", 0.0) }
      usable = allocations.sum { |row| row.fetch("usable_cost_usd", 0.0) }
      failed = allocations.sum { |row| row.fetch("failed_bringup_cost_usd", 0.0) }
      allocated = allocations.sum { |row| row.fetch("allocated_cost_usd", 0.0) }
      accrued = Float(@budget.fetch("accrued_compute_usd", 0.0))
      usable_samples = allocations.count { |row| row["usable_seconds"] }
      {
        "accrued_tracked_compute_usd" => accrued.round(6),
        "committed_and_pending_maximum_liability_usd" => Float(
          @budget.fetch("committed_maximum_liability_usd", 0.0)
        ).round(6),
        "cold_start_compute_usd" => cold.round(6),
        "failed_or_aborted_bringup_compute_usd" => failed.round(6),
        "usable_capacity_compute_estimate" => {
          "status" => usable_samples.positive? ? "estimated" : "unavailable",
          "usd" => usable.round(6),
          "definition" => "tracked compute after FO-11 bring-up prerequisites passed; may include READY-idle time and does not claim WLO command execution",
          "resource_sample_count" => usable_samples
        },
        "ready_idle_compute_usd" => unavailable("continuous READY and workload-idle intervals are unavailable"),
        "useful_work_compute_usd" => unavailable(
          "provider evidence alone cannot attribute paid time to workload command execution; owner measurements must be time-aligned by a separate presentation layer"
        ),
        "unallocated_tracked_compute_usd" => [accrued - allocated, 0.0].max.round(6),
        "allocation_coverage" => {
          "resource_count" => allocations.count { |row| row["classification"] != "unallocated" },
          "total_resource_count" => allocations.length
        }
      }
    end

    def failure_measurements(allocations)
      failed = allocations.select { |row| row["classification"] == "failed_bringup" }
      {
        "failed_bringup_resource_count" => failed.length,
        "failed_bringup_tracked_seconds" => seconds(failed.sum { |row| row.fetch("resource_seconds") }),
        "failed_bringup_compute_usd" => failed.sum { |row| row.fetch("failed_bringup_cost_usd") }.round(6)
      }
    end

    def allocate_resources(resources, measured_at)
      states = @bringup_states.group_by { |row| row.dig("identity", "provider_resource_id").to_s }
      resources.map do |resource|
        resource_id = resource.fetch("provider_resource_id").to_s
        started = parse_optional_time(resource["started_at_utc"])
        ended = resource_end(resource, measured_at)
        duration = started && ended && ended >= started ? ended - started : nil
        rate = finite_nonnegative?(resource["hourly_rate_usd"]) ? Float(resource["hourly_rate_usd"]) : nil
        state = Array(states[resource_id]).max_by { |row| row["updated_at_utc"].to_s }
        base = { "provider_resource_id" => resource_id, "resource_seconds" => duration || 0.0 }
        next base.merge("classification" => "unallocated") unless state && duration && rate

        if failed?(state)
          failed_at = failed_at(state)
          cold_duration = failed_at && failed_at >= started && failed_at <= ended ? failed_at - started : duration
          cold_cost = rate * cold_duration / 3600.0
          cost = rate * duration / 3600.0
          next base.merge(
            "classification" => "failed_bringup", "cold_start_seconds" => seconds(cold_duration),
            "cold_start_cost_usd" => cold_cost, "failed_bringup_cost_usd" => cost,
            "allocated_cost_usd" => cost
          )
        end

        ready_at = prerequisites_passed_at(state)
        unless ready_at && ready_at >= started && ready_at <= ended
          cost = in_progress?(state) ? rate * duration / 3600.0 : 0.0
          next base.merge(
            "classification" => in_progress?(state) ? "cold_start_in_progress" : "unallocated",
            "cold_start_seconds" => in_progress?(state) ? seconds(duration) : nil,
            "cold_start_cost_usd" => cost, "allocated_cost_usd" => cost
          )
        end

        cold_seconds = ready_at - started
        usable_seconds = ended - ready_at
        cold_cost = rate * cold_seconds / 3600.0
        usable_cost = rate * usable_seconds / 3600.0
        base.merge(
          "classification" => "prerequisites_passed",
          "cold_start_seconds" => seconds(cold_seconds), "usable_seconds" => seconds(usable_seconds),
          "cold_start_cost_usd" => cold_cost, "usable_cost_usd" => usable_cost,
          "allocated_cost_usd" => cold_cost + usable_cost
        )
      end
    end

    def prerequisites_passed_at(state)
      return unless state["readiness_prerequisites_satisfied"] == true || state["overall_status"] == "prerequisites_passed"

      values = %w[tunnel bootstrap capability].filter_map do |stage|
        parse_optional_time(state.dig(stage, "updated_at_utc"))
      end
      values.max
    end

    def failed?(state)
      %w[tunnel bootstrap capability].any? { |stage| state.dig(stage, "status") == "failed_terminal" }
    end

    def failed_at(state)
      %w[tunnel bootstrap capability].filter_map do |stage|
        next unless state.dig(stage, "status") == "failed_terminal"

        parse_optional_time(state.dig(stage, "updated_at_utc"))
      end.max
    end

    def in_progress?(state)
      statuses = %w[tunnel bootstrap capability].map { |stage| state.dig(stage, "status") }
      statuses.any? { |status| %w[not_started in_progress failed_retryable].include?(status) } && !failed?(state)
    end

    def resource_duration(resource, measured_at)
      started = parse_optional_time(resource["started_at_utc"])
      ended = resource_end(resource, measured_at)
      seconds(ended - started) if started && ended && ended >= started
    end

    def resource_end(resource, measured_at)
      parse_optional_time(resource["stopped_at_utc"]) || measured_at
    end

    def public_resource_intervals(resources, allocations, measured_at)
      by_id = allocations.to_h { |row| [row.fetch("provider_resource_id"), row] }
      states = @bringup_states.group_by { |row| row.dig("identity", "provider_resource_id").to_s }
      resources.filter_map do |resource|
        started = parse_optional_time(resource["started_at_utc"])
        ended = resource_end(resource, measured_at)
        rate = resource["hourly_rate_usd"]
        next unless started && ended && ended >= started && finite_nonnegative?(rate)

        state = Array(states[resource.fetch("provider_resource_id").to_s]).max_by { |row| row["updated_at_utc"].to_s }
        identity = state && state["identity"]
        {
          "provider_resource_id" => resource.fetch("provider_resource_id").to_s,
          "worker_identity" => identity && identity.slice("worker_id", "generation_id"),
          "started_at_utc" => started.iso8601,
          "ended_at_utc" => ended.iso8601,
          "tracked_hourly_rate_usd" => Float(rate),
          "classification" => by_id.fetch(resource.fetch("provider_resource_id").to_s).fetch("classification")
        }
      end
    end

    def duration_summary(values)
      return unavailable("no valid timing samples").merge("sample_count" => 0) if values.empty?

      {
        "status" => "available", "sample_count" => values.length,
        "total_seconds" => seconds(values.sum), "mean_seconds" => seconds(values.sum / values.length)
      }
    end

    def teardown_measurement
      started = parse_optional_time(@budget["teardown_started_at_utc"])
      finished = parse_optional_time(@budget["provider_absence_verified_at_utc"])
      return unavailable("teardown has not started") unless started
      return unavailable("provider absence has not been verified").merge("started_at_utc" => started.iso8601) unless finished

      {
        "status" => "available", "started_at_utc" => started.iso8601,
        "finished_at_utc" => finished.iso8601, "elapsed_seconds" => seconds(finished - started)
      }
    end

    def finite_nonnegative?(value)
      number = Float(value)
      number.finite? && !number.negative?
    rescue ArgumentError, TypeError
      false
    end

    def parse_optional_time(value)
      value && parse_time(value)
    rescue ArgumentError
      nil
    end

    def parse_time(value)
      Time.iso8601(value.to_s).utc
    end

    def utc_now
      value = @clock.call
      value = Time.parse(value.to_s) unless value.is_a?(Time)
      value.utc
    end

    def seconds(value)
      Float(value).round(6)
    end

    def unavailable(reason)
      { "status" => "unavailable", "reason" => reason }
    end

    def deep_copy(value)
      JSON.parse(JSON.generate(value))
    end
  end
end
