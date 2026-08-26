import { mountSections } from "./sections.js"
import { mountFilter } from "./filter.js"
import { sectionId } from "./util.js"
// See boxes.js's import for why this is a static import of the host pin and never a vendored copy.
// `host` is a LIVE BINDING — read through it at call time, never captured at module top level.
import { host } from "@maker/addon-sdk"

// The Box Generator's index page: a filterable, sectioned gallery of generators plus a saved-box
// rail. Ported from the tinkerex repo's app/views/tools/boxes/index.html.erb + its boxfilter/
// boxsections Stimulus controllers, onto plain DOM building + filter.js/sections.js.
//
// root: the element to render into (emptied first). generators/states: already-fetched arrays (see
// boxes.js). onOpenGenerator(key, prefillValues|null): open the editor on a fresh generator.
// onEditState(state): open the editor prefilled AND EDITING that box. onShowState(state): open its
// read-only detail view.
//
// THE TWO SAVED-BOX CALLBACKS ARE NAMED FOR WHICH ACT THEY ARE, not for which view they open. They
// were one `onOpenState` while there was only one thing a saved box could do; a left click now
// means "edit this box" and the detail view has moved to the right-click menu, and a single name
// covering both would leave every call site ambiguous about which one it wanted.
//
// NO `ctx`: the sample-photo <img> below was the only thing in this module that ever read one, and
// it now builds its URL through the SDK. Kept out rather than left in place for a future caller —
// an unread parameter reads as "something here still needs the mount context".
export function mountGallery(root, { generators, states, onOpenGenerator, onEditState, onShowState }) {
  const sections = groupByField(generators, (g) => g.group || "Other")
  const savedTree = buildSavedTree(states, generators)

  root.innerHTML = `
    <div class="box-index">
      <nav class="box-toc" aria-label="Generator sections">
        <div class="box-toc-head">
          <span class="box-toc-title">Sections</span>
          <button type="button" class="box-toc-all" data-boxsections="toggle-all">Collapse all</button>
        </div>
        <ul class="box-toc-list" data-role="toc-list"></ul>
      </nav>

      <section class="box-generators">
        <h2>New box</h2>
        <input type="search" class="box-search" placeholder="Filter generators…"
               aria-label="Filter generators" data-boxfilter="query">
        <div data-role="groups"></div>
        <p class="box-noresults muted" data-boxfilter="empty" hidden>No generators match your filter.</p>
      </section>

      <aside class="box-saved-rail">
        <h2>Saved boxes</h2>
        <div data-role="saved"></div>
      </aside>
    </div>`

  const $ = (role) => root.querySelector(`[data-role="${role}"]`)

  for (const [ section, gens ] of sections) {
    const id = sectionId(section)
    const li = document.createElement("li")
    li.dataset.boxfilter = "tocitem"
    li.dataset.section = id
    const a = document.createElement("a")
    a.href = `#${id}`
    a.dataset.boxsections = "link"
    a.append(section)
    const count = document.createElement("span")
    count.className = "box-toc-count"
    count.textContent = String(gens.length)
    a.appendChild(count)
    li.appendChild(a)
    $("toc-list").appendChild(li)
  }

  for (const [ section, gens ] of sections) {
    const details = document.createElement("details")
    details.className = "box-group"
    details.id = sectionId(section)
    details.open = true
    details.dataset.boxfilter = "group"
    details.dataset.boxsections = "section"

    const summary = document.createElement("summary")
    summary.className = "box-group-summary"
    const title = document.createElement("span")
    title.className = "box-group-title"
    title.textContent = section
    const count = document.createElement("span")
    count.className = "box-group-count"
    count.textContent = String(gens.length)
    summary.append(title, count)
    details.appendChild(summary)

    const grid = document.createElement("div")
    grid.className = "tools-grid"
    for (const g of gens) grid.appendChild(buildCard(g, onOpenGenerator))
    details.appendChild(grid)

    $("groups").appendChild(details)
  }

  // OWNED HERE, NOT AT MODULE SCOPE. The menu is appended to document.body — outside `root` — so
  // nothing about swapping this page out would remove it; the destroy callback below is what does,
  // and a module-level singleton would outlive every mount that created it.
  const savedMenu = createSavedMenu({ onEditState, onShowState })
  renderSavedRail($("saved"), savedTree, onEditState, savedMenu.open)

  // Registered once per mount and removed on destroy, exactly as the host's own filemenu controller
  // does it in connect()/disconnect() — closing is a no-op when no menu is open, so there is nothing
  // to arm or disarm as menus come and go. DELIBERATELY THE SAME SHAPE AS THE HOST'S, rather than a
  // listener armed on a later tick: if some gesture both opens a menu and dispatches a plain click,
  // the menu would close instantly — and the host's own file cells would do it too, in one place, so
  // this must not diverge into having its own half-fix.
  const onDocClick = () => savedMenu.close()
  const onDocKey = (e) => { if (e.key === "Escape") savedMenu.close() }
  document.addEventListener("click", onDocClick)
  document.addEventListener("keydown", onDocKey)

  const filterCtl = mountFilter(root)
  const sectionsCtl = mountSections(root)

  return () => {
    filterCtl.destroy()
    sectionsCtl.destroy()
    document.removeEventListener("click", onDocClick)
    document.removeEventListener("keydown", onDocKey)
    savedMenu.close()
  }
}

