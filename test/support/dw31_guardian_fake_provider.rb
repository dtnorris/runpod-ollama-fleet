# frozen_string_literal: true

require "json"
require "time"

repo_root = ENV.fetch("DW31_RPOF_ROOT")
$LOAD_PATH.unshift(File.join(repo_root, "lib"))
require "local_model_evaluation/capacity"

module Dw31GuardianFakeProvider
  Namespace = Struct.new(:fleet_key, keyword_init: true)

  module_function

  def clock
    -> { Time.iso8601(File.read(ENV.fetch("DW31_CLOCK_PATH")).strip) }
  end

  def with_state
    path = ENV.fetch("DW31_PROVIDER_PATH")
    File.open("#{path}.lock", File::RDWR | File::CREAT, 0o600) do |lock|
      lock.flock(File::LOCK_EX)
      document = JSON.parse(File.read(path))
      result = yield document
      temporary = "#{path}.tmp.#{$$}"
      File.write(temporary, JSON.pretty_generate(document) + "\n")
      File.rename(temporary, path)
      result
    ensure
      File.delete(temporary) if defined?(temporary) && temporary && File.exist?(temporary)
      lock.flock(File::LOCK_UN) rescue nil
    end
  end

  class Provider
    def list_pods
      Dw31GuardianFakeProvider.with_state { |document| document.fetch("pods").values }
    end

    def get_pod(id)
      pod = Dw31GuardianFakeProvider.with_state { |document| document.fetch("pods")[id.to_s] }
      return pod if pod

      raise LocalModelEvaluation::RunpodClient::Error.new(404, "missing fake pod")
    end
  end

  class Fleet
    def initialize(fleet_key)
      @fleet_key = fleet_key
    end

    def destroy(worker_indices:, verify_absent:, destroy_reason:, **_options)
      raise "guardian teardown must defer provider-absence verification" if verify_absent

      names = worker_indices.map do |index|
        if @fleet_key == "default"
          "af-lme-burst-#{index}"
        else
          "af-lme-#{@fleet_key}-burst-#{index}"
        end
      end
      Dw31GuardianFakeProvider.with_state do |document|
        removed = document.fetch("pods").select { |_id, pod| names.include?(pod.fetch("name")) }
        removed.each_key { |id| document.fetch("pods").delete(id) }
        removed.each_value do |pod|
          document.fetch("termination_events") << {
            "provider_resource_id" => pod.fetch("id"),
            "reason" => destroy_reason,
            "guardian_pid" => Process.pid
          }
        end
      end
      worker_indices
    end
  end

  module GuardianDependencies
    def initialize(root:, repo_root:, budget_id:, plan_sha256:, **keywords)
      wall_clock = Dw31GuardianFakeProvider.clock
      budget = LocalModelEvaluation::RunpodBudget.new(
        root:,
        budget_id:,
        plan_sha256:,
        wall_clock:
      )
      super(
        root:,
        repo_root:,
        budget_id:,
        plan_sha256:,
        budget:,
        provider_client: Provider.new,
        namespace_factory: ->(fleet_key) { Namespace.new(fleet_key:) },
        fleet_factory: ->(namespace) { Fleet.new(namespace.fleet_key) },
        sleeper: ->(_seconds) { sleep 0.005 },
        wall_clock:,
        **keywords
      )
    end
  end
end

LocalModelEvaluation::RunpodBudgetGuardian.prepend(
  Dw31GuardianFakeProvider::GuardianDependencies
)
