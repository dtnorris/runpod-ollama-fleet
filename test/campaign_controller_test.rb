# frozen_string_literal: true

require_relative "test_helper"
require "json"
require_relative "../lib/runpod_ollama_fleet"

class CampaignControllerTest < Minitest::Test
  Campaign = Struct.new(:identity_sha256, :campaign_id)

  class Budget
    attr_accessor :state, :mutation_allowed
    attr_reader :heartbeats

    def initialize
      @state = "ARMED"
      @mutation_allowed = true
      @heartbeats = 0
    end

    def evaluate!
      { "state" => state, "mutation_allowed" => mutation_allowed }
    end

    def heartbeat!(source:)
      raise "wrong heartbeat owner" unless source == "orchestrator"
      @heartbeats += 1
      { "last_orchestrator_heartbeat_at_utc" => "2030-01-01T00:00:#{format('%02d', heartbeats)}Z" }
    end

    def status
      { "deadline_at_utc" => "2030-01-01T01:00:00Z" }
    end
  end

  class Binding
    attr_reader :campaign, :binding_sha256, :declaration, :parent_budget

    def initialize
      @campaign = Campaign.new("a" * 64, "campaign-1")
      @binding_sha256 = "b" * 64
      @declaration = { "budget_id" => "budget-1" }
      @parent_budget = Budget.new
    end
  end

  class Lifecycle
    attr_accessor :error
    attr_reader :calls

    def initialize
      @calls = 0
    end

    def reconcile_once(ssh_public_key_path:)
      @calls += 1
      raise RunpodOllamaFleet::CampaignLifecycle::TransientReconciliationError, error if error
      raise "missing key" if ssh_public_key_path.empty?
      { "profiles" => [{ "profile_id" => "qwen", "action" => "none" }] }
    end
  end

  def setup
    @tmp = Dir.mktmpdir("campaign-controller-")
    @enabled = File.join(@tmp, "enabled")
    @runtime = File.join(@tmp, "runtime.json")
    @log = File.join(@tmp, "controller.log")
    File.write(@enabled, "enabled\n")
    @binding = Binding.new
    @lifecycle = Lifecycle.new
    @now = Time.utc(2030, 1, 1)
  end

  def teardown
    FileUtils.remove_entry(@tmp) if @tmp && File.exist?(@tmp)
  end

  def test_tick_owns_heartbeat_and_reconciliation
    assert controller.tick("2030-01-01T00:00:00Z")

    row = JSON.parse(File.read(@runtime))
    assert_equal 1, @binding.parent_budget.heartbeats
    assert_equal 1, @lifecycle.calls
    assert_equal "RUNNING", row.fetch("state")
    assert_equal "qwen:none", row.fetch("last_action")
    assert_equal "generation-1", row.fetch("generation_id")
  end

  def test_long_reconciliation_keeps_heartbeating_until_it_finishes
    started = Queue.new
    release = Queue.new
    blocking = Object.new
    blocking.define_singleton_method(:reconcile_once) do |ssh_public_key_path:|
      raise "missing key" if ssh_public_key_path.empty?

      started << true
      release.pop
      { "profiles" => [{ "profile_id" => "qwen", "action" => "created" }] }
    end
    instance = controller(lifecycle: blocking, heartbeat_seconds: 0.01)

    worker = Thread.new { instance.tick("2030-01-01T00:00:00Z") }
    started.pop
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 1.0
    until @binding.parent_budget.heartbeats >= 2
      flunk "controller did not heartbeat during reconciliation" if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
      sleep 0.005
    end

    row = JSON.parse(File.read(@runtime))
    assert_equal "RUNNING", row.fetch("state")
    assert_equal "reconciling", row.fetch("last_action")
    refute_nil row.fetch("last_heartbeat_at_utc")

    release << true
    assert worker.value
    row = JSON.parse(File.read(@runtime))
    assert_equal "qwen:created", row.fetch("last_action")
  ensure
    release << true if defined?(release) && release
    worker&.join(1)
  end

  def test_teardown_state_stops_before_heartbeat_or_reconciliation
    @binding.parent_budget.state = "TEARDOWN_REQUIRED"

    refute controller.tick
    assert_equal 0, @binding.parent_budget.heartbeats
    assert_equal 0, @lifecycle.calls
  end

  def test_reconciliation_failure_is_retained_and_loop_remains_bounded
    @lifecycle.error = "provider unavailable"

    assert controller.tick
    row = JSON.parse(File.read(@runtime))
    assert_equal "provider unavailable", row.fetch("last_error")
    assert_equal "reconciliation_error", row.fetch("last_action")
    assert_equal 1, @lifecycle.calls
  end

  def test_run_observes_stop_request_and_exits_without_claiming_budget_closure
    sleeps = 0
    instance = controller(sleeper: lambda do |_seconds|
      sleeps += 1
      File.delete(@enabled)
    end)

    assert_equal 0, instance.run
    row = JSON.parse(File.read(@runtime))
    assert_equal 1, sleeps
    assert_equal "STOPPED", row.fetch("state")
    assert_equal "supervision_disabled", row.fetch("last_action")
    assert_equal "ARMED", @binding.parent_budget.state
  end

  def test_permanent_failure_disables_restart_and_leaves_guardian_timeout_effective
    failing = Object.new
    failing.define_singleton_method(:reconcile_once) do |**|
      raise RunpodOllamaFleet::CampaignLifecycle::Error, "authority invalid"
    end
    instance = RunpodOllamaFleet::CampaignController.new(
      binding: @binding, lifecycle: failing, state_path: @runtime,
      enabled_path: @enabled, log_path: @log, generation_id: "generation-1",
      heartbeat_seconds: 5, ssh_public_key_path: "fixture.pub",
      wall_clock: -> { @now += 1 }, sleeper: ->(*) {}, pid: Process.pid + 1
    )

    assert_equal 1, instance.run
    refute File.exist?(@enabled)
    row = JSON.parse(File.read(@runtime))
    assert_equal "ERROR", row.fetch("state")
    assert_equal "authority invalid", row.fetch("last_error")
  end

  private

  def controller(sleeper: ->(*) {}, lifecycle: @lifecycle, heartbeat_seconds: 5)
    RunpodOllamaFleet::CampaignController.new(
      binding: @binding, lifecycle:, state_path: @runtime,
      enabled_path: @enabled, log_path: @log, generation_id: "generation-1",
      heartbeat_seconds:, ssh_public_key_path: "fixture.pub",
      wall_clock: -> { @now += 1 }, sleeper:, pid: Process.pid + 1
    )
  end
end
