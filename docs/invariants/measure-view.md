# Invariants — shape measurement, the Measure view (CLAUDE.md §14h)

> **This is CLAUDE.md's §14h, moved out of the always-loaded file on 2026-08-25.** It binds when you
> touch `app/services/maker/previews/`, `Maker::Previews::Geometry` and the four formats that feed
> it, `measure_controller.js`, `lib/print_sheet.js`, `lib/shape_svg.js`, `lib/export_svg.js`, or
> anything that reads a `maker_previews` row — and not at all otherwise. **The rules did not change
> and nothing was dropped.** (The two `lib/` modules were added on 2026-09-02 with the curve
> descriptor and the SVG export; CLAUDE.md's §14h stub names the older paths, and the stub is a
> pointer — this file is the list that binds.)
>
> **The `§14h` anchor still exists in CLAUDE.md and code cites it from the preview stack** — a
> citation resolves to the stub there, which points here.
>
> **Adding a fifth format?** `docs/adding-a-preview-format.md` is the walkthrough; this file is the
> set of rules it must not break.

> **FOUR FORMATS, ONE PAYLOAD.** `.lbrn/.lbrn2`, `.mage`, `.dxf` and `.svg` all measure, through
> `Maker::Previews::Geometry` — which owns the wire shape, the thinning, the circularity test and
> the job box. A format supplies **a traversal and a colour policy, nothing else**. Most rules
> below were written for LightBurn and now bind on all four; the ones that are format-specific say
> so. `measure_controller.js` branches on NO file type — a fifth format is a server-side traversal
> and not a line of JavaScript, and it should stay that way.

- **A CHANGE IN `Geometry` MUST BUMP EVERY FORMAT'S `PAYLOAD_REVISION`, NOT ONE.** Each format
  declares its own and `Enqueue` compares it per row, so a fix to the shared `simplify` that bumps
  only `LbrnGeometry` leaves every already-measured `.dxf` and `.svg` serving the old algorithm
  **forever** — a finished design's content never changes. That is exactly how four LightBurn files
  kept serving mangled curves after the thinning fix deployed. `Geometry::REVISIONED_BY` lists them
  and `GeometryTest` **enumerates the declaring modules from the code** and compares, so a fifth
  format cannot be added without appearing there. **Since 2026-08-19 the CORRECT EDIT is one
  line**: each geometry module is `PAYLOAD_REVISION = Geometry::SHARED_REVISION + FORMAT_REVISION`,
  so bumping the shared term moves **all THREE declared constants** — `LbrnGeometry`,
  `DxfGeometry`, `SvgGeometry` — which propagates to **all FOUR formats**, because `.mage` and
  `.lbrn2` both read `LbrnGeometry`. (This sentence read "all five names" until 2026-08-25; five
  matched neither count, and the bullet's own closing clause already said three. Measured:
  `REVISIONED_BY` has 3 entries, and `Lbrn2`/`Mage`/`Dxf`/`Svg` are the 4 formats answering
  `payload_revision(kind)`.) The outcome above is unchanged — what moved is that the arithmetic
  now does it, instead of three remembered edits.
- **`available?` ASKS WHETHER THIS BOX HAS *ANY* PATH TO A THUMBNAIL — NOT WHETHER IT HAS THE
  RASTERIZER.** `Svg` and `Dxf` gate on **resvg**, because a rasterized SVG is their only path.
  **`Lbrn2` and `Mage` are unconditionally `true`**, because both formats carry the authoring
  app's own render in `<Thumbnail Source="base64png">` and extracting it is pure Ruby. That split
  is the rule; it is not two conventions. Getting it wrong is silent and terminal: `Lbrn2` gated
  on resvg until 2026-08-19 and marked a file **whose PNG was sitting right there**
  `unsupported` on any box without the binary, while the byte-identical `.mage` rendered —
  §14a's one-condition-two-answers, split by format. **A renderer with an embedded-raster path
  therefore also owns the toolchain check in its FALLBACK** (`#outline_thumbnail`, raising
  `NoThumbnail` — the same class `Mage` and `ThreeMf` already use), or the check has nowhere to
  live and a resvg-less box gets an ENOENT from inside the rasterizer instead of a named state.
- **`available_for?(kind)` EXISTS ONLY WHERE IT CAN ANSWER DIFFERENTLY FROM `available?`** — i.e.
  on `Svg`/`Dxf`, whose thumbnail needs resvg while the measure payload (Nokogiri + arithmetic)
  does not. `Lbrn2` and `Mage` **do not define it**: with `available?` already true it could only
  repeat them, and `GeneratePreviewJob#available_for?` falls through to `available?` for a
  renderer that omits it. A test asking `available_for?("geometry")` on a box that HAS resvg
  passes however it is implemented; **stub the rasterizer absent or it proves nothing** — and the
  same trap has a second mouth: `RendererContractTest` does `next unless renderer.available?`, so
  flipping a renderer to unconditionally-true **stops it skipping** and its fixture must then be
  one that renders with no toolchain (hence `embedded-thumb.lbrn2` beside `sample.mage`). Both
  halves are invisible on a box that has the binary.
- **A MillMage `<Shape>` CARRIES `OpIndex`, A LIGHTBURN ONE `CutIndex`** — `Lbrn2.layer_index`
  reads either, and the `||` is unambiguous because no file writes both. The thumbnail cannot see
  the difference (a MillMage file has no `<CutSetting>`, so a nil index and a real one both fall
  through to `DEFAULT_STROKE` and draw the same black), so this surfaced only in the payload, where
  the layer key groups shapes and keys the colour map: **every `.mage` contour landed in one
  nameless layer**.
