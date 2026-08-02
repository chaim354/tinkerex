require "test_helper"

module Maker
  module Addons
    class SourceTest < ActiveSupport::TestCase
      setup do
        @prior = ENV["ADDON_SOURCE_URL"]
        ENV["ADDON_SOURCE_URL"] = "http://addons.test"
      end

      teardown do
        ENV["ADDON_SOURCE_URL"] = @prior
        Source.reset!
      end

      test "configured? follows ADDON_SOURCE_URL" do
        assert Source.configured?
        ENV.delete("ADDON_SOURCE_URL")
        assert_not Source.configured?
      end

      test "asset_path! rejects traversal instead of normalizing it" do
        # REJECTS, never normalizes — the same rule as FileLayer::S3#key_for (§14a). expand_path
        # would turn "a/../../b" into a VALID path and silently fetch the wrong object.
        %w[../secret a/../../etc/passwd /abs .. a/./b].each do |bad|
          assert_raises(Source::Error, "expected #{bad.inspect} to be refused") do
            Source.new("http://addons.test").asset_path!(bad)
          end
        end
      end

      test "asset_path! accepts an ordinary nested path" do
        source = Source.new("http://addons.test")
        assert_equal "generators/makerjs.js", source.asset_path!("generators/makerjs.js")
      end

      test "a malformed manifest index raises Source::Error, not a JSON error" do
        source = Source.new("http://addons.test")
        # NOT Object#stub: minitest 6 dropped minitest/mock in this repo (`require "minitest/mock"`
        # is a LoadError — verified directly, and test_helper.rb's with_concurrent_file_attachment
        # comment says the same). `get` is private, but define_singleton_method reaches it fine —
        # it defines straight onto the instance's singleton class, same as any other private method.
        source.define_singleton_method(:get) { |*_args| "not json at all" }
        assert_raises(Source::Error) { source.manifests }
      end
    end
  end
end
