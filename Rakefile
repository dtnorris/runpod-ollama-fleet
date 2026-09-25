# frozen_string_literal: true

require "minitest/test_task"

Minitest::TestTask.create do |t|
  t.test_globs = ["test/**/*_test.rb"]
  t.test_prelude = %(require "simplecov"; SimpleCov.start) if ENV["COVERAGE"]
end

desc "Check structural Minitest test quality"
task "test:lint" do
  sh "bundle", "exec", "rubocop", "--config", ".rubocop.yml", "test"
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

task default: :test
