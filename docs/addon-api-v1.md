# The Addon API, version 1

This is the reference for **writing an addon bundle**. It describes everything the host promises to
an addon at `api_version: "1"` — the manifest it reads, the SDK your code imports, the capabilities
it advertises, and the errors it answers with.

You should not have to read another bundle's source to write one. If something here is wrong or
missing, that is a bug in this document.

---

## 1. What an addon is

An addon is two things:

1. **A manifest** — one entry in the addon source's `manifests.json`, describing the addon and
   naming its entry module.
2. **An ESM bundle** — JavaScript served from a directory named after the addon's `key`, whose
   entry module has a default export with a `mount` method.

```js
// hole-jig.js — the entry module named by the manifest
export default {
  mount(el, ctx) {
    el.innerHTML = "<p>Hello from an addon.</p>"
  },
}
```

The host renders a page at `/tools/<key>`, resolves the entry module through its own asset proxy,
imports it, and calls `mount(element, ctx)` with the element your UI owns. Your bundle is not a
Stimulus controller and must not assume the host's JS framework — the default export with `mount`
is the whole contract.

**Publishing the bundle is the deploy.** The host reads manifests from the addon source at request
time (cached briefly), so shipping a new addon, or a new version of one, needs no change to the
server and no server rebuild. There is no registration step and nothing to add to the host's
source tree.

**Layout of the addon source.** The root holds `manifests.json`; every other path is
`<key>/<asset>`:

```
manifests.json
hole-jig/
  hole-jig.js
  vendor/geometry.js
  hole-jig.css
```

Asset paths in the manifest are relative to your addon's own directory. Relative imports inside
your bundle (`import "./vendor/geometry.js"`) resolve the same way, because every asset is served
from one proxied prefix.

Assets are served with a content type derived from the file extension — `.js`, `.css`, `.json` and
`.svg` are recognised; anything else is served as `application/octet-stream`.

---

## 2. The manifest

`manifests.json` is a **JSON array** of manifest objects, one per addon.

### Required keys

Every one of these must be present and non-empty, and `api_version` must be exactly the string
`"1"`:

| Key | Type | Meaning |
|---|---|---|
| `key` | string | The addon's id. It is the URL segment (`/tools/<key>`), the asset directory name, and the default scope for saved states. |
| `title` | string | Display name in the gallery and the page heading. |
| `icon` | string | An emoji shown beside the title. |
| `description` | string | One line, shown in the gallery and under the page heading. |
| `api_version` | string | `"1"`. A manifest declaring any other value is skipped. |
| `entry` | string | Path to the entry module, relative to your addon's directory. |

A complete, minimal, working manifest:

```json
[
  {
    "key": "hole-jig",
    "title": "Hole Jig",
    "icon": "🎯",
    "description": "Generates a drilling template as an SVG.",
    "api_version": "1",
    "entry": "hole-jig.js"
  }
]
```

**A manifest that fails validation is skipped, not reported.** One bad addon must never take the
whole gallery down, so the host drops it and serves the rest. The symptom you will see is that your
addon is simply *absent* from `/tools` — no error page, no message. If your addon does not appear,
check the required keys and the exact string `"1"` first.

### Optional keys this host accepts today

| Key | Type | Meaning |
|---|---|---|
| `pins` | object | Bare-specifier → asset path. Each entry is added to the page's import map, pointing at your addon's own asset, so `import geometry from "geometry"` resolves inside your bundle. Paths are relative to your addon's directory. |
| `services` | array of strings | Sidecar services this addon may talk to through `host.service.*`. **The host will only proxy a service your manifest names** *and* for which the operator has configured a URL — both, never either. |
| `layout` | string | `"wide"` opts the page into the wide container. Any other value — including a typo — is treated exactly like the key being absent. |
| `states_key` | string | The scope your saved states are read and written under. Defaults to `key`. Setting it to another addon's key shares that addon's saved states, in both directions. |

