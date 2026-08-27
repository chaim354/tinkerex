require "test_helper"
require "support/fake_s3"

module Maker
  module Git
    # THE LIFECYCLE, ASSERTED ONCE AND RUN AGAINST BOTH SHAPES THE PORT PRODUCES: a backend that is
    # operated on IN PLACE (share -- the library is already a filesystem) and one that must be
    # HYDRATED INTO AN EPHEMERAL CACHE (s3, chunk_remote). Two includers below.
    #
    # IT PINS ITS OWN ADAPTER RATHER THAN USING THE AMBIENT ONE, and that is a correction rather
    # than a preference. An earlier version built its fixture through `FileLayer.current`, which on
    # the `test-s3` leg is a REAL S3 adapter aimed at config/ci.rb's stub bucket -- so the suite
    # made a live network call and died with Aws::S3::Errors::Forbidden. Pinning also makes this
    # strictly better coverage: BOTH paths are exercised on all three legs, instead of whichever
    # one the leg happens to select.
    #
    # Hooks an includer must define: `adapter`, and `work_tree` (the project folder when this
    # backend has one, nil otherwise).
    module GitRepoLifecycle
      def self.included(base)
        base.setup do
          @cache_root = Dir.mktmpdir("git-cache-test")
          @user = User.create!(email: "git-repo-#{SecureRandom.hex(4)}@example.com")
          @project = @user.maker_projects.create!(name: "Lamp #{SecureRandom.hex(3)}")
          # MINTED THROUGH THE PINNED ADAPTER, never `Maker::Project#ensure_library_folder!` --
          # that goes through `FileLayer.current`, the AMBIENT backend, which on the `test-s3` leg
          # is a real S3 adapter aimed at config/ci.rb's stub bucket. Measured: 26 errors, all
          # Aws::S3::Errors::Forbidden, on two of the three legs.
          root = adapter.mkdir(@user, parent_node_id: nil, name: Maker::ProjectFolders::ROOT)
          folder = adapter.mkdir(@user, parent_node_id: root.node_id, name: @project.slug)
          @project.update_column(:folder_node_id, folder.node_id)
          @repo = build_repo
        end

        base.teardown do
          @repo&.discard_cache!
          FileUtils.remove_entry(@cache_root) if @cache_root && Dir.exist?(@cache_root)
        end
      end

      def build_repo(project = @project)
        Maker::Git::Repo.for(project, adapter:, cache_root: @cache_root)
      end

      def test_a_fresh_repo_has_no_head
        @repo.hydrate!
        assert_nil @repo.head_oid
      end

      def test_commit_writes_a_commit_and_moves_the_head
        @repo.hydrate!
        oid = @repo.commit!(paths: { "docs/notes.md" => "hello\n" }, message: "first")

        assert_match(/\A[0-9a-f]{40}\z/, oid)
        assert_equal oid, @repo.head_oid
      end

      # A sweep runs every 15 minutes forever. One empty commit per tick fills the history with
      # nothing and makes the version list useless within a week.
      def test_commit_returns_nil_when_nothing_changed
        @repo.hydrate!
        @repo.commit!(paths: { "docs/notes.md" => "hello\n" }, message: "first")

        assert_nil @repo.commit!(paths: { "docs/notes.md" => "hello\n" }, message: "second"),
                   "an unchanged tree must not mint an empty commit every scan"
      end

      # A commit that names one path must not delete every other tracked file. The index is rebuilt
      # from HEAD each time, so this is the assertion that pins `carry_forward`.
      def test_committing_one_path_carries_the_rest_of_the_tree_forward
        @repo.hydrate!
        @repo.commit!(paths: { "a.txt" => "one\n", "docs/b.txt" => "two\n" }, message: "both")
        second = @repo.commit!(paths: { "a.txt" => "changed\n" }, message: "only a")

        assert_equal "changed\n", @repo.blob_at(oid: second, path: "a.txt")
        assert_equal "two\n", @repo.blob_at(oid: second, path: "docs/b.txt"),
                     "a commit naming one path must not drop the rest of the tree"
      end

      # THE WHOLE PHASE IN ONE TEST. Everything the cache holds is thrown away and the repository is
      # rebuilt from library bytes alone.
      def test_history_survives_a_persist_and_a_fresh_hydrate
        @repo.hydrate!
        first = @repo.commit!(paths: { "docs/notes.md" => "one\n" }, message: "one")
        @repo.consolidate!
        @repo.persist!

        rebuilt = build_repo(@project.reload)
        rebuilt.discard_cache!
        rebuilt.hydrate!

        assert_equal first, rebuilt.head_oid
        assert_equal "one\n", rebuilt.blob_at(oid: first, path: "docs/notes.md")
      end

      # Not cosmetic: an unpacked 1,500-commit repo needs 11,287 GETs to hydrate on s3 against ~3.
      def test_consolidate_leaves_no_loose_objects
        @repo.hydrate!
        3.times { |i| @repo.commit!(paths: { "f#{i}.txt" => "#{i}\n" }, message: "c#{i}") }
        @repo.consolidate!

        assert_empty @repo.loose_object_rels,
                     "consolidate! must collapse every loose object; an unpacked repo is unhydratable off share"
      end

      def test_log_returns_commits_newest_first
        @repo.hydrate!
        @repo.commit!(paths: { "a.txt" => "1\n" }, message: "older")
        @repo.commit!(paths: { "a.txt" => "2\n" }, message: "newer")

        assert_equal [ "newer", "older" ], @repo.log(limit: 10).map(&:message).map(&:strip)
      end

      def test_log_is_empty_on_a_repo_with_no_commits_rather_than_raising
        @repo.hydrate!
        assert_empty @repo.log(limit: 10)
      end

      def test_blob_at_raises_notfound_for_a_path_that_is_not_in_that_commit
        @repo.hydrate!
        oid = @repo.commit!(paths: { "a.txt" => "1\n" }, message: "c")

        assert_raises(FileLayer::NotFound) { @repo.blob_at(oid:, path: "absent.md") }
      end

      # The managed marker is what tells OUR repo from one the maker made themselves, and it has to
      # survive the round trip or the distinction is worthless.
      def test_the_managed_marker_is_written_at_init_and_readable_after_a_rehydrate
        @repo.hydrate!
        @repo.commit!(paths: { "a.txt" => "1\n" }, message: "c")
        @repo.consolidate!
        @repo.persist!

        rebuilt = build_repo(@project.reload)
        rebuilt.discard_cache!
        rebuilt.hydrate!
        assert rebuilt.managed?, "the tinkerex.managed marker did not survive a persist/hydrate cycle"
      end

      def test_commit_records_the_head_in_the_bookkeeping_row
        @repo.hydrate!
        oid = @repo.commit!(paths: { "a.txt" => "1\n" }, message: "c")

        row = Maker::GitRepo.find_by(project: @project)
        assert_equal oid, row.head_oid
        assert row.last_commit_at.present?
      end

      # ---- what real git says about what we built -------------------------------------------
      #
      # THE LIFECYCLE TESTS ABOVE CANNOT PROVE THIS. They read back through the same rugged that
      # wrote it, which is the FakeS3 failure mode (§14e): an exactly-inverse encode/decode pair
      # kept 79 of 80 tests green over silent data loss. Only an independent reader settles it.

      def test_the_persisted_repository_passes_git_fsck_and_can_be_cloned
        skip "needs the git binary" unless system("git --version > /dev/null 2>&1")

        @repo.hydrate!
        @repo.commit!(paths: { "docs/notes.md" => "one\n" }, message: "one")
        @repo.commit!(paths: { "docs/notes.md" => "two\n" }, message: "two")
        @repo.consolidate!
        @repo.persist!

        rebuilt = build_repo(@project.reload)
        rebuilt.discard_cache!
        rebuilt.hydrate!
        dir = rebuilt.git_dir

        assert system("git -C #{dir} fsck --full --strict > /dev/null 2>&1"),
               "git rejected a repository this app built"
        assert_equal "2", `git -C #{dir} rev-list --count HEAD`.strip,
                     "HEAD must resolve to the branch we commit to, not libgit2's init default"

        Dir.mktmpdir do |dest|
          assert system("git clone -q #{dir} #{dest}/c > /dev/null 2>&1"), "git could not clone it"
          assert_equal "two\n", File.read("#{dest}/c/docs/notes.md")
        end
      ensure
        rebuilt&.discard_cache!
      end

      # `rev-list HEAD`, NOT `rev-list refs/heads/main` -- and the difference is a real bug this
      # caught. libgit2's init_at writes HEAD as `refs/heads/master` while this app commits to
      # `main`, so a repo whose HEAD was left alone has its history intact and INVISIBLE: `git log`
      # answers "your current branch 'master' does not have any commits yet". Naming the branch
      # explicitly, as the plan's version did, passes either way and hides it.
      def test_git_log_in_the_project_folder_shows_the_history_on_a_backend_operated_in_place
        skip "needs the git binary" unless system("git --version > /dev/null 2>&1")
        @repo.hydrate!
        skip "this backend has no work tree; the repo lives in an ephemeral cache" unless work_tree

        # THE FILE IS PUT ON DISK FIRST, because that is the real shape: the sweep commits files
        # that are ALREADY in the project folder, and in place that folder IS the work tree. A
        # commit whose content exists only in git objects is honestly reported by `git status` as
        # a deletion, so asserting a clean tree without writing the file would be asserting
        # something production never does.
        FileUtils.mkdir_p(work_tree.join("docs"))
        File.write(work_tree.join("docs/notes.md"), "one\n")
        @repo.commit!(paths: { "docs/notes.md" => "one\n" }, message: "a commit the maker can see")

        log = `git -C #{work_tree} log --oneline 2>&1`
        assert_match(/a commit the maker can see/, log,
                     "the maker must get `git log` in their own project folder -- got: #{log}")
        # `--porcelain` AND EMPTY, not "the first line names the branch" -- which is what an earlier
        # version of this assertion checked, and it was VACUOUS: without a written index the output
        # is `## main`, `D docs/notes.md`, `?? docs/notes.md`, so the FIRST LINE passes either way.
        # Mutation-checked: removing `index.write` left it green. What the maker actually sees is
        # every tracked file reported as DELETED in their own folder, which reads as "the app
        # deleted my files", so the thing to assert is that there is nothing to report at all.
        assert_empty `git -C #{work_tree} status --porcelain 2>&1`.strip,
                     "an unwritten index makes `git status` report every tracked file as DELETED"
      end
    end

    # ── IN PLACE: the library is a real filesystem, so the repo IS the project's own `.git` ──
    #
    # This is the shape that gives the maker `git log` in Finder, which is the strongest single
    # argument for git over a bespoke version store -- so it is asserted, not assumed.
    class RepoInPlaceTest < ActiveSupport::TestCase
      include GitRepoLifecycle

      teardown { FileUtils.remove_entry(@root) if @root&.exist? }

      # BUILT LAZILY, NOT IN `setup`. ActiveSupport runs setup callbacks in DECLARATION order, and
      # `include GitRepoLifecycle` is declared first -- so the module's own setup (which builds the
      # project and the repo) would run before an includer's `setup` had made the adapter.
      def adapter
        @root ||= Pathname.new(Dir.mktmpdir("git-repo-share"))
        @adapter ||= FileLayer::Share.new(root: @root.to_s)
      end

      def work_tree
        dir = adapter.repo_data_dir(@user, project: @project)
        dir && Pathname.new(dir).parent
      end
    end

    # ── HYDRATED: no local filesystem, so the repo is rebuilt into an ephemeral cache ──────────
    #
    # Driven against S3 because it is the backend whose fake is hermetic; the code path under test
    # is `repo_data_dir -> nil`, which chunk_remote answers identically. What matters is that
    # everything the cache holds can be thrown away and rebuilt from library bytes alone.
    class RepoHydratedTest < ActiveSupport::TestCase
      include GitRepoLifecycle

      PREFIX = "library".freeze

      # Lazy for the same reason the share includer's is -- see its comment.
      def adapter
        @fake ||= FakeS3.new
        @adapter ||= FileLayer::S3.new(bucket: "b", region: "us-east-1", access_key_id: "ak",
                                       secret_access_key: "sk", prefix: PREFIX, client: @fake.client)
      end

      # No work tree at all -- the bytes live in a bucket.
      def work_tree = nil
    end
  end
end
