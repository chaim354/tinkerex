import { Controller } from "@hotwired/stimulus"

// Collapsible sections + the table of contents that jumps to them, on the Box Generator index.
//
// The collapsing itself is <details>/<summary> in the markup, not this controller — the page folds
// and unfolds with JS off. This adds the three things markup can't do: remember what you left open
// across visits, open a collapsed section when its TOC entry is clicked (a bare #hash lands inside a
// closed <details>, which browsers do not reliably reveal), and mark which section you're looking at.
//
// Storage is best-effort: Safari private mode throws on localStorage, and a thrown error here would
// take the whole controller — and with it `jump` — down with it.
const STORE_KEY = "boxes:sections"

export default class extends Controller {
  static targets = ["section", "link", "toggleAll"]

  connect() {
    const open = this.#read()
    for (const section of this.sectionTargets) {
      if (section.id && section.id in open) section.open = open[section.id]
      section.querySelector(":scope > summary")?.addEventListener("click", this.#onSummaryClick)
      section.addEventListener("toggle", this.#onToggle)
    }
    this.#observe()
    this.#syncToggleAll()
  }

  disconnect() {
    for (const section of this.sectionTargets) {
      section.querySelector(":scope > summary")?.removeEventListener("click", this.#onSummaryClick)
      section.removeEventListener("toggle", this.#onToggle)
    }
    this.observer?.disconnect()
  }

  // A TOC entry: open the section, then scroll it under the sticky page top. Never let the browser
  // do the default #hash jump — the target may be inside a section that is still closed, and the
  // scroll would land on whatever happens to occupy that position instead.
  jump(event) {
    const section = this.#sectionFor(event.currentTarget)
    if (!section) return

    event.preventDefault()
    section.open = true
    this.#persist(section)
    section.scrollIntoView({ behavior: "smooth", block: "start" })
    this.#markActive(section.id)
    history.replaceState(null, "", `#${section.id}`)
  }

  toggleAll() {
    const sections = this.#tocSections()
    const collapsing = sections.some((s) => s.open)
    for (const section of sections) {
      section.open = !collapsing
      this.#persist(section)
    }
    this.#syncToggleAll()
  }

  // Persistence hangs off ACTIVATING A SUMMARY, not off the `toggle` event, and that is the whole
  // reason a search doesn't overwrite your layout: `boxfilter` opens matching sections by assigning
  // `.open`, which fires `toggle` and would be indistinguishable from a click. A summary click can
  // only come from the user (keyboard activation dispatches one too). `setTimeout` — not
  // `queueMicrotask` — because the flip is the click's DEFAULT ACTION, which has not happened yet
  // while listeners and microtasks run, so a microtask would read and store the OLD value.
  #onSummaryClick = (event) => {
    const section = event.currentTarget.parentElement
    setTimeout(() => this.#persist(section), 0)
  }

  // `toggle` only keeps the button's label honest — it must react to filter-driven opens as well.
  #onToggle = () => this.#syncToggleAll()

  // The sections collapse-all acts on. Where there's a table of contents it means the sections the
  // TOC lists — the index page's saved-box rail has its own two levels and is not what that button
  // is about. On the editor there is no TOC, and then it means every group on the form.
  #tocSections() {
    if (!this.hasLinkTarget) return this.sectionTargets
    return this.linkTargets.map((l) => this.#sectionFor(l)).filter(Boolean)
  }

  #sectionFor(link) {
    const id = (link.getAttribute("href") || "").replace(/^#/, "")
    return id ? this.sectionTargets.find((s) => s.id === id) : null
  }

  #syncToggleAll() {
    if (!this.hasToggleAllTarget) return
    this.toggleAllTarget.textContent = this.#tocSections().some((s) => s.open) ? "Collapse all" : "Expand all"
  }

  // Scroll-spy: the topmost section still intersecting the viewport is the one you're reading.
  #observe() {
    if (!this.hasLinkTarget || typeof IntersectionObserver === "undefined") return

    this.visible = new Set()
    this.observer = new IntersectionObserver(
      (entries) => {
        for (const e of entries) e.isIntersecting ? this.visible.add(e.target) : this.visible.delete(e.target)
        const top = [...this.visible].sort((a, b) => a.offsetTop - b.offsetTop)[0]
        if (top) this.#markActive(top.id)
      },
      { rootMargin: "-10% 0px -70% 0px" }
    )
    for (const section of this.#tocSections()) this.observer.observe(section)
  }

  #markActive(id) {
    for (const link of this.linkTargets) {
      link.closest("li")?.classList.toggle("is-active", link.getAttribute("href") === `#${id}`)
    }
  }

  #persist(section) {
    if (!section.id) return
    const open = this.#read()
    open[section.id] = section.open
    try {
      localStorage.setItem(STORE_KEY, JSON.stringify(open))
    } catch (_e) {
      /* storage unavailable or full — the sections still work, they just won't be remembered */
    }
  }

  #read() {
    try {
      return JSON.parse(localStorage.getItem(STORE_KEY)) || {}
    } catch (_e) {
      return {}
    }
  }
}
