# frozen_string_literal: true

module RunpodOllamaFleet
  module ContractV01
    CAPABILITY_REQUEST_VERSION = "afio-rpof-capability-check-request/v0.1"
    CAPABILITY_REQUEST_V2_VERSION = "afio-rpof-capability-check-request/v0.2"
    CAPABILITY_RESULT_VERSION = "afio-rpof-capability-check-result/v0.1"
    DISPATCH_REQUEST_VERSION = "afio-rpof-dispatch-request/v0.1"
    DISPATCH_SUMMARY_VERSION = "afio-rpof-dispatch-summary/v0.1"
    EXECUTION_POOL_REQUEST_VERSION = "afio-rpof-execution-pool-fulfill-request/v0.1"
    EXECUTION_POOL_RESULT_VERSION = "afio-rpof-execution-pool-fulfill-result/v0.1"
    PRODUCTION_BURST_BUDGET_VERSION = "afio-production-burst-budget/v0.1"

    FLEET_KEY = /\A[A-Za-z0-9][A-Za-z0-9._-]{0,63}\z/
    JOB_ID = /\A[A-Za-z0-9][A-Za-z0-9._-]{0,127}\z/
    ENV_KEY = /\A[A-Za-z_][A-Za-z0-9_]*\z/
    DIGEST = /\A[0-9A-Fa-f]{64}\z/

    class Error < StandardError; end

    module_function

    def validate_capability_request!(document)
      object!(document, %w[contract_version fleet_key worker_selector requirements], [])
      version = document.fetch("contract_version")
      unless [CAPABILITY_REQUEST_VERSION, CAPABILITY_REQUEST_V2_VERSION].include?(version)
        raise Error,
              "unsupported contract_version #{version.inspect}; expected " \
              "#{CAPABILITY_REQUEST_VERSION.inspect} or #{CAPABILITY_REQUEST_V2_VERSION.inspect}"
      end
      string!(document, "fleet_key", pattern: FLEET_KEY, max: 64)

      selector = document.fetch("worker_selector")
      raise Error, "worker_selector must be an object" unless selector.is_a?(Hash)
      case selector["mode"]
      when "all"
        object!(selector, %w[mode], [])
      when "indices"
        object!(selector, %w[mode indices], [])
        positive_unique_integers!(selector.fetch("indices"), "worker_selector.indices")
      else
        raise Error, "worker_selector.mode must be all or indices"
      end

      requirements = document.fetch("requirements")
      object!(requirements, %w[models required_context_length require_fully_gpu_resident], %w[required_gpu_id])
      models = requirements.fetch("models")
      raise Error, "requirements.models must be a non-empty array" unless models.is_a?(Array) && !models.empty?
      models.each_with_index do |model, index|
        required = ["name"]
        optional = ["expected_digest"]
        if version == CAPABILITY_REQUEST_V2_VERSION
          required << "expected_digest"
          optional = []
        end
        object!(model, required, optional)
        string!(model, "name", max: 256)
        if version == CAPABILITY_REQUEST_V2_VERSION || model.key?("expected_digest")
          string!(model, "expected_digest", pattern: DIGEST, max: 64)
        end
      rescue Error => e
        raise Error, "requirements.models[#{index}]: #{e.message}"
      end
      positive_integer!(requirements.fetch("required_context_length"), "requirements.required_context_length")
      unless requirements.fetch("require_fully_gpu_resident") == true
        raise Error, "requirements.require_fully_gpu_resident must be true"
      end
      string!(requirements, "required_gpu_id", max: 256) if requirements.key?("required_gpu_id")
      document
    end

    def validate_execution_pool_request!(document)
      object!(document, %w[contract_version plan_sha256 pool_id requirements capacity], %w[budget])
      const!(document, "contract_version", EXECUTION_POOL_REQUEST_VERSION)
      string!(document, "plan_sha256", pattern: DIGEST, max: 64)
      string!(document, "pool_id", pattern: FLEET_KEY, max: 64)
      if document.key?("budget")
        validate_production_burst_budget!(document.fetch("budget"), expected_plan_sha256: document.fetch("plan_sha256"))
      end

      requirements = document.fetch("requirements")
      object!(
        requirements,
        %w[ollama_model pull_model expected_digest required_context_length require_fully_gpu_resident],
        []
      )
      string!(requirements, "ollama_model", max: 256)
      string!(requirements, "pull_model", max: 256)
      string!(requirements, "expected_digest", pattern: DIGEST, max: 64)
      positive_integer!(requirements.fetch("required_context_length"), "requirements.required_context_length")
      unless requirements.fetch("require_fully_gpu_resident") == true
        raise Error, "requirements.require_fully_gpu_resident must be true"
      end

      capacity = document.fetch("capacity")
      object!(
        capacity,
        %w[desired_workers minimum_workers max_pool_hourly_usd max_total_hourly_usd],
        []
      )
      desired = positive_integer!(capacity.fetch("desired_workers"), "capacity.desired_workers")
      minimum = positive_integer!(capacity.fetch("minimum_workers"), "capacity.minimum_workers")
      if minimum > desired
        raise Error, "capacity.minimum_workers cannot exceed capacity.desired_workers"
      end
      positive_number!(capacity.fetch("max_pool_hourly_usd"), "capacity.max_pool_hourly_usd")
      positive_number!(capacity.fetch("max_total_hourly_usd"), "capacity.max_total_hourly_usd")
      document
    end

    def validate_production_burst_budget!(budget, expected_plan_sha256:)
      object!(
        budget,
        %w[
          contract_version budget_id plan_sha256 max_cumulative_compute_usd
          max_runtime_seconds guardian_poll_seconds
          orchestrator_heartbeat_timeout_seconds teardown_reserve_seconds
        ],
        []
      )
      const!(budget, "contract_version", PRODUCTION_BURST_BUDGET_VERSION)
      string!(budget, "budget_id", max: 256)
      string!(budget, "plan_sha256", pattern: DIGEST, max: 64)
      unless budget.fetch("plan_sha256").downcase == expected_plan_sha256.to_s.downcase
        raise Error, "budget.plan_sha256 must match request plan_sha256"
      end

      positive_number!(budget.fetch("max_cumulative_compute_usd"), "budget.max_cumulative_compute_usd")
      positive_number!(budget.fetch("max_runtime_seconds"), "budget.max_runtime_seconds")
      guardian_poll = positive_number!(budget.fetch("guardian_poll_seconds"), "budget.guardian_poll_seconds")
      heartbeat_timeout = positive_number!(
        budget.fetch("orchestrator_heartbeat_timeout_seconds"),
        "budget.orchestrator_heartbeat_timeout_seconds"
      )
      positive_number!(budget.fetch("teardown_reserve_seconds"), "budget.teardown_reserve_seconds")
      if heartbeat_timeout < 2 * guardian_poll
        raise Error, "budget.orchestrator_heartbeat_timeout_seconds must be at least twice budget.guardian_poll_seconds"
      end
      budget
    end

    def validate_dispatch_request!(document)
      object!(document, %w[contract_version target group_by_affinity jobs], [])
      const!(document, "contract_version", DISPATCH_REQUEST_VERSION)
      target = document.fetch("target")
      object!(target, %w[fleet_key expected_fleet_id worker_indices], [])
      string!(target, "fleet_key", pattern: FLEET_KEY, max: 64)
      string!(target, "expected_fleet_id", max: 256)
      positive_unique_integers!(target.fetch("worker_indices"), "target.worker_indices")
      unless [true, false].include?(document.fetch("group_by_affinity"))
        raise Error, "group_by_affinity must be boolean"
      end
      jobs = document.fetch("jobs")
      raise Error, "jobs must be a non-empty array" unless jobs.is_a?(Array) && !jobs.empty?
      ids = {}
      jobs.each_with_index do |job, index|
        object!(job, %w[job_id argv], %w[env affinity])
        string!(job, "job_id", pattern: JOB_ID, max: 128)
        raise Error, "duplicate job_id #{job['job_id'].inspect}" if ids[job["job_id"]]
        ids[job["job_id"]] = true
        argv = job.fetch("argv")
        unless argv.is_a?(Array) && !argv.empty? && argv.all? { |value| value.is_a?(String) && !value.include?("\0") }
          raise Error, "jobs[#{index}].argv must be a non-empty string array without NUL bytes"
        end
        if job.key?("env")
          env = job.fetch("env")
          unless env.is_a?(Hash) && env.all? { |key, value| key.to_s.match?(ENV_KEY) && value.is_a?(String) }
            raise Error, "jobs[#{index}].env must map environment-variable names to strings"
          end
        end
        string!(job, "affinity", max: 256) if job.key?("affinity")
      end
      document
    end

    def object!(value, required, optional)
      raise Error, "value must be an object" unless value.is_a?(Hash)
      missing = required.reject { |key| value.key?(key) }
      raise Error, "missing required field(s): #{missing.join(', ')}" unless missing.empty?
      unknown = value.keys.map(&:to_s) - required - optional
      raise Error, "unknown field(s): #{unknown.sort.join(', ')}" unless unknown.empty?
    end

    def const!(object, key, expected)
      actual = object.fetch(key)
      raise Error, "unsupported #{key} #{actual.inspect}; expected #{expected.inspect}" unless actual == expected
    end

    def string!(object, key, pattern: nil, max: nil)
      value = object.fetch(key)
      raise Error, "#{key} must be a non-empty string" unless value.is_a?(String) && !value.empty?
      raise Error, "#{key} exceeds #{max} characters" if max && value.length > max
      raise Error, "#{key} has invalid format" if pattern && !value.match?(pattern)
      value
    end

    def positive_integer!(value, label)
      raise Error, "#{label} must be a positive integer" unless value.is_a?(Integer) && value.positive?
      value
    end

    def positive_number!(value, label)
      number = Float(value)
      raise Error, "#{label} must be a positive finite number" unless number.positive? && number.finite?
      number
    rescue ArgumentError, TypeError
      raise Error, "#{label} must be a positive finite number"
    end

    def positive_unique_integers!(values, label)
      unless values.is_a?(Array) && !values.empty? && values.all? { |value| value.is_a?(Integer) && value.positive? }
        raise Error, "#{label} must be a non-empty array of positive integers"
      end
      raise Error, "#{label} must be unique" unless values.uniq.length == values.length
      values
    end
  end
end