- **MILLMAGE LAYERS GET NO COLOURS, AND THAT IS A REFUSAL RATHER THAN AN ABSENCE.** `LAYER_PALETTE`
  is defensible only because its values were RECOVERED from 58 real LightBurn exports; MillMage is
  a different application with its own layer bar and no colour field in `<Operation>`. Reusing
  LightBurn's palette would be the mistake this section already names in the other direction (a
  file-supplied colour gets no name, because "Blue" beside a green swatch contradicts itself).
  Detected by ROOT ELEMENT, not extension, so a future MillMage emitting `<CutSetting>`-shaped
  elements cannot silently acquire the palette.
- **`Dxf.to_svg` AND THE DXF PAYLOAD SHARE `each_geometry`; THE SVG LEG CANNOT AND SAYS SO.** For
  the three formats OUR parser draws, a second parse for measuring is §14b's `LbrnMetadata` bug —
  so DXF's drawing was rewritten onto the traversal (verified byte-identical across four inputs).
  An SVG thumbnail is rasterized by **resvg**, which we do not reimplement, so `SvgGeometry` is
  necessarily an independent second reading: resvg understands the whole format, this parser its
  geometry subset, and a file using something outside it measures fewer shapes than the picture
  shows. `<text>`, `<use>` and clip paths are deliberately unparsed. Do not "fix" that asymmetry by
  giving the other three a second parser.
- **`$INSUNITS` IS WHERE A DXF BECOMES PHYSICAL, AND `0`/ABSENT MEANS MILLIMETRES BY CHOICE.** The
  file genuinely does not say; mm is this corpus and it makes a header-less mm file correct, which
  is the common case (`sample.dxf` has no HEADER at all). An inches file with no header reads 25.4×
  small and nothing in the format lets us know. **Colours come from the `LAYER` TABLE, not the
  entity** — an entity's own code 62 is usually absent or `BYLAYER`, so reading only the entity
  leaves nearly every real file colourless — and a **NEGATIVE table colour means the layer is OFF**,
  so its geometry is neither drawn nor folded into the measured extent.
- **SVG IS ALREADY Y-DOWN; DXF IS Y-UP AND MUST BE FLIPPED.** Adding a flip to SVG "for symmetry
  with Dxf" turns every SVG upside down, and it still draws a plausible picture. Only a positional
  assertion catches either direction.
- **AN SVG'S UNITS COME FROM `width`/`height` OVER THE `viewBox`, FALLING BACK TO CSS px AT 96 dpi**
  — which is by definition, and is what makes a viewBox-only file measurable at all. `%`, `em` and
  `ex` are **refused** rather than read as bare numbers. `preserveAspectRatio` `meet` uses
  **min(sx, sy) on both axes**; per-axis reports a stretch the renderer never applies.
- **CURVE FLATTENING IS BOUNDED BY GEOMETRIC ERROR, NEVER BY A FIXED SAMPLE COUNT** — the same rule
  as the thinning below, one stage earlier. A fixed count undersamples a large curve, and an
  undersampled curve's chord sits INSIDE the true curve, so its bbox and its `d` both read small,
  silently. `SvgPath` subdivides adaptively; `Dxf.arc_samples` bounds relative sagitta and **rounds
  up to a multiple of 4** so a circle's axis extents are sampled exactly and `d` is the diameter
  rather than a chord.
- **`SvgGeometry` RECURSES INTO AN ALLOWLIST OF CONTAINERS, NOT PAST A SKIP-LIST.** It started as
  the latter, naming `defs`/`symbol`/`clipPath`/…, and that list was **dead code** — nothing
  recursed into them either way, so removing an entry left every test green. §14b records the
  skip-list blind spot as this repo's recurring bug, four instances deep; an allowlist excludes a
  template element the day it is invented, with nobody remembering to add it.
- **`BITMAP_ALPHABET` IS A `String#count` SET, NOT A REGEX, AND THAT IS A FIX NOT A STYLE CHOICE.**
  The inlined-photo attribute is routinely 10–25 MB and Rails sets `Regexp.timeout` to **1.0 s**;
  the old `%r{\A[A-Za-z0-9+/=\s]+\z}` measured **0.467 s standalone and over the limit through the
  real Nokogiri path**, so it failed by machine speed. `Regexp::TimeoutError` **is** a
  `StandardError`, so `LbrnMetadata.parse`'s blanket rescue swallowed it into nil metadata while
  `to_svg` and the payload — which have no rescue — would have failed the whole preview. `count` is
  45× faster and has no engine to time out; the `+`'s non-empty requirement moved to the caller.
- **EVERY REPORTED NUMBER COMES FROM FULL-RESOLUTION POINTS; THINNING IS DRAWING-ONLY.**
  `Geometry` simplifies contours to keep the payload small (the worst real file drops
  728 KB → 200 KB gzipped) and computes `b` and `d` **before** thinning. Measure after thinning and
  every curve under-reports, silently, while every "does it draw" test stays green. `d` is the
  sharper case: a 0.2 mm hole thins to 9 points, below `MIN_CIRCLE_POINTS`, so measuring after
  would drop its diameter entirely and report a bare bounding box instead of "⌀0.2 mm".
