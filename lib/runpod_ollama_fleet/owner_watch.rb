# frozen_string_literal: true

module RunpodOllamaFleet
  # An inherited pipe is a kernel-owned liveness lease. EOF proves that every
  # writer in the WLO owner process vanished, including on SIGKILL/crash. RPOF
  # then interrupts its dispatcher, whose existing cleanup terminates active
  # workload process groups and persists interrupted evidence.
  class OwnerWatch
    class Error < StandardError; end

    def initialize(fd:, on_loss: nil)
      @fd = Integer(fd)
      raise Error, "owner fd must be at least 3" if @fd < 3

      @on_loss = on_loss || -> { Thread.main.raise(Interrupt, "WLO owner channel closed") }
    rescue ArgumentError, TypeError
      raise Error, "owner fd must be an integer"
    end

    def start
      # The caller owns the inherited descriptor. A second autoclosing IO
      # would close it later during GC, possibly after its number was reused.
      io = IO.for_fd(@fd, autoclose: false)
      Thread.new do
        io.read
        @on_loss.call
      rescue IOError, SystemCallError => e
        @on_loss.call unless e.is_a?(IOError) && io.closed?
      end
    rescue SystemCallError => e
      raise Error, "cannot monitor WLO owner fd: #{e.message}"
    end
  end
end
