import { mountSections } from "./sections.js"
import { mountTraySync } from "./tray_sync.js"
import { mountTopView } from "./top_view.js"
import { mountPreview, generateSvg } from "./preview.js"
import { buildParamGroups, paramValues } from "./fields.js"

// The per-generator editor: the param form (grouped, collapsible), the live preview, the top-view
// compartment plan, and "made with this generator" prior boxes. Ported from the tinkerex repo's
// app/views/tools/boxes/new.html.erb + its boxpreview/boxsections/traylayout/topview Stimulus
// controllers, onto plain DOM building + the sibling modules in this directory.
//
// root: element to render into. generator: {key, title, group, param_groups}. states: the full
// saved-states array (filtered here to this generator for the prior-boxes list). ctx: the mount
// context (serviceUrl, saveUrl, csrfToken, folders, defaultFolder). prefillValues: a saved box's
// `params`, when opened via "Load"/"Duplicate & tweak", or null for a fresh generator.
// onBack(): return to the gallery. onSaved(): a save completed — the caller re-fetches states.
// onOpenGenerator(key, prefillValues): re-open the editor (same or another generator) — used by the
// "Load" link on a prior box made with this same generator.
export function mountEditor(root, { generator, states, ctx, prefillValues, onBack, onSaved, onOpenGenerator }) {
  root.innerHTML = `
    <div class="page-head">
      <div>
        <h1 data-role="key"></h1>
        <p class="page-subtitle muted" data-role="title"></p>
      </div>
      <button type="button" class="btn ghost" data-role="back">Back</button>
    </div>

    <div class="box-editor">
      <div>
        <div class="box-actions">
          <label class="box-field">
            <span class="box-field-label">Name</span>
            <input type="text" data-role="name" required>
          </label>
          <label class="box-field">
            <span class="box-field-label">Save to folder</span>
            <select data-role="folder"></select>
          </label>
          <div class="page-actions">
            <button type="button" data-role="preview-btn" class="btn ghost">Preview</button>
            <button type="button" data-role="save" class="btn">Save to library</button>
          </div>
        </div>
        <p class="muted" data-role="save-status" hidden></p>

        <div class="param-groups-head">
          <span class="param-groups-title">Settings</span>
          <button type="button" class="box-toc-all" data-boxsections="toggle-all">Collapse all</button>
        </div>
        <div data-role="groups"></div>
      </div>

      <aside class="box-side">
        <div class="preview box-preview">
          <img data-role="preview-image" alt="Box preview" class="preview-image">
          <p class="box-preview-status" data-role="status" role="status" aria-live="polite" hidden></p>
        </div>

        <div class="box-topview" data-role="topview-panel" hidden>
          <h3>
            Top view
            <span class="box-topview-summary muted" data-topview="summary"
                  role="status" aria-live="polite"></span>
          </h3>
          <div class="box-topview-canvas" data-topview="canvas"></div>
          <p class="box-topview-hint muted">Compartments only — joinery is on the cut sheet above.</p>
        </div>

        <div data-role="prior-wrap"></div>
      </aside>
    </div>`

  const $ = (role) => root.querySelector(`[data-role="${role}"]`)

  $("key").textContent = generator.key
  $("title").textContent = generator.title

  for (const [ label, id ] of ctx.folders) {
    const opt = new Option(label, id)
    if (id === ctx.defaultFolder) opt.selected = true
    $("folder").add(opt)
  }

  $("groups").appendChild(buildParamGroups(generator.param_groups, prefillValues))
  renderPrior($("prior-wrap"), states, generator, onOpenGenerator)

  const destroyers = []
  destroyers.push(mountSections(root))
  destroyers.push(mountTraySync($("groups")))
  destroyers.push(mountTopView($("topview-panel"), $("groups")))

  const preview = mountPreview({
    serviceUrl: ctx.serviceUrl,
    csrfToken: ctx.csrfToken,
    paramsRoot: $("groups"),
    image: $("preview-image"),
    status: $("status"),
    getGenerator: () => generator.key,
    getValues: () => paramValues($("groups")),
    markerEl: root.querySelector(".box-editor"),
  })
  destroyers.push(preview)
  $("preview-btn").addEventListener("click", preview.preview)

  const setSaveStatus = (text, isError = false) => {
    $("save-status").textContent = text
    $("save-status").hidden = text === ""
    $("save-status").classList.toggle("is-error", isError)
  }

  const onSaveClick = async () => {
    const name = $("name").value.trim()
    if (!name) { setSaveStatus("Name is required.", true); return }

    setSaveStatus("Saving…")
    const params = paramValues($("groups"))
    // A FRESH render, not whatever the debounced live preview last drew — the box's params may
    // have changed since that request landed, and this mirrors what the retired
    // Tools::BoxesController#create did (its own separate `client.generate` call at save time).
    const result = await generateSvg({ serviceUrl: ctx.serviceUrl, csrfToken: ctx.csrfToken, generator: generator.key, params })
    if (!result.ok) { setSaveStatus(result.message, true); return }

    const base = name.replace(/[^a-z0-9]+/gi, "-").toLowerCase() || "box"
    const body = new FormData()
    body.append("name", name)
    body.append("parent_node_id", $("folder").value)
    body.append("data", JSON.stringify({ generator: generator.key, params }))
    body.append("files", JSON.stringify([
      { name: `${base}.svg`, content_type: "image/svg+xml", body: result.svg },
    ]))

    const res = await fetch(ctx.saveUrl, { method: "POST", body, headers: { "X-CSRF-Token": ctx.csrfToken } })
    setSaveStatus(res.ok ? "Saved." : "Save failed.", !res.ok)
    if (res.ok) onSaved()
  }
  $("save").addEventListener("click", onSaveClick)

  const onBackClick = () => onBack()
  $("back").addEventListener("click", onBackClick)

  return () => {
    for (const d of destroyers) d?.destroy?.()
    $("preview-btn").removeEventListener("click", preview.preview)
    $("save").removeEventListener("click", onSaveClick)
    $("back").removeEventListener("click", onBackClick)
  }
}

