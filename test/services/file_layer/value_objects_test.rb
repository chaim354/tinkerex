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

    # The sixth, dir_deletable, is asserted separately below rather than here -- it is the only
    # one with a per-adapter claim attached, so its test needs the real adapters and this one does
    # not. It appears in the constructor call anyway because Data.define requires every member.
    test "Capabilities answers the first five questions" do
      caps = FileLayer::Capabilities.new(versioned: true, syncable: true, presignable: false,
                                         scannable: false, port_writable: true,
                                         dir_deletable: true)
      assert caps.versioned?
      assert caps.syncable?
      assert_not caps.presignable?
      assert_not caps.scannable?
      assert caps.port_writable?
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

    # dir_deletable asks ONE question: can this backend's `delete` be handed a DIRECTORY?
    #
    # It exists because FilesController#destroy stopped branching on port_writable?. Chunk
    # answers true (Sync::SubtreeDelete cascades the tombstone to the whole subtree); share
    # answers false (children would be stranded at paths that no longer exist while their bytes
    # sit in .trash, which the scan refuses to look at); S3 answers false (there is no directory
    # and no rename -- a dir node's key does not exist).
    #
    # IT IS NOT `syncable`, and the fact that it currently equals it is a coincidence of having
    # exactly three backends -- the same trap `scannable` was introduced to escape. A backend
    # that owns its own tree without a changelog (a database-backed store, a versioned object
    # store with real directories) answers dir_deletable true and syncable false.
    test "dir_deletable is part of the capability set and reads as a predicate" do
      caps = FileLayer::Capabilities.new(versioned: true, syncable: true, presignable: true,
                                         scannable: false, port_writable: false,
                                         dir_deletable: true)
      assert_predicate caps, :dir_deletable?
    end

    # Asserted as a RELATIONSHIP against the real adapters rather than three literals, so a
    # backend added later cannot quietly skip declaring it.
    #
    # `.allocate` SKIPS initialize, which is safe here and nowhere near as safe in general: every
    # one of the three `capabilities` methods returns hardcoded literals and reads no instance
    # state, while Share#initialize demands LIBRARY_PATH and S3#initialize a bucket, region and
    # keys. If a future adapter's capabilities ever depend on how it was constructed, this test
    # must move to real instances -- the answer would silently become whatever `allocate` left
    # behind, which for a Data-backed field is nil, and nil reads as false.
    test "every adapter declares dir_deletable, and only chunk allows it" do
      expected = { FileLayer::Chunk => true, FileLayer::Share => false, FileLayer::S3 => false }
      expected.each do |klass, want|
        got = klass.allocate.capabilities.dir_deletable?
        assert_equal want, got, "#{klass} must declare dir_deletable: #{want}"
      end
    end
  end
end
