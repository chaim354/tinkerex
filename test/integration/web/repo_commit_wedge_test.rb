require "test_helper"

require "support/git_repo_fixture"

# A COMMIT MUST LEAVE NOTHING OF ITSELF IN THE CATALOG.
#
# This is the highest-consequence silent failure available in this repo. §14b records FOUR
# skip-list wedges, each found only after the previous explanation said it could not happen, and
# the cost is not one bad row: a live node at a path no observation can pair is tombstoned by the
# next scan, the tombstone counts toward Library::Reconciler's mass-deletion fraction, and the
# guard then refuses that scan AND EVERY SCAN AFTER IT, permanently, with nothing saying why.
#
# rugged writes blobs, a tree, a commit and a ref into `.git` on every commit — dozens of files at
# paths Library::Scanner deliberately never descends into (Library::RepoMetadata). So the git
# surface is a fifth candidate for that wedge by construction, and this is the test that says it
# is not one.
class RepoCommitWedgeTest < ActionDispatch::IntegrationTest
  include GitRepoFixture

  # `sign_in_as` DOES NOT EXIST IN test_helper.rb — the only method by that name is a Capybara
  # helper in test/system/support/web_helpers.rb. Every web integration test here defines its own;
  # repo_edit_flow_test.rb says the same thing at more length.
  PASSWORD = "password123".freeze

  setup do
    @user = User.create!(email: "rw-#{SecureRandom.hex(4)}@example.com",
                         password: PASSWORD, confirmed_at: Time.current)
    sign_in_as(@user)
  end

  def sign_in_as(user) = sign_in_web!(user, password: PASSWORD)

  # THE SKIP IS RIGHT HERE, AND IT IS THE ONE PLACE IN THIS FEATURE THAT IT IS — §14e's rule is
  # that a guard which skips on the thing it asserts is vacuous, so it is worth being explicit
  # about why this one is not. What is asserted is "committing creates no catalog node under
  # .git". What is skipped on is whether a WORKING TREE CAN EXIST AT ALL, which is a precondition
  # rather than the claim: on s3 there is no directory to hand to git and on chunk_remote the bytes
  # are remote, so there is no commit to make and therefore no wedge to look for. The absence of
  # the affordance on those two legs is asserted, not skipped, by
  # RepoCommitSurfacePresenceTest in repo_edit_flow_test.rb.
  #
  # Note the setup above deliberately pins NOTHING. Calling use_fresh_share_library! there would
  # make local_worktree? true on every leg and turn this skip into dead code; make_repo! pins the
  # fresh share library itself, one line after the gate has already been passed.
  test "a commit leaves no catalog node under .git and the next scan is clean" do
    skip "commits need a local working tree (local_worktree?), which only share has" unless
      FileLayer.current.capabilities.local_worktree?

    root = make_repo!(files: { "a.txt" => "one\n" })
    a = @user.nodes.present.find_by!(name: "a.txt")
    patch file_path(a.node_id), params: { content: "two\n", base_token: token_for(a) }
    post repo_commit_path(root.node_id), params: { paths: [ "a.txt" ], message: "m" }

    # THE COMMIT IS ASSERTED BEFORE ITS TRACES ARE, or this whole test is vacuous. A refusal in
    # RepoCommitsController redirects and answers 302 exactly like a success, so without this line
    # a commit path that never ran would leave no rows under `.git` for the most uninteresting
    # reason there is, and the guard would report success over a feature it never exercised — the
    # dominant failure shape §15 names.
    repo = Rugged::Repository.new(File.join(library_root, "demo"))
    assert_equal "m", repo.head.target.message, "nothing was committed, so nothing was written " \
                                                "into .git and this guard has no subject"

    # And the same non-vacuity from the other side: the absence below is a claim about a real
    # population, not about an empty directory.
    on_disk = Dir.glob(File.join(library_root, "demo", ".git", "**", "*"), File::FNM_DOTMATCH)
                 .count { |p| File.file?(p) }
    assert_operator on_disk, :>, 0, ".git holds no files, so 'none of them reached the catalog' " \
                                    "is true for the wrong reason"

    # The scan the wedge would break. It is NOT the load-bearing assertion and should not be read
    # as one: Library::Reconciler's mass-deletion guard is a PERCENTAGE, so a three-file fixture
    # can absorb a stray tombstone without ever raising Library::Scanner::UnsafeScan. The rows are
    # the root cause; the refused scan is the symptom, and only on a library big enough to trip it.
    Library::ScanJob.new.perform(user_id: @user.id)

    # SPELLED AS A PATH MATCH, NOT AS Library::RepoMetadata.internal?, AND THAT IS DELIBERATE. The
    # observers' skip is built on that predicate, so asking it here would let a broken predicate
    # confirm itself — §14e's FakeS3 shape, where the fake shared the code's misunderstanding and
    # 79 of 80 tests were green over silent data loss. A second, independent spelling is the whole
    # value of this assertion. (`%/.git/%` and not `.git/%` because make_repo! always nests the
    # repository under a folder; a repository AT the library root is not a shape this fixture can
    # produce.)
    #
    # `@user.nodes`, NOT `.present` — a TOMBSTONE under `.git` is precisely the row that trips the
    # mass-deletion guard, so filtering tombstones out would hide the thing being looked for.
    under_git = @user.nodes.where("storage_path LIKE ?", "%/.git/%").pluck(:storage_path)
    assert_empty under_git,
                 "a cataloged node under .git is a permanent scan wedge (§14b): the next scan " \
                 "cannot pair it, tombstones it, and the mass-deletion guard then refuses that " \
                 "scan and every scan after it"

    # THE MARKER ITSELF MUST SURVIVE, and this half is as load-bearing as the absence above.
    # Library::RepoMetadata keeps the `.git` NODE and drops only its contents, because the node is
    # the evidence that the folder IS a repository — Library::WorkingTree reads exactly this row
    # and asks nothing else. "Nothing under .git" satisfied by dropping the marker too would
    # silently switch the whole git surface off.
    marker = @user.nodes.present.find_by(name: ".git", kind: "dir")
    assert marker, "the marker itself must stay indexed — it is the evidence this is a repository"
  end
end
