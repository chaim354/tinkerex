// See boxes.js's import for why this is a static import of the host pin and never a vendored copy.
// `host` is a LIVE BINDING — read through it at call time, never captured at module top level.
import { host } from "@maker/addon-sdk"

// A saved box's detail view, now reached from the saved rail's right-click menu rather than a left
// click — which opens the editor on that box instead. Kept because this is the only place that
// lists the bundle's files. Ported from the tinkerex repo's app/views/tools/boxes/show.html.erb.
//
// state: one entry from state.list() — {id, name, data: {generator, params}, updated_at, revision,
// files: [{node_id, role}]}. onBack(): return to the gallery. onDuplicate(generatorKey, params):
// open the editor prefilled with this box's params (the "Duplicate & tweak" flow) — a FORK, the one
// place in this bundle where opening a saved box's params does not mean editing that box.
//
// NOTE ON THE BUNDLE-FILES LIST: the states endpoint gives only {node_id, role} per file (no
// content_type, no name), so the link text is the role and the href is `host.files.url(node_id)` —
// the SDK's builder for a library file's DETAIL page (not its bytes, which are served as an
// attachment). This was a hand-built `/files/<node_id>` for as long as no host surface existed for
// that URL: a hardcoded assumption about Rails' routing, which is the one thing ctx exists so a
// bundle would not have to make. The SDK grew the builder, so that assumption is gone from here and
// from gallery.js's menu entry together.
export function mountShow(root, { state, ctx, onBack, onDuplicate }) {
  root.innerHTML = `
    <div class="page-head">
      <h1 data-role="title"></h1>
      <button type="button" class="btn ghost" data-role="back">Back</button>
    </div>
    <dl class="meta">
      <dt>Generator</dt><dd data-role="generator"></dd>
      <dt>Saved</dt><dd data-role="saved-at"></dd>
    </dl>
    <h2>Bundle</h2>
    <ul class="bundle-files" data-role="files"></ul>
    <section class="addon-params">
      <h2>Parameters</h2>
      <div data-role="params"></div>
    </section>
    <button type="button" class="btn ghost" data-role="duplicate">Duplicate &amp; tweak</button>`

  const $ = (role) => root.querySelector(`[data-role="${role}"]`)
  const generatorKey = String(state.data?.generator ?? "")
  const params = state.data?.params || {}

  $("title").textContent = state.name
  $("generator").textContent = generatorKey
  // The states endpoint (Tools::AddonsController#states) returns `updated_at`, not `created_at` —
  // the original ERB page showed the state's creation time; this is its LAST-saved time. Those were
  // the same moment for as long as every save minted a new box; now that a save appends a revision
  // they genuinely differ, and last-saved is the more useful of the two here — when the box was
  // first created is a fact the History panel's oldest entry carries.
  $("saved-at").textContent = formatDateTime(state.updated_at)

  const filesList = $("files")
  if (!state.files?.length) {
    filesList.innerHTML = `<li class="muted">No files.</li>`
  } else {
    for (const file of state.files) {
      const li = document.createElement("li")
      const link = document.createElement("a")
      link.href = host.files.url(file.node_id)
      link.textContent = file.role
      li.appendChild(link)
      filesList.appendChild(li)
    }
  }

  const paramsEl = $("params")
  const entries = Object.entries(params)
  if (!entries.length) {
    paramsEl.innerHTML = `<p class="muted">No parameters.</p>`
  } else {
    const dl = document.createElement("dl")
    dl.className = "meta"
    for (const [ key, value ] of entries) {
      const dt = document.createElement("dt")
      dt.textContent = key
      const dd = document.createElement("dd")
      dd.className = "mono"
      dd.textContent = String(value ?? "").trim() || "—"
      dl.append(dt, dd)
    }
    paramsEl.appendChild(dl)
  }

  const onBackClick = () => onBack()
  const onDupClick = () => onDuplicate(generatorKey, params)
  $("back").addEventListener("click", onBackClick)
  $("duplicate").addEventListener("click", onDupClick)

  return () => {
    $("back").removeEventListener("click", onBackClick)
    $("duplicate").removeEventListener("click", onDupClick)
  }
}

function formatDateTime(value) {
  const d = new Date(value)
  if (Number.isNaN(d.getTime())) return String(value ?? "")
  const pad = (n) => String(n).padStart(2, "0")
  return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())} ${pad(d.getHours())}:${pad(d.getMinutes())}`
}
