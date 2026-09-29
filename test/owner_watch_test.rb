# frozen_string_literal: true

require_relative "test_helper"
require "runpod_ollama_fleet/owner_watch"

class OwnerWatchTest < Minitest::Test
  def test_pipe_eof_reports_owner_loss
    reader, writer = IO.pipe
    losses = Queue.new
    watch = RunpodOllamaFleet::OwnerWatch.new(fd: reader.fileno, on_loss: -> { losses << :lost })
    thread = watch.start

    writer.close

    assert_equal :lost, losses.pop
    thread.join
    thread = nil
    GC.start
    assert reader.stat.pipe?, "the owner watch must not close the caller's descriptor"
  ensure
    reader&.close unless reader&.closed?
    writer&.close unless writer&.closed?
  end

  def test_invalid_owner_fd_is_rejected
    assert_raises(RunpodOllamaFleet::OwnerWatch::Error) do
      RunpodOllamaFleet::OwnerWatch.new(fd: 2)
    end
  end
end
