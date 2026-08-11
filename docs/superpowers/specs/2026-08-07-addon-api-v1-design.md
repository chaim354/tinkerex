# Addon/Tools API v1 — design

**Date:** 2026-08-07
**Status:** design approved, not yet implemented
**Baseline:** `main` at `de46dc2` (PR #158 merged).
**Supersedes:** `docs/plan-addon-api.md` (2026-08-03, DRAFT). That document's §3–§6 are carried
forward here with corrections; its §7 sequencing is replaced by §12 below. Its evidence base —
`docs/AUDIT-2026-08-03.md` §4.3 — still stands and is not restated.

> **What this is for.** Today an addon is authored against `test/fixtures/addons/boxes` by reading
> another bundle's source. This document is the contract that replaces that: a manifest schema, a
> host SDK, three HTTP planes, one error shape, and a written statement of what the trust boundary
> is and is not. The goal is that the *next* addon is a bundle plus a manifest and nothing else.

---

## 1. Goals and non-goals

**Goals**

1. A versioned, written contract — manifest, host API, save/state/data/error shapes — so an addon
   can be authored against a spec instead of against another addon's source.
2. A typed host SDK, so bundles stop hand-rolling `fetch` + CSRF + error parsing. That code is
   duplicated in every bundle today and each copy reads only the HTTP status.
3. Close the capability gaps the addon backlog actually demands (§2.2), including the two the
   prior plan missed: **reading a library file** and **shared structured data**.
4. An architecture path to third-party addons (Ring 2) that costs **zero changes to addon code**
   written against the SDK.

**Non-goals**

- No change to `Maker::Addons::LibraryOutput` as the one output path (§14c), the sidecar env-URL
  rule (manifests name services, never URLs — the SSRF invariant), CSP `script_src :self`, or
  publish-is-deploy via the `addons` accessory. Settled, and none of them is relitigated here.
- No marketplace or review infrastructure until a third party actually exists. The two-ring
  *boundary* is what cannot wait; the review apparatus can.
- No JS build step in the addons repo. Plain ESM + importmap pins stands.
- **No addon-initiated arbitrary `net.fetch` in v1.** A first-party addon that needs an external
  API gets a sidecar or a host proxy entry, which keeps the SSRF surface at zero. Revisit only
  with Engine ⑧ (printer handoff, part lookup), and as its own decision.

---

## 2. Where we are — verified against the tree, not the prior plan

### 2.1 What already changed since `docs/plan-addon-api.md` was written

The plan's §7 step 2 ("JSON error contract + `UnsupportedOperation` rescue") is **partly done**.
PR #132 landed three `rescue_from` arms in `Tools::AddonsController` (`UnsupportedOperation` → 422,
`FetchError` → 503, `NotFound` → 422) plus door-level filename validation and a save transaction.
Two things remain, and this spec must not re-plan the part that shipped:

- the body is **flat** — `{error: "unsupported_operation", message: "…"}` — not the nested
  `{error: {code, message, field?}}` the plan specified; and
- **no bundle reads the body.** They branch on `res.ok` and render a bare "Save failed."

Asset caching also landed (`ASSET_TTL`, `Rails.cache` write, `MAX_CACHED_ASSET_BYTES = 8_000_000`),
but as a **TTL**, not a content-addressed URL — so the stale-bundle trap is narrowed, not closed.

### 2.2 The capability classes the backlog demands

Derived from `docs/addon-backlog.md` (~48 entries), not from imagination:

