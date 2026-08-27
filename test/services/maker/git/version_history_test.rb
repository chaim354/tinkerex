require "test_helper"

module Maker
  module Git
    # "WHAT VERSIONS DOES THIS FILE HAVE, AND CAN I ACTUALLY SEE EACH ONE?"
    #
    # THE BACKEND IS PINNED, NEVER AMBIENT, for the reason project_commit_test.rb records:
    # `VersionHistory` builds a `Repo`, which resolves `FileLayer.current` itself, so a fixture
    # built through the ambient adapter is a real S3 client aimed at config/ci.rb's stub bucket on
    # the `test-s3` leg and writes a `Projects/` tree into the repo root on the `test` leg.
    # `use_fresh_share_library!` assigns a Share on a fresh tmpdir and OWNS the teardown of every
    # directory it mints, so this file is hermetic and identical on all three legs -- and pinning
    # is still testing the real thing, because the class under test asks the port for everything.
    class VersionHistoryTest < ActiveSupport::TestCase
      setup do
        @root = use_fresh_share_library!
        @user = User.create!(email: "git-history-#{SecureRandom.hex(4)}@example.com")
        @project = @user.maker_projects.create!(name: "Lamp #{SecureRandom.hex(3)}")
        @folder = mint_project_folder!
      end

      # §15's note about the 334 accumulated `tmp.*` directories found on the mac runner:
      # `use_fresh_share_library!` owns the LIBRARY root it minted; the cache root is this file's.
      teardown { FileUtils.remove_entry(@cache_root) if @cache_root && Dir.exist?(@cache_root) }

      # ---- content versions ------------------------------------------------------------------

      test "a text file's versions are the commits that changed it, newest first, all available" do
        repo.commit!(paths: { "notes.md" => "one\n" }, message: "one")
        repo.commit!(paths: { "notes.md" => "two\n" }, message: "two")

        versions = history.for_path("notes.md")

        assert_equal 2, versions.size
        assert_equal %w[two one], versions.map { |v| v.message.strip }, "newest first"
        assert versions.all?(&:content_available?),
               "content lives IN the repo, so it is available on every backend forever"
        assert_equal [ :content, :content ], versions.map(&:mode)
      end

      # OTHERWISE EVERY FILE LOOKS LIKE IT CHANGED ON EVERY SCAN. `Repo#commit!` carries HEAD's
      # whole tree forward, so a commit naming one path leaves every other blob byte-identical --
      # which is exactly what the sweep does 96 times a day.
      test "a commit that touched only other files is not a version of this one" do
        repo.commit!(paths: { "notes.md" => "one\n" }, message: "notes v1")
        repo.commit!(paths: { "other.md" => "x\n" }, message: "unrelated")

        versions = history.for_path("notes.md")

        assert_equal 1, versions.size, "notes.md did not change in the second commit"
        assert_equal "notes v1", versions.first.message.strip
      end

      # ---- pointer versions: the honest case -------------------------------------------------
      #
      # A pointer records that a version EXISTED; the bytes resolve only where the store kept
      # them. On share it kept nothing -- the maker's Finder overwrite destroyed the previous
      # bytes before any scan saw them -- so the superseded version must be LISTED and marked
      # unavailable. Omitting it would tell the maker their file has less history than it does,
      # and quietly.

      test "a superseded pointer version is listed but marked unavailable when the bytes are gone" do
        node = file_node("body.stl", content: "SOLID v2\n")
        repo.commit!(paths: { "body.stl.ptr" => pointer("sha256:#{'a' * 64}") }, message: "v1")
        repo.commit!(paths: { "body.stl.ptr" => pointer(node.content_hash) }, message: "v2")

        versions = history.for_path("body.stl")

        assert_equal 2, versions.size, "the version that is gone must still be RENDERED, not hidden"
        assert_equal %w[v2 v1], versions.map { |v| v.message.strip }
        assert_not versions.last.content_available?,
                   "a superseded pointer's bytes were never retained on share"
        assert versions.last.pointer?, "it is still a real version of a real commit"
        assert_equal "sha256:#{'a' * 64}", versions.last.content_token,
                     "the token is the pointer's own oid line, namespace and all"
      end

      test "the current pointer version is available because a live node still holds those bytes" do
        node = file_node("body.stl", content: "SOLID\n")
        repo.commit!(paths: { "body.stl.ptr" => pointer(node.content_hash) }, message: "v1")

        versions = history.for_path("body.stl")

        assert_equal 1, versions.size
        assert versions.first.content_available?
        assert_equal node.content_hash, versions.first.content_token
        assert_equal "body.stl", versions.first.path, "callers hold a filename, not a storage detail"
      end

      # THE OTHER LOCAL ARM, AND THE ONE MOST AT RISK OF BEING DELETED AS DEAD. On `chunk_remote`
      # `nodes.content_hash` is never written -- ChangelogSync mirrors `current_version_id` and the
      # version's MANIFEST instead -- and `ChunkRemote#read(content_token:)` resolves those bytes
      # through `RemoteManifestChunk` alone. A mirrored manifest is therefore the local evidence
      # that a superseded version can still be fetched; without this arm every chunk_remote version
      # would render "not kept", which is the exact opposite of what that backend actually does.
      # The row below is the one ChangelogSync#store_manifest writes.
      test "a pointer version whose manifest is mirrored locally is available" do
        token = "01234567-89ab-cdef-0123-456789abcdef"
        ::RemoteManifestChunk.create!(user: @user, version_id: token, seq: 0,
                                      chunk_hash: "h" * 64, offset: 0, length: 7)
        repo.commit!(paths: { "body.stl.ptr" => pointer(token) }, message: "v1")

        assert history.for_path("body.stl").first.content_available?,
               "a mirrored manifest is what a chunk_remote read resolves through"
      end

      # ---- nothing committed -----------------------------------------------------------------
      #
      # `hydrate!` MINTS `.git`, WHICH IS THE MARKER Maker::AttachToProject READS. Opening History
      # on a project that has never been committed must not switch off §14f's intake filing for
      # that project -- the same reason ProjectCommit#call! returns before hydrating.
      test "a path with no commits returns empty and does not mint a repository" do
        assert_empty history.for_path("notes.md")
        assert_not File.exist?(FileLayer.current.repo_data_dir(@user, project: @project).to_s),
                   "reading history must not mint a .git marker"
      end

      private

      def history = VersionHistory.new(project: @project.reload, cache_root:)

      # HYDRATED ONCE, ON DEMAND. Deliberately not called by the no-commits test, which asserts
      # that nothing minted a repository.
      def repo = @repo ||= Maker::Git::Repo.for(@project.reload, cache_root:).tap(&:hydrate!)

      # PER TEST, AND IT HAS TO BE. Repo keys its cache by user and project ID, and those repeat
      # across a transactional suite, so the shared default (`tmp/git-cache`) makes a later test
      # hydrate an earlier RUN's repository.
      def cache_root = @cache_root ||= Dir.mktmpdir("git-cache-version-history")

      # MINTED THROUGH THE PINNED ADAPTER, never Maker::Project#ensure_library_folder!, which goes
      # through the AMBIENT FileLayer.current -- see the class header.
      def mint_project_folder!
        root = FileLayer.current.mkdir(@user, parent_node_id: nil, name: Maker::ProjectFolders::ROOT)
        folder = FileLayer.current.mkdir(@user, parent_node_id: root.node_id, name: @project.slug)
        @project.update_column(:folder_node_id, folder.node_id)
        @user.nodes.find_by!(node_id: folder.node_id)
      end

      # A ROW PLUS THE FILE IT CLAIMS TO BE: on share a read resolves through storage_path and
      # opens an ACTUAL FILE, so a bare nodes.create! fixture is a node whose bytes were never
      # there (§14a).
      def file_node(name, content:)
        rel = File.join(@folder.storage_path, name)
        path = @root.join(rel)
        path.dirname.mkpath
        path.binwrite(content)
        @user.nodes.create!(node_id: SecureRandom.uuid, name:, kind: "file",
                            parent_node_id: @folder.node_id, storage_path: rel,
                            size: content.bytesize,
                            content_hash: "sha256:#{Digest::SHA256.hexdigest(content)}")
      end

      # Built through Tracking's own constant rather than a second copy of the wire format.
      def pointer(oid, size: 12) = "version #{Tracking::POINTER_VERSION}\noid #{oid}\nsize #{size}\n"
    end
  end
end
