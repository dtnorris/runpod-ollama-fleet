# frozen_string_literal: true

require "minitest/autorun"
require "json"
require_relative "../lib/local_model_evaluation/runpod_client"

class RunpodClientTest < Minitest::Test
  Response = Struct.new(:status, :body, keyword_init: true)

  def test_list_pods_sends_bearer_token_and_parses_response
    seen = nil
    transport = lambda do |request|
      seen = request
      Response.new(status: 200, body: JSON.generate("pods" => []))
    end

    client = LocalModelEvaluation::RunpodClient.new(api_key: "rpa_test", transport:)

    assert_equal [], client.list_pods
    assert_equal "GET", seen.fetch(:method)
    assert_equal "https://api.runpod.io/v2/pods", seen.fetch(:uri).to_s
    assert_equal "Bearer rpa_test", seen.fetch(:headers).fetch("Authorization")
    assert_nil seen.fetch(:body)
  end

  def test_catalog_query_requests_availability_for_one_community_pod
    seen = nil
    transport = lambda do |request|
      seen = request
      Response.new(status: 200, body: JSON.generate("gpus" => []))
    end

    client = LocalModelEvaluation::RunpodClient.new(api_key: "rpa_test", transport:)
    client.list_gpu_types(cloud: "COMMUNITY", count: 1)

    query = URI.decode_www_form(seen.fetch(:uri).query).to_h
    assert_equal "AVAILABILITY", query.fetch("include")
    assert_equal "POD", query.fetch("product")
    assert_equal "1", query.fetch("count")
    assert_equal "COMMUNITY", query.fetch("cloud")
  end

  def test_create_pod_posts_exact_v2_json_body
    seen = nil
    transport = lambda do |request|
      seen = request
      Response.new(status: 201, body: JSON.generate("id" => "pod_123"))
    end

    body = {
      "name" => "af-lme-burst-1",
      "image" => "runpod/pytorch:test",
      "gpu" => { "id" => "NVIDIA A40", "count" => 1 }
    }
    client = LocalModelEvaluation::RunpodClient.new(api_key: "rpa_test", transport:)

    assert_equal "pod_123", client.create_pod(body).fetch("id")
    assert_equal "POST", seen.fetch(:method)
    assert_equal "application/json", seen.fetch(:headers).fetch("Content-Type")
    assert_equal body, JSON.parse(seen.fetch(:body))
  end

  def test_create_pod_with_provider_deadline_uses_graphql_terminate_after
    seen = nil
    transport = lambda do |request|
      seen = request
      Response.new(
        status: 200,
        body: JSON.generate("data" => { "podFindAndDeployOnDemand" => { "id" => "pod_lease" } })
      )
    end

    terminate_after = "2026-10-05T14:35:00Z"
    body = {
      "name" => "af-lme-burst-1",
      "image" => "runpod/pytorch:test",
      "disk" => 30,
      "ports" => ["22/tcp"],
      "env" => { "PUBLIC_KEY" => "ssh-ed25519 test" },
      "mounts" => {},
      "cloud" => "SECURE",
      "gpu" => { "id" => "NVIDIA A40", "count" => 1 },
      "terminateAfter" => terminate_after
    }
    client = LocalModelEvaluation::RunpodClient.new(api_key: "rpa_test", transport:)

    assert_equal "pod_lease", client.create_pod(body).fetch("id")
    document = JSON.parse(seen.fetch(:body))
    assert_includes document.fetch("query"), "podFindAndDeployOnDemand"
    assert_equal terminate_after, document.dig("variables", "input", "terminateAfter")
  end

  def test_problem_json_raises_typed_error_without_leaking_api_key
    transport = lambda do |_request|
      Response.new(
        status: 403,
        body: JSON.generate("title" => "Forbidden", "status" => 403, "detail" => "access denied")
      )
    end
    client = LocalModelEvaluation::RunpodClient.new(api_key: "rpa_super_secret", transport:)

    error = assert_raises(LocalModelEvaluation::RunpodClient::Error) { client.list_pods }
    assert_equal 403, error.status
    assert_includes error.message, "access denied"
    refute_includes error.message, "rpa_super_secret"
  end

  def test_empty_api_key_is_rejected_before_network_access
    assert_raises(ArgumentError) do
      LocalModelEvaluation::RunpodClient.new(api_key: "")
    end
  end
end
