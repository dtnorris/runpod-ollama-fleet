# frozen_string_literal: true

require_relative "test_helper"
require "json"
require_relative "../lib/runpod_ollama_fleet"

class DesiredCapacityTest < Minitest::Test
  FIXTURE = File.expand_path("fixtures/rpof-capacity-campaign-v0.1.json", __dir__)
  BUDGET = File.expand_path("fixtures/rpof-capacity-campaign-budget-v0.1.json", __dir__)
  HARDWARE = File.expand_path("../config/execution_pool_hardware.yml", __dir__)

  def setup
    @tmp = Dir.mktmpdir("desired-capacity-")
    @now = Time.utc(2026, 10, 2, 16, 0, 0)
    hardware = RunpodOllamaFleet::ExecutionPoolHardware.new(path: HARDWARE)
    @campaign = RunpodOllamaFleet::CapacityCampaign.load(path: FIXTURE, hardware:)
    @binding = RunpodOllamaFleet::CampaignBudgetBinding.new(
      root: @tmp, repo_root: File.expand_path("..", __dir__), campaign: @campaign,
      declaration: JSON.parse(File.binread(BUDGET)), wall_clock: -> { @now }
    )
    @desired = RunpodOllamaFleet::DesiredCapacity.new(binding: @binding, wall_clock: -> { @now })
  end

  def teardown
    FileUtils.remove_entry(@tmp) if @tmp && File.exist?(@tmp)
  end

  def test_revision_zero_is_read_only_v01_compatibility_baseline
    state = @desired.current

    assert_equal "rpof-desired-capacity/v0.1", state.fetch("contract_version")
    assert_equal 0, state.fetch("revision")
    refute state.fetch("persisted")
    assert_equal desired_counts(@campaign.profiles), desired_counts(state.fetch("profiles"))
    refute File.exist?(@desired.current_path)

    document = JSON.parse(File.binread(FIXTURE))
    document.fetch("profiles").first["desired_workers"] = 0
    assert_raises(RunpodOllamaFleet::CapacityCampaign::Error) do
      RunpodOllamaFleet::CapacityCampaign.new(JSON.generate(document), hardware: hardware)
    end
  end

  def test_zero_desired_is_valid_without_removing_profile_or_authority
    before = authority_identity
    result = @desired.update!(
      profile_counts: { "qwen35" => 0 }, expected_revision: 0, reason: "hold qwen35"
    )

    assert result.fetch("changed")
    assert_equal 1, result.fetch("revision")
    assert_equal 0, desired_counts(result.fetch("profiles")).fetch("qwen35")
    assert_equal 3, authority_profile("qwen35").fetch("max_workers")
    assert_equal before, authority_identity
  end

  def test_zero_to_positive_and_positive_to_zero_increment_once_each
    first = @desired.update!(
      profile_counts: { "qwen35" => 0 }, expected_revision: 0, reason: "pause qwen35"
    )
    second = @desired.update!(
      profile_counts: { "qwen35" => 1 }, expected_revision: 1, reason: "resume qwen35"
    )
    third = @desired.update!(
      profile_counts: { "qwen35" => 0 }, expected_revision: 2, reason: "pause again"
    )

    assert_equal [1, 2, 3], [first, second, third].map { |row| row.fetch("revision") }
    assert_equal first.fetch("sha256"), second.fetch("previous_sha256")
    assert_equal second.fetch("sha256"), third.fetch("previous_sha256")
    assert_equal 0, desired_counts(third.fetch("profiles")).fetch("qwen35")
  end

  def test_multiple_profiles_can_mix_zero_and_positive_counts
    state = @desired.update!(
      profile_counts: { "qwen35" => 0, "qwen27" => 1, "gemma" => 0, "gptoss" => 1 },
      expected_revision: 0,
      reason: "select two pools"
    )

    assert_equal({ "gemma" => 0, "gptoss" => 1, "qwen27" => 1, "qwen35" => 0 },
                 desired_counts(state.fetch("profiles")))
    assert_equal @campaign.identity_sha256, state.fetch("campaign_identity_sha256")
    assert_equal @binding.binding_sha256, state.fetch("binding_sha256")
    assert_equal @binding.declaration.fetch("budget_id"), state.fetch("budget_id")
  end

  def test_stale_expected_revision_fails_closed
    @desired.update!(profile_counts: { "qwen35" => 0 }, expected_revision: 0, reason: "first")

    error = assert_raises(RunpodOllamaFleet::DesiredCapacity::Error) do
      @desired.update!(profile_counts: { "qwen35" => 1 }, expected_revision: 0, reason: "stale")
    end
    assert_includes error.message, "stale"
    assert_equal 1, @desired.current.fetch("revision")
  end

  def test_identical_request_at_current_revision_is_idempotent
    first = @desired.update!(
      profile_counts: { "qwen35" => 0 }, expected_revision: 0, reason: "first"
    )
    repeated = @desired.update!(
      profile_counts: { "qwen35" => 0 }, expected_revision: 1, reason: "repeat"
    )

    refute repeated.fetch("changed")
    assert_equal first.fetch("revision"), repeated.fetch("revision")
    assert_equal first.fetch("sha256"), repeated.fetch("sha256")
    assert_equal 1, Dir.glob(File.join(@desired.history_dir, "*.json")).length
  end

  def test_concurrent_writers_cannot_both_accept_one_expected_revision
    gate = Queue.new
    results = Queue.new
    threads = [0, 1].map do |count|
      Thread.new do
        gate.pop
        results << @desired.update!(
          profile_counts: { "qwen35" => count }, expected_revision: 0, reason: "writer #{count}"
        )
      rescue RunpodOllamaFleet::DesiredCapacity::Error => e
        results << e
      end
    end
    2.times { gate << true }
    threads.each(&:join)
    rows = 2.times.map { results.pop }

    assert_equal 1, rows.count { |row| row.is_a?(Hash) }
    assert_equal 1, rows.count { |row| row.is_a?(RunpodOllamaFleet::DesiredCapacity::Error) }
    assert_equal 1, @desired.current.fetch("revision")
  end

  def test_unknown_profile_and_count_above_authorized_maximum_fail_closed
    assert_raises(RunpodOllamaFleet::DesiredCapacity::Error) do
      @desired.update!(profile_counts: { "unknown" => 0 }, expected_revision: 0, reason: "bad")
    end
    error = assert_raises(RunpodOllamaFleet::DesiredCapacity::Error) do
      @desired.update!(profile_counts: { "qwen35" => 4 }, expected_revision: 0, reason: "bad")
    end
    assert_includes error.message, "immutable profile maximum"
    refute File.exist?(@desired.current_path)
  end

  def test_malformed_or_authority_widening_document_fails_closed
    @desired.update!(profile_counts: { "qwen35" => 0 }, expected_revision: 0, reason: "valid")
    document = JSON.parse(File.binread(@desired.current_path))
    document["max_workers"] = 99
    File.write(@desired.current_path, JSON.pretty_generate(document))

    error = assert_raises(RunpodOllamaFleet::DesiredCapacity::Error) { @desired.current }
    assert_includes error.message, "unknown field(s): max_workers"
  end

  def test_binding_campaign_and_budget_identity_are_immutable
    before = authority_identity
    state = @desired.update!(
      profile_counts: { "qwen35" => 0 }, expected_revision: 0, reason: "identity proof"
    )

    assert_equal before, authority_identity
    assert_equal before.fetch("campaign_identity_sha256"), state.fetch("campaign_identity_sha256")
    assert_equal before.fetch("binding_sha256"), state.fetch("binding_sha256")
    assert_equal before.fetch("budget_id"), state.fetch("budget_id")
    refute state.key?("deadline_at_utc")
    refute state.key?("max_workers")
    refute state.fetch("profiles").first.key?("model")
  end

  def test_failed_current_replace_leaves_prior_current_state_valid
    @desired.update!(profile_counts: { "qwen35" => 0 }, expected_revision: 0, reason: "first")
    original_rename = File.method(:rename)
    failing_rename = lambda do |source, target|
      raise Errno::EIO, "injected current replace failure" if target == @desired.current_path

      original_rename.call(source, target)
    end

    File.stub(:rename, failing_rename) do
      assert_raises(RunpodOllamaFleet::DesiredCapacity::Error) do
        @desired.update!(profile_counts: { "qwen35" => 1 }, expected_revision: 1, reason: "second")
      end
    end

    state = @desired.current
    assert_equal 1, state.fetch("revision")
    assert_equal 0, desired_counts(state.fetch("profiles")).fetch("qwen35")
  end

  def test_current_rejects_missing_history_and_broken_hash_chain
    first = @desired.update!(
      profile_counts: { "qwen35" => 0 }, expected_revision: 0, reason: "first"
    )
    second = @desired.update!(
      profile_counts: { "qwen35" => 1 }, expected_revision: 1, reason: "second"
    )
    File.write(File.join(@desired.history_dir, "0000000001.json"), "{}\n")

    error = assert_raises(RunpodOllamaFleet::DesiredCapacity::Error) { @desired.current }
    assert_match(/missing required|unreadable|previous revision/, error.message)
    assert_equal first.fetch("sha256"), second.fetch("previous_sha256")
  end

  private

  def hardware
    RunpodOllamaFleet::ExecutionPoolHardware.new(path: HARDWARE)
  end

  def desired_counts(profiles)
    profiles.to_h { |row| [row.fetch("profile_id"), row.fetch("desired_workers")] }
  end

  def authority_profile(profile_id)
    @campaign.profiles.find { |row| row.fetch("profile_id") == profile_id }
  end

  def authority_identity
    {
      "campaign_identity_sha256" => @campaign.identity_sha256,
      "binding_sha256" => @binding.binding_sha256,
      "budget_id" => @binding.declaration.fetch("budget_id"),
      "max_workers" => @binding.declaration.fetch("max_workers"),
      "max_aggregate_hourly_rate_usd" => @binding.declaration.fetch("max_aggregate_hourly_rate_usd"),
      "max_cumulative_compute_usd" => @binding.declaration.fetch("max_cumulative_compute_usd"),
      "max_runtime_seconds" => @binding.declaration.fetch("max_runtime_seconds")
    }
  end
end