// A small right-click menu on a saved box: the acts a left click no longer performs. Built the way
// the host's own filemenu controller builds one — a positioned div of plain buttons — rather than as
// a component, because this bundle has no framework and a host Stimulus controller does not
// auto-attach to markup a bundle injects (README).
//
// `.file-menu` IS THE HOST'S OWN CLASS AND THAT IS THE POINT: it carries `position: absolute` and
// the z-index. This repo ships no CSS at all (see history.js's header for why), so an invented class
// name would render an unpositioned stack of buttons in the middle of the page.
//
// Returns {open, close}; the caller owns the document-level listeners and closes it on destroy.
function createSavedMenu({ onEditState, onShowState }) {
  let el = null
  const close = () => { el?.remove(); el = null }

  const open = (event, state) => {
    close()
    el = document.createElement("div")
    el.className = "file-menu"
    el.style.left = `${event.pageX}px`
    el.style.top = `${event.pageY}px`

    const entry = (label, fn) => {
      const b = document.createElement("button")
      b.type = "button"
      b.textContent = label
      // CLOSED BEFORE `fn` RUNS, not left to the document listener: both of these swap the whole
      // page out, and the menu lives on document.body where that swap would not reach it.
      // `stopPropagation` then keeps the document listener from repeating a close that has happened.
      b.addEventListener("click", (e) => { e.stopPropagation(); close(); fn() })
      el.appendChild(b)
    }

    // NAMED FOR THE ACT, like the two callbacks themselves. "Open prefilled" described what a left
    // click used to do on its way somewhere else; this menu's whole job is to keep editing this box
    // apart from the two things that are not that.
    entry("Edit this box", () => onEditState(state))
    entry("Details", () => onShowState(state))

    // THE FIRST OUTPUT FILE — a cut sheet for every box this bundle saves, since the states endpoint
    // orders `files` by save position and the sheet is written before the plan. NOT NECESSARILY THE
    // CURRENT ONE: a revision saved under a NEW name leaves the previous file's row in place, and
    // Maker::AddonState's ordering breaks the position tie by id, oldest first — so after a rename
    // this can be the drawing from an earlier name. Still that box's drawing, which is what this
    // entry offers; the whole list is one click further on, under Details.
    //
    // `host.files.url` rather than a hand-built "/files/<id>": the SDK gained that builder precisely
    // so a bundle would stop encoding the host's route shape (see show.js's header, which recorded
    // the hardcoded version as tolerated only while there was no host surface for it).
    const first = state.files?.[0]
    if (first) {
      const link = document.createElement("a")
      link.href = host.files.url(first.node_id)
      link.textContent = "Open the file"
      // NOT closed from here. Removing an anchor from the document during its own click is the kind
      // of thing browsers disagree about, and navigating is this entry's entire job; the page it
      // loads takes the menu with it. `stopPropagation` keeps the document listener from doing the
      // removing either. A cmd-click that opens a new tab leaves the menu up for the next click.
      link.addEventListener("click", (e) => e.stopPropagation())
      el.appendChild(link)
    }

    document.body.appendChild(el)
  }

  return { open, close }
}

