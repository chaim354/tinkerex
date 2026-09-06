import { Controller } from "@hotwired/stimulus"

// Interactive 3D viewer for every format Online3DViewer's importers read — meshes (STL, 3MF, OBJ,
// glTF/GLB, PLY, OFF, DAE, WRL, 3DS, FBX, AMF), Rhino (3DM) and, through OpenCascade compiled to
// WebAssembly, the CAD formats (STEP, IGES, BREP, FCStd). The bytes are parsed CLIENT-SIDE — no
// server conversion — and rendered as a manipulable WebGL scene.
//
// THE ENGINE IS DYNAMIC-IMPORTED in boot(), so the ~1 MB bundle ships only on a page that actually
// holds a 3D file (Stimulus eager-imports controller MODULES at startup, so a top-level `import`
// would load it everywhere). Its `preload: false` pin is the other half — see config/importmap.rb
// and test/integration/web/lazy_bundles_test.rb.
//
// THE URL MUST END IN THE REAL FILENAME. Online3DViewer picks an importer from the URL'S OWN
// trailing extension (`GetFileExtension` in its io/fileutils.js), never from the bytes or a
// Content-Type — so both templates point this at `named_blob_file_path`, exactly as KiCanvas and
// the Gerber viewer do, and for exactly the same reason (§14d; kicanvas_test.rb's header has the
// long version).
//
// `lazy` defers the whole boot (and therefore the engine download AND the byte fetch) until the
// user clicks "View in 3D" (load()). A `source` <select> lets one viewer switch between several
// model files. Graceful degradation is the contract: any failure (no WebGL, import error,
// fetch/CORS failure, corrupt file, a missing wasm importer) restores the server-rendered
// thumbnail poster. `data-modelviewer-state` reports which of those happened —
// loading / ready / failed — and is what the system test drives.
export default class extends Controller {
  static values = {
    url: String, format: String, lazy: Boolean,
    // WHAT THE IMPORTER CANNOT KNOW, HANDED OVER BY THE SERVER (Maker::ThreeMfManifest): one
    // "#RRGGBB"-or-null per imported mesh from the slicer's own metadata, and the millimetre factor
    // for a 3MF's declared `unit`. Empty and 1 for every other format, which is a no-op on both.
    colors: Array, unitFactor: { type: Number, default: 1 }
  }
  static targets = ["canvas", "dims", "fallback", "source"]

  connect() {
    this.disposed = false
    this.generation = 0
    if (this.lazyValue) return // wait for load()
    this.load()
  }

  disconnect() {
    this.disposed = true
    this.teardown()
  }

  // Free the WebGL context and empty the stage, WITHOUT marking the controller disposed — so a
  // later load() (re-opening after showPoster) can start clean. Reused by disconnect() and
  // showPoster().
  //
  // A SOURCE SWITCH DOES NOT COME THROUGH HERE, deliberately: `LoadModelFromUrlList` clears the
  // viewer itself, so switching reuses the one EmbeddedViewer instead of building a second WebGL
  // context. That is not only cheaper — `EmbeddedViewer`'s constructor registers a `window`
  // resize listener it never removes, so one instance per file switch would accumulate listeners
  // pointing at destroyed viewers. One instance per open is bounded by the user's own clicking.
  teardown() {
    this.resizeObserver?.disconnect()
    this.viewer?.Destroy()
    this.viewer = null
    this.resizeObserver = null
    this.modelLoaded = this.modelFailed = null
    // Destroy() disposes the renderer but leaves its <canvas> (and any progress text) in the DOM.
    if (this.hasCanvasTarget) this.canvasTarget.replaceChildren()
    if (this.hasDimsTarget) this.dimsTarget.textContent = ""
  }

  // "View in 3D" (and the file-switch path): resolve the active source, then import the engine and
  // hand it the URL. On failure fall back to the poster.
  async load() {
    if (this.hasSourceTarget && this.sourceTarget.selectedOptions.length) {
      const opt = this.sourceTarget.selectedOptions[0]
      this.urlValue = opt.dataset.url
      this.formatValue = opt.dataset.format
      // The manifest belongs to the FILE, so it is carried per option and copied over here — a
      // switch that moved the url and left the colours behind would paint the new model with the
      // old one's palette, which the count check would usually but not always catch.
      this.colorsValue = JSON.parse(opt.dataset.colors || "[]")
      this.unitFactorValue = Number(opt.dataset.unitFactor || 1)
    }
    const gen = ++this.generation // invalidate any in-flight load (rapid switches / keyboard nav)

    // THE STAGE MUST BE VISIBLE AND SIZED BEFORE THE VIEWER IS CONSTRUCTED. `EmbeddedViewer` reads
    // `parentElement.clientWidth/clientHeight` in its constructor, and `.model-viewer-stage` is
    // `display: none` until `--ready` is added — so booting first yields a 0x0 canvas that never
    // recovers. `--ready` therefore means "the viewer is open", not "the model rendered"; the
    // state attribute is what carries success.
    this.element.classList.add("model-viewer--ready")
    this.state("loading")

    try {
      await this.boot(gen)
      if (this.disposed || gen !== this.generation) return
      // The callbacks are reassigned per load rather than closed over at construction, so a
      // completion that belongs to a SUPERSEDED load cannot report itself as the current one.
      this.modelLoaded = () => this.loaded(gen)
      this.modelFailed = () => this.fail(gen, new Error("the importer could not read this file"))
      this.viewer.LoadModelFromUrlList([this.urlValue])
    } catch (e) {
      this.fail(gen, e)
    }
  }

