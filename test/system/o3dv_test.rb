require "application_system_test_case"
require "support/mesh_fixture"
require "support/three_mf_fixture"

# ONLINE3DVIEWER ACTUALLY RENDERING A MODEL IN A REAL BROWSER. Everything else about the `:model3d`
# branch — which extensions reach it, the data attributes, the model page's switcher membership —
# is request-level (files_flow_test.rb, models_flow_test.rb, files_controller_preview_kind_test.rb,
# all cheap and all backend-neutral). What only a browser can see is this file's whole subject: does
# the vendored bundle load, does each importer actually parse real bytes, does the canvas appear,
# are the dimensions the ones the fixture's own coordinates imply, and does the CSP (report-only,
# but this is the check that matters per test/system/README.md) let the module and its fetches
# through.
#
# THREE FORMATS, THREE DIFFERENT IMPORTERS, AND THAT IS THE POINT OF THE COUNT. `.stl` is
# Online3DViewer's own binary reader, `.ply` its own ASCII reader and `.glb` its glTF reader — a
# suite that drove only STL would prove the engine boots and nothing about the widening from three
# formats to nineteen that this whole slice is.
#
# THE DIMS ASSERTIONS ARE EXACT, NOT SHAPE-MATCHES, and that is deliberate. `/\d+ × \d+/` passes on
# any two numbers, including the WRONG model's — and this page can show the wrong model, because a
# model-page switcher exists whose entire job is swapping one file for another. Each fixture is
# therefore a different size, and each test names the size its own coordinates produce
# (test/support/mesh_fixture.rb writes them beside the vertices).
#
# THE VIEWER'S CANVAS IS IN THE LIGHT DOM, which is why this file is simpler than kicanvas_test.rb:
# `EmbeddedViewer` appends a plain `<canvas>` to the element it is handed, so
# `assert_selector ".model-viewer-stage canvas"` works and is the honest assertion. No shadow-root
# recursion is needed here.
class O3dvTest < ApplicationSystemTestCase
  include MeshFixture
  include ThreeMfFixture

  setup do
    @root = use_fresh_share_library!
    @user = sign_in_as("o3dv@example.com")
  end

  teardown do
    FileLayer.reset!
    FileUtils.remove_entry(@root) if @root&.exist?
  end

  # MUTATION (§15, test/system/README.md; run for real, output in the PR, then reverted):
  # modelviewer_controller.js's `await import("online-3d-viewer")` changed to
  # `await import("online-3d-viewer-x")` — a specifier the importmap has no pin for — reds every
  # test in this file on the `ready` assertion, because the catch block sets
  # data-modelviewer-state="failed" and puts the poster back instead.
  def view_in_3d!(node)
    visit file_path(node.node_id)
    click_on "View in 3D"
  end

  def assert_rendered(dims)
    assert_selector ".model-viewer[data-modelviewer-state='ready']"
    assert_selector ".model-viewer-stage canvas"
    assert_selector ".model-viewer-dims", text: dims
    assert_no_console_errors
  end

  test "a binary STL renders, and reports the size its own vertices imply" do
    node = write_model!(name: "bracket.stl", body: binary_stl)
    view_in_3d!(node)
    assert_rendered(MeshFixture::STL_DIMS)
  end

  test "an ASCII PLY renders through a different importer than the STL one" do
    node = write_model!(name: "scan.ply", body: MeshFixture::PLY)
    view_in_3d!(node)
    assert_rendered(MeshFixture::PLY_DIMS)
  end

  test "a GLB renders through the glTF importer" do
    node = write_model!(name: "scene.glb", body: glb)
    view_in_3d!(node)
    assert_rendered(MeshFixture::GLB_DIMS)
  end

  # THE URL IS WHAT CHOOSES THE IMPORTER, so it gets an assertion of its own rather than being
  # implied by the render. Online3DViewer reads the format off the fetched URL'S OWN trailing
  # extension (its io/fileutils.js `GetFileExtension`), never off the bytes or a Content-Type —
  # the identical trap KiCanvas fell into, and the reason `named_blob_file_path` exists. Pointing
  # the viewer at the extensionless `blob_file_path` reaches NO importer at all, and the page's
  # only symptom is the poster coming back.
  test "the viewer is pointed at the named blob route, extension and all" do
    node = write_model!(name: "bracket.stl", body: binary_stl)
    visit file_path(node.node_id)

    assert_selector ".model-viewer[data-modelviewer-url-value='" \
                    "#{named_blob_file_path(node.node_id, filename: node.name)}']"
  end

  # THE FAILURE CONTRACT, DRIVEN RATHER THAN ARGUED: a file the importer cannot read must put the
  # server-rendered poster back, not leave an empty stage. This is also the state a deployment that
  # lost public/o3dv/<version>/ would land in for every CAD file, which is why it is worth a test
  # of its own and not just a comment.
  test "bytes no importer can read restore the poster instead of an empty stage" do
    node = write_model!(name: "corrupt.stl", body: "this is not an STL at all\n" * 4)
    view_in_3d!(node)

    assert_selector ".model-viewer[data-modelviewer-state='failed']"
    assert_no_selector ".model-viewer.model-viewer--ready"
    assert_selector ".model-viewer-fallback", visible: true
  end

  # THE MODEL PAGE'S SWITCHER, which is the one surface where the viewer must swap one live model
  # for another. Two files of DIFFERENT sizes, so "it switched" is a claim the dims can actually
  # carry — with two identically-sized fixtures this test would pass without switching anything.
  test "the model page's source select swaps the live model" do
    stl = write_model!(name: "body.stl", body: binary_stl)
    ply = write_model!(name: "shell.ply", body: MeshFixture::PLY)
    model = @user.maker_models.create!(title: "Switcher")
    [ stl, ply ].each_with_index do |node, i|
      model.file_attachments.create!(user: @user, node_id: node.node_id,
                                     role: Maker::FileAttachment.role_for(node.name), position: i)
    end

    visit model_path(model)
    click_on "View in 3D"
    assert_selector ".model-viewer[data-modelviewer-state='ready']"
    assert_selector ".model-viewer-dims", text: MeshFixture::STL_DIMS

    # BY CLASS, NOT BY LABEL: the switcher's accessible name is an `aria-label`, and Capybara only
    # matches those when `Capybara.enable_aria_label` is set, which this suite does not set.
    find("select.model-viewer-source").select("shell.ply")
    assert_selector ".model-viewer-dims", text: MeshFixture::PLY_DIMS
    assert_selector ".model-viewer-stage canvas"
    assert_no_console_errors
  end

  # ---- 3MF: the slicer's colours and the declared unit, which the importer cannot read ----------

  # THE ONE CLAIM ONLY A BROWSER CAN SETTLE. Everything about the manifest itself is a unit test
  # (three_mf_manifest_test.rb) and everything about the data attributes is request-level
  # (files_flow_test.rb); what neither can see is whether the server's leaf ORDER is the same order
  # the engine numbers its meshes in. That is the assumption the whole feature rests on, it is an
  # assumption about someone else's importer, and it is checked here by reading the materials out
  # of the live scene and sorting them by the engine's own `meshIndex`.
  #
  # THE FIXTURE'S BUILD ORDER IS NOT ITS ID ORDER (container 4 then 2, resources 2 then 4), so a
  # server walk over `<resources>` would put the colours on the wrong cubes and this test would read
  # them reversed rather than absent.
  MESH_MATERIALS_JS = <<~JS
    (function () {
      const el = document.querySelector(".model-viewer");
      const c = window.Stimulus.getControllerForElementAndIdentifier(el, "modelviewer");
      const out = [];
      c.viewer.GetViewer().scene.traverse(function (o) {
        if (!o.isMesh) return;
        const m = Array.isArray(o.material) ? o.material[0] : o.material;
        out.push({ index: o.userData.originalMeshInstance ? o.userData.originalMeshInstance.id.meshIndex : null,
                   hex: m.color.getHexString(), uuid: m.uuid });
      });
      out.sort(function (a, b) { return a.index - b.index; });
      return out;
    })()
  JS

  def mesh_materials = page.evaluate_script(MESH_MATERIALS_JS)

  test "a Bambu project's parts wear their own filament colours, in the engine's mesh order" do
    node = write_model!(name: "plate.3mf",
                        body: bambu_3mf(objects: [ { extruder: 1 }, { extruder: 2 } ],
                                        filaments: %w[#161616 #F98C36 #FFFFFF]))
    view_in_3d!(node)
    assert_selector ".model-viewer[data-modelviewer-state='ready']"

    materials = mesh_materials
    assert_equal [ 0, 1 ], materials.map { |m| m["index"] },
                 "the engine did not number these meshes 0,1 — the whole match is by that index"
    assert_equal %w[161616 f98c36], materials.map { |m| m["hex"] }
    assert_not_equal materials[0]["uuid"], materials[1]["uuid"],
                     "both parts share one material object, so painting one would paint both"
    assert_no_console_errors
  end

  # A PART-LEVEL EXTRUDER IS THE CASE A REAL PROJECT USES for lettering in a second filament, and it
  # is the one the server has to resolve through TWO ids (the build item's object and the component's
  # object inside the part file). Driven here as well as in the unit test because a wrong id pairing
  # produces a manifest of the right LENGTH — which the count check happily accepts.
  test "a part-level extruder paints that part, not the object's colour" do
    node = write_model!(name: "letters.3mf",
                        body: bambu_3mf(objects: [ { extruder: 1 }, { extruder: 1, part_extruder: 2 } ],
                                        filaments: %w[#161616 #F98C36 #FFFFFF]))
    view_in_3d!(node)
    assert_selector ".model-viewer[data-modelviewer-state='ready']"

    assert_equal %w[161616 f98c36], mesh_materials.map { |m| m["hex"] }
    assert_no_console_errors
  end

  # A COUNT MISMATCH APPLIES NOTHING, and this is the case worth driving rather than reasoning about:
  # three colours for two meshes means the server's walk and the importer disagreed about the file,
  # and a wrong colour on the wrong part is worse than grey.
  #
  # THE MISMATCH IS REAL, NOT SIMULATED. The third object holds a well-formed EMPTY mesh: the
  # server's walk counts it (it is an `<object>` with a `<mesh>`) while Online3DViewer's converter
  # drops a mesh with no triangles, so `MeshCount()` is 2 against a list of 3 — measured, and it is
  # the only shape found where the two genuinely disagree AND the import still succeeds (deleting a
  # part file instead takes the whole import down, because three's loader clones a component's
  # object without checking it resolved).
  #
  # BOTH MESHES MUST COME OUT SHARING THE ENGINE'S ONE MATERIAL, which is the sharpest assertion
  # available: applying anything at all clones per mesh, so the uuids diverge whether or not the
  # colour happens to look right.
  test "more colours than meshes leaves every part on the engine's own material" do
    node = write_model!(name: "mismatch.3mf",
                        body: bambu_3mf(objects: [ { extruder: 1 }, { extruder: 2 },
                                                   { extruder: 3, empty: true } ],
                                        filaments: %w[#161616 #F98C36 #FFFFFF]))
    view_in_3d!(node)
    assert_selector ".model-viewer[data-modelviewer-state='ready']"

    materials = mesh_materials
    assert_equal 2, materials.size, "the empty third object should not have reached the scene"
    assert_equal materials[0]["uuid"], materials[1]["uuid"],
                 "a material was cloned, so colours were applied despite the count mismatch"
    assert_empty(materials.map { |m| m["hex"] } & %w[161616 f98c36 ffffff],
                 "a slicer colour was applied from a list that does not match this model")
  end

  # THE UNIT, WHICH IS A MEASUREMENT BUG RATHER THAN A COLOUR ONE. three's 3MFLoader ignores
  # `<model unit>`, so this 10-unit cube declaring metres reads "10 × 10 × 10 mm" — 1000x short —
  # unless the server's factor reaches showDims(). The number is exact, and it is exact in the
  # rendered form (`toLocaleString` groups it), because that is what the user sees.
  test "a 3MF declaring metres measures in millimetres" do
    node = write_model!(name: "metre-cube.3mf", body: plain_3mf(unit: "meter", size: 10))
    view_in_3d!(node)

    assert_selector ".model-viewer[data-modelviewer-state='ready']"
    assert_selector ".model-viewer-dims", text: "10,000 × 10,000 × 10,000 mm"
    assert_no_console_errors
  end

  # A PLAIN 3MF IN MILLIMETRES IS THE CONTROL, and it is not redundant: it is what proves the factor
  # is a factor rather than a constant, and that a file with no slicer metadata is left alone.
  test "a plain 3MF in millimetres measures its own size and keeps the engine's colour" do
    node = write_model!(name: "plain.3mf", body: plain_3mf(size: 20))
    view_in_3d!(node)

    assert_selector ".model-viewer[data-modelviewer-state='ready']"
    assert_selector ".model-viewer-dims", text: "20 × 20 × 20 mm"
    assert_no_console_errors
  end

  # ---- OpenCascade (STEP/IGES/BREP/FCStd), the one importer that is a separate WebAssembly file --

  # WHAT THIS PROVES AND WHAT IT DOES NOT, stated plainly because the difference is the whole
  # design of the test. It does NOT prove OpenCascade parses a real solid: a valid STEP with
  # geometry runs to hundreds of lines of B-rep entities, and carrying one here would test
  # upstream's kernel rather than this app's wiring. What it proves is the wiring, in two halves:
  #
  #   1. the `.step` page reaches the viewer and the engine asks for OUR OWN worker —
  #      `/o3dv/<version>/occt-import-js-worker.js` — with NO jsdelivr request anywhere on the
  #      page. That is bin/build-o3dv's patch working end to end; upstream ships hard-coded CDN
  #      URLs, which `script-src 'self'` would refuse and an offline self-host could never reach.
  #   2. that worker, driven directly, LOADS AND ANSWERS — which means it resolved
  #      `importScripts('occt-import-js.js')` beside itself, instantiated the 7.7 MB
  #      `occt-import-js.wasm` through emscripten's `locateFile`, and ran `ReadFile`. A reply of
  #      ANY kind is the proof; `success: false` is the correct answer for a STEP file with an
  #      empty DATA section, and is what the assertion expects.
  #
  # The fixture therefore ends at `state="failed"` ("The model doesn't contain any meshes."), which
  # is the honest outcome and the same graceful path the corrupt-bytes test above pins.
  OCCT_PROBE_JS = <<~JS
    window.__occt = null;
    try {
      const w = new Worker("/o3dv/0.18.0/occt-import-js-worker.js");
      w.onmessage = (ev) => { window.__occt = { answered: true, success: !!(ev.data && ev.data.success) }; };
      w.onerror = (ev) => { window.__occt = { answered: false, message: ev.message || "worker error" }; };
      w.postMessage({
        format: "step",
        buffer: new TextEncoder().encode(#{MeshFixture::STEP.to_json}),
        params: { linearUnit: "millimeter", linearDeflectionType: "bounding_box_ratio",
                  linearDeflection: 0.001, angularDeflection: 0.5 }
      });
    } catch (e) { window.__occt = { answered: false, message: String(e) }; }
  JS

  # THE WASM IS 7.7 MB AND IS COMPILED, NOT JUST FETCHED, so this gets its own budget rather than
  # Capybara's 10 s. Free on a green run: the poll returns the moment the worker replies.
  def wait_for_occt(timeout: 60)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    loop do
      result = page.evaluate_script("window.__occt")
      return result if result
      flunk "the occt-import-js worker never answered in #{timeout}s" if
        Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
      sleep 0.25
    end
  end

  test "a STEP file drives the OpenCascade importer from our own directory, never a CDN" do
    node = write_model!(name: "bracket.step", body: MeshFixture::STEP)
    view_in_3d!(node)

    # The import ends in the failure state (an empty DATA section has no meshes) — the point is
    # everything that had to work to GET there.
    assert_selector ".model-viewer[data-modelviewer-state='failed']"

    requested = page.evaluate_script("performance.getEntriesByType('resource').map((e) => e.name)")
    assert requested.any? { |u| u.include?("/o3dv/0.18.0/occt-import-js-worker.js") },
           "the engine never asked for the local occt worker; it requested: #{requested.inspect}"
    assert_empty requested.select { |u| u.include?("jsdelivr") },
                 "the vendored bundle reached a CDN — bin/build-o3dv's patch is not in this build"

    page.execute_script(OCCT_PROBE_JS)
    result = wait_for_occt
    assert result["answered"], "the occt worker errored instead of answering: #{result.inspect}"
    assert_equal false, result["success"],
                 "a STEP file with an empty DATA section should parse to nothing, not to a solid"

    assert_no_console_errors
  end

  # ---- the viewer's lifecycle: a Turbo Back, a switch mid-import, an engine released mid-import --
  #
  # THREE STATES THE CONTROLLER USED TO GET WRONG, EACH DRIVEN HERE RATHER THAN READ OFF THE ENGINE
  # (audit 2026-10-19, F-S22-1). Each test below was run against the code before the fix and went
  # red there; the comment above each one records how. The vendored engine (o3dv.js) has two rules
  # that make all three possible, and they are worth knowing before touching any of this:
  #
  #   1. `EmbeddedViewer` runs ONE import at a time. A load asked for while one is running is
  #      DROPPED, silently (`ThreeModelLoader.LoadModel` opens with `this.inProgress || …`). Before
  #      dropping it, `LoadModelFromInputFiles` throws away the RUNNING import's progress element,
  #      and that import's next callback then writes to `null`.
  #   2. `Destroy()` does not stop a running import. It finishes on the destroyed engine and calls
  #      back whatever callback that engine was built with.
  #
  # THE ENGINE FETCHES WITH XMLHttpRequest (o3dv.js `Lf`), NOT `fetch`, so gerber_test.rb's fetch
  # stub would never see a model request. This gate holds the XHR for any URL that names one of
  # `needles` until the test releases it. That turns "while a model is importing" into a state a
  # test can stand in, instead of a race it hopes to win. Every other request goes out as usual.
  XHR_GATE_JS = <<~JS
    (function (needles) {
      const open = XMLHttpRequest.prototype.open
      const send = XMLHttpRequest.prototype.send
      window.__heldXhr = []
      XMLHttpRequest.prototype.open = function (method, url) {
        this.__url = String(url)
        return open.apply(this, arguments)
      }
      XMLHttpRequest.prototype.send = function () {
        const args = arguments
        if (!needles.some((n) => this.__url.includes(n))) return send.apply(this, args)
        window.__heldXhr.push({ url: this.__url, go: () => send.apply(this, args) })
      }
      window.__releaseXhr = function (needle) {
        const i = window.__heldXhr.findIndex((h) => h.url.includes(needle))
        if (i < 0) return false
        window.__heldXhr.splice(i, 1)[0].go()
        return true
      }
    })(arguments[0])
  JS

  # A MODEL PAGE WITH ONE SWITCHER OPTION PER NODE, the first one selected (the page's default is
  # the cover, else the first attachment).
  def switcher_model!(*nodes)
    model = @user.maker_models.create!(title: "Switcher")
    nodes.each_with_index do |node, i|
      model.file_attachments.create!(user: @user, node_id: node.node_id,
                                     role: Maker::FileAttachment.role_for(node.name), position: i)
    end
    model
  end

  def gate_xhr!(*needles) = page.execute_script(XHR_GATE_JS, needles)

  # Waits until the engine's request for `needle` is being held, which is the moment an import is
  # provably RUNNING: the engine has been built and has asked for the bytes.
  def wait_until_held(needle)
    wait_until(message: "the engine never asked for #{needle}, so nothing is importing yet") do
      page.evaluate_script("window.__heldXhr.some((h) => h.url.includes(#{needle.to_json}))")
    end
  end

  def release_xhr(needle)
    assert page.evaluate_script("window.__releaseXhr(#{needle.to_json})"), "#{needle} was not being held"
  end

  # BACK TO A FILE PAGE WHOSE VIEWER WAS OPEN. Turbo restores its snapshot of the page, which carries
  # `--ready`, the state attribute, the dims line and a blank CLONED <canvas>, and connects a fresh
  # controller that has no engine. Before the fix the launch button stayed hidden under `--ready`,
  # Reset was a no-op and Fullscreen enlarged an empty box. `connect()` now rests the element, which
  # is gerber_controller.js's rule.
  #
  # THE CANVASES ARE THE SECOND HALF. A rest that dropped the class and kept the cloned canvas would
  # pass every assertion here except the two about canvases, because the stage is display:none at
  # rest. The next launch would then append a second canvas below the clone. Hence
  # `visible: :all` on both canvas assertions: one right after the Back, one counting after the
  # relaunch.
  #
  # RED BEFORE THE FIX, on the first viewer assertion: `--ready` came back with the snapshot.
  # MUTATIONS (§15; run for real, output in the PR, then reverted): dropping `this.rest()` from
  # `connect()` reds the `--ready` assertion. Dropping the stage's `replaceChildren()` from
  # `release()` reds the canvas assertion right after the Back ("expected not to find css
  # .model-viewer-stage canvas, found 1 match"): the snapshot's clone survives.
  test "Back to a file page whose 3D viewer was open rests at the poster" do
    node = write_model!(name: "bracket.stl", body: binary_stl)
    view_in_3d!(node)
    assert_rendered(MeshFixture::STL_DIMS)

    back_through_turbo_cache

    assert_no_selector ".model-viewer.model-viewer--ready"
    assert_no_selector ".model-viewer[data-modelviewer-state]"
    assert_no_selector ".model-viewer-stage canvas", visible: :all
    assert_equal "", find(".model-viewer-dims", visible: :all).text(:all)
    assert_selector ".mv-launch button", text: "View in 3D"

    click_on "View in 3D"

    assert_selector ".model-viewer[data-modelviewer-state='ready']"
    assert_selector ".model-viewer-stage canvas", count: 1, visible: :all
    assert_selector ".model-viewer-dims", text: MeshFixture::STL_DIMS
    assert_no_console_errors
  end

  # A SWITCH WHILE A MODEL IS IMPORTING SHOWS THE LATEST CHOICE. The STL's request is held, so its
  # import is provably running when the switcher moves to the PLY and then to the GLB. That is what
  # arrowing through a closed <select> does, and the controller's own comment has long claimed it
  # was handled. Under the engine's rule 1 (header above) it was not. Both switches were dropped,
  # the running import's progress element was thrown away, the import threw `Cannot set properties
  # of null` when its bytes arrived, and the engine ignored every later load until ✕ Image. The
  # page sat at `loading` for good.
  #
  # The fix makes a load wait for the engine's running import before asking for another. The STL
  # finishes, both superseded switches see they are stale, and only the GLB is loaded.
  #
  # RED BEFORE THE FIX, on the `ready` wait. The page never left `loading`, and the console held
  # "Uncaught TypeError: Cannot set properties of null (setting 'innerHTML')" from inside o3dv.js.
  # MUTATION (§15; run for real, output in the PR, then reverted): dropping load()'s
  # `await engine.importing?.catch(() => {})` reds it on the same wait.
  test "a switch while a model is importing shows the latest choice" do
    stl = write_model!(name: "body.stl", body: binary_stl)
    ply = write_model!(name: "shell.ply", body: MeshFixture::PLY)
    scene = write_model!(name: "scene.glb", body: glb)
    visit model_path(switcher_model!(stl, ply, scene))
    gate_xhr!("body.stl")

    click_on "View in 3D"
    wait_until_held("body.stl")
    switcher = find("select.model-viewer-source")
    switcher.select("shell.ply")
    switcher.select("scene.glb")
    release_xhr("body.stl")

    assert_selector ".model-viewer[data-modelviewer-state='ready']"
    assert_selector ".model-viewer-dims", text: MeshFixture::GLB_DIMS
    assert_selector ".model-viewer-stage canvas", count: 1, visible: :all
    assert_no_console_errors
  end

  # AN ENGINE RELEASED MID-IMPORT CANNOT FAIL THE MODEL LOADED AFTER IT. ✕ Image while a corrupt
  # file's request is held releases engine A, but A's import is still running (rule 2). Then the
  # page loads the PLY on a new engine B, and A's import fails while B's is still running. A's
  # callbacks used to route through controller fields that the next load reassigned
  # (`this.modelFailed`), so A's failure failed B. B's engine was torn down mid-import, the page
  # read `failed`, and B's own import then threw NotFoundError into the console when it finished
  # on the torn-down stage.
  #
  # A's failure is WAITED FOR rather than raced. Engine A is captured while it is live, and its
  # failure callback is wrapped to raise a flag, so the test knows the failure arrived before it
  # releases B. B is held until then, because a B that had already settled
  # would make a misrouted failure a no-op in some designs. That is also why both mutations below
  # go red.
  #
  # RED BEFORE THE FIX, on the `ready` wait: the page read `failed`. The console blamed the PLY
  # ("[modelviewer] ply: keeping thumbnail fallback: Error: the importer could not read this file")
  # and then held B's "Uncaught DOMException: Failed to execute 'removeChild' on 'Node'".
  # MUTATIONS (§15; run for real, output in the PR, then reverted): routing construct()'s failure
  # callback through the controller (`this.fail(this.generation, …)`, the shape the old per-load
  # field had) reds it on the `ready` wait. So does routing it through the CURRENT engine
  # (`this.engine?.settle?.reject(…)`).
  test "an engine released mid-import cannot fail the model loaded after it" do
    broken = write_model!(name: "broken.stl", body: "this is not an STL at all\n" * 4)
    ply = write_model!(name: "shell.ply", body: MeshFixture::PLY)
    visit model_path(switcher_model!(broken, ply))
    gate_xhr!("broken.stl", "shell.ply")

    click_on "View in 3D"
    wait_until_held("broken.stl")
    page.execute_script(<<~JS)
      const el = document.querySelector(".model-viewer")
      const first = window.Stimulus.getControllerForElementAndIdentifier(el, "modelviewer").viewer
      const failed = first.parameters.onModelLoadFailed
      first.parameters.onModelLoadFailed = () => { window.__firstFailed = true; failed() }
    JS
    click_on "✕ Image"
    assert_no_selector ".model-viewer.model-viewer--ready"

    find("select.model-viewer-source").select("shell.ply")
    click_on "View in 3D"
    wait_until_held("shell.ply")
    release_xhr("broken.stl")
    wait_until(message: "the released engine never reported the corrupt file's failure") do
      page.evaluate_script("window.__firstFailed === true")
    end
    release_xhr("shell.ply")

    assert_selector ".model-viewer[data-modelviewer-state='ready']"
    assert_selector ".model-viewer-dims", text: MeshFixture::PLY_DIMS
    assert_selector ".model-viewer-stage canvas", count: 1, visible: :all
    assert_no_console_errors
  end
end