// The frame a generator with no sample photo gets. It carries `.addon-thumb` as well as its own
// class so the box is measured by the SAME rule as a real photo — one declaration of the size, so
// the two cannot drift apart and reintroduce the jump.
function emptyThumb() {
  const box = document.createElement("span")
  box.className = "addon-thumb addon-thumb-empty"
  box.textContent = "no sample photo"
  return box
}

function buildCard(generator, onOpenGenerator) {
  const card = document.createElement("a")
  card.href = "#"
  card.className = "addon-card"
  card.dataset.boxfilter = "card"
  card.dataset.terms = `${generator.title} ${generator.key} ${generator.group || ""}`.toLowerCase()
  card.addEventListener("click", (e) => {
    e.preventDefault()
    onOpenGenerator(generator.key, null)
  })

  const img = document.createElement("img")
  img.className = "addon-thumb"
  img.alt = ""
  img.loading = "lazy"
  // `service.url` IS A BUILDER, NOT A REQUEST — which is the one thing `service.get` structurally
  // cannot be: it PERFORMS the call and resolves a Response, and a Response cannot feed an attribute
  // the BROWSER must fetch itself. That is why this line was a hand-built `ctx.serviceUrl` string
  // until tinkerex PR #169 added the builder; it is not free-hand any more, and the encoding guards
  // (a rejected ".", ".." or empty segment, per-segment escaping) now apply here exactly as they do
  // to get/post, on the one URL no server guard ever gets to inspect. The host's proxy keeps
  // `image/jpeg` INLINE on its content-type allowlist for precisely this call site (tinkerex
  // CLAUDE.md §14c), so an <img> pointed at it is a supported path rather than a loophole.
  img.src = host.service.url("boxes", `sample/${generator.key}`)
  // Replaces the host's thumbfallback Stimulus controller for this addon: this bundle isn't
  // Stimulus, so a 404 is handled by hand rather than by a host controller auto-connecting to
  // markup this bundle injects.
  //
  // A MISSING SAMPLE KEEPS ITS FRAME — only the CONTENTS change. This used to add `is-missing`,
  // whose host CSS is `display: none`, which removed a 120px box AFTER the gallery looked settled:
  // every card below it jumped ~126px, so a click aimed at a card landed in dead space. That is not
  // theoretical — tinkerex's system suite carries a `settle_addon_cards` helper written for exactly
  // this race, its CI went red on it once (run 31188332739), and it still costs real mis-clicks.
  //
  // It is also rarer than the old comment here claimed ("most generators have none"): measured
  // against the deployed sidecar, **171 of the 181 offered generators ship a sample photo and 10 do
  // not**, so reserving the box costs ten cards a placeholder and buys a gallery that never
  // reflows.
  //
  // SWAPPING IN A REAL ELEMENT, not styling the failed <img>: a broken image paints a
  // browser-chosen glyph beside its alt text, and how much of that survives `background`/`color`
  // overrides differs per browser. An element we build renders the same everywhere.
  img.addEventListener("error", () => img.replaceWith(emptyThumb()))

  const label = document.createElement("span")
  label.className = "addon-title"
  label.textContent = generator.key

  card.append(img, label)
  return card
}

