# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require_relative "../lib/local_model_evaluation/process_supervisor"

class ProcessSupervisorTest < Minitest::Test
  def test_poll_returns_failed_status_when_process_was_already_reaped
    supervisor = LocalModelEvaluation::ProcessSupervisor.new
    pid = 12_345

    result = Process.stub(:waitpid2, ->(*) { raise Errno::ECHILD }) do
      supervisor.poll(pid)
    end

    assert_equal pid, result.fetch(0)
    refute result.fetch(1).success?
    assert_nil result.fetch(1).exitstatus
  end

  def test_signal_group_treats_missing_process_group_as_already_stopped
    supervisor = LocalModelEvaluation::ProcessSupervisor.new

    result = Process.stub(:kill, ->(*) { raise Errno::ESRCH }) do
      supervisor.signal_group("TERM", 12_345)
    end

    assert_nil result
  end

  def test_wait_treats_already_reaped_process_as_complete
    supervisor = LocalModelEvaluation::ProcessSupervisor.new

    result = Process.stub(:waitpid, ->(*) { raise Errno::ECHILD }) do
      supervisor.wait(12_345)
    end

    assert_nil result
  end

  def test_real_process_preserves_argv_detaches_stdin_and_is_group_signalable
    Dir.mktmpdir("process-supervisor-") do |root|
      script = File.join(root, "worker.sh")
      log_path = File.join(root, "worker.log")
      File.write(script, <<~'SH')
        #!/bin/sh
        set -eu
        printf 'ARG1=%s\n' "$1"
        printf 'ARG2=%s\n' "$2"
        if IFS= read -r _line; then
          printf 'STDIN=open\n'
        else
          printf 'STDIN=detached\n'
        fi
        printf 'READY\n'
        sleep 30
      SH
      File.chmod(0o755, script)

      supervisor = LocalModelEvaluation::ProcessSupervisor.new
      log = File.open(log_path, "w")
      pid = supervisor.spawn(
        command: [script, "two words", '$HOME'],
        chdir: root,
        output: log
      )
      log.close

      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 2
      until File.file?(log_path) && File.read(log_path).include?("READY")
        flunk "worker did not become ready" if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline

        sleep 0.005
      end

      text = File.read(log_path)
      assert_includes text, "ARG1=two words"
      assert_includes text, 'ARG2=$HOME'
      assert_includes text, "STDIN=detached"

      supervisor.signal_group("TERM", pid)
      waited = nil
      status = nil
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 2
      until waited
        waited, status = supervisor.poll(pid)
        break if waited
        flunk "worker process group did not terminate" if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline

        sleep 0.005
      end

      assert_equal pid, waited
      refute status.success?
    ensure
      supervisor&.signal_group("KILL", pid) if defined?(pid) && pid
      supervisor&.wait(pid) if defined?(pid) && pid
      log&.close unless log&.closed?
    end
  end
end
