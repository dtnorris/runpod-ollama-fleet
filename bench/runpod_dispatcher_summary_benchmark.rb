# frozen_string_literal: true

require_relative "../test/test_helper"
require "minitest/benchmark"
require "stringio"

class RunpodDispatcherSummaryBenchmark < Minitest::Benchmark
  RANGE = [1_000, 2_000, 4_000, 8_000, 16_000].freeze
  REPETITIONS = 5
  MIN_POWER_FIT = 0.90
  MAX_GROWTH_EXPONENT = 1.35
  STARTED_AT = Time.utc(2026, 9, 26, 12, 0, 0)

  def self.bench_range
    RANGE
  end

  def setup
    @dispatcher = LocalModelEvaluation::RunpodDispatcher.new(
      fleet_state: Object.new,
      output_dir: Dir.tmpdir,
      repo_root: Dir.pwd,
      out: StringIO.new,
      endpoint_checker: Object.new,
      command_runner: Object.new,
      wall_clock: -> { STARTED_AT }
    )
    @workers = (1..16).map { |index| { "index" => index } }
    @cases = self.class.bench_range.to_h do |count|
      jobs = (1..count).map do |index|
        { "job_id" => format("job-%05d", index) }
      end
      results = jobs.reverse_each.with_index.map do |job, index|
        {
          "job_id" => job.fetch("job_id"),
          "worker_index" => (index % @workers.length) + 1,
          "status" => "completed",
          "exit_status" => 0
        }
      end
      [count, { jobs:, results: }]
    end
  end

  def bench_summary_integrity_growth
    validation = proc do |range, times|
      _coefficient, exponent, fit = fit_power(range, times)
      assert_operator fit, :>=, MIN_POWER_FIT,
                      "dispatcher summary benchmark power fit is too noisy"
      assert_operator exponent, :<=, MAX_GROWTH_EXPONENT,
                      "dispatcher summary growth exponent #{exponent.round(3)} exceeds #{MAX_GROWTH_EXPONENT}"
    end

    assert_performance(validation) do |count|
      data = @cases.fetch(count)
      REPETITIONS.times do
        @dispatcher.instance_variable_set(:@results, data.fetch(:results))
        summary = @dispatcher.send(
          :build_summary,
          fleet_id: "benchmark-fleet",
          jobs: data.fetch(:jobs),
          workers: @workers,
          started_at: STARTED_AT
        )
        raise "benchmark summary integrity failed" unless summary.fetch("completed_count") == count
      end
    end
  end
end
