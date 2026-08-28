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
end
