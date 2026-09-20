# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "fileutils"
require "open3"
require_relative "../lib/local_model_evaluation/runpod_workers"

class RunpodScriptsTest < Minitest::Test
  parallelize_me!

  REPO_ROOT = File.expand_path("..", __dir__)

  def setup
    @tmp = Dir.mktmpdir("lme-runpod-scripts-")
    @repo = File.join(@tmp, "repo")
    @bin = File.join(@tmp, "bin")
    FileUtils.mkdir_p(File.join(@repo, "scripts"))
    FileUtils.mkdir_p(@bin)

    %w[
      runpod_ollama_tunnel.sh
      setup_runpod_worker_remote.sh
      setup_runpod_ollama_worker.sh
    ].each do |name|
      src = File.join(REPO_ROOT, "scripts", name)
      dst = File.join(@repo, "scripts", name)
      FileUtils.cp(src, dst)
      FileUtils.chmod(0o755, dst)
    end

    @identity = File.join(@tmp, "id_ed25519")
    File.write(@identity, "test-key\n")
    @ssh_log = File.join(@tmp, "ssh.log")
    @stdin_log = File.join(@tmp, "stdin.log")
    @fleet_dir = File.join(@repo, "output", "runpod-fleets", "test-fleet")
    FileUtils.mkdir_p(@fleet_dir)

    write_fake_ssh
  end

  def teardown
    FileUtils.remove_entry(@tmp) if @tmp && File.exist?(@tmp)
  end

  def test_tunnel_worker_mode_resolves_local_port_from_dotenv
    write_env(
      "LME_RUNPOD_FLEET_DIR=#{@fleet_dir}",
      "LME_BURST_2_URL=http://127.0.0.1:11442",
      "RUNPOD_BURST_2_HOST=198.51.100.22",
      "RUNPOD_BURST_2_SSH_PORT=22422"
    )

    stdout, stderr, status = run_script("runpod_ollama_tunnel.sh", "--stop", "--worker", "2")

    assert status.success?, stderr
    assert_includes stdout, "Loading worker connection settings"
    assert_includes stdout, "local port 11442"
    assert_includes stdout, "nothing to stop"
  end

  def test_tunnel_explicit_connection_flags_override_worker_dotenv
    write_env(
      "LME_RUNPOD_FLEET_DIR=#{@fleet_dir}",
      "LME_BURST_2_URL=http://127.0.0.1:11442",
      "RUNPOD_BURST_2_HOST=env-host.example",
      "RUNPOD_BURST_2_SSH_PORT=22002"
    )

    _stdout, stderr, status = run_script(
      "runpod_ollama_tunnel.sh",
      "--worker", "2",
      "--host", "203.0.113.99",
      "--ssh-port", "22999",
      "--local-port", "11999",
      "--identity", @identity,
      "--wait-seconds", "0"
    )

    refute status.success?
    assert_includes stderr, "Ollama did not become reachable"

    log = File.read(@ssh_log)
    assert_includes log, "-p 22999"
    assert_includes log, "root@203.0.113.99"
    refute_includes log, "env-host.example"
  end

  def test_tunnel_worker_mode_requires_fleet_scoped_state_dir
    write_env(
      "LME_BURST_2_URL=http://127.0.0.1:11442",
      "RUNPOD_BURST_2_HOST=198.51.100.22",
      "RUNPOD_BURST_2_SSH_PORT=22422"
    )

    _stdout, stderr, status = run_script("runpod_ollama_tunnel.sh", "--stop", "--worker", "2")

    refute status.success?
    assert_includes stderr, "LME_RUNPOD_FLEET_DIR is not set"
    refute File.exist?(File.join(@repo, "output", "tunnels"))
  end

  def test_remote_setup_wrapper_forwards_arguments_and_uses_distinct_fleet_scoped_known_hosts_files
    digest = "9d5803d493a991af27b9441c098aa56f2ed7bbd260877f075ec09b575c049bc3"
    write_env(
      "LME_RUNPOD_FLEET_DIR=#{@fleet_dir}",
      "RUNPOD_BURST_1_HOST=198.51.100.41",
      "RUNPOD_BURST_1_SSH_PORT=22441",
      "RUNPOD_BURST_2_HOST=198.51.100.42",
      "RUNPOD_BURST_2_SSH_PORT=22442"
    )

    threads = {
      1 => Thread.new do
        run_script(
          "setup_runpod_worker_remote.sh",
          "--worker", "1",
          "--identity", @identity,
          "--model", "qwen3.6:27b"
        )
      end,
      2 => Thread.new do
        run_script(
          "setup_runpod_worker_remote.sh",
          "--worker", "2",
          "--identity", @identity,
          "--clean",
          "--model", "qwen3.6:27b",
          "--expect-digest", "qwen3.6:27b=#{digest}"
        )
      end
    }
    results = threads.transform_values(&:value)

    results.each_value do |_stdout, stderr, status|
      assert status.success?, stderr
    end
    worker_2_stdout = results.fetch(2).fetch(0)
    assert_includes worker_2_stdout, "Resolved worker 2 -> root@198.51.100.42:22442"
    assert_includes worker_2_stdout, "remote setup PASS"

    log = File.read(@ssh_log)
    worker_1_hosts = File.join(@fleet_dir, "ssh", "known_hosts-burst_1")
    worker_2_hosts = File.join(@fleet_dir, "ssh", "known_hosts-burst_2")
    assert_includes log, "UserKnownHostsFile=#{worker_1_hosts}"
    assert_includes log, "UserKnownHostsFile=#{worker_2_hosts}"
    assert_equal 2, log.scan("UserKnownHostsFile=#{worker_2_hosts}").length
    refute_equal worker_1_hosts, worker_2_hosts
    assert File.file?(worker_1_hosts)
    assert File.file?(worker_2_hosts)
    assert_includes log, "-p 22442"
    assert_includes log, "root@198.51.100.42"
    assert_includes log, "bash -s -- --clean --model qwen3.6:27b --expect-digest qwen3.6:27b=#{digest}"

    streamed = File.read(@stdin_log)
    assert_includes streamed, "Bootstrap an already-created RunPod GPU worker"
  end

  def test_remote_setup_wrapper_requires_fleet_scoped_ssh_state
    write_env(
      "RUNPOD_BURST_2_HOST=198.51.100.42",
      "RUNPOD_BURST_2_SSH_PORT=22442"
    )

    _stdout, stderr, status = run_script(
      "setup_runpod_worker_remote.sh",
      "--worker", "2",
      "--identity", @identity,
      "--model", "qwen3.6:27b"
    )

    refute status.success?
    assert_includes stderr, "LME_RUNPOD_FLEET_DIR is not set"
    refute File.exist?(@ssh_log), "SSH should not be attempted without fleet-scoped host-key state"
  end

  def test_remote_setup_wrapper_fails_before_ssh_when_worker_coordinates_are_missing
    write_env("RUNPOD_BURST_2_SSH_PORT=22442")

    _stdout, stderr, status = run_script(
      "setup_runpod_worker_remote.sh",
      "--worker", "2",
      "--identity", @identity,
      "--model", "qwen3.6:27b"
    )

    refute status.success?
    assert_includes stderr, "RUNPOD_BURST_2_HOST is not set"
    refute File.exist?(@ssh_log), "SSH should not be attempted when .env is incomplete"
  end

  private

  def write_env(*lines)
    File.write(File.join(@repo, ".env"), lines.join("\n") + "\n")
  end

  def run_script(name, *args)
    env = {
      "PATH" => "#{@bin}:#{ENV.fetch("PATH")}",
      "FAKE_SSH_LOG" => @ssh_log,
      "FAKE_STDIN_LOG" => @stdin_log,
      "LME_SCRIPT_TIMESTAMPS" => "0"
    }

    # Other tests load the repo-local .env through dotenv. Do not let those
    # real worker coordinates leak into these isolated script fixtures.
    env["LME_RUNPOD_FLEET_DIR"] = nil

    (1..LocalModelEvaluation::RunpodWorkers::MAX_WORKERS).each do |worker|
      env["LME_BURST_#{worker}_URL"] = nil
      env["RUNPOD_BURST_#{worker}_HOST"] = nil
      env["RUNPOD_BURST_#{worker}_SSH_PORT"] = nil
    end

    Open3.capture3(env, File.join(@repo, "scripts", name), *args)
  end

  def write_fake_ssh
    path = File.join(@bin, "ssh")
    File.write(path, <<~'SH')
      #!/bin/sh
      set -eu
      printf '%s\n' "$*" >> "$FAKE_SSH_LOG"

      case "$*" in
        *direct-ssh-ok*)
          printf 'direct-ssh-ok\n'
          exit 0
          ;;
        *" -N "*)
          exec sleep 30
          ;;
      esac

      cat > "$FAKE_STDIN_LOG"
      exit 0
    SH
    FileUtils.chmod(0o755, path)
  end
end
