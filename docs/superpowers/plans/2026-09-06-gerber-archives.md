# Zipped Gerber exports — implementation plan

> **For agentic workers:** execute per `.claude/commands/execute-plan.md`. One implementer (the
> slice is one coherent unit), one capped review. Steps use checkbox (`- [ ]`) syntax.

**Goal:** a `.zip` that holds a Gerber export is a **board**: its own file page renders the stackup
(Top/Bottom), and a project's Fabrication panel — private and public — lists it as one board and
renders it, **without anyone unzipping it into the library and without Rails extracting a byte**.

**Why (the report that started this):** Finder's Archive Utility refused to expand
`Control PCB 2D_Gerbers_2026-08-13 v1.1.zip` into `Projects/Wheel Clock/Electronics` on the SMB
share ("Operation not permitted"). The share is fine — `ditto -xk` and `unzip` on the same mount
extract all 16 members — it is Archive Utility's own sandbox on a network volume. But the maker
should never have had to: the zip IS the artefact a fab house takes. That file is a **Fusion 360
"CAM outputs" export**: members under `Clough42/Wheel Clock/CAMOutputs/{GerberFiles,DrillFiles,Assembly}/`,
layers named `copper_top_l1.gbr`, `copper_inner_l2.gbr`, `soldermask_bottom.gbr`, `silkscreen_top.gbr`,
`solderpaste_top.gbr`, `profile.gbr`, a drill `drill_1_64.xln`, a `gerber_job.gbrjob`, and PnP/assembly
`.txt` files. **Probed against the vendored tracespace bundle (node, real files): every layer is
identified correctly from its BASENAME** (copper top/bottom/inner×2, drill, outline, silkscreen×2,
soldermask×2, solderpaste×2) and `renderBoard` produces a 355 × 65 mm board. No layer-type hints are
needed; the basename is the whole identification, exactly as it is for loose files today.

**Architecture:** the SERVER decides which zips are boards and which members are layers; the
BROWSER extracts.

