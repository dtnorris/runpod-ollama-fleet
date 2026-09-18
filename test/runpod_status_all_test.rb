# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/local_model_evaluation/runpod_status_all"

class RunpodStatusAllTest < Minitest::Test
  def setup
    @overview = LocalModelEvaluation::RunpodStatusAll.new
  end

  def test_aggregates_active_named_fleets_workers_cost_and_inference
    snapshot = @overview.snapshot(
      [
        entry(
          "batch31-gptoss",
          rate: 0.98,
          accrued: 0.41,
          workers: [
            worker(1, "pod_a", "NVIDIA A40", 0.49,
                   available: ["gpt-oss:20b"], loaded: ["gpt-oss:20b"], inference: "idle"),
            worker(2, "pod_b", "NVIDIA A40", 0.49,
                   available: ["gpt-oss:20b"], loaded: ["gpt-oss:20b"], inference: "active")
          ],
          bootstrap_workers: [bootstrap_worker(1, "pod_a"), bootstrap_worker(2, "pod_b")]
        ),
        entry(
          "batch31-nos-qwen27",
          rate: 1.06,
          accrued: 0.09,
          workers: [
            worker(1, "pod_c", "NVIDIA RTX A6000", 0.53,
                   model_status: "unavailable", inference: "unavailable"),
            worker(2, "pod_d", "NVIDIA RTX A6000", 0.53,
                   model_status: "unavailable", inference: "unavailable")
          ],
          bootstrap_workers: []
        ),
        entry(
          "old-destroyed",
          rate: 0.0,
          accrued: 1.0,
          workers: [],
          lme_status: "destroyed",
          bootstrap_workers: []
        )
      ]
    )

    assert_equal 2, snapshot.fetch("active_fleet_count")
    assert_equal 4, snapshot.fetch("active_worker_count")
    assert_in_delta 2.04, snapshot.fetch("current_tracked_hourly_rate_usd"), 0.000001
    assert_in_delta 0.50, snapshot.fetch("estimated_accrued_cost_usd"), 0.000001
    assert_equal(
      { "active" => 1, "idle" => 1, "unavailable" => 2, "unknown" => 0 },
      snapshot.fetch("inference_counts")
    )

    output = @overview.render(snapshot)
    assert_includes output, "RunPod aggregate status"
    assert_includes output, "Active fleets: 2"
    assert_includes output, "Active workers: 4"
    assert_includes output, "Current managed rate: $2.0400/hr"
    assert_includes output, "Fleet aliases (current active set):"
    assert_includes output, "A: batch31-gptoss"
    assert_includes output, "B: batch31-nos-qwen27"
    assert_match(/^A\s+1\s+NVIDIA A40.*gpt-oss:20b.*gpt-oss:20b.*IDLE.*READY$/, output)
    assert_match(/^B\s+1\s+NVIDIA RTX A6000.*-.*UNAVAILABLE.*UNAVAILABLE.*-$/, output)
    refute_includes output, "old-destroyed"
  end

  def test_excludes_destroyed_workers_from_active_fleet_rate_table
    fleet = entry(
      "mixed-lifecycle",
      rate: 0.53,
      accrued: 0.90,
      workers: [
        worker(1, "pod_a", "NVIDIA RTX A6000", 0.53, inference: "idle"),
        worker(2, "pod_b", "NVIDIA RTX A6000", 0.53, lme_status: "destroyed", inference: "unknown")
      ],
      bootstrap_workers: []
    )

    snapshot = @overview.snapshot([fleet])

    assert_equal 1, snapshot.fetch("active_worker_count")
    assert_equal 1, snapshot.fetch("workers").length
    assert_equal 1, snapshot.fetch("inference_counts").fetch("idle")
    assert_equal 0, snapshot.fetch("inference_counts").fetch("unknown")
  end

  def test_empty_or_nonactive_input_is_clean_zero_state
    snapshot = @overview.snapshot(
      [entry("finished", rate: 0.0, accrued: 0.25, workers: [], lme_status: "destroyed", bootstrap_workers: [])]
    )

    assert_equal 0, snapshot.fetch("active_fleet_count")
    assert_equal 0, snapshot.fetch("active_worker_count")
    assert_equal "No active managed RunPod fleets.\n", @overview.render(snapshot)
  end

  def test_bootstrap_label_rejects_stale_pod_generation
    fleet = entry(
      "replacement",
      rate: 0.49,
      accrued: 0.10,
      workers: [worker(1, "new_pod", "NVIDIA A40", 0.49, available: ["gpt-oss:20b"], inference: "idle")],
      bootstrap_workers: [bootstrap_worker(1, "old_pod")]
    )

    output = @overview.render(@overview.snapshot([fleet]))

    assert_includes output, "A: replacement"
    assert_match(/^A\s+1\s+.*gpt-oss:20b.*IDLE.*-$/, output)
    refute_match(/^A\s+1\s+.*READY$/, output)
  end

  def test_render_truncates_long_gpu_and_model_labels_and_keeps_full_fleet_alias
    fleet = entry(
      "batch31-qwen35-main",
      rate: 1.09,
      accrued: 0.10,
      workers: [
        worker(
          1,
          "pod_a",
          "NVIDIA RTX PRO 6000 Blackwell Server Edition MIG 2g.48gb",
          1.09,
          available: ["qwen3.6:35b-a3b-q4_K_M"],
          loaded: ["qwen3.6:35b-a3b-q4_K_M"],
          inference: "active"
        )
      ],
      bootstrap_workers: [bootstrap_worker(1, "pod_a")]
    )

    output = @overview.render(@overview.snapshot([fleet]))

    assert_includes output, "A: batch31-qwen35-main"
    assert_includes output, "NVIDIA RTX PRO ..."
    assert_includes output, "qwen3.6:35b-a3b..."
    refute_includes output, "NVIDIA RTX PRO 6000 Blackwell Server Edition MIG 2g.48gb"
  end

  def test_bootstrap_copy_progress_renders_in_existing_column
    bootstrap = bootstrap_worker(1, "pod_a")
    bootstrap["status"] = "running"
    bootstrap["stage"] = "COPYING"
    bootstrap["progress"] = "37%"
    fleet = entry(
      "copying",
      rate: 0.49,
      accrued: 0.10,
      workers: [worker(1, "pod_a", "NVIDIA A40", 0.49)],
      bootstrap_workers: [bootstrap]
    )

    output = @overview.render(@overview.snapshot([fleet]))

    assert_match(/^A\s+1\s+.*COPYING 37%$/, output)
  end

  def test_copying_without_progress_and_terminal_labels_remain_unchanged
    copying = bootstrap_worker(1, "pod_a")
    copying["status"] = "running"
    copying["stage"] = "COPYING"
    failed = bootstrap_worker(2, "pod_b")
    failed["status"] = "failed"
    failed["stage"] = "COPYING"
    failed["progress"] = "91%"
    fleet = entry(
      "labels",
      rate: 0.98,
      accrued: 0.10,
      workers: [
        worker(1, "pod_a", "NVIDIA A40", 0.49),
        worker(2, "pod_b", "NVIDIA A40", 0.49)
      ],
      bootstrap_workers: [copying, failed]
    )

    output = @overview.render(@overview.snapshot([fleet]))

    assert_match(/^A\s+1\s+.*COPYING$/, output)
    assert_match(/^A\s+2\s+.*FAILED$/, output)
  end

  private

  def entry(key, rate:, accrued:, workers:, bootstrap_workers:, lme_status: "active")
    {
      "fleet_key" => key,
      "snapshot" => {
        "lme_status" => lme_status,
        "current_tracked_hourly_rate_usd" => rate,
        "estimated_accrued_cost_usd" => accrued,
        "workers" => workers,
        "bootstrap" => {
          "status" => "passed",
          "workers" => bootstrap_workers
        }
      }
    }
  end

  def worker(index, pod_id, gpu, rate, available: [], loaded: [], model_status: "ok",
             inference: "idle", lme_status: "active")
    {
      "index" => index,
      "pod_id" => pod_id,
      "gpu_id" => gpu,
      "available_models" => available,
      "loaded_models" => loaded,
      "model_status" => model_status,
      "lme_status" => lme_status,
      "provider_status" => lme_status == "active" ? "RUNNING" : "-",
      "hourly_rate_usd" => rate,
      "inference_status" => inference
    }
  end

  def bootstrap_worker(index, pod_id)
    {
      "index" => index,
      "pod_id" => pod_id,
      "status" => "passed",
      "stage" => "READY"
    }
  end
end