- **THINNING IS BOUNDED BY GEOMETRIC ERROR, NEVER BY POSITION IN THE ARRAY.** `simplify` is
  Ramer-Douglas-Peucker against `SIMPLIFY_TOLERANCE` (0.01 mm). **Do not replace it with an index
  stride** — that is what shipped first, and it was wrong: `Lbrn2.polylines` appends 12 points per
  `B` (bezier) segment and exactly **ONE** per `L` (straight) segment, so a single straight edge
  shifts every later index and no vertex lands where a stride expects. For an `L` segment that one
  point IS a vertex, so dropping it cuts the corner off entirely. Measured over the corpus before
  the fix: **1148 of 5259 thinned contours displaced by more than 5% of their own size, worst case
  58.7 mm.** RDP keeps a corner by construction (a corner is the farthest point from any chord
  spanning it) and is also *smaller* — 200 KB worst case against the stride's 281 KB.
  - The stride's justification, `BEZIER_SAMPLES % DECIMATE_STRIDE == 0`, was **true but only for
    an all-bezier contour**, and `bezier-circle.lbrn2` is exactly that (`B0 1B1 2B2 3B3 0`) — so
    the guard asserting it passed while real mixed-geometry files were being mangled. If you find
    yourself proving a property on that fixture, check it on a contour with an `L` op too.
- **THE PAYLOAD'S BBOXES MUST UNION TO `Lbrn2.job_size`** — one traversal, so the Measure view and
  the Laser Settings panel cannot disagree; §14b's `LbrnMetadata` second-copy bug is the precedent.
  But **a union is the weakest possible form of that assertion** and cannot catch a
  measure-after-thinning bug: any per-shape error some other shape already bounds disappears into
  it. It stayed green on three separate fixtures. The guard with teeth is **per-shape**, on a
  fixture whose ellipse is not shadowed by a larger Rect.
- **CIRCULARITY NEEDS THE 12-POINT FLOOR, NOT JUST THE RADIUS TEST.** A square's four corners are
  all equidistant from its centre — as are any regular polygon's vertices — so radius variance
  alone calls every square round. Measured: a `Rect` emits 5 points with radial spread **0.00000**
  while a real bezier circle's 49 points spread **0.00263**, so the naive metric ranks the square
  as *more* circular. A `Rect` emits 5, a bezier circle 49, an `Ellipse` 33. Accepted consequence:
  a genuine 16-gon reports as round. `bezier-circle.lbrn2` pins both directions and **the square is
  the assertion that carries the weight**.
- **`each_geometry`'s 6th yielded value (`object_id`) counts NON-GROUP `<Shape>`s, and a Text's
  `<BackupPath>` REUSES its parent's** — the outline *is* the text, so alt-clicking one letter must
  report the whole word. A Group consumes no id. **Ids are DISTINCT PER OBJECT and nothing more —
  never assume contiguity**: a shape that yields nothing (a Rect without W/H, an Ellipse without
  Rx/Ry, a Text with no BackupPath) still spends a tick, so gaps are ordinary in a real file.
- **Bitmap base64 is EXCLUDED from the geometry payload, deliberately.** It is the single reason
  the payload is cheap: `metal test 5.lbrn2` is 1.45 MB gzipped as SVG and 0.1 KB as geometry JSON.
  A measuring view needs the rectangle, not the photo. Restoring it re-inflates every
  photo-engraving file by three orders of magnitude. `rake lbrn:geometry_report` is what notices —
  no fixture is big enough to.
- **A CORRUPT DOCUMENT RAISES; AN EMPTY ONE DOES NOT.** `LbrnGeometry` raises `ParseError` when
  `doc.root` is nil, matching `to_svg`, so the job marks it `failed`. A document that parses with no
  shapes returns the empty payload and goes `ready`. Collapse them and a corrupt file presents as a
  working Measure view reading "No measurable geometry in this file" — a lie about the file.
- **`geometry` IS THE FIRST KIND TO EXERCISE THE PREVIEW `kind` SEAM END TO END.** `model_glb` is
  declared in `Preview::KINDS` but refused by `Mesh`, so nothing produced a second artifact from one
  file until this. `RendererContractTest` still passes because its `render_with` never sends
  `kind:` — it exercises the thumbnail path, where "must be an inline-safe raster" stays true.
- **A CONTENT REPOINT BLANKS THE ARTIFACT; A RENDERER REBUILD DOES NOT.** `pending` exists so a user
  never sees an artifact of the PREVIOUS CONTENT labelled as the current file — a lie the spinner
  honestly replaces. A renderer bump is not that case: the stored artifact still depicts this exact
  file, only the code that built it moved on. Blanking it swapped a correct picture for a spinner
  on a page that **does not poll**, so it stayed a spinner until someone reloaded, and read as
  "generating preview is broken".
- **A CONSUMER THAT CANNOT TOLERATE AN OLDER BUILD'S OUTPUT SAYS SO ITSELF.**
  `FilesController#geometry` answers `pending` whenever it had to enqueue, **without reading the
  row's status** — geometry is DATA the client measures from (an older build's payload is wrong,
  not merely old) and its client polls, so pending resolves itself. The thumbnail is a picture on a
  page that doesn't poll. Same mechanism, opposite right answers; do not unify them.
- **A REVISION CHECK IN `Enqueue` IS USELESS UNLESS THE READ PATH ASKS FOR IT — and for thumbnails
  it did not.** `Enqueue` compared revisions correctly from the day it shipped, but only something
  that CALLS it can act on that, and the caller skips any node the read reports a row for. That
  query matched on `(kind, node_id, version_id)` alone — so a stale row satisfied it, nothing
  re-enqueued, and **172 of 174 LightBurn thumbnails sat at revision 1 through two deploys that had
  bumped it**, leaving the layer colours those deploys added invisible. **Every test of the
  mechanism passed throughout**, because they all called `Enqueue` directly and none drove the thing
  a user does — open a page. `test/integration/web/maker_page_thumbnails_test.rb` exists for exactly
  that gap and drives real requests.
