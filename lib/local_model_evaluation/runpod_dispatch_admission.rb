# frozen_string_literal: true

require "fileutils"
require "json"
require "time"
require_relative "runpod_workers"

module LocalModelEvaluation
  # Output-scoped control channel for admitting already-prepared workers into
  # one running generic dispatch. Provisioning/readiness remains outside this
  # class; callers must admit only workers that have completed the execution
  # preparation contract.
  class RunpodDispatchAdmission
    SCHEMA_VERSION = 1
    STATE_FILE = "admission-control.json"
    EVENTS_FILE = "worker-admissions.jsonl"
    LOCK_FILE = ".admission.lock"

    class Error < StandardError; end

    def initialize(output_dir:, fleet_state:, fleet_key:, wall_clock: nil)
      @output_dir = File.expand_path(output_dir)
      @fleet_state = fleet_state
      @fleet_key = fleet_key.to_s
      @wall_clock = wall_clock || -> { Time.now.utc }
    end

    attr_reader :output_dir

    def open!(fleet_id:, initial_worker_indices:)
      fleet_id = nonempty(fleet_id, "fleet id")
      initial = normalize_indices(initial_worker_indices, "initial worker indices")

      with_lock do
        FileUtils.mkdir_p(output_dir)
        document = if File.file?(state_path)
                     existing = read_state!
                     validate_identity!(existing, fleet_id:, initial_worker_indices: initial)
                     existing.merge(
                       "status" => "open",
                       "reopened_at_utc" => utc_now.iso8601,
                       "closed_at_utc" => nil
                     )
                   else
                     {
                       "schema_version" => SCHEMA_VERSION,
                       "fleet_key" => @fleet_key,
                       "fleet_id" => fleet_id,
                       "status" => "open",
                       "created_at_utc" => utc_now.iso8601,
                       "closed_at_utc" => nil,
                       "initial_worker_indices" => initial,
                       "admitted_worker_indices" => []
                     }
                   end
        write_json_atomic(state_path, document)
        FileUtils.touch(events_path)
        document
      end
    end

    def admit!(worker_index:)
      index = normalize_index(worker_index)

      with_lock do
        state = read_state!
        raise Error, "dispatch admission is closed" unless state.fetch("status") == "open"

        fleet = active_fleet!(expected_fleet_id: state.fetch("fleet_id"))
        worker = Array(fleet.fetch("workers")).find do |candidate|
          Integer(candidate.fetch("index")) == index
        rescue KeyError, ArgumentError, TypeError
          false
        end
        raise Error, "current fleet does not contain burst_#{index}" unless worker
        raise Error, "burst_#{index} is not active" unless worker["status"] == "active"

        initial = normalize_indices(state.fetch("initial_worker_indices"), "initial worker indices")
        admitted = normalize_indices(state.fetch("admitted_worker_indices", []), "admitted worker indices", allow_empty: true)
        if initial.include?(index) || admitted.include?(index)
          return {
            "status" => "already_admitted",
            "fleet_id" => state.fetch("fleet_id"),
            "worker_index" => index
          }
        end

        event = {
          "schema_version" => SCHEMA_VERSION,
          "status" => "admitted",
          "fleet_id" => state.fetch("fleet_id"),
          "worker_index" => index,
          "pod_id" => worker.fetch("pod_id").to_s,
          "local_ollama_url" => nonempty(worker.fetch("local_ollama_url"), "burst_#{index} local Ollama URL"),
          "admitted_at_utc" => utc_now.iso8601
        }
        File.open(events_path, "a", 0o600) do |file|
          file.write(JSON.generate(event) + "\n")
          file.flush
          file.fsync
        end
        state["admitted_worker_indices"] = (admitted + [index]).uniq.sort
        state["updated_at_utc"] = utc_now.iso8601
        write_json_atomic(state_path, state)
        event
      end
    rescue KeyError, ArgumentError, TypeError => e
      raise Error, "invalid dispatch admission state: #{e.message}"
    end

    def close!
      with_lock do
        return nil unless File.file?(state_path)

        state = read_state!
        return state if state.fetch("status") == "closed"

        state["status"] = "closed"
        state["closed_at_utc"] = utc_now.iso8601
        write_json_atomic(state_path, state)
        state
      end
    end

    def open?
      with_lock do
        return false unless File.file?(state_path)
        read_state!.fetch("status") == "open"
      end
    rescue KeyError
      false
    end

    def events
      with_lock do
        return [] unless File.file?(events_path)

        state = read_state!
        File.readlines(events_path, chomp: true).reject(&:empty?).map.with_index do |line, index|
          event = JSON.parse(line)
          unless event.is_a?(Hash) && event["schema_version"] == SCHEMA_VERSION
            raise Error, "worker admission event #{index + 1} has unsupported schema"
          end
          unless event["fleet_id"].to_s == state.fetch("fleet_id").to_s
            raise Error, "worker admission event #{index + 1} belongs to a different fleet"
          end
          normalize_index(event.fetch("worker_index"))
          event
        end
      end
    rescue JSON::ParserError, KeyError => e
      raise Error, "worker admission evidence is invalid: #{e.message}"
    end

    private

    def active_fleet!(expected_fleet_id:)
      fleet = @fleet_state.current
      raise Error, "no current active RunPod fleet exists" unless fleet && fleet["status"] == "active"
      unless fleet.fetch("fleet_id").to_s == expected_fleet_id.to_s
        raise Error,
              "active fleet id changed: expected #{expected_fleet_id}, got #{fleet.fetch('fleet_id')}"
      end
      fleet
    rescue KeyError => e
      raise Error, "invalid current fleet state: #{e.message}"
    end

    def validate_identity!(state, fleet_id:, initial_worker_indices:)
      unless state.is_a?(Hash) && state["schema_version"] == SCHEMA_VERSION
        raise Error, "existing dispatch admission control has unsupported schema"
      end
      unless state["fleet_key"].to_s == @fleet_key && state["fleet_id"].to_s == fleet_id.to_s
        raise Error, "existing dispatch admission control belongs to a different fleet"
      end
      existing = normalize_indices(state.fetch("initial_worker_indices"), "initial worker indices")
      unless existing == initial_worker_indices
        raise Error, "existing dispatch admission control uses different initial workers"
      end
      true
    end

    def read_state!
      raise Error, "dispatch admission control is not initialized: #{state_path}" unless File.file?(state_path)
      document = JSON.parse(File.read(state_path))
      raise Error, "dispatch admission control must be an object" unless document.is_a?(Hash)
      unless document["fleet_key"].to_s == @fleet_key
        raise Error, "dispatch admission control belongs to a different fleet key"
      end
      document
    rescue JSON::ParserError, SystemCallError => e
      raise Error, "dispatch admission control is unreadable: #{e.message}"
    end

    def normalize_indices(values, label, allow_empty: false)
      indices = Array(values).map { |value| normalize_index(value) }.uniq.sort
      raise Error, "#{label} cannot be empty" if indices.empty? && !allow_empty
      indices
    end

    def normalize_index(value)
      RunpodWorkers.validate_index(value)
    rescue RunpodWorkers::Error => e
      raise Error, e.message
    end

    def nonempty(value, label)
      text = value.to_s.strip
      raise Error, "#{label} cannot be empty" if text.empty?
      text
    end

    def with_lock
      FileUtils.mkdir_p(output_dir)
      File.open(lock_path, File::RDWR | File::CREAT, 0o600) do |lock|
        lock.flock(File::LOCK_EX)
        yield
      ensure
        lock.flock(File::LOCK_UN) rescue nil
      end
    end

    def write_json_atomic(path, document)
      tmp = "#{path}.tmp.#{$$}.#{Thread.current.object_id}"
      File.write(tmp, JSON.pretty_generate(document) + "\n")
      File.chmod(0o600, tmp)
      File.rename(tmp, path)
    ensure
      File.delete(tmp) if defined?(tmp) && tmp && File.exist?(tmp)
    end

    def state_path = File.join(output_dir, STATE_FILE)
    def events_path = File.join(output_dir, EVENTS_FILE)
    def lock_path = File.join(output_dir, LOCK_FILE)

    def utc_now
      value = @wall_clock.call
      value = Time.parse(value.to_s) unless value.is_a?(Time)
      value.utc
    rescue ArgumentError
      raise Error, "dispatch admission clock returned invalid time: #{value.inspect}"
    end
  end
end