| Class | Backlog demand | Today | In the prior plan? |
|---|---|---|---|
| Read a library file | G-code/DXF/STL viewers, post-CAM utilities, image prep, STL dims report | ✗ | yes |
| Binary / large output | STL, 3MF, PDF, G-code, PNG | ✗ (8 files / 4 MB, text-shaped) | yes |
| Editable saved presets | material settings, print tuning journal | partial — blob, unbounded, no update/delete | yes |
| **Inventory / projects / BOM access** | Engine ⑦, "THE MOAT": "Can I build this?", low-stock, bin finder, build report, filament decrement | **✗ — none** | **no** |
| **Shared structured data** | Machine library, Material settings, bit/tool library — the backlog's explicit second leverage axis, "shared *data* → many addons" | **✗** — `AddonState` is a per-addon blob; sharing is the `states_key` hack | **no** |
| External APIs + secrets | Octopart/LCSC, OctoPrint/Moonraker/Bambu, Printables import | ✗ | excluded deliberately |
| Long / async jobs | nesting, big renders, AI calls | ✗ — synchronous, `READ_TIMEOUT = 30` | partial (timeouts only) |
| Extend host previews | Gerber preview, G-code thumbnail (Engine ④) | ✗ — renderers are in-repo Ruby | no |

**Decisions taken on that table.** The file plane and a **shared-data plane** are in v1. Reading
existing maker models (inventory/projects/BOM) is specified as a capability name and gated behind
`host.capabilities()`, so an addon can be written for it before the host answers true — the
implementation is deliberately *not* in the v1 build. External APIs, async jobs and server-side
preview renderers are out of v1 and named in §13 so nobody re-derives whether they were forgotten.

### 2.3 The shape of the host today

- Shell: `Tools::AddonsController#show` renders a mount div carrying **nine data attributes**
  (`entry`, `save-url`, `service-url`, `states-url`, `folders`, `default-folder`,
  `default-folder-label`, `children-url`, `create-url`).
- `merged_importmap` draws the app's importmap and adds the manifest's `pins`.
- `Registry::REQUIRED = %w[key title icon description api_version entry]`, `API_VERSION = "1"`,
  `TTL = 5.minutes`. A manifest missing a required key, or declaring another `api_version`, is
  **skipped, never raised on**.
- `Maker::AddonState` — `(user, addon_key, name, data)` + ordered `Maker::AddonFile` children
  (`node_id`, `role`, `position`). `#states` lists them unbounded.
- `Maker::Addons::ServiceProxy` — `OPEN_TIMEOUT = 5`, `READ_TIMEOUT = 30`,
  `MAX_BODY_BYTES = 20_000_000`, one content-type allowlist.

---

## 3. Architecture

### 3.1 Three planes behind one SDK, one shell, one HTTP surface

| Plane | SDK surface | Backed by |
|---|---|---|
| **File** | `files.save`, `files.pickFolder`, `files.pickFile`, `files.read`, `files.url` | `LibraryOutput`, `FileLayer#read` / `Delivery`, the existing chooser |
| **Data** | `state.*`, `data.*` | `Maker::AddonState`, new `Maker::AddonRecord` |
| **Service** | `service.get`, `service.post` | `ServiceProxy`, per-service timeouts |

Plus `host.capabilities()`, `host.project.current()`, and `host.on("teardown")`.

### 3.2 `ctx` becomes one object; the nine attributes stay

The shell emits a single `data-addon-ctx-value` JSON blob (api version, host level, addon key and
version, URLs, capability map, CSRF token) which the SDK parses. **Every existing data attribute
keeps being emitted for the life of `api_version: "1"`.** That is a compatibility rule with a
mechanical reason, not politeness: publishing a bundle *is* the addon deploy and Rails is never
rebuilt (§14c), so the host can never assume bundles have moved in lockstep with it.

### 3.3 The SDK is the hinge

`@maker/addon-sdk` is a host-served ESM module, pinned into every merged importmap by the host
(one line in `merged_importmap`), so an addon gets it without declaring anything. In Ring 1 its
transport is same-origin `fetch` + CSRF — the code every bundle hand-rolls today, written once. In
Ring 2 the identical surface is implemented over `postMessage` RPC to the shell.

**Addon code is byte-identical in both rings.** That is the whole reason the SDK exists rather than
a documented `ctx` contract: it makes Ring 2 an infrastructure change instead of an ecosystem
migration.

