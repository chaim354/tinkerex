# Gerber Thumbnails and the Repo Browser — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Two things the user asked for on 2026-09-07, in one branch: (A) every Gerber layer, drill
file and zipped Gerber export gets a server-rendered thumbnail like every other previewable format;
(B) on the project page a repository section is collapsed by default and, when opened, shows the
Finder-style Miller-columns browser built for the boxes addon's folder picker, instead of the file
tiles and nested sections.

**Architecture (A):** The thumbnail is tracespace's own picture, rendered under **node** as a
subprocess — the same pinned `@tracespace/core` the browser runs, bundled a second time by
`bin/build-tracespace` for node — then rasterised through the existing `SvgRasterizer` (resvg).
A new `Maker::Previews::Gerber` renderer claims every `pcb`-role extension except `.gbrjob`; a new
`Maker::Previews::GerberZip` claims `zip` and renders the BOARD (top side) of a zipped export, or
terminates `unsupported` for any other zip. No second Gerber parser is written anywhere.

**Architecture (B):** `lib/file_chooser.js` grows a `browse` mode and a `mount(container)` entry
that hosts its columns inline (no overlay, no footer); a new `filebrowser` Stimulus controller mounts
it lazily on the first open of a repo section's `<details>`, rooted at the repo's dir node, with
file rows as real links to the file page. `LibraryBrowseController#children` hides `.git`, `.ptr`
and dot-files the way the Files page does.

**Tech Stack:** Rails 8, Stimulus, esbuild (build-time only), node ≥ 18 (runtime image + CI runner
image), resvg, rubyzip, Minitest + Capybara.

---

## Decisions already made (do not relitigate)

- **Node + tracespace, not a Ruby Gerber parser.** A Ruby reimplementation would be the "second
  copy of a traversal" §14b/`Dxf` warns about — a private parser free to drift from the viewer's —
  and could never compose a board. tracespace is MIT, so `bin/build-tracespace`'s "no server-side
  PCB renderer" sentence was about gerbv's licence, which does not apply; that sentence is rewritten
  in A9. Node is exec'd as a subprocess exactly like resvg/pdfium/f3d/stl-thumbnailer; nothing links it.
- **`zip` joins the Registry.** Every zip therefore gets a preview row; a non-Gerber zip terminates
  `unsupported` (the job's ordinary terminal state) after one bounded read. That is the price of a
  board thumbnail for the artefact a fab house is handed, and it is bounded by the job's 32 MB cap.
- **`.gbrjob` gets no thumbnail** — it is JSON; its picture would need its siblings, which a renderer
  handed bytes cannot reach. Say so in the docs; do not build it.
- **Repos only.** Ordinary subfolder sections stay open and keep their tiles. The public project page
  is untouched (it has no `<details>` sections). The repo card (facts line + README) stays above the
  browser.
- **The browser hides what the Files page hides**: `.git`, `*.ptr`, dot-files (`Node.visible_entries`).

## House rules that bind

- Tests: `LIBRARY_BACKEND=share LIBRARY_PATH=$(mktemp -d) bin/rails test <files>`. ONE test process
  at a time in a worktree (shared SQLite DB); retry on `SQLite3::BusyException`.
- Never `git add -A`/`git add .`; stage explicit pathspecs. Never `git stash`. Never `git checkout --`
  a file to undo a mutation — restore from a scratch copy. Clear bootsnap after restoring Ruby:
  `find tmp/cache -maxdepth 1 -name 'bootsnap*' -exec rm -rf {} +`.
- Never write the two-character ERB close sequence inside an ERB comment (§14d).
- Mutation-check every guard (§15): run it, quote the red output, restore, rerun green.
- Read before editing: `docs/invariants/files-preview.md` (Task A), `docs/invariants/measure-view.md`
  §"renderer" rules on `available?`/`available_for?`/revisions (Task A), `docs/invariants/design-system.md`
  (Task B: component selectors live in `components.css` only), `docs/invariants/addons.md` §"file
  chooser" if it exists (Task B — the modal is handed to addon bundles as `ctx.chooseFolder`;
  its contract must not change).

---

## Task A — Gerber thumbnails

