# frozen_string_literal: true

require_relative "test_helper"

class ProviderIndependenceTest < Minitest::Test
  REPO_ROOT = File.expand_path("..", __dir__)
  RUBY_ROOTS = %w[bin lib test].freeze

  def test_ruby_dependency_graph_has_no_low_implementation_import
    violations = imports.select { |_path, required| required.include?("local_ollama_workers") }
    assert_empty violations
  end

  def test_provider_runtime_and_conformance_do_not_import_wlo_or_adventurefinder
    violations = imports.select do |_path, required|
      required.include?("workload_orchestrator") || required.include?("adventure_finder")
    end
    assert_empty violations
  end

  private

  def imports
    RUBY_ROOTS.flat_map do |root|
      Dir[File.join(REPO_ROOT, root, "**", "*")].flat_map do |path|
        next [] unless File.file?(path)

        File.readlines(path, chomp: true).filter_map do |line|
          match = line.match(/^\s*require(?:_relative)?\s+["']([^"']+)["']/)
          [path.delete_prefix("#{REPO_ROOT}/"), match[1]] if match
        end
      end
    end
  end
end
