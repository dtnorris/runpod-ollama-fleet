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
    attr_reader :capability_requests
    attr_reader :calls
    attr_accessor :capacity_status, :capacity_initial, :capacity_final, :capability_ready
    attr_accessor :capability_ready_sequence

    def initialize
      @calls = []
      @capability_requests = []
      @capacity_status = "minimum_met"
      @capacity_initial = 0
      @capacity_final = 2
      @capability_ready = true
      @capability_ready_sequence = []
      @rolling_current = nil
      @rolling_limit = nil
    end

    def enable_rolling_capacity(current_workers: 0, limit: nil)
      @rolling_current = Integer(current_workers)
      @rolling_limit = limit && Integer(limit)
    end

    def run(argv, env: {})
      @calls << { argv: argv.dup, env: env.dup }
      command = argv.fetch(1)
      case command
      when "fulfill"
        output = value_after(argv, "--output")
        target = Integer(value_after(argv, "--target-workers"))
        minimum = Integer(value_after(argv, "--minimum-workers"))
        status, initial, final, reason = capacity_response(argv, target)
        File.write(output, JSON.pretty_generate(
          "contract_version" => "rpof-capacity-fulfillment-result/v0.1",
          "fleet_key" => value_after(argv, "--fleet"),
          "fleet_id" => "fixture-fleet",
          "status" => status,
          "target_workers" => target,
          "minimum_workers" => minimum,
          "initial_workers" => initial,
          "final_workers" => final,
          "stopped_reason" => reason,
          "attempts" => []
        ))
        %w[fulfilled minimum_met planned].include?(status) ? 0 : 1
      when "scale"
        @rolling_current = Integer(value_after(argv, "--workers")) unless @rolling_current.nil?
        0
      when "destroy"
        @rolling_current = 0 unless @rolling_current.nil?
        0
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
        @capability_requests << request
        output = value_after(argv, "--output")
        selected = request.dig("worker_selector", "indices")
        ready = @capability_ready_sequence.empty? ? @capability_ready : @capability_ready_sequence.shift
        File.write(output, JSON.pretty_generate(
          "contract_version" => "afio-rpof-capability-check-result/v0.1",
          "ready" => ready,
          "fleet_key" => request.fetch("fleet_key"),
          "fleet_id" => "fixture-fleet",
          "selected_worker_indices" => selected,
          "capabilities" => ready ? [{ "gpu_id" => "mixed", "models" => [] }] : nil,
          "diagnostics" => ready ? [] : [{ "code" => "bootstrap.provenance", "status" => "FAIL", "detail" => "fixture failure" }]
        ))
        ready ? 0 : 1
      else
        0
      end
    end

    private

    def capacity_response(argv, target)
      unless @rolling_current.nil?
        initial = @rolling_current
        if argv.include?("--dry-run")
          status = @rolling_limit && initial >= @rolling_limit ? "unavailable" : "planned"
          return [status, initial, initial, status == "planned" ? "would acquire" : "fixture capacity unavailable"]
        end

        if @rolling_limit && target > @rolling_limit
          return ["unfulfilled", initial, initial, "fixture capacity limit reached"]
        end

        @rolling_current = target
        return ["fulfilled", initial, target, "target worker count reached"]
      end

      reason = @capacity_status == "planned" ? "would acquire" : "fixture capacity"
      [@capacity_status, @capacity_initial, @capacity_final, reason]
    end

    def value_after(argv, flag)
      argv.fetch(argv.index(flag) + 1)
    end
  end

  def request
    {
      "contract_version" => "afio-rpof-execution-pool-fulfill-request/v0.1",
      "plan_sha256" => PLAN,
      "pool_id" => "qwen35",
      "budget" => {
        "contract_version" => "afio-production-burst-budget/v0.1",
        "budget_id" => "batch034",
        "plan_sha256" => PLAN,
        "max_cumulative_compute_usd" => 5.0,
        "max_runtime_seconds" => 2700,
        "guardian_poll_seconds" => 5,
        "orchestrator_heartbeat_timeout_seconds" => 30,
        "teardown_reserve_seconds" => 60
      },
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

  def test_prepare_next_worker_from_empty_pool_prepares_only_worker_one
    runner = FakeRunner.new
    runner.capacity_status = "fulfilled"
    runner.capacity_initial = 0
    runner.capacity_final = 1

    result = build(runner).prepare_next_worker(request, current_workers: 0, assume_yes: true)

    assert_equal true, result.fetch("ready")
    assert_equal "ready", result.fetch("status")
    assert_equal 1, result.fetch("worker_index")

    fulfill = runner.calls.find { |row| row.fetch(:argv)[1] == "fulfill" }.fetch(:argv)
    assert_equal "1", fulfill.fetch(fulfill.index("--target-workers") + 1)
    assert_equal "1", fulfill.fetch(fulfill.index("--minimum-workers") + 1)
    assert_equal "0", fulfill.fetch(fulfill.index("--expect-initial-workers") + 1)
    assert_equal "batch034", fulfill.fetch(fulfill.index("--budget-id") + 1)
    assert_equal PLAN, fulfill.fetch(fulfill.index("--budget-plan-sha256") + 1)

    %w[bootstrap runtime-alias].each do |command|
      argv = runner.calls.find { |row| row.fetch(:argv)[1] == command }.fetch(:argv)
      assert_equal "1", argv.fetch(argv.index("--workers") + 1)
    end
    tunnels = runner.calls.find { |row| row.fetch(:argv)[1] == "tunnels" }.fetch(:argv)
    assert_equal "1", tunnels.fetch(tunnels.index("--workers") + 1)
    assert_equal [1], runner.capability_request.dig("worker_selector", "indices")
  end

  def test_prepare_next_worker_after_existing_worker_targets_only_next_slot
    runner = FakeRunner.new
    runner.capacity_status = "fulfilled"
    runner.capacity_initial = 1
    runner.capacity_final = 2

    result = build(runner).prepare_next_worker(request, current_workers: 1, assume_yes: true)

    assert_equal true, result.fetch("ready")
    assert_equal 2, result.fetch("worker_index")
    bootstrap = runner.calls.find { |row| row.fetch(:argv)[1] == "bootstrap" }.fetch(:argv)
    assert_equal "2", bootstrap.fetch(bootstrap.index("--workers") + 1)
    assert_equal [2], runner.capability_request.dig("worker_selector", "indices")
  end

  def test_prepare_next_worker_failure_preserves_existing_workers
    runner = FakeRunner.new
    runner.capacity_status = "fulfilled"
    runner.capacity_initial = 1
    runner.capacity_final = 2
    runner.capability_ready = false

    result = build(runner).prepare_next_worker(request, current_workers: 1, assume_yes: true)

    assert_equal false, result.fetch("ready")
    assert_equal "failed", result.fetch("status")
    scale = runner.calls.find { |row| row.fetch(:argv)[1] == "scale" }.fetch(:argv)
    assert_equal "1", scale.fetch(scale.index("--workers") + 1)
    refute runner.calls.any? { |row| row.fetch(:argv)[1] == "destroy" }
  end

  def test_prepare_next_worker_capacity_miss_does_not_touch_existing_workers
    runner = FakeRunner.new
    runner.capacity_status = "unfulfilled"
    runner.capacity_initial = 1
    runner.capacity_final = 1

    result = build(runner).prepare_next_worker(request, current_workers: 1, assume_yes: true)

    assert_equal false, result.fetch("ready")
    assert_equal "capacity_unavailable", result.fetch("status")
    assert_equal 2, result.fetch("worker_index")
    assert_equal ["fulfill"], runner.calls.map { |row| row.fetch(:argv)[1] }
  end

  def test_prepare_next_worker_refuses_when_desired_capacity_is_already_met
    runner = FakeRunner.new

    error = assert_raises(RunpodOllamaFleet::ExecutionPoolFulfill::Error) do
      build(runner).prepare_next_worker(request, current_workers: 4, assume_yes: true)
    end

    assert_includes error.message, "already meet desired capacity"
    assert_empty runner.calls
  end

  def test_run_prepares_workers_serially_to_desired_capacity
    runner = FakeRunner.new
    runner.enable_rolling_capacity

    result = build(runner).run(request, assume_yes: true)

    assert_equal true, result.fetch("ready")
    assert_equal "ready", result.fetch("status")
    assert_equal [1, 2, 3, 4], result.fetch("worker_indices")
    assert_equal 0, result.dig("capacity", "initial_workers")
    assert_equal 4, result.dig("capacity", "final_workers")

    fulfill_calls = runner.calls.select { |row| row.fetch(:argv)[1] == "fulfill" }.map { |row| row.fetch(:argv) }
    assert_includes fulfill_calls.first, "--dry-run"
    paid = fulfill_calls.drop(1)
    assert_equal %w[1 2 3 4], paid.map { |argv| argv.fetch(argv.index("--target-workers") + 1) }
    assert_equal %w[0 1 2 3], paid.map { |argv| argv.fetch(argv.index("--expect-initial-workers") + 1) }
    assert paid.all? { |argv| argv.fetch(argv.index("--global-volume-id") + 1) == GLOBAL_VOLUME_ID }
    assert paid.all? { |argv| argv.fetch(argv.index("--max-hourly-usd") + 1) == "3.0" }
    assert paid.all? { |argv| argv.fetch(argv.index("--max-total-hourly-usd") + 1) == "6.0" }

    bootstraps = runner.calls.select { |row| row.fetch(:argv)[1] == "bootstrap" }.map { |row| row.fetch(:argv) }
    assert_equal %w[1 2 3 4], bootstraps.map { |argv| argv.fetch(argv.index("--workers") + 1) }
    refute bootstraps.any? { |argv| argv.fetch(argv.index("--workers") + 1).include?(",") }
    bootstraps.each do |argv|
      assert_equal SHARED_MODEL, argv.fetch(argv.index("--model") + 1)
      assert_includes argv, "#{SHARED_MODEL}=#{DIGEST}"
      assert_equal OLLAMA_STORE_PATH, argv.fetch(argv.index("--copy-from-shared-store") + 1)
      refute_includes argv, request.dig("requirements", "pull_model")
    end

    alias_calls = runner.calls.select { |row| row.fetch(:argv)[1] == "runtime-alias" }.map { |row| row.fetch(:argv) }
    assert_equal 4, alias_calls.length
    assert alias_calls.all? { |argv| argv.fetch(argv.index("--source-model") + 1) == SHARED_MODEL }
    assert alias_calls.all? { |argv| argv.fetch(argv.index("--runtime-model") + 1) == "qwen3.6:35b-a3b" }

    assert_equal [1, 2, 3, 4], runner.capability_requests.last.dig("worker_selector", "indices")
    capability_model = runner.capability_requests.last.dig("requirements", "models", 0)
    assert_equal DIGEST, capability_model.fetch("expected_digest")
    assert_equal GLOBAL_VOLUME_ID, result.dig("hardware_policy", "global_volume_id")
    assert_equal SHARED_MODEL, result.dig("hardware_policy", "shared_model")
    assert_equal OLLAMA_STORE_PATH, result.dig("hardware_policy", "ollama_store_path")
  end

  def test_run_reuses_only_existing_workers_that_pass_capability_and_rolls_from_next_slot
    runner = FakeRunner.new
    runner.enable_rolling_capacity(current_workers: 2)

    result = build(runner).run(request, assume_yes: true)

    assert_equal true, result.fetch("ready")
    assert_equal [1, 2, 3, 4], result.fetch("worker_indices")
    assert_equal [1, 2], runner.capability_requests.first.dig("worker_selector", "indices")
    bootstraps = runner.calls.select { |row| row.fetch(:argv)[1] == "bootstrap" }.map { |row| row.fetch(:argv) }
    assert_equal %w[3 4], bootstraps.map { |argv| argv.fetch(argv.index("--workers") + 1) }
  end

  def test_run_fails_closed_when_existing_workers_are_not_ready
    runner = FakeRunner.new
    runner.enable_rolling_capacity(current_workers: 2)
    runner.capability_ready = false

    result = build(runner).run(request, assume_yes: true)

    assert_equal false, result.fetch("ready")
    assert_equal "failed", result.fetch("status")
    assert_includes result.fetch("detail"), "existing execution workers are not ready"
    fulfill_calls = runner.calls.select { |row| row.fetch(:argv)[1] == "fulfill" }
    assert_equal 1, fulfill_calls.length
    assert_includes fulfill_calls.first.fetch(:argv), "--dry-run"
    refute runner.calls.any? { |row| row.fetch(:argv)[1] == "bootstrap" }
  end

  def test_run_retains_minimum_ready_prefix_when_target_capacity_is_unavailable
    runner = FakeRunner.new
    runner.enable_rolling_capacity(limit: 2)

    result = build(runner).run(request, assume_yes: true)

    assert_equal true, result.fetch("ready")
    assert_equal "partial_ready", result.fetch("status")
    assert_equal [1, 2], result.fetch("worker_indices")
    assert_equal 2, result.dig("capacity", "final_workers")
    assert_includes result.fetch("detail"), "fixture capacity limit reached"
    refute runner.calls.any? { |row| %w[scale destroy].include?(row.fetch(:argv)[1]) }
  end

  def test_run_cleans_back_to_initial_capacity_when_minimum_is_not_reached
    runner = FakeRunner.new
    runner.enable_rolling_capacity(limit: 1)

    result = build(runner).run(request, assume_yes: true)

    assert_equal false, result.fetch("ready")
    assert_equal "unfulfilled", result.fetch("status")
    assert_equal [], result.fetch("worker_indices")
    bootstraps = runner.calls.select { |row| row.fetch(:argv)[1] == "bootstrap" }.map { |row| row.fetch(:argv) }
    assert_equal ["1"], bootstraps.map { |argv| argv.fetch(argv.index("--workers") + 1) }
    assert runner.calls.any? { |row| row.fetch(:argv)[1] == "destroy" }
  end

  def test_run_retains_minimum_ready_prefix_when_next_bootstrap_fails
    runner = FakeRunner.new
    runner.enable_rolling_capacity
    runner.capability_ready_sequence = [true, true, false, true]

    result = build(runner).run(request, assume_yes: true)

    assert_equal true, result.fetch("ready")
    assert_equal "partial_ready", result.fetch("status")
    assert_equal [1, 2], result.fetch("worker_indices")
    scale = runner.calls.find { |row| row.fetch(:argv)[1] == "scale" }.fetch(:argv)
    assert_equal "2", scale.fetch(scale.index("--workers") + 1)
    assert_includes result.fetch("detail"), "bootstrap.provenance"
  end

  def test_dry_run_stops_before_paid_or_bootstrap_steps
    runner = FakeRunner.new
    runner.enable_rolling_capacity

    result = build(runner).run(request, dry_run: true)

    assert_equal false, result.fetch("ready")
    assert_equal "planned", result.fetch("status")
    assert_equal ["fulfill"], runner.calls.map { |row| row.fetch(:argv)[1] }
    fulfill = runner.calls.first.fetch(:argv)
    assert_includes fulfill, "--dry-run"
    refute_includes fulfill, "--yes"
  end
end