**Files**
- Modify: `bin/build-tracespace` (second bundle), `Dockerfile:153-156` (runtime apt), `ci/runner/Dockerfile:79-84` (runner apt)
- Create: `tools/gerber-svg/render.mjs`, `tools/gerber-svg/tracespace.mjs` (vendored, built), `tools/gerber-svg/LICENSE-tracespace.txt` (built), `app/services/maker/previews/gerber.rb`, `app/services/maker/previews/gerber_zip.rb`, `test/services/maker/previews/gerber_test.rb`, `test/services/maker/previews/gerber_zip_test.rb`, `test/fixtures/files/square.gtl`, `test/fixtures/files/gerber-export.zip`
- Modify: `app/services/maker/previews/registry.rb`, `app/services/maker/previews/svg_rasterizer.rb` (`stylesheet:` kwarg), `app/views/files/show.html.erb` (`:gerber` poster shows the thumbnail), `test/services/maker/previews/renderer_contract_test.rb`, `test/services/maker/previews/thumbnail_revision_test.rb`, `test/services/maker/previews/registry_test.rb`, `test/controllers/files_controller_preview_kind_test.rb`, `test/integration/web/gerber_preview_test.rb`, `docs/invariants/files-preview.md`, `CLAUDE.md` §10 (one line), `.gitattributes` if the repo marks binaries

- [ ] **A1. The node bundle.** In `bin/build-tracespace`, after the browser esbuild call (line ~107),
add a second invocation from the same `$WORK` (same pinned packages, same `entry.js`):

```bash
(cd "$WORK" && npx esbuild entry.js \
  --bundle --format=esm --platform=node --minify --target=node18 \
  --outfile=tracespace-node.mjs)
mkdir -p "$ROOT/tools/gerber-svg"
cp "$WORK/tracespace-node.mjs" "$ROOT/tools/gerber-svg/tracespace.mjs"
```
and write the same licence text the script already writes for the browser bundle to
`tools/gerber-svg/LICENSE-tracespace.txt` (copy the existing printf block, changing the path).
`--platform=node` keeps `node:fs/promises`/`node:path` external (esbuild does that itself), so drop
the two `--external:` flags for THIS invocation only. Rewrite the header paragraph that says "this
app ships no server-side PCB renderer and no sidecar (gerbv is GPL, §9)" to: no GPL renderer and no
sidecar; tracespace (MIT) is the one Gerber implementation and it runs in two places from one build
— the browser bundle for the viewer and the node bundle for `Maker::Previews::Gerber` — so the
thumbnail and the viewer can never disagree about a file. Run the script (it needs network for npm);
commit the two generated files. Check `git status` shows only the expected new files.

- [ ] **A2. The render script** — `tools/gerber-svg/render.mjs`:

```js
// tracespace under node: one Gerber/Excellon layer, or one board, to SVG on stdout.
//
// THE SAME PINNED BUNDLE THE BROWSER RUNS (bin/build-tracespace builds both from one node_modules),
// so a thumbnail is the viewer's own picture — never a second parser. Exec'd by
// Maker::Previews::Gerber / GerberZip the way resvg, pdfium and f3d are; nothing links it.
//
//   node render.mjs layer <file>          -> the one layer's SVG (renderLayers)
//   node render.mjs board <file> [<file>…] -> the board's TOP side (renderBoard)
//
// FILENAMES ARE LOAD-BEARING: tracespace identifies what a layer IS from the name (top copper,
// drill, outline…), never from the bytes — gerber_controller.js's header has the argument — so the
// caller writes each member under its real basename before invoking this.
import { read, plot, renderLayers, renderBoard, stringifySvg } from "./tracespace.mjs"

const [mode, ...files] = process.argv.slice(2)
if (!["layer", "board"].includes(mode) || files.length === 0) {
  process.stderr.write("usage: render.mjs layer <file> | board <file> [<file>…]\n")
  process.exit(2)
}

const rendered = renderLayers(plot(await read(files)))
if (rendered.layers.length === 0) {
  process.stderr.write("no layer could be parsed\n")
  process.exit(3)
}
const svg = mode === "layer"
  ? stringifySvg(rendered.rendersById[rendered.layers[0].id])
  : stringifySvg(renderBoard(rendered).top)
process.stdout.write(svg)
```
Probe it by hand once against `test/support/gerber_fixture.rb`'s `MINIMAL_GERBER` written to a
`.gtl` and against the Fusion zip members, and record in the file's header what `renderLayers`
emits for stroke widths (a `stroke-width` attribute on `<path>`, or outlined polygons) — A4 depends
on the answer.

