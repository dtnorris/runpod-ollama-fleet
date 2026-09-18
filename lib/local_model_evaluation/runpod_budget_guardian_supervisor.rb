# frozen_string_literal: true

require "digest"
require "fileutils"
require "json"
require "open3"
require "rbconfig"
require "time"

module LocalModelEvaluation
  class RunpodBudgetGuardianSupervisor
    class Error < StandardError; end

    def initialize(root:, repo_root:, command_runner: nil, sleeper: nil, monotonic_clock: nil, platform: RUBY_PLATFORM)
      @root = File.expand_path(root)
      @repo_root = File.expand_path(repo_root)
      state_root = ENV["RPOF_STATE_ROOT"].to_s.strip
      state_repo_root = ENV["RPOF_STATE_REPO_ROOT"].to_s.strip
      @fleet_state_root = File.expand_path(state_root.empty? ? @root : state_root)
      @fleet_state_repo_root = File.expand_path(state_repo_root.empty? ? @repo_root : state_repo_root)
      @command_runner = command_runner || lambda do |argv|
        stdout, stderr, status = Open3.capture3(*argv)
        [stdout, stderr, status.exitstatus]
      end
      @sleeper = sleeper || ->(seconds) { sleep seconds }
      @monotonic_clock = monotonic_clock || -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) }
      @platform = platform.to_s
    end

    def arm!(budget:, request:)
      prior = existing_budget_snapshot(budget)
      if prior && prior.fetch("state") == "CLOSED"
        raise Error, "closed budget cannot be resumed"
      end

      paths = paths_for(budget)
      FileUtils.mkdir_p(paths.fetch(:guardian_dir))
      write_json_atomic(paths.fetch(:request_path), request)
      File.write(paths.fetch(:enabled_path), "enabled\n")
      File.chmod(0o600, paths.fetch(:enabled_path))
      File.delete(paths.fetch(:runtime_path)) if File.file?(paths.fetch(:runtime_path))
      write_plist(paths:, budget:)
      ensure_launchd_running!(paths)
      runtime = wait_for_runtime(paths.fetch(:runtime_path), request.fetch("guardian_poll_seconds")) do |row|
        row["ready"] == true && row["provider_probe_at_utc"] && independent_guardian_pid?(row)
      end

      if prior && prior.fetch("state") == "TEARDOWN_REQUIRED"
        raise Error, "existing budget requires teardown and cannot be resumed; independent guardian is running"
      end

      # Re-evaluate after the guardian restart/probe window. A slow restart must
      # not refresh away a guardian-heartbeat lapse on an already-armed budget.
      after_start = existing_budget_snapshot(budget)
      if after_start && after_start.fetch("state") == "TEARDOWN_REQUIRED"
        raise Error, "budget became teardown-required while restarting its guardian; cannot resume"
      end

      snapshot = budget.arm!(
        budget: request,
        guardian_heartbeat_at_utc: runtime.fetch("provider_probe_at_utc")
      )

      wait_for_runtime(paths.fetch(:runtime_path), request.fetch("guardian_poll_seconds")) do |row|
        row["ledger_heartbeat_at_utc"] && row["state"] != "WAITING_FOR_ARM" && independent_guardian_pid?(row)
      end
      snapshot = budget.status
      unless snapshot.fetch("state") == "ARMED" && snapshot.fetch("mutation_allowed") == true
        raise Error, "guardian started but budget is not mutation-ready"
      end
      snapshot
    rescue RunpodBudget::Error, SystemCallError, JSON::ParserError, KeyError, ArgumentError, TypeError => e
      raise Error, e.message
    end

    def status(budget:)
      paths = paths_for(budget)
      runtime = File.file?(paths.fetch(:runtime_path)) ? JSON.parse(File.read(paths.fetch(:runtime_path))) : {}
      runtime.merge(
        "launchd_label" => paths.fetch(:label),
        "enabled" => File.file?(paths.fetch(:enabled_path)),
        "launchd_loaded" => launchd_loaded?(paths.fetch(:domain), paths.fetch(:label))
      )
    rescue JSON::ParserError, SystemCallError => e
      raise Error, "guardian status is unreadable: #{e.message}"
    end

    def disable!(budget:)
      paths = paths_for(budget)
      File.delete(paths.fetch(:enabled_path)) if File.file?(paths.fetch(:enabled_path))
      run_command(["/bin/launchctl", "bootout", "#{paths.fetch(:domain)}/#{paths.fetch(:label)}"], allow_failure: true)
      true
    end

    private

    def paths_for(budget)
      budget_dir = File.dirname(budget.state_path)
      guardian_dir = File.join(budget_dir, "guardian")
      identity = Digest::SHA256.hexdigest("#{budget.budget_id}\0#{budget.plan_sha256}")[0, 20]
      label = "com.adventurefinder.rpof-budget-#{identity}"
      {
        guardian_dir:,
        request_path: File.join(guardian_dir, "request.json"),
        runtime_path: File.join(guardian_dir, "runtime.json"),
        enabled_path: File.join(guardian_dir, "enabled"),
        plist_path: File.join(guardian_dir, "#{label}.plist"),
        log_path: File.join(guardian_dir, "guardian.log"),
        label:,
        domain: launchd_domain
      }
    end

    def launchd_domain
      unless @platform.include?("darwin")
        raise Error, "independent production-budget guardian requires macOS launchd"
      end
      "gui/#{Process.uid}"
    end

    def write_plist(paths:, budget:)
      script = File.join(@repo_root, "bin", "rpof-budget-guardian")
      raise Error, "guardian executable is missing: #{script}" unless File.file?(script)

      args = [
        RbConfig.ruby,
        script,
        "--state-root", @root,
        "--repo-root", @repo_root,
        "--fleet-state-root", @fleet_state_root,
        "--fleet-state-repo-root", @fleet_state_repo_root,
        "--budget-id", budget.budget_id,
        "--plan-sha256", budget.plan_sha256,
        "--enabled", paths.fetch(:enabled_path),
        "--runtime", paths.fetch(:runtime_path)
      ]
      plist = <<~PLIST
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
          <key>Label</key>
          <string>#{xml(paths.fetch(:label))}</string>
          <key>ProgramArguments</key>
          <array>
        #{args.map { |arg| "    <string>#{xml(arg)}</string>" }.join("\n")}
          </array>
          <key>WorkingDirectory</key>
          <string>#{xml(@repo_root)}</string>
          <key>RunAtLoad</key>
          <true/>
          <key>KeepAlive</key>
          <dict>
            <key>PathState</key>
            <dict>
              <key>#{xml(paths.fetch(:enabled_path))}</key>
              <true/>
            </dict>
          </dict>
          <key>ThrottleInterval</key>
          <integer>1</integer>
          <key>StandardOutPath</key>
          <string>#{xml(paths.fetch(:log_path))}</string>
          <key>StandardErrorPath</key>
          <string>#{xml(paths.fetch(:log_path))}</string>
        </dict>
        </plist>
      PLIST
      File.write(paths.fetch(:plist_path), plist)
      File.chmod(0o600, paths.fetch(:plist_path))
    end

    def ensure_launchd_running!(paths)
      domain = paths.fetch(:domain)
      label = paths.fetch(:label)
      unless launchd_loaded?(domain, label)
        _stdout, stderr, exit_status = run_command(
          ["/bin/launchctl", "bootstrap", domain, paths.fetch(:plist_path)],
          allow_failure: true
        )
        unless exit_status.zero? || launchd_loaded?(domain, label)
          raise Error, "could not bootstrap budget guardian with launchd: #{stderr.strip}"
        end
      end

      _stdout, stderr, exit_status = run_command(
        ["/bin/launchctl", "kickstart", "-k", "#{domain}/#{label}"],
        allow_failure: true
      )
      unless exit_status.zero?
        raise Error, "could not start budget guardian with launchd: #{stderr.strip}"
      end
    end

    def launchd_loaded?(domain, label)
      _stdout, _stderr, status = run_command(
        ["/bin/launchctl", "print", "#{domain}/#{label}"],
        allow_failure: true
      )
      status.zero?
    end

    def wait_for_runtime(path, guardian_poll_seconds)
      timeout = [10.0, Float(guardian_poll_seconds) * 3.0].max
      deadline = @monotonic_clock.call + timeout
      loop do
        if File.file?(path)
          row = JSON.parse(File.read(path))
          return row if yield(row)
          if row["last_error"]
            raise Error, "guardian reported startup error: #{row.fetch('last_error')}"
          end
        end
        raise Error, "timed out waiting for independent budget guardian readiness" if @monotonic_clock.call >= deadline
        @sleeper.call(0.1)
      end
    end

    def run_command(argv, allow_failure: false)
      stdout, stderr, exit_status = @command_runner.call(argv)
      exit_status = Integer(exit_status)
      if !allow_failure && !exit_status.zero?
        raise Error, "#{argv.first} failed with exit #{exit_status}: #{stderr}"
      end
      [stdout.to_s, stderr.to_s, exit_status]
    rescue ArgumentError, TypeError => e
      raise Error, "guardian supervisor command failed: #{e.message}"
    end

    def write_json_atomic(path, document)
      tmp = "#{path}.tmp.#{$$}"
      File.write(tmp, JSON.pretty_generate(document) + "\n")
      File.chmod(0o600, tmp)
      File.rename(tmp, path)
    ensure
      File.delete(tmp) if defined?(tmp) && tmp && File.exist?(tmp)
    end

    def existing_budget_snapshot(budget)
      budget.evaluate!
    rescue RunpodBudget::Error => e
      raise unless e.message.start_with?("budget is not armed:")
      nil
    end

    def independent_guardian_pid?(row)
      pid = Integer(row.fetch("pid"))
      pid.positive? && pid != Process.pid
    rescue KeyError, ArgumentError, TypeError
      false
    end

    def xml(value)
      value.to_s
           .gsub("&", "&amp;")
           .gsub("<", "&lt;")
           .gsub(">", "&gt;")
           .gsub('"', "&quot;")
           .gsub("'", "&apos;")
    end
  end
end
