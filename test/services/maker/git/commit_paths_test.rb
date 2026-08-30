require "test_helper"
require "support/git_repo_fixture"

class Maker::Git::CommitPathsTest < ActiveSupport::TestCase
  include GitRepoFixture

  setup { @user = User.create!(email: "rt-#{SecureRandom.hex(4)}@example.com") }

  def local(root) = Maker::Git::LocalRepo.open(@user, root)
  def rugged_at   = Rugged::Repository.new(File.join(library_root, "demo"))

  # THE ONE THAT MATTERS MOST. index.clear + add_all passes every bytes-oriented test while
  # committing whatever is lying around the maker's working tree.
  test "an unselected dirty file is NOT swept into the commit" do
    root = make_repo!(files: { "a.txt" => "one\n", "b.txt" => "two\n" })
    File.write(File.join(library_root, "demo", "a.txt"), "one changed\n")
    File.write(File.join(library_root, "demo", "b.txt"), "two changed\n")

    Maker::Git::CommitPaths.new(local(root)).call(paths: [ "a.txt" ], message: "just a")

    tree = rugged_at.head.target.tree
    assert_equal "one changed\n", rugged_at.lookup(tree.path("a.txt")[:oid]).content
    assert_equal "two\n", rugged_at.lookup(tree.path("b.txt")[:oid]).content,
                 "b.txt was never selected and must be exactly as HEAD had it"
  end

  test "the commit's parent is the old HEAD and the branch moves" do
    root = make_repo!(files: { "a.txt" => "one\n" })
    before = rugged_at.head.target_id
    File.write(File.join(library_root, "demo", "a.txt"), "two\n")

    Maker::Git::CommitPaths.new(local(root)).call(paths: [ "a.txt" ], message: "m")

    assert_equal [ before ], rugged_at.head.target.parent_ids
    # THE BRANCH HEAD MOVED, and the commit is ON it -- not left dangling. libgit2's `init_at`
    # writes refs/heads/master while git's own default is main, so assert against whatever HEAD
    # actually points at rather than hard-coding either name.
    assert_equal rugged_at.head.target_id, rugged_at.references[rugged_at.head.name].target_id
  end

  test "a first commit on an unborn HEAD has no parents" do
    root = make_repo!(files: { "a.txt" => "one\n" }, commit: false)

    Maker::Git::CommitPaths.new(local(root)).call(paths: [ "a.txt" ], message: "first")

    assert_empty rugged_at.head.target.parent_ids
  end

  # Leaving the index alone leaves the committed path reporting as modified in the maker's own
  # `git status`, which reads as "the app half-did something".
  #
  # `git_statuses` rather than `rugged.status.select { }`: Rugged::Repository#status TAKES A BLOCK
  # and returns no enumerator -- called without one it raises "A block was expected for iterating
  # through the repository contents." (rugged 1.9.6).
  test "the committed path reports clean afterwards" do
    root = make_repo!(files: { "a.txt" => "one\n" })
    File.write(File.join(library_root, "demo", "a.txt"), "two\n")

    Maker::Git::CommitPaths.new(local(root)).call(paths: [ "a.txt" ], message: "m")

    assert_nil git_statuses(rugged_at)["a.txt"]
  end

  test "an unselected dirty path is still dirty afterwards" do
    root = make_repo!(files: { "a.txt" => "one\n", "b.txt" => "two\n" })
    File.write(File.join(library_root, "demo", "a.txt"), "one changed\n")
    File.write(File.join(library_root, "demo", "b.txt"), "two changed\n")

    Maker::Git::CommitPaths.new(local(root)).call(paths: [ "a.txt" ], message: "m")

    refute_nil git_statuses(rugged_at)["b.txt"]
  end

  # THE BUILD BOX HAS A GLOBAL ~/.gitconfig AND THE CONTAINER DOES NOT, which is exactly why the
  # identity reader may not ask `repo.config`: that is the whole config STACK (system, global,
  # local), so this case would read the developer's own name here and the fallback would never run
  # in the one environment that has to exercise it. The reader opens .git/config directly.
  test "the author falls back to the account email with its local-part as the name" do
    root = make_repo!(files: { "a.txt" => "one\n" })
    File.write(File.join(library_root, "demo", "a.txt"), "two\n")

    Maker::Git::CommitPaths.new(local(root)).call(paths: [ "a.txt" ], message: "m")

    author = rugged_at.head.target.author
    assert_equal @user.email, author[:email]
    assert_equal @user.email.split("@").first, author[:name]
  end

  test "repo-local identity wins when it is set" do
    root = make_repo!(files: { "a.txt" => "one\n" })
    r = rugged_at
    r.config["user.name"]  = "Real Maker"
    r.config["user.email"] = "maker@example.com"
    File.write(File.join(library_root, "demo", "a.txt"), "two\n")

    Maker::Git::CommitPaths.new(local(root)).call(paths: [ "a.txt" ], message: "m")

    assert_equal "Real Maker", rugged_at.head.target.author[:name]
  end

  # THE PLAN'S OWN CASES ARE ALL FLAT, so #stage's recursion — the part its comment calls out as
  # load-bearing — was covered by nothing. A nested path needs every intermediate tree rebuilt;
  # getting it wrong either drops the sibling under that directory or writes a blob where a tree
  # belongs, and a root-only repository cannot show either.
  test "a nested path is committed without disturbing its siblings" do
    root = make_repo!(files: { "src/a.txt" => "one\n", "src/b.txt" => "two\n", "top.txt" => "t\n" })
    File.write(File.join(library_root, "demo", "src", "a.txt"), "one changed\n")

    Maker::Git::CommitPaths.new(local(root)).call(paths: [ "src/a.txt" ], message: "nested")

    tree = rugged_at.head.target.tree
    assert_equal "one changed\n", rugged_at.lookup(tree.path("src/a.txt")[:oid]).content
    assert_equal "two\n", rugged_at.lookup(tree.path("src/b.txt")[:oid]).content,
                 "src/b.txt shares the rebuilt subtree and was never selected"
    assert_equal "t\n", rugged_at.lookup(tree.path("top.txt")[:oid]).content
  end

  # filemode_for, likewise untested by the plan. Dropping the bit silently un-chmods a script, and
  # the bytes are identical either way, so nothing else here would notice.
  test "an executable file keeps its mode" do
    root = make_repo!(files: { "run.sh" => "#!/bin/sh\n" })
    path = File.join(library_root, "demo", "run.sh")
    File.chmod(0o755, path)
    File.write(path, "#!/bin/sh\necho hi\n")

    Maker::Git::CommitPaths.new(local(root)).call(paths: [ "run.sh" ], message: "m")

    assert_equal 0o100755, rugged_at.head.target.tree.path("run.sh")[:filemode]
  end

  test "a ref that moved under us is refused" do
    root = make_repo!(files: { "a.txt" => "one\n" })
    l = local(root)
    expected = l.rugged.head.target_id
    File.write(File.join(library_root, "demo", "a.txt"), "two\n")

    # someone else commits first
    Maker::Git::CommitPaths.new(local(root)).call(paths: [ "a.txt" ], message: "theirs")

    assert_raises(Maker::Git::CommitPaths::RefMoved) do
      Maker::Git::CommitPaths.new(l).call(paths: [ "a.txt" ], message: "mine", expected_head: expected)
    end
  end

  # ---- deletions -------------------------------------------------------------------------------

  test "a selected deleted path is removed from the new tree" do
    root = make_repo!(files: { "a.txt" => "one\n", "b.txt" => "two\n" })
    File.delete(File.join(library_root, "demo", "a.txt"))

    Maker::Git::CommitPaths.new(local(root)).call(paths: [ "a.txt" ], message: "drop a")

    tree = rugged_at.head.target.tree
    assert_raises(Rugged::TreeError) { tree.path("a.txt") }
    assert_equal "two\n", rugged_at.lookup(tree.path("b.txt")[:oid]).content
  end

  # THE ONE THAT MATTERS. The danger is not dropping the entry you selected -- it is dropping one
  # you did not. Same shape as index.clear: right about the files it was asked about, wrong about
  # everything else, and green on every bytes-oriented assertion.
  #
  # b.txt is dirty AND selected on purpose: without a selected path the commit could be a no-op and
  # still pass, so the assertion would not be about carrying HEAD through at all.
  test "an UNSELECTED deleted path survives in the new tree with HEAD's bytes" do
    root = make_repo!(files: { "a.txt" => "one\n", "b.txt" => "two\n" })
    File.delete(File.join(library_root, "demo", "a.txt"))
    File.write(File.join(library_root, "demo", "b.txt"), "two changed\n")

    Maker::Git::CommitPaths.new(local(root)).call(paths: [ "b.txt" ], message: "only b")

    tree = rugged_at.head.target.tree
    assert_equal "one\n", rugged_at.lookup(tree.path("a.txt")[:oid]).content,
                 "a.txt was deleted on disk but NOT selected; the commit must keep HEAD's copy"
    assert_equal "two changed\n", rugged_at.lookup(tree.path("b.txt")[:oid]).content
  end

  test "a nested deletion prunes only its own entry" do
    root = make_repo!(files: { "src/a.txt" => "one\n", "src/b.txt" => "two\n" })
    File.delete(File.join(library_root, "demo", "src", "a.txt"))

    Maker::Git::CommitPaths.new(local(root)).call(paths: [ "src/a.txt" ], message: "drop nested")

    tree = rugged_at.head.target.tree
    assert_raises(Rugged::TreeError) { tree.path("src/a.txt") }
    assert_equal "two\n", rugged_at.lookup(tree.path("src/b.txt")[:oid]).content
  end

  # A DIRECTORY THAT LOSES ITS LAST ENTRY IS PRUNED, not written as an empty tree. git has no empty
  # directories: inserting one puts the empty-tree oid (4b825dc..., probed) where a directory used
  # to be, which `git status` then reports as an untracked-and-deleted phantom forever.
  test "a directory emptied by a deletion is pruned from its parent" do
    root = make_repo!(files: { "src/a.txt" => "one\n", "top.txt" => "t\n" })
    File.delete(File.join(library_root, "demo", "src", "a.txt"))

    Maker::Git::CommitPaths.new(local(root)).call(paths: [ "src/a.txt" ], message: "drop the last one")

    tree = rugged_at.head.target.tree
    assert_raises(Rugged::TreeError) { tree.path("src") }
    assert_equal "t\n", rugged_at.lookup(tree.path("top.txt")[:oid]).content
  end

  test "the committed deletion reports clean to git afterwards" do
    root = make_repo!(files: { "a.txt" => "one\n" })
    File.delete(File.join(library_root, "demo", "a.txt"))

    Maker::Git::CommitPaths.new(local(root)).call(paths: [ "a.txt" ], message: "drop a")

    assert_empty git_statuses(rugged_at).select { |rel, _| rel == "a.txt" }
  end

  # A path in NEITHER the working tree nor HEAD -- a stale maker_repo_edits row, LocalRepo's
  # :missing -- is nothing to record rather than an error. The tree half is safe on its own
  # (`Tree::Builder#remove` answers false for a name it does not hold), but the INDEX half is not:
  # `Rugged::Index#remove` raises "index does not contain ghost.txt at stage 0" (rugged 1.9.6,
  # probed), so dropping its guard turns a harmless stale row into a 500 after the commit landed.
  test "a selected path in neither the worktree nor HEAD is a no-op, not an error" do
    root = make_repo!(files: { "a.txt" => "one\n" })
    File.write(File.join(library_root, "demo", "a.txt"), "one changed\n")

    Maker::Git::CommitPaths.new(local(root)).call(paths: [ "a.txt", "ghost.txt" ], message: "with a ghost")

    tree = rugged_at.head.target.tree
    assert_equal "one changed\n", rugged_at.lookup(tree.path("a.txt")[:oid]).content
    assert_raises(Rugged::TreeError) { tree.path("ghost.txt") }
  end
end
