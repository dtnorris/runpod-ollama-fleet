# frozen_string_literal: true

require_relative "test_helper"
require "json"
require "rbconfig"
require_relative "../lib/runpod_ollama_fleet"

class RpofCampaignCliTest < Minitest::Test
  ExitStatus = Struct.new(:exitstatus) do
    def success?
      exitstatus.zero?
    end
  end

  ROOT = File.expand_path("..", __dir__)
  CAMPAIGN = File.join(ROOT, "test", "fixtures", "rpof-capacity-campaign-v0.1.json")
  BUDGET = File.join(ROOT, "test", "fixtures", "rpof-capacity-campaign-budget-v0.1.json")

  def setup
    @tmp = Dir.mktmpdir("rpof-campaign-cli-")
  end

  def teardown
    FileUtils.remove_entry(@tmp) if @tmp && File.exist?(@tmp)
  end

  def test_plan_json_is_read_only_without_credentials
    expected = {
      "command" => "campaign plan",
      "read_only" => true,
      "paid_resources_created" => false,
      "campaign" => { "campaign_id" => "production-batch-039" }
    }
    stdout, stderr, status = with_stubbed_campaign(:plan, expected) { run_cli("plan", "--json") }

    assert status.success?, stderr
    assert_equal expected, JSON.parse(stdout)
    refute File.exist?(File.join(@tmp, "campaign-budgets"))
  end

  def test_consumer_bind_passes_exact_document_without_provider_access
    document = { "contract_version" => "rpof-consumer-binding/v0.1" }
    path = File.join(@tmp, "binding.json")
    File.write(path, JSON.generate(document))
    received = nil
    stdout, stderr, status = with_stubbed_campaign(:bind_consumer, document, argument_sink: ->(args) { received = args }) do
      run_cli("consumer-bind", "--consumer-binding", path, "--json")
    end
    assert status.success?, stderr
    assert_equal document, received
    assert_equal document, JSON.parse(stdout)
    _stdout, stderr, status = run_cli("plan", "--consumer-binding", path)
    refute status.success?
    assert_includes stderr, "only for consumer-bind"
  end

  def test_start_without_authorization_prints_plan_and_exits_before_mutation
    expected = {
      "command" => "campaign plan",
      "read_only" => true,
      "paid_resources_created" => false,
      "authorization_required" => true,
      "message" => "no paid mutation attempted; repeat with --authorize-paid",
      "campaign" => { "campaign_id" => "production-batch-039" }
    }
    stdout, stderr, status = with_stubbed_campaign(:start, expected) { run_cli("start", "--json") }

    assert_equal 2, status.exitstatus, stderr
    result = JSON.parse(stdout)
    assert_equal "campaign plan", result.fetch("command")
    assert result.fetch("authorization_required")
    assert result.fetch("read_only")
    refute result.fetch("paid_resources_created")
    assert_equal "production-batch-039", result.dig("campaign", "campaign_id")
    assert_equal "no paid mutation attempted; repeat with --authorize-paid", result.fetch("message")
    refute File.exist?(File.join(@tmp, "campaign-budgets"))
  end

  def test_top_level_campaign_dispatch_preserves_command_surface
    stdout, stderr, status, exec_argv = run_cli("plan", "--json", top_level: true)

    assert status.success?, stderr
    assert_empty stdout
    assert_equal [
      RbConfig.ruby, File.join(ROOT, "bin", "rpof-campaign"),
      "plan", "--campaign", CAMPAIGN, "--budget", BUDGET,
      "--state-root", @tmp, "--json"
    ], exec_argv
  end

  def test_campaign_status_labels_provider_active_and_registry_ready_separately
    expected = {
      "command" => "campaign status",
      "read_only" => true,
      "campaign" => { "campaign_id" => "production-batch-039" },
      "budget_state" => "ARMED",
      "guardian_healthy" => true,
      "deadline_at_utc" => "2030-01-01T01:00:00Z",
      "active_workers" => 1,
      "pending_workers" => 0,
      "max_workers" => 2,
      "active_plus_pending_hourly_rate_usd" => 0.49,
      "max_aggregate_hourly_rate_usd" => 2.0,
      "reserved_maximum_liability_usd" => 5.0,
      "max_cumulative_compute_usd" => 10.0,
      "pending_ambiguous_reservations" => [],
      "profiles" => [{
        "profile_id" => "gptoss",
        "provider_active_workers" => 1,
        "registry_status" => "available",
        "registry_ready_workers" => 0,
        "registry_not_ready_workers" => 1,
        "registry_unpublished_workers" => 0,
        "bootstrap_passed_workers" => 1,
        "tunnel_established_workers" => 1,
        "desired_workers" => 1,
        "max_workers" => 2
      }]
    }

    stdout, stderr, status = with_stubbed_campaign(:status, expected) { run_cli("status") }

    assert status.success?, stderr
    assert_includes stdout, "provider-active=1 registry-ready=0"
    assert_includes stdout, "registry-not-ready=1"
    refute_includes stdout, " ready="
  end

  def test_desired_json_is_read_only_and_provider_neutral
    expected = {
      "command" => "campaign desired",
      "read_only" => true,
      "provider_mutations" => 0,
      "actual_capacity_unchanged" => true,
      "campaign" => { "campaign_id" => "production-batch-039" },
      "desired_capacity" => { "contract_version" => "rpof-desired-capacity/v0.1", "revision" => 0 }
    }

    stdout, stderr, status = with_stubbed_campaign(:desired, expected) { run_cli("desired", "--json") }

    assert status.success?, stderr
    assert_equal expected, JSON.parse(stdout)
  end

  def test_desired_set_requires_compare_and_set_inputs_and_reports_no_provider_mutation
    expected = {
      "command" => "campaign desired-set",
      "updated" => true,
      "provider_mutations" => 0,
      "actual_capacity_unchanged" => true,
      "campaign" => { "campaign_id" => "production-batch-039" },
      "desired_capacity" => { "contract_version" => "rpof-desired-capacity/v0.1", "revision" => 1 }
    }
    received = nil
    stdout, stderr, status = with_stubbed_campaign(
      :set_desired, expected, argument_sink: ->(arguments) { received = arguments }
    ) do
      run_cli(
        "desired-set", "--profile", "qwen35=0", "--expected-revision", "0",
        "--reason", "hold qwen35", "--json"
      )
    end

    assert status.success?, stderr
    assert_equal expected, JSON.parse(stdout)
    assert_equal({
                   profile_counts: { "qwen35" => 0 },
                   expected_revision: 0,
                   reason: "hold qwen35"
                 }, received)

    _stdout, stderr, status = run_cli("desired-set", "--profile", "qwen35=0", "--json")
    refute status.success?
    assert_includes stderr, "--expected-revision"
  end

  def test_add_routes_absolute_target_and_revision_to_existing_campaign
    received = nil
    result = { "command" => "campaign add", "provider_mutations" => 0 }
    stdout, stderr, status = with_stubbed_campaign(:add, result, argument_sink: ->(args) { received = args }) do
      run_cli("add", "--profile", "qwen35=2", "--expected-revision", "3", "--reason", "add", "--json")
    end
    assert status.success?, stderr
    assert_equal result, JSON.parse(stdout)
    assert_equal({ profile_counts: { "qwen35" => 2 }, expected_revision: 3, reason: "add" }, received)
  end

  def test_selected_control_passes_exact_identity_confirmation_and_revision
    received = nil
    result = { "command" => "campaign remove", "provider_mutations" => 0 }
    stdout, stderr, status = with_stubbed_campaign(:select_worker, result, argument_sink: ->(args) { received = args }) do
      run_cli("remove", "--profile-id", "qwen35", "--fleet-id", "fleet-1", "--worker-id", "worker-1",
              "--generation-id", "generation-1", "--pod-id", "pod-1", "--expected-revision", "1",
              "--reason", "operator confirmed", "--confirm-remove", "--json")
    end
    assert status.success?, stderr
    assert_equal result, JSON.parse(stdout)
    assert_equal({ operation: "remove", profile_id: "qwen35", fleet_id: "fleet-1", worker_id: "worker-1",
                   generation_id: "generation-1", pod_id: "pod-1", expected_revision: 1,
                   reason: "operator confirmed", confirm: true }, received)
    _stdout, stderr, status = run_cli("drain", "--profile-id", "qwen35")
    refute status.success?
    assert_includes stderr, "--fleet-id"
  end

  private

  def with_stubbed_campaign(action, result, argument_sink: nil)
    hardware = Object.new
    campaign = Object.new
    binding = Object.new
    lifecycle = Object.new
    lifecycle.define_singleton_method(action) do |*positional, **arguments|
      argument_sink&.call(positional.first || arguments)
      result
    end

    RunpodOllamaFleet::ExecutionPoolHardware.stub(:new, hardware) do
      RunpodOllamaFleet::CapacityCampaign.stub(:load, campaign) do
        RunpodOllamaFleet::CampaignBudgetBinding.stub(:new, binding) do
          RunpodOllamaFleet::CampaignLifecycle.stub(:new, lifecycle) { yield }
        end
      end
    end
  end

  def run_cli(command, *extra, top_level: false)
    executable = File.join(ROOT, "bin", top_level ? "rpof" : "rpof-campaign")
    argv = []
    argv << "campaign" if top_level
    argv.concat([
      command, "--campaign", CAMPAIGN, "--budget", BUDGET,
      "--state-root", @tmp, *extra
    ])
    env = { "RUNPOD_API_KEY" => nil, "RUNPOD_API_BASE_URL" => nil }
    capture_loaded_executable(executable, argv, env:, intercept_exec: top_level)
  end

  # Exercise the exact executable files inside an anonymous module. This keeps
  # executable constants and helper methods isolated without paying the
  # platform-sensitive cost of forking the complete test process.
  def capture_loaded_executable(executable, argv, env:, intercept_exec:)
    previous_argv = ARGV.dup
    previous_env = env.to_h { |key, _value| [key, [ENV.key?(key), ENV[key]]] }
    previous_stdout = $stdout
    previous_stderr = $stderr
    stdout = StringIO.new
    stderr = StringIO.new
    exec_argv = nil
    exit_status = 0

    env.each { |key, value| value.nil? ? ENV.delete(key) : ENV.store(key, value) }
    ARGV.replace(argv)
    $stdout = stdout
    $stderr = stderr

    begin
      exec_argv = with_exec_capture(intercept_exec) do
        Dir.chdir(ROOT) { load executable, true }
        nil
      end
    rescue SystemExit => e
      exit_status = e.status
    end

    [stdout.string, stderr.string, ExitStatus.new(exit_status), exec_argv]
  ensure
    ARGV.replace(previous_argv) if previous_argv
    previous_env&.each do |key, (present, value)|
      present ? ENV.store(key, value) : ENV.delete(key)
    end
    $stdout = previous_stdout if previous_stdout
    $stderr = previous_stderr if previous_stderr
  end

  def with_exec_capture(enabled)
    return yield unless enabled

    original_exec = Kernel.instance_method(:exec)
    exec_argv = nil
    Kernel.module_eval do
      define_method(:exec) do |*args|
        exec_argv = args
        raise SystemExit, 0
      end
      private :exec
    end

    yield
  rescue SystemExit => e
    raise unless e.success?

    exec_argv
  ensure
    if original_exec
      Kernel.module_eval do
        define_method(:exec, original_exec)
        private :exec
      end
    end
  end
end
