require "test_helper"
require "support/git_repo_fixture"

module Maker
  # STAGE 3, S3-5: creating a release from what the project holds right now. A release records
  # REFERENCES, never bytes, so what these cases pin is which rows are captured, the token and size
  # the port reported for each, and the two ways a tag can be resolved — verified against a
  # repository the process can read, or recorded as typed where it cannot.
  #
  # A FRESH SHARE LIBRARY PER TEST, PINNED BEFORE ANY NODE EXISTS. The fixture writes real files and
  # a real git repository, so this suite cannot ride the ambient backend: on s3 and chunk_remote the
  # folder mkdir alone is a Forbidden / a provisioning refusal (the same reason
  # project_repo_card_test.rb pins share). The one case that is ABOUT a non-local backend fakes the
  # capability instead, which is the honest instrument — the files still need real bytes.
  class ReleaseSnapshotTest < ActiveSupport::TestCase
    include GitRepoFixture

    setup do
      @root = use_fresh_share_library!
      @library = @root
      @user = User.create!(email: "snap-#{SecureRandom.hex(4)}@example.com")
      @project = @user.maker_projects.create!(name: "Desk Lamp")
    end

    # The house mutation-check helper (readme_test.rb and project_repo_card_test.rb carry the same
    # body; there is no shared copy in test_helper.rb). Replaces ONE INSTANCE's singleton method —
    # here FileLayer.current's, which is memoised for the process, so every caller inside the block
    # sees the replacement.
    def replacing(owner, name, replacement)
      mod = owner.singleton_class
      own = mod.instance_methods(false).include?(name)
      original = mod.instance_method(name)
      mod.define_method(name, &replacement)
      yield
    ensure
      own ? mod.define_method(name, original) : mod.remove_method(name)
    end

    def folder_path = File.join(@root.to_s, Maker::ProjectFolders::ROOT, @project.slug)

    # Writes real files under the project's own folder and indexes them. `ensure_library_folder!` is
    # a real mkdir through the port — safe here because the backend is pinned share, and it is what
    # gives the two dir rows their storage_path so the scan pairs rather than duplicates them.
    def seed_folder!(files)
      @project.ensure_library_folder!(@user)
      files.each do |rel, body|
        path = File.join(folder_path, rel)
        FileUtils.mkdir_p(File.dirname(path))
        File.write(path, body)
      end
      Library::ScanJob.new.perform(user_id: @user.id)
    end

    # A real git repository INSIDE the project's folder, committed once and indexed. Not
    # GitRepoFixture#make_repo!, which resolves its return node with a bare `name:` lookup and no
    # parent (project_repo_card_test.rb makes the same choice for the same reason).
    def seed_repo!(name: "firmware", tags: [], annotated_tags: [])
      folder = @project.ensure_library_folder!(@user)
      dir = File.join(folder_path, name)
      FileUtils.mkdir_p(dir)
      repo = Rugged::Repository.init_at(dir)
      File.write(File.join(dir, "main.c"), "int main(void) { return 0; }\n")

      index = repo.index
      index.add(path: "main.c", oid: Rugged::Blob.from_workdir(repo, "main.c"), mode: 0o100644)
      index.write
      who = { name: "Seed", email: "seed@example.com", time: Time.at(1_700_000_000) }
      oid = Rugged::Commit.create(repo, tree: index.write_tree(repo), message: "Bring up firmware",
                                  parents: [], update_ref: "HEAD", author: who, committer: who)
      tags.each { |t| repo.tags.create(t, oid) }
      annotated_tags.each { |t| repo.tags.create(t, oid, message: "Release", tagger: who) }

      Library::ScanJob.new.perform(user_id: @user.id)
      [ @user.nodes.present.find_by!(parent_node_id: folder.node_id, name:, kind: "dir"), oid.to_s ]
    end

    def snapshot(**kwargs)
      Maker::ReleaseSnapshot.call(user: @user, project: @project, version: "v0.1.0", **kwargs)
    end

    test "every non-backup file in the folder is captured with the port's token and size" do
      seed_folder!("README.md" => "# Desk Lamp\n", "models/base.stl" => "solid base\n")

      result = snapshot

      assert_equal 2, result.file_count
      files = result.release.files.to_a
      assert_equal %w[README.md base.stl].sort, files.map(&:name).sort
      files.each do |file|
        node = @user.nodes.find_by!(node_id: file.node_id)
        assert_equal node.content_hash, file.content_token,
          "the recorded token must be what the port reported, not a value invented here"
        assert_equal node.size, file.size
        assert_predicate file.content_token, :present?
      end
    end

    # A LightBurn rescue copy is not something a maker released. The listing already diverts it out
    # of the tree into its own cross-cutting group, so this asserts the snapshot reads that group's
    # rows and drops them rather than silently inheriting whatever `all_rows` returns.
    test "a backup rescue copy is not part of a release" do
      seed_folder!("panel.lbrn2" => "<lbrn/>", "panel_backup.lbrn2" => "<lbrn/>")

      result = snapshot

      assert_equal [ "panel.lbrn2" ], result.release.files.map(&:name)
    end

    test "the recorded path is folder-relative, not the full library path" do
      seed_folder!("README.md" => "# Desk Lamp\n", "models/base.stl" => "solid base\n")

      paths = snapshot.release.files.map(&:path)

      assert_equal %w[README.md models/base.stl], paths.sort
    end

    test "the current BOM's id and revision are recorded" do
      seed_folder!("README.md" => "hi\n")
      @project.boms.create!(user: @user, revision: 1)
      current = @project.boms.create!(user: @user, revision: 2)

      release = snapshot.release

      assert_equal current.id, release.bom_id
      assert_equal 2, release.bom_revision
    end

    test "a project with no BOM records neither an id nor a revision" do
      seed_folder!("README.md" => "hi\n")

      release = snapshot.release

      assert_nil release.bom_id
      assert_nil release.bom_revision
    end

    # ONE `stat_all` FOR THE WHOLE FOLDER, NEVER ONE `stat` PER FILE — the same constancy rule the
    # pages keep (§14a: a bulk caller holds a list). A per-row rewrite calls `stat_all` zero times
    # and `stat` once per file, so both halves are asserted: the count alone would pass a mutation
    # that merely moved the call.
    test "the port is asked exactly once, however many files there are" do
      seed_folder!("a.stl" => "a\n", "b.stl" => "b\n", "models/c.stl" => "c\n",
                   "models/deep/d.stl" => "d\n")
      adapter = FileLayer.current
      bulk = adapter.method(:stat_all)
      single = adapter.method(:stat)
      bulk_calls = 0
      single_calls = 0

      # BOTH COUNTERS DELEGATE, so the mutation this exists to catch (a per-row `stat`) still
      # produces a correct-looking release and fails on the COUNTS below rather than incidentally
      # on a file that went missing — the assertion that carries the claim is the one that goes red.
      replacing(adapter, :stat_all, ->(user, node_ids:) { bulk_calls += 1; bulk.call(user, node_ids:) }) do
        replacing(adapter, :stat, ->(user, node_id:) { single_calls += 1; single.call(user, node_id:) }) do
          assert_equal 4, snapshot.file_count
        end
      end

      assert_equal 1, bulk_calls, "a release reads the whole folder in one stat_all"
      assert_equal 0, single_calls, "no per-file stat — that is the shape this rule forbids"
    end

    test "a folder with no files still produces a release, and asks the port nothing" do
      @project.ensure_library_folder!(@user)
      adapter = FileLayer.current
      calls = 0

      replacing(adapter, :stat_all, ->(_user, node_ids:) { calls += 1; {} }) do
        assert_equal 0, snapshot.file_count
      end

      assert_equal 0, calls
      assert_equal 1, @project.releases.count
    end

    # `stat_all` answers with an ABSENT KEY for a node it cannot see, never a raise (§14a), so a row
    # tombstoned between the listing and the stat is skipped rather than fatal.
    test "a row the port no longer reports is skipped, not fatal" do
      seed_folder!("kept.stl" => "k\n", "vanished.stl" => "v\n")
      adapter = FileLayer.current
      bulk = adapter.method(:stat_all)
      gone = @user.nodes.present.find_by!(name: "vanished.stl").node_id

      result = replacing(adapter, :stat_all, ->(user, node_ids:) { bulk.call(user, node_ids:).except(gone) }) do
        snapshot
      end

      assert_equal 1, result.file_count
      # THE SKIP IS COUNTED, NOT SILENT: a release taken while a scan tombstones rows records fewer
      # files than the folder held, and the result says how many (S3-5's review).
      assert_equal 1, result.skipped
      assert_equal [ "kept.stl" ], @project.releases.first.files.map(&:name)
    end

    # A PERMANENT RECORD MUST NOT CLAIM COMPLETENESS IT DOES NOT HAVE. The listing's FILE_CAP is a
    # page's render budget; the snapshot passes its own, and when even that is exceeded the result
    # says so, for the flash and the panel to repeat (S3-5's review, HIGH). Exercised through an
    # injected cap of 1, because building five thousand nodes is not a test.
    test "a folder past the snapshot's cap records the first files and reports truncation" do
      seed_folder!("a.stl" => "a\n", "b.stl" => "b\n")

      capped = Maker::ReleaseSnapshot.new(user: @user, project: @project, file_cap: 1)
                                     .call(version: "v0.1.0", notes: nil, git_tag: nil, repo_node_id: nil)

      assert_equal true, capped.truncated
      assert_equal true, capped.release.reload.files_truncated, "the flash is gone in a second; the row is what the panel reads back"
      assert_equal 1, capped.file_count
      assert_equal 0, capped.skipped, "truncation is not a skip: the port answered for every row it was asked about"

      assert_equal false, snapshot(version: "v0.2.0").truncated, "two files are well inside the default cap"
    end

    # A TAG PAST THE PICKER'S CAP STILL VERIFIES. `LocalRepo#tags` is bounded for the picker;
    # verification asks `#tag(name)` directly, so a repository with more tags than TAG_CAP can
    # still release on its newest one (S3-5's review, HIGH: the capped list refused a real tag).
    test "a tag the picker's capped list leaves out is still verified" do
      names = (Maker::Git::LocalRepo::TAG_CAP + 1).times.map { |i| format("v%04d", i) }
      repo, oid = seed_repo!(tags: names)
      last = names.max

      result = snapshot(git_tag: last, repo_node_id: repo.node_id)

      assert_equal true, result.tag_verified
      assert_equal oid, result.release.git_oid
    end

    test "no tag records no tag, no oid and no repository" do
      seed_folder!("README.md" => "hi\n")

      result = snapshot

      assert_equal false, result.tag_verified
      assert_nil result.release.git_tag
      assert_nil result.release.git_oid
      assert_nil result.release.repo_node_id
    end

    test "a tag that exists in the picked repository is verified and records its commit" do
      repo, head = seed_repo!(tags: [ "v1.0.0" ])

      result = snapshot(git_tag: "v1.0.0", repo_node_id: repo.node_id)

      assert result.tag_verified, "a tag read out of a real repository is verified"
      assert_equal "v1.0.0", result.release.git_tag
      assert_equal head, result.release.git_oid
      assert_equal repo.node_id, result.release.repo_node_id
      assert_equal head[0, 8], result.release.short_oid
    end

    test "an annotated tag records the commit it peels to" do
      repo, head = seed_repo!(annotated_tags: [ "release-1" ])

      result = snapshot(git_tag: "release-1", repo_node_id: repo.node_id)

      assert_equal head, result.release.git_oid
    end

    # THE TRANSACTION, SEEN FROM THE ONLY DOOR THAT CAN REACH IT: a refused tag must leave nothing —
    # no release, no file rows — rather than a release that claims a tag nobody can resolve.
    test "a tag that is not in the repository refuses and creates nothing" do
      repo, = seed_repo!(tags: [ "v1.0.0" ])

      error = assert_raises(Maker::ReleaseSnapshot::TagNotFound) do
        snapshot(git_tag: "v9.9.9", repo_node_id: repo.node_id)
      end

      assert_match(/no tag v9\.9\.9 in firmware/, error.message)
      assert_equal 0, @project.releases.count
      assert_equal 0, Maker::ReleaseFile.where(user_id: @user.id).count
    end

    # WHAT THE TRANSACTION IS ACTUALLY FOR, and it is NOT the refused tag above: `resolve_tag`
    # raises before the transaction opens, so that case leaves nothing behind whether or not the
    # block exists. The state only a transaction prevents is a release row whose FILES failed to
    # insert — a release claiming a snapshot it does not have. The failure is forced at the insert
    # rather than argued about.
    test "a release whose file rows cannot be written leaves no release behind" do
      seed_folder!("README.md" => "hi\n", "models/base.stl" => "solid\n")

      assert_raises(RuntimeError) do
        replacing(Maker::ReleaseFile, :insert_all, ->(*) { raise "the insert failed" }) { snapshot }
      end

      assert_equal 0, @project.releases.count,
        "the release must roll back with the file rows it could not write"
    end

    test "a repository node that is not live refuses" do
      seed_folder!("README.md" => "hi\n")
      missing = SecureRandom.uuid

      error = assert_raises(Maker::ReleaseSnapshot::TagNotFound) do
        snapshot(git_tag: "v1.0.0", repo_node_id: missing)
      end

      assert_match(/no repository at #{missing}/, error.message)
      assert_equal 0, @project.releases.count
    end

    # A `.lock` IS REFUSED, NEVER DELETED (docs/invariants/git-editing.md). The refusal LocalRepo
    # already computes is what the maker is told, verbatim, rather than a second sentence here.
    test "a repository the port cannot read refuses with the reason LocalRepo gives" do
      repo, = seed_repo!(tags: [ "v1.0.0" ])
      File.write(File.join(folder_path, "firmware", ".git", "index.lock"), "")

      error = assert_raises(Maker::ReleaseSnapshot::TagNotFound) do
        snapshot(git_tag: "v1.0.0", repo_node_id: repo.node_id)
      end

      assert_match(/index\.lock/, error.message)
      assert_equal 0, @project.releases.count
    end

    # WHERE THE LIBRARY IS NOT A LOCAL FOLDER THE TAG IS RECORDED AS TYPED. The card's own rule:
    # ask the CAPABILITY, never the adapter class. `with` on the real Capabilities keeps every other
    # answer (the files still need real bytes underneath) — the honest fake for one fact.
    test "a non-local library records the tag unverified rather than refusing" do
      repo, = seed_repo!(tags: [ "v1.0.0" ])
      remote = FileLayer.current.capabilities.with(local_worktree: false)

      result = replacing(FileLayer.current, :capabilities, -> { remote }) do
        snapshot(git_tag: "v2.0.0-not-in-the-repo", repo_node_id: repo.node_id)
      end

      assert_equal false, result.tag_verified
      assert_equal "v2.0.0-not-in-the-repo", result.release.git_tag
      assert_nil result.release.git_oid, "nothing verified the tag, so no commit may be claimed"
      assert_nil result.release.repo_node_id, "nothing opened the repository, so none may be named"
    end

    test "the version and changelog reach the row" do
      seed_folder!("README.md" => "hi\n")

      release = snapshot(notes: "<div>Fixed the mount</div>").release

      assert_equal "v0.1.0", release.version
      assert_includes release.notes.body.to_html, "Fixed the mount"
      assert_in_delta Time.current, release.published_at, 5
    end

    test "a duplicate version raises rather than creating a second release" do
      seed_folder!("README.md" => "hi\n")
      snapshot

      assert_raises(ActiveRecord::RecordInvalid) { snapshot }
      assert_equal 1, @project.releases.count
    end
  end
end
