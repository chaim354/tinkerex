# Addon framework + Boxes generator — design

**Date:** 2026-07-20
**Status:** design (approved for planning)
**Topic:** an extensible **addon framework** for embedding maker mini-tools into the web app, and
its first addon — a **parametric box generator** built on a forked, self-hosted `boxes.py`.

---

## 1. Goal & scope

Add a **Tools** area to the web app where small, self-contained maker tools ("addons") live. Each
addon has a UI, persists its own state/parameters uniformly, and can write outputs into the file
library. Ship the framework **and** the first addon (a box generator) together; a later notes/drawing
addon proves the framework spans client-only tools too.

**In scope:**
- The addon **seam** (registry + `Tools::` controllers + a `/tools` gallery).
- A generic **state store** (`Maker::AddonState`) — "auto stores parameters" for every addon — plus
  a **tied bundle of output files** (`Maker::AddonFile`): any number of files of any type produced by
  one save, grouped together (for boxes: the SVG *and* the parameters that made it).
- **Generic library write** — an addon hands the framework a SET of files (any type); they are stored
  in the file library and tied to the state in one go. The framework never inspects the bytes.
- The **Boxes addon**: a forked `boxes.py` running as a **separate Python sidecar** (GPL-isolated),
  with the UI, parameter persistence, and library-save owned by Rails.

**Explicitly out of scope (this pass):**
- **Dynamic / third-party / sandboxed plugins.** v1 addons are **in-repo**, first-class in the app.
  A real third-party plugin system (loading, sandboxing, a marketplace) is a much larger future
  project. "Extensible" here means *adding an addon is a controller + one registry line*.
- The **notes/drawing** addon itself — designed *for* by the framework, but specced/built later.
- Any change to the sync engine, changelog, conflicts, locks, or mounts (the file-layer split's §10
  tripwire still holds — addons write through the existing `FileLayer` port, nothing deeper).

**Decisions locked in brainstorming:**
- Modification lives in a **fork of boxes.py** (self-maintained GPL fork), not just a wrapper.
- The fork runs as a **separate Python sidecar service** (not in the main image, not an iframe).
- Rails owns the **UI, parameter storage, and library-save**; the sidecar only generates.

---

## 2. Architecture

```
┌─────────────────────────────────────────────┐        ┌──────────────────────────┐
│  Rails app (permissive)                       │  HTTP  │  boxes-sidecar (GPL)     │
│  • /tools            → addon gallery          │ ─────► │  forked boxes.py + thin  │
│  • /tools/boxes      → generator UI           │ ◄───── │  HTTP API, internal-only │
│  • Maker::Addons::Registry (the seam)         │  SVG   │  GET  /generators        │
│  • Maker::AddonState (generic param/doc store)│        │  POST /generate          │
│  • writes output via FileLayer → library node │        │  GET  /up  (health)      │
└───────────────────────┬───────────────────────┘        └──────────────────────────┘
                        │ writes SVG                              (separate container)
                        ▼
              File library ── auto-previews via the SVG renderer, versioned
```

Four reusable framework parts (§3–§6); the Boxes addon (§7–§8) is the first consumer of all four.

**Units, each independently testable:**
- `Maker::Addons::Registry` — addon_key → metadata (title, icon, description, mount). (§3)
- `Maker::AddonState` + `Maker::AddonFile` — the generic per-user state (JSON) and its tied bundle
  of output files (any type, any count, each with a role). (§4)
- `Maker::Addons::LibraryOutput` — the one generic helper that writes a SET of addon-produced files
  (any type) into the library via `FileLayer` and ties them all to an `AddonState` via `AddonFile`. (§5)
- `BoxesClient` — a typed HTTP client for the sidecar (list generators, generate). Stub-friendly. (§7)
- `Tools::BaseController` + `Tools::BoxesController` — the gallery and the box-generator UI. (§8)
- **boxes-sidecar** — the forked `boxes.py` + a thin API, its own image + GPL LICENSE. (§7)

---

## 3. The addon seam (`Maker::Addons::Registry`)

Same shape as `Maker::Previews::Registry`. Each addon is declared once:

