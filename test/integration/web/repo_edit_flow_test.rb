require "test_helper"

require "support/git_repo_fixture"

class RepoEditFlowTest < ActionDispatch::IntegrationTest
  include GitRepoFixture
  # The editor's Save re-enqueues the thumbnail it just invalidated (stage 4, S4-3),
  # so these tests assert on the QUEUE. Not previously needed here.
  include ActiveJob::TestHelper

  # `sign_in_as` DOES NOT EXIST IN test_helper.rb. The only method by that name is a Capybara
  # helper in test/system/support/web_helpers.rb, which takes an EMAIL and drives the real form.
  # Every web integration test here defines its own; shelves_test.rb records a previous plan
  # having assumed otherwise, so do not assume it again.
  PASSWORD = "password123".freeze

  setup do
    @library = use_fresh_share_library!
    @user = User.create!(email: "re-#{SecureRandom.hex(4)}@example.com",
                         password: PASSWORD, confirmed_at: Time.current)
    sign_in_as(@user)
  end

  def sign_in_as(user) = sign_in_web!(user, password: PASSWORD)

  # Drives the REAL door. §14e: the suite being green is not evidence a guard works if the
  # guard's precondition is never established in test.
  test "saving a text file in a working tree rewrites it and keeps the node" do
    node = seed_repo_file!("notes.md", "old\n")
    before = node.node_id

    patch file_path(node.node_id), params: { content: "new\n", base_token: token_for(node) }

    assert_response :success
    assert_equal "new\n", read_back(node)
    assert_equal before, @user.nodes.present.find_by!(name: "notes.md").node_id,
                 "a replace must REUSE the node (§14a) or every attachment is orphaned"
  end

  test "saving records exactly one pending edit, however many saves" do
    node = seed_repo_file!("notes.md", "a\n")

    patch file_path(node.node_id), params: { content: "b\n", base_token: token_for(node) }
    patch file_path(node.node_id), params: { content: "c\n", base_token: token_for(node.reload) }

    assert_equal 1, Maker::RepoEdit.where(user: @user, node_id: node.node_id).count
  end

  test "a stale base_token is refused and nothing is written" do
    node = seed_repo_file!("notes.md", "original\n")

    patch file_path(node.node_id), params: { content: "clobber\n", base_token: "sha256:stale" }

    assert_response :conflict
    assert_equal "original\n", read_back(node),
                 "last-write-wins would destroy the other edit silently, and on share for good"
  end

  # THE SAME 409, FOR THE HALF THE CATALOG CANNOT SEE. The token above is nonsense, so the row arm
  # of Maker::TextSave's check catches it; here the token is the REAL one the page rendered and the
  # row still agrees with it, because the file changed on disk with no scan behind it. That is the
  # ordinary shape of the failure — a maker editing the same repository from their desktop — and it
  # reached the port and overwrote until `expect_token:` existed (§14a).
  #
  # DRIVEN THROUGH THE DOOR rather than the service, because the response CODE is the door's: the
  # port raises FileLayer::StaleContent, TextSave turns it into the same :conflict the row arm
  # answers, and render_save_error turns that into the 409 the editor's JS reads. Three hops that a
  # service test does not cover.
  test "a save racing a desktop edit the scan has not seen is refused and keeps the desktop bytes" do
    node = seed_repo_file!("notes.md", "original\n")
    on_disk = File.join(library_root, node.storage_path)
    File.write(on_disk, "from the desktop\n")

    patch file_path(node.node_id), params: { content: "from the browser\n",
                                             base_token: token_for(node) }

    assert_response :conflict
    assert_equal "from the desktop\n", File.read(on_disk),
                 "the edit the catalog had not observed must survive the save that raced it"
  end

  # THE SAVE INVALIDATES THE PICTURE OF THE FILE, AND UNTIL NOW NOTHING SAID SO (stage 4, S4-3;
  # story 2.13's "the thumbnail and page stay stale after Save"). Every text extension has a
  # renderer — Maker::Previews::Registry DERIVES TextThumb for all 37 of them — so a saved .md
  # kept serving a thumbnail of the bytes it no longer had, on the Files grid, on the project
  # panel and on its own page, until the next 15-minute scan happened to notice.
  #
  # THE SAME DOOR THE TWO UPLOAD PATHS USE, not a third spelling: #enqueue_preview re-stats for the
  # content token the write just minted and swallows a vanished/unmounted library, because a
  # preview is best-effort UX and must never turn a successful save into an error.
  test "saving re-enqueues the thumbnail the save just invalidated" do
    node = seed_repo_file!("notes.md", "old\n")
    before_token = token_for(node)
    # find_or_initialize, NOT create!: seed_repo_file! runs a REAL Library::ScanJob, whose
    # Reconciler already enqueued a thumbnail for this node, and maker_previews is unique on
    # (user, node_id, kind). Putting that existing row into the state under test is what the
    # assertions below are about — a second row is not reachable through any door.
    preview = @user.maker_previews.find_or_initialize_by(node_id: node.node_id, kind: "thumbnail")
    preview.update!(version_id: before_token, status: "ready",
                    renderer_revision: Maker::Previews::Enqueue.revision_for_name("notes.md", "thumbnail"))

    assert_enqueued_with(job: Maker::GeneratePreviewJob) do
      patch file_path(node.node_id), params: { content: "new\n", base_token: before_token }
    end

    assert_response :success
    preview.reload
    assert_equal "pending", preview.status, "a content repoint blanks the artifact (§14h)"
    assert_not_equal before_token, preview.version_id, "the row points at the bytes that now exist"
    assert_equal token_for(node.reload), preview.version_id
  end

  # A REFUSED SAVE MUST NOT TOUCH THE PREVIEW. The 409 writes nothing, so re-enqueueing there would
  # blank a correct picture for a save that never happened.
  test "a stale base_token refuses without disturbing the preview" do
    node = seed_repo_file!("notes.md", "old\n")
    preview = @user.maker_previews.find_or_initialize_by(node_id: node.node_id, kind: "thumbnail")
    preview.update!(version_id: token_for(node), status: "ready",
                    renderer_revision: Maker::Previews::Enqueue.revision_for_name("notes.md", "thumbnail"))

    assert_no_enqueued_jobs only: Maker::GeneratePreviewJob do
      patch file_path(node.node_id), params: { content: "new\n", base_token: "stale" }
    end

    assert_response :conflict
    assert_equal "ready", preview.reload.status
  end

  # THIS CASE READ "a file outside a working tree is not saveable" UNTIL 2026-09-10, and asserted a
  # 422. `FilesController#update` refused `root.nil?` then, because git was the only undo on a
  # current-state backend; the trade is now named on the editor instead (`shared/_no_history_note`)
  # and the save lands. What the case is FOR has not moved: `root` must still decide something, and
  # the something is the pending git edit. Assert only the 200 and it would pass just as happily
  # over a door that recorded a Maker::RepoEdit against a repository that does not exist.
  test "a file outside a working tree saves, and records no pending edit" do
    node = seed_plain_file!("loose.md", "x\n")

    patch file_path(node.node_id), params: { content: "y\n", base_token: token_for(node) }

    assert_response :success
    assert_equal "y\n", read_back(node)
    assert_empty Maker::RepoEdit.where(user: @user, node_id: node.node_id)
  end

  # THE SIZE CAP IS RE-CHECKED ON THE SERVER, and this case is the reason it is not merely a
  # courtesy in JavaScript. codeview_controller fetches at most MAX_BYTES and appends
  # "… (truncated)"; a save of that buffer TRUNCATES THE FILE. A refusal that only lives in the
  # browser is one an unmodified `curl` walks straight past.
  test "a file over the editable cap is refused" do
    node = seed_repo_file!("huge.md", "x" * (FilesController::EDITABLE_MAX_BYTES + 1))

    patch file_path(node.node_id), params: { content: "tiny\n", base_token: token_for(node) }

    assert_response :unprocessable_entity
    assert_equal "x" * (FilesController::EDITABLE_MAX_BYTES + 1), read_back(node)
  end

  # --- The review-and-commit surface -------------------------------------------------------
  #
  # THE TABLE IS A HINT, NOT AN AUTHORITY. Each of these drives the page rather than the model,
  # because what is being asserted is that git is re-asked -- a test that read Maker::RepoEdit
  # would pass over a controller that trusted the rows blindly, which is the defect these exist
  # to catch.
  # THE FEATURE IS UNREACHABLE WITHOUT THIS, and that is how it shipped on 2026-08-28: the commit
  # box existed, answered correctly, and NOTHING IN THE APP LINKED TO IT. A person using the app
  # found it; the suite could not, because every other case here navigates straight to
  # repo_commit_path. A page that renders is not a page anyone can get to — assert the door, not
  # just the room behind it.
  test "the file page links to the commit box for a file in a working tree" do
    node = seed_repo_file!("notes.md", "old\n")
    root = @user.nodes.present.find_by!(name: "demo", kind: "dir")

    get file_path(node.node_id)

    assert_response :success
    assert_select "a[href=?]", repo_commit_path(root.node_id)
  end

  test "the link reports how many changes are pending in that repository" do
    node = seed_repo_file!("notes.md", "old\n")
    patch file_path(node.node_id), params: { content: "new\n", base_token: token_for(node) }

    get file_path(node.node_id)

    assert_select "a", text: /1 pending change in demo/
  end

  # THE BOX NO LONGER COUNTS WHAT IT WILL NOT SHOW. Until the staging panel this asserted
  # `[data-path='b.txt']` was ABSENT and a "1 other change ... not included" line took its place;
  # both are now wrong, because listing the maker's other work IS the feature. What survives from
  # the old case is the half that still matters: which GROUP each path lands in.
  test "the review page lists pending edits in one group and everything else in another" do
    root = make_repo!(files: { "a.txt" => "one\n", "b.txt" => "two\n" })
    a = @user.nodes.present.find_by!(name: "a.txt")
    patch file_path(a.node_id), params: { content: "one changed\n", base_token: token_for(a) }
    File.write(File.join(library_root, "demo", "b.txt"), "two changed\n")

    get repo_commit_path(root.node_id)

    assert_response :success
    assert_select "[data-group='pending'] [data-path='a.txt']", 1
    assert_select "[data-group='other'] [data-path='b.txt']", 1
    assert_select "[data-group='pending'] [data-path='b.txt']", 0
  end

  # THE HIDDEN FIELD IS ASSERTED BY NAME, not merely "the form posts". `expected_head` is the
  # compare-and-swap CommitPaths raises RefMoved on; drop it from the form and every commit
  # silently layers onto whatever HEAD has become, with no test failing anywhere else.
  test "the form carries expected_head, which is the compare-and-swap" do
    root = make_repo!(files: { "a.txt" => "one\n" })
    a = @user.nodes.present.find_by!(name: "a.txt")
    patch file_path(a.node_id), params: { content: "one changed\n", base_token: token_for(a) }
    head = Rugged::Repository.new(File.join(library_root, "demo")).head.target_id

    get repo_commit_path(root.node_id)

    assert_select "input[type=hidden][name=expected_head][value=?]", head
    # A FLAT NAME, NEVER "[thing][x]" -- a blank object_name plus fields_for emits the latter,
    # which Rack parses to the literal key "[thing]" and `require` rejects: a hard 400 (§14d).
    assert_select "input[name='paths[]']", 1
    assert_select "textarea[name=message]", 1
  end

  test "a commit that lands while the page is open is refused, not layered on" do
    root = make_repo!(files: { "a.txt" => "one\n" })
    a = @user.nodes.present.find_by!(name: "a.txt")
    patch file_path(a.node_id), params: { content: "one changed\n", base_token: token_for(a) }

    post repo_commit_path(root.node_id),
         params: { paths: [ "a.txt" ], message: "mine", expected_head: "0" * 40 }

    assert_redirected_to repo_commit_path(root.node_id)
    assert_match(/another commit landed/i, flash[:alert])
    repo = Rugged::Repository.new(File.join(library_root, "demo"))
    assert_equal "seed", repo.head.target.message
    assert_equal 1, Maker::RepoEdit.where(user: @user).count, "the row survives a refusal"
  end

  test "committing writes the commit and clears the rows" do
    root = make_repo!(files: { "a.txt" => "one\n" })
    a = @user.nodes.present.find_by!(name: "a.txt")
    patch file_path(a.node_id), params: { content: "one changed\n", base_token: token_for(a) }

    post repo_commit_path(root.node_id), params: { paths: [ "a.txt" ], message: "from tinkerex" }

    assert_redirected_to repo_commit_path(root.node_id)
    repo = Rugged::Repository.new(File.join(library_root, "demo"))
    assert_equal "from tinkerex", repo.head.target.message
    assert_equal 0, Maker::RepoEdit.where(user: @user).count
  end

  test "a row that now matches HEAD is dropped rather than offered" do
    root = make_repo!(files: { "a.txt" => "one\n" })
    a = @user.nodes.present.find_by!(name: "a.txt")
    patch file_path(a.node_id), params: { content: "one changed\n", base_token: token_for(a) }
    # the maker commits it themselves, at the terminal
    File.write(File.join(library_root, "demo", "a.txt"), "one changed\n")
    commit_at_the_terminal!(File.join(library_root, "demo"), "theirs")

    get repo_commit_path(root.node_id)

    assert_select "[data-path='a.txt']", 0
    assert_equal 0, Maker::RepoEdit.where(user: @user).count
  end

  # LISTED, NOT COMMITTABLE. Silently dropping an ignored path would answer "committed" over a
  # file git will never carry; hiding it would make the box lie about what tinkerex wrote.
  test "a path .gitignore covers is listed without a checkbox" do
    root = make_repo!(files: { "a.txt" => "one\n" }, gitignore: "*.log\n")
    File.write(File.join(library_root, "demo", "build.log"), "noise\n")
    Library::ScanJob.new.perform(user_id: @user.id)
    log = @user.nodes.present.find_by!(name: "build.log")
    patch file_path(log.node_id), params: { content: "more noise\n", base_token: token_for(log) }

    get repo_commit_path(root.node_id)

    assert_select "[data-path='build.log']", 1
    assert_select "[data-path='build.log'] input[type=checkbox]", 0
    assert_match(/ignored by \.gitignore/, response.body)
  end

  # --- The staging panel: three groups, one of them checked ---------------------------------

  # THE MEMBERSHIP OF ALL THREE GROUPS IN ONE PASS, off the one fixture that carries every state.
  # Five separate fixtures would let the groups drift: a change that quietly reclassifies clutter
  # as an ordinary add passes four of them.
  test "the box shows three groups with the right membership" do
    root = make_repo_with_every_state!
    kept = @user.nodes.present.find_by!(name: "kept.txt")
    patch file_path(kept.node_id), params: { content: "via tinkerex\n", base_token: token_for(kept) }

    get repo_commit_path(root.node_id)

    assert_response :success
    assert_select "[data-group='pending'] [data-path='kept.txt']", 1
    assert_select "[data-group='other'] [data-path='edited.txt']", 1
    assert_select "[data-group='other'] [data-path='fresh.txt']", 1
    assert_select "[data-group='other'] [data-path='doomed.txt'][data-state='deleted']", 1
    assert_select "[data-group='clutter'] [data-path='.DS_Store']", 1
    assert_select "[data-group='other'] [data-path='.DS_Store']", 0
    assert_match(/tinkerex never creates these/, response.body)

    # `.gitignore`d NEVER APPEARS, IN ANY GROUP. git will not carry it without -f, so offering it
    # would be offering something that cannot happen.
    assert_select "[data-path='secret.log']", 0
  end

  # THE PROPERTY PART 1 KNOWINGLY GAVE UP, AND THE ONLY TEST THAT CAN SEE IT. The box used to be
  # structurally incapable of touching the maker's other work because unedited paths were never
  # listed; now the protection is "unchecked by default, one click away". Pre-check the wider
  # group and every other case in this file stays green — this one counts the checked boxes on the
  # whole page and finds more than the single tinkerex-edited row.
  test "only the tinkerex-edited group is checked on load" do
    root = make_repo_with_every_state!
    kept = @user.nodes.present.find_by!(name: "kept.txt")
    patch file_path(kept.node_id), params: { content: "via tinkerex\n", base_token: token_for(kept) }

    get repo_commit_path(root.node_id)

    assert_select "input[name='paths[]'][checked='checked']", 1
    assert_select "[data-group='pending'] input[name='paths[]'][checked='checked']", 1
    # NON-VACUITY: the other groups must really be offering checkboxes, or "none of them is
    # checked" is true because there is nothing there to check (§14e).
    assert_operator css_select("[data-group='other'] input[name='paths[]']").size, :>=, 3
    assert_operator css_select("[data-group='clutter'] input[name='paths[]']").size, :>=, 1
  end

  # PARTITIONED BY `Library::OsClutter.ignore?`, NEVER BY A LIST OF NAMES (§14b: that predicate is
  # composed once and copied nowhere). `._sidecar.txt` is the case that proves which one is used:
  # it is clutter by the APPLE_DOUBLE_PREFIX rule and a `%w[.DS_Store]` literal misses it entirely.
  #
  # `Thumbs.db` WOULD BE THE WRONG PROBE and the constant says why in as many words — OsClutter is
  # macOS-only ON PURPOSE, so Windows clutter is NOT covered and a test using it would fail against
  # the correct code.
  test "OS clutter is partitioned by the shared predicate, not by a list of names" do
    root = make_repo!(files: { "a.txt" => "one\n" })
    File.write(File.join(library_root, "demo", "._sidecar.txt"), "resource fork\n")

    get repo_commit_path(root.node_id)

    assert_select "[data-group='clutter'] [data-path='._sidecar.txt']", 1
    assert_select "[data-group='other'] [data-path='._sidecar.txt']", 0
  end

  # A TRACKED PATH THAT `.gitignore` ALSO COVERS is a real state, not a hypothetical: git reports
  # it `:worktree_modified` (an ignore rule has no say over a tracked file), so it survives
  # full_status's filter and LocalRepo#row_for labels it `:ignored` from path_ignored?. It is
  # LISTED DISABLED rather than dropped — git status shows it, and the pending group has always
  # listed a .gitignore'd path exactly this way, so dropping it here would give one condition two
  # answers depending on which group it landed in.
  test "a tracked path .gitignore also covers is listed disabled rather than dropped" do
    root = make_repo!(files: { "a.txt" => "one\n", "build.log" => "noise\n" }, gitignore: "*.log\n")
    File.write(File.join(library_root, "demo", "build.log"), "more noise\n")

    get repo_commit_path(root.node_id)

    assert_select "[data-group='other'] [data-path='build.log']", 1
    assert_select "[data-path='build.log'] input[type=checkbox]", 0
    assert_match(/ignored by \.gitignore/, response.body)
  end

  # LISTED AND COMMITTABLE, WITH NO DIFF MOUNT. git commits a binary file fine; only the diff view
  # cannot help, and a CodeMirror merge view handed NUL bytes renders nonsense rather than failing.
  test "a binary path is committable and says so instead of mounting a diff" do
    root = make_repo!(files: { "a.txt" => "one\n" })
    File.write(File.join(library_root, "demo", "blob.bin"), "\x00\x01\x02binary".b)

    get repo_commit_path(root.node_id)

    assert_select "[data-path='blob.bin'] input[type=checkbox]", 1
    assert_select "[data-path='blob.bin'] .commit-diff", 0
    assert_match(/binary — no diff/, response.body)
  end

  # RENAMES ARE NOT DETECTED (spec part 2), so a rename arrives as both halves and the panel says
  # so. The negative case is what keeps the note from becoming decoration on every page.
  test "the box explains both halves of a rename only when both are present" do
    root = make_repo_with_every_state!

    get repo_commit_path(root.node_id)
    assert_match(/Renames are not detected/, response.body)

    plain = make_repo!(name: "plain", files: { "a.txt" => "one\n" })
    File.write(File.join(library_root, "plain", "a.txt"), "two\n")

    get repo_commit_path(plain.node_id)
    assert_no_match(/Renames are not detected/, response.body)
  end

  # A CAPPED LIST THAT DOES NOT SAY SO IS THE SAME LIE AS A CAPPED WALK REPORTING "no history".
  # The fixture must hold MORE than the cap or the assertion is vacuous — the shape that kept
  # tinkerex#185 invisible.
  test "a truncated list says how many paths it did not show" do
    root = make_repo!(files: { "a.txt" => "one\n" })
    dir = File.join(library_root, "demo")
    (Maker::Git::LocalRepo::DEFAULT_STATUS_LIMIT + 1).times { |i| File.write(File.join(dir, "f#{i}.txt"), "y\n") }

    get repo_commit_path(root.node_id)

    assert_select "li[data-path]", Maker::Git::LocalRepo::DEFAULT_STATUS_LIMIT
    assert_match(/1 further changed path not listed/, response.body)
  end

  # --- Committing from the wider groups ------------------------------------------------------
  #
  # `#create` INTERSECTS THE SUBMITTED PATHS WITH WHAT THE BOX COULD HAVE OFFERED, and the plan
  # said this method needed no change. It did: the intersection was against the reconciled
  # `maker_repo_edits` rows alone, so every path in the two new groups fell out of it and the
  # commit answered "Nothing selected." — the new capability silently doing nothing, on a redirect
  # indistinguishable from the refusal path.
  test "a path from Other changes commits, and only it" do
    root = make_repo_with_every_state!

    post repo_commit_path(root.node_id), params: { paths: [ "fresh.txt" ], message: "just fresh" }

    repo = Rugged::Repository.new(File.join(library_root, "mixed"))
    tree = repo.head.target.tree
    assert_equal "just fresh", repo.head.target.message
    assert_equal "new\n", repo.lookup(tree.path("fresh.txt")[:oid]).content
    assert_equal "before\n", repo.lookup(tree.path("edited.txt")[:oid]).content,
                 "edited.txt was dirty and NOT selected; the commit must keep HEAD's copy"
    assert_equal "bye\n", repo.lookup(tree.path("doomed.txt")[:oid]).content,
                 "an unselected DELETION must survive with HEAD's bytes"
    assert_raises(Rugged::TreeError) { tree.path(".DS_Store") }
  end

  test "a deletion from Other changes can be committed" do
    root = make_repo_with_every_state!

    post repo_commit_path(root.node_id), params: { paths: [ "doomed.txt" ], message: "drop it" }

    tree = Rugged::Repository.new(File.join(library_root, "mixed")).head.target.tree
    assert_raises(Rugged::TreeError) { tree.path("doomed.txt") }
    assert tree.path("kept.txt"), "only the selected path may leave the tree"
  end

  # THE THIRD GROUP COMMITS TOO, AND UNTIL NOW NOTHING POSTED FROM IT. `.DS_Store` is offered
  # unchecked under "OS clutter", and a maker who ticks it is asking for exactly that. #create's
  # authority is the committable rows of all three groups, the same row set the page rendered from
  # (F-S13-1). Leave the clutter group out of that list and only this case goes red: the membership
  # test still sees the row, and the commit answers "Nothing selected." over a box that offered it.
  test "a ticked OS-clutter path commits" do
    root = make_repo_with_every_state!

    post repo_commit_path(root.node_id), params: { paths: [ ".DS_Store" ], message: "clutter, on purpose" }

    repo = Rugged::Repository.new(File.join(library_root, "mixed"))
    assert_equal "clutter, on purpose", repo.head.target.message
    assert_equal "\x00clutter".b, repo.lookup(repo.head.target.tree.path(".DS_Store")[:oid]).content
  end

  # --- One row per path, per request ----------------------------------------------------------
  #
  # #show AND #create READ ONE ROW SET, BUILT ONCE (F-S13-1). The box used to compute a pending
  # path's row twice, once to reconcile it and once more inside full_status, and then re-open every
  # listed file for an 8 kB binary sniff. #create rebuilt both lists again to decide what it would
  # accept. Every row is a content read compared against HEAD's blob, about 15 ms per object over
  # CIFS. And two computations are two definitions of "what the page offered": #create's
  # intersection once disagreed with the render, and that shipped (the comment on #create says how).
  #
  # COUNTED AT THE READ, NOT AT A METHOD. `File.binread` under the working tree is every content read
  # LocalRepo#row_for makes, including the `.gitignore`d branch's sniff, so a second computation of
  # any row, by any route, shows up here as a 2.
  test "the box and the commit each read a listed path once" do
    root = make_repo_with_every_state!
    kept = @user.nodes.present.find_by!(name: "kept.txt")
    patch file_path(kept.node_id), params: { content: "via tinkerex\n", base_token: token_for(kept) }
    workdir = Maker::Git::LocalRepo.open(@user, root).workdir

    shown = reads_under(workdir) { get repo_commit_path(root.node_id) }

    assert_response :success
    # NON-VACUITY (§14e): a pending row and a wider-group row were both really read, so "once each"
    # is a claim about the two places a row used to be computed twice, not about an empty tally.
    assert_includes shown.keys, "kept.txt"
    assert_includes shown.keys, "edited.txt"
    assert_equal shown.transform_values { 1 }, shown, "a listed path was read more than once to render the box"

    committed = reads_under(workdir) do
      post repo_commit_path(root.node_id), params: { paths: [ "kept.txt" ], message: "read once" }
    end

    assert_equal "read once", Rugged::Repository.new(workdir).head.target.message,
                 "the commit must land, or the tally below is about a request that did nothing"
    assert_includes committed.keys, "kept.txt"
    assert_equal committed.transform_values { 1 }, committed, "a listed path was read more than once to commit"
  end

  # THE PATH IN NO GROUP AT ALL. `secret.log` sits in the working tree, is `.gitignore`d, and
  # therefore appears in NO group — so a POST naming it must be dropped rather than committed.
  # Without the intersection CommitPaths would take it happily: it reads bytes from the working
  # tree and knows nothing about which paths the page offered.
  test "a submitted path in no group is ignored rather than committed" do
    root = make_repo_with_every_state!

    post repo_commit_path(root.node_id), params: { paths: [ "fresh.txt", "secret.log" ], message: "two" }

    repo = Rugged::Repository.new(File.join(library_root, "mixed"))
    tree = repo.head.target.tree
    assert_equal "new\n", repo.lookup(tree.path("fresh.txt")[:oid]).content,
                 "the legitimate half must still commit, or this asserts nothing about filtering"
    assert_raises(Rugged::TreeError) { tree.path("secret.log") }
  end

  # HEAD'S BLOB LEAVES THE SERVER AS BYTES, and the server diffs neither side -- @codemirror/merge
  # does that in the browser (Task 11). An untracked path has no blob in HEAD, and the empty
  # document is the right answer rather than a 404: the diff is then "all of it is new".
  test "HEAD's blob is served as text for the browser to diff against" do
    root = make_repo!(files: { "a.txt" => "one\n" })
    a = @user.nodes.present.find_by!(name: "a.txt")
    patch file_path(a.node_id), params: { content: "one changed\n", base_token: token_for(a) }

    get repo_head_blob_path(root.node_id, path: "a.txt")

    assert_response :success
    assert_equal "one\n", response.body
    assert_match %r{text/plain}, response.media_type

    get repo_head_blob_path(root.node_id, path: "never-existed.txt")
    assert_equal "", response.body
  end

  private
    # A COMMIT MADE THE WAY A MAKER WOULD MAKE ONE — at the terminal, outside the app. Two things
    # here are deliberate, both learned on 2026-08-31 when CI moved to Linux containers and this was
    # the only test in the whole suite that failed.
    #
    # THE IDENTITY IS PASSED EXPLICITLY, because git REFUSES to commit without one:
    #
    #     Author identity unknown
    #     *** Please tell me who you are.
    #
    # This used to rely on whatever `user.name`/`user.email` the machine happened to carry. It
    # passed for months on a developer's Mac, which has a global identity set for unrelated reasons,
    # and failed the moment it ran anywhere that does not. `test/support/git_repo_fixture.rb` had
    # this right all along — its `Rugged::Commit.create` takes explicit author and committer
    # signatures — so this was the one call in the suite leaning on ambient config.
    #
    # AND THE EXIT STATUS IS ASSERTED, which matters more than the identity does. `err: File::NULL`
    # swallowed git's perfectly clear complaint, the commit silently did not happen, and the failure
    # surfaced one assertion later as `Expected exactly 0 elements matching "[data-path='a.txt']",
    # found 1` — which reads as a bug in the diff logic rather than as missing configuration.
    # Keeping the output quiet on a PASSING run is right; letting a FAILING one be silent was not.
    #
    # The ARRAY form of `system`, never the string form: it does not reach a shell, so a library
    # path containing a space cannot re-split into two arguments.
    def commit_at_the_terminal!(dir, message)
      ok = system("git", "-C", dir,
                  "-c", "user.name=Terminal", "-c", "user.email=terminal@example.com",
                  "commit", "-am", message,
                  out: File::NULL, err: File::NULL)
      assert ok, "the terminal-side `git commit` did not happen, so this test would be asserting " \
                 "about a working tree that was never committed. Drop `err: File::NULL` to see " \
                 "git's own reason."
    end

    # The house mutation/stub helper (text_file_creation_test.rb, readme_edit_test.rb and others
    # carry the same body; there is no shared copy in test_helper.rb, and this suite has no
    # Object#stub, because Minitest 6 dropped minitest/mock). Replaces a SINGLETON method for the
    # block's duration, so an INHERITED one is removed again rather than left behind.
    def replacing(owner, name, replacement)
      mod = owner.singleton_class
      own = mod.instance_methods(false).include?(name)
      original = mod.instance_method(name)
      mod.define_method(name, &replacement)
      yield
    ensure
      own ? mod.define_method(name, original) : mod.remove_method(name)
    end

    # Every `File.binread` of a path under `dir` during the block, tallied by its path relative to
    # `dir`. Any other read (a template, an asset) passes through uncounted. `File.binread` is
    # inherited from IO's singleton, which is the case `replacing` removes again afterwards.
    def reads_under(dir)
      prefix = "#{dir}/"
      tally = Hash.new(0)
      binread = File.method(:binread)
      counting = lambda do |path, *rest|
        tally[path.to_s.delete_prefix(prefix)] += 1 if path.to_s.start_with?(prefix)
        binread.call(path, *rest)
      end
      replacing(File, :binread, counting) { yield }
      tally
    end
