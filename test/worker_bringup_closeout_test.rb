# frozen_string_literal: true

require_relative "test_helper"
require "digest"
require "json"
require_relative "../lib/runpod_ollama_fleet"

class WorkerBringupCloseoutTest < Minitest::Test
  DIGEST = "a" * 64
  CAMPAIGN_SHA = "b" * 64
  COMMAND_SHA = "c" * 64

  ProcessInspector = Struct.new(:alive) do
    def same_process?(_identity) = alive
  end

  class Tunnel
    attr_reader :starts
    attr_accessor :observed, :after_ensure

    def initialize
      @starts = 0
      @observed = nil
    end

    def inspect(identity:) = observed

    def ensure!(identity:)
      @starts += 1
      self.observed = passed(identity)
      after_ensure&.call
      observed
    end

    def passed(identity)
      result(identity, "passed", {
        "worker_id" => identity.fetch("worker_id"),
        "generation_id" => identity.fetch("generation_id"),
        "provider_resource_id" => identity.fetch("provider_resource_id"),
        "endpoint" => identity.dig("tunnel_target", "ollama_endpoint")
      })
    end

    def stale(identity)
      result(identity, "passed", passed(identity).fetch("evidence").merge("generation_id" => "old-generation"))
    end

    private

    def result(identity, status, evidence)
      { "identity_sha256" => fingerprint(identity), "status" => status, "evidence" => evidence }
    end

    def fingerprint(identity) = Digest::SHA256.hexdigest(JSON.generate(identity))
  end

  class Bootstrap
    attr_reader :starts
    attr_accessor :observed, :mode, :before_start, :after_start

    def initialize(requirement)
      @requirement = requirement
      @starts = 0
      @mode = :passed
    end

    def inspect(identity:, attempt:) = observed

    def start!(identity:, attempt:)
      before_start&.call
      @starts += 1
      self.observed = mode == :in_progress ? in_progress(identity, attempt.fetch("attempt_id")) :
        passed(identity, attempt.fetch("attempt_id"))
      after_start&.call
      observed
    end

    def passed(identity, attempt_id)
      exact = @requirement.ollama
      {
        "identity_sha256" => fingerprint(identity), "attempt_id" => attempt_id,
        "status" => "passed", "evidence" => {
          "worker_id" => identity.fetch("worker_id"),
          "generation_id" => identity.fetch("generation_id"),
          "provider_resource_id" => identity.fetch("provider_resource_id"),
          "model" => exact.fetch("model"), "digest" => exact.fetch("expected_digest"),
          "context_length" => exact.fetch("required_context_length"),
          "fully_gpu_resident" => true, "gpu_id" => exact.fetch("required_gpu_id"),
          "observed_at_utc" => "2030-01-01T00:00:00Z"
        }
      }
    end

    def in_progress(identity, attempt_id)
      {
        "identity_sha256" => fingerprint(identity), "attempt_id" => attempt_id,
        "status" => "in_progress", "evidence" => nil,
        "launch_identity" => {
          "pid" => 12_345, "process_group_id" => 12_345,
          "start_token" => "proc:987654", "command_sha256" => COMMAND_SHA
        }
      }
    end

    private

    def fingerprint(identity) = Digest::SHA256.hexdigest(JSON.generate(identity))
  end

  class Capability
    attr_reader :checks
    attr_accessor :observed, :before_verify, :override

    def initialize(requirement)
      @requirement = requirement
      @checks = 0
    end

    def inspect(identity:) = observed

    def verify!(identity:)
      before_verify&.call
      @checks += 1
      self.observed = passed(identity).merge(override || {})
    end

    def passed(identity)
      exact = @requirement.ollama
      {
        "identity_sha256" => Digest::SHA256.hexdigest(JSON.generate(identity)),
        "status" => "passed", "evidence" => {
          "worker_id" => identity.fetch("worker_id"),
          "generation_id" => identity.fetch("generation_id"),
          "provider_resource_id" => identity.fetch("provider_resource_id"),
          "model" => exact.fetch("model"), "digest" => exact.fetch("expected_digest"),
          "context_length" => exact.fetch("required_context_length"),
          "fully_gpu_resident" => true, "gpu_id" => exact.fetch("required_gpu_id")
        }
      }
    end
  end

  class Publisher
    attr_reader :calls, :ready
    attr_accessor :fail

    def initialize(gate, worker)
      @gate = gate
      @worker = worker
      @calls = 0
      @ready = false
    end

    def snapshot
      @calls += 1
      raise RunpodOllamaFleet::DynamicWorkerRegistry::Error, "fixture publication failure" if fail

      @ready = @gate.satisfied?(fleet_key: "pool-a", worker: @worker)
      { "registry_id" => "fixture", "revision" => calls,
        "published_at" => "2030-01-01T00:00:00Z", "expires_at" => "2030-01-01T00:00:30Z" }
    end
  end

  class TunnelManager
    attr_reader :starts

    def initialize(row)
      @row = row
      @starts = 0
    end

    def status(worker_indices:)
      raise "wrong worker" unless worker_indices == [1]
      [@row]
    end

    def start(**)
      @starts += 1
    end
  end

  class AutomaticRuntime
    attr_accessor :admission
    attr_reader :workers, :provider_creates

    def initialize(root:, campaign_sha:, profile:, requirement:)
      @root = root
      @campaign_sha = campaign_sha
      @profile = profile
      @requirement = requirement
      @workers = []
      @provider_creates = 0
    end

    def current_worker_count = workers.length

    def ensure_workers!(desired_workers:, **)
      ((workers.length + 1)..desired_workers).each do |index|
        @provider_creates += 1
        workers << {
          "index" => index, "generation" => 1, "status" => "active",
          "pod_id" => "#{@profile.fetch('profile_id')}-pod-#{index}",
          "worker_id" => "#{@profile.fetch('profile_id')}-worker-#{index}",
          "generation_id" => "generation-1", "host" => "203.0.113.#{index}",
          "ssh_port" => 22_000 + index, "local_ollama_url" => "http://127.0.0.1:#{11_440 + index}",
          "gpu_id" => @requirement.required_gpu_id
        }
      end
    end

    def reconcile_bringup!(desired_workers:, transition_guard:)
      workers.first(desired_workers).map do |worker|
        transition_guard.call
        tunnel = Tunnel.new
        bootstrap = Bootstrap.new(@requirement)
        capability = Capability.new(@requirement)
        reconciler = RunpodOllamaFleet::WorkerBringupReconciler.new(
          root: @root, tunnel:, bootstrap:, capability:,
          process_inspector: ProcessInspector.new(true),
          clock: -> { Time.utc(2030, 1, 1) },
          attempt_id_generator: -> { "#{worker.fetch('worker_id')}-attempt" }
        )
        reconciler.reconcile!(
          campaign_identity_sha256: @campaign_sha, profile: @profile, worker:,
          generation_id: worker.fetch("generation_id"), capability_request: @requirement,
          retry_bootstrap: true
        )
      end
    end

    def status
      {
        "current_workers" => workers.length, "ready_workers" => workers.length,
        "fleet_id" => workers.empty? ? nil : "fleet-#{@profile.fetch('profile_id')}",
        "fleet_status" => workers.empty? ? nil : "active", "worker_readiness" => {}
      }
    end
  end

  class AutomaticPublisher
    attr_reader :ready_workers, :calls

    def initialize(gate, runtimes)
      @gate = gate
      @runtimes = runtimes
      @calls = 0
      @ready_workers = 0
    end

    def snapshot
      @calls += 1
      @ready_workers = @runtimes.sum do |profile_id, runtime|
        runtime.workers.count { |worker| @gate.satisfied?(fleet_key: profile_id, worker:) }
      end
      {
        "registry_id" => "automatic", "revision" => calls,
        "published_at" => "2030-01-01T00:00:00Z", "expires_at" => "2030-01-01T00:00:30Z"
      }
    end
  end

  class AutomaticSupervisor
    attr_accessor :lifecycle

    def validate_requirements!(binding:) = !binding.nil?

    def ensure_running!(binding:, ssh_public_key_path:, **)
      binding.parent_budget.heartbeat!(source: "orchestrator")
      lifecycle.reconcile_once(ssh_public_key_path:)
      status(binding:)
    end

    def status(binding:)
      { "state" => "RUNNING", "pid" => Process.pid + 1, "binding_sha256" => binding.binding_sha256 }
    end
  end

  def setup
    @tmp = Dir.mktmpdir("fo11-closeout-")
    @requirement = capability_request
    @worker = worker
    @tunnel = Tunnel.new
    @bootstrap = Bootstrap.new(@requirement)
    @capability = Capability.new(@requirement)
    @process = ProcessInspector.new(true)
    @attempt = 0
  end

  def teardown
    FileUtils.remove_entry(@tmp) if @tmp && File.exist?(@tmp)
  end

  def test_bu_c01_full_automatic_happy_path
    result, publisher, runtimes = authorized_start

    assert_equal "campaign start", result.fetch("command")
    assert_equal 6, publisher.ready_workers
    assert_equal 6, runtimes.values.sum(&:provider_creates)
    assert_equal 1, publisher.calls
  end

  def test_bu_c02_incremental_passes_do_not_duplicate
    @bootstrap.mode = :in_progress
    first = reconcile
    @bootstrap.mode = :passed
    @bootstrap.observed = @bootstrap.passed(first.fetch("identity"), first.dig("bootstrap", "attempt", "attempt_id"))

    second = reconcile

    assert_equal "prerequisites_passed", second.fetch("overall_status")
    assert_equal 1, @tunnel.starts
    assert_equal 1, @bootstrap.starts
  end

  def test_bu_c03_provider_already_present_continues_bringup_without_create
    runtime = runtime_with_existing_worker

    states = runtime.reconcile_bringup!(desired_workers: 1, transition_guard: -> { true })

    assert_equal "prerequisites_passed", states.fetch(0).fetch("overall_status")
    assert_equal 1, runtime.current_worker_count
  end

  def test_bu_c04_same_generation_tunnel_is_reused
    identity = identity_document
    row = {
      "index" => 1, "pod_id" => "pod-1", "worker_id" => "worker-1",
      "generation_id" => "generation-1", "endpoint" => "http://127.0.0.1:11441",
      "process_status" => "running", "health_status" => "healthy"
    }
    manager = TunnelManager.new(row)
    adapter = RunpodOllamaFleet::WorkerBringupAdapters::Tunnel.new(
      tunnels: manager, requirement: @requirement, transition_guard: -> { true }
    )

    result = adapter.inspect(identity:)

    assert_equal "passed", result.fetch("status")
    assert_equal 0, manager.starts
  end

  def test_bu_c05_stale_tunnel_generation_never_satisfies_ready
    @tunnel.observed = @tunnel.stale(identity_document)

    state = reconcile

    refute state.fetch("readiness_prerequisites_satisfied")
    assert_equal "failed_terminal", state.dig("tunnel", "status")
  end

  def test_bu_c06_restart_adopts_matching_bootstrap_process
    @bootstrap.mode = :in_progress
    first = reconcile
    starts = @bootstrap.starts

    second = reconcile

    assert_equal "in_progress", second.dig("bootstrap", "status")
    assert_equal starts, @bootstrap.starts
    assert_equal first.dig("bootstrap", "attempt", "attempt_id"),
                 second.dig("bootstrap", "attempt", "attempt_id")
  end

  def test_bu_c07_vanished_bootstrap_fails_closed_without_relaunch
    @bootstrap.mode = :in_progress
    reconcile
    @process.alive = false

    state = reconcile

    assert_equal "failed_terminal", state.dig("bootstrap", "status")
    assert_equal 1, @bootstrap.starts
  end

  def test_bu_c08_capability_mismatch_prevents_ready
    bad = @capability.passed(identity_document)
    bad.fetch("evidence")["digest"] = "d" * 64
    @capability.observed = bad

    state = reconcile

    refute state.fetch("readiness_prerequisites_satisfied")
    assert_equal "failed_terminal", state.dig("capability", "status")
  end

  def test_bu_c09_prerequisites_publish_ready_for_exact_generation
    reconcile
    publisher = publisher_for(@worker)

    snapshot = publisher.snapshot

    assert publisher.ready
    assert_equal 1, snapshot.fetch("revision")
  end

  def test_bu_c10_publication_failure_does_not_claim_ready
    reconcile
    publisher = publisher_for(@worker)
    publisher.fail = true

    assert_raises(RunpodOllamaFleet::DynamicWorkerRegistry::Error) { publisher.snapshot }
    refute publisher.ready
    assert_equal 1, publisher.calls
  end

  def test_bu_c11_already_ready_reconciliation_is_idempotent
    first = reconcile
    second = reconcile

    assert_equal first.fetch("identity_sha256"), second.fetch("identity_sha256")
    assert_equal [1, 1, 1], [@tunnel.starts, @bootstrap.starts, @capability.checks]
  end

  def test_bu_c12_generation_replacement_invalidates_old_ready
    reconcile
    old_publisher = publisher_for(@worker)
    old_publisher.snapshot
    replacement = @worker.merge(
      "generation" => 2, "pod_id" => "pod-2", "generation_id" => "generation-2"
    )

    refute gate.satisfied?(fleet_key: "pool-a", worker: replacement)
    assert old_publisher.ready
  end

  def test_bu_c13_restart_after_verification_reuses_durable_evidence
    reconcile
    starts = [@tunnel.starts, @bootstrap.starts, @capability.checks]
    restarted = build_reconciler

    state = restarted.reconcile!(**arguments)

    assert_equal "prerequisites_passed", state.fetch("overall_status")
    assert_equal starts, [@tunnel.starts, @bootstrap.starts, @capability.checks]
  end

  def test_bu_c14_desired_zero_starts_no_provider_or_bringup_work
    called = false
    runtime = runtime_with_existing_worker(factory: ->(_guard) { called = true })

    assert_empty runtime.reconcile_bringup!(desired_workers: 0, transition_guard: -> { true })
    refute called
    assert_equal 0, @tunnel.starts
  end

  def test_bu_c15_teardown_during_tunnel_blocks_bootstrap_and_publication
    authority = true
    @tunnel.after_ensure = -> { authority = false }
    @bootstrap.before_start = lambda do
      raise RunpodOllamaFleet::WorkerBringupReconciler::RetryableTransitionError, "teardown" unless authority
    end

    state = reconcile

    assert_equal "failed_retryable", state.dig("bootstrap", "status")
    refute state.fetch("readiness_prerequisites_satisfied")
    assert_equal 0, @bootstrap.starts
  end

  def test_bu_c16_teardown_during_bootstrap_blocks_capability_and_ready
    authority = true
    @bootstrap.after_start = -> { authority = false }
    @capability.before_verify = lambda do
      raise RunpodOllamaFleet::WorkerBringupReconciler::RetryableTransitionError, "teardown" unless authority
    end

    state = reconcile
    publisher = publisher_for(@worker)
    publisher.snapshot

    assert_equal "failed_retryable", state.dig("capability", "status")
    refute publisher.ready
  end

  def test_bu_c17_fo08_authority_refusal_occurs_before_provider_create
    binding = armed_binding
    admission = RunpodOllamaFleet::CampaignCapacityAdmission.new(binding:, profile_id: "qwen35")
    provider_called = false

    assert_raises(RunpodOllamaFleet::CampaignCapacityAdmission::Error) do
      handle = admission.reserve!(
        operation_type: "create", logical_resource_id: "blocked", max_hourly_rate_delta_usd: 99.0,
        gpu_id: "NVIDIA A40", cloud: "SECURE"
      )
      admission.attempt_provider_create!(handle) { provider_called = true }
    end
    refute provider_called
  end

  def test_bu_c18_pending_ambiguity_is_not_a_duplicate_create_authority
    binding = armed_binding
    admission = RunpodOllamaFleet::CampaignCapacityAdmission.new(binding:, profile_id: "qwen35")
    handle = admission.reserve!(
      operation_type: "create", logical_resource_id: "burst_1", max_hourly_rate_delta_usd: 0.5,
      gpu_id: "NVIDIA A40", cloud: "SECURE"
    )
    assert_raises(RuntimeError) { admission.attempt_provider_create!(handle) { raise "ambiguous" } }

    pending = binding.status.dig("parent_budget", "reservations").values
    assert_equal ["pending"], pending.map { |row| row.fetch("status") }.uniq
    assert_equal 1, binding.status.dig("authority", "committed_workers_by_profile", "qwen35")
  end

  def test_bu_c19_exact_requirement_artifact_drift_is_refused
    repo_root = File.expand_path("..", __dir__)
    hardware_path = File.join(repo_root, "config", "execution_pool_hardware.yml")
    campaign_path = File.expand_path("fixtures/rpof-capacity-campaign-v0.1.json", __dir__)
    budget_path = File.expand_path("fixtures/rpof-capacity-campaign-budget-v0.1.json", __dir__)
    hardware_registry = RunpodOllamaFleet::ExecutionPoolHardware.new(path: hardware_path)
    campaign = RunpodOllamaFleet::CapacityCampaign.load(path: campaign_path, hardware: hardware_registry)
    binding = RunpodOllamaFleet::CampaignBudgetBinding.new(
      root: File.join(@tmp, "drift"), repo_root:, campaign:,
      declaration: JSON.parse(File.binread(budget_path)), wall_clock: -> { Time.utc(2030, 1, 1) },
      guardian_supervisor: guardian(Time.utc(2030, 1, 1))
    )
    paths = campaign.profiles.to_h do |row|
      hardware = campaign.hardware_bindings.find { |item| item.fetch("profile_id") == row.fetch("profile_id") }
      path = File.join(@tmp, "#{row.fetch('profile_id')}-capability.json")
      File.write(path, JSON.pretty_generate(requirement_for(row, hardware).document) + "\n")
      [row.fetch("profile_id"), path]
    end
    supervisor = RunpodOllamaFleet::CampaignControllerSupervisor.new(
      root: File.join(@tmp, "drift"), repo_root:, campaign_path:, budget_path:, hardware_path:,
      capability_request_paths: paths
    )
    request = supervisor.send(
      :request_document, binding:, generation: "generation-1", heartbeat_seconds: 5,
      ssh_public_key_path: "/tmp/offline.pub"
    )
    changed = JSON.parse(File.binread(paths.fetch("qwen35")))
    changed.fetch("ollama")["model"] = "changed:model"
    File.write(paths.fetch("qwen35"), JSON.pretty_generate(changed) + "\n")

    error = assert_raises(RunpodOllamaFleet::CampaignControllerSupervisor::Error) do
      supervisor.send(:validate_retained_request!, request, binding)
    end
    assert_includes error.message, "artifact changed"
  end

  def test_bu_c20_one_authorized_start_is_sufficient_offline
    ENV["RPOF_HARD_OFFLINE"] = "1"

    result, publisher, = authorized_start

    assert result.fetch("paid_authorized")
    assert_equal "RUNNING", result.dig("controller", "state")
    assert_equal 6, publisher.ready_workers
  ensure
    ENV.delete("RPOF_HARD_OFFLINE")
  end

  private

  def authorized_start
    now = Time.utc(2030, 1, 1)
    hardware_registry = RunpodOllamaFleet::ExecutionPoolHardware.new(
      path: File.expand_path("../config/execution_pool_hardware.yml", __dir__)
    )
    campaign_path = File.expand_path("fixtures/rpof-capacity-campaign-v0.1.json", __dir__)
    budget_path = File.expand_path("fixtures/rpof-capacity-campaign-budget-v0.1.json", __dir__)
    campaign = RunpodOllamaFleet::CapacityCampaign.load(path: campaign_path, hardware: hardware_registry)
    guardian = guardian(now)
    binding = RunpodOllamaFleet::CampaignBudgetBinding.new(
      root: File.join(@tmp, "automatic"), repo_root: File.expand_path("..", __dir__), campaign:,
      declaration: JSON.parse(File.binread(budget_path)), wall_clock: -> { now }, guardian_supervisor: guardian
    )
    requirements = campaign.profiles.to_h do |row|
      hardware = campaign.hardware_bindings.find { |item| item.fetch("profile_id") == row.fetch("profile_id") }
      [row.fetch("profile_id"), requirement_for(row, hardware)]
    end
    gate = RunpodOllamaFleet::WorkerBringupReadinessGate.new(
      root: File.join(@tmp, "automatic"), campaign_identity_sha256: campaign.identity_sha256,
      requirements:
    )
    runtimes = {}
    factory = lambda do |row, _hardware, admission|
      runtime = (runtimes[row.fetch("profile_id")] ||= AutomaticRuntime.new(
        root: File.join(@tmp, "automatic"), campaign_sha: campaign.identity_sha256,
        profile: row, requirement: requirements.fetch(row.fetch("profile_id"))
      ))
      runtime.admission = admission
      runtime
    end
    publisher = AutomaticPublisher.new(gate, runtimes)
    supervisor = AutomaticSupervisor.new
    lifecycle = RunpodOllamaFleet::CampaignLifecycle.new(
      campaign:, binding:, runtime_factory: factory, price_resolver: ->(*) { 0.5 },
      wall_clock: -> { now }, controller_supervisor: supervisor, registry_publisher: publisher
    )
    supervisor.lifecycle = lifecycle
    result = lifecycle.start(authorize_paid: true, ssh_public_key_path: "offline-fixture")
    [result, publisher, runtimes]
  end

  def requirement_for(row, hardware)
    document = {
      "contract_version" => RunpodOllamaFleet::OllamaCapabilityRequest::CONTRACT_VERSION,
      "ollama" => {
      "model" => row.fetch("model"), "expected_digest" => row.fetch("expected_digest"),
      "required_context_length" => row.fetch("required_context_length"),
      "require_fully_gpu_resident" => true,
      "required_gpu_id" => hardware.fetch("qualified_gpu_ids").first
      }
    }
    RunpodOllamaFleet::OllamaCapabilityRequest.new(JSON.generate(document))
  end

  def guardian(now)
    Class.new do
      define_method(:initialize) { |clock| @clock = clock }
      define_method(:arm!) do |budget:, request:|
        @armed = true
        budget.arm!(budget: request, guardian_heartbeat_at_utc: @clock)
      end
      define_method(:status) do |budget:|
        {
          "budget_id" => budget.budget_id, "plan_sha256" => budget.plan_sha256,
          "enabled" => true, "launchd_loaded" => true, "ready" => true,
          "pid" => Process.pid + 1, "provider_probe_at_utc" => @clock.iso8601,
          "ledger_heartbeat_at_utc" => @clock.iso8601,
          "state" => (@armed ? budget.status.fetch("state") : "WAITING_FOR_ARM"), "last_error" => nil
        }
      end
    end.new(now)
  end

  def build_reconciler
    RunpodOllamaFleet::WorkerBringupReconciler.new(
      root: @tmp, tunnel: @tunnel, bootstrap: @bootstrap, capability: @capability,
      process_inspector: @process, clock: -> { Time.utc(2030, 1, 1) },
      attempt_id_generator: -> { @attempt += 1; "attempt-#{@attempt}" }
    )
  end

  def reconcile
    (@reconciler ||= build_reconciler).reconcile!(**arguments)
  end

  def arguments(worker: @worker)
    {
      campaign_identity_sha256: CAMPAIGN_SHA,
      profile: profile,
      worker:,
      generation_id: worker.fetch("generation_id"),
      capability_request: @requirement,
      retry_bootstrap: true
    }
  end

  def identity_document
    values = arguments
    RunpodOllamaFleet::WorkerBringupIdentity.new(
      campaign_identity_sha256: values.fetch(:campaign_identity_sha256),
      profile: values.fetch(:profile), worker: values.fetch(:worker),
      generation_id: values.fetch(:generation_id),
      capability_request: values.fetch(:capability_request)
    ).document
  end

  def gate
    @gate ||= RunpodOllamaFleet::WorkerBringupReadinessGate.new(
      root: @tmp, campaign_identity_sha256: CAMPAIGN_SHA,
      requirements: { "pool-a" => @requirement }
    )
  end

  def publisher_for(worker)
    Publisher.new(gate, worker)
  end

  def runtime_with_existing_worker(factory: nil)
    fixture = { "status" => "active", "worker_count" => 1, "workers" => [@worker] }
    factory ||= ->(_guard) { @reconciler ||= build_reconciler }
    klass = Class.new(RunpodOllamaFleet::CampaignRunpodRuntime) do
      define_method(:current_record) { fixture }
    end
    klass.new(
      root: @tmp, repo_root: File.expand_path("..", __dir__), profile:, hardware: hardware,
      client: nil, capability_request: @requirement, campaign_identity_sha256: CAMPAIGN_SHA,
      bringup_reconciler_factory: factory
    )
  end

  def armed_binding
    hardware_registry = RunpodOllamaFleet::ExecutionPoolHardware.new(
      path: File.expand_path("../config/execution_pool_hardware.yml", __dir__)
    )
    campaign_path = File.expand_path("fixtures/rpof-capacity-campaign-v0.1.json", __dir__)
    budget_path = File.expand_path("fixtures/rpof-capacity-campaign-budget-v0.1.json", __dir__)
    campaign = RunpodOllamaFleet::CapacityCampaign.load(path: campaign_path, hardware: hardware_registry)
    guardian = Class.new do
      define_method(:arm!) do |budget:, request:|
        @armed = true
        budget.arm!(budget: request, guardian_heartbeat_at_utc: Time.utc(2030, 1, 1))
      end
      define_method(:status) do |budget:|
        {
          "budget_id" => budget.budget_id, "plan_sha256" => budget.plan_sha256,
          "enabled" => true, "launchd_loaded" => true, "ready" => true,
          "pid" => Process.pid + 1, "provider_probe_at_utc" => "2030-01-01T00:00:00Z",
          "ledger_heartbeat_at_utc" => "2030-01-01T00:00:00Z",
          "state" => (@armed ? budget.status.fetch("state") : "WAITING_FOR_ARM"), "last_error" => nil
        }
      end
    end.new
    binding = RunpodOllamaFleet::CampaignBudgetBinding.new(
      root: File.join(@tmp, "binding"),
      repo_root: File.expand_path("..", __dir__), campaign:,
      declaration: JSON.parse(File.binread(budget_path)), wall_clock: -> { Time.utc(2030, 1, 1) },
      guardian_supervisor: guardian
    )
    binding.bind!
    binding.arm!
    binding
  end

  def profile
    {
      "profile_id" => "pool-a", "model" => "qualified-model:latest",
      "expected_digest" => DIGEST, "required_context_length" => 131_072,
      "require_fully_gpu_resident" => true, "min_workers" => 1,
      "desired_workers" => 1, "max_workers" => 1
    }
  end

  def hardware
    {
      "qualified_gpu_ids" => ["NVIDIA A40"], "cloud" => "SECURE",
      "global_volume_id" => "volume-1", "ollama_store_path" => "/workspace-global/ollama-models"
    }
  end

  def worker
    {
      "index" => 1, "generation" => 1, "status" => "active", "pod_id" => "pod-1",
      "worker_id" => "worker-1", "generation_id" => "generation-1",
      "host" => "203.0.113.1", "ssh_port" => 22_001,
      "local_ollama_url" => "http://127.0.0.1:11441", "gpu_id" => "NVIDIA A40"
    }
  end

  def capability_request
    document = {
      "contract_version" => RunpodOllamaFleet::OllamaCapabilityRequest::CONTRACT_VERSION,
      "ollama" => requirement_document.fetch("ollama")
    }
    RunpodOllamaFleet::OllamaCapabilityRequest.new(JSON.generate(document))
  end

  def requirement_document
    {
      "contract_version" => RunpodOllamaFleet::ModelRequirement::CONTRACT_VERSION,
      "batch_handle" => "batch-1", "production_batch_id" => "production-1",
      "plan_id" => "plan-1", "plan_sha256" => "e" * 64, "alias" => "operator-alias",
      "pool_id" => "pool-a", "required_labels" => %w[inference ollama remote],
      "ollama" => {
        "model" => "qualified-model:latest", "expected_digest" => DIGEST,
        "required_context_length" => 131_072, "require_fully_gpu_resident" => true,
        "required_gpu_id" => "NVIDIA A40"
      }
    }
  end
end
