# frozen_string_literal: true

require "minitest/autorun"

class RunpodWorkerVramPreflightTest < Minitest::Test
  SCRIPT = File.expand_path("../scripts/setup_runpod_ollama_worker.sh", __dir__)

  def test_accepts_tiny_nominal_vram_reporting_gap
    assert vram_meets_minimum?(reported_mib: 24_564, required_gib: 24)
  end

  def test_rejects_genuinely_smaller_gpu
    refute vram_meets_minimum?(reported_mib: 23_552, required_gib: 24)
  end

  def test_bootstrap_script_uses_same_64_mib_tolerance
    text = File.read(SCRIPT)

    assert_includes text, "VRAM_REPORTING_TOLERANCE_MIB=64"
    assert_includes(
      text,
      "GPU_VRAM_MIB + VRAM_REPORTING_TOLERANCE_MIB >= MIN_VRAM_MIB"
    )
  end

  private

  def vram_meets_minimum?(reported_mib:, required_gib:)
    tolerance_mib = 64
    minimum_mib = required_gib * 1024
    reported_mib + tolerance_mib >= minimum_mib
  end
end
