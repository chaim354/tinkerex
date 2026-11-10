# Adding a preview format

The preview system renders a file's bytes to a **PNG thumbnail** behind a small seam
(`app/services/maker/previews/`). Adding a format is four steps — plus a fifth if it is 2D vector
and can also be measured.

1. **Write a renderer** in `app/services/maker/previews/<ext>.rb`. It responds to:
   - `available?` → Boolean — is the toolchain present? (Pure-Ruby renderers return `true`.)
   - `EXTENSIONS` → array of **lowercase** extensions it claims.
   - `render(bytes, size:) → { bytes:, content_type:, width:, height: }` — `content_type` must be
     an **inline-safe raster type** (`image/png` in almost all cases). If your source is 2D vector,
     build an SVG and hand it to `Maker::Previews::SvgRasterizer.to_png` (that is what `Dxf`/`Lbrn2`
     do) — do **not** emit `image/svg+xml`, the web layer will not inline it (SVG can carry script).
   - Raise a renderer-specific error (e.g. `RenderError`) on bad input, never a bare crash — the
     job classifies a known "no renderable content" condition as `unsupported`/`failed`.
   - **Paint ink on paper**: an opaque ground of exactly `Maker::Previews::Palette::PAPER` (white),
     drawn in the file's own colours, or the palette's `INK` / `MATERIAL` where it has none. The
     browser multiplies every thumbnail onto a themed card, so white becomes the card and a ground a
     shade off white shows as a tinted square in both themes. `SvgRasterizer` already paints the
     ground. A later change to what a renderer paints needs a `THUMBNAIL_REVISION` +
     `payload_revision` bump (and its row in `thumbnail_revision_test.rb` moved with it), or the
     library keeps the old pictures (`docs/invariants/measure-view.md`).

2. **Register it** — one line in `app/services/maker/previews/registry.rb` (`"<ext>" => Renderer`).

3. **Add a fixture** — a small valid file at `test/fixtures/files/<sample>.<ext>`, and add the
   renderer → fixture pair to `FIXTURES` in
   `test/services/maker/previews/renderer_contract_test.rb`. The shared contract test now exercises
   your renderer automatically (interface, `EXTENSIONS` resolve back through the Registry,
   inline-safe raster output). A renderer that lies about its output cannot merge.

4. **If it needs a binary**, gate `available?` on it (with a `<NAME>_BIN` env override), install it
   in the `Dockerfile` (a build stage + a COPY, like `stl-thumbnailer`/`resvg`), and add an
   idempotent install to the self-hosted CI legs in `.github/workflows/ci.yml`. A box without the
   binary degrades that format to `unsupported` (a non-error terminal state) — never a crash.

5. **If it is 2D vector, it can also measure.** A format that can yield contours gets the Measure
   view by supplying a traversal to `Maker::Previews::Geometry.build` (see `LbrnGeometry`,
   `DxfGeometry`, `SvgGeometry`) and declaring `FORMAT_REVISION` / `PAYLOAD_REVISION` — the latter
   as `Geometry::SHARED_REVISION + FORMAT_REVISION`, never a bare integer, and the module must be
   named in `Geometry::REVISIONED_BY` or `GeometryTest` fails.

   A traversal MAY also supply a **curve descriptor** through `Collector#add`'s `curve:` keyword,
   built with `Geometry.ellipse_curve` or `Geometry.arc_curve` and already in client space (mm,
   Y-down). It is optional and **drawing-only**: `b`, `d` and the job box are computed from the
   full-resolution points regardless, so a format supplying none is complete. Supply one ONLY where
   the file itself declared an exact primitive — never inferred from the points — and refuse it
   under a rotated or skewed transform.

   A traversal SHOULD also hand `Geometry.build` an `unreadable:` hash and fill it with whatever it
   met and could not draw — `{ "ELLIPSE" => 2 }`, emitted as the payload's top-level `"u"` key and
   omitted entirely when empty. Every parser here handles a SUBSET of its format, and the
   alternative is what DXF did for years: an entity type with no arm in the traversal's `case`
   returned nil and was skipped with no error, no log and no status — missing from the job box as
   well as from the picture, so the reported size described a subset of the file. **Hand the hash IN
   and let the traversal fill it during the yield**; `build` reads it after the block returns, so a
   version that snapshots it earlier reports nothing, on every file, with nothing going red.

   `docs/invariants/measure-view.md` is the binding set of rules here; read it before writing a
   traversal.

Thumbnails generate eagerly: `Maker::Previews::Enqueue.call(user:, node_id:, name:, version_id:)`
fires from the upload and scan seams (see `Maker::Addons::LibraryOutput.enqueue_preview`, which
every upload door calls, and `Library::Reconciler`), so no extra wiring is needed once the
renderer is registered — a newly registered extension is picked up automatically.

**Licensing:** permissive only (CLAUDE.md §9) — no GPL/AGPL toolchains in shipped artifacts. The
current stack: `stl-thumbnailer` (Apache/MIT), `resvg` (MPL-2.0/Apache), rubyzip (BSD-2), F3D
(BSD-3, subprocess-isolated; its OCCT plugin is LGPL and stays out-of-process — and is not shipped
in our image today, so STEP/OBJ/IGES are `unsupported` in-deploy).
