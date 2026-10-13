# Addon/Tools API v1 — plan

> **HISTORICAL — not re-verified.** Written before the repository split of 2026-08-20, when the
> sync engine and the Rust client still lived here (they are `chaim354/tinkerex-sync` and
> `chaim354/tinkerex-client` now). Kept for its reasoning and its measurements; it does not
> describe what this repository contains today. The current map is `docs/README.md`.


**Date:** 2026-08-03 · **Status:** DRAFT (from the 2026-08-03 audit; see
`docs/AUDIT-2026-08-03.md` §4.3/§6 for the evidence base)
**Baseline:** the runtime-bundle design
(`docs/superpowers/specs/2026-08-02-addons-runtime-bundle-design.md`) as shipped through
Phase B (PRs #116/#117/#120/#121/#124). This plan does not relitigate that design — it
formalizes the contract it created, closes the gaps an addon author hits today, and lays the
architecture for the one thing the design explicitly deferred: addons the operator did not
write.

---

## 1. Where we are, in one paragraph

An addon today is a manifest + plain-ESM bundle fetched from a static container, proxied
same-origin, mounted by `default.mount(el, ctx)`, where `ctx` is six untyped values
(`saveUrl`, `serviceUrl`, `statesUrl`, `folders`, `defaultFolder`, `csrfToken`). Saves are a
hand-rolled multipart POST; errors come back body-less; state is `AddonState#data` verbatim;
sidecars are reached through one proxy with a fixed 30 s/20 MB ceiling. The trust model is
"just me / trusted forks" and it is **load-bearing**: the bundle runs with the host session
on the host origin. Everything below sorts into (a) contract formalization that pays off now,
(b) capability gaps that block real addons now, and (c) the sandbox architecture that becomes
mandatory the day a third-party addon exists.

**Comparative anchors** (audit §4.3): delivery is already Figma-shaped (manifest + bundle
into a host page); trust is Obsidian-shaped (full trust), which Obsidian itself retreated
from in 2026. The plan therefore: keep today's model as **Ring 1 (trusted)**, specify the API
so that **Ring 2 (sandboxed iframe + postMessage RPC + scoped tokens)** can be added without
rewriting addons — the SDK is the hinge that makes both rings look identical to addon code.

---

## 2. Goals / non-goals

**Goals**
1. A written, versioned contract — manifest schema, host API, save/state/error shapes — so an
   addon can be authored against a spec instead of against `test/fixtures/addons/boxes`.
2. A typed host SDK so bundles stop hand-rolling `fetch` + CSRF + error parsing (today
   duplicated between every bundle).
3. Close the capability gaps that block real addons: binary output, reading library files as
   input, state update/delete, JSON error contract, per-service timeouts.
4. An architecture path to third-party addons (Ring 2) that requires **zero changes to addon
   code written against the SDK**.

**Non-goals**
- No change to `LibraryOutput` as the one output path (§14c), the sidecar env-URL rule
  (manifests name services, never URLs — SSRF invariant), CSP `script_src :self`, or
  publish-is-deploy via the accessory. These are settled.
- No marketplace/review infrastructure until a third party actually shows up (HACS lesson:
  the two-ring model is honest; the review apparatus can wait, the *boundary* cannot).
- No JS build step in the addons repo (design decision stands: plain ESM + pins).

---

## 3. The v1 manifest spec (formalize + extend)

Today's de-facto schema (REQUIRED: `key`, `title`, `icon`, `description`, `api_version`,
`entry`; optional: `pins`, `services`, `layout`, `states_key`) is kept verbatim — every
existing manifest stays valid. Additions, all optional, all degrade-not-500 per the
Registry's existing rule:

