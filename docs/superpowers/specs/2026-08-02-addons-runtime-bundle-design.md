# Addons as runtime-loaded bundles — design

**Date:** 2026-08-02
**Status:** design approved, not yet implemented
**Baseline:** `main` at `9b1ddb6`. Nothing from the abandoned engine-gem attempt is present here.

> **Prior attempt, abandoned.** Delivering addons as a **Rails engine gem** was designed and
> partially built before this. It cannot give the addon UI independent deploy — an engine ships
> *inside* the Rails image — which turned out to be the goal that actually mattered. Summary in
> `docs/roads-not-taken.md` §8; the built-and-abandoned host-side prep is PR #115, left open
> unmerged as reference, with its own spec and plan on branch
> `claude/tools-addons-separate-repo-d44dc8`. **Do not revive it without reading §8 first.**

---

## 1. Why

Three goals, in the order they affect the design:

1. **Independent deploy of an addon's UI** — ship an addon change without redeploying Rails.
2. **Pluggable addons** — adding one should not mean editing the server repo.
3. **Keep the main repo focused.**

**Trust model: "just me / trusted forks."** Addon authors are people who would already have commit
access. This is load-bearing: it is what makes it acceptable for an addon's JS to run on the host's
own origin with the host's session, which in turn is what removes the need for a token-scoped API
(§3.3). Under an untrusted model this design would be wrong.

### Two measurements that decided the shape

