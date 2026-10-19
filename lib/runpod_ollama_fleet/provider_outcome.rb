# frozen_string_literal: true

module RunpodOllamaFleet
  # Closed failure vocabulary at the provider/bring-up boundary. Codes describe
  # observations, not fallback permission: admission, verified absence and the
  # existing campaign policy remain authoritative in phase A.
  module ProviderOutcome
    CODES = %i[
      unknown capacity_unavailable hardware_mismatch resource_unusable
      readiness_unavailable capability_mismatch identity_mismatch
    ].freeze

    # Preserves existing exception classes/messages while attaching a code.
    # Untagged failures default to unknown; diagnostic text never selects a code.
    class Failure < StandardError
      # Returns the immutable symbol supplied at the source of the failure.
      attr_reader :outcome_code

      # Accepts an optional diagnostic and one closed-set symbol. Raises
      # ArgumentError for unsupported codes, never interpreting message text.
      def initialize(message = nil, outcome_code: :unknown)
        raise ArgumentError, "unsupported provider outcome code" unless CODES.include?(outcome_code)

        @outcome_code = outcome_code
        super(message)
      end
    end

    # Returns a typed failure's code, or unknown for legacy/untyped inputs.
    # Unknown and ambiguous diagnostics provide no typed permission to retry.
    def self.code_for(failure)
      failure.is_a?(Failure) ? failure.outcome_code : :unknown
    end
  end
end
