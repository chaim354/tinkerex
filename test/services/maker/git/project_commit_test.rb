require "test_helper"
require "support/fake_s3"

module Maker
  module Git
    # ONE PROJECT'S COMMIT PASS, driven through the real port.
    #
    # THE BACKEND IS PINNED, NEVER AMBIENT, and that is a correction rather than a preference --
    # repo_test.rb records the measurement. `ProjectCommit` resolves `FileLayer.current` itself, so
    # a fixture built through the ambient adapter is a real S3 client aimed at config/ci.rb's stub
    # bucket on the `test-s3` leg (Aws::S3::Errors::Forbidden), and on the `test` leg it writes a
    # `Projects/` tree into the repo root. `use_fresh_share_library!` assigns a Share on a fresh
    # tmpdir and OWNS the teardown of every directory it mints, so this file is hermetic and
    # identical on all three legs -- and pinning is still testing the real thing, because the class
    # under test asks the port for everything it does.
    #
    # THE HYDRATED (cache-backed) SHAPE IS DELIBERATELY NOT RE-COVERED HERE. `Maker::Git::Repo`'s
    # own suite runs its whole lifecycle against BOTH shapes via two includers, so this file
    # exercises the IN-PLACE shape -- the one that gives the maker `git log` in their own folder --
    # and adds exactly one hydrated test below, for the one thing only a hydrated backend can show:
    # that consolidate! runs BEFORE persist!.
    class ProjectCommitTest < ActiveSupport::TestCase
      setup do
        @root = use_fresh_share_library!
        @user = User.create!(email: "git-commit-#{SecureRandom.hex(4)}@example.com")
        @project = @user.maker_projects.create!(name: "Lamp #{SecureRandom.hex(3)}")
        @folder = mint_project_folder!
      end

      # THE HELPER BELOW MINTS A TMPDIR AND SO THIS HAS TO EXIST -- §15's own note about the 334
      # accumulated `tmp.*` directories found on the mac runner. `use_fresh_share_library!` owns
      # the teardown of the LIBRARY root it minted; the cache root is this file's own.
      teardown { FileUtils.remove_entry(@cache_root) if @cache_root && Dir.exist?(@cache_root) }

      # ---- settle detection ------------------------------------------------------------------
      #
      # THE HAZARD: a slicer writing a 200 MB 3MF takes tens of seconds. A commit made mid-write
      # records a TRUNCATED FILE as a legitimate version -- and it looks entirely normal
      # afterwards, which is what makes it dangerous.
      #
      # THE TWO EVENTS ARE DAYS APART, NEVER SECONDS. A timestamp compared at second resolution is
      # a guard that usually cannot fail (§15): the row under test is written in the same second as
      # the thing you fear overwrote it, so the mutation stays green. Three days makes a regression
      # fail by three orders of magnitude.

      test "a node touched during this scan is not eligible" do
        node = file_node("notes.md") # written now...
        scan_started = 3.days.ago    # ...long after this scan began

        assert_empty pass(scan_started_at: scan_started).eligible_nodes,
                     "a file touched since the scan started may still be being written"
        assert node.updated_at > scan_started, "fixture is inverted; the test would be vacuous"
      end

      test "a node unchanged since before this scan is eligible" do
        node = travel_to(3.days.ago) { file_node("notes.md") }

        assert_equal [ node.node_id ], pass.eligible_nodes.map(&:node_id)
      end

      test "files nested under the project folder are eligible too" do
        nested = travel_to(3.days.ago) do
          sub = dir_node("cad", parent: @folder)
          file_node("body.step", parent: sub)
        end

        assert_equal [ nested.node_id ], pass.eligible_nodes.map(&:node_id)
      end

      test "a directory is not eligible; only files enter a commit" do
        travel_to(3.days.ago) { dir_node("cad", parent: @folder) }

        assert_empty pass.eligible_nodes
      end

      # ---- the commit pass -------------------------------------------------------------------

      test "call! commits text as content and binaries as a pointer naming the content hash" do
        step = travel_to(3.days.ago) do
          file_node("notes.md", content: "hello\n")
          file_node("body.step", content: "SOLID\n")
        end

        assert pass.call!, "expected a commit"

        repo = read_back
        head = repo.head_oid
        assert head, "expected a commit"
        assert_equal "hello\n", repo.blob_at(oid: head, path: "notes.md"),
                     "text must be committed as content, not as a pointer"
        pointer = repo.blob_at(oid: head, path: "body.step.ptr")
        assert_match(/^oid #{Regexp.escape(step.content_hash)}$/, pointer,
                     "a binary's pointer body must name the library's own content hash")
        assert_raises(FileLayer::NotFound, "a binary's bytes must never enter the history") do
          repo.blob_at(oid: head, path: "body.step")
        end
      end

      # THE SIZE CEILING IS CONSULTED AT THE COMMIT DOOR, NOT MERELY DEFINED.
      # `Tracking::MAX_CONTENT_BYTES` can exist, be documented and be fully unit-tested while
      # `paths_for` never passes a `size:` -- a knob wired to nothing, which is §15's own recorded
      # shape ("16 green tests over an operator env knob that shipped inert"). No predicate test can
      # see that argument go missing; only driving the real pass can.
      #
      # THE ROW'S SIZE IS STAMPED RATHER THAN WRITTEN, deliberately. The file on disk stays six
      # bytes, so if the ceiling is NOT consulted the pass READS those bytes and commits them as
      # content at `notes.md` -- a loud, specific failure -- where a genuine 4 MiB write would only
      # have made the test slow. `update_column` also leaves `updated_at` alone, so the node stays
      # settled and the pass still sees it.
      test "a text file over the size ceiling is committed as a pointer, not as content" do
        node = travel_to(3.days.ago) { file_node("notes.md", content: "hello\n") }
        node.update_column(:size, Maker::Git::Tracking::MAX_CONTENT_BYTES + 1)

        head = pass.call!
        assert head, "expected a commit"

        repo = read_back
        pointer = repo.blob_at(oid: head, path: "notes.md.ptr")
        assert_match(/^oid #{Regexp.escape(node.content_hash)}$/, pointer,
                     "an over-ceiling file must be committed as a pointer naming the content hash")
        assert_match(/^size #{Maker::Git::Tracking::MAX_CONTENT_BYTES + 1}$/, pointer)
        assert_raises(FileLayer::NotFound,
                      "an over-ceiling file's bytes must never enter the history") do
          repo.blob_at(oid: head, path: "notes.md")
        end
      end

      # A `.git` DIRECTORY IS NOT INERT -- IT IS THE MARKER Maker::AttachToProject reads to decide
      # whether §14f's intake filing applies. Minting one for a project with nothing to commit
      # would silently switch that off, at the next scan, nowhere near this call.
      test "call! is a no-op when nothing has settled" do
        file_node("notes.md") # touched now, so still in flight

        assert_nil pass(scan_started_at: 3.days.ago).call!
        assert_nil Maker::GitRepo.find_by(project: @project)&.head_oid
        refute File.exist?(FileLayer.current.repo_data_dir(@user, project: @project).to_s),
               "a pass with nothing to commit must not mint a .git marker"
      end

      # Not cosmetic: an unpacked 1,500-commit repo needs 11,287 GETs to hydrate off s3 against ~3,
      # so a pass that commits without packing leaves the project unusable on two of three backends.
      test "call! leaves the repository packed" do
        travel_to(3.days.ago) { file_node("notes.md") }
        pass.call!

        assert_empty read_back.loose_object_rels,
                     "consolidate! must run inside the pass; an unpacked repo is unhydratable off share"
      end

      # THE SWEEP RUNS EVERY 15 MINUTES FOREVER. One commit per tick fills the history with nothing
      # and makes the version list useless within a week.
      test "a second pass with nothing changed does not move the head" do
        travel_to(3.days.ago) { file_node("notes.md") }
        first = pass.call!

        assert_nil pass.call!, "an unchanged tree must not mint a second commit"
        assert_equal first, read_back.head_oid
      end

      # A file that vanished or is unreachable mid-sweep is skipped, not fatal: the next tick picks
      # it up, and failing the whole pass would stall every other project's history behind one bad
      # file.
      test "a file that vanished mid-sweep is skipped rather than failing the pass" do
        travel_to(3.days.ago) do
          file_node("gone.md", content: "x\n")
          file_node("kept.md", content: "y\n")
        end
        @root.join(@folder.storage_path, "gone.md").delete

        head = pass.call!
        assert head, "one unreadable file must not fail the whole pass"

        repo = read_back
        assert_equal "y\n", repo.blob_at(oid: head, path: "kept.md")
        assert_raises(FileLayer::NotFound) { repo.blob_at(oid: head, path: "gone.md") }
      end

      # THE PATH IS DERIVED FROM storage_path AND THE FOLDER'S OWN PREFIX, so a row whose
      # storage_path disagrees with the tree it is parented into must be dropped rather than
      # committed at an absolute-looking path, or at the wrong path entirely.
      test "a node whose storage_path is not beneath the project folder is skipped" do
        stray = travel_to(3.days.ago) { file_node("stray.md", content: "z\n") }
        stray.update_column(:storage_path, "Elsewhere/stray.md")
        travel_to(3.days.ago) { file_node("kept.md", content: "y\n") }

        head = pass.call!
        repo = read_back

        assert_equal "y\n", repo.blob_at(oid: head, path: "kept.md")
        assert_raises(FileLayer::NotFound) { repo.blob_at(oid: head, path: "stray.md") }
        assert_raises(FileLayer::NotFound) { repo.blob_at(oid: head, path: "Elsewhere/stray.md") }
      end

      private

      def pass(scan_started_at: Time.current)
        Maker::Git::ProjectCommit.new(project: @project.reload, scan_started_at:, cache_root:)
      end

      # A SECOND Repo OVER THE SAME REPOSITORY, to read back what the pass wrote. In place, the
      # cache root is never consulted -- it is passed anyway because user and project IDs REPEAT
      # across transactional tests, so a shared default would let a later test hydrate an earlier
      # test's repository the moment this backend stopped being in-place.
      def read_back
        repo = Maker::Git::Repo.for(@project.reload, cache_root: cache_root)
        repo.hydrate!
        repo
      end

      # PER TEST, AND IT HAS TO BE. Repo keys its cache by user and project ID, and those repeat
      # across a transactional suite -- the shared default (`tmp/git-cache`) makes a later test
      # hydrate an earlier RUN's repository, whose tree is then identical and whose commit is
      # correctly refused. Measured: the hydrated test below returned nil in isolation and passed
      # only when something else had run first. It also keeps the suite from leaving directories
      # in the repo's own `tmp/` (§15's 334 accumulated tmpdirs).
      def cache_root = @cache_root ||= Dir.mktmpdir("git-cache-project-commit")

      # MINTED THROUGH THE PINNED ADAPTER, never Maker::Project#ensure_library_folder!, which goes
      # through the AMBIENT FileLayer.current -- see the class header.
      def mint_project_folder!
        root = FileLayer.current.mkdir(@user, parent_node_id: nil, name: Maker::ProjectFolders::ROOT)
        folder = FileLayer.current.mkdir(@user, parent_node_id: root.node_id, name: @project.slug)
        @project.update_column(:folder_node_id, folder.node_id)
        @user.nodes.find_by!(node_id: folder.node_id)
      end

      def dir_node(name, parent:)
        stat = FileLayer.current.mkdir(@user, parent_node_id: parent.node_id, name:)
        @user.nodes.find_by!(node_id: stat.node_id)
      end

      # A ROW **PLUS THE FILE IT CLAIMS TO BE**: on share a read resolves through storage_path and
      # opens an ACTUAL FILE, so a bare nodes.create! fixture is a node whose bytes were never
      # there (§14a).
      def file_node(name, content: "x\n", parent: nil)
        parent ||= @folder
        rel = File.join(parent.storage_path, name)
        path = @root.join(rel)
        path.dirname.mkpath
        path.binwrite(content)
        @user.nodes.create!(node_id: SecureRandom.uuid, name:, kind: "file", parent_node_id: parent.node_id,
                            storage_path: rel, size: content.bytesize,
                            content_hash: "sha256:#{Digest::SHA256.hexdigest(content)}")
      end
    end

    # ── THE ONE THING ONLY A HYDRATED BACKEND CAN SHOW ────────────────────────────────────────
    #
    # ORDER IS LOAD-BEARING: commit, then consolidate, then persist. On share `persist!` is a
    # no-op, so swapping the last two changes NOTHING there and the packed test above stays green
    # under that mutation -- the ordering would be untested. Driven against S3 because its fake is
    # hermetic, and the code path is `repo_data_dir -> nil`, which chunk_remote answers identically.
    #
    # ONLY A POINTER FILE, DELIBERATELY: a pointer is built from the ROW (content_hash, size) and
    # never reads bytes, so this needs nothing seeded in the bucket and stays about the ordering.
    class ProjectCommitPersistOrderTest < ActiveSupport::TestCase
      PREFIX = "library".freeze

      setup do
        @fake = FakeS3.new
        FileLayer.current = FileLayer::S3.new(bucket: "b", region: "us-east-1", access_key_id: "ak",
                                              secret_access_key: "sk", prefix: PREFIX, client: @fake.client)
        @user = User.create!(email: "git-commit-s3-#{SecureRandom.hex(4)}@example.com")
        @project = @user.maker_projects.create!(name: "Lamp #{SecureRandom.hex(3)}")
        root = FileLayer.current.mkdir(@user, parent_node_id: nil, name: Maker::ProjectFolders::ROOT)
        folder = FileLayer.current.mkdir(@user, parent_node_id: root.node_id, name: @project.slug)
        @project.update_column(:folder_node_id, folder.node_id)
        @folder = @user.nodes.find_by!(node_id: folder.node_id)
        # THIS BACKEND IS HYDRATED, so the cache root is real state -- see the share class's
        # cache_root comment for why a shared one makes this very test pass or fail by history.
        @cache_root = Dir.mktmpdir("git-cache-persist-order")
      end

      teardown do
        FileLayer.reset!
        FileUtils.remove_entry(@cache_root) if @cache_root && Dir.exist?(@cache_root)
      end

      test "the library receives packs and refs, never loose objects" do
        travel_to(3.days.ago) do
          @user.nodes.create!(node_id: SecureRandom.uuid, name: "body.step", kind: "file",
                              parent_node_id: @folder.node_id, size: 12,
                              storage_path: File.join(@folder.storage_path, "body.step"),
                              content_hash: "sha256:#{'a' * 64}")
        end

        assert Maker::Git::ProjectCommit.new(project: @project, scan_started_at: Time.current,
                                             cache_root: @cache_root).call!

        rels = FileLayer.current.list_repo_data(@user, project: @project)
        loose = rels.grep(%r{\Aobjects/[0-9a-f]{2}/})
        assert_empty loose,
                     "persist! ran before consolidate!: loose objects were pushed into the library, " \
                     "which is the 11,287-request hydrate consolidation exists to prevent"
        assert rels.any? { |r| r.start_with?("objects/pack/") }, "nothing was packed at all"
      end
    end

    # ── THE SAME PASS ON A chunk_remote-SHAPED LIBRARY ────────────────────────────────────────
    #
    # NODES WITH PARENT CHAINS AND NO storage_path, WHICH IS THE ONLY SHAPE chunk_remote HAS. Every
    # rel was derived from storage_path until this suite existed, so on the product's BASE
    # deployment (§7) `paths_for` yielded nothing, `call!` returned nil before opening anything,
    # and the whole feature was inert with no error anywhere. The fixture is deliberately NOT a
    # share library with the paths knocked out: a bare `nodes.create!` with a NULL storage_path is
    # the exact fixture §14a warns produces a chunk-green/share-red split, and here it would be
    # asserting the derivation against a shape neither backend has.
    #
    # A REAL FileLayer::ChunkRemote, WITH ONLY THE VERBS THAT OPEN A SOCKET HELD IN MEMORY.
    # Everything this class actually exercises on that adapter is the shipping code -- the mirrored
    # `nodes` reads it resolves eligibility and paths from, and `repo_data_dir` answering nil so
    # Repo hydrates into a cache instead of operating in place. The three repo-data verbs and
    # `read` are substituted because they are the sync server's half of the wire, and they already
    # have their own coverage: `adapter_repo_data_contract.rb` runs them against a REAL engine in
    # `upload_test.rb`. Booting a sync server here would test that adapter's upload a third time
    # and this class's path derivation not at all.
    class ProjectCommitChunkRemoteTest < ActiveSupport::TestCase
      class MirrorOnlyChunkRemote < FileLayer::ChunkRemote
        def initialize
          super()
          @repo_data = {}
          @bytes = {}
        end

        # The bytes of one library file, by node id: what a :content file's commit reads through
        # the port, and what a pointer file never asks for at all.
        def seed_bytes(node_id, content) = @bytes[node_id] = content

        def read(_user, node_id:, content_token: nil)
          @bytes.fetch(node_id) { raise FileLayer::NotFound, node_id }
        end

        def write_repo_data(_user, project:, rel:, io:)
          @repo_data[[ project.id, rel ]] = io.read.b
          nil
        end

        def read_repo_data(_user, project:, rel:)
          @repo_data.fetch([ project.id, rel ]) { raise FileLayer::NotFound, rel }
        end

        def list_repo_data(_user, project:, prefix: nil)
          rels = @repo_data.keys.select { |id, _rel| id == project.id }.map(&:last)
          prefix.blank? ? rels : rels.select { |r| r.start_with?("#{prefix}/") }
        end
      end

      setup do
        @adapter = MirrorOnlyChunkRemote.new
        FileLayer.current = @adapter
        @user = User.create!(email: "git-commit-cr-#{SecureRandom.hex(4)}@example.com")
        @project = @user.maker_projects.create!(name: "Lamp #{SecureRandom.hex(3)}")
        @projects_root = dir_node(Maker::ProjectFolders::ROOT, parent: nil)
        @folder = dir_node(@project.slug, parent: @projects_root)
        @project.update_column(:folder_node_id, @folder.node_id)
        # THIS BACKEND IS HYDRATED (repo_data_dir is nil), so the cache root is real state and has
        # to be per test -- see the share class's cache_root comment for why a shared one makes a
        # test pass or fail depending on what ran before it.
        @cache_root = Dir.mktmpdir("git-cache-project-commit-cr")
      end

      teardown do
        FileLayer.reset!
        FileUtils.remove_entry(@cache_root) if @cache_root && Dir.exist?(@cache_root)
      end

      # THE HEADLINE: the rel is PROJECT-relative and derived from the parent chain, since there is
      # no storage_path anywhere in this library to derive it from. Both wrong answers are asserted
      # against by name -- a bare basename (the folder the file was in is lost, and two `body.step`
      # files in different folders then collide in one repository) and the library-root-relative
      # path LibraryTree actually answers with (which buries every project's repo under a copy of
      # its own place in the library).
      test "a nested binary is committed at its path relative to the PROJECT FOLDER" do
        step = travel_to(3.days.ago) do
          cad = dir_node("cad", parent: @folder)
          file_node("body.step", parent: cad)
        end

        head = pass.call!
        assert head, "the pass must commit on chunk_remote, whose nodes carry no storage_path"

        repo = read_back
        assert_match(/^oid #{Regexp.escape(step.content_hash)}$/,
                     repo.blob_at(oid: head, path: "cad/body.step.ptr"))
        assert_raises(FileLayer::NotFound, "a bare basename loses the folder the file was in") do
          repo.blob_at(oid: head, path: "body.step.ptr")
        end
        assert_raises(FileLayer::NotFound, "the rel must not be library-root-relative") do
          repo.blob_at(oid: head, path: "#{Maker::ProjectFolders::ROOT}/#{@project.slug}/cad/body.step.ptr")
        end
      end

      test "a text file nested two levels deep is committed as content at its own relative path" do
        travel_to(3.days.ago) do
          notes = dir_node("notes", parent: dir_node("docs", parent: @folder))
          file_node("build.md", parent: notes, content: "day one\n")
        end

        head = pass.call!
        assert head, "expected a commit"
        assert_equal "day one\n", read_back.blob_at(oid: head, path: "docs/notes/build.md"),
                     "a text file goes in as content, at the path its parent chain gives it"
      end

      # ---- a broken parent chain ---------------------------------------------------------------
      #
      # THE FIRST LINE OF DEFENCE IS THE DESCENT, and saying so is what makes the second test below
      # honest about what it is exercising: `eligible_nodes` asks for files whose parent is a dir it
      # reached by descending FROM the project folder, so a file hanging off an id that does not
      # exist is never a candidate in the first place. The mirror is deliberately stale between
      # pulls (§14a), so a row whose parent has not been applied yet is an ordinary state here, not
      # a corruption.

      test "a file whose parent id points at nothing is never even eligible" do
        travel_to(3.days.ago) do
          @user.nodes.create!(node_id: SecureRandom.uuid, name: "orphan.step", kind: "file",
                              parent_node_id: SecureRandom.uuid, size: 3,
                              content_hash: "sha256:#{'a' * 64}")
          file_node("kept.step", parent: @folder)
        end

        assert_equal %w[kept.step], pass.eligible_nodes.map(&:name)
      end

      # A CHAIN BROKEN ABOVE THE PROJECT FOLDER IS THE CASE THE DESCENT CANNOT CATCH: every file is
      # still reachable from the folder, so they are all eligible, and it is Maker::LibraryTree's
      # `:broken` sentinel -- nil -- that has to stop them. Unchecked it fails QUIETLY (`:broken`
      # answers `.name`), and quiet here means files committed at a path derived from half a chain,
      # which git keeps forever. Nothing this tick is the recoverable answer: the next pull applies
      # the missing ancestor and the next tick commits normally.
      test "a broken parent chain above the folder commits nothing rather than a guessed path" do
        travel_to(3.days.ago) { file_node("body.step", parent: @folder) }
        assert_equal 1, pass.eligible_nodes.count, "fixture is inverted; the test would be vacuous"
        @projects_root.destroy! # the folder's own parent id now points at nothing

        assert_nil pass.call!, "a file whose chain cannot be resolved must not be committed anywhere"
        assert_empty @adapter.list_repo_data(@user, project: @project),
                     "nothing may be written to the library for a project whose paths did not resolve"
      end

      # THE PER-NODE ARM OF THE SAME SENTINEL CHECK, WHICH THE PUBLIC ROUTE CANNOT REACH TODAY and
      # which is therefore driven through `paths_for` directly. `eligible_nodes` only ever yields
      # files whose parent was reached by descending from the project folder, so a per-node break
      # under a resolvable folder is unrepresentable through `call!` -- but `paths_for` takes a node
      # LIST from a caller, and LibraryTree's header requires EVERY caller to check the sentinel.
      # Asserting it here is what keeps that arm from being a guard nobody has ever driven.
      test "paths_for drops a node whose own parent chain is broken, with the folder resolvable" do
        orphan = travel_to(3.days.ago) do
          @user.nodes.create!(node_id: SecureRandom.uuid, name: "orphan.step", kind: "file",
                              parent_node_id: SecureRandom.uuid, size: 3,
                              content_hash: "sha256:#{'b' * 64}")
        end
        kept = travel_to(3.days.ago) { file_node("kept.step", parent: @folder) }

        assert_equal({ "kept.step.ptr" => Maker::Git::Tracking.pointer_for(kept) },
                     pass.send(:paths_for, [ orphan, kept ]))
      end

      private

      def pass(scan_started_at: Time.current)
        Maker::Git::ProjectCommit.new(project: @project.reload, scan_started_at:,
                                      cache_root: @cache_root)
      end

      def read_back
        repo = Maker::Git::Repo.for(@project.reload, cache_root: @cache_root)
        repo.hydrate!
        repo
      end

      def dir_node(name, parent:)
        @user.nodes.create!(node_id: SecureRandom.uuid, name:, kind: "dir",
                            parent_node_id: parent&.node_id)
      end

      # A ROW WITH NO storage_path AND A REAL PARENT POINTER -- the whole point of this suite. The
      # bytes live with the adapter, keyed by node id, exactly as they live on the sync server:
      # there is no path anywhere for a read to resolve against.
      def file_node(name, parent:, content: nil)
        node = @user.nodes.create!(node_id: SecureRandom.uuid, name:, kind: "file",
                                   parent_node_id: parent.node_id,
                                   size: content&.bytesize || 12,
                                   current_version_id: SecureRandom.uuid,
                                   content_hash: "sha256:#{Digest::SHA256.hexdigest(content.to_s)}")
        @adapter.seed_bytes(node.node_id, content) if content
        node
      end
    end
  end
end
