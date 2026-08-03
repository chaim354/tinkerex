// A saved box's detail view. Ported from the tinkerex repo's app/views/tools/boxes/show.html.erb.
//
// state: one entry from ctx.statesUrl — {id, name, data: {generator, params}, updated_at,
// files: [{node_id, role}]}. onBack(): return to the gallery. onDuplicate(generatorKey, params):
// open the editor prefilled with this box's params (the "Duplicate & tweak" flow).
//
// NOTE ON THE BUNDLE-FILES LIST: the states endpoint gives only {node_id, role} per file (no
// content_type, no browsable URL) — this bundle has no host surface for "the URL of a library
// file", so the link below is built from `/files/<node_id>`, the app's own long-standing
// `resources :files` route. That is a hardcoded assumption about Rails' routing (the one thing
// ctx.serviceUrl/ctx.statesUrl exist specifically so a bundle would NOT have to make), narrowly
// tolerated here because the route is foundational and used throughout the host app; if it ever
// moves, this link breaks quietly rather than the rest of the page.
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
  // the original ERB page showed the state's creation time; this is its last-saved time instead,
  // which for a box that is never re-saved in place (this bundle always creates a new state) are
  // the same moment anyway.
  $("saved-at").textContent = formatDateTime(state.updated_at)

  const filesList = $("files")
  if (!state.files?.length) {
    filesList.innerHTML = `<li class="muted">No files.</li>`
  } else {
    for (const file of state.files) {
      const li = document.createElement("li")
      const link = document.createElement("a")
      link.href = `/files/${encodeURIComponent(file.node_id)}`
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
