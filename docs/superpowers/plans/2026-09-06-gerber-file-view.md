# Gerber File View Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A Gerber is a file like any other on the project pages, and its board renders only on its
own file page — wearing the 3D viewer's chrome (poster, launch button, one bar: Fit, Fullscreen,
✕ Image, plus Top/Bottom and the layer toggles).

**Architecture:** Two batches. (A) The Fabrication panels on the private and public project pages
go, together with the board grouping that only they read (`Maker::GerberSets.for`, `Board`,
`Archive`, `PublicProject#gerber_boards`, the helper's badge labels and `gerber_layers_for(board)`);
what stays of `GerberSets` is `job_layer_names`, the `.gbrjob` reader `FilesController#show` uses.
(B) The file page's `:gerber` branch becomes a `.model-viewer.gerber-viewer` driven by a lazy
`gerber_controller.js` — nothing fetched until "View board" / "View layer" — with the 3D viewer's
`.model-viewer*` CSS doing the chrome and `.gerber-viewer` saying only what an `<svg>` stage needs.

**Tech Stack:** Rails 8 views/helpers, Stimulus, tracespace (vendored), `lib/svg_pan_zoom.js`,
Minitest request + Capybara system tests.

**Decided by the user (2026-09-06):** "Project page: tiles, not a panel" AND "Same viewer chrome as
3D". NOT chosen: a separate file type for Gerber zips. Not asked for and not built: a "Board" mode on a
single layer's page (a loose set with no `.gbrjob` renders one layer per page now — flag it in the PR
as the one thing the panel could do that the file page cannot).

**House rules that bind here:** never `git add -A` (explicit pathspecs); one full-suite run at a
time (shared SQLite test DB — retry on `SQLite3::BusyException`); tests need
`LIBRARY_BACKEND=share LIBRARY_PATH=$(mktemp -d)`; after restoring a mutated Ruby file run
`find tmp/cache -maxdepth 1 -name 'bootsnap*' -exec rm -rf {} +`; never write `%>` inside an ERB
comment (§14d); every mutation check is run for real and its output quoted in the report.

---

## Files

**Task A — the panel goes**
- Delete: `app/views/projects/_fabrication.html.erb`, `app/views/public/projects/_fabrication.html.erb`
- Modify: `app/views/projects/show.html.erb:77-80`, `app/views/public/projects/show.html.erb:127`,
  `app/services/maker/public_project.rb:210-223`, `app/services/maker/gerber_sets.rb` (rewrite),
  `app/helpers/files_helper.rb:174-248`, `app/services/maker/gerber_archive.rb:28,61` (comments),
  `app/services/maker/three_mf_manifest.rb:80` (comment),
  `test/services/maker/gerber_sets_test.rb` (rewrite),
  `test/integration/web/page_query_budget_test.rb:146-148,241-242` (comments),
  `test/integration/web/template_hygiene_test.rb:152-162` (comment)

**Task B — the file page wears the 3D viewer's chrome**
- Modify: `app/views/files/show.html.erb:149-191`, `app/javascript/controllers/gerber_controller.js`
  (rewrite), `app/assets/stylesheets/pages/preview.css:333-372`,
  `app/controllers/files_controller.rb:469-486,1490-1508` (comments),
  `test/integration/web/gerber_preview_test.rb` (rewrite), `test/system/gerber_test.rb` (rewrite),
  `test/system/shell_test.rb:159-168,237-253`, `docs/invariants/files-preview.md:105-190`

Run Task A first, commit, then Task B, commit. The two share no file.

---

## Task A: the Fabrication panels and the board grouping go

- [ ] **A1. Delete the two partials and their render lines.**

```bash
git rm app/views/projects/_fabrication.html.erb app/views/public/projects/_fabrication.html.erb
```

In `app/views/projects/show.html.erb` remove these four lines (77-80):

```erb
  <%# The board's fabrication outputs, rendered by tracespace. Beside Schematics because they are
      the same subject one stage further along — the design, then what goes to the board house —
      and the partial decides for itself whether the folder holds any. %>
  <%= render "fabrication" %>
```

In `app/views/public/projects/show.html.erb` remove line 127: `  <%= render "fabrication", pub: @pub %>`.

- [ ] **A2. `Maker::PublicProject`: remove `gerber_boards`** and the comment above it (lines 210-223,
from `# Every board this folder holds` through `end`). Nothing else in the class reads it.

- [ ] **A3. Rewrite `app/services/maker/gerber_sets.rb`** to exactly this:

```ruby
module Maker
  # WHAT A `.gbrjob` SAYS A BOARD IS MADE OF. The Gerber job file is the export's own manifest —
  # `FilesAttributes[].Path` names exactly the layers that belong to the board — so where one exists
  # and parses, its list is what a job file's own page stacks (FilesController#gerber_layers_for,
  # the one caller). Where there is no job, or it does not parse, every pcb-role sibling is the set:
  # the honest answer when nothing has told us otherwise, and the one that keeps a hand-made export
  # working. `Maker::GerberArchive` applies the same rule to a `.gbrjob` INSIDE a zip.
  #
  # THE JOB IS MATCHED BY BASENAME AMONG THE DIRECTORY'S OWN SIBLINGS, NEVER BY PATH. `Path` is
  # written by the CAM tool and may carry any prefix the exporter felt like (KiCad writes a bare
  # name, some tools write `./name`, some an absolute path from the author's machine). Resolving it
  # as a path would reach outside the folder — or, on a library where a name repeats, at the wrong
  # file. `File.basename` against the rows already in hand cannot do either, and a name the
  # directory does not hold is simply dropped.
  #
  # THIS CLASS USED TO GROUP A FOLDER'S GERBERS INTO BOARDS for the project pages' Fabrication
  # panels (one board per folder, a zip a board of its own, the list and the stack two different
  # lists). The panels went on 2026-09-06 — a Gerber is a file like any other on a project page and
  # the board renders on its own file page — and the grouping went with them; `git show
  # 2addf8f:app/services/maker/gerber_sets.rb` holds it should a board mode on a layer's page ever
  # want it back.
  class GerberSets
    # A `.gbrjob` past this is not read. It is JSON naming a few dozen files; anything larger is not
    # a job file, and reading it would be a stream of arbitrary length off the user's NAS into this
    # request for nothing (`Maker::Readme::READ_LIMIT` makes the identical argument, and for the
    # identical reason: the catalog already knows the size, so the check costs no read at all).
    READ_LIMIT = 512 * 1024

    # THE BASENAMES ONE `.gbrjob` NAMES, as a Set, or nil when there is nothing usable.
    #
    # EVERY FAILURE MODE COLLAPSES TO nil ON PURPOSE — an unreadable file, an unmounted share,
    # invalid JSON, a JSON document that is not an object, a missing or wrongly-shaped
    # `FilesAttributes`. The caller answers all of them the same way (use the directory), so
    # distinguishing them here would be a branch nothing acts on.
    #
    # `rescue JSON::ParserError` BESIDE THE PORT'S OWN TWO, NEVER A BARE `rescue`: a job file is
    # user data and malformed JSON is routine, but a NoMethodError in this method is a bug and must
    # stay loud.
    def self.job_layer_names(user:, node:)
      return nil if node.size.to_i > READ_LIMIT

      bytes = FileLayer.current.read(user, node_id: node.node_id)
      doc = JSON.parse(bytes.dup.force_encoding(Encoding::UTF_8).scrub)
      return nil unless doc.is_a?(Hash)

      names = Array(doc["FilesAttributes"]).filter_map do |entry|
        File.basename(entry["Path"].to_s) if entry.is_a?(Hash) && entry["Path"].present?
      end
      names.any? ? names.to_set : nil
    rescue FileLayer::NotFound, FileLayer::FetchError, JSON::ParserError
      nil
    end
  end