### 3.4 `mount(el, ctx)` is unchanged

The entry contract stays. The SDK is what the entry module imports; raw `ctx` stays supported.

---

## 4. The v1 manifest

Existing keys are kept **verbatim** (`key`, `title`, `icon`, `description`, `api_version`, `entry`,
`pins`, `services`, `layout`, `states_key`) — every published manifest stays valid. All additions
are optional and degrade rather than raise, per the Registry's existing rule that one bad addon
must never take `/tools` down.

| Key | Type | Purpose |
|---|---|---|
| `version` | string | The addon's own version. Gallery display, and the cache key that closes the stale-bundle trap (today a republished bundle is distinguishable only by TTL expiry). |
| `author`, `license`, `homepage` | string | Display + audit. `license` is the §9 posture the day sources widen. |
| `min_host` | integer | Floor against `Maker::Addons::Host::LEVEL` (**the shipped constant** — an earlier draft of this document said `Maker::Addons::HOST_LEVEL`, which does not exist), which the host bumps when the SDK gains a capability. Equality on `api_version` alone cannot express "needs host ≥ X" (the VS Code `engines` lesson). A too-new addon **greys out with a reason** instead of failing at runtime. |
| `permissions` | array of `{name, reasoning}` | `library:read`, `library:write`, `state`, `project:read`, `data:read:<addon>/<collection>`, `service:<name>`. `reasoning` is mandatory for any cross-addon or read permission. |
| `collections` | hash | Addon-owned record types: `{name: {schema?, shared_read: [addon keys]}}`. See §7. |
| `shares_states_with` | array | The mutual counterpart to `states_key`. See §4.1. |
| `service_timeouts` | hash `{name: seconds}` | Per-service read-timeout ceiling, capped by `ADDON_SERVICE_MAX_TIMEOUT` (default 120). Unblocks the OpenSCAD migration: renders take up to 60 s against today's fixed 30 s. |
| `contributes` | hash | Declarative extension points read **without executing addon code**: `file_handlers` (extensions the addon can open — the file browser gains "Open in ⟨addon⟩") and `params_schema` (a saved state renders a summary without loading the bundle). |
| `integrity` | hash | Per-asset SHA-256, keyed by the asset path as the manifest names it (`{"boxes.js": "sha256-…"}`). When present the asset proxy verifies before serving and refuses a mismatch; when absent the asset serves as it does today. The manifest index is the trust root — the same posture as an importmap carrying integrity metadata, and the compensating control for bundles being remote by design. |

### 4.1 `states_key` gets its constraint now

`Registry#build` asserts `states_key == key` **unless** the target manifest names the claimant in
`shares_states_with`. Mutual declaration. The in-code comment at `registry.rb:56–65` already
specifies this fix and calls the current behaviour a deliberate trust widening; doing it while every
manifest is first-party costs one line per existing pair and closes audit §2.1.

A manifest that fails the assertion is **skipped like any other invalid manifest** — not raised on.

---

## 5. The SDK surface

```js
import { host } from "@maker/addon-sdk";

host.level                                      // integer host capability level
host.addon                                      // { key, version }
const caps = await host.capabilities();         // { "library:read": true, "maker:read": false, … }

// ---- files
await host.files.save({ name, folderNodeId, files: [{ name, blob, role }] });
const folder = await host.files.pickFolder();   // already opens at the host's default folder
const file   = await host.files.pickFile({ extensions: [".scad", ".svg"] });
const bytes  = await host.files.read(file.nodeId);      // ArrayBuffer
host.files.url(nodeId);                                  // for <img src> / a download link

// ---- state
const page = await host.state.list({ limit: 20, before: cursor });
await host.state.get(id);
await host.state.create({ name, data });
await host.state.update(id, { name, data });
await host.state.delete(id);

// ---- data (addon-owned collections)
await host.data.put("machines", "shapeoko-5", { travel: [1220, 1220, 100] });
await host.data.get("machines", "shapeoko-5");
await host.data.list("machines", { limit: 50 });
await host.data.list("machine-library/machines");        // another addon's, if granted
await host.data.delete("machines", "shapeoko-5");

// ---- misc
await host.project.current();                            // { id, name, folderNodeId } | null
const svg = await host.service.post("boxes", "generate", params, { timeout: 90 });
host.on("teardown", fn);
```

