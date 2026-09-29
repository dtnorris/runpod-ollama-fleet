# frozen_string_literal: true

# Historical AFIO/WLO workload-dispatch surfaces. New campaign and worker-
# registry consumers must require "runpod_ollama_fleet" instead.
require_relative "../local_model_evaluation/capacity"
require_relative "../runpod_ollama_fleet"
require_relative "contract_v0_1"
require_relative "execution_pool_fulfill"
require_relative "capability_check"
require_relative "dispatch_v0_1"
require_relative "owner_watch"