| Key | Type | Purpose |
|---|---|---|
| `version` | string | The addon's own version, shown in the gallery + used in cache keys (today a republished bundle is only distinguishable by TTL expiry). |
| `author`, `license`, `homepage` | string | Display + audit metadata. `license` matters for the §9 posture the day sources widen. |
| `min_host` | string | Host build/date the addon needs *within* an `api_version` generation (VS Code `engines` lesson: equality on `api_version` alone can't say "needs host ≥ X"). Host compares against a `Maker::Addons::HOST_LEVEL` integer it bumps when it adds SDK capabilities; too-new addons grey out with a reason instead of failing at runtime. |
| `permissions` | array | Declarative capability list, **enforced in Ring 2, displayed in Ring 1**: `library:write`, `library:read`, `state`, `project:read`, `service:<name>` (subsumes `services`), `net:<origin>` (each with a `reasoning` string, Figma-style — mandatory for `net:*`). Ring 1 renders them on the gallery card ("this tool can: write files, call the boxes sidecar") so the operator sees scope drift at publish time even while enforcement is trust-based. |
| `service_timeouts` | hash `{name: seconds}` | Per-service proxy read-timeout ceiling, capped by a host env maximum (`ADDON_SERVICE_MAX_TIMEOUT`, default 120). Unblocks the OpenSCAD migration (audit §2.3: proxy 30 s < sidecar render 60 s). |
| `contributes` | hash | Declarative extension points read without executing addon code: `file_handlers` (extensions the addon can open — the file browser gains "Open in <addon>"), `params_schema` (so saved states render a summary in `/tools/:key/states` without the bundle). |

**`states_key` gets its constraint now, not later.** Registry asserts
`states_key == key` **unless** the target manifest lists the claimant in a new
`shares_states_with` array (mutual declaration; `boxes`/`boxes-next` both name each other).
The in-code comment at `registry.rb:56-65` already names this fix; doing it while every
manifest is first-party costs one line per existing pair and removes a standing HIGH-if-
trust-widens finding (audit §2.1).

**Integrity pinning.** The manifest index gains optional `integrity` (SHA-256 per asset).
When present, the asset proxy verifies before serving; the index itself is the trust root
(same posture as an importmap with integrity metadata). Bundles are remote by design — this
is the compensating control MV3's "no remote code" rule points at.

---

## 4. The host SDK — the hinge of the whole plan

A single host-served ESM module, `@maker/addon-sdk` (pinned into every merged importmap
automatically, versioned by the host, ~200 lines). `mount(el, ctx)` keeps working forever;
the SDK wraps `ctx` and is the **only** thing addon code should touch:

```js
import { host } from "@maker/addon-sdk";

const caps = await host.capabilities();       // feature discovery; degrade, don't crash
await host.files.save({ name, files: [...] }); // typed; throws typed errors incl. Conflict
const states = await host.state.list({ limit: 20 });
await host.state.update(id, { name, data });
const folder = await host.files.pickFolder();  // host-owned chooser (existing filechooser)
const input  = await host.files.pickFile({ extensions: [".scad"] }); // read gated by permission
const svg    = await host.service.post("boxes", "generate", payload);
host.on("teardown", fn);                       // lifecycle the shell actually calls
```

Why this is the hinge: in Ring 1 the SDK's transport is same-origin `fetch` + CSRF (exactly
today's hand-rolled code, written once); in Ring 2 the same surface is implemented over
`postMessage` RPC to the shell. **Addon code is identical in both rings.** This is the Figma
lesson applied without paying the sandbox cost up front — and it means Ring 2 is an
infrastructure change, not an ecosystem migration (the mistake Obsidian is currently paying
for in reverse).

SDK v1 surface (each item maps to an HTTP change in §5): `capabilities()`, `files.save`,
`files.pickFolder/pickFile`, `files.url(node_id)` (replaces the hardcoded `/files/<id>`
bundles ship today), `state.list/get/create/update/delete`, `project.current()`,
`service.get/post`, `on("teardown")`. Everything promise-based; every server error surfaces
as a typed error (`ConflictError`, `TooLargeError`, `ServiceUnavailableError`, …) built from
the JSON error contract below.

---

## 5. HTTP surface changes (Ring 1, incremental, each independently shippable)

1. **JSON error contract on save** — `POST /tools/:key` answers the fetch caller with
   `{error: {code, message, field?}}` on 4xx; rescue `FileLayer::UnsupportedOperation` → 422
   `code: "name_taken"` (today an unrescued **500** on share/s3 — audit §2.2, the
   TrashController failure shape recurring). The HTML redirect stays for non-fetch fallback.
2. **Binary output** — accept real multipart file parts alongside the JSON `files` field
   (`body_b64` was considered and rejected: 33% overhead against the 4 MB ceiling). Raises
   the practical ceiling for 3MF/STL outputs; per-file and per-request caps become explicit
   (`ADDON_SAVE_MAX_BYTES`, default keeps today's 4 MB; operators with S3 backends can raise
   it). Content-type from the part, not guessed.
3. **State CRUD** — `PATCH/DELETE /tools/:key/states/:id` (update name/data; delete releases
   the `AddonFile` rows, never the library files — §14c's "a migration must not delete user
   bytes" applies to addons too). `GET states` gains `limit`/`before` cursor (today unbounded
   and accumulating forever).
4. **Read surface** — `GET /tools/:key/file/:node_id` streams a library file through the
   existing `FileLayer#read`/`Delivery` machinery, gated on the manifest declaring
   `library:read` and (Ring 1) the same session auth as everything else. This is the single
   most-blocking capability gap: an addon cannot open a `.scad`/`.svg` from the library today.
   File *selection* stays host-owned (`pickFile`), so addons never enumerate the tree — which
   also lets the shell stop inflating the user's entire folder tree into a data attribute on
   every load (`folders` moves behind `pickFolder`).
5. **Per-service timeouts** — §3's `service_timeouts`, plumbed into `ServiceProxy`.
   Prerequisite for retiring the legacy OpenSCAD controller (design spec §7 step 2, still
   unshipped; its §6 hazard — server-side param coercion moves into the sidecar — is
   unchanged by this plan).
6. **Asset caching** — assets served under a content-addressed URL
   (`/tools/:key/asset/:digest/*path`, digest from the manifest `integrity` or the accessory's
   index) with `Cache-Control: immutable`; the manifest index stays the only uncached fetch.
   Kills both the per-request re-proxying and the "stale bundle reads as my-fix-didn't-deploy"
   risk the design doc named as the most time-wasting failure.
7. **Dev loop** — `ADDON_SOURCE_PATH` mode skips the 5-minute registry cache (dev/test
   already read disk); a `bin/rails addons:refresh` task busts `CACHE_KEY` for
   staging-against-accessory work. No new endpoint (a cache-bust endpoint is an operator
   surface we don't need yet).
8. **Eager intake parity** — the addon save door calls `intake_project_folder` like the other
   three web doors, and reads the result into the flash (the §14f rule: a caller must read the
   return value, not just trigger the side effect).

Explicitly **not** in v1: addon-initiated arbitrary `net.fetch` (Ring 1 addons are
first-party; a first-party addon that needs an external API gets a sidecar or a host proxy
entry — keeps the SSRF surface at zero), webhooks/events beyond `teardown`, i18n (single
operator locale today; manifest strings stay plain).

## 6. Ring 2 — the sandbox, when it's needed

Trigger: the first addon whose author would *not* get commit access. Architecture (fully
specified so nobody re-derives it, deliberately unbuilt until triggered):

- Shell mounts the addon in an `<iframe sandbox="allow-scripts">` (**no**
  `allow-same-origin` → null origin: no cookies, no host DOM, no CSP inheritance headaches).
  Assets still same-origin-proxied; the iframe document is host-generated boilerplate that
  imports the bundle + the SDK's Ring-2 transport.
- SDK transport becomes postMessage RPC to the shell; the shell executes against the same
  HTTP surface as Ring 1 — **server endpoints don't change**.
- Every server call carries a **host-minted, short-lived signed token** (Shopify session-token
  pattern): addon key + granted permission set + user + expiry, minted per shell load. Server
  middleware enforces the manifest `permissions` list independently of anything the iframe
  claims. (This also retroactively hardens Ring 1 if we ever want it: same middleware, token
  minted into `ctx`.)
- `net:<origin>` permissions become enforceable: the host proxies and allowlists, with the
  manifest's `reasoning` string shown at install/enable time.
- Distribution grows the HACS-honest second ring: operator adds a third-party source URL,
  sees the permission list + license + integrity status, and enables per-addon. Automated
  publish-time checks (manifest lint, permission diff vs previous version, license presence —
  `test/deploy_hygiene_test.rb` generalized) come with it.

Cost honesty: the iframe boundary costs UI integration (no shared DOM/CSS with the host —
the de-facto design system bundles lean on today would need a published CSS file the iframe
imports), and file pickers become host-rendered overlays invoked over RPC. That is the real
price of third-party addons, and it is why Ring 2 waits for a trigger instead of shipping on
principle.

## 7. Sequencing

| # | Step | Unblocks | Risk |
|---|---|---|---|
| 1 | Write the spec (this doc → `docs/addon-api-v1.md` as the normative reference: manifest table, ctx, save/state/error shapes, sidecar conventions) | Everything; costs a day | none |
| 2 | JSON error contract + `UnsupportedOperation` rescue (§5.1) | Correct UX on share/s3 today | low |
| 3 | SDK v1 over today's transport + `files.url()`; generators adopts | All future addons; deletes per-bundle fetch code | low |
| 4 | `states_key` constraint + manifest metadata keys (§3) | Closes audit §2.1 while cheap | low |
| 5 | State CRUD + pagination (§5.3) | States stop accumulating unboundedly | low |
| 6 | Asset content-hash caching (§5.6) | Perf + the stale-bundle trap | medium (cache keying — the design doc's named risk #3) |
| 7 | Binary save (§5.2) + read surface (§5.4) | Real CAD addons (3MF/STL out, .scad in) | medium |
| 8 | Per-service timeouts (§5.5) → OpenSCAD migrates onto the generic surface (design spec §7.2 incl. its §6 coercion port) | Retires the last bespoke controller + the hardcoded gallery card | high (the §6 hazard) |
| 9 | Ring 2 | Third-party addons | triggered, not scheduled |

Steps 2–5 are individually small enough to be single PRs; each leaves every existing addon
working unmodified (the SDK is additive; `mount(el, ctx)` and raw `ctx` remain supported for
the life of `api_version: "1"`).
