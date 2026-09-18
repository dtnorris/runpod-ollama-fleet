# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "fileutils"
require_relative "../lib/local_model_evaluation/runpod_budget"
require_relative "../lib/local_model_evaluation/runpod_budget_guardian"

class RunpodBudgetGuardianTest < Minitest::Test
  PLAN = "a" * 64

  FakeNamespace = Struct.new(:fleet_key, :env_path, :state_root, :local_port_base, keyword_init: true)

  class FakeProvider
    def initialize
      @pods = {}
    end

    def add(id, name)
      @pods[id] = { "id" => id, "name" => name }
    end

    def list_pods
      @pods.values
    end

    def get_pod(id)
      pod = @pods[id]
      raise LocalModelEvaluation::RunpodClient::Error.new(404, "missing") unless pod
      pod
    end

    def delete(id)
      @pods.delete(id)
    end
  end

  class FakeFleet
    attr_reader :calls

    def initialize(provider, names)
      @provider = provider
      @names = names
      @calls = []
    end

    def destroy(worker_indices:, verify_absent:, destroy_reason:, verify_wait_seconds: 30.0, verify_poll_seconds: 1.0)
      @calls << {
        worker_indices:,
        verify_absent:,
        destroy_reason:,
        verify_wait_seconds:,
        verify_poll_seconds:
      }
      worker_indices.each do |index|
        name = @names.fetch(index)
        pod = @provider.list_pods.find { |row| row["name"] == name }
        @provider.delete(pod["id"]) if pod
      end
      worker_indices
    end
  end

  def setup
    @tmp = Dir.mktmpdir("budget-guardian-")
    @now = Time.utc(2026, 9, 18, 20, 0, 0)
    @budget = LocalModelEvaluation::RunpodBudget.new(
      root: @tmp,
      budget_id: "batch034",
      plan_sha256: PLAN,
      wall_clock: -> { @now }
    )
    @provider = FakeProvider.new
    @fleet = FakeFleet.new(@provider, 1 => "af-lme-ep-qwen-burst-1", 2 => "af-lme-ep-qwen-burst-2")
    @namespace = FakeNamespace.new(
      fleet_key: "ep-qwen",
      env_path: File.join(@tmp, "fleet.env"),
      state_root: @tmp,
      local_port_base: 11_500
    )
  end

  def teardown
    FileUtils.remove_entry(@tmp) if @tmp && File.exist?(@tmp)
  end

  def test_armed_tick_reconciles_provider_absence_without_teardown
    arm
    reservation = @budget.reserve_mutation!(
      operation_type: "create",
      fleet_key: "ep-qwen",
      logical_resource_id: "burst_1",
      max_hourly_rate_delta_usd: 1.0,
      reservation_id: "r1"
    )
    @budget.commit_mutation!(
      reservation_id: "r1",
      provider_resource_id: "pod-1",
      actual_hourly_rate_usd: 0.5,
      started_at_utc: reservation.fetch("created_at_utc")
    )

    guardian = build_guardian
    status = guardian.tick

    assert_equal "ARMED", status.fetch("state")
    assert_equal "absent", status.dig("owned_resources", "pod-1", "status")
  end

  def test_teardown_destroys_committed_and_pending_slots_then_closes_budget
    arm
    @provider.add("pod-1", "af-lme-ep-qwen-burst-1")
    @provider.add("pod-2", "af-lme-ep-qwen-burst-2")
    reservation = @budget.reserve_mutation!(
      operation_type: "create",
      fleet_key: "ep-qwen",
      logical_resource_id: "burst_1",
      max_hourly_rate_delta_usd: 1.0,
      reservation_id: "r1"
    )
    @budget.commit_mutation!(
      reservation_id: "r1",
      provider_resource_id: "pod-1",
      actual_hourly_rate_usd: 0.5,
      started_at_utc: reservation.fetch("created_at_utc")
    )
    @budget.reserve_mutation!(
      operation_type: "scale_up",
      fleet_key: "ep-qwen",
      logical_resource_id: "burst_2",
      max_hourly_rate_delta_usd: 1.0,
      reservation_id: "r2"
    )
    @budget.begin_teardown!(reason: "fixture")

    status = build_guardian.tick

    assert_equal "CLOSED", status.fetch("state")
    assert_empty @provider.list_pods
    assert_equal "absent", status.dig("owned_resources", "pod-1", "status")
    assert_equal "released", status.dig("reservations", "r2", "status")
    assert_equal [1, 2], @fleet.calls.fetch(0).fetch(:worker_indices)
    assert_equal false, @fleet.calls.fetch(0).fetch(:verify_absent)
  end

  def test_stale_orchestrator_heartbeat_triggers_crash_teardown_and_close
    arm
    @provider.add("pod-1", "af-lme-ep-qwen-burst-1")
    reservation = @budget.reserve_mutation!(
      operation_type: "create",
      fleet_key: "ep-qwen",
      logical_resource_id: "burst_1",
      max_hourly_rate_delta_usd: 1.0,
      reservation_id: "r1"
    )
    @budget.commit_mutation!(
      reservation_id: "r1",
      provider_resource_id: "pod-1",
      actual_hourly_rate_usd: 0.5,
      started_at_utc: reservation.fetch("created_at_utc")
    )

    @now += 31
    status = build_guardian.tick

    assert_equal "CLOSED", status.fetch("state")
    assert_equal "stale_orchestrator_heartbeat", status.fetch("teardown_reason")
    assert_empty @provider.list_pods
    assert_equal false, @fleet.calls.fetch(0).fetch(:verify_absent)
  end

  def test_provider_probe_is_required_before_guardian_readiness
    broken = Object.new
    def broken.list_pods
      raise LocalModelEvaluation::RunpodClient::Error.new(503, "fixture outage")
    end

    error = assert_raises(LocalModelEvaluation::RunpodBudgetGuardian::Error) do
      build_guardian(provider: broken).provider_probe!
    end
    assert_includes error.message, "provider probe failed"
  end

  private

  def arm
    @budget.arm!(budget: budget_config, guardian_heartbeat_at_utc: @now)
  end

  def build_guardian(provider: @provider)
    LocalModelEvaluation::RunpodBudgetGuardian.new(
      root: @tmp,
      repo_root: @tmp,
      budget_id: "batch034",
      plan_sha256: PLAN,
      budget: @budget,
      provider_client: provider,
      namespace_factory: ->(_fleet_key) { @namespace },
      fleet_factory: ->(_namespace) { @fleet },
      sleeper: ->(_seconds) {},
      wall_clock: -> { @now }
    )
  end

  def budget_config
    {
      "contract_version" => "afio-production-burst-budget/v0.1",
      "budget_id" => "batch034",
      "plan_sha256" => PLAN,
      "max_cumulative_compute_usd" => 5.0,
      "max_runtime_seconds" => 2700.0,
      "guardian_poll_seconds" => 5.0,
      "orchestrator_heartbeat_timeout_seconds" => 30.0,
      "teardown_reserve_seconds" => 60.0
    }
  end
end
