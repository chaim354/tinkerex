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
  - **THE RULE CUTS ON WHAT A FORMAT EMITS, NOT ON WHICH FILE WAS EDITED, AND AN ADDITIVE HELPER IS
    THE CASE THAT SEPARATES THEM.** It exists for a change that alters what ALL formats emit — a
    fix to `simplify`, a new rounding, a different job box. `Geometry.path_curve` was ADDED on
    2026-09-03 and moves not one byte of a format's output until that format CALLS it:
    `LbrnGeometry` (4 → 5) and `SvgGeometry` (1 → 2) do and each bumped its OWN term, `DxfGeometry`
    did NOT ON THE DAY, and **`dxf_geometry_test.rb`'s three then-unchanged digests are the evidence
    rather than the claim** that a DXF payload was byte-identical across it. **It CALLS the helper
    since 2026-09-03** — a spline's own cubics — and bumped its own term again, 2 → 3, which is this
    rule working rather than an exception to it: what moved was one format's USE of a helper that
    did not itself change, and the other three formats' payloads are untouched by it either way.
    Bumping the shared term there would re-measure every `.dxf` in the library for a change that
    cannot reach one — the same waste in the opposite direction from the staleness the constant
    exists to prevent. **Ask "does this format's output move" per format**; where the answer is yes
    for all of them, that is what the shared term is for. `GEOMETRY_REVISIONS`' absolute pins are
    what make either mistake visible.
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
  repeat them, and `Maker::Previews::Registry.available_for?` (what `GeneratePreviewJob` asks) falls
  through to `available?` for a renderer that omits it. A test asking `available_for?("geometry")`
  on a box that HAS resvg passes however it is implemented; **stub the rasterizer absent or it
  proves nothing** — and the same trap has a second mouth: `RendererContractTest` does
  `next unless renderer.available?`, so flipping a renderer to unconditionally-true **stops it
  skipping** and its fixture must then be one that renders with no toolchain (hence
  `embedded-thumb.lbrn2` beside `sample.mage`). Both halves are invisible on a box that has the
  binary.
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
- **A `case` WITH NO `else` OVER A FILE FORMAT'S ENTITY TYPES IS SILENT DATA LOSS, AND `Dxf.flatten`
  HAD ONE.** SPLINE, ELLIPSE and INSERT returned nil and `each_geometry` skipped them with no error,
  no log and no status: **18,906 splines across 29 of 129 real files**, `elianadxf.dxf` — four
  splines and nothing else — reporting `shapes=0, job 0×0` under a Measure view reading "No
  measurable geometry in this file" about a file that is entirely geometry. **WORSE THAN A MISSING
  PICTURE:** a skipped entity never reaches `Collector#add`, so it is absent from the **bbox** as
  well as from the drawing and every reported size describes a SUBSET, with nothing on screen to say
  so — the measure-after-thinning failure below, at whole-entity scale. `Geometry.build(unreadable:)`
  → the payload's `"u"` key is the backstop, and it lives in the SHARED builder because any of the
  four traversals can meet something it cannot read; DXF is only where it was measured. The hash is
  handed IN and filled during the yield, so `build` reads it AFTER the traversal — a tidier version
  snapshotting the argument at the top emits an empty tally on every file with nothing going red.
  The client says so in `restingStatus()` **and** in the zero-shape branch, which never reaches it
  and is the case the mechanism was built for.
  - **ONCE A TYPE BECOMES DRAWABLE THE TYPE-BASED TALLY STOPS FIRING FOR IT, SO A REFUSED INSTANCE
    MUST BE TALLIED EXPLICITLY AND UNDER A DISTINCT NAME.** `parse_document` counts a `0`-code name
    that is NOT in `ENTITY_TYPES`, so promoting `SPLINE` or `INSERT` into that list — the very
    change that makes them draw — silences the only thing reporting the instances still refused.
    That is worse than the bug it replaces, because the status line now actively states that nothing
    was skipped. Hence `SPLINE(malformed)`, `INSERT(unknown-block)`, `INSERT(cyclic)`,
    `INSERT(too-deep)`, `LWPOLYLINE(bulge)`: "we cannot read this type at all" and "we read this one
    and it was broken" are different claims about a file and must not add up into one number.
    **Every future promotion into `ENTITY_TYPES` walks into this.**
- **NEVER LINE-GREP A DXF.** `grep -E "^SPLINE$"` cannot match a CRLF file: it counted 243 where a
  walk over code/value pairs counts **18,906**, an undercount of 78×, which nearly scoped this work
  as speculative. The format is pairs of LINES, so anything anchored on one is reading half a record.
- **A GROUP CODE MEANS DIFFERENT THINGS ON DIFFERENT ENTITY TYPES, SO A TALLY OR A LOOKUP KEYS ON
  THE ENTITY TYPE AND NEVER ON A CODE'S PRESENCE.** `42` is a bulge on an LWPOLYLINE vertex, a
  control-point tolerance on a SPLINE — **3,308 of them in `cards.dxf` alone**, plus more on VPORT,
  STYLE and VISUALSTYLE records — and the Y scale on an INSERT. A code-keyed bulge tally reports
  3,308 unreadable bulges in a file containing none, and it stays GREEN under mutation right up
  until SPLINE becomes drawable, so the type check has to be right before anything makes it visible.
- **ALL 3,869 REAL BULGES ARE ON OLD-STYLE `POLYLINE` `VERTEX` RECORDS AND NONE ON `LWPOLYLINE`,
  WHICH IS WHY ONE HALF IS DRAWN AND THE OTHER ONLY REPORTED.** A `VERTEX` is its own record, so
  `codes[42]` is unambiguously that vertex's bulge; an LWPOLYLINE holds its vertices as repeated
  10/20 codes with an OPTIONAL 42 each, and `parse_document` groups an entity's values BY CODE — the
  interleaving that says which bulge belongs to which vertex is gone before anything can read it.
  Pairing them needs a positional parser, so the honest answer is `LWPOLYLINE(bulge)` in the tally
  rather than a silent chord. **The one refusal on the drawn half is an arc whose radius dwarfs its
  chord**: r = c / (2·sin(Δθ/2)) blows up as Δθ approaches EITHER 0 or a full turn, and a 1e-20
  bulge — a rounding artefact — produced a **15,313 mm job box out of a 10 mm chord**. A job box is
  a UNION, so one bad vertex takes the whole file's reported size with it.
  - **A BULGE IS NOT ALWAYS OUTWARD, SO "THE BBOX MUST GROW" IS VACUOUS ON REAL DATA.** Both real
    bulged files fillet corners, which arc INWARD: a fillet cuts a corner, the straight edges still
    define the extent, and only 1 of 175 per-shape boxes moved at all — by 0.01 mm, one unit of
    `PRECISION`. On a real file assert the arcs are PRESENT (stub the arc path to nil and diff per
    shape: 1,195 drawn, 0 refused, 37 of them on the closing last→first segment, deepest chord
    deviation 0.043 mm, agreeing with r(1−cos(Δθ/2)) to 4 dp). Pin the growth DIRECTION
    synthetically instead, with a semicircle AND with a negative bulge: dropping the sign draws the
    right radius on the wrong side of the chord, with a bbox of the identical SIZE.
