# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "json"
require_relative "../lib/local_model_evaluation/bootstrap_store"

class BootstrapStoreTest < Minitest::Test
  def test_filesystem_store_persists_current_record_and_log_tail
    Dir.mktmpdir("bootstrap-store-") do |root|
      store = LocalModelEvaluation::BootstrapStore.new
      run_dir = nil

      store.with_lock(root) do
        run_dir = store.start_run(root:, run_id: "run-001")
        store.write_record(path: store.record_path(run_dir), record: {"status" => "running"})
        log = store.open_worker_log(run_dir:, worker_index: 2)
        log.io.write("first\nsecond\n")
        store.close_worker_log(log)

        assert_equal "second\n", store.log_tail(log.path, max_bytes: 7)
      end

      assert_equal "run-001", File.read(File.join(root, "current")).strip
      assert_equal(
        "running",
        JSON.parse(File.read(File.join(run_dir, "bootstrap.json"))).fetch("status")
      )
    end
  end

  def test_filesystem_store_fails_nonblocking_when_lock_is_held
    Dir.mktmpdir("bootstrap-store-lock-") do |root|
      store = LocalModelEvaluation::BootstrapStore.new

      store.with_lock(root) do
        assert_raises(LocalModelEvaluation::BootstrapStore::LockUnavailable) do
          store.with_lock(root) { flunk "nested lock must not be acquired" }
        end
      end
    end
  end
end