// "Made with <generator>" — saved boxes made with this same generator, newest first (the states
// endpoint already orders that way). Ported from new.html.erb's @prior list; see fields.js/show.js's
// header comments for why there is no library-file thumbnail here (out of this task's host-surface
// scope) — a generic SVG tile stands in for every item instead of the host's `thumbs` controller.
function renderPrior(container, states, generator, onOpenGenerator) {
  const prior = states.filter((s) => String(s.data?.generator ?? "") === generator.key)
  if (!prior.length) {
    container.innerHTML = `<p class="box-prior-hint muted">No saved boxes with this generator yet.</p>`
    return
  }

  container.innerHTML = `
    <div class="box-prior">
      <h3>Made with ${escapeHtml(generator.key)}</h3>
      <div class="box-prior-hint muted">${prior.length} saved box${prior.length === 1 ? "" : "es"}</div>
      <ul class="box-prior-list" data-role="list"></ul>
    </div>`
  const list = container.querySelector('[data-role="list"]')

  for (const state of prior) {
    const li = document.createElement("li")
    li.className = "box-prior-item"

    const thumb = document.createElement("span")
    thumb.className = "thumb"
    thumb.innerHTML = `<span class="thumb-icon" aria-hidden="true">SVG</span>`

    const meta = document.createElement("div")
    meta.className = "box-prior-meta"
    const name = document.createElement("div")
    name.className = "box-prior-name"
    name.textContent = state.name
    const date = document.createElement("div")
    date.className = "box-prior-date"
    date.textContent = String(state.updated_at).slice(0, 10)
    meta.append(name, date)

    const load = document.createElement("a")
    load.href = "#"
    load.textContent = "Load"
    load.setAttribute("aria-label", `Load ${state.name}`)
    load.addEventListener("click", (e) => {
      e.preventDefault()
      // Reopen THIS SAME editor with the saved params prefilled — mirrors the original's
      // `box_prefill_path`, which re-requested `new` with `params[params]` set.
      onOpenGenerator(generator.key, state.data?.params || {})
    })

    li.append(thumb, meta, load)
    list.appendChild(li)
  }
}

function escapeHtml(s) {
  return String(s).replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]))
}