- **`Maker::Previews::ThumbnailMap` IS THE ONE IMPLEMENTATION OF BOTH THE REVISION FILTER AND THE
  BACKFILL, AND `FilesController` CALLS IT RATHER THAN KEEPING ITS OWN.** The bug above was fixed in
  `FilesController#thumbnails_for`/`#backfill_thumbnails` and nowhere else, so the Models page, the
  project covers and `ProjectsController#show`'s two maps — five call sites that go through
  `ThumbnailMap` — had **neither**: a missing row spun forever (nothing in that path ever called
  `Enqueue`, and `/files/thumbnails` omits a row-less node from its JSON, so the client's
  `if (!entry) continue` gives up after 40 polls, still spinning) and a stale row was **served**, an
  old picture presented as the file's current thumbnail. Those three controller privates are **gone**,
  not duplicated — the enqueue belongs to the service and not the callers (§14d) because its inputs
  are precisely what this class computes and does not expose, and because a sixth caller must get it
  without knowing to ask. Two consequences to keep: **`from_info`'s `backfill:` is REQUIRED, not
  defaulted**, because its two callers disagree and both wrong answers are silent (`#index` must
  self-heal; `#thumbnails` is polled every 2 s for 40 ticks and must not write) — guarded by driving
  the real endpoint, since no unit test of the map can see which flag an action passes; and the
  **renderable-only check earns its place at the BUDGET, not at correctness** — `Enqueue` already
  refuses a name no renderer handles, so deleting the check creates no rows and enqueues no jobs and
  came back GREEN under mutation, while `budget -= 1` runs unconditionally, so a wall of `.gcode`
  ahead of the models would spend the whole budget on files that can never have a thumbnail and the
  backlog would never drain.
- **`pending` AND `processing` ARE ASSERTIONS THAT A JOB EXISTS, AND `Enqueue::STALLED_AFTER` IS THE
  ONLY THING THAT EVER VERIFIES THEM.** `failed` re-enqueues, `ready` is done, `unsupported` is
  terminal by design — those two were the only statuses with **no way back**, so a lost job wedged
  the row FOREVER: `Enqueue`'s early return fires for every caller, so the 15-minute scan,
  `ThumbnailMap`'s backfill, `#current_thumbnail` and the addon door all no-op'd on it, and
  `MissingBackfill` looks only for content with NO row. Three rows sat wedged on the live share
  library, the oldest over a week, spinning. **The window is what keeps the escape from becoming a
  stampede** (the backfill calls `Enqueue` per row on every Files render), and **the
  explicit `updated_at` restamp is what keeps the heal from repeating** — healing changes no other
  attribute and `save!` on an unchanged record is a NO-OP that leaves the timestamp alone, so
  without it every scan and page load adds another duplicate job. All three halves are
  mutation-checked; dropping `|| stalled` must produce **two** failures, not one.
- **A JOB WHOSE ARGUMENT IS A PRIMARY-DB ROW ID MUST SET `enqueue_after_transaction_commit`, BECAUSE
  THE JOB LIVES IN A DIFFERENT DATABASE FROM THE ROW.** Rails 8.1 defaults it to **false**, so
  `perform_later` commits to the QUEUE database on its own connection **immediately** while the row
  is still inside the caller's open transaction — and Solid Queue runs IN THE PUMA PROCESS here
  (`SOLID_QUEUE_IN_PUMA`) polling sub-second, so it wins that race. `Maker::GeneratePreviewJob`'s
  own `discard_on ActiveRecord::RecordNotFound` then made the loss **silent**: no failure, no log,
  job marked finished, row stranded at `pending`. Proven on the box — job 15583 created *and*
  finished at 2026-08-13 23:09:20 while preview 1747 was never touched. **Every addon save is inside
  a transaction** (`Tools::AddonsController#create`), which is why addon output was hit and uploads
  were not. Set PER JOB, not globally: it is a claim about that job's argument, and it belongs
  beside the `discard_on` it interacts with.
- **A PREVIEW IS STALE ON TWO INDEPENDENT AXES, AND `version_id` IS ONLY THE FIRST.** It asks
  whether an artifact was made from the file's current CONTENT; `renderer_revision` asks whether it
  was made by the current CODE. With only the first, a payload change invalidated **nothing** —
  a finished design's content never changes — so the .lbrn2 thinning fix deployed and four
  already-measured files kept serving mangled curves until they were destroyed by hand, on the one
  backend of three that had them. **Change a payload → bump the renderer's `PAYLOAD_REVISION`.**
  - **Revisions are PER KIND** (`Lbrn2.payload_revision(kind)`): one renderer emits both a
    thumbnail and a geometry payload, and bumping geometry must not rebuild ~1400 thumbnails as a
    side effect of an unrelated fix.
  - **`renderer_revision` is `NOT NULL DEFAULT 1`, and both halves are load-bearing.** Nullable, a
    NULL would differ from every declared revision, so adding the column would itself have
    triggered a full-library re-render; and `Enqueue` is **not** the only creator —
    `V1::Maker::PreviewsController` builds rows via `find_or_initialize_by`, which with no default
    would leave them stale forever, re-enqueueing on every request.
  - **`SCHEMA_VERSION` is NOT this**, and is the easy thing to bump by mistake. It is the wire
    contract the JS checks; `PAYLOAD_REVISION` is the server-side cache key. Revision 2 changed
    every coordinate while touching no key, so the schema was rightly left alone.
  - **A RENDERER WHOSE OUTPUT IS BUILT BY ANOTHER RENDERER MUST TRACK THAT ONE'S REVISION.**
    `ThreeMf`'s mesh fallback calls `Stl.render`, so bumping `Stl` alone leaves every CAD-exported
    3MF (Shapr3D, Onshape, Fusion — none carry an embedded slicer thumbnail) rendering from the old
    code forever, with nothing anywhere to say so. Pinned as a RELATIONSHIP in `stl_test.rb`, never
    as two literals.
  - **AND A CHANGE IN THE RUST CRATE NEEDS THE RUBY-SIDE BUMP, WHICH IS THE HALF WITH NO COMPILER
    BEHIND IT.** `tools/stl-thumbnailer` has no idea a `maker_previews` row exists. Rebuilding the
    binary without bumping `Stl::THUMBNAIL_REVISION` re-renders nothing; bumping without rebuilding
    re-renders everything with the old binary. **Ship both or neither.**
