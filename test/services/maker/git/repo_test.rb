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

      # A pointer's blob body, shaped like Maker::Git::Tracking's but written out here: Repo does
      # not know what a pointer is and these tests are about what it does with a path that has no
      # file, not about the body's format (tracking_test.rb owns that).
      POINTER_BODY = "version tinkerex/v1\noid sha256:#{'a' * 64}\nsize 42\n".freeze

      def build_repo(project = @project)
        Maker::Git::Repo.for(project, adapter:, cache_root: @cache_root)
      end

      # THE TWO SKIPS EVERY IN-PLACE TEST BELOW NEEDS, with the hydrate between them in that order
      # -- `work_tree` asks the adapter, and the repository has to exist before there is anything
      # for git to look at.
      def hydrate_or_skip_without_a_work_tree!
        skip "needs the git binary" unless system("git --version > /dev/null 2>&1")
        @repo.hydrate!
        skip "this backend has no work tree; the repo lives in an ephemeral cache" unless work_tree
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

      # ---- repack: collapsing a year of commit windows ----------------------------------------
      #
      # #consolidate! writes one pack per commit WINDOW, which is right for the window and wrong for
      # a year of them: 365 daily windows is 365 packs and a hydrate fetches all of them.

      # ONE MORE THAN THE LIMIT, and driving the REAL constant rather than an injected one: a test
      # that passed its own threshold in would prove the parameter works and say nothing about
      # whether MAX_PACKS is consulted at all.
      def pack_up_to_the_limit!(count = Maker::Git::Repo::MAX_PACKS + 1)
        count.times do |i|
          @repo.commit!(paths: { "f#{i}.txt" => "#{i}\n" }, message: "c#{i}")
          @repo.consolidate!
        end
      end

      # THE LOG IS ASSERTED, NOT THE PACK COUNT ALONE. A repack that wrote one EMPTY pack and
      # deleted the other fifty-one passes any count-only test perfectly, and is total data loss.
      def test_repack_collapses_many_packs_into_one_and_keeps_every_commit
        @repo.hydrate!
        pack_up_to_the_limit!
        assert_equal Maker::Git::Repo::MAX_PACKS + 1, @repo.pack_idx_rels.size

        name = @repo.repack_all!

        assert_match(/\A[0-9a-f]{40}\z/, name)
        assert_equal [ "pack-#{name}.idx" ], @repo.pack_idx_rels.map { |r| File.basename(r) }
        assert_equal (0..Maker::Git::Repo::MAX_PACKS).map { |i| "c#{i}" }.reverse,
                     @repo.log(limit: 200).map(&:message).map(&:strip),
                     "the repack kept the pack count and lost the history"
        assert_equal "0\n", @repo.blob_at(oid: @repo.head_oid, path: "f0.txt"),
                     "the oldest blob must survive a repack, not merely the commits naming it"
      end

      # A repack reads and rewrites every object the repository has -- on a hydrated backend a full
      # download and a full re-upload. THE THRESHOLD is what keeps that rare, so it is the threshold
      # that is asserted.
      def test_repack_is_a_no_op_below_the_limit
        @repo.hydrate!
        pack_up_to_the_limit!(3)

        assert_nil @repo.repack_all!, "a repository with three packs has nothing to gain"
        assert_equal 3, @repo.pack_idx_rels.size
      end

      # WHERE IT ACTUALLY MATTERS. A hydrate reads the LIBRARY, so a repack that collapses only the
      # working directory leaves 365 fetches in place while the cache looks tidy. In place the
      # library IS the working directory, so this holds on both shapes and for different reasons --
      # which is why the mutation that proves it (drop the delete_repo_data call) goes red only on
      # the hydrated one.
      def test_repack_deletes_the_superseded_packs_from_the_library
        @repo.hydrate!
        pack_up_to_the_limit!
        @repo.persist!
        assert_equal Maker::Git::Repo::MAX_PACKS + 1, library_pack_rels.count { |r| r.end_with?(".idx") }

        name = @repo.repack_all!

        assert_equal [ "objects/pack/pack-#{name}.idx", "objects/pack/pack-#{name}.pack" ],
                     library_pack_rels.sort,
                     "the library kept the superseded packs; the repack tidied the cache and nothing else"
      end

      # THE ORDERING RULE, DRIVEN. Deleting first and writing second is §14a's copy-delete-tombstone
      # landmine with the stakes at their highest: a failure between the two leaves the repository
      # with no objects at all and nothing anywhere saying so.
      def test_a_failure_in_the_writer_leaves_every_pack_and_the_whole_history_intact
        @repo.hydrate!
        pack_up_to_the_limit!
        @repo.persist!
        before = @repo.pack_idx_rels.sort

        with_a_failing_pack_writer do
          assert_raises(RuntimeError) { @repo.repack_all! }
        end

        assert_equal before, @repo.pack_idx_rels.sort, "packs were deleted before the new one existed"
        assert_equal Maker::Git::Repo::MAX_PACKS + 1, library_pack_rels.count { |r| r.end_with?(".idx") }
        assert_equal "0\n", build_repo(@project.reload).hydrate!.blob_at(oid: @repo.head_oid, path: "f0.txt"),
                     "the repository must still hydrate out of the library after a failed repack"
      end

      # A multi-pack index NAMES the packs it covers, so deleting them behind it leaves git reading
      # a repository it believes is corrupt -- in place, the maker's own. This app never writes one;
      # a maker who ran `git multi-pack-index write` in their project folder does.
      def test_repack_declines_rather_than_deleting_packs_a_multi_pack_index_names
        @repo.hydrate!
        pack_up_to_the_limit!
        File.binwrite(File.join(@repo.git_dir, "objects/pack", "multi-pack-index"), "MIDX")

        assert_nil @repo.repack_all!
        assert_equal Maker::Git::Repo::MAX_PACKS + 1, @repo.pack_idx_rels.size
      end

      # WHAT REAL GIT SAYS ABOUT A REPACKED REPOSITORY, and it is the assertion with the most to
      # lose: everything above reads back through the same libgit2 that answered the enumeration, and
      # a repack is the one operation here that DELETES what it replaced. The rebuild is from LIBRARY
      # BYTES ALONE, so this pins the collapsed library as a complete repository too, not just the
      # working directory.
      def test_a_repacked_repository_is_one_git_itself_still_accepts
        skip "needs the git binary" unless system("git --version > /dev/null 2>&1")

        @repo.hydrate!
        pack_up_to_the_limit!
        @repo.persist!
        @repo.repack_all!

        rebuilt = build_repo(@project.reload)
        rebuilt.discard_cache!
        rebuilt.hydrate!
        dir = rebuilt.git_dir

        assert system("git -C #{dir} fsck --full --strict > /dev/null 2>&1"),
               "git rejected a repository this app repacked"
        assert_equal (Maker::Git::Repo::MAX_PACKS + 1).to_s,
                     `git -C #{dir} rev-list --count HEAD`.strip,
                     "every commit must survive the repack, counted by git rather than by rugged"
      ensure
        rebuilt&.discard_cache!
      end

      # HAND-ROLLED, NOT Object#stub: minitest 6 dropped minitest/mock, so `stub` does not exist in
      # this suite -- test_helper.rb says so in two places. The ensure-restore is load-bearing: a
      # leaked override makes every later test in this worker see a broken pack writer, a whole
      # debugging session away from here.
      def with_a_failing_pack_writer
        original = Maker::Git::PackWriter.method(:write)
        Maker::Git::PackWriter.define_singleton_method(:write) { |*| raise "the pack write failed" }
        yield
      ensure
        Maker::Git::PackWriter.define_singleton_method(:write, original)
      end

      # What the LIBRARY holds under objects/pack, asked through the port rather than off disk --
      # in place that is the same directory, on a hydrated backend it is the bucket.
      def library_pack_rels
        adapter.list_repo_data(@user, project: @project).select { |r| r.start_with?("objects/pack/") }
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

      # ---- a repository we did not create ------------------------------------------------------
      #
      # THE MARKER IS ONLY A MARKER IF IT IS READ BEFORE IT IS WRITTEN. `ensure_initialized!` wrote
      # `tinkerex.managed` unconditionally, so the one question it exists to answer was destroyed at
      # the moment of asking: a maker's own clone under `Projects/` was adopted on sight, and the
      # same pass then cleared their index and committed onto their `refs/heads/main`.

      # A REAL REPOSITORY WITH A REAL COMMIT AND NO MARKER -- what `git clone` leaves behind. It is
      # planted at `git_dir` rather than through the port because no port verb mints one: on share
      # git itself wrote it and the scan observed it, and on a hydrated backend it arrives as
      # repo data. Returns the head oid, which is what "untouched" is measured against.
      def plant_a_foreign_repository!
        FileUtils.mkdir_p(@repo.git_dir)
        their = ::Rugged::Repository.init_at(@repo.git_dir, true)
        their.config["user.name"] = "The Maker"
        index = their.index
        index.add(path: "THEIRS.md", oid: their.write("their own work\n", :blob), mode: 0o100644)
        signature = { name: "The Maker", email: "maker@example.com", time: Time.current.to_time }
        oid = ::Rugged::Commit.create(their, tree: index.write_tree(their), message: "mine",
                                             parents: [], author: signature, committer: signature,
                                             update_ref: Maker::Git::Repo::BRANCH)
        their.head = Maker::Git::Repo::BRANCH
        oid
      end

      # EVERY FILE'S CONTENT, NOT A COUNT AND NOT A LIST OF NAMES. "We did not commit" is a weaker
      # claim than "we wrote nothing at all": stamping the config key, clearing the index and
      # writing it back are each a silent mutation of the maker's own repository that no
      # commit-shaped assertion can see.
      def repository_digest(dir)
        Dir.glob("**/*", base: dir, flags: File::FNM_DOTMATCH)
           .reject { |rel| File.basename(rel).match?(/\A\.\.?\z/) }
           .reject { |rel| File.directory?(File.join(dir, rel)) }
           .sort
           .map { |rel| [ rel, Digest::SHA256.hexdigest(File.binread(File.join(dir, rel))) ] }
      end

      def test_hydrate_refuses_a_repository_this_app_did_not_create_and_writes_nothing
        theirs = plant_a_foreign_repository!
        before = repository_digest(@repo.git_dir)

        assert_raises(Maker::Git::Repo::UnmanagedRepository) { @repo.hydrate! }

        assert_equal before, repository_digest(@repo.git_dir),
                     "the refusal still wrote into a repository this app did not create"
        reopened = ::Rugged::Repository.new(@repo.git_dir)
        assert_equal theirs, reopened.references[Maker::Git::Repo::BRANCH].target_id,
                     "their branch was moved"
        assert_nil reopened.config[Maker::Git::Repo::MANAGED_CONFIG_KEY],
                   "we stamped our own marker into their config, which is how their repo becomes ours"
        assert_equal "The Maker", reopened.config["user.name"], "their config was rewritten"
        assert_nil Maker::GitRepo.find_by(project: @project)
      end

      # THE OVER-REFUSAL THAT WOULD BREAK EVERY ORDINARY PROJECT. A directory holding no repository
      # is not a repository -- you cannot create one by creating the folder -- so it is ours to
      # initialize. This is the ordinary FIRST-PASS state on the hydrated backends, whose #hydrate!
      # runs `mkdir_p(cache_dir)` before anything else, and it is what an empty `.git` a maker made
      # by hand looks like in place.
      def test_hydrate_initializes_a_directory_that_exists_but_holds_no_repository
        FileUtils.mkdir_p(@repo.git_dir)

        @repo.hydrate!
        oid = @repo.commit!(paths: { "a.txt" => "1\n" }, message: "c")

        assert_equal oid, @repo.head_oid
        assert @repo.managed?, "a repository we initialized must carry our marker"
      end

      # Fragments are not a repository either, and this is the corner where the init test and the
      # refusal test are the SAME question -- "can libgit2 open this?" -- rather than two spellings
      # that can disagree about a half-written directory.
      def test_hydrate_initializes_a_directory_holding_fragments_but_no_repository
        FileUtils.mkdir_p(File.join(@repo.git_dir, "objects"))

        @repo.hydrate!

        assert @repo.commit!(paths: { "a.txt" => "1\n" }, message: "c")
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
      # BOTH SHAPES OF TRACKED PATH, WHICH IS THE GAP THIS TEST HAD. It has always asserted the
      # right thing -- `--porcelain` and EMPTY -- but its fixture committed CONTENT ONLY, and it
      # writes a content file to disk first, so the tracked path always had a file behind it. A
      # POINTER never does: `core.stl.ptr` stands in for bytes that live at `core.stl`, and nothing
      # anywhere writes a `.ptr` file. So the assertion passed for content and was NEVER EXERCISED
      # FOR POINTERS, which is exactly where the defect was -- measured on the share box
      # (tinkerex#173): `Projects/laser-mount` reported 13 ` D` lines, every one a `.ptr` path whose
      # real file was present right beside it.
      #
      # THE REAL BINARY IS DELIBERATELY NOT WRITTEN BESIDE THE POINTER HERE. On the box it is there
      # and shows as `??`, which is TRUE -- binaries are deliberately not tracked -- and out of this
      # fix's scope; writing one would make `--porcelain` non-empty for something that is not a
      # defect and cost this assertion its strength. `project_commit_test.rb` drives the full
      # fixture, untracked binary and all, and asserts the `??` line is the ONLY one.
      def test_git_log_in_the_project_folder_shows_the_history_on_a_backend_operated_in_place
        hydrate_or_skip_without_a_work_tree!

        # THE CONTENT FILE IS PUT ON DISK FIRST, because that is the real shape: the sweep commits
        # files that are ALREADY in the project folder, and in place that folder IS the work tree.
        # A content commit whose bytes exist only in git objects is honestly reported by `git
        # status` as a deletion, so asserting a clean tree without writing the file would be
        # asserting something production never does.
        FileUtils.mkdir_p(work_tree.join("docs"))
        File.write(work_tree.join("docs/notes.md"), "one\n")
        @repo.commit!(paths: { "docs/notes.md" => "one\n", "core.stl.ptr" => POINTER_BODY },
                      message: "a commit the maker can see",
                      absent_from_work_tree: [ "core.stl.ptr" ])

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
                     "a tracked path with no file -- an unwritten index, or a pointer -- makes " \
                     "`git status` report it as DELETED in the maker's own folder"
        # THE MARK ITSELF, BOTH WAYS ROUND. `h` is assume-unchanged, `H` is an ordinary cached
        # entry. Asserting only the clean status would pass with the flag on EVERY entry, which is
        # the worse bug (see the next test but one); asserting both lines pins the split.
        marks = `git -C #{work_tree} ls-files -v`.lines.map(&:strip)
        assert_includes marks, "h core.stl.ptr",
                        "a pointer's path has no file on purpose and must be marked as such"
        assert_includes marks, "H docs/notes.md",
                        "a content file IS in the work tree and must stay an ordinary entry"
      end

      # THE HALF THAT IS EASY TO MISS. `commit!` rebuilds the index from nothing every pass, so the
      # entries `carry_forward` brings back from HEAD arrive with no flag -- a pointer committed on
      # Monday reports ` D` again on Tuesday, and a fix that only marks the paths a pass NAMES
      # works for exactly one commit before silently reverting.
      #
      # THE SECOND PASS DELIBERATELY DOES NOT NAME THE POINTER, in `paths:` or in
      # `absent_from_work_tree:`, and that is the production case rather than a contrived one: a
      # pass only names nodes that SETTLED, so a binary still being written -- or one since deleted
      # from the library -- is carried forward without being mentioned at all.
      def test_a_pointer_from_an_earlier_pass_is_still_clean_after_a_later_one
        hydrate_or_skip_without_a_work_tree!

        File.write(work_tree.join("notes.md"), "one\n")
        @repo.commit!(paths: { "notes.md" => "one\n", "core.stl.ptr" => POINTER_BODY },
                      message: "first pass", absent_from_work_tree: [ "core.stl.ptr" ])

        File.write(work_tree.join("notes.md"), "two\n")
        assert @repo.commit!(paths: { "notes.md" => "two\n" }, message: "second pass"),
               "fixture is inverted: the second pass must actually commit, or it never rewrites " \
               "the index and this test cannot fail"

        assert_empty `git -C #{work_tree} status --porcelain 2>&1`.strip,
                     "a pointer carried forward from HEAD lost its mark and reads as DELETED again"
        assert_includes `git -C #{work_tree} ls-files -v`.lines.map(&:strip), "h core.stl.ptr"
      end

      # THE OTHER DIRECTION, AND IT IS THE WORSE LIE OF THE TWO. Assume-valid tells git to stop
      # consulting the file, so on a CONTENT entry it would report a clean tree while the maker's
      # own edit sat unrecorded. The ` D` this fix removes was alarming and false; this would be
      # reassuring and false, and a maker would find out when a version went missing from the
      # history rather than immediately.
      def test_marking_pointers_does_not_stop_a_real_edit_showing_as_modified
        hydrate_or_skip_without_a_work_tree!

        File.write(work_tree.join("notes.md"), "one\n")
        @repo.commit!(paths: { "notes.md" => "one\n", "core.stl.ptr" => POINTER_BODY },
                      message: "first pass", absent_from_work_tree: [ "core.stl.ptr" ])
        File.write(work_tree.join("notes.md"), "the maker changed this\n")

        # `.lines` AND `chomp`, NEVER `strip`: porcelain's status is the FIRST TWO COLUMNS, so an
        # unstaged modification is " M notes.md" with a leading space and stripping it away turns
        # this into an assertion about a different thing.
        assert_equal [ " M notes.md" ],
                     `git -C #{work_tree} status --porcelain 2>&1`.lines.map(&:chomp),
                     "a content file's edit must still be visible -- the mark is for paths that " \
                     "have no file, and a content path has one"
      end

      # RUNS ON BOTH SHAPES, WHICH IS THE POINT: it is what says a cache-backed backend is
      # UNAFFECTED rather than merely believed to be. The mark is index state and a TREE carries
      # mode and oid only, so a repository whose pointers gained it must still answer nil to an
      # otherwise identical pass -- if it did not, every existing repository would mint one
      # meaningless commit the first time this shipped, and the sweep would do it forever.
      def test_marking_a_path_absent_from_the_work_tree_is_not_part_of_the_tree
        @repo.hydrate!
        oid = @repo.commit!(paths: { "core.stl.ptr" => POINTER_BODY }, message: "first",
                            absent_from_work_tree: [ "core.stl.ptr" ])

        assert_equal POINTER_BODY, @repo.blob_at(oid:, path: "core.stl.ptr")
        assert_nil @repo.commit!(paths: { "core.stl.ptr" => POINTER_BODY }, message: "second",
                                 absent_from_work_tree: [ "core.stl.ptr" ]),
                   "the mark must not reach the tree, or an unchanged pass mints a commit"
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

      # A `.git` that is a FILE is a `gitdir:` pointer -- what `git worktree add` and a submodule
      # write -- so the project folder is somebody else's linked working tree. IN PLACE ONLY,
      # because it is a property of the maker's own folder: on a hydrated backend `git_dir` is our
      # cache, and #hydrate!'s own `mkdir_p` would meet the file first.
      #
      # THE POINTER'S TARGET IS DELIBERATELY MISSING, which is the corner the open cannot answer:
      # libgit2 raises OSError trying to resolve it, which without a guard reads as "nothing here"
      # and sends `mkdir_p` at an existing file. A pointer whose target resolves is refused by the
      # marker check instead, since it opens the MAIN repository and that carries no marker.
      def test_hydrate_refuses_a_gitdir_pointer_file_where_our_repository_would_go
        File.write(@repo.git_dir, "gitdir: #{@root.join('nowhere/.git/worktrees/x')}\n")

        assert_raises(Maker::Git::Repo::UnmanagedRepository) { @repo.hydrate! }

        assert_equal "gitdir: #{@root.join('nowhere/.git/worktrees/x')}\n", File.read(@repo.git_dir),
                     "the pointer file was overwritten"
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
