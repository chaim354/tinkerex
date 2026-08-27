// THE ADDON HOST SDK — the one thing an addon bundle should touch.
//
// WHY IT EXISTS RATHER THAN A DOCUMENTED ctx. Every bundle today hand-rolls the same fetch + CSRF +
// error handling, and each copy reads only the HTTP status, so a save that failed for a nameable
// reason reports "Save failed." More importantly: this module is the HINGE for the sandbox (Ring 2,
// docs/superpowers/specs/2026-08-07-addon-api-v1-design.md §8.2 — NAMED rather than a bare "spec §",
// which elsewhere in the addon code means the 2026-08-02 bundle design). Today its transport is
// same-origin fetch; under a null-origin iframe the identical surface is implemented over
// postMessage. Addon code does not change. Talking to the transport
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

// THE SENTINEL a bundle sees if it reads `host` while no host is live — before any initHost() has
// run, or after teardownHost(). A BUNDLE'S OWN MODULE TOP LEVEL IS *NOT* THE BEFORE-INIT CASE, and
// an earlier draft of this comment claimed it was: connect() calls initHost(ctx) and THEN
// `await import(entry)` (addon_controller.js), so top-level code always sees a real host and a
// top-level `const { files } = host` SUCCEEDS. It is worth writing this down because the real
// hazard is the opposite one and is SILENT rather than loud: an ES module is evaluated ONCE PER URL
// PER PAGE, so on a re-mount (a Turbo navigation away and back) initHost builds a NEW Host while
// the cached module's top level does NOT re-run — that captured `files` goes on serving the
// PREVIOUS, torn-down host's _ctx, stale csrfToken and stale chooseFolder included, with nothing
// thrown and nothing logged. Reading through `host` at call time is what fixes it: the live binding
// resolves to the current instance. THIS sentinel then covers the genuinely dead read — a closure
// that outlived its mount — turning it into a named error rather than `Cannot read properties of
// null`, which names nothing. THE ONE HONEST COST: this is still an OBJECT, so `if (host)` is
// truthy whether or not a host is live — `capabilities()` is the supported way to ask "is a real
// host here", never a truthiness check on the binding itself.

// SET ONCE initHost() HAS EVER RUN, AND NEVER BACK TO false — teardownHost() puts `host` right back
// on this same Proxy, so the trap below sees ONE object for two different developers: one who read
// `host` too early (an ordering bug in connect()) and one holding a closure that outlived its mount
// (a stale reference, not an ordering bug at all — e.g. a callback captured before disconnect()).
// Wording the message for only the first case sends the second developer hunting connect() for a
// bug that is not there.
let everInitialized = false