- **THE STL/3MF WORLD IS Z-UP, IN BOTH RENDERERS, AND NO EXISTING TEST COULD SEE IT WHEN IT WAS NOT.**
  The formats declare no orientation, but every producer and consumer in 3D printing treats +Z as up
  (the 3MF core spec puts the build plate in the XY plane). `auto_frame` orbited **Y** and the Three.js
  viewer used the library default, so every model rendered **tipped onto its side** — consistently
  enough to read as a house style. Every thumbnail test asked "is the frame non-blank?", which a model
  lying down answers exactly as well as one standing up; **only a POSITIONAL assertion catches this**,
  and it needs BOTH directions (a tall column must render tall AND a flat slab must render wide) or a
  fix that merely swapped which axis is wrong still passes. `.obj` stays Y-up — that is Wavefront's own
  convention, and guessing Z there breaks the case the per-format map exists to get right.
  - **THE VIEWER MOVES THE CAMERA, NOT THE MODEL**, and three.js's own 3MFLoader docblock suggests the
    opposite (`object.rotation.set(-Math.PI/2, 0, 0)`). Equivalent on screen, wrong for `showDims`: the
    bounding box is read AFTER parse, so a rotated 10×20×30 model reports "10 × 30 × 20 mm" — a
    measurement contradicting the user's own slicer.
- **`FilesController#geometry` READS THE EXISTING PREVIEW ROW BEFORE CALLING `Enqueue`.** `Enqueue`
  resets a `failed` row to `pending` and re-enqueues *whenever called* — right for a one-shot nudge
  at upload time, wrong for a poll. Unconditional, it makes the action's own `"failed"` branch
  **dead code** and re-enqueues a doomed render on every poll of a broken file. Accepted: a `failed`
  geometry preview is terminal until the content changes, which is honest because a transient
  byte-store failure is a `FetchError` that leaves the row `processing` and self-heals.
- **`#geometry` RESCUES `RecordNotFound` LOCALLY**, because the class-level `rescue_from` branches
  on format and answers a plain `get` — html, the default with no Accept header — with a **302 to
  `files_path`**. Right for `#show`/`#blob`, which render a page; wrong for a JSON poller, which
  would read a redirect body carrying neither a status key nor a 404.
- **The Measure view builds its SVG with `createElementNS`, never `innerHTML`.**
  `Maker::Previews::Svg` rasterizes precisely because the web layer refuses to inline SVG;
  constructing elements from parsed coordinates sidesteps that rule rather than excepting it.
- **Hit-testing is PAINT ORDER, not geometry.** Contours are appended in DESCENDING bbox-area order
  so the browser's own topmost-wins dispatch selects the hole rather than the plate around it.
  There is no point-in-polygon code; reversing that sort silently makes every small feature inside
  a larger one unclickable, while drawing an identical picture. Pinned by
  `nested-plate.lbrn2` — a plate and a hole on a SHARED CENTRE, clicked at the SVG element's own
  centre so paint order alone decides the answer. `bezier-circle.lbrn2` cannot test this and the
  gap went unclosed for a while because of it: its two shapes are equal-area AND disjoint, so
  neither ever covers the other.
- **LIGHTBURN'S LAYER PALETTE IS A HARD-CODED TABLE, AND THAT WAS RELITIGATED ON PURPOSE.** §14's
  earlier note refused one, on the grounds it would mean "30 colours guessed from thumbnails". The
  Measure view changed the calculus — it draws OUR outlines, where the file's own render is
  unavailable and the alternative is flat black — and the values are no longer guesses: most were
  RECOVERED from the embedded thumbnails by mapping contours into pixel space and reading what
  LightBurn painted. `Lbrn2::LAYER_PALETTE` marks each entry `measured` or `palette strip`. It is
  cosmetic by construction: nothing measures or decides anything from it.
- **THE PANEL LABELS A LAYER BY COLOUR ONLY WHEN LIGHTBURN NAMED IT AFTER ITS INDEX**, and the
  precedence has three arms, all load-bearing: a name its owner CHOSE wins outright; else the
  colour's name, since "C01" says nothing the swatch does not; else the file's own label
  **verbatim**. That last arm is reached whenever a file OVERRIDES a layer's colour — there is then
  no palette name — and reconstructing it as `"C#{index}"` loses LightBurn's zero padding, turning
  `C00` into `C0`. A pre-existing flow test caught exactly that.
- **A FILE-SUPPLIED COLOUR GETS NO NAME.** `Lbrn2.layer_name` names the PALETTE entry for an index,
  so naming a recoloured layer prints "Blue" beside a green swatch — a label contradicting the
  thing it labels. `LbrnMetadata` returns nil there and the view falls through. The names are ours,
  not LightBurn's (it identifies layers only by number), which is why a user's own name outranks
  them.
