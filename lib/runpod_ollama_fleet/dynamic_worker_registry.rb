# frozen_string_literal: true

require "digest"
require "fileutils"
require "json"
require "securerandom"
require "time"
require "uri"
require_relative "../local_model_evaluation/runpod_fleet_namespace"
require_relative "../local_model_evaluation/runpod_fleet_state"
require_relative "../local_model_evaluation/runpod_runtime_alias"
require_relative "../local_model_evaluation/runpod_tunnels"

module RunpodOllamaFleet
  class DynamicWorkerRegistry
    CONTRACT_VERSION = "dynamic-worker-registry/v0.1"
    DEFAULT_TTL_SECONDS = 30
    LABELS = %w[inference ollama remote].freeze
    DIGEST = /\A[0-9a-f]{64}\z/
    ID = /\A[A-Za-z0-9][A-Za-z0-9._-]{0,127}\z/
    PUBLISHER_STATE_FILE = "dynamic-worker-registry-v0.1-publisher.json"
    PUBLISHER_LOCK_FILE = ".dynamic-worker-registry-v0.1.lock"
    PUBLISHER_STATE_SCHEMA = 2
    CANONICAL_TIMESTAMP = /\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z\z/

    class Error < StandardError; end

    def initialize(state_root:, repo_root:, clock: nil, ttl_seconds: DEFAULT_TTL_SECONDS,
                   process_adapter: nil, health_checker: nil, fleet_sources: nil,
                   id_generator: nil)
      @state_root = File.expand_path(state_root)
      @repo_root = File.expand_path(repo_root)
      @clock = clock || -> { Time.now.utc }
      @ttl_seconds = positive_integer(ttl_seconds, "registry TTL seconds")
      @process = process_adapter || LocalModelEvaluation::RunpodTunnels::SystemProcessAdapter.new
      @health = health_checker || LocalModelEvaluation::RunpodTunnels::HttpHealthChecker.new
      @fleet_sources = fleet_sources
      @id_generator = id_generator || -> { "rpof-#{SecureRandom.hex(16)}" }
    end

    def snapshot
      workers = sources.flat_map { |source| workers_for(source) }
                       .sort_by { |worker| worker.fetch("worker_id") }
      identities = workers.map { |worker| worker.fetch("worker_id") }
      raise Error, "worker identities are not unique" unless identities.uniq.length == identities.length

      publish_snapshot(workers, utc_now)
    rescue LocalModelEvaluation::RunpodFleetNamespace::Error,
           LocalModelEvaluation::RunpodFleetState::Error => e
      raise Error, e.message
    end

    # Read-only diagnostics from the same provider-neutral evidence and READY
    # predicate used by #snapshot. This does not advance publisher state.
    def readiness_status
      workers = sources.flat_map { |source| readiness_for(source) }
                       .sort_by { |worker| [worker.fetch("fleet_key"), worker.fetch("index")] }
      states = %w[READY NOT_READY UNAVAILABLE].to_h do |state|
        [state, workers.count { |worker| worker["registry_state"] == state }]
      end
      {
        "status" => "available",
        "workers" => workers,
        "counts" => states.merge(
          "bootstrap_passed" => workers.count { |worker| worker.fetch("bootstrap_passed") },
          "capability_evidence_valid" => workers.count { |worker| worker.fetch("capability_evidence_valid") },
          "tunnel_established" => workers.count { |worker| worker.fetch("tunnel_established") },
          "registry_unpublished" => workers.count { |worker| worker["registry_state"].nil? }
        )
      }
    rescue LocalModelEvaluation::RunpodFleetNamespace::Error,
           LocalModelEvaluation::RunpodFleetState::Error => e
      raise Error, e.message
    end

    def self.capability_fingerprint(worker)
      capabilities = worker.fetch("capabilities")
      models = capabilities.dig("ollama", "models").map do |model|
        {
          "context_length" => model.fetch("context_length"),
          "digest" => model.fetch("digest"),
          "fully_gpu_resident" => model.fetch("fully_gpu_resident"),
          "model" => model.fetch("model")
        }
      end
      Digest::SHA256.hexdigest(JSON.generate(
        "gpu_id" => capabilities.fetch("gpu_id"),
        "labels" => worker.fetch("labels"),
        "ollama_models" => models
      ))
    end

    private

    def sources
      return @fleet_sources if @fleet_sources

      root = LocalModelEvaluation::RunpodFleetNamespace.new(
        root: @state_root,
        repo_root: @repo_root,
        fleet_key: LocalModelEvaluation::RunpodFleetNamespace::DEFAULT_KEY
      )
      keys = [LocalModelEvaluation::RunpodFleetNamespace::DEFAULT_KEY, *root.registered_fleet_keys].uniq.sort
      keys.map do |fleet_key|
        namespace = LocalModelEvaluation::RunpodFleetNamespace.new(
          root: root.root,
          repo_root: root.repo_root,
          fleet_key: fleet_key
        )
        state = LocalModelEvaluation::RunpodFleetState.new(
          root: namespace.state_root,
          local_port_base: namespace.local_port_base
        )
        { "fleet_key" => fleet_key, "state" => state }
      end
    end

    def workers_for(source)
      fleet_key = source.fetch("fleet_key").to_s
      state = source.fetch("state")
      fleet = state.current
      return [] unless fleet

      bootstrap = load_bootstrap(state, fleet)
      runtime_aliases = load_runtime_aliases(state, fleet)
      tunnels = load_tunnels(state, fleet)
      Array(fleet.fetch("workers")).filter_map do |worker|
        build_worker(state:, fleet:, worker:, bootstrap:, runtime_aliases:, tunnels:)
      end
    rescue JSON::ParserError, SystemCallError, KeyError, ArgumentError, TypeError => e
      raise Error, "invalid source state for fleet #{fleet_key.inspect}: #{e.message}"
    end

    def readiness_for(source)
      fleet_key = source.fetch("fleet_key").to_s
      state = source.fetch("state")
      fleet = state.current
      return [] unless fleet

      bootstrap = load_bootstrap(state, fleet)
      runtime_aliases = load_runtime_aliases(state, fleet)
      tunnels = load_tunnels(state, fleet)
      Array(fleet.fetch("workers")).map do |worker|
        index = positive_integer(worker.fetch("index"), "worker index")
        published = build_worker(state:, fleet:, worker:, bootstrap:, runtime_aliases:, tunnels:)
        models = capability_models(worker, worker_gpu_id(fleet, worker), bootstrap, runtime_aliases)
        tunnel = tunnels[index]
        {
          "fleet_key" => fleet_key,
          "index" => index,
          "pod_id" => nonempty(worker.fetch("pod_id"), "worker pod identity"),
          "bootstrap_passed" => bootstrap_passed?(bootstrap, worker),
          "capability_evidence_valid" => !models.empty?,
          "tunnel_established" => tunnel_established?(worker, tunnel),
          "registry_state" => published && published.fetch("state"),
          "worker_id" => published && published.fetch("worker_id"),
          "generation_id" => published && published.fetch("generation_id")
        }
      end
    rescue JSON::ParserError, SystemCallError, KeyError, ArgumentError, TypeError => e
      raise Error, "invalid source state for fleet #{fleet_key.inspect}: #{e.message}"
    end

    def bootstrap_passed?(bootstrap, worker)
      return false unless bootstrap

      evidence = Array(bootstrap.fetch("workers")).find do |candidate|
        Integer(candidate.fetch("index")) == Integer(worker.fetch("index")) &&
          candidate.fetch("pod_id").to_s == worker.fetch("pod_id").to_s &&
          candidate.fetch("worker_id").to_s == worker.fetch("worker_id").to_s &&
          candidate.fetch("generation_id").to_s == worker.fetch("generation_id").to_s
      rescue KeyError, ArgumentError, TypeError
        false
      end
      !!(evidence && evidence["status"] == "passed" && evidence["provenance_error"].nil? &&
        evidence["provenance"].is_a?(Hash))
    end

    def tunnel_established?(worker, tunnel)
      return false unless tunnel
      return false unless tunnel.fetch("pod_id").to_s == worker.fetch("pod_id").to_s
      return false unless tunnel.fetch("worker_id").to_s == worker.fetch("worker_id").to_s
      return false unless tunnel.fetch("generation_id").to_s == worker.fetch("generation_id").to_s
      return false unless valid_endpoint(tunnel.fetch("endpoint")) == valid_endpoint(worker.fetch("local_ollama_url"))

      pid = tunnel.fetch("pid")
      @process.alive?(pid) && @process.matches?(pid, tunnel.fetch("process_identity"))
    rescue KeyError, ArgumentError, TypeError, URI::InvalidURIError, Error
      false
    end

    def build_worker(state:, fleet:, worker:, bootstrap:, runtime_aliases:, tunnels:)
      index = positive_integer(worker.fetch("index"), "worker index")
      pod_id = nonempty(worker.fetch("pod_id"), "worker pod identity")
      gpu_id = worker_gpu_id(fleet, worker)
      models = capability_models(worker, gpu_id, bootstrap, runtime_aliases)
      return nil if models.empty?

      tunnel = tunnels[index]
      return nil unless tunnel

      endpoint = valid_endpoint(worker.fetch("local_ollama_url"))
      identity = state.registry_identity(
        index:,
        observed_pod_id: tunnel.fetch("pod_id")
      )
      record = {
        "worker_id" => identity.fetch("worker_id"),
        "generation_id" => identity.fetch("generation_id"),
        "endpoint" => endpoint,
        "state" => registry_state(fleet, worker, bootstrap, tunnels, endpoint, pod_id),
        "labels" => LABELS,
        "capabilities" => {
          "gpu_id" => gpu_id,
          "ollama" => { "models" => models }
        }
      }
      record["capability_fingerprint"] = self.class.capability_fingerprint(record)
      record
    end

    def capability_models(worker, gpu_id, bootstrap, runtime_aliases)
      rows = bootstrap_models(worker, gpu_id, bootstrap) + runtime_alias_models(worker, runtime_aliases)
      models = rows.uniq.sort_by do |row|
        [row.fetch("model"), row.fetch("digest"), row.fetch("context_length"), row.fetch("fully_gpu_resident") ? 1 : 0]
      end
      models.group_by { |row| row.fetch("model") }.each do |name, variants|
        raise Error, "ambiguous capability evidence for model #{name.inspect}" if variants.length > 1
      end
      models
    end

    def bootstrap_models(worker, gpu_id, bootstrap)
      return [] unless bootstrap

      evidence = Array(bootstrap.fetch("workers")).find do |candidate|
        Integer(candidate.fetch("index")) == Integer(worker.fetch("index")) &&
          candidate.fetch("pod_id").to_s == worker.fetch("pod_id").to_s &&
          candidate.fetch("worker_id").to_s == worker.fetch("worker_id").to_s &&
          candidate.fetch("generation_id").to_s == worker.fetch("generation_id").to_s
      rescue KeyError, ArgumentError, TypeError
        false
      end
      return [] unless evidence && evidence["status"] == "passed"
      return [] unless evidence["provenance_error"].nil?

      provenance = evidence.fetch("provenance")
      observed_gpu = provenance.dig("gpu", "name").to_s
      return [] if observed_gpu.empty?
      raise Error, "worker GPU identity conflicts with bootstrap evidence" unless observed_gpu == gpu_id

      expected_digests = bootstrap.fetch("expected_digests")
      context = positive_integer(bootstrap.fetch("context"), "bootstrap context")
      Array(bootstrap.fetch("models")).map do |name|
        model = nonempty(name, "bootstrap model")
        observed = provenance.fetch("models").fetch(model)
        capability_model(
          model:,
          digest: observed.fetch("digest"),
          context_length: observed.fetch("context_length"),
          fully_gpu_resident: observed.fetch("fully_gpu_resident"),
          size_bytes: observed.fetch("size_bytes"),
          size_vram_bytes: observed.fetch("size_vram_bytes"),
          expected_digest: expected_digests.fetch(model),
          expected_context: context
        )
      end
    rescue KeyError, ArgumentError, TypeError => e
      raise Error, "invalid bootstrap capability evidence: #{e.message}"
    end

    def runtime_alias_models(worker, aliases)
      return [] unless aliases

      Array(aliases.fetch("workers")).filter_map do |row|
        next unless Integer(row.fetch("worker_index")) == Integer(worker.fetch("index"))
        next unless row.fetch("pod_id").to_s == worker.fetch("pod_id").to_s

        capability_model(
          model: row.fetch("runtime_model"),
          digest: row.fetch("digest"),
          context_length: row.fetch("context_length"),
          fully_gpu_resident: row.fetch("fully_gpu_resident"),
          size_bytes: row.fetch("size_bytes"),
          size_vram_bytes: row.fetch("size_vram_bytes")
        )
      end
    rescue KeyError, ArgumentError, TypeError => e
      raise Error, "invalid runtime alias capability evidence: #{e.message}"
    end

    def capability_model(model:, digest:, context_length:, fully_gpu_resident:, size_bytes:, size_vram_bytes:,
                         expected_digest: nil, expected_context: nil)
      name = nonempty(model, "model identity")
      exact_digest = digest.to_s.downcase
      raise Error, "model #{name.inspect} has an invalid digest" unless exact_digest.match?(DIGEST)
      if expected_digest && exact_digest != expected_digest.to_s.downcase
        raise Error, "model #{name.inspect} digest evidence conflicts"
      end
      context = positive_integer(context_length, "model context length")
      if expected_context && context != Integer(expected_context)
        raise Error, "model #{name.inspect} context evidence conflicts"
      end
      size = positive_integer(size_bytes, "model size bytes")
      vram = positive_integer(size_vram_bytes, "model VRAM bytes")
      unless fully_gpu_resident == true && size == vram
        raise Error, "model #{name.inspect} is not proven fully GPU-resident"
      end

      {
        "model" => name,
        "digest" => exact_digest,
        "context_length" => context,
        "fully_gpu_resident" => true
      }
    end

    def registry_state(fleet, worker, bootstrap, tunnels, endpoint, pod_id)
      return "UNAVAILABLE" unless fleet["status"] == "active" && worker["status"] == "active"
      return "NOT_READY" unless bootstrap_ready?(bootstrap)

      tunnel = tunnels[Integer(worker.fetch("index"))]
      return "NOT_READY" unless tunnel
      return "NOT_READY" unless tunnel.fetch("pod_id").to_s == pod_id
      return "NOT_READY" unless tunnel.fetch("worker_id").to_s == worker.fetch("worker_id").to_s
      return "NOT_READY" unless tunnel.fetch("generation_id").to_s == worker.fetch("generation_id").to_s
      return "NOT_READY" unless valid_endpoint(tunnel.fetch("endpoint")) == endpoint

      pid = tunnel.fetch("pid")
      return "NOT_READY" unless @process.alive?(pid)
      return "NOT_READY" unless @process.matches?(pid, tunnel.fetch("process_identity"))

      health = @health.check(endpoint)
      health.respond_to?(:healthy) && health.healthy ? "READY" : "NOT_READY"
    rescue KeyError, ArgumentError, TypeError, URI::InvalidURIError
      "NOT_READY"
    end

    def bootstrap_ready?(bootstrap)
      bootstrap.nil? || bootstrap["status"] == "passed"
    end

    def load_bootstrap(state, fleet)
      root = state.artifact_dir(fleet.fetch("fleet_id"), "bootstrap")
      pointer = File.join(root, "current")
      return nil unless File.file?(pointer)

      run_id = File.read(pointer).strip
      unless run_id.match?(/\A[A-Za-z0-9_.-]+\z/) && !run_id.include?("..")
        raise Error, "bootstrap current pointer is invalid"
      end
      path = File.join(root, run_id, "bootstrap.json")
      raise Error, "bootstrap state is missing" unless File.file?(path)

      document = JSON.parse(File.read(path))
      raise Error, "bootstrap state belongs to a different fleet" unless document["fleet_id"] == fleet.fetch("fleet_id")
      document
    end

    def load_runtime_aliases(state, fleet)
      path = File.join(
        state.artifact_dir(fleet.fetch("fleet_id"), "runtime-alias"),
        LocalModelEvaluation::RunpodRuntimeAlias::EVIDENCE_FILE
      )
      return nil unless File.file?(path)

      document = JSON.parse(File.read(path))
      unless document["fleet_id"].to_s == fleet.fetch("fleet_id").to_s
        raise Error, "runtime alias evidence belongs to a different fleet"
      end
      document
    end

    def load_tunnels(state, fleet)
      path = File.join(
        state.artifact_dir(fleet.fetch("fleet_id"), "tunnels"),
        LocalModelEvaluation::RunpodTunnels::STATE_FILE
      )
      return {} unless File.file?(path)

      document = JSON.parse(File.read(path))
      raise Error, "tunnel state belongs to a different fleet" unless document["fleet_id"] == fleet.fetch("fleet_id")
      rows = Array(document.fetch("workers"))
      tunnels = rows.to_h do |row|
        [positive_integer(row.fetch("index"), "tunnel worker index"), row]
      end
      raise Error, "tunnel worker indices are not unique" unless tunnels.length == rows.length
      tunnels
    end

    def worker_gpu_id(fleet, worker)
      value = worker["gpu_id"].to_s.strip
      value = fleet.dig("gpu", "id").to_s.strip if value.empty?
      nonempty(value, "worker GPU identity", max: 256)
    end

    def valid_endpoint(value)
      uri = URI.parse(value.to_s)
      unless %w[http https].include?(uri.scheme) && uri.host && !uri.host.empty? &&
             uri.userinfo.nil? && uri.query.nil? && uri.fragment.nil? && ["", "/"].include?(uri.path.to_s)
        raise Error, "worker endpoint is invalid"
      end
      value.to_s.sub(%r{/\z}, "")
    rescue URI::InvalidURIError
      raise Error, "worker endpoint is invalid"
    end

    def publish_snapshot(workers, observed_at)
      published_at = Time.at(observed_at.to_i).utc
      FileUtils.mkdir_p(@state_root)
      File.open(File.join(@state_root, PUBLISHER_LOCK_FILE), File::RDWR | File::CREAT, 0o600) do |lock|
        lock.flock(File::LOCK_EX)
        state = load_publisher_state
        registry_id = state ? state.fetch("registry_id") : @id_generator.call.to_s
        raise Error, "publisher registry_id is invalid" unless registry_id.is_a?(String) && registry_id.match?(ID)

        if state && state.fetch("schema_version") == 1
          legacy_publication_floor = Time.at(File.mtime(publisher_state_path).to_i).utc
          unless published_at > legacy_publication_floor
            raise Error, "legacy publisher state cannot safely advance in the current second"
          end
        end
        if state && state.fetch("schema_version") == PUBLISHER_STATE_SCHEMA
          previous = state.fetch("snapshot")
          previous_time = Time.iso8601(previous.fetch("published_at"))
          raise Error, "publisher clock moved backwards" if published_at < previous_time
          return previous if published_at == previous_time
        end

        revision = state ? Integer(state.fetch("revision")) + 1 : 1
        raise Error, "publisher revision is invalid" unless revision.positive?

        snapshot = {
          "contract_version" => CONTRACT_VERSION,
          "registry_id" => registry_id,
          "revision" => revision,
          "published_at" => timestamp(published_at),
          "expires_at" => timestamp(published_at + @ttl_seconds),
          "workers" => workers
        }
        write_publisher_state(
          "schema_version" => PUBLISHER_STATE_SCHEMA,
          "registry_id" => registry_id,
          "revision" => revision,
          "snapshot_sha256" => Digest::SHA256.hexdigest(JSON.generate(snapshot)),
          "snapshot" => snapshot
        )
        snapshot
      end
    rescue JSON::ParserError, SystemCallError, KeyError, ArgumentError, TypeError => e
      raise Error, "could not advance registry publication: #{e.message}"
    end

    def load_publisher_state
      path = publisher_state_path
      return nil unless File.file?(path)

      state = JSON.parse(File.read(path))
      schema = state.fetch("schema_version")
      raise Error, "publisher state schema is invalid" unless [1, PUBLISHER_STATE_SCHEMA].include?(schema)
      return state if schema == 1

      validate_publisher_snapshot!(state)
      state
    end

    def validate_publisher_snapshot!(state)
      expected = %w[registry_id revision schema_version snapshot snapshot_sha256]
      raise Error, "publisher state fields are invalid" unless state.keys.sort == expected
      raise Error, "publisher registry_id is invalid" unless
        state.fetch("registry_id").is_a?(String) && state.fetch("registry_id").match?(ID)
      raise Error, "publisher revision is invalid" unless
        state.fetch("revision").is_a?(Integer) && state.fetch("revision").positive?

      snapshot = state.fetch("snapshot")
      snapshot_keys = %w[contract_version expires_at published_at registry_id revision workers]
      raise Error, "publisher snapshot fields are invalid" unless
        snapshot.is_a?(Hash) && snapshot.keys.sort == snapshot_keys
      raise Error, "publisher snapshot contract is invalid" unless
        snapshot.fetch("contract_version") == CONTRACT_VERSION
      raise Error, "publisher snapshot identity is invalid" unless
        snapshot.fetch("registry_id") == state.fetch("registry_id") &&
        snapshot.fetch("revision") == state.fetch("revision")
      %w[published_at expires_at].each do |field|
        raise Error, "publisher snapshot #{field} is not canonical" unless
          snapshot.fetch(field).is_a?(String) && snapshot.fetch(field).match?(CANONICAL_TIMESTAMP)
      end
      raise Error, "publisher snapshot workers are invalid" unless snapshot.fetch("workers").is_a?(Array)

      expected_digest = Digest::SHA256.hexdigest(JSON.generate(snapshot))
      raise Error, "publisher snapshot digest is invalid" unless
        state.fetch("snapshot_sha256") == expected_digest
      published_at = Time.iso8601(snapshot.fetch("published_at"))
      expires_at = Time.iso8601(snapshot.fetch("expires_at"))
      raise Error, "publisher snapshot expiry is invalid" unless expires_at > published_at
    end

    def write_publisher_state(document)
      path = publisher_state_path
      tmp = "#{path}.tmp.#{$$}.#{Thread.current.object_id}"
      File.write(tmp, JSON.generate(document) + "\n")
      File.chmod(0o600, tmp)
      File.rename(tmp, path)
    ensure
      File.delete(tmp) if defined?(tmp) && tmp && File.exist?(tmp)
    end

    def publisher_state_path
      File.join(@state_root, PUBLISHER_STATE_FILE)
    end

    def utc_now
      value = @clock.call
      value = Time.parse(value.to_s) unless value.is_a?(Time)
      value.utc
    rescue ArgumentError
      raise Error, "registry clock returned an invalid time"
    end

    def timestamp(value)
      value.utc.iso8601(0)
    end

    def nonempty(value, label, max: 256)
      text = value.to_s
      raise Error, "#{label} is empty" if text.empty?
      raise Error, "#{label} exceeds #{max} characters" if text.length > max
      text
    end

    def positive_integer(value, label)
      number = Integer(value)
      raise Error, "#{label} must be positive" unless number.positive?
      number
    rescue ArgumentError, TypeError
      raise Error, "#{label} must be a positive integer"
    end
  end
end
