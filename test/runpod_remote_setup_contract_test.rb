# frozen_string_literal: true

require_relative "test_helper"

class RunpodRemoteSetupContractTest < Minitest::Test
  SCRIPT = File.expand_path(
    "../scripts/setup_runpod_ollama_worker.sh",
    __dir__
  )

  def test_ollama_run_never_inherits_streamed_setup_stdin
    run_lines = File.readlines(SCRIPT).grep(/ollama run/)

    refute_empty run_lines, "expected at least one ollama run invocation"

    run_lines.each do |line|
      assert_includes(
        line,
        "</dev/null",
        "ollama run must detach stdin because the remote setup script itself is streamed over stdin"
      )
    end
  end
end
