# frozen_string_literal: true

require "fileutils"
require "json"
require "open3"
require "tmpdir"
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

  def test_shared_store_copy_emits_real_cumulative_progress_and_keeps_atomic_completion_metrics
    Dir.mktmpdir("rpof-shared-copy-") do |dir|
      source = File.join(dir, "source")
      destination = File.join(dir, "destination")
      metrics = File.join(dir, "metrics.tsv")
      model = "fixture:latest"
      digests = ["sha256:#{'a' * 64}", "sha256:#{'b' * 64}"]
      manifest_rel = File.join("manifests", "registry.ollama.ai", "library", "fixture", "latest")
      source_manifest = File.join(source, manifest_rel)
      FileUtils.mkdir_p(File.dirname(source_manifest))
      FileUtils.mkdir_p(File.join(source, "blobs"))
      File.write(
        source_manifest,
        JSON.generate("config" => {"digest" => digests[0]}, "layers" => [{"digest" => digests[1]}])
      )

      sizes = [20 * 1024 * 1024, 4 * 1024 * 1024]
      digests.zip(sizes).each do |digest, size|
        blob = File.join(source, "blobs", digest.sub(":", "-"))
        File.open(blob, "wb") { |handle| handle.truncate(size) }
      end
      total = sizes.sum

      stdout, stderr, status = Open3.capture3(
        "python3", "-", source, destination, model, metrics,
        stdin_data: shared_copy_python
      )

      assert status.success?, stdout + stderr
      progress = stdout.lines.filter_map do |line|
        fields = line.strip.split("\t")
        next unless fields[0] == "LME_COPY_PROGRESS"

        {copied: Integer(fields[2]), total: Integer(fields[3]), percent: Float(fields[4])}
      end
      assert_operator progress.length, :>=, 3
      assert_equal 0, progress.first.fetch(:copied)
      assert_equal total, progress.last.fetch(:copied)
      assert_equal 100.0, progress.last.fetch(:percent)
      assert progress.any? { |entry| entry.fetch(:copied).between?(1, total - 1) }
      assert_equal progress.map { |entry| entry.fetch(:copied) }.sort, progress.map { |entry| entry.fetch(:copied) }

      digests.zip(sizes).each do |digest, size|
        destination_blob = File.join(destination, "blobs", digest.sub(":", "-"))
        assert_equal size, File.size(destination_blob)
        refute File.exist?("#{destination_blob}.partial")
      end
      assert_equal File.read(source_manifest), File.read(File.join(destination, manifest_rel))
      assert_match(/^LME_SHARED_COPY\t#{Regexp.escape(model)}\t#{total}\t/, stdout)
      assert_includes File.read(metrics), "#{model}\t#{total}\t"

      python = shared_copy_python
      assert_includes python, 'temporary_blob = destination_blob + ".partial"'
      assert_includes python, "os.replace(temporary_blob, destination_blob)"
      refute_includes python, "shutil.copyfile(source_blob, temporary_blob)"
    end
  end

  private

  def shared_copy_python
    source = File.read(SCRIPT)
    marker = 'shared-copy-${safe}.tsv" <<\'PY\''
    start = source.index(marker) || raise("could not locate shared-store Python copy block")
    body_start = source.index("\n", start) + 1
    body_end = source.index("\nPY\n", body_start) || raise("could not find end of shared-store Python copy block")
    source[body_start...body_end]
  end
end