- [ ] **A3. Runtime and CI images.** `Dockerfile` final stage: add `nodejs` to the
`apt-get install --no-install-recommends -y` list beside `libx11-6 libegl1 …`, with a comment: the
Gerber thumbnailer (`tools/gerber-svg`, MIT tracespace under node); exec'd as a subprocess like
resvg/pdfium/f3d, never linked. `ci/runner/Dockerfile`: add `nodejs` to the apt list at line 79-84
with the same one-line comment. (The runner image is rebuilt by ops after merge — say so in the
PR; until then CI skips the render assertions exactly as it does for f3d.)

- [ ] **A4. `SvgRasterizer.to_png` takes a `stylesheet:` kwarg.** Signature
`def to_png(svg, size: 512, stylesheet: STYLESHEET)`; when `stylesheet` is nil no `--stylesheet`
flag is passed. Comment beside `STYLESHEET`: it exists for hairline vector sources; a tracespace
render carries REAL trace widths (measured in A2 — state the finding), so `Gerber` passes nil and a
0.5 mm trace stays 0.5 mm rather than being flattened to 1.5 px. `svg_rasterizer_test.rb`: one case
that `stylesheet: nil` renders (bytes differ from the default render of an SVG with a hairline
stroke, proving the flag is really omitted).

- [ ] **A5. `Maker::Previews::Gerber`** (`app/services/maker/previews/gerber.rb`):

```ruby
require "open3"
require "tmpdir"

module Maker
  module Previews
    # A Gerber layer or an Excellon drill file -> SVG -> PNG thumbnail, rendered by TRACESPACE UNDER
    # NODE (tools/gerber-svg/render.mjs) and rasterised by the shared SvgRasterizer. The same pinned
    # bundle the browser's viewer runs, built twice by bin/build-tracespace — so the tile, the poster
    # and the viewer are one picture, and no Gerber parser exists in Ruby (§14b: a second traversal
    // drifts). Exec'd like resvg/pdfium/f3d; nothing links node into Rails.
    #
    # EVERY `pcb`-ROLE EXTENSION EXCEPT `.gbrjob`. A job file is JSON naming its siblings; its
    # picture would need bytes this renderer is never handed, so it has no thumbnail (files-preview.md).
    # Derived from the one vocabulary, never a second list (§14d); gerber_test.rb pins the relation
    # to FilesController::GERBER_EXTS so the two cannot drift.
    #
    # NO HAIRLINE STYLESHEET: tracespace draws real trace widths (bin/build-tracespace's header and
    # SvgRasterizer::STYLESHEET say why the default exists and why it is wrong here).
    #
    # `available?` gates on node AND the vendored bundle; a box without either degrades every Gerber
    # to `unsupported` — the graceful path Stl/Mesh/Pdf take without their binaries.
    module Gerber
      module_function

      RenderError = Class.new(StandardError)

      EXTENSIONS = (Maker::FileAttachment::ROLE_BY_EXT.select { |_ext, role| role == "pcb" }.keys - %w[gbrjob]).freeze

      SCRIPT = Rails.root.join("tools/gerber-svg/render.mjs").freeze
      BUNDLE = Rails.root.join("tools/gerber-svg/tracespace.mjs").freeze

      def node_bin = ENV.fetch("NODE_BIN", "node")

      def available?
        return false unless BUNDLE.exist?
        _out, status = Open3.capture2e(node_bin, "--version")
        status.success?
      rescue Errno::ENOENT, Errno::EACCES
        false
      end

      THUMBNAIL_REVISION = 1

      def payload_revision(_kind) = THUMBNAIL_REVISION

      # `ext` names the file for tracespace (it identifies the layer from the name). A 512x512 PNG.
      def render(bytes, size: 512, ext: "gbr")
        svg = svg_for(bytes, ext:)
        png = Maker::Previews::SvgRasterizer.to_png(svg, size:, stylesheet: nil)
        { bytes: png.b, content_type: "image/png", width: size, height: size }
      end

      # The SVG step on its own, so a test can assert geometry without decoding a PNG.
      def svg_for(bytes, ext:)
        Dir.mktmpdir("gerber-thumb") do |dir|
          path = File.join(dir, "layer.#{ext.to_s.downcase.delete_prefix('.')}")
          File.binwrite(path, bytes.b)
          run_node("layer", path)
        end
      end

      def run_node(mode, *paths)
        out, err, status = Open3.capture3(node_bin, SCRIPT.to_s, mode, *paths)
        raise RenderError, "tracespace failed (#{status.exitstatus}): #{err.to_s[0, 300]}" unless status.success?
        raise RenderError, "tracespace produced no SVG" unless out.include?("<svg")

        out
      rescue Errno::ENOENT => e
        raise RenderError, "node not runnable: #{e.message}"
      end
    end
  end
end
```
(Fix the one `//` comment line above to `#` — it is a typo in the plan, not intent.) Confirm the job
passes `ext:` — `GeneratePreviewJob#render_with` passes it when the signature declares it (it does).

