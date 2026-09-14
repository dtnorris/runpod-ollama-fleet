# frozen_string_literal: true

require "fileutils"
require "json"

module LocalModelEvaluation
  class BootstrapStore
    class LockUnavailable < StandardError; end

    LogTarget = Struct.new(:path, :io, keyword_init: true)

    def with_lock(root)
      FileUtils.mkdir_p(root)
      lock_path = File.join(root, ".lock")
      File.open(lock_path, File::RDWR | File::CREAT, 0o600) do |lock|
        raise LockUnavailable unless lock.flock(File::LOCK_EX | File::LOCK_NB)

        yield
      end
    end

    def start_run(root:, run_id:)
      run_dir = File.join(root, run_id)
      FileUtils.mkdir_p(run_dir)
      atomic_write(File.join(root, "current"), "#{run_id}\n")
      run_dir
    end

    def record_path(run_dir)
      File.join(run_dir, "bootstrap.json")
    end

    def write_record(path:, record:)
      atomic_write(path, JSON.pretty_generate(record) + "\n")
    end

    def open_worker_log(run_dir:, worker_index:)
      path = File.join(run_dir, "burst_#{worker_index}.log")
      LogTarget.new(path:, io: File.open(path, "w"))
    end

    def close_worker_log(target)
      target&.io&.close unless target&.io&.closed?
    end

    def log_tail(path, max_bytes:)
      return "" unless File.file?(path)

      File.open(path, "rb") do |file|
        file.seek(-[file.size, max_bytes].min, IO::SEEK_END)
        file.read.to_s
      end
    rescue Errno::ENOENT
      ""
    end

    private

    def atomic_write(path, content)
      FileUtils.mkdir_p(File.dirname(path))
      tmp = "#{path}.tmp.#{$$}.#{Thread.current.object_id}"
      File.write(tmp, content)
      File.rename(tmp, path)
    ensure
      File.delete(tmp) if defined?(tmp) && tmp && File.exist?(tmp)
    end
  end
end
