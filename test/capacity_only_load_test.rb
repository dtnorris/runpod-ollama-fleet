# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/runpod_ollama_fleet"

class CapacityOnlyLoadTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)
  PRIMARY_LOADER = File.join(ROOT, "lib", "runpod_ollama_fleet.rb")
  RUNPOD_BUDGET = File.join(ROOT, "lib", "local_model_evaluation", "runpod_budget.rb")
  RUNPOD_FLEET = File.join(ROOT, "lib", "local_model_evaluation", "runpod_fleet.rb")
  DISPATCHER = File.join(ROOT, "lib", "local_model_evaluation", "runpod_dispatcher.rb")
  DISPATCH_V01 = File.join(ROOT, "lib", "runpod_ollama_fleet", "dispatch_v0_1.rb")
  EXECUTION_POOL_FULFILL = File.join(ROOT, "lib", "runpod_ollama_fleet", "execution_pool_fulfill.rb")

  def test_capacity_and_compatibility_load_boundaries
    registry_dependencies = local_dependencies("lib/runpod_ollama_fleet/dynamic_worker_registry.rb")
    primary_dependencies = local_dependencies("lib/runpod_ollama_fleet.rb")
    capacity_dependencies = local_dependencies("lib/local_model_evaluation/capacity.rb")
    campaign_cli_dependencies = local_dependencies("bin/rpof-campaign")
    compatibility_dependencies = local_dependencies("lib/runpod_ollama_fleet/compatibility.rb")

    [registry_dependencies, primary_dependencies, capacity_dependencies, campaign_cli_dependencies,
     compatibility_dependencies].each do |dependencies|
      refute_includes dependencies, DISPATCHER
      refute_includes dependencies, DISPATCH_V01
      refute_includes dependencies, EXECUTION_POOL_FULFILL
    end
    assert_includes capacity_dependencies, RUNPOD_BUDGET
    assert_includes capacity_dependencies, RUNPOD_FLEET
    assert_includes campaign_cli_dependencies, PRIMARY_LOADER

    required = %i[
      CapacityCampaign CampaignBudgetBinding CampaignCapacityAdmission
      CampaignController CampaignControllerSupervisor CampaignLifecycle
      CampaignRunpodRuntime DynamicWorkerRegistry
    ]
    missing = required.reject { |name| RunpodOllamaFleet.const_defined?(name, false) }
    assert_empty missing, "missing capacity constants: #{missing.join(', ')}"

    forbidden = %i[job jobs job_id argv env affinity attempt attempts result results result_path]
    classes = [
      RunpodOllamaFleet::CampaignLifecycle,
      RunpodOllamaFleet::CampaignCapacityAdmission,
      RunpodOllamaFleet::CampaignRunpodRuntime,
      RunpodOllamaFleet::DynamicWorkerRegistry
    ]
    leaks = classes.flat_map do |klass|
      klass.public_instance_methods(false).filter_map do |method_name|
        values = klass.instance_method(method_name).parameters.map(&:last).compact & forbidden
        "#{klass}##{method_name}: #{values.join(', ')}" unless values.empty?
      end
    end
    assert_empty leaks, "capacity API workload leakage: #{leaks.join('; ')}"
  end

  private

  def local_dependencies(relative_entrypoint)
    pending = [File.join(ROOT, relative_entrypoint)]
    visited = []

    until pending.empty?
      path = File.realpath(pending.pop)
      next if visited.include?(path)

      visited << path
      File.foreach(path) do |line|
        match = line.match(/^\s*require(_relative)?\s+["']([^"']+)["']/)
        next unless match

        dependency = resolve_local_dependency(path, match[2], relative: !match[1].nil?)
        pending << dependency if dependency
      end
    end

    visited.sort
  end

  def resolve_local_dependency(source, feature, relative:)
    candidate = if relative
                  File.expand_path(feature, File.dirname(source))
                else
                  File.join(ROOT, "lib", feature)
                end
    candidate += ".rb" unless File.extname(candidate) == ".rb"
    candidate if File.file?(candidate)
  end
end
