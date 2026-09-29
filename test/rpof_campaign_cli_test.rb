# frozen_string_literal: true

require_relative "test_helper"
require "json"
require "rbconfig"

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
    stdout, stderr, status = run_cli("plan", "--json")

    assert status.success?, stderr
    result = JSON.parse(stdout)
    assert result.fetch("read_only")
    refute result.fetch("paid_resources_created")
    assert_equal "production-batch-039", result.dig("campaign", "campaign_id")
    refute File.exist?(File.join(@tmp, "campaign-budgets"))
  end

  def test_start_without_authorization_prints_plan_and_exits_before_mutation
    stdout, stderr, status = run_cli("start", "--json")

    assert_equal 2, status.exitstatus, stderr
    assert JSON.parse(stdout).fetch("authorization_required")
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

  private

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