Everything is promise-based. Every server error surfaces as a typed error built from §9's contract
(`ConflictError`, `TooLargeError`, `SchemaInvalidError`, `ForbiddenCapabilityError`,
`ServiceUnavailableError`, …), so an addon can branch on the class rather than parse a string.

**`capabilities()` is how an addon written against this spec survives a host that has not shipped a
capability yet.** Addons degrade; they do not crash. This is what lets §2.2's deferred rows
(`maker:read`, async jobs) be named in the contract without being built.

---

## 6. The file plane

### 6.1 Save

- Real **multipart** file parts alongside today's JSON `files` field. `body_b64` is rejected: 33%
  overhead against a byte ceiling.
- `ADDON_SAVE_MAX_FILES` and `ADDON_SAVE_MAX_BYTES` become explicit, defaulting to today's `8` and
  `4_000_000` so **no existing bundle changes behaviour**. An operator on an S3 backend can raise
  them.
- Content type comes **from the part**, never guessed.
- Unchanged and load-bearing: `Maker::Addons::LibraryOutput` stays the one output path and the one
  legitimate direct `Storage::ChunkStore` call in the maker layer (§14c); the `port_writable?`
  branch stays inside it rather than becoming a sixth inline copy (§14d); the save still fires the
  eager intake nudge **and reads its return value** into the response (§14f — a caller must not
  merely trigger the side effect); filenames are still validated at the door via
  `Maker::MoveNode.valid_leaf_name?`, never inside an adapter.

### 6.2 Read

`GET /tools/:key/file/:node_id` streams one library file through `FileLayer#read` and `Delivery`,
gated on the manifest declaring `library:read`. The addon receives a stream; it never constructs a
path, and `Delivery`'s three mechanisms are consumed exactly as `FilesController` consumes them.

**Selection stays host-owned.** `files.pickFile` opens the existing Miller-columns chooser, so an
addon never enumerates the tree. Two consequences, both deliberate: the shell stops inflating the
user's entire folder tree into a data attribute on every load, and Ring 2 becomes possible — a
null-origin iframe cannot be handed the tree.

`folders` therefore moves behind `pickFolder`. The data attribute stays emitted per §3.2.

---

## 7. The data plane

### 7.1 The model

`Maker::AddonRecord` — `(user_id, owner_addon_key, collection, record_key, data, timestamps)`,
unique index on `(user_id, owner_addon_key, collection, record_key)`, plus a keyset index on
`(user_id, owner_addon_key, collection, updated_at, id)` for listing. Per-user, like everything
else (§8: tenant = user).

### 7.2 Ownership and sharing

- **Writes: owner only.** An addon may write only collections its own manifest declares.
- **Reads: mutual grant.** The reader declares `data:read:<owner>/<collection>` in `permissions`
  *and* the owner names the reader in that collection's `shared_read`. Same shape as
  `shares_states_with`, so the system has **one** sharing rule rather than two.
- **The name decides which.** An unprefixed collection name (`"machines"`) always means the calling
  addon's own; a prefixed one (`"machine-library/machines"`) means another addon's and is refused
  unless both halves of the grant are present. There is no ambient "current addon" ambiguity: the
  route already carries the caller's key.

### 7.3 The two costs of addon-owned data, and what pays them down

Host-owned first-class models were considered and rejected (see §14). The two real costs are
answered in the contract rather than left standing:

- **No validation** → a collection may declare a **JSON Schema** in the manifest. When present the
  host validates on write and refuses with `schema_invalid`. Opt-in, and it needs no Rails change
  per data type.
