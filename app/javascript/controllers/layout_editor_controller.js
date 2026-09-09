import { Controller } from "@hotwired/stimulus"
import Sortable from "sortablejs"

// THE PAGE EDITOR (2026-09-09; spec docs/superpowers/specs/2026-09-09-page-editor-design.md §5).
//
// THE DRAFT LIVES IN THE SLOTS. Every `.panel-slot` carries data-key/-hidden/-width/-view/-title/
// -intro (projects/_panel_slot.html.erb); this controller reads the draft off them and writes each
// change back to them, so there is no second copy of the layout to fall out of step, and the DOM
// order of the slots IS the draft's order. Save serialises the slots into the form's hidden field;
// the drawer's text is whatever the server rendered for that same serialisation.
//
// THE BROWSER NEVER PARSES OR EMITS YAML (spec decision 2): the drawer refreshes by posting the
// draft to `yamlUrl` and Apply posts the text to `parseUrl`; both answer from the one grammar,
// Maker::LayoutDocument. A view change fetches that panel's body from `panelUrl` so the preview is
// the real tiles, list or browser.
//
// SORTABLE RUNS IN FALLBACK MODE (`forceFallback: true`): native HTML5 drag events cannot be driven
// by Selenium, so the browser suite could not prove dragging at all with them, and the fallback is
// also what makes touch work the same on every platform. The pinned Publish slot is filtered out
// of dragging and refused as a drop target (spec decision 11).
const YAML_DEBOUNCE_MS = 200
const TOAST_MS = 6000

export default class extends Controller {
  static targets = ["grid", "slot", "form", "draft", "drawer", "yaml", "notes", "copy"]
  static values = { yamlUrl: String, parseUrl: String, panelUrl: String }

  connect() {
    this.sortable = Sortable.create(this.gridTarget, {
      handle: ".panel-strip-handle",
      draggable: ".panel-slot",
      filter: ".panel-slot--pinned",
      ghostClass: "panel-slot--ghost",
      forceFallback: true,
      fallbackTolerance: 3,
      animation: 120,
      onMove: (evt) => !evt.related.classList.contains("panel-slot--pinned"),
      onEnd: () => this.changed()
    })
  }

  disconnect() {
    this.sortable?.destroy()
    clearTimeout(this.yamlTimer)
  }

  // --- the draft, read off the slots ---------------------------------------------------------

  draft() {
    return { layout: 1, panels: this.slotTargets.map((slot) => this.entry(slot)) }
  }

  entry(slot) {
    const d = slot.dataset
    const e = { key: d.key, hidden: d.hidden === "true", width: d.width }
    if (d.view) e.view = d.view
    if (d.title) e.title = d.title
    if (d.intro) e.intro = d.intro
    return e
  }

  slotOf(event) {
    return event.currentTarget.closest(".panel-slot")
  }

  changed() {
    this.refreshYaml()
  }

  // --- order -----------------------------------------------------------------------------------

  up(event) { this.step(this.slotOf(event), -1) }
  down(event) { this.step(this.slotOf(event), 1) }

  step(slot, delta) {
    const movable = this.slotTargets.filter((s) => !s.classList.contains("panel-slot--pinned"))
    const i = movable.indexOf(slot)
    const j = i + delta
    if (i < 0 || j < 0 || j >= movable.length) return
    if (delta < 0) movable[j].before(slot)
    else movable[j].after(slot)
    slot.querySelector(delta < 0 ? "[data-action='layout-editor#up']" : "[data-action='layout-editor#down']")?.focus()
    this.changed()
  }

  // --- hidden ------------------------------------------------------------------------------------

  toggleHidden(event) {
    const slot = this.slotOf(event)
    this.setHidden(slot, slot.dataset.hidden !== "true")
    this.changed()
  }

  setHidden(slot, hidden) {
    slot.dataset.hidden = String(hidden)
    slot.classList.toggle("panel-slot--hidden", hidden)
    const eye = slot.querySelector("[data-layout-editor-target=eye]")
    if (eye) eye.textContent = hidden ? "Show" : "Hide"
  }

  // --- width -------------------------------------------------------------------------------------

  width(event) {
    this.setWidth(this.slotOf(event), event.currentTarget.dataset.width)
    this.changed()
  }

  setWidth(slot, width) {
    slot.dataset.width = width
    slot.classList.toggle("panel--full", width === "full")
    slot.classList.toggle("panel--half", width === "half")
    this.activate(slot, "[data-width]", (b) => b.dataset.width === width)
  }

  // --- view --------------------------------------------------------------------------------------

  async view(event) {
    await this.setView(this.slotOf(event), event.currentTarget.dataset.view)
    this.changed()
  }

  // THE DRAFT KEEPS THE CHOSEN VIEW WHATEVER THE PREVIEW DOES: a failed fetch leaves the old body
  // on screen and says so, and Save still writes the view the maker asked for (spec §6).
  async setView(slot, view) {
    if (slot.dataset.view === view) return
    slot.dataset.view = view
    this.activate(slot, "[data-view]", (b) => b.dataset.view === view)
    const url = new URL(this.panelUrlValue, window.location.origin)
    url.searchParams.set("panel", slot.dataset.key)
    url.searchParams.set("view", view)
    try {
      const res = await fetch(url, { credentials: "same-origin", headers: { Accept: "text/html" } })
      if (!res.ok) throw new Error(`HTTP ${res.status}`)
      slot.querySelector("[data-layout-editor-target=body]").innerHTML = await res.text()
      this.applyTitle(slot, slot.dataset.title || "")
      this.applyIntro(slot, slot.dataset.intro || "")
    } catch (_e) {
      this.toast("The preview for that view did not load. The view is kept and applies on Save.")
    }
  }

