# frozen_string_literal: true

require_relative "test_helper"
require "json"
require "stringio"
require_relative "../lib/runpod_ollama_fleet"
require_relative "../lib/local_model_evaluation/runpod_fleet"
require_relative "../lib/local_model_evaluation/runpod_fleet_lifecycle"

class CampaignCapacityAdmissionTest < Minitest::Test
  FIXTURE = File.expand_path("fixtures/rpof-capacity-campaign-v0.1.json", __dir__)
  HARDWARE = File.expand_path("../config/execution_pool_hardware.yml", __dir__)

  class FakeGuardianSupervisor
    attr_accessor :healthy

    def initialize(clock)
      @clock = clock
      @healthy = true
      @armed = false
    end

    def arm!(budget:, request:)
      result = budget.arm!(budget: request, guardian_heartbeat_at_utc: @clock.call)
      @armed = true
      result
    end

    def status(budget:)
      {
        "budget_id" => budget.budget_id,
        "plan_sha256" => budget.plan_sha256,
        "enabled" => healthy,
        "launchd_loaded" => healthy,
        "ready" => healthy,
        "pid" => Process.pid + 10_000,
        "provider_probe_at_utc" => @clock.call.iso8601,
        "ledger_heartbeat_at_utc" => @clock.call.iso8601,
        "state" => (@armed ? budget.status.fetch("state") : "WAITING_FOR_ARM"),
        "last_error" => nil
      }
    end
  end

  class FakeProvider
    attr_accessor :actual_rate, :create_error
    attr_reader :events, :created_bodies, :deleted_ids

    def initialize(events)
      @events = events
      @pods = {}
      @created_bodies = []
      @deleted_ids = []
      @sequence = 0
      @actual_rate = 0.5
      @create_error = nil
    end

    def list_gpu_types(cloud:, count:)
      [{
        "id" => "NVIDIA A40",
        "name" => "A40",
        "memory" => 48,
        cloud.downcase => true,
        "availability" => "HIGH",
        "price" => { cloud.downcase => 0.5 }
      }]
    end

    def list_pods
      @pods.values.map { |pod| Marshal.load(Marshal.dump(pod)) }
    end

    def create_pod(body)
      @events << ["provider_create", body.fetch("name")]
      @created_bodies << Marshal.load(Marshal.dump(body))
      raise create_error if create_error

      @sequence += 1
      id = "pod-#{@sequence}"
      index = Integer(body.fetch("name").match(/burst-(\d+)\z/)[1])
      @pods[id] = {
        "id" => id,
        "name" => body.fetch("name"),
        "status" => "RUNNING",
        "cloud" => body.fetch("cloud"),
        "gpu" => body.fetch("gpu"),
        "cost" => actual_rate,
        "runtime" => {
          "ports" => [{
            "private" => 22,
            "public" => 22_000 + index,
            "type" => "tcp",
            "ip" => "198.51.100.#{10 + index}"
          }]
        }
      }
      { "id" => id }
    end

    def get_pod(id)
      @pods.fetch(id) do
        raise LocalModelEvaluation::RunpodClient::Error.new(404, "not found")
      end
    end

    def delete_pod(id)
      @events << ["provider_delete", id]
      @deleted_ids << id
      @pods.delete(id)
      { "id" => id, "status" => "TERMINATED" }
    end
  end

  def setup
    @tmp = Dir.mktmpdir("campaign-capacity-admission-")
    @now = Time.utc(2026, 9, 29, 12, 0, 0)
    hardware = RunpodOllamaFleet::ExecutionPoolHardware.new(path: HARDWARE)
    @campaign = RunpodOllamaFleet::CapacityCampaign.new(File.binread(FIXTURE), hardware:)
    @supervisor = FakeGuardianSupervisor.new(-> { @now })
    @binding = build_binding
    @binding.arm!
  end

  def teardown
    FileUtils.remove_entry(@tmp) if @tmp && File.exist?(@tmp)
  end

  def test_six_workers_are_admitted_across_profiles_and_seventh_is_rejected
    reservations = []
    3.times do |index|
      reservations << reserve("qwen35", "burst_#{index + 1}", rate: 0.5)
    end
    %w[qwen27 gemma gptoss].each do |profile|
      reservations << reserve(profile, "burst_1", rate: 0.5)
    end

    status = @binding.status
    assert_equal 6, status.dig("authority", "committed_workers")
    assert_equal 3.0, status.dig("authority", "committed_hourly_rate_usd")
    assert_equal(
      { "gemma" => 1, "gptoss" => 1, "qwen27" => 1, "qwen35" => 3 },
      status.dig("authority", "committed_workers_by_profile")
    )
    assert_equal 6, reservations.length

    called = false
    error = assert_raises(RunpodOllamaFleet::CampaignCapacityAdmission::Error) do
      handle = admission("gemma").reserve!(
        operation_type: "scale_up",
        logical_resource_id: "burst_2",
        max_hourly_rate_delta_usd: 0.5,
        gpu_id: "NVIDIA L40S",
        cloud: "SECURE"
      )
      admission("gemma").attempt_provider_create!(handle) { called = true }
    end
    assert_includes error.message, "campaign worker ceiling"
    refute called
    assert_equal 6, pending_reservations.length
  end

  def test_pending_reservations_span_profiles_for_aggregate_rate_and_profile_limits
    reserve("qwen35", "burst_1", rate: 3.0)
    reserve("qwen27", "burst_1", rate: 3.0)

    error = assert_raises(RunpodOllamaFleet::CampaignCapacityAdmission::Error) do
      reserve("gemma", "burst_1", rate: 0.01)
    end
    assert_includes error.message, "aggregate hourly ceiling"
    assert_equal 2, pending_reservations.length
    assert_equal 6.0, @binding.status.dig("authority", "committed_hourly_rate_usd")

    isolated = build_binding(root: File.join(@tmp, "profile"),
                             supervisor: FakeGuardianSupervisor.new(-> { @now }))
    isolated.arm!
    first = admission("qwen27", binding: isolated)
    first.reserve!(operation_type: "create", logical_resource_id: "burst_1",
                   max_hourly_rate_delta_usd: 0.5, gpu_id: "NVIDIA A40", cloud: "SECURE")
    error = assert_raises(RunpodOllamaFleet::CampaignCapacityAdmission::Error) do
      first.reserve!(operation_type: "scale_up", logical_resource_id: "burst_2",
                     max_hourly_rate_delta_usd: 0.5, gpu_id: "NVIDIA A40", cloud: "SECURE")
    end
    assert_includes error.message, "profile \"qwen27\" worker ceiling"
    assert_equal 1, isolated.status.dig("authority", "committed_workers")
  end

  def test_replacement_overlap_counts_until_old_resource_is_verified_absent
    authority = admission("qwen27")
    original = authority.reserve!(operation_type: "create", logical_resource_id: "burst_1",
                                  max_hourly_rate_delta_usd: 0.5,
                                  gpu_id: "NVIDIA A40", cloud: "SECURE")
    authority.attempt_provider_create!(original) { { "id" => "old-pod" } }
    authority.commit!(original, provider_resource_id: "old-pod", actual_hourly_rate_usd: 0.5)

    error = assert_raises(RunpodOllamaFleet::CampaignCapacityAdmission::Error) do
      authority.reserve!(operation_type: "replace", logical_resource_id: "burst_1",
                         max_hourly_rate_delta_usd: 0.5,
                         gpu_id: "NVIDIA A40", cloud: "SECURE")
    end
    assert_includes error.message, "profile \"qwen27\" worker ceiling"
    assert_equal "active", ledger.dig("owned_resources", "old-pod", "status")

    authority.mark_resource_absent!(provider_resource_id: "old-pod")
    replacement = authority.reserve!(operation_type: "replace", logical_resource_id: "burst_1",
                                     max_hourly_rate_delta_usd: 0.5,
                                     gpu_id: "NVIDIA A40", cloud: "SECURE")
    assert_equal "pending", ledger.dig("reservations", replacement.reservation_id, "status")
  end

  def test_reservation_provider_commit_order_and_crash_boundaries_are_durable
    events = []
    authority = admission("qwen35", events:)
    handle = authority.reserve!(operation_type: "create", logical_resource_id: "burst_1",
                                max_hourly_rate_delta_usd: 0.5,
                                gpu_id: "NVIDIA A40", cloud: "SECURE")
    assert_equal "pending", ledger.dig("reservations", handle.reservation_id, "status")
    assert_equal "reservation_persisted", events.fetch(0).fetch(0)

    result = authority.attempt_provider_create!(handle) do
      assert_equal "pending", ledger.dig("reservations", handle.reservation_id, "status")
      events << ["provider_create", {}]
      { "id" => "pod-1" }
    end
    assert_equal "pod-1", result.fetch("id")
    assert_equal "pending", ledger.dig("reservations", handle.reservation_id, "status")
    assert_finite_liability

    authority.commit!(handle, provider_resource_id: "pod-1", actual_hourly_rate_usd: 0.5)
    assert_equal "committed", ledger.dig("reservations", handle.reservation_id, "status")
    assert_equal "active", ledger.dig("owned_resources", "pod-1", "status")
    assert_equal(
      %w[reservation_persisted provider_create_invoked provider_create provider_identity_committed],
      events.map(&:first)
    )

    not_attempted = authority.reserve!(operation_type: "scale_up", logical_resource_id: "burst_2",
                                       max_hourly_rate_delta_usd: 0.5,
                                       gpu_id: "NVIDIA A40", cloud: "SECURE")
    authority.release_not_attempted!(not_attempted, reason: "validation failed before provider call")
    assert_equal "released", ledger.dig("reservations", not_attempted.reservation_id, "status")

    ambiguous = authority.reserve!(operation_type: "scale_up", logical_resource_id: "burst_2",
                                   max_hourly_rate_delta_usd: 0.5,
                                   gpu_id: "NVIDIA A40", cloud: "SECURE")
    assert_raises(RuntimeError) do
      authority.attempt_provider_create!(ambiguous) { raise "provider result lost" }
    end
    assert_equal "pending", ledger.dig("reservations", ambiguous.reservation_id, "status")
    assert_finite_liability
  end

  def test_actual_rate_above_reservation_retains_identity_and_requires_teardown
    authority = admission("qwen35")
    handle = authority.reserve!(operation_type: "create", logical_resource_id: "burst_1",
                                max_hourly_rate_delta_usd: 0.5,
                                gpu_id: "NVIDIA A40", cloud: "SECURE")
    authority.attempt_provider_create!(handle) { { "id" => "expensive-pod" } }

    error = assert_raises(RunpodOllamaFleet::CampaignCapacityAdmission::Error) do
      authority.commit!(handle, provider_resource_id: "expensive-pod", actual_hourly_rate_usd: 0.75)
    end
    assert_includes error.message, "exceeds reserved maximum"
    assert_equal "TEARDOWN_REQUIRED", ledger.fetch("state")
    assert_equal "provider_rate_exceeded_reservation", ledger.fetch("teardown_reason")
    assert_equal "committed", ledger.dig("reservations", handle.reservation_id, "status")
    assert_equal "active", ledger.dig("owned_resources", "expensive-pod", "status")

    authority.provider_absence_verified!(
      handle,
      provider_resource_id: "expensive-pod",
      reason: "rollback verified provider absence"
    )
    assert_equal "absent", ledger.dig("owned_resources", "expensive-pod", "status")
    assert_equal "TEARDOWN_REQUIRED", ledger.fetch("state")
  end

  def test_authority_failures_never_reach_provider_and_preserve_original_deadline
    authority = admission("qwen35")
    original_deadline = @binding.status.fetch("deadline_at_utc")
    @supervisor.healthy = false
    called = false
    error = assert_raises(RunpodOllamaFleet::CampaignCapacityAdmission::Error) do
      handle = authority.reserve!(operation_type: "scale_up", logical_resource_id: "burst_1",
                                  max_hourly_rate_delta_usd: 0.5,
                                  gpu_id: "NVIDIA A40", cloud: "SECURE")
      authority.attempt_provider_create!(handle) { called = true }
    end
    assert_includes error.message, "guardian is not independently loaded and fresh"
    refute called
    assert_equal original_deadline, @binding.inspect_authority.fetch("deadline_at_utc")

    @supervisor.healthy = true
    @now = Time.parse(original_deadline) + 1
    error = assert_raises(RunpodOllamaFleet::CampaignCapacityAdmission::Error) do
      authority.reserve!(operation_type: "replace", logical_resource_id: "burst_1",
                         max_hourly_rate_delta_usd: 0.5,
                         gpu_id: "NVIDIA A40", cloud: "SECURE")
    end
    assert_includes error.message, "TEARDOWN_REQUIRED"
    refute called
    assert_equal original_deadline, @binding.inspect_authority.fetch("deadline_at_utc")
  end

  def test_cumulative_cap_blocks_mutation_with_worker_and_rate_room
    constrained = build_binding(
      root: File.join(@tmp, "cumulative"),
      supervisor: FakeGuardianSupervisor.new(-> { @now }),
      cumulative_cap: 0.01
    )
    constrained.arm!
    called = false
    authority = admission("qwen35", binding: constrained)

    error = assert_raises(RunpodOllamaFleet::CampaignCapacityAdmission::Error) do
      handle = authority.reserve!(operation_type: "create", logical_resource_id: "burst_1",
                                  max_hourly_rate_delta_usd: 1.0,
                                  gpu_id: "NVIDIA A40", cloud: "SECURE")
      authority.attempt_provider_create!(handle) { called = true }
    end
    assert_includes error.message, "remaining cumulative authority"
    refute called
    assert_equal 0, constrained.status.dig("authority", "committed_workers")
    assert_equal 0.0, constrained.status.dig("authority", "committed_hourly_rate_usd")
  end

  def test_qualification_and_binding_identity_fail_closed_before_provider_call
    authority = admission("gemma")
    error = assert_raises(RunpodOllamaFleet::CampaignCapacityAdmission::Error) do
      authority.reserve!(operation_type: "create", logical_resource_id: "burst_1",
                         max_hourly_rate_delta_usd: 0.5,
                         gpu_id: "NVIDIA A40", cloud: "SECURE")
    end
    assert_includes error.message, "not qualified"
    assert_empty pending_reservations

    changed = authority.authority_identity.merge("budget_id" => "other-budget")
    error = assert_raises(RunpodOllamaFleet::CampaignCapacityAdmission::Error) do
      authority.assert_matches!(changed)
    end
    assert_includes error.message, "does not match"
  end

  def test_initial_scale_and_replace_all_use_same_parent_admission
    events = []
    provider = FakeProvider.new(events)
    authority = admission("qwen35", events:)
    state_root = File.join(@tmp, "fleet-state")
    env_path = File.join(@tmp, "qwen35.env")
    File.write(env_path, "RUNPOD_API_KEY=fake-only\n")
    fleet = LocalModelEvaluation::RunpodFleet.new(
      client: provider,
      env_path:,
      state_root:,
      fleet_key: "qwen35",
      local_port_base: 12_000,
      out: StringIO.new,
      sleeper: ->(_seconds) {},
      clock: -> { 0.0 },
      wall_clock: -> { @now },
      capacity_admission: authority
    )
    preflight = fleet.preflight(worker_count: 1, max_fleet_hourly_usd: 1.0)
    fleet.create(worker_count: 1, ssh_public_key: public_key, preflight:,
                 max_fleet_hourly_usd: 1.0)

    assert_equal authority.authority_identity, fleet.fleet_state.current.fetch("campaign_authority")
    assert_ordered_mutation(events)
    first_pod = fleet.fleet_state.current.fetch("workers").first.fetch("pod_id")

    lifecycle = LocalModelEvaluation::RunpodFleetLifecycle.new(
      client: provider,
      fleet_state: fleet.fleet_state,
      env_path:,
      fleet_key: "qwen35",
      local_port_base: 12_000,
      out: StringIO.new,
      sleeper: ->(_seconds) {},
      monotonic_clock: -> { 0.0 },
      wall_clock: -> { @now },
      capacity_admission: authority
    )
    events.clear
    scale = lifecycle.preflight_scale(target_worker_count: 2, max_fleet_hourly_usd: 2.0)
    lifecycle.scale(target_worker_count: 2, ssh_public_key: public_key,
                    preflight: scale, max_fleet_hourly_usd: 2.0)
    assert_ordered_mutation(events)
    assert_equal "scale_up", ledger.fetch("reservations").values.last.fetch("operation_type")

    events.clear
    replace = lifecycle.preflight_replace(worker_index: 1, max_fleet_hourly_usd: 2.0)
    lifecycle.replace(worker_index: 1, ssh_public_key: public_key,
                      preflight: replace, max_fleet_hourly_usd: 2.0)
    assert_equal "absent", ledger.dig("owned_resources", first_pod, "status")
    assert_equal "replace", ledger.fetch("reservations").values.last.fetch("operation_type")
    delete_index = events.index { |event| event.first == "provider_delete" }
    reserve_index = events.index { |event| event.first == "reservation_persisted" }
    create_index = events.index { |event| event.first == "provider_create" }
    commit_index = events.index { |event| event.first == "provider_identity_committed" }
    assert_operator delete_index, :<, reserve_index
    assert_operator reserve_index, :<, create_index
    assert_operator create_index, :<, commit_index
  end

  def test_campaign_owned_scale_fails_closed_without_matching_admission
    events = []
    provider = FakeProvider.new(events)
    authority = admission("qwen35", events:)
    state_root = File.join(@tmp, "blocked-state")
    env_path = File.join(@tmp, "blocked.env")
    File.write(env_path, "RUNPOD_API_KEY=fake-only\n")
    fleet = LocalModelEvaluation::RunpodFleet.new(
      client: provider, env_path:, state_root:, fleet_key: "qwen35",
      local_port_base: 13_000, out: StringIO.new, sleeper: ->(_seconds) {},
      clock: -> { 0.0 }, wall_clock: -> { @now }, capacity_admission: authority
    )
    preflight = fleet.preflight(worker_count: 1, max_fleet_hourly_usd: 1.0)
    fleet.create(worker_count: 1, ssh_public_key: public_key, preflight:,
                 max_fleet_hourly_usd: 1.0)

    lifecycle = LocalModelEvaluation::RunpodFleetLifecycle.new(
      client: provider, fleet_state: fleet.fleet_state, env_path:, fleet_key: "qwen35",
      local_port_base: 13_000, out: StringIO.new, sleeper: ->(_seconds) {},
      monotonic_clock: -> { 0.0 }, wall_clock: -> { @now }
    )
    scale = lifecycle.preflight_scale(target_worker_count: 2, max_fleet_hourly_usd: 2.0)
    create_count = provider.created_bodies.length
    error = assert_raises(LocalModelEvaluation::RunpodFleetLifecycle::Error) do
      lifecycle.scale(target_worker_count: 2, ssh_public_key: public_key,
                      preflight: scale, max_fleet_hourly_usd: 2.0)
    end
    assert_includes error.message, "requires its matching parent campaign authority"
    assert_equal create_count, provider.created_bodies.length
  end

  def test_campaign_admission_requires_matching_fleet_namespace
    authority = admission("qwen35")
    error = assert_raises(LocalModelEvaluation::RunpodFleet::Error) do
      LocalModelEvaluation::RunpodFleet.new(
        client: FakeProvider.new([]), env_path: File.join(@tmp, "mismatch.env"),
        state_root: File.join(@tmp, "mismatch-state"), fleet_key: "wrong-profile",
        capacity_admission: authority
      )
    end
    assert_includes error.message, "must use matching fleet namespace"
  end

  private

  def build_binding(root: @tmp, supervisor: @supervisor, cumulative_cap: 30.0)
    RunpodOllamaFleet::CampaignBudgetBinding.new(
      root:,
      repo_root: File.expand_path("..", __dir__),
      campaign: @campaign,
      declaration: {
        "contract_version" => "rpof-capacity-campaign-budget/v0.1",
        "campaign_identity" => @campaign.identity,
        "campaign_identity_sha256" => @campaign.identity_sha256,
        "budget_id" => "batch039-parent",
        "max_cumulative_compute_usd" => cumulative_cap,
        "max_aggregate_hourly_rate_usd" => @campaign.max_hourly_rate_usd,
        "max_workers" => @campaign.max_workers,
        "max_runtime_seconds" => 5400.0,
        "guardian_poll_seconds" => 5.0,
        "orchestrator_heartbeat_timeout_seconds" => 30.0,
        "teardown_reserve_seconds" => 120.0
      },
      wall_clock: -> { @now },
      guardian_supervisor: supervisor
    )
  end

  def admission(profile_id, binding: @binding, events: nil)
    sink = events && lambda do |event, detail|
      events << [event, detail]
    end
    RunpodOllamaFleet::CampaignCapacityAdmission.new(
      binding:,
      profile_id:,
      event_sink: sink
    )
  end

  def reserve(profile, logical, rate:)
    hardware = @campaign.hardware_bindings.find { |row| row.fetch("profile_id") == profile }
    admission(profile).reserve!(
      operation_type: "scale_up",
      logical_resource_id: logical,
      max_hourly_rate_delta_usd: rate,
      gpu_id: hardware.fetch("qualified_gpu_ids").first,
      cloud: hardware.fetch("cloud")
    )
  end

  def ledger
    @binding.parent_budget.status
  end

  def pending_reservations
    ledger.fetch("reservations").values.select { |row| row.fetch("status") == "pending" }
  end

  def assert_finite_liability
    status = @binding.status.fetch("authority")
    assert status.fetch("maximum_additional_compute_liability_usd").finite?
    assert status.fetch("committed_maximum_liability_usd").finite?
    assert_operator status.fetch("committed_maximum_liability_usd"), :<=,
                    status.fetch("max_cumulative_compute_usd")
  end

  def assert_ordered_mutation(events)
    reserve_index = events.index { |event| event.first == "reservation_persisted" }
    create_index = events.index { |event| event.first == "provider_create" }
    commit_index = events.index { |event| event.first == "provider_identity_committed" }
    assert_operator reserve_index, :<, create_index
    assert_operator create_index, :<, commit_index
  end

  def public_key
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAITest campaign@example"
  end
end
