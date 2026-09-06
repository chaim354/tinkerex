import { Controller } from "@hotwired/stimulus"

// KiCad schematics and boards, rendered in the browser (stage 3, S3-2). The KiCanvas module is
// ONE vendored build (bin/build-kicanvas, importmap pin "kicanvas") and it is imported LAZILY here,
// on connect, so a page without a KiCad file never downloads it. The embed fetches `urlValue`
// itself — a `named_blob_file_path`, NOT the plain blob URL the 3D viewer's loaders use: KiCanvas
// decides what it just fetched from the URL's OWN trailing extension, so it has to be the one
// carrying `.kicad_sch`/`.kicad_pcb` (see files/show.html.erb's comment on that route; measured
// against the vendored module, not guessed). On s3 that fetch follows a presigned redirect to the
// bucket — cross-origin, so it reads only under the bucket's CORS rule (docs/DEPLOY.md) and a
// connect-src the port names for the CSP (FileLayer#presigned_origin), exactly as the 3D
// viewer's fetch does.
export default class extends Controller {
  static values = { url: String, controls: { type: String, default: "basic" } }
  static targets = ["stage", "status"]

  async connect() {
    try {
      await import("kicanvas")
      const embed = document.createElement("kicanvas-embed")
      embed.setAttribute("src", this.urlValue)
      embed.setAttribute("controls", this.controlsValue)
      this.stageTarget.replaceChildren(embed)
      // The status line is a SIBLING of the stage, not inside it — replaceChildren above only
      // touches the stage, so without this "Loading the viewer…" would sit above a working embed
      // forever.
      if (this.hasStatusTarget) this.statusTarget.remove()
      this.element.dataset.kicanvasState = "ready"
    } catch (e) {
      this.element.dataset.kicanvasState = "failed"
      if (this.hasStatusTarget) this.statusTarget.textContent = "The viewer could not load."
    }
  }
}
