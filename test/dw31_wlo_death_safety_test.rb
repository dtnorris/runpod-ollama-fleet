# frozen_string_literal: true

require_relative "test_helper"
require "digest"
require "json"
require "open3"
require "rbconfig"
require "time"
require_relative "../lib/runpod_ollama_fleet"

class Dw31WloDeathSafetyTest < Minitest::Test
  REPO_ROOT = File.expand_path("..", __dir__)
  WLO_ROOT = File.expand_path(
    ENV.fetch("WLO_REPO_ROOT", "../../workload-orchestrator"),
    __dir__
  )
  WLO_LOADER = File.join(WLO_ROOT, "lib/workload_orchestrator.rb")
  PROCESS_FIXTURE = File.join(__dir__, "support/dw31_process_fixture.rb")
  INITIAL_TIME = Time.utc(2026, 9, 29, 20, 0, 0)
  MAX_CUMULATIVE_USD = 1.60
  MAX_HOURLY_USD = 6.0
  MAX_WORKERS = 2
  MAX_RUNTIME_SECONDS = 5400.0
  GUARDIAN_POLL_SECONDS = 5.0
  HEARTBEAT_TIMEOUT_SECONDS = 30.0
  TEARDOWN_RESERVE_SECONDS = 120.0

  class GuardianProcess
    attr_reader :pid

    def initialize(*arguments, log_path:)
      @stdin, @stdout, @stderr, @wait_thread = Open3.popen3(
        RbConfig.ruby,
        PROCESS_FIXTURE,
        "guardian",
        *arguments
      )
      @stdin.sync = true
      @pid = @wait_thread.pid
      @log_path = log_path
    end

    def request(document)
      @stdin.puts(JSON.generate(document))
      ready = IO.select([@stdout], nil, nil, 5)
      raise "timed out waiting for DW-31 guardian process" unless ready

      line = @stdout.gets
      raise "DW-31 guardian process exited: #{stderr_text}" unless line

      response = JSON.parse(line)
      raise response.fetch("error") if response["error"]

      response
    end

    def alive?
      Process.kill(0, pid)
      true
    rescue Errno::ESRCH
      false
    end

    def stop
      request("command" => "exit") if alive?
      @stdin.close unless @stdin.closed?
      @stdout.close unless @stdout.closed?
      error = stderr_text
      @stderr.close unless @stderr.closed?
      @wait_thread.value
      File.write(@log_path, error) unless error.empty?
    rescue IOError, Errno::EPIPE, Errno::ESRCH
      nil
    end

    private

    def stderr_text
      @stderr.read_nonblock(16_384)
    rescue IO::WaitReadable, EOFError, IOError
      ""
    end
  end

  class IndependentGuardianSupervisor
    def initialize(clock)
      @clock = clock
      @guardian = nil
      @probe = nil
    end

    def attach(guardian)
      @guardian = guardian
      @probe = guardian.request("command" => "probe")
    end

    def arm!(budget:, request:)
      @probe = @guardian.request("command" => "probe")
      begin
        prior = budget.evaluate!
        if prior.fetch("state") == "TEARDOWN_REQUIRED"
          raise LocalModelEvaluation::RunpodBudgetGuardianSupervisor::Error,
                "existing budget requires teardown and cannot be resumed"
        end
      rescue LocalModelEvaluation::RunpodBudget::Error => e
        raise unless e.message.start_with?("budget is not armed:")
      end

      budget.arm!(
        budget: request,
        guardian_heartbeat_at_utc: @probe.fetch("provider_probe_at_utc")
      )
      @guardian.request("command" => "tick", "campaign_heartbeat" => true)
      budget.status
    end

    def status(budget:)
      row = @guardian.request("command" => "status")
      {
        "enabled" => true,
        "launchd_loaded" => true,
        "ready" => row.fetch("ready"),
        "pid" => row.fetch("pid"),
        "provider_probe_at_utc" => @probe.fetch("provider_probe_at_utc"),
        "ledger_heartbeat_at_utc" => row.fetch("ledger_heartbeat_at_utc"),
        "state" => row.fetch("state"),
        "last_error" => nil
      }
    end
  end

  def setup
    skip "set WLO_REPO_ROOT to a current workload-orchestrator checkout" unless File.file?(WLO_LOADER)

    @tmp = Dir.mktmpdir("dw31-wlo-death-")
    @clock_path = File.join(@tmp, "clock.txt")
    @provider_path = File.join(@tmp, "fake-provider.json")
    @registry_path = File.join(@tmp, "registry.json")
    @guardian_log = File.join(@tmp, "guardian.log")
    @now = INITIAL_TIME
    @wlo_pids = []
    write_clock(@now)
    write_provider("pods" => {}, "create_events" => [], "termination_events" => [])
  end

  def teardown
    @wlo_pids.each { |pid| kill_process(pid) }
    @guardian&.stop
    FileUtils.remove_entry(@tmp) if @tmp && File.exist?(@tmp)
  end

  def test_parent_authority_and_guardian_survive_sigkill_of_dynamic_wlo
    campaign = build_campaign
    supervisor = IndependentGuardianSupervisor.new(-> { @now })
    binding = build_binding(campaign, supervisor:)
    @guardian = GuardianProcess.new(
      @tmp,
      REPO_ROOT,
      binding.declaration.fetch("budget_id"),
      binding.binding_sha256,
      @clock_path,
      @provider_path,
      log_path: @guardian_log
    )
    supervisor.attach(@guardian)

    armed = binding.arm!
    original = authority_identity(armed)
    assert_finite_original_authority(original, binding, campaign)

    first_admission = admission_for(binding)
    create_resource(
      first_admission,
      resource_id: "fake-pod-1",
      worker_index: 1,
      hourly_rate: 1.0
    )
    after_create = binding.status
    assert_equal original, authority_identity(after_create)
    assert_equal "active", after_create.dig("parent_budget", "owned_resources", "fake-pod-1", "status")
    assert_equal binding.binding_sha256,
                 provider_state.dig("pods", "fake-pod-1", "campaign_binding_sha256")
    assert_in_delta 1.0,
                    after_create.dig("parent_budget", "owned_resources", "fake-pod-1", "hourly_rate_usd"),
                    0.000001
    publish_registry(campaign, worker_count: 1, revision: 1)

    before_binding_bytes = File.binread(binding.state_path)
    before_budget_bytes = File.binread(binding.parent_budget.state_path)
    wlo_pid, wlo_ready = start_wlo("first")
    assert_equal "dw31-registry", wlo_ready.fetch("registry_id")
    assert_equal "dw31-worker-1", wlo_ready.fetch("worker_id")
    assert_equal "http://127.0.0.1:11441", wlo_ready.fetch("endpoint")
    assert_empty wlo_ready.fetch("provider_lifecycle_features")

    killed = kill_wlo_abruptly(wlo_pid)
    assert_predicate killed, :signaled?
    assert_equal Signal.list.fetch("KILL"), killed.termsig
    assert @guardian.alive?, "independent RPOF guardian died with WLO"
    assert_equal before_binding_bytes, File.binread(binding.state_path)
    assert_equal before_budget_bytes, File.binread(binding.parent_budget.state_path)
    assert_equal ["fake-pod-1"], provider_state.fetch("pods").keys

    second_pid, second_ready = start_wlo("replacement")
    assert_equal wlo_ready.slice("registry_id", "worker_id", "endpoint"),
                 second_ready.slice("registry_id", "worker_id", "endpoint")
    kill_wlo_abruptly(second_pid)
    after_reconnect = binding.status
    assert_equal original, authority_identity(after_reconnect)

    advance_clock(MAX_RUNTIME_SECONDS - 100)
    @guardian.request("command" => "tick", "campaign_heartbeat" => true)
    resumed = binding.arm!
    assert_equal original.fetch("armed_at_utc"), resumed.fetch("armed_at_utc")
    assert_equal original.fetch("deadline_at_utc"), resumed.fetch("deadline_at_utc")
    assert_equal original.fetch("binding_sha256"), resumed.fetch("binding_sha256")

    changed = build_binding(
      campaign,
      supervisor:,
      overrides: { "max_cumulative_compute_usd" => MAX_CUMULATIVE_USD + 1.0 }
    )
    mismatch = assert_raises(RunpodOllamaFleet::CampaignBudgetBinding::Error) { changed.bind! }
    assert_includes mismatch.message, "does not match"

    hourly = assert_raises(RunpodOllamaFleet::CampaignBudgetBinding::Error) do
      binding.mutation_authority!(
        expected_binding_sha256: binding.binding_sha256,
        additional_workers: 1,
        additional_hourly_rate_usd: 5.01,
        profile_id: "qwen35"
      )
    end
    assert_includes hourly.message, "aggregate hourly ceiling"

    cumulative = assert_raises(RunpodOllamaFleet::CampaignBudgetBinding::Error) do
      binding.mutation_authority!(
        expected_binding_sha256: binding.binding_sha256,
        additional_workers: 1,
        additional_hourly_rate_usd: 5.0,
        profile_id: "qwen35"
      )
    end
    assert_includes cumulative.message, "remaining cumulative authority"

    second_admission = admission_for(binding)
    create_resource(
      second_admission,
      resource_id: "fake-pod-2",
      worker_index: 2,
      hourly_rate: 0.5
    )
    publish_registry(campaign, worker_count: 2, revision: 2)
    worker_limit = assert_raises(RunpodOllamaFleet::CampaignBudgetBinding::Error) do
      binding.mutation_authority!(
        expected_binding_sha256: binding.binding_sha256,
        additional_workers: 1,
        additional_hourly_rate_usd: 0.0,
        profile_id: "qwen35"
      )
    end
    assert_includes worker_limit.message, "worker ceiling"

    before_deadline = binding.status
    assert_equal original, authority_identity(before_deadline)
    assert_equal 2, before_deadline.dig("authority", "committed_workers")
    assert_in_delta 1.5, before_deadline.dig("authority", "committed_hourly_rate_usd"), 0.000001
    assert_operator before_deadline.dig("parent_budget", "committed_maximum_liability_usd"),
                    :<,
                    MAX_CUMULATIVE_USD

    advance_clock(100)
    closed = @guardian.request("command" => "tick", "campaign_heartbeat" => true).fetch("status")
    assert_equal "CLOSED", closed.fetch("state")
    assert_equal "runtime_expired", closed.fetch("teardown_reason")
    assert_equal "verified_provider_absence", closed.fetch("teardown_phase")
    refute_nil closed.fetch("provider_absence_verified_at_utc")
    assert_equal original.fetch("deadline_at_utc"), closed.fetch("deadline_at_utc")
    assert_equal %w[fake-pod-1 fake-pod-2], closed.fetch("owned_resources").keys.sort
    assert closed.fetch("owned_resources").values.all? { |resource| resource.fetch("status") == "absent" }

    provider = provider_state
    assert_empty provider.fetch("pods")
    assert_equal %w[fake-pod-1 fake-pod-2],
                 provider.fetch("termination_events").map { |event| event.fetch("provider_resource_id") }.sort
    assert(provider.fetch("termination_events").all? do |event|
      event.fetch("reason") == "budget_guardian:runtime_expired"
    end)

    time_bound = MAX_HOURLY_USD *
                 (MAX_RUNTIME_SECONDS + GUARDIAN_POLL_SECONDS + TEARDOWN_RESERVE_SECONDS) / 3600.0
    worst_case = [MAX_CUMULATIVE_USD, time_bound].min
    assert_in_delta 9.208333, time_bound, 0.000001
    assert_in_delta 1.60, worst_case, 0.000001
    controller_crash_bound = MAX_HOURLY_USD * crash_liability_horizon / 3600.0
    assert_in_delta 0.258333, controller_crash_bound, 0.000001
  end

  private

  def build_campaign
    hardware = RunpodOllamaFleet::ExecutionPoolHardware.new(
      path: File.join(REPO_ROOT, "config/execution_pool_hardware.yml")
    )
    RunpodOllamaFleet::CapacityCampaign.new(JSON.generate(
      "contract_version" => "rpof-capacity-campaign/v0.1",
      "campaign_id" => "dw31-fixture",
      "max_workers" => MAX_WORKERS,
      "max_hourly_rate_usd" => MAX_HOURLY_USD,
      "profiles" => [{
        "profile_id" => "qwen35",
        "model" => "qwen3.6:35b-a3b",
        "expected_digest" => "a" * 64,
        "required_context_length" => 131_072,
        "require_fully_gpu_resident" => true,
        "min_workers" => 1,
        "desired_workers" => 1,
        "max_workers" => MAX_WORKERS
      }]
    ), hardware:)
  end

  def build_binding(campaign, supervisor:, overrides: {})
    declaration = {
      "contract_version" => "rpof-capacity-campaign-budget/v0.1",
      "campaign_identity" => campaign.identity,
      "campaign_identity_sha256" => campaign.identity_sha256,
      "budget_id" => "dw31-parent",
      "max_cumulative_compute_usd" => MAX_CUMULATIVE_USD,
      "max_aggregate_hourly_rate_usd" => MAX_HOURLY_USD,
      "max_workers" => MAX_WORKERS,
      "max_runtime_seconds" => MAX_RUNTIME_SECONDS,
      "guardian_poll_seconds" => GUARDIAN_POLL_SECONDS,
      "orchestrator_heartbeat_timeout_seconds" => HEARTBEAT_TIMEOUT_SECONDS,
      "teardown_reserve_seconds" => TEARDOWN_RESERVE_SECONDS
    }.merge(overrides)
    RunpodOllamaFleet::CampaignBudgetBinding.new(
      root: @tmp,
      repo_root: REPO_ROOT,
      campaign:,
      declaration:,
      wall_clock: -> { @now },
      guardian_supervisor: supervisor
    )
  end

  def admission_for(binding)
    RunpodOllamaFleet::CampaignCapacityAdmission.new(binding:, profile_id: "qwen35")
  end

  def create_resource(admission, resource_id:, worker_index:, hourly_rate:)
    hardware = admission.binding.campaign.hardware_bindings.fetch(0)
    handle = admission.reserve!(
      operation_type: "scale_up",
      logical_resource_id: "burst_#{worker_index}",
      max_hourly_rate_delta_usd: hourly_rate,
      gpu_id: hardware.fetch("qualified_gpu_ids").fetch(0),
      cloud: hardware.fetch("cloud"),
      reservation_id: "dw31-reservation-#{worker_index}"
    )
    admission.attempt_provider_create!(handle) do
      add_provider_resource(
        id: resource_id,
        name: "af-lme-qwen35-burst-#{worker_index}",
        hourly_rate:,
        binding_sha256: admission.binding.binding_sha256
      )
      resource_id
    end
    admission.commit!(
      handle,
      provider_resource_id: resource_id,
      actual_hourly_rate_usd: hourly_rate
    )
  end

  def publish_registry(campaign, worker_count:, revision:)
    model = campaign.profiles.fetch(0)
    published = @now
    workers = (1..worker_count).map do |index|
      worker = {
        "worker_id" => "dw31-worker-#{index}",
        "generation_id" => "dw31-generation-#{index}",
        "endpoint" => "http://127.0.0.1:#{11_440 + index}",
        "state" => "READY",
        "labels" => %w[inference ollama remote],
        "capabilities" => {
          "gpu_id" => "NVIDIA A40",
          "ollama" => {
            "models" => [{
              "model" => model.fetch("model"),
              "digest" => model.fetch("expected_digest"),
              "context_length" => model.fetch("required_context_length"),
              "fully_gpu_resident" => true
            }]
          }
        }
      }
      worker.merge(
        "capability_fingerprint" => RunpodOllamaFleet::DynamicWorkerRegistry.capability_fingerprint(worker)
      )
    end
    File.write(@registry_path, JSON.pretty_generate(
      "contract_version" => "dynamic-worker-registry/v0.1",
      "registry_id" => "dw31-registry",
      "revision" => revision,
      "published_at" => published.iso8601,
      "expires_at" => (published + MAX_RUNTIME_SECONDS + 600).iso8601,
      "workers" => workers
    ) + "\n")
  end

  def start_wlo(label)
    ready_path = File.join(@tmp, "wlo-#{label}-ready.json")
    workdir = File.join(@tmp, "wlo-#{label}-work")
    output = File.join(@tmp, "wlo-#{label}-output")
    log = File.join(@tmp, "wlo-#{label}.log")
    pid = Process.spawn(
      RbConfig.ruby,
      PROCESS_FIXTURE,
      "wlo",
      WLO_ROOT,
      @registry_path,
      ready_path,
      workdir,
      output,
      @now.iso8601,
      out: log,
      err: log
    )
    @wlo_pids << pid
    wait_for_file(ready_path, pid:, log:)
    [pid, JSON.parse(File.read(ready_path))]
  end

  def kill_wlo_abruptly(pid)
    Process.kill("KILL", pid)
    _waited_pid, status = Process.wait2(pid)
    @wlo_pids.delete(pid)
    status
  end

  def wait_for_file(path, pid:, log:)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 5
    until File.file?(path)
      waited = Process.waitpid(pid, Process::WNOHANG)
      raise "WLO fixture exited before readiness: #{File.read(log)}" if waited
      raise "timed out waiting for WLO fixture: #{File.read(log)}" if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
      sleep 0.01
    end
  end

  def kill_process(pid)
    Process.kill("KILL", pid)
    Process.wait(pid)
  rescue Errno::ESRCH, Errno::ECHILD
    nil
  end

  def authority_identity(status)
    {
      "binding_sha256" => status.fetch("binding_sha256"),
      "campaign_identity_sha256" => status.dig("binding", "campaign_identity_sha256"),
      "budget_id" => status.dig("parent_budget", "budget_id"),
      "plan_sha256" => status.dig("parent_budget", "plan_sha256"),
      "armed_at_utc" => status.fetch("armed_at_utc"),
      "deadline_at_utc" => status.fetch("deadline_at_utc"),
      "limits" => status.dig("parent_budget", "limits"),
      "guardian_pid" => status.dig("guardian", "pid")
    }
  end

  def assert_finite_original_authority(authority, binding, campaign)
    assert_equal binding.binding_sha256, authority.fetch("binding_sha256")
    assert_equal campaign.identity_sha256, authority.fetch("campaign_identity_sha256")
    assert_equal "dw31-parent", authority.fetch("budget_id")
    assert_equal binding.binding_sha256, authority.fetch("plan_sha256")
    assert_equal INITIAL_TIME.iso8601, authority.fetch("armed_at_utc")
    assert_equal (INITIAL_TIME + MAX_RUNTIME_SECONDS).iso8601, authority.fetch("deadline_at_utc")
    assert_equal MAX_CUMULATIVE_USD, authority.dig("limits", "max_cumulative_compute_usd")
    assert_equal MAX_HOURLY_USD, authority.dig("limits", "max_aggregate_hourly_rate_usd")
    assert_equal MAX_WORKERS, authority.dig("limits", "max_workers")
    assert_equal @guardian.pid, authority.fetch("guardian_pid")
    refute_equal Process.pid, authority.fetch("guardian_pid")
  end

  def add_provider_resource(id:, name:, hourly_rate:, binding_sha256:)
    document = provider_state
    document.fetch("pods")[id] = {
      "id" => id,
      "name" => name,
      "hourly_rate_usd" => hourly_rate,
      "campaign_binding_sha256" => binding_sha256
    }
    document.fetch("create_events") << document.fetch("pods").fetch(id)
    write_provider(document)
  end

  def provider_state
    JSON.parse(File.read(@provider_path))
  end

  def write_provider(document)
    File.write(@provider_path, JSON.pretty_generate(document) + "\n")
  end

  def write_clock(time)
    File.write(@clock_path, "#{time.iso8601}\n")
  end

  def advance_clock(seconds)
    @now += seconds
    write_clock(@now)
  end

  def crash_liability_horizon
    GUARDIAN_POLL_SECONDS + HEARTBEAT_TIMEOUT_SECONDS + TEARDOWN_RESERVE_SECONDS
  end
end
