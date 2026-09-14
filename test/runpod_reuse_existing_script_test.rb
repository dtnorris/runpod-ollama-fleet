# frozen_string_literal: true

require_relative "test_helper"
require "fileutils"
require "open3"
require "tmpdir"

class RunpodReuseExistingScriptTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)
  SCRIPT = File.join(ROOT, "scripts", "setup_runpod_ollama_worker.sh")
  MODEL = "gemma4:26b"
  DIGEST = "a" * 64
  OTHER_DIGEST = "b" * 64

  def setup
    @bash = bash4_or_newer
    skip "remote worker script integration requires Bash 4+" unless @bash

    @tmp = Dir.mktmpdir("runpod-reuse-existing-")
    @bin = File.join(@tmp, "bin")
    @shared = File.join(@tmp, "shared-models")
    @staging = File.join(@tmp, "staging-models")
    @state = File.join(@tmp, "state")
    @ollama_log = File.join(@tmp, "ollama.log")
    @rsync_log = File.join(@tmp, "rsync.log")
    FileUtils.mkdir_p(@bin)
    install_fakes
  end

  def teardown
    FileUtils.remove_entry(@tmp) if @tmp && File.exist?(@tmp)
  end

  def test_reuse_existing_restarts_and_verifies_without_pull_stage_or_rsync
    FileUtils.mkdir_p(@shared)
    File.write(File.join(@shared, "cache-marker"), "preserve me\n")

    out, err, status = run_script(digest: DIGEST)

    assert status.success?, out + err
    assert_includes out, "Reuse existing workspace model cache without pull or copy"
    assert_includes out, "Skipping staging, ollama pull, and rsync"
    commands = File.file?(@ollama_log) ? File.read(@ollama_log) : ""
    assert_match(/(?:\A|\n)serve\b/, commands)
    assert_match(/(?:\A|\n)run\b/, commands)
    refute_match(/(?:\A|\n)pull\b/, commands)
    refute File.exist?(@rsync_log), "rsync must not run in --reuse-existing mode"
    refute File.exist?(@staging), "staging store must not be created in --reuse-existing mode"
    assert_equal "preserve me\n", File.read(File.join(@shared, "cache-marker"))

    summary = Dir.glob(File.join(@state, "*", "worker-summary.txt")).fetch(0)
    assert_includes File.read(summary), "reuse_existing=1"
  end

  def test_reuse_existing_fails_closed_when_shared_cache_is_missing
    out, err, status = run_script(digest: DIGEST)

    refute status.success?, out + err
    assert_includes out + err, "shared Ollama cache is missing"
    assert_includes out + err, "run normal bootstrap to populate it"
    commands = File.file?(@ollama_log) ? File.read(@ollama_log) : ""
    refute_match(/(?:\A|\n)pull\b/, commands)
    refute File.exist?(@rsync_log)
  end

  def test_reuse_existing_fails_on_cached_digest_mismatch_without_fallback_pull
    FileUtils.mkdir_p(@shared)
    File.write(File.join(@shared, "cache-marker"), "preserve me\n")

    out, err, status = run_script(digest: OTHER_DIGEST)

    refute status.success?, out + err
    assert_includes out + err, "final digest mismatch for #{MODEL}"
    commands = File.file?(@ollama_log) ? File.read(@ollama_log) : ""
    refute_match(/(?:\A|\n)pull\b/, commands)
    refute File.exist?(@rsync_log)
  end

  private

  def run_script(digest:)
    env = {
      "PATH" => [@bin, ENV.fetch("PATH")].join(File::PATH_SEPARATOR),
      "FAKE_DIGEST" => digest,
      "FAKE_MODEL" => MODEL,
      "FAKE_OLLAMA_LOG" => @ollama_log,
      "FAKE_RSYNC_LOG" => @rsync_log
    }
    Open3.capture3(
      env,
      @bash,
      SCRIPT,
      "--reuse-existing",
      "--model", MODEL,
      "--expect-digest", "#{MODEL}=#{DIGEST}",
      "--expect-gpu", "NVIDIA A40",
      "--min-vram-gb", "40",
      "--shared-dir", @shared,
      "--staging-dir", @staging,
      "--state-root", @state,
      "--context", "131072"
    )
  end

  def bash4_or_newer
    candidates = [ENV["LME_TEST_BASH"], "/opt/homebrew/bin/bash", "/usr/local/bin/bash", "bash"].compact.uniq
    candidates.find do |candidate|
      _out, _err, status = Open3.capture3(candidate, "-c", '(( BASH_VERSINFO[0] >= 4 ))')
      status.success?
    rescue Errno::ENOENT
      false
    end
  end

  def install_fakes
    write_executable("id", <<~'SH')
      #!/usr/bin/env bash
      if [[ "${1:-}" == "-u" ]]; then echo 0; else /usr/bin/id "$@"; fi
    SH

    write_executable("nvidia-smi", <<~'SH')
      #!/usr/bin/env bash
      if [[ "$*" == *"--query-gpu=name,memory.total"* ]]; then
        echo "NVIDIA A40, 46068"
      else
        echo "fake nvidia-smi"
      fi
    SH

    write_executable("curl", <<~'SH')
      #!/usr/bin/env bash
      url="${!#}"
      case "$url" in
        */api/tags)
          printf '{"models":[{"name":"%s","model":"%s","digest":"%s"}]}\n' "$FAKE_MODEL" "$FAKE_MODEL" "$FAKE_DIGEST"
          ;;
        */api/ps)
          printf '{"models":[{"name":"%s","model":"%s","context_length":131072,"size":123,"size_vram":123}]}\n' "$FAKE_MODEL" "$FAKE_MODEL"
          ;;
        */api/version)
          printf '{"version":"test"}\n'
          ;;
        *)
          echo "unexpected curl URL: $url" >&2
          exit 88
          ;;
      esac
    SH

    write_executable("jq", <<~'RUBY')
      #!/usr/bin/env ruby
      require "json"
      args = ARGV.dup
      data = JSON.parse(STDIN.read)
      query = args.last.to_s
      if query == "."
        puts JSON.pretty_generate(data)
        exit 0
      end
      if query.include?(".models[]")
        model_index = args.index("--arg")
        model = model_index ? args.fetch(model_index + 2) : nil
        entry = Array(data["models"]).find { |item| item["name"] == model || item["model"] == model }
        if args.include?("-c")
          puts JSON.generate(entry) if entry
        elsif query.include?(".digest")
          puts entry["digest"] if entry
        end
        exit 0
      end
      key = query.sub(/\A\./, "")
      value = data[key]
      puts value unless value.nil?
    RUBY

    write_executable("ollama", <<~'SH')
      #!/usr/bin/env bash
      printf '%s\n' "$*" >> "$FAKE_OLLAMA_LOG"
      case "${1:-}" in
        --version) echo "ollama version test" ;;
        serve) exit 0 ;;
        list) echo "NAME ID SIZE" ;;
        run) echo "warmed ${2:-}" ;;
        ps) echo "NAME SIZE PROCESSOR CONTEXT" ;;
        stop) exit 0 ;;
        pull) echo "ollama pull must not run in --reuse-existing mode" >&2; exit 91 ;;
        *) exit 0 ;;
      esac
    SH

    write_executable("rsync", <<~'SH')
      #!/usr/bin/env bash
      echo "called" > "$FAKE_RSYNC_LOG"
      echo "rsync must not run in --reuse-existing mode" >&2
      exit 92
    SH

    write_executable("apt-get", <<~'SH')
      #!/usr/bin/env bash
      echo "apt-get must not run in this test" >&2
      exit 93
    SH

    write_executable("pkill", <<~'SH')
      #!/usr/bin/env bash
      exit 0
    SH
  end

  def write_executable(name, body)
    path = File.join(@bin, name)
    File.write(path, body)
    FileUtils.chmod(0o755, path)
  end
end
