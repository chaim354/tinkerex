// THE ADDON HOST SDK — the one thing an addon bundle should touch.
//
// WHY IT EXISTS RATHER THAN A DOCUMENTED ctx. Every bundle today hand-rolls the same fetch + CSRF +
// error handling, and each copy reads only the HTTP status, so a save that failed for a nameable
// reason reports "Save failed." More importantly: this module is the HINGE for the sandbox (Ring 2,
// spec §8.2). Today its transport is same-origin fetch; under a null-origin iframe the identical
// surface is implemented over postMessage. Addon code does not change. Talking to the transport
// directly forfeits that — which is why the constructor's context is kept on `_ctx` (underscored,
// never a public `host.ctx`) instead of published as a semi-supported escape hatch: a name that
// reads as supported gets used.
//
// `host` IS A LIVE BINDING, NOT A SINGLETON YOU CONSTRUCT. addon_controller.js calls initHost(ctx)
// BEFORE it dynamic-imports the bundle, so by the time any addon code runs the binding is set.
// Consequence worth knowing: destructuring at module top level (`const { files } = host`) captures
// whatever `host` IS AT THAT MOMENT — read through `host` at call time instead. Before initHost()
// runs, `host` is not null but a Proxy that THROWS a named error on any property read (see
// UNINITIALIZED_HOST below), so getting this wrong fails loudly at the read, not with a generic
// null-dereference several calls later.

// THE SENTINEL a bundle sees if it reads `host` before initHost() has run — e.g. code at a bundle's
// own module top level, which executes at import time, before addon_controller.js's initHost(ctx)
// call happens. Throwing beats returning null: `Cannot read properties of null` names nothing, and
// a top-level `const { files } = host` would silently capture null with NO error at all, to be
// dereferenced pages later with no clue where it went wrong. THE ONE HONEST COST: this is still an
// OBJECT, so `if (host)` is truthy whether or not initHost() has run — `capabilities()` is the
// supported way to ask "is a real host here", never a truthiness check on the binding itself.
const UNINITIALIZED_HOST = new Proxy({}, {
  get(_target, prop) {
    if (typeof prop === "symbol") return undefined // let engine/devtools introspection pass quietly
    throw new AddonError(
      "host_not_initialized",
      `host.${String(prop)} was read before initHost() ran. addon_controller.js calls initHost(ctx) ` +
        "before dynamic-importing a bundle — this module ran before that had happened.",
    )
  },
})

export let host = UNINITIALIZED_HOST

// ---------------------------------------------------------------------------
// Errors
// ---------------------------------------------------------------------------

// Every failure an addon can act on is a class, so a bundle branches on `instanceof` rather than
// parsing a message. `code` is the server's own code (docs/addon-api-v1.md §5) and `body` is the
// parsed payload, kept so a caller can reach fields this SDK does not model yet.
export class AddonError extends Error {
  constructor(code, message, body = null, status = null) {
    super(message)
    this.name = new.target.name
    this.code = code
    this.body = body
    this.status = status
  }
}

// 422 — the destination name is taken. NEVER succeeds on retry, so it must not be offered as a
// question. This is the distinction save.js exists to make; getting it wrong offers an Overwrite
// button for a save that can never take one.
export class NameTakenError extends AddonError {}

// 409 — the save WOULD replace files the addon previously wrote. Answerable: re-send with
// overwrite. `files` is [{name, folder}].
//
// READS BOTH BODY SHAPES errorFrom COMMITS TO. errorFrom accepts today's flat {error: "would_replace",
// files: [...]} AND PR 3's nested {error: {code: "would_replace", files: [...]}}. A getter reading
// only `body.files` would silently hand `onReplace` an empty list under the nested shape — the
// confirmation dialog would name no files while the save proceeded as though there were no conflict.
export class WouldReplaceError extends AddonError {
  get files() { return this.body?.files ?? this.body?.error?.files ?? [] }
}

// 503 — the library is unreachable (an unmounted share), OR _fetch below caught a transport failure
// before any response existed at all (a dropped connection, DNS failure, offline — code
// "network_error"). Both read the same way to a caller: retry later, there is nothing to fix now.
export class ServiceUnavailableError extends AddonError {}

// The host does not have this capability at this level. Thrown by the SDK itself, before any
// request, so the failure names the capability instead of surfacing as a 404.
export class UnsupportedCapabilityError extends AddonError {}

// A SIDECAR'S OWN FAILURE, built directly from a response's status and its raw text — see
// serviceErrorFrom below for why it is kept OUT of the host's error table entirely. There is no
// `code` here worth naming, because the SDK cannot know a sidecar's error shape, only that it
// failed and what it said.
export class ServiceError extends AddonError {
  constructor(status, text) {
    super("service_error", text || `Service request failed (${status})`, text, status)
  }
}

