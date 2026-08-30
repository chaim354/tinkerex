require "test_helper"
require "support/git_repo_fixture"

class Maker::Git::HistoryTest < ActiveSupport::TestCase
  include GitRepoFixture

  setup { @user = User.create!(email: "h-#{SecureRandom.hex(4)}@example.com") }

  def history_for(root) = Maker::Git::History.new(Maker::Git::LocalRepo.open(@user, root))

  test "repository history is newest first" do
    root = make_repo_with_commits!(count: 5)
    r = history_for(root).for_repo

    assert_equal %w[c4 c3 c2 c1 c0], r.entries.map { |e| e.message.strip }
    assert_equal :exhausted, r.stopped
  end

  test "an entry carries the author and time git recorded" do
    root = make_repo_with_commits!(count: 2)
    e = history_for(root).for_repo.entries.first

    assert_equal "Seed", e.author_name
    assert_equal "s@example.com", e.author_email
    assert_kind_of Time, e.time
    assert_equal 40, e.oid.length
  end

  # THE CAP IS A CORRECTNESS RULE (spec part 3): an uncapped walk measured 4.9s on 333 commits
  # over CIFS. Assert what was WALKED, not just what was returned -- returning few is not the
  # same as looking at few, and only the second protects the page.
  test "the walk stops at walk_limit and says so" do
    root = make_repo_with_commits!(count: 20)
    r = history_for(root).for_repo(limit: 50, walk_limit: 5)

    assert_equal 5, r.walked
    assert_equal :walk_limit, r.stopped
  end

  test "the walk stops at limit and says so" do
    root = make_repo_with_commits!(count: 20)
    r = history_for(root).for_repo(limit: 3, walk_limit: 100)

    assert_equal 3, r.entries.size
    assert_equal :limit, r.stopped
  end

  # MAX_WALK_LIMIT IS A CEILING, NOT A DEFAULT: 2,000 commits cold is ~30s (spec part 4), so a
  # caller asking for more must still be capped. Asserted on `walked` for the same reason as
  # above -- a small `entries` proves nothing about how far the walk went.
  test "a walk_limit above the ceiling is clamped to it" do
    root = make_repo_with_commits!(count: 6)
    r = history_for(root).for_repo(limit: 50, walk_limit: Maker::Git::History::MAX_WALK_LIMIT + 5_000)

    assert_equal 6, r.walked
    assert_equal :exhausted, r.stopped
  end

  test "path history lists only the commits that touched that path" do
    root = make_repo_with_commits!(count: 12, touch_every: 4)
    r = history_for(root).for_path("tracked.txt")

    assert_equal %w[c8 c4 c0], r.entries.map { |e| e.message.strip }
  end

  # FIRST PARENT ONLY (spec part 4). The merge took the mainline version of tracked.txt, so it is
  # TREESAME to its first parent: the change belongs to c1 and is listed once, there. Comparing
  # against every parent lists it at the merge too -- and drops the root commit, whose `parents`
  # is empty.
  test "a merge that took the mainline version is not listed again for that path" do
    root = make_repo_with_merge!
    h = history_for(root)

    # The fixture really did merge. Without this the assertion below passes over a linear history
    # and the rule it exists to pin is untested (§14e).
    head = h.for_repo.entries.first
    assert_equal "m", head.subject
    merge = Rugged::Repository.new(File.join(library_root, "merged")).lookup(head.oid)
    assert_equal 2, merge.parents.size

    assert_equal %w[c1 c0], h.for_path("tracked.txt").entries.map(&:subject)
  end

  # The state spec part 3 says must never be reported as "no history".
  test "a capped path walk can find nothing and reports walk_limit, not exhausted" do
    root = make_repo_with_commits!(count: 12, touch_every: 4)
    r = history_for(root).for_path("other-1.txt", walk_limit: 2)

    assert_empty r.entries
    assert_equal :walk_limit, r.stopped
    refute r.exhausted?, "an empty capped walk must not license the view to say there is no history"
  end

  test "blob_at returns the content at that commit" do
    root = make_repo_with_commits!(count: 12, touch_every: 4)
    h = history_for(root)
    oldest = h.for_path("tracked.txt").entries.last

    assert_equal "v0\n", h.blob_at(oldest.oid, "tracked.txt")
  end

  test "blob_at is nil when the path is absent at that commit" do
    root = make_repo_with_commits!(count: 4, touch_every: 4)
    h = history_for(root)

    assert_nil h.blob_at(h.for_repo.entries.first.oid, "nope.txt")
  end

  test "an oid from another repository is refused" do
    a = make_repo_with_commits!(name: "a", count: 2)
    make_repo_with_commits!(name: "b", count: 2)
    foreign = Rugged::Repository.new(File.join(library_root, "b")).head.target.oid

    # The two repositories really are distinct. Built with the same trees, messages, authors and
    # times they would share commit oids exactly (git content-addresses commits), and this test
    # would be handing repository `a` an oid it already contains.
    refute_equal Rugged::Repository.new(File.join(library_root, "a")).head.target.oid, foreign

    assert_nil history_for(a).blob_at(foreign, "tracked.txt")
  end

  # A WELL-FORMED OID THIS REPOSITORY DOES CONTAIN, POINTING AT SOMETHING THAT IS NOT A COMMIT.
  # The `oid` is a URL parameter, so this is reachable; without the type check, `Rugged::Blob` has
  # no `#tree` and the NoMethodError is not one of the rescued Rugged errors -- a 500, not a 404.
  test "an oid that is not a commit is refused" do
    root = make_repo_with_commits!(count: 4, touch_every: 4)
    repo = Rugged::Repository.new(File.join(library_root, "many"))
    blob_oid = repo.head.target.tree.path("tracked.txt")[:oid]

    assert_kind_of Rugged::Blob, repo.lookup(blob_oid)
    assert_nil history_for(root).blob_at(blob_oid, "tracked.txt")
  end

  test "an unborn repository has no history and is exhausted" do
    root = make_repo!(files: { "a.txt" => "x\n" }, commit: false)
    r = history_for(root).for_repo

    assert_empty r.entries
    assert_equal :exhausted, r.stopped
  end
end