- [ ] **A6. `Maker::Previews::GerberZip`** (`gerber_zip.rb`) — claims `zip`:

```ruby
module Maker
  module Previews
    # A ZIPPED GERBER EXPORT -> the BOARD's top side as a thumbnail; ANY OTHER ZIP -> `unsupported`.
    # Every CAM tool hands a board over as a zip (files-preview.md), so the artefact a fab house takes
    # is the one whose tile most wants a picture. Registering `zip` means every zip in a library gets
    # one bounded read and a preview row; a zip of firmware terminates in the job's ordinary
    # `unsupported` state (GeneratePreviewJob::Unsupported, the class Mesh raises for GLB) and is
    # never read again until its content changes.
    #
    # Maker::GerberArchive.listing_from decides WHICH members are the board (its job-file rule inside
    # the archive), so this renderer and the zip's own file page agree about the stack. Members are
    # extracted to a tempdir UNDER THEIR BASENAME (tracespace identifies a layer from its name), one
    # subdirectory per member so two same-named members in different folders cannot collide — and
    # NEVER under the member's own path: a zip's entry names are user data and may say `../`.
    # Bounded: MAX_MEMBERS layers and MAX_EXTRACTED_BYTES of declared size, refused as Unsupported.
    module GerberZip
      module_function

      EXTENSIONS = %w[zip].freeze
      MAX_MEMBERS = 64
      MAX_EXTRACTED_BYTES = 64 * 1024 * 1024

      def available? = Maker::Previews::Gerber.available?

      THUMBNAIL_REVISION = 1

      def payload_revision(_kind) = THUMBNAIL_REVISION

      def render(bytes, size: 512)
        svg = svg_for(bytes)
        png = Maker::Previews::SvgRasterizer.to_png(svg, size:, stylesheet: nil)
        { bytes: png.b, content_type: "image/png", width: size, height: size }
      end

      def svg_for(bytes)
        listing = Maker::GerberArchive.listing_from(bytes) or
          raise ::Maker::GeneratePreviewJob::Unsupported, "not a Gerber export"
        zip = Maker::GerberArchive.open_zip(bytes) or
          raise ::Maker::GeneratePreviewJob::Unsupported, "not a readable zip"
        members = listing.stacked
        raise ::Maker::GeneratePreviewJob::Unsupported, "#{members.size} layers is past MAX_MEMBERS" if members.size > MAX_MEMBERS
        declared = members.sum { |name| zip.find_entry(name)&.size.to_i }
        raise ::Maker::GeneratePreviewJob::Unsupported, "declared #{declared} bytes is past the extraction bound" if declared > MAX_EXTRACTED_BYTES

        Dir.mktmpdir("gerber-board") do |dir|
          paths = members.each_with_index.map do |name, i|
            sub = File.join(dir, i.to_s)
            Dir.mkdir(sub)
            path = File.join(sub, File.basename(name))
            File.binwrite(path, zip.find_entry(name).get_input_stream.read)
            path
          end
          Maker::Previews::Gerber.run_node("board", *paths)
        end
      end
    end
  end
end
```
Check `GerberArchive.open_zip` visibility (it is `def self.open_zip`, called from `listing_from`; if
it is `private_class_method`, add a public `read_members` door to `GerberArchive` instead of
reaching in — keep ONE place that opens an archive's bytes). `find_entry` returns nil for a name
that is not in the zip; treat that as Unsupported rather than NoMethodError.

- [ ] **A7. Registry, contract, revision and kind tests.**
  - `registry.rb` `FORMAT_RENDERERS`: add `**Maker::Previews::Gerber::EXTENSIONS.index_with { Maker::Previews::Gerber }`
    (a comment: derived from the `pcb` role, never listed twice) and `"zip" => Maker::Previews::GerberZip`.
    Keep `FORMAT_RENDERERS` on top of the text entries as its comment demands.
  - `registry_test.rb`: `gtl`, `gbl`, `drl`, `xln` → `Gerber`; `zip` → `GerberZip`; `gbrjob` → nil;
    and `Gerber::EXTENSIONS.sort + ["gbrjob"] == FilesController::GERBER_EXTS.sort` (the drift pin).
  - `renderer_contract_test.rb` `FIXTURES`: `Maker::Previews::Gerber => "square.gtl"`
    (`test/fixtures/files/square.gtl` = `GerberFixture::MINIMAL_GERBER` verbatim) and
    `Maker::Previews::GerberZip => "gerber-export.zip"` (build ONCE with `GerberFixture#fusion_zip`
    or the same rubyzip recipe and commit the bytes; comment that it is committed rather than built
    per run because rubyzip stamps DOS times).
  - `thumbnail_revision_test.rb` `THUMBNAIL_REVISIONS`: `"a.gtl" => 1, # Gerber — every pcb ext but gbrjob`
    and `"a.zip" => 1, # GerberZip`.
  - `files_controller_preview_kind_test.rb`: `preview_kind("x.gtl") == :gerber` still (it returns
    before `:thumbnail`); `preview_kind("firmware.zip") == :thumbnail` now, with a comment naming
    why (GerberZip claims zip; `FilesController#show` still overrides a Gerber zip to `:gerber`).

- [ ] **A8. Renderer tests** — `gerber_test.rb`: `svg_for(MINIMAL_GERBER, ext: "gtl")` contains
`<svg` and a `<path`; `svg_for(MINIMAL_DRILL, ext: "drl")` contains a `<circle`; `render` returns
`image/png` with the PNG magic and `width: 512`; `render` of the square differs in bytes from a
render of an empty layer (`"%FSLAX24Y24*%\n%MOMM*%\nM02*\n"` — if tracespace refuses an empty layer,
`run_node` raises RenderError; assert that instead); `available?` is false with `NODE_BIN` pointed
at a non-existent path (use `ENV` stubbing via the house `replacing` helper or a `with_env` helper
if one exists — never `Object#stub`). Every render case `skip "node not available"` when
`Gerber.available?` is false, and the skip message names it (the f3d precedent). `gerber_zip_test.rb`:
the fixture zip renders a board SVG (contains `<svg` and a `<path`), a zip with no Gerber member
raises `GeneratePreviewJob::Unsupported`, a zip whose member is named `../escape.gtl` still renders
and leaves nothing outside the tempdir (assert `Dir.exist?` false on the escape path), a zip past
`MAX_MEMBERS` raises Unsupported without extracting (count `File.binwrite` calls or assert no tempdir
child — simplest: give the stub 65 tiny members and assert the exception message).

- [ ] **A9. Surfaces and docs.**
  - `app/views/files/show.html.erb`, the `:gerber` branch's `.model-viewer-fallback`: before the
    sentence, `<% if @thumbnail&.status == "ready" && @thumbnail.asset.attached? %><img src="<%= url_for(@thumbnail.asset) %>" alt="Preview of <%= @node.name %>" class="preview-image"><% end %>`
    — the `:model3d` branch's exact shape. `gerber_preview_test.rb`: one case that a `.gtl` page whose
    preview row is `ready` with an attached asset renders that `<img>` inside `.gerber-viewer .model-viewer-fallback`
    (build the row the way `files_flow_test.rb` builds a ready poster — grep `status: "ready"` there).
  - `docs/invariants/files-preview.md`, `:gerber` section, new paragraph after the viewer-chrome one:
    **THE THUMBNAIL IS TRACESPACE TOO, UNDER NODE, FROM THE SAME BUILD.** State: one script builds
    two bundles from one pinned node_modules; `tools/gerber-svg/render.mjs` is exec'd like resvg;
    `Gerber` claims every `pcb` extension but `.gbrjob` (why); `GerberZip` claims `zip` and what a
    non-Gerber zip costs (one bounded read, a terminal `unsupported` row); extraction is by basename
    in per-member subdirs, bounded, never by the entry's own path; the hairline stylesheet is NOT
    applied (why); `available?` gates on node + bundle and a box without them degrades to
    `unsupported`; the CI runner image carries node for the same reason it carries resvg.
  - `CLAUDE.md` §10 `/tools` line: add `gerber-svg` (tracespace under node — the Gerber
    thumbnailer, same server-side status as stl-thumbnailer). One line; the docs hygiene ceiling
    is a ratchet.
  - `bin/build-tracespace` header (A1).

- [ ] **A10. Run, mutate, commit.**
```bash
LIBRARY_BACKEND=share LIBRARY_PATH=$(mktemp -d) bin/rails test test/services/maker/previews test/controllers/files_controller_preview_kind_test.rb test/integration/web/gerber_preview_test.rb test/docs_hygiene_test.rb
```
Mutations (run for real, quote, restore, green): (M1) `Gerber::EXTENSIONS` written as a literal
missing `xln` → the registry drift pin reds; (M2) `GerberZip#svg_for` writing members under
`File.join(dir, name)` (the entry's own path) → the `../escape.gtl` case reds; (M3) `stylesheet: nil`
→ `stylesheet: STYLESHEET` in `Gerber.render` → A4's rasterizer case does NOT red (it tests the
rasterizer, not the caller) — so ADD a Gerber case that pins it: render a layer whose only geometry is
a 2 mm-wide trace on a 10 mm board and assert the PNG differs from the same render with the
stylesheet forced (call `to_png` twice yourself); (M4) `"zip" => GerberZip` removed from the registry
→ `thumbnail_revision_test` reds on `a.zip`.
Commit with explicit pathspecs: `Gerber layers, drills and zipped exports get thumbnails — tracespace under node`.

---

## Task B — repos collapsed, browsed Finder-style

**Files**
- Modify: `app/controllers/library_browse_controller.rb:11-18`, `app/javascript/lib/file_chooser.js`, `app/views/projects/_file_tree_section.html.erb`, `app/assets/stylesheets/components.css:254-296`, `app/assets/stylesheets/pages/projects.css`, `test/integration/web/project_attachments_test.rb:176-196`, `test/integration/web/library_browse_test.rb`, `test/integration/web/template_hygiene_test.rb` (fixture), `test/system/shell_test.rb` (optional, see B7)
- Create: `app/javascript/controllers/filebrowser_controller.js`, `app/views/projects/_repo_browser.html.erb`, `test/system/repo_browser_test.rb`

- [ ] **B1. The browse endpoint hides what the Files page hides.** In `LibraryBrowseController#children`:
`scope = current_user.nodes.present.visible_entries.where(parent_node_id: parent&.node_id)`
(`Node.visible_entries` — `app/models/node.rb:67` — drops `.git`, `*.ptr` and dot-files; the chooser
had been offering `.git` as a destination, which the write guards refuse anyway). Comment it.
`library_browse_test.rb`: a folder holding `.git`, `notes.ptr`, `.DS_Store`, `src/` and `main.c`
answers `src` and `main.c` only (with `files=1`) and `src` only without.

- [ ] **B2. `lib/file_chooser.js` — a `browse` mode and an inline host.** Keep every existing
behaviour of `folder`/`file` mode and the modal byte-for-byte in effect (`file_chooser_test.rb` and
the addon contract `ctx.chooseFolder`/`ctx.chooseFile` must stay green). Changes:
  - Constructor options gain `rootId = null` (the node id the first column lists — the library root
    when null) and `fileUrlTemplate = null` (a string containing `__ID__`).
  - `this.host` replaces the `this.overlay`-as-host assumption: `buildModal()` sets `this.host` to the
    `.filechooser` element; `render()` returns early on `!this.host`; the footer elements
    (`selEl`, `chooseBtn`, `newWrap`) are used only when present.
  - `mount(container)`: builds
    `<div class="filechooser filechooser--inline"><div class="filechooser-bar"><button type="button" class="btn ghost filechooser-back" aria-label="Back">← Back</button><span class="filechooser-crumbs"></span></div><div class="filechooser-cols"></div></div>`
    into `container`, sets `this.host`, wires Back, and calls `render()`. `destroy()` empties the
    container. No overlay, no keydown listener, no promise.
  - `render()`: `levels = [{ id: this.rootId, name: this.rootLabel }, ...this.trail]`; the first
    column lists `childrenOf(this.rootId)`. `submitNewFolder`'s `parentId` falls back to `this.rootId`
    rather than null (browse mode never shows New Folder, but the fallback keeps the modal correct if
    a caller ever passes `rootId`).
  - `childrenOf`: `files=1` when mode is `file` OR `browse`.
  - `columnEl`, browse mode: a folder is `<button type="button" class="filechooser-row">` (click →
    `descend`, which sets NO selection in browse mode); a file is
    `<a class="filechooser-row is-file" href="…">` with `href = fileUrlTemplate.replace("__ID__", encodeURIComponent(entry.node_id))`
    and no click handler — a real link, so middle-click and keyboard work. Other modes keep their
    `div` rows exactly as they are. `textContent`, never innerHTML, as today.
  - Header comment: add browse mode's line to the two-mode list and say why the class hosts inline
    (the repo section on the project page; design rule: a verb two surfaces perform gets one module).

- [ ] **B3. `filebrowser_controller.js`:**

```js
import { Controller } from "@hotwired/stimulus"
import { FileChooser } from "lib/file_chooser"

// A REPOSITORY'S FILES, BROWSED FINDER-STYLE INSIDE ITS OWN <details> on the project page — the
// Miller-columns module the boxes addon's folder picker uses (lib/file_chooser.js), mounted inline
// in `browse` mode: folders descend, files are links to their file page. Mounted LAZILY on the first
// open of the enclosing <details>, because a repo section is closed by default (2026-09-07, at the
// user's request) and a browser nobody opened should cost no request. The <details> is an ANCESTOR,
// which Stimulus actions cannot target, so the toggle listener is attached by hand and removed on
// disconnect. Turbo restores a snapshot with the columns in it and then connects a fresh controller
// that holds nothing for them — so `connect` mounts again if the details is already open.
export default class extends Controller {
  static values = { childrenUrl: String, root: String, rootLabel: String, fileUrlTemplate: String }
  static targets = ["mount"]

  connect() {
    this.details = this.element.closest("details")
    this.onToggle = () => this.reveal()
    this.details?.addEventListener("toggle", this.onToggle)
    if (this.details?.open) this.reveal()
  }

  disconnect() {
    this.details?.removeEventListener("toggle", this.onToggle)
    this.chooser?.destroy()
    this.chooser = null
  }

  reveal() {
    if (this.chooser || !this.details?.open) return
    this.chooser = new FileChooser({
      mode: "browse",
      childrenUrl: this.childrenUrlValue,
      rootId: this.rootValue,
      rootLabel: this.rootLabelValue,
      fileUrlTemplate: this.fileUrlTemplateValue
    })
    this.chooser.mount(this.mountTarget)
  }
}
```

- [ ] **B4. The partial and the section.** `app/views/projects/_repo_browser.html.erb`:

```erb
<%#
  THE REPOSITORY'S FILES, FINDER-STYLE (2026-09-07, at the user's request): the Miller-columns
  browser the boxes addon's folder picker is built on (lib/file_chooser.js, browse mode), mounted
  inline by filebrowser_controller.js the first time this section is opened. It REPLACES the tiles,
  the list and the nested subfolder sections a plain folder renders — a repository is navigated,
  not unrolled. The data is LibraryBrowseController#children, which hides what the Files page
  hides (.git, *.ptr, dot-files). The file link is built from a template the server writes here,
  so the module never learns a route.

  Local: dir (Maker::ProjectFolderListing::Dir), a repo? dir.
%>
<div class="repo-browser"
     data-controller="filebrowser"
     data-filebrowser-children-url-value="<%= library_children_path %>"
     data-filebrowser-root-value="<%= dir.node_id %>"
     data-filebrowser-root-label-value="<%= dir.name %>"
     data-filebrowser-file-url-template-value="<%= file_path("__ID__") %>">
  <div data-filebrowser-target="mount"></div>
</div>
```
(`file_path("__ID__")` renders `/files/__ID__` — confirm the route does not escape the underscores;
if it does, build the template as `file_path("ID").sub("ID", "__ID__")`.)

`_file_tree_section.html.erb`: `<details<%= " open" unless dir.repo? %>>`; inside, after the
summary: `if dir.repo?` → render the card (guarded as today) then `projects/repo_browser`, and render
NEITHER the tiles/rows NOR the nested `file_tree_section` collection; `else` → today's body
unchanged. Rewrite the header's "ALWAYS OPEN" paragraph: a real subfolder is always open; a
REPOSITORY is the second exception since 2026-09-07 — closed by default, and its contents are the
browser, not sections (say why: a repo is a tree the maker navigates, and its files are edited on
their own pages).

- [ ] **B5. CSS.** `components.css`, the chooser block: add
`.filechooser--inline { position: static; width: 100%; max-height: none; height: 320px; border: 1px solid var(--line); border-radius: var(--radius-panel); }`,
`.filechooser-bar { display: flex; align-items: center; gap: 8px; padding: 6px 10px; border-bottom: 1px solid var(--line); }`
(`.filechooser-crumbs` inside it keeps its font; give it `flex: 1; min-width: 0; border-bottom: 0` under
`.filechooser-bar .filechooser-crumbs`), and reset the new row elements so a `button`/`a` row looks
like the `div` row: `.filechooser-row { appearance: none; border: 0; background: none; width: 100%; text-align: left; font: inherit; color: inherit; text-decoration: none; display: block; }`
(merge into the existing `.filechooser-row` rule — keep every property it already has). Check the
`@media` narrow rule at the end of the block still applies to the inline variant (one column at a
time on a phone, Back to pop). `pages/projects.css`: `.repo-browser { margin-top: 8px; }`. Run
`test/css_hygiene_test.rb`.

- [ ] **B6. Tests.**
  - `project_attachments_test.rb:176` — rename to "a repository inside the folder is a nested section, badged, closed by default, browsed rather than unrolled" and assert: the summary keeps badge + Commits/History links (unchanged block); `assert_select ".file-tree-section details[open] summary", text: /firmware/, count: 0`; `assert_select ".file-tree-section .repo-browser[data-controller=?]", "filebrowser"`; `assert_select ".repo-browser[data-filebrowser-root-value=?]", firmware.node_id`; `assert_select ".repo-browser[data-filebrowser-file-url-template-value=?]", file_path("__ID__")`; `assert_select ".attachment-tile .grid-name", text: "main.c", count: 0`; and a nested subfolder of the repo renders NO `.file-tree-section` of its own (add `src` under firmware in the fixture and assert `text: /src/, count: 0` on section summaries). The two existing `details[open]` cases (lines 379, 401) stay as they are — they are the non-repo control.
  - `template_hygiene_test.rb`: the page fixture must render `_repo_browser` — add a repo dir (`Library::RepoMetadata::DIR_NAME` child) under the project folder if the fixture has none; the sweep needs the partial's ERB comment rendered once.
  - `test/system/repo_browser_test.rb` (rows only — `project_folder_rows!` from `test_helper.rb:171`; NEVER `ensure_library_folder!`, a real mkdir): a repo dir `firmware` with `.git`, `README.md`, `main.c`, `src/led.c`, `.DS_Store`. Visit the project page: `assert_no_selector ".filechooser--inline"` (closed, nothing mounted); `find("summary", text: /firmware/).click`; `assert_selector ".filechooser--inline .filechooser-col", count: 1`; the column lists `src`, `README.md`, `main.c` and NOT `.git`/`.DS_Store` (`assert_no_selector ".filechooser-row", text: ".git"`); folders before files; click `src` → `count: 2` columns with `led.c`; `click_link "📄 led.c"` (or find by `href`) → `assert_current_path file_path(led.node_id)`; back → the section is closed again? (a full navigation; do not assert). `assert_no_console_errors`. Also one case: the ← Back button pops a column. Mutation: `visible_entries` → `present` in B1 reds the `.git` assertion; the `toggle` listener removed reds the first column count.
  - `file_chooser_test.rb`, `library_browse_test.rb`, `project_repo_card_test.rb`, `page_query_budget_test.rb` all stay green — run them.

- [ ] **B7. Optional, do it if cheap:** `test/system/shell_test.rb`'s signed-in sweep has no repo in
its project. If `project_folder_rows!` makes adding one two lines, add a repo dir and, on the project
page, open it and `assert_selector ".filechooser--inline"` before the overflow check at 375 px (the
narrow rule shows one column). Otherwise skip and say so.

- [ ] **B8. Run, mutate, commit.**
```bash
LIBRARY_BACKEND=share LIBRARY_PATH=$(mktemp -d) bin/rails test test/integration/web/project_attachments_test.rb test/integration/web/library_browse_test.rb test/integration/web/template_hygiene_test.rb test/integration/web/project_repo_card_test.rb test/integration/web/page_query_budget_test.rb test/css_hygiene_test.rb test/stimulus_hygiene_test.rb test/system/repo_browser_test.rb test/system/file_chooser_test.rb
```
Commit: `A repository on the project page is collapsed, and opens as a Finder-style browser`.

---

## After both tasks (the integrator, not the implementers)

Merge both branches, then `export TINKEREX_SYNC_DIR=/Users/charlesschwartz/Desktop/repos/tinkerex-sync && bin/ci`
— every gate green, three identical run counts. PR, arc, CI watch. After merge and deploy: rebuild
the CI runner image (node), and run `bin/rails previews:backfill_missing` in each deployed container
so existing Gerbers get their thumbnails.

## Self-review notes

- Coverage: thumbnails for layers/drills (A5), zips (A6), surfaces (A9), images (A3); repos closed
  (B4), Finder browser (B2-B4), hidden clutter (B1); tests for each (A7-A8, B6).
- Names used consistently: `Maker::Previews::Gerber`/`GerberZip`, `tools/gerber-svg/render.mjs`,
  `filebrowser` controller with values `childrenUrl`/`root`/`rootLabel`/`fileUrlTemplate`, mode
  `browse`, `.filechooser--inline`, `.repo-browser`.
