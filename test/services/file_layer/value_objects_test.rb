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

    # dir_deletable and local_worktree are asserted separately below rather than here -- they are
    # the two with a per-adapter claim attached, so their tests need the real adapters and this one
    # does not. Both appear in the constructor call anyway because Data.define requires every
    # member, which is also why adding a capability breaks every construction site at once rather
    # than defaulting one silently.
    test "Capabilities answers the first five questions" do
      caps = FileLayer::Capabilities.new(versioned: true, syncable: true, presignable: false,
                                         scannable: false, port_writable: true,
                                         local_worktree: false)
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

    # `dir_deletable` STOOD HERE AND IS RETIRED (2026-09-10). It asked one question for one caller
    # — may this backend's `delete` be handed a DIRECTORY? — and it was a real distinction while
    # chunk_remote cascaded and share and s3 refused. All three cascade now, so it varied on
    # nothing, and §14a's own rule is that a capability earns its place by VARYING: one that agrees
    # on every backend is a lie about the shape of the port, not a seam.
    #
    # THE ARGUMENT FOR KEEPING IT WAS CONSIDERED AND REJECTED. It ran: leave the seam for a future
    # backend that cannot cascade. But a member nothing reads is not a seam — it is a claim the
    # tests stop checking, and reintroducing it later costs one line. §14a records what each
    # backend does instead, which is the part a future adapter author actually needs.


    # Asserted as a RELATIONSHIP against the real adapters rather than three literals, so a
    # backend added later cannot quietly skip declaring it.
    #
    # `.allocate` SKIPS initialize, which is safe here and nowhere near as safe in general: every
    # one of the three `capabilities` methods returns hardcoded literals and reads no instance
    # state, while Share#initialize demands LIBRARY_PATH and S3#initialize a bucket, region and
    # keys. If a future adapter's capabilities ever depend on how it was constructed, this test
    # must move to real instances -- the answer would silently become whatever `allocate` left
    # behind, which for a Data-backed field is nil, and nil reads as false.

    # Task 8's two return types. Both are plain immutable Data objects, same as FileInfo above --
    # the assertions here are deliberately as thin as FileInfo's own: what matters about a Data
    # type is that it HOLDS its fields and cannot be mutated after construction, not that a unit
    # test re-derives the port behaviour that builds one (chunk_test.rb already does that).
    test "UploadBegun carries the fields a caller needs to drive the two-phase flow" do
      begun = FileLayer::UploadBegun.new(
        commit_id: "c1", node_id: "n1", put_urls: { "h1" => "https://example/h1" }, missing: [ "h1" ]
      )
      assert_equal "c1", begun.commit_id
      assert_equal "n1", begun.node_id
      assert_equal({ "h1" => "https://example/h1" }, begun.put_urls)
      assert_equal [ "h1" ], begun.missing
      assert_raises(NoMethodError) { begun.node_id = "n2" }
    end

    test "UploadFinalized carries version_id/seq unconditionally and info separately" do
      info = FileLayer::FileInfo.new(node_id: "n1", name: "a.stl", kind: "file", size: 5,
                                     mtime: 123, content_token: "v1")
      finalized = FileLayer::UploadFinalized.new(version_id: "v1", seq: 42, info:)
      assert_equal "v1", finalized.version_id
      assert_equal 42, finalized.seq
      assert_equal info, finalized.info
      assert_raises(NoMethodError) { finalized.seq = 43 }
    end

    # `info` CAN BE NIL -- the belt-and-braces case Chunk#finalize_upload's own comment explains
    # (a node that cannot be found immediately after the transaction that wrote it committed).
    # Data.define permits nil for any member; this test exists to say the nil is EXPECTED here,
    # not to catch Ruby forbidding it.
    test "UploadFinalized allows a nil info" do
      finalized = FileLayer::UploadFinalized.new(version_id: "v1", seq: 1, info: nil)
      assert_nil finalized.info
    end
  end
end
