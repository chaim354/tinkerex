# Server-side thumbnail previews — extensible, multi-format

**Date:** 2026-07-20
**Status:** design (approved for planning)
**Topic:** a robust, easily-extended server-side preview system that renders a static PNG
thumbnail for many 2D/3D file types (STL, 3MF, SVG, DXF, LightBurn, …) and surfaces those
thumbnails in the web UI.

---

## 1. Goal & scope

Give the library a **static PNG thumbnail** for as many maker file types as we can render
permissively, **generated eagerly** when a file's bytes land, **served off Rails** (§15), and
**shown in the web file grid + single-file view**. The system must be **trivially extensible**:
adding a new format is a renderer module + one registry line + a fixture, with a shared contract
test that keeps every renderer honest.

**In scope:** the render engine's contract/hardening, output normalization to PNG, the eager
lifecycle, the web UI surfaces, and the extensibility guarantee.

**Not a rewrite.** A substantial server-side render engine already exists on `main` (see §2). This
design *completes and formalizes* it; it does not replace it.

**Non-goals (this project):**
- Interactive 3D/2D viewers (rotate/zoom, GLB, inline SVG). Static thumbnails only. The desktop
  app's client-side Three.js interactive path is unaffected and out of scope.
- STEP/OBJ/IGES rendering **in our deploy** — deferred (§5, §8). The `Mesh`/F3D renderer stays
  registered so a box that *has* F3D still renders them; we just don't ship F3D in our image yet.
