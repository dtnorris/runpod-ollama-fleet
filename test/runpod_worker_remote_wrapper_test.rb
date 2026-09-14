# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "fileutils"
require "open3"

class RunpodWorkerRemoteWrapperTest < Minitest::Test
  REPO_ROOT = File.expand_path("..", __dir__)
  SCRIPT = File.join(REPO_ROOT, "scripts", "setup_runpod_worker_remote.sh")

  def test_named_fleet_reads_fleet_scoped_environment_file
    fleet_key = "wrappertest-#{Process.pid}"
    fleet_root = File.join(REPO_ROOT, "output", "runpod-fleets", "fleets", fleet_key)
    env_path = File.join(fleet_root, "fleet.env")
    identity = File.join(fleet_root, "id_ed25519")
    fake_bin = File.join(fleet_root, "bin")
    ssh_log = File.join(fleet_root, "ssh.log")

    FileUtils.mkdir_p(fake_bin)
    File.write(
      env_path,
      [
        "RUNPOD_BURST_1_HOST=203.0.113.10",
        "RUNPOD_BURST_1_SSH_PORT=2222",
        "LME_RUNPOD_FLEET_DIR=#{fleet_root}"
      ].join("\n") + "\n"
    )
    File.write(identity, "test-only\n")

    fake_ssh = File.join(fake_bin, "ssh")
    File.write(fake_ssh, <<~'SH')
      #!/bin/sh
      printf '%s\n' "$*" >> "$FAKE_SSH_LOG"
      case "$*" in
        *direct-ssh-ok*) printf 'direct-ssh-ok\n' ;;
        *) cat >/dev/null ;;
      esac
    SH
    FileUtils.chmod(0o755, fake_ssh)

    env = {
      "LME_RUNPOD_FLEET" => fleet_key,
      "FAKE_SSH_LOG" => ssh_log,
      "PATH" => "#{fake_bin}:#{ENV.fetch("PATH")}"
    }

    stdout, stderr, status = Open3.capture3(
      env,
      SCRIPT,
      "--worker", "1",
      "--identity", identity,
      "--model", "gpt-oss:20b",
      chdir: REPO_ROOT
    )

    assert status.success?, stderr
    assert_includes stdout, "Loading worker 1 connection settings from #{env_path}"
    assert_includes stdout, "Resolved worker 1 -> root@203.0.113.10:2222"

    ssh_calls = File.read(ssh_log)
    assert_includes ssh_calls, "-p 2222"
    assert_includes ssh_calls, "root@203.0.113.10"
  ensure
    FileUtils.rm_rf(fleet_root) if fleet_root
  end
end
