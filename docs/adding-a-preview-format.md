# Adding a preview format

The preview system renders a file's bytes to a **PNG thumbnail** behind a small seam
(`app/services/maker/previews/`). Adding a format is four steps.

1. **Write a renderer** in `app/services/maker/previews/<ext>.rb`. It responds to:
   - `available?` → Boolean — is the toolchain present? (Pure-Ruby renderers return `true`.)
   - `EXTENSIONS` → array of **lowercase** extensions it claims.
   - `render(bytes, size:) → { bytes:, content_type:, width:, height: }` — `content_type` must be
     an **inline-safe raster type** (`image/png` in almost all cases). If your source is 2D vector,
     build an SVG and hand it to `Maker::Previews::SvgRasterizer.to_png` (that is what `Dxf`/`Lbrn2`
     do) — do **not** emit `image/svg+xml`, the web layer will not inline it (SVG can carry script).
   - Raise a renderer-specific error (e.g. `RenderError`) on bad input, never a bare crash — the
     job classifies a known "no renderable content" condition as `unsupported`/`failed`.

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

Thumbnails generate eagerly: `Maker::Previews::Enqueue.call(user:, node_id:, name:, version_id:)`
fires from the upload, API-commit, and scan seams (see `FilesController#enqueue_preview`,
`V1::CommitsController#finalize`, `Library::Reconciler`), so no extra wiring is needed once the
renderer is registered — a newly registered extension is picked up automatically.

**Licensing:** permissive only (CLAUDE.md §9) — no GPL/AGPL toolchains in shipped artifacts. The
current stack: `stl-thumbnailer` (Apache/MIT), `resvg` (MPL-2.0/Apache), rubyzip (BSD-2), F3D
(BSD-3, subprocess-isolated; its OCCT plugin is LGPL and stays out-of-process — and is not shipped
in our image today, so STEP/OBJ/IGES are `unsupported` in-deploy).
