# Flat-file dimensions and the Material estimate tool — design

**Date:** 2026-11-22 · **Branch:** `claude/material-estimate` · **Status:** approved in conversation, awaiting spec review

Two pieces, one shared measuring function:

1. **A file's size in mm and inches** on the file page and in the Library's inspector, for the
   four flat formats the server already measures: SVG, LightBurn (`.lbrn`/`.lbrn2`), DXF and
   MillMage (`.mage`).
2. **A built-in Material estimate tool** at `/tools/material`. You add flat files (uploaded, from a
   project, or from the library) with a quantity each. It reports each part's dimensions, the total
   part area, and how many sheets of a chosen stock size the parts need, with a drawing of each
   sheet.

## Decisions the owner made

| Question | Answer |
|---|---|
| What "total material" means | Sheets of stock **and** total area **and** a list of each part's dimensions |
| Quantity per file | Yes, a number per row, default 1 |
| Uploaded files | **Measured and thrown away**, never saved to the library |
| Formats | SVG and LightBurn, **plus DXF and MillMage** |
| Packing in Ruby on the server, page re-figures in place | Approved with the design |
| The recipe panels' own "Job size" line goes, replaced by the facts row | Approved with the design |

## What exists today (measured on `origin/main` at `909d755a`)

- `Maker::Previews::LbrnMetadata` and `MageMetadata` already store `"job" => {"width", "height"}`
  (mm, rounded to 0.1) and, for a multi-page file, `"pages" => [{name, job, current}]` on the
  **thumbnail** preview row's `metadata`, from `Lbrn2.page_metadata`, the same walk the Measure
  payload's job box comes from (§14h: "the payload's bboxes must union to `Lbrn2.job_size`").
- `Svg` and `Dxf` thumbnails store **no metadata**. Their size exists only inside the `geometry`
  payload (`"job" => {"w", "h", "x", "y"}`, mm at 0.01), which is built on demand when the Measure
  view asks, never by the scan.
- `files/show.html.erb` reads `@thumbnail.metadata` as the **recipe** and renders the LightBurn panel
  for any non-empty metadata that has no `"operations"` key. So metadata that holds only a size would
  draw an empty "Laser settings" panel unless that branch changes.
- `files/_meta.html.erb` (the facts list) is rendered by `files/show` and `files/inspector`, both of
  which hold `@thumbnail`.
- **Cut List** (`tinkerex-addons`, key `cut-list`) packs typed rectangles onto sheets by guillotine
  shelf packing, which follows saw cuts and overcounts for a laser. Add-ons cannot list a project's
  or a folder's files ("Selection is the host's, always", `docs/addon-api-v1.md`). That is why the
  tool below is built in, like the calculator, rather than an add-on.
- The calculator is the one built-in tool: a card on `/tools`, pinnable through
  `Maker::ToolPins::CALCULATOR`.

## Part 1 — dimensions on the file page and in the inspector

### What the user sees

A **Dimensions** row in the facts list, directly under **Size**, on any file of the four formats
whose size is known:

    Dimensions   120.5 × 80 mm · 4.74 × 3.15 in

- **It is the extent of what is drawn**, the same box the Measure view and LightBurn's job size use.
  It is not an SVG's `width`/`height` page or canvas size.
- **mm** go through `recipe_num` (no trailing zeros). **Inches** always show two decimals
  (0.01 in ≈ 0.25 mm, finer than the stored LightBurn rounding of 0.1 mm warrants).
- **A multi-page LightBurn or MillMage file** gets one line per page, named, the saved page marked
  "(in preview)" as the recipe panel's Pages table marks it.
- **No row at all** when the size is unknown: a format outside the four, no preview row yet, a
  thumbnail that has not been rebuilt since this change, or a drawing with no measurable shapes. A
  blank or "—" row would claim something the page does not know.
- Because `_meta` is shared, the **Library inspector** (the right-hand panel when a file is selected)
  shows the same row.

### Changes to the recipe panels

- `files/_lbrn_settings` and `files/_mage_settings` **drop their "Job size" line**. The facts row
  says it, in both units, a few lines below.