const ERROR_CLASSES = {
  would_replace: WouldReplaceError,
  name_taken: NameTakenError,
  // unsupported_operation -> NameTakenError: today this door's ONLY unsupported_operation is the
  // clobber refusal, so the two codes name one condition. §14a: a caller that must branch on WHY
  // gets a subclass of its own — if this door ever grows a second unsupported_operation meaning,
  // that meaning needs its own subclass rather than continuing to borrow this one.
  unsupported_operation: NameTakenError,
  fetch_error: ServiceUnavailableError,
  service_unavailable: ServiceUnavailableError,
  // service_error is deliberately ABSENT — sidecar failures never reach errorFrom at all; see
  // service.get/post and serviceErrorFrom below.
}

// READS BOTH BODY SHAPES ON PURPOSE. The nested {error: {code, message}} contract lands in PR 3;
// the host answers the flat {error: "code", message} today and keeps answering it for the life of
// api_version 1. An SDK that understood only one of them would break on whichever host it met.
async function errorFrom(res) {
  let body = null
  try { body = await res.json() } catch { /* a body-less or non-JSON failure is still a failure */ }

  const nested = body?.error && typeof body.error === "object" ? body.error : null
  const code = nested?.code ?? (typeof body?.error === "string" ? body.error : "request_failed")
  const message = nested?.message ?? body?.message ?? `Request failed (${res.status})`
  // Object.hasOwn, NOT `ERROR_CLASSES[code]` truthiness: `code` comes straight off a response body,
  // so a body of {error: "toString"} or {error: "constructor"} would resolve through the prototype
  // chain to something that is not a class at all, and `new Klass(...)` throws a bare TypeError from
  // INSIDE errorFrom — discarding the original HTTP failure this function exists to describe.
  const Klass = Object.hasOwn(ERROR_CLASSES, code) ? ERROR_CLASSES[code] : AddonError
  return new Klass(code, message, body, res.status)
}

