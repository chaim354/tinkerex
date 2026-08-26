require "test_helper"

module Library
  # THE ONE-TIME PURGE, and its reason is arithmetic rather than tidiness: once the observers stop
  # descending into `.git`, every node already indexed beneath one VANISHES in a single pass. The
  # mass-deletion guard is a percentage with no floor, so a repo-heavy library trips it and the
  # scan is refused — that scan and every scan after it — until someone overrides the threshold.
  class RepoMetadataPurgeTest < ActiveSupport::TestCase
    setup do
      @user = User.create!(email: "purge-#{SecureRandom.hex(4)}@example.com",
                           confirmed_at: Time.current, omniauth_signup: true)
      @dirs = {}
      # THE BACKEND IS PINNED, NOT INHERITED, AND EVERY TEST BELOW DEPENDS ON IT.
      # RepoMetadataPurge.call gates on FileLayer.current.capabilities.scannable?, so a suite
      # that took the ambient LIBRARY_BACKEND asserted about a purge that DECLINED on the
      # chunk_remote leg — eight tests failing there while share and s3 stayed green purely
      # because their ambient backend happens to be scannable. §15 names that shape as a bug in
      # its own right, and the negatives test was WORSE than a failure: it asserts
      # `destroyed == 0`, which a declined run satisfies for free.
      #
      # `use_fresh_share_library!` (a direct FileLayer.current =) rather than
      # pin_file_layer_backend, for the reason rescan_test.rb states: pin rebuilds from ENV, and a
      # Share adapter needs a tmpdir ROOT that ENV does not supply on the other two legs. The
      # teardown reset is load-bearing rather than decoration — a direct assignment does not set
      # test_helper's @file_layer_backend_pinned, so its teardown will not clean up after this one.
      @root = use_fresh_share_library!
    end

    teardown do
      FileLayer.reset!
      FileUtils.remove_entry(@root) if @root&.exist?
    end

    # SHARE-SHAPED FIXTURES: storage_path AND a real parent chain, which is what
    # Library::Reconciler actually writes on share and s3 — #create_or_revive! and #ensure_dirs
    # both set parent_node_id. A fixture carrying storage_path ALONE is a shape no backend
    # produces, and building the tests on one would make them agree with a purge that reads only
    # that column — the exact mistake the chunk_remote test below exists to catch.
    def dir(rel)
      @dirs[rel] ||= begin
        parent = File.dirname(rel)
        @user.nodes.create!(node_id: SecureRandom.uuid, name: File.basename(rel), kind: "dir",
                            storage_path: rel,
                            parent_node_id: (dir(parent).node_id unless parent == "."))
      end
    end

    def file(rel)
      parent = File.dirname(rel)
      @user.nodes.create!(node_id: SecureRandom.uuid, name: File.basename(rel), kind: "file",
                          storage_path: rel, size: 1,
                          parent_node_id: (dir(parent).node_id unless parent == "."))
    end

    test "nodes beneath .git are destroyed and the MARKER itself survives" do
      dir("firmware/.git")
      file("firmware/.git/config")
      file("firmware/.git/objects/ab/cdef")
      file("firmware/main.cpp")

      result = RepoMetadataPurge.call

      # The whole surviving tree, asserted as a set rather than row by row: the marker lives (it is
      # what detects a working tree), its own parent lives, the source file lives, and everything
      # between the marker and a blob — the two synthesized object directories included — is gone.
      assert_equal [ "firmware", "firmware/.git", "firmware/main.cpp" ],
                   @user.nodes.order(:storage_path).pluck(:storage_path)
      assert_equal 4, result.destroyed,
                   "two files and the two directories synthesized between them"
      assert_empty result.skipped
    end

    test "a node carrying an attachment is REPORTED, never destroyed" do
      hook = file("firmware/.git/hooks/pre-commit")
      project = @user.maker_projects.create!(name: "Lamp")
      project.file_attachments.create!(user: @user, node_id: hook.node_id, role: "other")

      result = RepoMetadataPurge.call

      assert Node.exists?(hook.id),
             "destroying an attached node silently orphans a project reference"
      assert_equal [ hook.node_id ], result.skipped.map(&:node_id)
      assert_equal 0, result.destroyed
    end

    # A skipped node whose ancestors were destroyed is a live row hanging off a parent_node_id that
    # resolves to nothing — an orphan of a different kind, and one that goes SILENT: the second run
    # can no longer rebuild the path, so the node it refused to destroy stops being reported at all.
    # The skip exists to be loud; a skip that reports once and then forgets is not.
    test "the ancestors of a skipped node are kept, so a re-run still reports it" do
      hook = file("firmware/.git/hooks/pre-commit")
      project = @user.maker_projects.create!(name: "Lamp")
      project.file_attachments.create!(user: @user, node_id: hook.node_id, role: "other")

      RepoMetadataPurge.call

      assert_equal [ hook.node_id ], RepoMetadataPurge.call.skipped.map(&:node_id)
      assert_includes @user.nodes.pluck(:storage_path), "firmware/.git/hooks"
    end

    # The negatives that a PREFIX match would take out. `.gitignore` alone does not bite one:
    # it is the LAST segment, so `start_with?(".git")` still answers "the marker is its own path"
    # and internal? stays false. `.github/workflows/ci.yml` is the case that actually falls —
    # positioned here deliberately, because a negative no plausible mutation can reach is
    # decoration.
    test "paths merely NAMED like the marker are untouched" do
      keep = [ file(".gitignore"), file("firmware/.gitignore"),
               file(".github/workflows/ci.yml"), file("notes/git/todo.txt") ]

      assert_equal 0, RepoMetadataPurge.call.destroyed
      keep.each { |n| assert Node.exists?(n.id), "#{n.storage_path} is not repository metadata" }
    end

    test "it is idempotent — a second run destroys nothing" do
      dir("firmware/.git")
      file("firmware/.git/config")

      assert_equal 1, RepoMetadataPurge.call.destroyed
      assert_equal 0, RepoMetadataPurge.call.destroyed
    end

    # A NULL `storage_path` is not a chunk_remote curiosity, and this is the SHAPE test for it: a
    # purge reading only that column answers `false` here and destroys nothing. It is the shape a
    # chunk_remote mirror row has (§14a — ChangelogSync#upsert writes parent_node_id and never
    # storage_path), and, on the scannable backends this service actually runs on, the shape a
    # TRASH-KIND TOMBSTONE has; the next test drives that one through the real door.
    test "a node with a NULL storage_path is resolved by its parent chain" do
      repo = @user.nodes.create!(node_id: SecureRandom.uuid, name: "firmware", kind: "dir")
      marker = @user.nodes.create!(node_id: SecureRandom.uuid, name: ".git", kind: "dir",
                                   parent_node_id: repo.node_id)
      inner = @user.nodes.create!(node_id: SecureRandom.uuid, name: "config", kind: "file",
                                  parent_node_id: marker.node_id, size: 1)

      RepoMetadataPurge.call

      assert Node.exists?(marker.id)
      assert_not Node.exists?(inner.id)
    end

    # THE SHAPE ABOVE, REACHED THE WAY A REAL SHARE LIBRARY REACHES IT. `FileLayer::Share#delete`
    # ends `update!(deleted: true, storage_path: nil)` — it nulls the column deliberately, so
    # Reconciler#create_or_revive! cannot revive the row onto a new file dropped at that path. So a
    # file trashed out of a `.git` before this arc landed is a live-parented row with no path, on a
    # backend the scannable gate DOES cover. Without the parent chain every one of them survives
    # the purge.
    test "a trash-kind tombstone beneath the marker (path released) is purged too" do
      dir("firmware/.git")
      hook = file("firmware/.git/pre-commit")
      hook.update!(deleted: true, storage_path: nil)

      assert_equal 1, RepoMetadataPurge.call.destroyed
      assert_not Node.exists?(hook.id)
    end

    # THE SCANNABLE GATE, asserted as a SURVIVAL rather than as "a share-shaped node is destroyed"
    # — the second can pass while the gate does nothing at all. Constructing the adapter needs no
    # sync server (`capabilities` is a constant and no port call is made), the precedent
    # rescan_test.rb states for the same construction.
    test "a non-scannable backend is DECLINED, and its mirror rows survive untouched" do
      repo = @user.nodes.create!(node_id: SecureRandom.uuid, name: "firmware", kind: "dir")
      marker = @user.nodes.create!(node_id: SecureRandom.uuid, name: ".git", kind: "dir",
                                   parent_node_id: repo.node_id)
      inner = @user.nodes.create!(node_id: SecureRandom.uuid, name: "config", kind: "file",
                                  parent_node_id: marker.node_id, size: 1)
      # OVERRIDES setup's scannable pin, which is the other direction of the same rule: without
      # this line the test asserts a decline that only happens on the chunk_remote leg, so on
      # share and s3 — where it would be green — the gate is not exercised at all. Mutation-
      # checked by deleting it. Constructing the adapter needs no sync server: `capabilities` is
      # a constant and the gate returns before any port call, the precedent rescan_test.rb states
      # for the same construction. teardown does the restore.
      FileLayer.current = FileLayer::ChunkRemote.new

      result = RepoMetadataPurge.call

      # THE SURVIVAL ASSERTION GOES FIRST, and the order is the point rather than taste: removing
      # the gate makes `declined` false too, so a `declined` assertion above this one would fail
      # first and report a flag instead of the harm. This line names the harm.
      assert Node.exists?(inner.id),
             "the mirror is the sync server's tree — destroying rows makes it lie (§14a), and " \
             "node.rb records these as HIDDEN rather than removed"
      assert Node.exists?(marker.id)
      assert result.declined, "an operator must not read a declined run as `destroyed 0`"
      assert_equal 0, result.destroyed
    end

    # AN ENVIRONMENT THAT CANNOT CONSTRUCT A BACKEND AT ALL DECLINES — the SECOND decline reason,
    # and the one `bin/ci setup` broke on. This service asks FileLayer.current for a capability,
    # and on a fresh clone with nothing configured it is that CONSTRUCTION which fails, so the
    # PurgeRepoMetadataNodes migration aborted `db:prepare` with `KeyError: key not found:
    # "LIBRARY_PATH"`. A backend that cannot be built has indexed nothing and scans nothing away,
    # so declining is the same no-op a fresh database already takes — an ANSWER rather than a crash.
    #
    # THE RESCUE IS SCOPED TO THE PORT LOOKUP AND MUST STAY THERE. Widened around the sweep it
    # would swallow a real breakage inside the purge and report success; the migration's own
    # comment states that rule about its NameError rescue, and this is the same rule one method
    # down (§15). LibraryBackendCheck::Error specifically, NOT StandardError: an unknown
    # LIBRARY_BACKEND still raises ArgumentError out of FileLayer.build, because that is a
    # MISCONFIGURED DEPLOYMENT rather than an unconfigured developer and §14a wants it loud.
    test "an environment with no library backend configured DECLINES rather than raising" do
      inner = file("firmware/.git/config")

      result = with_unconfigured_backend { RepoMetadataPurge.call }

      # The harm first, as the chunk_remote test above explains: a flag is not the thing at stake.
      assert Node.exists?(inner.id), "a purge that could not even look must destroy nothing"
      assert result.declined, "an operator must not read a declined run as `destroyed 0`"
      assert_equal 0, result.destroyed
      assert_match(/no library backend is configured/, result.reason)
    end

    # THE TWO DECLINE REASONS MUST READ DIFFERENTLY, which is the whole reason `reason` exists and
    # the reason the migration prints it instead of re-deriving one. Both are `declined: true` with
    # `destroyed: 0`, and they mean opposite things: a chunk_remote decline is CORRECT and is
    # recorded as expected output in docs/DEPLOY.md, while an unconfigured environment declining on
    # a real deployment means the purge did not happen. One shared sentence makes the second
    # unreadable — and printing the first one's text ("FileLayer::ChunkRemote is not a scannable
    # backend") for it would be an actively FALSE statement about a deployment holding no
    # ChunkRemote at all.
    test "the two decline reasons are distinguishable" do
      FileLayer.current = FileLayer::ChunkRemote.new
      not_scannable = RepoMetadataPurge.call.reason
      unconfigured = with_unconfigured_backend { RepoMetadataPurge.call.reason }

      assert_match(/not a scannable backend/, not_scannable)
      assert_no_match(/not a scannable backend/, unconfigured)
      assert_not_equal not_scannable, unconfigured
    end

    # A SUCCESSFUL RUN CARRIES NO REASON. Without this, `reason` could be populated unconditionally
    # and the two tests above would still pass while an operator reading a report of real work saw
    # a decline sentence beside it.
    test "a run that actually did the work reports no decline reason" do
      file("firmware/.git/config")

      result = RepoMetadataPurge.call

      assert_equal 1, result.destroyed
      assert_not result.declined
      assert_nil result.reason
    end

    # A PROJECT'S OR MODEL'S COVER IS A THIRD POINTER, and the worse one: Maker::DeadNodes
    # .reapable? answers TRUE for a nil node, so a destroyed cover is reaped immediately with none
    # of the grace a tombstone buys — cleared silently, with nothing anywhere saying why.
    test "a node chosen as a project or model cover is REPORTED, never destroyed" do
      art = file("firmware/.git/art.png")
      other = file("firmware/.git/model.png")
      @user.maker_projects.create!(name: "Lamp", cover_node_id: art.node_id)
      @user.maker_models.create!(title: "Bracket", slug: "bracket", cover_node_id: other.node_id)

      result = RepoMetadataPurge.call

      assert Node.exists?(art.id), "a project cover is a reference like any other"
      assert Node.exists?(other.id), "a model cover too"
      assert_equal [ art.node_id, other.node_id ].sort, result.skipped.map(&:node_id).sort
      assert_equal 0, result.destroyed
    end

    # THE LOCAL PARENT-LOOKUP CACHE, WHICH NOTHING ELSE HERE CAN FAIL FOR. Restoring the plan's
    # module-level `@cache` leaves the rest of this file fully green: the idempotency test cannot
    # see it, because after run 1 the only rows left are ABOVE the marker and run 2 has nothing to
    # get wrong either way. The defect needs the tree to CHANGE between two runs in one process —
    # then a stale cached row still says `.git` for a directory that has been renamed, and the
    # second run destroys a file sitting beneath no marker at all.
    test "a second run in one process reads the tree, not a memo from the first" do
      marker = dir("firmware/.git")
      file("firmware/.git/config")

      assert_equal 1, RepoMetadataPurge.call.destroyed

      marker.update!(name: "notgit", storage_path: "firmware/notgit")
      @dirs["firmware/notgit"] = @dirs.delete("firmware/.git")
      innocent = file("firmware/notgit/readme.md")

      assert_equal 0, RepoMetadataPurge.call.destroyed
      assert Node.exists?(innocent.id), "there is no marker above it any more"
    end

    # THE WEDGE THIS WHOLE TASK EXISTS TO PREVENT, driven rather than argued (§15). The first scan
    # runs with the marker skip lifted, which is exactly the OLD behaviour every already-deployed
    # library was indexed under; the second runs the code as it now ships.
    test "after the purge, a scan over a repo library does not trip the mass-deletion guard" do
      # setup's pinned share library IS this test's library — one root for the suite rather than a
      # second one here, so the pin and the fixture cannot disagree about which library is current.
      (@root/"firmware"/".git"/"objects").mkpath
      20.times { |i| (@root/"firmware"/".git"/"objects"/"o#{i}").write("x") }
      (@root/"firmware"/"main.cpp").write("int main(){}")

      scanning_the_old_way { Library::Scanner.call(@user, root: @root) }
      assert_operator @user.nodes.present.count, :>, 20

      RepoMetadataPurge.call

      assert_nothing_raised { Library::Scanner.call(@user, root: @root) }
    end

    # A backend the factory cannot CONSTRUCT, deterministically on all three CI legs. `share` is
    # named EXPLICITLY rather than left to the factory's default because the s3 and chunk_remote
    # legs each carry their own backend's env — unsetting LIBRARY_PATH alone would leave those two
    # perfectly configured, and the test would assert nothing on two legs out of three.
    #
    # FileLayer.reset! on the way IN as well as out: setup's use_fresh_share_library! assigns
    # FileLayer.current directly, so without the reset the memo answers and the factory — the thing
    # under test — is never asked at all.
    def with_unconfigured_backend
      prior = { "LIBRARY_BACKEND" => ENV["LIBRARY_BACKEND"], "LIBRARY_PATH" => ENV["LIBRARY_PATH"] }
      ENV["LIBRARY_BACKEND"] = "share"
      ENV["LIBRARY_PATH"] = nil
      FileLayer.reset!
      yield
    ensure
      prior.each { |k, v| ENV[k] = v }
      FileLayer.reset!
    end

    # Library::Scanner declines the descent on RepoMetadata.marker?, so lifting that one answer
    # reproduces the pre-Task-3 scan exactly — the real code path, rather than hand-built rows
    # guessing at what it used to write.
    def scanning_the_old_way
      original = RepoMetadata.method(:marker?)
      RepoMetadata.define_singleton_method(:marker?) { |_name| false }
      yield
    ensure
      RepoMetadata.define_singleton_method(:marker?, original)
    end
  end
end
