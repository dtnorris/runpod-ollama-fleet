# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "fileutils"
require "json"
require "stringio"
require_relative "../lib/local_model_evaluation/runpod_cost_control"

class RunpodCostControlTest < Minitest::Test
  def test_runtime_aggregate_cap_blocks_new_dispatch_without_destroying_anything
    Dir.mktmpdir("rpof-cost-") do |root|
      write_active_fleet(root, rate: 5.50)
      control = LocalModelEvaluation::RunpodCostControl.new(root: root, repo_root: root)
      control.enable!(max_total_hourly_usd: 5.00)

      gate = control.dispatch_gate(fleet_key: "default", fleet_id: "20260916T170000Z-pod_a")

      refute gate.fetch("allowed")
      assert_equal "cost.aggregate_cap", gate.fetch("code")
      assert_includes gate.fetch("detail"), "$5.5000/hr"
    end
  end

  def test_enabled_policy_only_tightens_existing_provisioning_cap
    Dir.mktmpdir("rpof-cost-") do |root|
      control = LocalModelEvaluation::RunpodCostControl.new(root: root, repo_root: root)
      control.enable!(max_total_hourly_usd: 5.00)

      assert_in_delta 5.00, control.provisioning_cap(6.00), 0.000001
      assert_in_delta 4.50, control.provisioning_cap(4.50), 0.000001
    end
  end

  def test_temporary_override_expires_automatically
    Dir.mktmpdir("rpof-cost-") do |root|
      now = Time.utc(2026, 9, 16, 17, 0, 0)
      clock = -> { now }
      control = LocalModelEvaluation::RunpodCostControl.new(root: root, repo_root: root, wall_clock: clock)
      control.set_limit!(5.00)
      control.set_override!(max_total_hourly_usd: 6.75, minutes: 20)

      assert_in_delta 6.75, control.effective_max_total_hourly_usd, 0.000001
      now += 21 * 60
      assert_in_delta 5.00, control.effective_max_total_hourly_usd, 0.000001
    end
  end

  def test_ephemeral_fleet_defaults_to_short_idle_and_unavailable_reaping
    Dir.mktmpdir("rpof-cost-") do |root|
      control = LocalModelEvaluation::RunpodCostControl.new(root: root, repo_root: root)
      control.configure_fleet!(fleet_key: "copytest", lifecycle: "ephemeral")

      policy = JSON.parse(File.read(File.join(root, "cost-policy.json")))
      fleet = policy.fetch("fleets").fetch("copytest")
      assert_equal "ephemeral", fleet.fetch("lifecycle")
      assert_in_delta 180.0, fleet.fetch("idle_timeout_seconds"), 0.001
      assert_in_delta 90.0, fleet.fetch("unavailable_timeout_seconds"), 0.001
    end
  end

  def test_soft_limit_must_precede_hard_limit
    Dir.mktmpdir("rpof-cost-") do |root|
      control = LocalModelEvaluation::RunpodCostControl.new(root: root, repo_root: root)

      error = assert_raises(LocalModelEvaluation::RunpodCostControl::Error) do
        control.configure_fleet!(
          fleet_key: "main",
          lifecycle: "persistent",
          soft_max_runtime_seconds: 120,
          hard_max_runtime_seconds: 60
        )
      end

      assert_includes error.message, "soft runtime limit must be less than hard runtime limit"
    end
  end

  def test_draining_fleet_rejects_new_dispatch
    Dir.mktmpdir("rpof-cost-") do |root|
      write_active_fleet(root, rate: 1.09)
      control = LocalModelEvaluation::RunpodCostControl.new(root: root, repo_root: root)
      control.enable!(max_total_hourly_usd: 5.00)
      File.write(
        File.join(root, "cost-control-state.json"),
        JSON.pretty_generate(
          "schema_version" => 1,
          "draining_fleets" => {
            "default" => {
              "fleet_id" => "20260916T170000Z-pod_a",
              "since_utc" => "2026-09-16T17:10:00Z",
              "reasons" => ["soft_spend_limit"]
            }
          },
          "worker_observations" => {},
          "policy_baselines" => {}
        ) + "\n"
      )

      gate = control.dispatch_gate(fleet_key: "default", fleet_id: "20260916T170000Z-pod_a")

      refute gate.fetch("allowed")
      assert_equal "cost.draining", gate.fetch("code")
    end
  end

  def test_soft_runtime_limit_persists_drain_without_interrupting_active_worker
    Dir.mktmpdir("rpof-cost-") do |root|
      now = Time.utc(2026, 9, 16, 17, 0, 0)
      snapshot = policy_snapshot(elapsed: 100.0, cost: 1.0, inference: "active")
      entry = policy_entry(snapshot)
      control = LocalModelEvaluation::RunpodCostControl.new(
        root: root,
        repo_root: root,
        client: Object.new,
        out: StringIO.new,
        wall_clock: -> { now }
      )
      control.define_singleton_method(:active_entries) { [entry] }
      control.configure_fleet!(
        fleet_key: "default",
        lifecycle: "persistent",
        soft_max_runtime_seconds: 60,
        hard_max_runtime_seconds: 120
      )
      control.enable!(max_total_hourly_usd: 5.0)

      control.watch_once # establish generation-relative baseline
      snapshot["tracked_elapsed_seconds"] = 161.0
      now += 61
      control.watch_once

      gate = control.dispatch_gate(fleet_key: "default", fleet_id: entry.fetch("fleet").fetch("fleet_id"))
      refute gate.fetch("allowed")
      assert_equal "cost.draining", gate.fetch("code")
      event = JSON.parse(File.readlines(File.join(root, "cost-events.jsonl")).last)
      assert_equal "drain", event.fetch("action")
      assert_equal "soft_runtime_limit", event.fetch("reason")
    end
  end

  def test_hard_runtime_limit_requests_immediate_teardown_even_while_active
    Dir.mktmpdir("rpof-cost-") do |root|
      now = Time.utc(2026, 9, 16, 17, 0, 0)
      snapshot = policy_snapshot(elapsed: 100.0, cost: 1.0, inference: "active")
      entry = policy_entry(snapshot)
      destroyed = []
      control = LocalModelEvaluation::RunpodCostControl.new(
        root: root,
        repo_root: root,
        client: Object.new,
        wall_clock: -> { now }
      )
      control.define_singleton_method(:active_entries) { [entry] }
      control.define_singleton_method(:destroy_entry!) do |_entry, indices, reason:, state_data:|
        destroyed << [indices, reason]
      end
      control.configure_fleet!(
        fleet_key: "default",
        lifecycle: "persistent",
        soft_max_runtime_seconds: 60,
        hard_max_runtime_seconds: 120
      )
      control.enable!(max_total_hourly_usd: 5.0)

      control.watch_once
      snapshot["tracked_elapsed_seconds"] = 221.0
      now += 121
      control.watch_once

      assert_equal [[[1], "hard_runtime_limit"]], destroyed
    end
  end

  private


  def policy_snapshot(elapsed:, cost:, inference:)
    {
      "tracked_elapsed_seconds" => elapsed,
      "estimated_accrued_cost_usd" => cost,
      "workers" => [
        {
          "index" => 1,
          "pod_id" => "pod_a",
          "lme_status" => "active",
          "inference_status" => inference
        }
      ]
    }
  end

  def policy_entry(snapshot)
    {
      "fleet_key" => "default",
      "fleet" => {
        "fleet_id" => "20260916T170000Z-pod_a",
        "status" => "active",
        "workers" => [{ "index" => 1, "status" => "active" }]
      },
      "status" => snapshot
    }
  end

  def write_active_fleet(root, rate:)
    fleet_id = "20260916T170000Z-pod_a"
    FileUtils.mkdir_p(File.join(root, fleet_id))
    File.write(File.join(root, "current"), "#{fleet_id}\n")
    File.write(
      File.join(root, fleet_id, "fleet.json"),
      JSON.pretty_generate(
        "fleet_id" => fleet_id,
        "status" => "active",
        "fleet_hourly_rate_usd" => rate
      ) + "\n"
    )
  end
end
