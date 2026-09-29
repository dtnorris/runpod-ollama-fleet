# frozen_string_literal: true

require "minitest/autorun"
require "open3"
require "rbconfig"
require "tmpdir"

class CapacityOnlyLoadTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)
  CAMPAIGN = File.join(ROOT, "test", "fixtures", "rpof-capacity-campaign-v0.1.json")
  BUDGET = File.join(ROOT, "test", "fixtures", "rpof-capacity-campaign-budget-v0.1.json")

  def test_capacity_and_compatibility_load_boundaries
    Dir.mktmpdir("capacity-only-load-") do |state_root|
      stdout, stderr, status = Open3.capture3(
        RbConfig.ruby, "-I#{File.join(ROOT, 'lib')}", "-e", probe_source(state_root), chdir: ROOT
      )

      assert status.success?, [stdout, stderr].reject(&:empty?).join("\n")
    end
  end

  private

  def probe_source(state_root)
    <<~RUBY
      forbidden = %i[job jobs job_id argv env affinity attempt attempts result results result_path]

      require "runpod_ollama_fleet/dynamic_worker_registry"
      raise "registry missing" unless defined?(RunpodOllamaFleet::DynamicWorkerRegistry)
      raise "registry loaded dispatch" if defined?(LocalModelEvaluation::RunpodDispatcher)

      require "runpod_ollama_fleet"
      required = %i[
        CapacityCampaign CampaignBudgetBinding CampaignCapacityAdmission
        CampaignLifecycle CampaignRunpodRuntime DynamicWorkerRegistry
      ]
      missing = required.reject { |name| RunpodOllamaFleet.const_defined?(name, false) }
      raise "missing capacity constants: \#{missing.join(', ')}" unless missing.empty?
      raise "primary loader exposed DispatchV01" if RunpodOllamaFleet.const_defined?(:DispatchV01, false)
      if RunpodOllamaFleet.const_defined?(:ExecutionPoolFulfill, false)
        raise "primary loader exposed ExecutionPoolFulfill"
      end
      raise "primary loader loaded dispatcher" if defined?(LocalModelEvaluation::RunpodDispatcher)

      classes = [
        RunpodOllamaFleet::CampaignLifecycle,
        RunpodOllamaFleet::CampaignCapacityAdmission,
        RunpodOllamaFleet::CampaignRunpodRuntime,
        RunpodOllamaFleet::DynamicWorkerRegistry
      ]
      leaks = classes.flat_map do |klass|
        klass.public_instance_methods(false).filter_map do |method_name|
          names = klass.instance_method(method_name).parameters.map(&:last).compact
          values = names & forbidden
          "\#{klass}##\#{method_name}: \#{values.join(', ')}" unless values.empty?
        end
      end
      raise "capacity API workload leakage: \#{leaks.join('; ')}" unless leaks.empty?

      require "local_model_evaluation/capacity"
      raise "RunpodFleet missing" unless defined?(LocalModelEvaluation::RunpodFleet)
      raise "RunpodBudget missing" unless defined?(LocalModelEvaluation::RunpodBudget)
      raise "capacity loader loaded dispatcher" if defined?(LocalModelEvaluation::RunpodDispatcher)

      ENV.delete("RUNPOD_API_KEY")
      ENV.delete("RUNPOD_API_BASE_URL")
      ARGV.replace([
        "plan", "--campaign", #{CAMPAIGN.dump}, "--budget", #{BUDGET.dump},
        "--state-root", #{state_root.dump}, "--json"
      ])
      $stdout.reopen(File::NULL, "w")
      exit_status = begin
        Dir.chdir(#{ROOT.dump}) { load File.join(#{ROOT.dump}, "bin", "rpof-campaign") }
        0
      rescue SystemExit => e
        e.status
      end
      raise "campaign plan exited \#{exit_status}" unless exit_status.zero?
      raise "campaign CLI exposed DispatchV01" if defined?(RunpodOllamaFleet::DispatchV01)
      raise "campaign CLI loaded dispatcher" if defined?(LocalModelEvaluation::RunpodDispatcher)

      require "runpod_ollama_fleet/compatibility"
      raise "DispatchV01 missing" unless defined?(RunpodOllamaFleet::DispatchV01)
      raise "ExecutionPoolFulfill missing" unless defined?(RunpodOllamaFleet::ExecutionPoolFulfill)
      raise "RunpodDispatcher missing" unless defined?(LocalModelEvaluation::RunpodDispatcher)
    RUBY
  end
end
