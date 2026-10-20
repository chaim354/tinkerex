require "test_helper"

require "support/git_repo_fixture"

# The SERVER half of history and restore (tinkerex#178): the JSON the file panel fetches, the bytes
# of one old version, the restore that becomes a pending edit, and the repository-wide list.
#
# WHY EVERY CASE DRIVES A REAL REQUEST. The panel these endpoints feed is populated by fetch, so no
# request test can see the rendered rows — what a request test CAN prove is that the endpoints tell
# the truth, and the truth that matters here is `stopped`. Path filtering is sparse (spec part 3),
# so an empty entry list usually means "we stopped looking" rather than "nothing happened", and a
# view handed `exhausted` for a capped walk would say "no history" about a file with plenty.
#
# PINS A SHARE LIBRARY (GitRepoFixture#library_root), so these run IDENTICALLY on all three legs
# rather than varying with the ambient LIBRARY_BACKEND — that is what keeps the run counts equal
# (§15). The one case whose subject IS the ambient backend lives in its own class at the bottom and
# deliberately pins nothing.
class RepoHistoryFlowTest < ActionDispatch::IntegrationTest
  include GitRepoFixture

  # `sign_in_as` DOES NOT EXIST IN test_helper.rb — the only method by that name is a Capybara
  # helper in test/system/support/web_helpers.rb. Every web integration test here defines its own.
  PASSWORD = "password123".freeze

  setup do
    @library = use_fresh_share_library!
    @user = User.create!(email: "rh-#{SecureRandom.hex(4)}@example.com",
                         password: PASSWORD, confirmed_at: Time.current)
    sign_in_web!(@user, password: PASSWORD)
  end

  # THE DOOR, ASSERTED SEPARATELY FROM THE ROOM. A `data-controller` that resolves to nothing is a
  # silent no-op with no console warning (§14d, nine days once), so the mount is the one thing about
  # this panel a request test can check at all.
  test "the file page mounts the history panel for a file in a working tree" do
    node = seed_repo_file!("notes.md", "old\n")

    get file_path(node.node_id)

    assert_response :success
    assert_select "[data-controller='history']", 1
    assert_select "[data-history-url-value=?]", history_file_path(node.node_id)
  end

  test "a file outside a working tree gets no history panel" do
    node = seed_plain_file!("loose.md", "x\n")

    get file_path(node.node_id)

    assert_select "[data-controller='history']", 0
  end

  test "history JSON lists the commits that touched this path" do
    make_repo_with_commits!(count: 8, touch_every: 4)
    node = @user.nodes.present.find_by!(name: "tracked.txt")

    get history_file_path(node.node_id), as: :json

    body = JSON.parse(response.body)
    assert_equal %w[c4 c0], body["entries"].map { |e| e["subject"] }
    assert_equal "exhausted", body["stopped"]
    assert_equal "Seed", body["entries"].first["author"]
    assert_equal 8, body["entries"].first["short_oid"].length
    assert body["restorable"], "a share library holds the working tree, so a restore can be committed"
  end

  # THE HONEST-EMPTINESS RULE (spec part 3), AND THE REASON `stopped` EXISTS AT ALL. A capped walk
  # that found nothing must not be reported in a way a view could render as "this file has no
  # earlier history" — path filtering is sparse, so this is the ORDINARY outcome on a real
  # repository, not an edge case.
  test "a capped walk that finds nothing reports walk_limit, not exhausted" do
    make_repo_with_commits!(count: 12, touch_every: 4)
    node = @user.nodes.present.find_by!(name: "other-1.txt")

    get history_file_path(node.node_id, walk_limit: 2), as: :json

    body = JSON.parse(response.body)
    assert_empty body["entries"]
    assert_equal "walk_limit", body["stopped"]
    assert_equal 2, body["walked"], "walked is what licenses the panel to offer 'look further'"
  end

  # JUNK IS THE ORDINARY PAGE, NOT AN ERROR: this is a query string, and a caller cannot ask for an
  # unbounded walk however they spell it.
  test "a walk_limit above the ceiling is clamped and a junk one is the default" do
    make_repo_with_commits!(count: 4, touch_every: 4)
    node = @user.nodes.present.find_by!(name: "tracked.txt")

    get history_file_path(node.node_id, walk_limit: 10_000_000), as: :json
    assert_response :success
    assert_equal "exhausted", JSON.parse(response.body)["stopped"]

    get history_file_path(node.node_id, walk_limit: "banana"), as: :json
    assert_response :success
    assert_equal "exhausted", JSON.parse(response.body)["stopped"]
  end

  test "the blob at a commit is served as text" do
    make_repo_with_commits!(count: 8, touch_every: 4)
    node = @user.nodes.present.find_by!(name: "tracked.txt")
    oid = history_entries(node).dig(1, "oid")

    get history_blob_file_path(node.node_id, oid: oid)

    assert_response :success
    assert_equal "v0\n", response.body
    assert_match %r{text/plain}, response.media_type
  end

  test "an oid this repository does not contain is 404" do
    node = seed_repo_file!("notes.md", "old\n")

    get history_blob_file_path(node.node_id, oid: "0" * 40)

    assert_response :not_found
  end

  # RESTORE IS A PENDING EDIT, NOT A COMMIT (spec part 6). The maker reviews it in the commit box
  # like any other change, which is what makes an accidental restore one click from undone.
  test "restoring writes the old content and creates a pending edit" do
    root = make_repo_with_commits!(count: 8, touch_every: 4)
    node = @user.nodes.present.find_by!(name: "tracked.txt")
    oid = history_entries(node).dig(1, "oid")

    post restore_file_path(node.node_id, oid: oid)

    assert_redirected_to file_path(node.node_id)
    assert_equal "v0\n", read_back(node)
    assert_equal node.node_id, @user.nodes.present.find_by!(name: "tracked.txt").node_id,
                 "a replace must REUSE the node (§14a) or every attachment is orphaned"
    row = Maker::RepoEdit.where(user: @user, node_id: node.node_id)
    assert_equal 1, row.count
    assert_equal root.node_id, row.first.repo_root_node_id
  end

  # A NO-OP RESTORE IS REFUSED RATHER THAN PERFORMED. Writing identical bytes creates a pending edit
  # the commit box immediately drops as :unchanged — a button that appears to do nothing, which is
  # indistinguishable from the feature being broken.
  test "restoring the content already on disk is refused" do
    make_repo_with_commits!(count: 8, touch_every: 4)
    node = @user.nodes.present.find_by!(name: "tracked.txt")
    newest = history_entries(node).dig(0, "oid")
    before = read_back(node)

    post restore_file_path(node.node_id, oid: newest)

    assert_response :unprocessable_entity
    assert_match(/already what is on disk/i, JSON.parse(response.body)["error"])
    assert_equal before, read_back(node)
    assert_equal 0, Maker::RepoEdit.where(user: @user, node_id: node.node_id).count,
                 "a pending edit the commit box will immediately drop is worse than no button"
  end

  test "restoring a file outside a working tree is refused" do
    node = seed_plain_file!("loose.md", "x\n")

    post restore_file_path(node.node_id, oid: "0" * 40)

    assert_response :unprocessable_entity
    assert_equal "x\n", read_back(node)
  end

  test "restoring an oid this repository does not contain is 404" do
    node = seed_repo_file!("notes.md", "old\n")

    post restore_file_path(node.node_id, oid: "0" * 40)

    assert_response :not_found
    assert_equal "old\n", read_back(node)
  end

  # THE REPOSITORY-WIDE LIST, AND THE DOOR INTO IT. The commit box shipped on 2026-08-28 linked from
  # nowhere and a person found it, not the suite, because every test navigated straight to its URL.
  # Assert the door, not just the room behind it.
  test "the repository page lists commits and is reachable from the file page" do
    root = make_repo_with_commits!(count: 5)
    node = @user.nodes.present.find_by!(name: "tracked.txt")

    get file_path(node.node_id)
    assert_select "a[href=?]", repo_history_path(root.node_id)

    get repo_history_path(root.node_id)
    assert_response :success
    rows = css_select("[data-oid]")
    assert_equal 5, rows.size
    assert_match(/c4/, rows.first.text, "newest first, and the walker's order is what says so")
    # THE RENDERED-OUTPUT SWEEP FOR THIS TEMPLATE, WHICH LIVES HERE BECAUSE NOTHING ELSE CAN RUN IT.
    # Web::TemplateHygieneTest cannot reach this page -- it needs a real git working tree and a
    # local_worktree? backend -- so it lists this template in UNSWEPT_TEMPLATES. An ERB comment ends
    # at its FIRST terminator, so one quoting a snippet prints its own prose into the document, and
    # every assert_select in this suite is blind to it: the defect makes a TEXT NODE (§14d).
    assert_not_includes response.body, "<%", "an ERB opener reached the page"
    assert_not_includes response.body, "%>", "an ERB comment terminated early and leaked its prose"
  end

  # A REPOSITORY GIT CANNOT WORK WITH ANSWERS A SENTENCE, NOT A 500. Reading history would be fine
  # mid-lock, and the endpoint refuses anyway: the panel's first affordance overwrites the working
  # tree, so it takes the commit box's whole refusal rather than inventing a looser second one.
  test "a repository git is busy with says so instead of 500ing" do
    make_repo_with_commits!(count: 3)
    node = @user.nodes.present.find_by!(name: "tracked.txt")
    FileUtils.touch(File.join(library_root, "many", ".git", "index.lock"))

    get history_file_path(node.node_id), as: :json

    assert_response :success
    body = JSON.parse(response.body)
    assert_equal "unavailable", body["stopped"]
    assert_match(/index\.lock/, body["reason"])
    assert_not body["restorable"]
  end

  # SAME REFUSAL STYLE AS THE COMMIT BOX, and deliberately the same METHOD: two pages over one
  # repository must not disagree about whether it can be opened.
  test "a folder that is not a repository redirects rather than 500ing" do
    dir = Maker::LibraryFolder.ensure_path!(@user, [ "plain-#{SecureRandom.hex(4)}" ])

    get repo_history_path(dir.node_id)

    assert_redirected_to files_path
    assert flash[:alert].present?
  end

  private

  def history_entries(node)
    get history_file_path(node.node_id), as: :json
    JSON.parse(response.body).fetch("entries")
  end
