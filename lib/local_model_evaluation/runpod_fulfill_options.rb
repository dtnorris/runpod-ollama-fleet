# frozen_string_literal: true

require "optparse"

module LocalModelEvaluation
  module RunpodFulfillOptions
    BUDGET_KEYS = %i[
      budget_id budget_plan_sha256 budget_max_cumulative_compute_usd budget_max_runtime_seconds
      budget_guardian_poll_seconds budget_orchestrator_heartbeat_timeout_seconds budget_teardown_reserve_seconds
    ].freeze

    module_function

    def validate!(opts, remaining_args)
      raise OptionParser::InvalidArgument, "unexpected arguments: #{remaining_args.join(' ')}" unless remaining_args.empty?
      raise OptionParser::MissingArgument, "--target-workers" unless opts[:target_workers]
      raise OptionParser::MissingArgument, "--minimum-workers" unless opts[:minimum_workers]
      raise OptionParser::MissingArgument, "--gpu" if opts[:gpu_ids].empty?
      raise OptionParser::MissingArgument, "--max-hourly-per-worker" unless opts[:max_hourly_per_worker_usd]

      if opts[:expect_initial_workers] && opts[:expect_initial_workers].negative?
        raise OptionParser::InvalidArgument, "--expect-initial-workers must be non-negative"
      end
      if opts[:network_volume_id] && opts[:volume_gb]
        raise OptionParser::InvalidArgument, "--network-volume-id cannot be combined with --volume-gb"
      end
      if opts[:global_volume_id] && opts[:volume_gb]
        raise OptionParser::InvalidArgument, "--global-volume-id cannot be combined with --volume-gb"
      end

      supplied_budget_keys = BUDGET_KEYS.select { |key| !opts[key].nil? }
      if supplied_budget_keys.any? && supplied_budget_keys.length != BUDGET_KEYS.length
        raise OptionParser::InvalidArgument, "parent burst budget options must be supplied together"
      end
      if supplied_budget_keys.any? && (opts[:max_runtime_seconds] || opts[:max_spend_usd])
        raise OptionParser::InvalidArgument,
              "parent burst budget derives the child fleet runtime/spend lease; " \
              "do not combine budget options with --max-runtime-minutes or --max-spend-usd"
      end
      if opts[:yes] && !opts[:dry_run] && supplied_budget_keys.empty?
        raise OptionParser::MissingArgument,
              "parent burst budget options are required for non-interactive paid fulfillment"
      end

      true
    end
  end
end