// SIDECAR ERRORS NEVER GO THROUGH errorFrom/ERROR_CLASSES — a sidecar's error body is not one of
// ours to interpret. boxes.py answers {"error": "argument --height: invalid value"}, where "error"
// is a HUMAN MESSAGE, not a code: errorFrom would put that prose in `.code` and a generic "Request
// failed" filler in `.message`, the opposite of useful. openscad answers text/plain, which errorFrom's
// `res.json()` would fail to parse and DISCARD ENTIRELY — exactly the message §14c kept
// application/json on the proxy's content-type allowlist to preserve. ServiceError instead carries
// the response verbatim: raw status, raw text, no guessing at a shape the SDK cannot know.
async function serviceErrorFrom(res) {
  let text = ""
  try { text = await res.text() } catch { /* a body-less failure still has a status worth keeping */ }
  return new ServiceError(res.status, text)
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

// `path` is legitimately multi-segment ("boxes/generate"), so it cannot be run through ONE
// `encodeURIComponent` call — that would also encode its own "/" separators into "%2F" and ask for
// a route that does not exist. Encoding PER SEGMENT means a "#" or "?" inside a single segment
// cannot start a fragment/query CLIENT-SIDE and truncate the URL — for a GET, that would silently
// drop the real query string the template literal appends after it.
function encodePathSegments(path) {
  return path.split("/").map(encodeURIComponent).join("/")
}

// ---------------------------------------------------------------------------
// The host
// ---------------------------------------------------------------------------

class Host {
  constructor(ctx) {
    // UNDERSCORED, NOT PUBLIC. The header's whole Ring-2 argument is that a bundle talks only
    // through `host`'s methods, never the transport underneath — a public `ctx` would hand back the
    // raw csrfToken and chooseFolder this module exists to wrap, and the two claims cannot both be
    // true. Still kept on `this` rather than a closure, because files/state/service all need it.
    this._ctx = ctx
    this.level = ctx.hostLevel
    this.addon = ctx.addon
    this._caps = ctx.capabilities ?? {}
    this._teardown = []
  }

  // Async because Ring 2 answers it over RPC. Returns a copy: a bundle must not be able to talk
  // itself into a capability by mutating the map.
  async capabilities() { return { ...this._caps } }

  // THE SERVER'S CAPABILITY MAP IS TOTAL: every one of its ten keys is always present with a real
  // boolean (asserted by host_test.rb), so "name in this._caps" is a meaningful, DISTINGUISHABLE
  // condition — a name absent from that total map is a typo in the bundle, or a capability this
  // host predates, never a deliberate `false`. Two different bugs get two different messages; this
  // reads the invariant rather than re-listing the map's own keys here, which would drift from it.
  _require(name) {
    if (!(name in this._caps)) {
      throw new UnsupportedCapabilityError(
        "unknown_capability",
        `"${name}" is not a capability this host's map declares at all — check the spelling, or ` +
          "this host predates a capability your bundle expects. host.capabilities() shows what it " +
          "actually has.",
      )
    }
    if (!this._caps[name]) {
      throw new UnsupportedCapabilityError(
        "unsupported_capability",
        `This host (level ${this.level}) does not support "${name}". Check host.capabilities() first.`,
      )
    }
  }

  // THE ONE PLACE THIS MODULE TALKS TO THE NETWORK. _post and every request in files/state/service
  // below all end up here — which is what makes the header's Ring-2 promise literal: swapping
  // same-origin fetch for a postMessage transport under a null-origin iframe means changing this ONE
  // function, not re-auditing every call site. A REJECTED fetch (offline, DNS failure, a dropped
  // connection) throws a bare `TypeError: Failed to fetch` today — the most actionable failure a
  // bundle can see, and the only one with no class, in a file that opens by claiming every
  // actionable failure is one. Classify it instead of letting it escape raw.
  async _fetch(url, init = {}) {
    try {
      return await fetch(url, init)
    } catch (err) {
      throw new ServiceUnavailableError("network_error", `Network request failed: ${err?.message ?? err}`)
    }
  }

  _post(url, body) {
    return this._fetch(url, { method: "POST", body, headers: { "X-CSRF-Token": this._ctx.csrfToken } })
  }

  files = {
    // Absorbs what every bundle copies today (save.js): POST, and if the host answers 409
    // would_replace, ask `onReplace` and re-send with overwrite=1. A bundle passing no onReplace
    // gets the WouldReplaceError thrown instead, which is the honest default — silently
    // overwriting is the one behaviour that must never be implicit.
    //
    // RETURNS A TAGGED OBJECT, THE SAME SHAPE EVERY TIME IT SUCCEEDS OR IS CANCELLED:
    // `{ cancelled: false, data }` on a real save, `{ cancelled: true }` on a declined replace.
    // #create redirects on success and fetch FOLLOWS a redirect, so `res.ok`/a parsed body is
    // truthy on every successful POST regardless of outcome — `if (await host.files.save(...))`
    // would report success on a save the user just cancelled. Read `.cancelled`, never the
    // returned object's mere presence.
    //
    // `folderNodeId` IS REQUIRED, NOT DEFAULTED. pickFolder (below) returns null for a cancelled
    // chooser, and null is deliberately not the same folder as "" (the library root) — defaulting a
    // null to "" is exactly how `folderNodeId: (await host.files.pickFolder())?.nodeId` would
    // silently save to the root on Esc. Pass "" explicitly when the root really is the destination.
    save: async ({ name, data = {}, folderNodeId, files: outputFiles = [], onReplace = null }) => {
      this._require("library:write")
      if (folderNodeId === null || folderNodeId === undefined) {
        throw new AddonError(
          "invalid_argument",
          'folderNodeId is required: pass "" for the library root, or a real folder id — never omit ' +
            "it, since a cancelled pickFolder() returning null must not silently become the root.",
        )
      }

      // ONE SPELLING IN THE CONTRACT, NOT TWO: JSON.stringify DROPS an object key whose value is
      // undefined, so a part with no contentType would not even reach the wire as `content_type:
      // null` — it would simply vanish, and the write would proceed with no content type at all,
      // discovered only later by a bundle staring at a file that will not preview. Loud now beats
      // silent then.
      const parts = outputFiles.map((f) => {
        if (!f.contentType) {
          throw new AddonError("invalid_argument", `File "${f.name}" has no contentType.`)
        }
        return { name: f.name, content_type: f.contentType, body: f.body }
      })

      const build = (overwrite) => {
        const body = new FormData()
        body.append("name", name)
        body.append("data", JSON.stringify(data))
        body.append("parent_node_id", folderNodeId)
        body.append("files", JSON.stringify(parts))
        if (overwrite) body.append("overwrite", "1")
        return body
      }

      const url = this._ctx.urls.save
      let res = await this._post(url, build(false))
      if (res.ok) return { cancelled: false, data: await res.json().catch(() => ({})) }

      const error = await errorFrom(res)
      if (!(error instanceof WouldReplaceError)) throw error
      if (!onReplace) throw error

      const proceed = await onReplace(error.files)
      if (!proceed) return { cancelled: true }

      res = await this._post(url, build(true))
      if (res.ok) return { cancelled: false, data: await res.json().catch(() => ({})) }
      throw await errorFrom(res)
    },

    // The host's own chooser, handed across as a function since before the SDK existed. Resolves
    // {nodeId, kind, path} or null for CANCEL — and null is deliberately NOT the same answer as the
    // library root ({nodeId: ""}); conflating them is exactly what save (above) now refuses to do by
    // treating a missing folderNodeId as an error rather than defaulting it to the root.
    pickFolder: async (options = {}) => {
      this._require("pick:folder")
      if (typeof this._ctx.chooseFolder !== "function") {
        // _require above already passed, so capabilities() says this host CAN pick a folder — a
        // missing chooseFolder here is the HOST lying about what it wired up, not the user pressing
        // Esc. Those are different failures and must not collapse into the same "return null" a
        // caller cannot tell apart from an ordinary cancel.
        throw new AddonError(
          "host_misconfigured",
          "capabilities() advertises pick:folder, but this host never provided a chooseFolder function.",
        )
      }
      return this._ctx.chooseFolder(options)
    },

    // A link to the file's DETAIL PAGE (`resources :files`'s `/files/:id`) — what every shipped
    // bundle actually wants this for today: "open what I just saved, in the library". NOT the raw
    // bytes, which live at `/files/:id/blob`. No `blobUrl` helper yet, on purpose: the read surface
    // is PR 5's, and it needs to state the SVG-forced-to-attachment caveat (§14c) properly rather
    // than have one bolted on here first.
    url: (nodeId) => `/files/${encodeURIComponent(nodeId)}`,
  }

  state = {
    list: async () => {
      this._require("state:list")
      const res = await this._fetch(this._ctx.urls.states, { headers: { Accept: "application/json" } })
      if (!res.ok) throw await errorFrom(res)
      try {
        return await res.json()
      } catch {
        // Guarded the way save's own res.json() is — a malformed body must not surface as a bare
        // SyntaxError with no status attached and no indication which request it came from.
        throw new AddonError("invalid_response", "The host returned a non-JSON states list.", null, res.status)
      }
    },
  }

  service = {
    // Returns the raw Response, not parsed data — unlike save/state.list, which are OUR endpoints
    // with a known JSON shape, a sidecar can answer SVG, 3MF or a JPEG, and the SDK has no way to
    // know which up front. Parsing is left to the caller: `.text()`, `.blob()`, `.json()` —
    // whichever fits that addon's own sidecar.
    get: async (serviceName, path, params = {}) => {
      this._require("service")
      const qs = new URLSearchParams(params).toString()
      const url = `${this._ctx.urls.service}${serviceName}/${encodePathSegments(path)}${qs ? `?${qs}` : ""}`
      const res = await this._fetch(url)
      if (!res.ok) throw await serviceErrorFrom(res)
      return res
    },

    post: async (serviceName, path, params = {}) => {
      this._require("service")
      const body = new FormData()
      Object.entries(params).forEach(([ k, v ]) => body.append(k, v))
      const res = await this._post(`${this._ctx.urls.service}${serviceName}/${encodePathSegments(path)}`, body)
      if (!res.ok) throw await serviceErrorFrom(res)
      return res
    },
  }

  // The only lifecycle event in v1. The shell calls it on disconnect so a bundle can stop timers.
  // Returns an unsubscribe function — additive, conventional, and free to add now.
  on(event, fn) {
    if (event !== "teardown") throw new AddonError("unknown_event", `Unknown event "${event}"`)
    this._teardown.push(fn)
    return () => { this._teardown = this._teardown.filter((registered) => registered !== fn) }
  }

  _fireTeardown() {
    this._teardown.forEach((fn) => { try { fn() } catch { /* one bad handler must not block the rest */ } })
    this._teardown = []
  }
}

export function initHost(ctx) {
  // Tears down any previous host FIRST — a double connect() (a Turbo re-visit, a bundle re-mounted
  // without a clean disconnect) must not orphan the prior host's _teardown handlers: with no
  // teardown, they would sit forever referencing a host nobody can reach any more, never firing.
  teardownHost()
  host = new Host(ctx)
  return host
}

export function teardownHost() {
  // UNINITIALIZED_HOST is itself a throwing Proxy, so `host._fireTeardown()` would throw if called
  // on it — compare by IDENTITY, which does not trigger the trap, before touching a property.
  if (host !== UNINITIALIZED_HOST) host._fireTeardown()
  host = UNINITIALIZED_HOST
}
