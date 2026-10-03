# frozen_string_literal: true

require "minitest/autorun"
require "minitest/mock"
require "stringio"
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

  def test_process_identity_uses_pid_group_and_start_token
    supervisor = LocalModelEvaluation::ProcessSupervisor.new
    command = ["/bin/sleep", "30"]
    Process.stub(:getpgid, 12_345) do
      supervisor.stub(:process_start_token, "proc:987654") do
        identity = supervisor.process_identity(pid: 12_345, command:)

        assert_equal 12_345, identity.fetch("pid")
        assert_equal 12_345, identity.fetch("process_group_id")
        assert_match(/\A[0-9a-f]{64}\z/, identity.fetch("command_sha256"))
        assert supervisor.same_process?(identity)
        refute supervisor.same_process?(identity.merge("start_token" => "different-start"))
      end
    end
  end

  def test_process_identity_falls_back_fail_closed_when_process_already_vanished
    supervisor = LocalModelEvaluation::ProcessSupervisor.new
    Process.stub(:getpgid, ->(*) { raise Errno::ESRCH }) do
      identity = supervisor.process_identity(pid: 12_345, command: ["worker", "arg"])

      assert_equal 12_345, identity.fetch("process_group_id")
      assert_match(/\Aexited-before-capture:/, identity.fetch("start_token"))
      refute supervisor.same_process?(identity)
    end
  end

  def test_same_process_rejects_empty_and_malformed_identity
    supervisor = LocalModelEvaluation::ProcessSupervisor.new

    refute supervisor.same_process?("pid" => 1, "process_group_id" => 1, "start_token" => "")
    refute supervisor.same_process?({})
  end

  def test_linux_process_start_token_uses_proc_stat_start_time
    supervisor = LocalModelEvaluation::ProcessSupervisor.new
    stat = "123 (worker name) S #{Array.new(18, "0").join(' ')} 987654 0"

    File.stub(:file?, true) do
      File.stub(:binread, stat) do
        assert_equal "proc:987654", supervisor.send(:process_start_token, 123)
      end
    end
  end

  def test_non_proc_process_start_token_uses_ps_start_time
    supervisor = LocalModelEvaluation::ProcessSupervisor.new
    stream = StringIO.new("Mon Jan  1 00:00:00 2030\n")

    File.stub(:file?, false) do
      IO.stub(:popen, ->(*_args, &block) { block.call(stream) }) do
        assert_equal "ps:Mon Jan  1 00:00:00 2030", supervisor.send(:process_start_token, 123)
      end
    end
  end
end
