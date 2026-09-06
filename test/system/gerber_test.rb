require "application_system_test_case"
require "support/gerber_fixture"

# tracespace ACTUALLY RENDERING a Gerber in a real browser. Everything else about the `:gerber`
# branch — which extensions reach it, the data attributes, the Fabrication panel's grouping, the
# `.gbrjob` rules — is request-level (test/integration/web/gerber_preview_test.rb, cheap, and
# already covers the parts a browser adds nothing to). What only a browser can see is this file's
# whole subject: does the vendored module load, does it parse real RS-274X and Excellon bytes, does
# it paint geometry rather than an empty `<svg>`, and does the CSP (report-only, but this is the
# check that matters per test/system/README.md) let the module and its fetches through.
#
# THE SVG LANDS IN THE LIGHT DOM, WHICH IS WHY THIS FILE IS SIMPLER THAN kicanvas_test.rb.
# `<kicanvas-embed>` paints into an open shadow root several custom elements deep, so that suite
# needs a recursive `shadowRoot` probe in JS — Capybara's Selenium-backed `:css` finder does not
# pierce shadow boundaries. gerber_controller.js assigns markup it built itself into the stage, so
# a plain `assert_selector ".gerber-stage svg path"` works and is the honest assertion.
#
# `data-gerber-state="ready"` IS SET AFTER THE RENDER, NOT BEFORE IT — again unlike KiCanvas, whose
# `ready` fires as soon as the embed is inserted and whose own async load then continues. Here the
# fetch, the parse, the plot and the serialisation have all happened by the time the attribute
# lands, so the path assertion below is not a race and needs no poll of its own.
#
# A DRILL FILE RENDERS A `<circle>`, NOT A `<path>` — measured against the vendored bundle, not
# assumed. So the single-layer assertion below is on a `.gtl`; the board assertions are on a set
# whose copper layers supply the paths. An assertion written as "any Gerber renders a path" would
# be red on a drill file while the viewer worked perfectly.
class GerberTest < ApplicationSystemTestCase
  include GerberFixture

  setup do
    @root = use_fresh_share_library!
    @user = sign_in_as("gerber@example.com")
  end

  teardown do
    FileLayer.reset!
    FileUtils.remove_entry(@root) if @root&.exist?
  end

  # The project's folder ROWS plus the directories they claim to be — never
  # `ensure_library_folder!`, which is a real mkdir through the port (the house rule; see
  # test/support/public_fixture.rb's header for the full argument).
  def project_with_board!(visibility: "private", stem: "board")
    project = @user.maker_projects.create!(name: "Driver", visibility:)
    projects_dir = @user.nodes.create!(node_id: SecureRandom.uuid, name: Maker::ProjectFolders::ROOT,
                                       kind: "dir", mtime: 1, size: 0,
                                       storage_path: Maker::ProjectFolders::ROOT)
    folder = @user.nodes.create!(node_id: SecureRandom.uuid, name: project.slug, kind: "dir",
                                 parent_node_id: projects_dir.node_id, mtime: 1, size: 0,
                                 storage_path: File.join(Maker::ProjectFolders::ROOT, project.slug))
    @root.join(folder.storage_path).mkpath
    project.update_column(:folder_node_id, folder.node_id)
    dir = gerber_dir!(name: "pcb", parent_node_id: folder.node_id)
    [ project, write_gerber_set!(stem:, parent_node_id: dir.node_id) ]
  end

  # MUTATION (§15, test/system/README.md; run for real, output in the PR, then reverted):
  # gerber_controller.js's `await import("tracespace")` changed to `await import("tracespace-x")` —
  # a specifier the importmap has no pin for — reds this test on the `ready` assertion, because the
  # catch block sets data-gerber-state="failed" instead.
  test "a real Gerber layer renders in the browser" do
    node = write_gerber!(name: "board.gtl")

    visit file_path(node.node_id)

    assert_selector ".gerber-stage[data-gerber-state='ready']"
    # GEOMETRY, NOT MERELY AN <svg>. tracespace emits a well-formed empty document for a file it
    # parsed and found nothing in, so asserting the element alone would pass over a viewer that
    # loaded and rendered nothing — this repo's dominant failure shape.
    assert_selector ".gerber-stage svg path", minimum: 1
    # The stage fills its box rather than rendering at the board's physical 10mm — the controller
    # overrides the attributes tracespace writes, and CSS cannot beat them (see gerber_controller.js).
    assert_equal "100%", find(".gerber-stage svg")[:width]
    assert_no_console_errors
  end

  test "a drill file renders too, as circles rather than paths" do
    node = write_gerber!(name: "board.drl", body: MINIMAL_DRILL)

    visit file_path(node.node_id)

    assert_selector ".gerber-stage[data-gerber-state='ready']"
    assert_selector ".gerber-stage svg circle", minimum: 1
    assert_no_console_errors
  end

  # THE STACKUP, AND THE TOGGLE. Bottom is a genuinely different picture — renderBoard mirrors the
  # board and composes the other side's copper, mask and silk — so comparing the two innerHTMLs is
  # what proves the toggle swapped something rather than re-rendering the same side.
  test "a project folder's Gerbers render as a board, and the Bottom toggle swaps the side" do
    project, = project_with_board!

    visit project_path(project)

    assert_selector ".fabrication-panel .gerber-stage[data-gerber-state='ready']"
    assert_selector ".fabrication-panel .gerber-stage svg path", minimum: 1
    top = find(".fabrication-panel .gerber-stage [data-gerber-target='stage']")["innerHTML"]

    find(".fabrication-panel button[data-gerber-side='bottom']").click

    # WAIT ON THE TOGGLE'S OWN STATE BEFORE READING THE STAGE. `show()` sets the class in the same
    # turn it assigns the markup, so this is what keeps the read below from racing the click.
    assert_selector ".fabrication-panel button[data-gerber-side='bottom'].active"
    bottom = find(".fabrication-panel .gerber-stage [data-gerber-target='stage']")["innerHTML"]
    assert_not_equal top, bottom, "the Bottom toggle rendered the same SVG as Top"
    assert_selector ".fabrication-panel .gerber-stage svg path", minimum: 1
    assert_no_console_errors
  end

  # SIGNED OUT, ON A PUBLIC PAGE. The viewer's own fetches go through the public file route, which a
  # visitor's request has no session behind — a route that answered 404 there would leave the panel
  # rendered and the board blank, which is exactly the pair Maker::PublicProject exists to prevent.
  test "the public project page renders the board to a signed-out visitor" do
    @user.update!(handle: "gerber")
    project, = project_with_board!(visibility: "public")
    Capybara.reset_sessions!

    visit public_project_path("gerber", project.slug)

    assert_selector ".fabrication-panel .gerber-stage[data-gerber-state='ready']"
    assert_selector ".fabrication-panel .gerber-stage svg path", minimum: 1
    assert_no_console_errors
  end
end
