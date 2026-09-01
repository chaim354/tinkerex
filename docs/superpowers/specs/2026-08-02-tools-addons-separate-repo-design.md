> **HISTORICAL — RESCUED, GOAL MET DIFFERENTLY.** Recovered from the deleted branch
> `claude/tools-addons-separate-repo-d44dc8` (tip `11d0298`) on 2026-09-01. Addons DO live in
> their own repo now (`chaim354/tinkerex-addons`, shipped as a Kamal accessory — CLAUDE.md §4),
> but by a different route than this spec describes. Its companion plan is
> `../plans/2026-08-02-addon-sdk-host-prep.md`. Kept for the reasoning.

# Tools & addons in their own repo — design

**Date:** 2026-08-02
**Status:** design approved, not yet implemented
**Scope:** extract the three `/tools` addons + both GPL sidecars into a `maker-addons` repo,
delivered to the host as a non-isolated Rails engine gem.

---

## 1. Why

Three goals, stated by the owner, in priority order as they affect the design:

1. **Pluggable addons** — adding an addon should not mean editing the server repo.
2. **Keep the main repo focused** — addons are a distinct concern that costs every agent
   session and every review.
3. **Independent release cadence** — ship addon changes without redeploying the server.

**Trust model: "just me / trusted forks."** Addon authors are people who would already have
commit access. This is the single most load-bearing input to the design: it removes
sandboxing, a token-scoped public API, and out-of-process isolation from consideration, and
makes an in-process engine gem the cheapest thing that delivers goal 1.

**Honest scoring of the chosen approach against those goals:**

| Goal | Delivered? | Note |
|---|---|---|
| Pluggable | ✅ | gem line + self-registration; no host edit |
| Repo focus | ✅ | ~1,360 LOC Ruby/ERB + ~567 LOC JS + 276K sidecars leave; ~231 LOC of platform stays |
| Independent cadence | 🟡 | **sidecars: fully independent.** Ruby/ERB UI still needs a gem bump + Rails redeploy — see §7. |

A caveat recorded deliberately, because it should stay visible if this stalls: goal 2 alone
would not justify the split. The addon Ruby is only ~1,360 LOC; the thing actually taxing
every agent session is `CLAUDE.md` and `docs/`, which could be trimmed without touching code.
**The split earns its keep on goal 1.**

### Approaches considered and rejected

| Approach | Why rejected |
|---|---|
| Submodule + `path:` gem | Same code split, no release ceremony — but pluggability is nominal and cadence is unchanged (image rebuild either way). Cheaper, but delivers only goal 2, the weakest goal. |
| Out-of-process addon apps (own service + token-scoped write-back API) | The only option with fully independent deploy, but it requires designing and versioning a public API, rewriting the ERB UIs, and re-solving the folder-chooser and current-project UX across the boundary. Under "just me / trusted forks" the isolation it buys is worth ~nothing for several times the work. |
| Split the sidecars only | Smallest honest step, but the sidecars are *already* HTTP-only, `.dockerignore`'d and independently deployed. It would deliver almost nothing that isn't already true. |

---

## 2. What moves and what stays

The split is **not** "`/tools` vs. the rest of the app." It is **the addon platform (stays)
vs. the addons (move)**. The platform is already addon-agnostic — that is what makes this
tractable.

### Stays in the host (the platform / SDK)

- `Maker::AddonState`, `Maker::AddonFile` + their 3 migrations (`maker_addon_states`,
  `maker_addon_files`, and the 2026-07-30 params-row deletion)
- `Maker::Addons::LibraryOutput` — THE one output path (§14c), and the one legitimate direct
  `Storage::ChunkStore` call in the maker layer that `architecture_invariants_test.rb` asserts
- `Maker::Addons::Registry` — becomes a registration API (§3), not a frozen hash
- `Tools::BaseController`, `Tools::LibraryFolders`, `Tools::AddonParamsController`,
  `Tools::HomeController` + `app/views/tools/home/index.html.erb`
- `app/views/tools/shared/_params.html.erb`
- `CurrentProject#current_project_folder_node_id`, `#attach_addon_files_to_current_project`
- the `Tools` nav link in `app/views/layouts/application.html.erb`
- `User has_many :maker_addon_states`

### Moves to `maker-addons`

