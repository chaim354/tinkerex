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
| `service_timeouts` | object | Per-service read timeout in seconds, `{ "<service>": <integer> }`. Bounded by a host maximum — see below. |
| `layout` | string | `"wide"` opts the page into the wide container. Any other value — including a typo — is treated exactly like the key being absent. |
| `states_key` | string | The scope your saved states are read and written under. Defaults to `key`. Naming **another** addon's key requires that addon's written consent — see below. |
| `shares_states_with` | array of strings | The addon keys you consent to sharing *your* saved states with. The other half of `states_key`; on its own it grants nothing. |
| `min_host` | integer | The lowest `host.level` your bundle works against. A host below it lists your addon **greyed out with a reason** rather than running it. Must be a JSON integer. |
| `permissions` | array of objects | What your addon asks for, as `{ "name": …, "reasoning": … }`. Shown to the operator. **`library:read` must be declared or `files.read` answers 403**; every other name is display only — see §4. |
| `version` | string | Your bundle's own version string. Read onto the addon, displayed nowhere yet. |
| `author` | string | Who wrote it. Read, displayed nowhere yet. |
| `license` | string | The bundle's licence. Read, displayed nowhere yet. |
| `homepage` | string | A URL for the addon. Read, displayed nowhere yet. |

The last four are parsed, carried on the addon the host builds, and **surfaced on no page today**.
Write them anyway — they cost nothing, and they are what a future gallery will render — but do not
expect to see them.

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
  "states_key": "hole-jig",
  "min_host": 1,
  "version": "1.2.0",
  "author": "Your Name",
  "license": "MIT",
  "homepage": "https://example.com/hole-jig",
  "permissions": [
    { "name": "library:write", "reasoning": "Saves the drilling template into your library." },
    { "name": "service:boxes", "reasoning": "Renders the template." }
  ]
}
```

You do not need to pin `@maker/addon-sdk`. The host pins it for every addon page.

#### `min_host` — a version floor, and a gallery decision

`min_host` is compared against `host.level` (§3). If it is **higher** than this host's level, your
addon is still built and still **listed** — greyed out, with a reason naming both numbers
("asks for level 3, this host is level 2"). It is deliberately not hidden: an addon that silently
never appears reads as a broken deploy, which sends an operator looking in the wrong place.

Two things to know before you rely on it:

- **A non-integer is ignored, not coerced.** `"min_host": "2"` — the string — is treated exactly
  like the key being absent, so the floor you thought you set **does not apply** and your addon
  stays available on a host that is too old. No warning, no log line. Write it as a bare JSON
  number.
- **Greying out is the gallery's decision, not a gate on your endpoints.** The host does not refuse
  a request because of `min_host`: navigating straight to `/tools/<key>` still renders the addon
  page, and `/tools/<key>/states` still answers. `min_host` keeps a user from *launching* your
  addon out of the gallery; it is not a runtime kill switch. Feature-detect with
  `host.capabilities()` (§4) for anything that must actually not run.

#### `permissions` — declared and displayed; exactly one is also checked

Each entry is an object with a **`name`** and an optional **`reasoning`**. The names your addon
declares are rendered on its gallery card and, with the reasoning, on its own page.

| Name | Rendered as |
|---|---|
| `library:read` | Read files from your library |
| `library:write` | Write files to your library |
| `state` | Save and reload its own settings |
| `project:read` | See which project you are working in |
| `service:<name>` | Call the `<name>` service |

> This table is a **hand-maintained copy** of `Maker::Addons::Permissions::LABELS`, and nothing keeps
> the two in sync. **The code is authoritative.** It is reproduced here because this file is the
> author-facing reference and an author cannot read the server's source — but if a name here renders
> differently than documented, believe the page. (A drifting second copy of a vocabulary is a
> failure shape this repo has recorded before; the mitigation is that these labels are **cosmetic** —
> nothing measures, gates or decides anything from them, so drift costs a wrong caption and nothing
> else.)

A name this host has never heard of is displayed **as you spelled it**, rather than being dropped —
a card that silently understates what an addon asked for would be worse than one showing a
developer-facing string.

**An entry that is not an object with a non-empty `name` is dropped, silently.** The bare-string
form — `"permissions": ["library:write"]` — is the easy mistake, and it does not error: the entry
is discarded, and a manifest whose permissions are *all* bare strings renders no permission block
at all, indistinguishable from omitting the key.

**These names are their own vocabulary and are not the capability names in §4.** They overlap
(`library:write` is in both) and they diverge on purpose: this list has `state` and `project:read`
where the capability map has `state:list`, `state:crud` and `project:current`. Declaring a
permission does not grant a capability, and a capability answered `true` does not require a
declaration.

> **`library:read` is the one name the server checks.** Without it, `host.files.read` answers 403
> `forbidden_capability` (§3). Every other name is displayed only — nothing refuses a request
> because your manifest did or did not declare it.
>
> **Even that one is declaration consistency, not containment.** Your bundle runs same-origin in the
> signed-in session and can call a *different* addon's read endpoint, whose manifest may well
> declare it. What the check buys is that an addon which starts reading the library has to say so
> where the operator sees it, in a deployment where republishing a bundle *is* the deploy and Rails
> is never rebuilt: the card is where scope drift becomes visible. The list is **not** a sandbox,
> not an allowlist, and not a thing to design a security argument around. See §4.

#### `service_timeouts` — asking for longer, within a ceiling you do not set

The host gives every sidecar call a **30-second** read timeout. That is too short for some real
renders, so a manifest can ask for more, per service:

```json
{
  "services": [ "openscad", "boxes" ],
  "service_timeouts": { "openscad": 90 }
}
```

Keyed by **service name**, not by addon: an addon with a slow sidecar and a fast one should not
give the fast one the slow one's budget. A service you do not list keeps the 30-second default.

**You are asking, not setting.** The operator's `ADDON_SERVICE_MAX_TIMEOUT` (default **120**) is the
ceiling, and a value above it is silently **clamped to the cap rather than refused** — your addon
keeps working on a deployment that lowered the ceiling, it just does not get the number it asked
for. There is no way to observe the effective value from a bundle; if a render needs more time than
the deployment allows, the call fails as an ordinary `ServiceError` when the timeout expires.

Three ways to write it that do **not** work, all silent, all leaving that service on the 30-second
default:

- **a string** — `"openscad": "90"`. Write a bare JSON number. (`min_host`'s rule, same reason:
  coercing would honour a value a JSON manifest should not contain.)
- **zero or a negative** — refused rather than honoured, because the underlying HTTP client reads a
  0-second timeout as "give up immediately", which would take the sidecar down completely instead
  of leaving it as it was.
- **a non-object** — `"service_timeouts": 90` is ignored entirely.

A malformed entry only discards **itself**; valid siblings in the same object still apply.

**Why there is a ceiling at all, since it constrains you:** the proxy is synchronous and holds one
of the host's request threads for the whole sidecar round trip. At the cap, a handful of concurrent
renders can occupy the entire pool and queue every other request behind them — including the addon
page itself. A genuinely long-running job wants an async surface, which this version does not have
(§7).

> **This is a manifest key, not a per-call option.** The design sketch for this API showed
> `host.service.post(name, path, params, { timeout: 90 })`; that is **not** implemented and is not
> the shape this shipped in. The only per-call option is `signal` (§3).

#### `states_key` and `shares_states_with` — both sides, or neither

By default your saved states live under your own `key`. `states_key` points them at a different
scope — the reason it exists is a **successor** addon (`boxes-next`) that needs to keep reading and
writing what its predecessor (`boxes`) saved.

Claiming another addon's key **requires that addon to name you back**:

```json
[
  { "key": "boxes",      "shares_states_with": [ "boxes-next" ], "…": "…" },
  { "key": "boxes-next", "states_key": "boxes",                  "…": "…" }
]
```

**If the claim is not reciprocated, your addon disappears from the gallery entirely.** Not greyed
out — absent, exactly as if a required key were missing, with only a line in the server log to say
why. Three cases all produce that same silence:

- the target addon does not name you in `shares_states_with`;
- the target addon **is not in the index at all** (a typo in the key — the permissive reading, "no
  target, no harm", would let a typo quietly reserve a namespace and start colliding the day the
  real addon shipped);
- the target addon exists but is **itself invalid** — missing a required key, or declaring an
  `api_version` this host does not speak. An entry the host rejects outright cannot confer a grant
  on its own behalf.

The check is **not recursive**, which is worth knowing so you do not chase a phantom: if the target
is a valid addon that happens to be skipped for *its own* unreciprocated `states_key`, your claim on
it still stands and your addon still appears. That is deliberate — the target consented to you in
writing, and its own separate mistake is not yours.

Setting `states_key` to your own key, or omitting it, is the ordinary case and is never checked.

Two addons that each name the other in **both** keys are both admitted, and their state namespaces
swap. That is legal and requires both authors to opt in.

**This is not a runtime boundary between addons, and it never was.** Your bundle runs same-origin in
the signed-in session and can `fetch("/tools/<other-key>/states")` directly — the host resolves
whatever key is in the URL, with no `states_key` involved. What the mutual declaration stops is
narrower and worth stating exactly: **a manifest can no longer, by declaration alone, redirect its
own saves into another addon's namespace.** The real protection on that endpoint is, and remains,
per-user scoping.

### Not yet accepted — coming in a later host level

The design for this API reserves the keys below. **This host does not read any of them yet.**

`collections`, `contributes`, `integrity`.

**Unknown keys are ignored in silence.** The manifest reader takes only the keys it knows and never
complains about the rest, so writing `"integrity": {…}` today produces no warning, no log line and
no refusal — it simply has no effect, and an addon that depends on one of these behaving will run
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

An integer — the host's capability level. **`2` today.** It rises when the host gains capabilities,
in the same change that flips them on, so `min_host` (§2) can name a floor.

| Level | Added |
|---|---|
| 1 | The SDK itself: `files.save`, `files.pickFolder`, `files.url`, `state.list`, `service.*`, `capabilities()`, `on("teardown")` |
| 2 | The file plane: binary bodies on `files.save`, `files.read`, `files.pickFile` |

```js
console.log(host.level)  // 2
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

