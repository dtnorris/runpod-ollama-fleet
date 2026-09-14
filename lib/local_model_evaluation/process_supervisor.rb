# frozen_string_literal: true

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
  end
end