| What | Detail |
|---|---|
| Controllers | `Tools::{Boxes,Openscad,Generators}Controller` |
| Views | `app/views/tools/{boxes,openscad,generators}/**` — 12 files |
| Helpers | `Tools::{Boxes,Openscad}Helper` |
| Services | `BoxesClient`, `OpenscadClient`, `OpenscadParams` — **renamed under `Tools::`**, see §3 |
| Stimulus | `boxfilter`, `boxpreview`, `boxsections`, `traylayout`, `topview`, `generator` (~567 LOC) |
| Shared JS | `app/javascript/lib/tray_layout.js` |
| Generator modules | `app/javascript/generators/{index,material_test_grid}.js` |
| Vendored JS | `makerjs.js` + its four deps: `bezier-js.js`, `clone.js`, `graham_scan.js`, `kdbush.js` |
| Routes | the `/tools/{boxes,generators}` block + the hand-written OpenSCAD routes |
| Sidecars | `sidecar/boxes` (GPL-3.0), `sidecar/openscad` (GPL-2.0) + their Kamal accessory config |
| Tests | 3 controller tests, `openscad_client_test`, `fake_boxes.rb`, `fake_openscad.rb`, 3 system tests |

### Explicitly NOT moving — checked, not assumed

- **`sheet_controller.js`** — reads as addon-adjacent by name; it is used only by
  `app/views/projects/sheets/show.html.erb`. It is a Projects feature.
- **`jszip`, `three.*`, `STLLoader`/`OBJLoader`/`3MFLoader`/`OrbitControls`, `jspreadsheet`,
  `formula-parser`, `jsuites`, `fflate`** — importer, model viewer and sheet features. Host.
- **`boxfilter` / `boxpreview` / `generator`** are shared across *all three* addons — they move,
  but as addons-repo-shared JS, not as `boxes`-owned files. Relevant to the step ordering in §8:
  the first addon extracted drags them along.

---

## 3. The boundary

### The engine is NOT isolated

`isolate_namespace` would prefix every route helper (`maker_addons.tools_boxes_path`), give
the engine its own layout and helper lookup, and cut it off from `ApplicationController`, the
app layout, `content_for`, and the shared CSS classes the addon views already use. That
isolation buys namespace protection a trusted single-consumer gem does not need, at the cost
of churning every view. **Non-isolated:** the engine contributes to the same `Tools::`
namespace and the moved files read exactly as they do now.

Known consequence, accepted: two addon gems would collide in `Tools::`. Under the trust model
there is one gem. Revisit if a second ever appears.

### The SDK is six surfaces and nothing else

| Surface | Purpose |
|---|---|
| `Maker::Addons::LibraryOutput.write(user:, state:, parent_node_id:, files:)` | the one output path |
| `Tools::BaseController` | session-auth base |
| `Tools::LibraryFolders` | `chosen_parent_node_id`, `folder_options` |
| `CurrentProject#current_project_folder_node_id` / `#attach_addon_files_to_current_project` | default destination + auto-attach |
| `current_user.maker_addon_states` / `Maker::AddonState.for_addon` | state persistence |
| `Maker::Addons::Registry.register(...)` | appearing in the gallery |

**Everything below that line stays private to the host:** `FileLayer`, `Sync::Commit`,
`Storage::ChunkStore`, `Maker::Previews`, `Device`. Today the addons only reach those
*through* `LibraryOutput`; the split turns that from a convention into an enforceable
boundary. This is the same tripwire as §14d — *if an addon needs to touch sync, the changelog,
conflicts, locks or the mounts, the boundary is wrong; stop.*

### Version skew is a boot-time failure, not a runtime one

`Maker::Addons::SDK_VERSION` in the host; the engine declares the version it requires and
**raises at boot** if the host is older. A loud boot failure beats a green suite over a
silently missing method — this repo's dominant recorded failure mode (§15).

### Registration replaces the frozen hash — and deletes a bug class

The gallery currently does `send("tools_#{addon.key}_path")`. That single line is the entire
reason for both inflector traps documented at `config/routes.rb:159-170` and for the
hand-written OpenSCAD routes. Under registration the addon declares its own path:

```ruby
Maker::Addons::Registry.register(
  key: "boxes", title: "Box Generator", icon: "📦",
  description: "Parametric laser-cut / CNC boxes",
  available: -> { Tools::BoxesClient.configured? },
  path: ->(r) { r.tools_boxes_path }
)
```