end
```

- [ ] **A4. `app/helpers/files_helper.rb`:** delete `#gerber?` with its comment (lines 174-181),
`GERBER_LAYER_LABELS` and `#gerber_layer_label` with their comment (183-214), and
`#gerber_layers_for(board)` with its comment (216-233). Keep `#gerber_archive_entry` and replace
its comment with:

```ruby
  # THE ONE WIRE SHAPE gerber_controller.js READS FOR A ZIPPED EXPORT — one entry, the zip's own
  # name and URL, `archive: true`, and the member paths the browser extracts with JSZip after
  # fetching the zip once through the same URL a download uses (Maker::GerberArchive's header).
  # Built here rather than as a literal in FilesController#show so that only a browser ever reads
  # these keys and no second spelling of them exists for a server-side assertion to miss drifting.
  # Its loose-layer sibling is `FilesController#gerber_layer_for` (`{ name:, url: }`).
```

Then grep to confirm nothing else names the removed methods:

```bash
grep -rnE 'gerber_layer_label|GERBER_LAYER_LABELS|gerber_layers_for\(board|gerber_boards|\bgerber\?\(' app lib test config
```
Expected: only `app/controllers/files_controller.rb`'s own `gerber_layers_for(node)` /
`gerber_layers_for(@node)` lines (a different, controller-private method) — nothing else.

- [ ] **A5. Comment sweeps.** In `app/services/maker/gerber_archive.rb` line 28 change
"`Maker::GerberSets`'s rule for a folder" to "`Maker::GerberSets.job_layer_names`'s rule for a
folder's job file"; line 61 change "on the public page the OWNER, never the visitor (GerberSets's
rule)" to "the file page's current user". In `app/services/maker/three_mf_manifest.rb` line 80
change "on a public page the OWNER, never the visitor (Maker::GerberSets's rule)" to "the file
page's current user; nothing public reads a manifest". Grep afterwards:

```bash
grep -rnE 'Fabrication|fabrication panel|_fabrication' app lib config
```
Expected: no output.

- [ ] **A6. Rewrite `test/services/maker/gerber_sets_test.rb`** against `job_layer_names` alone. Keep
the header's share-pinning argument; drop the `rows_for`/`boards_for` helpers and every board case.
Full file:

```ruby
require "test_helper"
require "support/gerber_fixture"

module Maker
  # WHAT A `.gbrjob` NAMES — `Maker::GerberSets.job_layer_names`, the `.gbrjob` reader behind a job
  # file's own page (FilesController#gerber_layers_for). Tested as a unit because it is one port
  # read plus a parse, and driving the file page to ask it would be slower and no more true; which
  # markup that page renders is test/integration/web/gerber_preview_test.rb's subject.
  #
  # SHARE IS PINNED BEFORE ANY NODE IS CREATED, because `job_layer_names` really opens the `.gbrjob`
  # through the port: a fixture with no bytes behind it would answer nil on every leg and the
  # positive cases would pass for the wrong reason.
  class GerberSetsTest < ActiveSupport::TestCase
    include GerberFixture

    setup do
      @root = use_fresh_share_library!
      @user = User.create!(email: "gerber-sets-#{SecureRandom.hex(4)}@example.com",
                           confirmed_at: Time.current, omniauth_signup: true)
    end

    teardown { FileLayer.reset! }

    def names_of(job) = Maker::GerberSets.job_layer_names(user: @user, node: job)

    test "a job names its layers by basename, as a Set" do
      dir = gerber_dir!(name: "pcb")
      job = write_gerber!(name: "board.gbrjob", parent_node_id: dir.node_id,
                          body: gerber_job("board.gtl", "board.gbl", "board.drl"))

      assert_equal Set["board.gtl", "board.gbl", "board.drl"], names_of(job)
    end

    # `Path` CARRIES WHATEVER PREFIX THE EXPORTER FELT LIKE, and it is reduced to a BASENAME — never
    # resolved as a path, which could reach outside the folder or land on a name that repeats
    # elsewhere in the library. A backslash is not a path separator here: only the POSIX basename
    # resolves, so a Windows-style path yields the whole string and matches nothing.
    test "a job's Path is reduced to its POSIX basename, prefix and all" do
      dir = gerber_dir!(name: "pcb")
      job = write_gerber!(name: "board.gbrjob", parent_node_id: dir.node_id,
                          body: JSON.generate("FilesAttributes" => [
                                                { "Path" => "/home/someone/export/board.gtl" },
                                                { "Path" => "./board.drl" },
                                                { "Path" => "gerbers\\board.gbl" }
                                              ]))

      assert_equal Set["board.gtl", "board.drl", "gerbers\\board.gbl"], names_of(job)
    end

    # EVERY FAILURE MODE IS nil, which the caller turns into "every Gerber in the directory" — the
    # honest answer when nothing has told us otherwise, and the one that keeps a hand-made export
    # working.
    test "a malformed, non-object, attribute-less or empty job answers nil" do
      {
        "not json at all" => "{{{",
        "json that is not an object" => "[1, 2, 3]",
        "an object with no FilesAttributes" => JSON.generate("Header" => {}),
        "FilesAttributes with no usable Path" => JSON.generate("FilesAttributes" => [ { "Path" => "" }, 7 ]),
        "an empty FilesAttributes" => JSON.generate("FilesAttributes" => [])
      }.each do |why, body|
        dir = gerber_dir!(name: "pcb-#{SecureRandom.hex(3)}")
        job = write_gerber!(name: "board.gbrjob", parent_node_id: dir.node_id, body:)

        assert_nil names_of(job), why
      end
    end

    # THE SIZE CHECK IS ON THE CATALOG'S OWN COLUMN, so an oversized job costs no read at all —
    # Maker::Readme::READ_LIMIT makes the identical argument. Asserted through the row rather than
    # by writing half a megabyte of JSON, and the read count is what proves "never read".
    test "a job past READ_LIMIT is never read" do
      dir = gerber_dir!(name: "pcb")
      job = write_gerber!(name: "board.gbrjob", parent_node_id: dir.node_id,
                          body: gerber_job("board.gtl"))
      job.update_column(:size, Maker::GerberSets::READ_LIMIT + 1)

      reads = 0
      port = FileLayer.current
      port.define_singleton_method(:read) { |*args, **kw| reads += 1; super(*args, **kw) }
      begin
        assert_nil names_of(job.reload)
      ensure
        port.singleton_class.remove_method(:read)
      end
      assert_equal 0, reads
    end

    # AN UNMOUNTED SHARE MUST NOT 500 THE PAGE. The port's two conditions are rescued beside
    # JSON::ParserError precisely so a job file whose bytes are unreachable still renders its page
    # from the directory — driven here by deleting the bytes under a row that still claims them.
    test "a job whose bytes are gone answers nil rather than raising" do
      dir = gerber_dir!(name: "pcb")
      job = write_gerber!(name: "board.gbrjob", parent_node_id: dir.node_id,
                          body: gerber_job("board.gtl"))
      @root.join(job.storage_path).delete

      assert_nil names_of(job)
    end
  end
