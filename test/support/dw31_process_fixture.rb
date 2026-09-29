# frozen_string_literal: true

require "json"
require "time"

mode = ARGV.shift

if mode == "wlo"
  wlo_root, registry_path, ready_path, workdir, output_dir, now_text = ARGV
  $LOAD_PATH.unshift(File.join(wlo_root, "lib"))
  require "fileutils"
  require "stringio"
  require "workload_orchestrator"

  now = Time.iso8601(now_text)
  registry_bytes = File.binread(registry_path)
  source = WorkloadOrchestrator::StaticWorkerSource.new(registry_bytes)
  registry = WorkloadOrchestrator::DynamicWorkerRegistry.new(registry_bytes, now:)
  worker = registry.schedulable_workers.fetch(0)
  model = worker.capabilities.dig("ollama", "models", 0)
  plan = WorkloadOrchestrator::Plan.new(JSON.generate(
    "contract_version" => WorkloadOrchestrator::Plan::PRIORITY_CONTRACT_VERSION,
    "plan_id" => "dw31-killable-wlo",
    "failure_policy" => { "max_consecutive_failures" => 2, "max_total_failures" => 2 },
    "pools" => [{
      "pool_id" => "dw31-pool",
      "required_labels" => ["inference"],
      "requirements" => {
        "ollama" => {
          "model" => model.fetch("model"),
          "expected_digest" => model.fetch("digest"),
          "required_context_length" => model.fetch("context_length"),
          "require_fully_gpu_resident" => true,
          "required_gpu_id" => worker.capabilities.fetch("gpu_id")
        }
      }
    }],
    "jobs" => [{
      "job_id" => "hold-open",
      "pool_id" => "dw31-pool",
      "argv" => ["dw31-fixture"]
    }]
  ))
  FileUtils.mkdir_p(workdir)
  executor = lambda do |environment, *argv, chdir:|
    document = {
      "pid" => Process.pid,
      "registry_id" => registry.registry_id,
      "worker_id" => worker.worker_id,
      "endpoint" => environment.fetch("AF_OLLAMA_BASE_URL"),
      "argv" => argv,
      "workdir" => chdir,
      "provider_lifecycle_features" => $LOADED_FEATURES.grep(
        %r{/(?:rpof|paid_budget|pool_fulfillment|execution_pool_plan|worker_admission|legacy_rpof)}
      ).sort
    }
    File.write(ready_path, JSON.generate(document) + "\n")
    sleep 3600
  end
  runner = WorkloadOrchestrator::Runner.new(
    plan:,
    workers: WorkloadOrchestrator::WorkerSet.new({}),
    workdir:,
    output_dir:,
    out: StringIO.new,
    worker_source: source,
    worker_registry_clock: -> { now },
    worker_registry_sleeper: ->(*) { sleep 0.01 },
    worker_poll_interval: 0.01,
    command_executor: executor
  )
  runner.run
  exit
end

unless mode == "guardian"
  warn "usage: #{$PROGRAM_NAME} guardian|wlo ..."
  exit 64
end

root, repo_root, budget_id, plan_sha256, clock_path, provider_path = ARGV
$LOAD_PATH.unshift(File.join(repo_root, "lib"))
require "fileutils"
require "local_model_evaluation/runpod_budget_guardian"

class Dw31SharedProvider
  def initialize(path)
    @path = path
    @lock_path = "#{path}.lock"
  end

  def list_pods
    with_state { |document| document.fetch("pods").values }
  end

  def get_pod(id)
    pod = with_state { |document| document.fetch("pods")[id.to_s] }
    return pod if pod

    raise LocalModelEvaluation::RunpodClient::Error.new(404, "missing")
  end

  def delete_by_name(name, reason)
    with_state(write: true) do |document|
      id, pod = document.fetch("pods").find { |_candidate_id, row| row.fetch("name") == name }
      next false unless pod

      document.fetch("pods").delete(id)
      document.fetch("termination_events") << {
        "provider_resource_id" => id,
        "name" => name,
        "reason" => reason,
        "at_utc" => Time.now.utc.iso8601
      }
      true
    end
  end

  private

  def with_state(write: false)
    File.open(@lock_path, File::RDWR | File::CREAT, 0o600) do |lock|
      lock.flock(File::LOCK_EX)
      document = JSON.parse(File.read(@path))
      result = yield(document)
      if write
        temporary = "#{@path}.tmp.#{$$}"
        File.write(temporary, JSON.pretty_generate(document) + "\n")
        File.rename(temporary, @path)
      end
      result
    ensure
      lock.flock(File::LOCK_UN) rescue nil
    end
  end
end

Dw31Namespace = Struct.new(:fleet_key, :env_path, :state_root, :local_port_base, keyword_init: true)

class Dw31SharedFleet
  def initialize(provider, fleet_key)
    @provider = provider
    @fleet_key = fleet_key
  end

  def destroy(worker_indices:, verify_absent:, destroy_reason:, **)
    raise "DW-31 guardian must perform shared absence verification" unless verify_absent == false

    worker_indices.each do |index|
      @provider.delete_by_name("af-lme-#{@fleet_key}-burst-#{index}", destroy_reason)
    end
    worker_indices
  end
end

clock = lambda do
  Time.iso8601(File.read(clock_path).strip).utc
end
budget = LocalModelEvaluation::RunpodBudget.new(
  root:,
  budget_id:,
  plan_sha256:,
  wall_clock: clock
)
provider = Dw31SharedProvider.new(provider_path)
guardian = LocalModelEvaluation::RunpodBudgetGuardian.new(
  root:,
  repo_root:,
  budget_id:,
  plan_sha256:,
  budget:,
  provider_client: provider,
  namespace_factory: lambda do |fleet_key|
    Dw31Namespace.new(
      fleet_key:,
      env_path: File.join(root, "unused.env"),
      state_root: root,
      local_port_base: 11_400
    )
  end,
  fleet_factory: ->(namespace) { Dw31SharedFleet.new(provider, namespace.fleet_key) },
  sleeper: ->(_seconds) {},
  wall_clock: clock
)

$stdout.sync = true
$stdin.each_line do |line|
  request = JSON.parse(line)
  case request.fetch("command")
  when "probe"
    guardian.provider_probe!
    response = {
      "ready" => true,
      "pid" => Process.pid,
      "provider_probe_at_utc" => clock.call.iso8601,
      "state" => "WAITING_FOR_ARM"
    }
  when "tick"
    budget.heartbeat!(source: "orchestrator") if request["campaign_heartbeat"] == true
    status = guardian.tick
    response = {
      "ready" => true,
      "pid" => Process.pid,
      "provider_probe_at_utc" => clock.call.iso8601,
      "ledger_heartbeat_at_utc" => status["last_guardian_heartbeat_at_utc"],
      "state" => status.fetch("state"),
      "status" => status
    }
  when "status"
    status = budget.status
    response = {
      "ready" => true,
      "pid" => Process.pid,
      "provider_probe_at_utc" => clock.call.iso8601,
      "ledger_heartbeat_at_utc" => status["last_guardian_heartbeat_at_utc"],
      "state" => status.fetch("state"),
      "status" => status
    }
  when "exit"
    puts JSON.generate("stopped" => true, "pid" => Process.pid)
    break
  else
    raise "unknown DW-31 process command #{request.fetch('command').inspect}"
  end
  puts JSON.generate(response)
rescue StandardError => e
  puts JSON.generate("error" => "#{e.class}: #{e.message}", "pid" => Process.pid)
end