`available:` stays a lambda — that is what lets an addon grey out when its sidecar is
unconfigured instead of 500ing, and it must stay lazy.

**The guard test gets stronger, not weaker.** Today `openscad_controller_test.rb:38` guards one
naming accident. It becomes: *every registered addon's `path` proc resolves with no arguments*
— which covers addons that do not exist yet. The inflector traps remain real for whoever
writes an addon's routes, and the comment moves with them; what changes is that the gallery no
longer depends on the naming.

### Naming: keep the controllers, move the three clients under `Tools::`

`BoxesClient` (31 refs / 12 files), `OpenscadClient` (45 / 7) and `OpenscadParams` (8 / 4) are
top-level constants — the only real collision risk a gem introduces into the host's global
namespace. Renaming to `Tools::BoxesClient` etc. is mechanical and removes three globals.
Controllers stay `Tools::*Controller`: churning them would touch every route, view and test
for no safety gain.

---

## 4. Routes

The engine **appends to the host's route set** rather than mounting:

```ruby
initializer "maker_addons.routes" { |app| app.routes.append { MakerAddons.draw_routes(self) } }
```

**Verified safe:** `config/routes.rb` has no catch-all. The only wildcard-ish entry is
`root to: redirect("/files")` at line 37, which matches `/` exactly, so appended `/tools/*`
routes cannot be shadowed. And because the block is evaluated *inside the host's route set*,
the generated helpers are ordinary main-app helpers — `tools_boxes_path` keeps working
unprefixed in host views. This sidesteps the question of engine helper visibility entirely,
which is why it is preferred over `mount`.

---

## 5. Assets — the one genuine unknown

importmap-rails documents an engine pattern:

```ruby
initializer "maker_addons.importmap", before: "importmap" do |app|
  app.config.importmap.paths << Engine.root.join("config/importmap.rb")
  app.config.importmap.cache_sweepers << Engine.root.join("app/javascript")
  app.config.assets.paths << Engine.root.join("app/javascript")
  app.config.assets.paths << Engine.root.join("vendor/javascript")
end
```

Propshaft picks up engine asset paths. This *should* work. But this repo has scar tissue
exactly here — the jspm shared-chunk hunt (`jszip-buffer-chunk`) and the `buffer.js` import
re-pin, both recorded in `config/importmap.rb` — so it is **spiked first, before any file
moves** (§8 step 0). Prefer a probe over an argument (§15).

**If the spike fails**, the fallback is a reduced split: Ruby + ERB move, JS stays vendored in
the host. That is a worse boundary and it is a decision to bring back to the owner, not a
problem to work around silently.

---

## 6. Migrations

`maker_addon_states` and `maker_addon_files` are addon-agnostic **platform** tables. They stay
in the host with all 3 migrations. The engine ships none today. If an addon ever needs its own
table: `rails maker_addons:install:migrations`.

---

## 7. Sidecars, deploy, and the §9 landmine this creates

### Deploy

The addons repo owns `sidecar/*`, builds and pushes both images, and gets its own
`config/deploy.yml` booting them as Kamal accessories on the Unraid host. **This is where the
independent cadence actually lands** — `kamal accessory reboot boxes` from the addons repo,
no Rails redeploy.

The host drops the accessory *definitions* but keeps `BOXES_SIDECAR_URL` and
`OPENSCAD_SIDECAR_URL` in `env.clear` — it still calls them.

### The landmine

A conventional gemspec is `spec.files = git ls-files`. That puts **both GPL sidecar trees
inside the permissive gem**, which is then pushed. That is redistribution — the exact
`.dockerignore` bug from §14c, re-created in a new container format. And the host's existing
guard cannot catch it, because the host no longer has a `sidecar/` directory to discover:
`assert sidecars.any?` in `test/deploy_hygiene_test.rb` goes **RED** the moment the directory
leaves. That is the correct failure, not a regression to suppress.

### The guard splits three ways

| Guard | Lands where | State |
|---|---|---|
| OVH overlay clears every `*_SIDECAR_URL` | **host**, unchanged | still true, still needed — the host still sets those URLs |
| Every GPL sidecar image carries its own licence text | **addons repo**, unchanged | the images are still built and pushed from there |
| GPL is excluded from the permissive shipped artifact | **addons repo**, *adapted* | was `.dockerignore` contains `/sidecar/`; becomes **no `sidecar/` path appears in `spec.files`** |