#### `body` may be text or bytes (host level 2)

| `body` | Written as |
|---|---|
| a `string` | text, carried in the save's JSON payload |
| a `Blob` (or `File`) | bytes |
| an `ArrayBuffer` | bytes |
| a `TypedArray` (`Uint8Array`, …) or `DataView` | bytes |

```js
const zip = await make3mf()                       // a Uint8Array
await host.files.save({
  name: "bracket",
  folderNodeId: folder.nodeId,
  files: [
    { name: "bracket.3mf", contentType: "model/3mf",  body: zip },
    { name: "bracket.txt", contentType: "text/plain", body: "printed at 0.2mm\n" },
  ],
})
```

Anything else — a number, an object, `null` — throws `invalid_argument` before any request.

**Your declared `contentType` always wins.** If you pass a `Blob`, the SDK re-wraps it so the part
carries `contentType` rather than whatever `type` the Blob happened to have. There is one content
type per file and it is the one you wrote down.

**You do not choose how a file travels, and you must not try to.** Which wire shape each body takes
is the SDK's decision, and it exists to keep one rule true: **a file's content never crosses the
wire as a plain multipart text field.** Multipart serialisation rewrites every text field's
newlines to CRLF inside the browser, after the value is handed over — the defect that silently
corrupted a line-by-line sidecar payload once already (§3, `service.post`). A string body is
JSON-encoded, so its newlines are escaped and there is nothing for the serialiser to rewrite; a
binary body is a file part, which is transmitted verbatim because it is not a text field at all.
Both are safe; hand-rolling a `FormData` yourself is not. Your `\n` stays a `\n` either way, and
your bytes arrive byte for byte.

