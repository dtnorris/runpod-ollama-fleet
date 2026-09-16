# frozen_string_literal: true

require "minitest/autorun"
require "stringio"
require "tmpdir"
require_relative "../lib/local_model_evaluation/runpod_fleet"

class RunpodFleetVerifiedDestroyTest < Minitest::Test
  class FakeClient
    attr_reader :events

    def initialize
      @events = []
      @remaining_observations = 2
    end

    def list_pods
      @events << :list
      return [] if @deleted && (@remaining_observations -= 1) < 0
      [{ "id" => "pod_1", "name" => "burst_1" }]
    end

    def delete_pod(id)
      @events << [:delete, id]
      @deleted = true
    end
  end

  class FakeState
    attr_reader :calls
    def initialize(events); @events = events; @calls = []; end
    def mark_destroyed(indices, reason: nil)
      @events << :state
      @calls << [indices, reason]
      { "status" => "destroyed" }
    end
  end

  class TestFleet < LocalModelEvaluation::RunpodFleet
    def install_state(state)
      @fleet_state = state
    end

    private

    def worker_name(index) = "burst_#{index}"
    def validate_worker_index(index) = index
    def env_key(index, suffix) = "IGNORED_#{index}_#{suffix}"
    def resolve_pod_for_destroy(index, _pod_id, live_pods)
      live_pods.find { |pod| pod["name"] == worker_name(index) }
    end
    def remove_worker_env(_indices, clear_fleet:) = clear_fleet
    def with_fleet_state = yield
  end

  def test_verified_destroy_does_not_mark_state_until_provider_absence_is_observed
    Dir.mktmpdir("verified-destroy-") do |dir|
      env = File.join(dir, ".env")
      File.write(env, "")
      client = FakeClient.new
      now = 0.0
      fleet = TestFleet.new(
        client: client,
        env_path: env,
        out: StringIO.new,
        state_root: File.join(dir, "state"),
        clock: -> { now },
        sleeper: ->(seconds) { now += seconds }
      )
      state = FakeState.new(client.events)
      fleet.install_state(state)

      cleared = fleet.destroy(
        worker_indices: [1],
        verify_absent: true,
        destroy_reason: "campaign_terminal",
        verify_wait_seconds: 10,
        verify_poll_seconds: 1
      )

      assert_equal [1], cleared
      assert_equal [[[1], "campaign_terminal"]], state.calls
      assert_operator client.events.index(:state), :>, client.events.index([:delete, "pod_1"])
      assert_operator client.events.count(:list), :>=, 3
    end
  end
end
