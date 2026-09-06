require "test_helper"
require "support/git_repo_fixture"

class Maker::Git::LocalRepoTest < ActiveSupport::TestCase
  include GitRepoFixture

  setup { @user = User.create!(email: "rt-#{SecureRandom.hex(4)}@example.com") }

  test "opens a repository the maker brought" do
    root = make_repo!
    assert Maker::Git::LocalRepo.open(@user, root).committable?
  end

  # An ordinary first commit, not an edge case to refuse.
  test "an unborn HEAD is committable" do
    root = make_repo!(commit: false)
    assert Maker::Git::LocalRepo.open(@user, root).committable?
  end

  test "a detached HEAD refuses, naming the reason" do
    root = make_repo!
    repo = Rugged::Repository.new(File.join(library_root, "demo"))
    repo.checkout(repo.head.target_id, strategy: :force)

    local = Maker::Git::LocalRepo.open(@user, root)
    refute local.committable?
    assert_match(/detached/i, local.refusal)
  end

  test "an operation in progress refuses" do
    root = make_repo!
    File.write(File.join(library_root, "demo", ".git", "MERGE_HEAD"), "deadbeef\n")

    local = Maker::Git::LocalRepo.open(@user, root)
    refute local.committable?
    assert_match(/merge/i, local.refusal)
  end

  # §8 rule 2: another git may hold this repository, or a crashed one left the lock. Deleting
  # another process's lock is how repositories get corrupted.
  test "a lock file refuses and is NOT deleted" do
    root = make_repo!
    lock = File.join(library_root, "demo", ".git", "index.lock")
    File.write(lock, "")

    local = Maker::Git::LocalRepo.open(@user, root)
    refute local.committable?
    assert_match(/index\.lock/, local.refusal)
    assert File.exist?(lock), "a lock must be refused, never deleted"
  end

  # THE TOUCH MAKES §8 RULE 1 EXPLICIT. That rule forbids a stat comparison because `share` is a
  # NAS over SMB/NFS: an mtime can move without a byte changing (a re-save writing the same
  # content, an rsync, an attribute-cache artefact), and this path must still read :unchanged.
  #
  # MEASURED RATHER THAN ASSUMED, because the obvious claim for this line is false: an mtime-based
  # implementation goes RED here WITH OR WITHOUT the touch. A commit's own time is truncated to
  # whole seconds while the file's mtime is not, so the seeded file already looks newer than the
  # commit that contains it — §15's .to_i trap seen from the other side. The touch is what makes
  # the failure be about the RULE instead of about sub-second luck.
  test "a path whose content matches HEAD is reported unchanged" do
    root = make_repo!(files: { "a.txt" => "same\n" })
    FileUtils.touch(File.join(library_root, "demo", "a.txt"), mtime: Time.now + 60)

    rows = Maker::Git::LocalRepo.open(@user, root).status_for([ "a.txt" ])

    assert_equal :unchanged, rows.fetch("a.txt").state
  end

  test "a modified path reports its line counts" do
    root = make_repo!(files: { "a.txt" => "one\n" })
    File.write(File.join(library_root, "demo", "a.txt"), "one\ntwo\n")

    row = Maker::Git::LocalRepo.open(@user, root).status_for([ "a.txt" ]).fetch("a.txt")

    assert_equal :modified, row.state
    assert_equal 1, row.additions
  end

  # THE FIXTURE THAT WAS MISSING, and its absence is the whole story of tinkerex#185: every file in
  # this suite had UNIQUE lines ("one", "two"), which is the one shape where `(b & a).size` happens
  # to be right. Real files repeat lines constantly -- blank ones most of all -- so the shipped
  # counts were wrong on essentially every file a maker would edit, and the suite could not see it.
  #
  # THE ASSERTION IS AGAINST GIT'S OWN ANSWER, not against a number I worked out by hand: a
  # hand-computed expectation is just this bug written down a second time.
  test "line counts are right for a file with repeated blank lines" do
    body = "alpha\n\nbeta\n\ngamma\n\ndelta\n\n"
    root = make_repo!(files: { "a.txt" => body })
    File.write(File.join(library_root, "demo", "a.txt"), body + "epsilon\n\n")

    row = Maker::Git::LocalRepo.open(@user, root).status_for([ "a.txt" ]).fetch("a.txt")

    repo = Rugged::Repository.new(File.join(library_root, "demo"))
    truth = Rugged::Patch.from_strings(body, body + "epsilon\n\n").stat

    assert_equal :modified, row.state
    assert_equal truth, [ row.additions, row.deletions ]
    assert_equal [ 2, 0 ], [ row.additions, row.deletions ],
                 "two lines appended is +2 -0; the old (b & a) collapsed the four blank lines"
  end

  test "line counts are right when lines are removed as well as added" do
    body = "a\n\nb\n\nc\n\n"
    root = make_repo!(files: { "a.txt" => body })
    File.write(File.join(library_root, "demo", "a.txt"), "a\n\nz\n\n")

    row = Maker::Git::LocalRepo.open(@user, root).status_for([ "a.txt" ]).fetch("a.txt")

    assert_equal Rugged::Patch.from_strings(body, "a\n\nz\n\n").stat,
                 [ row.additions, row.deletions ]
  end

  test "an ignored path is listed and NOT committable" do
    root = make_repo!(files: { "a.txt" => "x\n" }, gitignore: "secret.txt\n")
    File.write(File.join(library_root, "demo", "secret.txt"), "shh\n")

    row = Maker::Git::LocalRepo.open(@user, root).status_for([ "secret.txt" ]).fetch("secret.txt")

    assert_equal :ignored, row.state
    refute row.committable?
  end

  # Counted, never listed. The box must not misrepresent the repository, and must not become a
  # staging panel either.
  test "other dirty paths are counted, not returned" do
    root = make_repo!(files: { "a.txt" => "x\n", "b.txt" => "y\n" })
    File.write(File.join(library_root, "demo", "a.txt"), "changed\n")
    File.write(File.join(library_root, "demo", "b.txt"), "also changed\n")

    local = Maker::Git::LocalRepo.open(@user, root)
    rows  = local.status_for([ "a.txt" ])

    assert_equal [ "a.txt" ], rows.keys
    assert_equal 1, local.other_dirty_count([ "a.txt" ])
  end

  test "full_status reports every non-ignored path with its state" do
    root = make_repo_with_every_state!
    rows = Maker::Git::LocalRepo.open(@user, root).full_status.rows.to_h { |r| [ r.path, r.state ] }

    assert_equal :modified, rows["edited.txt"]
    assert_equal :added,    rows["fresh.txt"]
    assert_equal :deleted,  rows["doomed.txt"]
    assert_equal :added,    rows[".DS_Store"]      # clutter is a state-less fact; grouping is the VIEW's job
    assert_nil              rows["secret.log"]      # .gitignore'd paths never appear
    assert_nil              rows["kept.txt"]        # unchanged paths are not "changes"
  end

  # THE SPLIT. Conflated, either every stale RepoEdit row becomes a committable deletion or every
  # real deletion is silently dropped — and both are silent.
  test "a path in HEAD and gone from the worktree is deleted, and committable" do
    root = make_repo_with_every_state!
    row = Maker::Git::LocalRepo.open(@user, root).full_status.rows.find { |r| r.path == "doomed.txt" }

    assert_equal :deleted, row.state
    assert row.committable?
  end

  test "a path in neither HEAD nor the worktree is missing, and NOT committable" do
    root = make_repo_with_every_state!
    row = Maker::Git::LocalRepo.open(@user, root).status_for([ "never-existed.txt" ]).fetch("never-existed.txt")

    assert_equal :missing, row.state
    refute row.committable?
  end

  test "full_status is capped and says how many it did not list" do
    root = make_repo!(files: { "a.txt" => "x\n" })
    12.times { |i| File.write(File.join(library_root, "demo", "f#{i}.txt"), "y\n") }
    Library::ScanJob.new.perform(user_id: @user.id)

    s = Maker::Git::LocalRepo.open(@user, root).full_status(limit: 5)

    assert_equal 5, s.rows.size
    assert_operator s.truncated_count, :>=, 1
  end

  # STAGE 3, S3-2: git facts for a repository CARD. `head_summary`/`tags_at_head` read rugged
  # only — no port write, no CommitPaths — so they are tested against the SAME fixture shape as
  # everything else here, `make_repo!`'s single seeded commit.
  test "head_summary reads the last commit's oid, summary, author and time" do
    root = make_repo!(files: { "a.txt" => "x\n" })
    head_commit = Rugged::Repository.new(File.join(library_root, "demo")).head.target

    summary = Maker::Git::LocalRepo.open(@user, root).head_summary

    assert_equal head_commit.oid, summary.oid
    assert_equal head_commit.oid[0, 8], summary.short_oid
    assert_equal "seed", summary.summary
    assert_equal "Seed", summary.author
    assert_equal head_commit.time, summary.time
  end

  test "head_summary is nil on an unborn repository" do
    root = make_repo!(commit: false)

    assert_nil Maker::Git::LocalRepo.open(@user, root).head_summary
  end

  # THE FIRST LINE ONLY. A commit body is prose the maker wrote for git log, not for a one-line
  # card — the same choice Maker::Git::History::Entry#subject already made off the identical
  # `message.lines.first.to_s.strip` (probed: kramdown never enters this path, so nothing here
  # needs the multi-line body sanitised).
  test "head_summary's summary is only the first line of a multi-line commit message" do
    root = make_repo!(files: { "a.txt" => "x\n" })
    repo = Rugged::Repository.new(File.join(library_root, "demo"))
    who = { name: "Seed", email: "seed@example.com", time: Time.now }
    index = repo.index
    File.write(File.join(library_root, "demo", "a.txt"), "y\n")
    index.add(path: "a.txt", oid: Rugged::Blob.from_workdir(repo, "a.txt"), mode: 0o100644)
    index.write
    Rugged::Commit.create(repo, tree: index.write_tree(repo), message: "Fix the thing\n\nLonger body here.",
                          parents: [ repo.head.target_id ], update_ref: "HEAD", author: who, committer: who)

    summary = Maker::Git::LocalRepo.open(@user, root).head_summary

    assert_equal "Fix the thing", summary.summary
  end

  test "tags_at_head returns a lightweight tag and an annotated tag on HEAD, sorted, but not one on an older commit" do
    root = make_repo!(files: { "a.txt" => "one\n" })
    repo = Rugged::Repository.new(File.join(library_root, "demo"))
    old_oid = repo.head.target_id

    File.write(File.join(library_root, "demo", "a.txt"), "two\n")
    index = repo.index
    index.add(path: "a.txt", oid: Rugged::Blob.from_workdir(repo, "a.txt"), mode: 0o100644)
    index.write
    who = { name: "Seed", email: "seed@example.com", time: Time.now }
    Rugged::Commit.create(repo, tree: index.write_tree(repo), message: "second", parents: [ old_oid ],
                          update_ref: "HEAD", author: who, committer: who)

    repo.tags.create("old-tag", old_oid)
    repo.tags.create("zeta", repo.head.target_id)
    repo.tags.create("alpha-annotated", repo.head.target_id, message: "Release", tagger: who)

    tags = Maker::Git::LocalRepo.open(@user, root).tags_at_head

    assert_equal [ "alpha-annotated", "zeta" ], tags
  end

  test "tags_at_head is empty when HEAD carries no tag" do
    root = make_repo!

    assert_equal [], Maker::Git::LocalRepo.open(@user, root).tags_at_head
  end

  test "tags_at_head is empty on an unborn repository" do
    root = make_repo!(commit: false)

    assert_equal [], Maker::Git::LocalRepo.open(@user, root).tags_at_head
  end
end