**Order is preserved across both shapes.** The files you list are written in the order you list
them, whatever each body's type, and that is the order `state.list()` reports them back in.

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

- at least one file, and at most **8** per save (`ADDON_SAVE_MAX_FILES`);
- **4,000,000 bytes** total across all file bodies (`ADDON_SAVE_MAX_BYTES`) — a *total*, not a
  per-file allowance;
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

### `host.files.pickFile(options?)` — capability `pick:file`

Opens the host's own file chooser: folders navigate, and clicking a file selects it.

```js
const file = await host.files.pickFile({ extensions: [ ".scad", ".svg" ] })
// -> { nodeId: "…", kind: "file", path: "/Projects/harbor/design/lid.scad" }   or   null if cancelled
```

`null` means **cancel**. There is no "chose the root" answer in file mode — a folder is never a
valid selection — so `null` has exactly one meaning, and conflating it with a value gives you
nothing usable.

**`extensions` is a convenience for the person picking, not a restriction on you.** Matching is
case-insensitive and a leading dot is optional (`"svg"` and `".SVG"` both work). Folders are never
filtered, or the path to a matching file would be unreachable. Nothing stops you passing any node
id to `read`, and nothing stops the user having files your addon cannot parse — **check what you
actually got.** An `extensions` value the host cannot make sense of (not an array, or an array with
nothing usable in it) filters nothing rather than everything, so a typo shows the user their files
instead of an empty picker.

