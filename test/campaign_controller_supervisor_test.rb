# frozen_string_literal: true

require_relative "test_helper"
require "json"
require_relative "../lib/runpod_ollama_fleet"

class CampaignControllerSupervisorTest < Minitest::Test
  Campaign = Struct.new(:identity_sha256, :profiles, :hardware_bindings)
  Binding = Struct.new(:state_path, :binding_sha256, :campaign, :declaration)

  def setup
    @tmp = Dir.mktmpdir("campaign-controller-supervisor-")
    @repo = File.join(@tmp, "repo")
    FileUtils.mkdir_p(File.join(@repo, "bin"))
    File.write(File.join(@repo, "bin", "rpof-campaign-controller"), "#!/usr/bin/env ruby\n")
    @campaign_path = artifact("campaign.json")
    @budget_path = artifact("budget.json")
    @hardware_path = artifact("hardware.yml")
    @capability_path = File.join(@tmp, "ollama-capability-request.json")
    File.write(@capability_path, JSON.generate(capability_request_document))
    binding_dir = File.join(@tmp, "campaign-budgets", "binding")
    FileUtils.mkdir_p(binding_dir)
    @binding = Binding.new(
      File.join(binding_dir, "binding.json"), "b" * 64,
      Campaign.new("a" * 64, [profile], [hardware_binding]),
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

  def test_disable_waits_for_successful_bootout_to_become_observable
    supervisor = build_supervisor(bootout_unload_after_prints: 2)
    supervisor.ensure_running!(
      binding: @binding, ssh_public_key_path: "fixture.pub", heartbeat_timeout_seconds: 30
    )

    result = supervisor.disable!(binding: @binding)

    assert_equal "STOPPED", result.fetch("state")
    refute result.fetch("launchd_loaded")
  end

  def test_request_binds_exact_capability_artifact_and_fingerprint
    supervisor = build_supervisor
    supervisor.ensure_running!(
      binding: @binding, ssh_public_key_path: "fixture.pub", heartbeat_timeout_seconds: 30
    )

    request = JSON.parse(File.binread(controller_path("request.json")))
    row = request.fetch("capability_requests").fetch(0)
    capability = RunpodOllamaFleet::OllamaCapabilityRequest.load(@capability_path)
    assert_equal RunpodOllamaFleet::CampaignControllerSupervisor::REQUEST_CONTRACT_VERSION,
                 request.fetch("contract_version")
    assert_equal "profile-1", row.fetch("profile_id")
    assert_equal Digest::SHA256.file(@capability_path).hexdigest, row.fetch("artifact_sha256")
    assert_equal capability.fingerprint, row.fetch("capability_fingerprint")
    refute request.key?("model_requirements")
  end

  def test_requirement_validation_fails_before_controller_launch
    File.write(@capability_path, JSON.generate(capability_request_document.merge(
      "ollama" => capability_request_document.fetch("ollama").merge("expected_digest" => "d" * 64)
    )))
    supervisor = build_supervisor

    error = assert_raises(RunpodOllamaFleet::CampaignControllerSupervisor::Error) do
      supervisor.validate_requirements!(binding: @binding)
    end

    assert_includes error.message, "expected_digest mismatch"
    assert_empty @commands
  end

  def test_new_campaign_rejects_legacy_af_shaped_input_before_controller_launch
    File.write(@capability_path, JSON.generate(model_requirement_document))
    supervisor = build_supervisor

    error = assert_raises(RunpodOllamaFleet::CampaignControllerSupervisor::Error) do
      supervisor.validate_requirements!(binding: @binding)
    end

    assert_includes error.message, "unknown fields"
    assert_empty @commands
  end

  def test_status_can_resolve_exact_capabilities_from_retained_request
    build_supervisor.ensure_running!(
      binding: @binding, ssh_public_key_path: "fixture.pub", heartbeat_timeout_seconds: 30
    )
    restarted = build_supervisor(capability_request_paths: {})

    requests = restarted.resolved_capability_requests(binding: @binding)

    assert_equal ["profile-1"], requests.keys
    assert_equal RunpodOllamaFleet::OllamaCapabilityRequest.load(@capability_path).fingerprint,
                 requests.fetch("profile-1").fingerprint
  end

  def test_detached_restart_reloads_exact_generic_request_identity
    supervisor = build_supervisor
    supervisor.ensure_running!(
      binding: @binding, ssh_public_key_path: "fixture.pub", heartbeat_timeout_seconds: 30
    )
    original_artifact = File.binread(@capability_path)
    original_request = JSON.parse(File.binread(controller_path("request.json")))

    supervisor.disable!(binding: @binding)
    restarted = build_supervisor(capability_request_paths: {})
    result = restarted.ensure_running!(
      binding: @binding, ssh_public_key_path: "ignored.pub", heartbeat_timeout_seconds: 30
    )

    restarted_request = JSON.parse(File.binread(controller_path("request.json")))
    assert_equal original_artifact, File.binread(@capability_path)
    assert_equal original_request.fetch("capability_requests"), restarted_request.fetch("capability_requests")
    refute_equal original_request.fetch("generation_id"), result.fetch("generation_id")
  end

  def test_legacy_retained_request_is_readable_and_not_rewritten
    write_legacy_retained_request
    original = File.binread(controller_path("request.json"))
    supervisor = build_supervisor(capability_request_paths: {})

    requests = supervisor.resolved_capability_requests(binding: @binding)
    supervisor.ensure_running!(
      binding: @binding, ssh_public_key_path: "ignored.pub", heartbeat_timeout_seconds: 30
    )

    assert_instance_of RunpodOllamaFleet::ModelRequirement, requests.fetch("profile-1")
    assert_equal original, File.binread(controller_path("request.json"))
    assert_equal "budget-1", JSON.parse(original).fetch("budget_id")
  end

  def test_new_generic_input_cannot_enter_legacy_retained_reader
    write_legacy_retained_request
    supervisor = build_supervisor

    error = assert_raises(RunpodOllamaFleet::CampaignControllerSupervisor::Error) do
      supervisor.validate_requirements!(binding: @binding)
    end
    assert_includes error.message, "cannot use the legacy retained-state reader"
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

  def build_supervisor(capability_request_paths: { "profile-1" => @capability_path },
                       bootout_unload_after_prints: 0)
    pending_unload_prints = 0
    runner = lambda do |argv|
      @commands << argv
      case argv[1]
      when "print"
        if pending_unload_prints.positive?
          pending_unload_prints -= 1
          @loaded = false if pending_unload_prints.zero?
        end
        ["", "", @loaded ? 0 : 1]
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
      when "bootout"
        pending_unload_prints = bootout_unload_after_prints
        @loaded = false if pending_unload_prints.zero?
        ["", "", 0]
      else ["", "unexpected", 1]
      end
    end
    RunpodOllamaFleet::CampaignControllerSupervisor.new(
      root: @tmp, repo_root: @repo, campaign_path: @campaign_path,
      budget_path: @budget_path, hardware_path: @hardware_path,
      capability_request_paths:,
      command_runner: runner, sleeper: ->(*) {}, monotonic_clock: -> { 0 },
      wall_clock: -> { @now }, platform: "arm64-darwin"
    )
  end

  def profile
    {
      "profile_id" => "profile-1",
      "model" => "qualified-model:latest",
      "expected_digest" => "c" * 64,
      "required_context_length" => 131_072,
      "require_fully_gpu_resident" => true
    }
  end

  def hardware_binding
    { "profile_id" => "profile-1", "qualified_gpu_ids" => ["NVIDIA A40"] }
  end

  def capability_request_document
    {
      "contract_version" => "ollama-capability-request/v0.1",
      "ollama" => {
        "model" => "qualified-model:latest",
        "expected_digest" => "c" * 64,
        "required_context_length" => 131_072,
        "require_fully_gpu_resident" => true,
        "required_gpu_id" => "NVIDIA A40"
      }
    }
  end

  def model_requirement_document
    {
      "contract_version" => "adventurefinder-model-requirement/v0.1",
      "batch_handle" => "39",
      "production_batch_id" => "production-batch-039",
      "plan_id" => "production-batch-039",
      "plan_sha256" => "e" * 64,
      "alias" => "qualified",
      "pool_id" => "profile-1",
      "required_labels" => ["inference"],
      "ollama" => {
        "model" => "qualified-model:latest",
        "expected_digest" => "c" * 64,
        "required_context_length" => 131_072,
        "require_fully_gpu_resident" => true,
        "required_gpu_id" => "NVIDIA A40"
      }
    }
  end

  def write_legacy_retained_request
    FileUtils.mkdir_p(File.dirname(controller_path("request.json")))
    legacy_path = File.join(@tmp, "legacy-model-requirement.json")
    File.write(legacy_path, JSON.generate(model_requirement_document))
    requirement = RunpodOllamaFleet::ModelRequirement.load(legacy_path)
    request = {
      "contract_version" => RunpodOllamaFleet::CampaignControllerSupervisor::LEGACY_REQUEST_CONTRACT_VERSION,
      "campaign_identity_sha256" => @binding.campaign.identity_sha256,
      "binding_sha256" => @binding.binding_sha256,
      "budget_id" => "budget-1",
      "generation_id" => "legacy-generation",
      "campaign_path" => @campaign_path,
      "campaign_sha256" => Digest::SHA256.file(@campaign_path).hexdigest,
      "budget_path" => @budget_path,
      "budget_sha256" => Digest::SHA256.file(@budget_path).hexdigest,
      "hardware_path" => @hardware_path,
      "hardware_sha256" => Digest::SHA256.file(@hardware_path).hexdigest,
      "model_requirements" => [{
        "profile_id" => "profile-1",
        "path" => legacy_path,
        "artifact_sha256" => Digest::SHA256.file(legacy_path).hexdigest,
        "requirement_sha256" => requirement.fingerprint
      }],
      "controller_executable_sha256" => "f" * 64,
      "state_root" => @tmp,
      "repo_root" => @repo,
      "ssh_public_key_path" => "/tmp/legacy.pub",
      "heartbeat_seconds" => 10.0
    }
    File.write(controller_path("request.json"), JSON.pretty_generate(request) + "\n")
  end
end
