# frozen_string_literal: true

require "digest"
require "json"
require "securerandom"

module LocalModelEvaluation
  class ProcessSupervisor
    FailedStatus = Struct.new(:exitstatus) do
      def success? = false
    end

    def file?(path)
      File.file?(path)
    end

    def executable?(path)
      File.executable?(path)
    end

    def spawn(command:, chdir:, output:)
      Process.spawn(
        *command,
        chdir:,
        in: File::NULL,
        out: output,
        err: [:child, :out],
        pgroup: true
      )
    end

    def poll(pid)
      Process.waitpid2(pid, Process::WNOHANG)
    rescue Errno::ECHILD
      [pid, FailedStatus.new(nil)]
    end

    def process_identity(pid:, command:)
      process_id = Integer(pid)
      {
        "pid" => process_id,
        "process_group_id" => Process.getpgid(process_id),
        "start_token" => process_start_token(process_id),
        "command_sha256" => Digest::SHA256.hexdigest(JSON.generate(Array(command).map(&:to_s)))
      }
    rescue Errno::ESRCH, Errno::ENOENT
      {
        "pid" => process_id,
        "process_group_id" => process_id,
        "start_token" => "exited-before-capture:#{SecureRandom.hex(16)}",
        "command_sha256" => Digest::SHA256.hexdigest(JSON.generate(Array(command).map(&:to_s)))
      }
    end

    def same_process?(identity)
      pid = Integer(identity.fetch("pid"))
      process_group_id = Integer(identity.fetch("process_group_id"))
      start_token = identity.fetch("start_token").to_s
      return false if start_token.empty?
      return false if start_token.start_with?("exited-before-capture:")

      Process.getpgid(pid) == process_group_id && process_start_token(pid) == start_token
    rescue Errno::ESRCH, Errno::ENOENT, KeyError, ArgumentError, TypeError
      false
    end

    def signal_group(signal, pid)
      Process.kill(signal, -pid)
    rescue Errno::ESRCH
      nil
    end

    def wait(pid)
      Process.waitpid(pid)
    rescue Errno::ECHILD
      nil
    end

    private

    def process_start_token(pid)
      proc_stat = "/proc/#{Integer(pid)}/stat"
      if File.file?(proc_stat)
        fields = File.binread(proc_stat).sub(/\A\d+ \(.*\) \S /, "").split
        token = fields.fetch(18)
        return "proc:#{token}"
      end

      value = IO.popen(["ps", "-p", Integer(pid).to_s, "-o", "lstart="], &:read).to_s.strip
      raise Errno::ESRCH, pid.to_s if value.empty?

      "ps:#{value}"
    end
  end
end
