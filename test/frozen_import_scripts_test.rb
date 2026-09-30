# frozen_string_literal: true

require_relative "test_helper"
require "open3"

class FrozenImportScriptsTest < Minitest::Test
  REPO_ROOT = File.expand_path("..", __dir__)
  HISTORICAL_CONTENT = <<~TEXT.freeze
    AFIO_RPOF_INTERFACE_v0.1
    LocalModelEvaluation
    LME_SOURCE_REPO
    lme_runpod_compatibility
  TEXT

  def setup
    @tmp = Dir.mktmpdir("frozen-import-scripts-")
    @rpof = File.join(@tmp, "runpod-ollama-fleet")
    @default_source = File.join(@tmp, "af-workloads")
    @override_source = File.join(@tmp, "historical-source")
    @bin = File.join(@tmp, "bin")
    @git_log = File.join(@tmp, "git.log")

    FileUtils.mkdir_p([File.join(@rpof, "script"), File.join(@rpof, "bin"), @bin])
    %w[import-frozen-lme verify-frozen-import].each do |name|
      FileUtils.cp(File.join(REPO_ROOT, "script", name), File.join(@rpof, "script", name))
    end
    File.write(File.join(@rpof, "SOURCE_IMPORT_MANIFEST.txt"), "historical/source.txt\timported/source.txt\n")
    File.write(File.join(@rpof, "bin", "rpof"), "#!/usr/bin/env bash\n")
    write_fake_git
  end

  def teardown
    FileUtils.remove_entry(@tmp) if @tmp && File.exist?(@tmp)
  end

  def test_default_source_is_af_workloads_for_import_and_verification
    make_checkout(@default_source)

    import_stdout, import_stderr, import_status = run_script("import-frozen-lme")
    assert import_status.success?, import_stderr
    assert_includes import_stdout, "Imported 1 frozen provider files"
    assert_equal HISTORICAL_CONTENT, File.read(File.join(@rpof, "imported", "source.txt"))

    verify_stdout, verify_stderr, verify_status = run_script("verify-frozen-import")
    assert verify_status.success?, verify_stderr
    assert_includes verify_stdout, "Checked 1 imported files; failures=0"
    assert_equal(
      { "import-frozen-lme" => @default_source, "verify-frozen-import" => @default_source },
      source_roots_by_script
    )
  end

  def test_explicit_source_override_wins_for_both_scripts
    make_checkout(@default_source)
    make_checkout(@override_source)

    _stdout, stderr, status = run_script("import-frozen-lme", "LME_SOURCE_REPO" => @override_source)
    assert status.success?, stderr
    _stdout, stderr, status = run_script("verify-frozen-import", "LME_SOURCE_REPO" => @override_source)
    assert status.success?, stderr

    assert_equal(
      { "import-frozen-lme" => @override_source, "verify-frozen-import" => @override_source },
      source_roots_by_script
    )
  end

  def test_missing_default_source_fails_clearly_for_both_scripts
    %w[import-frozen-lme verify-frozen-import].each do |name|
      _stdout, stderr, status = run_script(name)

      refute status.success?
      assert_equal 2, status.exitstatus
      assert_includes stderr, "ERROR: local-model-eval Git checkout not found: #{@default_source}"
    end
  end

  private

  def make_checkout(path)
    FileUtils.mkdir_p(File.join(path, ".git"))
  end

  def run_script(name, extra_env = {})
    env = {
      "PATH" => "#{@bin}:#{ENV.fetch('PATH')}",
      "FAKE_GIT_LOG" => @git_log,
      "FAKE_GIT_CONTEXT" => name,
      "HISTORICAL_CONTENT" => HISTORICAL_CONTENT
    }.merge(extra_env)
    Open3.capture3(env, File.join(@rpof, "script", name))
  end

  def source_roots_by_script
    File.readlines(@git_log, chomp: true).to_h do |line|
      fields = line.split("\t")
      [fields[0], fields[1]]
    end
  end

  def write_fake_git
    path = File.join(@bin, "git")
    File.write(path, <<~'SH')
      #!/usr/bin/env bash
      set -euo pipefail
      printf '%s\t%s\n' "$FAKE_GIT_CONTEXT" "$2" >> "$FAKE_GIT_LOG"
      shift 2
      case "$1" in
        cat-file)
          exit 0
          ;;
        show)
          printf '%s' "$HISTORICAL_CONTENT"
          ;;
        *)
          printf 'unexpected fake git command: %s\n' "$*" >&2
          exit 64
          ;;
      esac
    SH
    FileUtils.chmod(0o755, path)
  end
end
