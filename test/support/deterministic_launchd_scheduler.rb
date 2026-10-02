# frozen_string_literal: true

require "digest"
require "fileutils"
require "json"
require "thread"

class DeterministicLaunchdScheduler
  def initialize(socket_path:, service_environment:)
    @command_dir = File.expand_path(socket_path)
    @service_environment = service_environment
    @mutex = Mutex.new
    @loaded = false
    @stopping = false
    @service_pid = nil
    @invocations = []
  end

  def start
    FileUtils.mkdir_p(@command_dir)
    @server_thread = Thread.new { serve }
    @monitor_thread = Thread.new { monitor }
    self
  end

  def stop
    @mutex.synchronize { @stopping = true }
    @server_thread&.join(1)
    @monitor_thread&.join(1)
    @mutex.synchronize { terminate_service }
    nil
  end

  def descriptor
    @mutex.synchronize { Marshal.load(Marshal.dump(@descriptor)) }
  end

  def invocations
    @mutex.synchronize { Marshal.load(Marshal.dump(@invocations)) }
  end

  def service_pid
    @mutex.synchronize do
      reap_service
      @service_pid
    end
  end

  def kill_service_abruptly
    @mutex.synchronize do
      reap_service
      raise "deterministic launchd has no running service" unless @service_pid

      Process.kill("KILL", @service_pid)
      @service_pid
    end
  end

  def invoke_once
    details = @mutex.synchronize do
      raise "deterministic launchd has no loaded service" unless @descriptor

      @descriptor.dup
    end
    pid = Process.spawn(
      @service_environment,
      *details.fetch("program_arguments"),
      chdir: details.fetch("working_directory"),
      out: details.fetch("log_path"),
      err: details.fetch("log_path")
    )
    _waited, status = Process.wait2(pid)
    @mutex.synchronize do
      @invocations << invocation(details, pid, "scheduled_follow_up")
    end
    status
  end

  private

  def serve
    loop do
      break if stopping?

      Dir.glob(File.join(@command_dir, "*.request.json")).sort.each do |request_path|
        response_path = request_path.sub(".request.json", ".response.json")
        begin
          request = JSON.parse(File.read(request_path))
          response = handle_command(request.fetch("argv"))
        rescue StandardError => e
          response = result("", e.message, 1)
        end
        write_json_atomic(response_path, response)
        File.delete(request_path) if File.file?(request_path)
      end
      sleep 0.002
    end
  end

  def monitor
    loop do
      break if stopping?

      @mutex.synchronize do
        reap_service
        start_service("keep_alive") if keep_alive? && @service_pid.nil?
      end
      sleep 0.005
    end
  end

  def write_json_atomic(path, document)
    temporary = "#{path}.tmp.#{Process.pid}.#{Thread.current.object_id}"
    File.write(temporary, JSON.generate(document) + "\n")
    File.rename(temporary, path)
  ensure
    File.delete(temporary) if defined?(temporary) && temporary && File.exist?(temporary)
  end

  def handle_command(argv)
    @mutex.synchronize do
      case argv.fetch(1)
      when "print"
        result("", "", @loaded ? 0 : 1)
      when "bootstrap"
        load_plist(argv.fetch(3))
        @loaded = true
        start_service("run_at_load") if @descriptor.fetch("run_at_load")
        result
      when "kickstart"
        terminate_service
        start_service("kickstart")
        result
      when "bootout"
        @loaded = false
        terminate_service
        result
      else
        result("", "unexpected launchctl command: #{argv.inspect}", 1)
      end
    end
  end

  def load_plist(path)
    plist = File.read(path)
    arguments_xml = plist.match(
      %r{<key>ProgramArguments</key>\s*<array>(.*?)</array>}m
    )[1]
    arguments = arguments_xml.scan(%r{<string>(.*?)</string>}m).flatten.map do |argument|
      xml_text(argument)
    end
    path_state = plist.match(
      %r{<key>PathState</key>\s*<dict>\s*<key>(.*?)</key>\s*<true/>}m
    )[1]

    @descriptor = {
      "label" => plist_string(plist, "Label"),
      "program_arguments" => arguments,
      "program_arguments_sha256" => Digest::SHA256.hexdigest(JSON.generate(arguments)),
      "working_directory" => plist_string(plist, "WorkingDirectory"),
      "run_at_load" => plist.match?(%r{<key>RunAtLoad</key>\s*<true/>}),
      "keep_alive_enabled_path" => xml_text(path_state),
      "throttle_interval_seconds" => Integer(plist_integer(plist, "ThrottleInterval")),
      "log_path" => plist_string(plist, "StandardOutPath"),
      "plist_path" => File.expand_path(path),
      "plist_sha256" => Digest::SHA256.file(path).hexdigest
    }
  end

  def plist_string(plist, key)
    value = plist.match(%r{<key>#{Regexp.escape(key)}</key>\s*<string>(.*?)</string>}m)[1]
    xml_text(value)
  end

  def plist_integer(plist, key)
    plist.match(%r{<key>#{Regexp.escape(key)}</key>\s*<integer>(.*?)</integer>}m)[1]
  end

  def xml_text(value)
    value.to_s
         .gsub("&quot;", '"')
         .gsub("&apos;", "'")
         .gsub("&gt;", ">")
         .gsub("&lt;", "<")
         .gsub("&amp;", "&")
  end

  def keep_alive?
    @loaded && @descriptor && File.file?(@descriptor.fetch("keep_alive_enabled_path"))
  end

  def start_service(reason)
    return if @service_pid || !@descriptor

    @service_pid = Process.spawn(
      @service_environment,
      *@descriptor.fetch("program_arguments"),
      chdir: @descriptor.fetch("working_directory"),
      out: @descriptor.fetch("log_path"),
      err: @descriptor.fetch("log_path")
    )
    @invocations << invocation(@descriptor, @service_pid, reason)
  end

  def invocation(details, pid, reason)
    {
      "pid" => pid,
      "reason" => reason,
      "label" => details.fetch("label"),
      "program_arguments_sha256" => details.fetch("program_arguments_sha256")
    }
  end

  def reap_service
    return unless @service_pid

    waited = Process.waitpid(@service_pid, Process::WNOHANG)
    @service_pid = nil if waited
  rescue Errno::ECHILD, Errno::ESRCH
    @service_pid = nil
  end

  def terminate_service
    return unless @service_pid

    Process.kill("KILL", @service_pid)
    Process.wait(@service_pid)
  rescue Errno::ECHILD, Errno::ESRCH
    nil
  ensure
    @service_pid = nil
  end

  def stopping?
    @mutex.synchronize { @stopping }
  end

  def result(stdout = "", stderr = "", status = 0)
    { "stdout" => stdout, "stderr" => stderr, "status" => status }
  end
end
