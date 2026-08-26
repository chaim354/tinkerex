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
    ensure
      FileLayer.reset!
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
      root = use_fresh_share_library!
      (root/"firmware"/".git"/"objects").mkpath
      20.times { |i| (root/"firmware"/".git"/"objects"/"o#{i}").write("x") }
      (root/"firmware"/"main.cpp").write("int main(){}")

      scanning_the_old_way { Library::Scanner.call(@user, root: root) }
      assert_operator @user.nodes.present.count, :>, 20

      RepoMetadataPurge.call

      assert_nothing_raised { Library::Scanner.call(@user, root: root) }
    ensure
      FileLayer.reset!
      FileUtils.remove_entry(root) if root&.exist?
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
