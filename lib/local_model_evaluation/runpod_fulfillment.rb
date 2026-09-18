# frozen_string_literal: true

require_relative "runpod_capacity_policy"

module LocalModelEvaluation
  class RunpodFulfillment
    class Error < StandardError; end
    class CandidateUnavailable < Error; end

    Attempt = Struct.new(:gpu_id, :hourly_rate_usd, :status, :detail, keyword_init: true)
    Result = Struct.new(
      :status,
      :target_workers,
      :minimum_workers,
      :initial_workers,
      :final_workers,
      :attempts,
      :stopped_reason,
      keyword_init: true
    )

    CAPACITY_ERROR = /(capacity|availability|not available|catalog did not return|out of stock|insufficient stock|timed out waiting for RunPod SSH endpoints|entered terminal status|readiness ended)/i

    def self.capacity_error?(error)
      error.message.to_s.match?(CAPACITY_ERROR)
    end

    def initialize(capacity_policy:, out: $stdout)
      @capacity_policy = capacity_policy
      @out = out
    end

    def run(target_workers:, minimum_workers:, gpu_ids:, cloud:, current_workers:,
            expected_current_workers: nil, max_hourly_per_worker_usd: nil, dry_run: false, &provision_one)
      target = positive_integer(target_workers, "target workers")
      minimum = positive_integer(minimum_workers, "minimum workers")
      current = nonnegative_integer(current_workers, "current workers")
      expected = expected_current_workers.nil? ? nil : nonnegative_integer(expected_current_workers, "expected current workers")
      if !expected.nil? && current != expected
        raise Error, "current workers #{current} do not match expected #{expected}; refusing capacity mutation"
      end
      raise Error, "minimum workers cannot exceed target workers" if minimum > target
      raise Error, "current workers cannot exceed target workers" if current > target
      raise Error, "provision callback is required" unless dry_run || provision_one

      initial = current
      attempts = []
      stopped_reason = nil

      if dry_run
        ranking = ranking_for(
          gpu_ids:,
          cloud:,
          max_hourly_per_worker_usd:
        )
        status = ranking.candidates.empty? ? "unavailable" : "planned"
        reason = if ranking.candidates.empty?
                   "no qualified GPU candidate is currently available within policy"
                 else
                   "would try qualified candidates cheapest-first, one durable worker at a time"
                 end
        return Result.new(
          status:,
          target_workers: target,
          minimum_workers: minimum,
          initial_workers: initial,
          final_workers: current,
          attempts:,
          stopped_reason: reason
        )
      end

      while current < target
        ranking = ranking_for(
          gpu_ids:,
          cloud:,
          max_hourly_per_worker_usd:
        )
        if ranking.candidates.empty?
          stopped_reason = "no qualified GPU candidate is currently available within policy"
          break
        end

        advanced = false
        ranking.candidates.each do |candidate|
          @out.puts format(
            "Fulfillment attempt: %s at $%.4f/hr (%s)",
            candidate.gpu_id,
            candidate.hourly_rate_usd,
            candidate.availability
          )
          begin
            next_count = Integer(provision_one.call(candidate))
            unless next_count == current + 1
              raise Error,
                    "provision callback must add exactly one worker: expected #{current + 1}, got #{next_count}"
            end
            attempts << Attempt.new(
              gpu_id: candidate.gpu_id,
              hourly_rate_usd: candidate.hourly_rate_usd,
              status: "provisioned",
              detail: "worker count #{current} -> #{next_count}"
            )
            current = next_count
            advanced = true
            break
          rescue CandidateUnavailable => e
            attempts << Attempt.new(
              gpu_id: candidate.gpu_id,
              hourly_rate_usd: candidate.hourly_rate_usd,
              status: "unavailable",
              detail: e.message
            )
            @out.puts "Candidate unavailable: #{candidate.gpu_id}: #{e.message}"
          end
        end

        unless advanced
          stopped_reason = "all currently qualified candidates failed capacity acquisition"
          break
        end
      end

      status = if current >= target
                 "fulfilled"
               elsif current >= minimum
                 "minimum_met"
               else
                 "unfulfilled"
               end
      stopped_reason ||= "target worker count reached" if status == "fulfilled"
      stopped_reason ||= "minimum useful capacity retained; target not reached" if status == "minimum_met"
      stopped_reason ||= "minimum useful capacity was not reached"

      Result.new(
        status:,
        target_workers: target,
        minimum_workers: minimum,
        initial_workers: initial,
        final_workers: current,
        attempts:,
        stopped_reason:
      )
    end

    private

    def ranking_for(gpu_ids:, cloud:, max_hourly_per_worker_usd:)
      @capacity_policy.rank(
        gpu_ids:,
        cloud:,
        max_hourly_per_worker_usd:
      )
    rescue RunpodCapacityPolicy::Error => e
      raise Error, e.message
    end

    def positive_integer(value, label)
      number = Integer(value)
      raise ArgumentError unless number.positive?
      number
    rescue ArgumentError, TypeError
      raise Error, "#{label} must be a positive integer"
    end

    def nonnegative_integer(value, label)
      number = Integer(value)
      raise ArgumentError if number.negative?
      number
    rescue ArgumentError, TypeError
      raise Error, "#{label} must be a nonnegative integer"
    end
  end
end