```json
{
  "key": "hole-jig",
  "title": "Hole Jig",
  "icon": "🎯",
  "description": "Generates a drilling template as an SVG.",
  "api_version": "1",
  "entry": "hole-jig.js",
  "pins": { "geometry": "vendor/geometry.js" },
  "services": [ "boxes" ],
  "layout": "wide",
  "states_key": "hole-jig"
}
```

You do not need to pin `@maker/addon-sdk`. The host pins it for every addon page.

### Not yet accepted — coming in a later host level

The design for this API reserves the keys below. **This host does not read any of them yet.**

`version`, `author`, `license`, `homepage`, `min_host`, `permissions`, `collections`,
`contributes`, `integrity`, `service_timeouts`, `shares_states_with`.

**Unknown keys are ignored in silence.** The manifest reader takes only the keys it knows and never
complains about the rest, so writing `"min_host": 3` today produces no warning, no log line and no
refusal — it simply has no effect, and an addon that depends on one of these behaving will run
against a host that ignores it. If you write them now, write them as forward-compatible decoration
only, and gate real behaviour on `host.capabilities()` (§4) instead.

---

## 3. The SDK

```js
import { host } from "@maker/addon-sdk"
```

The specifier `@maker/addon-sdk` is pinned by the host on every addon page. Do not vendor a copy and
do not pin it yourself.

### `host` is a live binding — read through it at call time, never capture it

The host initialises `host` before it imports your bundle, so a top-level destructure **succeeds**
on first load. That is exactly what makes it dangerous: it works the first time and goes wrong
later, without an error.

```js
// WRONG — captures whichever host instance happens to be current at import time.
import { host } from "@maker/addon-sdk"
const { files } = host

export default {
  mount(el, ctx) {
    el.querySelector("button").addEventListener("click", () => files.save({ /* … */ }))
  },
}
```

```js
// RIGHT — read through `host` at call time.
import { host } from "@maker/addon-sdk"

export default {
  mount(el, ctx) {
    el.querySelector("button").addEventListener("click", () => host.files.save({ /* … */ }))
  },
}
```

**Why the first one breaks.** An ES module is evaluated **once per URL per page**: its top-level
code runs on the first mount and never again. Your addon, though, can be mounted more than once in
one page's life — a client-side navigation away and back re-mounts it, and the host builds a **new**
host object each time. The cached module's top level does not re-run, so `files` still refers to the
**previous, torn-down** host — its context, its CSRF token, its folder chooser, all belonging to a
mount that is over. Nothing throws and nothing is logged; the second visit simply misbehaves while
the first was fine.

`host` being a live binding is the fix, not a footnote: reading `host.files` at call time always
resolves to the host that is current *now*. Hold the **name**, never the value — and the same goes
for anything you reach through it.

**When you do get a loud failure.** Reading a property off `host` itself while no host is live
throws an `AddonError` with code `host_not_initialized`. Two situations reach it: no host has ever
been initialised, and — the one a bundle actually hits — a callback that outlived its mount reading
`host` after teardown. The message names which of the two it was, so a stale closure is not mistaken
for an ordering bug. This is the good outcome: capturing the value hides the same mistake, reading
the binding reports it.

One consequence worth knowing: that sentinel is still an object, so **`if (host)` is always truthy**
and is not a way to ask whether a real host is present. Use `await host.capabilities()` for that.

### `host.level`

An integer — the host's capability level. `1` today. It rises when the host gains capabilities.

```js
console.log(host.level)  // 1
```

### `host.addon`

`{ key }` — your addon's own key, as the host resolved it.

```js
host.addon.key  // "hole-jig"
```

Only `key` is present at this level.

### `host.capabilities()`

Async. Resolves to the host's capability map — see §4.

```js
const caps = await host.capabilities()
if (caps["pick:folder"]) { /* offer a "Choose folder…" button */ }
```

It returns a **copy**: mutating the object you get back changes nothing about what the host will
let you do.

### `host.files.save(options)` — capability `library:write`

Writes one or more output files into the user's library and records the save as a named state.