end

# THE AMBIENT BACKEND, ASSERTED RATHER THAN SKIPPED (§14e: a guard that skips on the thing it
# asserts is vacuous). On s3 and chunk_remote there is no working tree on this box — and on
# chunk_remote a repository's `.git` directory IS mirrored into the catalog (§14b), so
# `Library::WorkingTree` answers a root there and this is a live path rather than a hypothetical.
#
# ITS SETUP DELIBERATELY PINS NOTHING. RepoHistoryFlowTest above pins a share library so its cases
# run identically on all three legs; doing that here would make `local_worktree?` true on every leg
# and both branches below would then be testing the same thing.
#
# IT IS THE ONE CLASS IN THIS FILE WHOSE ASSERTION COUNT VARIES BY LEG, on purpose and for the same
# reason RepoCommitSurfacePresenceTest's does: §15's rule is that the three legs' RUN counts match,
# and padding a branch with filler assertions to level the other number would hide a real signal
# behind a decorative one.
class RepoHistoryAmbientBackendTest < ActionDispatch::IntegrationTest
  PASSWORD = "password123".freeze

  setup do
    stub_the_s3_client_only!
    @user = User.create!(email: "hab-#{SecureRandom.hex(4)}@example.com",
                         password: PASSWORD, confirmed_at: Time.current)
    sign_in_web!(@user, password: PASSWORD)
  end

  teardown { FileLayer.reset! if @stubbed_s3 }

  # THE S3 LEG POINTS AT A BUCKET THAT DOES NOT EXIST, by `config/ci.rb`'s design rather than by a
  # gap here: `LIBRARY_S3_BUCKET=ci-not-a-real-bucket` with credentials `ci`/`ci`, so the first real
  # call answers `Aws::S3::Errors::Forbidden`. Every s3-mode test that needs a working port injects
  # FakeS3 (s3_write_test.rb, s3_delivery_test.rb, repo_edit_flow_test.rb); this is the same
  # concession spelled out at the one door that needs it, not an exception to it.
  #
  # IT SWAPS THE CLIENT, NOT THE BACKEND. The adapter is still FileLayer::S3 and `local_worktree?`
  # is still false, which is the whole subject here — only the socket at the far end is fake. The
  # `FileLayer.reset!` in teardown is load-bearing: a direct assignment does not set the pin flag
  # test_helper's own teardown looks for.
  def stub_the_s3_client_only!
    return unless FileLayer.current.is_a?(FileLayer::S3)

    require_relative "../../support/fake_s3"
    @stubbed_s3 = FakeS3.new
    FileLayer.current = FileLayer::S3.new(bucket: "b", region: "us-east-1", access_key_id: "ak",
                                          secret_access_key: "sk", prefix: "library",
                                          client: @stubbed_s3.client)
  end

  test "history answers honestly on whatever backend is live" do
    node_id = repo_file!

    get history_file_path(node_id), as: :json

    assert_response :success
    body = JSON.parse(response.body)
    if FileLayer.current.capabilities.local_worktree?
      assert_equal "exhausted", body["stopped"], "a real, unborn repository has no history yet"
      assert body["restorable"]
    else
      assert_equal "no_worktree", body["stopped"]
      assert_empty body["entries"]
      assert_not body["restorable"]
      assert_match(/local filesystem/i, body["reason"])
    end
  end

  # THE GATE, DRIVEN THROUGH THE REAL DOOR. Its message is asserted rather than only its status,
  # because `LocalRepo#refusal` one line below asks the same capability and would answer 422 too —
  # so the sentence is what distinguishes "restore refused this" from "the commit box refused it",
  # and it is what a mutation removing the gate changes.
  test "restore is refused where the repository is not on this box" do
    node_id = repo_file!

    post restore_file_path(node_id, oid: "0" * 40)

    if FileLayer.current.capabilities.local_worktree?
      assert_response :not_found, "a real repository, but no commit with that oid"
    else
      assert_response :unprocessable_entity
      assert_match(/Restoring needs a library on a local filesystem/, JSON.parse(response.body)["error"])
    end
    assert_equal "old\n", FileLayer.current.read(@user, node_id:)
  end

  private

  # THE FOLDER GOES THROUGH THE REAL DOOR AND THE MARKER DOES NOT, and the asymmetry is the whole
  # fixture (repo_edit_flow_test.rb records why). A bare `nodes.create!` dir has a NULL
  # storage_path, which cannot exist on share or s3 (§14a); the `.git` MARKER stays a bare row
  # because no door may mint one — Library::ReservedNames refuses that name at every leaf-minting
  # door and the port refuses it as a write destination (§14b). Nothing reads its bytes:
  # Library::WorkingTree asks the catalog for a live `.git` DIR row and nothing else.
  #
  # ON A BACKEND THAT REALLY HOLDS THE BYTES IT ALSO `init_at`s THE DIRECTORY, so the share leg
  # exercises a repository git can genuinely open. Without that the share arm would be asserting a
  # Rugged error dressed as a refusal — a green branch about the wrong thing.
  def repo_file!
    repo = Maker::LibraryFolder.ensure_path!(@user, [ "h-#{SecureRandom.hex(4)}" ])
    if FileLayer.current.capabilities.local_worktree?
      require "rugged"
      Rugged::Repository.init_at(FileLayer.current.absolute_path(repo).to_s)
    end
    @user.nodes.create!(node_id: SecureRandom.uuid, name: ".git", kind: "dir",
                        parent_node_id: repo.node_id)
    Maker::Addons::LibraryOutput.write_bytes!(@user, parent_node_id: repo.node_id,
                                              name: "a.md", bytes: "old\n")
  end
end