```ruby
Addon = Data.define(:key, :title, :icon, :description, :controller)

REGISTRY = {
  "boxes" => Addon.new(key: "boxes", title: "Box Generator", icon: "📦",
                       description: "Parametric laser-cut / CNC boxes",
                       controller: "tools/boxes"),
  # future: "notes" => Addon.new(...)
}
```

- `GET /tools` (`Tools::HomeController#index`) renders the gallery from `REGISTRY`.
- Each addon mounts at `/tools/:key`, served by its declared controller under `Tools::`.
- **Adding an addon = a `Tools::` controller + one REGISTRY line** (+ an optional sidecar for
  server-backed tools). No dynamic loading.
- All `Tools::` controllers require login and are user-scoped, exactly like `FilesController`.

**Availability:** an addon may declare an `available?` (e.g. Boxes is available only when
`BOXES_SIDECAR_URL` is configured). The gallery shows unavailable addons greyed with a reason, the
same graceful-degradation posture the preview renderers take.

---

## 4. The generic state + output-bundle model (`Maker::AddonState` + `Maker::AddonFile`)

The framework is **format- and count-agnostic**: one saved addon thing is a **state** (structured
data, for reload) plus a **bundle of any number of output files of any type**, all tied together.
Two small models, shared by every addon:

```
maker_addon_states                         maker_addon_files   (the tie — one state, many files)
  id                                         id
  user_id   (belongs_to user, scoped)        addon_state_id  (belongs_to, dependent: :destroy)
  addon_key (string, e.g. "boxes")           node_id         (string — a library node)
  name      (string — user's label)          role            (string — "output" | "parameters" | ...)
  data      (json — the addon's own shape)    content_type    (string)
  created_at / updated_at                     position        (int — stable ordering)
  index (user_id, addon_key)                  index (addon_state_id), unique (addon_state_id, node_id)
```

- **`AddonState has_many :files` (`AddonFile`)** — this is the "tie all the files output at one go"
  requirement. One save = one state + N linked library nodes, each with a **role** so the addon (and
  the UI) knows what each file is. For **Boxes**, one saved box ties together: the **`box.svg`**
  (`role: "output"`) and the **`box.params.json`** (`role: "parameters"`) — and later a `box.dxf` /
  `box.gcode` with no model change, because the bundle is just "N files with roles".
