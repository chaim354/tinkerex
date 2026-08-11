import { mountSections } from "./sections.js"
import { mountTraySync } from "./tray_sync.js"
import { mountTopView } from "./top_view.js"
import { mountPreview, generateSvg } from "./preview.js"
import { buildParamGroups, paramValues } from "./fields.js"
import { printPlan, downloadPdf, downloadSvg, planSvgFor } from "./export.js"
import { mountFolderField } from "./folder_field.js"
// See boxes.js's import for why this is a static import of the host pin and never a vendored copy.
// `host` is a LIVE BINDING — read through it at call time, never captured at module top level.
import {
  host, AddonError, NameTakenError, ServiceUnavailableError, WouldReplaceError,
} from "@maker/addon-sdk"

const PAPER_KEY = "boxes.paper"

// WHAT A FAILED SAVE SAYS, PER REFUSAL — the actual win of moving onto the SDK. Every failure used
// to collapse into one string, "Save failed.", because the hand-rolled POST read `res.ok` and
// nothing else. The host has answered a typed, nameable refusal on each of these since its save
// door grew its rescue_from block; the SDK turns each one into a class, so `instanceof` is all it
// takes to say WHICH — and the user finally learns whether to rename, retry, or wait.
//
// 409 AND 422 STAY APART, and that is the one distinction here that is not cosmetic: a 409 is a
// QUESTION (resend with overwrite and it succeeds — onReplace below answers it) while a 422 NEVER
// succeeds on retry. Collapsing them offers an Overwrite button for a save that can never take one.
// This is the same table generators.js carries, and deliberately the same wording where the
// conditions are the same — two bundles disagreeing about what a 503 means would be worse than
// either wording.
const saveFailure = (e) => {
  // 422 unsupported_operation — the name is taken in the folder the user picked. The host's own
  // message already names the file and says what to do ("Rename the save or pick another folder."),
  // so adding advice here would only be a second copy of it, free to drift.
  if (e instanceof NameTakenError) return `Not saved. ${e.message}`
  // 409 would_replace, reachable ONLY on the overwrite re-send: the SDK answers the first one
  // through onReplace, so arriving here means the user already said yes and the host refused again.
  // Naming the files is the useful part; asking the same question a second time is not.
  if (e instanceof WouldReplaceError) {
    return `Not saved: this would still replace ${e.files.map((f) => f.name).join(", ")}.`
  }
  // 503 fetch_error from an unmounted share, or the SDK's own network_error raised before any
  // response existed. Both read the same way to a user: the request was fine, the library was not.
  if (e instanceof ServiceUnavailableError) {
    return "Couldn't reach your library — nothing was saved. Try again in a moment."
  }
  // Everything else the host or the SDK can name: a reserved output name, an oversized payload, a
  // capability this host does not have. `message` carries the host's own sentence where there is
  // one, and the SDK's own where there is not.
  if (e instanceof AddonError) return `Save failed: ${e.message}`
  return `Save failed: ${e.message || e}`
}

