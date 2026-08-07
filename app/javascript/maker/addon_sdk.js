// THE ADDON HOST SDK — the one thing an addon bundle should touch.
//
// WHY IT EXISTS RATHER THAN A DOCUMENTED ctx. Every bundle today hand-rolls the same fetch + CSRF +
// error handling, and each copy reads only the HTTP status, so a save that failed for a nameable
// reason reports "Save failed." More importantly: this module is the HINGE for the sandbox (Ring 2,
// spec §8.2). Today its transport is same-origin fetch; under a null-origin iframe the identical
// surface is implemented over postMessage. Addon code does not change. Talking to `ctx` directly
// forfeits that, which is why the raw values stay supported but undocumented for new bundles.
//
// `host` IS A LIVE BINDING, NOT A SINGLETON YOU CONSTRUCT. addon_controller.js calls initHost(ctx)
// BEFORE it dynamic-imports the bundle, so by the time any addon code runs the binding is set.
// Consequence worth knowing: destructuring at module top level (`const { files } = host`) captures
// null. Read through `host` at call time.

export let host = null

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
export class WouldReplaceError extends AddonError {
  get files() { return this.body?.files ?? [] }
}

// 503 — the library is unreachable (an unmounted share). Retryable.
export class ServiceUnavailableError extends AddonError {}

// The host does not have this capability at this level. Thrown by the SDK itself, before any
// request, so the failure names the capability instead of surfacing as a 404.
export class UnsupportedCapabilityError extends AddonError {}

const ERROR_CLASSES = {
  would_replace: WouldReplaceError,
  name_taken: NameTakenError,
  unsupported_operation: NameTakenError,
  fetch_error: ServiceUnavailableError,
  service_unavailable: ServiceUnavailableError,
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
  const Klass = ERROR_CLASSES[code] ?? AddonError
  return new Klass(code, message, body, res.status)
}

// ---------------------------------------------------------------------------
// The host
// ---------------------------------------------------------------------------

class Host {
  constructor(ctx) {
    this.ctx = ctx
    this.level = ctx.hostLevel
    this.addon = ctx.addon
    this._caps = ctx.capabilities ?? {}
    this._teardown = []
  }

  // Async because Ring 2 answers it over RPC. Returns a copy: a bundle must not be able to talk
  // itself into a capability by mutating the map.
  async capabilities() { return { ...this._caps } }

  _require(name) {
    if (!this._caps[name]) {
      throw new UnsupportedCapabilityError(
        "unsupported_capability",
        `This host (level ${this.level}) does not support "${name}". Check host.capabilities() first.`,
      )
    }
  }

  _post(url, body) {
    return fetch(url, { method: "POST", body, headers: { "X-CSRF-Token": this.ctx.csrfToken } })
  }

  files = {
    // Absorbs what every bundle copies today (save.js): POST, and if the host answers 409
    // would_replace, ask `onReplace` and re-send with overwrite=1. A bundle passing no onReplace
    // gets the WouldReplaceError thrown instead, which is the honest default — silently
    // overwriting is the one behaviour that must never be implicit.
    save: async ({ name, data = {}, folderNodeId = "", files = [], onReplace = null }) => {
      this._require("library:write")

      const build = (overwrite) => {
        const body = new FormData()
        body.append("name", name)
        body.append("data", JSON.stringify(data))
        body.append("parent_node_id", folderNodeId ?? "")
        body.append("files", JSON.stringify(files.map((f) => ({
          name: f.name, content_type: f.contentType, body: f.body,
        }))))
        if (overwrite) body.append("overwrite", "1")
        return body
      }

      const url = this.ctx.urls.save
      let res = await this._post(url, build(false))
      if (res.ok) return res.json().catch(() => ({}))

      const error = await errorFrom(res)
      if (!(error instanceof WouldReplaceError)) throw error
      if (!onReplace) throw error

      const proceed = await onReplace(error.files)
      if (!proceed) return { cancelled: true }

      res = await this._post(url, build(true))
      if (res.ok) return res.json().catch(() => ({}))
      throw await errorFrom(res)
    },

    // The host's own chooser, handed across as a function since before the SDK existed. Resolves
    // {nodeId, kind, path} or null for CANCEL — and null is deliberately NOT the same answer as
    // the library root ({nodeId: ""}); conflating them silently moves a save to the root on Esc.
    pickFolder: async (options = {}) => {
      this._require("pick:folder")
      if (typeof this.ctx.chooseFolder !== "function") return null
      return this.ctx.chooseFolder(options)
    },

    // A URL for an <img src> or a download link. A method rather than a documented path so the
    // route stays the host's to change without republishing every bundle.
    url: (nodeId) => `/files/${encodeURIComponent(nodeId)}`,
  }

  state = {
    list: async () => {
      this._require("state:list")
      const res = await fetch(this.ctx.urls.states, { headers: { Accept: "application/json" } })
      if (!res.ok) throw await errorFrom(res)
      return res.json()
    },
  }

  service = {
    // `${serviceUrl}${service}/${path}` — the base keeps its trailing slash for exactly this.
    get: async (service, path, params = {}) => {
      this._require("service")
      const qs = new URLSearchParams(params).toString()
      const url = `${this.ctx.urls.service}${service}/${path}${qs ? `?${qs}` : ""}`
      const res = await fetch(url)
      if (!res.ok) throw await errorFrom(res)
      return res
    },

    post: async (service, path, params = {}) => {
      this._require("service")
      const body = new FormData()
      Object.entries(params).forEach(([ k, v ]) => body.append(k, v))
      const res = await this._post(`${this.ctx.urls.service}${service}/${path}`, body)
      if (!res.ok) throw await errorFrom(res)
      return res
    },
  }

  // The only lifecycle event in v1. The shell calls it on disconnect so a bundle can stop timers.
  on(event, fn) {
    if (event !== "teardown") throw new AddonError("unknown_event", `Unknown event "${event}"`)
    this._teardown.push(fn)
  }

  _fireTeardown() {
    this._teardown.forEach((fn) => { try { fn() } catch { /* one bad handler must not block the rest */ } })
    this._teardown = []
  }
}

export function initHost(ctx) {
  host = new Host(ctx)
  return host
}

export function teardownHost() {
  host?._fireTeardown()
  host = null
}
