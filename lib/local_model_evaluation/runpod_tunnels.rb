# frozen_string_literal: true

require "fileutils"
require "json"
require "net/http"
require "socket"
require "time"
require "uri"
require_relative "runpod_fleet_state"
require_relative "runpod_workers"

module LocalModelEvaluation
  class RunpodTunnels
    DEFAULT_WAIT_SECONDS = 30
    DEFAULT_POLL_SECONDS = 1.0
    DEFAULT_REMOTE_PORT = 11_434
    TERMINATION_GRACE_SECONDS = 3.0
    STATE_FILE = "tunnels.json"

    class Error < StandardError; end

    Health = Struct.new(:healthy, :version, :detail, keyword_init: true)

    class HttpHealthChecker
      def initialize(open_timeout: 0.5, read_timeout: 1.0)
        @open_timeout = open_timeout
        @read_timeout = read_timeout
      end

      def check(endpoint)
        uri = URI.join("#{endpoint}/", "api/version")
        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl = uri.scheme == "https"
        http.open_timeout = @open_timeout
        http.read_timeout = @read_timeout
        response = http.get(uri.request_uri)
        unless response.is_a?(Net::HTTPSuccess)
          return Health.new(healthy: false, detail: "HTTP #{response.code}")
        end

        data = JSON.parse(response.body)
        Health.new(healthy: true, version: data["version"].to_s)
      rescue StandardError => e
        Health.new(healthy: false, detail: "#{e.class}: #{e.message}")
      end
    end

    class PortChecker
      def available?(port)
        server = TCPServer.new("127.0.0.1", Integer(port))
        true
      rescue Errno::EADDRINUSE
        false
      ensure
        server&.close
      end
    end

    class SystemProcessAdapter
      def initialize(sleeper: nil, monotonic_clock: nil)
        @sleeper = sleeper || ->(seconds) { sleep seconds }
        @monotonic_clock = monotonic_clock || -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) }
      end

      def spawn(command:, log_path:, chdir:)
        FileUtils.mkdir_p(File.dirname(log_path))
        log = File.open(log_path, "a")
        pid = Process.spawn(
          *command,
          chdir:,
          in: File::NULL,
          out: log,
          err: [:child, :out],
          pgroup: true
        )
        Process.detach(pid)
        pid
      ensure
        log&.close
      end

      def alive?(pid)
        Process.kill(0, Integer(pid))
        true
      rescue Errno::ESRCH, Errno::EPERM
        false
      end

      def matches?(pid, identity)
        command = IO.popen(["ps", "-p", Integer(pid).to_s, "-o", "command="], &:read).to_s
        return false if command.strip.empty?

        forward = identity.fetch("forward")
        target = identity.fetch("target")
        ssh_port = identity.fetch("ssh_port").to_s
        command.include?(forward) && command.include?(target) &&
          (command.include?("-p #{ssh_port}") || command.include?("-p#{ssh_port}"))
      rescue StandardError
        false
      end

      def terminate_group(pid, grace_seconds: TERMINATION_GRACE_SECONDS)
        pid = Integer(pid)
        signal_group("TERM", pid)
        deadline = @monotonic_clock.call + Float(grace_seconds)
        while alive?(pid) && @monotonic_clock.call < deadline
          @sleeper.call(0.05)
        end
        signal_group("KILL", pid) if alive?(pid)
      end

      private

      def signal_group(signal, pid)
        Process.kill(signal, -pid)
      rescue Errno::ESRCH
        nil
      end
    end

    def initialize(fleet_state:, repo_root:, out: $stdout, ssh_path: "ssh", identity_path: nil,
                   wall_clock: nil, monotonic_clock: nil, sleeper: nil,
                   process_adapter: nil, health_checker: nil, port_checker: nil)
      @fleet_state = fleet_state
      @repo_root = File.expand_path(repo_root)
      @out = out
      @ssh_path = ssh_path.to_s
      @identity_path = File.expand_path(identity_path || "~/.ssh/id_ed25519")
      @wall_clock = wall_clock || -> { Time.now.utc }
      @monotonic_clock = monotonic_clock || -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) }
      @sleeper = sleeper || ->(seconds) { sleep seconds }
      @process = process_adapter || SystemProcessAdapter.new(sleeper: @sleeper, monotonic_clock: @monotonic_clock)
      @health = health_checker || HttpHealthChecker.new
      @ports = port_checker || PortChecker.new
      @out.sync = true if @out.respond_to?(:sync=)
    end

    def start(worker_indices:, wait_seconds: DEFAULT_WAIT_SECONDS, poll_seconds: DEFAULT_POLL_SECONDS,
              remote_port: DEFAULT_REMOTE_PORT)
      fleet = active_fleet!
      workers = selected_workers(fleet, worker_indices, default_all: false)
      wait_seconds = nonnegative_float(wait_seconds, "wait seconds")
      poll_seconds = positive_float(poll_seconds, "poll seconds")
      remote_port = positive_integer(remote_port, "remote port")
      validate_identity!

      with_state_lock(fleet) do |root|
        state = load_state(root, fleet)
        newly_started = []
        pending = []
        failures = []

        begin
          workers.each do |worker|
            index = worker.fetch("index")
            existing = state_worker(state, index)
            if existing && existing["pid"] && @process.alive?(existing["pid"])
              unless @process.matches?(existing["pid"], existing.fetch("process_identity"))
                failures << "burst_#{index}: managed pid #{existing['pid']} no longer matches recorded SSH tunnel identity"
                existing["process_status"] = "mismatch"
                existing["health_status"] = "unknown"
                next
              end

              health = @health.check(existing.fetch("endpoint"))
              update_health(existing, health)
              if health.healthy
                existing["process_status"] = "running"
                @out.puts "PASS: burst_#{index} tunnel already healthy (pid=#{existing['pid']})"
              else
                existing["process_status"] = "running"
                failures << "burst_#{index}: existing managed tunnel is not healthy: #{health.detail}"
              end
              next
            end

            mark_stale(existing) if existing
            spec = tunnel_spec(worker, remote_port, root)
            unless @ports.available?(spec.fetch("local_port"))
              failures << "burst_#{index}: local port #{spec.fetch('local_port')} is already in use by an unmanaged process"
              next
            end

            pid = @process.spawn(
              command: ssh_command(spec),
              log_path: spec.fetch("log_path"),
              chdir: @repo_root
            )
            record = build_record(worker, spec, pid)
            replace_state_worker(state, record)
            newly_started << record
            pending << record
            @out.puts format(
              "Starting tunnel on burst_%d: 127.0.0.1:%d -> %s:%d -> 127.0.0.1:%d (pid=%d)...",
              index,
              spec.fetch("local_port"),
              worker.fetch("host"),
              worker.fetch("ssh_port"),
              remote_port,
              pid
            )
            write_state(root, state)
          end

          deadline = @monotonic_clock.call + wait_seconds
          next_feedback = @monotonic_clock.call + 5.0
          until pending.empty?
            pending.dup.each do |record|
              index = record.fetch("index")
              unless @process.alive?(record.fetch("pid"))
                record["process_status"] = "exited"
                record["health_status"] = "unhealthy"
                record["last_health_detail"] = "SSH tunnel process exited before becoming healthy"
                record["last_health_at_utc"] = utc_now.iso8601
                failures << "burst_#{index}: SSH tunnel process exited; inspect #{File.join(root, record.fetch('log'))}"
                pending.delete(record)
                write_state(root, state)
                next
              end

              health = @health.check(record.fetch("endpoint"))
              update_health(record, health)
              if health.healthy
                record["process_status"] = "running"
                pending.delete(record)
                @out.puts format(
                  "PASS: burst_%d tunnel healthy | pid=%d | %s | Ollama %s",
                  index,
                  record.fetch("pid"),
                  record.fetch("endpoint"),
                  health.version.to_s.empty? ? "?" : health.version
                )
                write_state(root, state)
              end
            end

            break if pending.empty?
            now = @monotonic_clock.call
            break if now >= deadline
            if now >= next_feedback
              healthy_count = newly_started.count { |record| record["health_status"] == "healthy" }
              @out.puts "[#{utc_now.strftime('%H:%M:%S')}] tunnel heartbeat: #{healthy_count}/#{newly_started.length} newly-started healthy; #{pending.length} waiting"
              next_feedback = now + 5.0
            end
            @sleeper.call(poll_seconds)
          end

          pending.each do |record|
            record["process_status"] = @process.alive?(record.fetch("pid")) ? "running" : "exited"
            record["health_status"] = "unhealthy"
            record["last_health_detail"] ||= "Ollama did not become reachable within #{wait_seconds.to_i}s"
            record["last_health_at_utc"] = utc_now.iso8601
            failures << "burst_#{record.fetch('index')}: Ollama did not become reachable within #{wait_seconds.to_i}s"
          end
          write_state(root, state)
        rescue Interrupt
          @out.puts "Interrupt received; stopping #{newly_started.length} tunnel(s) started by this command..."
          newly_started.each { |record| stop_record(record, force_identity: true) }
          write_state(root, state)
          raise
        end

        healthy = workers.count do |worker|
          record = state_worker(state, worker.fetch("index"))
          record && record["health_status"] == "healthy" && record["pid"] && @process.alive?(record["pid"])
        end
        @out.puts "Tunnel start complete: #{healthy}/#{workers.length} selected workers healthy. Evidence: #{root}"
        raise Error, failures.uniq.join("; ") unless failures.empty?

        state
      end
    end

    def repair(worker_indices:, wait_seconds: DEFAULT_WAIT_SECONDS, poll_seconds: DEFAULT_POLL_SECONDS,
               remote_port: DEFAULT_REMOTE_PORT)
      wait_seconds = nonnegative_float(wait_seconds, "wait seconds")
      poll_seconds = positive_float(poll_seconds, "poll seconds")
      remote_port = positive_integer(remote_port, "remote port")

      rows = status(worker_indices:)
      mismatches = rows.select { |row| row.fetch("process_status") == "mismatch" }
      unless mismatches.empty?
        names = mismatches.map { |row| "burst_#{row.fetch('index')}" }.join(", ")
        raise Error, "refusing tunnel repair for #{names}: managed pid identity does not match recorded SSH tunnel"
      end

      targets = rows.reject do |row|
        row.fetch("process_status") == "running" && row.fetch("health_status") == "healthy"
      end
      if targets.empty?
        @out.puts "Tunnel repair complete: #{rows.length}/#{rows.length} selected workers already healthy; no processes restarted."
        return rows
      end

      # Validate restart prerequisites before deliberately stopping any managed tunnel.
      validate_identity!
      target_indices = targets.map { |row| row.fetch("index") }
      @out.puts "Repairing tunnel(s): #{target_indices.map { |index| "burst_#{index}" }.join(', ')}"
      stop(worker_indices: target_indices)
      start(
        worker_indices: target_indices,
        wait_seconds:,
        poll_seconds:,
        remote_port:
      )

      repaired = status(worker_indices:)
      healthy = repaired.count do |row|
        row.fetch("process_status") == "running" && row.fetch("health_status") == "healthy"
      end
      @out.puts "Tunnel repair complete: #{healthy}/#{repaired.length} selected workers healthy."
      repaired
    end

    def status(worker_indices: nil)
      fleet = active_fleet!
      workers = selected_workers(fleet, worker_indices, default_all: true)

      with_state_lock(fleet) do |root|
        state = load_state(root, fleet)
        rows = workers.map do |worker|
          record = state_worker(state, worker.fetch("index"))
          inspect_record(record, worker)
        end
        write_state(root, state)
        rows
      end
    end

    def stop(worker_indices:)
      fleet = active_fleet!
      workers = selected_workers(fleet, worker_indices, default_all: false)

      with_state_lock(fleet) do |root|
        state = load_state(root, fleet)
        errors = []
        workers.each do |worker|
          index = worker.fetch("index")
          record = state_worker(state, index)
          unless record && record["pid"]
            @out.puts "Already absent: burst_#{index} tunnel"
            next
          end

          pid = record.fetch("pid")
          if @process.alive?(pid) && !@process.matches?(pid, record.fetch("process_identity"))
            record["process_status"] = "mismatch"
            record["health_status"] = "unknown"
            errors << "burst_#{index}: refusing to kill pid #{pid}; process identity does not match recorded tunnel"
            next
          end

          stop_record(record, force_identity: true)
          @out.puts "Stopped: burst_#{index} tunnel"
        end
        write_state(root, state)
        raise Error, errors.join("; ") unless errors.empty?

        state
      end
    end

    def render_status(rows)
      lines = []
      lines << format("%-9s %-8s %-11s %-7s %-23s %s", "WORKER", "PID", "PROCESS", "HEALTH", "ENDPOINT", "OLLAMA")
      rows.each do |row|
        lines << format(
          "%-9s %-8s %-11s %-7s %-23s %s",
          "burst_#{row.fetch('index')}",
          row["pid"] || "-",
          row.fetch("process_status").upcase,
          row.fetch("health_status").upcase,
          row.fetch("endpoint"),
          row["ollama_version"].to_s.empty? ? "-" : row["ollama_version"]
        )
      end
      lines.join("\n") + "\n"
    end

    private

    def active_fleet!
      fleet = @fleet_state.current
      raise Error, "no current RunPod fleet state exists; provision a fleet first" unless fleet
      raise Error, "current RunPod fleet #{fleet.fetch('fleet_id')} is not active" unless fleet["status"] == "active"

      fleet
    rescue RunpodFleetState::Error => e
      raise Error, e.message
    end

    def selected_workers(fleet, values, default_all:)
      active = fleet.fetch("workers").select { |worker| worker["status"] == "active" }
      if values.nil? && default_all
        return active.sort_by { |worker| Integer(worker.fetch("index")) }
      end

      indices = Array(values).map { |value| RunpodWorkers.validate_index(value) }.uniq.sort
      raise Error, "no workers selected" if indices.empty?
      by_index = fleet.fetch("workers").to_h { |worker| [Integer(worker.fetch("index")), worker] }
      unknown = indices.reject { |index| by_index.key?(index) }
      raise Error, "current fleet does not contain worker index(es): #{unknown.join(', ')}" unless unknown.empty?
      selected = indices.map { |index| by_index.fetch(index) }
      inactive = selected.reject { |worker| worker["status"] == "active" }
      unless inactive.empty?
        raise Error, "selected worker(s) are not active: #{inactive.map { |worker| "burst_#{worker.fetch('index')}" }.join(', ')}"
      end
      selected
    rescue RunpodWorkers::Error => e
      raise Error, e.message
    rescue ArgumentError, TypeError
      raise Error, "worker indices must be integers"
    end

    def with_state_lock(fleet)
      root = @fleet_state.artifact_dir(fleet.fetch("fleet_id"), "tunnels")
      FileUtils.mkdir_p(root)
      File.open(File.join(root, ".lock"), File::RDWR | File::CREAT, 0o600) do |lock|
        unless lock.flock(File::LOCK_EX | File::LOCK_NB)
          raise Error, "another tunnel management command is already running for fleet #{fleet.fetch('fleet_id')}"
        end
        yield root
      end
    rescue RunpodFleetState::Error => e
      raise Error, e.message
    end

    def load_state(root, fleet)
      path = File.join(root, STATE_FILE)
      unless File.file?(path)
        return {
          "schema_version" => 1,
          "fleet_id" => fleet.fetch("fleet_id"),
          "updated_at_utc" => utc_now.iso8601,
          "workers" => []
        }
      end

      state = JSON.parse(File.read(path))
      unless state["fleet_id"] == fleet.fetch("fleet_id")
        raise Error, "tunnel state fleet id mismatch: expected #{fleet.fetch('fleet_id')}, got #{state['fleet_id'].inspect}"
      end
      state["workers"] = Array(state["workers"])
      state
    rescue JSON::ParserError => e
      raise Error, "tunnel state is invalid JSON: #{e.message}"
    end

    def write_state(root, state)
      state["updated_at_utc"] = utc_now.iso8601
      path = File.join(root, STATE_FILE)
      tmp = "#{path}.tmp.#{$$}.#{Thread.current.object_id}"
      File.write(tmp, JSON.pretty_generate(state) + "\n")
      File.rename(tmp, path)
    ensure
      File.delete(tmp) if defined?(tmp) && tmp && File.exist?(tmp)
    end

    def tunnel_spec(worker, remote_port, root)
      local_port = endpoint_port(worker.fetch("local_ollama_url"))
      index = Integer(worker.fetch("index"))
      {
        "index" => index,
        "host" => worker.fetch("host").to_s,
        "ssh_port" => positive_integer(worker.fetch("ssh_port"), "burst_#{index} SSH port"),
        "local_port" => local_port,
        "remote_port" => remote_port,
        "endpoint" => "http://127.0.0.1:#{local_port}",
        "target" => "root@#{worker.fetch('host')}",
        "log_path" => File.join(root, "burst_#{index}.log"),
        "known_hosts_path" => File.join(root, "known_hosts-burst_#{index}")
      }
    end

    def ssh_command(spec)
      forward = "127.0.0.1:#{spec.fetch('local_port')}:127.0.0.1:#{spec.fetch('remote_port')}"
      [
        @ssh_path,
        "-N",
        "-o", "BatchMode=yes",
        "-o", "IdentitiesOnly=yes",
        "-o", "StrictHostKeyChecking=accept-new",
        "-o", "UserKnownHostsFile=#{spec.fetch('known_hosts_path')}",
        "-o", "ExitOnForwardFailure=yes",
        "-o", "ConnectTimeout=10",
        "-o", "ServerAliveInterval=30",
        "-o", "ServerAliveCountMax=3",
        "-L", forward,
        "-p", spec.fetch("ssh_port").to_s,
        "-i", @identity_path,
        spec.fetch("target")
      ]
    end

    def build_record(worker, spec, pid)
      forward = "127.0.0.1:#{spec.fetch('local_port')}:127.0.0.1:#{spec.fetch('remote_port')}"
      {
        "index" => Integer(worker.fetch("index")),
        "pod_id" => worker.fetch("pod_id").to_s,
        "pid" => Integer(pid),
        "process_status" => "starting",
        "health_status" => "pending",
        "started_at_utc" => utc_now.iso8601,
        "stopped_at_utc" => nil,
        "last_health_at_utc" => nil,
        "last_health_detail" => nil,
        "ollama_version" => nil,
        "host" => spec.fetch("host"),
        "ssh_port" => spec.fetch("ssh_port"),
        "local_port" => spec.fetch("local_port"),
        "remote_port" => spec.fetch("remote_port"),
        "endpoint" => spec.fetch("endpoint"),
        "log" => File.basename(spec.fetch("log_path")),
        "known_hosts" => File.basename(spec.fetch("known_hosts_path")),
        "process_identity" => {
          "forward" => forward,
          "ssh_port" => spec.fetch("ssh_port"),
          "target" => spec.fetch("target")
        }
      }
    end

    def inspect_record(record, worker)
      endpoint = worker.fetch("local_ollama_url").to_s
      unless record
        return {
          "index" => Integer(worker.fetch("index")),
          "pid" => nil,
          "process_status" => "missing",
          "health_status" => "missing",
          "endpoint" => endpoint,
          "ollama_version" => nil
        }
      end

      pid = record["pid"]
      unless pid && @process.alive?(pid)
        mark_stale(record)
        return status_row(record)
      end

      unless @process.matches?(pid, record.fetch("process_identity"))
        record["process_status"] = "mismatch"
        record["health_status"] = "unknown"
        record["last_health_at_utc"] = utc_now.iso8601
        record["last_health_detail"] = "pid is alive but does not match recorded SSH tunnel identity"
        return status_row(record)
      end

      record["process_status"] = "running"
      update_health(record, @health.check(record.fetch("endpoint")))
      status_row(record)
    end

    def status_row(record)
      {
        "index" => Integer(record.fetch("index")),
        "pid" => record["pid"],
        "process_status" => record.fetch("process_status"),
        "health_status" => record.fetch("health_status"),
        "endpoint" => record.fetch("endpoint"),
        "ollama_version" => record["ollama_version"],
        "detail" => record["last_health_detail"]
      }
    end

    def update_health(record, health)
      record["last_health_at_utc"] = utc_now.iso8601
      record["health_status"] = health.healthy ? "healthy" : "unhealthy"
      record["ollama_version"] = health.version unless health.version.to_s.empty?
      record["last_health_detail"] = health.detail
    end

    def mark_stale(record)
      return unless record

      record["process_status"] = "stale"
      record["health_status"] = "unhealthy"
      record["last_health_at_utc"] = utc_now.iso8601
      record["last_health_detail"] = "recorded tunnel pid is not running"
    end

    def stop_record(record, force_identity: false)
      pid = record["pid"]
      if pid && @process.alive?(pid)
        unless force_identity || @process.matches?(pid, record.fetch("process_identity"))
          raise Error, "refusing to kill pid #{pid}; process identity does not match recorded tunnel"
        end
        @process.terminate_group(pid, grace_seconds: TERMINATION_GRACE_SECONDS)
      end
      record["pid"] = nil
      record["process_status"] = "stopped"
      record["health_status"] = "stopped"
      record["stopped_at_utc"] = utc_now.iso8601
      record["last_health_at_utc"] = record["stopped_at_utc"]
      record["last_health_detail"] = nil
    end

    def replace_state_worker(state, record)
      workers = state.fetch("workers")
      workers.reject! { |entry| Integer(entry.fetch("index")) == record.fetch("index") }
      workers << record
      workers.sort_by! { |entry| Integer(entry.fetch("index")) }
    end

    def state_worker(state, index)
      state.fetch("workers").find { |entry| Integer(entry.fetch("index")) == Integer(index) }
    end

    def endpoint_port(value)
      uri = URI.parse(value.to_s)
      unless uri.scheme == "http" && %w[127.0.0.1 localhost].include?(uri.host) && uri.port.positive?
        raise Error, "worker endpoint must be localhost HTTP, got #{value.inspect}"
      end
      uri.port
    rescue URI::InvalidURIError
      raise Error, "invalid worker endpoint: #{value.inspect}"
    end

    def validate_identity!
      raise Error, "SSH identity not found: #{@identity_path}" unless File.file?(@identity_path)
    end

    def positive_integer(value, label)
      number = Integer(value)
      raise Error, "#{label} must be positive" unless number.positive?
      number
    rescue ArgumentError, TypeError
      raise Error, "#{label} must be an integer"
    end

    def positive_float(value, label)
      number = Float(value)
      raise Error, "#{label} must be positive" unless number.positive?
      number
    rescue ArgumentError, TypeError
      raise Error, "#{label} must be numeric"
    end

    def nonnegative_float(value, label)
      number = Float(value)
      raise Error, "#{label} must be non-negative" if number.negative?
      number
    rescue ArgumentError, TypeError
      raise Error, "#{label} must be numeric"
    end

    def utc_now
      value = @wall_clock.call
      value = Time.parse(value.to_s) unless value.is_a?(Time)
      value.utc
    end
  end
end