- **THE PALETTE HAS ONE DEFINITION, SERVER-SIDE.** The geometry payload carries a `colors` map for
  the layers a file uses, rather than the client looking indices up in a copy — §14d's third
  extension→role table is the precedent for what a second copy does. It also means a file that DOES
  override a layer's colour is honoured without the client knowing that is possible.
- **THE LAYER COLOUR IS AN SVG PRESENTATION ATTRIBUTE, NEVER `node.style`, AND `.measure-contour` MUST
  NOT DECLARE A STROKE.** Presentation attributes sit BELOW every CSS rule, which is exactly what
  lets `--hover`/`--selected` recolour a contour. Set it inline instead and selection silently stops
  changing colour (only width moves); give `.measure-contour` a stroke and every layer flattens to one
  colour. Both directions are mutation-checked, and both need the COMPUTED style asserted — reading
  the attribute reports what we wrote even when a rule outranks it.
- **The pan/click slop is in SCREEN PIXELS, not user units.** Zoomed in, one mm is many pixels, so a
  user-space threshold calls an ordinary click a drag and silently swallows the selection.
- **THE PRINT SHEET'S SCALE IS `width="215.9mm"` PLUS A `viewBox` SPANNING 215.9 USER UNITS, AND
  THAT PAIR IS THE WHOLE MECHANISM.** There is no transform and no dpi constant. A px width over
  the same viewBox draws an identical-looking page at the wrong size, **on paper**, where the error
  is discoverable only with a ruler — so `measure_print_test.rb` asserts both literals AND
  separately asserts that a 60 mm part spans 60 units. "A polygon exists" is answered exactly as
  well by a polygon of the wrong size — and nothing pinned the printed size against the PAGE until
  late in the arc: `transform: scale(0.9)` on the print stylesheet's `svg` rule left the file green
  at 45 runs / 444 assertions.
  Same trap one attribute over: a unit suffix inside an SVG attribute resolves through CSS at
  96 dpi, so `font-size="3mm"` computes to 11.3386px — a header nearly four times too tall on a
  sheet that still looks like a sheet.
- **THE HEADER AND CALIBRATION STRIPS ARE RESERVED, NOT OVERLAID — the deliberate divergence from
  the `boxes` sibling**, which draws its bar over its own content because it knows that content is
  a tray plan of known extent. Measure prints arbitrary user geometry that can be anywhere, so an
  overlaid ruler lands across a part outline. The consequence is a real `<clipPath>` where the
  sibling gets away with a bbox filter — and a `clip-path` naming a missing id is **silently
  inert**, so the guard asserts the browser's own geometry (a point inside the window is painted,
  one outside is not) rather than reading the attribute back.
- **THAT CLIP AND THE PAGE TRANSFORM MUST STAY ON TWO NESTED `<g>`s — COLLAPSING THEM PRINTS A
  BLANK SHEET.** `clipPathUnits` defaults to `userSpaceOnUse`, which is the user space of the
  element **referencing** the clip, not the page — so one group carrying both makes the window
  travel with the geometry. Verified in Chrome by hit testing, not reasoned: on `nested-plate` the
  sheet prints a 20 × 3 mm scrap of one corner, and for an ordinary file whose parts sit at
  POSITIVE coordinates the translate is negative, the window lands off-paper, and the whole sheet
  prints **blank** — no error, nothing logged, on a document that is otherwise perfectly formed.
  It survived all **24** of that task's mutations because the clip was never asserted at all:
  deleting the `<clipPath>` element AND the `clip-path` attribute outright left the suite green.
- **THE PRINTED SIZE LABEL COMES FROM `sizeLabel()`, INJECTED FROM THE CONTROLLER, NEVER RE-DERIVED
  FROM `shape.p`.** Those are the THINNED drawing points: measuring from them under-reports every
  curve, and a re-derivation loses the ⌀ ENTIRELY, printing a bounding box where a diameter
  belongs — because the CLIENT HAS NO CIRCULARITY TEST AT ALL; `d` is decided server-side from
  full-resolution points. (An earlier wording blamed `nested-plate.lbrn2`'s ⌀10 hole thinning below
  `MIN_CIRCLE_POINTS`. Measured: it keeps **49** points against a floor of 12 — the mechanism is
  the missing test, not the point count. The 0.2 mm hole two bullets up is the real floor case.) The same trap as measuring before
  thinning, one surface further out, and on the one surface a maker may read INSTEAD of measuring.
  Mutation-checked.
- **THE PRINT IFRAME IS BUILT AS NODES, NOT `doc.write` ON A MARKUP STRING**, because the header
  carries a library FILENAME — user-controlled, and legitimately able to contain `<` on a
  NAS-scanned share. The `boxes` sibling can use `doc.write` because its plan carries no user text;
  copying that pattern across is an injection into a same-origin iframe with this page's cookies
  behind it.
- **`lib/print_sheet.js` DUPLICATES THE `boxes` BUNDLE'S `sheet.js` CONVENTIONS ON PURPOSE** —
  same `MARGIN`/`OVERLAP` = 10, same `MAX_SHEETS` = 40, same `Sheet c,r of C×R`. That bundle lives
  in `chaim354/tinkerex-addons`, where **publishing IS the deploy and Rails is never rebuilt**
  (§14c), so importing it through the addon asset proxy would let an addon republish break a core
  file page — and would remove Measure's print button outright on OVH, which blanks
  `ADDON_SOURCE_URL`. Conventions copied, code not. If they ever must agree mechanically, move the
  pagination to ONE place; do not add a third copy.
- **A SINGLE SHEET CARRIES NO `Sheet 1,1 of 1×1` LABEL**, because there is nothing to register
  against — and both halves of that rule are mutation-checked, since an implementation that always
  labels and one that never does each pass half the tests.
