require "test_helper"

module FileLayer
  class ValueObjectsTest < ActiveSupport::TestCase
    test "FileInfo carries the fields the maker layer needs" do
      info = FileLayer::FileInfo.new(
        node_id: "n1", name: "a.stl", kind: "file", size: 5, mtime: 123, content_token: "v1"
      )
      assert_equal "n1", info.node_id
      assert_equal "a.stl", info.name
      assert_equal "file", info.kind
      assert_equal 5, info.size
      assert_equal 123, info.mtime
      assert_equal "v1", info.content_token
    end

    test "FileInfo is immutable" do
      info = FileLayer::FileInfo.new(
        node_id: "n1", name: "a.stl", kind: "file", size: 5, mtime: 123, content_token: "v1"
      )
      assert_raises(NoMethodError) { info.name = "b.stl" }
    end

    test "Capabilities answers the four questions" do
      caps = FileLayer::Capabilities.new(versioned: true, syncable: true, presignable: false,
                                         scannable: false)
      assert caps.versioned?
      assert caps.syncable?
      assert_not caps.presignable?
      assert_not caps.scannable?
    end

    # Data.define requires EVERY member, and that is the mechanism the scan gate rests on rather
    # than a detail of Ruby: a new backend cannot construct its Capabilities without stating
    # `scannable:`, so it cannot inherit a false the way `is_a?(FileLayer::Share)` handed one to
    # FileLayer::S3 (the Phase 3 trap). "You must say" is the default, not "false".
    test "a Capabilities that omits a question cannot be built at all" do
      err = assert_raises(ArgumentError) do
        FileLayer::Capabilities.new(versioned: true, syncable: true, presignable: false)
      end
      assert_match(/scannable/, err.message)
    end
  end
end
