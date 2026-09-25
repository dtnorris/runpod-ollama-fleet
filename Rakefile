# frozen_string_literal: true

require "minitest/test_task"

Minitest::TestTask.create do |t|
  t.test_globs = ["test/**/*_test.rb"]
end

desc "Check structural Minitest test quality"
task "test:lint" do
  sh "bundle", "exec", "rubocop", "--config", ".rubocop.yml", "test"
end

task default: :test
