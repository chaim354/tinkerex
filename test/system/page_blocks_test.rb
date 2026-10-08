require "application_system_test_case"

# CONTENT BLOCKS, DRIVEN (2026-09-09; spec §9). The server tests prove what the doors write and what
# each page renders; only a browser can prove that the menu mints a slot from the server's template,
# that a card follows the inputs as they are typed, that Preview shows the server's Markdown, that a
# block drags like a panel, and that the grid PACKS — a gap is a layout fact, and nothing below the
# browser can measure one.
#
# ROWS ONLY, NEVER THE PORT (project_folder_rows!): the editor and the pickers read `nodes` and
# fetch no bytes. The consequence to remember when adding a case here is that a picture on a SAVED
# page has no bytes behind it, so the hero's and an image block's `<img>` answer 404 — which is why
# `assert_no_console_errors` is called on the pages that have no such image rather than everywhere.
class PageBlocksTest < ApplicationSystemTestCase
  include WebHelpers

  setup do
    @user = sign_in_as("page-blocks@example.com")
    @project = @user.maker_projects.create!(name: "Lamp", description: "A lamp.")
    @folder = project_folder_rows!(@user, @project)
    @photos = dir!("photos", @folder.node_id)
    @side = file!("side.jpg", @photos.node_id)
    @front = file!("front.png", @photos.node_id)
  end

  def dir!(name, parent) = @user.nodes.create!(node_id: SecureRandom.uuid, name:, kind: "dir", parent_node_id: parent, mtime: 1, size: 0)
  def file!(name, parent) = @user.nodes.create!(node_id: SecureRandom.uuid, name:, kind: "file", parent_node_id: parent, mtime: 1, size: 3)
  def slot(k) = "div.panel-slot[data-key='#{k}']"
  def new_slot(kind) = "div.panel-slot[data-kind='#{kind}'][data-key^='block:new-']"

  # [top, bottom, left] of the SLOT around the block whose section carries id=<layout key>.
  # `getElementById` rather than a CSS selector: a layout key contains a colon, which a selector
  # would have to escape and an id lookup does not.
  def rect(key)
    page.evaluate_script("(() => { const r = document.getElementById(#{key.to_json}).closest('.panel-slot').getBoundingClientRect(); return [r.top, r.bottom, r.left]; })()")
  end

  def open_editor
    visit edit_layout_project_path(@project)
    assert_selector ".layout-bar", text: "Editing page layout"
  end

  # A `<template>`'s contents are INERT in a browser — a DocumentFragment, not part of the document
  # — so `all("div.panel-slot")` and every selector below count only the slots that are really on
  # the page, and the three templates beside the drawer are invisible to all of them.
  def add(kind)
    find("details.layout-add > summary").click
    find("details.layout-add button[data-kind='#{kind}']").click
    assert_selector new_slot(kind)
  end

  test "a text block: add, type, preview, save, and it is first on the page" do
    open_editor
    add("text")
    within(new_slot("text")) do
      fill_in "Heading", with: "Why a printed shade"
      fill_in "Text (Markdown)", with: "A **paper** shade yellows."
      # THE PREVIEW IS THE SERVER'S RENDERER (spec §2): a second Markdown implementation in the
      # browser would be a preview that lies about what the page will show.
      click_on "Preview"
      assert_selector ".block-preview strong", text: "paper"
    end
    assert_equal "block:new-1", all("div.panel-slot").first["data-key"], "Add lands the block first"

    click_on "Save"
    assert_selector ".flash-notice", text: "Page layout saved."
    block = @project.blocks.sole
    assert_equal [ "text", "Why a printed shade", "A **paper** shade yellows." ], [ block.kind, block.heading, block.body ]
    assert_equal block.layout_key, @project.reload.panels["order"].first, "and Save rewrote the placeholder key into the order"
    assert_selector "section.block--text h2", text: "Why a printed shade"
    assert_selector "section.block--text .markdown strong", text: "paper"
    assert_no_console_errors
  end

  test "a link block's card follows the inputs, and an image block picks a folder image" do
    open_editor
    add("link")
    within(new_slot("link")) do
      fill_in "URL", with: "https://www.printables.com/model/1"
      fill_in "Title", with: "Printables"
      fill_in "One line", with: "Sliced files."
      # DRAWN LIVE, NOT FETCHED: the card is pure arrangement of what was just typed, and the host
      # is parsed in the browser.
      assert_selector ".block-link-card .block-link-title", text: "Printables"
      assert_selector ".block-link-card .block-link-line", text: "Sliced files."
      assert_selector ".block-link-card .block-link-host", text: "www.printables.com"
    end
    add("image")
    within(new_slot("image")) do
      find("button.image-pick[data-node-id='#{@side.node_id}']").click
      assert_selector "button.image-pick.active[data-node-id='#{@side.node_id}']"
      fill_in "Caption", with: "Side on."
    end

    click_on "Save"
    assert_selector ".flash-notice", text: "Page layout saved."
    link = @project.blocks.find_by(kind: "link")
    image = @project.blocks.find_by(kind: "image")
    assert_equal [ "Printables", "https://www.printables.com/model/1", "Sliced files." ], [ link.heading, link.url, link.line ]
    assert_equal [ @side.node_id, "Side on." ], [ image.node_id, image.caption ]
    assert_selector "section.block--link a.block-link-card[href='https://www.printables.com/model/1']"
    assert_selector "section.block--image figure img"
    assert_selector "section.block--image figcaption", text: "Side on."
  end

  test "Delete removes a block and Save persists the removal; a dragged block lands below Files" do
    gone = @project.blocks.create!(user: @user, kind: "text", body: "gone")
    kept = @project.blocks.create!(user: @user, kind: "text", body: "kept")
    # THE WHOLE PAGE IN VIEW, so the stepped drag below never has to leave the viewport (a pointer
    # move outside it is refused) and nothing scrolls mid-gesture. The 2026-10-08 redesign's 14px
    # type put Photos' top at y≈1290 in the suite's 1257px viewport. Restored in `ensure`.
    page.current_window.resize_to(1400, 2200)
    open_editor
    within(slot(gone.layout_key)) { click_on "Delete" }
    assert_no_selector slot(gone.layout_key)

    # THE DROP TARGET MUST BE IN THE VIEWPORT, and Photos is the panel that is on this page. A
    # `move_to` whose element is below the fold makes Selenium SCROLL first — mid-drag, which moves
    # every rect Sortable is comparing against and loses the drop silently (measured: Tasks sits at
    # y≈1475 in a 1257px viewport here, the page scrolled 298px, and the slot did not move).
    drag(find("#{slot(kept.layout_key)} .panel-strip-handle"), find(slot("photos")))
    order = all("div.panel-slot").map { |s| s["data-key"] }
    assert_operator order.index(kept.layout_key), :>, order.index("attachments"),
                    "the block dropped below Files: #{order.inspect}"

    click_on "Save"
    assert_selector ".flash-notice", text: "Page layout saved."
    # A BLOCK ABSENT FROM THE POSTED DRAFT IS DESTROYED (spec decision 3): the draft is the whole
    # truth of blocks, so removing the slot IS the delete, and nothing else had to ask for it.
    assert_nil Maker::ProjectBlock.find_by(id: gone.id)
    saved = @project.reload.panels["order"]
    assert_operator saved.index(kept.layout_key), :>, saved.index("attachments")
  ensure
    page.current_window.resize_to(1400, 1400)
  end

  # SORTABLE RUNS `forceFallback: true` (layout_editor_controller.js says why), so it listens for
  # REAL mouse events rather than the HTML5 drag events `drag_to` synthesises — a `drag_to` here
  # moves nothing at all, silently. The gesture: press on the handle, move 40px to pass
  # `fallbackTolerance`, then WALK to a point just past the target's centre and release.
  #
  # WHY A WALK AND NOT A JUMP (2026-10-08). The earlier sequence jumped onto the target with two
  # `move_to`s and a 10px nudge, and it was knife-edge on geometry: masonry re-packs the grid the
  # instant the first slot lifts, and Sortable decides on the rects it sees at that moment. The
  # redesign's 14px type tipped it (bisected to a combination of component hunks, none wrong
  # alone): the pointer sat on Photos' centre with Photos correctly under it, and Sortable made no
  # move. Each step here re-reads the target's rect and covers half the remaining distance, which
  # is the run of `mousemove`s a person's drag produces — and a person never meets the knife-edge,
  # because they watch the ghost and release when it looks right. Mutation-checked: Sortable
  # created with `disabled: true` turns the order assertion red.
  #
  # THE WHOLE PAGE MUST BE IN VIEW (the test resizes the window to 1400×2200): Selenium refuses a
  # pointer move outside the viewport, and a page that scrolls mid-gesture moves every rect Sortable
  # is comparing against. test/system/page_tabs_test.rb records the same constraint for its page.
  def drag(handle, target)
    target_key = target["data-key"]
    b = page.driver.browser
    b.action.click_and_hold(handle.native).move_by(0, 40).perform
    pointer = center_of(handle).then { |x, y| [ x, y + 40 ] }
    # STEPPED, LIKE A HAND. Each step re-reads the target's rect (masonry re-packs and the page may
    # scroll under the drag) and covers half the remaining distance to a point just past its centre,
    # so Sortable sees the run of `mousemove`s a person's drag produces rather than one jump.
    12.times do
      tx, ty = center_of_slot(target_key)
      dx = ((tx + 10 - pointer[0]) / 2.0).round
      dy = ((ty + 10 - pointer[1]) / 2.0).round
      break if dx.abs < 2 && dy.abs < 2
      b.action.move_by(dx, dy).perform
      pointer = [ pointer[0] + dx, pointer[1] + dy ]
    end
    b.action.move_by(2, 2).release.perform
  end

  # Viewport-relative centres, read in the browser so they reflect the layout at this instant.
  def center_of(el) = page.evaluate_script("(() => { const r = arguments[0].getBoundingClientRect(); return [r.left + r.width / 2, r.top + r.height / 2]; })()".sub("arguments[0]", "document.querySelector(#{css_path_for(el).to_json})"))
  def center_of_slot(key) = page.evaluate_script("(() => { const r = document.querySelector(#{slot(key).to_json}).getBoundingClientRect(); return [r.left + r.width / 2, r.top + r.height / 2]; })()")
  def css_path_for(handle) = "#{slot(handle.find(:xpath, "ancestor::div[contains(concat(' ', normalize-space(@class), ' '), ' panel-slot ')][1]")['data-key'])} .panel-strip-handle"

  # THE GATE ON SAVE (found in review): without it an empty block made the server refuse the whole
  # draft and reload the editor from the row — every other unsaved change in the session gone.
  test "Save refuses to leave with an empty block and keeps the rest of the session's changes" do
    open_editor
    within("div.panel-slot[data-key='tasks']") { click_on "Hide" }
    add("text")
    click_on "Save"
    assert_selector ".flash-notice", text: "Not saved: a text block needs a heading or a body"
    assert_current_path edit_layout_project_path(@project)
    assert_no_selector ".flash-alert"
    assert_selector "div.panel-slot[data-key='tasks'].panel-slot--hidden"
    within(new_slot("text")) { click_on "Delete" }
    click_on "Save"
    assert_selector ".flash-notice", text: "Page layout saved."
    assert_includes @project.reload.panels["hidden"], "tasks"
  end

  test "the page intro changes the description and the cover" do
    open_editor
    within(".page-intro") do
      fill_in "Description", with: "A lamp, rewritten."
      find("button.cover-pick[data-node-id='#{@front.node_id}']").click
      assert_selector ".cover-current", text: "front.png"
      assert_selector "button.cover-pick.active[data-node-id='#{@front.node_id}']"
    end
    # DRAINED HERE RATHER THAN AFTER Save: the cover this test picks is a rows-only fixture with no
    # bytes behind it, so the hero's `<img>` on the saved page answers 404 and Chrome logs it at
    # SEVERE. The claim worth making is about the editor, and this is where the editor is.
    assert_no_console_errors

    click_on "Save"
    assert_selector ".flash-notice", text: "Page layout saved."
    assert_equal [ "A lamp, rewritten.", @front.node_id ], [ @project.reload.description, @project.cover_node_id ]
    assert_selector "p.project-description", text: "A lamp, rewritten."
  end

  # APPLY CAN PUT A BLOCK ON THE PAGE THAT WAS NOT THERE A MOMENT AGO, which no other case here
  # reaches: Maker::LayoutDocument mints `block:new-N` for a `block:` entry whose `id:` names no row
  # of this project (spec decision 3), so the browser has to mint the matching SLOT — the same
  # template Add uses — or the pasted block would exist in the draft with nothing to show or edit,
  # and Save would write it from a page that never displayed it.
  test "Apply mints a slot for a block the pasted text creates, and Save writes it" do
    open_editor
    click_on "Edit as YAML"
    # A textarea's VALUE is not its text node, so no Capybara matcher can wait on the server's
    # answer arriving; poll it (slice 1's suite records the same).
    wait_until(message: "the drawer never filled with the server's YAML") do
      find("textarea.layout-yaml").value.include?("layout: 1")
    end
    find("textarea.layout-yaml").set("layout: 1\npanels:\n  - block: text\n    heading: Pasted\n    body: From another project.\n")
    click_on "Apply"

    assert_no_selector ".layout-note--error"
    assert_selector new_slot("text")
    within(new_slot("text")) do
      assert_field "Heading", with: "Pasted"
      assert_field "Text (Markdown)", with: "From another project."
    end

    click_on "Save"
    assert_selector ".flash-notice", text: "Page layout saved."
    block = @project.blocks.sole
    assert_equal [ "Pasted", "From another project." ], [ block.heading, block.body ]
    assert_equal block.layout_key, @project.reload.panels["order"].first
  end

  test "half-width panels pack: the slot below a short half starts within one gap of its bottom" do
    tall = @project.blocks.create!(user: @user, kind: "text", body: (1..40).map { |i| "line #{i}" }.join("\n\n"))
    short = @project.blocks.create!(user: @user, kind: "text", body: "short")
    third = @project.blocks.create!(user: @user, kind: "text", body: "third")
    @project.update!(panels: { "order" => [ tall.layout_key, short.layout_key, third.layout_key ] + Maker::Project::PANELS,
                               "widths" => { tall.layout_key => "half", short.layout_key => "half", third.layout_key => "half" } })

    visit project_path(@project)
    assert_selector "div.project-panels.masonry"
    assert_selector "section.block--text", minimum: 3
    tall_r, short_r, third_r = rect(tall.layout_key), rect(short.layout_key), rect(third.layout_key)

    assert_in_delta short_r[2], third_r[2], 1, "the third half sits in the short one's column"
    assert_operator third_r[0] - short_r[1], :<=, 17, "no gap: the third starts within one gap of the short one's bottom"
    assert_operator tall_r[1], :>, third_r[0], "and that is above the tall neighbour's bottom, i.e. a gap was actually closed"
  end
end
