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
//
// CONTENT BLOCKS EXTEND THE SAME IDEA AND ADD NO SECOND STORE (2026-09-09, content blocks; spec §2,
// §3). A block's heading, body, URL, line, picture and caption are data attributes on its slot,
// exactly as a panel's width and title are, so `draft()` is still one read over the slots and Save
// still posts one thing. Two consequences worth stating because they are easy to undo:
//
//   * `entry()` EMITS EVERY FIELD OF A BLOCK'S KIND, empty ones included. Maker::LayoutDocument
//     merges the posted entry into what the ROW holds, so an omitted attribute means "keep what is
//     stored" — which is right for a paste and wrong for a maker who has just emptied the heading
//     box. Stating the whole set is what makes clearing a field clear it. The empties cost nothing
//     downstream: `apply_block` deletes an empty string, so the YAML drawer never shows `line: ''`.
//   * `draft()` EMITS EVERY BLOCK SLOT. Save treats the draft as the whole truth of blocks (spec
//     decision 3) and DESTROYS a row no entry names, so a block skipped here is a block deleted.
//
// A NEW BLOCK'S MARKUP IS THE SERVER'S: "Add block" clones one of projects/_block_templates'
// `<template>`s rather than building a slot with `createElement`, so there is no second copy of the
// slot, the strip and the editor to drift from the ones a saved block renders.
const YAML_DEBOUNCE_MS = 200
const TOAST_MS = 6000
const NEW_KEY = /^block:new-(\d+)$/
const TEMPLATE_KEY = "block:new-__N__"