- **`data` is opaque to the framework** — each addon owns its shape (boxes: `{generator, params}`;
  notes: `{content}`). It is the structured copy used to **reload** the tool; the same params are
  ALSO emitted into the bundle as a `parameters` file so they are a first-class, downloadable,
  portable artifact next to the output (the user's "the svg AND the parameters used to make it").
- Every addon persists the **same way** through the same two models — nothing here is boxes-specific.
  Backend-neutral (ordinary Rails, unaffected by `LIBRARY_BACKEND`).

A thin `V1::Maker::AddonStatesController`-style JSON surface is **not** required for v1 (the boxes UI
is server-rendered and talks to its own controller); a client-only addon (notes) will need a small
JSON CRUD endpoint, added when that addon lands.

---

## 5. Library integration — store ANY files an addon sends (`Maker::Addons::LibraryOutput`)

The one generic write path. An addon hands over **a set of files of any type**; the framework writes
them all into the library through the existing `FileLayer` port and ties them to the state in one go:

```ruby
# `files`: [{ name:, bytes:, content_type:, role: }, ...] — ANY number, ANY type. Each is written
# into the user's library under a per-save folder, then linked to `state` as an AddonFile carrying
# its role. Returns the AddonFiles. Backend-neutral: chunk mode uses the two-phase Sync::Commit path
# the web upload uses; share/s3 use FileLayer#write. Reuses existing write plumbing — no new
# bytes-through-Rails path, and each written node gets a preview enqueued by the eager seam.
Maker::Addons::LibraryOutput.write(user:, state:, folder:, files:)
```

- **Any type, any count** — the helper never inspects the bytes; a boxes SVG, a params JSON, a DXF,
  a drawing PNG, a note's markdown all flow through the same call. This is the "store any file an
  addon sends to the file system" requirement.
- **Grouped + tied two ways.** Physically, one save writes into a **per-save folder**
  (`Tools/<Addon>/<name>/`) so browsing the library shows the whole bundle together (svg + params
  side by side). Structurally, every written node is linked to the `AddonState` via an `AddonFile`
  with its role, so the tool can re-open the bundle and know which file is which. The folder is the
  human tie; the join is the machine tie.
- **Regenerate = new versions in place.** Re-saving a state re-writes the same-named files in the
  same folder (new immutable versions on chunk; overwrite on share/s3) and re-uses the existing
  `AddonFile` links — the bundle stays one thing across edits, not a pile of `-2.svg` duplicates.
- Each written file **auto-previews** (a box SVG gets its thumbnail from the SVG renderer) and
  versions, for free. **§15 holds** where the backend can presign (chunk/s3); on share it streams
  like any other file.

---

## 6. Deployment: the sidecar (Kamal accessory)

- `boxes-sidecar` is a **new container** (Kamal `accessory`, or a peer service in `config/deploy*`),
  **internal network only** — never published to the internet. Rails reaches it at
  `BOXES_SIDECAR_URL` (e.g. `http://boxes-sidecar:8000`).
- Built from `sidecar/boxes/Dockerfile`: a slim Python base + the **forked boxes.py** (a git
  submodule or vendored subtree under `sidecar/boxes/vendor/`) + a thin API app (`app.py`,
  FastAPI/Flask). Pinned versions.
- The sidecar directory carries its **own `LICENSE` (GPL-3.0)**; nothing links it into the Ruby app.
  This is the §9 posture for GPL: a separate program invoked over HTTP (aggregation), the same
  arm's-length treatment F3D/WinFsp get, made stronger by being a distinct artifact.
- Self-hosted CI: a `boxes-sidecar` image build + a health check on the self-hosted runners
  (§15 CI rule — self-hosted only, idempotent).

---

## 7. The sidecar API (Python, forked boxes)

Thin and typed, so Rails can render a form and generate without knowing boxes internals:

- `GET /generators` →
  ```json
  [{ "key": "ABox", "title": "Fully closed box", "group": "Boxes",
     "params": [{ "name": "x", "type": "float", "default": 100, "min": 0, "help": "width (mm)" },
                { "name": "burn", "type": "float", "default": 0.1, "help": "kerf" }, ...] }]
  ```
  Derived from boxes' own generator + argument definitions (boxes exposes argparse-style params).
- `POST /generate` `{ "generator": "ABox", "params": { "x": 100, ... } }` → `image/svg+xml` body
  (plus a JSON error `{error}` with 422 on bad params).
- `GET /up` → health.

`BoxesClient` (Ruby, `app/services/boxes_client.rb`) wraps these with a timeout and typed results,
and is **stub-friendly** (a `FakeBoxes` client for tests, mirroring `FakeS3`).

---

## 8. The Boxes addon UI flow (`Tools::BoxesController`)

1. `GET /tools/boxes` — two panes: **your saved boxes** (`AddonState` for `boxes`) and a **new box**
   picker (generators from `BoxesClient#generators`, cached).
2. `GET /tools/boxes/new?generator=ABox` — Rails fetches the generator's param schema and renders a
   **dynamic form** (number/select/checkbox per param type, with defaults + help text).
3. `POST /tools/boxes/preview` `{generator, params}` — Rails validates params against the schema,
   calls `BoxesClient#generate`, returns the **SVG for live preview** (rendered inline, sanitized —
   or rasterized via resvg to a PNG to avoid inlining untrusted SVG; see §9).
4. `POST /tools/boxes` (save) — persist `AddonState{generator, params, name}` **and**
   `LibraryOutput.write` the whole **bundle in one go** into `Tools/Boxes/<name>/`: **`box.svg`**
   (`role: "output"`) and **`box.params.json`** (`role: "parameters"`), both tied to the state as
   `AddonFile`s. The SVG auto-previews. A future format (DXF/gcode) is just another entry in the
   files array — no model or flow change.
5. `GET /tools/boxes/:id` — reopen a saved box: its `AddonState.data` reloads the form → tweak →
   regenerate → updates the state and re-writes the bundle (new versions of `box.svg` +
   `box.params.json` in the same folder, same `AddonFile` links).

---

## 9. Security & ops

- **Sidecar isolation:** internal-only; Rails is the sole caller, behind session auth. The sidecar
  runs no user code — it only maps typed params onto boxes generators.
- **Untrusted SVG:** boxes output is generated (not user-authored), but to stay consistent with the
  web layer's no-inline-SVG posture, the **live preview rasterizes the SVG to PNG via resvg** (already
  deployed) rather than inlining it. The saved `.svg` in the library is served as a download/preview
  through the existing blob path (which already forces SVG to download).
