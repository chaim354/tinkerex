import { mountSections } from "./sections.js"
import { mountTraySync } from "./tray_sync.js"
import { mountTopView } from "./top_view.js"
import { mountPreview, generateSvg } from "./preview.js"
import { buildParamGroups, paramValues } from "./fields.js"
import { printPlan, downloadPdf, downloadSvg, planSvgFor } from "./export.js"
import { saveWithOverwrite } from "./save.js"

const PAPER_KEY = "boxes.paper"

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
          <div class="box-topview-actions">
            <select data-export="paper" aria-label="Paper size">
              <option value="A4">A4</option>
              <option value="Letter">Letter</option>
              <option value="A3">A3</option>
              <option value="Tabloid">Tabloid</option>
            </select>
            <button type="button" class="btn ghost btn-sm" data-export="print">Print</button>
            <button type="button" class="btn ghost btn-sm" data-export="pdf">PDF</button>
            <button type="button" class="btn ghost btn-sm" data-export="svg">SVG</button>
          </div>
          <div class="box-topview-canvas" data-topview="canvas"></div>
          <p class="box-topview-hint muted">Compartments only — joinery is on the cut sheet above.
            Printed sheets are 1:1 — check the 100&nbsp;mm bar with a ruler.</p>
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

  const topView = mountTopView($("topview-panel"), $("groups"))
  destroyers.push(topView)

  // The top-view panel REMOVES ITSELF when the first draw yields no grid — that is how FrontPanel,
  // whose `layout` is a different DSL entirely, is kept out. So these controls exist only where a
  // plan exists, and need no gate of their own.
  const paperSel = root.querySelector('[data-export="paper"]')
  if (paperSel) {
    paperSel.value = localStorage.getItem(PAPER_KEY) || "A4"
    const rememberPaper = () => localStorage.setItem(PAPER_KEY, paperSel.value)
    paperSel.addEventListener("change", rememberPaper)
    destroyers.push({ destroy: () => paperSel.removeEventListener("change", rememberPaper) })
  }

  const exportBase = () =>
    $("name").value.trim().replace(/[^a-z0-9]+/gi, "-").toLowerCase() || generator.key.toLowerCase()

  // Mid-edit the art is routinely unparseable and the panel deliberately keeps the last good
  // drawing up, so an export uses that same model: what you print is what you are looking at.
  const onExport = (event) => {
    const which = event.target.closest("[data-export]")?.dataset.export
    if (!which || which === "paper") return
    const model = topView.getPlan?.()
    if (!model) return

    const say = (text) => { const s = root.querySelector('[data-topview="summary"]'); if (s) s.textContent = text }
    try {
      const sinks = { print: printPlan, pdf: downloadPdf, svg: downloadSvg }
      const pages = sinks[which](model, paperSel.value, exportBase())
      if (which === "print" && pages > 1) say(`${pages} sheets — tape along the overlap band.`)
    } catch (e) {
      // The 40-sheet refusal lands here, and so does anything the print frame throws. Saying it in
      // the panel beats a console error nobody sees.
      say(e.message)
    }
  }
  root.addEventListener("click", onExport)
  destroyers.push({ destroy: () => root.removeEventListener("click", onExport) })

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
    // The plan goes in UNTILED and full size: tiling is a property of the printer, not of the
    // drawing, and an archival artifact should not arrive pre-chopped into sheets. SVG rather than
    // PDF because parse_files requires a String body over JSON — binary cannot round-trip, and a
    // base64 path would cost a Rails redeploy for something the PDF download already gives.
    // MAX_FILES is 8, so a second output needs no host change.
    const outputs = [ { name: `${base}.svg`, content_type: "image/svg+xml", body: result.svg } ]
    const planModel = topView.getPlan?.()
    if (planModel) {
      outputs.push({
        name: `${base}-plan.svg`, content_type: "image/svg+xml", body: planSvgFor(planModel),
      })
    }
    body.append("files", JSON.stringify(outputs))

    // Through saveWithOverwrite, not a bare fetch. A re-save under the same name is the ORDINARY
    // way to iterate on a design, and BOTH outputs collide on it (<base>.svg and
    // <base>-plan.svg) — which used to strand a second copy of each at the project root.
    // See save.js for the 409 contract.
    const { res, cancelled } = await saveWithOverwrite(ctx.saveUrl, body, ctx.csrfToken)
    setSaveStatus(cancelled ? "Not saved." : res.ok ? "Saved." : "Save failed.", !cancelled && !res.ok)
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