- `files/_recipe_pages`' Size column shows **both units** per page, in the facts row's format.
- `files/show.html.erb`'s recipe branch must not draw a recipe panel for metadata that holds **only
  size keys** (`job`, `pages`). Discriminate on the keys present, not on the file extension (the
  existing comment's rule). LightBurn metadata can omit `layers` (`.compact`), so `layers` alone is
  not the test.

### Where the number comes from — one function

New **`Maker::Previews::Dimensions`**, the one reader and the one measurer:

- **`measure(name, bytes)`** → the size facts for a file of the four formats, dispatched on extension:
  - `.lbrn`/`.lbrn2` → `Lbrn2.page_metadata` (via the existing metadata modules or the same call)
  - `.mage` → the same, through MillMage's parse
  - `.svg` → the job box of `SvgGeometry`'s traversal
  - `.dxf` → the job box of `DxfGeometry`'s traversal

  It returns the same Hash shape the metadata already uses (`"job" => {"width","height"}`, optional
  `"pages"`), or a refusal with a reason ("no measurable shapes", "not a readable SVG", …). A
  zero-size job box is "no measurable shapes", never a 0 × 0 part.
- **`from_metadata(metadata)`** → the same facts read back from a stored row, or nil.

**SVG and DXF thumbnails start storing that Hash as their `metadata`**, computed by
`Dimensions.measure` from the same bytes in the same job. That is a change in what the row stores, so
per §14h **`Svg::THUMBNAIL_REVISION` 1 → 2 and `Dxf::THUMBNAIL_REVISION` 3 → 4**. Every SVG and DXF
thumbnail rebuilds once. The row goes `rebuilding` and keeps showing its old picture throughout.
No geometry payload changes for this reason. (`SvgGeometry::FORMAT_REVISION` does move, 2 → 3, for a
separate fix found in review: with no `viewBox`, SVG user units are CSS px whatever unit `width` is
written in, and the old code read them as millimetres. So deploying also re-renders every stored SVG
Measure payload once.)

**THE DELEGATE PATH MUST NOT CARRY SVG METADATA.** `Dxf`, `Lbrn2` and `Mage` rasterize an SVG they
generated, so the rasterize is split out as `Svg.rasterize`, which carries no metadata, while
`Svg.render` (an `.svg` file's own thumbnail) adds its size. Metadata measured from that generated SVG would describe
the wrong document (DXF's units are resolved before it; LightBurn's bed frame is in it). The `.svg`
file's own thumbnail adds metadata; the shared rasterize does not. A test pins that a DXF's and a
LightBurn file's thumbnail metadata is their own format's, not SVG-derived.

**Precision is the format's own.** LightBurn and MillMage keep their existing 0.1 mm values; SVG and
DXF store their geometry job box at 0.01 mm, the numbers the Measure view shows for the same file.

**Which row the file page reads.** The facts row reads a **showable** row's metadata only
(`FilesHelper#file_dimensions`): Enqueue repoints a row at new content without clearing its
metadata, so a pending row still holds the previous content's size. A rebuilding row is a rebuild
of the same content and shows. On a box without `resvg` an SVG or
DXF thumbnail is `unsupported` and carries no size. That is accepted; the production image has resvg.

## Part 2 — the Material estimate tool

### Where it lives

- **`GET /tools/material`**: the page. A card in the built-in section of `/tools`, under the
  calculator.
- **`POST /tools/material`** re-figures the estimate, including adding parts from a project or the
  library. **`POST /tools/material/measure`** takes uploads.
- **Both GET and POST `tools/material` are two-segment `/tools/*` routes and must be declared ABOVE
  `tools/:key`** (routes.rb's long comment), or the addon wildcard swallows them.
- **The keys `material` and `calculator` are reserved.** The addon registry skips an addon keyed
  either one and reports it in `Registry.problems`. An addon keyed `material` would be shadowed by
  the built-in route, silently. One keyed `calculator` would collide with the built-in calculator's
  pin key, which `Maker::ToolPins` already treats as the calculator. Neither key is in the published
  index today (checked against `tinkerex-addons` `addons/manifests.json`).
- **Pinnable**: `Maker::ToolPins` learns a second built-in (`MATERIAL = "material"`, label
  "Material estimate"); the pinned rail link goes to `/tools/material`. The pins controller accepts it
  without reading the registry, as it does the calculator.
- Session-authed, like every web page. Nothing public. The demo account may use it, since nothing
  is saved.

### Adding parts, three ways

1. **Upload** — a file input taking several files at once, `accept`ing the four formats. Each is
   measured by `Dimensions.measure` and **discarded**: nothing reaches the port, the library, Active
   Storage, or a preview row.
2. **A project** — a select of the user's projects. It adds every live file **attached to** that
   project (`Maker::FileAttachment`) with one of the four extensions.
3. **The library** — the existing chooser (`shared/_folder_field`), once in folder mode and once in
   file mode. A folder adds its live files of the four formats **including subfolders**, walked by
   the parent edge (`FileLayer::Subtree`), sorted by name (a chunk_remote node has no stored path, and
   building one is a parent walk per file). Nothing beneath a `.git` is added in practice: share and
   s3 never index its contents, and git's own files carry none of the four extensions.

Every lookup starts from `current_user`. Another user's project, folder or file answers like a
missing one.

**Measuring a library file**: use its thumbnail row's stored facts when that row is `current_build?`
for the file's current content. A measurement is data, and §14h says a consumer that measures asks
`current_build?`. Otherwise **read the bytes through the port** (`Maker::FileBytes.read`, under the
same `PREVIEW_MAX_BYTES` ceiling as previews) and `Dimensions.measure` them. A `FetchError` lists the
part as "library unreachable — try again". Nothing is enqueued from here.

### The parts list

One row per part. A multi-page file is **one part per non-empty page**, because pages are cut as
separate jobs. Each row shows:

- **The name**, linked to the file page for a library file. Upload names are plain text.
- **The page name**, when the file has pages.
- **Width × height in mm and in.**
- **A quantity** (integer, default 1).
- **Remove.**

**A file that cannot be measured stays in the list, greyed, with its reason**, and counts toward
nothing. Dropping it silently would make the total quietly describe fewer files than were added.
Adding the same library file twice is allowed (two rows).

### Stock and settings

- **Sheet width × height**, with a **mm / in** unit for these inputs.
- **Gap**: the space kept between parts and from the sheet edge. One value; default 2 mm.
- **Allow rotating parts 90°**, on by default.
- Remembered **in this browser** (localStorage, wrapped in try/catch, a convenience only). First
  visit: 300 × 300 mm.

### Results

- **Sheets needed.**
- **Total part area**, the sum of width × height × quantity over measured parts, in cm² and in², and
  in ft² as well once it reaches 1 ft².
- **Sheet use**: **placed** part area ÷ (sheets × sheet area), as a percentage. A part too big for
  the sheet stays in the total area and out of this figure.
- **A drawing of each sheet**: the sheet outline and each placed part as a labelled rectangle,
  drawn as server-rendered SVG markup. **Every label is escaped by ERB, never `raw`/`html_safe`**
  (filenames are user-controlled). At most 20 sheets are drawn; past that the page says how many more.
- **Parts that don't fit**: any part larger than the sheet (rotated too, when rotation is allowed) is
  named in a callout above the drawings. It is excluded from the sheet count and still counted in
  the area.
- One sentence under the result: it packs each part's **bounding box**, so nesting software that
  follows the real outline can often fit round or irregular parts tighter.

### Packing

New **`Maker::Material::SheetPack`**, pure Ruby, no I/O:

- **MaxRects, best-short-side-fit**, over every copy of every part, largest area first (ties: longer
  side, then name, then input order, so a layout is deterministic).
- **Rotation** when allowed: each placement tries both orientations.
- **The gap** inflates every part by `gap` on its width and height and packs into a usable sheet of
  `(W − gap) × (H − gap)` offset by `(gap, gap)`. That keeps `gap` between neighbours **and** from
  every edge. A part fits only if `w ≤ W − 2·gap` (in some allowed orientation).
- A sheet opens only when no open sheet can take the next part. Parts are never moved between sheets.
- **Promises the tests pin:** every placement lies inside its sheet's usable area, no two inflated
  placements overlap, every fitting copy is placed exactly once, and the area arithmetic adds up.

### State and requests

- **The page is one form, and the parts list lives in it as hidden fields** (`parts[][name]`,
  `node_id`, `page`, `width`, `height`, `qty`, `reason`). The server holds no session state, so a
  submit re-renders the whole tool body in a Turbo frame from what the form sent.
- Hidden numbers are user-supplied, so they are **re-validated** on every request. A forged value
  only changes that user's own estimate, and a `node_id` only ever becomes a link that 404s if it is
  not theirs.
- **Changing a number re-figures in place**: a small Stimulus controller submits the form,
  debounced, on input. Picking files submits to `/tools/material/measure`. Without JavaScript an
  **Update** button does the same.
- **Uploads have their own action** so they carry their own rate limit:
  `rate_limit to: 20, within: 1.minute, by: user` on `measure`. Re-figuring is unlimited, since it is
  pure arithmetic under the caps below.
- **Nothing is saved.** Reloading the page starts empty, apart from the remembered stock settings.

### Limits

Each limit is a named constant, and each refusal says what was cut:

| Limit | Value |
|---|---|
| Parts in the list | 200 |
| Quantity per part | 1–500 |
| Total placements (sum of quantities) | 2,000 |
| Files per upload submit | 20 |
| Bytes per uploaded file | `PREVIEW_MAX_BYTES` (32 MB default), the preview ceiling |
| Files added from one folder | 200, by name order, with "first 200 of N" |
| Sheet side | 1–10,000 mm |
| Gap | 0–100 mm |

## Invariants touched

- **§14h (`docs/invariants/measure-view.md`)**: per-kind thumbnail revision bumps for Svg and Dxf
  with no geometry bump. One traversal per format, so the facts row, the Measure view and the tool
  read the same box. The delegate-path rule above. The recipe discriminator. These get **new bullets
  in `measure-view.md`**, written in the branch.
- **§15, "keep bytes out of Rails"**: **a deliberate, scoped departure**, chosen by the owner.
  Uploaded files pass through Rails to be measured and are never stored. Rack's multipart tempfile
  is the only copy and dies with the request. The library-file fallback is an ordinary port read,
  as previews already do.
- **§14c / routes**: the two built-in routes above `tools/:key`, and the reserved key.
- **§14m (`docs/invariants/design-system.md`)**: read before styling. Component selectors go in
  `components.css`, and new classes must not reuse a name the addon bundles build markup with.
- **§14d Stimulus**: the new controller is named by a literal `data-controller`.

## Error handling

| Situation | Result |
|---|---|
| Upload of another extension | Listed with "not an SVG, LightBurn, DXF or MillMage file" |
| Unparseable or empty drawing | Listed with the parser's reason / "no measurable shapes" |
| Upload over the byte ceiling | Listed with "over the 32 MB limit", bytes not parsed |
| Share unmounted on a library read | Part listed "library unreachable — try again"; other parts unaffected |
| Over a count limit | The extra parts are not added, and the page says how many were left out |
| Rate limit hit on uploads | The frame shows "too many uploads — wait a minute", and the list survives |

## Testing

- **`Dimensions`**: each format, a multi-page LightBurn file, an empty drawing, a corrupt file, an
  SVG whose canvas is larger than its drawing (the canvas must not win). Mutation-checked.
- **Thumbnail metadata**: SVG and DXF rows carry the facts; DXF and LightBurn metadata are not
  SVG-derived. Revision pins move in the existing `GEOMETRY_REVISIONS` / renderer revision tests.
- **File page and inspector**: the row renders in both units for each format, one line per page,
  nothing for an unmeasured file. An SVG with size-only metadata draws **no** Laser settings panel.
  Assert the rendered text, by driving the real request.
- **`SheetPack`**: exact sheet counts on hand-checked layouts, rotation on and off, the gap at edges
  and between parts, oversize parts, determinism, and the four promises above as properties over
  random inputs. Each mutation-checked (drop the gap, drop rotation, skip the overlap check).
- **Requests**: an upload leaves no node, preview row, blob or library file behind. A project add and
  a folder add take the user's files only; another user's ids answer like missing ones. Limits,
  the rate limit, and the routes reaching the built-in rather than `tools/:key`.
- **One system test**: upload two SVGs, set a quantity, change the sheet size, and watch the sheet
  count and the drawing update.
- **All three backend legs** at identical RUN counts. Library-add tests that need bytes must have real
  bytes on share, s3 and chunk_remote. Project fixtures stay port-free where the test does not read
  bytes.

## Rollout

- Deploying rebuilds every SVG and DXF thumbnail once. Pictures stay up throughout (`rebuilding`), and
  each file's Dimensions row appears as its rebuild lands. Every stored SVG Measure payload also
  re-renders once (`SvgGeometry::FORMAT_REVISION` 2 → 3, the no-`viewBox` unit fix).
- The arc is recorded with `bin/log arc --from-pr <n>` when the PR opens (§15).

## Not in scope

Saving or sharing an estimate. Nesting by true outline. Cost or price per sheet. Several stock sizes
in one run. Material thickness or grouping by material. A Library multi-select "Estimate material"
entry point. MCP or v1 API access to the estimate.