- **`tokenize` DOES NOT SCOPE TO THE `ENTITIES` SECTION, AND THE FIX FOR THAT REMOVED BEHAVIOUR
  RATHER THAN ADDING IT.** Every code/value pair in the file reaches the walk, so a BLOCKS-section
  entity was collected and yielded as a TOP-LEVEL shape at its DEFINITION coordinates while the
  INSERT placing it was dropped. The net effect was never MISSING geometry — it was geometry in the
  WRONG PLACE, drawn once however many times the file places it. On `cards.dxf` that was the entire
  picture: all 8,148 contours live in blocks and its ENTITIES section holds nothing but nine
  INSERTs. **A test asserting only "the inserted copy appears" passes while the ghost still draws —
  assert the SHAPE COUNT.** `parse_document` now tracks sections just far enough to place block
  bodies and no further, which is why the unreadable predicate still has to skip every TABLES and
  OBJECTS record arriving on that same `0`-code stream.
  - **THE INSERT CYCLE GUARD TRACKS THE RECURSION PATH, NOT A GLOBAL VISITED SET.** A global set
    draws a shared block's FIRST placement and silently drops every other one — the same data loss
    this whole arc exists to end, delivered by the guard meant to prevent a hang. Real files share
    blocks and nest them; 168 of `cards.dxf`'s 177 INSERTs are nested. The depth cap is a SEPARATE
    concern (a tree doubling per level out of a file that grows linearly), as is the MINSERT
    row × column ceiling, where `70`/`71` let twelve bytes ask for billions of copies of a block.
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
  - **AND AN ADAPTIVE SUBDIVISION NEEDS A MINIMUM DEPTH AS WELL AS A MAXIMUM.**
    `Dxf.flatten_spline` splits each knot span against `SPLINE_FLATNESS_RATIO`, measured against the
    PATH LENGTH through the midpoint and never against the chord — on a hairpin the chord is near
    zero, so a chord-relative test divides a real deviation by nothing and calls the loop flat. And
    a single cubic piece can be an S whose midpoint sits EXACTLY on its own chord, which reads as
    perfectly flat and collapses the curve to a straight line, so the first split is forced before
    the test is trusted at all.
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
- **A MULTI-PAGE FILE IS MEASURED, DRAWN AND SIZED ONE PAGE AT A TIME (LightBurn 2.2 / MillMage 0.9,
  2026-10-25).** A real 2.2.00 save keeps page 1 as the root's own shapes and every other page as a
  root-level `<Shape Type="Group" SubType="Page">`, all in ONE coordinate space — so the walker that
  read a page as an ordinary Group drew every page stacked on the first. `Lbrn2.pages` is the one
  reading; `walk_shapes` skips a page group rather than recursing into it. Four rules ride on it:
  **one `GeometryIndex` for every page**, because instancing crosses pages (a duplicated page's
  shapes are bare `VertID`s pointing at page 1's lists); **the outline fallback draws the saved page
  (`CurrentPage`)**, because that is what the embedded thumbnail pictures; **`"pages"`/`"page"`/`"pg"`
  are ABSENT on a one-page payload**, like `"u"`, so those bytes did not move and the shared term did
  not bump; and **the union rule holds per page** — a page's shapes union to its own job box, and to
  the panel's size for that page. Switching pages in the view goes through `rest()`, the one lifecycle
  reset of the selection. MillMage's page form is inferred from its binary, not from a save:
  `pages.mage` says so, and is the file to replace when a real one exists.
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
- **THE PAYLOAD BUDGET IS REAL, AND ON THE WORST DXF IT WAS UNREACHABLE — WHICH WAS REPORTED RATHER
  THAN PAID FOR IN ACCURACY NOTHING ELSE IN THE FILE GIVES UP.** `cards.dxf` (8.7 MB, 3,308 splines
  over 19,454 knot spans) went 563 KB → **3,366 KB**, against a design budget of 1,536 KB; the
  render went 0.53 s → 1.54 s (median of 5; 1.50–1.56), inside the 3 s the same design asked for. **The FLOOR
  is 1,497 KB** — every knot span collapsed to the straight chord between its own endpoints, which
  is not a curve at all — so the budget allowed 0.3 extra points per span above
  a drawing that is simply wrong, and coarsening does not rescue it: 0.02 → 2,272 KB and
  0.05 → 1,620 KB are both still over while the median deviation from the true curve goes
  0.011 → 0.042 → 0.111 mm. **The dominant cost is 8,148 shapes' per-shape scaffolding plus one
  point per span, not curve sampling** — which is what a budget set before anyone counted the spans
  could not know. `SPLINE_FLATNESS_RATIO` therefore stays at 0.01, whose 0.011 mm median deviation
  is `Geometry::SIMPLIFY_TOLERANCE` almost exactly and whose ~4.6°/segment matches `arc_samples`'
  ~5.0°, so a spline and an arc in one file agree about how round a curve is. Gzipped that payload
  is 949 KB, and `cards.dxf` is the worst of 129 files (`elianadxf.dxf` 32 KB, `macropad v5.dxf`
  27 KB); **whether that fetch is acceptable was a product decision, not a tuning one, and it was
  ACCEPTED on 2026-09-03 — twice, at 949 KB gzipped and again at 1,293 KB.** So a future reader
  finding the largest file in the library fetching over a megabyte should know it was measured,
  raised and taken, not missed. **The lever that would claw it back is measured and deliberately
  unused:** where a shape carries a descriptor the client draws THAT, so `p` is only a hit target
  and does not need 0.01 mm fidelity — at ~2.9 retained points per cubic, thinning it there would
  roughly pay for the descriptor. It stays available; do not take it without a reason better than
  the number being large, and measure the hit-test cost before you do.
  **THOSE FIGURES ARE THE STATE BEFORE THE SPLINE DESCRIPTOR** — the
  same file is 4,386.6 KB / 1,293 KB gzipped since 2026-09-03 (measured below) — **and the knob is
  unmoved by that on purpose**: a descriptor is exact at ANY flatness, so coarsening the sampling
  now shrinks the points beside a curve the client no longer draws from them.
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
  for the whole render — and before stage 4, S4-3 the page did not poll, so it stayed a spinner
  until someone reloaded — and read as "generating preview is broken". The page now polls an
  in-flight row with nothing to show and reloads once (`thumbs_controller.js`'s reload mode); the
  decision stands on the first half alone.
  - **THE REBUILD HAS ITS OWN STATUS, `rebuilding`, AND IT IS NOT `ready` (F-S08-2, 2026-10-20).**
    `Enqueue` used to stamp the new revision and leave the row `ready`, which said "this asset IS
    the build these coordinates name" the moment the stamp landed — false until the job ran. The
    picture surfaces were right to keep showing it; the Measure poll was wrong to serve it, and
    could not tell the two apart. And the job's start wrote `processing` over the row anyway, so
    the picture this rule protects went dark for the whole render regardless. Now a renderer bump
    on a row with a picture writes `rebuilding` (a row with none goes `pending`), the job's start
    moves `pending → processing` and nothing else, compare-and-set like its other writes, and a
    lost rebuild heals through `STALLED_AFTER` because `rebuilding` is in `IN_FLIGHT`.
- **A CONSUMER THAT CANNOT TOLERATE AN OLDER BUILD'S OUTPUT SAYS SO ITSELF, BY ASKING THE ROW.** The
  classes are named once on `Maker::Preview`: a surface that SHOWS an artifact asks `showable?`
  (`ready`, or `rebuilding` with its old asset — a picture of this content, any build); a surface
  that MEASURES from one asks `current_build?` (`ready` only). `FilesController#geometry` and the
  public poll ask `current_build?`, so they answer `pending` through a rebuild — geometry is DATA,
  an older build's payload is wrong rather than merely old, and its client polls, so pending
  resolves itself. The thumbnail is a picture: a showable row renders no poll cell at all, and
  `/files/thumbnails` answers `ready` for one. Same mechanism, opposite right answers; do not unify
  them. The two doors that hand out EITHER kind — the public payload route and the v1 API — ask
  `servable?`, which is that split by kind (`MEASURED_KINDS`), so the payload route 404s and v1
  says `pending` with no url for geometry mid-rebuild while both keep serving the picture.
  Outside the model, never compare `status` to `ready` or `rebuilding`, nor re-spell the in-flight
  set. `architecture_invariants_test.rb` refuses them in their `==`/`!=`/`when`/`%w[]` spellings; a
  pattern cannot see every spelling (`where(status: "ready")`, `status.in?([...])`, `.eql?` pass it),
  so the rule binds where the guard is blind. A literal that means one thing is not policed — the
  job's start reads `pending`, the geometry polls' terminal arm `failed` and `unsupported`.
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
- **`pending`, `processing` AND `rebuilding` (`Maker::Preview::IN_FLIGHT`) ARE ASSERTIONS THAT A JOB
  EXISTS, AND `Enqueue::STALLED_AFTER` IS THE ONLY THING THAT EVER VERIFIES THEM.** `failed`
  re-enqueues, `ready` is done, `unsupported` is terminal by design — the in-flight statuses were
  the only ones with **no way back**, so a lost job wedged the row FOREVER (a lost rebuild sat at
  `ready`, showing the older build for good). Three rows sat wedged on the live share library,
  the oldest over a week, spinning. **THE HEAL IS `Enqueue.needs_job?`, AND EVERY DOOR THAT HOLDS A
  ROW MUST ASK IT.** This bullet said the scan, `ThumbnailMap`'s backfill, `#current_thumbnail` and
  the addon door reached the heal through `call`; until 2026-10-19 none did. Each door asked "is
  this row current?" first (`current_preview`, status-blind on purpose) and never called `call` for
  a row that was, `MissingBackfill` compared a status-blind triple, and the scan enqueues nothing
  for an unchanged file — so every stall test passed by calling `call` directly while nothing a user
  opens reached it. Now `ThumbnailMap`'s backfill, `#current_thumbnail` (file page and inspector),
  `#geometry`'s poll and `MissingBackfill` ask the predicate of the row they hold, and
  `Public::FilesController#enqueue_geometry` asks it through `call` — every one with `retry_failed:
  false`, the read doors' policy, which `needs_job?` REQUIRES rather than defaults (a door that
  forgets to choose raises). The scan still does not ask, and does not need to. **The window is what
  keeps the escape from becoming a stampede** (the backfill asks per row on every Files render, and
  `#geometry` is polled every 2 s), and **the explicit `updated_at` restamp is what keeps the heal
  from repeating** — healing changes no other attribute and `save!` on an unchanged record is a
  NO-OP that leaves the timestamp alone, so without it every page load adds another duplicate job.
  All three halves are mutation-checked AT THE DOORS (`maker_page_thumbnails_test.rb`,
  `lbrn_geometry_test.rb`, `public_file_view_test.rb`, `missing_backfill_test.rb`), not only through
  `call`: deleting the stall arm of `needs_job?` reddens 10 tests in 7 files, the v1 API's own
  stall test among them.
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
  - **A THUMBNAIL THE MAKER CHOSE IN THE 3D VIEWER IS STALE ON THE FIRST AXIS ONLY (2026-10-20).**
    A `source: "viewer"` row was built by no renderer, so a revision bump has nothing to improve:
    `Enqueue.needs_job?` enqueues nothing for it, `Enqueue.revision_current?` (behind both
    `current_preview` shapes) calls it current at any revision, and `GeneratePreviewJob`'s
    compare-and-set never writes over it. A CONTENT change still repoints it and resets `source` to
    `renderer` — the chosen angle is a picture of geometry that no longer exists.
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
  - **THE THUMBNAILERS' COLOURS ARE THE DESIGN SYSTEM'S, SPELLED FOUR TIMES AND HELD EQUAL
    STATICALLY** (2026-10-21, ink on paper). `Maker::Previews::Palette` (PAPER/INK/MATERIAL) is
    what `Mesh`, `TextThumb` and `SvgRasterizer` paint; the crate's `BG`/`MATERIAL` mirror it, as
    do the CSS `--model-material` and Paper's `--fg`. `palette_test.rb` PARSES all of them rather
    than rendering, because the CI runner image bakes `stl-thumbnailer` at image build — a Ruby test
    asserting STL pixels would be testing that image's binary, not this checkout's crate (the
    crate's own `tests/render.rs` asserts the pixels). Every renderer of ours paints an exactly
    white ground: the browser multiplies it onto the themed card. A palette change is a revision
    bump in every renderer that paints it — `Stl` and `ThreeMf` together, `Mesh`, `TextThumb`.
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
  byte-store failure is a `FetchError` that leaves the row in flight and self-heals — through
  `Enqueue.needs_job?`, which the poll asks of the row it read once that row is past
  `STALLED_AFTER` (the `IN_FLIGHT` bullet above). Until 2026-10-19 the poll enqueued only on a
  MISSING row, so nothing healed it and this sentence was false.
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
  lets `--hover`/`--marked` recolour a contour. Set it inline instead and selection silently stops
  changing colour (only width moves); give `.measure-contour` a stroke and every layer flattens to one
  colour. Both directions are mutation-checked, and both need the COMPUTED style asserted — reading
  the attribute reports what we wrote even when a rule outranks it. (This rule read
  `--hover`/`--selected` until 2026-09-03; `--selected` merged into `--marked` that day and the
  mechanism is untouched.)

- **THE SELECTION IS ONE STATE, ONE COLOUR, AND EVERY CLICK IS A SELECTING CLICK — REPLACING THE
  "Select parts" MODE ON 2026-09-03, AT THE USER'S REQUEST.** Until that date the view carried TWO:
  `this.selected`, the transient measurement highlight (`--selected`, red), and `this.marked`, the
  print set (`--marked`, blue), which could only be added to while a **Select parts** toggle was
  on. The user asked for one — click a contour and it turns **red and stays red** — so `selecting`,
  `selected`, `toggleSelect`, `applySelecting`, `clearSelection`, the `selectToggle` target, the
  ERB button and `.measure-view--selecting` are all **gone rather than unused**, and
  `.measure-contour--marked` inherits `--selected`'s stroke and weight plus its own tint. Four
  rules follow, and each replaced an earlier one that said the opposite:
  - **A SECOND CLICK ON A SELECTED CONTOUR DROPS IT.** `toggleMarks` already toggled; keeping that
    is what makes it possible to drop ONE part from a gathered set, which a select-only click
    cannot do short of clearing everything and picking it again.
  - **A CLICK ON EMPTY SPACE CLEARS THE WHOLE SELECTION** and returns the readout to
    `restingStatus()`. The superseded rule was *"EMPTY SPACE DESELECTS … it deliberately does NOT
    touch the print set: in select mode a stray click on the background must not throw away the
    parts you gathered"* — true while a background click dropped only a highlight, meaningless with
    one state. **The cost was accepted, not missed**: a stray click empties the set and the only
    recovery is picking the parts again.
  - **`.measure-contour--marked` IS DECLARED AFTER `--hover`, AND THAT ORDER IS THE WHOLE "STAYS
    RED" CLAIM.** Both are a single class, (0,1,0), so source order alone decides a contour that is
    both — and a click leaves the pointer ON the contour it just selected, so with `--marked` first
    the shape you just picked sits under the hover green until you move the mouse. **Measured:**
    restoring that order turns `measure_print_test.rb`'s computed-style assertion red with
    `Actual: "rgb(34, 187, 119)"` on the plain post-click read, because a Selenium click really does
    leave `--hover` on the contour; the test then applies `--hover` a second time DIRECTLY, the way
    the cursor test applies `is-panning`, so the claim does not rest on the driver's pointer
    synthesis continuing to behave that way.
  - **THE FIXTURE'S RED AND THE SELECTION'S RED ARE DIFFERENT NUMBERS, AND THE OPEN-CONTOUR TEST
    RESTS ON IT.** `sample.lbrn2`'s layer 0 paints `rgb(255, 0, 0)` and `--marked` `#d40` =
    `rgb(221, 68, 0)`. Repaint the selection pure red and "the class reached the drawn line" stops
    being distinguishable from "the line was already that colour" — a test that cannot fail.

- **`reset()` CLEARS THE SELECTION UNCONDITIONALLY, AND `clearMarks()` WRITES THE RESTING LINE.**
  The superseded rule guarded the clear with `if (this.marked.size)` so a plain view reset would
  not stomp a MEASUREMENT the user had just asked for — there is no measurement apart from a
  selection now, and the state that guard walks past is the stale one: unpick the last part and the
  readout still reads `60 × 40 mm · nothing selected` over an empty set. `clearMarks` writes
  `restingStatus()` rather than `selectionStatus()`'s empty arm because both its doors — a
  background click and Reset — mean "start again", and one state must not have two sentences
  depending on how it was reached. The empty arm is still reachable where it is honest: unpicking
  the LAST part leaves its size on screen beside "nothing selected".

- **THE CONTROLLER OWNS THE STAGE, AND `--ready` IS ONLY ITS PROJECTION (F-S09-1, 2026-10-19).**
  `draw()` alone adds `measure-view--ready`, and `rest()` alone removes it. `rest()` runs from
  `connect()` and from ✕ Image, and it drops the shapes, the SVG and the selection with the class.
  So the class always means "this controller drew what is on the stage". Before, it could mean
  something else. A Turbo Back restored a drawn, marked stage over a fresh controller that held no
  shapes, which left Print promising a part and Reset throwing. Four comments had argued
  correctness from "the button is display:none". Two rules keep this true, and
  `measure_print_test.rb` drives both:
  - **One load generation.** A load paints only while its number is the latest, and its error
    reaches the readout on the same condition.
  - **One shared in-flight fetch.** The launch button stays clickable until the stage is drawn, so
    a second click joins the first fetch and the view is drawn once.

  `rest()` is the ONE LIFECYCLE reset of the selection, and `draw()` does not repeat it. A drawing
  can start only from a rest, so a second copy of that reset in `draw()` would be a guard no
  gesture can reach. It is NOT the only place the set is emptied. `clearMarks()` empties it too,
  on Reset and on a click on empty space. The two must stay separate: `clearMarks()` drops the
  marks and keeps the drawing, while `rest()` takes the drawing down with them. Routing a Reset
  through `rest()` would wipe the stage.

- **THE DRAWING OPENS ON ARRIVAL, AND THE POSTER IS WHAT SHOWS WHEN IT DOES NOT (2026-10-25, at the
  user's request).** Until then nothing was fetched before Measure was clicked, so a LightBurn page
  rested on LightBurn's thumbnail of the whole bed with the design small inside it, and a DXF on a
  512 px server render; neither filled the stage, and the zoom overlay could only enlarge them.
  `connect()` now rests and then calls `open({ arriving: true })`, the same load the button runs, so
  a click during the arrival's download joins it (one fetch, one draw, by the two rules above).
  The price is the payload on every visit to one of these pages, up to 1.3 MB gzipped on the
  densest real file. Four things not to undo, each pinned in `lbrn_measure_test.rb` or
  `measure_print_test.rb` and mutation-checked:
  - **The poster stays while the payload loads, on any failure, and on a page of nothing but
    bitmaps.** A photo engraving draws as a dashed box where its poster shows the photo, so the
    arrival leaves it there (`onlyBitmaps`, on the page `draw` would show). Measure still opens it.
  - **No arrival from a Turbo preview.** A Turbo visit to a cached page connects a controller in
    the cached copy before the real page arrives; opening there polls and downloads for an
    element about to be discarded (2 geometry polls for 1, measured).
  - **`rest()` on connect still matters, though a drawing that lands hides its absence.** The
    arrival's draw replaces a Turbo-restored stage whether or not it was rested, so the Back test
    holds the geometry poll to see the restored page in between — the state a page whose drawing
    is still generating, failed, or is all bitmaps stays in.
  - **The paper is read on the first draw, which now follows the visit at once.** A test that
    sets or clears `measure.paper` does it before `visit`, not after; `populatePaper` never
    re-reads it on a later draw.

  SVG text is the visible cost: `SvgGeometry` draws no `<text>` and no `<use>`, so an SVG's labels
  are absent from the drawing that now opens by default (Boxes.py's part names, for one). The file
  itself is one click away, as ✕ Image.

- **`pick` COMPOSES `contourLabel` WITH `selectionStatus()`, WHICH IS WHAT SAVED THE ⌥ HINT.**
  `"part of a 2-contour object (⌥ for 30 × 10 mm)"` is the ONLY place the app says alt-click
  exists, and until 2026-09-03 it was shown only OUTSIDE select mode — i.e. exactly where marking
  was impossible — so collapsing the modes onto the old selecting arm's bare `sizeLabel` would have
  deleted the affordance with nothing going red. Its sibling `objectLabel` did go, and deliberately:
  beside `selectionStatus()`'s own "2 parts" its "whole object, 2 contours" is the same count twice
  in one line, so the widened arm passes the union dims and lets the summary do the counting.
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
  worse. `bezier-circle.lbrn2`'s Path circle is the pin, and it is the assertion no `<Ellipse>`
  fixture can make.
  - **THE PIN READ "`d` PRESENT, `g` ABSENT" UNTIL 2026-09-03, AND IT NOW READS "`d` PRESENT, `g`
    IS A `"p"`, NEVER AN `"e"`."** The rule did not move; the set of exact forms did. That Path
    carries the file's OWN cubics now, which is a faithful rendering of what the file declared —
    the opposite of an inference from the points. What must never appear is the `"e"`: nothing may
    promote a contour to an ELLIPSE because it happened to measure round. Stated as absence, the
    invariant was the right rule written in a world where the only descriptor a Path could have
    acquired was an inferred one, and it would have refused the correct implementation.
- **THE AXIS-ALIGNED GATE IS LOAD-BEARING ON BOTH LEGS, AND HAD NO TEST AT ALL UNTIL 2026-09-02.**
  Under a rotation an SVG `<ellipse>` is not an SVG `<ellipse>`, so emitting one exports geometry
  the file does not contain. Every `<XForm>` in the fixture corpus was a translate or a scale, so
  `Lbrn2.axis_aligned?` was a GREEN MUTATION for as long as it existed — it governed only thumbnail
  crispness and nothing noticed; carrying the descriptor into the payload made it govern exported
  geometry. `rotated-ellipse.lbrn2` carries an upright ellipse AND a 30° one, because an
  implementation that always emits and one that never emits each pass half of a one-shape fixture,
  and its radii differ (20 × 10) because a rotated CIRCLE is still an upright circle and could not
  tell a working gate from a missing one. `SvgGeometry.ellipse_curve_for` applies the same test for
  the same reason. **It binds on `"e"` ALONE and must not be widened to `"p"`** — see the
  cubics-only bullet below for why a cubic path needs no such refusal.
  - **THE SAME REFUSAL ONE TRANSFORM SOURCE ALONG: A DXF `e` OR `a` DESCRIPTOR IS DROPPED UNDER A
    NON-UNIFORM SCALE** (it read "A DXF CURVE DESCRIPTOR" until 2026-09-03, when a third arm
    arrived that must NOT drop — next bullet). A BLOCK's contents are placed by their INSERT's
    affine, and only a SIMILARITY keeps a circle a circle — under a non-uniform scale it is an
    ellipse whose axes are turned by the rotation, and the wire's `e` form carries rx and ry with
    NO rotation term. There is no honest descriptor to emit, so `Dxf.transform_curve` emits none
    for those two arms: **dropping is always safe** — the flattened points still carry the true
    shape and `b`, `d` and the job box are computed from them — while the thumbnail draws the
    descriptor INSTEAD of the points, so a stale one is a WRONG PICTURE rather than a coarse one.
    A MIRROR is a similarity and survives, but it REVERSES an arc's direction, so the placed arc's
    endpoints swap; leaving `a0` alone draws the complementary arc — same endpoints, wrong side —
    and `arc_svg` writes it as-is.
  - **AND `transform_curve`'s `:path` ARM NEVER DROPS, WHERE ITS TWO NEIGHBOURS MUST — THE ARM MOST
    LIKELY TO BE "FIXED" INTO A REFUSAL BY ANALOGY WITH THEM.** The situations are not the same: an
    `e` or an `a` names a CIRCLE, which only a similarity preserves, while a cubic Bézier is a
    convex combination of its own four control points, so ANY affine — non-uniform scale, shear,
    mirror, all at once — maps the curve by mapping the points and the image is still EXACTLY a
    cubic. Nothing is lost and nothing is approximated — the same property that binds the gate this
    bullet hangs under to `"e"` alone. Load-bearing rather than theoretical: all 3,308 of
    `cards.dxf`'s splines live in BLOCK definitions and reach the drawing through an INSERT, so
    **every one of them goes through this arm** and a refusal copied from the neighbours would
    coarsen every placed spline in the corpus for no defect at all. Mutation-checked — making it
    drop under a non-similarity turns the placed-spline test RED.
- **A 360° DXF `ARC` IS ENCODED AS AN ELLIPSE, NEVER AS AN ARC.** `Dxf.arc_points` turns
  `a0 == a1` into a 360° sweep — its own comment, *"the whole circle, not a zero-length arc"* —
  whose start and end points are IDENTICAL, and SVG's rule for an arc whose endpoints coincide is
  to omit the segment ENTIRELY. An `A` command there exports a path that draws nothing: no error,
  nothing logged, a shape simply missing from a file somebody cuts. **`Dxf.arc_svg` CARRIED THE
  IDENTICAL DEFECT FOR THE THUMBNAIL UNTIL 2026-09-03** (tinkerex#215) and now takes the same
  branch. **Both thresholds are `>=`, not `==`, and must stay identical**: `transform_curve` carries
  `sweep` across a block placement unchanged rather than recomputing it, so a full-turn arc inside
  an INSERT would otherwise be a circle in the picture and a different shape in the measurement. It
  waited only because it needed a `THUMBNAIL_REVISION` bump, which four stages of other work then
  forced anyway — and it needed a FIXTURE, since no real file in the scratch corpus holds an ARC at
  all and a thumbnail is a PNG nobody asserts the contents of. **The guard that generalises asks
  that NO `A` command in the emitted SVG ends where it began**, not merely that a `<circle>` is
  present: a fix that emits the circle and leaves the dead path behind satisfies an
  `assert_includes` while still writing a segment no renderer draws.
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
- **THE `"p"` FORM IS CUBICS AND LINES ONLY — `M`/`L`/`C`/`Z` AND NOTHING ELSE — AND THAT ALPHABET
  IS THE WHOLE DESIGN.** Every input reduces to it: a LightBurn `B` segment IS the cubic
  `(a, a.c0, b.c1, b)`; SVG's `C` already is one; `S` and `T` reflect the previous control point
  into one; `Q` converts EXACTLY by degree elevation (`c1 = p0 + ⅔(c − p0)`, `c2 = p + ⅔(c − p)`);
  and an `A` becomes cubics. **One segment kind is what makes an affine placement a transform of
  CONTROL POINTS and nothing else** — a Bézier is a convex combination of its own four points, so
  an affine map commutes with it. That is also why **the axis-aligned gate binds on `"e"` and NOT
  on `"p"`**: the `"e"` form carries rx and ry with no rotation term, so under a rotation or a skew
  it would export an upright ellipse the file does not contain, while a cubic path under the same
  matrix is still exactly itself. A rotated or skewed `<path>` therefore KEEPS its descriptor.
  Stage 2 mutation-checked the "fix" that extends the gate to `"p"` — a needless refusal with no
  defect behind it — and both arms are pinned in one test, since gating neither and gating both
  each pass half a pair.
  - **AND THE SAME PROPERTY IS WHY THIS FORM MAY ROUND AT `PRECISION` WHERE THE ARC ABOVE COULD
    NOT.** Rounding a control point by δ moves the drawn curve by at most δ — 0.005 mm, at any
    radius — because there is no reconstruction step to amplify it.
- **AN `A`'s CUBIC COUNT IS BOUNDED BY ERROR, NEVER BY A COUNT, AND THE PLAN'S OWN "≤4 cubics,
  bounded error" WAS SELF-CONTRADICTORY.** The tangent-matched fit's radial error is
  `r·(2/27)·sin⁶(θ/4)/cos²(θ/4)` — 2.7e-4·r at θ = π/2, i.e. **0.054 mm at r = 200 mm**, an order
  of magnitude worse than the `p` points beside it, which are flattened and thinned at 0.01 mm. **A
  descriptor LESS faithful than the polyline it replaces is the `tinkerex#213` defect exactly**, so
  `SvgPath.arc_cubic_steps` treats 4 as a FLOOR and grows with the radius (about four under an
  18 mm radius, six at 200 mm), with `MAX_ARC_CUBICS` = 32 as the stop against a pathological one.
  **On the real corpus the bound never fires** — all 1,699 arcs land at ≤4 and 1,560 at one — so
  "≤4" was empirically right and structurally wrong, which is the kind of number that survives
  every test until the file that needs it arrives.
- **A CONTOUR EMITS A DESCRIPTOR ONLY WHEN IT ACTUALLY CURVES.** A straight-only contour is already
  described EXACTLY by `p` (thinning only drops points within `SIMPLIFY_TOLERANCE` of the line the
  browser draws), so a path there restates the same geometry in a second encoding and is paid for
  on every contour of every file. **A MIXED contour keeps ALL of its `L` segments**, because a path
  is continuous and the straight segments are how the cubics are reached — dropping them is not a
  saving, it is a different shape. `SvgPath.curved` and `Lbrn2.curved_segments` are the same
  decision on the two producer legs, deliberately not shared: each is one `any?` over a list only
  that traversal holds. A THIRD producer is the point at which they fold into `Geometry.path_curve`
  instead of becoming a third copy — **and the third producer arrived on 2026-09-03 and made no
  copy at all**, because the question does not arise for it: a DXF descriptor is decided per ENTITY
  TYPE, and a SPLINE curves BY DECLARATION rather than by inspection of a segment list. The fold is
  still owed to a producer that has to ASK; DXF is the case that shows not every leg does.
- **A ROUNDED `<rect>` DELIBERATELY GETS NO DESCRIPTOR, THOUGH IT WOULD COME FOR FREE.**
  `SvgGeometry.rect_contours` synthesises a `d` of four `A` commands for an `rx` and hands it to
  the same parser, so the segments arrive already built — and are dropped, in the ONE place
  `contours_for` strips the third element. **That `d` is OURS, not the author's**, and a descriptor
  is a claim about what the FILE declared; extending it to a shape we constructed is a separate
  change with its own payload measurement. Mutation-checked as the one such place, and written as
  a `.map` at the call site rather than a flag on `parse`, because the decision belongs to the
  caller.
- **`SvgPath.arc_params` IS SHARED BY THE SAMPLER AND THE CUBIC EMITTER, SO THE MEASURED POINTS AND
  THE DRAWN CURVE CANNOT DISAGREE ABOUT THE SAME ARC.** A second copy of SVG F.6.5/F.6.6 is §14b's
  `LbrnMetadata` bug in the densest part of the format: `b`, `d` and the job box come from the
  points while the client DRAWS the cubics, so a divergence surfaces as a picture contradicting the
  readout beside it. The extraction was proved **bit-identical to the old sampler over 3,600 cases**
  (radii 1–1000, five rotations, both flags, three tolerances, zero differing points), which is what
  licensed it: **no measured number moved.**
- **`Dxf.de_boor` IS THE REPEATED-PARAMETER CASE OF `Dxf.blossom`, NOT A SECOND COPY OF THE
  RECURRENCE** — the bullet above, one leg over, on the recurrence where a second copy would cost
  most. De Boor's algorithm ALREADY WAS the polar form with every level handed the same `u`, so the
  extraction is a generalisation and `de_boor` calls into it: the flattened points and the extracted
  cubics come out of ONE evaluation and cannot describe different curves on the same spline. A
  second copy here would be §14b's `LbrnMetadata` bug where it is hardest to notice — both copies
  draw a plausible spline. **The evaluation path is bit-identical, same operations in the same
  order**, which is precisely what licenses the two spline-free fixtures' digests NOT MOVING:
  `sample.dxf` and `plate.dxf` come out byte-for-byte unchanged on both artifacts, which is the
  evidence rather than the claim that the generalisation moved nothing under it.
- **THE `d` STRING IS BUILT FROM PARSED NUMBERS, NEVER FROM THE AUTHOR'S MARKUP, AND THAT IS WHAT
  MAKES IT COMPATIBLE WITH §15.** `Geometry.path_curve` takes a SEGMENT LIST of Floats the format
  module has already parsed; `round` is a method a String does not answer to and `#{}` never
  appears, so there is no door by which a filename or a `<VertList>`'s own bytes reach the output.
  On the client `setAttribute("d", …)` is a GEOMETRY attribute, not markup — it can open neither an
  element nor a URL — so this is not the inlining §15 forbids, which is about USER MARKUP reaching
  a document. **Asserted mechanically rather than left to this paragraph**: every `d` emitted over
  the real fixtures must match the command-and-number grammar and nothing else.
- **THE PAYLOAD ROUGHLY DOUBLES, AND THAT WAS MEASURED AND ACCEPTED ON 2026-09-03 — NOT MISSED.**
  LightBurn's three heaviest went **+66% / +69% / +98%** (574 → 952, 330 → 556, 745 → 1476 KB;
  gzipped 162 → 285, 86 → 151, 210 → 440 KB) against an estimate of +35/+54/+12%. The whole SVG
  corpus went **+41.9% raw and +48.0% gzipped**, median **+58.2%** among the 134 of 168 files that
  gain a descriptor, worst +137.9%. Render time moved 3–25%, which is noise on this artifact.
  Fidelity is the other half of the trade and it holds: over 21,048 resolved descriptors the worst
  deviation from the shape's own points is **0.0138 mm**, against ~0.017 mm that the thinning plus
  `PRECISION` rounding account for on their own. **What makes it affordable** is that after RDP at
  0.01 mm the `p` points retain only ~2.9 per cubic, so an exact cubic costs about what its own
  thinned polyline already cost.
  - **THE OFFSET LEVER IS AVAILABLE AND WAS DELIBERATELY NOT TAKEN.** Where a descriptor exists the
    client DRAWS it, so `p` is only a hit target there — and a hit target does not need 0.01 mm
    fidelity, so thinning `p` harder on exactly those contours could more than pay the growth back.
    It is a second, independent change to interaction fidelity; taking it in the same arc would
    have confounded the measurement above. A reader finding a doubled payload here should reach for
    this rather than for the descriptor.
- **THE THIRD PRODUCER LEG'S GROWTH WAS MEASURED AND ACCEPTED THE SAME WAY, AND THE PROJECTION CAME
  IN LOW.** `cards.dxf` — the corpus's worst file, 3,308 splines over 19,454 knot spans — went
  **3,366 → 4,386.6 KB (+30.3%)**, gzipped **949 → 1,293 KB**; `elianadxf.dxf` **+80.6%**;
  `macropad v5.dxf` **+38.3%**. Shapes and job boxes are unchanged on all five scratch files, and
  the two carrying no spline are byte-identical on the payload AND the SVG — which is what says the
  growth is the descriptor and nothing else. The plan's own estimate, built from span counts through
  the parser, said **+27%**. Three points is small and the cause was not chased, but **the direction
  is worth recording**: even an estimate counted on the right traversal came in UNDER, so **treat a
  payload projection as a floor rather than a forecast** — as the reason to measure and not as a
  substitute for it.
  - **AND THE THUMBNAIL GOT SMALLER, WHICH IS THE SIGN A PAYLOAD-SHAPED ARGUMENT PREDICTS WRONG.**
    Adding the `:path` arm to `Dxf.element_svg` cut `cards.dxf`'s thumbnail SVG **3,106 →
    1,609.5 KB (−48%)** and `macropad v5.dxf`'s **64.5 → 13.1 KB (−80%)**. The reason generalises
    past DXF: the payload pays for a descriptor riding BESIDE the thinned points it exists to
    improve on, while **the thumbnail leg has no thinning stage and no points to keep**, so six
    numbers REPLACE every sample of a span instead of joining it. **A descriptor is a saving on that
    artifact even where it is a cost on this one** — so measure both, per leg, rather than carrying
    the payload's arithmetic across.
- **COUNTING A FILE'S TEXT IS NOT COUNTING WHAT A TRAVERSAL YIELDS — THREE TIMES ON ONE BRANCH.**
  `grep -E "^SPLINE$"` missed every CRLF file and put a plan out by **78×** (`tinkerex#216`).
  Counting `B<a> <b>` ops missed that LightBurn shares geometry between instances by
  `VertID`/`PrimID`, so `bookmark.lbrn2`'s 2,169 text ops emit **14,825** cubics — **6.8×**, and the
  whole reason the payload estimate above was wrong. And grepping `d` attributes for curve command
  letters gave **163,637 / 43,374 / 35,026 / 48,878 / 34,927** where LEXING the same corpus gives
  **116,244 / 8,011 / 1,459 / 2 / 859** — `C`/`S`/`Q`/`T`/`A`, in that order in both rows, which is
  the one thing to keep straight about them: the plan's own table reads `859 A, 2 T` and a reader
  pairing the two sequences by eye will otherwise swap the last pair. **Count through the parser**,
  on the same traversal the renderer uses; a text-level count is a different question wearing the
  same units.
- **A DXF SPLINE'S BÉZIER EXTRACTION IS EXACT FOR DEGREE 3 WITH UNIT WEIGHTS, AND REFUSED
  OTHERWISE — AND THIS BULLET SAID "DELIBERATELY OUT OF SCOPE" UNTIL 2026-09-03.** It was out on
  cost, and the cost has since been measured and accepted (two bullets up); the geometry half of it
  stands unchanged. **A degree-3 B-spline IS a chain of cubic Béziers**, so `Dxf.spline_curve` is an
  exact REWRITING of the file rather than a fit: each non-empty knot span yields exactly one cubic,
  read off as four blossom values at that span's own endpoints, which is Böhm's insertion done
  through the recurrence `de_boor` was already running. Nothing is sampled and no tolerance is
  involved. **A RATIONAL spline is refused** — a rational cubic is a RATIO of polynomials and an SVG
  `C` is a polynomial, so no cubic draws one, and emitting the projected control points anyway would
  put a curve that is not the file's into a picture the thumbnail draws INSTEAD of the points.
  **The refusal is TALLIED, as `SPLINE(rational)`**: `SPLINE` is in `ENTITY_TYPES` now, so the
  type-based tally no longer fires for it and a silent drop would leave the status line actively
  stating that nothing was skipped. Zero rational splines occur in the 129-file corpus — **the guard
  is about tomorrow's file**, which is why the fixture has to MAKE one rather than find one.
  - **THE RATIONAL TEST READS THE HOMOGENEOUS CONTROL POINTS, NOT THE FILE'S CODE 41 OR ITS RATIONAL
    FLAG, AND THE DISTINCTION IS LOAD-BEARING.** `Dxf.homogeneous` already IGNORES a weight run that
    does not match the control points one for one, and a non-positive weight, substituting 1.0 — so
    such a file DRAWS the unweighted curve, which a cubic spells exactly. Reading the raw weights
    would refuse a descriptor for a curve with no rational component left in it; reading flag 70's
    bit would refuse on a CLAIM the file makes about itself. `hcp` is what was actually evaluated,
    so the refusal and the drawing cannot disagree.
  - **A DEGREE OTHER THAN 3 GETS NO DESCRIPTOR AND IS DELIBERATELY NOT TALLIED** — only what the
    wire form STRUCTURALLY cannot express is a shortfall worth reporting, and neither omission is
    one. A degree-1 spline IS its own control polygon, which `p` already carries EXACTLY, so the
    curved-contour rule above refuses it on its own terms and nothing is lost. A degree-2 spline
    elevates to a cubic EXACTLY (`Geometry.path_curve`'s own `Q` conversion), so it is a feature not
    yet written rather than a refusal — and it has ZERO corpus occurrences, so shipping it would be
    untestable against anything but a synthetic file. Tallying either would report a shortfall that
    did not happen, which is the same lie as hiding one that did.
- **A REVISION IS BUMPED ONCE PER SHIPPED CHANGE, NOT ONCE PER EDIT.** `SHARED_REVISION` moved
  0 → 1 when `g` was introduced; the arc's wire form was then REDEFINED inside that same unmerged
  revision and deliberately NOT bumped again. A revision exists to invalidate STORED artifacts, and
  no deployment had ever served revision-1 arc bytes — there was nothing to invalidate, and a
  second bump would re-measure every payload in the library for a form no row holds. **The single
  bump is deliberate, not forgotten**, and `SHARED_REVISION`'s own log says so beside the number,
  which is where a later reader looks before deciding it was missed.
- **BOTH DXF REVISIONS MOVE TOGETHER WHENEVER `each_geometry` CHANGES**, because that one traversal
  feeds the thumbnail AND the payload: `Dxf::THUMBNAIL_REVISION` and `DxfGeometry::FORMAT_REVISION`
  both, and **never `Geometry::SHARED_REVISION`**, which would re-render every `.lbrn2`, `.mage` and
  `.svg` payload for a DXF-only change. **AND THE TWO FIXTURE DIGESTS DID NOT MOVE WITH THEM, WHICH
  IS THE REVERSE OF THE TIME BEFORE AND IS NOT A MISTAKE** — `sample.dxf` and `plate.dxf` hold no
  spline, no BLOCKS section and no non-zero bulge, so there was nothing in either for the new code
  to reach, while the output moved for 29, 26 and 24 of the 129-file live corpus. **A revision
  tracks what the renderer does to REAL files, not what two narrow fixtures happen to hold.** For
  four stages that byte-for-byte guard reported "nothing moved" about changes that redrew a fifth of
  every DXF in the library — right about its fixtures and blind to the change, which is a guard that
  cannot fail for the thing it exists to catch. `entities.dxf` is what closes it: one two-span
  degree-3 SPLINE, a closed POLYLINE with equal and OPPOSITE bulges, a BLOCK placed by an INSERT at
  a non-zero offset, and a full-turn ARC, with a `999`-comment header saying what each part pins. A
  fifth entity type gets a fifth part of that fixture, not a fourth fixture.
  - **AND ON 2026-09-03 IT FIRED — THE FIRST TIME THAT GUARD HAS CAUGHT ANYTHING SINCE IT WAS
    ADDED.** Through `tinkerex#216`, `#219` and `#217` it reported "nothing moved" on every run:
    correct about `sample.dxf` and `plate.dxf`, which hold no spline, no BLOCKS section and no
    bulge, and blind to changes that moved the output for dozens of real files. The spline
    descriptor moved **both** of `entities.dxf`'s digests while those two stayed still — the second
    half doing as much work as the first, since a move there would have meant the change reached
    geometry it has no business touching. **That is what a fixture earning its place looks like**,
    and it is the argument for adding one the moment a guard's subject is not represented in what it
    scans: the alternative is not a weaker guard, it is a guard that cannot fail.
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
- **THE HIT TWIN IS ALWAYS A POLYLINE FROM `shape.p`, EVEN UNDER AN ARC OR A `"p"` PATH.** It is an
  invisible 8 px target, so approximating the curve costs nothing visible and keeps the twin one
  element. Build it from the points, never by reusing the visible node's `points` string — the
  visible node no longer necessarily has one.
  - **A TWIN IS FOR AN OPEN CONTOUR ONLY, AND A CLOSED `"p"` PATH IS ITS OWN TARGET BECAUSE OF ITS
    `Z`.** `.measure-contour { fill: transparent }` fills a `<path>`'s CLOSED subpath exactly as it
    filled the `<polygon>` that element replaced — so the closing command is not cosmetic, and a
    descriptor that omitted it would draw an identical picture while silently reducing every closed
    curve to a stroke-only click target. `measure_formats_test.rb` clicks `curves.svg` in its
    interior for that reason.
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
  - **AND THE `<path>` CASE ARRIVED ONE SHAPE KIND EARLIER THAN THE ARC THIS WAS WRITTEN FOR, AS
    THE COMMON CASE RATHER THAN THE EXOTIC ONE.** Every bezier Path in the fixture corpus draws as
    a `<path>` since `"p"` (2026-09-03), so `lbrn_measure_test.rb` and `measure_print_test.rb` both
    gained a `path_min_x` arm reading the minimum of the CONTROL POLYGON — a bound, which is all a
    helper telling contours 30 mm apart needs, and exact wherever the leftmost point is a node.
    **It returns nil for any command outside `M`/`L`/`C`/`Z`**, so the `A` rule above survives
    intact rather than being papered over: an arc's flags sit among its numbers and would be
    averaged into a coordinate. Three print-sheet assertions counted `g polygon` and were reading a
    printed curve as a MISSING PART — "Print all printed half the file" is the thing one of them
    exists to refuse, and it would have been reporting it.
- **THE EXPORT IS NORMALIZED TO THE ORIGIN AND ITS CANVAS SIZE IS THE PART SIZE.** `width="{w}mm"`
  plus a viewBox spanning the same `w` is the ENTIRE scale mechanism — the same pair the print
  sheet uses, no transform and no dpi constant — so a px width draws an identical-looking file that
  is silently the wrong size in an application that will cut it. ONE translate for the whole
  selection, so several selected parts keep their relative positions; and normalizing at all is
  what stops a part pulled out of a 1200 mm sheet importing as a speck in an empty canvas. The root
  is created IN the SVG namespace so the serialiser writes `xmlns` itself; never ALSO
  `setAttribute("xmlns", …)`. The rule stands on the XML serialization algorithm, which would
  declare it twice — **measured 2026-09-07 (S4-3): headless Chrome does NOT**, Blink skips its own
  declaration when the attribute is present, so a doubled `xmlns` cannot be observed in the one
  browser this repo drives, and `print_sheet.js#sheetDocuments` strips the attribute for the
  algorithm's sake rather than for an observed doubling. An earlier version of this sentence
  claimed the doubling as fact; it was reasoning, not a measurement.
- **THE EXPORT USES THE LAYER COLOUR WHERE THE PRINT SHEET USES BLACK, AND THAT DIVERGENCE IS
  ARGUED.** The sheet is black because a mono printer turns a layer palette into indistinguishable
  greys, on the one artifact whose job is to be measured and cut against. A file has no such
  constraint, and LightBurn maps stroke colour back to layers on import.
- **`lib/export_svg.js` BUILDS THE DOCUMENT AND THE CONTROLLER BUILDS THE BLOB.** The same split
  `print_sheet.js` draws between `renderSheet`/`sheetDocuments` (pure) and `buildPrintFrame` (not)
  — three pure builders since S4-3, and the controller owns the Blob, the NAME and the DOOR for all
  of them: a download, or **Save to library** through the same two-door upload flow every other
  upload takes (`uploadPortFile` on share/s3, `uploadChunkFile` on chunk_remote), into the source
  file's own folder as `<base>-parts.svg` / `<base>-print.svg`, never a third door — and it is what
  lets the export be asserted as a STRING: headless Chrome here has no configured download
  directory, so the system test shims `URL.createObjectURL` and `HTMLAnchorElement.prototype.click`
  instead of looking for a file on disk. An empty selection REFUSES rather than writing a 0 × 0 mm
  document — that opens in every viewer showing nothing, which reads as "the export is broken"
  rather than "you selected nothing", and the caller has a readout to put the message in.
- **THE SVG BUTTON'S VISIBLE TEXT IS CONSTANT AND ITS ACCESSIBLE NAME IS NOT.** The actions bar
  carries seven controls since S4-3 (paper, Print, Save sheet, Download SVG, Save SVG, Reset,
  ✕ Image), eight with the mm/in toggle, so a second count-bearing label beside "Print 3 parts" is noise — but a
  button must not lie about what it does, so its `aria-label` AND its `title` are written from the
  same `targetNoun()` the Print label uses, by the same refresh — four buttons since S4-3, the
  Download/Save SVG twins and the Print/Save sheet pair — and the ERB's at-rest literals are that
  same string with the noun `all`, so all of them can only drift together. **The text reads
  "Download SVG" as of 2026-09-03, at the user's request** (it was `SVG`, a one-word button beside a
  paper picker); constant is a claim about the count, not about the wording, so
  `measure_export_test.rb` asserts the text on BOTH sides of a selecting click.
  **`targetShapes()` and `targetNoun()`
  are the ONE definition of the precedence, which is TWO arms since 2026-09-03** — the marked set,
  else the whole file. The middle arm was *"else the selected contour, so measuring a part is
  enough to target it and Select parts is not a toll gate on printing one part"*; selecting IS the
  measuring click now, so the first arm does that job and a second state for it would be two
  answers to one question. "Print selected" went with it — a selected contour is a one-part set,
  and the button reads "Print 1 part". It was written out TWICE, in `print()` and in
  `refreshPrintBar()`, under a comment saying the two "must not drift", which is prose where a
  mechanism belongs; the exporter would have been a third copy.
- **THE mm/in TOGGLE CHANGES WORDS, NEVER GEOMETRY.** The payload is millimetres and stays so;
  `measure_controller.js#length` is the ONE place a payload number becomes text, and it converts
  there and nowhere earlier. The **SVG export and the print sheet's scale do not read the unit** —
  `width="{w}mm"` over a viewBox is the whole scale mechanism of both, so routing the toggle into
  either changes the physical size of a file somebody cuts. The sheet's size LABELS do follow it,
  through the injected `sizeLabel` (the paper and the readout must not disagree — the PRINTED SIZE LABEL bullet above);
  the calibration ruler's "100 mm" does not, because it certifies the scale rather than reporting
  a part. A measurement line is kept as the CLOSURE that wrote it (`setReadout`), so a flip rewrites
  the line on screen; every plain `setStatus` drops it, so a flip can never resurrect a measurement
  over a save notice or a refusal. The remembered choice is checked with `Object.hasOwn`, not
  `UNITS[saved]`: a stored `constructor` answers truthy off the prototype and prints `NaN`. Guard:
  `test/system/measure_units_test.rb`, every test of which first asserts `mm` is pressed. A leaked
  `in` would turn other files' `mm` assertions red, and what prevents it is Capybara's own reset,
  which clears localStorage between tests (measured 2026-10-08, capybara 3.40).
