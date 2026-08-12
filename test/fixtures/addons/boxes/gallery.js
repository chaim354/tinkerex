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
// boxes.js). onOpenGenerator(key, prefillValues|null): open the editor. onOpenState(state): open a
// saved box's detail view.
//
// NO `ctx`: the sample-photo <img> below was the only thing in this module that ever read one, and
// it now builds its URL through the SDK. Kept out rather than left in place for a future caller —
// an unread parameter reads as "something here still needs the mount context".
export function mountGallery(root, { generators, states, onOpenGenerator, onOpenState }) {
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

  renderSavedRail($("saved"), savedTree, onOpenState)

  const filterCtl = mountFilter(root)
  const sectionsCtl = mountSections(root)

  return () => {
    filterCtl.destroy()
    sectionsCtl.destroy()
  }
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
  // Stimulus, so a missing sample photo (most generators have none — 404) is hidden by hand rather
  // than relying on a host controller auto-connecting to markup this bundle injects.
  img.addEventListener("error", () => img.classList.add("is-missing"))

  const label = document.createElement("span")
  label.className = "addon-title"
  label.textContent = generator.key

  card.append(img, label)
  return card
}

function renderSavedRail(container, savedTree, onOpenState) {
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
        a.addEventListener("click", (e) => { e.preventDefault(); onOpenState(state) })
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
