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
end
