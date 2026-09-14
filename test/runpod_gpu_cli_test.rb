# frozen_string_literal: true

require_relative "test_helper"
require "json"
require "open3"
require "rbconfig"
require "socket"
require "timeout"
require "tmpdir"
require "fileutils"

class RunpodGpuCliTest < Minitest::Test
  REPO_ROOT = File.expand_path("..", __dir__)

  def setup
    @tmp = Dir.mktmpdir("runpod-gpu-cli-")
    @public_key = File.join(@tmp, "id_ed25519.pub")
    File.write(@public_key, "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAITest cli@example\n")
  end

  def teardown
    FileUtils.remove_entry(@tmp) if @tmp && File.exist?(@tmp)
  end

  def test_create_dry_run_accepts_first_class_a6000
    requests = Queue.new
    server, thread = start_fake_runpod(requests)
    port = server.addr[1]
    fleet_key = "gpu-test-#{Process.pid}"
    env = {
      "RUNPOD_API_KEY" => "rpa_test_only",
      "RUNPOD_API_BASE_URL" => "http://127.0.0.1:#{port}/v2",
      "RUNPOD_MAX_FLEET_HOURLY_USD" => "1.00",
      "RUNPOD_MAX_TOTAL_HOURLY_USD" => "1.00",
      "RPOF_STATE_ROOT" => File.join(@tmp, "state"),
      "RPOF_STATE_REPO_ROOT" => @tmp
    }

    stdout, stderr, status = Open3.capture3(
      env,
      RbConfig.ruby,
      File.join(REPO_ROOT, "bin", "rpof"),
      "create",
      "--workers", "1",
      "--cloud", "SECURE",
      "--gpu", "NVIDIA RTX A6000",
      "--fleet", fleet_key,
      "--dry-run",
      "--ssh-public-key", @public_key,
      chdir: REPO_ROOT
    )

    assert status.success?, stderr
    assert_includes stdout, "GPU: NVIDIA RTX A6000 (48 GB VRAM)"
    assert_includes stdout, "Catalog rate: $0.5300/hr per worker"
    assert_includes stdout, "Dry run PASS."

    received = 2.times.map { Timeout.timeout(2) { requests.pop } }
    assert_equal ["GET", "GET"], received.map { |request| request.fetch(:method) }
  ensure
    server&.close
    thread&.kill
    thread&.join(1)
  end

  private

  def start_fake_runpod(requests)
    server = TCPServer.new("127.0.0.1", 0)
    thread = Thread.new do
      2.times do
        socket = server.accept
        request_line = socket.gets.to_s
        method, target, = request_line.split(" ")
        while (line = socket.gets)
          break if line == "\r\n"
        end
        path = target.to_s.split("?", 2).first
        requests << { method:, path: }
        body = if path == "/v2/pods"
                 JSON.generate("pods" => [])
               else
                 JSON.generate(
                   "gpus" => [{
                     "id" => "NVIDIA RTX A6000",
                     "name" => "RTX A6000",
                     "memory" => 48,
                     "secure" => true,
                     "community" => true,
                     "price" => { "secure" => 0.53, "community" => 0.36 },
                     "maxCount" => { "secure" => 8, "community" => 8 },
                     "availability" => "HIGH"
                   }]
                 )
               end
        socket.write("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: #{body.bytesize}\r\nConnection: close\r\n\r\n#{body}")
        socket.close
      end
    end
    [server, thread]
  end
end
