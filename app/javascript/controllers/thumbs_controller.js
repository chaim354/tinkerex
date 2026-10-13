import { Controller } from "@hotwired/stimulus"

// Polls the web thumbnails endpoint for cells whose thumbnail isn't ready yet. Stops when nothing
// is pending (or after a bounded number of tries), so a permanently-unsupported file doesn't poll
// forever.
//
// TWO SURFACES, TWO ANSWERS TO "IT LANDED", AND THE MODE IS DECLARED BY THE PAGE. A grid cell holds
// a `.thumb-spinner` and gets the image swapped in where the spinner was. The FILE PAGE (stage 4,
// S4-3) has no thumb box at all — its poster is the page's own full-width preview, and the laser/CNC
// settings panel, Size and Modified all come from the same render — so it sets `reload` and declares
// its pending cell with `data-thumbs-pending`, and the whole page is fetched again once the answer
// arrives. Grids set neither and behave exactly as they did before that mode existed.
export default class extends Controller {
  static values = { url: String, reload: Boolean }
  static targets = ["cell"]

  connect() {
    this.tries = 0
    this.reloaded = false
    this.poll()
  }

  disconnect() {
    clearTimeout(this.timer)
  }

  // A CELL IS PENDING IF IT LOOKS IT OR SAYS IT. A grid cell announces itself by holding a
  // `.thumb-spinner`; the file page's cell has no thumb box at all (its poster is the page's own
  // full-width preview), so it declares `data-thumbs-pending` instead and the flag is cleared as
  // soon as an answer arrives — so a page never polls past the answer it was waiting for.
  pendingIds() {
    return this.cellTargets
      .filter((c) => c.querySelector(".thumb-spinner") || c.dataset.thumbsPending === "true")
      .map((c) => c.dataset.nodeId)
  }

  async poll() {
    const ids = this.pendingIds()
    if (ids.length === 0) return
    // GIVING UP RESOLVES THE SPINNERS, IT DOES NOT JUST STOP ASKING. This used to be part of the
    // condition above and simply returned, so any cell still spinning at try 41 spun for as long
    // as the page stayed open — the animation is CSS and does not care that polling ended. The
    // server now answers "unsupported" for a node with no row, so reaching this line means
    // something else went wrong (an endpoint erroring, a node appearing mid-session); a static
    // badge is the honest end state either way, and "forever" stops being reachable at all.
    if (this.tries > 40) return this.resolveStragglers()
    this.tries += 1

    try {
      const res = await fetch(`${this.urlValue}?ids=${encodeURIComponent(ids.join(","))}`, {
        headers: { Accept: "application/json" },
      })
      if (res.ok) {
        const data = await res.json()
        for (const cell of this.cellTargets) {
          const entry = data[cell.dataset.nodeId]
          if (!entry) continue
          if (entry.status === "ready" && entry.url) {
            const declared = cell.dataset.thumbsPending === "true"
            delete cell.dataset.thumbsPending
            this.setImage(cell, entry.url)
            // RELOAD MODE (stage 4, S4-3), for a surface whose poster is not a `.thumb` and whose
            // OTHER content — the laser/CNC settings panel, Size, Modified — came from the same
            // render. `setImage` above is a no-op there (no `.thumb` to fill), so the reload is
            // what makes the answer visible. Only for a cell that DECLARED itself pending, so a
            // grid never reloads: its cells are found by their spinner and behave exactly as
            // before this mode existed.
            if (declared && this.reloadValue) return this.reloadOnce()
          }
          // A terminal non-ready state (no permissive renderer for this file here, or a render
          // error) resolves the spinner to a static icon — otherwise it would spin forever and
          // keep the cell in the poll set. THE TWO ARE DIFFERENT ANSWERS AND THE TILE SAYS WHICH
          // (F onboarding): they resolved identically, so a render that broke read as a file type
          // with no preview. A failed one keeps its type icon and gains a mark and its own title.
          else if (entry.status === "unsupported" || entry.status === "failed") {
            delete cell.dataset.thumbsPending
            this.setIcon(cell, { failed: entry.status === "failed" })
          }
        }
      }
    } catch (_e) {
      /* transient; try again below */
    }

    this.timer = setTimeout(() => this.poll(), 2000)
  }

  setImage(cell, url) {
    const thumb = cell.querySelector(".thumb")
    if (!thumb || thumb.querySelector("img")) return
    const img = document.createElement("img")
    img.src = url
    img.loading = "lazy"
    img.alt = ""
    thumb.innerHTML = ""
    thumb.appendChild(img)
  }

  // ONCE PER CONNECT, WHICH IS WHAT BOUNDS THIS. The reloaded page renders the ready poster, so no
  // cell declares itself pending, so nothing polls and nothing reloads — the loop closes on the
  // server's own answer rather than on a counter. The guard is here anyway because a page that
  // reloaded itself repeatedly would be unusable and unrecoverable by the user.
  reloadOnce() {
    if (this.reloaded) return
    this.reloaded = true
    clearTimeout(this.timer)
    window.location.reload()
  }

  // Every cell still holding a spinner becomes a static badge. Used when polling gives up.
  resolveStragglers() {
    for (const cell of this.cellTargets) {
      if (cell.querySelector(".thumb-spinner")) this.setIcon(cell)
    }
  }

  setIcon(cell, { failed = false } = {}) {
    const thumb = cell.querySelector(".thumb")
    if (!thumb || thumb.querySelector(".thumb-icon")) return
    const icon = document.createElement("span")
    icon.className = "thumb-icon"
    // Mirrors files/_thumb.html.erb's terminal branch — same title, same em-dash fallback for a
    // cover cell with no extension. The two must agree: one of them renders on load and the other
    // replaces a spinner, and a user seeing both would otherwise get two different answers to
    // "why is there no picture".
    //
    // THE FAILED ARM HAS NO TWIN THERE YET. That partial renders a row that had ALREADY failed at
    // page load through its one terminal branch ("Preview not supported", no mark), so until it
    // grows a failed arm a failure only says so when it lands while the page is open.
    //
    // The mark is a class on the `.thumb` box, not on the cell: a cell can be a whole grid card or
    // table cell, and the mark belongs in the corner of the picture (components.css).
    icon.title = failed ? "Preview couldn't be rendered" : "Preview not supported"
    icon.textContent = cell.dataset.ext || "—"
    thumb.innerHTML = ""
    thumb.appendChild(icon)
    thumb.classList.toggle("thumb-failed", failed)
  }
}
