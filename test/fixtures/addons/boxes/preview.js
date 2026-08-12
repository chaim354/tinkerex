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
//
// See boxes.js's import for why this is a static import of the host pin and never a vendored copy.
// `host` is a LIVE BINDING — read through it at call time, never captured at module top level.
import { host, ServiceError } from "@maker/addon-sdk"

// One call to the sidecar's /generate, via the host's service proxy. Shared by the live preview
// below AND editor.js's save handler (which needs a FRESH render at save time — the same thing
// Tools::BoxesController#create did server-side — rather than reusing whatever the debounced
// preview last drew, which may be stale by the time Save is clicked).
//
// Returns { ok: true, svg } or { ok: false, message } — never throws for an ordinary sidecar
// rejection (a 422 naming a bad param is not exceptional here), only lets a genuine network/abort
// failure propagate so callers can tell "the sidecar said no" from "we couldn't reach it". That
// split is exactly the SDK's own: `service.post` throws ServiceError for a response the SIDECAR
// refused, ServiceUnavailableError for a transport failure, and rethrows an abort VERBATIM — so
// catching the one class below leaves the other two to propagate, unchanged.
//
// DO NOT PUT THIS BACK ON A RAW fetch. It was one until tinkerex PR #169, because `service.post`
// sent a FormData and multipart serialization rewrites every text entry's newlines to CRLF — which
// silently corrupted TrayLayout, whose entire input is a `layout` textarea boxes.py parses line by
// line (tinkerex CLAUDE.md §14c). It sends a JSON body now, so the exception is gone and with it the
// one call in this bundle that forfeited the SDK's Ring-2 promise: there is again ONE transport to
// swap under a null-origin iframe rather than one plus a hand-rolled CSRF header.
export async function generateSvg({ generator, params, signal }) {
  let res
  try {
    res = await host.service.post("boxes", "generate", { generator, params }, { signal })
  } catch (e) {
    if (e instanceof ServiceError) return { ok: false, message: sidecarMessage(e) }
    throw e
  }

  return { ok: true, svg: await res.text() }
}

// THE SIDECAR'S OWN PROSE, WHICH IS THE WHOLE REASON THIS FUNCTION EXISTS. "traylayout requires
// --layout, …" names the param to fix; a status code does not. boxes.py sends it as JSON
// ({"error": "…"}), but ServiceError deliberately carries the response's RAW TEXT rather than a
// parsed body — a failure through this proxy may not be JSON at all (the proxy's own body-less 404
// for an unconfigured sidecar, Werkzeug's HTML 405 page for a GET at a POST-only route), and
// errorFrom's own res.json() would discard exactly the message worth keeping. So the parse belongs
// HERE, in the one place the sidecar's shape is known. Three rungs, so a failure never renders as a
// blank message: the JSON `error` key; else the raw text, which ServiceError has already put in
// `message` (substituting its own "Service request failed (404)" when the body was empty); else, for
// a whitespace-only body that leaves both blank, a sentence of our own.
function sidecarMessage(error) {
  try {
    const body = JSON.parse(error.body)
    if (typeof body?.error === "string" && body.error.trim()) return body.error
  } catch (_e) { /* not JSON — the raw text is still the sidecar's own words */ }
  return error.message.trim() || `Preview failed (${error.status})`
}

// It renders the generator's defaults on mount — landing on an empty grey panel and having to press
// a button to find out what the generator even makes was the thing the original fixed — and then
// re-renders on a debounce whenever a param settles. Only param fields trigger a re-render: the
// box's name and its destination folder do not affect the drawing, and re-rendering while someone
// types a name would be a sidecar call per keystroke for nothing.
//
// TAKES NO `ctx` AT ALL NOW, AND THAT IS THE POINT OF THE CHANGE ABOVE. It threaded one through to
// generateSvg purely to feed a raw fetch's URL and CSRF header; the SDK owns both, so the parameter
// went with the fetch rather than being kept "in case". A module that needs no mount context should
// not be handed one — the next reader would reasonably assume something here still reads it.
//
// opts:
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
  paramsRoot, image, status, getGenerator, getValues, markerEl, delay = 600,
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
        generator: getGenerator(), params: getValues(), signal: controller.signal,
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
