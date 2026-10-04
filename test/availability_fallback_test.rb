# frozen_string_literal: true

require_relative "test_helper"
require "json"
require "stringio"
require_relative "../lib/runpod_ollama_fleet"

class AvailabilityFallbackTest < Minitest::Test
  FIXTURE = File.expand_path("fixtures/rpof-capacity-campaign-v0.1.json", __dir__)
  BUDGET = File.expand_path("fixtures/rpof-capacity-campaign-budget-v0.1.json", __dir__)
  HARDWARE = File.expand_path("../config/execution_pool_hardware.yml", __dir__)
  A40 = "NVIDIA A40"
  BLACKWELL = "NVIDIA RTX PRO 6000 Blackwell Server Edition"

  class Guardian
    def initialize(clock)
      @clock = clock
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
        "enabled" => true,
        "launchd_loaded" => true,
        "ready" => true,
        "pid" => Process.pid + 10_000,
        "provider_probe_at_utc" => @clock.call.iso8601,
        "ledger_heartbeat_at_utc" => @clock.call.iso8601,
        "state" => (@armed ? budget.status.fetch("state") : "WAITING_FOR_ARM"),
        "last_error" => nil
      }
    end
  end

  class Provider
    attr_accessor :catalog, :behaviors, :delete_error
    attr_reader :create_bodies, :deleted_ids

    def initialize(catalog)
      @catalog = catalog
      @behaviors = {}
      @pods = {}
      @create_bodies = []
      @deleted_ids = []
      @sequence = 0
    end

    def list_gpu_types(cloud:, count:)
      raise "unexpected cloud" unless cloud == "SECURE"
      raise "invalid count" unless count.positive?

      Marshal.load(Marshal.dump(catalog))
    end

    def list_pods
      Marshal.load(Marshal.dump(@pods.values))
    end

    def create_pod(body)
      @create_bodies << Marshal.load(Marshal.dump(body))
      gpu_id = body.dig("gpu", "id")
      case behaviors[gpu_id]
      when :capacity_unavailable
        raise LocalModelEvaluation::RunpodClient::Error.new(409, "capacity unavailable for requested hardware")
      when :ambiguous
        raise "provider result lost"
      end

      @sequence += 1
      id = "pod-#{@sequence}"
      index = Integer(body.fetch("name").match(/burst-(\d+)\z/)[1])
      observed_gpu = behaviors[gpu_id] == :wrong_gpu ? "UNAUTHORIZED GPU" : gpu_id
      @pods[id] = {
        "id" => id,
        "name" => body.fetch("name"),
        "status" => "RUNNING",
        "cloud" => body.fetch("cloud"),
        "gpu" => { "id" => observed_gpu, "count" => 1 },
        "cost" => catalog.find { |row| row["id"] == gpu_id }.dig("price", "secure"),
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
      raise delete_error if delete_error

      @deleted_ids << id
      @pods.delete(id)
      { "id" => id, "status" => "TERMINATED" }
    end
  end

  class Bringup
    def reconcile!(worker:, **)
      if worker.fetch("gpu_id") == A40
        failed(worker)
      else
        passed(worker)
      end
    end

    private

    def failed(worker)
      stage = { "status" => "passed", "evidence" => {} }
      {
        "identity" => { "worker_id" => worker.fetch("worker_id") },
        "overall_status" => "failed_terminal",
        "readiness_prerequisites_satisfied" => false,
        "tunnel" => stage.dup,
        "bootstrap" => stage.dup,
        "capability" => {
          "status" => "failed_terminal",
          "error" => "capability evidence digest does not match exact capability request",
          "evidence" => nil
        }
      }
    end

    def passed(worker)
      stage = { "status" => "passed", "evidence" => {} }
      {
        "identity" => { "worker_id" => worker.fetch("worker_id") },
        "overall_status" => "prerequisites_passed",
        "readiness_prerequisites_satisfied" => true,
        "tunnel" => stage.dup,
        "bootstrap" => stage.dup,
        "capability" => stage.dup
      }
    end
  end

  class PassingBringup
    def reconcile!(worker:, **)
      stage = { "status" => "passed", "evidence" => {} }
      {
        "identity" => { "worker_id" => worker.fetch("worker_id") },
        "overall_status" => "prerequisites_passed",
        "readiness_prerequisites_satisfied" => true,
        "tunnel" => stage.dup,
        "bootstrap" => stage.dup,
        "capability" => stage.dup
      }
    end
  end

  def setup
    @tmp = Dir.mktmpdir("availability-fallback-")
    @now = Time.utc(2026, 10, 4, 12, 0, 0)
    registry = RunpodOllamaFleet::ExecutionPoolHardware.new(path: HARDWARE)
    @campaign = RunpodOllamaFleet::CapacityCampaign.load(path: FIXTURE, hardware: registry)
    @profile = @campaign.profiles.find { |row| row.fetch("profile_id") == "qwen35" }
    @hardware = @campaign.hardware_bindings.find { |row| row.fetch("profile_id") == "qwen35" }
    @binding = RunpodOllamaFleet::CampaignBudgetBinding.new(
      root: @tmp,
      repo_root: File.expand_path("..", __dir__),
      campaign: @campaign,
      declaration: JSON.parse(File.binread(BUDGET)),
      wall_clock: -> { @now },
      guardian_supervisor: Guardian.new(-> { @now })
    )
    @binding.arm!
    @deadline = @binding.status.fetch("deadline_at_utc")
    @key_path = File.join(@tmp, "test.pub")
    File.write(@key_path, "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFallbackOfflineOnly operator@example\n")
  end

  def teardown
    FileUtils.remove_entry(@tmp) if @tmp && File.exist?(@tmp)
  end

  def test_cheapest_unavailable_uses_next_authorized_candidate_in_deterministic_order
    provider = Provider.new([
      gpu(BLACKWELL, 2.09),
      gpu(A40, 0.49, availability: "NONE"),
      gpu("UNAUTHORIZED H100", 0.10)
    ])
    runtime = runtime(provider:)

    runtime.ensure_workers!(**ensure_arguments)

    assert_equal [BLACKWELL], provider.create_bodies.map { |body| body.dig("gpu", "id") }
    state = runtime.status.fetch("availability_fallback")
    assert_equal [A40, BLACKWELL], state.fetch("candidate_order")
    assert_equal %w[rejected provisioned], state.fetch("candidates").map { |row| row.fetch("status") }
    assert_equal @binding.binding_sha256, state.fetch("binding_sha256")
    assert_equal @binding.declaration.fetch("budget_id"), state.fetch("budget_id")
    assert_equal @binding.status.fetch("armed_at_utc"), state.fetch("armed_at_utc")
    assert_equal @deadline, state.fetch("original_deadline_at_utc")
    assert_equal 30.0, state.fetch("max_cumulative_compute_usd")
    assert_equal 6.0, state.fetch("max_aggregate_hourly_rate_usd")
    assert_equal 6, state.fetch("campaign_max_workers")
    assert_equal 3, state.fetch("profile_max_workers")
  end

  def test_equal_prices_use_gpu_identity_tie_break_not_provider_order
    provider = Provider.new([gpu(BLACKWELL, 0.49), gpu(A40, 0.49)])
    runtime(provider:).ensure_workers!(**ensure_arguments)

    assert_equal A40, provider.create_bodies.first.dig("gpu", "id")
  end

  def test_provider_capacity_rejection_is_proved_absent_before_next_candidate
    provider = Provider.new([gpu(BLACKWELL, 2.09), gpu(A40, 0.49)])
    provider.behaviors[A40] = :capacity_unavailable
    runtime = runtime(provider:)

    runtime.ensure_workers!(**ensure_arguments)

    assert_equal [A40, BLACKWELL], provider.create_bodies.map { |body| body.dig("gpu", "id") }
    attempts = runtime.status.dig("availability_fallback", "candidates")
    assert_equal "verified_absent", attempts.first.fetch("cleanup_status")
    assert_equal "provisioned", attempts.last.fetch("status")
    ledger = @binding.parent_budget.status
    assert_equal 1, ledger.fetch("reservations").values.count { |row| row["status"] == "released" }
    assert_equal 1, ledger.fetch("reservations").values.count { |row| row["status"] == "committed" }
  end

  def test_scale_up_capacity_rejection_uses_same_verified_absence_gate
    provider = Provider.new([gpu(BLACKWELL, 2.09), gpu(A40, 0.49)])
    runtime = runtime(provider:, bringup: PassingBringup.new)
    runtime.ensure_workers!(**ensure_arguments)
    runtime.reconcile_bringup!(desired_workers: 1, transition_guard: -> { true })
    provider.behaviors[A40] = :capacity_unavailable

    runtime.ensure_workers!(**ensure_arguments.merge(desired_workers: 2))

    assert_equal [A40, A40, BLACKWELL], provider.create_bodies.map { |body| body.dig("gpu", "id") }
    assert_equal 2, runtime.current_worker_count
    state = runtime.status.fetch("availability_fallback")
    assert_equal %w[rejected provisioned], state.fetch("candidates").map { |row| row.fetch("status") }
    assert_equal "verified_absent", state.fetch("candidates").first.fetch("cleanup_status")
  end

  def test_created_wrong_gpu_is_deleted_and_verified_absent_before_fallback
    provider = Provider.new([gpu(BLACKWELL, 2.09), gpu(A40, 0.49)])
    provider.behaviors[A40] = :wrong_gpu
    runtime = runtime(provider:)

    runtime.ensure_workers!(**ensure_arguments)

    assert_equal [A40, BLACKWELL], provider.create_bodies.map { |body| body.dig("gpu", "id") }
    assert_equal ["pod-1"], provider.deleted_ids
    first = runtime.status.dig("availability_fallback", "candidates", 0)
    assert_equal "rejected", first.fetch("status")
    assert_equal "verified_absent", first.fetch("cleanup_status")
    assert_equal 1, @binding.status.dig("authority", "committed_workers_by_profile", "qwen35")
  end

  def test_ambiguous_provider_result_blocks_and_restart_does_not_reset_series
    provider = Provider.new([gpu(A40, 0.49), gpu(BLACKWELL, 2.09)])
    provider.behaviors[A40] = :ambiguous
    first = runtime(provider:)

    error = assert_raises(RuntimeError) do
      first.ensure_workers!(**ensure_arguments)
    end
    assert_includes error.message, "provider result lost"
    assert_equal "blocked", first.status.dig("availability_fallback", "state")
    assert_equal 1, @binding.status.dig("authority", "committed_workers_by_profile", "qwen35")

    restarted = runtime(provider:)
    assert_raises(RunpodOllamaFleet::CampaignRunpodRuntime::Error) do
      restarted.ensure_workers!(**ensure_arguments)
    end
    assert_equal [A40], provider.create_bodies.map { |body| body.dig("gpu", "id") }
  end

  def test_all_candidates_unavailable_is_finite_and_performs_no_create
    provider = Provider.new([
      gpu(A40, 0.49, availability: "NONE"),
      gpu(BLACKWELL, 2.09, availability: "NONE")
    ])
    runtime = runtime(provider:)

    assert_raises(RunpodOllamaFleet::CampaignRunpodRuntime::Error) do
      runtime.ensure_workers!(**ensure_arguments)
    end
    assert_empty provider.create_bodies
    assert_equal "exhausted", runtime.status.dig("availability_fallback", "state")

    assert_raises(RunpodOllamaFleet::CampaignRunpodRuntime::Error) do
      runtime(provider:).ensure_workers!(**ensure_arguments)
    end
    assert_empty provider.create_bodies
  end

  def test_each_candidate_is_attempted_at_most_once
    provider = Provider.new([gpu(BLACKWELL, 2.09), gpu(A40, 0.49)])
    provider.behaviors[A40] = :capacity_unavailable
    provider.behaviors[BLACKWELL] = :capacity_unavailable
    runtime = runtime(provider:)

    assert_raises(RunpodOllamaFleet::CampaignRunpodRuntime::Error) do
      runtime.ensure_workers!(**ensure_arguments)
    end
    assert_equal [A40, BLACKWELL], provider.create_bodies.map { |body| body.dig("gpu", "id") }
    assert_equal "exhausted", runtime.status.dig("availability_fallback", "state")
  end

  def test_restart_refuses_to_repeat_retained_in_progress_candidate
    provider = Provider.new([gpu(A40, 0.49), gpu(BLACKWELL, 2.09)])
    first = runtime(provider:)
    fallback = first.instance_variable_get(:@availability_fallback)
    fallback.prepare!(
      from_workers: 0,
      target_workers: 1,
      original_deadline_at_utc: @deadline,
      candidates: first.send(:fallback_candidates)
    )
    fallback.next_candidate!
    fallback.mark_provider_mutation_started!

    error = assert_raises(RunpodOllamaFleet::CampaignRunpodRuntime::Error) do
      runtime(provider:).ensure_workers!(**ensure_arguments)
    end
    assert_includes error.message, "unresolved in_progress"
    assert_empty provider.create_bodies
  end

  def test_required_gpu_id_never_falls_through_to_different_authorized_hardware
    provider = Provider.new([
      gpu(A40, 0.49, availability: "NONE"),
      gpu(BLACKWELL, 2.09)
    ])
    runtime = runtime(provider:, required_gpu_id: A40)

    assert_raises(RunpodOllamaFleet::CampaignRunpodRuntime::Error) do
      runtime.ensure_workers!(**ensure_arguments)
    end
    assert_empty provider.create_bodies
    assert_equal [A40], runtime.status.dig("availability_fallback", "authorized_gpu_ids")
  end

  def test_more_expensive_candidate_is_refused_by_original_hourly_ceiling
    provider = Provider.new([
      gpu(A40, 0.49, availability: "NONE"),
      gpu(BLACKWELL, 6.01)
    ])
    runtime = runtime(provider:)
    original = authority_identity

    error = assert_raises(RunpodOllamaFleet::CampaignRunpodRuntime::Error) do
      runtime.ensure_workers!(**ensure_arguments)
    end

    assert_includes error.message, "safety cap"
    assert_empty provider.create_bodies
    assert_equal "blocked", runtime.status.dig("availability_fallback", "state")
    assert_equal original, authority_identity
  end

  def test_changed_deadline_is_rejected_before_provider_mutation
    provider = Provider.new([gpu(A40, 0.49), gpu(BLACKWELL, 2.09)])
    later = (Time.iso8601(@deadline) + 60).iso8601

    error = assert_raises(RunpodOllamaFleet::CampaignRunpodRuntime::Error) do
      runtime(provider:).ensure_workers!(**ensure_arguments.merge(original_deadline_at_utc: later))
    end

    assert_includes error.message, "does not match the original parent deadline"
    assert_empty provider.create_bodies
  end

  def test_retained_authority_tampering_fails_closed
    provider = Provider.new([gpu(A40, 0.49), gpu(BLACKWELL, 2.09)])
    first = runtime(provider:)
    first.ensure_workers!(**ensure_arguments)
    state = first.status.fetch("availability_fallback")
    root = File.join(File.dirname(@binding.state_path), "availability-fallback", "qwen35")
    path = File.join(root, "decisions", "#{state.fetch('decision_sha256')}.json")
    document = JSON.parse(File.binread(path))
    document["max_aggregate_hourly_rate_usd"] = 600.0
    File.write(path, JSON.pretty_generate(document) + "\n")

    error = assert_raises(RunpodOllamaFleet::AvailabilityFallback::Error) do
      runtime(provider:).status
    end
    assert_includes error.message, "does not match immutable campaign authority"
    assert_equal [A40], provider.create_bodies.map { |body| body.dig("gpu", "id") }
  end

  def test_fo11_exact_capability_failure_cleans_up_then_accepts_next_candidate
    provider = Provider.new([gpu(BLACKWELL, 2.09), gpu(A40, 0.49)])
    runtime = runtime(provider:, bringup: Bringup.new)

    runtime.ensure_workers!(**ensure_arguments)
    runtime.reconcile_bringup!(desired_workers: 1, transition_guard: -> { true })

    assert runtime.fallback_retry_pending?
    assert_equal 0, runtime.current_worker_count
    assert_equal ["pod-1"], provider.deleted_ids
    assert_equal "absent", @binding.parent_budget.status.dig("owned_resources", "pod-1", "status")

    runtime.ensure_workers!(**ensure_arguments)
    runtime.reconcile_bringup!(desired_workers: 1, transition_guard: -> { true })

    state = runtime.status.fetch("availability_fallback")
    assert_equal "accepted", state.fetch("state")
    assert_equal BLACKWELL, state.fetch("selected_candidate")
    assert_equal [A40, BLACKWELL], provider.create_bodies.map { |body| body.dig("gpu", "id") }
  end

  def test_fo11_cleanup_failure_blocks_next_candidate_and_retains_liability
    provider = Provider.new([gpu(BLACKWELL, 2.09), gpu(A40, 0.49)])
    provider.delete_error = LocalModelEvaluation::RunpodClient::Error.new(500, "delete failed")
    runtime = runtime(provider:, bringup: Bringup.new)
    runtime.ensure_workers!(**ensure_arguments)

    error = assert_raises(RunpodOllamaFleet::CampaignRunpodRuntime::Error) do
      runtime.reconcile_bringup!(desired_workers: 1, transition_guard: -> { true })
    end

    assert_includes error.message, "cleanup failed"
    assert_equal "blocked", runtime.status.dig("availability_fallback", "state")
    assert_equal [A40], provider.create_bodies.map { |body| body.dig("gpu", "id") }
    assert_equal 1, @binding.status.dig("authority", "committed_workers_by_profile", "qwen35")
  end

  private

  def runtime(provider:, required_gpu_id: nil, bringup: nil)
    admission = RunpodOllamaFleet::CampaignCapacityAdmission.new(
      binding: @binding, profile_id: @profile.fetch("profile_id")
    )
    RunpodOllamaFleet::CampaignRunpodRuntime.new(
      root: @tmp,
      repo_root: File.expand_path("..", __dir__),
      profile: @profile,
      hardware: @hardware,
      client: provider,
      admission:,
      out: StringIO.new,
      wall_clock: -> { @now },
      capability_request: capability_request(required_gpu_id:),
      campaign_identity_sha256: @campaign.identity_sha256,
      binding: @binding,
      bringup_reconciler_factory: bringup && ->(_guard) { bringup }
    )
  end

  def capability_request(required_gpu_id:)
    ollama = {
      "model" => @profile.fetch("model"),
      "expected_digest" => @profile.fetch("expected_digest"),
      "required_context_length" => @profile.fetch("required_context_length"),
      "require_fully_gpu_resident" => true
    }
    ollama["required_gpu_id"] = required_gpu_id if required_gpu_id
    RunpodOllamaFleet::OllamaCapabilityRequest.new(
      JSON.generate(
        "contract_version" => RunpodOllamaFleet::OllamaCapabilityRequest::CONTRACT_VERSION,
        "ollama" => ollama
      )
    )
  end

  def ensure_arguments
    {
      desired_workers: 1,
      ssh_public_key_path: @key_path,
      original_deadline_at_utc: @deadline,
      max_hourly_rate_usd: @campaign.max_hourly_rate_usd
    }
  end

  def gpu(id, rate, availability: "HIGH")
    {
      "id" => id,
      "memory" => 96,
      "secure" => true,
      "availability" => availability,
      "price" => { "secure" => rate }
    }
  end

  def authority_identity
    status = @binding.status
    {
      campaign_identity: @campaign.identity_sha256,
      binding: @binding.binding_sha256,
      budget_id: @binding.declaration.fetch("budget_id"),
      armed_at: status.fetch("armed_at_utc"),
      deadline: status.fetch("deadline_at_utc"),
      max_workers: @binding.declaration.fetch("max_workers"),
      max_hourly: @binding.declaration.fetch("max_aggregate_hourly_rate_usd"),
      max_cumulative: @binding.declaration.fetch("max_cumulative_compute_usd")
    }
  end
end
