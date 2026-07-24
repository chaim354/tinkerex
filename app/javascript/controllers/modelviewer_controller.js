import { Controller } from "@hotwired/stimulus"

// Interactive 3D viewer for the mesh formats a print library is made of (STL / 3MF / OBJ).
// Parses the raw model bytes CLIENT-SIDE — no server conversion — and renders a manipulable
// WebGL scene. Three.js (~2MB unminified core) is pulled via a DYNAMIC import in boot() so it
// ships only on pages that actually contain a 3D file, not site-wide (Stimulus eager-imports
// controller MODULES at startup, so a top-level `import` would load Three everywhere).
//
// `lazy` defers the whole boot (and therefore the Three.js download + the byte fetch) until the
// user clicks "View in 3D" (load()). A `source` <select> lets one viewer switch between several
// model files. Graceful degradation is the contract: any failure (no WebGL, import error,
// fetch/CORS failure, corrupt file) leaves the server-rendered thumbnail poster visible. The
// `--ready` class, added only on a successful render, reveals the canvas and hides that poster.
export default class extends Controller {
  static values = { url: String, format: String, lazy: Boolean }
  static targets = ["canvas", "dims", "fallback", "source"]

  async connect() {
    this.disposed = false
    if (this.lazyValue) return // wait for load()
    try {
      await this.boot()
    } catch (e) {
      console.warn("[modelviewer] keeping thumbnail fallback:", e)
    }
  }

  disconnect() {
    this.disposed = true
    this.teardown()
  }

  // Free every GPU/DOM resource the current scene holds, WITHOUT marking the controller disposed —
  // so a later boot() (a file switch, or re-opening after showPoster) can start clean. Reused by
  // disconnect(), showPoster(), and the switch path in load().
  teardown() {
    if (this.frame) cancelAnimationFrame(this.frame)
    this.resizeObserver?.disconnect()
    this.controls?.dispose()
    this.scene?.traverse((o) => {
      o.geometry?.dispose?.()
      if (o.material) [].concat(o.material).forEach((m) => m.dispose?.())
    })
    if (this.renderer) {
      this.renderer.dispose()
      this.renderer.domElement?.remove()
    }
    this.frame = this.resizeObserver = this.controls = null
    this.scene = this.camera = this.renderer = this.home = null
  }

  // "View in 3D" (and the file-switch path): resolve the active source, tear down any current
  // scene, then boot. On failure fall back to the poster.
  async load() {
    if (this.hasSourceTarget && this.sourceTarget.selectedOptions.length) {
      const opt = this.sourceTarget.selectedOptions[0]
      this.urlValue = opt.dataset.url
      this.formatValue = opt.dataset.format
    }
    if (this.renderer) this.teardown() // switching files
    try {
      await this.boot()
    } catch (e) {
      console.warn("[modelviewer] keeping thumbnail fallback:", e)
      this.element.classList.remove("model-viewer--ready")
    }
  }

  // Dropdown change: live-switch only while the viewer is already showing; otherwise the choice is
  // simply read the next time the user clicks "View in 3D".
  selectSource() {
    if (this.element.classList.contains("model-viewer--ready")) this.load()
  }

  // "✕ Image": drop the scene (frees GPU memory, stops the render loop) and reveal the poster.
  showPoster() {
    this.teardown()
    this.element.classList.remove("model-viewer--ready")
  }