**Selection is the host's, always.** There is no way to list a folder, walk the tree, or search —
by design. Your addon asks the host to ask the user. That is what keeps the whole tree out of your
bundle's reach and what will let a future host run addons in a sandboxed frame without any addon
changing.

If the capability map says `pick:file` is available but the host wired up no chooser, you get an
`AddonError` with code `host_misconfigured` — never `null`, for the same reason as `pickFolder`.

### `host.files.read(nodeId)` — capability `library:read`

Reads one library file's bytes.

```js
const buf  = await host.files.read(file.nodeId)   // an ArrayBuffer
const text = new TextDecoder().decode(buf)        // for a .scad, .dxf, .svg, G-code…
```

**Bytes, not text, and that is deliberate.** The host does not know your file's encoding and you
often do; decoding for you would be a guess you cannot undo. One line of `TextDecoder` is the whole
cost.

**Where a `nodeId` comes from:** `pickFile`, or the `files` list on a `state.list()` entry. There is
no way to enumerate the library.

**What `library:read` is, exactly.** Your manifest must declare it in `permissions` (§2) or this
endpoint answers **403 `forbidden_capability`** — and that check is a *declaration-consistency*
check, not a security boundary. It exists so that an addon which starts reading the library has to
say so on the card the operator reads at publish time; a bundle runs same-origin in the signed-in
session and can call another addon's read endpoint directly. What actually protects a user's files
is that every lookup is scoped to the signed-in user: there is no way to read another user's file,
declared or not. A node id that is not yours, and one that does not exist, both answer **404** with
the same body.

**Failures.** `not_found` (404) for a missing, deleted, foreign or non-file node;
`ServiceUnavailableError` (503) when the library itself is unreachable — retry that one, it is the
unmounted-share case and nothing is wrong with your request.

**Every file comes back as `application/octet-stream`, whatever it is.** The response's
`Content-Type` tells you nothing — do not read it. You picked the file and you know what you asked
for; if you need a typed `Blob`, say so yourself:

```js
const blob = new Blob([ await host.files.read(nodeId) ], { type: "model/3mf" })
```

That is not tidiness. Serving a `.js` file as `text/javascript` made Rails' own cross-origin-JS
guard reject the response — a `fetch` is not an XHR, so an addon reading a `.js` from the library
got a **422 HTML error page** instead of its bytes. Serving everything opaquely removes the
condition, and it also means this URL can never deliver a script-capable document in the app's
origin.

