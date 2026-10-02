# frozen_string_literal: true

require_relative "test_helper"
require "json"
require_relative "../lib/runpod_ollama_fleet"

class CampaignControllerSupervisorTest < Minitest::Test
  Campaign = Struct.new(:identity_sha256)
  Binding = Struct.new(:state_path, :binding_sha256, :campaign, :declaration)

  def setup
    @tmp = Dir.mktmpdir("campaign-controller-supervisor-")
    @repo = File.join(@tmp, "repo")
    FileUtils.mkdir_p(File.join(@repo, "bin"))
    File.write(File.join(@repo, "bin", "rpof-campaign-controller"), "#!/usr/bin/env ruby\n")
    @campaign_path = artifact("campaign.json")
    @budget_path = artifact("budget.json")
    @hardware_path = artifact("hardware.yml")
    binding_dir = File.join(@tmp, "campaign-budgets", "binding")
    FileUtils.mkdir_p(binding_dir)
    @binding = Binding.new(
      File.join(binding_dir, "binding.json"), "b" * 64, Campaign.new("a" * 64),
      { "budget_id" => "budget-1", "orchestrator_heartbeat_timeout_seconds" => 30.0 }
    )
    @loaded = false
    @commands = []
    @now = Time.utc(2030, 1, 1)
  end

  def teardown
    FileUtils.remove_entry(@tmp) if @tmp && File.exist?(@tmp)
  end

  def test_launches_once_and_reuses_matching_healthy_controller
    supervisor = build_supervisor
    first = supervisor.ensure_running!(
      binding: @binding, ssh_public_key_path: "fixture.pub", heartbeat_timeout_seconds: 30
    )
    kickstarts = @commands.count { |argv| argv.include?("kickstart") }
    second = supervisor.ensure_running!(
      binding: @binding, ssh_public_key_path: "fixture.pub", heartbeat_timeout_seconds: 30
    )

    assert_equal "RUNNING", first.fetch("state")
    assert_equal first.fetch("generation_id"), second.fetch("generation_id")
    assert_equal kickstarts, @commands.count { |argv| argv.include?("kickstart") }
    assert_operator first.fetch("pid"), :>, 0
  end

  def test_mismatched_retained_runtime_fails_closed
    supervisor = build_supervisor
    supervisor.ensure_running!(
      binding: @binding, ssh_public_key_path: "fixture.pub", heartbeat_timeout_seconds: 30
    )
    path = controller_path("runtime.json")
    row = JSON.parse(File.read(path))
    row["binding_sha256"] = "c" * 64
    File.write(path, JSON.generate(row))

    error = assert_raises(RunpodOllamaFleet::CampaignControllerSupervisor::Error) do
      supervisor.status(binding: @binding)
    end
    assert_includes error.message, "identity"
  end

  def test_disable_removes_restart_condition_before_bootout
    supervisor = build_supervisor
    supervisor.ensure_running!(
      binding: @binding, ssh_public_key_path: "fixture.pub", heartbeat_timeout_seconds: 30
    )

    result = supervisor.disable!(binding: @binding)

    assert_equal "STOPPED", result.fetch("state")
    refute File.exist?(controller_path("enabled"))
    assert @commands.any? { |argv| argv.include?("bootout") }
  end

  private

  def artifact(name)
    path = File.join(@tmp, name)
    File.write(path, "#{name}\n")
    path
  end

  def controller_path(name)
    File.join(File.dirname(@binding.state_path), "controller", name)
  end

  def build_supervisor
    runner = lambda do |argv|
      @commands << argv
      case argv[1]
      when "print" then ["", "", @loaded ? 0 : 1]
      when "bootstrap" then @loaded = true; ["", "", 0]
      when "kickstart"
        request = JSON.parse(File.read(controller_path("request.json")))
        File.write(controller_path("runtime.json"), JSON.generate(
          "contract_version" => RunpodOllamaFleet::CampaignController::CONTRACT_VERSION,
          "campaign_identity_sha256" => @binding.campaign.identity_sha256,
          "binding_sha256" => @binding.binding_sha256,
          "budget_id" => "budget-1", "generation_id" => request.fetch("generation_id"),
          "pid" => Process.pid + 1, "state" => "RUNNING",
          "started_at_utc" => @now.iso8601, "last_heartbeat_at_utc" => @now.iso8601,
          "last_reconciliation_at_utc" => @now.iso8601, "last_action" => "none", "last_error" => nil
        ))
        ["", "", 0]
      when "bootout" then @loaded = false; ["", "", 0]
      else ["", "unexpected", 1]
      end
    end
    RunpodOllamaFleet::CampaignControllerSupervisor.new(
      root: @tmp, repo_root: @repo, campaign_path: @campaign_path,
      budget_path: @budget_path, hardware_path: @hardware_path,
      command_runner: runner, sleeper: ->(*) {}, monotonic_clock: -> { 0 },
      wall_clock: -> { @now }, platform: "arm64-darwin"
    )
  end
end
