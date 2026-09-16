# frozen_string_literal: true

require "json"
require_relative "contract_v0_1"
require_relative "../local_model_evaluation/runpod_client"
require_relative "../local_model_evaluation/runpod_status"
require_relative "../local_model_evaluation/runpod_tunnels"
require_relative "../local_model_evaluation/runpod_workers"

module RunpodOllamaFleet
  class CapabilityCheck
    def initialize(fleet_state:, fleet_key:, client: nil, process_adapter: nil, health_checker: nil, wall_clock: nil)
      @fleet_state = fleet_state
      @fleet_key = fleet_key
      @client = client
      @process = process_adapter || LocalModelEvaluation::RunpodTunnels::SystemProcessAdapter.new
      @health = health_checker || LocalModelEvaluation::RunpodTunnels::HttpHealthChecker.new
      @wall_clock = wall_clock || -> { Time.now.utc }
    end

    def check(request)
      ContractV01.validate_capability_request!(request)
      diagnostics = []
      fleet = @fleet_state.current
      unless fleet && fleet["status"] == "active"
        diagnostics << diagnostic("fleet.active", "FAIL", fleet ? "current fleet is #{fleet['status'].inspect}" : "no current active fleet")
        return result(request, fleet: fleet, indices: [], capabilities: nil, diagnostics: diagnostics)
      end
      diagnostics << diagnostic("fleet.active", "PASS", "selected logical fleet is active")

      indices, workers = select_workers(fleet, request.fetch("worker_selector"))
      diagnostics << diagnostic("workers.active", "PASS", "selected workers: #{indices.join(', ')}")

      status = LocalModelEvaluation::RunpodStatus.new(
        fleet_state: @fleet_state,
        client: @client,
        wall_clock: @wall_clock
      ).snapshot

      diagnostics << provider_diagnostic(status, indices)
      capabilities, provenance_detail = verify_provenance(
        fleet: fleet,
        bootstrap: status && status["bootstrap"],
        workers: workers,
        requirements: request.fetch("requirements")
      )
      diagnostics << diagnostic("bootstrap.provenance", capabilities ? "PASS" : "FAIL", provenance_detail)
      diagnostics << tunnel_diagnostic(fleet, workers)
      diagnostics << lease_diagnostic(status && status["lease"])

      billing = if status
                  {
                    "tracked_elapsed_seconds" => Float(status.fetch("tracked_elapsed_seconds")),
                    "current_tracked_hourly_rate_usd" => Float(status.fetch("current_tracked_hourly_rate_usd")),
                    "estimated_accrued_cost_usd" => Float(status.fetch("estimated_accrued_cost_usd"))
                  }
                end
      result(request, fleet: fleet, indices: indices, capabilities: capabilities,
             diagnostics: diagnostics, billing: billing)
    rescue LocalModelEvaluation::RunpodFleetState::Error,
           LocalModelEvaluation::RunpodStatus::Error,
           LocalModelEvaluation::RunpodWorkers::Error,
           KeyError, ArgumentError, TypeError => e
      result(request, fleet: nil, indices: [], capabilities: nil,
             diagnostics: [diagnostic("capability.check", "FAIL", "#{e.class}: #{e.message}")])
    end

    private

    def select_workers(fleet, selector)
      active = Array(fleet.fetch("workers")).select { |worker| worker["status"] == "active" }
      indices = if selector.fetch("mode") == "all"
                  active.map { |worker| Integer(worker.fetch("index")) }.sort
                else
                  selector.fetch("indices").map { |value| LocalModelEvaluation::RunpodWorkers.validate_index(value) }.sort
                end
      raise ArgumentError, "no active workers selected" if indices.empty?
      by_index = Array(fleet.fetch("workers")).to_h { |worker| [Integer(worker.fetch("index")), worker] }
      missing = indices.reject { |index| by_index.key?(index) }
      raise ArgumentError, "current fleet does not contain worker index(es): #{missing.join(', ')}" unless missing.empty?
      workers = indices.map { |index| by_index.fetch(index) }
      inactive = workers.reject { |worker| worker["status"] == "active" }
      unless inactive.empty?
        raise ArgumentError, "selected worker(s) are not active: #{inactive.map { |w| "burst_#{w.fetch('index')}" }.join(', ')}"
      end
      [indices, workers]
    end

    def provider_diagnostic(status, indices)
      return diagnostic("provider.running", "SKIP", "RUNPOD_API_KEY unavailable; provider state not checked") unless status && status["provider_checked"]
      by_index = Array(status.fetch("workers")).to_h { |worker| [Integer(worker.fetch("index")), worker] }
      bad = indices.filter_map do |index|
        row = by_index[index]
        next "burst_#{index}: missing provider status" unless row
        provider = row.fetch("provider_status").to_s
        "burst_#{index}: #{provider}" unless provider == "RUNNING"
      end
      return diagnostic("provider.running", "PASS", "selected provider pods are RUNNING") if bad.empty?
      diagnostic("provider.running", "FAIL", bad.join("; "))
    end

    def verify_provenance(fleet:, bootstrap:, workers:, requirements:)
      return [nil, "no bootstrap evidence recorded for current fleet"] unless bootstrap
      return [nil, "bootstrap state is #{bootstrap['status'].inspect}"] unless bootstrap["status"] == "passed"
      required_context = Integer(requirements.fetch("required_context_length"))
      return [nil, "bootstrap context mismatch: expected #{required_context}, got #{bootstrap['context'].inspect}"] unless bootstrap["context"] == required_context

      required_gpu = requirements["required_gpu_id"]
      worker_gpus = workers.to_h do |worker|
        index = Integer(worker.fetch("index"))
        [index, worker_gpu_id(fleet, worker)]
      end
      if required_gpu
        mismatched = worker_gpus.select { |_index, gpu_id| gpu_id != required_gpu }
        unless mismatched.empty?
          detail = mismatched.map { |index, gpu_id| "burst_#{index}=#{gpu_id.inspect}" }.join(", ")
          return [nil, "GPU mismatch: expected #{required_gpu.inspect}; #{detail}"]
        end
      end

      boot_by_index = Array(bootstrap.fetch("workers")).to_h { |worker| [Integer(worker.fetch("index")), worker] }
      capabilities = []
      requirements.fetch("models").each do |requirement|
        name = requirement.fetch("name")
        observations = workers.map do |worker|
          index = Integer(worker.fetch("index"))
          boot = boot_by_index[index]
          return [nil, "burst_#{index}: missing bootstrap provenance"] unless boot && boot["status"] == "passed"
          provenance = boot.fetch("provenance", {})
          gpu = provenance.dig("gpu", "name").to_s
          expected_gpu = worker_gpus.fetch(index)
          unless gpu == expected_gpu
            return [nil, "burst_#{index}: GPU provenance mismatch: expected #{expected_gpu.inspect}, got #{gpu.inspect}"]
          end
          observed = provenance.fetch("models", {})[name]
          return [nil, "burst_#{index}: missing model provenance for #{name}"] unless observed
          observed
        end
        digests = observations.map { |observed| observed["digest"].to_s.downcase }.uniq
        return [nil, "#{name}: workers do not agree on one exact digest"] unless digests.length == 1 && digests.first.match?(ContractV01::DIGEST)
        expected_digest = requirement["expected_digest"]&.downcase
        return [nil, "#{name}: digest mismatch"] if expected_digest && digests.first != expected_digest
        observations.each_with_index do |observed, offset|
          index = Integer(workers.fetch(offset).fetch("index"))
          return [nil, "burst_#{index}: #{name} context mismatch"] unless observed["context_length"] == required_context
          unless observed["fully_gpu_resident"] == true && observed["size_bytes"] && observed["size_bytes"] == observed["size_vram_bytes"]
            return [nil, "burst_#{index}: #{name} is not proven fully GPU-resident"]
          end
        end
        capabilities << {
          "name" => name,
          "digest" => digests.first,
          "context_length" => required_context,
          "fully_gpu_resident" => true
        }
      end
      selected_gpu_ids = worker_gpus.values.uniq
      [{
        "gpu_id" => selected_gpu_ids.length == 1 ? selected_gpu_ids.first : "mixed",
        "bootstrap_run_id" => bootstrap.fetch("run_id"),
        "models" => capabilities
      }, "exact bootstrap model/GPU/context provenance matches selected workers"]
    rescue KeyError, ArgumentError, TypeError => e
      [nil, "invalid bootstrap provenance: #{e.message}"]
    end

    def worker_gpu_id(fleet, worker)
      selected = worker["gpu_id"].to_s.strip
      selected = fleet.dig("gpu", "id").to_s.strip if selected.empty?
      raise ArgumentError, "burst_#{worker.fetch('index')} does not record an exact GPU id" if selected.empty?
      selected
    end

    def tunnel_diagnostic(fleet, workers)
      root = @fleet_state.artifact_dir(fleet.fetch("fleet_id"), "tunnels")
      path = File.join(root, LocalModelEvaluation::RunpodTunnels::STATE_FILE)
      return diagnostic("tunnels.healthy", "FAIL", "tunnel state is missing") unless File.file?(path)
      state = JSON.parse(File.read(path))
      return diagnostic("tunnels.healthy", "FAIL", "tunnel state belongs to a different fleet") unless state["fleet_id"] == fleet.fetch("fleet_id")
      by_index = Array(state["workers"]).to_h { |row| [Integer(row.fetch("index")), row] }
      failures = workers.filter_map do |worker|
        index = Integer(worker.fetch("index"))
        row = by_index[index]
        next "burst_#{index}: tunnel record missing" unless row
        next "burst_#{index}: tunnel pod identity mismatch" unless row["pod_id"].to_s == worker["pod_id"].to_s
        pid = row["pid"]
        next "burst_#{index}: tunnel pid missing" unless pid && @process.alive?(pid)
        next "burst_#{index}: tunnel process identity mismatch" unless @process.matches?(pid, row.fetch("process_identity"))
        health = @health.check(row.fetch("endpoint"))
        "burst_#{index}: #{health.detail || 'Ollama health check failed'}" unless health.respond_to?(:healthy) && health.healthy
      end
      return diagnostic("tunnels.healthy", "PASS", "selected tunnels and Ollama endpoints are healthy") if failures.empty?
      diagnostic("tunnels.healthy", "FAIL", failures.join("; "))
    rescue JSON::ParserError, KeyError, ArgumentError, TypeError,
           LocalModelEvaluation::RunpodFleetState::Error => e
      diagnostic("tunnels.healthy", "FAIL", "could not verify tunnels: #{e.message}")
    end

    def lease_diagnostic(lease)
      return diagnostic("lease.within_limits", "SKIP", "no runtime/spend lease configured") unless lease
      return diagnostic("lease.within_limits", "PASS", "runtime/spend lease is active") if lease["status"] == "active"
      diagnostic("lease.within_limits", "FAIL", "runtime/spend lease is #{lease['status'].inspect}")
    end

    def result(request, fleet:, indices:, capabilities:, diagnostics:, billing: nil)
      document = {
        "contract_version" => ContractV01::CAPABILITY_RESULT_VERSION,
        "ready" => diagnostics.none? { |row| row.fetch("status") == "FAIL" },
        "fleet_key" => request["fleet_key"].to_s,
        "fleet_id" => fleet && fleet["fleet_id"],
        "selected_worker_indices" => indices,
        "capabilities" => capabilities,
        "diagnostics" => diagnostics
      }
      document["billing"] = billing if billing
      document
    end

    def diagnostic(code, status, detail)
      { "code" => code, "status" => status, "detail" => detail.to_s }
    end
  end
end
