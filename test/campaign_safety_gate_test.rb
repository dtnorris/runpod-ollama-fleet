# frozen_string_literal: true

require_relative "test_helper"
require "json"
require_relative "../lib/runpod_ollama_fleet"

class CampaignSafetyGateTest < Minitest::Test
  FIXTURE = File.expand_path("fixtures/rpof-capacity-campaign-v0.1.json", __dir__)
  BUDGET = File.expand_path("fixtures/rpof-capacity-campaign-budget-v0.1.json", __dir__)
  HARDWARE = File.expand_path("../config/execution_pool_hardware.yml", __dir__)

  class Guardian
    attr_accessor :healthy, :identity_matches, :fail_arm

    def initialize(clock)
      @clock = clock
      @healthy = true
      @identity_matches = true
      @fail_arm = false
      @armed = false
    end

    def arm!(budget:, request:)
      raise LocalModelEvaluation::RunpodBudgetGuardianSupervisor::Error, "fixture guardian arm failed" if fail_arm

      result = budget.arm!(budget: request, guardian_heartbeat_at_utc: @clock.call)
      @armed = true
      result
    end

    def status(budget:)
      {
        "budget_id" => identity_matches ? budget.budget_id : "wrong-budget",
        "plan_sha256" => identity_matches ? budget.plan_sha256 : "f" * 64,
        "enabled" => healthy,
        "launchd_loaded" => healthy,
        "ready" => healthy,
        "pid" => Process.pid + 1,
        "provider_probe_at_utc" => @clock.call.iso8601,
        "ledger_heartbeat_at_utc" => @clock.call.iso8601,
        "state" => (@armed ? budget.status.fetch("state") : "WAITING_FOR_ARM"),
        "last_error" => nil,
        "launchd_label" => "com.adventurefinder.fixture"
      }
    end
  end

  class Runtime
    attr_accessor :admission
    attr_reader :count

    def initialize(profile, admission, events)
      @profile = profile
      @admission = admission
      @events = events
      @count = 0
    end

    def current_worker_count = count

    def ensure_workers!(desired_workers:, **)
      ((count + 1)..desired_workers).each do |index|
        handle = admission.reserve!(
          operation_type: count.zero? ? "create" : "scale_up",
          logical_resource_id: "burst_#{index}",
          max_hourly_rate_delta_usd: 0.5,
          gpu_id: qualified_gpu,
          cloud: "SECURE"
        )
        pod = admission.attempt_provider_create!(handle) do
          @events << "provider_create"
          { "id" => "#{@profile.fetch('profile_id')}-pod-#{index}" }
        end
        admission.commit!(handle, provider_resource_id: pod.fetch("id"), actual_hourly_rate_usd: 0.5)
        @count += 1
      end
    end

    def status
      {
        "current_workers" => count,
        "ready_workers" => count,
        "fleet_id" => count.positive? ? "fixture-fleet" : nil,
        "fleet_status" => count.positive? ? "active" : nil,
        "worker_readiness" => count.positive? ? { "active" => count } : {}
      }
    end

    private

    def qualified_gpu
      @profile.fetch("profile_id") == "gemma" ? "NVIDIA L40S" : "NVIDIA A40"
    end
  end

  class Controller
    attr_accessor :lifecycle

    def ensure_running!(binding:, ssh_public_key_path:, **)
      binding.parent_budget.heartbeat!(source: "orchestrator")
      lifecycle.reconcile_once(ssh_public_key_path:)
      status(binding:)
    end

    def validate_requirements!(binding:) = true

    def status(binding:)
      { "state" => "RUNNING", "pid" => Process.pid + 1, "binding_sha256" => binding.binding_sha256 }
    end

    def disable!(binding:)
      status(binding:).merge("state" => "STOPPED")
    end
  end

  def setup
    @tmp = Dir.mktmpdir("campaign-safety-gate-")
    @now = Time.utc(2026, 10, 2, 12, 0, 0)
    hardware = RunpodOllamaFleet::ExecutionPoolHardware.new(path: HARDWARE)
    @campaign = RunpodOllamaFleet::CapacityCampaign.load(path: FIXTURE, hardware:)
    @guardian = Guardian.new(-> { @now })
    @events = []
    @runtimes = {}
  end

  def teardown
    FileUtils.remove_entry(@tmp) if @tmp && File.exist?(@tmp)
  end

  def test_valid_gate_is_reported_before_provider_mutation_with_truthful_scope
    lifecycle, = build_lifecycle
    observed = nil

    result = lifecycle.start(
      authorize_paid: true,
      ssh_public_key_path: "unused",
      safety_reporter: lambda do |report|
        observed = report
        @events << "safety_#{report.fetch('safety_gate')}"
      end
    )

    assert_equal "PASS", observed.fetch("safety_gate")
    assert_operator @events.index("safety_PASS"), :<, @events.index("provider_create")
    assert_equal 6, observed.dig("workers", "projected")
    assert_equal 3.0, observed.dig("hourly_compute_usd", "projected")
    assert_equal 30.0, observed.dig("cumulative_compute_usd", "maximum")
    assert_equal 5400.0, observed.dig("runtime", "maximum_seconds")
    assert_equal 155.0, observed.dig("crash_liability", "horizon_seconds")
    assert_in_delta 0.129167,
                    observed.dig("crash_liability", "maximum_additional_compute_usd_after_orchestrator_loss"),
                    0.000001
    assert observed.dig("enforcement", "guardian_healthy_and_armed")
    assert observed.dig("enforcement", "guardian_identity_matches")
    assert observed.dig("enforcement", "survives", "initiating_cli_exit")
    assert observed.dig("enforcement", "does_not_guarantee", "host_power_loss_or_reboot_before_service_restoration")
    assert_equal "runpod_pod_compute_only", observed.dig("billing_scope", "label")
    assert observed.dig("billing_scope", "charges_may_continue_outside_cap")
    refute observed.dig("billing_scope", "requested_resources", "global_volume", "created_by_campaign")
    assert_equal observed, result.fetch("safety_report")
  end

  def test_missing_or_nonfinite_required_bounds_fail_before_provider_create
    assert_invalid_budget("max_cumulative_compute_usd" => nil)
    assert_invalid_budget("max_cumulative_compute_usd" => Float::INFINITY)
    assert_invalid_budget("max_runtime_seconds" => nil)
    assert_invalid_budget("max_runtime_seconds" => Float::NAN)
    assert_empty @events
  end

  def test_guardian_arm_health_and_identity_fail_before_provider_create
    @guardian.fail_arm = true
    lifecycle, = build_lifecycle
    assert_raises(RunpodOllamaFleet::CampaignLifecycle::Error) do
      lifecycle.start(authorize_paid: true, ssh_public_key_path: "unused")
    end
    assert_empty @events

    @guardian = Guardian.new(-> { @now })
    @guardian.healthy = false
    lifecycle, = build_lifecycle(root: File.join(@tmp, "unhealthy"))
    assert_raises(RunpodOllamaFleet::CampaignLifecycle::Error) do
      lifecycle.start(authorize_paid: true, ssh_public_key_path: "unused")
    end
    assert_empty @events

    @guardian = Guardian.new(-> { @now })
    @guardian.identity_matches = false
    lifecycle, = build_lifecycle(root: File.join(@tmp, "identity"))
    error = assert_raises(RunpodOllamaFleet::CampaignLifecycle::Error) do
      lifecycle.start(authorize_paid: true, ssh_public_key_path: "unused")
    end
    assert_includes error.message, "identity mismatch"
    assert_empty @events
  end

  def test_expired_original_deadline_and_excess_crash_liability_fail_before_create
    lifecycle, binding = build_lifecycle
    binding.arm!
    original_deadline = binding.status.fetch("deadline_at_utc")
    @now = Time.parse(original_deadline) + 1

    error = assert_raises(RunpodOllamaFleet::CampaignLifecycle::Error) do
      lifecycle.start(authorize_paid: true, ssh_public_key_path: "unused")
    end
    assert_match(/deadline|TEARDOWN_REQUIRED/, error.message)
    assert_equal original_deadline, binding.inspect_authority.fetch("deadline_at_utc")
    assert_empty @events

    @now = Time.utc(2026, 10, 2, 12, 0, 0)
    @guardian = Guardian.new(-> { @now })
    lifecycle, = build_lifecycle(
      root: File.join(@tmp, "liability"),
      budget_overrides: { "max_cumulative_compute_usd" => 0.12 }
    )
    error = assert_raises(RunpodOllamaFleet::CampaignLifecycle::Error) do
      lifecycle.start(authorize_paid: true, ssh_public_key_path: "unused")
    end
    assert_includes error.message, "projected_cumulative_compute_authority_exceeded"
    assert_empty @events
  end

  def test_pending_ambiguous_capacity_is_included_in_safety_liability
    _lifecycle, binding = build_lifecycle
    binding.arm!
    admission = RunpodOllamaFleet::CampaignCapacityAdmission.new(binding:, profile_id: "qwen35")
    admission.reserve!(
      operation_type: "replace",
      logical_resource_id: "burst_1",
      max_hourly_rate_delta_usd: 0.75,
      gpu_id: "NVIDIA A40",
      cloud: "SECURE"
    )

    report = binding.safety_report(projected_workers: 1, projected_hourly_rate_usd: 0.75)

    assert_equal "PASS", report.fetch("safety_gate")
    assert_equal 1, report.dig("workers", "committed_and_pending")
    assert_equal 1, report.dig("workers", "pending_or_ambiguous")
    assert_equal 0.75, report.dig("hourly_compute_usd", "committed_and_pending")
    assert_equal 0.75, report.dig("hourly_compute_usd", "pending_or_ambiguous")
    assert_in_delta 0.032292,
                    report.dig("cumulative_compute_usd", "committed_and_pending_maximum_liability"),
                    0.000001
  end

  def test_failed_gate_is_retained_before_assertion_raises
    _lifecycle, binding = build_lifecycle
    binding.arm!

    error = assert_raises(RunpodOllamaFleet::CampaignBudgetBinding::Error) do
      binding.assert_safety_gate!(projected_workers: 99, projected_hourly_rate_usd: 49.5)
    end

    assert_includes error.message, "projected_worker_ceiling_exceeded"
    artifact = binding.retained_safety_report
    assert_equal "rpof-retained-capacity-campaign-safety-report/v0.1", artifact.fetch("contract_version")
    assert_equal binding.binding_sha256, artifact.fetch("binding_sha256")
    assert_equal "FAIL", artifact.dig("report", "safety_gate")
    assert_includes artifact.dig("report", "refusal_reasons"), "projected_worker_ceiling_exceeded"
  end

  private

  def build_lifecycle(root: @tmp, budget_overrides: {})
    declaration = JSON.parse(File.binread(BUDGET)).merge(budget_overrides)
    binding = RunpodOllamaFleet::CampaignBudgetBinding.new(
      root:,
      repo_root: File.expand_path("..", __dir__),
      campaign: @campaign,
      declaration:,
      wall_clock: -> { @now },
      guardian_supervisor: @guardian
    )
    factory = lambda do |profile, _hardware, admission|
      runtime = (@runtimes[profile.fetch("profile_id")] ||= Runtime.new(profile, admission, @events))
      runtime.admission = admission if admission
      runtime
    end
    controller = Controller.new
    lifecycle = RunpodOllamaFleet::CampaignLifecycle.new(
      campaign: @campaign,
      binding:,
      runtime_factory: factory,
      price_resolver: ->(_profile, _hardware) { 0.5 },
      wall_clock: -> { @now },
      controller_supervisor: controller
    )
    controller.lifecycle = lifecycle
    [lifecycle, binding]
  end

  def assert_invalid_budget(overrides)
    error = assert_raises(RunpodOllamaFleet::CampaignBudgetBinding::Error) do
      build_lifecycle(root: File.join(@tmp, "invalid-#{overrides.keys.first}"), budget_overrides: overrides)
    end
    assert_includes error.message, "positive and finite"
  end
end