**There is no URL helper for the bytes.** The host serves this endpoint as
`Content-Disposition: attachment` unconditionally, so such a URL could not back an `<img src>`
anyway — it would download. If you need a preview, `read` it and build an object URL yourself:

```js
const url = URL.createObjectURL(new Blob([ await host.files.read(nodeId) ], { type: "image/png" }))
img.src = url
img.onload = () => URL.revokeObjectURL(url)
```

### `host.files.url(nodeId)`

Synchronous. Returns the path of a file's **detail page** in the library.

```js
link.href = host.files.url(nodeId)
link.textContent = "Open in the library"
```

This is not a URL for the raw bytes, and there is no helper that returns one — see
`host.files.read` above for why, and for what to do instead.

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

### `host.service.get(name, path, params?, options?)` / `host.service.post(name, path, params?, options?)` / `host.service.url(name, path, params?)` — capability `service`

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
whichever fits.

**`post` sends `params` as a JSON body** (`Content-Type: application/json`); `get` sends them as a
query string. Two consequences worth knowing, because both were real bugs under the form-data
transport this replaced:

- **Nested values survive.** `{ generator: "TrayLayout", params: { depth: 3 } }` arrives at your
  sidecar as that object. Form data stringified the inner object to the literal
  `"[object Object]"`.
- **Multi-line strings survive.** A `\n` stays a `\n`. Multipart serialization rewrites every text
  field's newlines to **CRLF**, so a `<textarea>` whose DOM value is LF-clean reached the sidecar
  as `"+-+-+-+\r\n…"` — which a sidecar parsing line by line misreads with no error anywhere.

Your sidecar therefore reads a JSON body. In Flask that is `request.get_json(force=True)`, which is
what `sidecar/boxes` already did — the host has always re-emitted these params as JSON, so it is
only the browser half that changed.

`path` may be multi-segment (`"render/preview"`); each segment is encoded separately. Empty
segments and `.` / `..` are **rejected** with `invalid_argument` rather than normalised away, so a
mistake fails loudly instead of quietly requesting the wrong thing.

`name` gets the same refusal, and one more: it is **a single segment**, so alongside empty, `.` and
`..` it also rejects any `/`. Both arguments land in the same URL, and a `..` in either is removed
by the browser's own URL parser *before the request is sent* — so the host never sees it, and the
call would otherwise misroute silently instead of failing.

The host answers **404** if your manifest does not name the service, or if the operator has
configured no URL for it. The sidecar's URL never comes from your manifest.

#### Cancelling a call: the `signal` option

Both take an optional fourth argument, `{ signal }` — an ordinary `AbortSignal`, forwarded to
`fetch`. A superseded render and a teardown are the two cases:

```js
let controller = null

async function render() {
  controller?.abort()                    // whatever is in flight is now stale
  controller = new AbortController()
  try {
    const res = await host.service.post("boxes", "generate", values(), { signal: controller.signal })
    draw(await res.text())
  } catch (e) {
    if (e.name === "AbortError") return  // we cancelled this ourselves; not a failure
    showError(e)
  }
}

host.on("teardown", () => controller?.abort())
```

**An abort is rethrown exactly as the platform produced it — it is deliberately *not* wrapped in a
`ServiceUnavailableError`.** That class means "retry later, there is nothing to fix now", which
would be a lie about a request your own code cancelled, and would make a cancelled render paint an
error banner. So:

| How you aborted | What you catch |
|---|---|
| `controller.abort()` | the platform's `DOMException`, `name === "AbortError"` |
| `controller.abort(reason)` | **`reason` itself**, untouched — whatever object you passed |
| `AbortSignal.timeout(ms)` expiring | the platform's `DOMException`, `name === "TimeoutError"` |
| a genuine network failure | `ServiceUnavailableError`, code `network_error` |