end

# SAVE ON WHATEVER BACKEND IS LIVE. The cases above pin a share library so they run identically on
# all three legs, which is what keeps run counts equal — but that means none of them exercises s3's
# `write` or chunk_remote's two-phase upload, and "Save works everywhere" is half this design.
#
# NO REAL GIT IS NEEDED, and that is the point: the Save door asks Library::WorkingTree, which
# reads NODES. A `.git` dir node is all it takes, and every backend has one — on chunk_remote the
# mirror carries whatever the client synced, and repo_metadata_purge.rb records those rows as
# HIDDEN rather than removed.
class RepoEditAmbientBackendTest < ActionDispatch::IntegrationTest
  PASSWORD = "password123".freeze

  setup do
    stub_the_s3_client_only!
    @user = User.create!(email: "ab-#{SecureRandom.hex(4)}@example.com",
                         password: PASSWORD, confirmed_at: Time.current)
    sign_in_web!(@user, password: PASSWORD)
  end

  teardown { FileLayer.reset! if @stubbed_s3 }

  # THE S3 LEG POINTS AT A BUCKET THAT DOES NOT EXIST, and that is `config/ci.rb`'s design rather
  # than a gap here: `LIBRARY_S3_BUCKET=ci-not-a-real-bucket` with credentials `ci`/`ci`, so the
  # first real call answers `Aws::S3::Errors::Forbidden`. Every s3-mode test in this suite that
  # needs a working port therefore injects `FakeS3` (s3_write_test.rb, s3_delivery_test.rb); this
  # one is not an exception to that, it is the same concession spelled out at the one door that
  # needs it.
  #
  # IT SWAPS THE CLIENT, NOT THE BACKEND. The adapter is still `FileLayer::S3` and the Save door
  # still takes S3's own `write`, so what this test asserts about the ambient backend stays true —
  # only the socket at the far end is fake. `is_a?` is allowed HERE for Task 2's stated reason: a
  # test naming which adapter is live is the opposite of production code branching on the class.
  # The `FileLayer.reset!` in teardown is load-bearing, not decoration — a direct assignment does
  # not set the pin flag test_helper's teardown looks for.
  def stub_the_s3_client_only!
    return unless FileLayer.current.is_a?(FileLayer::S3)

    require_relative "../../support/fake_s3"
    @stubbed_s3 = FakeS3.new
    FileLayer.current = FileLayer::S3.new(bucket: "b", region: "us-east-1", access_key_id: "ak",
                                          secret_access_key: "sk", prefix: "library",
                                          client: @stubbed_s3.client)
  end

  # THE FOLDER GOES THROUGH THE REAL DOOR AND THE MARKER DOES NOT, and the asymmetry is the whole
  # fixture. A `nodes.create!` dir has a NULL `storage_path`, which cannot exist on share or s3
  # (§14a) — `FileLayer::Share#write` into it raises `FileLayer::NotFound: parent … has no
  # storage_path`, so the plan's two bare rows made this case pass on chunk_remote alone, which is
  # the one leg it was written to escape. `Maker::LibraryFolder` is the one cross-backend
  # folder-creation door and gives a real parent on all three.
  #
  # THE `.git` MARKER STAYS A BARE ROW BECAUSE NO DOOR MAY MINT ONE. `Library::ReservedNames`
  # refuses that name at every leaf-minting door and the port refuses it as a write destination
  # (§14b), so `ensure_path!` cannot create it and must not learn how. Nothing reads the marker's
  # bytes anyway: `Library::WorkingTree` asks the catalog for a live `.git` DIR row and nothing else.
  test "saving works on the ambient backend, whichever it is" do
    repo = Maker::LibraryFolder.ensure_path!(@user, [ "r-#{SecureRandom.hex(4)}" ])
    @user.nodes.create!(node_id: SecureRandom.uuid, name: ".git", kind: "dir",
                        parent_node_id: repo.node_id)
    node = write_through_port!(parent: repo, name: "a.md", bytes: "old\n")

    patch file_path(node.node_id),
          params: { content: "new\n",
                    base_token: FileLayer.current.stat(@user, node_id: node.node_id)&.content_token }

    assert_response :success
    assert_equal "new\n", FileLayer.current.read(@user, node_id: node.node_id)
  end

  # THE OTHER ARM, asserted rather than skipped (§14e). Where a backend cannot hold a working tree
  # the page must still say what happens to the save, or the maker is left with an editor and no
  # account of where their change went.
  #
  # `ensure_path!`, NEVER `nodes.create!`: a bare row has a NULL storage_path, which §14a says
  # cannot exist on share or s3 — `Share#write` raises `parent has no storage_path`. A fixture built
  # that way can only pass on chunk_remote, which is the one leg this case exists to reach.
  test "a backend without local_worktree explains where the commit happens instead" do
    repo = Maker::LibraryFolder.ensure_path!(@user, [ "rb-#{SecureRandom.hex(4)}" ])
    @user.nodes.create!(node_id: SecureRandom.uuid, name: ".git", kind: "dir",
                        parent_node_id: repo.node_id)
    node = write_through_port!(parent: repo, name: "a.md", bytes: "old\n")

    get file_path(node.node_id)

    if FileLayer.current.capabilities.local_worktree?
      assert_select "a[href=?]", repo_commit_path(repo.node_id)
    else
      assert_select "a[href=?]", repo_commit_path(repo.node_id), count: 0
      assert_match(/sync to the machine that holds/, response.body)
    end
  end

  # Uses the SAME door the editor does, so this test cannot pass by a route the product lacks.
  def write_through_port!(parent:, name:, bytes:)
    id = Maker::Addons::LibraryOutput.write_bytes!(@user, parent_node_id: parent.node_id, name:, bytes:)
    @user.nodes.present.find_by!(node_id: id)
  end
