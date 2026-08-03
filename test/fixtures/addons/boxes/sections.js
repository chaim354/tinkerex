// Collapsible <details> sections + the table of contents that jumps to them. Ported from the
// tinkerex repo's boxsections_controller.js (a Stimulus controller) to a plain mount/destroy
// function — this bundle has no Stimulus dependency (it is not a Stimulus controller itself, and
// must not assume the host has one either; see boxes.js).
//
// The collapsing itself is <details>/<summary> — this only adds three things markup can't do:
// remember what was left open across visits (localStorage), open a collapsed section when its TOC
// entry is clicked (a bare #hash lands inside a closed <details>, which browsers do not reliably
// reveal), and mark which section is currently in view.
//
// Called once per "page" this bundle renders (the gallery and the editor each mount their own
// instance over their own root) — mirrors the original having one Stimulus controller instance per
// data-controller="boxsections" element. Both instances share the SAME localStorage key, exactly as
// the original module-level STORE_KEY did, because section ids are unique across the whole addon
// (box-section-*, saved-section-*, saved-type-*, param-group-*) — one bucket, no collisions.
//
// Storage is best-effort: Safari private mode throws on localStorage, and a thrown error here must
// not take the rest of the behaviour down with it.
const STORE_KEY = "boxes:sections"

const read = () => {
  try {
    return JSON.parse(localStorage.getItem(STORE_KEY)) || {}
  } catch (_e) {
    return {}
  }
}

const write = (open) => {
  try {
    localStorage.setItem(STORE_KEY, JSON.stringify(open))
  } catch (_e) {
    /* storage unavailable or full — sections still work, they just won't be remembered */
  }
}

const persist = (section) => {
  if (!section.id) return
  const open = read()
  open[section.id] = section.open
  write(open)
}

// root: the element containing every section this instance manages.
//   [data-boxsections="section"]    — one per <details> to persist/restore
//   [data-boxsections="link"]       — TOC anchors with href="#<section id>" (optional)
//   [data-boxsections="toggle-all"] — a button that folds/unfolds every TOC'd section (optional)
export function mountSections(root) {
  const sections = [ ...root.querySelectorAll('[data-boxsections="section"]') ]
  const links = [ ...root.querySelectorAll('[data-boxsections="link"]') ]
  const toggleAllBtn = root.querySelector('[data-boxsections="toggle-all"]')

  const sectionFor = (link) => {
    const id = (link.getAttribute("href") || "").replace(/^#/, "")
    return id ? sections.find((s) => s.id === id) : null
  }

  // The sections collapse-all acts on. Where there IS a table of contents, that means the sections
  // the TOC lists — a saved-box rail with its own nested sections is not what "collapse all" is
  // about there. Where there is no TOC (the editor), it means every managed section.
  const tocSections = () => (links.length ? links.map(sectionFor).filter(Boolean) : sections)

  const syncToggleAll = () => {
    if (!toggleAllBtn) return
    toggleAllBtn.textContent = tocSections().some((s) => s.open) ? "Collapse all" : "Expand all"
  }

  const markActive = (id) => {
    for (const link of links) {
      link.closest("li")?.classList.toggle("is-active", link.getAttribute("href") === `#${id}`)
    }
  }

  // Persistence hangs off ACTIVATING A SUMMARY, not the `toggle` event — that is the whole reason a
  // search doesn't overwrite a saved layout: filter.js opens matching sections by assigning
  // `.open`, which fires `toggle` too, and would be indistinguishable from a click. `setTimeout` —
  // not a microtask — because the flip is the click's DEFAULT ACTION, which has not happened yet
  // while listeners run; a microtask would read and store the OLD value.
  const onSummaryClick = (event) => {
    const section = event.currentTarget.parentElement
    setTimeout(() => persist(section), 0)
  }
  const onToggle = () => syncToggleAll()

  const open = read()
  for (const section of sections) {
    if (section.id && section.id in open) section.open = open[section.id]
    section.querySelector(":scope > summary")?.addEventListener("click", onSummaryClick)
    section.addEventListener("toggle", onToggle)
  }

  const jump = (event) => {
    const section = sectionFor(event.currentTarget)
    if (!section) return

    event.preventDefault()
    section.open = true
    persist(section)
    section.scrollIntoView({ behavior: "smooth", block: "start" })
    markActive(section.id)
    history.replaceState(null, "", `#${section.id}`)
  }
  for (const link of links) link.addEventListener("click", jump)

  const toggleAll = () => {
    const targets = tocSections()
    const collapsing = targets.some((s) => s.open)
    for (const section of targets) {
      section.open = !collapsing
      persist(section)
    }
    syncToggleAll()
  }
  toggleAllBtn?.addEventListener("click", toggleAll)

  // Scroll-spy: the topmost section still intersecting the viewport is the one you're reading.
  let observer = null
  if (links.length && typeof IntersectionObserver !== "undefined") {
    const visible = new Set()
    observer = new IntersectionObserver(
      (entries) => {
        for (const e of entries) e.isIntersecting ? visible.add(e.target) : visible.delete(e.target)
        const top = [ ...visible ].sort((a, b) => a.offsetTop - b.offsetTop)[0]
        if (top) markActive(top.id)
      },
      { rootMargin: "-10% 0px -70% 0px" }
    )
    for (const section of tocSections()) observer.observe(section)
  }

  syncToggleAll()

  return {
    destroy() {
      for (const section of sections) {
        section.querySelector(":scope > summary")?.removeEventListener("click", onSummaryClick)
        section.removeEventListener("toggle", onToggle)
      }
      for (const link of links) link.removeEventListener("click", jump)
      toggleAllBtn?.removeEventListener("click", toggleAll)
      observer?.disconnect()
    },
  }
}