  async boot(gen) {
    if (this.viewer) return
    const OV = await import("online-3d-viewer")
    if (this.disposed || gen !== this.generation) return
    this.OV = OV

    this.viewer = new OV.EmbeddedViewer(this.canvasTarget, {
      // THE RENDERER IS NOT CREATED WITH `alpha: true` (checked in the engine's viewer.js), so a
      // transparent background paints BLACK rather than letting the stage show through. Reading
      // the stage's own computed colour instead keeps the viewer on the page's palette in both
      // themes without duplicating a hex value that a restyle would leave behind (§14m).
      backgroundColor: this.stageColor(OV),
      defaultColor: new OV.RGBColor(150, 160, 170), // used only where the file names no colour
      edgeSettings: new OV.EdgeSettings(false, new OV.RGBColor(0, 0, 0), 1),
      onModelLoaded: () => this.modelLoaded?.(),
      onModelLoadFailed: () => this.modelFailed?.()
    })

    this.resizeObserver = new ResizeObserver(() => this.viewer?.Resize())
    this.resizeObserver.observe(this.canvasTarget)
  }

  // `getComputedStyle` resolves the var(--raised) the stylesheet sets; `rgb(r g b)` and
  // `rgba(r, g, b, a)` are both matched. A colour we cannot parse (or a transparent one, which is
  // what a detached element reports) falls back to the light-theme surface rather than to black.
  stageColor(OV) {
    const parts = getComputedStyle(this.canvasTarget).backgroundColor.match(/\d+(\.\d+)?/g)
    if (parts && parts.length >= 3 && parts[3] !== "0") {
      return new OV.RGBAColor(+parts[0], +parts[1], +parts[2], 255)
    }
    return new OV.RGBAColor(247, 248, 250, 255)
  }

  loaded(gen) {
    if (this.disposed || gen !== this.generation || !this.viewer) return
    this.applyColors()
    this.showDims()
    this.state("ready")
    this.focusViewer()
  }

  // THE SLICER'S COLOURS, APPLIED BY IMPORT INDEX — Maker::ThreeMfManifest's header carries the
  // whole argument. Matched on `userData.originalMeshInstance.id.meshIndex`, the engine's own
  // numbering of the meshes it imported, never by name: a Bambu `<object>` has no `name` attribute
  // at all (the name lives in model_settings.config), so a name match would apply nothing.
  //
  // APPLIED ONLY WHEN THE LIST IS EXACTLY AS LONG AS THE MODEL. A mismatch means the server's walk
  // and the loader disagreed about how many meshes this file has, and painting the wrong part is
  // worse than leaving it grey — so a mismatch applies NOTHING and says so in the console.
  //
  // TWO MORE THINGS NOT TO SIMPLIFY AWAY. A mesh whose geometry carries its own vertex colours (a
  // CAD export's `m:colorgroup`, which the importer DOES read) is left alone — the file's own
  // colours beat a slicer's guess at them. And the material is CLONED first: the engine hands every
  // mesh built from one 3MF material the SAME material object, so setting `.color` on it in place
  // paints every part the last colour in the list. The clone keeps the array shape the engine used
  // (`meshThreeMaterials` is an array, one entry per material group).
  applyColors() {
    const colors = this.colorsValue || []
    const model = this.viewer?.GetModel()
    if (!model || colors.length === 0 || colors.length !== model.MeshCount()) {
      if (colors.length) {
        console.info(`[modelviewer] ${colors.length} colours for ${model?.MeshCount()} meshes; not applied`)
      }
      return
    }

    const three = this.viewer.GetViewer()
    // `scene.traverse` rather than the engine's own EnumerateMeshes: three's API, so nothing here
    // depends on which internal model object holds the meshes in this release. `isMesh` is what
    // keeps the edge LineSegments out.
    three.scene.traverse((mesh) => {
      if (!mesh.isMesh) return
      const index = mesh.userData.originalMeshInstance?.id?.meshIndex
      const hex = Number.isInteger(index) ? colors[index] : null
      if (!hex || mesh.geometry.attributes.color) return

      const source = mesh.material
      const painted = Array.isArray(source) ? source.map((m) => m.clone()) : source.clone()
      const each = Array.isArray(painted) ? painted : [painted]
      each.forEach((m) => {
        m.color.set(hex)
        m.vertexColors = false
        m.needsUpdate = true
      })
      mesh.material = painted
      // Non-null only while the engine is holding the original for a highlight; keeping the two in
      // step means ending a highlight restores OUR colour rather than the default grey.
      if (mesh.userData.threeMaterials) mesh.userData.threeMaterials = painted
    })
    three.Render()
  }