- **`g` IS A DRAWING HINT AND NOTHING MEASURES FROM IT — the contract both traversals already
  stated, extended to a second consumer.** `Lbrn2.each_geometry` and `Dxf.each_geometry` have
  always yielded an exact ellipse/circle/arc beside the flattened points, and both thumbnail
  renderers have always drawn it; `Collector#add` had no slot for one, so the payload discarded it
  BY NAME (`_ellipse`, `_curve`) and the Measure view drew a 32-gon beside a thumbnail drawing an
  ellipse. `b`, `d` and the job box are still computed from FULL-RESOLUTION POINTS, so a client
  ignoring `g` draws what it drew before it existed and reports identical numbers. **ABSENT, NOT
  NULL:** `"g" => nil` on every polygon is bytes for nothing on exactly the densest files — the
  ones the payload's size budget exists for — and the client's own check is truthiness, so a null
  would read as "no descriptor" while still being paid for.
- **NOTHING INFERS A DESCRIPTOR FROM THE POINTS, AND THAT IS THE WHOLE SAFETY ARGUMENT.** A shape
  gets one because the FILE said `<Ellipse>` / `CIRCLE` / `ARC` / `<circle>`, never because it
  measured round. `Geometry.diameter`'s accepted consequence — a genuine 16-gon reports as round —
  stays confined to the ⌀ LABEL, which is advisory. Reaching it into `g` substitutes a circle for a
  designed polygon in a file somebody CUTS: the label trap one surface further out and one degree
  worse. `bezier-circle.lbrn2`'s Path circle is the pin — `d` present, `g` absent — and it is the
  assertion no `<Ellipse>` fixture can make.
- **THE AXIS-ALIGNED GATE IS LOAD-BEARING ON BOTH LEGS, AND HAD NO TEST AT ALL UNTIL 2026-09-02.**
  Under a rotation an SVG `<ellipse>` is not an SVG `<ellipse>`, so emitting one exports geometry
  the file does not contain. Every `<XForm>` in the fixture corpus was a translate or a scale, so
  `Lbrn2.axis_aligned?` was a GREEN MUTATION for as long as it existed — it governed only thumbnail
  crispness and nothing noticed; carrying the descriptor into the payload made it govern exported
  geometry. `rotated-ellipse.lbrn2` carries an upright ellipse AND a 30° one, because an
  implementation that always emits and one that never emits each pass half of a one-shape fixture,
  and its radii differ (20 × 10) because a rotated CIRCLE is still an upright circle and could not
  tell a working gate from a missing one. `SvgGeometry.ellipse_curve_for` applies the same test for
  the same reason.
- **A 360° DXF `ARC` IS ENCODED AS AN ELLIPSE, NEVER AS AN ARC.** `Dxf.arc_points` turns
  `a0 == a1` into a 360° sweep — its own comment, *"the whole circle, not a zero-length arc"* —
  whose start and end points are IDENTICAL, and SVG's rule for an arc whose endpoints coincide is
  to omit the segment ENTIRELY. An `A` command there exports a path that draws nothing: no error,
  nothing logged, a shape simply missing from a file somebody cuts. **`Dxf.arc_svg` STILL HAS THIS
  BUG FOR THE THUMBNAIL** — recorded, not fixed, because the fix needs a `THUMBNAIL_REVISION` bump
  and a DXF thumbnail rebuild; the payload path must not inherit it.
- **AN ARC'S WIRE FORM IS CENTRE + START ANGLE + SIGNED SWEEP, BECAUSE SVG'S ENDPOINT
  PARAMETERISATION CANNOT BE ROUNDED.** SVG puts the centre `sqrt(r² − d²)` from the chord midpoint
  (`d` the half-chord), so an error δ in an endpoint displaces the centre by about `sqrt(2rδ)` —
  ill-conditioned near a half-turn, and worse as the radius grows. Resolved `A` endpoints rounded
  to `PRECISION` drew **1.37 mm** from the curve the shape's own points describe at r = 200, on a
  180° slot end cap — the commonest arc in a laser or CNC DXF — while `p` in the SAME payload was
  good to 0.005 mm: the descriptor exists to be MORE faithful than the points and was ~240× less
  so. Centre-plus-angles has no such conditioning, because the client resolves the endpoints itself
  at double precision: worst case **0.00836 mm over all 3600 start angles**, and FLAT IN RADIUS,
  which is the actual fix rather than the smaller number. Emitting more decimals is not a fix — it
  leaves the parameterisation ill-conditioned and needs about nine places to be safe at r = 200.
  - **`ANGLE_PRECISION` (6) IS SEPARATE FROM `PRECISION` (2) BECAUSE `PRECISION` IS A LENGTH.** An
    angle error ε displaces a point by `r·ε`, so PRECISION's 0.005° half-step is 0.0175 mm at
    r = 200 and 0.087 mm at r = 1000 — the descriptor would again be less accurate than the points
    it rides beside. Rounding both at one constant is the same defect wearing a tidier constant.
  - **THE GUARD MUST RESOLVE THE DESCRIPTOR BACK TO A CURVE AND COMPARE IT AGAINST THE SHAPE'S OWN
    `p` AND `b`.** A test asserting the five numbers passes on any self-consistent encoding and
    could never have seen this — the numbers were never what was wrong, the parameterisation was.
