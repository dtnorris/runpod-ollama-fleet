# frozen_string_literal: true

require "digest"
require "fileutils"
require "json"
require_relative "ollama_capability_request"
require_relative "capacity_campaign"
require_relative "campaign_budget_binding"

module RunpodOllamaFleet
  # Strict operator intent for one bounded, single-capability campaign. It
  # derives the existing campaign and budget contracts; it is not retained as
  # a second lifecycle contract or authority.
  class BoundedFleetIntent
    ARTIFACT_DIRECTORY = "bounded-fleets"
    CAMPAIGN_FILE = "campaign.json"
    BUDGET_FILE = "budget.json"
    CAPABILITY_FILE = "ollama-capability-request.json"

    class Error < StandardError; end

    attr_reader :campaign, :binding, :capability_request, :profile_id,
                :campaign_bytes, :budget_bytes, :capability_bytes

    def initialize(state_root:, repo_root:, hardware:, capability_request:,
                   campaign_id:, profile_id:, desired_workers:, max_workers:,
                   max_hourly_rate_usd:, max_cumulative_compute_usd:,
                   max_runtime_seconds:, guardian_poll_seconds:,
                   orchestrator_heartbeat_timeout_seconds:, teardown_reserve_seconds:)
      @state_root = File.expand_path(state_root)
      @repo_root = File.expand_path(repo_root)
      @hardware = hardware
      @capability_request = capability_request
      @profile_id = profile_id
      unless hardware.respond_to?(:profile_for)
        raise Error, "hardware registry must implement #profile_for"
      end
      unless capability_request.is_a?(OllamaCapabilityRequest)
        raise Error, "capability request must be an OllamaCapabilityRequest"
      end

      campaign_document = {
        "contract_version" => CapacityCampaign::CONTRACT_VERSION,
        "campaign_id" => campaign_id,
        "max_workers" => max_workers,
        "max_hourly_rate_usd" => max_hourly_rate_usd,
        "profiles" => [{
          "profile_id" => profile_id,
          "model" => capability_request.ollama.fetch("model"),
          "expected_digest" => capability_request.ollama.fetch("expected_digest"),
          "required_context_length" => capability_request.ollama.fetch("required_context_length"),
          "require_fully_gpu_resident" => capability_request.ollama.fetch("require_fully_gpu_resident"),
          "min_workers" => 1,
          "desired_workers" => desired_workers,
          "max_workers" => max_workers
        }]
      }
      @campaign = CapacityCampaign.new(JSON.generate(campaign_document), hardware:)
      qualification = campaign.hardware_bindings.fetch(0)
      capability_request.validate_profile!(profile: campaign.profiles.fetch(0), hardware: qualification)

      budget_document = {
        "contract_version" => CampaignBudgetBinding::CONTRACT_VERSION,
        "campaign_identity" => campaign.identity,
        "campaign_identity_sha256" => campaign.identity_sha256,
        "budget_id" => self.class.budget_id(campaign.campaign_id),
        "max_cumulative_compute_usd" => max_cumulative_compute_usd,
        "max_aggregate_hourly_rate_usd" => max_hourly_rate_usd,
        "max_workers" => max_workers,
        "max_runtime_seconds" => max_runtime_seconds,
        "guardian_poll_seconds" => guardian_poll_seconds,
        "orchestrator_heartbeat_timeout_seconds" => orchestrator_heartbeat_timeout_seconds,
        "teardown_reserve_seconds" => teardown_reserve_seconds
      }
      @binding = CampaignBudgetBinding.new(
        root: @state_root, repo_root: @repo_root, campaign:, declaration: budget_document
      )
      @campaign_bytes = JSON.pretty_generate(campaign.normalized_document) + "\n"
      @budget_bytes = JSON.pretty_generate(binding.declaration) + "\n"
      @capability_bytes = JSON.pretty_generate(
        "contract_version" => OllamaCapabilityRequest::CONTRACT_VERSION,
        "ollama" => capability_request.ollama
      ) + "\n"
    rescue CapacityCampaign::Error, CampaignBudgetBinding::Error, OllamaCapabilityRequest::Error,
           KeyError, ArgumentError, TypeError => e
      raise Error, e.message
    end

    def preview
      profile = campaign.profiles.fetch(0)
      hardware = campaign.hardware_bindings.fetch(0)
      {
        "command" => "bounded-fleet preview",
        "read_only" => true,
        "provider_mutations" => 0,
        "guardian_mutations" => 0,
        "controller_mutations" => 0,
        "registry_publications" => 0,
        "inference_requests" => 0,
        "authority_artifacts_persisted" => false,
        "validation" => {
          "bounded_intent" => "ACCEPTED",
          "paid_start_gate" => "NOT_RUN",
          "paid_start_gate_reason" => "requires explicit start, retained authority, live pricing, and guardian evidence"
        },
        "capability" => {
          "contract_version" => OllamaCapabilityRequest::CONTRACT_VERSION,
          "fingerprint" => capability_request.fingerprint,
          "model" => capability_request.ollama.fetch("model"),
          "expected_digest" => capability_request.ollama.fetch("expected_digest"),
          "required_context_length" => capability_request.ollama.fetch("required_context_length"),
          "require_fully_gpu_resident" => capability_request.ollama.fetch("require_fully_gpu_resident"),
          "required_gpu_id" => capability_request.required_gpu_id
        },
        "campaign" => campaign.identity.merge("identity_sha256" => campaign.identity_sha256),
        "binding_sha256" => binding.binding_sha256,
        "profile" => profile.merge(
          "cloud" => hardware.fetch("cloud"),
          "qualified_gpu_ids" => hardware.fetch("qualified_gpu_ids"),
          "shared_model" => hardware.fetch("shared_model")
        ),
        "authority" => binding.authority_preview
      }
    end

    def persist!
      paths = artifact_paths
      FileUtils.mkdir_p(paths.fetch(:directory), mode: 0o700)
      File.open(paths.fetch(:lock), File::RDWR | File::CREAT, 0o600) do |lock|
        lock.flock(File::LOCK_EX)
        expected = expected_artifacts(paths)
        conflicts = expected.filter_map do |path, bytes|
          next unless File.exist?(path)
          next path unless File.file?(path)
          next if File.binread(path) == bytes

          path
        end
        unless conflicts.empty?
          raise Error, "retained bounded-fleet artifact conflicts with requested authority: #{conflicts.join(', ')}"
        end
        expected.each { |path, bytes| write_exclusive(path, bytes) unless File.exist?(path) }
      end
      paths
    rescue SystemCallError => e
      raise Error, "could not retain bounded-fleet authority: #{e.message}"
    end

    def artifact_paths
      self.class.artifact_paths(state_root: @state_root, campaign_id: campaign.campaign_id)
    end

    def self.artifact_paths(state_root:, campaign_id:)
      key = Digest::SHA256.hexdigest(valid_campaign_id!(campaign_id))
      directory = File.join(File.expand_path(state_root), ARTIFACT_DIRECTORY, key)
      {
        directory:,
        campaign: File.join(directory, CAMPAIGN_FILE),
        budget: File.join(directory, BUDGET_FILE),
        capability_request: File.join(directory, CAPABILITY_FILE),
        lock: File.join(directory, ".lock")
      }
    end

    def self.budget_id(campaign_id)
      "bounded-#{Digest::SHA256.hexdigest(valid_campaign_id!(campaign_id))[0, 32]}"
    end

    def self.valid_campaign_id!(value)
      unless value.is_a?(String) && value.match?(CapacityCampaign::ID)
        raise Error, "campaign_id has invalid format"
      end

      value
    end
    private_class_method :valid_campaign_id!

    private

    def expected_artifacts(paths)
      {
        paths.fetch(:campaign) => campaign_bytes,
        paths.fetch(:budget) => budget_bytes,
        paths.fetch(:capability_request) => capability_bytes
      }
    end

    def write_exclusive(path, bytes)
      File.open(path, File::WRONLY | File::CREAT | File::EXCL, 0o600) do |file|
        file.write(bytes)
        file.flush
        file.fsync
      end
    end
  end
end