```js
const result = await host.files.save({
  name: "8mm jig",                       // the state's name; required
  folderNodeId: "",                      // "" is the library root; required — see below
  data: { holes: 6, spacing: 32 },       // your params, recorded on the state; optional
  files: [
    { name: "8mm-jig.svg", contentType: "image/svg+xml", body: svgText },
  ],
  onReplace: async (files) => window.confirm(
    `Replace ${files.map((f) => `${f.name} in ${f.folder}`).join(", ")}?`,
  ),
})

if (result.cancelled) {
  status.textContent = "Not saved."
} else {
  status.textContent = "Saved."
}
```

**`folderNodeId` is required and is not defaulted.** Pass `""` to mean the library root. Passing
`null` or `undefined` throws `invalid_argument` **before any request is made**. This is deliberate:
a cancelled `pickFolder()` resolves to `null`, so

```js
folderNodeId: (await host.files.pickFolder())?.nodeId   // undefined on Esc
```

would silently write the user's file to the library root every time they press Escape. Decide what
a cancel means and say so:

```js
const folder = await host.files.pickFolder()
if (!folder) return                       // the user cancelled; do nothing
await host.files.save({ name, folderNodeId: folder.nodeId, files })
```

**Each file part needs `contentType`.** A part without one throws `invalid_argument` before any
request, naming the file. Without that check the key would vanish during serialisation and the file
would be written with no content type at all — discovered days later as a file that will not
preview.

`body` is a **string**. Binary output is not available at this level (§7).

**`data` must be a JSON object.** It is your params, stored on the state and handed straight back by
`host.state.list()`. Anything that is not an object — an array, a number, a string — is **silently
replaced with `{}`**: no error, no warning, and you discover it when a saved state you try to reload
comes back empty. Wrap a bare value in an object.

**The return value is tagged, and you must read `.cancelled`.**

| Outcome | Return |
|---|---|
| Saved | `{ cancelled: false, data }` |
| The user declined a replace | `{ cancelled: true }` |

Never test the returned object for truthiness — both shapes are truthy objects, so
`if (await host.files.save(…))` reports success on a save the user just cancelled.

**`data` is `{}` today.** The save door answers a successful save with a redirect rather than a JSON
body, so there is nothing to parse yet. `result.data.node_id` is `undefined` — not because you asked
wrong, but because there is nothing there. Treat `data` as reserved.

**`onReplace` is how the 409 is answered.** If the save would replace files this addon previously
wrote, the host refuses with `would_replace` and lists them. With an `onReplace` callback, the SDK
asks it — receiving `[{ name, folder }]` — and re-sends with overwrite if it resolves truthy. With
**no** `onReplace`, the `WouldReplaceError` is thrown to you instead. Silently overwriting is never
implicit.

**Server-side limits on a save**, all answered as a refusal rather than a partial write:

- at least one file, and at most **8** per save;
- **4,000,000 bytes** total across all file bodies;
- names unique within one save;
- each name a valid single filename: non-empty, at most 255 bytes, no `/`, `\` or NUL, and not
  `.` or `..`.

**Where the file actually lands.** If the destination is a project's folder, the host may file the
output into a category subfolder, and if the user has a current project set, the outputs are
attached to it. Your addon does not need to do either.

### `host.files.pickFolder(options?)` — capability `pick:folder`

Opens the host's own folder chooser.

```js
const folder = await host.files.pickFolder()
// -> { nodeId: "…", kind: "dir", path: "/Projects/harbor" }   or   null if cancelled
```

`null` means **cancel** and is deliberately not the same answer as the library root
(`{ nodeId: "" }`). Do not collapse them.

`options` is forwarded to the chooser, which the host owns. Two keys are useful and stable: `value`
(the node id to seed the selection with) and `label` (the path text to show for it). The host
already seeds both from the user's current project folder, so calling `pickFolder()` with no
arguments is the normal case. Unrecognised options are ignored.

If the capability map says `pick:folder` is available but the host wired up no chooser, you get an
`AddonError` with code `host_misconfigured` — never a `null`, because that would be
indistinguishable from the user pressing Escape.

### `host.files.url(nodeId)`

Synchronous. Returns the path of a file's **detail page** in the library.

```js
link.href = host.files.url(nodeId)
link.textContent = "Open in the library"
```

This is not a URL for the raw bytes. There is no byte-level URL helper at this level (§7).

### `host.state.list()` — capability `state:list`

Lists this addon's saved states for the signed-in user, newest first.

```js
const states = await host.state.list()
// [
//   { id: 41, name: "8mm jig", data: { holes: 6 }, updated_at: "…",
//     files: [ { node_id: "…", role: "output" } ] },
//   …
// ]
```

`data` is whatever you passed to `save`. `files` relinks each save to the library files it produced,
so you can offer "open what I made last time". The list is scoped both to the current user and to
your addon's `states_key`; there is no way to read another user's states.

A non-JSON response raises an `AddonError` with code `invalid_response` rather than a bare
`SyntaxError`.

### `host.service.get(name, path, params?)` / `host.service.post(name, path, params?)` — capability `service`

Proxies one request to a sidecar your manifest names in `services`.

```js
const res = await host.service.post("boxes", "generate", { width: 120, height: 80 })
const svg = await res.text()
```

```js
const res  = await host.service.get("boxes", "generators", { q: "tray" })
const list = await res.json()
```

**These return the raw `Response`, not parsed data.** A sidecar can answer SVG, JSON, a 3MF or a
JPEG, and the SDK has no way to know which — so parsing is yours: `.text()`, `.json()`, `.blob()`,
whichever fits. `post` sends `params` as form data; `get` sends them as a query string.

`path` may be multi-segment (`"render/preview"`); each segment is encoded separately. Empty
segments and `.` / `..` are **rejected** with `invalid_argument` rather than normalised away, so a
mistake fails loudly instead of quietly requesting the wrong thing.

The host answers **404** if your manifest does not name the service, or if the operator has
configured no URL for it. The sidecar's URL never comes from your manifest.

One thing that only matters if you point an element's `src` straight at the proxy URL (available as
`ctx.serviceUrl` in `mount`) rather than reading through `service.get`: the host re-decides the
response's content type from a fixed list — `application/json`, `image/jpeg`, `image/png`,
`text/plain` and `model/*` are served inline; **everything else, including `image/svg+xml`, is
served as an `application/octet-stream` attachment**. Neither header affects a `fetch()` body, so a
`service.*` call is unaffected — read the SVG with `res.text()` and build a `data:` URL if you need
to display it.

### `host.on("teardown", fn)`

The only lifecycle event at this level. It fires when the host disposes of your addon — a page
navigation, a re-mount — and is where you stop timers, abort requests and remove listeners you
attached outside your own element.

```js
mount(el, ctx) {
  const timer = setInterval(poll, 5000)
  host.on("teardown", () => clearInterval(timer))
}
```

**It returns an unsubscribe function**, so a handler you only need for part of a mount's life can
remove itself:

```js
const stop = host.on("teardown", abortInFlightRequest)
// …once the request has settled and there is nothing left to abort:
stop()
```

Handlers fire once and the list is then cleared. A handler that throws does not prevent the others
from running. Any event name other than `"teardown"` throws an `AddonError` with code
`unknown_event`.

---

## 4. Capability discovery

The host publishes exactly what it can do as a map of name → boolean. It is the mechanism that lets
you write an addon against a capability the host has not shipped yet: the capability is *named*
before it is *built*, answered `false` until then, so your feature detection is written once and
lights up on its own when the host gains it.

| Capability | Today | What it gates |
|---|---|---|
| `library:write` | **true** | `host.files.save` — writing output files into the library |
| `library:read` | false | Reading the bytes of a library file |
| `state:list` | **true** | `host.state.list` — listing this addon's saved states |
| `state:crud` | false | Creating, updating and deleting states directly |
| `data` | false | Addon-owned collections (records that are not files or states) |
| `maker:read` | false | Reading maker data — inventory, projects, BOM |
| `project:current` | false | Reading the user's current project |
| `service` | **true** | `host.service.get` / `host.service.post` — the sidecar proxy |
| `pick:folder` | **true** | `host.files.pickFolder` — the host's folder chooser |
| `pick:file` | false | Picking an existing library file |

### The rule: check before you call

```js
const caps = await host.capabilities()

if (caps["pick:folder"]) {
  chooseBtn.hidden = false
  chooseBtn.addEventListener("click", async () => {
    const folder = await host.files.pickFolder()
    if (folder) setDestination(folder.nodeId, folder.path)
  })
}
```

The SDK enforces this: calling a method whose capability is false throws **before any request is
made**, so the failure names the capability instead of arriving as a confusing 404.

**Two different mistakes get two different codes**, and the difference is worth branching on:

| Code | Meaning |
|---|---|
| `unsupported_capability` | The name is in the map, answered `false`. The host knows about it and does not have it yet. Degrade. |
| `unknown_capability` | The name is not in the map at all. Either you misspelled it, or this host predates a capability your bundle expects. |

The map is **total**: every capability name is always present with a real boolean, never missing and
never null. That is what makes `"x" in caps` a meaningful question and lets the two cases above be
told apart. Test the value, not the key's presence:

```js
if (caps["maker:read"]) { showInventoryPanel() }     // false today, true later, no code change
```

---

## 5. Errors

Every failure you can act on is a **class**, so branch with `instanceof` rather than parsing a
message.

```
Error
└── AddonError            code, message, body, status
    ├── NameTakenError            the destination name is taken — terminal
    ├── WouldReplaceError         the save would replace files — answerable; .files -> [{name, folder}]
    ├── ServiceUnavailableError   the library or the network is unreachable — retry later
    ├── UnsupportedCapabilityError this host cannot do that
    └── ServiceError              a sidecar's own failure; .body is raw text
```

Every instance carries:

- `code` — a stable string (the tables below);
- `message` — human-readable;
- `body` — the parsed response body, so you can reach fields the SDK does not model yet (raw text
  for a `ServiceError`);
- `status` — the HTTP status, or `null` for a failure raised before any request.

### The distinction that matters most: 409 is a question, 422 is not

| | 409 `would_replace` | 422 `unsupported_operation` |
|---|---|---|
| Class | `WouldReplaceError` | `NameTakenError` |
| Means | "This would replace files you wrote before." | "That name is already taken in the folder you picked." |
| Retrying the same request | Succeeds, if you resend with overwrite | **Never** succeeds |
| The right UI | An **Overwrite?** prompt | An error, and a prompt to rename |

Offering an "Overwrite?" button for the 422 offers the user a choice that cannot be taken — the
retry fails identically, every time. Keep the two apart:

```js
import { host, NameTakenError, WouldReplaceError, ServiceUnavailableError } from "@maker/addon-sdk"

try {
  const result = await host.files.save({ name, folderNodeId, files })
  report(result.cancelled ? "Not saved." : "Saved.")
} catch (e) {
  if (e instanceof NameTakenError) {
    report(`${e.message} Pick a different name.`)          // no retry offered
  } else if (e instanceof WouldReplaceError) {
    report(`Would replace ${e.files.map((f) => f.name).join(", ")}.`)   // answerable
  } else if (e instanceof ServiceUnavailableError) {
    report("Couldn't reach your library. Try again in a moment.")
  } else {
    report(`Failed: ${e.code}`)
  }
}
```

Passing an `onReplace` callback to `save` handles the 409 for you; the `WouldReplaceError` is thrown
only when you did not.

### Codes the host answers

| Code | Status | Class | When |
|---|---|---|---|
| `would_replace` | 409 | `WouldReplaceError` | The save would replace files this addon wrote before. `.files` is `[{name, folder}]`. |
| `unsupported_operation` | 422 | `NameTakenError` | An output name is already taken in the folder you picked. |
| `not_found` | 422 | `AddonError` | **A missing destination folder does NOT produce this — see the warning below.** The host maps a port-level `FileLayer::NotFound` here, and 422 rather than 404 because the endpoint is fine and the request was refused; but no request shape described in this document is known to raise one today. Handle it via the `AddonError` fallback; do not build a flow around it. |
| `fetch_error` | 503 | `ServiceUnavailableError` | The library is unreachable — for example an unmounted share. Retry later; there is nothing to fix in your request. |
| `request_failed` | any | `AddonError` | The fallback when a failure response carries no code at all. A save rejected for a malformed or oversized payload answers a body-less 422 and arrives this way. |
| `name_taken` | — | `NameTakenError` | **Reserved.** The SDK already maps it, but this host does not emit it yet; today the same condition arrives as `unsupported_operation`. |
| `service_unavailable` | — | `ServiceUnavailableError` | **Reserved**, in the same way. The SDK already maps it; this host does not emit it yet — an unreachable library arrives as `fetch_error`. |

> **A save aimed at a folder that has gone SUCCEEDS, and writes to the library ROOT.** This is the
> one refusal this document previously promised and the host does not perform. `parent_node_id` is
> resolved against your own live folders, and an id that matches nothing **falls back to `nil`, which
> means the library root** — *before* any storage call, so there is nothing left to raise. The save
> then answers **302, a success**, and your file lands somewhere the user did not choose. Verified
> against a running host on both the chunk and share backends.
>
> There is no error to catch and no response field that reports it, so **an addon cannot detect this
> after the fact** — `save` has no JSON success branch to name the folder it actually used. What you
> can do is not trust a `folderNodeId` you did not just obtain: one persisted in an `AddonState` from
> an earlier session may name a folder the user has since deleted or that the library scan has
> tombstoned. Re-confirm with `files.pickFolder()` when the destination matters, and remember that
> `""` and a stale id are indistinguishable in the outcome.
>
> This is host behaviour, not SDK behaviour, and it predates the SDK — recorded here because a
> document that describes a refusal which never happens is worse than one that says nothing.

The two reserved codes are why you should **branch on the error class, not on the code string**. Each
reserved code maps to the same class as the code the host emits for that condition today
(`name_taken` and `unsupported_operation` are both `NameTakenError`; `service_unavailable` and
`fetch_error` are both `ServiceUnavailableError`), so an `instanceof` check keeps working when the
host starts emitting the newer spelling, and a `e.code === "…"` check quietly stops matching.

### Codes the SDK raises itself, before or around a request

| Code | Class | When |
|---|---|---|
| `host_not_initialized` | `AddonError` | You read `host` before the host was ready (module top-level code) or after your addon was torn down (a stale closure). The message says which. |
| `host_misconfigured` | `AddonError` | The capability map advertises `pick:folder` but the host provided no chooser. Not a user cancel. |
| `invalid_argument` | `AddonError` | A missing `folderNodeId`, a file part with no `contentType`, or an empty / `.` / `..` segment in a service path. |
| `unsupported_capability` | `UnsupportedCapabilityError` | The capability is in the map and false. |
| `unknown_capability` | `UnsupportedCapabilityError` | The capability is not in the map at all. |
| `network_error` | `ServiceUnavailableError` | The request never reached the host — offline, DNS failure, a dropped connection. Reads the same way as a 503: retry later. |
| `invalid_response` | `AddonError` | The host answered the states list with something that is not JSON. |
| `unknown_event` | `AddonError` | `host.on` was given an event name other than `"teardown"`. |

### Sidecar failures are not run through this table

A failed `host.service.get`/`post` raises a **`ServiceError`** with code `service_error`, carrying
the sidecar's **status and raw response text** verbatim.

```js
import { host, ServiceError } from "@maker/addon-sdk"

try {
  const res = await host.service.post("boxes", "generate", params)
  render(await res.text())
} catch (e) {
  if (e instanceof ServiceError) {
    report(`The generator said: ${e.body || e.message}`)   // e.body is raw text
  }
}
```

This is deliberate. A sidecar answers **prose, not codes** — a typical failure body is
`{"error": "argument --height: invalid value"}`, where `error` is a human sentence rather than a
code name. Running that through the host's code table would file the sentence under `code` and
leave `message` a generic filler, which is the opposite of useful. Sidecar responses may not be JSON
at all, so `ServiceError` keeps the response as-is and guesses at nothing.

### Two body shapes, both understood

The host answers a failure as `{ "error": "would_replace", "files": [...] }` today, and will answer
`{ "error": { "code": "would_replace", "files": [...] } }` later. **The SDK reads both**, and
`WouldReplaceError#files` finds the list under either. If you read `e.body` directly, be prepared
for both shapes — or read the typed accessors instead.

---

## 6. Compatibility

These are the promises the host keeps for the life of `api_version: "1"`. Your bundle and the host
deploy independently, so at any moment a bundle built against one may be running against a host
built against the other.

1. **`mount(el, ctx)` never changes.** The default export with a `mount` method taking an element
   and a context object is the entry contract, and it stays.

2. **The raw `ctx` values keep being passed to `mount`, and keep working.** The SDK is an addition,
   not a replacement — nothing that reads `ctx` directly has been deprecated or will stop being
   populated. Today `mount` receives:

   | Key | Value |
   |---|---|
   | `saveUrl` | The save endpoint for this addon |
   | `serviceUrl` | The sidecar proxy **base**, ending in `/`; append `<service>/<path>` |
   | `statesUrl` | The states endpoint, complete on its own |
   | `folders` | A flat `[label, nodeId]` list, for building a `<select>` |
   | `defaultFolder` | The default destination's node id, as a string |
   | `defaultFolderLabel` | That folder's path, e.g. `/Projects/harbor` |
   | `chooseFolder` | The folder chooser, as a function → `Promise<{nodeId, kind, path} \| null>` |
   | `csrfToken` | The token for a hand-rolled request |

   Prefer the SDK. It exists so a future host can move the transport underneath you — the same
   method surface, a different mechanism — without your bundle changing. Code that talks to `ctx`'s
   URLs and token directly forfeits that.

3. **The SDK is additive.** Methods and error subclasses are added; existing ones keep their
   signatures and their meanings. A `code` string, once answered, keeps meaning the same thing.

4. **`@maker/addon-sdk` never changes as a specifier**, even though the file behind it may move.
   Import it by that name; never by a path.

5. **Both error body shapes are understood** for the life of version 1, in both directions (§5).

6. **Capability names are added, never repurposed.** A name answered `false` today either becomes
   `true` or stays `false` — it will not come to mean something else. The host announces new
   capabilities by raising `host.level` and flipping the map, which is why feature detection written
   today keeps working without a version check.

---

## 7. Not in this version

Named so you do not have to work out whether they were forgotten. Each is reserved under the
capability that will announce it, so you can write the feature detection **now** and have it light
up when the host ships it — no new release of your bundle required.

| Not available | Will be announced by |
|---|---|
| Reading the bytes of a library file | `library:read` |
| Picking an existing file (`pickFile`) | `pick:file` |
| Creating, updating and deleting saved states from your bundle | `state:crud` |
| Addon-owned collections — structured records that are neither files nor states | `data` |
| Reading maker data: inventory, projects, BOM | `maker:read` |
| Reading the user's current project | `project:current` |
| Outbound HTTP to anything but a declared sidecar | Not reserved. The host makes no arbitrary outbound requests on an addon's behalf, by design; a future permission model would name specific origins. |
| Binary file output | No capability of its own — `body` becomes able to carry bytes under `library:write`, and the host's `level` rises when it does. Today `body` is a string. |

```js
// Written today, dormant today, live the day the host ships it.
const caps = await host.capabilities()
inventoryPanel.hidden = !caps["maker:read"]
```