- Any change to the sync engine, changelog, conflicts, locks, or the mounts. This is a
  maker-layer feature reacting to completed commits (respects the file-layer split's §10 tripwire).

---

## 2. What already exists (do NOT rebuild)

On `main`, deployed in part:

| Piece | Path | State |
|---|---|---|
| Registry (ext → renderer) | `app/services/maker/previews/registry.rb` | exists |
| `Stl` renderer | `.../previews/stl.rb` | `stl-thumbnailer` binary — **deployed & working** |
| `ThreeMf` renderer | `.../previews/three_mf.rb` | embedded-thumbnail extract, pure Ruby — **working** |
| `Mesh` renderer (obj/step/iges) | `.../previews/mesh.rb` | F3D subprocess — **not deployed** (F3D not in image) |
| `Svg`/`Dxf`/`Lbrn2` renderers | `.../previews/{svg,dxf,lbrn2}.rb` | emit `image/svg+xml` today — **to be normalized to PNG** |
| `GeneratePreviewJob` orchestrator | `app/jobs/maker/generate_preview_job.rb` | states pending→processing→ready/failed/unsupported, retry-on-transient |
| `Maker::Preview` model + table | `app/models/maker/preview.rb`, `maker_previews` | migrated; ActiveStorage asset; unique on `(user,node,version,kind)` |
| `V1::Maker::PreviewsController` | `app/controllers/v1/maker/previews_controller.rb` | JSON enqueue + index API |
| `stl-thumbnailer` in deploy | `Dockerfile` (build + copy to PATH) | STL renders in prod |

**The two real gaps this design closes:**
1. **The web UI never uses any of it.** The grid shows no thumbnails; the single-file view only
   understands `:image`/`:text` and shows *"No inline preview for this file type."* for STL/3MF/CAD.
   Nothing in the web layer enqueues a preview or renders the `maker_previews` asset.
2. **2D vector formats emit SVG, not PNG**, and previews are only ever generated on-demand via the
   v1 API (never eagerly), so browsing a freshly-uploaded library shows nothing.

---

## 3. Architecture

The seam stays as-is; the data flow is:

```
bytes land (upload / scan)                     browse (web UI)
        │                                             │
   ensure_preview_for(node, version)            grid cell / detail view
        │  (idempotent enqueue)                       │  reads Maker::Preview
        ▼                                             ▼
  GeneratePreviewJob                          ready → <img src=blob_url>   (off Rails, §15)
   ├─ Registry.for_filename(name) → renderer  pending/processing → spinner + poll
   ├─ renderer.available?  → else `unsupported`  unsupported/failed → format-icon fallback
   ├─ FileLayer.current.read(...) → bytes
   ├─ renderer.render(bytes, size:) → { png bytes, content_type, w, h }
   └─ attach asset; status = ready
```

**Units, each independently testable:**
- **Renderer** (per format): bytes → PNG. Pure function of its input + toolchain. (§4)
- **`SvgRasterizer`** (new internal helper): SVG string → PNG bytes, via a permissive subprocess
  rasterizer. Shared by `Svg`/`Dxf`/`Lbrn2` so 2D formats converge on one raster step. (§5)
- **`Registry`**: ext → renderer. (exists)
- **`GeneratePreviewJob`**: orchestration + terminal-state policy. (exists; unchanged in shape)
- **`Maker::Preview`**: the record + asset. (exists)
- **`Previews::Enqueue`** (new thin helper): the one idempotent entry point the "bytes landed"
  seams call. (§6)
- **Web surfaces**: grid cell partial + detail branch + a poll-until-ready Stimulus controller. (§7)

---

## 4. The renderer contract (the extensibility guarantee)

**Formal interface.** A renderer is any object responding to:
- `available?` → Boolean — is the underlying toolchain present on this box?
- `render(bytes, size:, **opts) → { bytes:, content_type:, width:, height: }` — `content_type` is
  `"image/png"` for every thumbnail renderer (§5). `width`/`height` may be `nil` when not cheaply known.
- `EXTENSIONS` → array of lowercase extensions it claims.
- A renderer-specific error class raised on bad input (never a bare crash that the job can't
  classify) — the job maps a known "no renderable content" condition to `unsupported`/`failed`.

**Shared contract test** (mirrors `test/.../adapter_contract.rb` from the file layer). Every
renderer registered in `Registry::RENDERERS` is exercised against one contract:
- a valid fixture → `render` returns the documented hash with `content_type: "image/png"` and
  non-empty bytes that are a real PNG (magic-byte check);
- `available?` is a Boolean and, when false, the job's path yields `unsupported` (not a 500);
- garbage/truncated input raises the renderer's declared error, not an arbitrary exception;
- `EXTENSIONS` are all lowercase and all resolve back to this renderer through `Registry.for`.

A renderer that lies about its own output (wrong content-type, non-PNG bytes) cannot merge. This
is the "easily extended" promise made mechanical: **write module + register + fixture → covered.**

**Docs:** a short `docs/adding-a-preview-format.md` — the four steps, plus the fixture/licensing
checklist (§9 permissive-only).

---

## 5. Format coverage + output normalization

Every thumbnail renderer emits **PNG**. One content-type to serve, one uniform grid, and it
sidesteps the SVG-as-XSS-vector problem the web layer already guards against.

| Format(s) | Renderer | Mechanism | Deployed? |
|---|---|---|---|
| `stl` | `Stl` | `stl-thumbnailer` (GL-free CPU raster) | **yes** |
| `3mf` | `ThreeMf` | extract embedded slicer thumbnail (rubyzip) | **yes** (pure Ruby) |
| `svg` | `Svg` | **rasterize SVG → PNG** (was: pass-through SVG) | after this project |
| `dxf` | `Dxf` | DXF → SVG → **rasterize → PNG** | after this project |
| `lbrn`/`lbrn2` | `Lbrn2` | LightBurn XML → SVG → **rasterize → PNG** | after this project |
| `obj`/`step`/`stp`/`iges`/`igs` | `Mesh` | F3D subprocess | **no** — deferred, stays registered |

**SVG → PNG rasterizer.** Add a small **permissive** rasterizer as a subprocess, matching the
`stl-thumbnailer` posture (a single static binary compiled into the image, no GPU/GL). Recommended:
**resvg** (Rust, MPL-2.0/Apache — §9-clean, single CLI binary). `Svg`/`Dxf`/`Lbrn2` all route their
generated SVG through one `Previews::SvgRasterizer` helper that shells out to it. `available?` for
these renderers gates on the rasterizer binary being present — so a box without it degrades to
`unsupported`, same graceful path as F3D.

**STEP/OBJ/IGES:** left `unsupported` in our deploy (no F3D in the image). The renderer remains
registered; `available?` is false in prod → the job records `unsupported` (a non-error terminal
state). A self-host box that installs F3D gets them for free. Revisit deploying F3D later.

---

## 6. Eager lifecycle

**Trigger:** render when a file's bytes land, via a single idempotent helper
`Maker::Previews::Enqueue.call(user:, node:, version_id:)` that finds-or-creates the
`(node, version, kind: "thumbnail")` `Preview` and enqueues `GeneratePreviewJob` only when it is
new or previously `failed`/superseded. Called from the small set of "content arrived" seams:

- **Web upload, chunk mode:** `FilesController#finalize_upload`, after `Sync::Commit.finalize`.
- **Web upload, share/s3 mode:** `FilesController#create`, after `FileLayer.current.write`.
- **Desktop/API commit, chunk mode:** the server-side finalize path (`V1::CommitsController`
  finalize, or the equivalent commit-finalize choke point) — so files synced from the desktop app
  also get thumbnails, not just web uploads.
- **Share/s3 scan:** `Library::Reconciler` when it creates or revives a node (files that arrive
  out-of-band on the NAS/bucket).

**Supersede on new version.** A new `version_id` for a node is a new `Preview` row (the unique
index is `(user, node, version, kind)`); the grid/detail always read the **current version's**
thumbnail, so an edited file re-renders. Old-version rows may be swept later (out of scope here).

**Idempotency & cost.** Re-enqueue for an already-`ready` (node, version) is a no-op. Enqueue is
cheap (a row + a job); the render itself is bounded by the format's cost and runs in Solid Queue
(the same worker the scan sweep uses), never in the request.

**No sync coupling.** Every seam is a *reaction to a completed commit/scan* — it reads the port
and enqueues a job. It never touches sync internals (§10 tripwire).

---

## 7. Web UI surfaces

- **Grid** (`files/index.html.erb`): each file cell renders its thumbnail. States:
  - `ready` → `<img src=blob_url>` (the ActiveStorage asset URL, off Rails).
  - `pending`/`processing` → a spinner/placeholder; a small Stimulus controller polls the previews
    index API for cells still not `ready` and swaps in the image when it lands.
  - `unsupported`/`failed` → a per-extension format-icon fallback (no broken-image icon).
  - directories / no content → folder or generic icon.
  The controller batches the poll (one request for the folder's pending node_ids) rather than one
  request per cell.
- **Detail** (`files/show.html.erb`): `preview_kind` gains a `:thumbnail` branch that shows the
  rendered PNG for 3D/CAD/vector files, replacing *"No inline preview for this file type."* The
  existing `:image` (raster) and `:text` branches are unchanged; the raw-bytes `<img src=blob>`
  path is **not** used for STL/3MF/etc. (it never worked for them).

**Reading previews.** The views read `Maker::Preview` rows for the folder's nodes (scoped to
`current_user`, current version, `kind: "thumbnail"`) — a single batched query, not N+1, in the
spirit of `stat_all`.

---

## 8. Deployment & graceful degradation

- **Dockerfile:** add the **resvg** binary (build a small Rust stage + copy to PATH, exactly like
  `stl-thumbnailer`). Do **not** add F3D yet.
- **Degradation is already correct:** `available?` gates each renderer; a missing toolchain →
  `unsupported` (non-error), never a crash or retry storm. So:
  - Our managed/deploy image: STL, 3MF, SVG, DXF, LightBurn render; STEP/OBJ/IGES `unsupported`.
  - A self-host box: renders whatever toolchains it has; missing ones degrade quietly.
- **Overrides:** the existing `*_BIN` env overrides (`STL_THUMBNAILER_BIN`, `F3D_BIN`, and a new
  `RESVG_BIN`) let an operator point at a differently-located binary.

---

## 9. Security

- **PNG-only inline.** Generated thumbnails are PNG and safe to inline; we never inline
  user-supplied SVG/HTML (the web layer's existing XSS posture). Rasterizing 2D vector formats to
  PNG is part of *why* this holds.
- **Bytes off Rails.** Thumbnail bytes are served via the ActiveStorage blob URL, consistent with
  §8/§15. The preview record references the file only by stable `node_id` + immutable `version_id`.
- **Tenant scoping.** Every preview read/write is scoped to `current_user`; a foreign node_id
  yields nothing.
- **Permissive licenses only (§9).** resvg (MPL-2.0/Apache), stl-thumbnailer (Apache/MIT), rubyzip
  (BSD-2). F3D (BSD-3) / its OCCT plugin (LGPL) stay out-of-process *and* out of the image for now.

---

## 10. Testing

- **Renderer contract test** (§4) across all registered renderers — the extensibility backstop.
- **`SvgRasterizer`** unit test (SVG in → PNG magic bytes out; missing binary → declared error).
- **`Enqueue` helper**: idempotent (no duplicate jobs for a ready preview); enqueues on new version.
- **`GeneratePreviewJob`** state coverage already exists — extend for the PNG-normalized 2D
  renderers and the `unsupported` (toolchain-missing) path.
- **Web UI**: grid renders thumbnail/spinner/fallback per state; detail shows the PNG; both scoped
  to `current_user`; no N+1 on the batched preview read.
- **Cross-backend**: the eager seams fire on chunk, share, and s3 (the suite's three legs) —
  uploads/scan produce a `ready` thumbnail on each.
- **Deploy smoke**: `resvg` and `stl-thumbnailer` are on PATH in the built image; a sample of each
  format renders `ready`.

---

## 11. Deferred / out of scope

- F3D in the deploy (STEP/OBJ/IGES in prod).
- Interactive 3D (GLB) / inline SVG viewers.
- Old-version thumbnail GC / retention.
- Preview backfill for the *existing* library (a one-off rake task to enqueue thumbnails for files
  already present) — nice-to-have; can be a follow-up once the eager path is proven.

---

## 12. Definition of done

- Every registered renderer emits PNG and passes the shared contract test.
- SVG/DXF/LightBurn rasterize to PNG via `SvgRasterizer`; resvg is in the deploy image.
- Thumbnails generate eagerly on web upload (chunk + share/s3), desktop/API commit, and share/s3
  scan; idempotent; supersede on new version.
- The web grid shows thumbnails (with spinner/fallback states) and the detail view shows the PNG
  for STL/3MF/SVG/DXF/LightBurn.
- STEP/OBJ/IGES degrade to `unsupported` cleanly (no 500, no retry storm).
- Server suite green on all three backend legs (`bin/rails test`, `LIBRARY_BACKEND=share`,
  `LIBRARY_BACKEND=s3`).
- `docs/adding-a-preview-format.md` documents the four-step extension path.
