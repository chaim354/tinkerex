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
end
