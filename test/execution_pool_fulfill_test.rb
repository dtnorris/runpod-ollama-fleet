# frozen_string_literal: true

require "minitest/autorun"
require "json"
require_relative "../lib/runpod_ollama_fleet/execution_pool_fulfill"

class ExecutionPoolFulfillTest < Minitest::Test
  DIGEST = "a" * 64
  PLAN = "b" * 64
  SHARED_MODEL = "shared/qwen35"
  GLOBAL_VOLUME_ID = "global-123"
  OLLAMA_STORE_PATH = "/workspace-global/ollama-models"

  class FakeHardware
    def profile_for(model)
      raise "unexpected model #{model}" unless model == "qwen3.6:35b-a3b"
      RunpodOllamaFleet::ExecutionPoolHardware::Profile.new(
        model:,
        cloud: "SECURE",
        gpu_ids: ["NVIDIA A40", "NVIDIA RTX A6000"],
        shared_model: SHARED_MODEL,
        global_volume_id: GLOBAL_VOLUME_ID,
        ollama_store_path: OLLAMA_STORE_PATH
      )
    end
  end

  class FakeRunner
    attr_reader :capability_request
    attr_reader :calls
    attr_accessor :capacity_status, :capacity_initial, :capacity_final, :capability_ready

    def initialize
      @calls = []
      @capacity_status = "minimum_met"
      @capacity_initial = 0
      @capacity_final = 2
      @capability_ready = true
    end

    def run(argv, env: {})
      @calls << { argv: argv.dup, env: env.dup }
      command = argv.fetch(1)
      case command
      when "fulfill"
        output = value_after(argv, "--output")
        File.write(output, JSON.pretty_generate(
          "contract_version" => "rpof-capacity-fulfillment-result/v0.1",
          "fleet_key" => value_after(argv, "--fleet"),
          "fleet_id" => "fixture-fleet",
          "status" => @capacity_status,
          "target_workers" => 4,
          "minimum_workers" => 2,
          "initial_workers" => @capacity_initial,
          "final_workers" => @capacity_final,
          "stopped_reason" => @capacity_status == "planned" ? "would acquire" : "fixture capacity",
          "attempts" => []
        ))
        %w[fulfilled minimum_met planned].include?(@capacity_status) ? 0 : 1
      when "runtime-alias"
        output = value_after(argv, "--output")
        workers = value_after(argv, "--workers").split(",").map do |index|
          {
            "worker_index" => Integer(index),
            "runtime_model" => value_after(argv, "--runtime-model"),
            "source_model" => value_after(argv, "--source-model"),
            "digest" => value_after(argv, "--expect-digest"),
            "context_length" => Integer(value_after(argv, "--context")),
            "fully_gpu_resident" => true
          }
        end
        File.write(output, JSON.pretty_generate(
          "contract_version" => "rpof-runtime-alias-result/v0.1",
          "ready" => true,
          "workers" => workers
        ))
        0
      when "capability-check"
        request = JSON.parse(File.read(value_after(argv, "--request")))
        @capability_request = request
        output = value_after(argv, "--output")
        selected = request.dig("worker_selector", "indices")
        File.write(output, JSON.pretty_generate(
          "contract_version" => "afio-rpof-capability-check-result/v0.1",
          "ready" => @capability_ready,
          "fleet_key" => request.fetch("fleet_key"),
          "fleet_id" => "fixture-fleet",
          "selected_worker_indices" => selected,
          "capabilities" => @capability_ready ? [{ "gpu_id" => "mixed", "models" => [] }] : nil,
          "diagnostics" => @capability_ready ? [] : [{ "code" => "bootstrap.provenance", "status" => "FAIL", "detail" => "fixture failure" }]
        ))
        @capability_ready ? 0 : 1
      else
        0
      end
    end

    private

    def value_after(argv, flag)
      argv.fetch(argv.index(flag) + 1)
    end
  end

  def request
    {
      "contract_version" => "afio-rpof-execution-pool-fulfill-request/v0.1",
      "plan_sha256" => PLAN,
      "pool_id" => "qwen35",
      "requirements" => {
        "ollama_model" => "qwen3.6:35b-a3b",
        "pull_model" => "qwen3.6:35b-a3b-q4_K_M",
        "expected_digest" => DIGEST,
        "required_context_length" => 131_072,
        "require_fully_gpu_resident" => true
      },
      "capacity" => {
        "desired_workers" => 4,
        "minimum_workers" => 2,
        "max_pool_hourly_usd" => 3.0,
        "max_total_hourly_usd" => 6.0
      }
    }
  end

  def build(runner)
    RunpodOllamaFleet::ExecutionPoolFulfill.new(
      repo_root: Dir.pwd,
      executable: "/fixture/rpof",
      hardware: FakeHardware.new,
      command_runner: runner
    )
  end

  def test_turns_minimum_capacity_into_ready_runtime_pool
    runner = FakeRunner.new
    result = build(runner).run(request, assume_yes: true)

    assert_equal true, result.fetch("ready")
    assert_equal "partial_ready", result.fetch("status")
    assert_equal "ep-qwen35-#{PLAN[0, 10]}", result.fetch("execution_handle")
    assert_equal [1, 2], result.fetch("worker_indices")

    fulfill = runner.calls.find { |row| row.fetch(:argv)[1] == "fulfill" }.fetch(:argv)
    assert_equal ["NVIDIA A40", "NVIDIA RTX A6000"], fulfill.each_index.filter_map { |i| fulfill[i + 1] if fulfill[i] == "--gpu" }
    assert_equal "3.0", fulfill.fetch(fulfill.index("--max-hourly-usd") + 1)
    assert_equal "6.0", fulfill.fetch(fulfill.index("--max-total-hourly-usd") + 1)
    assert_equal GLOBAL_VOLUME_ID, fulfill.fetch(fulfill.index("--global-volume-id") + 1)

    bootstrap = runner.calls.find { |row| row.fetch(:argv)[1] == "bootstrap" }.fetch(:argv)
    assert_equal SHARED_MODEL, bootstrap.fetch(bootstrap.index("--model") + 1)
    assert_includes bootstrap, "#{SHARED_MODEL}=#{DIGEST}"
    assert_equal OLLAMA_STORE_PATH, bootstrap.fetch(bootstrap.index("--copy-from-shared-store") + 1)
    refute_includes bootstrap, request.dig("requirements", "pull_model")

    tunnels = runner.calls.find { |row| row.fetch(:argv)[1] == "tunnels" }
    assert_equal result.fetch("execution_handle"), tunnels.dig(:env, "LME_RUNPOD_FLEET")

    alias_call = runner.calls.find { |row| row.fetch(:argv)[1] == "runtime-alias" }.fetch(:argv)
    assert_equal SHARED_MODEL, alias_call.fetch(alias_call.index("--source-model") + 1)
    assert_equal "qwen3.6:35b-a3b", alias_call.fetch(alias_call.index("--runtime-model") + 1)
    assert_equal "afio-rpof-capability-check-request/v0.2", runner.capability_request.fetch("contract_version")
    capability_model = runner.capability_request.dig("requirements", "models", 0)
    assert_equal "qwen3.6:35b-a3b", capability_model.fetch("name")
    assert_equal DIGEST, capability_model.fetch("expected_digest")
    assert_equal GLOBAL_VOLUME_ID, result.dig("hardware_policy", "global_volume_id")
    assert_equal SHARED_MODEL, result.dig("hardware_policy", "shared_model")
    assert_equal OLLAMA_STORE_PATH, result.dig("hardware_policy", "ollama_store_path")
  end

  def test_failed_readiness_tears_down_only_new_capacity
    runner = FakeRunner.new
    runner.capability_ready = false

    result = build(runner).run(request, assume_yes: true)

    assert_equal false, result.fetch("ready")
    assert_equal "failed", result.fetch("status")
    destroy = runner.calls.find { |row| row.fetch(:argv)[1] == "destroy" }
    refute_nil destroy
    assert_includes result.fetch("detail"), "bootstrap.provenance"
  end

  def test_below_minimum_capacity_is_not_bootstrapped_and_is_torn_down
    runner = FakeRunner.new
    runner.capacity_status = "unfulfilled"
    runner.capacity_final = 1

    result = build(runner).run(request, assume_yes: true)

    assert_equal false, result.fetch("ready")
    assert_equal "unfulfilled", result.fetch("status")
    refute runner.calls.any? { |row| row.fetch(:argv)[1] == "bootstrap" }
    assert runner.calls.any? { |row| row.fetch(:argv)[1] == "destroy" }
  end

  def test_failure_preserves_preexisting_workers_and_scales_back_only_new_tail
    runner = FakeRunner.new
    runner.capacity_initial = 1
    runner.capacity_final = 2
    runner.capability_ready = false

    build(runner).run(request, assume_yes: true)

    scale = runner.calls.find { |row| row.fetch(:argv)[1] == "scale" }.fetch(:argv)
    assert_equal "1", scale.fetch(scale.index("--workers") + 1)
    refute runner.calls.any? { |row| row.fetch(:argv)[1] == "destroy" }
  end

  def test_dry_run_stops_before_paid_or_bootstrap_steps
    runner = FakeRunner.new
    runner.capacity_status = "planned"
    runner.capacity_final = 0

    result = build(runner).run(request, dry_run: true)

    assert_equal false, result.fetch("ready")
    assert_equal "planned", result.fetch("status")
    assert_equal ["fulfill"], runner.calls.map { |row| row.fetch(:argv)[1] }
    fulfill = runner.calls.first.fetch(:argv)
    assert_includes fulfill, "--dry-run"
    refute_includes fulfill, "--yes"
  end
end