Branch on `e.name === "AbortError"`, or on `signal.aborted`, or on your own reason object —
whichever suits. What you must *not* do is treat `ServiceUnavailableError` as covering
cancellation; it never does.

#### `host.service.url(name, path, params?)` — a URL, no request

Synchronous. Returns the proxy URL for a sidecar endpoint **without fetching anything**, for the
one case `get` cannot serve: handing a string to an attribute the browser fetches itself.

```js
const img = document.createElement("img")
img.loading = "lazy"
img.src = host.service.url("boxes", `sample/${generator.key}`)
```

`get` performs the request and resolves a `Response`, which cannot feed an `<img src>`; fetching
and building an object URL instead would download every tile eagerly (defeating `loading="lazy"`)
and need a `revokeObjectURL` per element. This is the supported spelling.

It applies **exactly the same refusals as `get` and `post`** — same encoding, same rejection of
empty / `.` / `..` segments and of a `/` in the service name — and throws
`UnsupportedCapabilityError` if the host cannot proxy services at all, rather than handing back a
URL that would 404 as a silent broken image.

Mind the content-type rule below: this is the call site it exists for, and it is also the call site
where getting the type wrong shows up as a blank element rather than an error.

#### What the host serves inline

This only matters if the browser fetches the URL itself — via `service.url` above, or the raw
`ctx.serviceUrl` in `mount` — rather than your code reading through `service.get`. The host
re-decides the response's content type from a fixed list: `application/json`, `image/jpeg`,
`image/png`, `text/plain` and `model/*` are served inline; **everything else, including
`image/svg+xml`, is served as an `application/octet-stream` attachment**.

So an `<img src>` pointed at a JPEG endpoint works, and one pointed at an SVG endpoint does not.
Neither header affects a `fetch()` body, so a `service.get` / `service.post` call is unaffected —
read the SVG with `res.text()` and build a `data:` URL if you need to display it.

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
| `library:read` | **true** | `host.files.read` — reading the bytes of a library file |
| `state:list` | **true** | `host.state.list` — listing this addon's saved states |
| `state:crud` | false | Creating, updating and deleting states directly |
| `data` | false | Addon-owned collections (records that are not files or states) |
| `maker:read` | false | Reading maker data — inventory, projects, BOM |
| `project:current` | false | Reading the user's current project |
| `service` | **true** | `host.service.get` / `host.service.post` — the sidecar proxy |
| `pick:folder` | **true** | `host.files.pickFolder` — the host's folder chooser |
| `pick:file` | **true** | `host.files.pickFile` — the host's file chooser |

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

### Capabilities gate what you can call. Declared permissions almost never do.

These are two different things and it matters which one you are looking at:

| | The capability map (this section) | `permissions` in your manifest (§2) |
|---|---|---|
| Where it lives | The host, one definition, served to every addon | Your own manifest |
| What it does | The SDK refuses a call whose capability is `false`, before any request | Renders on your gallery card and your addon page |
| Refuses a request? | Yes — `UnsupportedCapabilityError` | **Only `library:read`** — 403 `forbidden_capability` |

**Exactly one declared permission is checked: `library:read`.** Without it in your manifest,
`GET /tools/<key>/file/<node_id>` answers 403 and `host.files.read` throws. Every other name in the
list is display only. Removing `library:write` does not stop `host.files.save` from working, and
adding `maker:read` does not make anything readable.

**Even that one is a declaration-consistency check, not a security boundary, and this document says
so in those words.** Your bundle runs same-origin in the signed-in session, so it can call any
`/tools/<key>/…` endpoint the user can — including a *different* addon's read endpoint, whose
manifest may well declare `library:read`. Nothing prevents that and nothing is claimed to. What the
check buys is that an addon which starts reading the library has to say so where the operator can
see it, which matters here because **republishing a bundle *is* the deploy** — Rails is never
rebuilt, there is no review step and no CI in between, so the gallery card is the only place scope
drift becomes visible.

Declaring the rest is still worth doing, for the same operator-facing reason.

