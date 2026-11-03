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
    if (e instanceof ServiceError) return { ok: false, message: serviceFailure(e) }
    throw e
  }

  return { ok: true, svg: await res.text() }
}

// WHAT A FAILED SIDECAR CALL SAYS TO A MAKER: A SENTENCE, NEVER THE WIRE. The SDK's ServiceError
// carries the response's status and its RAW TEXT, and its `message` falls back to "Service request
// failed (404)" for an empty body: accurate for a developer, and exactly the raw wire code the host
// stopped showing anyone (its UX audit, 2026-11-01). Every catch in this bundle that would show a
// failed sidecar call's text goes through here — the editor's live preview and save (via generateSvg
// above, and editor.js's transport arm) and boxes.js's load — so the decision is made once.
// (mountPreview's own transport arm below shows a fixed sentence and no error text, so it needs
// none of this.) Three answers, by status:
//
//   - 503, or a 404 carrying no words of the sidecar's own: the service is not there. The host's
//     proxy answers a BODY-LESS 404 for a sidecar it has no URL for, one it cannot reach and one
//     that timed out (Tools::AddonsController#service), so a bare 404 means "not configured or not
//     running", never "no such thing".
//   - any other 4xx, or a 404 the sidecar wrote words into: it answered and named the problem.
//     boxes.py's {"error": "traylayout requires --layout, …"} names the param to fix, which a status
//     code never could; its 404 {"error": "unknown generator"} proves the service IS running. Its
//     words, verbatim.
//   - anything else — a 5xx, an HTML error page, the SDK's network_error raised before any response
//     existed, a bug in this bundle: no answer came back, and "try again" is the only advice that is
//     true of all of them.
//
// THE RAW TEXT GOES TO THE CONSOLE EXACTLY WHEN THE SCREEN REPLACES IT, so it is never lost — and is
// not logged when the sidecar's own words are what the screen shows, or the debounced preview would
// log a console error every time someone paused mid-way through typing a value.
const TITLE = "Box Generator"

export function serviceFailure(error) {
  const status = error instanceof ServiceError ? error.status : null
  const words = status === null ? "" : sidecarWords(error.body)
  if (words && status >= 400 && status < 500) return words
  console.error(`${TITLE}: a service call failed.`, error)
  if (status === 404 || status === 503) {
    return `The ${TITLE} service is not running on this server right now.`
  }
  return `${TITLE} could not answer; try again in a moment.`
}

// The sidecar's own sentence, or "" when the body holds none. The parse belongs HERE, in the one
// place the sidecar's shape is known: ServiceError deliberately keeps the raw text rather than a
// parsed body, because a failure through this proxy may not be JSON at all. boxes.py writes JSON
// ({"error": "…"}) — JSON WITHOUT a string `error` is a shape we do not know, and showing it raw
// would put braces in front of a maker. Plain text is the sidecar's own words; markup is not (a
// Werkzeug HTML 405 page for a GET at a POST-only route is a page, not a sentence).
function sidecarWords(text) {
  const raw = String(text ?? "").trim()
  try {
    const body = JSON.parse(raw)
    return typeof body?.error === "string" ? body.error.trim() : ""
  } catch (_e) { /* not JSON — plain text may still be the sidecar's own words */ }
  return raw.startsWith("<") ? "" : raw
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
