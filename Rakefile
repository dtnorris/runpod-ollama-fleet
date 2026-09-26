# frozen_string_literal: true

require "minitest/test_task"

TEST_RUNTIME_WARN_SECONDS = 5.0
TEST_RUNTIME_FAIL_SECONDS = 5.5

Minitest::TestTask.create do |t|
  t.test_globs = ["test/**/*_test.rb"]
  t.test_prelude = %(require "simplecov"; SimpleCov.start) if ENV["COVERAGE"]
end

desc "Check structural Minitest test quality"
task "test:lint" do
  sh "bundle", "exec", "rubocop", "--config", ".rubocop.yml", "test"
end

desc "Run the ordinary test suite and enforce its runtime ceiling"
task "test:runtime" do
  started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  passed = system("bundle", "exec", "rake", "test")
  elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at

  abort "Test suite failed before runtime could be accepted" unless passed

  if elapsed >= TEST_RUNTIME_FAIL_SECONDS
    abort format(
      "Test suite runtime %.3fs reached hard ceiling %.1fs",
      elapsed,
      TEST_RUNTIME_FAIL_SECONDS
    )
  elsif elapsed >= TEST_RUNTIME_WARN_SECONDS
    warn format(
      "WARNING: test suite runtime %.3fs reached warning threshold %.1fs",
      elapsed,
      TEST_RUNTIME_WARN_SECONDS
    )
  else
    puts format(
      "Test suite runtime %.3fs (warn %.1fs, fail %.1fs)",
      elapsed,
      TEST_RUNTIME_WARN_SECONDS,
      TEST_RUNTIME_FAIL_SECONDS
    )
  end
end

desc "Run tests with line and branch coverage"
task "test:coverage" do
  sh({ "COVERAGE" => "1" }, "bundle", "exec", "rake", "test")
end

desc "Measure current coverage and initialize the committed ratchet baseline"
task "test:coverage:baseline" do
  sh({ "COVERAGE" => "1" }, "bundle", "exec", "rake", "test")
  sh "bundle", "exec", "simplecov", "ratchet", "--init"
end

desc "Run the complete test-suite contract"
task "test:contract" => ["test:runtime", "test:deps", "test:lint", "test:coverage"]

task default: :test