end
```

Check `gerber_job` in `test/support/gerber_fixture.rb` takes a splat of names (it does today:
`gerber_job("board.gtl", "board.gbl", "board.drl")` in the old tests). If the singleton `read`
override collides with the port's arity, mirror the pattern already used in
`test/services/maker/gerber_archive_test.rb` (the "is never read" case there counts reads the same way).

Run: `LIBRARY_BACKEND=share LIBRARY_PATH=$(mktemp -d) bin/rails test test/services/maker/gerber_sets_test.rb`
Expected: 5 runs, 0 failures.

- [ ] **A7. Comment rewrites in two tests (the seeds stay).** `test/integration/web/page_query_budget_test.rb`
lines 146-148 become:

```ruby
          # A GERBER PER SUBFOLDER: pcb-role rows are ordinary file rows on this page (the
          # Fabrication panel that once grouped them went on 2026-09-06), kept so the seed still
          # holds a subfolder of them — a shape the tree section renders and must not query per row.
```
and lines 241-242 become the same sentence with "the public Fabrication panel" in place of "the
Fabrication panel". `test/integration/web/template_hygiene_test.rb` lines 152-162: replace the
paragraph beginning `# A GERBER SET IN ITS OWN SUBFOLDER, OR projects/_fabrication` (through the
sentence ending `for that reason.`) with:

```ruby
      # A GERBER SET IN ITS OWN SUBFOLDER, so the project pages render a subfolder of pcb-role rows
      # through the ordinary tree section — there is no Fabrication panel since 2026-09-06, and the
      # only Gerber-specific markup left is the FILE page's viewer, which gerber_preview_test.rb
      # drives with real bytes on share. NO `.gbrjob`: FilesController#gerber_layers_for would READ
      # it through the port, and every node this fixture seeds has no bytes behind it, which is
      # exactly the backend-dependence this class's header rules out.
```

- [ ] **A8. Run the three affected suites and commit.**

```bash
LIBRARY_BACKEND=share LIBRARY_PATH=$(mktemp -d) bin/rails test test/services/maker/gerber_sets_test.rb test/integration/web/page_query_budget_test.rb test/integration/web/template_hygiene_test.rb test/integration/web/projects_flow_test.rb test/services/maker/public_project_test.rb
```
(Skip any file in that list that does not exist.) `test/integration/web/gerber_preview_test.rb` is
RED after this task until Task B rewrites it — expected; do not fix it here.