- **No referential integrity** → a record field may hold a **typed reference**, a string
  `"<type>:<id>"` drawn from a **closed, documented type set** — v1: `inventory_item`, `location`,
  `supplier`, `project`, `node`. `get`/`list` accept `expand:` and the host resolves it,
  **verifying the row belongs to the requesting user**. So a bit library points at real inventory
  items without pretending to be one. An unresolvable reference expands to `null` — a stale
  pointer must not fail the read. An unknown *type* is refused at write time (`schema_invalid`),
  because a typo that silently stores an inert string is the failure this mechanism exists to
  avoid.

### 7.4 Promotion path

If a collection later deserves to be a first-class model (a web UI, FKs, a v1 API), the migration
is: add the model, keep the collection endpoint answering from it for one `api_version`, then
retire the collection. Written down so it is a decision, not a rewrite.

### 7.5 State CRUD

`PATCH` / `DELETE /tools/:key/states/:id`, and keyset paging (`limit`, `before`) on the list, which
is unbounded today and accumulates forever. **Deleting a state releases its `AddonFile` rows and
never the library bytes** — §14c's "a migration must not delete user bytes" applies to addons too;
the files are ordinary library files the user may have renamed or attached to a project.

---

## 8. Permissions and the two rings

### 8.1 Ring 1 — what the permission check is, and what it is not

Declared permissions are displayed on the gallery card and the addon page, recorded at manifest
fetch time, and **checked server-side on every request**: the route is `/tools/:key/…`, so the host
knows which addon is claiming what and refuses an undeclared capability.

**It is a declaration-consistency check, not a security boundary — and the spec says so in those
words.** A Ring 1 bundle runs with the host session on the host origin, so nothing prevents it
calling a different addon's endpoint directly. The check catches scope drift and author mistakes;
it does not contain a hostile bundle. Stating this is the point: the failure mode this repo keeps
recording is a guard everyone believed in that never worked.

What *are* real boundaries today: the same-origin proxy (sidecars have no published port, so a
browser cannot reach them), the SSRF invariant (manifests name services, never URLs), CSP
`script_src :self`, the content-type allowlist on the proxy, and per-user scoping on every query.

### 8.2 Ring 2 — specified, deliberately unbuilt

Trigger: **the first addon whose author would not get commit access.**

- The shell mounts the addon in `<iframe sandbox="allow-scripts">` with **no** `allow-same-origin`
  → null origin: no cookies, no host DOM, no CSP inheritance problem. Assets stay same-origin
  proxied; the iframe document is host-generated boilerplate importing the bundle and the SDK's
  Ring-2 transport.
- The SDK transport becomes postMessage RPC. **Server endpoints do not change.**
- Every server call carries a **host-minted, short-lived signed token** — addon key, granted
  permission set, user, expiry — minted per shell load. Middleware enforces it independently of
  anything the iframe claims. (The same middleware retroactively hardens Ring 1 if wanted: mint the
  token into `ctx`.)
- `net:<origin>` permissions become enforceable, with the manifest's `reasoning` shown at enable
  time.
- Distribution grows the HACS-honest second ring: the operator adds a third-party source, sees
  permissions + licence + integrity status, and enables per addon.

**Cost honesty.** The iframe costs UI integration — no shared DOM or CSS with the host, so the
de-facto design system bundles lean on today becomes a published CSS file the iframe imports — and
file pickers become host-rendered overlays invoked over RPC. That price is why Ring 2 waits for a
trigger instead of shipping on principle.

---

## 9. The error contract

One shape on every 4xx/5xx JSON response across every endpoint:

```json
{ "error": { "code": "name_taken", "message": "…", "field": "files[1].name" } }
```

Closed, documented code set: `invalid_name`, `name_taken`, `not_found`, `conflict`, `too_large`,
`too_many_files`, `schema_invalid`, `forbidden_capability`, `service_timeout`,
`service_unavailable`. The SDK maps each to a typed error class.