  async boot() {
    const THREE = await import("three")
    const { OrbitControls } = await import("three/addons/controls/OrbitControls.js")

    // Same-origin request; may 302 to a presigned cross-origin URL on s3/chunk-over-S3, which
    // needs bucket CORS — if it's not set the fetch rejects here and we fall back cleanly.
    const res = await fetch(this.urlValue, { credentials: "same-origin" })
    if (!res.ok) throw new Error(`fetch ${res.status}`)
    const buf = await res.arrayBuffer()

    const object = await this.parse(THREE, buf)

    const stage = this.canvasTarget
    const width = stage.clientWidth || 640
    const height = stage.clientHeight || 420

    this.scene = new THREE.Scene()
    this.scene.background = new THREE.Color(0xf7f8fa)

    // Center the model at the origin and read its size for the dimensions label + camera framing.
    const box = new THREE.Box3().setFromObject(object)
    const size = box.getSize(new THREE.Vector3())
    const center = box.getCenter(new THREE.Vector3())
    object.position.sub(center)
    this.scene.add(object)
    this.showDims(size)

    const maxDim = Math.max(size.x, size.y, size.z) || 1
    this.camera = new THREE.PerspectiveCamera(45, width / height, maxDim / 100, maxDim * 100)
    this.camera.position.set(maxDim * 1.4, maxDim * 1.0, maxDim * 1.6)

    this.renderer = new THREE.WebGLRenderer({ antialias: true })
    this.renderer.setPixelRatio(window.devicePixelRatio)
    this.renderer.setSize(width, height)
    stage.appendChild(this.renderer.domElement)

    this.scene.add(new THREE.HemisphereLight(0xffffff, 0x444444, 1.0))
    const key = new THREE.DirectionalLight(0xffffff, 1.4)
    key.position.set(1, 1, 1)
    this.scene.add(key)

    this.controls = new OrbitControls(this.camera, this.renderer.domElement)
    this.controls.enableDamping = true
    this.controls.target.set(0, 0, 0)
    this.controls.update()
    this.home = { pos: this.camera.position.clone(), target: this.controls.target.clone() }

    this.resizeObserver = new ResizeObserver(() => this.resize())
    this.resizeObserver.observe(stage)

    this.element.classList.add("model-viewer--ready")
    this.animate()
  }

  async parse(THREE, buf) {
    const surface = () =>
      new THREE.MeshStandardMaterial({ color: 0x8899aa, metalness: 0.1, roughness: 0.8 })

    switch (this.formatValue) {
      case "stl": {
        const { STLLoader } = await import("three/addons/loaders/STLLoader.js")
        const geometry = new STLLoader().parse(buf)
        geometry.computeVertexNormals()
        return new THREE.Mesh(geometry, surface())
      }
      case "3mf": {
        const { ThreeMFLoader } = await import("three/addons/loaders/3MFLoader.js")
        return new ThreeMFLoader().parse(buf) // respects embedded units/materials
      }
      case "obj": {
        const { OBJLoader } = await import("three/addons/loaders/OBJLoader.js")
        const group = new OBJLoader().parse(new TextDecoder().decode(buf))
        group.traverse((o) => { if (o.isMesh) o.material = surface() }) // no .mtl -> neutral surface
        return group
      }
      default:
        throw new Error(`unsupported format ${this.formatValue}`)
    }
  }

  // STL/OBJ are unitless -> mm by the 3D-print convention; 3MF carries its own unit (applied by
  // the loader). Round to 0.1 for a readable bounding-box size.
  showDims(size) {
    if (!this.hasDimsTarget) return
    const mm = (n) => (Math.round(n * 10) / 10).toLocaleString()
    this.dimsTarget.textContent = `${mm(size.x)} × ${mm(size.y)} × ${mm(size.z)} mm`
  }

  resize() {
    if (!this.renderer || this.disposed) return
    const stage = this.canvasTarget
    const width = stage.clientWidth || 640
    const height = stage.clientHeight || 420
    this.camera.aspect = width / height
    this.camera.updateProjectionMatrix()
    this.renderer.setSize(width, height)
  }

  animate() {
    if (this.disposed || !this.renderer) return
    this.frame = requestAnimationFrame(() => this.animate())
    this.controls.update()
    this.renderer.render(this.scene, this.camera)
  }

  reset() {
    if (!this.home) return
    this.camera.position.copy(this.home.pos)
    this.controls.target.copy(this.home.target)
    this.controls.update()
  }

  fullscreen() {
    if (document.fullscreenElement) {
      document.exitFullscreen()
    } else {
      this.element.requestFullscreen?.()
    }
  }
}
