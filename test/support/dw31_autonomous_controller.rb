# frozen_string_literal: true

require "fileutils"
require "json"
require "rbconfig"
require "time"

repo_root, wlo_root, state_root, scheduler_socket, clock_path, provider_path,
  registry_path, result_path, config_path = ARGV
abort "invalid DW-31 autonomous controller arguments" unless config_path

$LOAD_PATH.unshift(File.join(repo_root, "lib"))
require "runpod_ollama_fleet"
require "local_model_evaluation/capacity"

def write_json_atomic(path, document)
  FileUtils.mkdir_p(File.dirname(path))
  temporary = "#{path}.tmp.#{$$}"
  File.write(temporary, JSON.pretty_generate(document) + "\n")
  File.rename(temporary, path)
ensure
  File.delete(temporary) if defined?(temporary) && temporary && File.exist?(temporary)
end

def update_provider(path)
  File.open("#{path}.lock", File::RDWR | File::CREAT, 0o600) do |lock|
    lock.flock(File::LOCK_EX)
    document = JSON.parse(File.read(path))
    yield document
    write_json_atomic(path, document)
  ensure
    lock.flock(File::LOCK_UN) rescue nil
  end
end

def scheduler_command(command_dir, argv)
  identity = "#{$$}-#{Thread.current.object_id}-#{Process.clock_gettime(Process::CLOCK_MONOTONIC, :nanosecond)}"
  request_path = File.join(command_dir, "#{identity}.request.json")
  response_path = File.join(command_dir, "#{identity}.response.json")
  write_json_atomic(request_path, "argv" => argv)
  deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 5
  until File.file?(response_path)
    raise "timed out waiting for deterministic launchd" if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline

    sleep 0.002
  end
  response = JSON.parse(File.read(response_path))
  File.delete(response_path)
  [response.fetch("stdout"), response.fetch("stderr"), response.fetch("status")]
end

def wait_for_file(path, pid:, log_path:)
  deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 5
  until File.file?(path)
    if Process.waitpid(pid, Process::WNOHANG)
      raise "WLO fixture exited before readiness: #{File.read(log_path)}"
    end
    if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
      raise "timed out waiting for WLO fixture: #{File.read(log_path)}"
    end
    sleep 0.01
  end
end

def publish_registry(path, campaign, now)
  profile = campaign.profiles.fetch(0)
  worker = {
    "worker_id" => "dw31-autonomous-worker-1",
    "generation_id" => "dw31-autonomous-generation-1",
    "endpoint" => "http://127.0.0.1:11441",
    "state" => "READY",
    "labels" => %w[inference ollama remote],
    "capabilities" => {
      "gpu_id" => "NVIDIA A40",
      "ollama" => {
        "models" => [{
          "model" => profile.fetch("model"),
          "digest" => profile.fetch("expected_digest"),
          "context_length" => profile.fetch("required_context_length"),
          "fully_gpu_resident" => true
        }]
      }
    }
  }
  worker["capability_fingerprint"] =
    RunpodOllamaFleet::DynamicWorkerRegistry.capability_fingerprint(worker)
  write_json_atomic(path, {
    "contract_version" => "dynamic-worker-registry/v0.1",
    "registry_id" => "dw31-autonomous-registry",
    "revision" => 1,
    "published_at" => now.iso8601,
    "expires_at" => (now + 7200).iso8601,
    "workers" => [worker]
  })
end

