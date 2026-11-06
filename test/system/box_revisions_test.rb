require "application_system_test_case"
require_relative "../support/fake_boxes_sidecar"

# Revising a saved box — the surfaces the addon-state-revisions arc added to the Box Generator
# bundle: a left click in the saved rail opening the EDITOR on that box, Save appending a revision
# instead of minting a second box, "Save as new box" forking on purpose, the lazy History panel, and
# the `?state=` deep link.
#
# WHY THE HOST TESTS ANOTHER REPO'S CODE. The same answer box_sections_test.rb's header gives at
# length: the bundle (chaim354/tinkerex-addons) has no headless harness of its own and this repo's CI
# has no checkout of it, so the shipped modules are driven through the hermetic SNAPSHOT in
# test/fixtures/addons/boxes/, which that repo's bin/check-fixture-drift refuses to let anyone
# publish past. The five bundle system tests already here cover what the Box Generator did BEFORE
# this arc; without this file its headline behaviour — a save that appends rather than duplicates —
# would ship with no automated coverage anywhere, in either repo.
#
# EVERY "IT REVISED" ASSERTION IS MADE ON THE ROWS, NOT ON THE SCREEN: one Maker::AddonState where
# there used to be two, `revision` 2, two snapshots, and the output file's node_id UNCHANGED — §14a,
# where a replace written as delete-then-create passes any bytes-oriented check while orphaning every
# attachment, BOM link and tag.
class BoxRevisionsTest < ApplicationSystemTestCase
  SAMPLE_404 = %r{/tools/boxes/service/boxes/sample/\w+ - Failed to load resource.+404}

  # The join offer is provoked ON PURPOSE, and the 409 that asks the question is a failed fetch,
  # which Chrome logs at SEVERE — the same argument SAMPLE_404 above makes for the gallery's missing
  # sample photos. Without this the deliberate refusal would mask a genuine error logged beside it.
  SAVE_409 = %r{/tools/boxes - Failed to load resource.+409}

  setup do
    # A fresh library root per test. The system gate shares ONE LIBRARY_PATH for the whole run
    # while the database rolls back per test, so files outlive the rows that named them and
    # Share's clobber refusal (§14a) rejects the second test to save a given name -- which
    # surfaces as 'Not saved. "shelf-box.svg" already exists' rather than as anything about
    # the feature under test.
    @root = use_fresh_share_library!
    @prior_addon_source_path = ENV["ADDON_SOURCE_PATH"]
    ENV["ADDON_SOURCE_PATH"] = Rails.root.join("test/fixtures/addons").to_s
    FakeBoxesSidecar.install!
    @user = sign_in_as "boxrevisions@example.com"
  end

  teardown do
    FileLayer.reset!
    FileUtils.remove_entry(@root) if @root&.exist?
  end

  teardown do
    FakeBoxesSidecar.uninstall!
    ENV["ADDON_SOURCE_PATH"] = @prior_addon_source_path
  end

  test "a left click on a saved box opens the editor, editing that box" do
    # A FRESH GENERATOR HAS NOTHING TO FORK FROM, so the button is not there to press. Asserted
    # BEFORE any save: once the editor has saved, it is editing the box it made and the button is
    # back (the fresh-generator revision test below asserts that half).
    visit tools_addon_path("boxes")
    open_addon_card("ABox")
    assert_no_selector '[data-role="save-as-new"]'

    create_box("Shelf box", x: "123")
    open_saved("Shelf box")

    assert_selector '[data-role="editing"]', text: "Editing “Shelf box” · v1"
    assert_equal "Shelf box", find('[data-role="name"]').value
    assert_equal "123", find('[data-param="x"]').value
    # The fork button only exists while there is something to fork FROM.
    assert_selector '[data-role="save-as-new"]'
    assert_no_console_errors ignoring: [ SAMPLE_404 ]
  end

  test "saving from that editor appends a revision instead of minting a second box" do
    state = create_box("Shelf box", x: "111")
    node_id = state.files.sole.node_id

    open_saved("Shelf box")
    find('[data-param="x"]').set("222")
    find('[data-role="save"]').click
    assert_selector '[data-role="save-status"]', text: "Saved."

    assert_equal 1, Maker::AddonState.count
    state.reload
    assert_equal 2, state.revision
    assert_equal [ 1, 2 ], state.revisions.map(&:revision)
    assert_equal "111", state.revisions.first.data["params"]["x"]
    assert_equal "222", state.data["params"]["x"]
    # REPLACED, NOT RE-CREATED. Also proves the save reached the host's own-file collision exemption:
    # both outputs land on the same name in the same folder as revision 1, and without the exemption
    # this would have stopped at a confirm dialog that no test answers.
    assert_equal node_id, state.files.sole.node_id

    # The header caught up without a reload — the editor stays open after a save.
    assert_selector '[data-role="editing"]', text: "· v2"
    assert_no_console_errors ignoring: [ SAMPLE_404 ]
  end

  # THE FLOW SOMEBODY ITERATING ACTUALLY TAKES — a fresh generator, save, tweak a param, save again,
  # no navigation in between — into a PLAIN folder (here the library root), which is where it was a
  # dead end. The editor did not know the id of the box its own first save had made, so the second
  # save was another CREATE, and #refuse_taken_names! answered it with the terminal 422 "…already
  # exists in that folder. Rename the save or pick another folder." Every other revising test here
  # navigates to a saved box first, and the one same-mount test saved into a PROJECT folder, where a
  # 409 join offer happened to rescue it — which is why nothing caught this.
  test "save, tweak, save again from a fresh generator revises the box it just made" do
    visit tools_addon_path("boxes")
    open_addon_card("ABox")
    find('[data-param="x"]').set("111")
    find('[data-role="name"]').set("Shelf box")
    find('[data-role="save"]').click
    assert_selector '[data-role="save-status"]', text: "Saved."
    node_id = Maker::AddonState.sole.files.sole.node_id

    # The first save turned this editor into one editing the box it made, exactly as opening that
    # box from the saved rail would have.
    assert_selector '[data-role="editing"]', text: "Editing “Shelf box” · v1"
    assert_selector '[data-role="save-as-new"]'

    find('[data-param="x"]').set("222")
    find('[data-role="save"]').click
    state = wait_for_revision(2)

    assert_equal 1, Maker::AddonState.count
    assert_equal [ 1, 2 ], state.revisions.map(&:revision)
    assert_equal "222", state.data["params"]["x"]
    assert_equal node_id, state.files.sole.node_id
    assert_selector '[data-role="editing"]', text: "Editing “Shelf box” · v2"
    assert_no_console_errors ignoring: [ SAMPLE_404 ]
  end

  test "Save as new box forks the design rather than revising it" do
    create_box("Shelf box")
    open_saved("Shelf box")

    find('[data-role="name"]').set("Shelf box mk2")
    find('[data-role="save-as-new"]').click
    assert_selector '[data-role="save-status"]', text: "Saved."

    assert_equal 2, Maker::AddonState.count
    assert_equal [ 1, 1 ], Maker::AddonState.order(:id).map(&:revision)
    assert_equal [ "Shelf box", "Shelf box mk2" ], Maker::AddonState.order(:id).map(&:name)

    # AND THE EDITOR NOW EDITS THE FORK, not the box it was opened on. It used to go on naming the
    # ORIGINAL, so the next Save revised that box under the fork's name — and the fork's own
    # `shelf-box-mk2.svg`, which the original does not own, refused it with the terminal 422.
    assert_selector '[data-role="editing"]', text: "Editing “Shelf box mk2” · v1"
    find('[data-param="x"]').set("222")
    find('[data-role="save"]').click
    fork = wait_for_revision(2)

    assert_equal "Shelf box mk2", fork.name
    assert_equal "222", fork.data["params"]["x"]
    assert_equal [ "Shelf box", 1 ], Maker::AddonState.order(:id).first.then { |s| [ s.name, s.revision ] }
  end

  test "the history panel is lazy, refetches after a save, and loads a revision back" do
    create_box("Shelf box", x: "111")
    open_saved("Shelf box")

    # NOTHING IS FETCHED UNTIL IT IS EXPANDED — the states list carries only the current revision
    # number, and this is the call that pays for one box's history.
    #
    # ASSERTED ON THE REQUESTS THE BROWSER MADE, because laziness is a claim about a request and no
    # DOM assertion can see it: `assert_no_selector '… li'` returns the moment the list is absent,
    # which is equally true of an eager fetch that has not resolved yet — mutation-checked, and it
    # stayed GREEN with a `load()` moved to mount.
    assert_equal 0, revision_requests
    find('[data-role="history"] summary').click
    assert_selector '[data-role="history"] li', count: 1
    assert_equal 1, revision_requests

    find('[data-param="x"]').set("222")
    find('[data-role="save"]').click
    assert_selector '[data-role="save-status"]', text: "Saved."

    # THE PANEL WAS OPEN WHEN THE REVISION LANDED, so it refetches rather than sitting one behind —
    # mountHistory#refresh's own `if (details.open)` branch, which nothing else here drives.
    assert_selector '[data-role="history"] li', count: 2
    assert_equal 2, revision_requests

    find('[data-role="history"] button', text: "v1").click
    assert_equal "111", find('[data-param="x"]').value
    # Still editing the same box: loading an old revision is how a design is restored (its FILE is
    # gone on share and s3 — one file per box, overwritten), so the next save must append to it.
    assert_selector '[data-role="editing"]', text: "Editing “Shelf box” · v2"
    assert_no_console_errors ignoring: [ SAMPLE_404 ]
  end

  test "a ?state= deep link lands in the editor, and a stale one lands on the gallery" do
    state = create_box("Shelf box")

    visit "#{tools_addon_path('boxes')}?state=#{state.id}"
    assert_selector '[data-role="editing"]', text: "Editing “Shelf box”"

    # An id that resolves to nothing is a HINT the host answers nil for, never a 404 — a bookmark to
    # a box the user has since deleted must still open the tool.
    visit "#{tools_addon_path('boxes')}?state=999999"
    assert_selector ".box-index"
    assert_no_console_errors ignoring: [ SAMPLE_404 ]
  end

  # THE ONE PATH THAT REACHES THE 409 DIALOG, AND IT IS NOT THE ONE THE DESIGN'S §8.3 DESCRIBES.
  # Measured while mutation-checking this file: a same-name save into a PLAIN library folder never
  # gets a 409 at all — Tools::AddonsController#refuse_taken_names! runs first and is TERMINAL, so
  # it answers 422 "…already exists in that folder. Rename the save or pick another folder."
  # A 409 arises only through #resolve_placements, i.e. when the picked folder is a PROJECT FOLDER's
  # own root and the CATEGORY folder the sweep will file into already holds that name (CLAUDE.md
  # §14f's recorded gap, and §12 item 11 in the wild). That is the mainline for anyone saving into a
  # project folder, which a tool starts in when its last output was filed there.
  #
  # ANSWERING YES SENDS A SECOND SAVE CARRYING `state_id`, NOT AN OVERWRITE RETRY. The SDK resolves
  # `stateId` once, before its first request, so onReplace returning true would replace the file and
  # STILL mint a second box. This is the assertion that proves the second call happened: one row,
  # revision 2.
  test "a same-name save into a project folder offers to join that box's lineage" do
    lamp = project_folder

    create_box("Shelf box", x: "111", folder: lamp)
    original = Maker::AddonState.sole
    # The eager intake nudge has filed it under the category folder, which is what leaves the
    # project root vacant for the next save and opens the gap.
    assert_equal "design", @user.nodes.present.find_by!(node_id: original.files.sole.node_id)
      .then { |n| @user.nodes.present.find_by!(node_id: n.parent_node_id).name }

    # A BLANK GENERATOR, not the saved box — this is the accidental re-save, not an edit.
    #
    # NO `in=`: the blank generator starts where this tool last saved, mapped up to the project
    # folder (step 3), and that is the only reason this save reaches the 409.
    visit tools_addon_path("boxes")
    open_addon_card("ABox")
    find('[data-param="x"]').set("222")
    find('[data-role="name"]').set("Shelf box")
    accept_confirm(/Save as revision 2 of “Shelf box”/) { find('[data-role="save"]').click }
    assert_selector '[data-role="save-status"]', text: "Saved."

    assert_equal 1, Maker::AddonState.count
    original.reload
    assert_equal 2, original.revision
    assert_equal "222", original.data["params"]["x"]
    assert_equal [ 1, 2 ], original.revisions.map(&:revision)

    # AND THE EDITOR NOW EDITS THAT BOX, so the next save appends without asking a second time. Were
    # it still a fresh editor, this save would meet the same 409 and an unanswered confirm, which the
    # next page interaction raises on.
    assert_selector '[data-role="editing"]', text: "Editing “Shelf box” · v2"
    find('[data-param="x"]').set("333")
    find('[data-role="save"]').click
    wait_for_revision(3)
    assert_equal 1, Maker::AddonState.count
    assert_selector '[data-role="editing"]', text: "Editing “Shelf box” · v3"
    assert_no_console_errors ignoring: [ SAMPLE_404, SAVE_409 ]
  end

  # THE SAME-MOUNT FLOW AGAIN, INTO A PROJECT FOLDER — the one place it used to reach a question rather
  # than a dead end. The eager intake nudge files the first save's output under `design/`, leaving the
  # project root vacant, so a second save that did not name its box met #resolve_placements' 409 and a
  # "Save as revision 2?" offer. It names its box now, and the host's own-file exemption answers
  # instead: no question at all, exactly as when revising a box opened from the saved rail. An
  # unexpected confirm would be unanswered here, and the next page interaction raises on it.
  #
  # THE HEADER IS AWAITED BEFORE THE SECOND SAVE, and not for tidiness: "Saved." appears before the
  # states refresh that tells the editor which box it made, so a click sent on "Saved." alone can
  # race it and post a create.
  test "save, tweak, save again into a project folder revises without asking" do
    lamp = project_folder

    visit tools_addon_path("boxes", in: lamp)
    open_addon_card("ABox")
    find('[data-param="x"]').set("111")
    find('[data-role="name"]').set("Shelf box")
    find('[data-role="save"]').click
    assert_selector '[data-role="editing"]', text: "Editing “Shelf box” · v1"
    node_id = Maker::AddonState.sole.files.sole.node_id

    find('[data-param="x"]').set("222")
    find('[data-role="save"]').click
    wait_for_revision(2)
    find('[data-param="x"]').set("333")
    find('[data-role="save"]').click
    state = wait_for_revision(3)

    assert_equal 1, Maker::AddonState.count
    assert_equal "333", state.data["params"]["x"]
    assert_equal node_id, state.files.sole.node_id
    assert_selector '[data-role="editing"]', text: "Editing “Shelf box” · v3"
    assert_no_console_errors ignoring: [ SAMPLE_404 ]
  end

  test "a right click on a saved box offers the detail view and the file" do
    state = create_box("Shelf box")
    visit tools_addon_path("boxes")
    expand_saved_rail

    # `right_click`, NOT `click(:left, ctrl: true)`. Measured through this same driver: a ctrl+click
    # arrives as `mousedown`/`click` with `button=0` and no `contextmenu` at all — chromedriver
    # synthesizes the modifier rather than going through the platform's secondary-click mapping — so
    # it opens the editor like any left click and would test nothing here.
    find(".box-saved-link", text: "Shelf box").right_click
    assert_selector ".file-menu"
    assert_selector ".file-menu button", text: "Edit this box"
    # The file link is `host.files.url(node_id)` — the SDK's builder for a library file's detail
    # page. Asserted as the URL a user would follow, not as the string the bundle passed in.
    assert_match %r{/files/#{state.files.sole.node_id}\z}, find(".file-menu a", text: "Open the file")[:href]

    find(".file-menu button", text: "Details").click
    assert_selector "h1", text: "Shelf box"
    assert_selector ".bundle-files a"
    assert_no_selector ".file-menu"
  end

  private

  # Saves one box from a fresh generator and returns its row. The ordinary CREATE path, used as the
  # fixture every test here starts from — so nothing hand-builds an AddonState whose files point at
  # node ids no port ever wrote, which is the shape that would let a bytes-level regression through.
  def create_box(name, x: nil, folder: nil)
    visit tools_addon_path("boxes", in: folder)
    open_addon_card("ABox")
    find('[data-param="x"]').set(x) if x
    find('[data-role="name"]').set(name)
    find('[data-role="save"]').click
    assert_selector '[data-role="save-status"]', text: "Saved."
    Maker::AddonState.order(:id).last
  end

  # A project whose library folder a save starts in — which is what puts the save on the one path
  # that reaches a 409 rather than the terminal 422 (see the join test). Returns the folder's
  # node_id for `?in=`.
  def project_folder(name = "Lamp")
    @user.maker_projects.create!(name:).ensure_library_folder!(@user).node_id
  end

  # POLLS THE ROW, NOT THE STATUS LINE, and that is not fussiness: "Saved." is already on screen from
  # the previous save in the same mount, so an assert_selector for it can pass before the save under
  # test has been sent at all. Same shape as box_save_folder_test.rb's own wait_for_node. A save that
  # minted a second box instead leaves the newest row at revision 1, so this times out and says so.
  def wait_for_revision(number)
    deadline = Time.now + 5
    state = nil
    while Time.now < deadline
      state = Maker::AddonState.order(:id).last
      break if state&.revision == number

      sleep 0.05
    end
    assert_equal number, state&.revision, "no save ever reached revision #{number}"
    state
  end

  # How many times this page has asked the host for a revision history. The resource timeline is the
  # only place a request that was never made is distinguishable from one that has not landed.
  def revision_requests
    page.evaluate_script(
      "performance.getEntriesByType('resource').filter((e) => e.name.includes('/revisions')).length",
    )
  end

  def open_saved(name)
    visit tools_addon_path("boxes")
    expand_saved_rail
    find(".box-saved-link", text: name).click
  end

  # The saved rail's <details> ship closed, and mountSections REMEMBERS what was left open in
  # localStorage — which the browser carries across tests in one run. Clicking a summary to expand
  # would therefore collapse it in whichever test ran second. Opening them directly is scaffolding
  # for reaching the link; the folding itself is box_sections_test.rb's subject, not this file's.
  def expand_saved_rail
    assert_selector ".box-saved-rail .box-saved-section"
    page.execute_script(
      "document.querySelectorAll('.box-saved-rail details').forEach((d) => { d.open = true })",
    )
  end
end
