# frozen_string_literal: true

require_relative "test_helper"
require "digest"
require "json"
require "rbconfig"
require "time"
require_relative "../lib/runpod_ollama_fleet"
require_relative "support/deterministic_launchd_scheduler"

class Dw31AutonomousGuardianSupervisorTest < Minitest::Test
  REPO_ROOT = File.expand_path("..", __dir__)
  WLO_ROOT = File.expand_path(
    ENV.fetch("WLO_REPO_ROOT", "../../workload-orchestrator"),
    __dir__
  )
  WLO_LOADER = File.join(WLO_ROOT, "lib/workload_orchestrator.rb")
  CONTROLLER = File.join(__dir__, "support/dw31_autonomous_controller.rb")
  GUARDIAN_OVERRIDE = File.join(__dir__, "support/dw31_guardian_fake_provider.rb")
  INITIAL_TIME = Time.utc(2026, 9, 29, 20, 0, 0)
  MAX_CUMULATIVE_USD = 10.0
  MAX_HOURLY_USD = 6.0
  MAX_WORKERS = 1
  MAX_RUNTIME_SECONDS = 5400.0
  GUARDIAN_POLL_SECONDS = 5.0
  HEARTBEAT_TIMEOUT_SECONDS = 30.0
  TEARDOWN_RESERVE_SECONDS = 120.0

  def setup
    skip "set WLO_REPO_ROOT to a current workload-orchestrator checkout" unless File.file?(WLO_LOADER)

    @tmp = Dir.mktmpdir("dw31-autonomous-guardian-")
    @state_root = File.join(@tmp, "state")
    @clock_path = File.join(@tmp, "clock.txt")
    @provider_path = File.join(@tmp, "provider.json")
    @registry_path = File.join(@tmp, "registry.json")
    @result_path = File.join(@tmp, "controller-result.json")
    @config_path = File.join(@tmp, "config.json")
    @scheduler_socket = File.join(@tmp, "launchd-commands")
    File.write(@clock_path, "#{INITIAL_TIME.iso8601}\n")
    write_json(@provider_path, "pods" => {}, "create_events" => [], "termination_events" => [])
    rubyopt = [ENV["RUBYOPT"], "-r#{GUARDIAN_OVERRIDE}"].compact.reject(&:empty?).join(" ")
    @scheduler = DeterministicLaunchdScheduler.new(
      socket_path: @scheduler_socket,
      service_environment: {
        "RUBYOPT" => rubyopt,
        "DW31_RPOF_ROOT" => REPO_ROOT,
        "DW31_CLOCK_PATH" => @clock_path,
        "DW31_PROVIDER_PATH" => @provider_path,
        "RUNPOD_API_KEY" => "dw31-local-fake-only"
      }
    ).start
    @controller_pids = []
  end

  def teardown
    Array(@controller_pids).each { |pid| kill_and_wait(pid) }
    @scheduler&.stop
    FileUtils.remove_entry(@tmp) if @tmp && File.exist?(@tmp)
  end

  def test_launchd_keep_alive_reinvokes_guardian_after_wlo_and_controller_death
    evidence = start_controller(start_wlo: true, campaign_id: "dw31-autonomous-deadline")
    original = evidence.fetch("authority")
    descriptor = assert_production_service_descriptor(original)

    wlo = evidence.fetch("wlo")
    assert_equal "dw31-autonomous-registry", wlo.fetch("registry_id")
    assert_equal "dw31-autonomous-worker-1", wlo.fetch("worker_id")
    assert_equal "http://127.0.0.1:11441", wlo.fetch("endpoint")
    assert_equal 1, Process.kill("KILL", wlo.fetch("pid"))
    wait_for_process_absence(wlo.fetch("pid"))

    controller_status = kill_controller(evidence.fetch("controller_pid"))
    assert_predicate controller_status, :signaled?
    assert_equal Signal.list.fetch("KILL"), controller_status.termsig

    first_guardian_pid = Integer(original.fetch("guardian_pid"))
    assert_equal first_guardian_pid, @scheduler.service_pid
    invocations_before_crash = @scheduler.invocations.length
    assert_equal first_guardian_pid, @scheduler.kill_service_abruptly
    restarted_pid = wait_for_guardian_restart(first_guardian_pid, invocations_before_crash)
    restart = @scheduler.invocations.find { |invocation| invocation.fetch("pid") == restarted_pid }
    assert_equal "keep_alive", restart.fetch("reason")

    write_clock(Time.iso8601(original.fetch("deadline_at_utc")) + 1)
    wait_for_budget_state(evidence.fetch("budget_state_path"), "CLOSED")
    closed = budget_status(evidence)
    assert_equal "runtime_expired", closed.fetch("teardown_reason")
    assert_equal "verified_provider_absence", closed.fetch("teardown_phase")
    refute_nil closed.fetch("provider_absence_verified_at_utc")
    assert_equal "absent", closed.dig("owned_resources", "fake-pod-1", "status")
    assert_original_authority(original, evidence, closed, descriptor)
    assert_equal descriptor, @scheduler.descriptor

    provider = provider_state
    assert_empty provider.fetch("pods")
    terminated_ids = provider.fetch("termination_events").map do |event|
      event.fetch("provider_resource_id")
    end
    assert_equal ["fake-pod-1"], terminated_ids
    teardown = provider.fetch("termination_events").fetch(0)
    assert_equal "budget_guardian:runtime_expired", teardown.fetch("reason")
    assert_equal restarted_pid, teardown.fetch("guardian_pid")
    refute_equal Process.pid, teardown.fetch("guardian_pid")
    refute_equal evidence.fetch("controller_pid"), teardown.fetch("guardian_pid")

    assert_idempotent_follow_up(evidence.fetch("budget_state_path"), closed)
    assert_crash_loss_bound(closed)
  end

  private

  def start_controller(start_wlo:, campaign_id:)
    write_json(@config_path, {
      "campaign_id" => campaign_id,
      "budget_id" => "dw31-parent",
      "max_cumulative_compute_usd" => MAX_CUMULATIVE_USD,
      "max_hourly_rate_usd" => MAX_HOURLY_USD,
      "max_workers" => MAX_WORKERS,
      "max_runtime_seconds" => MAX_RUNTIME_SECONDS,
      "guardian_poll_seconds" => GUARDIAN_POLL_SECONDS,
      "heartbeat_timeout_seconds" => HEARTBEAT_TIMEOUT_SECONDS,
      "teardown_reserve_seconds" => TEARDOWN_RESERVE_SECONDS,
      "start_wlo" => start_wlo
    })
    log_path = File.join(@tmp, "controller.log")
    pid = Process.spawn(
      RbConfig.ruby,
      CONTROLLER,
      REPO_ROOT,
      WLO_ROOT,
      @state_root,
      @scheduler_socket,
      @clock_path,
      @provider_path,
      @registry_path,
      @result_path,
      @config_path,
      out: log_path,
      err: log_path
    )
    @controller_pids << pid
    wait_for_file(@result_path, pid:, log_path:)
    evidence = JSON.parse(File.read(@result_path))
    flunk "controller failed: #{evidence.fetch('error')}\n#{Array(evidence['backtrace']).join("\n")}" if evidence["error"]
    assert_equal pid, evidence.fetch("controller_pid")
    evidence
  end

  def assert_production_service_descriptor(original)
    descriptor = @scheduler.descriptor
    arguments = descriptor.fetch("program_arguments")
    assert_equal RbConfig.ruby, arguments.fetch(0)
    assert_equal File.join(REPO_ROOT, "bin/rpof-budget-guardian"), arguments.fetch(1)
    assert_equal true, descriptor.fetch("run_at_load")
    assert_equal 1, descriptor.fetch("throttle_interval_seconds")
    assert File.file?(descriptor.fetch("keep_alive_enabled_path"))
    assert_equal original.fetch("launchd_label"), descriptor.fetch("label")
    assert_equal Digest::SHA256.file(descriptor.fetch("plist_path")).hexdigest,
                 descriptor.fetch("plist_sha256")
    descriptor
  end

  def assert_original_authority(original, evidence, closed, descriptor)
    binding = JSON.parse(File.read(evidence.fetch("binding_state_path")))
    after = {
      "campaign_id" => binding.dig("binding", "campaign_identity", "campaign_id"),
      "binding_sha256" => binding.fetch("binding_sha256"),
      "budget_id" => closed.fetch("budget_id"),
      "plan_sha256" => closed.fetch("plan_sha256"),
      "campaign_identity_sha256" => binding.dig("binding", "campaign_identity_sha256"),
      "armed_at_utc" => closed.fetch("armed_at_utc"),
      "deadline_at_utc" => closed.fetch("deadline_at_utc"),
      "max_cumulative_compute_usd" => closed.dig("limits", "max_cumulative_compute_usd"),
      "max_aggregate_hourly_rate_usd" => closed.dig("limits", "max_aggregate_hourly_rate_usd"),
      "max_workers" => closed.dig("limits", "max_workers"),
      "guardian_poll_seconds" => closed.dig("limits", "guardian_poll_seconds"),
      "orchestrator_heartbeat_timeout_seconds" => closed.dig(
        "limits", "orchestrator_heartbeat_timeout_seconds"
      ),
      "teardown_reserve_seconds" => closed.dig("limits", "teardown_reserve_seconds"),
      "launchd_label" => descriptor.fetch("label")
    }
    assert_equal original.except("guardian_pid"), after
    assert_equal original.fetch("deadline_at_utc"), binding.fetch("deadline_at_utc")
    assert_equal original.fetch("armed_at_utc"), binding.fetch("armed_at_utc")
  end

  def assert_idempotent_follow_up(budget_path, closed)
    provider_before = provider_state
    accrued_before = closed.fetch("accrued_compute_usd")
    status = @scheduler.invoke_once
    assert_predicate status, :success?
    after = JSON.parse(File.read(budget_path))
    assert_equal "CLOSED", after.fetch("state")
    assert_equal accrued_before, after.fetch("accrued_compute_usd")
    assert_equal provider_before, provider_state
    assert_empty provider_state.fetch("pods")
  end

  def budget_status(evidence)
    authority = evidence.fetch("authority")
    LocalModelEvaluation::RunpodBudget.new(
      root: @state_root,
      budget_id: authority.fetch("budget_id"),
      plan_sha256: authority.fetch("plan_sha256"),
      wall_clock: -> { clock }
    ).status
  end

  def assert_crash_loss_bound(closed)
    horizon = GUARDIAN_POLL_SECONDS + HEARTBEAT_TIMEOUT_SECONDS + TEARDOWN_RESERVE_SECONDS
    rate_bound = MAX_HOURLY_USD * horizon / 3600.0
    remaining_cumulative = MAX_CUMULATIVE_USD - closed.fetch("accrued_compute_usd")
    worst_case = [remaining_cumulative, rate_bound].min
    assert_equal 155.0, horizon
    assert_in_delta 0.258333, rate_bound, 0.000001
    assert_operator closed.fetch("accrued_compute_usd"), :>, 9.0
    assert_operator closed.fetch("accrued_compute_usd"), :<, MAX_CUMULATIVE_USD
    assert_operator remaining_cumulative, :>, rate_bound
    assert_in_delta 0.258333, worst_case, 0.000001
  end

  def wait_for_guardian_restart(first_pid, invocations_before_crash)
    wait_until("guardian restart") do
      pid = @scheduler.service_pid
      pid if pid && pid != first_pid && @scheduler.invocations.length > invocations_before_crash
    end
  end

  def wait_for_budget_state(path, expected)
    wait_until("budget state #{expected}") do
      next unless File.file?(path)

      status = JSON.parse(File.read(path))
      status if status["state"] == expected
    rescue JSON::ParserError
      nil
    end
  end

  def kill_controller(pid)
    Process.kill("KILL", pid)
    _waited, status = Process.wait2(pid)
    @controller_pids.delete(pid)
    status
  end

  def wait_for_process_absence(pid)
    wait_until("process #{pid} exit") do
      Process.kill(0, pid)
      nil
    rescue Errno::ESRCH
      true
    end
  end

  def wait_for_file(path, pid:, log_path:)
    wait_until("controller result") do
      next true if File.file?(path)

      waited = Process.waitpid(pid, Process::WNOHANG)
      if waited
        @controller_pids.delete(pid)
        flunk "controller exited before readiness: #{File.read(log_path)}"
      end
      false
    end
  end

  def wait_until(label)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 5
    loop do
      result = yield
      return result if result
      flunk "timed out waiting for #{label}" if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
      sleep 0.01
    end
  end

  def kill_and_wait(pid)
    Process.kill("KILL", pid)
    Process.wait(pid)
  rescue Errno::ESRCH, Errno::ECHILD
    nil
  end

  def write_clock(value)
    File.write(@clock_path, "#{value.utc.iso8601}\n")
  end

  def clock
    Time.iso8601(File.read(@clock_path).strip)
  end

  def provider_state
    File.open("#{@provider_path}.lock", File::RDWR | File::CREAT, 0o600) do |lock|
      lock.flock(File::LOCK_SH)
      JSON.parse(File.read(@provider_path))
    ensure
      lock.flock(File::LOCK_UN) rescue nil
    end
  end

  def write_json(path, document)
    File.write(path, JSON.pretty_generate(document) + "\n")
  end
end
