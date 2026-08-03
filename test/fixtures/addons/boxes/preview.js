// Live box preview: POST the current form params to the sidecar (via the host's service proxy) and
// drop the returned SVG straight into the preview <img> as a data URL. Ported from the tinkerex
// repo's boxpreview_controller.js (a Stimulus controller) to a plain mount/destroy function, with
// one deliberate change: the SHIPPED version rasterized the sidecar's SVG to PNG server-side
// (Tools::BoxesController#preview -> Maker::Previews::SvgRasterizer), but its own rescue clause
// already handed back RAW SVG when resvg was absent, and the shipped JS already assigned whatever
// came back straight to an <img src> — so SVG-in-<img> was already proven to work on that path. This
// bundle always takes that path: render the SVG as a data URL, exactly as addons/generators/
// generators.js does. There is no PNG endpoint to call — the host never grew one (see the boxes
// migration plan's "the rasterization surface is not built, deliberately").

// One call to the sidecar's /generate, via the host's service proxy. Shared by the live preview
// below AND editor.js's save handler (which needs a FRESH render at save time — the same thing
// Tools::BoxesController#create did server-side — rather than reusing whatever the debounced
// preview last drew, which may be stale by the time Save is clicked).
//
// Returns { ok: true, svg } or { ok: false, message } — never throws for an ordinary sidecar
// rejection (a 422 naming a bad param is not exceptional here), only lets a genuine network/abort
// failure propagate so callers can tell "the sidecar said no" from "we couldn't reach it".
export async function generateSvg({ serviceUrl, csrfToken, generator, params, signal }) {
  const res = await fetch(`${serviceUrl}boxes/generate`, {
    method: "POST",
    headers: { "Content-Type": "application/json", "X-CSRF-Token": csrfToken },
    body: JSON.stringify({ generator, params }),
    signal,
  })

  if (!res.ok) {
    // The sidecar's own complaint ("traylayout requires --layout, …") is the most useful thing to
    // show — it names the param to fix. It comes back as JSON ({"error": "..."}); fall back to the
    // raw body for anything else so a failure never renders as a blank message.
    let message = `Preview failed (${res.status})`
    try {
      if ((res.headers.get("content-type") || "").includes("json")) {
        const body = await res.json()
        message = body?.error || message
      } else {
        message = (await res.text()).trim() || message
      }
    } catch (_e) { /* keep the generic message */ }
    return { ok: false, message }
  }

  return { ok: true, svg: await res.text() }
}

// It renders the generator's defaults on mount — landing on an empty grey panel and having to press
// a button to find out what the generator even makes was the thing the original fixed — and then
// re-renders on a debounce whenever a param settles. Only param fields trigger a re-render: the
// box's name and its destination folder do not affect the drawing, and re-rendering while someone
// types a name would be a sidecar call per keystroke for nothing.
//
// opts:
//   serviceUrl   — ctx.serviceUrl (see boxes.js); calls are POSTed to `${serviceUrl}boxes/generate`.
//   csrfToken    — ctx.csrfToken; sent as X-CSRF-Token (the service route is NOT CSRF-exempt).
//   paramsRoot   — the element whose descendant [data-param] inputs should trigger a re-render.
//   image        — the <img> to update.
//   status       — a status element (optional); textContent set to the current state.
//   getGenerator — () => current generator key.
//   getValues    — () => { [paramName]: value } for the current generator.
//   markerEl     — element to receive a "has-preview" class once the first render lands (optional;
//                  mirrors the original's `this.element.classList.add("has-preview")` on the
//                  `.box-editor` root — unused by application.css today, kept for parity in case a
//                  future style hooks off it).
//   delay        — debounce delay in ms (default 600, matching the original).
export function mountPreview({
  serviceUrl, csrfToken, paramsRoot, image, status, getGenerator, getValues, markerEl, delay = 600,
}) {
  let seq = 0
  let timer = null
  let controller = null

  const setStatus = (text, isError = false) => {
    if (!status) return
    status.textContent = text
    status.hidden = text === ""
    status.classList.toggle("is-error", isError)
  }

  async function preview() {
    clearTimeout(timer)
    // An edit made mid-render must win, however the two requests happen to land: abort the one in
    // flight AND stamp this one, so a slow earlier response can't overwrite a newer image.
    controller?.abort()
    controller = new AbortController()
    const mine = ++seq
    setStatus("Rendering…")

    try {
      const result = await generateSvg({
        serviceUrl, csrfToken, generator: getGenerator(), params: getValues(), signal: controller.signal,
      })
      if (mine !== seq) return

      if (!result.ok) {
        setStatus(result.message, true)
        return
      }

      image.src = `data:image/svg+xml;utf8,${encodeURIComponent(result.svg)}`
      markerEl?.classList.add("has-preview")
      setStatus("")
    } catch (e) {
      if (e.name === "AbortError" || mine !== seq) return
      setStatus("Preview unavailable — check the connection, then press Preview.", true)
    }
  }

  const onEdit = (event) => {
    if (!event.target.dataset || event.target.dataset.param === undefined) return
    clearTimeout(timer)
    timer = setTimeout(preview, delay)
  }
  paramsRoot.addEventListener("input", onEdit)
  paramsRoot.addEventListener("change", onEdit)

  preview() // self-start: render the defaults with nothing clicked

  return {
    preview,
    destroy() {
      clearTimeout(timer)
      controller?.abort()
      paramsRoot.removeEventListener("input", onEdit)
      paramsRoot.removeEventListener("change", onEdit)
    },
  }
}