function renderSavedRail(container, savedTree, onEditState, openMenu) {
  const total = savedTree.reduce((n, [ , types ]) => n + types.reduce((m, [ , items ]) => m + items.length, 0), 0)
  if (total === 0) {
    container.innerHTML = `<p class="muted">No saved boxes yet.</p>`
    return
  }

  const count = document.createElement("p")
  count.className = "box-saved-count muted"
  count.textContent = `${total} saved box${total === 1 ? "" : "es"}`
  container.appendChild(count)

  for (const [ section, types ] of savedTree) {
    const sectionCount = types.reduce((m, [ , items ]) => m + items.length, 0)
    const sectionDetails = document.createElement("details")
    sectionDetails.className = "box-saved-section"
    sectionDetails.id = sectionId(section, "saved-section")
    sectionDetails.dataset.boxsections = "section"
    sectionDetails.appendChild(savedSummary(section, sectionCount))

    for (const [ type, items ] of types) {
      const typeDetails = document.createElement("details")
      typeDetails.className = "box-saved-type"
      typeDetails.id = sectionId(`${section}-${type}`, "saved-type")
      typeDetails.dataset.boxsections = "section"
      typeDetails.appendChild(savedSummary(type, items.length))

      const ul = document.createElement("ul")
      ul.className = "saved-boxes"
      for (const state of items) {
        const li = document.createElement("li")
        const a = document.createElement("a")
        a.href = "#"
        a.className = "box-saved-link"
        a.textContent = state.name
        // A LEFT CLICK OPENS THE FORM, EDITING THIS BOX — it used to open the read-only detail view,
        // whose "Duplicate & tweak" button was a second click on the way to the same form and forked
        // the design when it got there. Everything rarer moved to the right-click menu, mirroring the
        // host's own file cells.
        a.addEventListener("click", (e) => { e.preventDefault(); onEditState(state) })
        a.addEventListener("contextmenu", (e) => { e.preventDefault(); openMenu(e, state) })
        const date = document.createElement("div")
        date.className = "muted"
        date.textContent = String(state.updated_at).slice(0, 10)
        li.append(a, date)
        ul.appendChild(li)
      }
      typeDetails.appendChild(ul)
      sectionDetails.appendChild(typeDetails)
    }
    container.appendChild(sectionDetails)
  }
}

function savedSummary(name, count) {
  const summary = document.createElement("summary")
  summary.className = "box-saved-summary"
  const label = document.createElement("span")
  label.className = "box-saved-name"
  label.textContent = name
  const badge = document.createElement("span")
  badge.className = "box-toc-count"
  badge.textContent = String(count)
  summary.append(label, badge)
  return summary
}

// Port of BoxesController#index's `@sections` grouping: Object.groupBy is too new to rely on across
// every browser this addon might see, so a small manual grouping stands in for
// `generators.group_by { ... }.sort_by { |group, _| group }`. Insertion order within a group is
// preserved (the sidecar already returns generators sorted by key), matching the original.
function groupByField(items, keyFn) {
  const map = new Map()
  for (const item of items) {
    const key = keyFn(item)
    if (!map.has(key)) map.set(key, [])
    map.get(key).push(item)
  }
  return [ ...map.entries() ].sort((a, b) => a[0].localeCompare(b[0]))
}

// Port of BoxesController#saved_tree: section (generator's ui_group) -> generator key -> that
// generator's saved boxes. A saved box whose generator the sidecar no longer offers still has to
// appear (the user's file is in their library either way), so an unknown key files under "Other".
function buildSavedTree(states, generators) {
  const sectionOf = new Map(generators.map((g) => [ g.key, g.group || "Other" ]))
  const bySection = new Map()
  for (const state of states) {
    const genKey = String(state.data?.generator ?? "")
    const section = sectionOf.get(genKey) || "Other"
    if (!bySection.has(section)) bySection.set(section, new Map())
    const byType = bySection.get(section)
    const typeKey = genKey || "Unknown"
    if (!byType.has(typeKey)) byType.set(typeKey, [])
    byType.get(typeKey).push(state)
  }
  return [ ...bySection.entries() ]
    .sort((a, b) => a[0].localeCompare(b[0]))
    .map(([ section, byType ]) => [ section, [ ...byType.entries() ].sort((a, b) => a[0].localeCompare(b[0])) ])
}
