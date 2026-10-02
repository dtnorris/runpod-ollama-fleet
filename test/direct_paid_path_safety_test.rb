# frozen_string_literal: true

require_relative "test_helper"
require_relative "../lib/local_model_evaluation/runpod_direct_paid_safety"

class DirectPaidPathSafetyTest < Minitest::Test
  def test_noninteractive_direct_positive_mutations_are_blocked_but_scale_down_is_allowed
    %w[create scale replace].each do |operation|
      error = assert_raises(LocalModelEvaluation::RunpodDirectPaidSafety::Error) do
        LocalModelEvaluation::RunpodDirectPaidSafety.assert_not_automated!(
          operation:,
          assume_yes: true,
          dry_run: false,
          paid_mutation: true
        )
      end
      assert_includes error.message, "automated direct paid #{operation} is blocked"
    end

    assert LocalModelEvaluation::RunpodDirectPaidSafety.assert_not_automated!(
      operation: "scale",
      assume_yes: true,
      dry_run: false,
      paid_mutation: false
    )
  end

  def test_manual_positive_mutations_require_both_finite_lease_bounds
    %w[create scale replace].each do |operation|
      error = assert_raises(LocalModelEvaluation::RunpodDirectPaidSafety::Error) do
        LocalModelEvaluation::RunpodDirectPaidSafety.assert_complete_manual_lease!(
          operation:,
          lease: { "max_runtime_seconds" => 600.0, "max_spend_usd" => nil },
          dry_run: false
        )
      end
      assert_includes error.message, "finite runtime-and-spend lease"
      assert LocalModelEvaluation::RunpodDirectPaidSafety.assert_complete_manual_lease!(
        operation:,
        lease: { "max_runtime_seconds" => 600.0, "max_spend_usd" => 1.0 },
        dry_run: false
      )
      assert_raises(LocalModelEvaluation::RunpodDirectPaidSafety::Error) do
        LocalModelEvaluation::RunpodDirectPaidSafety.assert_complete_manual_lease!(
          operation:,
          lease: { "max_runtime_seconds" => Float::INFINITY, "max_spend_usd" => 1.0 },
          dry_run: false
        )
      end
    end
  end
end
