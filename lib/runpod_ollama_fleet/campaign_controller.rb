# frozen_string_literal: true

require "fileutils"
require "json"
require "thread"
require "time"

module RunpodOllamaFleet
  # Continuing owner of ordinary campaign heartbeats and reconciliation. It
  # cannot arm, widen, close, or tear down the parent budget.
  class CampaignController
    CONTRACT_VERSION = "rpof-campaign-controller-runtime/v0.1"
    MAX_LOG_BYTES = 262_144

    class Error < StandardError; end

    def initialize(binding:, lifecycle:, state_path:, enabled_path:, log_path:, generation_id:,
                   heartbeat_seconds:, ssh_public_key_path:, wall_clock: nil, sleeper: nil,
                   pid: Process.pid)
      @binding = binding
      @lifecycle = lifecycle
      @state_path = File.expand_path(state_path)
      @enabled_path = File.expand_path(enabled_path)
      @log_path = File.expand_path(log_path)
      @generation_id = generation_id.to_s
      @heartbeat_seconds = Float(heartbeat_seconds)
      @ssh_public_key_path = ssh_public_key_path
      @wall_clock = wall_clock || -> { Time.now.utc }
      @sleeper = sleeper || ->(seconds) { sleep(seconds) }
      @pid = Integer(pid)
      raise Error, "controller heartbeat interval must be positive" unless @heartbeat_seconds.positive?
      raise Error, "controller generation is required" if @generation_id.empty?
    rescue ArgumentError, TypeError => e
      raise Error, e.message
    end

    def run
      started = utc_now.iso8601
      persist(runtime_document("RUNNING", started_at: started, last_action: "startup"))
      log("startup")
      loop do
        break stop("supervision_disabled", started) unless File.file?(@enabled_path)
        break stop("teardown_in_progress", started) unless tick(started)
        @sleeper.call(@heartbeat_seconds)
      end
      0
    rescue StandardError => e
      File.delete(@enabled_path) if File.file?(@enabled_path)
      persist(runtime_document("ERROR", started_at: started, last_action: "error", last_error: e.message))
      log("error: #{e.class}: #{e.message}")
      1
    end

    def tick(started_at = nil)
      ledger = @binding.parent_budget.evaluate!
      return false unless ledger.fetch("state") == "ARMED" && ledger.fetch("mutation_allowed") == true

      heartbeat = @binding.parent_budget.heartbeat!(source: "orchestrator")
      persist(runtime_document(
        "RUNNING", started_at:, last_heartbeat_at: heartbeat.fetch("last_orchestrator_heartbeat_at_utc"),
        last_action: "reconciling", last_error: nil
      ))
      result = reconcile_with_heartbeats(started_at:) do
        @lifecycle.reconcile_once(ssh_public_key_path: @ssh_public_key_path)
      end
      actions = result.fetch("profiles").map { |row| "#{row.fetch('profile_id')}:#{row.fetch('action')}" }
      now = utc_now.iso8601
      persist(runtime_document(
        "RUNNING", started_at:, last_reconciliation_at: now,
        last_action: actions.join(","), last_error: nil
      ))
      log("reconcile #{actions.join(' ')}")
      true
    rescue CampaignLifecycle::TransientReconciliationError => e
      now = utc_now.iso8601
      persist(runtime_document(
        "RUNNING", started_at:, last_reconciliation_at: now,
        last_action: "reconciliation_error", last_error: e.message
      ))
      log("reconciliation_error: #{e.message}")
      true
    end

    private

    def reconcile_with_heartbeats(started_at:)
      mutex = Mutex.new
      condition = ConditionVariable.new
      stopped = false
      heartbeat_error = nil

      heartbeat_thread = Thread.new do
        loop do
          should_stop = mutex.synchronize do
            if stopped
              true
            else
              condition.wait(mutex, @heartbeat_seconds)
              stopped
            end
          end
          break if should_stop

          begin
            heartbeat = @binding.parent_budget.heartbeat!(source: "orchestrator")
            persist(runtime_document(
              "RUNNING", started_at:,
              last_heartbeat_at: heartbeat.fetch("last_orchestrator_heartbeat_at_utc"),
              last_action: "reconciling", last_error: nil
            ))
          rescue StandardError => e
            heartbeat_error = e
            break
          end
        end
      end

      result = yield
      raise heartbeat_error if heartbeat_error

      result
    ensure
      if defined?(mutex) && mutex && defined?(condition) && condition
        mutex.synchronize do
          stopped = true
          condition.broadcast
        end
      end
      heartbeat_thread&.join
    end

    def stop(reason, started_at)
      persist(runtime_document("STOPPED", started_at:, last_action: reason))
      log("stop #{reason}")
      false
    end

    def runtime_document(state, started_at:, last_heartbeat_at: nil,
                         last_reconciliation_at: nil, last_action: nil, last_error: nil)
      previous = read_state
      {
        "contract_version" => CONTRACT_VERSION,
        "campaign_id" => @binding.campaign.campaign_id,
        "campaign_identity_sha256" => @binding.campaign.identity_sha256,
        "binding_sha256" => @binding.binding_sha256,
        "budget_id" => @binding.declaration.fetch("budget_id"),
        "generation_id" => @generation_id,
        "pid" => @pid,
        "state" => state,
        "started_at_utc" => started_at || previous["started_at_utc"] || utc_now.iso8601,
        "original_deadline_at_utc" => original_deadline(previous),
        "last_heartbeat_at_utc" => last_heartbeat_at || previous["last_heartbeat_at_utc"],
        "last_reconciliation_at_utc" => last_reconciliation_at || previous["last_reconciliation_at_utc"],
        "last_action" => last_action || previous["last_action"],
        "last_error" => last_error
      }
    end

    def read_state
      File.file?(@state_path) ? JSON.parse(File.read(@state_path)) : {}
    rescue JSON::ParserError, SystemCallError
      {}
    end

    def original_deadline(previous)
      @binding.parent_budget.status["deadline_at_utc"] || previous["original_deadline_at_utc"]
    rescue LocalModelEvaluation::RunpodBudget::Error
      previous["original_deadline_at_utc"]
    end

    def persist(document)
      FileUtils.mkdir_p(File.dirname(@state_path))
      tmp = "#{@state_path}.tmp.#{$$}.#{Thread.current.object_id}"
      File.write(tmp, JSON.pretty_generate(document) + "\n")
      File.chmod(0o600, tmp)
      File.rename(tmp, @state_path)
    ensure
      File.delete(tmp) if defined?(tmp) && tmp && File.exist?(tmp)
    end

    def log(message)
      FileUtils.mkdir_p(File.dirname(@log_path))
      File.open(@log_path, "a", 0o600) { |file| file.puts("#{utc_now.iso8601} #{message}") }
      return unless File.size(@log_path) > MAX_LOG_BYTES

      bytes = File.binread(@log_path)
      File.binwrite(@log_path, bytes.byteslice(-MAX_LOG_BYTES / 2, MAX_LOG_BYTES / 2))
    end

    def utc_now
      value = @wall_clock.call
      value = Time.parse(value.to_s) unless value.is_a?(Time)
      value.utc
    end
  end
end