begin
  config = JSON.parse(File.read(config_path))
  wall_clock = -> { Time.iso8601(File.read(clock_path).strip) }
  hardware = RunpodOllamaFleet::ExecutionPoolHardware.new(
    path: File.join(repo_root, "config/execution_pool_hardware.yml")
  )
  campaign = RunpodOllamaFleet::CapacityCampaign.new(JSON.generate(
    "contract_version" => "rpof-capacity-campaign/v0.1",
    "campaign_id" => config.fetch("campaign_id"),
    "max_workers" => config.fetch("max_workers"),
    "max_hourly_rate_usd" => config.fetch("max_hourly_rate_usd"),
    "profiles" => [{
      "profile_id" => "qwen35",
      "model" => "qwen3.6:35b-a3b",
      "expected_digest" => "a" * 64,
      "required_context_length" => 131_072,
      "require_fully_gpu_resident" => true,
      "min_workers" => 1,
      "desired_workers" => 1,
      "max_workers" => config.fetch("max_workers")
    }]
  ), hardware:)
  supervisor = LocalModelEvaluation::RunpodBudgetGuardianSupervisor.new(
    root: state_root,
    repo_root:,
    platform: "arm64-darwin",
    command_runner: ->(argv) { scheduler_command(scheduler_socket, argv) }
  )
  declaration = {
    "contract_version" => "rpof-capacity-campaign-budget/v0.1",
    "campaign_identity" => campaign.identity,
    "campaign_identity_sha256" => campaign.identity_sha256,
    "budget_id" => config.fetch("budget_id"),
    "max_cumulative_compute_usd" => config.fetch("max_cumulative_compute_usd"),
    "max_aggregate_hourly_rate_usd" => config.fetch("max_hourly_rate_usd"),
    "max_workers" => config.fetch("max_workers"),
    "max_runtime_seconds" => config.fetch("max_runtime_seconds"),
    "guardian_poll_seconds" => config.fetch("guardian_poll_seconds"),
    "orchestrator_heartbeat_timeout_seconds" => config.fetch("heartbeat_timeout_seconds"),
    "teardown_reserve_seconds" => config.fetch("teardown_reserve_seconds")
  }
  binding = RunpodOllamaFleet::CampaignBudgetBinding.new(
    root: state_root,
    repo_root:,
    campaign:,
    declaration:,
    wall_clock:,
    guardian_supervisor: supervisor
  )
  binding.arm!

  admission = RunpodOllamaFleet::CampaignCapacityAdmission.new(
    binding:,
    profile_id: "qwen35"
  )
  handle = admission.reserve!(
    operation_type: "create",
    logical_resource_id: "burst_1",
    max_hourly_rate_delta_usd: config.fetch("max_hourly_rate_usd"),
    gpu_id: "NVIDIA A40",
    cloud: "SECURE",
    reservation_id: "dw31-autonomous-reservation-1"
  )
  provider_id = admission.attempt_provider_create!(handle) do
    update_provider(provider_path) do |provider|
      provider.fetch("pods")["fake-pod-1"] = {
        "id" => "fake-pod-1",
        "name" => "af-lme-qwen35-burst-1",
        "hourly_rate_usd" => config.fetch("max_hourly_rate_usd"),
        "campaign_binding_sha256" => binding.binding_sha256
      }
      provider.fetch("create_events") << provider.fetch("pods").fetch("fake-pod-1")
    end
    "fake-pod-1"
  end
  admission.commit!(
    handle,
    provider_resource_id: provider_id,
    actual_hourly_rate_usd: config.fetch("max_hourly_rate_usd")
  )

  wlo = nil
  if config.fetch("start_wlo")
    publish_registry(registry_path, campaign, wall_clock.call)
    ready_path = File.join(state_root, "wlo-ready.json")
    workdir = File.join(state_root, "wlo-work")
    output_dir = File.join(state_root, "wlo-output")
    log_path = File.join(state_root, "wlo.log")
    fixture = File.join(repo_root, "test/support/dw31_process_fixture.rb")
    wlo_pid = Process.spawn(
      RbConfig.ruby,
      fixture,
      "wlo",
      wlo_root,
      registry_path,
      ready_path,
      workdir,
      output_dir,
      wall_clock.call.iso8601,
      out: log_path,
      err: log_path
    )
    wait_for_file(ready_path, pid: wlo_pid, log_path:)
    Process.detach(wlo_pid)
    wlo = JSON.parse(File.read(ready_path)).merge("pid" => wlo_pid)
  end

  status = binding.status
  write_json_atomic(result_path, {
    "controller_pid" => Process.pid,
    "wlo" => wlo,
    "binding_state_path" => binding.state_path,
    "budget_state_path" => binding.parent_budget.state_path,
    "authority" => {
      "campaign_id" => campaign.campaign_id,
      "binding_sha256" => binding.binding_sha256,
      "budget_id" => status.dig("parent_budget", "budget_id"),
      "plan_sha256" => status.dig("parent_budget", "plan_sha256"),
      "campaign_identity_sha256" => campaign.identity_sha256,
      "armed_at_utc" => status.fetch("armed_at_utc"),
      "deadline_at_utc" => status.fetch("deadline_at_utc"),
      "max_cumulative_compute_usd" => declaration.fetch("max_cumulative_compute_usd"),
      "max_aggregate_hourly_rate_usd" => declaration.fetch("max_aggregate_hourly_rate_usd"),
      "max_workers" => declaration.fetch("max_workers"),
      "guardian_poll_seconds" => declaration.fetch("guardian_poll_seconds"),
      "orchestrator_heartbeat_timeout_seconds" => declaration.fetch(
        "orchestrator_heartbeat_timeout_seconds"
      ),
      "teardown_reserve_seconds" => declaration.fetch("teardown_reserve_seconds"),
      "launchd_label" => status.dig("guardian", "launchd_label"),
      "guardian_pid" => status.dig("guardian", "pid")
    }
  })

  loop do
    sleep 0.01
    binding.parent_budget.heartbeat!(source: "orchestrator")
  end
rescue StandardError => e
  write_json_atomic(result_path, {
    "error" => "#{e.class}: #{e.message}",
    "backtrace" => e.backtrace,
    "controller_pid" => Process.pid
  })
  exit 1
end