- **A REVISION IS BUMPED ONCE PER SHIPPED CHANGE, NOT ONCE PER EDIT.** `SHARED_REVISION` moved
  0 → 1 when `g` was introduced; the arc's wire form was then REDEFINED inside that same unmerged
  revision and deliberately NOT bumped again. A revision exists to invalidate STORED artifacts, and
  no deployment had ever served revision-1 arc bytes — there was nothing to invalidate, and a
  second bump would re-measure every payload in the library for a form no row holds. **The single
  bump is deliberate, not forgotten**, and `SHARED_REVISION`'s own log says so beside the number,
  which is where a later reader looks before deciding it was missed.
- **THE ELEMENT A SHAPE DRAWS AS HAS ONE DEFINITION, `lib/shape_svg.js`, AND IT WRITES NO
  PRESENTATION.** Three callers want three presentations of one shape — the Measure view's class +
  layer colour under a transparent hit twin, the print sheet's black 0.2 mm, the exporter's layer
  colour at 0.1 mm — so the shared module picks the ELEMENT TYPE and the geometry attributes only,
  and each caller applies its own. `el` and `unionBox` moved there too and `print_sheet.js`
  RE-EXPORTS both, which is what keeps `measure_print_test.rb`'s pin of `el`'s mis-call guard
  working through the move; `measure_controller.js`'s `unionOf` was byte-identical to `unionBox`
  and is gone, and the exporter would have made a third copy. **A circle gets `<circle>`, not an
  `<ellipse>` with equal radii** — both draw the same picture, but the export's destinations are a
  vector editor and a CAD sketch import, where `<circle>` is the unambiguous primitive and an
  ellipse may arrive as a spline. **And the resolved arc endpoints go out UNROUNDED**: rounding
  them here rebuilds the ill-conditioning the wire form exists to remove, one layer further out.
- **THE HIT TWIN IS ALWAYS A POLYLINE FROM `shape.p`, EVEN UNDER AN ARC.** It is an invisible 8 px
  target, so approximating the curve costs nothing visible and keeps the twin one element. Build it
  from the points, never by reusing the visible node's `points` string — the visible node no longer
  necessarily has one.
- **A CONTOUR IS NOT NECESSARILY A `<polygon>`, SO `points` IS NOT A GENERAL WAY TO ASK ONE WHERE
  IT IS — AND THREE HARNESSES ASSUMED IT WAS.** `measure_formats_test.rb` and
  `measure_print_test.rb` read `[:points]` off whatever `.measure-contour` they found and got
  **nil** the moment a file-declared circle rendered as `<circle>`: two errors from subtracting
  from nil, and one failure reading *"the fixture or the draw changed"* when neither had.
  `lbrn_measure_test.rb` carries the IDENTICAL pattern and is green only because its helper happens
  to be aimed at all-polygon fixtures — luck, not coverage, and it selects `polygon.measure-contour`
  by tag today. Ask each element kind for its own geometry (`circle` cx−r, `ellipse` cx−rx, else
  the `points` parse) and answer **nil** for anything else: an arc is a `<path>` whose geometry
  lives in `d` and carries no such attribute at all, so nil makes the caller report a missing
  contour rather than raise. Select by CLASS, never by tag; `.measure-contour--hit` is a different
  token, so widening never matches the twin.
- **THE EXPORT IS NORMALIZED TO THE ORIGIN AND ITS CANVAS SIZE IS THE PART SIZE.** `width="{w}mm"`
  plus a viewBox spanning the same `w` is the ENTIRE scale mechanism — the same pair the print
  sheet uses, no transform and no dpi constant — so a px width draws an identical-looking file that
  is silently the wrong size in an application that will cut it. ONE translate for the whole
  selection, so several selected parts keep their relative positions; and normalizing at all is
  what stops a part pulled out of a 1200 mm sheet importing as a speck in an empty canvas. The root
  is created IN the SVG namespace so the serialiser writes `xmlns` itself — adding
  `setAttribute("xmlns", …)` as well emits it TWICE, which is not well-formed XML and which some
  importers reject outright.
- **THE EXPORT USES THE LAYER COLOUR WHERE THE PRINT SHEET USES BLACK, AND THAT DIVERGENCE IS
  ARGUED.** The sheet is black because a mono printer turns a layer palette into indistinguishable
  greys, on the one artifact whose job is to be measured and cut against. A file has no such
  constraint, and LightBurn maps stroke colour back to layers on import.
- **`lib/export_svg.js` BUILDS THE DOCUMENT AND THE CONTROLLER BUILDS THE BLOB.** The same split
  `print_sheet.js` draws between `renderSheet` (pure) and `buildPrintFrame` (not), and it is what
  lets the export be asserted as a STRING: headless Chrome here has no configured download
  directory, so the system test shims `URL.createObjectURL` and `HTMLAnchorElement.prototype.click`
  instead of looking for a file on disk. An empty selection REFUSES rather than writing a 0 × 0 mm
  document — that opens in every viewer showing nothing, which reads as "the export is broken"
  rather than "you selected nothing", and the caller has a readout to put the message in.
- **THE SVG BUTTON'S VISIBLE TEXT IS CONSTANT AND ITS ACCESSIBLE NAME IS NOT.** The actions bar
  carries six controls, so a second count-bearing label beside "Print 3 parts" is noise — but a
  button must not lie about what it does, so its `aria-label` AND its `title` are written from the
  same `targetNoun()` the Print label uses, by the same refresh — and the ERB's at-rest literals
  are that same string with the noun `all`, so all three can only drift together.
  **`targetShapes()` and `targetNoun()`
  are the ONE definition of the three-arm precedence** — marked set, else the selected contour,
  else the whole file. It was written out TWICE, in `print()` and in `refreshPrintBar()`, under a
  comment saying the two "must not drift", which is prose where a mechanism belongs; the exporter
  would have been a third copy.
