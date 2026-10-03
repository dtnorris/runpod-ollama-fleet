# frozen_string_literal: true

require "digest"
require "fileutils"
require "json"
require "open3"
require "rbconfig"
require "securerandom"
require "time"
require_relative "model_requirement"

module RunpodOllamaFleet
  # Per-user launchd supervision for the continuing campaign controller. This
  # owns process liveness only; CampaignBudgetBinding remains the sole authority.
  class CampaignControllerSupervisor
    REQUEST_CONTRACT_VERSION = "rpof-campaign-controller-request/v0.2"

    class Error < StandardError; end

    def initialize(root:, repo_root:, campaign_path:, budget_path:, hardware_path:,
                   model_requirement_paths: {},
                   command_runner: nil, sleeper: nil, monotonic_clock: nil,
                   wall_clock: nil, platform: RUBY_PLATFORM)
      @root = File.expand_path(root)
      @repo_root = File.expand_path(repo_root)
      @campaign_path = File.expand_path(campaign_path)
      @budget_path = File.expand_path(budget_path)
      @hardware_path = File.expand_path(hardware_path)
      @model_requirement_paths = model_requirement_paths.to_h.transform_keys(&:to_s).transform_values do |path|
        File.expand_path(path)
      end
      @command_runner = command_runner || lambda do |argv|
        stdout, stderr, status = Open3.capture3(*argv)
        [stdout, stderr, status.exitstatus]
      end
      @sleeper = sleeper || ->(seconds) { sleep(seconds) }
      @monotonic_clock = monotonic_clock || -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) }
      @wall_clock = wall_clock || -> { Time.now.utc }
      @platform = platform.to_s
    end

    def ensure_running!(binding:, ssh_public_key_path:, heartbeat_timeout_seconds:)
      paths = paths_for(binding)
      prepared = false
      FileUtils.mkdir_p(paths.fetch(:controller_dir))
      verify_retained_identity!(paths, binding)
      existing = status(binding:)
      return existing if existing.fetch("state") == "RUNNING"

      generation = SecureRandom.uuid
      heartbeat = [[Float(heartbeat_timeout_seconds) / 3.0, 10.0].min, 1.0].max
      request = request_document(
        binding:, generation:, heartbeat_seconds: heartbeat,
        ssh_public_key_path: File.expand_path(ssh_public_key_path)
      )
      write_json_atomic(paths.fetch(:request_path), request)
      File.write(paths.fetch(:enabled_path), "enabled\n")
      File.chmod(0o600, paths.fetch(:enabled_path))
      prepared = true
      write_plist(paths)
      ensure_launchd_running!(paths)
      wait_for_runtime(paths.fetch(:runtime_path), heartbeat_timeout_seconds) do |row|
        runtime_matches?(row, binding, generation) && row["state"] == "RUNNING" &&
          row["last_heartbeat_at_utc"]
      end
      status(binding:)
    rescue Error, ArgumentError, TypeError, SystemCallError, JSON::ParserError, KeyError => e
      cleanup_failed_launch(paths) if prepared
      raise Error, e.message
    end

    def validate_requirements!(binding:)
      model_requirement_bindings(binding, require_all: true)
      true
    rescue ModelRequirement::Error, KeyError, ArgumentError, TypeError, SystemCallError => e
      raise Error, "campaign model requirements are invalid: #{e.message}"
    end

    # Read-only resolution for campaign status after the initiating CLI has
    # exited. With no explicitly supplied paths, reuse only the exact artifact
    # bindings already retained in the supervised controller request.
    def resolved_model_requirements(binding:, require_all: false)
      paths = @model_requirement_paths
      if paths.empty?
        request = read_json(paths_for(binding).fetch(:request_path))
        return {} unless request

        validate_retained_requirements!(request, binding)
        paths = request.fetch("model_requirements").to_h do |row|
          [row.fetch("profile_id"), File.expand_path(row.fetch("path"))]
        end
      end
      original = @model_requirement_paths
      @model_requirement_paths = paths
      model_requirement_bindings(binding, require_all:).to_h do |row|
        [row.fetch("profile_id"), ModelRequirement.load(row.fetch("path"))]
      end
    rescue ModelRequirement::Error, KeyError, ArgumentError, TypeError, SystemCallError,
           JSON::ParserError => e
      raise Error, "campaign model requirements are invalid: #{e.message}"
    ensure
      @model_requirement_paths = original if defined?(original)
    end

    def status(binding:)
      paths = paths_for(binding)
      row = read_json(paths.fetch(:runtime_path)) || {}
      request = read_json(paths.fetch(:request_path)) || {}
      loaded = launchd_loaded?(paths.fetch(:domain), paths.fetch(:label))
      unless row.empty?
        verify_runtime_identity!(row, binding)
        unless request.empty? || row["generation_id"] == request["generation_id"]
          raise Error, "campaign controller runtime generation does not match supervised request"
        end
      end
      state = controller_state(row, loaded:, enabled: File.file?(paths.fetch(:enabled_path)), binding:)
      row.merge(
        "state" => state,
        "launchd_label" => paths.fetch(:label),
        "launchd_loaded" => loaded,
        "enabled" => File.file?(paths.fetch(:enabled_path)),
        "runtime_path" => paths.fetch(:runtime_path),
        "log_path" => paths.fetch(:log_path)
      )
    rescue JSON::ParserError, SystemCallError, KeyError, ArgumentError, TypeError => e
      raise Error, "campaign controller status is unreadable: #{e.message}"
    end

    def disable!(binding:)
      paths = paths_for(binding)
      File.delete(paths.fetch(:enabled_path)) if File.file?(paths.fetch(:enabled_path))
      _out, error, code = run_command(
        ["/bin/launchctl", "bootout", "#{paths.fetch(:domain)}/#{paths.fetch(:label)}"],
        allow_failure: true
      )
      if launchd_loaded?(paths.fetch(:domain), paths.fetch(:label))
        raise Error, "campaign controller remains loaded after stop request: #{error.strip} (exit #{code})"
      end
      status(binding:).merge("state" => "STOPPED", "enabled" => false, "launchd_loaded" => false)
    end

    private

    def cleanup_failed_launch(paths)
      File.delete(paths.fetch(:enabled_path)) if File.file?(paths.fetch(:enabled_path))
      run_command(["/bin/launchctl", "bootout", "#{paths.fetch(:domain)}/#{paths.fetch(:label)}"],
                  allow_failure: true)
    rescue Error, SystemCallError
      nil
    end

    def paths_for(binding)
      controller_dir = File.join(File.dirname(binding.state_path), "controller")
      identity = binding.binding_sha256[0, 20]
      label = "com.adventurefinder.rpof-campaign-#{identity}"
      {
        controller_dir:,
        request_path: File.join(controller_dir, "request.json"),
        runtime_path: File.join(controller_dir, "runtime.json"),
        enabled_path: File.join(controller_dir, "enabled"),
        plist_path: File.join(controller_dir, "#{label}.plist"),
        log_path: File.join(controller_dir, "controller.log"),
        label:,
        domain: launchd_domain
      }
    end

    def request_document(binding:, generation:, heartbeat_seconds:, ssh_public_key_path:)
      {
        "contract_version" => REQUEST_CONTRACT_VERSION,
        "campaign_identity_sha256" => binding.campaign.identity_sha256,
        "binding_sha256" => binding.binding_sha256,
        "budget_id" => binding.declaration.fetch("budget_id"),
        "generation_id" => generation,
        "campaign_path" => @campaign_path,
        "campaign_sha256" => Digest::SHA256.file(@campaign_path).hexdigest,
        "budget_path" => @budget_path,
        "budget_sha256" => Digest::SHA256.file(@budget_path).hexdigest,
        "hardware_path" => @hardware_path,
        "hardware_sha256" => Digest::SHA256.file(@hardware_path).hexdigest,
        "model_requirements" => model_requirement_bindings(binding, require_all: true),
        "controller_executable_sha256" => Digest::SHA256.file(
          File.join(@repo_root, "bin", "rpof-campaign-controller")
        ).hexdigest,
        "state_root" => @root,
        "repo_root" => @repo_root,
        "ssh_public_key_path" => ssh_public_key_path,
        "heartbeat_seconds" => heartbeat_seconds
      }
    end

    def verify_retained_identity!(paths, binding)
      request = read_json(paths.fetch(:request_path))
      runtime = read_json(paths.fetch(:runtime_path))
      [request, runtime].compact.each do |row|
        unless row["campaign_identity_sha256"] == binding.campaign.identity_sha256 &&
               row["binding_sha256"] == binding.binding_sha256 &&
               row["budget_id"] == binding.declaration.fetch("budget_id")
          raise Error, "retained campaign controller identity does not match requested authority"
        end
      end
      validate_retained_requirements!(request, binding) if request
    end

    def model_requirement_bindings(binding, require_all:)
      profiles = binding.campaign.profiles
      profile_ids = profiles.map { |profile| profile.fetch("profile_id") }
      supplied = @model_requirement_paths.keys
      unknown = supplied - profile_ids
      raise Error, "model requirements name unknown profile(s): #{unknown.sort.join(', ')}" unless unknown.empty?
      missing = profile_ids - supplied
      if require_all && !missing.empty?
        raise Error, "exact model requirement required for profile(s): #{missing.sort.join(', ')}"
      end

      profiles.filter_map do |profile|
        profile_id = profile.fetch("profile_id")
        path = @model_requirement_paths[profile_id]
        next unless path

        hardware = binding.campaign.hardware_bindings.find { |row| row.fetch("profile_id") == profile_id }
        raise Error, "campaign profile #{profile_id.inspect} has no hardware qualification" unless hardware
        requirement = ModelRequirement.load(path)
        requirement.validate_profile!(profile:, hardware:)
        {
          "profile_id" => profile_id,
          "path" => path,
          "artifact_sha256" => Digest::SHA256.file(path).hexdigest,
          "requirement_sha256" => requirement.fingerprint
        }
      end
    end

    def validate_retained_requirements!(request, binding)
      unless request["contract_version"] == REQUEST_CONTRACT_VERSION
        raise Error, "retained campaign controller request predates exact model-requirement binding"
      end
      rows = request.fetch("model_requirements")
      raise Error, "retained model requirements must be an array" unless rows.is_a?(Array)
      paths = rows.to_h do |row|
        expected_keys = %w[profile_id path artifact_sha256 requirement_sha256]
        unless row.is_a?(Hash) && row.keys.sort == expected_keys.sort
          raise Error, "retained model requirement binding fields are invalid"
        end
        path = File.expand_path(row.fetch("path"))
        requirement = ModelRequirement.load(path)
        unless Digest::SHA256.file(path).hexdigest == row.fetch("artifact_sha256") &&
               requirement.fingerprint == row.fetch("requirement_sha256")
          raise Error, "retained model requirement artifact changed"
        end
        [row.fetch("profile_id"), path]
      end
      raise Error, "retained model requirement profile identities are not unique" unless paths.length == rows.length

      configured = @model_requirement_paths
      unless configured.empty? || configured == paths
        raise Error, "retained model requirement paths do not match requested artifacts"
      end
      original = @model_requirement_paths
      @model_requirement_paths = paths
      expected = model_requirement_bindings(binding, require_all: true)
      unless rows == expected
        raise Error, "retained model requirement bindings do not match campaign profiles"
      end
    ensure
      @model_requirement_paths = original if defined?(original)
    end

    def verify_runtime_identity!(row, binding)
      return true if row["campaign_identity_sha256"] == binding.campaign.identity_sha256 &&
                     row["binding_sha256"] == binding.binding_sha256 &&
                     row["budget_id"] == binding.declaration.fetch("budget_id")

      raise Error, "campaign controller runtime identity does not match requested authority"
    end

    def runtime_matches?(row, binding, generation)
      verify_runtime_identity!(row, binding)
      Integer(row.fetch("pid")).positive? && Integer(row.fetch("pid")) != Process.pid &&
        row.fetch("generation_id") == generation
    rescue ArgumentError, TypeError, KeyError
      false
    end

    def controller_state(row, loaded:, enabled:, binding:)
      return "STOPPED" unless enabled || loaded
      return "STALE" if row.empty?
      return row.fetch("state") if row.fetch("state") == "ERROR"
      return "STOPPED" unless row.fetch("state") == "RUNNING" && loaded && enabled

      heartbeat = Time.parse(row.fetch("last_heartbeat_at_utc").to_s).utc
      timeout = binding.declaration.fetch("orchestrator_heartbeat_timeout_seconds")
      age = utc_now - heartbeat
      age >= 0 && age <= timeout ? "RUNNING" : "STALE"
    rescue ArgumentError, TypeError, KeyError
      "STALE"
    end

    def write_plist(paths)
      script = File.join(@repo_root, "bin", "rpof-campaign-controller")
      raise Error, "campaign controller executable is missing: #{script}" unless File.file?(script)
      args = [
        RbConfig.ruby, script,
        "--request", paths.fetch(:request_path),
        "--enabled", paths.fetch(:enabled_path),
        "--runtime", paths.fetch(:runtime_path),
        "--log", paths.fetch(:log_path)
      ]
      plist = <<~PLIST
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict>
          <key>Label</key><string>#{xml(paths.fetch(:label))}</string>
          <key>ProgramArguments</key><array>
        #{args.map { |arg| "    <string>#{xml(arg)}</string>" }.join("\n")}
          </array>
          <key>WorkingDirectory</key><string>#{xml(@repo_root)}</string>
          <key>RunAtLoad</key><true/>
          <key>KeepAlive</key><dict><key>PathState</key><dict>
            <key>#{xml(paths.fetch(:enabled_path))}</key><true/>
          </dict></dict>
          <key>ThrottleInterval</key><integer>1</integer>
          <key>StandardOutPath</key><string>#{xml(paths.fetch(:log_path))}</string>
          <key>StandardErrorPath</key><string>#{xml(paths.fetch(:log_path))}</string>
        </dict></plist>
      PLIST
      File.write(paths.fetch(:plist_path), plist)
      File.chmod(0o600, paths.fetch(:plist_path))
    end

    def ensure_launchd_running!(paths)
      domain = paths.fetch(:domain)
      label = paths.fetch(:label)
      unless launchd_loaded?(domain, label)
        _out, err, code = run_command(
          ["/bin/launchctl", "bootstrap", domain, paths.fetch(:plist_path)], allow_failure: true
        )
        raise Error, "could not bootstrap campaign controller with launchd: #{err.strip}" unless code.zero? || launchd_loaded?(domain, label)
      end
      _out, err, code = run_command(
        ["/bin/launchctl", "kickstart", "-k", "#{domain}/#{label}"], allow_failure: true
      )
      raise Error, "could not start campaign controller with launchd: #{err.strip}" unless code.zero?
    end

    def launchd_loaded?(domain, label)
      _out, _err, code = run_command(["/bin/launchctl", "print", "#{domain}/#{label}"], allow_failure: true)
      code.zero?
    end

    def wait_for_runtime(path, heartbeat_timeout_seconds)
      deadline = @monotonic_clock.call + [10.0, Float(heartbeat_timeout_seconds)].max
      loop do
        row = read_json(path)
        return row if row && yield(row)
        if row && row["state"] == "ERROR"
          raise Error, "campaign controller reported startup error: #{row['last_error']}"
        end
        raise Error, "timed out waiting for campaign controller readiness" if @monotonic_clock.call >= deadline
        @sleeper.call(0.1)
      end
    end

    def read_json(path)
      File.file?(path) ? JSON.parse(File.read(path)) : nil
    end

    def write_json_atomic(path, document)
      tmp = "#{path}.tmp.#{$$}.#{Thread.current.object_id}"
      File.write(tmp, JSON.pretty_generate(document) + "\n")
      File.chmod(0o600, tmp)
      File.rename(tmp, path)
    ensure
      File.delete(tmp) if defined?(tmp) && tmp && File.exist?(tmp)
    end

    def run_command(argv, allow_failure: false)
      stdout, stderr, status = @command_runner.call(argv)
      code = Integer(status)
      raise Error, "#{argv.first} failed with exit #{code}: #{stderr}" if !allow_failure && !code.zero?
      [stdout.to_s, stderr.to_s, code]
    end

    def launchd_domain
      raise Error, "campaign controller supervision requires macOS launchd" unless @platform.include?("darwin")
      "gui/#{Process.uid}"
    end

    def utc_now
      value = @wall_clock.call
      value = Time.parse(value.to_s) unless value.is_a?(Time)
      value.utc
    end

    def xml(value)
      value.to_s.gsub("&", "&amp;").gsub("<", "&lt;").gsub(">", "&gt;")
           .gsub('"', "&quot;").gsub("'", "&apos;")
    end
  end
end