**Compatibility:** today's flat `{error: "…", message: "…"}` keys stay emitted **alongside** the
nested object for the life of `api_version: "1"`. A published bundle reading the old shape must not
break — §3.2's rule again.

**Never a redirect to a `fetch` caller.** `fetch` follows a 302, so answering an error the way
success is answered reports "Saved." over a save that did not happen. Already fixed in
`Tools::AddonsController`; recorded here as a rule so it cannot be undone by a later refactor.

---

## 10. Compatibility rules (all three are mechanical, not courtesy)

1. Every current data attribute and every current response key stays for the life of
   `api_version: "1"`. Bundles deploy independently of Rails.
2. `mount(el, ctx)` and raw `ctx` stay supported. The SDK is **additive**.
3. Defaults preserve today's behaviour exactly (`8` files, `4_000_000` bytes, `30 s` service read
   timeout unless a manifest raises it under the env cap).

---

## 11. Testing

- **Contract tests over the HTTP surface**, run on all three `LIBRARY_BACKEND` legs, reporting
  **identical counts** (§15).
- The **hermetic fixture addon** (`test/fixtures/addons/`) grows to exercise each new capability
  through the real host pipeline — never the live `tinkerex-addons` repo, which a fresh clone does
  not have.
- **Mutation-check every guard** (§15). Specifically: revoke a `shared_read` grant and the
  cross-addon read must go **red**; break the schema check, the size caps, the integrity verify,
  the `states_key` assertion, and the permission refusal, one at a time, and confirm each reddens
  **its own** test. A guard that has never failed has not been shown to work.
- Two recorded traps carried in so they are not re-learned: a cache- or rate-limit-backed test
  against the test env's default `:null_store` fires **never** (§14e); and a traversal test that
  asserts only a 404 proves nothing unless a real file sits where the traversal would land (the
  `Source::Local` false-green).
- The SDK's transport is exercised in **system tests**, because a browser is the only place it is
  real — the same reason the CSP defects were invisible to every integration test.

---

## 12. Sequencing

One PR each, `bin/ci` green on all gates, the spec amended **in the same branch** as the change it
describes (§15's close-out rule applied to this document — a deferred doc update is how PR #135's
arc went unrecorded for a day).

**This document is a contract, not one implementation plan.** Each row below gets its own plan
before it is built; the rows are deliberately sized so that none of them is a multi-week branch.
PR 1 additionally produces `docs/addon-api-v1.md` — the author-facing normative reference extracted
from §4, §5, §9 and §10, which is what an addon author reads instead of this file.

| # | PR | Unblocks | Risk |
|---|---|---|---|
| 1 | **SHIPPED** (branch `claude/todo-list-review-6beccc`) — spec + SDK v1 over today's transport + `capabilities()` + typed errors, proved in a browser by an **SDK-only fixture bundle**; `generators`' adoption is a follow-up PR in `chaim354/tinkerex-addons` (see below) | Everything downstream; deletes per-bundle fetch code | low |
| 2 | Manifest metadata, `min_host` / `Host::LEVEL`, `states_key` constraint, permission display | Closes audit §2.1 while every manifest is first-party | low |
| 3 | Error contract completion + state CRUD + keyset paging | States stop accumulating unboundedly | low |
| 4 | Data plane — `AddonRecord`, collections, grants, JSON Schema, typed refs | Machine / Material / bit libraries; the moat becomes addressable | medium |
| 5 | File plane — multipart + binary save, gated read, `pickFile`; `folders` moves behind `pickFolder` | Real CAD/CAM addons (3MF/STL out, `.scad`/`.dxf` in) | medium |
| 6 | Per-service timeouts, `integrity`, content-hash asset URLs | Perf + the stale-bundle trap | medium |
| 7 | OpenSCAD migrates onto the generic surface; the bespoke controller retires | Retires the last hand-written addon controller | **high** — server-side param coercion moves into the sidecar |
| 8 | Ring 2 | Third-party addons | triggered, not scheduled |

