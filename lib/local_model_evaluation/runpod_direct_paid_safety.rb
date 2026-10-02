# frozen_string_literal: true

module LocalModelEvaluation
  # Fail-closed policy for legacy/manual paid-capacity entrypoints. Production
  # automation belongs to the campaign safety gate; direct commands retain
  # read-only planning, teardown, and bounded interactive compatibility use.
  module RunpodDirectPaidSafety
    class Error < StandardError; end

    module_function

    def assert_not_automated!(operation:, assume_yes:, dry_run:, paid_mutation: true)
      return true if dry_run || !paid_mutation || !assume_yes

      raise Error,
            "automated direct paid #{operation} is blocked: " \
            "use an authorized campaign start with its safety gate"
    end

    def assert_complete_manual_lease!(operation:, lease:, dry_run:, paid_mutation: true)
      return true if dry_run || !paid_mutation

      runtime = positive_finite(lease && lease["max_runtime_seconds"])
      spend = positive_finite(lease && lease["max_spend_usd"])
      return true if runtime && spend

      raise Error,
            "direct paid #{operation} requires a finite runtime-and-spend lease; " \
            "this manual compatibility lease is not the campaign guardian proof"
    end

    def positive_finite(value)
      number = Float(value)
      number.positive? && number.finite?
    rescue ArgumentError, TypeError
      false
    end
    private_class_method :positive_finite
  end
end