  fail(gen, error) {
    if (this.disposed || gen !== this.generation) return // superseded — leave newer state alone
    console.warn(`[modelviewer] ${this.formatValue}: keeping thumbnail fallback:`, error)
    this.teardown()
    this.element.classList.remove("model-viewer--ready")
    this.state("failed")
  }

  state(value) {
    this.element.dataset.modelviewerState = value
  }

  // Dropdown change: live-switch only while the viewer is already showing; otherwise the choice is
  // simply read the next time the user clicks "View in 3D".
  selectSource() {
    if (this.element.classList.contains("model-viewer--ready")) this.load()
  }

  // "✕ Image": drop the scene (frees the WebGL context) and reveal the poster.
  showPoster() {
    this.generation++ // cancel any in-flight load so it can't reopen the viewer after dismissal
    this.teardown()
    this.element.classList.remove("model-viewer--ready")
    this.element.removeAttribute("data-modelviewer-state")
    // The ✕ button that had focus is now hidden; return focus to the "View in 3D" launch button.
    this.element.querySelector(".mv-launch button")?.focus()
  }

  // After a successful load the "View in 3D" button that had focus is display:none; move focus to
  // a persistent, now-visible control so keyboard/AT users aren't dropped to <body>.
  focusViewer() {
    this.element.querySelector(".mv-actions button")?.focus()
  }

  // THE DIMENSIONS COME FROM THE *MODEL*, NEVER FROM THE VIEWER'S SCENE, and that distinction is
  // the thing in this file most likely to be "simplified" into a bug.
  //
  // The engine normalises everything it imports to a Y-UP SCENE: each importer declares its own
  // format's up direction (`GetUpDirection` — Z for STL, 3DS, 3DM, FCStd and SVG; Y for OBJ, PLY,
  // OFF, glTF, OpenCascade and the three.js-backed FBX/DAE/WRL/3MF/AMF) and `ThreeModelLoader`
  // rotates the three object by -90° about X wherever that direction is Z. So `Viewer#GetBoundingBox`
  // — the obvious call, and the one this used at first — reports a Z-up file's HEIGHT AS ITS DEPTH.
  // Measured, not reasoned: an STL whose vertices span 20 x 10 x 5 came back as "20 × 5 × 10 mm",
  // a number that disagrees with the user's own slicer.
  //
  // `OV.GetBoundingBox(model)` walks the imported MODEL's vertices instead, in the file's own axes,
  // and it walks MESH INSTANCES — so an assembly's node transformations are applied and a
  // multi-part STEP measures as it sits rather than as its parts were authored.
  //
  // THE NUMBERS ARE IN THE FILE'S OWN UNITS, AND A 3MF's ARE NOT NECESSARILY MILLIMETRES — this
  // paragraph used to claim "the formats that declare a unit (3MF, FCStd) already converted by
  // their importer", which is FALSE for 3MF and was measured to be false: three's 3MFLoader ignores
  // `<model unit>` entirely, so an Onshape export declaring `unit="meter"` and standing 1.9 m tall
  // read as "0 × 1 × 0.6 mm" — 1000x short, a number that disagrees with the user's own CAD. The
  // factor therefore comes from the SERVER (Maker::ThreeMfManifest reads the attribute the importer
  // dropped) and is 1 for every other format, including the ones that really do convert. Round to
  // 0.1 for a readable size.
  showDims() {
    if (!this.hasDimsTarget) return
    const model = this.viewer.GetModel()
    const box = model && this.OV.GetBoundingBox(model)
    if (!box) return
    const min = box.GetMin()
    const max = box.GetMax()
    const factor = this.unitFactorValue || 1
    const mm = (n) => (Math.round(n * factor * 10) / 10).toLocaleString()
    this.dimsTarget.textContent =
      `${mm(max.x - min.x)} × ${mm(max.y - min.y)} × ${mm(max.z - min.z)} mm`
  }

  // "Reset view": put the camera back exactly where `EmbeddedViewer` put it after the import — its
  // own Y-up default, then a fit to the model's bounding sphere.
  //
  // THERE IS NO PER-FORMAT UP-AXIS TABLE HERE, and adding one back is the mistake this comment
  // exists to prevent. The Three.js viewer this replaced carried one (`UP_AXIS`) because neither
  // STLLoader nor 3MFLoader rotated what it parsed, so a Z-up print file rendered lying on its
  // side. Online3DViewer does that job itself, per importer, at import time (see showDims above) —
  // so naming Direction.Z here would rotate an ALREADY-ROTATED model and lay every STL on its
  // side: the exact bug the old table existed to fix, reintroduced from the other end.
  reset() {
    if (!this.viewer) return
    const viewer = this.viewer.GetViewer()
    viewer.SetUpVector(this.OV.Direction.Y, false)
    const sphere = viewer.GetBoundingSphere(() => true)
    if (sphere) viewer.FitSphereToWindow(sphere, false)
  }

  fullscreen() {
    if (document.fullscreenElement) {
      document.exitFullscreen()
    } else {
      this.element.requestFullscreen?.()
    }
  }
}
