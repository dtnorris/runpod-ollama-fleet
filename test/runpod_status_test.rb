# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "fileutils"
require_relative "../lib/local_model_evaluation/runpod_status"

class RunpodStatusTest < Minitest::Test
  class FakeFleetState
    def initialize(root:, current:)
      @root = root
      @current = current
    end

    def current
      @current
    end

    def artifact_dir(fleet_id, name)
      File.join(@root, fleet_id, name)
    end
  end

  class ProviderError < StandardError
    attr_reader :status

    def initialize(status, message)
      @status = status
      super(message)
    end
  end

  class FakeClient
    def initialize(pods = {})
      @pods = pods
    end

    def get_pod(pod_id)
      value = @pods.fetch(pod_id) { raise ProviderError.new(404, "not found") }
      raise value if value.is_a?(Exception)
      value
    end
  end

  def setup
    @tmp = Dir.mktmpdir("lme-runpod-status-")
    @now = Time.utc(2026, 8, 29, 20, 30, 0)
  end

  def teardown
    FileUtils.remove_entry(@tmp) if @tmp && File.exist?(@tmp)
  end

  def test_active_fleet_reports_rate_elapsed_cost_and_provider_state
    fleet = fleet_record(
      workers: [
        worker(1, "pod_a", 0.44),
        worker(2, "pod_b", 0.50)
      ]
    )
    client = FakeClient.new(
      "pod_a" => { "status" => "RUNNING", "cost" => 0.44 },
      "pod_b" => { "status" => "RUNNING", "cost" => 0.50 }
    )
    status = build_status(fleet, client:)

    snapshot = status.snapshot

    assert_in_delta 1800.0, snapshot.fetch("tracked_elapsed_seconds"), 0.001
    assert_in_delta 0.94, snapshot.fetch("current_tracked_hourly_rate_usd"), 0.0001
    assert_in_delta 0.47, snapshot.fetch("estimated_accrued_cost_usd"), 0.0001
    assert_equal %w[RUNNING RUNNING], snapshot.fetch("workers").map { |entry| entry.fetch("provider_status") }

    output = status.render(snapshot)
    assert_includes output, "Current tracked rate: $0.9400/hr"
    assert_includes output, "Tracked elapsed: 00:30:00"
    assert_includes output, "Estimated accrued cost: $0.4700"
  end

  def test_status_reports_lease_deadline_and_budget_remaining
    fleet = fleet_record(workers: [worker(1, "pod_a", 0.44)])
    fleet["lease"] = {
      "started_at_utc" => "2026-08-29T20:00:00Z",
      "max_runtime_seconds" => 3600.0,
      "max_spend_usd" => 1.0
    }
    status = build_status(fleet)

    snapshot = status.snapshot
    lease = snapshot.fetch("lease")
    assert_equal "2026-08-29T21:00:00Z", lease.fetch("expires_at_utc")
    assert_in_delta 0.78, lease.fetch("budget_remaining_usd"), 0.000001

    output = status.render(snapshot)
    assert_includes output, "Lease deadline: 2026-08-29T21:00:00Z"
    assert_includes output, "Runtime lease: 01:00:00 max; 00:30:00 remaining"
    assert_includes output, "Spend lease: $1.0000 max; $0.2200 conservative tracked"
    assert_includes output, "Budget remaining: $0.7800"
  end

  def test_partial_teardown_stops_cost_clock_for_destroyed_worker
    fleet = fleet_record(
      workers: [
        worker(1, "pod_a", 0.44, status: "destroyed", destroyed_at: "2026-08-29T20:10:00Z"),
        worker(2, "pod_b", 0.50)
      ]
    )
    status = build_status(fleet, client: FakeClient.new("pod_b" => { "status" => "RUNNING" }))

    snapshot = status.snapshot
    first, second = snapshot.fetch("workers")

    assert_in_delta 600.0, first.fetch("tracked_elapsed_seconds"), 0.001
    assert_in_delta 1800.0, second.fetch("tracked_elapsed_seconds"), 0.001
    assert_in_delta 0.073333, first.fetch("estimated_cost_usd"), 0.00001
    assert_in_delta 0.25, second.fetch("estimated_cost_usd"), 0.00001
    assert_in_delta 0.323333, snapshot.fetch("estimated_accrued_cost_usd"), 0.00001
    assert_in_delta 0.50, snapshot.fetch("current_tracked_hourly_rate_usd"), 0.00001
    assert_equal "-", first.fetch("provider_status")
  end

  def test_current_bootstrap_is_reported_with_worker_stages
    fleet = fleet_record(workers: [worker(1, "pod_a", 0.44), worker(2, "pod_b", 0.44)])
    state = FakeFleetState.new(root: @tmp, current: fleet)
    bootstrap_root = state.artifact_dir(fleet.fetch("fleet_id"), "bootstrap")
    run_id = "20260829T201000Z-1234-abcd"
    run_dir = File.join(bootstrap_root, run_id)
    FileUtils.mkdir_p(run_dir)
    File.write(File.join(bootstrap_root, "current"), "#{run_id}\n")
    File.write(File.join(run_dir, "bootstrap.json"), JSON.pretty_generate(
      {
        "fleet_id" => fleet.fetch("fleet_id"),
        "status" => "running",
        "started_at_utc" => "2026-08-29T20:10:00Z",
        "finished_at_utc" => nil,
        "models" => ["gemma4:26b"],
        "context" => 131_072,
        "workers" => [
          { "index" => 1, "status" => "passed", "stage" => "READY" },
          { "index" => 2, "status" => "running", "stage" => "WARMING" }
        ]
      }
    ))
    status = LocalModelEvaluation::RunpodStatus.new(
      fleet_state: state,
      client: nil,
      wall_clock: -> { @now }
    )

    snapshot = status.snapshot
    bootstrap = snapshot.fetch("bootstrap")
    assert_equal "running", bootstrap.fetch("status")
    assert_equal ["gemma4:26b"], bootstrap.fetch("models")
    assert_in_delta 1200.0, bootstrap.fetch("elapsed_seconds"), 0.001

    output = status.render(snapshot)
    assert_includes output, "burst_1"
    assert_includes output, "READY"
    assert_includes output, "WARMING"
    assert_includes output, "Models: gemma4:26b"
    assert_includes output, "1 running; 1 passed; 0 failed; 0 interrupted"
  end

  def test_provider_missing_warns_without_hiding_local_billing_state
    fleet = fleet_record(workers: [worker(1, "pod_missing", 0.44)])
    status = build_status(fleet, client: FakeClient.new)

    snapshot = status.snapshot
    assert_equal "MISSING", snapshot.fetch("workers").first.fetch("provider_status")
    assert_in_delta 0.22, snapshot.fetch("estimated_accrued_cost_usd"), 0.0001

    output = status.render(snapshot)
    assert_includes output, "WARNING: burst_1 is ACTIVE in LME state but RunPod status is MISSING"
  end

  def test_status_routes_worker_sixteen_from_fleet_state
    fleet = fleet_record(workers: [worker(16, "pod_16", 0.44)])
    status = build_status(fleet, client: FakeClient.new("pod_16" => { "status" => "RUNNING", "cost" => 0.44 }))

    snapshot = status.snapshot
    assert_equal 16, snapshot.fetch("workers").first.fetch("index")
    assert_includes status.render(snapshot), "burst_16"
  end

  def test_no_current_fleet_is_a_clean_zero_state
    state = FakeFleetState.new(root: @tmp, current: nil)
    status = LocalModelEvaluation::RunpodStatus.new(fleet_state: state, wall_clock: -> { @now })

    assert_nil status.snapshot
    assert_equal "No current RunPod fleet.\n", status.render(nil)
  end

  private

  def build_status(fleet, client: nil)
    state = FakeFleetState.new(root: @tmp, current: fleet)
    LocalModelEvaluation::RunpodStatus.new(
      fleet_state: state,
      client: client,
      wall_clock: -> { @now }
    )
  end

  def fleet_record(workers:)
    {
      "fleet_id" => "20260829T200000Z-pod_a",
      "status" => "active",
      "created_at_utc" => "2026-08-29T20:00:00Z",
      "destroyed_at_utc" => nil,
      "cloud" => "SECURE",
      "gpu" => { "id" => "NVIDIA A40", "count_per_worker" => 1 },
      "fleet_hourly_rate_usd" => workers.sum { |entry| entry.fetch("hourly_rate_usd") },
      "workers" => workers
    }
  end

  def worker(index, pod_id, rate, status: "active", destroyed_at: nil)
    {
      "index" => index,
      "name" => "af-lme-burst-#{index}",
      "pod_id" => pod_id,
      "host" => "198.51.100.#{index}",
      "ssh_port" => 22_000 + index,
      "hourly_rate_usd" => rate,
      "status" => status,
      "destroyed_at_utc" => destroyed_at
    }.compact
  end
end
