# frozen_string_literal: true

require "minitest/autorun"
require "json"
require_relative "../lib/runpod_ollama_fleet/capacity_campaign"

class CapacityCampaignTest < Minitest::Test
  FIXTURE = File.expand_path("fixtures/rpof-capacity-campaign-v0.1.json", __dir__)
  HARDWARE = File.expand_path("../config/execution_pool_hardware.yml", __dir__)
  CAMPAIGN_SHA256 = "3bde2853ec51980537953ceb6e85e91314041397328c433bde20a7889b58c575"
  HARDWARE_SHA256 = "2b238e97b9de66a335fad4f40b69eb178ddee2157bab7f762a2b8e8e73502d50"
  IDENTITY_SHA256 = "e5bfc39c8e3275eef65d17104887fef0d11cb1c1321b04744a31404dad9a8442"

  def test_valid_multi_model_campaign_normalizes_and_binds_identity
    campaign = load_campaign(fixture)

    assert_equal "production-batch-039", campaign.campaign_id
    assert_equal 6, campaign.max_workers
    assert_equal 6.0, campaign.max_hourly_rate_usd
    assert_equal %w[gemma gptoss qwen27 qwen35], campaign.profiles.map { |row| row.fetch("profile_id") }
    assert_equal CAMPAIGN_SHA256, campaign.sha256
    assert_equal HARDWARE_SHA256, campaign.hardware_qualification_sha256
    assert_equal IDENTITY_SHA256, campaign.identity_sha256
    assert_equal campaign.sha256, campaign.identity.fetch("campaign_sha256")
    assert campaign.normalized_document.frozen?
    assert campaign.profiles.all?(&:frozen?)
    assert campaign.hardware_bindings.frozen?
    assert campaign.frozen?
  end

  def test_four_model_example_has_six_desired_and_maximum_workers
    campaign = load_campaign(fixture)

    assert_equal 4, campaign.profiles.length
    assert_equal 6, campaign.profiles.sum { |row| row.fetch("desired_workers") }
    assert_equal 6, campaign.profiles.sum { |row| row.fetch("max_workers") }
    assert_equal({ "qwen35" => 3, "qwen27" => 1, "gemma" => 1, "gptoss" => 1 },
                 campaign.profiles.to_h { |row| [row.fetch("profile_id"), row.fetch("desired_workers")] })
  end

  def test_rejects_duplicate_profile_ids
    document = fixture
    document.fetch("profiles")[1]["profile_id"] = "qwen35"

    assert_error_includes("profile_id values must be unique") { load_campaign(document) }
  end

  def test_rejects_invalid_worker_count_ordering
    %w[min_workers desired_workers max_workers].each do |field|
      document = fixture
      profile = document.fetch("profiles").first
      profile[field] = 0
      assert_error_includes("positive integer") { load_campaign(document) }
    end

    document = fixture
    document.fetch("profiles").first.merge!("min_workers" => 3, "desired_workers" => 2, "max_workers" => 4)
    assert_error_includes("min_workers <= desired_workers <= max_workers") { load_campaign(document) }

    document = fixture
    document.fetch("profiles").first.merge!("min_workers" => 1, "desired_workers" => 4, "max_workers" => 3)
    assert_error_includes("min_workers <= desired_workers <= max_workers") { load_campaign(document) }
  end

  def test_rejects_aggregate_profile_maximum_above_campaign_ceiling
    document = fixture
    document["max_workers"] = 5

    assert_error_includes("exceeds campaign max_workers") { load_campaign(document) }
  end

  def test_rejects_unknown_or_unqualified_model
    document = fixture
    document.fetch("profiles").first["model"] = "unqualified:model"

    assert_error_includes("no qualified RPOF hardware profile") { load_campaign(document) }
  end

  def test_rejects_digest_and_capability_mismatches
    document = fixture
    document.fetch("profiles").first["expected_digest"] = "not-a-digest"
    assert_error_includes("full SHA-256 digest") { load_campaign(document) }

    document = fixture
    document.fetch("profiles").first["require_fully_gpu_resident"] = false
    assert_error_includes("must be true") { load_campaign(document) }

    document = fixture
    duplicate_model = JSON.parse(JSON.generate(document.fetch("profiles").first))
    duplicate_model["profile_id"] = "qwen35-conflict"
    duplicate_model["expected_digest"] = "f" * 64
    duplicate_model["min_workers"] = 1
    duplicate_model["desired_workers"] = 1
    duplicate_model["max_workers"] = 1
    document.fetch("profiles") << duplicate_model
    document["max_workers"] = 7
    assert_error_includes("conflicting digest or capability") { load_campaign(document) }
  end

  def test_rejects_unknown_fields_at_every_contract_level
    document = fixture.merge("fleet_id" => "provider-detail")
    assert_error_includes("unknown field(s): fleet_id") { load_campaign(document) }

    document = fixture
    document.fetch("profiles").first["gpu_ids"] = ["NVIDIA A40"]
    assert_error_includes("unknown field(s): gpu_ids") { load_campaign(document) }
  end

  def test_rejects_wrong_version_missing_fields_and_duplicate_json_keys
    document = fixture.merge("contract_version" => "rpof-capacity-campaign/v0.2")
    assert_error_includes("contract must be") { load_campaign(document) }

    document = fixture
    document.delete("campaign_id")
    assert_error_includes("missing required field(s): campaign_id") { load_campaign(document) }

    bytes = File.read(FIXTURE).sub(
      '"campaign_id": "production-batch-039",',
      '"campaign_id": "first", "campaign_id": "second",'
    )
    error = assert_raises(RunpodOllamaFleet::CapacityCampaign::Error) do
      RunpodOllamaFleet::CapacityCampaign.new(bytes, hardware: hardware)
    end
    assert_includes error.message, "duplicate"
  end

  def test_normalized_bytes_and_hashes_are_deterministic
    first = load_campaign(fixture)
    reordered = fixture
    reordered["max_hourly_rate_usd"] = 6
    reordered["profiles"].reverse_each do |profile|
      profile["expected_digest"] = profile.fetch("expected_digest").upcase
    end
    reordered["profiles"].reverse!
    second = load_campaign(reordered)

    assert_equal first.normalized_bytes, second.normalized_bytes
    assert_equal first.sha256, second.sha256
    assert_equal first.hardware_qualification_sha256, second.hardware_qualification_sha256
    assert_equal first.identity, second.identity
    assert_equal first.identity_sha256, second.identity_sha256
  end

  def test_all_current_hardware_qualification_entries_are_compatible
    campaign = load_campaign(fixture)
    bindings = campaign.hardware_bindings.to_h { |row| [row.fetch("profile_id"), row] }

    assert_equal "qwen3.6:35b-a3b-q4_K_M", bindings.dig("qwen35", "shared_model")
    assert_equal "qwen3.6:27b-q4_K_M", bindings.dig("qwen27", "shared_model")
    assert_equal "gemma4:26b-a4b-it-mtp-q4_K_M", bindings.dig("gemma", "shared_model")
    assert_equal "gpt-oss:20b", bindings.dig("gptoss", "shared_model")
    assert_includes bindings.dig("qwen35", "qualified_gpu_ids"), "NVIDIA A40"
    assert_equal %w[cloud global_volume_id model ollama_store_path profile_id qualified_gpu_ids shared_model],
                 bindings.fetch("qwen35").keys.sort
    refute campaign.normalized_bytes.include?("NVIDIA")
    refute campaign.normalized_bytes.include?("fleet")
  end

  def test_qualification_changes_produce_distinct_lifecycle_identity
    first = load_campaign(fixture)
    hardware = Class.new do
      def profile_for(model)
        RunpodOllamaFleet::ExecutionPoolHardware::Profile.new(
          model:, cloud: "SECURE", gpu_ids: ["DIFFERENT QUALIFIED GPU"],
          shared_model: "shared/#{model}", global_volume_id: "volume",
          ollama_store_path: "/workspace-global/models"
        )
      end
    end.new
    second = load_campaign(fixture, hardware:)

    assert_equal first.sha256, second.sha256
    refute_equal first.hardware_qualification_sha256, second.hardware_qualification_sha256
    refute_equal first.identity_sha256, second.identity_sha256
  end

  private

  def fixture
    JSON.parse(File.read(FIXTURE))
  end

  def hardware
    RunpodOllamaFleet::ExecutionPoolHardware.new(path: HARDWARE)
  end

  def load_campaign(document, hardware: self.hardware)
    RunpodOllamaFleet::CapacityCampaign.new(JSON.generate(document), hardware:)
  end

  def assert_error_includes(text, &)
    error = assert_raises(RunpodOllamaFleet::CapacityCampaign::Error, &)
    assert_includes error.message, text
  end
end