export default class extends Controller {
  static targets = ["grid", "slot", "form", "draft", "drawer", "yaml", "notes", "copy",
                    "addMenu", "blockTemplate", "page", "coverName", "preview", "linkCard"]
  static values = {
    yamlUrl: String, parseUrl: String, panelUrl: String, previewUrl: String,
    blockCap: { type: Number, default: 40 }
  }

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
    const d = { layout: 1, panels: this.slotTargets.map((slot) => this.entry(slot)) }
    // The page intro is rendered in edit mode only, and a draft with no `page` mapping leaves the
    // description and the cover exactly as they are (Maker::LayoutDocument#page_from answers nil).
    if (this.hasPageTarget) {
      d.page = { description: this.pageTarget.dataset.description || null, cover: this.pageTarget.dataset.cover || null }
    }
    return d
  }

  entry(slot) {
    const d = slot.dataset
    const e = { key: d.key, hidden: d.hidden === "true", width: d.width }
    if (d.kind) {
      e.kind = d.kind
      if (d.kind === "text") { e.heading = d.heading || ""; e.body = d.body || "" }
      if (d.kind === "link") { e.url = d.url || ""; e.title = d.linkTitle || ""; e.line = d.line || "" }
      if (d.kind === "image") { e.file = d.file || ""; e.caption = d.caption || "" }
      return e
    }
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

  // --- blocks ------------------------------------------------------------------------------------

  // ADD LANDS THE BLOCK FIRST, WITH ITS EDITOR OPEN (spec §2 and decision 5): first is where the
  // maker is looking, and dragging is how it gets anywhere else. The menu is closed by hand because
  // a <details> stays open on a click inside itself, and menu_controller only closes it on a click
  // OUTSIDE — which this one is not.
  addBlock(event) {
    const kind = event.currentTarget.dataset.kind
    // THE CAP IS NEVER THIS NUMBER'S ALONE TO KEEP: projects/_layout_bar renders these buttons
    // `disabled` at Maker::ProjectBlock::CAP, the document refuses a draft over it and Save refuses
    // again. This is the third lock, so a drift between the two spellings costs nothing.
    if (this.slotTargets.filter((s) => s.dataset.kind).length >= this.blockCapValue) {
      // SAID, NOT SWALLOWED (found in review): the bar's `disabled` reflects the SAVED count, so
      // blocks added within a session reach this lock with the buttons still live.
      this.addMenuTarget.removeAttribute("open")
      this.toast(`This page has ${this.blockCapValue} blocks, the most it can hold.`)
      return
    }

    // THE COUNTER TAKES THE HIGHEST KEY ON THE PAGE INTO ACCOUNT EVERY TIME, not only on the first
    // add: an Apply mints its own `block:new-N` keys from the server (Maker::LayoutDocument's
    // `next_new_index`), so a counter that only ever counted its own adds would hand the next one a
    // key already on the page — two slots with one key, which Save refuses as a repeat.
    this.newCounter = Math.max(this.newCounter || 0, this.highestNew()) + 1
    const slot = this.mintSlot(kind, `block:new-${this.newCounter}`)
    if (!slot) return

    this.gridTarget.prepend(slot)
    this.addMenuTarget.removeAttribute("open")
    slot.querySelector("input, textarea")?.focus()
    this.changed()
  }

  // One empty slot for this kind, cloned from the server's own template with the placeholder key
  // substituted. Returns null when no template is on the page (read mode has none).
  mintSlot(kind, key) {
    const tpl = this.blockTemplateTargets.find((t) => t.dataset.kind === kind)
    if (!tpl) return null

    const wrapper = document.createElement("div")
    wrapper.innerHTML = tpl.innerHTML.trim().replaceAll(TEMPLATE_KEY, key)
    return wrapper.firstElementChild
  }

  highestNew() {
    return Math.max(0, ...this.slotTargets.map((s) => Number((s.dataset.key.match(NEW_KEY) || [])[1] || 0)))
  }

  // A DRAFT EDIT, NOT A WRITE: Cancel (a reload) brings the block back and only Save makes it final.
  deleteBlock(event) {
    this.slotOf(event).remove()
    this.changed()
  }

  // Every input in a block's editor names its field; the slot's data attribute IS the draft.
  field(event) {
    const slot = this.slotOf(event)
    slot.dataset[event.currentTarget.dataset.field] = event.currentTarget.value
    if (slot.dataset.kind === "link") this.drawLinkCard(slot)
    this.changed()
  }

  // The card is pure arrangement of what was just typed, so it is drawn here rather than fetched —
  // unlike the Markdown preview, which must be the server's renderer or it lies (spec §2).
  drawLinkCard(slot) {
    const card = slot.querySelector("[data-layout-editor-target=linkCard]")
    if (!card) return

    const url = slot.dataset.url || ""
    card.href = /^https?:\/\//i.test(url) ? url : "#"
    card.querySelector(".block-link-title").textContent = slot.dataset.linkTitle || "Title"
    card.querySelector(".block-link-line").textContent = slot.dataset.line || ""
    let host = ""
    // `hostname`, not `host`: the saved card's host comes from Ruby's URI#host, which carries no port, and
    // the live card must say the same thing on `https://x.example:8080/a` (found in review).
    try { host = new URL(url).hostname } catch (_e) { host = "" }
    card.querySelector(".block-link-host").textContent = host
  }

  pickImage(event) {
    const slot = this.slotOf(event)
    slot.dataset.file = event.currentTarget.dataset.nodeId
    slot.querySelectorAll(".image-pick").forEach((b) => b.classList.toggle("active", b === event.currentTarget))
    // The "picture is not in the folder any more" line has just stopped being true.
    slot.querySelector(".block-missing")?.remove()
    this.changed()
  }

  // THE TEXT IS KEPT WHATEVER THE PREVIEW DOES, the same rule a failed panel preview follows: the
  // draft is the slot's `data-body`, the preview only shows it.
  async previewMarkdown(event) {
    const slot = this.slotOf(event)
    const box = slot.querySelector("[data-layout-editor-target=preview]")
    if (!box) return

    try {
      const res = await this.post(this.previewUrlValue, { markdown: slot.dataset.body || "" })
      box.innerHTML = await res.text()
      box.hidden = false
    } catch (e) {
      // A 422 IS THE BODY CAP, and Save will refuse that body too — say so rather than promise it
      // applies (found in review).
      this.toast(/422/.test(String(e?.message))
        ? "The text is over the 20 KB limit; Save will refuse it too."
        : "The preview did not render; the text is kept and applies on Save.")
    }
  }

  // --- the page intro ------------------------------------------------------------------------------

  // STRIPPED, NEVER COLLAPSED, and not even stripped here: the description's line breaks are
  // content (the page renders it as the column holds it), so the raw value goes to the draft and
  // Maker::LayoutDocument does the one strip.
  description(event) {
    this.pageTarget.dataset.description = event.currentTarget.value
    this.changed()
  }

  pickCover(event) {
    this.setCover(event.currentTarget.dataset.nodeId, event.currentTarget.title)
    this.changed()
  }

  removeCover() {
    this.setCover("", "No cover")
    this.changed()
  }

  setCover(nodeId, name) {
    this.pageTarget.dataset.cover = nodeId
    this.pageTarget.querySelectorAll(".cover-pick").forEach((b) => b.classList.toggle("active", b.dataset.nodeId === nodeId))
    if (this.hasCoverNameTarget) this.coverNameTarget.textContent = name
  }

  // --- the drawer --------------------------------------------------------------------------------

  toggleDrawer(event) {
    const open = this.drawerTarget.hidden
    this.drawerTarget.hidden = !open
    event.currentTarget.setAttribute("aria-expanded", String(open))
    this.element.classList.toggle("layout-editor--drawer", open)
    if (open) this.refreshYaml(true)
    else clearTimeout(this.yamlTimer)
  }

  // Copy follows what is ON SCREEN: hand-typed text updates the copy value too, so a paste with an
  // error that Apply refused still copies as typed (found in review).
  yamlTyped(event) {
    this.copyTarget.dataset.copyTextValue = event.currentTarget.value
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
      // The draft rides beside the text so the server merges into what is ON SCREEN, not the row.
      const res = await this.post(this.parseUrlValue, { yaml: this.yamlTarget.value, draft: this.draft() })
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
      let slot = byKey.get(e.key)
      // A BLOCK ENTRY WITH NO SLOT IS ONE THE PASTED TEXT CREATED: Maker::LayoutDocument mints
      // `block:new-N` for a `block:` entry whose `id:` names no row of this project, so Apply has to
      // be able to put a block on the page that was not there a moment ago — the same slot Add mints.
      if (!slot && e.kind) {
        slot = this.mintSlot(e.kind, e.key)
        if (slot) byKey.set(e.key, slot)
      }
      if (!slot) continue

      this.gridTarget.appendChild(slot)
      this.setHidden(slot, Boolean(e.hidden))
      this.setWidth(slot, e.width)
      if (e.kind) {
        this.adoptBlock(slot, e)
        continue
      }
      slot.dataset.title = e.title || ""
      slot.dataset.intro = e.intro || ""
      this.applyTitle(slot, slot.dataset.title)
      this.applyIntro(slot, slot.dataset.intro)
      if (e.view) await this.setView(slot, e.view)
    }
    if (this.hasPageTarget && draft.page) this.adoptPage(draft.page)
    this.refreshYaml(true)
  }

  // THE INPUTS ARE REFILLED FROM THE DRAFT, not the other way round: the slot's data attributes are
  // the state, and a box still showing what the maker typed before an Apply would be a second copy
  // of the block disagreeing with the one Save posts.
  adoptBlock(slot, e) {
    const d = slot.dataset
    d.heading = e.heading || ""
    d.body = e.body || ""
    d.url = e.url || ""
    d.linkTitle = e.title || ""
    d.line = e.line || ""
    d.file = e.file || ""
    d.caption = e.caption || ""
    slot.querySelectorAll("[data-field]").forEach((input) => { input.value = d[input.dataset.field] || "" })
    slot.querySelectorAll(".image-pick").forEach((b) => b.classList.toggle("active", b.dataset.nodeId === d.file))
    if (d.kind === "link") this.drawLinkCard(slot)
  }

  adoptPage(page) {
    const description = page.description || ""
    this.pageTarget.dataset.description = description
    const box = this.pageTarget.querySelector("textarea")
    if (box) box.value = description
    const cover = page.cover || ""
    const picked = cover ? this.pageTarget.querySelector(`.cover-pick[data-node-id="${cover}"]`) : null
    // A COVER FROM OUTSIDE THE FOLDER HAS NO BUTTON HERE AND NO NAME TO READ (spec §3): it keeps
    // working and the card keeps saying what it already said, rather than inventing a name.
    const current = this.hasCoverNameTarget ? this.coverNameTarget.textContent : ""
    this.setCover(cover, cover ? (picked ? picked.title : current) : "No cover")
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

  // WHAT SAVE REFUSES TO POST (found in review): an empty block makes the server refuse the whole
  // draft and reload the editor from the row, which throws away every OTHER unsaved change in the
  // session. The server's own rules, asked here first; the toast names the block, the slot is
  // scrolled into view, and nothing is lost. The body is byte-counted like the server, not in the
  // UTF-16 units `maxlength` counts.
  blockProblem(slot) {
    const d = slot.dataset
    switch (d.kind) {
      case "text":
        if (!d.heading && !d.body) return "a text block needs a heading or a body"
        if (new TextEncoder().encode(d.body || "").length > 20 * 1024) return "a text block's body is over 20 KB"
        return null
      case "link":
        if (!/^https?:\/\/\S+$/i.test(d.url || "")) return "a link needs an http or https URL"
        if (!d.linkTitle) return "a link needs a title"
        return null
      case "image":
        return d.file ? null : "an image block needs a picture from the project folder"
      default:
        return null
    }
  }

  save(event) {
    const problems = this.slotTargets.filter((s) => s.dataset.kind).map((s) => [s, this.blockProblem(s)]).filter(([, p]) => p)
    if (problems.length) {
      event.preventDefault()
      const [slot, problem] = problems[0]
      slot.scrollIntoView({ block: "center" })
      slot.querySelector("input, textarea")?.focus()
      this.toast(`Not saved: ${problem}. Fill it in or delete the block; nothing else was lost.`)
      return
    }
    this.draftTarget.value = JSON.stringify(this.draft())
  }

  // --- helpers -------------------------------------------------------------------------------------

  post(url, body) {
    return fetch(url, {
      method: "POST",
      credentials: "same-origin",
      headers: {
        "Content-Type": "application/json",
        // TEXT/HTML IS THE MARKDOWN PREVIEW'S ANSWER (Projects::LayoutsController#preview renders
        // `html:`); the other two doors answer JSON and plain text.
        Accept: "application/json, text/plain, text/html",
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
