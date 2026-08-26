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

    test "a chunk_remote-shaped node (NULL storage_path) is resolved by its parent chain" do
      # On chunk_remote there is no storage_path at all (§14a), so a purge that only reads that
      # column would silently do nothing on the product's main deployment — green suite, zero
      # effect. The path is rebuilt from parent_node_id instead.
      repo = @user.nodes.create!(node_id: SecureRandom.uuid, name: "firmware", kind: "dir")
      marker = @user.nodes.create!(node_id: SecureRandom.uuid, name: ".git", kind: "dir",
                                   parent_node_id: repo.node_id)
      inner = @user.nodes.create!(node_id: SecureRandom.uuid, name: "config", kind: "file",
                                  parent_node_id: marker.node_id, size: 1)

      RepoMetadataPurge.call

      assert Node.exists?(marker.id)
      assert_not Node.exists?(inner.id)
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
