# frozen_string_literal: true

require "minitest/autorun"
require "json"
require_relative "../lib/local_model_evaluation/runpod_runtime_alias"

class RunpodRuntimeAliasTest < Minitest::Test
  DIGEST = "d" * 64

  class FakeState
    def current
      {
        "status" => "active",
        "workers" => [
          { "index" => 1, "status" => "active", "local_ollama_url" => "http://127.0.0.1:11441" }
        ]
      }
    end
  end

  Response = Struct.new(:status, :body, keyword_init: true)

  def test_copies_runtime_alias_then_warms_and_proves_residency
    tags = {
      "pull/model" => DIGEST
    }
    calls = []
    transport = lambda do |method:, uri:, body:|
      calls << [method, uri.path, body]
      case [method, uri.path]
      when ["GET", "/api/tags"]
        models = tags.map { |name, digest| { "name" => name, "digest" => digest } }
        Response.new(status: 200, body: JSON.generate("models" => models))
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

    evidence = LocalModelEvaluation::RunpodRuntimeAlias.new(
      fleet_state: FakeState.new,
      transport:
    ).ensure_alias(
      worker_indices: [1],
      source_model: "pull/model",
      runtime_model: "runtime:model",
      expected_digest: DIGEST,
      context: 131_072
    )

    assert_equal 1, evidence.length
    assert_equal "runtime:model", evidence.first.fetch("runtime_model")
    assert_equal DIGEST, evidence.first.fetch("digest")
    assert_equal true, evidence.first.fetch("fully_gpu_resident")
    assert calls.any? { |method, path, _| method == "POST" && path == "/api/copy" }
    assert calls.any? { |method, path, _| method == "POST" && path == "/api/generate" }
  end

  def test_refuses_to_overwrite_runtime_alias_with_wrong_existing_digest
    wrong = "e" * 64
    transport = lambda do |method:, uri:, body:|
      raise "unexpected mutation" if method == "POST"
      if uri.path == "/api/tags"
        Response.new(
          status: 200,
          body: JSON.generate(
            "models" => [
              { "name" => "pull/model", "digest" => DIGEST },
              { "name" => "runtime:model", "digest" => wrong }
            ]
          )
        )
      else
        raise "unexpected request"
      end
    end

    error = assert_raises(LocalModelEvaluation::RunpodRuntimeAlias::Error) do
      LocalModelEvaluation::RunpodRuntimeAlias.new(
        fleet_state: FakeState.new,
        transport:
      ).ensure_alias(
        worker_indices: [1],
        source_model: "pull/model",
        runtime_model: "runtime:model",
        expected_digest: DIGEST,
        context: 131_072
      )
    end
    assert_includes error.message, "unexpected digest"
  end
end
