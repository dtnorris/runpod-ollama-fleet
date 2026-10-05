# frozen_string_literal: true

require_relative "test_helper"
require "json"
require "open3"
require "rbconfig"
require "digest"
require_relative "../lib/runpod_ollama_fleet"

class RpofBoundedFleetCliTest < Minitest::Test
  ExitStatus = Struct.new(:exitstatus) do
    def success?
      exitstatus.zero?
    end
  end

  ROOT = File.expand_path("..", __dir__)

  def setup
    @tmp = Dir.mktmpdir("rpof-bounded-fleet-cli-")
    @state_root = File.join(@tmp, "state")
    @capability = File.join(@tmp, "capability.json")
    File.write(@capability, JSON.pretty_generate(
      "contract_version" => "ollama-capability-request/v0.1",
      "ollama" => {
        "model" => "qwen3.6:27b",
        "expected_digest" => "a" * 64,
        "required_context_length" => 131_072,
        "require_fully_gpu_resident" => true
      }
    ))
  end

  def teardown
    FileUtils.remove_entry(@tmp) if @tmp && File.exist?(@tmp)
  end

  def test_preview_is_read_only_and_unknown_options_fail
    stdout, stderr, status = run_cli("preview", "--json")

    assert status.success?, stderr
    result = JSON.parse(stdout)
    assert result.fetch("read_only")
    assert_equal "ACCEPTED", result.dig("validation", "bounded_intent")
    refute File.exist?(@state_root)

    _stdout, stderr, status = run_cli("preview", "--not-an-option")
    refute status.success?
    assert_includes stderr, "invalid option"
    refute File.exist?(@state_root)

    _stdout, stderr, status = run_cli("preview", "--interval", "5")
    refute status.success?
    assert_includes stderr, "valid only for bounded-fleet view"
  end

  def test_missing_bound_and_invalid_values_fail_without_persisting
    argv = common_argv.dup
    missing_index = argv.index("--max-cumulative-compute-usd")
    argv.slice!(missing_index, 2)
    _stdout, stderr, status = capture("preview", *argv)
    refute status.success?
    assert_includes stderr, "--max-cumulative-compute-usd"

    stdout, stderr, status = run_cli("preview", "--desired-workers", "0")
    refute status.success?, stdout
    assert_includes stderr, "positive integer"
    refute File.exist?(@state_root)
  end

  def test_start_requires_explicit_paid_authorization_before_retaining_authority
    _stdout, stderr, status = run_cli("start")

    refute status.success?
    assert_includes stderr, "--authorize-paid"
    refute File.exist?(@state_root)
  end

  def test_authorized_start_retains_owner_artifacts_then_uses_existing_paid_start_gate
    _stdout, stderr, status, exec_argv = run_cli("start", "--authorize-paid", intercept_exec: true)

    assert status.success?, stderr
    assert_includes stderr, "Attached view after successful start"
    assert_includes stderr, "Explicit teardown: bin/rpof campaign stop"
    paths = Dir.glob(File.join(@state_root, "bounded-fleets", "*", "*.json"))
    assert_equal 3, paths.length
    contracts = paths.to_h { |path| [File.basename(path), JSON.parse(File.read(path))["contract_version"]] }
    assert_equal "rpof-capacity-campaign/v0.1", contracts.fetch("campaign.json")
    assert_equal "rpof-capacity-campaign-budget/v0.1", contracts.fetch("budget.json")
    assert_equal "ollama-capability-request/v0.1", contracts.fetch("ollama-capability-request.json")
    assert_equal RbConfig.ruby, exec_argv.fetch(0)
    assert_equal File.join(ROOT, "bin", "rpof-campaign"), exec_argv.fetch(1)
    assert_equal "start", exec_argv.fetch(2)
    assert_includes exec_argv, "--authorize-paid"
    assert_includes exec_argv, "--capability-request"
  end

  def test_attached_view_and_ctrl_c_are_observational_only
    retain_intent
    before = retained_hashes
    result = {
      "command" => "campaign status",
      "read_only" => true,
      "campaign" => { "campaign_id" => "fleet-a-production" },
      "desired_capacity" => { "profiles" => [{ "desired_workers" => 1 }] },
      "budget_state" => "ARMED",
      "guardian_healthy" => true,
      "deadline_at_utc" => "2030-01-01T01:00:00Z",
      "active_workers" => 1,
      "pending_workers" => 0,
      "active_plus_pending_hourly_rate_usd" => 0.49,
      "max_aggregate_hourly_rate_usd" => 0.60,
      "reserved_maximum_liability_usd" => 0.10,
      "max_cumulative_compute_usd" => 0.40,
      "controller" => { "state" => "RUNNING", "pid" => 1234 },
      "profiles" => [{
        "profile_id" => "qwen",
        "provider_active_workers" => 1,
        "bootstrap_passed_workers" => 1,
        "tunnel_established_workers" => 1,
        "registry_ready_workers" => 1,
        "desired_workers" => 1
      }],
      "teardown_reason" => nil,
      "provider_absence_verified_at_utc" => nil
    }
    response = [JSON.generate(result), "", ExitStatus.new(0)]
    argv = [
      "view", "--campaign-id", "fleet-a-production", "--state-root", @state_root,
      "--once", "--json"
    ]

    stdout, stderr, status, = Open3.stub(:capture3, response) { capture_loaded(argv) }
    assert status.success?, stderr
    assert_equal result, JSON.parse(stdout)
    assert_equal before, retained_hashes

    human_argv = [
      "view", "--campaign-id", "fleet-a-production", "--state-root", @state_root, "--once"
    ]
    stdout, stderr, status, = Open3.stub(:capture3, response) { capture_loaded(human_argv) }
    assert status.success?, stderr
    assert_includes stdout, "ATTACHED READ-ONLY fleet view"
    assert_equal before, retained_hashes

    interrupter = ->(*_arguments) { raise Interrupt }
    _stdout, stderr, status, = Open3.stub(:capture3, interrupter) { capture_loaded(argv) }
    assert status.success?
    assert_includes stderr, "View detached"
    assert_includes stderr, "were not changed"
    assert_equal before, retained_hashes
  end

  private

  def run_cli(command, *extra, env: {}, intercept_exec: false)
    capture_loaded([command, *common_argv, *extra], env:, intercept_exec:)
  end

  def common_argv
    [
      "--campaign-id", "fleet-a-production",
      "--profile-id", "qwen27",
      "--capability-request", @capability,
      "--desired-workers", "1",
      "--max-workers", "2",
      "--max-hourly-rate-usd", "2.0",
      "--max-cumulative-compute-usd", "5.0",
      "--max-runtime-seconds", "600",
      "--guardian-poll-seconds", "5",
      "--heartbeat-timeout-seconds", "30",
      "--teardown-reserve-seconds", "60",
      "--state-root", @state_root
    ]
  end

  def capture(command, *argv, env: {})
    capture_loaded([command, *argv], env:).first(3)
  end

  def retain_intent
    hardware = RunpodOllamaFleet::ExecutionPoolHardware.new(
      path: File.join(ROOT, "config", "execution_pool_hardware.yml")
    )
    capability = RunpodOllamaFleet::OllamaCapabilityRequest.load(@capability)
    RunpodOllamaFleet::BoundedFleetIntent.new(
      state_root: @state_root, repo_root: ROOT, hardware:, capability_request: capability,
      campaign_id: "fleet-a-production", profile_id: "qwen27", desired_workers: 1,
      max_workers: 2, max_hourly_rate_usd: 2.0, max_cumulative_compute_usd: 5.0,
      max_runtime_seconds: 600.0, guardian_poll_seconds: 5.0,
      orchestrator_heartbeat_timeout_seconds: 30.0, teardown_reserve_seconds: 60.0
    ).persist!
  end

  def retained_hashes
    Dir.glob(File.join(@state_root, "**", "*"), File::FNM_DOTMATCH).select { |path| File.file?(path) }.to_h do |path|
      [path.delete_prefix("#{@state_root}/"), Digest::SHA256.file(path).hexdigest]
    end
  end

  def capture_loaded(argv, env: {}, intercept_exec: false)
    executable = File.join(ROOT, "bin", "rpof-bounded-fleet")
    previous_argv = ARGV.dup
    clean_env = { "RUNPOD_API_KEY" => nil, "RUNPOD_API_BASE_URL" => nil }.merge(env)
    previous_env = clean_env.to_h { |key, _value| [key, [ENV.key?(key), ENV[key]]] }
    previous_stdout = $stdout
    previous_stderr = $stderr
    stdout = StringIO.new
    stderr = StringIO.new
    exec_argv = nil
    exit_status = 0
    clean_env.each { |key, value| value.nil? ? ENV.delete(key) : ENV.store(key, value) }
    ARGV.replace(argv)
    $stdout = stdout
    $stderr = stderr
    begin
      exec_argv = with_exec_capture(intercept_exec) { Dir.chdir(ROOT) { load executable, true } }
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
      define_method(:exec) do |*arguments|
        exec_argv = arguments
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