const UNINITIALIZED_HOST = new Proxy({}, {
  get(_target, prop) {
    // Only SYMBOL-KEYED reads pass silently — console.log/util.inspect genuinely work, because they
    // probe via well-known symbols rather than guessing at string keys. String coercion gets NO such
    // pass: String(host), a template literal, and JSON.stringify(host) all probe `.toString`/
    // `.toJSON` — STRING keys — so they still throw here, same as any ordinary property read.
    if (typeof prop === "symbol") return undefined
    throw new AddonError(
      "host_not_initialized",
      everInitialized
        ? `host.${String(prop)} was read after this addon's host was torn down. A closure that ` +
            "outlived its mount is the usual cause — a listener or callback that captured host " +
            "before disconnect() ran. Read host fresh at call time instead of holding onto it."
        : `host.${String(prop)} was read before initHost() ran. addon_controller.js calls initHost(ctx) ` +
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
// serviceErrorFrom below for why it is kept OUT of the host's error table entirely. `body` here is
// RAW TEXT, not AddonError's usual "parsed payload" (see its comment above): a sidecar's failure
// response may not be JSON at all (see serviceErrorFrom's own examples), so there is nothing to
// parse and nothing gained by pretending otherwise — and no `code` worth naming beyond
// "service_error", for the same reason.
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
  //
  // not_found IS ALSO ABSENT, AND UNLIKE service_error IT IS A CODE THAT REALLY DOES ARRIVE HERE —
  // from TWO endpoints meaning TWO different things. #file answers "No such file in your library."
  // (files.read) and #create/#revisions answer "No such saved item for this addon."
  // (files.save with a stateId, state.revisions). ONE class covering both would be a class whose
  // meaning depends on which method threw, which is precisely what `instanceof` cannot express: a
  // bundle catching around a block that both reads a file and loads a history could not tell them
  // apart, while the SAME bundle already knows which call it made. So this stays a plain AddonError
  // carrying `code === "not_found"` and `status === 404`, and the call site is the disambiguator.
  //
  // §14a's rule if a caller ever genuinely must branch: the answer is a SUBCLASS — and that needs
  // the HOST to send two distinct codes first. Inventing two classes over one wire code here would
  // only move the guess into the SDK.
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
// failed" filler in `.message`, the opposite of useful. Non-JSON (or body-less) responses through
// this proxy are not hypothetical either — the service route is `via: %i[get post]` while boxes'
// /generate is POST-only, so a plain GET reaches Werkzeug's own HTML 405 page (§14c); and this
// controller's own refusals (addons_controller.rb:138, :153) answer a body-less `head :not_found`.
// errorFrom's `res.json()` would fail to parse either and DISCARD IT ENTIRELY — exactly the message
// §14c kept application/json on the proxy's content-type allowlist to preserve. ServiceError instead
// carries the response verbatim: raw status, raw text (empty if there was none), no guessing at a
// shape the SDK cannot know.
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
//
// REJECTS ".", "..", AND EMPTY SEGMENTS RATHER THAN ENCODING THEM. encodeURIComponent("..") leaves
// ".." untouched, so `service.get("boxes", "../../secret")` used to build a URL the BROWSER ITSELF
// normalizes away before the request is even sent — the traversal never reached the service route,
// so the server's own guard never got a chance to refuse it either; it misrouted silently instead of
// failing loudly. §14a's key_for and §14c's validate_asset_path! both already hold this line: REJECT
// a path, never normalize one. (An empty segment — e.g. from a leading "/" — is refused for the same
// reason: left alone it would build "boxes//generate".)
//
// Callers pass RAW segments, never pre-encoded ones: encodeURIComponent("%2E") re-escapes the "%"
// and double-encodes.
function encodePathSegments(path) {
  return path.split("/").map((segment) => {
    if (segment === "" || segment === "." || segment === "..") {
      throw new AddonError(
        "invalid_argument",
        `Invalid path segment ${JSON.stringify(segment)} in ${JSON.stringify(path)}.`,
      )
    }
    return encodeURIComponent(segment)
  }).join("/")
}

// THE SERVICE NAME SITS IN THE SAME URL, ONE SEGMENT EARLIER, AND GETS THE SAME REFUSAL. It had
// none of the above: `service.get("../../evil", "x")` built `/tools/<key>/service/../../evil/x`,
// which THE BROWSER NORMALIZES AWAY BEFORE THE REQUEST IS SENT — so `sidecar_url_for`, the server
// guard whose whole job is to refuse a service the manifest does not name, was never asked, and the
// call misrouted silently rather than failing loudly. That is verbatim the defect encodePathSegments
// exists for; leaving the first segment out of it made the invariant true of only part of one URL.
// An empty name is refused for encodePathSegments' own reason: left alone it builds a double slash.
//
// A "/" IS REJECTED OUTRIGHT RATHER THAN SPLIT INTO SEGMENTS, which is the one real design choice
// here, and it is a rejection on all three counts:
//   1. A service name is ONE segment by construction. The route is `tools/:key/service/:service/*path`
//      (`:service` is a single Rails dynamic segment) and the server matches the name VERBATIM
//      against the manifest's own `services` list (AddonsController#sidecar_url_for), so "a/b" cannot
//      name a service on any host — splitting it only defers a nameable mistake into a 404 that reads
//      as a missing or unconfigured sidecar.
//   2. Splitting would NORMALIZE a structural error into a differently-shaped URL. §14a's key_for and
//      §14c's validate_asset_path! both reject rather than normalize, for exactly this reason.
//   3. Split, the contract would be incoherent: "../.." refused while "a/b" is accepted, for a value
//      that is one segment by definition.
// Note the "/" clause is NOT what makes this safe — encodeURIComponent("/") is "%2F", so encoding
// alone already defuses it. It is what makes the SDK honest about an input it cannot serve.
//
// WHAT IS DELIBERATELY *NOT* LISTED: "\", "#", "?" and "%" need no clause, because encodeURIComponent
// escapes all four. The backslash is the one worth naming — a browser treats it as a path separator
// in a special-scheme URL, so `"..\\..\\evil"` would normalize like the slash form — but the encoding
// runs while we are still building a string, before any URL parser sees it, so "%5C" is what ships.
// A GREAT DEAL survives encodeURIComponent untouched — every alphanumeric plus `- . _ ~ ! * ' ( )`,
// so "a.b" and "..." come through verbatim; an earlier draft of this line claimed these three were
// the only survivors and that is simply false. The true claim is narrower and is the one the guard
// rests on: ".", ".." and "" are the only survivors A URL PARSER ACTS ON — the two dot-segments it
// resolves away, and the empty segment that builds a double slash — so those are exactly the clauses
// here. (The %2e spellings WHATWG also treats as dot-segments need no clause of their own: the "%"
// escapes to "%25", so "%2e%2e" ships as "%252e%252e" and is inert. Verified, not reasoned.)
//
// The type check earns its place rather than mirroring encodePathSegments (which throws a bare
// TypeError off `.split`): `encodeURIComponent(undefined)` is the STRING "undefined", so a missing
// argument would otherwise request a service literally named "undefined" and 404 for a reason that
// names nothing.
function encodeServiceName(name) {
  if (typeof name !== "string" || name === "" || name === "." || name === ".." || name.includes("/")) {
    throw new AddonError(
      "invalid_argument",
      `Invalid service name ${JSON.stringify(name)}: a service name is a single path segment — it ` +
        'cannot be empty, "." or "..", or contain "/".',
    )
  }
  return encodeURIComponent(name)
}

// A SAVED ITEM'S ID, AS THE STRING THAT WILL BE SENT — a String or an INTEGER Number and nothing
// else, mirroring the allowlist Tools::AddonsController#find_addon_state applies on the other end.
// Both spellings are ordinary: `state.list()` answers integers, while an id read out of an <input>
// or a URL is a string.
//
// THE REFUSAL EXISTS BECAUSE `String(…)` WOULD LAUNDER THE VALUE PAST THAT SERVER GUARD, and the
// server's own comment records what it costs when something does: an Array reached `find_by(id:)`
// and RESOLVED, "to whichever of the user's own boxes the database returned first — a design nobody
// named, with no error anywhere". It refuses an Array today — but only because Rack hands it one.
// `String([1, 2])` is the string "1,2", which is a perfectly good String to that allowlist and
// which ActiveRecord's integer cast turns into the FIRST id in the list — probed against real rows:
// `find_by(id: "15,16")` returned state 15. So coercing here would re-open, from the client,
// exactly the hole the server closed — silently, and on the save door it WRITES.
//
// NOT A VALIDATION OF THE STRING ITSELF, deliberately, and the server says the same: "1abc" casts
// to 1 and opens state 1. That is a bound parameter inside both the user and addon scopes, so there
// is nothing to reach and nothing to inject, and refusing it would make a hand-typed URL fail in a
// way no user could read. What is refused here is only the shape JS itself would flatten.
function stateIdString(id) {
  if (typeof id !== "string" && !Number.isInteger(id)) {
    throw new AddonError(
      "invalid_argument",
      `Invalid state id ${JSON.stringify(id)}: a state id is a string or a whole number — the id ` +
        "from state.list(), ctx.launch, or a saved item's own id.",
    )
  }
  return String(id)
}

// THE SAME ID AS A URL PATH SEGMENT, WHICH ADDS THE ENCODING RULE encodeServiceName AND
// encodePathSegments ALREADY HOLD: REJECT, NEVER NORMALIZE. `encodeURIComponent("..")` leaves ".."
// untouched, so `/tools/k/states/../revisions` is resolved by THE BROWSER'S OWN URL PARSER before
// the request is sent — the route the server guards is never asked, and the call misroutes silently
// instead of failing loudly. ".", ".." and "" are the only values that survive encodeURIComponent
// AND mean something to a URL parser — plenty of others survive it untouched ("a.b", "..."), they
// just are not dot-segments; "/", "#", "?", "%" and "\" all escape. encodeServiceName's own comment
// works through both halves of that list.
//
// An empty id is refused for the second reason too: left alone it builds ".../states//revisions".
function encodeStateId(id) {
  const s = stateIdString(id)
  if (s === "" || s === "." || s === "..") {
    throw new AddonError(
      "invalid_argument",
      `Invalid state id ${JSON.stringify(s)}: it cannot be empty, "." or "..".`,
    )
  }
  return encodeURIComponent(s)
}

// IS THIS BODY BYTES RATHER THAN TEXT? `File extends Blob`, so the first clause covers a File the
// user dropped on the page; `ArrayBuffer.isView` covers every TypedArray AND DataView in one test,
// which an `instanceof Uint8Array` chain would not (a bundle emitting a 3MF through a zip library
// is as likely to hold a `Uint8Array` as an `ArrayBuffer`, and one holding a `DataView` should not
// silently fall through to the string branch and be refused).
function isBytes(body) {
  return body instanceof Blob || body instanceof ArrayBuffer || ArrayBuffer.isView(body)
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
  //
  // AN ABORT IS THE ONE REJECTION THAT ESCAPES UNWRAPPED, AND THAT IS THE CONTRACT, NOT A GAP. When
  // the caller's own `signal` fired, the rejection is the CALLER'S OWN ACTION rather than a host
  // failure, and the two must stay distinguishable: `ServiceUnavailableError` means "retry later,
  // there is nothing to fix now", which is a lie about a request the bundle itself cancelled — it
  // would make a superseded render paint an error banner and a teardown-time abort log a fake
  // outage. So the original rejection is rethrown verbatim, which is also what every fetch-based
  // bundle already tests for (`if (e.name === "AbortError") return`).
  //
  // THE CONDITION IS `signal.aborted`, DELIBERATELY NOT `err.name === "AbortError"`. `abort(reason)`
  // makes fetch reject with THAT reason — a plain `Error("superseded")`, whose name is "Error" —
  // and a bundle that names its own abort reasons is exactly the bundle careful enough to be doing
  // this. Matching on the name would wrap those back into ServiceUnavailableError, i.e. work for
  // the simple caller and silently fail for the careful one. `AbortSignal.timeout()` (a
  // `TimeoutError`, never an `AbortError`) rides along on the same reading, correctly: the caller
  // set that deadline too.
  async _fetch(url, init = {}) {
    try {
      return await fetch(url, init)
    } catch (err) {
      if (init.signal?.aborted) throw err
      throw new ServiceUnavailableError("network_error", `Network request failed: ${err?.message ?? err}`)
    }
  }

  // `headers` MERGES OVER the CSRF token rather than replacing the object, so a caller adding a
  // Content-Type cannot drop the token by accident — the failure that would be, a 422
  // InvalidAuthenticityToken on every save, is loud but pointlessly so.
  _post(url, body, { headers = {}, signal } = {}) {
    return this._fetch(url, {
      method: "POST", body, signal,
      headers: { "X-CSRF-Token": this._ctx.csrfToken, ...headers },
    })
  }

  files = {
    // Absorbs what every bundle used to copy by hand (its own save.js, which the real bundles have
    // since dropped for this call): POST, and if the host answers 409 would_replace, ask
    // `onReplace` and re-send with overwrite=1. A bundle passing no onReplace
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
    // `data` IS STRUCTURALLY EMPTY TODAY — EXPECTED, NOT A BUG TO CHASE. #create has no JSON success
    // branch: every success exits via `redirect_to`, fetch FOLLOWS that redirect, and the response it
    // follows to is HTML — so `res.json()` always falls through to the `.catch(() => ({}))` below. A
    // bundle reading `result.data.node_id` gets `undefined` today not because it asked wrong, but
    // because there is nothing there yet: `data` stays `{}` until the save door grows a JSON branch.
    //
    // `folderNodeId` IS REQUIRED, NOT DEFAULTED. pickFolder (below) returns null for a cancelled
    // chooser, and null is deliberately not the same folder as "" (the library root) — defaulting a
    // null to "" is exactly how `folderNodeId: (await host.files.pickFolder())?.nodeId` would
    // silently save to the root on Esc. Pass "" explicitly when the root really is the destination.
    //
    // `stateId` NAMES THE SAVED ITEM THIS SAVE REVISES, and omitting it is what every bundle
    // published so far does — so a save without it sends a byte-identical request to what it always
    // has, and creates a new item. Requires host level 3; an OLDER host ignores the field entirely
    // and creates, which is why a bundle that depends on revising declares `min_host: 3` rather than
    // feature-detecting a capability. There is none, on purpose: revising is this same
    // `library:write` door growing an optional parameter, so a capability would be true for exactly
    // the hosts that answer `library:write` true and would carry no information
    // (Maker::Addons::Host::LEVEL says so at length).
    save: async ({ name, data = {}, folderNodeId, files: outputFiles = [], onReplace = null,
                   stateId = null }) => {
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
      //
      // TWO WIRE SHAPES, AND WHICH ONE A FILE TAKES IS DECIDED BY ITS BODY'S TYPE — NEVER BY ITS
      // NAME OR ITS CONTENT TYPE.
      //
      //   a string  -> stays in the JSON `files` field, byte-identical to what every bundle has
      //                always sent. This host has accepted it since v1 and keeps accepting it.
      //   bytes     -> a Blob / ArrayBuffer / TypedArray / DataView becomes a REAL multipart file
      //                part, posted as `parts[fN]`, and the JSON entry becomes `{name, part}`.
      //
      // THE RULE UNDERNEATH BOTH: A FILE'S CONTENT NEVER TRAVELS AS A BARE MULTIPART TEXT FIELD.
      // multipart/form-data serialization REWRITES EVERY TEXT ENTRY'S NEWLINES TO CRLF, inside the
      // browser, after `append` — the corruption that silently mangled a line-by-line sidecar
      // payload once already and cannot be fixed from bundle code (see service.post below). Both
      // shapes here are immune, for two different reasons that must both be understood before
      // anyone adds a third: a string inside `JSON.stringify` is ESCAPED, so a "\n" is the two
      // characters `\` and `n` on the wire and the serializer has no newline to find; and a Blob
      // is a FILE entry, which that same algorithm transmits verbatim precisely because it is not
      // text. Appending `f.body` straight onto the FormData would be neither, and would corrupt
      // every G-code, CSV, .scad and SVG an addon ever writes — silently, since the file still
      // saves and still opens.
      //
      // A BLOB IS ALWAYS RE-WRAPPED SO ITS `type` IS THE AUTHOR'S DECLARED contentType. The server
      // takes a part's content type FROM THE PART and ignores the JSON entry's, so if a bundle
      // handed us a Blob built with no type (or a different one), the declared contentType would
      // be silently discarded in favour of `application/octet-stream`. One value, one source, and
      // the source is the one the author wrote down.
      const parts = outputFiles.map((f, i) => {
        if (!f.contentType) {
          throw new AddonError("invalid_argument", `File "${f.name}" has no contentType.`)
        }
        if (isBytes(f.body)) {
          return { name: f.name, part: `f${i}`, blob: new Blob([ f.body ], { type: f.contentType }) }
        }
        if (typeof f.body !== "string") {
          throw new AddonError(
            "invalid_argument",
            `File "${f.name}" has a body that is neither a string nor binary. Pass text as a ` +
              "string, or bytes as a Blob, ArrayBuffer, TypedArray or DataView.",
          )
        }
        return { name: f.name, content_type: f.contentType, body: f.body }
      })

      // RESOLVED ONCE, OUT HERE, RATHER THAN INSIDE build() — which runs a second time for the
      // overwrite retry, so the same string is sent both times by construction.
      //
      // NOT "so an unusable id is refused before the first request", WHICH AN EARLIER DRAFT OF THIS
      // COMMENT CLAIMED AND WHICH IS FALSE. `build(false)` is evaluated as an ARGUMENT to _post
      // below, so a throw inside build precedes the request just as surely. Measured rather than
      // argued: with the validation moved inside build, the number of requests reaching #create was
      // still ZERO. There is no round trip here to save.
      //
      // `null` MEANS "CREATE" AND IS THE ONLY VALUE THAT OMITS THE FIELD. A caller passing `""` gets
      // `state_id=""` on the wire, which the door treats exactly as an absent one (`present?`) —
      // that is the compatibility promise a bundle rendering an empty hidden field depends on, and
      // it has a mutation-checked test of its own server-side. Nothing to special-case here.
      const stateIdField = stateId === null ? null : stateIdString(stateId)

      const build = (overwrite) => {
        const body = new FormData()
        body.append("name", name)
        body.append("data", JSON.stringify(data))
        body.append("parent_node_id", folderNodeId)
        if (stateIdField !== null) body.append("state_id", stateIdField)
        // THE JSON ARRAY IS THE ORDERED MANIFEST FOR BOTH SHAPES — a part entry names its part
        // rather than carrying its bytes, so there is exactly one list and one index. The server
        // pairs `files[i]` with the destination it resolved for `files[i]`; two collections with
        // an implied ordering between them is how that pairing would silently slip.
        body.append("files", JSON.stringify(parts.map(
          (p) => (p.blob ? { name: p.name, part: p.part } : p),
        )))
        // The third argument is the part's `filename=`. THE SERVER IGNORES IT — the name always
        // comes from the JSON entry, so there is only ever one source for a filename — and it is
        // sent anyway because it costs nothing and makes the request legible in devtools.
        for (const p of parts) if (p.blob) body.append(`parts[${p.part}]`, p.blob, p.name)
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

    // THE FILE-MODE SIBLING OF pickFolder, and the same cancel contract: {nodeId, kind, path}, or
    // null when the user cancelled. There is no "chose the root" answer in file mode — a directory
    // is never a valid selection — so null has exactly one meaning here.
    //
    // `options.extensions` (["\.scad", ".svg"], or "scad" — the host normalizes both spellings)
    // filters which FILES the picker offers. Folders are never filtered, or the path to a matching
    // file would be unreachable. IT IS A CONVENIENCE FOR THE HUMAN, NOT A RESTRICTION ON THE ADDON:
    // nothing stops a bundle passing any node id to `read`, so an addon that genuinely cannot
    // handle a file type must still check what it got.
    //
    // SELECTION STAYS HOST-OWNED (spec §6.2). An addon never enumerates the tree — it asks the
    // host to ask the user — which is both why there is no `files.list` and what makes Ring 2
    // possible: a null-origin iframe cannot be handed a user's folder tree.
    pickFile: async (options = {}) => {
      this._require("pick:file")
      if (typeof this._ctx.chooseFile !== "function") {
        // The pickFolder argument, one door over: _require passed, so capabilities() says this
        // host CAN pick a file — a missing chooseFile is the HOST failing to wire up what it
        // advertises, not the user pressing Esc. Returning null would make those indistinguishable.
        throw new AddonError(
          "host_misconfigured",
          "capabilities() advertises pick:file, but this host never provided a chooseFile function.",
        )
      }
      return this._ctx.chooseFile(options)
    },

    // ONE LIBRARY FILE'S BYTES, AS AN ArrayBuffer. Bytes rather than text because the host cannot
    // know the encoding and a bundle can: `new TextDecoder().decode(buf)` is one line for a .scad
    // or an SVG, while a String the SDK had already decoded for you is unrecoverable if it guessed
    // wrong. A `.dxf` in cp1252 and a `.3mf` are the same call.
    //
    // WHAT THE nodeId MAY BE: whatever pickFile handed back, or a node_id off `state.list()`'s
    // `files`. There is no way to enumerate the library and no way to reach another user's file —
    // the server scopes every lookup to the signed-in user, which is the boundary that is real
    // here (the manifest's `library:read` declaration is NOT one; see docs/addon-api-v1.md §4).
    read: async (nodeId) => {
      this._require("library:read")
      if (typeof nodeId !== "string" || nodeId === "") {
        throw new AddonError("invalid_argument", `Invalid nodeId ${JSON.stringify(nodeId)}.`)
      }
      const res = await this._fetch(`${this._ctx.urls.file}${encodeURIComponent(nodeId)}`)
      if (!res.ok) throw await errorFrom(res)
      return await res.arrayBuffer()
    },

    // A link to the file's DETAIL PAGE (`resources :files`'s `/files/:id`) — what every shipped
    // bundle actually wants this for today: "open what I just saved, in the library". NOT the raw
    // bytes, which live at `/files/:id/blob`.
    //
    // STILL NO `blobUrl`, AND NOW FOR A SETTLED REASON RATHER THAN A DEFERRED ONE. The read
    // endpoint `files.read` uses serves EVERY file as `Content-Disposition: attachment`, so a URL
    // pointing at it cannot back an `<img src>` — the browser would download rather than render.
    // A helper would exist only to be a trap. Use `read` + a Blob object URL if a preview is
    // genuinely needed, and revoke it.
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

    // ONE SAVED ITEM'S REVISION HISTORY, NEWEST FIRST — [{revision, data, created_at}].
    //
    // LAZY BY DESIGN, WHICH IS WHY IT IS A SECOND CALL RATHER THAN A KEY ON list(). `state.list()`
    // carries only each item's current `revision` NUMBER, so a gallery pays nothing for histories
    // nobody expanded; this is what a bundle calls when one is.
    //
    // `state:list` AND NOT `state:crud`. The capability names the READ side of the state surface,
    // which this is — a GET of rows the same scope already lists (Tools::AddonsController#revisions
    // resolves through the very lookup #states does). `state:crud` is still false and still reserved
    // for creating, updating and deleting states DIRECTLY (docs/addon-api-v1.md §4's capability
    // table and §7's reserved list); requiring it here would make this method throw on every host
    // there is.
    //
    // THE RESPONSE IS THE WHOLE HISTORY, UNBOUNDED, AND THE SDK DOES NOT CAP IT EITHER. The host
    // refuses to (its own #revisions comment argues it): a limit with no paging is a silent
    // truncation, and a bundle handed a history that quietly stops at N cannot tell that from a
    // design saved N times. Slicing here would reintroduce exactly that, one layer further from
    // anything able to notice.
    revisions: async (id) => {
      this._require("state:list")
      const res = await this._fetch(`${this._ctx.urls.states}/${encodeStateId(id)}/revisions`,
                                    { headers: { Accept: "application/json" } })
      if (!res.ok) throw await errorFrom(res)
      try {
        return await res.json()
      } catch {
        throw new AddonError("invalid_response", "The host returned a non-JSON revision list.",
                             null, res.status)
      }
    },
  }

  // WHICH SAVED ITEM THIS PAGE WAS OPENED FOR — `{stateId}`, resolved server-side from `?state=`,
  // with `stateId` null when there is nothing to open.
  //
  // ALWAYS AN OBJECT, NEVER undefined, AND THAT IS THE WHOLE CONTRACT. A host that predates this
  // sends no `launch` key at all, which reads as `undefined` in JS and cannot be told apart from
  // "no deep link" — the same argument Host::CAPABILITIES makes for every capability value being a
  // real boolean. Object spread ignores a nullish operand, so the one literal below covers both an
  // old host (no key) and a new one (a key whose `stateId` may be null).
  //
  // A GETTER RETURNING A FRESH OBJECT, for capabilities()'s own stated reason a few methods up:
  // `_ctx` is private by design, and handing back a live reference into it would let a bundle mutate
  // the host's own view of what it was opened for. SYNCHRONOUS, unlike capabilities(), matching
  // `level` and `addon` — like those this is a fact fixed when the page was served, not something a
  // Ring-2 host would have to answer over RPC.
  //
  // AND IT IS READ THROUGH `host` AT CALL TIME, like everything else here: a bundle that captures
  // `const { launch } = host` at module top level goes on serving the PREVIOUS mount's deep link
  // after a Turbo re-mount, because an ES module is evaluated once per URL per page (see the header).
  get launch() { return { stateId: null, ...this._ctx.launch } }

  // ONE URL BUILDER FOR ALL THREE VERBS, WHICH IS WHAT MAKES THE GUARDS UNFORGEABLE. get, post and
  // url all land here, so `encodeServiceName` and `encodePathSegments` cannot be applied to two of
  // them and forgotten on the third — and the third, `url`, is precisely the one where forgetting
  // would matter most, because it hands a raw string to an attribute the BROWSER dereferences with
  // no further checking. A builder that skipped the guards would be a traversal hole with a
  // friendly name; sharing the function means it cannot drift into one later either.
  _serviceUrl(serviceName, path, params = {}) {
    const qs = new URLSearchParams(params).toString()
    return `${this._ctx.urls.service}${encodeServiceName(serviceName)}/` +
      `${encodePathSegments(path)}${qs ? `?${qs}` : ""}`
  }

  service = {
    // Returns the raw Response, not parsed data — unlike save/state.list, which are OUR endpoints
    // with a known JSON shape, a sidecar can answer SVG, 3MF or a JPEG, and the SDK has no way to
    // know which up front. Parsing is left to the caller: `.text()`, `.blob()`, `.json()` —
    // whichever fits that addon's own sidecar.
    //
    // `options.signal` is an ordinary AbortSignal, forwarded to fetch. A long sidecar render is the
    // canonical thing a user cancels by editing a field or navigating away, and an abort surfaces
    // as the caller's OWN rejection rather than a ServiceUnavailableError — see _fetch for why the
    // two must not collapse.
    get: async (serviceName, path, params = {}, { signal } = {}) => {
      this._require("service")
      const res = await this._fetch(this._serviceUrl(serviceName, path, params), { signal })
      if (!res.ok) throw await serviceErrorFrom(res)
      return res
    },

    // A JSON BODY, NOT A FormData, AND THAT IS A BUG FIX RATHER THAN A PREFERENCE — TWO OF THEM, AND
    // THE SECOND IS SILENT.
    //
    //   1. multipart/form-data serialization NORMALIZES EVERY TEXT ENTRY'S NEWLINES TO CRLF (the
    //      HTML standard's own "multipart/form-data encoding algorithm" says so). A textarea's DOM
    //      value is always LF-clean, so a bundle that reads `textarea.value` and appends it here
    //      handed the sidecar "+-+-+-+\r\n…" without one line of bundle code doing anything wrong.
    //      A sidecar that parses line by line then silently misreads it: boxes.py's TrayLayout,
    //      whose ENTIRE input is ASCII art, rendered the wrong tray and reported no error at all.
    //      There is no bundle-side fix — the mangling happens inside the browser's multipart
    //      serializer, AFTER append — which is why the fix has to be here.
    //   2. `body.append(k, v)` STRINGIFIES a nested value to the literal "[object Object]". Every
    //      real sidecar call in the boxes bundle sends `{generator, params: {…}}`, so the nesting
    //      is not an edge case; JSON preserves it by construction.
    //
    // THE SERVER SIDE ALREADY WANTED JSON, which is what makes this a one-sided change. Rails parses
    // whatever arrives into `request.request_parameters`, and Maker::Addons::ServiceProxy re-emits
    // that hash as a JSON body — because boxes.py reads `request.get_json(force=True)` and cannot
    // read a form body at all. So the whole corruption was introduced in the browser, between
    // `append` and the wire, and undone by not going through multipart in the first place.
    post: async (serviceName, path, params = {}, { signal } = {}) => {
      this._require("service")
      const res = await this._post(this._serviceUrl(serviceName, path), JSON.stringify(params), {
        headers: { "Content-Type": "application/json" }, signal,
      })
      if (!res.ok) throw await serviceErrorFrom(res)
      return res
    },

    // A URL, AND NOTHING ELSE — SYNCHRONOUS, AND IT ISSUES NO REQUEST. For the one thing `get`
    // structurally cannot do: hand a string to an attribute the browser fetches itself. `get`
    // PERFORMS the request and resolves a Response, which cannot feed an `<img src>`, and the two
    // ways of reaching around that are both worse than the gap this closes — fetch-and-objectURL
    // defeats `loading="lazy"` across a tile grid (it downloads every tile eagerly) and needs a
    // matching revokeObjectURL per card, while hand-building the URL from `ctx.serviceUrl` is this
    // function with the guards left off.
    //
    // NOT A LOOPHOLE IN THE PROXY'S CONTENT-TYPE POLICY: the host already keeps `image/jpeg` inline
    // on its allowlist FOR THIS EXACT CALL SITE (§14c), so pointing an `<img>` at the proxy is a
    // supported path that until now had no supported way to spell. What is served inline is still
    // the host's decision, unchanged — `image/svg+xml` is still downgraded to an attachment, so an
    // `<img src>` at an SVG endpoint will not render and should still go through `get` + `res.text()`.
    //
    // REQUIRES THE CAPABILITY even though nothing is sent. A host that cannot proxy services would
    // answer this URL with a 404, and an `<img>` reports that as a bare `onerror` with no reason
    // attached — the named UnsupportedCapabilityError is strictly more diagnosable than a silently
    // broken tile.
    url: (serviceName, path, params = {}) => {
      this._require("service")
      return this._serviceUrl(serviceName, path, params)
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
  everInitialized = true
  return host
}

export function teardownHost() {
  // UNINITIALIZED_HOST is itself a throwing Proxy, so `host._fireTeardown()` would throw if called
  // on it — compare by IDENTITY, which does not trigger the trap, before touching a property.
  if (host !== UNINITIALIZED_HOST) host._fireTeardown()
  host = UNINITIALIZED_HOST
}