- **Resource limits:** generation has a **timeout** and an **output-size cap** — a pathological
  parameter set (huge dimensions / tiny kerf) can produce a large/slow SVG. Exceeding either →
  a 422 with a clear message, never a hung request.
- **Param validation:** every param is checked against the generator schema (type, min/max, choices)
  in Rails before calling the sidecar — the sidecar is a backstop, not the gate.
- **Licensing (§9):** the GPL fork is a separate image/artifact invoked over HTTP; the permissive
  Rails app never imports or links it. Documented in `sidecar/boxes/README` + its own LICENSE.

---

## 10. Extensibility — how the next addon plugs in

A future **notes/drawing** addon: a `Tools::NotesController` + one REGISTRY line, a client-side JS
view (rich text + `<canvas>`/SVG), and `AddonState` for storage (via a small JSON CRUD endpoint added
then). **No sidecar.** This demonstrates the framework spans server-backed (boxes) and client-only
(notes) tools with the same seam + the same state store.

---

## 11. Testing

- **Registry / gallery:** `/tools` lists registered addons; unavailable ones degrade gracefully.
- **`AddonState`:** CRUD, user-scoping, JSON round-trip.
- **`LibraryOutput`:** writes a **multi-file bundle of mixed types** through `FileLayer` on all three
  backends (chunk/share/s3), ties each file to the `AddonState` via `AddonFile` with its role, groups
  them under one per-save folder, and enqueues a preview per node (reuses the eager seam). Re-saving
  re-versions the same files rather than creating duplicates.
- **`Tools::BoxesController`** with a **stubbed `BoxesClient` (`FakeBoxes`)** — list generators,
  render the dynamic form, preview (stub SVG → resvg PNG), save (AddonState + the tied bundle: an SVG
  output file AND a params file), reopen a saved box and regenerate (same bundle, new versions).
- **Param validation** rejects out-of-schema params before any sidecar call.
- **Sidecar (Python)**: its own tests live with the fork (`sidecar/boxes/tests`) — generate a known
  box, assert valid SVG; schema endpoint shape.
- **One real-sidecar smoke** (like the SeaweedFS real run): Rails → live sidecar → SVG → library, on
  CI/self-hosted. Optional but recommended.
- Server suite stays green on all three `LIBRARY_BACKEND` legs.

---

## 12. Deferred / out of scope

- Dynamic/third-party/sandboxed plugin loading + a plugin API/marketplace.
- The notes/drawing addon (framework supports it; build later).
- Non-SVG boxes output (DXF/gcode via pstoedit) — boxes can, but SVG covers the preview + laser use;
  add formats later if wanted.
- A client-facing `AddonState` JSON API (added with the first client-only addon).

## 13. Definition of done

- `/tools` gallery renders registered addons; Boxes is present (and greys out cleanly if the sidecar
  is unconfigured).
- A user can: pick a generator → fill a dynamically-generated form → preview → save → find the box's
  **bundle** in their library (the SVG *and* the params file, grouped in one folder, the SVG with a
  thumbnail) → reopen the saved box, tweak, regenerate (new versions of the whole bundle).
- The library-write helper stores an **arbitrary set of files of any type** an addon hands it, tied
  to one `AddonState` — demonstrably not boxes-specific.
- `boxes-sidecar` deploys as an internal-only container from the forked `boxes.py`; Rails talks to it
  via `BoxesClient`; GPL stays isolated to that artifact.
- Server suite green on `bin/rails test`, `LIBRARY_BACKEND=share`, `LIBRARY_BACKEND=s3`.
- Adding a second (client-only) addon is demonstrably a controller + a registry line + `AddonState`.
