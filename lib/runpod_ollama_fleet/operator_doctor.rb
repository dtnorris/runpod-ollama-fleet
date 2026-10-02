# frozen_string_literal: true

require "json"

module RunpodOllamaFleet
  # Read-only explanation layer over FO-04 status and FO-08 retained safety
  # evidence. It never calls provider APIs or advances registry publication.
  class OperatorDoctor
    class Error < StandardError; end
    DEFAULT_LOG_LINES = 15
    MAX_LOG_LINES = 200
    MAX_TAIL_BYTES = 262_144
    STAGES = %w[
      provider_creation tunnel bootstrap capability_verification
      registry_publication paid_start_safety_gate guardian teardown
      provider_absence_verification healthy unknown
    ].freeze
    ACTIONS = %w[
      inspect_fleet_status inspect_pod inspect_bootstrap_log inspect_tunnel_status
      inspect_registry_status inspect_campaign_safety inspect_campaign_status
      repeat_teardown_status
    ].freeze

    def initialize(snapshot: nil, state_root: nil, campaign_binding: nil)
      @snapshot = snapshot
      @state_root = state_root && File.expand_path(state_root)
      @campaign_binding = campaign_binding
    end

    def pod(handle)
      worker = resolve_pod(handle)
      result = pod_result(worker)
      validate!(result)
      result
    end

    def fleet(handle)
      alias_name = handle.to_s.upcase
      rows = snapshot.fetch("workers").select { |worker| worker.fetch("fleet_alias") == alias_name }
      raise Error, "unknown or stale fleet handle #{handle.inspect}" if rows.empty?

      failing = rows.sort_by { |worker| worker.fetch("index") }.find do |worker|
        pod_result(worker).fetch("status") != "healthy"
      end
      result = if failing
                 diagnosis = pod_result(failing)
                 diagnosis.merge(
                   "subject" => { "type" => "fleet", "handle" => alias_name,
                                   "fleet_key" => failing.fetch("fleet_key") },
                   "next_action" => action("inspect_pod", "handle" => pod_handle(failing))
                 )
               else
                 {
                   "subject" => { "type" => "fleet", "handle" => alias_name,
                                   "fleet_key" => rows.first.fetch("fleet_key") },
                   "stage" => "healthy", "status" => "healthy",
                   "summary" => "All retained workers are registry READY.",
                   "evidence" => [{ "kind" => "fleet_status", "workers" => rows.length,
                                    "registry_ready" => rows.count { |row| row["registry_state"] == "READY" } }],
                   "next_action" => nil
                 }
               end
      validate!(result)
      result
    end

    def campaign
      raise Error, "campaign binding is required" unless @campaign_binding

      authority = @campaign_binding.inspect_authority
      retained = @campaign_binding.retained_safety_report
      report = retained && retained.fetch("report")
      ledger = authority["parent_budget"] || {}
      result = campaign_result(authority, ledger, retained, report)
      validate!(result)
      result
    end

    def pod_logs(handle, lines: DEFAULT_LOG_LINES)
      worker = resolve_pod(handle)
      count = Integer(lines)
      raise Error, "--lines must be between 1 and #{MAX_LOG_LINES}" unless count.between?(1, MAX_LOG_LINES)

      path = worker["bootstrap_log"]
      {
        "subject" => pod_subject(worker),
        "source" => path && relative_state_path(path),
        "lines" => path ? redact(tail_lines(verified_state_path(path), count)) : []
      }
    rescue ArgumentError, TypeError
      raise Error, "--lines must be between 1 and #{MAX_LOG_LINES}"
    end

    private

    def snapshot
      @snapshot || raise(Error, "fleet status snapshot is required")
    end

    def resolve_pod(handle)
      text = handle.to_s.upcase
      matches = snapshot.fetch("workers").select do |worker|
        pod_handle(worker) == text || worker["worker_id"] == handle.to_s || worker["pod_id"] == handle.to_s
      end
      raise Error, "unknown or stale pod handle #{handle.inspect}" if matches.empty?
      raise Error, "ambiguous pod handle #{handle.inspect}" if matches.length > 1

      matches.first
    end

    def pod_result(worker)
      result = {
        "subject" => pod_subject(worker), "stage" => "unknown", "status" => "blocked",
        "summary" => "Retained evidence does not identify one failing stage.",
        "evidence" => [pod_evidence(worker)], "next_action" => action("inspect_fleet_status")
      }
      unless worker.fetch("lme_status") == "active"
        return result.merge("stage" => "provider_creation",
                            "summary" => "Retained fleet state does not show an active managed pod.")
      end
      unless worker.fetch("tunnel_status") == "ESTABLISHED"
        return result.merge("stage" => "tunnel",
                            "summary" => "Managed pod is retained, but its tunnel is not established.",
                            "next_action" => action("inspect_tunnel_status"))
      end
      bootstrap = worker.fetch("bootstrap_status")
      if bootstrap == "-" || bootstrap == "FAILED" || bootstrap == "INTERRUPTED"
        return result.merge("stage" => "bootstrap",
                            "summary" => "Bootstrap evidence is #{bootstrap == '-' ? 'missing' : bootstrap.downcase}.",
                            "next_action" => action("inspect_bootstrap_log"))
      end
      if Array(worker["available_models"]).empty?
        return result.merge("stage" => "capability_verification",
                            "summary" => "Validated model capability evidence is missing.",
                            "next_action" => action("inspect_bootstrap_log"))
      end
      unless worker.fetch("registry_state") == "READY"
        return result.merge("stage" => "registry_publication",
                            "summary" => "Registry reports #{worker.fetch('registry_state')}.",
                            "next_action" => action("inspect_registry_status"))
      end

      result.merge("stage" => "healthy", "status" => "healthy",
                   "summary" => "Pod is registry READY.", "next_action" => nil)
    end

    def campaign_result(authority, ledger, retained, report)
      subject = { "type" => "campaign", "id" => @campaign_binding.campaign.campaign_id }
      if report && report.fetch("safety_gate") == "FAIL"
        return {
          "subject" => subject, "stage" => "paid_start_safety_gate", "status" => "blocked",
          "summary" => "Paid-start safety gate refused authorization.",
          "evidence" => [{ "kind" => "safety_report", "path" => relative_state_path(@campaign_binding.safety_report_path),
                           "recorded_at_utc" => retained.fetch("recorded_at_utc"),
                           "refusal_reasons" => report.fetch("refusal_reasons") }],
          "next_action" => action("inspect_campaign_safety")
        }
      end
      if ledger["state"] == "CLOSED" && ledger["provider_absence_verified_at_utc"]
        return {
          "subject" => subject, "stage" => "healthy", "status" => "healthy",
          "summary" => "Campaign is CLOSED with provider absence verified.",
          "evidence" => [{ "kind" => "provider_absence", "verified_at_utc" => ledger["provider_absence_verified_at_utc"] }],
          "next_action" => nil
        }
      end
      if ledger["state"] == "TEARDOWN_REQUIRED"
        failures = Array(ledger["teardown_failures"])
        return {
          "subject" => subject,
          "stage" => failures.empty? ? "provider_absence_verification" : "teardown",
          "status" => "blocked",
          "summary" => failures.empty? ? "Teardown is requested; provider absence is not verified." :
            "Guardian-reported teardown failure is retained.",
          "evidence" => [{ "kind" => "campaign_budget", "state" => ledger["state"],
                           "latest_failure" => failures.last }],
          "next_action" => action("repeat_teardown_status")
        }
      end
      unless authority.fetch("guardian_healthy", false)
        return {
          "subject" => subject, "stage" => "guardian", "status" => "blocked",
          "summary" => "Guardian evidence is unhealthy or mismatched.",
          "evidence" => [{ "kind" => "guardian", "guardian" => authority["guardian"] }],
          "next_action" => action("inspect_campaign_status")
        }
      end
      {
        "subject" => subject, "stage" => "healthy", "status" => "healthy",
        "summary" => "Campaign authority is retained without a diagnosed fault.",
        "evidence" => [{ "kind" => "campaign_budget", "state" => ledger["state"],
                         "safety_gate" => report && report["safety_gate"] }], "next_action" => nil
      }
    end

    def pod_subject(worker)
      { "type" => "pod", "handle" => pod_handle(worker), "pod_id" => worker.fetch("pod_id"),
        "worker_id" => worker["worker_id"], "generation_id" => worker["generation_id"],
        "fleet_key" => worker.fetch("fleet_key"), "index" => worker.fetch("index") }
    end

    def pod_evidence(worker)
      { "kind" => "readiness", "managed_state" => worker.fetch("lme_status"),
        "provider" => worker.fetch("provider_status"), "tunnel" => worker.fetch("tunnel_status"),
        "bootstrap" => worker.fetch("bootstrap_status"), "registry" => worker.fetch("registry_state"),
        "models" => worker.fetch("available_models") }
    end

    def pod_handle(worker)
      "#{worker.fetch('fleet_alias')}#{worker.fetch('index')}"
    end

    def action(id, extra = {})
      raise Error, "invalid diagnostic action #{id.inspect}" unless ACTIONS.include?(id)

      { "action" => id }.merge(extra)
    end

    def validate!(result)
      raise Error, "invalid diagnostic stage" unless STAGES.include?(result.fetch("stage"))
      action_row = result["next_action"]
      if result.fetch("status") == "healthy"
        raise Error, "healthy diagnosis cannot have a next action" if action_row
      elsif !action_row || !ACTIONS.include?(action_row.fetch("action"))
        raise Error, "blocked diagnosis must have exactly one next action"
      end
    end

    def verified_state_path(path)
      expanded = File.expand_path(path)
      unless @state_root && (expanded == @state_root || expanded.start_with?("#{@state_root}/"))
        raise Error, "diagnostic evidence path is outside the RPOF state root"
      end
      expanded
    end

    def relative_state_path(path)
      return path unless @state_root

      File.expand_path(path).delete_prefix("#{@state_root}/")
    end

    def tail_lines(path, count)
      return [] unless File.file?(path)

      bytes = +""
      File.open(path, "rb") do |file|
        position = file.size
        while position.positive? && bytes.count("\n") <= count && bytes.bytesize < MAX_TAIL_BYTES
          size = [4096, position, MAX_TAIL_BYTES - bytes.bytesize].min
          position -= size
          file.seek(position)
          bytes.prepend(file.read(size))
        end
      end
      bytes.lines.last(count).map(&:chomp)
    rescue Errno::ENOENT
      []
    end

    def redact(lines)
      names = /(RUNPOD_API_KEY|OPENAI_API_KEY|ANTHROPIC_API_KEY|GOOGLE_API_KEY|AWS_ACCESS_KEY_ID|AWS_SECRET_ACCESS_KEY)/i
      lines.map do |line|
        line.gsub(/(#{names.source}\s*[=:]\s*)\S+/i, "\\1[REDACTED]")
            .gsub(/(Authorization:\s*Bearer\s+)\S+/i, "\\1[REDACTED]")
      end
    end
  end


  # Adapter for RunpodStatus that consumes the last atomically retained
  # publisher snapshot. It performs no health request and does not advance the
  # publisher revision.
  class RetainedReadiness
    OfflineHealth = Struct.new(:healthy)

    class OfflineHealthChecker
      def check(_endpoint) = OfflineHealth.new(false)
    end

    def initialize(state_root:, repo_root:, fleet_key:, fleet_state:, readiness_observer: nil)
      @state_root = File.expand_path(state_root)
      @repo_root = File.expand_path(repo_root)
      @fleet_key = fleet_key.to_s
      @fleet_state = fleet_state
      @readiness_observer = readiness_observer || DynamicWorkerRegistry.new(
        state_root: @state_root, repo_root: @repo_root,
        fleet_sources: [{ "fleet_key" => @fleet_key, "state" => @fleet_state }],
        health_checker: OfflineHealthChecker.new
      )
    end

    def readiness_status
      fleet = @fleet_state.current
      return unavailable("no current fleet state") unless fleet

      snapshot = retained_snapshot
      published = snapshot.fetch("workers").to_h do |worker|
        [[worker.fetch("worker_id"), worker.fetch("generation_id")], worker]
      end
      current = fleet.fetch("workers").to_h { |worker| [Integer(worker.fetch("index")), worker] }
      observed = @readiness_observer.readiness_status.fetch("workers")
      workers = observed.map do |observation|
        worker = current.fetch(Integer(observation.fetch("index")))
        identity = [worker.fetch("worker_id"), worker.fetch("generation_id")]
        row = published[identity]
        state = row && row.fetch("state")
        {
          "fleet_key" => @fleet_key,
          "index" => Integer(worker.fetch("index")),
          "pod_id" => worker.fetch("pod_id").to_s,
          "bootstrap_passed" => observation.fetch("bootstrap_passed"),
          "capability_evidence_valid" => observation.fetch("capability_evidence_valid"),
          "tunnel_established" => observation.fetch("tunnel_established"),
          "registry_state" => state,
          "worker_id" => worker.fetch("worker_id"),
          "generation_id" => worker.fetch("generation_id")
        }
      end
      states = %w[READY NOT_READY UNAVAILABLE].to_h do |state|
        [state, workers.count { |worker| worker["registry_state"] == state }]
      end
      {
        "status" => "available", "retained_revision" => snapshot.fetch("revision"),
        "retained_published_at" => snapshot.fetch("published_at"), "workers" => workers,
        "counts" => states.merge(
          "bootstrap_passed" => workers.count { |worker| worker.fetch("bootstrap_passed") },
          "capability_evidence_valid" => workers.count { |worker| worker.fetch("capability_evidence_valid") },
          "tunnel_established" => workers.count { |worker| worker.fetch("tunnel_established") },
          "registry_unpublished" => workers.count { |worker| worker["registry_state"].nil? }
        )
      }
    rescue JSON::ParserError, SystemCallError, KeyError, ArgumentError, TypeError => e
      unavailable("retained registry evidence is invalid: #{e.message}")
    end

    private

    def retained_snapshot
      path = File.join(@state_root, DynamicWorkerRegistry::PUBLISHER_STATE_FILE)
      state = JSON.parse(File.read(path))
      snapshot = state.fetch("snapshot")
      unless snapshot.fetch("contract_version") == DynamicWorkerRegistry::CONTRACT_VERSION
        raise Error, "retained registry contract is invalid"
      end
      snapshot
    end

    def unavailable(message)
      { "status" => "unavailable", "error" => message, "workers" => [], "counts" => {} }
    end
  end
end