**Row 1's scope correction, recorded where the wrong version was written.** This document said
*"`generators` adopts it"*. **`generators` does not live in this repo** — bundles live in
`chaim354/tinkerex-addons` and ship by republishing the accessory image (CLAUDE.md §14c), so that
adoption spans two repos and cannot land in the same PR as the SDK. What PR 1 shipped in its place is
a **second hermetic fixture** (`test/fixtures/addons/sdk-fixture/`, driven by
`test/system/addon_sdk_test.rb`) that touches the host **only** through `@maker/addon-sdk`, added
beside the existing `fixture` addon — **which deliberately stays on the raw-`ctx` path**, so both
halves of the compatibility rules in §10 are covered by something that RUNS. `generators`' migration is
a follow-up PR in the bundles repo; until it lands, **no real published bundle has been proven against
the SDK.** Narrated in `docs/STATUS.md` (2026-08-07, the host SDK).

---

## 13. Explicitly out of v1 — named so nobody re-derives whether they were forgotten

| Deferred | Why | Contract status |
|---|---|---|
| Reading maker models (inventory / projects / BOM) | Engine ⑦ is the moat, but it needs its own permission story and there is no web UI for that data yet | **Capability name reserved** (`maker:read`), answered `false` by `capabilities()` |
| Async / long-running jobs | Nesting and AI calls want submit → poll → result; nothing in the backlog's phases 1–3 needs it | Not reserved; add as `jobs:*` when a consumer exists |
| External HTTP + a secret store | Reverses the deliberate zero-SSRF stance; Engine ⑧ is phase 5 | Ring 2's `net:<origin>` is specified, unbuilt |
| Server-side preview renderers from an addon | A JS bundle cannot supply a Ruby renderer; Engine ④ addons are in-repo work | Out |
| i18n | One operator locale; manifest strings stay plain | Out |
| Marketplace / review | No third party exists | Out |

---

## 14. Decisions taken, with the argument (so they are not relitigated)

- **Addon-owned collections, not host-owned first-class models.** Host-owned `Machine` /
  `MaterialSetting` models were argued for — the backlog says the bit library *is* inventory items,
  which wants real FKs, validation, a v1 API and eventually a web UI, none of which a JSON blob
  gets. Decided the other way, deliberately: a new data type must not require a Rails change, which
  is the same reason the addon framework exists at all. §7.3's schema and typed references pay down
  the two costs, and §7.4 keeps promotion open.
- **An SDK, not just a documented `ctx`.** A documented contract would leave every bundle
  hand-rolling transport, which means Ring 2 becomes an ecosystem migration instead of an
  infrastructure change. The SDK is the only thing that makes both rings look identical to addon
  code.
- **Permissions displayed and consistency-checked in Ring 1 rather than omitted until Ring 2.**
  They are cheapest to add while every manifest is first-party, and scope drift is visible at
  publish time. §8.1's honesty about what the check is prevents it being mistaken for containment.
- **`folders` moves behind a picker.** It removes a per-load tree inflation, and an addon that
  cannot enumerate the tree is one that can later run in a null origin unchanged.

---

## 15. Invariants to record in `CLAUDE.md` §14c

Added **as each PR ships**, not as a tidy-up afterwards:

1. Every response key and data attribute is load-bearing for the life of an `api_version` —
   publishing a bundle is the deploy and Rails is never rebuilt, so the host may never assume
   bundles moved with it.
2. Ring 1 permission checks are declaration consistency, not containment. Do not describe them as a
   boundary.
3. `data:read` is a **mutual** grant (reader declares, owner lists) — the same rule as
   `shares_states_with`. One sharing rule, not two.
4. Deleting an `AddonState` releases `AddonFile` rows and never library bytes.
5. `capabilities()` is the compatibility mechanism: a capability may be named in the contract and
   answered `false`. Addons degrade; they never crash on a missing capability.