1. **The addon UI is already more client-side than server-side** — 516 lines of ERB against 683
   lines of Stimulus, and `generators` is already 100% client-side behind a generator-agnostic
   controller (`Tools::GeneratorsController`, whose own comment says adding a generator is "a JS
   module + a registry line, NO Ruby"). The rewrite is smaller than it looks, and the pattern
   already exists in-tree.
2. **Both sidecars are internal-only.** `config/deploy.yml` gives neither a `port:`; they are
   reachable only on the Kamal network as `tinkerex-boxes` / `tinkerex-openscad`. A browser cannot
   fetch anything from them. Combined with `script_src :self`, this **forces** the host to proxy
   bundles same-origin — and that constraint turns out to be the design's biggest simplification.

---

## 2. What an addon is

Two artifacts, served by a static container in the addons repo:

**A manifest:**

```json
{
  "key": "boxes",
  "title": "Box Generator",
  "icon": "📦",
  "description": "Parametric laser-cut / CNC boxes",
  "api_version": "1",
  "entry": "boxes.js",
  "pins": { "makerjs": "makerjs.js" },
  "services": ["boxes"]
}
```

**A plain-ESM bundle** (plus any modules it pins). **No JS build step.** The host has no bundler by
design — importmap + propshaft — and introducing esbuild in the addons repo would be a new
toolchain to maintain for no gain. An addon ships plain ESM; `pins` declares the importmap entries
it needs, which the host merges into its own importmap pointing at proxied asset routes. This is
how every other module in this app already loads.

**`services` names WHICH sidecars, never WHERE.** The host's own env supplies the URL, exactly as
`BOXES_SIDECAR_URL` does today. A manifest that could supply a URL would be an SSRF primitive
aimed at the internal network — see §4.1.

---

## 3. Architecture

### 3.1 The host collapses to one generic controller

`Tools::BoxesController`, `Tools::OpenscadController` and `Tools::GeneratorsController` — plus 12
views, 2 helpers, and the `BoxesClient` / `OpenscadClient` / `OpenscadParams` services — are
replaced by a single `Tools::AddonsController` with four routes:

| Route | Purpose |
|---|---|
| `GET /tools/:key` | the shell page: mounts the bundle, passes current-project folder node id, folder options and the CSRF token as data attributes |
| `GET /tools/:key/asset/*path` | proxies + caches the bundle and its pinned modules from the static container, same-origin |
| `POST /tools/:key/service/:name/*path` | proxies to the sidecar named in the manifest, URL resolved from host env |
| `POST /tools/:key/save` | `Maker::Addons::LibraryOutput.write` — already addon-agnostic |

**This collapse is the mechanism.** Rails stops needing a redeploy precisely because nothing in the
host knows anything addon-specific any more.

It also **retires the two inflector traps in `config/routes.rb` outright** rather than guarding
them. Those traps exist because the gallery resolves links via `send("tools_#{addon.key}_path")`,
so an addon key that doesn't inflect to a zero-argument helper takes `/tools` down for every user.
With one generic route there is no per-addon helper to inflect.

### 3.2 Registration is manifest-driven

`Maker::Addons::Registry` today is a frozen `REGISTRY` hash listing the three addons. It becomes a
table populated from manifests fetched from the static container and cached. (Solid Cache is wired
— §14e records that this must be confirmed by running `config.cache_store`, not by reading the
file, because it once resolved to a `FileStore` wiped every deploy.)

Two consequences:

- A republished bundle is picked up within the cache TTL, not at redeploy. **That is the
  independent deploy this design exists for.**
- **The addon host being unreachable must grey addons out, never 500.** This generalizes the
  existing `available:` lambda, which already lets an addon grey out when its sidecar is
  unconfigured — the same graceful degradation the preview renderers use.

### 3.3 No addon token, no API auth to design

Because the bundle is proxied same-origin, the addon's JS runs on the host's origin and carries the
host's ordinary session cookie. The library-write endpoint is just a session-authed Rails action.

Designing and versioning a token-scoped write-back API was the single largest cost in the
out-of-process (iframe) alternative. The internal-only sidecar topology eliminates it.

---

## 4. Security and licensing constraints

### 4.1 The manifest never supplies a URL

`services` names a service; the host's env says where it lives. A manifest-supplied URL would let
an addon — or anyone who can write to the static container — aim the host's HTTP client at
arbitrary internal addresses. The host must reject a `services` entry it has no configured URL for,
and that addon greys out.

### 4.2 CSP stays `script_src :self`

Same-origin proxying means **no CSP change at all**. This is deliberate: §14e records that a CSP
which parses is not a CSP that works, and that an empty `'nonce-'` once made Chrome discard the
whole `script-src` directive on anonymous pages. Not touching `script-src` is worth real design
effort.

### 4.3 Bundles ship from a permissive container, not the GPL sidecars

One small static container in the addons repo serves every addon's bundle; the two GPL sidecars
stay pure compute. Putting our permissively-licensed JS inside a GPL-3.0 image that we build and
push is redistribution, and while GPL-3.0's mere-aggregation clause probably covers it, "probably
covers it" is exactly the argument §9 exists to avoid. This repo already `.dockerignore`s the
sidecar tree out of the Rails image for the same reason; this keeps that line where it is.

The existing `test/deploy_hygiene_test.rb` guards — `/sidecar/` in `.dockerignore`, the OVH overlay
blanking every `*_SIDECAR_URL`, and each GPL image carrying its own licence text — all still apply
and move with the sidecars when they move.

---

## 5. What already exists and is reused

Reused unchanged, all already on `main`:

- `Maker::AddonState` / `Maker::AddonFile` + their migrations — the per-addon saved state and its
  tied output files. Already addon-agnostic; `data` is each addon's own shape.
- `Maker::Addons::LibraryOutput` — the one output path (§14c), backend-neutral on `port_writable?`,
  and the one legitimate direct `Storage::ChunkStore` call in the maker layer. Moves behind an HTTP
  endpoint; its internals do not change.
- `Tools::BaseController` (session auth) and `Tools::LibraryFolders` (`chosen_parent_node_id`,
  `folder_options`).
- `Tools::AddonParamsController` — already one route for all addons.
- `CurrentProject#current_project_folder_node_id` / `#attach_addon_files_to_current_project`.

**Deleted from the host:** the three per-addon controllers, 12 views, 2 helpers, and
`BoxesClient` / `OpenscadClient` / `OpenscadParams`.

**"Deleted" is the wrong word for one of those.** `OpenscadParams` leaves the host, but its
*behaviour must not leave the system* — it relocates into the openscad sidecar. Deleting it
outright reintroduces a silent-wrong-output bug. See §6, the most important section of this
document.

### What PR #115 built that this design does NOT take

Recorded so nobody re-derives it as a prerequisite:

- **`Tools::` namespacing of the three clients** — moot, since those clients are deleted here.
- **`Maker::Addons::SDK_VERSION` + `require_sdk!`** — a boot-time gate for a gem's engine. There is
  no engine. The concept lives on as `api_version` in the manifest, checked at registration; an
  addon declaring an unsupported version greys out rather than crashing the host, which is the
  better failure mode anyway — one bad addon should not take the app down.
- **`Registry.register` with per-addon `path:` procs** — those procs exist because each addon had
  its own route helper. One generic route removes that variation, so the proc is machinery for a
  problem this design does not have.

---

## 6. THE HAZARD: `OpenscadParams` must not become client-side

`OpenscadParams` exists because **a garbage parameter value renders successfully**. Observed
against the real sidecar, not reasoned: `{"cols": "))("}` returns 200 with the DEFAULT geometry,
because OpenSCAD's `parameterSet` silently ignores a value it cannot parse. Without server-side
refusal, a user's typo yields a default-sized model saved into their library with no feedback
anywhere.

That is **silent wrong output** — the failure mode this codebase treats as worst. Client-side
coercion is trivially bypassable and reintroduces it.

**The coercion moves into the openscad sidecar**, which already derives the schema (`schema.py`)
and is the right home for addon-specific knowledge in the addon's own deployable. That means
porting a subtle, well-tested Ruby class into Python.

This is planned work with real regression risk, not a detail:

- Its tests port with it. `test/services/tools/openscad_client_test.rb`'s coercion cases are the
  specification.
- The port must be validated against the **real** sidecar, not a fake. §14e records a case where a
  fake sharing the code's misunderstanding kept 79/80 tests green over silent data loss.
- The types are `schema.py`'s normalized set — int / float / bool / vector / enum / str — and a
  param carrying `choices` is an enum whatever its declared type says (schema.py's "TRAP 3").
  Min/max are deliberately NOT enforced; they are form hints. Preserve both decisions.

---

## 7. Migration order

The generic host surface (§3.1) lands first. Then:

| # | Addon | Why here |
|---|---|---|
| 1 | `generators` | Already 100% client-side behind a generator-agnostic controller. Smallest possible step, and it exercises the entire pipeline — manifest, pin merging, asset proxy, shell, save — with no sidecar involved. |
| 2 | `openscad` | Introduces the service proxy, and forces the §6 port. |
| 3 | `boxes` | Largest UI: 5 Stimulus controllers, collapsible sections, live preview, tray layout, top view, the sample-photo proxy, and the 3 system tests. |

Each step is independently shippable.

---

## 8. Risks

1. **~516 lines of ERB become JS rendering.** These are the forms users actually touch; regression
   risk concentrates here. Mitigated by the fact that both addons' forms are already schema-driven
   from sidecar responses, and `_field.html.erb` / `_form.html.erb` already share one shape.
2. **The 3 system tests gain a dependency on bundles being servable in CI.** A local-path bundle
   source in the test environment is the likely answer, but it needs deciding rather than
   discovering.
3. **A stale cached bundle reads as "my fix didn't deploy."** Cache keying must be content-derived,
   or invalidation explicit. This is the failure that will waste the most time if got wrong.
4. **The addon UI becomes JS-only.** Today the ERB renders the initial form without JS. Accepted:
   the app is Hotwire throughout and every addon already requires JS to function.
5. **Manifest fetch failure modes.** Down, slow, malformed, or partially-updated static container.
   The registry must degrade to "addon unavailable," never to a 500 or a half-registered addon.

---

## 9. Documentation this changes

- **`CLAUDE.md` §14c** currently says *"`Registry` declares each addon with its own `available:`
  lambda, so an addon whose backing service is unconfigured greys out rather than 500ing"* — true
  of today's frozen hash. It must be rewritten when §3.2 lands, keeping the `available:` point
  (still true) and adding that registration is manifest-driven and degrades to unavailable.
- **§14c's addon bullets** describing the `/tools` gallery and per-addon controllers need revising
  once the host collapses to one controller.
- **`docs/roads-not-taken.md` §8** already records the engine-gem approach; no further change.
- **`docs/STATUS.md`** narrates the arc as it lands, per its usual role.

---

## 10. Open questions

None blocking. One deferred:

- **Whether the static container is one per addons repo or one per addon.** One total is the
  starting assumption (fewer moving parts, and the addons repo is a single repo). Revisit only if
  addons ever come from more than one source.
