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

  # THE ZIP IS UNPACKED IN THE BROWSER, AND ONLY A BROWSER CAN SHOW THAT. The server never opens a
  # member (Maker::GerberArchive lists the central directory and stops); everything below the fetch
  # — JSZip loading the archive, pulling the four members the server named, and tracespace
  # identifying each one from its BASENAME three directories down — happens here and nowhere else in
  # the suite. A request test can only assert that the paths were written into the attribute.
  #
  # MUTATION (§15, test/system/README.md; run for real, output in the PR, then reverted):
  # gerber_controller.js's `zip.file(path)` changed to `zip.file(path + "x")` reds this test on the
  # `ready` assertion — the member miss throws and the catch sets data-gerber-state="failed".
  test "a zipped Fusion export renders as a board, and the Bottom toggle swaps the side" do
    node = write_gerber_zip!

    visit file_path(node.node_id)

    assert_selector ".gerber-stage[data-gerber-state='ready']"
    # GEOMETRY, NOT MERELY AN <svg> — the copper layers inside the archive supply the paths, which
    # is what proves the members were really extracted and parsed rather than merely fetched.
    assert_selector ".gerber-stage svg path", minimum: 1
    top = find(".gerber-stage [data-gerber-target='stage']")["innerHTML"]

    find("button[data-gerber-side='bottom']").click

    assert_selector "button[data-gerber-side='bottom'].active"
    bottom = find(".gerber-stage [data-gerber-target='stage']")["innerHTML"]
    assert_not_equal top, bottom, "the Bottom toggle rendered the same SVG as Top"
    assert_no_console_errors
  end

  # ------------------------------------------------------------------------------------------
  # THE HANDS: pan, zoom, Fit and the per-layer toggles (lib/svg_pan_zoom.js + gerber_controller.js)
  #
  # ALL FOUR ARE BROWSER-ONLY BY CONSTRUCTION. The viewBox is written by a wheel or pointer
  # listener and read back off the live element; the toggles re-compose a tracespace render that
  # only exists after a fetch, a parse and a plot in this browser. There is no server contract to
  # assert against — `gerber_preview_test.rb` covers everything the server says about a board and
  # is deliberately unchanged by this feature.
  #
  # THESE ARE ALSO THE ONLY PIN THE MEASURE VIEW'S PAN/ZOOM HAS. The maths moved out of
  # measure_controller.js into lib/svg_pan_zoom.js on 2026-09-06 so both stages could share one
  # copy; nothing under test/system/*measure* drives a wheel or a drag, so a regression in the
  # shared module shows up HERE and nowhere else. Mutation-checked in both directions: neutering
  # `zoomAbout` reds the zoom case below and leaves every Measure test green.
  #
  # CAPYBARA CANNOT SEND A WHEEL EVENT, so the two helpers at the bottom of this file dispatch
  # real `WheelEvent`/`PointerEvent` objects through `execute_script`. Probed rather than assumed:
  # a synthetic `PointerEvent` with `pointerId: 1` is accepted by `setPointerCapture` in this
  # headless Chrome (it does NOT raise the `NotFoundError` an inactive pointer id can), so the
  # drag below exercises the same capture path a real mouse takes.

  test "the wheel zooms the board about the cursor" do
    node = write_gerber_zip!

    visit file_path(node.node_id)

    assert_selector ".gerber-stage[data-gerber-state='ready']"
    home_x, home_y, home_w, home_h = view_box

    wheel_on(delta_y: -100)
    x, y, w, h = view_box

    assert_operator w, :<, home_w, "a wheel up must narrow the viewBox"
    assert_operator h, :<, home_h, "the aspect ratio must survive a zoom"
    # ZOOMED ABOUT THE CURSOR, WHICH IS THE WHOLE POINT AND THE PART A NAIVE IMPLEMENTATION GETS
    # WRONG. The wheel lands at the element's centre, and with `xMidYMid meet` that maps exactly to
    # the viewBox's centre — so the centre must come back unmoved while the box shrinks around it.
    # Asserting the width alone would pass on a zoom that scaled about the ORIGIN and threw the
    # board off screen.
    assert_in_delta home_x + home_w / 2, x + w / 2, 0.001, "the point under the cursor must stay put"
    assert_in_delta home_y + home_h / 2, y + h / 2, 0.001, "the point under the cursor must stay put"
    assert_no_console_errors
  end

  test "a drag pans the board" do
    node = write_gerber_zip!

    visit file_path(node.node_id)

    assert_selector ".gerber-stage[data-gerber-state='ready']"
    home_x, home_y, home_w, home_h = view_box

    drag_on(dx: 80, dy: 0)
    x, y, w, h = view_box

    # DRAGGING RIGHT MOVES THE CONTENT RIGHT, WHICH MOVES THE viewBox LEFT — the sign is the thing
    # to get wrong, and a pan that inverted it would still change `x` by the right amount.
    assert_operator x, :<, home_x, "dragging right must move the viewBox left"
    assert_in_delta home_y, y, 0.001, "a horizontal drag must not move the view vertically"
    assert_in_delta home_w, w, 0.001, "a pan must not change the zoom"
    assert_in_delta home_h, h, 0.001, "a pan must not change the zoom"
    assert_no_console_errors
  end

  test "Fit returns the view to the whole board" do
    node = write_gerber_zip!

    visit file_path(node.node_id)

    assert_selector ".gerber-stage[data-gerber-state='ready']"
    home = view_box

    # MOVED ON BOTH AXES OF THE FEATURE BEFORE FITTING, so this cannot pass on a Fit that only
    # undoes one of them — or on one that never ran, which is what asserting against `home` alone
    # would do on an untouched view.
    wheel_on(delta_y: -100)
    drag_on(dx: 60, dy: 40)
    assert_not_equal home, view_box, "premise: the view must be off home before Fit"

    find(".gerber-tools .btn", exact_text: "Fit").click

    assert_equal home, view_box, "Fit must return the viewBox the render arrived with"
    assert_no_console_errors
  end

  # THE TOGGLE RE-COMPOSES FROM THE ONE RENDER, so what it must prove is that geometry LEFT the
  # picture — not merely that a button changed colour. The fixture's zipped export carries top
  # copper, bottom copper, an outline and a drill; the Top view draws two paths (the copper and
  # the outline) and one circle (the drill, in the mask), so hiding top copper takes the path
  # count from 2 to 1. Measured against the vendored bundle, not assumed.
  test "a layer toggle hides that layer, and the view survives it" do
    node = write_gerber_zip!

    visit file_path(node.node_id)

    assert_selector ".gerber-stage[data-gerber-state='ready']"
    # ZOOMED FIRST, so the "the view survives" assertion below is about a view the toggle could
    # actually have lost. Against the fit view it would pass on a re-render that reset everything.
    wheel_on(delta_y: -100)
    zoomed = view_box
    before = all(".gerber-stage svg path", visible: :all).size
    assert_operator before, :>, 1, "premise: the board must draw more than one layer's paths"

    find(".gerber-tools .btn", exact_text: "top copper").click

    assert_selector ".gerber-tools .btn[aria-pressed='false']", exact_text: "top copper"
    assert_no_selector ".gerber-tools .btn.active", exact_text: "top copper"
    assert_operator all(".gerber-stage svg path", visible: :all).size, :<, before,
                    "hiding top copper must remove its geometry from the render"
    assert_equal zoomed, view_box, "a toggle must not throw the reader back to the fit view"
    assert_no_console_errors
  end

  # A SINGLE LAYER GETS `Fit` AND NOTHING ELSE. There is one layer, so a toggle for it is a button
  # whose only effect is to blank the page — and the side toggle is absent for the same reason the
  # template omits it (one render, two buttons showing the same picture).
  # A STAGE WITH NO SIZE MUST NOT POISON THE VIEW. Screen -> user-space conversion divides by the
  # element's on-screen scale, and an element with a 0 x 0 rect (a hidden browser pane, a collapsed
  # container, a background tab) has none: the first draft of the shared module put `NaN` into the
  # viewBox on one wheel event over the real Wheel Clock board, and every pan after that stayed NaN
  # until Fit. Measured in the desktop app's hidden preview pane, where the viewport itself is 0 x 0
  # — which is why headless Chrome never saw it. The lib now answers the view's centre for a point
  # on a sizeless element and refuses a non-finite viewBox outright.
  # MUTATION: removing both guards in lib/svg_pan_zoom.js reds this on the finite assertion.
  test "a wheel over a stage collapsed to no size leaves the view finite" do
    node = write_gerber_zip!

    visit file_path(node.node_id)

    assert_selector ".gerber-stage[data-gerber-state='ready']"
    home = view_box
    page.execute_script(<<~JS)
      const stage = document.querySelector('.gerber-stage [data-gerber-target="stage"]')
      stage.style.width = "0px"; stage.style.height = "0px"; stage.style.overflow = "hidden"
      stage.querySelector("svg").style.width = "0px"; stage.querySelector("svg").style.height = "0px"
    JS
    assert_equal [ 0, 0 ], page.evaluate_script(<<~JS), "premise: the stage must really be sizeless"
      (() => { const r = document.querySelector('.gerber-stage svg').getBoundingClientRect(); return [r.width, r.height] })()
    JS

    wheel_on(delta_y: -100)
    drag_on(dx: 40, dy: 10)
    # THE RAW ATTRIBUTE, NOT `view_box`: Ruby's `"NaN".to_f` is 0.0, so a parsed viewBox is finite
    # by construction and an assertion on it passed with `NaN NaN …` on the element (the mutation
    # was caught only by Chrome logging the invalid attribute). The string is the honest witness.
    raw = page.evaluate_script("document.querySelector('.gerber-stage svg').getAttribute('viewBox')")

    assert_no_match(/NaN|Infinity/, raw, "the viewBox must stay finite on a sizeless stage")
    # The wheel still zooms — about the view's centre, the only point a sizeless element can name.
    assert_operator view_box[2], :<, home[2], "the zoom itself must still apply"
    assert_no_console_errors
  end

  test "the single-layer page offers Fit and no layer toggles" do
    node = write_gerber!(name: "board.gtl")

    visit file_path(node.node_id)

    assert_selector ".gerber-stage[data-gerber-state='ready']"
    assert_selector ".gerber-tools .btn", exact_text: "Fit"
    assert_selector ".gerber-tools .btn", count: 1
    assert_no_selector "[data-gerber-layer-id]"
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

  private
    # THE VIEWBOX AS FOUR FLOATS. Split on whitespace AND commas, because the SVG spec allows both
    # and a board's box is routinely negative in y (`viewBox="0 -10 10 10"` on this fixture), so a
    # number scan that dropped the signs would read a pan as a no-op.
    def view_box(selector = ".gerber-stage")
      raw = page.evaluate_script(<<~JS)
        (() => {
          const el = document.querySelector("#{selector} svg")
          return el && el.getAttribute("viewBox")
        })()
      JS
      raw.to_s.strip.split(/[\s,]+/).map(&:to_f)
    end

    # A REAL `WheelEvent` AT THE ELEMENT'S CENTRE. Capybara's Selenium driver has no wheel action
    # that can carry a chosen `deltaY` to a chosen point, and the listener reads `deltaY`,
    # `clientX` and `clientY` — so this constructs the event the listener actually sees.
    # `cancelable: true` matters: the handler calls `preventDefault()`, and a non-cancelable event
    # makes that a silent no-op plus a console warning the sweep would catch.
    def wheel_on(selector = ".gerber-stage", delta_y:)
      page.execute_script(<<~JS)
        (() => {
          const el = document.querySelector("#{selector} svg")
          const r = el.getBoundingClientRect()
          el.dispatchEvent(new WheelEvent("wheel", {
            deltaY: #{delta_y}, clientX: r.left + r.width / 2, clientY: r.top + r.height / 2,
            bubbles: true, cancelable: true
          }))
        })()
      JS
    end

    # pointerdown -> pointermove -> pointerup from the element's centre, the three events a drag is.
    # `pointerId: 1` with `isPrimary: true` is what the handler tracks in its pointer map, and
    # `button: 0` is what its mouse guard checks; ONE move is enough because the pan is computed
    # from the origin rather than accumulated per frame.
    def drag_on(selector = ".gerber-stage", dx:, dy:)
      page.execute_script(<<~JS)
        (() => {
          const el = document.querySelector("#{selector} svg")
          const r = el.getBoundingClientRect()
          const x = r.left + r.width / 2, y = r.top + r.height / 2
          const opts = (cx, cy) => ({
            pointerId: 1, pointerType: "mouse", isPrimary: true, button: 0, buttons: 1,
            clientX: cx, clientY: cy, bubbles: true, cancelable: true
          })
          el.dispatchEvent(new PointerEvent("pointerdown", opts(x, y)))
          el.dispatchEvent(new PointerEvent("pointermove", opts(x + #{dx}, y + #{dy})))
          el.dispatchEvent(new PointerEvent("pointerup", opts(x + #{dx}, y + #{dy})))
        })()
      JS
    end
end
