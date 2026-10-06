# frozen_string_literal: true

module SiblingImplementationBoundary
  def self.forbidden_features(features, root:, pattern:)
    own_prefix = "#{File.realpath(root)}#{File::SEPARATOR}"
    features.select do |feature|
      resolved = File.realpath(feature) if File.exist?(feature)
      # Resolve before excluding our checkout so an internal symlink cannot hide a sibling.
      next false if resolved&.start_with?(own_prefix)

      pattern.match?(feature) || (resolved && pattern.match?(resolved))
    end
  end
end
