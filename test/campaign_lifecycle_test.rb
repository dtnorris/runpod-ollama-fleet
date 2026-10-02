# frozen_string_literal: true

require_relative "test_helper"
require "json"
require_relative "../lib/runpod_ollama_fleet"

class CampaignLifecycleTest < Minitest::Test
  FIXTURE = File.expand_path("fixtures/rpof-capacity-campaign-v0.1.json", __dir__)
  BUDGET = File.expand_path("fixtures/rpof-capacity-campaign-budget-v0.1.json", __dir__)
  HARDWARE = File.expand_path("../config/execution_pool_hardware.yml", __dir__)

  class Guardian
    attr_reader :events
    attr_accessor :healthy

    def initialize(clock, events)
      @clock = clock
      @events = events
      @healthy = true
      @armed = false
    end

    def arm!(budget:, request:)
      events << "guardian_arm"
      result = budget.arm!(budget: request, guardian_heartbeat_at_utc: @clock.call)
      @armed = true
      result
    end

    def status(budget:)
      {
        "budget_id" => budget.budget_id,
        "plan_sha256" => budget.plan_sha256,
        "enabled" => healthy, "launchd_loaded" => healthy, "ready" => healthy,
        "pid" => Process.pid + 1, "provider_probe_at_utc" => @clock.call.iso8601,
        "ledger_heartbeat_at_utc" => @clock.call.iso8601,
        "state" => (@armed ? budget.status.fetch("state") : "WAITING_FOR_ARM"),
        "last_error" => nil
      }
    end
  end

  class Runtime
    attr_reader :profile, :events
    attr_accessor :count, :fail_mode

    def initialize(profile, admission, binding, events)
      @profile = profile
      @admission = admission
      @binding = binding
      @events = events
      @count = 0
      @fail_mode = nil
    end

    def current_worker_count = count

    def ensure_workers!(desired_workers:, **)
      raise "definitive startup failure" if fail_mode == :before_reservation
      ((count + 1)..desired_workers).each do |index|
        raise "binding was not persisted" unless File.file?(@binding.state_path)
        raise "guardian was not armed" unless @binding.status.fetch("guardian_healthy")
        events << "start_profile_#{profile.fetch('profile_id')}"
        handle = @admission.reserve!(
          operation_type: count.zero? ? "create" : "scale_up",
          logical_resource_id: "burst_#{index}", max_hourly_rate_delta_usd: 0.5,
          gpu_id: qualified_gpu, cloud: "SECURE"
        )
        events << "reservation_persisted"
        if fail_mode == :ambiguous
          @admission.attempt_provider_create!(handle) do
            events << "provider_create"
            raise "provider result lost"
          end
        end
        pod = @admission.attempt_provider_create!(handle) do
          events << "provider_create"
          { "id" => "#{profile.fetch('profile_id')}-pod-#{index}" }
        end
        @admission.commit!(handle, provider_resource_id: pod.fetch("id"), actual_hourly_rate_usd: 0.5)
        events << "provider_identity_committed"
        @count += 1
      end
    end

    def status
      {
        "current_workers" => count, "ready_workers" => count,
        "fleet_id" => count.positive? ? "fleet-#{profile.fetch('profile_id')}" : nil,
        "fleet_status" => count.positive? ? "active" : nil,
        "worker_readiness" => count.positive? ? { "active" => count } : {}
      }
    end

    private

    def qualified_gpu
      case profile.fetch("profile_id")
      when "gemma" then "NVIDIA L40S"
      when "gptoss" then "NVIDIA A40"
      else "NVIDIA A40"
      end
    end
  end

  class Provider
    attr_reader :create_calls
    attr_accessor :fail_on_create

    def initialize
      @pods = {}
      @create_calls = 0
    end

    def list_gpu_types(cloud:, count:)
      [{
        "id" => "NVIDIA A40", "memory" => 48, cloud.downcase => true,
        "availability" => "HIGH", "price" => { cloud.downcase => 0.5 },
        "requested_count" => count
      }]
    end

    def list_pods
      Marshal.load(Marshal.dump(@pods.values))
    end

    def create_pod(body)
      @create_calls += 1
      raise "provider result lost" if create_calls == fail_on_create
      id = "runtime-pod-#{@create_calls}"
      index = Integer(body.fetch("name").match(/burst-(\d+)\z/)[1])
      @pods[id] = {
        "id" => id, "name" => body.fetch("name"), "status" => "RUNNING",
        "cloud" => body.fetch("cloud"), "gpu" => body.fetch("gpu"), "cost" => 0.5,
        "runtime" => { "ports" => [{ "private" => 22, "public" => 22_000 + index,
                                       "type" => "tcp", "ip" => "198.51.100.#{index}" }] }
      }
      { "id" => id }
    end

    def get_pod(id)
      @pods.fetch(id) { raise LocalModelEvaluation::RunpodClient::Error.new(404, "not found") }
    end

    def delete_pod(id)
      @pods.delete(id)
      { "id" => id, "status" => "TERMINATED" }
    end
  end

  class ControllerSupervisor
    attr_accessor :lifecycle
    attr_reader :events, :generation

    def initialize(events)
      @events = events
      @generation = "controller-generation-1"
      @running = false
    end

    def ensure_running!(binding:, ssh_public_key_path:, heartbeat_timeout_seconds:)
      launched = !@running
      events << "controller_start" if launched
      @running = true
      reconcile!(binding:, ssh_public_key_path:) if launched
      status(binding:).merge("heartbeat_timeout_seconds" => heartbeat_timeout_seconds)
    rescue RunpodOllamaFleet::CampaignLifecycle::Error => e
      raise RunpodOllamaFleet::CampaignControllerSupervisor::Error, e.message
    end

    def reconcile!(binding:, ssh_public_key_path:)
      binding.parent_budget.heartbeat!(source: "orchestrator")
      lifecycle.reconcile_once(ssh_public_key_path:)
    end

    def status(binding:)
      {
        "state" => (@running ? "RUNNING" : "STOPPED"),
        "generation_id" => generation,
        "pid" => Process.pid + 1,
        "binding_sha256" => binding.binding_sha256
      }
    end

    def disable!(binding:)
      events << "controller_stop"
      @running = false
      status(binding:)
    end
  end

  def setup
    @tmp = Dir.mktmpdir("campaign-lifecycle-")
    @now = Time.utc(2026, 9, 29, 12, 0, 0)
    @events = []
    hardware = RunpodOllamaFleet::ExecutionPoolHardware.new(path: HARDWARE)
    @campaign = RunpodOllamaFleet::CapacityCampaign.load(path: FIXTURE, hardware:)
    @guardian = Guardian.new(-> { @now }, @events)
    @binding = RunpodOllamaFleet::CampaignBudgetBinding.new(
      root: @tmp, repo_root: File.expand_path("..", __dir__), campaign: @campaign,
      declaration: JSON.parse(File.binread(BUDGET)), wall_clock: -> { @now },
      guardian_supervisor: @guardian
    )
    @runtimes = {}
    factory = lambda do |profile, _hardware, admission|
      id = profile.fetch("profile_id")
      runtime = (@runtimes[id] ||= Runtime.new(profile, admission, @binding, @events))
      runtime.instance_variable_set(:@admission, admission) if admission
      runtime
    end
    @controller = ControllerSupervisor.new(@events)
    @lifecycle = RunpodOllamaFleet::CampaignLifecycle.new(
      campaign: @campaign, binding: @binding, runtime_factory: factory,
      price_resolver: ->(_profile, _hardware) { 0.5 }, wall_clock: -> { @now },
      controller_supervisor: @controller
    )
    @controller.lifecycle = @lifecycle
  end

  def teardown
    FileUtils.remove_entry(@tmp) if @tmp && File.exist?(@tmp)
  end

  def test_plan_is_read_only_and_reports_exact_campaign_and_budget_intent
    result = @lifecycle.plan

    assert result.fetch("read_only")
    refute result.fetch("paid_resources_created")
    assert_equal @campaign.identity_sha256, result.dig("campaign", "identity_sha256")
    assert_equal 6, result.fetch("expected_desired_workers")
    assert_equal 3.0, result.fetch("projected_desired_hourly_rate_usd")
    assert_equal 30.0, result.dig("budget", "max_cumulative_compute_usd")
    refute File.exist?(@binding.state_path)
    assert_empty @events
  end

  def test_start_without_authorization_returns_plan_and_never_mutates
    lifecycle = RunpodOllamaFleet::CampaignLifecycle.new(
      campaign: @campaign, binding: @binding,
      runtime_factory: ->(*) { flunk "read-only start must not construct a provider runtime" },
      wall_clock: -> { @now }
    )

    result = lifecycle.start(authorize_paid: false)

    assert result.fetch("authorization_required")
    assert_nil result.fetch("projected_desired_hourly_rate_usd")
    assert result.fetch("profiles").all? { |profile| profile["projected_worker_hourly_rate_usd"].nil? }
    refute File.exist?(@binding.state_path)
    assert_empty @events
  end

  def test_authorized_start_orders_one_authority_reservation_provider_and_commit
    result = @lifecycle.start(authorize_paid: true, ssh_public_key_path: "unused")

    assert_equal "ARMED", result.fetch("budget_state")
    assert_equal 6, result.fetch("active_workers")
    assert_equal 1, @events.count("guardian_arm")
    assert_equal 1, @events.count("controller_start")
    first_start = @events.index("start_profile_gemma")
    assert_operator @events.index("guardian_arm"), :<, first_start
    assert_operator @events.index("reservation_persisted"), :<, @events.index("provider_create")
    assert_operator @events.index("provider_create"), :<, @events.index("provider_identity_committed")
    assert_equal({ "gemma" => 1, "gptoss" => 1, "qwen27" => 1, "qwen35" => 3 },
                 @runtimes.transform_values(&:count))
    assert_equal 1, [@binding.binding_sha256].uniq.length
  end

  def test_repeated_start_resumes_same_authority_without_resetting_deadline_or_creating
    @lifecycle.start(authorize_paid: true, ssh_public_key_path: "unused")
    deadline = @binding.status.fetch("deadline_at_utc")
    provider_calls = @events.count("provider_create")
    @now += 10

    @lifecycle.start(authorize_paid: true, ssh_public_key_path: "unused")

    assert_equal deadline, @binding.status.fetch("deadline_at_utc")
    assert_equal provider_calls, @events.count("provider_create")
    assert_equal 1, @events.count("controller_start")
  end

  def test_partial_start_retains_same_durable_authority
    @runtimes["gptoss"] = Runtime.new(
      @campaign.profiles.find { |p| p.fetch("profile_id") == "gptoss" }, nil, @binding, @events
    ).tap { |runtime| runtime.fail_mode = :before_reservation }

    error = assert_raises(RunpodOllamaFleet::CampaignLifecycle::Error) do
      @lifecycle.start(authorize_paid: true, ssh_public_key_path: "unused")
    end
    assert_includes error.message, "campaign reconciliation failed"
    assert_equal "ARMED", @binding.status.fetch("phase")
    assert_equal 1, @binding.status.dig("authority", "committed_workers")
  end

  def test_ambiguous_provider_result_remains_pending
    @runtimes["gemma"] = Runtime.new(
      @campaign.profiles.find { |p| p.fetch("profile_id") == "gemma" }, nil, @binding, @events
    ).tap { |runtime| runtime.fail_mode = :ambiguous }

    assert_raises(RunpodOllamaFleet::CampaignLifecycle::Error) do
      @lifecycle.start(authorize_paid: true, ssh_public_key_path: "unused")
    end
    pending = @binding.parent_budget.status.fetch("reservations").values.select { |r| r["status"] == "pending" }
    assert_equal 1, pending.length
    assert_equal "gemma", pending.first.fetch("fleet_key")

    @runtimes.fetch("gemma").fail_mode = nil
    @lifecycle.start(authorize_paid: true, ssh_public_key_path: "unused")
    assert_equal 1, @events.count("start_profile_gemma"),
                 "retained pending liability must prevent a duplicate create"
  end

  def test_status_exposes_guardian_limits_capacity_and_pending_liability
    @binding.arm!
    admission = RunpodOllamaFleet::CampaignCapacityAdmission.new(binding: @binding, profile_id: "qwen35")
    admission.reserve!(operation_type: "create", logical_resource_id: "burst_1",
                       max_hourly_rate_delta_usd: 0.5, gpu_id: "NVIDIA A40", cloud: "SECURE")

    result = @lifecycle.status

    assert result.fetch("read_only")
    assert result.fetch("guardian_healthy")
    assert_equal 1, result.fetch("pending_workers")
    assert_equal 0.5, result.fetch("active_plus_pending_hourly_rate_usd")
    assert_equal 6, result.fetch("max_workers")
    assert_equal 6.0, result.fetch("max_aggregate_hourly_rate_usd")
    assert_equal 1, result.fetch("pending_ambiguous_reservations").length
    assert_equal 4, result.fetch("profiles").length
  end

  def test_desired_update_to_zero_is_control_plane_only
    campaign_identity = @campaign.identity_sha256
    binding_sha = @binding.binding_sha256

    result = @lifecycle.set_desired(
      profile_counts: { "qwen35" => 0 }, expected_revision: 0, reason: "hold qwen35"
    )

    assert result.fetch("updated")
    assert_equal 0, result.fetch("provider_mutations")
    assert result.fetch("actual_capacity_unchanged")
    assert_equal campaign_identity, result.dig("campaign", "identity_sha256")
    assert_equal binding_sha, result.fetch("binding_sha256")
    assert_equal 0, result.fetch("profiles").find { |row| row["profile_id"] == "qwen35" }
                                               .fetch("desired_workers")
    refute File.exist?(@binding.state_path)
    assert_empty @events
    assert_empty @runtimes
  end

  def test_zero_to_positive_reuses_original_budget_and_deadline
    @lifecycle.set_desired(
      profile_counts: { "qwen35" => 0, "qwen27" => 0, "gemma" => 0, "gptoss" => 0 },
      expected_revision: 0,
      reason: "arm without capacity"
    )
    first = @lifecycle.start(authorize_paid: true, ssh_public_key_path: "unused")
    identity = first.dig("campaign", "identity_sha256")
    binding_sha = first.fetch("binding_sha256")
    budget_id = @binding.declaration.fetch("budget_id")
    armed_at = first.fetch("armed_at_utc")
    deadline = first.fetch("deadline_at_utc")
    assert_equal 0, @events.count("provider_create")

    @now += 10
    update = @lifecycle.set_desired(
      profile_counts: { "qwen35" => 1 }, expected_revision: 1, reason: "add qwen35"
    )
    assert_equal 0, update.fetch("provider_mutations")
    assert_equal 0, @events.count("provider_create")
    reconciliation = @controller.reconcile!(binding: @binding, ssh_public_key_path: "unused")
    assert_equal 2, reconciliation.dig("desired_capacity", "revision")
    assert_equal 1, @events.count("provider_create")
    second = @lifecycle.start(authorize_paid: true, ssh_public_key_path: "unused")

    assert_equal 1, @events.count("provider_create")
    assert_equal identity, second.dig("campaign", "identity_sha256")
    assert_equal binding_sha, second.fetch("binding_sha256")
    assert_equal budget_id, @binding.declaration.fetch("budget_id")
    assert_equal armed_at, second.fetch("armed_at_utc")
    assert_equal deadline, second.fetch("deadline_at_utc")
  end

  def test_positive_to_zero_does_not_remove_existing_provider_capacity
    first = @lifecycle.start(authorize_paid: true, ssh_public_key_path: "unused")
    provider_calls = @events.count("provider_create")
    deadline = first.fetch("deadline_at_utc")

    @lifecycle.set_desired(
      profile_counts: { "qwen35" => 0 }, expected_revision: 0, reason: "drain later"
    )
    second = @lifecycle.start(authorize_paid: true, ssh_public_key_path: "unused")

    assert_equal provider_calls, @events.count("provider_create")
    assert_equal 3, @runtimes.fetch("qwen35").count
    assert_equal 0, second.fetch("profiles").find { |row| row["profile_id"] == "qwen35" }
                                      .fetch("desired_workers")
    assert_equal deadline, second.fetch("deadline_at_utc")
  end

  def test_desired_update_preserves_pending_liability_and_accrued_compute
    @binding.arm!
    admission = RunpodOllamaFleet::CampaignCapacityAdmission.new(binding: @binding, profile_id: "qwen35")
    admission.reserve!(operation_type: "replace", logical_resource_id: "burst_1",
                       max_hourly_rate_delta_usd: 0.75, gpu_id: "NVIDIA A40", cloud: "SECURE")
    before = @binding.parent_budget.status

    @lifecycle.set_desired(
      profile_counts: { "qwen35" => 0 }, expected_revision: 0, reason: "do not add"
    )
    after = @binding.parent_budget.status

    assert_equal before.fetch("reservations"), after.fetch("reservations")
    assert_equal before.fetch("accrued_compute_usd"), after.fetch("accrued_compute_usd")
    assert_equal before.fetch("committed_maximum_liability_usd"),
                 after.fetch("committed_maximum_liability_usd")
  end

  def test_expired_deadline_allows_desired_state_but_blocks_paid_increase
    @binding.arm!
    original = @binding.inspect_authority
    @now = Time.parse(original.fetch("deadline_at_utc")) + 1

    update = @lifecycle.set_desired(
      profile_counts: { "qwen35" => 1 }, expected_revision: 0, reason: "record intent only"
    )
    assert_equal 1, update.dig("desired_capacity", "revision")
    assert_equal 0, update.fetch("provider_mutations")
    error = assert_raises(RunpodOllamaFleet::CampaignLifecycle::Error) do
      @lifecycle.start(authorize_paid: true, ssh_public_key_path: "unused")
    end

    assert_match(/deadline|TEARDOWN_REQUIRED/, error.message)
    assert_equal original.fetch("armed_at_utc"), @binding.inspect_authority.fetch("armed_at_utc")
    assert_equal original.fetch("deadline_at_utc"), @binding.inspect_authority.fetch("deadline_at_utc")
    assert_empty @events.grep("provider_create")
  end

  def test_stop_is_idempotent_and_does_not_claim_absence
    @binding.arm!
    first = @lifecycle.stop
    second = @lifecycle.stop

    assert_equal "TEARDOWN_REQUIRED", first.fetch("budget_state")
    refute first.fetch("provider_absence_verified")
    assert_equal first.fetch("budget_state"), second.fetch("budget_state")
    assert_includes first.fetch("message"), "not complete"
    assert_equal "STOPPED", first.dig("controller", "state")
  end

  def test_teardown_request_blocks_late_controller_reconciliation
    @lifecycle.start(authorize_paid: true, ssh_public_key_path: "unused")
    creates = @events.count("provider_create")
    @lifecycle.stop

    assert_raises(RunpodOllamaFleet::CampaignLifecycle::Error) do
      @lifecycle.reconcile_once(ssh_public_key_path: "unused")
    end
    assert_equal creates, @events.count("provider_create")
  end

  def test_closed_campaign_cannot_restart
    @binding.arm!
    @binding.parent_budget.begin_teardown!(reason: "test")
    @binding.parent_budget.mark_teardown_in_progress!
    @binding.parent_budget.mark_provider_absence_verified!
    @binding.parent_budget.close!

    error = assert_raises(RunpodOllamaFleet::CampaignLifecycle::Error) do
      @lifecycle.start(authorize_paid: true, ssh_public_key_path: "unused")
    end
    assert_includes error.message, "closed"
  end

  def test_runpod_runtime_uses_admitted_fleet_create_then_lifecycle_scale
    @binding.arm!
    profile = @campaign.profiles.find { |row| row.fetch("profile_id") == "qwen35" }
    hardware = @campaign.hardware_bindings.find { |row| row.fetch("profile_id") == "qwen35" }
    provider = Provider.new
    admission = RunpodOllamaFleet::CampaignCapacityAdmission.new(binding: @binding, profile_id: "qwen35")
    runtime = RunpodOllamaFleet::CampaignRunpodRuntime.new(
      root: @tmp, repo_root: @tmp, profile:, hardware:, client: provider,
      admission:, out: StringIO.new, wall_clock: -> { @now }
    )
    key_path = File.join(@tmp, "campaign.pub")
    File.write(key_path, "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIEexamplecampaignkey operator@example\n")

    runtime.ensure_workers!(
      desired_workers: 1, ssh_public_key_path: key_path,
      original_deadline_at_utc: @binding.status.fetch("deadline_at_utc"),
      max_hourly_rate_usd: 6.0
    )
    runtime.ensure_workers!(
      desired_workers: 2, ssh_public_key_path: key_path,
      original_deadline_at_utc: @binding.status.fetch("deadline_at_utc"),
      max_hourly_rate_usd: 6.0
    )

    assert_equal 2, runtime.current_worker_count
    assert_equal 2, provider.create_calls
    assert_equal 2, @binding.status.dig("authority", "committed_workers")
    assert_equal 2, runtime.status.fetch("ready_workers")
  end

  def test_initial_campaign_rollback_releases_only_verified_absent_created_worker
    profile = @campaign.profiles.find { |row| row.fetch("profile_id") == "qwen35" }
    hardware = @campaign.hardware_bindings.find { |row| row.fetch("profile_id") == "qwen35" }
    provider = Provider.new.tap { |fake| fake.fail_on_create = 2 }
    @binding.arm!
    admission = RunpodOllamaFleet::CampaignCapacityAdmission.new(binding: @binding, profile_id: "qwen35")
    runtime = RunpodOllamaFleet::CampaignRunpodRuntime.new(
      root: @tmp, repo_root: @tmp, profile:, hardware:, client: provider,
      admission:, out: StringIO.new, wall_clock: -> { @now }
    )
    key_path = File.join(@tmp, "rollback.pub")
    File.write(key_path, "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIEcampaignrollbackkey operator@example\n")

    assert_raises(RuntimeError) do
      runtime.ensure_workers!(desired_workers: 2, ssh_public_key_path: key_path,
                              original_deadline_at_utc: @binding.status.fetch("deadline_at_utc"),
                              max_hourly_rate_usd: 6.0)
    end
    rows = @binding.parent_budget.status.fetch("reservations").values.sort_by { |row| row["logical_resource_id"] }
    assert_equal %w[released pending], rows.map { |row| row.fetch("status") }
    assert_equal 0, runtime.current_worker_count
  end

  def test_scale_rollback_verifies_created_overlap_absent_and_keeps_ambiguous_reservation
    profile = @campaign.profiles.find { |row| row.fetch("profile_id") == "qwen35" }
    hardware = @campaign.hardware_bindings.find { |row| row.fetch("profile_id") == "qwen35" }
    provider = Provider.new
    @binding.arm!
    admission = RunpodOllamaFleet::CampaignCapacityAdmission.new(binding: @binding, profile_id: "qwen35")
    runtime = RunpodOllamaFleet::CampaignRunpodRuntime.new(
      root: @tmp, repo_root: @tmp, profile:, hardware:, client: provider,
      admission:, out: StringIO.new, wall_clock: -> { @now }
    )
    key_path = File.join(@tmp, "scale-rollback.pub")
    File.write(key_path, "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIEcampaignscalekey operator@example\n")
    runtime.ensure_workers!(desired_workers: 1, ssh_public_key_path: key_path,
                            original_deadline_at_utc: @binding.status.fetch("deadline_at_utc"),
                            max_hourly_rate_usd: 6.0)
    provider.fail_on_create = 3

    assert_raises(RunpodOllamaFleet::CampaignRunpodRuntime::Error) do
      runtime.ensure_workers!(desired_workers: 3, ssh_public_key_path: key_path,
                              original_deadline_at_utc: @binding.status.fetch("deadline_at_utc"),
                              max_hourly_rate_usd: 6.0)
    end
    rows = @binding.parent_budget.status.fetch("reservations").values
    assert_equal 1, rows.count { |row| row["status"] == "committed" }
    assert_equal 1, rows.count { |row| row["status"] == "released" }
    assert_equal 1, rows.count { |row| row["status"] == "pending" }
    assert_equal 1, runtime.current_worker_count
  end

  def test_fleet_and_lifecycle_reject_incomplete_or_mismatched_campaign_admission
    incomplete = Struct.new(:profile_id).new("qwen35")
    assert_raises(LocalModelEvaluation::RunpodFleet::Error) do
      LocalModelEvaluation::RunpodFleet.new(
        client: Provider.new, env_path: File.join(@tmp, "bad.env"), state_root: @tmp,
        fleet_key: "qwen35", capacity_admission: incomplete
      )
    end
    mismatch = Object.new
    %i[authority_identity assert_matches! reserve! attempt_provider_create! commit!
       provider_absence_verified! mark_resource_absent!].each do |name|
      mismatch.define_singleton_method(name) { |**| nil }
    end
    mismatch.define_singleton_method(:profile_id) { "gemma" }
    state = LocalModelEvaluation::RunpodFleetState.new(root: File.join(@tmp, "mismatch"))
    assert_raises(LocalModelEvaluation::RunpodFleetLifecycle::Error) do
      LocalModelEvaluation::RunpodFleetLifecycle.new(
        client: Provider.new, fleet_state: state, env_path: File.join(@tmp, "mismatch.env"),
        fleet_key: "qwen35", local_port_base: 20_000, capacity_admission: mismatch
      )
    end
  end

  def test_lifecycle_campaign_failure_seams_fail_closed
    state = LocalModelEvaluation::RunpodFleetState.new(root: File.join(@tmp, "failure-seams"))
    incomplete = Struct.new(:profile_id).new("qwen35")
    assert_raises(LocalModelEvaluation::RunpodFleetLifecycle::Error) do
      LocalModelEvaluation::RunpodFleetLifecycle.new(
        client: Provider.new, fleet_state: state, env_path: File.join(@tmp, "failure.env"),
        fleet_key: "qwen35", local_port_base: 20_100, capacity_admission: incomplete
      )
    end

    out = StringIO.new
    lifecycle = LocalModelEvaluation::RunpodFleetLifecycle.new(
      client: Provider.new, fleet_state: state, env_path: File.join(@tmp, "failure.env"),
      fleet_key: "qwen35", local_port_base: 20_100, out:
    )
    raising = Object.new
    %i[reserve! commit! provider_absence_verified! mark_resource_absent!].each do |name|
      raising.define_singleton_method(name) { |**| raise "#{name} blocked" }
    end
    lifecycle.instance_variable_set(:@capacity_admission, raising)
    assert_raises(LocalModelEvaluation::RunpodFleetLifecycle::Error) do
      lifecycle.send(:require_matching_campaign_admission!, {})
    end
    assert_raises(LocalModelEvaluation::RunpodFleetLifecycle::Error) do
      lifecycle.send(:reserve_campaign_capacity, operation_type: "scale_up")
    end
    assert_raises(LocalModelEvaluation::RunpodFleetLifecycle::Error) do
      lifecycle.send(:commit_campaign_capacity, Object.new,
                     provider_resource_id: "pod", actual_hourly_rate_usd: 0.5)
    end
    lifecycle.send(:record_campaign_absence, Object.new, provider_resource_id: "pod", reason: "test")
    assert_includes out.string, "could not release campaign liability"
    assert_raises(LocalModelEvaluation::RunpodFleetLifecycle::Error) do
      lifecycle.send(:mark_campaign_resource_absent!, "pod")
    end
  end
end