The host keeps `/sidecar/` in `.dockerignore` as belt-and-braces against a sidecar ever coming
back, and §14c gains a line recording that the guard now lives in the addons repo.

---

## 8. Testing and CI

### Most tests do not move

Sorting the 14 addon-touching test files by what they actually assert, these are testing the
**platform** and stay in the host: `addon_params_controller_test`, `home_controller_test`,
`library_folders_test`, `library_output_test`, `addon_state_test`, the params-row migration
test, `architecture_invariants_test`. (`attach_to_project_test` and `project_intake_test`
merely mention addons; they are host tests.)

### Where the addon tests run — and the tax this incurs

A dummy app in the addons repo would need users, auth, the `nodes` table, a configured
`FileLayer` and `Sync::Commit` — it would have to reimplement the server in order to test a
form. So:

- **addons repo owns unit tests** — `openscad_client_test`, `OpenscadParams`, the two fakes.
  Pure HTTP and parsing, no database.
- **host owns the integration gate** — the 3 controller tests and 3 system tests keep running
  in `bin/ci`, where the full stack and the three `LIBRARY_BACKEND` legs already exist.

**Stated plainly, because it is the real cost:** addon code will live in a different repo from
the tests that prove it works. A PR in the addons repo cannot fully prove itself; it proves
itself when the host bumps the gem ref. **This is what makes the Ruby half's cadence 🟡
rather than ✅ in §1.**

Escape hatch, deliberately *not* built in v1: the addons repo's CI clones the host at a pinned
ref, installs itself via `path:`, and runs the host's `test/controllers/tools` suite. Feasible
because everything runs on one machine. Build it if the skew becomes annoying.

### CI constraints carried over verbatim

- The addons repo must use `runs-on: [self-hosted, macos]` and **never** a `*-latest` runner —
  GitHub bills only hosted runners (§15).
- Only one runner is registered (`charless-MacBook-Pro-maker-mac`). Both repos contend for it,
  so the addons suite must stay fast.
- The host's three test legs must keep reporting **identical** counts.

---

## 9. Sequence

Green at every step; steps 2 and 3 are each independently shippable and revertable.

| # | Step | Rationale |
|---|---|---|
| 0 | **Spike the asset pipeline.** Scratch engine + this app: prove an engine-supplied Stimulus controller loads and Maker.js resolves *in the browser*. | Go/no-go for the whole plan (§5). |
| 1 | **Host-side prep, no new repo.** `Registry.register` + path procs; the stronger gallery guard; `SDK_VERSION`; the three clients moved under `Tools::`. | Reversible and valuable on its own — improves the host whether or not the split happens. |
| 2 | **Create `maker-addons`; move `generators` only.** | Smallest addon (no sidecar, generic controller) but it exercises the hardest part: JS, vendored Maker.js, importmap. Drags the three shared Stimulus controllers with it. |
| 3 | **Move `openscad`, then `boxes`.** | Boxes last: 5 Stimulus controllers, the sample-photo proxy route, 3 system tests. |
| 4 | **Move both sidecars + their Kamal deploy.** Split `deploy_hygiene_test` three ways, add the gemspec guard, deploy both accessories from the new repo for real. | §7. |
| 5 | **Docs.** §14c rewritten as the SDK contract; `docs/STATUS.md` narrates the arc; the new repo gets its own `CLAUDE.md`. | |

**Every new guard gets mutation-checked** — break the thing it guards, confirm RED, restore
(§15). That applies hardest to the gemspec exclusion in step 4: it is the §9 landmine, and it
is exactly the shape of guard this repo has shipped broken before.

---

## 10. Open questions

None blocking. Two decisions deliberately deferred:

1. **Reverse-integration CI in the addons repo** (§8) — deferred until the version skew is
   demonstrably annoying rather than theoretically annoying.
2. **Generalizing the `generators` manifest pattern to all addons** — an addon as
   *manifest + JS bundle*, with one generic host controller, is the logical end state and
   would make addons pure content. It is out of scope here because the boxes UI is genuinely
   bespoke (collapsible sections, section index, live preview, top view) and forcing it
   through a schema today would be a downgrade. Revisit once a fourth addon exists.
