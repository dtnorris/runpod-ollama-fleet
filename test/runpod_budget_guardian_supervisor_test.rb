# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "fileutils"
require "json"
require_relative "../lib/local_model_evaluation/runpod_budget"
require_relative "../lib/local_model_evaluation/runpod_budget_guardian_supervisor"

class RunpodBudgetGuardianSupervisorTest < Minitest::Test
  PLAN = "a" * 64

  def setup
    @tmp = Dir.mktmpdir("budget-guardian-supervisor-")
    @repo = File.join(@tmp, "rpof")
    @state_root = File.join(@tmp, "budget-state")
    @fleet_state_root = File.join(@tmp, "afio-fleet-state")
    @fleet_state_repo_root = File.join(@tmp, "afio")
    FileUtils.mkdir_p(File.join(@repo, "bin"))
    File.write(File.join(@repo, "bin", "rpof-budget-guardian"), "#!/usr/bin/env ruby\n")
    @now = Time.utc(2026, 9, 18, 20, 0, 0)
    @mono = 0.0
    @loaded = false
    @commands = []
    @kickstart_advance_seconds = 0.0
    @budget = LocalModelEvaluation::RunpodBudget.new(
      root: @state_root,
      budget_id: "batch034",
      plan_sha256: PLAN,
      wall_clock: -> { @now }
    )
    @old_state_root = ENV["RPOF_STATE_ROOT"]
    @old_state_repo_root = ENV["RPOF_STATE_REPO_ROOT"]
    ENV["RPOF_STATE_ROOT"] = @fleet_state_root
    ENV["RPOF_STATE_REPO_ROOT"] = @fleet_state_repo_root
  end

  def teardown
    ENV["RPOF_STATE_ROOT"] = @old_state_root
    ENV["RPOF_STATE_REPO_ROOT"] = @old_state_repo_root
    FileUtils.remove_entry(@tmp) if @tmp && File.exist?(@tmp)
  end

  def test_arm_proves_independent_guardian_before_budget_becomes_mutation_ready
    supervisor = build_supervisor

    status = supervisor.arm!(budget: @budget, request: budget_config)

    assert_equal "ARMED", status.fetch("state")
    assert_equal true, status.fetch("mutation_allowed")
    assert @commands.any? { |argv| argv[1] == "bootstrap" }
    assert @commands.any? { |argv| argv[1] == "kickstart" }

    plist = Dir.glob(File.join(File.dirname(@budget.state_path), "guardian", "*.plist")).fetch(0)
    content = File.read(plist)
    assert_includes content, @fleet_state_root
    assert_includes content, @fleet_state_repo_root
    assert_includes content, "--fleet-state-root"
    assert_includes content, "--fleet-state-repo-root"
  end

  def test_resume_cannot_refresh_away_a_stale_orchestrator_heartbeat
    supervisor = build_supervisor
    first = supervisor.arm!(budget: @budget, request: budget_config)
    deadline = first.fetch("deadline_at_utc")
    @now += 31

    error = assert_raises(LocalModelEvaluation::RunpodBudgetGuardianSupervisor::Error) do
      supervisor.arm!(budget: @budget, request: budget_config)
    end

    assert_includes error.message, "requires teardown"
    status = @budget.status
    assert_equal "TEARDOWN_REQUIRED", status.fetch("state")
    assert_equal "stale_orchestrator_heartbeat", status.fetch("teardown_reason")
    assert_equal deadline, status.fetch("deadline_at_utc")
  end

  def test_slow_guardian_restart_cannot_refresh_away_guardian_staleness
    supervisor = build_supervisor
    supervisor.arm!(budget: @budget, request: budget_config)
    @kickstart_advance_seconds = 11.0

    error = assert_raises(LocalModelEvaluation::RunpodBudgetGuardianSupervisor::Error) do
      supervisor.arm!(budget: @budget, request: budget_config)
    end

    assert_includes error.message, "teardown-required while restarting"
    status = @budget.status
    assert_equal "TEARDOWN_REQUIRED", status.fetch("state")
    assert_equal "stale_guardian_heartbeat", status.fetch("teardown_reason")
  end

  def test_non_darwin_platform_fails_closed_before_budget_arm
    supervisor = build_supervisor(platform: "linux")

    error = assert_raises(LocalModelEvaluation::RunpodBudgetGuardianSupervisor::Error) do
      supervisor.arm!(budget: @budget, request: budget_config)
    end

    assert_includes error.message, "requires macOS launchd"
    refute File.file?(@budget.state_path)
  end

  private

  def build_supervisor(platform: "arm64-darwin")
    LocalModelEvaluation::RunpodBudgetGuardianSupervisor.new(
      root: @state_root,
      repo_root: @repo,
      platform:,
      monotonic_clock: -> { @mono },
      sleeper: lambda do |seconds|
        @mono += seconds
        write_runtime("ARMED", ledger_heartbeat: true) if File.file?(@budget.state_path)
      end,
      command_runner: method(:run_command)
    )
  end

  def run_command(argv)
    @commands << argv.dup
    case argv[1]
    when "print"
      ["", "", @loaded ? 0 : 1]
    when "bootstrap"
      @loaded = true
      ["", "", 0]
    when "kickstart"
      @now += @kickstart_advance_seconds
      write_runtime("WAITING_FOR_ARM", ledger_heartbeat: false)
      ["", "", 0]
    when "bootout"
      @loaded = false
      ["", "", 0]
    else
      ["", "unexpected launchctl command", 1]
    end
  end

  def write_runtime(state, ledger_heartbeat:)
    dir = File.join(File.dirname(@budget.state_path), "guardian")
    FileUtils.mkdir_p(dir)
    path = File.join(dir, "runtime.json")
    File.write(
      path,
      JSON.pretty_generate(
        "ready" => true,
        "pid" => Process.pid + 10_000,
        "provider_probe_at_utc" => @now.iso8601,
        "ledger_heartbeat_at_utc" => (ledger_heartbeat ? @now.iso8601 : nil),
        "state" => state,
        "last_error" => nil
      ) + "\n"
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
