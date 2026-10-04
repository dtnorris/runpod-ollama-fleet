# frozen_string_literal: true

require "fileutils"
require "json"
require "time"

module RunpodOllamaFleet
  # Durable state for the generation-bound bring-up reconciler. Superseded
  # generations remain available for audit but can never become current again.
  class WorkerBringupState
    CONTRACT_VERSION = "rpof-worker-bringup-state/v0.1"
    STAGES = %w[tunnel bootstrap capability].freeze
    STAGE_STATUSES = %w[
      not_started in_progress passed failed_retryable failed_terminal stale
    ].freeze

    class Error < StandardError; end

    def initialize(root:, clock: nil)
      @root = File.expand_path(root)
      @clock = clock || -> { Time.now.utc }
    end

    def with_current(identity)
      worker_root = File.join(@root, "worker-bringup-v0.1", identity.document.fetch("worker_id"))
      FileUtils.mkdir_p(worker_root)
      File.open(File.join(worker_root, ".lock"), File::RDWR | File::CREAT, 0o600) do |lock|
        lock.flock(File::LOCK_EX)
        retire_previous(worker_root, identity)
        path = state_path(worker_root, identity.sha256)
        state = File.file?(path) ? load_state(path, identity) : initial_state(identity)
        yield state, -> { write_state(path, state) }
        write_state(path, state)
        write_atomic(File.join(worker_root, "current"), "#{identity.sha256}\n")
        deep_copy(state)
      end
    rescue JSON::ParserError, SystemCallError, KeyError, ArgumentError, TypeError => e
      raise Error, "could not reconcile worker bring-up state: #{e.message}"
    end

    def read_current(worker_id:)
      identity = worker_id.to_s
      unless identity.match?(/\A[A-Za-z0-9][A-Za-z0-9._-]{0,127}\z/)
        raise Error, "worker identity has invalid syntax"
      end

      worker_root = File.join(@root, "worker-bringup-v0.1", identity)
      pointer = File.join(worker_root, "current")
      return nil unless File.file?(pointer)

      File.open(File.join(worker_root, ".lock"), File::RDWR | File::CREAT, 0o600) do |lock|
        lock.flock(File::LOCK_SH)
        sha256 = File.binread(pointer).strip
        raise Error, "worker bring-up current pointer is invalid" unless sha256.match?(/\A[0-9a-f]{64}\z/)

        path = state_path(worker_root, sha256)
        raise Error, "worker bring-up current state is missing" unless File.file?(path)

        state = JSON.parse(File.binread(path))
        validate_shape!(state)
        unless state.fetch("identity_sha256") == sha256
          raise Error, "worker bring-up current pointer does not match retained identity"
        end
        deep_copy(state)
      end
    rescue JSON::ParserError, SystemCallError, KeyError, ArgumentError, TypeError => e
      raise Error, "could not read worker bring-up state: #{e.message}"
    end

    private

    def retire_previous(worker_root, identity)
      pointer = File.join(worker_root, "current")
      return unless File.file?(pointer)

      previous_sha = File.binread(pointer).strip
      return if previous_sha == identity.sha256
      unless previous_sha.match?(/\A[0-9a-f]{64}\z/)
        raise Error, "worker bring-up current pointer is invalid"
      end

      path = state_path(worker_root, previous_sha)
      raise Error, "worker bring-up current state is missing" unless File.file?(path)
      previous = JSON.parse(File.binread(path))
      validate_shape!(previous)
      previous_generation = Integer(previous.dig("identity", "worker_generation"))
      requested_generation = Integer(identity.document.fetch("worker_generation"))
      if requested_generation < previous_generation
        raise Error, "refusing to reactivate superseded worker generation"
      end
      if requested_generation == previous_generation
        raise Error, "retained worker generation conflicts with requested bring-up identity"
      end
      previous["overall_status"] = "stale"
      previous["superseded_at_utc"] ||= timestamp
      STAGES.each do |stage|
        previous.fetch(stage)["status"] = "stale"
        previous.fetch(stage)["updated_at_utc"] = timestamp
      end
      previous["updated_at_utc"] = timestamp
      write_state(path, previous)
    end

    def initial_state(identity)
      now = timestamp
      stage = -> { { "status" => "not_started", "updated_at_utc" => now, "evidence" => nil } }
      {
        "contract_version" => CONTRACT_VERSION,
        "identity_sha256" => identity.sha256,
        "identity" => identity.document,
        # Historical v0.1 field name. The nested contract_version identifies
        # whether these exact retained bytes are generic or legacy.
        "model_requirement" => identity.capability_request.document,
        "overall_status" => "not_started",
        "readiness_prerequisites_satisfied" => false,
        "created_at_utc" => now,
        "updated_at_utc" => now,
        "superseded_at_utc" => nil,
        "tunnel" => stage.call,
        "bootstrap" => stage.call.merge("attempt" => nil),
        "capability" => stage.call
      }
    end

    def load_state(path, identity)
      state = JSON.parse(File.binread(path))
      validate_shape!(state)
      unless state.fetch("identity_sha256") == identity.sha256 && state.fetch("identity") == identity.document &&
             state.fetch("model_requirement") == identity.capability_request.document
        raise Error, "retained worker bring-up state identity does not match requested generation"
      end
      state
    end

    def validate_shape!(state)
      unless state.fetch("contract_version") == CONTRACT_VERSION
        raise Error, "worker bring-up state contract is unsupported"
      end
      STAGES.each do |stage|
        status = state.fetch(stage).fetch("status")
        raise Error, "worker bring-up #{stage} status is invalid" unless STAGE_STATUSES.include?(status)
      end
      state
    end

    def state_path(worker_root, sha256)
      File.join(worker_root, "#{sha256}.json")
    end

    def write_state(path, state)
      state["updated_at_utc"] = timestamp
      write_atomic(path, JSON.pretty_generate(state) + "\n")
    end

    def write_atomic(path, bytes)
      temporary = "#{path}.tmp.#{$$}.#{Thread.current.object_id}"
      File.open(temporary, File::WRONLY | File::CREAT | File::TRUNC, 0o600) do |file|
        file.write(bytes)
        file.flush
        file.fsync
      end
      File.rename(temporary, path)
    ensure
      File.delete(temporary) if defined?(temporary) && temporary && File.exist?(temporary)
    end

    def timestamp
      value = @clock.call
      value = Time.parse(value.to_s) unless value.is_a?(Time)
      value.utc.iso8601
    end

    def deep_copy(value)
      JSON.parse(JSON.generate(value))
    end
  end
end