- `Maker::GerberArchive` reads a zip through the port ONCE (bounded by a size cap judged on the
  catalog's own `size` column before any read), lists its central directory with **rubyzip**
  (already a dependency — `Maker::Previews::ThreeMf`), keeps the members whose extension is in
  `FilesController::GERBER_EXTS`, lets an inline `.gbrjob` member choose the stack exactly as
  `Maker::GerberSets` does for a folder, and caches the answer in `Rails.cache` keyed by the node's
  content token (Solid Cache in production; the null store in test, so every test run really reads).
- `Maker::GerberSets` turns each such zip into a **Board of its own**. A zip is a complete export,
  so it is never merged with loose layers: a zip beside loose layers in one folder is two boards.
- `gerber_controller.js` fetches the zip through the SAME route a download uses (the named blob
  route privately, the public file route publicly — so the s3 story, presigned redirect + bucket
  CORS + the port-named `connect-src`, is unchanged), unzips it in the browser with the
  already-vendored **JSZip** (lazy `import("jszip")`), and hands tracespace one `File` per stacked
  member, named by its basename. No new table, no job, no migration, no server-side extraction (§15).
- `preview_kind` stays NAME-ONLY. The zip branch is decided in `FilesController#show` by a read —
  the only preview kind that is — the way `gerber_layers_for`'s `.gbrjob` read already lives there.

**Tech:** rubyzip 3.4 (BSD-2, `gem "rubyzip", require: "zip"`), JSZip 3.10.1 (MIT, pin `"jszip"`,
`import JSZip from "jszip"` already works in `bundle_controller.js`), tracespace (vendored).

**Not in scope, and say so in the PR:** filing. `zip` stays role `source_archive`, so a Gerber zip
dropped loose at a project's ROOT is filed into the source folder by the intake sweep, while one in
`Electronics/` (the report's case) is never moved. Role is decided by name and the sweep runs before
any read; a content-aware refiling is a separate decision. Also not in scope: `.rar`/`.7z`, nested
zips, zips over the cap, and a server thumbnail for the zip in the Files grid.

---

## Task A — the whole slice

**Files:**
- Create: `app/services/maker/gerber_archive.rb`, `test/services/maker/gerber_archive_test.rb`
- Modify: `app/services/maker/gerber_sets.rb` (Board gains `archive`; zips become boards),
  `app/controllers/files_controller.rb` (`#show`: the zip branch), `app/helpers/files_helper.rb`
  (`gerber_layers_for(board) { |row| url }` — the ONE wire shape; `GERBER_LAYER_LABELS` gains
  `"zip" => "archive"`), `app/views/files/show.html.erb` (nothing structural — `@gerber_layers` carries
  the archive descriptor; fix the branch comment), `app/views/projects/_fabrication.html.erb` and
  `app/views/public/projects/_fabrication.html.erb` (build the JSON through the helper),
  `app/javascript/controllers/gerber_controller.js` (the archive branch), `test/support/gerber_fixture.rb`
  (`gerber_zip`, `fusion_zip`, `write_gerber_zip!`), `test/services/maker/gerber_sets_test.rb`,
  `test/integration/web/gerber_preview_test.rb`, `test/system/gerber_test.rb`,
  `docs/invariants/files-preview.md` (one paragraph in the `:gerber` section).

### A.1 `Maker::GerberArchive` — what is inside a zip, decided once

- [ ] Create `app/services/maker/gerber_archive.rb`:

```ruby
require "zip"

module Maker
  # A ZIPPED GERBER EXPORT IS A BOARD, AND THIS IS THE ONE PLACE THE SERVER LOOKS INSIDE THE ZIP.
  #
  # Every CAM tool hands a board over as a zip — Fusion 360's "CAM outputs", Altium's job outputs,
  # KiCad's fabrication plugin, EasyEDA/JLCPCB's `Gerber_*.zip` — and that zip is the artefact the
  # fab house takes, so a maker keeps it as it arrived. The old answer was "unzip it into the folder";
  # the report that made this class exist was Finder refusing to do exactly that on the SMB share.
  #
  # THE SERVER LISTS, THE BROWSER EXTRACTS. rubyzip reads the central directory here — names and
  # sizes, never a byte of a layer — and gerber_controller.js opens the same zip with JSZip to pull
  # the members this class named. Rails extracting layers and serving them would be bytes flowing
  # through the control plane on every backend (§15); the browser already has to fetch the zip to
  # render it, so it is the one that unpacks it.
  #
  # ONE PORT READ PER ZIP, BOUNDED TWICE, THEN CACHED. `READ_LIMIT` is judged on the catalog's own
  # `size` column BEFORE any read (`Maker::GerberSets::READ_LIMIT` makes the same argument for a job
  # file: the size is already known, so refusing costs nothing), and the job member is read only if
  # its own uncompressed size is under the job cap. The listing is a pure function of the bytes, so
  # it is cached in Rails.cache by `(node_id, content token)` — a re-exported zip has a new token
  # and reads again; an unchanged one is never opened twice. nil IS CACHED TOO: a zip of firmware
  # is not a board and stays not-a-board until its content changes, and re-reading a 10 MB archive
  # on every project-page view to re-learn that would be the cost this cache exists to avoid.
  # (test: null_store, so every test really reads; production: Solid Cache, one query per fetch.)
  #
  # A `.gbrjob` MEMBER PICKS THE STACK, DOWNWARD ONLY — `Maker::GerberSets`'s rule for a folder,
  # applied inside the archive: where a job parses and names members this zip holds, those are
  # stacked; every pcb-role member is still LISTED; a job naming nothing here falls back to every
  # layer. Matched by basename, never by path, for that class's reason (exporters write any prefix).
  # The job is never itself a layer (JSON into tracespace is a junk layer, not an error).
  #
  # MEMBER NAMES ARE HANDED TO THE BROWSER AS PATHS AND TO tracespace AS BASENAMES. JSZip looks a
  # member up by its full path; tracespace identifies a layer by its filename, and Fusion's
  # `copper_top_l1.gbr` under three directories is identified by exactly the basename (probed).
  # Names are scrubbed to UTF-8 for the JSON attribute; a zip written with a non-UTF-8 name would
  # miss its member in JSZip and fail the board loudly ("could not load") rather than silently.
  #
  # EVERY FAILURE COLLAPSES TO nil — not a zip, a corrupt zip, an unreadable or unmounted store, a
  # zip with no Gerber member at all — because every caller answers all of them the same way (not
  # a board). `rescue Zip::Error` beside the port's own two, never a bare rescue: a NoMethodError
  # here is a bug and must stay loud.
  class GerberArchive
    # `members`: every pcb-role member path in the zip (String, name-ordered), the panel's LIST.
    # `stacked`: the subset the viewer renders (never the .gbrjob). `job_name`: the job member's
    # basename, or nil — the board takes the ZIP's stem as its name regardless (the export's own
    # name is the one the maker recognises; Fusion calls every job `gerber_job.gbrjob`).
    Listing = Data.define(:members, :stacked, :job_name)

    EXT = "zip".freeze
    # A Gerber export is a few hundred KB to a few MB (the report's 4-layer board: 300 KB zipped,
    # 1.2 MB flat). 16 MB is generous; past it the zip is something else, and reading it to find out
    # would stream that much off the user's store into a page request for nothing.
    READ_LIMIT = 16 * 1024 * 1024
    CACHE_TTL = 30.days

    def self.archive?(name) = File.extname(name.to_s).downcase.delete(".") == EXT

    # nil unless this node is a zip holding at least one Gerber layer. `user` is whose library the
    # bytes are read from — on the public page the OWNER, never the visitor (GerberSets's rule).
    def self.for(user:, node:)
      return nil unless archive?(node.name)
      return nil if node.size.to_i > READ_LIMIT

      token = node.content_hash.presence || node.current_version.presence
      Rails.cache.fetch([ "gerber-archive", node.node_id, token ], expires_in: CACHE_TTL) do
        read(user:, node:)
      end
    end

    def self.read(user:, node:)
      listing_from(FileLayer.current.read(user, node_id: node.node_id))
    rescue FileLayer::NotFound, FileLayer::FetchError
      nil
    end

    # PUBLIC AND PURE so the tests can hand it bytes directly; `for` is the cached, port-reading door.
    def self.listing_from(bytes)
      names = []
      job = nil
      Zip::File.open_buffer(StringIO.new(bytes.b)) do |zip|
        zip.each do |entry|
          next if entry.directory?

          name = entry.name.dup.force_encoding(Encoding::UTF_8).scrub
          ext = ext_of(name)
          next unless FilesController::GERBER_EXTS.include?(ext)

          if ext == "gbrjob"
            job ||= entry
          else
            names << name
          end
        end
        return nil if names.empty?

        names.sort!
        listed = job && job_layer_names(job)
        stacked = listed ? names.select { |n| listed.include?(File.basename(n)) } : names
        stacked = names if stacked.empty?
        Listing.new(members: names, stacked:, job_name: job && File.basename(job.name))
      end
    rescue Zip::Error
      nil
    end

    # The same document rules as `Maker::GerberSets.job_layer_names`, for a member instead of a
    # node: the job's own uncompressed size is the cap, and every failure is nil (use the directory).
    def self.job_layer_names(entry)
      return nil if entry.size.to_i > Maker::GerberSets::READ_LIMIT

      doc = JSON.parse(entry.get_input_stream.read.force_encoding(Encoding::UTF_8).scrub)
      return nil unless doc.is_a?(Hash)

      names = Array(doc["FilesAttributes"]).filter_map do |item|
        File.basename(item["Path"].to_s) if item.is_a?(Hash) && item["Path"].present?
      end
      names.any? ? names.to_set : nil
    rescue JSON::ParserError, Zip::Error
      nil
    end

    def self.ext_of(name) = File.extname(name.to_s).downcase.delete(".")
  end
end
```

- [ ] Check the two things this code assumes, and fix the code (not the assumption) if either is
  false: `Node` has `content_hash` and `current_version` columns (the summary's §5 says so — verify
  in `db/schema.rb`); `Zip::File.open_buffer` on rubyzip 3.4 accepts a StringIO and yields (it does
  in `Maker::Previews::ThreeMf`). `return` from inside the `open_buffer` block returns from the
  method — that is intended; if rubyzip's block form swallows it, restructure to assign and return
  after the block.

### A.2 `Maker::GerberSets` — a zip is a board of its own

- [ ] `Board` gains a sixth field and a sibling type:

```ruby
    # `archive` is nil for a folder's loose set, and for a zipped export it is the zip's own Row plus
    # the member paths the viewer stacks — the one shape both Fabrication partials and the file page
    # hand to gerber_controller.js through FilesHelper#gerber_layers_for. `rows` is then exactly
    # [the zip's row] (the panel LISTS the archive, one line, badge "archive") and `stacked` is empty:
    # what is stacked lives in the zip, not in the catalog.
    Board = Data.define(:dir_node_id, :section, :name, :rows, :stacked, :archive)
    Archive = Data.define(:row, :members)
```

- [ ] `boards` includes zip boards, and sorts deterministically now that one section can hold two
  boards (a zip beside a loose set):

```ruby
    def boards
      @boards ||= (folder_boards + archive_boards)
                    .sort_by { |board| [ board.section.empty? ? 0 : 1, board.section, board.name ] }
    end

    private

    def folder_boards
      @rows.select { |row| gerber?(row.node.name) }
           .group_by { |row| row.node.parent_node_id }
           .map { |dir_node_id, dir_rows| board_for(dir_node_id, dir_rows) }
    end

    # A ZIP IS NEVER MERGED INTO ITS FOLDER'S LOOSE SET. An export is complete by construction —
    # stacking a folder's stray `.gtl` on top of a zip's own top copper would render two revisions
    # as one board, the exact image-of-nothing-real the folder rule exists to prevent. A zip whose
    # listing is nil (not a Gerber export, unreadable, too big) is simply not a board.
    def archive_boards
      @rows.select { |row| GerberArchive.archive?(row.node.name) }.filter_map do |row|
        listing = GerberArchive.for(user: @user, node: row.node) or next
        Board.new(dir_node_id: row.node.parent_node_id, section: row.section.to_s,
                  name: File.basename(row.node.name, ".*"), rows: [ row ], stacked: [],
                  archive: Archive.new(row:, members: listing.stacked))
      end
    end
```

- [ ] `board_for` passes `archive: nil`. Update the class comment's "A BOARD IS A FOLDER" paragraph
  with one sentence: a zipped export is the other kind of board, its own, never merged.

### A.3 The surfaces — ONE wire shape, three pages

- [ ] `app/helpers/files_helper.rb`:

```ruby
  # THE ONE WIRE SHAPE gerber_controller.js READS, built for all three pages that mount it — the
  # file page, the private Fabrication panel, the public one — which differ only in how a row's
  # URL is spelled (the named blob route, or the public file route with its token), so that is
  # the block. A loose board is one {name, url} per stacked row; a zipped export is ONE entry, the
  # zip's, with `archive: true` and the member paths to extract — the browser fetches the zip once
  # through the same route a download uses and unzips it itself (Maker::GerberArchive's header).
  def gerber_layers_for(board)
    if board.archive
      row = board.archive.row
      [ { name: row.node.name, url: yield(row), archive: true, members: board.archive.members } ]
    else
      board.stacked.map { |row| { name: row.node.name, url: yield(row) } }
    end
  end
```
  and `GERBER_LAYER_LABELS` gains `"zip" => "archive"` (the zip's own row is the one line the
  panel lists for an archive board; without this it reads "gerber").

- [ ] Both `_fabrication.html.erb` partials replace their inline `board.stacked.map { … }.to_json`
  with `gerber_layers_for(board) { |row| named_blob_file_path(row.node_id, filename: row.node.name) }.to_json`
  (private) and `gerber_layers_for(board) { |row| pub.file_url_for(row.node_id, filename: row.node.name) }.to_json`
  (public). The list loop is unchanged: an archive board's `rows` is the zip, so it lists one line
  with its badge. Update each partial's header comment (both say "the viewer gets `stacked`").

- [ ] `FilesController#show` — after `@kind = preview_kind(@node.name)` and before the
  `@gerber_layers` line:

```ruby
    # A ZIP IS A BOARD WHEN ITS CONTENTS SAY SO — the one preview kind decided by a READ rather than
    # by the name. `preview_kind` answers from the name for the whole vocabulary and stays that way;
    # this branch lives here beside `gerber_layers_for`'s `.gbrjob` read, the other server read a
    # Gerber page makes. One port read, bounded and cached (Maker::GerberArchive).
    @gerber_archive = Maker::GerberArchive.archive?(@node.name) &&
                      Maker::GerberArchive.for(user: current_user, node: @node)
    @kind = :gerber if @gerber_archive
```
  then `@gerber_layers` becomes: for an archive, the helper's archive entry (build it through a
  `Maker::GerberSets::Board`-shaped object OR give the helper a second door — implementer's choice,
  but the SHAPE must be defined once; a second literal `{ archive: true, members: … }` in the
  controller is the drift to avoid), else the existing `gerber_layers_for(@node)`. And
  `@gerber_single` is false for an archive: `@kind == :gerber && !gerber_job?(@node.name) && !@gerber_archive`.
  A zip page therefore mounts the stackup with Top/Bottom, like a `.gbrjob` page.

- [ ] `app/views/files/show.html.erb`'s `:gerber` comment: add one line saying a zipped export
  reaches this branch through `@gerber_archive` and renders the board.

### A.4 `gerber_controller.js` — the archive branch

- [ ] Replace the `files` construction in `connect()`:

```js
      const files = (await Promise.all(this.layersValue.map((layer) => this.filesFor(layer)))).flat()
```
  and add, as a method with its own comment block (do NOT edit the header comment's s3 paragraph —
  a sibling branch changes those lines):

```js
  // ONE LAYER ENTRY IS EITHER A FILE OR A WHOLE ARCHIVE. A loose layer is fetched and named as it
  // always was. An entry with `archive: true` is a zipped export: the zip is fetched ONCE through
  // the same URL a download uses, opened HERE with JSZip — never by Rails (§15; Maker::GerberArchive's
  // header has the argument) — and each member the server named is handed to tracespace as a File
  // named by its BASENAME, because that is what tracespace identifies a layer from and what the
  // server matched the job file against. A member the zip does not hold fails the whole board, the
  // rule the fetch above already applies to a missing layer: a stackup rendered without its outline
  // or its drills is a wrong picture, not a partial one.
  //
  // `import("jszip")` IS LAZY for the same reason tracespace's is: the pin is preloaded for
  // bundle_controller.js's static import, but a Gerber page without a zip never runs this.
  async filesFor({ name, url, archive, members }) {
    const res = await fetch(url)
    if (!res.ok) throw new Error(`${name}: ${res.status}`)
    if (!archive) return [new File([await res.text()], name)]

    const { default: JSZip } = await import("jszip")
    const zip = await JSZip.loadAsync(await res.arrayBuffer())
    return Promise.all(
      members.map(async (path) => {
        const entry = zip.file(path)
        if (!entry) throw new Error(`${name}: ${path} is not in the archive`)
        return new File([await entry.async("string")], path.split("/").pop())
      })
    )
  }
```

### A.5 Tests

- [ ] `test/support/gerber_fixture.rb` gains:

```ruby
  # A ZIP BUILT IN MEMORY WITH RUBYZIP from the same minimal bytes, so a test controls its member
  # paths exactly. `entries` maps "path/in/zip" => body.
  def gerber_zip(entries)
    Zip::OutputStream.write_buffer(StringIO.new("".b)) do |out|
      entries.each { |path, body| out.put_next_entry(path); out.write(body) }
    end.string
  end

  # THE FUSION 360 "CAM OUTPUTS" SHAPE the report was about: layers three directories deep, a drill
  # in a sibling directory, a job naming them, and assembly text that is not a layer.
  def fusion_zip(stem: "board", job: true)
    base = "Clough42/#{stem}/CAMOutputs"
    entries = {
      "#{base}/GerberFiles/copper_top_l1.gbr"    => MINIMAL_GERBER,
      "#{base}/GerberFiles/copper_bottom_l4.gbr" => MINIMAL_GERBER,
      "#{base}/GerberFiles/profile.gbr"          => MINIMAL_GERBER,
      "#{base}/DrillFiles/drill_1_64.xln"        => MINIMAL_DRILL,
      "#{base}/Assembly/PnP_#{stem}_front.txt"   => "pnp"
    }
    if job
      entries["#{base}/GerberFiles/gerber_job.gbrjob"] =
        gerber_job("copper_top_l1.gbr", "copper_bottom_l4.gbr", "profile.gbr", "drill_1_64.xln")
    end
    gerber_zip(entries)
  end

  def write_gerber_zip!(name: "board.zip", parent_node_id: nil, body: fusion_zip)
    write_gerber!(name:, parent_node_id:, body:)
  end
```
  (`require "zip"` at the top of the fixture.) Check `Zip::OutputStream.write_buffer` returns the
  StringIO on rubyzip 3.4 — if it returns something else, capture the io and read `.string` after.

- [ ] `test/services/maker/gerber_archive_test.rb` — share pinned (`use_fresh_share_library!`),
  the `GerberSetsTest` shape. Cases, each a real read through the port:
  1. the Fusion zip: `members` are the four layer PATHS name-ordered (no `.gbrjob`, no `.txt`),
     `stacked == members`, `job_name == "gerber_job.gbrjob"`.
  2. a job naming a subset stacks the subset, still lists all; a job naming nothing the zip holds
     stacks everything; a job that is not JSON stacks everything.
  3. a zip with no Gerber member (only `.txt`) is nil; a zip holding only a `.gbrjob` is nil.
  4. `size` over `READ_LIMIT` is nil **and reads nothing** — count reads with the singleton-method
     technique `gerber_sets_test.rb` already uses (`adapter.define_singleton_method(:read)`).
  5. garbage bytes named `.zip` are nil; a node whose bytes are gone from disk is nil.
  6. THE CACHE: swap `Rails.cache` for `ActiveSupport::Cache::MemoryStore.new` for the test (restore
     in `ensure`); the second `for` performs no read; a node with a different `content_hash` reads
     again. Mutation the test must catch: drop the token from the key → the second assertion fails.
  7. `.gbrjob` is never in `members` or `stacked`.

- [ ] `test/services/maker/gerber_sets_test.rb`: a zip row in a dir is one archive board — `name`
  is the zip's stem, `rows == [zip row]`, `stacked` empty, `archive.members == listing.stacked`; a
  zip beside a loose set in one folder is TWO boards, name-ordered within the section; a zip of
  `.txt` is no board; an oversized zip is no board and no read.

- [ ] `test/integration/web/gerber_preview_test.rb`:
  - a `.zip` holding a Gerber export renders the gerber stage on its file page, `single` false, two
    side buttons, `layers_of` is one entry `{name: "board.zip", url: named_blob…(filename: "board.zip"),
    archive: true, members: [the four paths]}`;
  - a `.zip` of nothing relevant renders no gerber stage;
  - the project page lists the zip under the Fabrication panel with `h3` the zip's stem and badge
    "archive", and its viewer JSON is the archive entry;
  - a zip beside a loose set is two boards on the page;
  - the public page's archive entry uses `public_file_path(handle, slug, zip.node_id, filename: "board.zip")`;
    the unlisted page's URL carries the token (extend the existing token test with the zip);
  - the public viewer URL actually serves the zip bytes (the existing "layer URLs actually serve
    the bytes" pattern).

- [ ] `test/system/gerber_test.rb`: a Fusion zip on its file page reaches `data-gerber-state="ready"`
  and `.gerber-stage svg path` (copper supplies the path), and the Bottom button swaps the side.
  **MUTATION (run for real, output in the PR, then `git checkout -- app/javascript/controllers/gerber_controller.js`):**
  `zip.file(path)` → `zip.file(path + "x")` reds it on the `ready` assertion (the member miss throws,
  the catch sets `failed`).

- [ ] Run, green: the four test files above, `test/controllers/files_controller_preview_kind_test.rb`,
  `test/integration/web/page_query_budget_test.rb` (the project page must stay constant in N — a
  zip adds a port read and a cache fetch, never a query on the null store), `test/stimulus_hygiene_test.rb`,
  `test/integration/web/template_hygiene_test.rb`, `test/integration/web/lazy_bundles_test.rb`,
  `bin/rubocop` on every touched Ruby file. Then bare `bin/ci`.

- [ ] Mutations to run and report VERBATIM (each restored with `git checkout -- <file>`, then
  `find tmp/cache -maxdepth 1 -name 'bootsnap*' -exec rm -rf {} +`):
  - M1 `GerberArchive.for`: drop the `READ_LIMIT` check → case 4 reads (red).
  - M2 `GerberSets#archive_boards`: `next` unconditionally → the sets test and the request test's
    project-page cases red.
  - M3 `FilesHelper#gerber_layers_for`: drop `archive: true` → the request test's file-page case red.
  - M4 the system mutation above.
  - M5 `GerberArchive.for`: key without the token → cache case red.
  - M6 `GerberArchive.listing_from`: stop excluding the `.gbrjob` from `names` → case 7 red.

### A.6 Docs

- [ ] `docs/invariants/files-preview.md`, in the `:gerber` section directly after the paragraph
  **"A `.gbrjob` IS READ ON THE SERVER, and it is the only preview input that is."** — which is now
  false, so rewrite its first sentence to "…and a zipped export is the other" — add one paragraph:
  **A ZIPPED EXPORT IS A BOARD OF ITS OWN, AND THE SERVER ONLY LISTS IT.** State: the one bounded
  port read (judged on the catalog's `size` column first, `READ_LIMIT`), cached in `Rails.cache` by
  content token with nil cached too; rubyzip lists and never extracts, JSZip in the browser does
  (§15); members are identified by BASENAME, the job member picks the stack downward only; a zip is
  never merged with loose layers; the zip's own file page is the board; `preview_kind` stays
  name-only and the zip branch is decided in `show` by a read; filing is untouched (`zip` stays
  `source_archive`, the root-loose wart named above). Mention the sibling comments that state the
  rule (GerberArchive's header, GerberSets, the helper, the controller) so a future edit sweeps them.

- [ ] Sweep every comment that says the viewer's list comes only from `stacked` rows or that a
  Gerber page reads only a `.gbrjob` on the server: both `_fabrication` partials' headers,
  `files/show.html.erb`'s `:gerber` comment, `gerber_controller.js`'s `layersValue` paragraph
  ("a server-built list of {name, url}" — now "or one archive entry"), `GerberSets`'s class comment.
  `grep -rn "stacked" app/views app/helpers app/services/maker/gerber_sets.rb` and
  `grep -rn "gbrjob" app/ docs/invariants/files-preview.md` are the two sweeps.

## Self-review

- Spec coverage: file page (A.3 controller + view), private panel (A.3 partial), public panel (A.3
  partial + `pub.gerber_boards`, which already goes through `GerberSets`), browser extraction (A.4),
  detection (A.1), grouping (A.2), tests (A.5), docs (A.6). Filing deliberately out (header).
- Type consistency: `Listing#stacked` (paths) → `Archive#members` (paths) → the JSON `members`
  (paths) → `zip.file(path)`; basenames only at the two identification points (the job match on the
  server, the `File` name in the browser).
- The s3 story is untouched: the zip is fetched through the same routes as any layer.
