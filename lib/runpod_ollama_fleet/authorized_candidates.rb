# frozen_string_literal: true

require_relative "../local_model_evaluation/runpod_capacity_policy"

module RunpodOllamaFleet
  # Shared FO-15 catalog qualification and cheap-first ordering. No state writes.
  module AuthorizedCandidates
    def self.observe(client:, gpu_ids:, cloud:)
      ranking = LocalModelEvaluation::RunpodCapacityPolicy.new(client: client).rank(
        gpu_ids: gpu_ids,
        cloud: cloud
      )
      rows = ranking.candidates.map do |candidate|
        {
          "gpu_id" => candidate.gpu_id,
          "cloud" => ranking.cloud,
          "hourly_rate_usd" => candidate.hourly_rate_usd,
          "eligible" => true,
          "reason" => nil
        }
      end
      rows.concat(ranking.rejections.map do |rejection|
        {
          "gpu_id" => rejection.gpu_id,
          "cloud" => ranking.cloud,
          "hourly_rate_usd" => rejection.hourly_rate_usd,
          "eligible" => false,
          "reason" => rejection.reason
        }
      end)
      rows.sort_by do |row|
        [row["hourly_rate_usd"].nil? ? 1 : 0, row["hourly_rate_usd"] || 0.0, row.fetch("gpu_id")]
      end
    end
  end
end
