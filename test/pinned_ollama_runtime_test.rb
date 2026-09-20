# frozen_string_literal: true

require "fileutils"
require "minitest/autorun"
require "open3"
require "tmpdir"

class PinnedOllamaRuntimeTest < Minitest::Test
  SCRIPT = File.expand_path("../scripts/setup_runpod_ollama_worker.sh", __dir__)
  VERSION = "v0.34.1"
  SHA256 = "f361dc3992ec07e4ad429f4bb2d10d4663ba2c295f9a9a688c7d52f4ba650034"

  def test_pins_exact_runtime_contract_and_keeps_public_install_only_for_non_shared_mode
    text = source

    assert_includes text, %(PINNED_OLLAMA_RUNTIME_VERSION="#{VERSION}")
    assert_includes text, %(PINNED_OLLAMA_RUNTIME_SHA256="#{SHA256}")
    assert_includes text, %(PINNED_OLLAMA_RUNTIME_ARCHIVE="/workspace-global/runtime-cache/ollama/${PINNED_OLLAMA_RUNTIME_VERSION}/ollama-linux-amd64.tar.zst")
    assert_includes text, '[[ -f "$PINNED_OLLAMA_RUNTIME_ARCHIVE" ]] || die "pinned Ollama runtime archive is missing:'
    assert_includes text, '[[ -r "$PINNED_OLLAMA_RUNTIME_ARCHIVE" ]] || die "pinned Ollama runtime archive is not readable:'
    assert_includes text, "curl -fsSL https://ollama.com/install.sh | sh"

    refute_match(/curl|ollama\.com/, pinned_runtime_body)
  end

  def test_valid_cached_runtime_is_verified_extracted_and_recorded
    result = run_pinned_runtime

    assert result[:status].success?, result[:stderr]
    assert_includes result[:stdout], "Pinned Ollama runtime PASS: #{VERSION} sha256=#{SHA256}"
    assert_includes result[:stdout], "MODE=pinned_shared_archive"
    assert_includes result[:stdout], "VERSION=#{VERSION}"
    assert_includes result[:stdout], "SHA256=#{SHA256}"
    assert_includes result[:stdout], "ARCHIVE=#{result[:archive]}"
    assert result[:extracted], "expected extraction to run"
    assert_equal "Warning: client version is 0.34.1\n", result[:recorded_version]
  end

  def test_checksum_mismatch_fails_closed_before_extraction
    result = run_pinned_runtime(reported_sha256: "0" * 64)

    refute result[:status].success?
    assert_includes result[:stderr], "pinned Ollama runtime checksum mismatch"
    refute result[:extracted], "checksum failure must happen before extraction"
  end

  def test_version_mismatch_fails_closed
    result = run_pinned_runtime(version: "0.34.0")

    refute result[:status].success?
    assert_includes result[:stderr], "pinned Ollama runtime version mismatch: expected 0.34.1, got 0.34.0"
    assert result[:extracted], "version is checked after verified extraction"
  end

  private

  def source
    @source ||= File.read(SCRIPT)
  end

  def pinned_runtime_body
    start_marker = '  info "Installing pinned Ollama runtime from shared cache: $PINNED_OLLAMA_RUNTIME_ARCHIVE"'
    end_marker = "\nelif ! command -v ollama >/dev/null 2>&1; then"
    start = source.index(start_marker) || raise("could not locate pinned shared-runtime branch in #{SCRIPT}")
    finish = source.index(end_marker, start) || raise("could not locate end of pinned shared-runtime branch in #{SCRIPT}")

    source[start...finish]
  end

  def run_pinned_runtime(reported_sha256: SHA256, version: "0.34.1")
    Dir.mktmpdir("rpof-pinned-ollama-runtime-") do |dir|
      archive = File.join(dir, "ollama-linux-amd64.tar.zst")
      local_root = File.join(dir, "local-runtime")
      state_dir = File.join(dir, "state")
      fake_bin = File.join(dir, "fake-bin")
      tar_marker = File.join(dir, "tar-ran")
      recorded_version = File.join(state_dir, "ollama-runtime-version.txt")
      File.binwrite(archive, "fixture archive")
      FileUtils.mkdir_p([state_dir, fake_bin])

      write_executable(File.join(fake_bin, "sha256sum"), <<~'SH')
        #!/usr/bin/env bash
        set -euo pipefail
        printf '%s  %s\n' "$RPOF_TEST_SHA256" "$1"
      SH

      write_executable(File.join(fake_bin, "tar"), <<~'SH')
        #!/usr/bin/env bash
        set -euo pipefail
        while (($#)); do
          if [[ "$1" == "-C" ]]; then
            dest="$2"
            break
          fi
          shift
        done
        [[ -n "${dest:-}" ]]
        : > "$RPOF_TEST_TAR_MARKER"
        mkdir -p "$dest/bin"
        cat > "$dest/bin/ollama" <<'OLLAMA'
        #!/usr/bin/env bash
        printf 'Warning: client version is %s\n' "$RPOF_TEST_OLLAMA_VERSION" >&2
        OLLAMA
        chmod +x "$dest/bin/ollama"
      SH

      env = {
        "PATH" => "#{fake_bin}:#{ENV.fetch('PATH')}",
        "RPOF_TEST_SHA256" => reported_sha256,
        "RPOF_TEST_OLLAMA_VERSION" => version,
        "RPOF_TEST_TAR_MARKER" => tar_marker,
        "PINNED_OLLAMA_RUNTIME_VERSION" => VERSION,
        "PINNED_OLLAMA_RUNTIME_SHA256" => SHA256,
        "PINNED_OLLAMA_RUNTIME_ARCHIVE" => archive,
        "PINNED_OLLAMA_RUNTIME_LOCAL_ROOT" => local_root,
        "STATE_DIR" => state_dir
      }

      driver = <<~BASH
        set -euo pipefail
        OLLAMA_RUNTIME_MODE=public_or_existing
        OLLAMA_RUNTIME_VERSION=""
        OLLAMA_RUNTIME_SHA256=""
        OLLAMA_RUNTIME_ARCHIVE=""
        info() { printf '%s\n' "$*"; }
        die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
        #{pinned_runtime_body}
        printf 'MODE=%s\nVERSION=%s\nSHA256=%s\nARCHIVE=%s\n' \
          "$OLLAMA_RUNTIME_MODE" "$OLLAMA_RUNTIME_VERSION" "$OLLAMA_RUNTIME_SHA256" "$OLLAMA_RUNTIME_ARCHIVE"
      BASH

      stdout, stderr, status = Open3.capture3(env, "bash", "-c", driver)
      {
        stdout:,
        stderr:,
        status:,
        archive:,
        extracted: File.exist?(tar_marker),
        recorded_version: File.exist?(recorded_version) ? File.read(recorded_version) : nil
      }
    end
  end

  def write_executable(path, content)
    File.write(path, content)
    FileUtils.chmod(0o755, path)
  end
end
