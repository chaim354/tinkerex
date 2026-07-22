import { Controller } from "@hotwired/stimulus"

// Right-click a file → a small menu (Add note / Open). "Add note" opens a popover with a textarea
// that POSTs to the file's notes endpoint (JSON), then reloads so the server-rendered badge is
// correct. Progressive enhancement: with no JS, right-click is the browser's own menu and notes
// stay fully usable from the file detail page.
export default class extends Controller {
  connect() {
    this.onDocClick = () => this.close()
    this.onKey = (e) => { if (e.key === "Escape") this.close() }
    document.addEventListener("click", this.onDocClick)
    document.addEventListener("keydown", this.onKey)
  }

  disconnect() {
    document.removeEventListener("click", this.onDocClick)
    document.removeEventListener("keydown", this.onKey)
    this.close()
  }

  // data-action="contextmenu->filemenu#open" on each file cell (which carries data-note-url).
  open(event) {
    const cell = event.currentTarget
    const noteUrl = cell.dataset.noteUrl
    if (!noteUrl) return
    event.preventDefault()
    this.close()

    const href = cell.getAttribute("href") || cell.querySelector("a")?.getAttribute("href")
    this.menu = document.createElement("div")
    this.menu.className = "file-menu"
    this.menu.style.left = `${event.pageX}px`
    this.menu.style.top = `${event.pageY}px`

    const add = document.createElement("button")
    add.type = "button"
    add.textContent = "Add note"
    add.addEventListener("click", (e) => { e.stopPropagation(); this.closeMenu(); this.openPopover(noteUrl, event.pageX, event.pageY) })
    this.menu.appendChild(add)

    if (href) {
      const open = document.createElement("a")
      open.href = href
      open.textContent = "Open"
      this.menu.appendChild(open)
    }
    document.body.appendChild(this.menu)
  }

  openPopover(noteUrl, x, y) {
    this.closePopover()
    const pop = document.createElement("div")
    pop.className = "note-popover"
    pop.style.left = `${x}px`
    pop.style.top = `${y}px`
    pop.addEventListener("click", (e) => e.stopPropagation())
    pop.innerHTML = `
      <textarea rows="3" placeholder="Add a note (markdown)…"></textarea>
      <div class="note-popover-actions">
        <button type="button" data-role="save" class="btn small">Save</button>
        <button type="button" data-role="cancel" class="linkbtn">Cancel</button>
        <span class="note-popover-status"></span>
      </div>`
    const ta = pop.querySelector("textarea")
    pop.querySelector('[data-role="cancel"]').addEventListener("click", () => this.closePopover())
    pop.querySelector('[data-role="save"]').addEventListener("click", () => this.save(noteUrl, ta.value, pop))
    document.body.appendChild(pop)
    this.popover = pop
    ta.focus()
  }

  async save(noteUrl, body, pop) {
    if (!body.trim()) return
    const status = pop.querySelector(".note-popover-status")
    status.textContent = "Saving…"
    try {
      const res = await fetch(noteUrl, {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          Accept: "application/json",
          "X-CSRF-Token": document.querySelector('meta[name="csrf-token"]')?.content || ""
        },
        body: JSON.stringify({ note: { body } })
      })
      const data = await res.json().catch(() => ({}))
      if (!res.ok) throw new Error(data.error || `failed (${res.status})`)
      window.location.reload()
    } catch (e) {
      status.textContent = e.message
    }
  }

  closeMenu() { this.menu?.remove(); this.menu = null }
  closePopover() { this.popover?.remove(); this.popover = null }
  close() { this.closeMenu(); this.closePopover() }
}
