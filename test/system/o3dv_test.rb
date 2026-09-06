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
end
