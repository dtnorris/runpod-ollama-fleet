# frozen_string_literal: true

require "minitest/autorun"
require "fileutils"
require "tmpdir"
require_relative "support/sibling_implementation_boundary"

class SiblingImplementationBoundaryTest < Minitest::Test
  def setup
    @tmp = Dir.mktmpdir("boundary-")
    @parent = File.join(@tmp, "adventure-finder-components")
    @root = File.join(@parent, "runpod-ollama-fleet")
    @before = $LOADED_FEATURES.dup
    FileUtils.mkdir_p(@root)
  end

  def teardown
    $LOADED_FEATURES.replace(@before)
    FileUtils.remove_entry(@tmp)
  end

  def test_loaded_own_file_and_external_alias_are_allowed
    own = write_feature(File.join(@root, "lib", "own.rb"))
    alias_root = File.join(@tmp, "adventure-finder-alias")
    File.symlink(@root, alias_root)
    require own

    assert_empty forbidden($LOADED_FEATURES - @before)
    assert_empty forbidden([File.join(alias_root, "lib", "own.rb")])
    assert_empty SiblingImplementationBoundary.forbidden_features(
      [own], root: alias_root, pattern: /adventure[_-]finder/i
    )
  end

  def test_loaded_sibling_and_shared_prefix_checkout_are_rejected
    sibling = write_feature(File.join(@parent, "adventure-finder", "lib", "sibling.rb"))
    neighbor = write_feature(File.join("#{@root}-extra", "lib", "neighbor.rb"))
    require sibling
    require neighbor

    assert_equal [sibling, neighbor].sort, forbidden($LOADED_FEATURES - @before).sort
  end

  def test_symlink_inside_own_checkout_cannot_hide_a_loaded_sibling
    sibling = write_feature(File.join(@tmp, "adventure-finder", "lib", "sibling.rb"))
    alias_path = File.join(@root, "hidden.rb")
    File.symlink(sibling, alias_path)
    require alias_path

    refute_empty forbidden($LOADED_FEATURES - @before)
    assert_equal [alias_path], forbidden([alias_path])
  end

  def test_unresolved_matching_feature_is_not_exempted_as_own_code
    missing = File.join(@root, "missing.rb")

    assert_equal [missing], forbidden(["enumerator.so", missing])
  end

  private

  def forbidden(features)
    SiblingImplementationBoundary.forbidden_features(
      features, root: @root, pattern: /adventure[_-]finder/i
    )
  end

  def write_feature(path)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, "# Boundary fixture.\n")
    path
  end
end