```bash
git add app/views/projects/show.html.erb app/views/public/projects/show.html.erb app/services/maker/public_project.rb app/services/maker/gerber_sets.rb app/helpers/files_helper.rb app/services/maker/gerber_archive.rb app/services/maker/three_mf_manifest.rb test/services/maker/gerber_sets_test.rb test/integration/web/page_query_budget_test.rb test/integration/web/template_hygiene_test.rb
git commit -m "The project pages list a Gerber as a file; the board renders only on its own page"
```
(`git rm` already staged the two partials.) Body: what went, why (the user's decision), that
`job_layer_names` is what remains and where the grouping lives in history.

---

## Task B: the file page's `:gerber` branch wears the 3D viewer's chrome

- [ ] **B1. `app/views/files/show.html.erb` — replace the `:gerber` branch (lines 149-191) with:**

```erb
  <% elsif @kind == :gerber %>
    <%# A Gerber layer, an Excellon drill file, a .gbrjob or a zipped export, rendered in the browser
        by tracespace (the vendored module in vendor/javascript/tracespace.js, gerber_controller.js).

        THIS IS THE 3D VIEWER'S CHROME, ON PURPOSE (the :model3d branch below, 2026-09-06 at the
        user's request): a poster with a launch button at rest, and once launched the same stage and
        bar — Fit, Fullscreen, ✕ Image — plus what only a board has, Top/Bottom and one toggle per
        layer. The .model-viewer* classes are the 3D viewer's because the chrome IS the 3D viewer's
        (pages/preview.css defines them once); .gerber-viewer adds only what an SVG stage needs.
        NOTHING IS FETCHED UNTIL THE BUTTON IS CLICKED — the module, the layer bytes, a zip — which
        is the :model3d rule, and it is why the project pages' Fabrication panels could go: a board
        on a project page cost every visitor its parse whether or not they looked.

        THE LAYER LIST IS THE CONTROLLER'S (FilesController#show), never rebuilt here: for an
        ordinary layer it is this one file; for a .gbrjob it is the siblings the job names; for a
        zip it is ONE archive entry carrying the zip's URL and the member paths the browser extracts
        with JSZip (FilesHelper#gerber_archive_entry). named_blob_file_path for the KiCanvas
        comment's reason: the trailing extension is the file's real name, which tracespace reads
        off the File object and a download from the same link should arrive under.

        THE SIDE BUTTONS AND THE LAYER TOGGLES ARE A STACKUP'S ONLY. A single layer has one render,
        so Top/Bottom would be two buttons showing the same picture, and a toggle for it would be a
        button whose only effect is to blank the stage. The toggles are BUILT BY THE CONTROLLER into
        the tools span: their labels are tracespace's own type/side and cannot exist before the
        parse; everything else in the bar is known without one and lives here. %>
    <% if @gerber_layers.empty? %>
      <p class="muted">No Gerber layers sit beside this job file.</p>
    <% else %>
      <div class="model-viewer gerber-viewer"
           data-controller="gerber"
           data-gerber-single-value="<%= @gerber_single %>"
           data-gerber-layers-value="<%= @gerber_layers.to_json %>">
        <div class="model-viewer-stage" data-gerber-target="stage"></div>
        <div class="model-viewer-bar">
          <span class="model-viewer-dims" data-gerber-target="dims"></span>
          <span class="mv-launch">
            <button type="button" class="btn small" data-action="gerber#load"><%= @gerber_single ? "View layer" : "View board" %></button>
          </span>
          <span class="mv-actions">
            <% unless @gerber_single %>
              <span class="gerber-sides">
                <button type="button" class="btn small active" data-gerber-target="side"
                        data-gerber-side="top" data-action="gerber#top">Top</button>
                <button type="button" class="btn small" data-gerber-target="side"
                        data-gerber-side="bottom" data-action="gerber#bottom">Bottom</button>
              </span>
              <span class="gerber-tools" data-gerber-target="tools"></span>
            <% end %>
            <button type="button" class="btn small ghost" data-action="gerber#fit">Fit</button>
            <button type="button" class="btn small ghost" data-action="gerber#fullscreen">Fullscreen</button>
            <button type="button" class="btn small ghost" aria-label="Return to image" data-action="gerber#showPoster">✕ Image</button>
          </span>
        </div>
        <div class="model-viewer-fallback">
          <p class="muted" data-gerber-target="status">Click <strong><%= @gerber_single ? "View layer" : "View board" %></strong> to render <%= @gerber_single ? "this layer" : "the board" %> in the browser, or download the file.</p>
          <%= link_to "Download #{@node.name}", blob_file_path(@node.node_id, download: 1), class: "btn" %>
        </div>
      </div>
    <% end %>
```

Gerbers have no server thumbnail (`Maker::Previews::Registry` has no entry for them), so the poster
is the sentence and the Download button — deliberately not a blank image box.

- [ ] **B2. Rewrite `app/javascript/controllers/gerber_controller.js`** to exactly this (the
`LAYER_TYPE_WORDS`/`LAYER_SIDE_WORDS`/`layerLabel` block, `filesFor`, `toggleLayer`, `compose`,
`show`, `viewBoxOf` keep their bodies; what changes is the lifecycle):

```js
import { Controller } from "@hotwired/stimulus"
import { installPanZoom } from "lib/svg_pan_zoom"

// ONE GERBER LAYER, OR A WHOLE BOARD, rendered in the browser by tracespace — so this app ships no
// server-side PCB renderer and no sidecar (gerbv is GPL, CLAUDE.md §9). Mounted on the FILE page and
// nowhere else since 2026-09-06, when the project pages' Fabrication panels went: a Gerber is a file
// like any other there (a row, a tile, a link to its page), and the board renders here.
//
// THE CHROME IS THE 3D VIEWER'S (modelviewer_controller.js; the .model-viewer* rules in
// pages/preview.css): a poster with a launch button at rest, then the same stage and bar — Fit,
// Fullscreen, ✕ Image — plus what only a board has, Top/Bottom and one toggle per layer. NOTHING IS
// FETCHED UNTIL THE USER ASKS. `load()` is the launch; it adds `model-viewer--ready` BEFORE the
// fetch for the 3D viewer's reason (the stage must have a size when the SVG lands in it — a
// percentage-height SVG against a display:none box is 0px) and reports loading / ready / failed in
// `data-gerber-state` on this element. `showPoster()` is the way back and KEEPS the parsed render,
// so re-opening is a re-compose and no network (test/system/gerber_test.rb pins that).
//
// The module is ONE vendored build (bin/build-tracespace, importmap pin "tracespace") and it is
// imported LAZILY in `load()`, so a page never downloads its 98 KB until asked — the KiCanvas rule,
// and config/importmap.rb pins it `preload: false` so the browser does not fetch it anyway
// (test/integration/web/lazy_bundles_test.rb).
//
// `layersValue` IS A SERVER-BUILT LIST OF {name, url} — OR ONE ARCHIVE ENTRY — AND THE `name` IS
// LOAD-BEARING. tracespace identifies what a layer IS — top copper, solder mask, drill — from the
// FILENAME, never from the bytes, so the name the server put in this list is what decides where the
// file lands in the stackup. That is the same property KiCanvas has (it reads the trailing
// extension off the URL it fetches), which is why both surfaces link the NAMED blob route: the
// fetch below does not depend on it, but nothing is gained by having the two disagree, and a
// download from the same URL wants the real name. An entry carrying `archive: true` is a zipped
// export and expands to several layers here — `filesFor` below, and FilesHelper#gerber_archive_entry
// is where the server builds that shape.
//
// SINGLE vs STACKUP is a SERVER decision, not a count of the layers here. A layer's page renders
// the one file it is about even when its folder holds a whole board (`singleValue` true →
// renderLayers, one layer, no side buttons, no toggles); a .gbrjob's or a zip's page renders the
// board (`renderBoard`, top and bottom). THE LAYER TOGGLES ARE BUILT HERE, into the template's
// tools span, because their LABELS come from tracespace's own `type`/`side` and cannot exist
// before the parse; Fit, Fullscreen, ✕ Image and the side buttons are in the template precisely
// because they are known without one.
//
// PAN, ZOOM AND FIT ARE lib/svg_pan_zoom's, SHARED WITH THE MEASURE VIEW — never a second copy of
// the letterbox maths. That module was measure_controller.js's until 2026-09-06; the Gerber stage
// wanted the same hands, so it moved rather than being reimplemented (§14d).
//
// ON S3 THE FETCH BELOW LEAVES THE ORIGIN, as modelviewer_controller.js's and
// kicanvas_controller.js's do: the blob route answers a presigned redirect to the bucket, which
// the browser reads only if the bucket's CORS rule allows this origin (docs/DEPLOY.md), under a
// connect-src the port names for the CSP (FileLayer#presigned_origin). Shared by every
// client-side viewer in this app; the share and chunk_remote deployments stream from Rails and
// never leave the origin.

// tracespace's LAYER TYPE -> THE WORD THE TOGGLE SHOWS: "top copper", "top silk", "drill" — the
// vocabulary the Fabrication panel's row badges used before the panel went, kept because a maker
// cannot tell top copper from solder mask by looking at three letters of extension.
const LAYER_TYPE_WORDS = {
  copper: "copper", soldermask: "mask", silkscreen: "silk", solderpaste: "paste",
  drill: "drill", outline: "outline", drawing: "drawing"
}
// `all` and anything unrecognised contribute no prefix — a drill file spans the board, so "drill"
// is the whole truth about it and "all drill" would be noise.
const LAYER_SIDE_WORDS = { top: "top", bottom: "bottom", inner: "inner" }

function layerLabel({ type, side }) {
  const word = LAYER_TYPE_WORDS[type] || type || "layer"
  const prefix = LAYER_SIDE_WORDS[side]
  return prefix ? `${prefix} ${word}` : word
}

export default class extends Controller {
  static targets = ["stage", "status", "side", "dims", "tools"]
  static values = { layers: Array, single: Boolean }

  connect() {
    // HIDDEN LAYERS ARE IDS, NOT INDEXES, and the Set is built before any parse so `compose()` has
    // one shape to read whether or not a toggle has ever been clicked.
    this.hidden = new Set()
    this.side = "top"
    this.generation = 0
    // AT REST, WHATEVER THE MARKUP SAYS. A Turbo Drive back-navigation restores the page from a
    // snapshot taken WITH the stage open — the class, the state attribute, the SVG, the toggles —
    // and then connects this fresh controller, which holds no render for any of it to act on.
    // Resetting to the poster is the honest state; the render is one click away, as it was.
    this.rest()
  }

  disconnect() {
    this.generation++
    this.panZoom?.destroy()
    this.panZoom = null
  }

  // "View board" / "View layer". The first click fetches and parses; a later one — after ✕ Image —
  // reuses the render and only re-composes, which is what keeps that button cheap.
  async load() {
    const gen = ++this.generation
    this.element.classList.add("model-viewer--ready")
    this.state("loading")
    try {
      if (!this.rendered) await this.render()
      // A superseded load keeps what it fetched (the render is valid data and the next click will
      // want it) but must not PAINT: the user has dismissed the viewer, or opened it again and a
      // newer load owns the stage now.
      if (gen !== this.generation) return
      this.compose()
      this.buildTools()
      this.show(this.side)
      this.showDims()
      this.state("ready")
      this.focusViewer()
    } catch (e) {
      this.fail(gen, e)
    }
  }

  // read -> plot -> renderLayers is the whole pipeline; renderBoard composes the two sides out of
  // a renderLayers result, so both branches share everything up to that point.
  //
  // THE RESULT IS KEPT, which is what makes a layer toggle — and a re-open — free: `compose()`
  // re-composes from this object and never re-fetches, re-reads or re-plots.
  async render() {
    const ts = await import("tracespace")
    // FETCHED IN PARALLEL, but a single failure fails the whole board: a stackup missing its
    // outline layer renders at the wrong size and a stackup missing its drill file renders solid
    // copper over the holes, either of which is a WRONG picture rather than a partial one.
    // `.flat()` because one entry can be a whole archive — see `filesFor`.
    const files = (await Promise.all(this.layersValue.map((layer) => this.filesFor(layer)))).flat()
    this.ts = ts
    this.rendered = ts.renderLayers(ts.plot(await ts.read(files)))
  }

  // (filesFor unchanged — copy it verbatim from the current file, including its comment)

  top() { this.show("top") }
  bottom() { this.show("bottom") }

  fit() { this.panZoom?.reset() }

  fullscreen() {
    if (document.fullscreenElement) {
      document.exitFullscreen()
    } else {
      this.element.requestFullscreen?.()
    }
  }

  // "✕ Image": back to the poster. The render is KEPT (see load); the stage, the toggles and the
  // dims are cleared because they belong to an open viewer, and the class comes off so the poster
  // returns. `generation++` so a fetch still in flight cannot paint after the dismissal.
  showPoster() {
    this.generation++
    this.rest()
    // The ✕ button that had focus is now hidden; return focus to the launch button.
    this.element.querySelector(".mv-launch button")?.focus()
  }

  rest() {
    this.panZoom?.destroy()
    this.panZoom = null
    this.stageTarget.replaceChildren()
    if (this.hasToolsTarget) this.toolsTarget.replaceChildren()
    if (this.hasDimsTarget) this.dimsTarget.textContent = ""
    this.element.classList.remove("model-viewer--ready")
    this.element.removeAttribute("data-gerber-state")
  }

  fail(gen, error) {
    if (gen !== this.generation) return // superseded — leave newer state alone
    console.warn("[gerber] keeping the poster:", error)
    this.rest()
    this.state("failed")
    if (this.hasStatusTarget) this.statusTarget.textContent = "The viewer could not load."
  }

  state(value) {
    this.element.dataset.gerberState = value
  }

  // After a successful load the launch button that had focus is display:none; move focus to a
  // persistent, now-visible control so keyboard/AT users aren't dropped to <body>.
  focusViewer() {
    this.element.querySelector(".mv-actions button")?.focus()
  }

  // (toggleLayer unchanged — copy verbatim with its comment)

  // (compose unchanged — copy verbatim with its comment)

  // THE LAYER TOGGLES, INTO THE TEMPLATE'S TOOLS SPAN. `replaceChildren` makes it idempotent: a
  // re-open after ✕ Image builds them again, and a toggle reads its state off `this.hidden` rather
  // than defaulting to shown, so a layer hidden before the dismissal is still hidden after the
  // re-open — the render it re-composes from is the same one.
  //
  // A SINGLE LAYER HAS NO TOOLS SPAN AT ALL (the template omits it): there is one layer, so a
  // toggle for it is a button whose only effect is to blank the stage, and `renderLayers` has no
  // stackup to re-compose.
  buildTools() {
    if (!this.hasToolsTarget) return
    this.toolsTarget.replaceChildren()
    for (const layer of this.rendered.layers) {
      const shown = !this.hidden.has(layer.id)
      const button = this.toolButton(layerLabel(layer), { gerberAction: "toggleLayer", layerId: layer.id })
      button.classList.toggle("active", shown)
      button.setAttribute("aria-pressed", String(shown))
      this.toolsTarget.appendChild(button)
    }
  }

  // (toolButton unchanged — copy verbatim with its comment, minus the phrase "in the three
  // templates": it is one template now)

  // (show unchanged in body — copy verbatim with its comment — EXCEPT that the physical size is read
  // off the first SVG before the attributes are overridden; add these two lines right after
  // `const el = this.stageTarget.querySelector("svg")` / `if (el) {`:)
  //     this.size ||= this.sizeOf(el)
  // (before the three setAttribute calls.)

  // THE BOARD'S PHYSICAL SIZE, IN MILLIMETRES, for the bar's dims — the 3D viewer shows a model's
  // and a board's is the number a maker checks against the fab house's quote. tracespace writes
  // it as the SVG's own `width="355.05mm" height="65mm"` (its units are the Gerber's, `mm` or
  // `in`), which `show()` overrides to 100% a line later — so it is read HERE, first, and kept:
  // every side and every re-compose shares the one board shape. Inches are converted so the bar
  // never shows two units. Anything unparseable shows nothing rather than a wrong number.
  sizeOf(el) {
    const dim = (attr) => {
      const m = /^(-?\d*\.?\d+)(mm|in)$/.exec(el.getAttribute(attr) || "")
      return m ? Number(m[1]) * (m[2] === "in" ? 25.4 : 1) : null
    }
    const w = dim("width")
    const h = dim("height")
    return w !== null && h !== null ? [w, h] : null
  }

  showDims() {
    if (!this.hasDimsTarget || !this.size) return
    const [w, h] = this.size
    this.dimsTarget.textContent = `${w.toFixed(1)} × ${h.toFixed(1)} mm`
  }

  // (viewBoxOf unchanged — copy verbatim with its comment)
}
```

Delete the old `connect()`-driven flow entirely (no `statusTarget.remove()`, no `prepend` of a
tools row, no `.gerber-tools` query). The `status` target now lives in the poster and is only
written on failure.

- [ ] **B3. `app/assets/stylesheets/pages/preview.css`:** delete the whole Gerber block (the comment
starting `/* --- Gerber/Excellon (tracespace) — the file page's :gerber branch AND both Fabrication
panels` through `.gerber-stage .gerber-tools { … }`) AND the Fabrication block after it
(`/* --- Fabrication section …` through `.fabrication-board h3 { … }`). In their place, directly
after the `.model-viewer:fullscreen .model-viewer-stage { … }` line inside the same `@layer` block,
add:

```css
  /* --- Gerber/Excellon (tracespace) — the file page's :gerber branch WEARS THE 3D VIEWER'S CHROME
     (every .model-viewer* rule above: the stage hidden until --ready, the bar, the poster, the
     fullscreen height), and `.gerber-viewer` says only what an <svg> stage needs that a <canvas>
     one does not. The project pages' Fabrication panels, which mounted this viewer inline, went on
     2026-09-06 and took `.gerber-stage` with them: the stage IS `.model-viewer-stage` now, whose
     explicit height is what the controller's `height="100%"` SVG resolves against (a percentage
     height against an auto-height ancestor is 0px — the KiCanvas comment below). `color` because a
     tracespace render is `fill="currentColor"` line work on nothing and needs the page's ink over
     the stage's --raised surface. */
  .gerber-viewer .model-viewer-stage { color: var(--fg); }
  /* `cursor: grab` says the board can be dragged before anyone tries it; `is-panning` is the class
     lib/svg_pan_zoom adds for the length of a drag, so the cursor answers the gesture rather than
     the hover.

     `touch-action: none` IS WHAT LETS A SECOND FINGER REACH THE PINCH HANDLER AT ALL. Without it
     the browser claims a two-finger gesture for page scrolling and zooming and never delivers the
     second pointer, so the pinch is not merely degraded — it never fires. It also stops a
     one-finger drag scrolling the page under the board on a phone. */
  .gerber-viewer .model-viewer-stage svg { display: block; width: 100%; height: 100%; cursor: grab; touch-action: none; }
  .gerber-viewer .model-viewer-stage svg.is-panning { cursor: grabbing; }
  /* A board's bar carries Top/Bottom and one toggle per layer beside Fit, Fullscreen and ✕ Image —
     a dozen buttons on a six-layer board — so it wraps where the 3D viewer's three-button bar never
     needs to. `.btn small` is the component (design-system.md rule 3); these only lay the groups out. */
  .gerber-viewer .mv-actions { flex-wrap: wrap; }
  .gerber-sides, .gerber-tools { display: inline-flex; flex-wrap: wrap; gap: 6px; }
```

Check the KiCanvas block's comment still reads correctly after the Gerber block moves above it (it
says "the KiCanvas rule above" nowhere — fine; but the new Gerber comment says "the KiCanvas comment
below", so the KiCanvas block must indeed come later in the file — it does, at the old line 315).

Then: `bin/ci style` (or `bin/rubocop` + whatever `config/ci.rb`'s style gate runs) and
`LIBRARY_BACKEND=share LIBRARY_PATH=$(mktemp -d) bin/rails test test/css_hygiene_test.rb test/stimulus_hygiene_test.rb`.

- [ ] **B4. `app/controllers/files_controller.rb` comments only.** Lines 474-478 (inside `#show`,
the sentence "built through `FilesHelper#gerber_archive_entry`, the same builder both Fabrication
panels reach through `gerber_layers_for`. A second literal of that shape here is the drift to
avoid:") become "built through `FilesHelper#gerber_archive_entry`, the one place that shape is
spelled, so that no second literal of keys only a browser reads can drift:". Lines 1493-1496 (the
paragraph "AN ORDINARY LAYER IS ITSELF, AND THAT IS THE WHOLE PAGE … the project page's Fabrication
panel is where a board is a board, and a file page that quietly rendered the neighbours would be
showing something other than the file it is about.") become:

```ruby
  # AN ORDINARY LAYER IS ITSELF, AND THAT IS THE WHOLE PAGE. A `.gtl` file page shows the `.gtl`,
  # even when its folder holds the rest of the board — a page that quietly rendered the neighbours
  # would be showing something other than the file it is named for. The board's own pages are the
  # `.gbrjob`'s and a zipped export's (since 2026-09-06 there is no project-page panel rendering
  # a folder as a board; a loose set with no job file is one layer per page).
```
Line 1499 "the same reader the panel uses, so the two surfaces can never disagree" → "its one
caller". Grep `Fabrication|panel` in the file afterwards and fix any leftover sentence.

- [ ] **B5. Rewrite `test/integration/web/gerber_preview_test.rb`.** Header: drop the panel sentence
(the file is about "the file page's `:gerber` branch (FilesController#show, files/show.html.erb) and
the two project pages' NOT rendering a viewer"). Keep `setup`, `layers_of`, the private helpers at
the bottom (`reset!` etc.). The file-page cases keep their fixtures and layer-list assertions and
swap the markup assertions — the first one becomes:

```ruby
    test "a .gtl file page renders the viewer at rest, single, pointed at its own named blob" do
      node = write_gerber!(name: "board.gtl")

      get file_path(node.node_id)
      assert_response :success
      assert_select ".model-viewer.gerber-viewer[data-controller=?]", "gerber"
      assert_select ".gerber-viewer[data-gerber-single-value=?]", "true"
      assert_select ".gerber-viewer .model-viewer-stage[data-gerber-target=?]", "stage"
      # THE 3D VIEWER'S CHROME: a launch button in the bar, the three actions beside it, and the
      # poster underneath with the download — nothing is fetched until the button is clicked.
      assert_select ".gerber-viewer .mv-launch button", text: "View layer"
      assert_select ".gerber-viewer .mv-actions button", text: "Fit"
      assert_select ".gerber-viewer .mv-actions button", text: "Fullscreen"
      assert_select ".gerber-viewer .mv-actions button", text: "✕ Image"
      assert_select ".gerber-viewer .model-viewer-fallback a[href=?]", blob_file_path(node.node_id, download: 1)
      assert_equal [ { "name" => "board.gtl",
                       "url" => named_blob_file_path(node.node_id, filename: "board.gtl") } ],
                   layers_of(".gerber-viewer")
      # NO SIDE BUTTONS AND NO TOOLS SPAN ON A SINGLE LAYER: renderLayers produces one picture, so
      # Top and Bottom would be two buttons showing the same thing, and a toggle for the one layer
      # would only blank the stage.
      assert_select ".gerber-viewer [data-gerber-target=?]", "side", 0
      assert_select ".gerber-viewer [data-gerber-target=?]", "tools", 0
    end
```
Every other file-page case: replace `.gerber-stage` with `.gerber-viewer` in selectors and
`layers_of` calls; where a stackup is asserted (the `.gbrjob` cases and the zip case) add
`assert_select ".gerber-viewer .mv-launch button", text: "View board"`,
`assert_select ".gerber-viewer [data-gerber-target=?]", "side", 2` and
`assert_select ".gerber-viewer [data-gerber-target=?]", "tools", 1`. The "says so instead of
mounting an empty viewer" case asserts `assert_select ".gerber-viewer", 0` and the sentence.

Delete every case from `# --- the private project panel ---` to the end of the public cases (the
eleven tests from "the project page groups a folder's Gerbers" through "the public viewer's layer
URLs actually serve the bytes"). In their place:

```ruby
    # --- the project pages ----------------------------------------------------------

    # NO BOARD ON A PROJECT PAGE (2026-09-06, at the user's request): a folder's Gerbers and a zipped
    # export are ordinary file rows there, linking to the file page where the board renders. The
    # Fabrication panel that grouped them into inline viewers is gone, and this is the test that
    # says so — a panel quietly re-added under any name mounts `data-controller="gerber"`.
    test "the project page mounts no board viewer and lists a folder's Gerbers as files" do
      project = @user.maker_projects.create!(name: "Driver")
      folder = make_project_folder!(@user, project)
      dir = gerber_dir!(name: "pcb", parent_node_id: folder.node_id)
      set = write_gerber_set!(parent_node_id: dir.node_id)
      zip = write_gerber_zip!(parent_node_id: dir.node_id)

      get project_path(project)
      assert_response :success
      assert_select "[data-controller=?]", "gerber", 0
      assert_select ".fabrication-panel", 0
      assert_select "a[href=?]", file_path(set[:gtl].node_id)
      assert_select "a[href=?]", file_path(zip.node_id)
    end

    # THE PUBLIC PAGE HAS NO BOARD RENDER AT ALL — there is no public FILE page to mount one on —
    # and it still lists every layer for a visitor to download through the public file route.
    test "the public page mounts no board viewer and lists the layers as public files" do
      project = @user.maker_projects.create!(name: "Driver", visibility: "public")
      folder = make_project_folder!(@user, project)
      dir = gerber_dir!(name: "pcb", parent_node_id: folder.node_id)
      set = write_gerber_set!(parent_node_id: dir.node_id)
      reset!

      get public_project_path("gerber", project.slug)
      assert_response :success
      assert_select "[data-controller=?]", "gerber", 0
      assert_select "a[href=?]", public_file_path("gerber", project.slug, set[:gtl].node_id)
    end
```
If the public files table renders the link with a different query (check
`app/views/public/projects/_files.html.erb:43` — `pub.file_url_for(row.node_id)` — and
`Maker::PublicProject#file_url_for`'s signature) assert the URL the page actually renders; the point
of the assertion is that a subfolder's layer is listed, not the exact spelling.

Run: `LIBRARY_BACKEND=share LIBRARY_PATH=$(mktemp -d) bin/rails test test/integration/web/gerber_preview_test.rb`
Expected: 12 runs, 0 failures.

- [ ] **B6. Rewrite `test/system/gerber_test.rb`.** Header: replace "the Fabrication panel's
grouping" with "the two project pages' absence of a viewer", and add one paragraph:

```ruby
# EVERY CASE CLICKS THE LAUNCH BUTTON FIRST. The viewer wears the 3D viewer's chrome (2026-09-06),
# so nothing — not the module, not a byte — loads until "View layer" / "View board" is clicked; a
# `visit` followed straight by the ready assertion would wait out the timeout on a poster. The
# label is the server's: "View layer" for a single file, "View board" for a .gbrjob or a zip.
```
Delete `project_with_board!` and the two cases that used it ("a project folder's Gerbers render as
a board…" and "the public project page renders the board…"). Rewrite the first case:

```ruby
  test "a real Gerber layer renders in the browser once launched, and the bar shows its size" do
    node = write_gerber!(name: "board.gtl")

    visit file_path(node.node_id)

    # AT REST: the poster, the launch button, and NO svg — nothing has been fetched.
    assert_selector ".gerber-viewer .mv-launch button", text: "View layer"
    assert_no_selector ".gerber-viewer svg"
    click_button "View layer"

    assert_selector ".gerber-viewer[data-gerber-state='ready']"
    # GEOMETRY, NOT MERELY AN <svg>. tracespace emits a well-formed empty document for a file it
    # parsed and found nothing in, so asserting the element alone would pass over a viewer that
    # loaded and rendered nothing — this repo's dominant failure shape.
    assert_selector ".gerber-viewer svg path", minimum: 1
    # The stage fills its box rather than rendering at the board's physical 10mm — the controller
    # overrides the attributes tracespace writes, and CSS cannot beat them (see gerber_controller.js).
    assert_equal "100%", find(".gerber-viewer svg")[:width]
    # …and the physical size those attributes carried is what the bar shows, in mm, one decimal.
    assert_selector ".gerber-viewer .model-viewer-dims", text: "10.0 × 10.0 mm"
    assert_no_console_errors
  end
```
(Confirm the fixture's size: `MINIMAL_GERBER` in `test/support/gerber_fixture.rb` draws a 10 × 10 mm
board — the old `view_box` comment says `viewBox="0 -10 10 10"`. If tracespace reports a different
width, assert the number it reports after checking it is the board's real size, and say so in the
test.)

The drill case: click "View layer" after `visit`. The zip case: click "View board"; its Top/Bottom
buttons are found the same way (`find("button[data-gerber-side='bottom']")`). The wheel / drag /
Fit / toggle / sizeless cases: after `visit`, `click_button "View board"` (they use the zip fixture;
if one uses a single `.gtl`, "View layer"), then the existing ready wait; every `.gerber-stage`
selector becomes `.gerber-viewer` (the private helpers' default arguments too — they query
`"#{selector} svg"`, which still finds the SVG inside the stage). The sizeless case collapses the
STAGE: its JS must target `.gerber-viewer .model-viewer-stage` instead of `.gerber-stage`. The
toggle case finds buttons by `[data-gerber-layer-id]` — unchanged. Replace "the single-layer page
offers Fit and no layer toggles" with:

```ruby
  test "the single-layer page offers Fit and no layer toggles" do
    node = write_gerber!(name: "board.gtl")

    visit file_path(node.node_id)
    click_button "View layer"

    assert_selector ".gerber-viewer[data-gerber-state='ready']"
    assert_selector ".gerber-viewer .mv-actions .btn", exact_text: "Fit"
    assert_no_selector "[data-gerber-layer-id]"
    assert_no_selector "[data-gerber-side]"
    assert_no_console_errors
  end
```
Add one new case:

```ruby
  # ✕ IMAGE KEEPS THE RENDER. The way back to the poster drops the SVG, the toggles and the dims —
  # and keeps the parsed board, so the next "View board" is a re-compose and NO fetch: the resource
  # timeline is the witness, counting the blob URL's entries before and after. A re-open that
  # fetched again would pass every other assertion here and cost a twelve-layer board its whole
  # parse for a click that should be free.
  #
  # MUTATION (§15, test/system/README.md; run for real, output in the PR, then reverted):
  # gerber_controller.js's `if (!this.rendered) await this.render()` changed to
  # `await this.render()` reds this test on the fetch count (2 where 1 is expected).
  test "✕ Image returns to the poster, and View board re-opens the render without a fetch" do
    node = write_gerber_zip!

    visit file_path(node.node_id)
    click_button "View board"
    assert_selector ".gerber-viewer[data-gerber-state='ready']"
    assert_selector ".gerber-viewer svg path", minimum: 1
    fetches = -> { page.evaluate_script("performance.getEntriesByType('resource').filter(e => e.name.includes('/blob')).length") }
    assert_equal 1, fetches.call, "the archive is fetched exactly once on launch"

    click_button "✕ Image"

    assert_no_selector ".gerber-viewer.model-viewer--ready"
    assert_no_selector ".gerber-viewer[data-gerber-state]"
    assert_no_selector ".gerber-viewer svg"
    assert_selector ".gerber-viewer .mv-launch button", text: "View board"

    click_button "View board"

    assert_selector ".gerber-viewer[data-gerber-state='ready']"
    assert_selector ".gerber-viewer svg path", minimum: 1
    assert_equal 1, fetches.call, "re-opening fetched the archive again"
    assert_no_console_errors
  end
```
(If the named blob route's path does not contain `/blob`, filter on the literal path the entry
carries — read it with `page.evaluate_script("performance.getEntriesByType('resource').map(e => e.name)")`
once and pin the real substring.)

Run: `LIBRARY_BACKEND=share LIBRARY_PATH=$(mktemp -d) bin/rails test test/system/gerber_test.rb`
Expected: 11 runs, 0 failures.

- [ ] **B7. `test/system/shell_test.rb`.** Lines 159-168's comment becomes:

```ruby
    # THE GERBER FILE PAGE, at 375px. Its stackup is an <svg> the browser is told to render at
    # width: 100% — the one element on these pages whose natural size is its PHYSICAL size (a board
    # is millimetres wide), so it is the one most likely to push the page sideways if
    # gerber_controller.js's attribute override or pages/preview.css's stage rules regress. REAL
    # BYTES for the KiCanvas argument directly above: tracespace fetches these for real in a live
    # Chrome, and a parse failure would log its own console error, indistinguishable at the final
    # assert_no_console_errors from an actual overflow regression. The viewer is LAZY, so the loop
    # below launches it on that page before measuring — a poster cannot overflow, and a sweep that
    # never clicked would be measuring nothing. (The project page lists these as ordinary rows since
    # 2026-09-06; there is no panel there to render them.)
```
In the signed-in loop (line ~245, after `visit path`) launch the viewer on that one page before the
overflow check:

```ruby
        visit path
        if path == file_path(gerbers[:gtl].node_id)
          click_button "View layer"
          assert_selector ".gerber-viewer[data-gerber-state='ready']"
        end
```
Run `LIBRARY_BACKEND=share LIBRARY_PATH=$(mktemp -d) bin/rails test test/system/shell_test.rb`.

- [ ] **B8. `docs/invariants/files-preview.md`.** Three edits in the `:gerber` section.

(i) The sentence "The rule is stated beside the code in four places that must sweep together:
`Maker::GerberArchive`'s header, `Maker::GerberSets`' class comment and `#archive_boards`,
`FilesHelper#gerber_layers_for` / `#gerber_archive_entry` (the ONE wire shape all three pages
build), and `gerber_controller.js`'s `filesFor`." becomes "The rule is stated beside the code in
three places that must sweep together: `Maker::GerberArchive`'s header,
`FilesHelper#gerber_archive_entry` (the ONE wire shape, built by `FilesController#show`), and
`gerber_controller.js`'s `filesFor`."

(ii) Replace the paragraph beginning **One board is one FOLDER.** with:

> **A GERBER IS A FILE LIKE ANY OTHER ON THE PROJECT PAGES, AND THE BOARD RENDERS ONLY ON ITS OWN
> FILE PAGE** (2026-09-06, at the user's request). The private and public project pages' Fabrication
> panels — one inline viewer per folder, grouped by `Maker::GerberSets` (one board per folder, a zip
> a board of its own, the list and the stack two different lists) — are gone, and the grouping with
> them; `git show 2addf8f:app/services/maker/gerber_sets.rb` holds it. What remains of `GerberSets` is
> `job_layer_names`, the `.gbrjob` reader behind a job file's page. A layer's page shows that layer; a
> `.gbrjob`'s and a zip's page show the board; **a loose set with no job file is one layer per page**
> — the one thing the panel could do that the file page cannot, deliberately not rebuilt. A public
> project therefore has **no board render**: the public page lists the layers as files a visitor can
> download, and there is no public file page to mount a viewer on.

(iii) Replace the paragraph beginning **THE TOOLBAR IS BUILT BY THE CONTROLLER, NOT BY THE THREE
TEMPLATES** with:

> **THE VIEWER WEARS THE 3D VIEWER'S CHROME AND FETCHES NOTHING UNTIL LAUNCHED.** The `:gerber`
> branch is a `.model-viewer.gerber-viewer`: at rest a poster (a sentence and the Download button —
> Gerbers have no thumbnail) with a `View layer` / `View board` button, then the same stage and bar as
> `:model3d` — dims, Fit, Fullscreen, ✕ Image — plus Top/Bottom and one toggle per layer for a
> stackup. The `.model-viewer*` classes are the 3D viewer's because the chrome IS the 3D viewer's,
> defined once in `pages/preview.css`; `.gerber-viewer` adds only what an `<svg>` stage needs
> (`color`, the grab cursor, `touch-action: none`, a wrapping bar). `model-viewer--ready` goes on
> BEFORE the fetch for the 3D viewer's reason (the stage must have a size when the SVG lands).
> **✕ Image KEEPS the parsed render**, so re-opening is a re-compose and no fetch — pinned by the
> resource timeline in `test/system/gerber_test.rb`. The dims are the board's physical size in mm,
> read off the `width`/`height` tracespace writes (`mm` or `in`, converted) BEFORE the controller
> overrides them to 100%. The layer toggles are still **built by the controller** into the template's
> tools span (their labels are tracespace's `type`/`side`, unknowable before the parse) and read their
> state off the hidden set, so a layer hidden before ✕ Image stays hidden after the re-open; Fit,
> Fullscreen, ✕ Image and the side buttons are in the template because they are known without a
> parse. The toggle wording ("top copper", "top silk", "drill") is the vocabulary the panel's row
> badges used; the badges went with the panel and the words stayed. A Turbo-restored snapshot of an
> open viewer is reset to the poster on connect — the fresh controller holds no render for it.

Then `LIBRARY_BACKEND=share LIBRARY_PATH=$(mktemp -d) bin/rails test test/docs_hygiene_test.rb`.

- [ ] **B9. Mutation checks — run each for real, quote the failing assertion, restore, and clear
bootsnap where a Ruby file was mutated.**

  - M1 (existing): `import("tracespace")` → `import("tracespace-x")` in the controller → the first
    system case reds at the ready wait.
  - M2: `if (!this.rendered) await this.render()` → `await this.render()` → the ✕ Image case reds on
    the fetch count.
  - M3: `showDims()` given an early `return` → the first case reds on the dims text.
  - M4: add `<div data-controller="gerber"></div>` to `app/views/projects/show.html.erb` → the
    request test's project-page case reds (count 1 where 0 expected).
  - M5: `File.basename(entry["Path"].to_s)` → `entry["Path"].to_s` in `GerberSets.job_layer_names`
    → the basename unit case reds.

- [ ] **B10. Commit.**

```bash
git add app/views/files/show.html.erb app/javascript/controllers/gerber_controller.js app/assets/stylesheets/pages/preview.css app/controllers/files_controller.rb test/integration/web/gerber_preview_test.rb test/system/gerber_test.rb test/system/shell_test.rb docs/invariants/files-preview.md docs/superpowers/plans/2026-09-06-gerber-file-view.md
git commit -m "A Gerber file page rests as a poster and opens in the 3D viewer's chrome"
```

---

## Verification (the whole branch)

```bash
export TINKEREX_SYNC_DIR=/Users/charlesschwartz/Desktop/repos/tinkerex-sync
bin/ci
```
All gates green; the three backend legs (`test`, `test-s3`, `test-chunk-remote`) report identical
run counts (±2 assertions is the known flap, `tinkerex#131`). Report the counts.

## Self-review notes

- Spec coverage: panel removal (A1-A2), grouping removal (A3-A4), tests for both (A6, B5), the
  file page's chrome (B1-B3), lazy fetch + poster round-trip (B2, B6), dims (B2, B6), docs (B8).
- Names used consistently: `.gerber-viewer`, `data-gerber-target="stage|status|side|dims|tools"`,
  `data-gerber-state`, `model-viewer--ready`, `gerber#load|showPoster|fit|fullscreen|top|bottom|toggleLayer`,
  labels "View layer" / "View board".