What the list is **not**: a sandbox, an allowlist, a capability grant, or a boundary between one
addon and another. The boundaries that actually hold today are elsewhere — **per-user scoping on
every query** (the one protecting `files.read`), the same-origin sidecar proxy (a sidecar has no
published port, so a browser cannot reach it directly), the rule that a manifest names a *service*
and never a URL, `script_src 'self'`, and the content-type allowlist on the proxy. Do not build a
security argument on top of the permission list.

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
| `not_found` | 422 | `AddonError` | **A missing destination folder does NOT produce this — see the warning below.** What does: an output `name` the library cannot index — `.DS_Store`, `._x`, `__MACOSX`, `.Trashes`, or `.trash` at the library root (plus `.maker-tmp-*` on a share-backed host). Rename the output. Raised only on a share/S3-backed host; a chunk-backed host accepts those names. 422 rather than 404 because the endpoint is fine and the request was refused. |
| `fetch_error` | 503 | `ServiceUnavailableError` | The library is unreachable — for example an unmounted share. Retry later; there is nothing to fix in your request. |
| `not_found` | 404 | `AddonError` | **`files.read` only.** No such file: a node id that is not yours, one that never existed, one that has been deleted, or a folder. All four answer identically on purpose — a split would tell you which node ids are real. Note the status: this is the only place `not_found` is a 404, and the 422 row above is a different condition on a different endpoint. |
| `forbidden_capability` | 403 | `AddonError` | **`files.read` only.** Your manifest does not declare the `library:read` permission. Add it; nothing about the file changed. |
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
| `invalid_argument` | `AddonError` | A missing `folderNodeId`, a file part with no `contentType`, an empty / `.` / `..` segment in a service path, or a service **name** that is empty, `.`, `..`, or contains `/`. |
| `unsupported_capability` | `UnsupportedCapabilityError` | The capability is in the map and false. |
| `unknown_capability` | `UnsupportedCapabilityError` | The capability is not in the map at all. |
| `network_error` | `ServiceUnavailableError` | The request never reached the host — offline, DNS failure, a dropped connection. Reads the same way as a 503: retry later. |
| `invalid_response` | `AddonError` | The host answered the states list with something that is not JSON. |
| `unknown_event` | `AddonError` | `host.on` was given an event name other than `"teardown"`. |

**A cancelled request is not in this table, on purpose.** When you abort a `service.get` /
`service.post` through its `signal`, the rejection you catch is the platform's own — or your own
`abort(reason)` object — passed through with no `code` and no SDK class wrapped around it. It is
your action, not a host failure, so it is not given a failure code. See §3 for the full table of
what you catch for each way of aborting; note in particular that it is **never**
`ServiceUnavailableError`.

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
   | `chooseFile` | The file chooser, same shape; takes `{extensions}`. Added at host level 2 — feature-detect with `typeof ctx.chooseFile === "function"` if you are on the raw-`ctx` path |
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
| Creating, updating and deleting saved states from your bundle | `state:crud` |
| Addon-owned collections — structured records that are neither files nor states | `data` |
| Reading maker data: inventory, projects, BOM | `maker:read` |
| Reading the user's current project | `project:current` |
| Outbound HTTP to anything but a declared sidecar | Not reserved. The host makes no arbitrary outbound requests on an addon's behalf, by design; a future permission model would name specific origins. |
| ~~Binary file output~~ | **Shipped at host level 2.** It never got a capability of its own: it is the same `library:write` door growing a second body type, so a second name would be `true` exactly when `library:write` is and would carry no information. `min_host: 2` is how a bundle requires it. |
| Async / long-running jobs — submit, poll, collect | Not reserved. Every sidecar call is synchronous and holds a host thread for its duration, which is why `service_timeouts` (§2) has a ceiling; a job surface would be named `jobs:*` once something needs one. |

```js
// Written today, dormant today, live the day the host ships it.
const caps = await host.capabilities()
inventoryPanel.hidden = !caps["maker:read"]
```