// The per-generator editor: the param form (grouped, collapsible), the live preview, the top-view
// compartment plan, and "made with this generator" prior boxes. Ported from the tinkerex repo's
// app/views/tools/boxes/new.html.erb + its boxpreview/boxsections/traylayout/topview Stimulus
// controllers, onto plain DOM building + the sibling modules in this directory.
//
// root: element to render into. generator: {key, title, group, param_groups}. states: the full
// saved-states array (filtered here to this generator for the prior-boxes list). ctx: the mount
// context, now forwarded rather than picked apart — folder_field.js reads its two DESTINATION keys
// (`defaultFolder`, `defaultFolderLabel`) and preview.js reads `serviceUrl`/`csrfToken` for the one
// call the SDK cannot yet carry (see the gap block in preview.js). `saveUrl` and the hand-rolled
// CSRF header are gone entirely — `host.files.save` owns the save door now.
// prefillValues: a saved box's
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
          <!-- A <div>, NOT the <label> its siblings use, because mountFolderField may render a
               <button> here: a <label> wrapping a button re-dispatches the click, which opens the
               chooser and immediately reopens it. The <select> shape never had that problem, which
               is why this one field's markup differs from the Name field above it. -->
          <div class="box-field">
            <span class="box-field-label">Save to folder</span>
            <span data-role="folder-field"></span>
          </div>
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

  // The third argument is where the chooser reports a failure it cannot handle itself (a host that
  // advertises pick:folder and wired up no chooser, a capability answered false). Without it the
  // rejection would be uncaught and the button would simply do nothing, which is visually identical
  // to the user pressing Esc. `setSaveStatus` is declared further down and is in its temporal dead
  // zone right now — safe because this closure is only ever CALLED from a click, long after.
  const folderField = mountFolderField($("folder-field"), ctx, (msg) => setSaveStatus(msg, true))

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
    ctx,
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
    let result
    try {
      result = await generateSvg({ ctx, generator: generator.key, params })
    } catch (e) {
      // generateSvg returns {ok: false} for a sidecar's own refusal and only THROWS for a genuine
      // transport failure, so this arm must not say anything about parameters. Previously an
      // unhandled rejection: the save silently stopped at "Saving…" forever.
      setSaveStatus(`Couldn't reach the box generator — nothing was saved. ${e.message}`, true)
      return
    }
    if (!result.ok) { setSaveStatus(result.message, true); return }

    const base = name.replace(/[^a-z0-9]+/gi, "-").toLowerCase() || "box"
    // The plan goes in UNTILED and full size: tiling is a property of the printer, not of the
    // drawing, and an archival artifact should not arrive pre-chopped into sheets. SVG rather than
    // PDF because parse_files requires a String body over JSON — binary cannot round-trip, and a
    // base64 path would cost a Rails redeploy for something the PDF download already gives.
    // MAX_FILES is 8, so a second output needs no host change.
    //
    // camelCase `contentType`, not the wire's `content_type` — the SDK does that rename. A part
    // without one throws invalid_argument rather than letting the key vanish during serialisation
    // (JSON.stringify DROPS an undefined value) and writing a file with no content type at all.
    const outputs = [ { name: `${base}.svg`, contentType: "image/svg+xml", body: result.svg } ]
    const planModel = topView.getPlan?.()
    if (planModel) {
      outputs.push({
        name: `${base}-plan.svg`, contentType: "image/svg+xml", body: planSvgFor(planModel),
      })
    }

    try {
      const saved = await host.files.save({
        name,
        // REQUIRED AND NEVER DEFAULTED: null/undefined throws invalid_argument before any request,
        // because a cancelled pickFolder() resolves null and must not silently become the library
        // root. Safe here by construction — folderField.value() always answers a string, "" being
        // the root, and a cancelled chooser leaves the previous choice in place.
        folderNodeId: folderField.value(),
        data: { generator: generator.key, params },
        files: outputs,
        // THE 409 ANSWERED IN PLACE. A re-save under the same name is the ORDINARY way to iterate
        // on a design, and BOTH outputs collide on it (<base>.svg and <base>-plan.svg) — which used
        // to strand a second copy of each at the project root, silently. Omit onReplace and the SDK
        // throws WouldReplaceError instead — overwriting is never implicit.
        onReplace: (files) => window.confirm(
          `This will replace ${files.length === 1 ? "a file" : "files"} you already saved:\n\n` +
            `${files.map((f) => `  ${f.name}  (in ${f.folder}/)`).join("\n")}\n\n` +
            "Replace with this version?",
        ),
      })
      // TAGGED, AND BOTH SHAPES ARE TRUTHY — `{cancelled: false, data}` and `{cancelled: true}`.
      // Read `.cancelled`; testing the returned object itself reports "Saved." over a save the user
      // just declined. (`data` is `{}` today: the save door redirects rather than answering JSON.)
      setSaveStatus(saved.cancelled ? "Not saved." : "Saved.")
      if (!saved.cancelled) onSaved()
    } catch (e) {
      setSaveStatus(saveFailure(e), true)
      // Anything that is not an AddonError is a bug in THIS bundle rather than a refusal from the
      // host. Say so in the status line and still let the stack reach the console, instead of
      // swallowing it into a tidy message.
      if (!(e instanceof AddonError)) throw e
    }
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
