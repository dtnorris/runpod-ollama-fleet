# frozen_string_literal: true

require_relative "test_helper"
require "json"
require "rbconfig"

class RpofCampaignCliTest < Minitest::Test
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

  # These tests exercise the exact executable files, but fork the already
  # loaded test process instead of cold-starting Ruby and the complete RPOF
  # dependency graph for every assertion. exit! prevents inherited Minitest
  # and SimpleCov at_exit hooks from running a second suite in the child.
  def capture_loaded_executable(executable, argv, env:, intercept_exec:)
    stdout_reader, stdout_writer = IO.pipe
    stderr_reader, stderr_writer = IO.pipe
    exec_capture = File.join(@tmp, "exec-#{Process.pid}-#{rand(1_000_000)}.json")

    pid = Process.fork do
      stdout_reader.close
      stderr_reader.close
      STDOUT.reopen(stdout_writer)
      STDERR.reopen(stderr_writer)
      stdout_writer.close
      stderr_writer.close
      $stdout.sync = true
      $stderr.sync = true

      env.each { |key, value| value.nil? ? ENV.delete(key) : ENV.store(key, value) }
      ARGV.replace(argv)
      install_exec_capture(exec_capture) if intercept_exec

      exit_status = 0
      begin
        Dir.chdir(ROOT) { load executable }
      rescue SystemExit => e
        exit_status = e.status
      rescue Exception => e # rubocop:disable Lint/RescueException
        warn "#{e.class}: #{e.message}"
        warn e.backtrace.join("\n")
        exit_status = 1
      ensure
        $stdout.flush
        $stderr.flush
        exit!(exit_status)
      end
    end

    stdout_writer.close
    stderr_writer.close
    stdout_thread = Thread.new { stdout_reader.read }
    stderr_thread = Thread.new { stderr_reader.read }
    _child, status = Process.wait2(pid)
    stdout = stdout_thread.value
    stderr = stderr_thread.value
    exec_argv = JSON.parse(File.binread(exec_capture)) if File.file?(exec_capture)
    [stdout, stderr, status, exec_argv]
  ensure
    stdout_reader&.close unless stdout_reader&.closed?
    stderr_reader&.close unless stderr_reader&.closed?
  end

  def install_exec_capture(path)
    Kernel.module_eval do
      define_method(:exec) do |*args|
        File.binwrite(path, JSON.generate(args))
        raise SystemExit, 0
      end
      private :exec
    end
  end
end
