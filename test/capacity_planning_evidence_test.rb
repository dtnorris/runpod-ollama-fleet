# frozen_string_literal: true

require_relative "test_helper"
require "json"
require "stringio"
require "open3"
require_relative "../lib/runpod_ollama_fleet"

class CapacityPlanningEvidenceTest < Minitest::Test
  A40 = "NVIDIA A40"
  BLACKWELL = "NVIDIA RTX PRO 6000 Blackwell Server Edition"
  ROOT = File.expand_path("..", __dir__)

  class Guardian
    attr_accessor :healthy, :missing
    def initialize(clock)
      @clock = clock
      @healthy = true
    end

    def arm!(budget:, request:)
      budget.arm!(budget: request, guardian_heartbeat_at_utc: @clock.call)
    end

    def status(budget:)
      raise LocalModelEvaluation::RunpodBudgetGuardianSupervisor::Error, "unavailable" if missing
      { "budget_id" => budget.budget_id, "plan_sha256" => budget.plan_sha256,
        "enabled" => healthy, "launchd_loaded" => healthy, "ready" => healthy,
        "pid" => Process.pid + 1000, "ledger_heartbeat_at_utc" => @clock.call.iso8601,
        "state" => "ARMED" }
    end
  end

  # No lifecycle methods at all: unexpected provider calls fail immediately.
  class Catalog
    attr_accessor :rows, :error
    attr_reader :calls
    def initialize(rows)
      @rows = rows
      @calls = []
    end

    def list_gpu_types(cloud:, count:)
      @calls << [cloud, count]
      raise LocalModelEvaluation::RunpodClient::Error.new(503, "offline unavailable") if error
      Marshal.load(Marshal.dump(rows))
    end
  end

  def setup
    @tmp = Dir.mktmpdir("fo21b-")
    @now = Time.utc(2026, 10, 4, 12)
    @hardware = RunpodOllamaFleet::ExecutionPoolHardware.new(path: File.join(ROOT, "config/execution_pool_hardware.yml"))
    @campaign = RunpodOllamaFleet::CapacityCampaign.load(
      path: File.join(__dir__, "fixtures/rpof-capacity-campaign-v0.1.json"), hardware: @hardware
    )
    @declaration = JSON.parse(File.binread(File.join(__dir__, "fixtures/rpof-capacity-campaign-budget-v0.1.json")))
    @guardian = Guardian.new(-> { @now })
    @client = Catalog.new([gpu(A40, 0.5), gpu(BLACKWELL, 2.5), gpu("UNAUTHORIZED", 0.01)])
    @binding = build_binding
    @binding.arm!
  end

  def teardown
    FileUtils.remove_entry(@tmp)
  end

  def test_exact_identity_limits_and_candidate_specific_safety
    result = preview(3)
    assert_equal "rpof-capacity-planning-evidence/v0.1", result.fetch("contract_version")
    assert result.fetch("read_only")
    assert_equal @campaign.identity_sha256, result.fetch("campaign_identity_sha256")
    assert_equal @binding.binding_sha256, result.fetch("binding_sha256")
    assert_equal request.fingerprint, result.fetch("capability_fingerprint")
    assert_equal @binding.status.fetch("deadline_at_utc"), result.dig("authority", "original_deadline_at_utc")
    assert_equal 3, result.dig("authority", "profile_max_workers")
    assert_equal 6, result.dig("authority", "limits", "max_workers")
    cheap, costly = result.fetch("candidates")
    assert_equal [A40, BLACKWELL], result.fetch("candidates").map { |row| row.fetch("gpu_id") }
    assert_equal [1, 2], result.fetch("candidates").map { |row| row.fetch("rank") }
    assert_equal 1.5, cheap.fetch("projected_aggregate_hourly_rate_usd")
    assert_equal 7.5, costly.fetch("projected_aggregate_hourly_rate_usd")
    assert_equal "admissible_under_current_authority", cheap.dig("admission_preview", "status")
    assert_equal "not_admissible", costly.dig("admission_preview", "status")
    assert_includes costly.dig("admission_preview", "reasons"), "projected_hourly_rate_ceiling_exceeded"
    assert_equal "runpod_pod_compute_only", result.dig("authority", "billing_scope", "label")
    refute result.dig("admission_preview", "mutation_permission")
    assert_equal [["SECURE", 1]], @client.calls
  end

  def test_fo15_exact_candidate_order_is_shared_and_provider_order_does_not_matter
    runtime = RunpodOllamaFleet::CampaignRunpodRuntime.new(
      root: @tmp, repo_root: ROOT, profile: @campaign.profiles.find { |row| row.fetch("profile_id") == "qwen35" },
      hardware: @campaign.hardware_bindings.find { |row| row.fetch("profile_id") == "qwen35" }, client: @client, capability_request: request, out: StringIO.new
    )
    expected = runtime.send(:fallback_candidates)
    actual = preview(1).fetch("candidates").map { |row| row.slice("gpu_id", "cloud", "hourly_rate_usd", "eligible", "reason") }
    assert_equal expected, actual
    @client.rows.reverse!
    assert_equal actual, preview(1).fetch("candidates").map { |row| row.slice(*actual.first.keys) }
  end

  def test_required_gpu_narrows_to_one_identity
    rows = preview(1, capability_request: request("required_gpu_id" => BLACKWELL)).fetch("candidates")
    assert_equal [BLACKWELL], rows.map { |row| row.fetch("gpu_id") }
    assert_raises(RunpodOllamaFleet::OllamaCapabilityRequest::Error) do
      preview(1, capability_request: request("required_gpu_id" => "UNAUTHORIZED"))
    end
  end

  def test_wrong_campaign_binding_profile_and_capability_fail_closed
    assert_raises(RunpodOllamaFleet::CapacityPlanningEvidence::Error) { preview(1, profile_id: "unknown") }
    assert_raises(RunpodOllamaFleet::OllamaCapabilityRequest::Error) do
      preview(1, capability_request: request("require_fully_gpu_resident" => false))
    end
    wrong = build_binding(declaration: @declaration.merge("budget_id" => "different"))
    assert_raises(RunpodOllamaFleet::CapacityPlanningEvidence::Error) { preview(1, binding: wrong) }
    declaration = @declaration.merge("campaign_identity_sha256" => "f" * 64)
    assert_raises(RunpodOllamaFleet::CampaignBudgetBinding::Error) { build_binding(declaration:) }
  end

  def test_repeated_preview_is_byte_identical_for_every_retained_file_and_directory
    RunpodOllamaFleet::DesiredCapacity.new(binding: @binding).update!(
      profile_counts: { "qwen35" => 2 }, expected_revision: 0, reason: "fixture"
    )
    consumer = RunpodOllamaFleet::ConsumerCapacity.new(binding: @binding)
    consumer.bind!(
      "contract_version" => "rpof-consumer-binding/v0.1",
      "campaign_identity_sha256" => @campaign.identity_sha256, "binding_sha256" => @binding.binding_sha256,
      "idle_grace_seconds" => 30,
      "profiles" => @campaign.profiles.map do |profile|
        { "profile_id" => profile.fetch("profile_id"), "consumer_id" => "a" * 64, "plan_sha256" => "b" * 64,
          "pool_id" => profile.fetch("profile_id"), "source_argv" => ["/must/not/run"],
          "capability_request" => { "contract_version" => "ollama-capability-request/v0.1",
                                    "ollama" => profile.slice("model", "expected_digest", "required_context_length", "require_fully_gpu_resident") } }
      end
    )
    # Real retained consumer/fallback/registry-like bytes must not be consulted or rewritten.
    %w[consumer-binding.json availability-fallback.json registry.json guardian.json fleet.json].each do |name|
      File.binwrite(File.join(@tmp, name), "retained #{name}\n")
    end
    fallback = RunpodOllamaFleet::AvailabilityFallback.new(
      binding: @binding, profile: @campaign.profiles.find { |row| row.fetch("profile_id") == "qwen35" },
      hardware: @campaign.hardware_bindings.find { |row| row.fetch("profile_id") == "qwen35" },
      capability_request: request, wall_clock: -> { @now }
    )
    fallback.prepare!(from_workers: 0, target_workers: 1,
      original_deadline_at_utc: @binding.status.fetch("deadline_at_utc"),
      candidates: RunpodOllamaFleet::AuthorizedCandidates.observe(client: @client, gpu_ids: [A40, BLACKWELL], cloud: "SECURE"))
    %i[arm! bind! reserve_capacity_mutation! mutation_authority! assert_safety_gate!].each do |method|
      @binding.define_singleton_method(method) { |**| raise "planning invoked mutation #{method}" }
    end
    before = tree
    3.times { preview(2) }
    assert_equal before, tree
    assert_empty @binding.parent_budget.status.fetch("reservations")
  end

  def test_missing_state_does_not_even_create_a_lock_or_directory
    missing_root = File.join(@tmp, "missing")
    binding = build_binding(root: missing_root)
    before = tree
    assert_raises(RunpodOllamaFleet::CapacityPlanningEvidence::Error) { preview(1, binding:) }
    assert_equal before, tree
    refute_path_exists missing_root
  end

  def test_unavailable_missing_and_invalid_prices_are_explicit
    @client.rows[0]["availability"] = "NONE"
    @client.rows[1]["price"] = {}
    result = preview(1)
    cheap, costly = result.fetch("candidates")
    assert_equal "unavailable", cheap.fetch("availability")
    assert_equal "observed", cheap.fetch("price_status")
    refute cheap.fetch("eligible")
    assert_equal "unavailable", costly.fetch("price_status")
    assert_equal "insufficient_evidence", result.dig("admission_preview", "status")
    @client.rows[1]["price"]["secure"] = "nonsense"
    assert_equal "invalid", preview(1).fetch("candidates").last.fetch("price_status")
    @client.rows = []
    assert preview(1).fetch("candidates").all? { |row| row.fetch("availability") == "unknown" }
  end

  def test_nonfinite_and_nonpositive_rates_are_rejected_by_shared_fo15_policy
    [Float::INFINITY, Float::NAN, -0.5, 0].each do |rate|
      @client.rows[0]["price"]["secure"] = rate
      row = preview(1).fetch("candidates").find { |item| item.fetch("gpu_id") == A40 }
      assert_equal "invalid", row.fetch("price_status")
      assert_nil row.fetch("hourly_rate_usd")
      refute row.fetch("eligible")
      assert_equal "insufficient_evidence", row.dig("admission_preview", "status")
    end
  end

  def test_campaign_max_includes_all_profiles_and_preserves_unknown_reservations
    %w[qwen27 gemma gptoss].each { |profile| reserve(profile:, rate: 0.5) }
    result = preview(3)
    assert_equal 6, result.dig("proposal", "projected_campaign_workers")
    assert_equal "admissible_under_current_authority", result.dig("admission_preview", "status")
    assert_equal 3, result.dig("authority", "pending_or_ambiguous_workers")
    assert_includes preview(4).dig("admission_preview", "reasons"), "projected_worker_ceiling_exceeded"
  end

  def test_qualification_failure_stays_visible_with_observed_price
    @client.rows[0]["memory"] = 16
    row = preview(1).fetch("candidates").first
    assert_equal "observed", row.fetch("price_status")
    assert_equal 0.5, row.fetch("hourly_rate_usd")
    assert_equal "reported_available", row.fetch("availability")
    refute row.fetch("eligible")
    assert_match(/VRAM/, row.fetch("reason"))
    assert_equal "not_admissible", row.dig("admission_preview", "status")
  end

  def test_tampered_original_deadline_or_ledger_limits_fail_closed
    path = @binding.parent_budget.state_path
    original = File.binread(path)
    document = JSON.parse(original)
    document["deadline_at_utc"] = (@now + 10_000).iso8601
    File.binwrite(path, JSON.generate(document))
    assert_raises(RunpodOllamaFleet::CapacityPlanningEvidence::Error) { preview(1) }
    document = JSON.parse(original)
    document["limits"]["max_workers"] = 100
    File.binwrite(path, JSON.generate(document))
    assert_raises(RunpodOllamaFleet::CapacityPlanningEvidence::Error) { preview(1) }
  end

  def test_catalog_failure_and_no_available_candidates
    @client.rows.each { |row| row["availability"] = "NONE" }
    result = preview(1)
    assert_equal "not_admissible", result.dig("admission_preview", "status")
    assert_includes result.dig("admission_preview", "reasons"), "no_currently_eligible_authorized_candidate"
    @client.error = true
    result = preview(1)
    assert_equal "insufficient_evidence", result.dig("admission_preview", "status")
    assert_equal [A40, BLACKWELL], result.fetch("candidates").map { |row| row.fetch("gpu_id") }
    assert result.fetch("candidates").all? { |row| row.fetch("rank").nil? }
    assert_match(/offline unavailable/, result.fetch("catalog_error"))
  end

  def test_worker_limits_and_strict_input_validation
    assert_equal "admissible_under_current_authority", preview(1).dig("admission_preview", "status")
    assert_equal "admissible_under_current_authority", preview(3).dig("admission_preview", "status")
    assert_includes preview(4).dig("admission_preview", "reasons"), "profile_worker_ceiling_exceeded"
    assert_includes preview(7).dig("admission_preview", "reasons"), "projected_worker_ceiling_exceeded"
    [0, -1, 1.5, 2.0, "2", nil, true, 1_000_001].each do |count|
      assert_raises(RunpodOllamaFleet::CapacityPlanningEvidence::Error) { preview(count) }
    end
  end

  def test_pending_and_active_other_profile_costs_are_preserved
    reserve(profile: "qwen35", rate: 0.75)
    handle = reserve(profile: "gemma", rate: 1.0)
    admission = RunpodOllamaFleet::CampaignCapacityAdmission.new(binding: @binding, profile_id: "gemma")
    admission.attempt_provider_create!(handle) { "fake" }
    admission.commit!(handle, provider_resource_id: "fake", actual_hourly_rate_usd: 1.0)
    @now += 2
    result = preview(3)
    assert_equal 1, result.dig("authority", "active_workers")
    assert_equal 1, result.dig("authority", "pending_or_ambiguous_workers")
    assert_equal 4, result.dig("proposal", "projected_campaign_workers")
    assert_equal 2.75, result.fetch("candidates").first.fetch("projected_aggregate_hourly_rate_usd")
    assert_operator result.dig("authority", "accrued_compute_usd"), :>, 0
    assert_operator result.dig("authority", "committed_maximum_liability_usd"), :>, 0
    before = tree
    lower = preview(1)
    assert_equal 0, lower.dig("proposal", "additional_workers")
    assert_equal 1.75, lower.fetch("candidates").first.fetch("projected_aggregate_hourly_rate_usd")
    assert_equal before, tree
  end

  def test_cumulative_liability_is_existing_crash_horizon_and_not_reserved
    binding = build_binding(root: File.join(@tmp, "small"), declaration: @declaration.merge("max_cumulative_compute_usd" => 0.05))
    binding.arm!
    assert_equal "admissible_under_current_authority", preview(1, binding:).dig("admission_preview", "status")
    result = preview(3, binding:)
    assert_equal "not_admissible", result.dig("admission_preview", "status")
    assert_includes result.dig("admission_preview", "reasons"), "projected_cumulative_compute_authority_exceeded"
    assert_in_delta 1.5 * 155 / 3600, result.fetch("candidates").first.dig(
      "admission_preview", "safety_report", "crash_liability", "maximum_additional_compute_usd_after_orchestrator_loss"
    ), 0.000001
    assert_empty binding.parent_budget.status.fetch("reservations")
  end

  def test_expiry_unhealthy_and_unavailable_guardian_never_grant_admission
    original = @binding.status.fetch("deadline_at_utc")
    @guardian.healthy = false
    assert_equal "not_admissible", preview(1).dig("admission_preview", "status")
    @guardian.missing = true
    assert_equal "insufficient_evidence", preview(1).dig("admission_preview", "status")
    @now = Time.iso8601(original) + 1
    before = tree
    result = preview(1)
    assert_equal "not_admissible", result.dig("admission_preview", "status")
    assert_equal original, result.dig("authority", "original_deadline_at_utc")
    assert_includes result.dig("admission_preview", "reasons"), "original_deadline_expired"
    assert_equal before, tree
  end

  def test_cli_dispatch_help_and_missing_arguments_are_offline
    out, err, status = Open3.capture3(RbConfig.ruby, File.join(ROOT, "bin/rpof"), "planning-evidence", "--help")
    assert status.success?, err
    assert_includes out, "--proposed-workers"
    _out, err, status = Open3.capture3(RbConfig.ruby, File.join(ROOT, "bin/rpof"), "planning-evidence")
    refute status.success?
    assert_includes err, "--campaign"
  end

  def test_cli_emits_evidence_from_retained_state_without_provider_mutation
    request_path = File.join(@tmp, "request.json")
    budget_path = File.join(@tmp, "declaration.json")
    preload_path = File.join(@tmp, "offline.rb")
    File.binwrite(request_path, JSON.generate(request.document))
    File.binwrite(budget_path, JSON.generate(@declaration))
    File.binwrite(preload_path, <<~RUBY)
      require #{File.join(ROOT, "lib/local_model_evaluation/runpod_client").inspect}
      class LocalModelEvaluation::RunpodClient
        def list_gpu_types(**)
          #{[@client.rows.first].inspect}
        end
        def request(*) = raise("unexpected provider request")
      end
    RUBY
    before = tree
    out, err, status = Open3.capture3(
      { "RUBYOPT" => "-r#{preload_path}", "RUNPOD_API_KEY" => "offline-only" },
      RbConfig.ruby, File.join(ROOT, "bin/rpof"), "planning-evidence",
      "--campaign", File.join(__dir__, "fixtures/rpof-capacity-campaign-v0.1.json"),
      "--budget", budget_path, "--state-root", @tmp, "--profile-id", "qwen35",
      "--capability-request", request_path, "--proposed-workers", "2"
    )
    assert status.success?, err
    document = JSON.parse(out)
    assert_equal @binding.binding_sha256, document.fetch("binding_sha256")
    assert document.fetch("read_only")
    assert_equal 2, document.dig("proposal", "profile_workers")
    refute document.dig("admission_preview", "mutation_permission")
    assert_equal before, tree
  end

  private

  def build_binding(root: @tmp, declaration: @declaration)
    RunpodOllamaFleet::CampaignBudgetBinding.new(
      root:, repo_root: ROOT, campaign: @campaign, declaration:,
      wall_clock: -> { @now }, guardian_supervisor: @guardian
    )
  end

  def request(overrides = {})
    RunpodOllamaFleet::OllamaCapabilityRequest.new(JSON.generate(
      "contract_version" => "ollama-capability-request/v0.1",
      "ollama" => @campaign.profiles.find { |row| row.fetch("profile_id") == "qwen35" }.slice(
        "model", "expected_digest", "required_context_length", "require_fully_gpu_resident"
      ).merge(overrides)
    ))
  end

  def preview(count, binding: @binding, profile_id: "qwen35", capability_request: request)
    RunpodOllamaFleet::CapacityPlanningEvidence.new(
      binding:, profile_id:, capability_request:, client: @client, clock: -> { @now }
    ).document(proposed_workers: count)
  end

  def gpu(id, rate)
    { "id" => id, "memory" => 96, "secure" => true, "availability" => "HIGH", "price" => { "secure" => rate } }
  end

  def tree
    Dir.glob(File.join(@tmp, "**", "*"), File::FNM_DOTMATCH).reject { |path| [".", ".."].include?(File.basename(path)) }.sort.to_h do |path|
      [path.delete_prefix(@tmp), File.file?(path) ? File.binread(path) : :directory]
    end
  end

  def reserve(profile:, rate:)
    RunpodOllamaFleet::CampaignCapacityAdmission.new(binding: @binding, profile_id: profile).reserve!(
      operation_type: "create", logical_resource_id: "#{profile}-1", max_hourly_rate_delta_usd: rate,
      gpu_id: profile == "gemma" ? "NVIDIA L40S" : A40, cloud: "SECURE"
    )
  end
end
