# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "fileutils"
require "json"
require_relative "../lib/local_model_evaluation/runpod_runtime_alias"

class RunpodRuntimeAliasProvenanceTest < Minitest::Test
  DIGEST = "d" * 64
  Response = Struct.new(:status, :body, keyword_init: true)

  class FakeState
    def initialize(root)
      @root = root
    end

    def current
      {
        "fleet_id" => "fleet-1",
        "status" => "active",
        "workers" => [{
          "index" => 1,
          "pod_id" => "pod-1",
          "status" => "active",
          "local_ollama_url" => "http://127.0.0.1:11441"
        }]
      }
    end

    def artifact_dir(fleet_id, kind)
      File.join(@root, fleet_id, kind)
    end
  end

  def test_runtime_alias_proof_is_persisted_and_bound_to_current_pod
    Dir.mktmpdir("runtime-alias-provenance-") do |root|
      tags = { "pull/model" => DIGEST }
      transport = lambda do |method:, uri:, body:|
        case [method, uri.path]
        when ["GET", "/api/tags"]
          Response.new(
            status: 200,
            body: JSON.generate("models" => tags.map { |name, digest| { "name" => name, "digest" => digest } })
          )
        when ["POST", "/api/copy"]
          payload = JSON.parse(body)
          tags[payload.fetch("destination")] = tags.fetch(payload.fetch("source"))
          Response.new(status: 200, body: "{}")
        when ["POST", "/api/generate"]
          Response.new(status: 200, body: JSON.generate("done" => true))
        when ["GET", "/api/ps"]
          Response.new(
            status: 200,
            body: JSON.generate(
              "models" => [{
                "name" => "runtime:model",
                "context_length" => 131_072,
                "size" => 20_000,
                "size_vram" => 20_000
              }]
            )
          )
        else
          raise "unexpected request #{method} #{uri}"
        end
      end

      state = FakeState.new(root)
      LocalModelEvaluation::RunpodRuntimeAlias.new(
        fleet_state: state,
        transport:
      ).ensure_alias(
        worker_indices: [1],
        source_model: "pull/model",
        runtime_model: "runtime:model",
        expected_digest: DIGEST,
        context: 131_072
      )

      path = File.join(
        root,
        "fleet-1",
        "runtime-alias",
        LocalModelEvaluation::RunpodRuntimeAlias::EVIDENCE_FILE
      )
      document = JSON.parse(File.read(path))
      row = document.fetch("workers").fetch(0)
      assert_equal "fleet-1", document.fetch("fleet_id")
      assert_equal 1, row.fetch("worker_index")
      assert_equal "pod-1", row.fetch("pod_id")
      assert_equal "runtime:model", row.fetch("runtime_model")
      assert_equal DIGEST, row.fetch("digest")
      assert_equal 131_072, row.fetch("context_length")
      assert_equal true, row.fetch("fully_gpu_resident")
    end
  end
end
