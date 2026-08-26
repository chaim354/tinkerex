import { Controller } from "@hotwired/stimulus"

// Polls the web thumbnails endpoint for cells whose thumbnail isn't ready yet, and swaps the
// spinner for the image when it lands. Stops when nothing is pending (or after a bounded number
// of tries), so a permanently-unsupported file doesn't poll forever.
export default class extends Controller {
  static values = { url: String }
  static targets = ["cell"]

  connect() {
    this.tries = 0
    this.poll()
  }

  disconnect() {
    clearTimeout(this.timer)
  }

  pendingIds() {
    return this.cellTargets
      .filter((c) => c.querySelector(".thumb-spinner"))
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
          if (entry.status === "ready" && entry.url) this.setImage(cell, entry.url)
          // A terminal non-ready state (no permissive renderer for this file here, or a render
          // error) resolves the spinner to a static icon — otherwise it would spin forever and
          // keep the cell in the poll set.
          else if (entry.status === "unsupported" || entry.status === "failed") this.setIcon(cell)
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

  // Every cell still holding a spinner becomes a static badge. Used when polling gives up.
  resolveStragglers() {
    for (const cell of this.cellTargets) {
      if (cell.querySelector(".thumb-spinner")) this.setIcon(cell)
    }
  }

  setIcon(cell) {
    const thumb = cell.querySelector(".thumb")
    if (!thumb || thumb.querySelector(".thumb-icon")) return
    const icon = document.createElement("span")
    icon.className = "thumb-icon"
    // Mirrors files/_thumb.html.erb's terminal branch — same title, same em-dash fallback for a
    // cover cell with no extension. The two must agree: one of them renders on load and the other
    // replaces a spinner, and a user seeing both would otherwise get two different answers to
    // "why is there no picture".
    icon.title = "Preview not supported"
    icon.textContent = cell.dataset.ext || "—"
    thumb.innerHTML = ""
    thumb.appendChild(icon)
  }
}