end

# RUNS ON ALL THREE LEGS and asserts the ABSENCE of the affordance rather than skipping — §14e, a
# guard that skips on the thing it asserts is vacuous, and that exact mistake once made a boot test
# report success over a loaded engine.
#
# IT IS THE ONE CASE IN THIS FILE WHOSE ASSERTION COUNT VARIES BY LEG, and that is the branch
# above rather than a leg-dependent bug. Measured on this file: share 1 assertion, s3/chunk_remote
# 5, so the file reports 44 and 48. §15's rule is that the three legs' RUN COUNTS match — they do,
# 14 each — and it warns that a structural ASSERTION difference means a test depends on the ambient
# LIBRARY_BACKEND. This one depends on it on purpose; padding the `if` branch with filler
# assertions to make the numbers line up would hide a real signal behind a decorative one.
#
# ITS SETUP DELIBERATELY PINS NOTHING. RepoEditFlowTest above calls `use_fresh_share_library!` in
# setup, which makes `local_worktree?` true on every leg — so the else branch there would be dead
# code on all three, which is the vacuous shape this case exists to avoid. The `if` branch may pin
# (it is already share when it runs); the `else` branch must never touch `library_root`.
class RepoCommitSurfacePresenceTest < ActionDispatch::IntegrationTest
  include GitRepoFixture

  PASSWORD = "password123".freeze

  setup do
    @user = User.create!(email: "cs-#{SecureRandom.hex(4)}@example.com",
                         password: PASSWORD, confirmed_at: Time.current)
    sign_in_web!(@user, password: PASSWORD)
  end

  test "the commit surface exists only where local_worktree is true" do
    if FileLayer.current.capabilities.local_worktree?
      root = make_repo!
      get repo_commit_path(root.node_id)
      assert_response :success
    else
      dir = @user.nodes.create!(node_id: SecureRandom.uuid, name: "x", kind: "dir")
      get repo_commit_path(dir.node_id)
      assert_redirected_to files_path
      assert_match(/local filesystem/i, flash[:alert])
    end
  end
end
