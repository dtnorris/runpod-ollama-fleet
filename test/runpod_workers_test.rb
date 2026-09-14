# frozen_string_literal: true

require_relative "test_helper"

class RunpodWorkersTest < Minitest::Test
  def test_canonical_worker_bounds
    [1, 8, 12, 16].each do |count|
      assert_equal count, LocalModelEvaluation::RunpodWorkers.validate_count(count)
      assert_equal count, LocalModelEvaluation::RunpodWorkers.validate_index(count)
    end

    [0, 17].each do |count|
      assert_raises(LocalModelEvaluation::RunpodWorkers::Error) do
        LocalModelEvaluation::RunpodWorkers.validate_count(count)
      end
      assert_raises(LocalModelEvaluation::RunpodWorkers::Error) do
        LocalModelEvaluation::RunpodWorkers.validate_index(count)
      end
    end
  end

  def test_worker_selectors_support_ranges_and_subsets_through_sixteen
    assert_equal (1..12).to_a, LocalModelEvaluation::RunpodWorkers.parse_selector("1-12")
    assert_equal [9, 10, 11, 12], LocalModelEvaluation::RunpodWorkers.parse_selector("9-12")
    assert_equal [1, 6, 12], LocalModelEvaluation::RunpodWorkers.parse_selector("1,6,12")
    assert_equal [1, 12, 16], LocalModelEvaluation::RunpodWorkers.parse_selector("16,1,12,12")

    error = assert_raises(LocalModelEvaluation::RunpodWorkers::Error) do
      LocalModelEvaluation::RunpodWorkers.parse_selector("1-17")
    end
    assert_includes error.message, "between 1 and 16"
  end
end