  // --- title and intro -------------------------------------------------------------------------

  title(event) {
    const slot = this.slotOf(event)
    slot.dataset.title = event.currentTarget.value.trim()
    this.applyTitle(slot, slot.dataset.title)
    this.changed()
  }

  intro(event) {
    const slot = this.slotOf(event)
    slot.dataset.intro = event.currentTarget.value.trim()
    this.applyIntro(slot, slot.dataset.intro)
    this.changed()
  }

  applyTitle(slot, title) {
    const input = slot.querySelector(".panel-strip-popover input[data-action='input->layout-editor#title']")
    if (input && input.value.trim() !== title) input.value = title
    const name = title || input?.placeholder || slot.dataset.key
    const label = slot.querySelector("[data-layout-editor-target=name]")
    if (label) label.textContent = name
    const h2 = slot.querySelector(".panel-slot-body .panel h2")
    if (h2) h2.textContent = name
  }

  applyIntro(slot, intro) {
    const input = slot.querySelector(".panel-strip-popover input[data-action='input->layout-editor#intro']")
    if (input && input.value.trim() !== intro) input.value = intro
    const body = slot.querySelector(".panel-slot-body")
    let p = body?.querySelector(".panel-intro")
    if (!p && intro && body) {
      p = document.createElement("p")
      p.className = "panel-intro muted"
      const head = body.querySelector(".panel-head") || body.querySelector(".panel h2")
      head?.after(p)
    }
    if (p) {
      p.textContent = intro
      p.hidden = !intro
    }
  }

  // --- the drawer --------------------------------------------------------------------------------

  toggleDrawer(event) {
    const open = this.drawerTarget.hidden
    this.drawerTarget.hidden = !open
    event.currentTarget.setAttribute("aria-expanded", String(open))
    this.element.classList.toggle("layout-editor--drawer", open)
    if (open) this.refreshYaml(true)
  }

  refreshYaml(now = false) {
    clearTimeout(this.yamlTimer)
    if (this.drawerTarget.hidden) return
    this.yamlTimer = setTimeout(() => this.fetchYaml(), now ? 0 : YAML_DEBOUNCE_MS)
  }

  async fetchYaml() {
    try {
      const res = await this.post(this.yamlUrlValue, { draft: this.draft() })
      const text = await res.text()
      this.yamlTarget.value = text
      this.copyTarget.dataset.copyTextValue = text
    } catch (_e) {
      this.note(["The YAML view could not be refreshed."], [])
    }
  }

  async apply() {
    let data
    try {
      const res = await this.post(this.parseUrlValue, { yaml: this.yamlTarget.value })
      data = await res.json()
    } catch (_e) {
      this.note(["Apply failed: the server did not answer."], [])
      return
    }
    this.note(data.errors, data.notes)
    if (data.errors.length) return
    await this.adopt(data.draft)
  }

  // Re-append the slots in the draft's order (a slot the draft does not name — none, the merge is
  // total — would stay where it is), then apply every attribute, fetching bodies for changed views.
  async adopt(draft) {
    const byKey = new Map(this.slotTargets.map((s) => [s.dataset.key, s]))
    for (const e of draft.panels) {
      const slot = byKey.get(e.key)
      if (!slot) continue
      this.gridTarget.appendChild(slot)
      this.setHidden(slot, Boolean(e.hidden))
      this.setWidth(slot, e.width)
      slot.dataset.title = e.title || ""
      slot.dataset.intro = e.intro || ""
      this.applyTitle(slot, slot.dataset.title)
      this.applyIntro(slot, slot.dataset.intro)
      if (e.view) await this.setView(slot, e.view)
    }
    this.refreshYaml(true)
  }

  note(errors, notes) {
    this.notesTarget.replaceChildren()
    const add = (text, cls) => {
      const p = document.createElement("p")
      p.className = cls
      p.textContent = text
      this.notesTarget.appendChild(p)
    }
    errors.forEach((e) => add(e, "layout-note layout-note--error"))
    notes.forEach((n) => add(n, "layout-note"))
    if (!errors.length && !notes.length) add("Valid.", "layout-note layout-note--ok")
  }

  // --- Save ----------------------------------------------------------------------------------------

  save(_event) {
    this.draftTarget.value = JSON.stringify(this.draft())
  }

  // --- helpers -------------------------------------------------------------------------------------

  post(url, body) {
    return fetch(url, {
      method: "POST",
      credentials: "same-origin",
      headers: {
        "Content-Type": "application/json",
        Accept: "application/json, text/plain",
        "X-CSRF-Token": document.querySelector("meta[name=csrf-token]")?.content ?? ""
      },
      body: JSON.stringify(body)
    }).then((res) => {
      if (!res.ok) throw new Error(`HTTP ${res.status}`)
      return res
    })
  }

  activate(slot, selector, chosen) {
    slot.querySelectorAll(`.panel-strip button${selector}`).forEach((b) => b.classList.toggle("active", chosen(b)))
  }

  // The flash stack is always in the layout (layouts/_flash.html.erb); a notice removes itself.
  toast(text) {
    const stack = document.querySelector(".flash-stack")
    if (!stack) return
    const item = document.createElement("div")
    item.className = "flash flash-notice"
    item.setAttribute("role", "status")
    const span = document.createElement("span")
    span.className = "flash-text"
    span.textContent = text
    item.appendChild(span)
    stack.appendChild(item)
    setTimeout(() => item.remove(), TOAST_MS)
  }
}
