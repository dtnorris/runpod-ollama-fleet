# frozen_string_literal: true

require "minitest/test_task"
require "open3"

TEST_RUNTIME_WARN_SECONDS = 5.0
TEST_RUNTIME_FAIL_SECONDS = 5.5
TEST_HEALTH_RESULTS = {}
TEST_HEALTH_ERRORS = {}
TEST_HEALTH_MUTEX = Mutex.new

Minitest::TestTask.create do |t|
  t.test_globs = ["test/**/*_test.rb"]
  t.test_prelude = %(require "simplecov"; SimpleCov.start) if ENV["COVERAGE"]
end

desc "Check structural Minitest test quality"
task "test:lint" do
  sh "bundle", "exec", "rubocop", "--config", ".rubocop.yml", "test"
end

desc "Run the functional suite with coverage and enforce its runtime ceiling"
task "test:coverage" do
  started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  status = nil
  Open3.popen2e({ "COVERAGE" => "1" }, "bundle", "exec", "rake", "test") do |_stdin, stream, wait_thread|
    current_line = +""
    suppress_next_blank = false

    begin
      loop do
        chunk = stream.readpartial(4096)
        visible = +""

        chunk.each_char do |char|
          if suppress_next_blank
            if char == "\n"
              suppress_next_blank = false
              next
            end
            suppress_next_blank = false
          end

          visible << char

          if char == "\n"
            suppress_next_blank = current_line.start_with?("Finished in ")
            current_line.clear
          else
            current_line << char
          end
        end

        print visible
        $stdout.flush
      end
    rescue EOFError
      # Child process closed its output stream.
    end

    status = wait_thread.value
  end

  elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at

  abort "Coverage test suite failed before runtime could be accepted" unless status.success?

  if elapsed >= TEST_RUNTIME_FAIL_SECONDS
    failure = format(
      "FAILURE: coverage test suite runtime %.3fs reached hard ceiling %.1fs",
      elapsed,
      TEST_RUNTIME_FAIL_SECONDS
    )

    if (Rake.application.top_level_tasks & %w[default test:contract]).empty?
      abort failure
    else
      TEST_HEALTH_RESULTS[:runtime_failure] = failure
    end
  elsif elapsed >= TEST_RUNTIME_WARN_SECONDS
    warning = format(
      "WARNING: coverage test suite runtime %.3fs reached warning threshold %.1fs",
      elapsed,
      TEST_RUNTIME_WARN_SECONDS
    )

    if (Rake.application.top_level_tasks & %w[default test:contract]).empty?
      warn warning
    else
      TEST_HEALTH_RESULTS[:runtime_warning] = warning
    end
  else
    puts format(
      "Coverage test suite runtime %.3fs (warn %.1fs, fail %.1fs)",
      elapsed,
      TEST_RUNTIME_WARN_SECONDS,
      TEST_RUNTIME_FAIL_SECONDS
    )
  end
end

desc "Measure current coverage and initialize the committed ratchet baseline"
task "test:coverage:baseline" do
  sh({ "COVERAGE" => "1" }, "bundle", "exec", "rake", "test")
  sh "bundle", "exec", "simplecov", "ratchet", "--init"
end

task "test:lint:quiet" do
  stdout, stderr, status = Open3.capture3(
    "bundle", "exec", "rubocop", "--config", ".rubocop.yml", "test"
  )

  if status.success?
    match = stdout.match(/(\d+) files inspected, no offenses detected/)
    if match
      TEST_HEALTH_MUTEX.synchronize do
        TEST_HEALTH_RESULTS[:lint] =
          "test:lint: #{match[1]} files inspected, no offenses detected"
      end
    else
      TEST_HEALTH_MUTEX.synchronize do
        TEST_HEALTH_ERRORS[:lint] =
          "test:lint succeeded but its summary could not be parsed\n#{stdout}"
      end
    end
  else
    TEST_HEALTH_MUTEX.synchronize do
      TEST_HEALTH_ERRORS[:lint] = [stdout, stderr].reject(&:empty?).join
    end
  end
end

task "test:deps:quiet" do
  stdout, stderr, status = Open3.capture3("bundle", "exec", "rake", "test:deps")

  TEST_HEALTH_MUTEX.synchronize do
    if status.success?
      TEST_HEALTH_RESULTS[:deps] = "test:deps: no broken dependencies found"
    else
      TEST_HEALTH_ERRORS[:deps] = [stdout, stderr].reject(&:empty?).join
    end
  end
end

desc "Run independent post-suite health checks in parallel"
multitask "test:health:parallel" => ["test:deps:quiet", "test:lint:quiet"]

task "test:health" do
  label = "Running secondary test-health checks"
  spinner = nil

  if $stdout.tty?
    frames = %w[⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏]
    spinner = Thread.new do
      index = 0
      loop do
        print "\r#{label} #{frames[index % frames.length]}"
        $stdout.flush
        sleep 0.08
        index += 1
      end
    end
  else
    puts "#{label}..."
  end

  begin
    Rake::Task["test:health:parallel"].invoke
  ensure
    if spinner
      spinner.kill
      spinner.join
      print "\r#{" " * (label.length + 2)}\r"
      $stdout.flush
    end
  end

  unless TEST_HEALTH_ERRORS.empty?
    TEST_HEALTH_ERRORS.each_value { |output| warn output unless output.empty? }
    abort "secondary test-health checks failed"
  end
end

desc "Run the complete test-suite contract"
task "test:contract" => ["test:coverage", "test:health"] do
  puts TEST_HEALTH_RESULTS.fetch(:lint)
  puts TEST_HEALTH_RESULTS.fetch(:deps)

  if (failure = TEST_HEALTH_RESULTS[:runtime_failure])
    puts
    puts failure
    exit(false)
  elsif (warning = TEST_HEALTH_RESULTS[:runtime_warning])
    puts
    puts warning
  end
  puts
end

task default: "test:contract"
