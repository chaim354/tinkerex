require "test_helper"
require "support/git_repo_fixture"

# STAGE 3, S3-5: the release picker's tag list. `tags_at_head` (local_repo_test.rb) answers "which
# tags point HERE"; this one answers "every tag, and the COMMIT each resolves to", which is what a
# release records. The peel is the interesting half — an annotated tag's own oid is the ANNOTATION
# object, not a commit, so an unpeeled answer records something no maker can look up.
class Maker::Git::LocalRepoTagsTest < ActiveSupport::TestCase
  include GitRepoFixture

  # A FRESH SHARE LIBRARY PER TEST, PINNED BEFORE ANY NODE EXISTS: a working tree is only openable
  # where the library is a real filesystem, so this suite cannot ride the ambient backend.
  setup do
    @library = use_fresh_share_library!
    @user = User.create!(email: "tags-#{SecureRandom.hex(4)}@example.com")
  end

  def repo_at(name) = Rugged::Repository.new(File.join(library_root, name))

  def local_for(root) = Maker::Git::LocalRepo.open(@user, root)

  test "a lightweight tag resolves to the commit it names" do
    root = make_repo!
    repo = repo_at("demo")
    head = repo.head.target_id
    repo.tags.create("v1.0.0", head)

    tags = local_for(root).tags

    assert_equal [ "v1.0.0" ], tags.map(&:name)
    assert_equal [ head ], tags.map(&:oid)
  end

  # THE CASE THE PEEL EXISTS FOR. An annotated tag is its own object in the database, so the ref
  # points at the annotation and the annotation points at the commit. Asserting the oid is the
  # COMMIT (and, separately, that it is NOT the tag object's own oid) is what makes dropping
  # `annotated?` fail here rather than pass with a plausible-looking hex string.
  test "an annotated tag resolves to the commit, not to the annotation object" do
    root = make_repo!
    repo = repo_at("demo")
    head = repo.head.target_id
    who = { name: "Seed", email: "seed@example.com", time: Time.at(1_700_000_000) }
    tag_oid = repo.tags.create("release-1", head, message: "Release one", tagger: who)

    tags = local_for(root).tags

    assert_equal [ "release-1" ], tags.map(&:name)
    assert_equal head, tags.first.oid
    assert_not_equal tag_oid.to_s, tags.first.oid,
      "an annotated tag's own object id is not a commit — the target must be peeled"
  end

  test "tags come back sorted by name" do
    root = make_repo!
    repo = repo_at("demo")
    head = repo.head.target_id
    %w[v2.0.0 v0.1.0 v1.0.0].each { |t| repo.tags.create(t, head) }

    assert_equal %w[v0.1.0 v1.0.0 v2.0.0], local_for(root).tags.map(&:name)
  end

  test "a repository with no tags answers with an empty list" do
    assert_equal [], local_for(make_repo!).tags
  end

  # An unborn HEAD has no commit for a tag to point at; `tags_at_head` returns [] for the same
  # reason and this one must not raise instead.
  test "an unborn HEAD answers with an empty list" do
    root = make_repo!(commit: false)
    assert_equal [], local_for(root).tags
  end

  # THE CAP, WITH MORE TAGS THAN THE CAP — a walk that never reaches its limit proves nothing about
  # the limit (GitRepoFixture makes the same point about commits).
  test "the list is capped, so a repository with more tags than the cap lists only the cap" do
    root = make_repo!
    repo = repo_at("demo")
    head = repo.head.target_id
    (Maker::Git::LocalRepo::TAG_CAP + 1).times { |i| repo.tags.create(format("v%04d", i), head) }

    tags = local_for(root).tags

    assert_equal Maker::Git::LocalRepo::TAG_CAP, tags.size
    assert_equal tags.map(&:name).sort, tags.map(&:name), "the capped slice is still name-sorted"
  end

  # SORTED BEFORE THE CAP, so the capped set is the alphabetical first TAG_CAP and two renders
  # can never differ (git-editing.md's rule for `full_status`; S3-5's review caught this method
  # capping first and citing that rule as precedent). The 201st name sorts LAST and must be the
  # one left out -- a cap taken in ref order could drop any name and still pass the test above.
  test "the cap keeps the alphabetical first TAG_CAP, so the last name by sort is the one left out" do
    root = make_repo!(name: "many-sorted")
    repo = repo_at("many-sorted")
    head = repo.head.target_id
    names = (Maker::Git::LocalRepo::TAG_CAP + 1).times.map { |i| format("v%04d", i) }
    names.shuffle(random: Random.new(7)).each { |t| repo.tags.create(t, head) }

    tags = local_for(root).tags

    assert_equal names.sort.first(Maker::Git::LocalRepo::TAG_CAP), tags.map(&:name)
    assert_not_includes tags.map(&:name), names.max
  end

  # A DIRECT LOOKUP SEES PAST THE CAP. The picker's list is bounded; verifying the tag a maker
  # chose is not, or a real tag would be refused as "no such tag" (S3-5's review, HIGH).
  test "tag(name) answers a tag the capped list left out, and nil for a name that is not a tag" do
    root = make_repo!(name: "past-cap")
    repo = repo_at("past-cap")
    head = repo.head.target_id
    (Maker::Git::LocalRepo::TAG_CAP + 1).times { |i| repo.tags.create(format("v%04d", i), head) }
    last = format("v%04d", Maker::Git::LocalRepo::TAG_CAP)
    local = local_for(root)

    assert_not_includes local.tags.map(&:name), last, "the fixture must put the tag past the cap"
    found = local.tag(last)
    assert_equal last, found.name
    assert_equal head, found.oid
    assert_nil local.tag("v9999")
    assert_nil local.tag("")
  end

  test "tag(name) on an unborn HEAD is nil" do
    root = make_repo!(name: "unborn-tag", commit: false)
    assert_nil local_for(root).tag("v1.0.0")
  end
end
