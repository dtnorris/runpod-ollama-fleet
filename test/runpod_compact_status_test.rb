# frozen_string_literal: true

require_relative "test_helper"

class RunpodCompactStatusTest < Minitest::Test
  def setup
    @renderer = LocalModelEvaluation::RunpodCompactStatus.new
  end

  def test_single_fleet_renders_one_truthful_line_per_worker
    snapshot = fleet_snapshot(
      worker(1, provider: "RUNNING", registry: "NOT_READY", model: "gptoss"),
      worker(2, provider: "RUNNING", registry: "READY", model: "qwen27")
    )

    lines = @renderer.render_fleet(snapshot).lines(chomp: true)

    assert_equal 3, lines.length
    assert_match(/^burst_1\s+.*gptoss\s+UP\s+NOT_READY\s+\$0\.4900\/h$/, lines[1])
    assert_match(/^burst_2\s+.*qwen27\s+UP\s+READY\s+\$0\.4900\/h$/, lines[2])
  end

  def test_aggregate_uses_stable_existing_fleet_alias_and_worker_index
    snapshot = aggregate_snapshot(
      worker(1, fleet_alias: "A", model: "gptoss"),
      worker(2, fleet_alias: "A", model: "gptoss"),
      worker(1, fleet_alias: "B", model: "gemma")
    )

    ids = @renderer.render_all(snapshot).lines(chomp: true).drop(1).map { |line| line.split.first }

    assert_equal %w[A1 A2 B1], ids
  end

  def test_unavailable_unpublished_and_unknown_rate_are_explicit
    snapshot = fleet_snapshot(
      worker(1, provider: "NOT_CHECKED", registry: "UNAVAILABLE", rate: nil),
      worker(2, provider: "ERROR", registry: "UNPUBLISHED", rate: nil)
    )

    lines = @renderer.render_fleet(snapshot).lines(chomp: true)

    assert_match(/N\/C\s+UNAVAILABLE\s+-$/, lines[1])
    assert_match(/ERR\s+UNPUBLISHED\s+-$/, lines[2])
  end

  def test_long_gpu_and_model_labels_truncate_visibly_without_wrapping
    snapshot = fleet_snapshot(
      worker(
        1,
        gpu: "NVIDIA RTX PRO 6000 Blackwell Server Edition MIG 2g.48gb",
        model: "qwen3.6:35b-a3b-q4_K_M-with-a-long-distinguishing-suffix"
      )
    )

    [72, 80, 100].each do |width|
      output = LocalModelEvaluation::RunpodCompactStatus.new(width:).render_fleet(snapshot)
      assert_operator output.lines(chomp: true).map(&:length).max, :<=, width
      assert_includes output, "~"
    end
  end

  def test_rendering_does_not_change_machine_snapshot
    snapshot = aggregate_snapshot(worker(1, fleet_alias: "A"))
    before = Marshal.load(Marshal.dump(snapshot))

    @renderer.render_all(snapshot)

    assert_equal before, snapshot
  end

  private

  def fleet_snapshot(*workers)
    { "workers" => workers }
  end

  def aggregate_snapshot(*workers)
    { "active_fleet_count" => workers.empty? ? 0 : 1, "workers" => workers }
  end

  def worker(index, fleet_alias: nil, gpu: "NVIDIA A40", model: "gptoss",
             provider: "RUNNING", registry: "READY", rate: 0.49)
    {
      "index" => index,
      "fleet_alias" => fleet_alias,
      "gpu_id" => gpu,
      "available_models" => model == "-" ? [] : [model],
      "loaded_models" => [],
      "provider_status" => provider,
      "registry_state" => registry,
      "hourly_rate_usd" => rate
    }
  end
end
