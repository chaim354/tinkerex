# LightBurn per-shape dimensions — design

**Date:** 2026-08-06
**Branch:** `claude/lightburn-shape-dimensions-f4c487`
**Status:** approved, ready for an implementation plan

---

## 1. The problem

A `.lbrn2` file page shows LightBurn's own embedded thumbnail and a Laser Settings panel. The
panel reports **one** size — `Lbrn2.job_size`, the bounding box of the whole document. There is
no way to ask "how wide is that slot?" without opening LightBurn.

**Nothing computes a per-shape size today.** `Lbrn2.each_geometry` yields every drawable leaf
with its points already transformed into document space, and `Lbrn2.job_size` folds *all* of
those points into a single `BBox`. Per-shape extents are computed transiently and discarded.

**The obstacle is the preview surface, not the parser.** `Lbrn2.render` prefers LightBurn's
embedded `<Thumbnail>` PNG (57 of 58 real exports carry one) and the fallback path rasterizes our
SVG to PNG via resvg — `Maker::Previews::Svg` deliberately refuses to inline user SVG as an XSS
rule. The page then shows a plain `<img>`. There is nothing on it to hit-test, and the PNG's
pixels have no known mapping back to mm.

## 2. What we're building

Behind a **Measure** button on the `.lbrn/.lbrn2` file page, an interactive outline view where
clicking a contour reports its dimensions in mm.

Decided scope:

| Decision | Choice |
|---|---|
| Purpose | Spot-measure a feature while browsing |
| Click granularity | **Contour** by default; **alt-click** widens to the whole `<Shape>` object |
| Entry point | **Behind a Measure button**; LightBurn's colour PNG stays the resting state |
| Readout | **Width × height in mm**, plus **⌀ diameter when the contour is circular** |
| Zoom / pan | **In scope** — scroll to zoom, drag to pan |

Explicitly **out of scope**: layer/speed/power in the readout, bed position, cut length/perimeter,
per-layer colouring of the outline view, and any overlay onto LightBurn's own render.

## 3. Measurements that drove the design

Run over the 58 real exports at `~/Documents/3d printing copy/**/*.lbrn2` using the real parser.
Payload sizes are **gzipped**.

| payload | median | p90 | worst |
|---|---|---|---|
| bounding boxes only | 0.6 KB | 5.6 KB | 15.2 KB |
| full outlines | 12.4 KB | 227 KB | 734 KB |
| outlines decimated 3:1 | 5.2 KB | 86.9 KB | 280.5 KB |

Server parse + walk: **median 7 ms, p90 71 ms, worst 436 ms** (`reference card.lbrn2`,
1,245 contours). Corpus total: 8,516 contours across 58 files; worst single file 1,920 contours
(`longest road.lbrn2`) and 181,473 points (`reference card.lbrn2`).

Two findings shaped the payload:

1. **JSON beats shipping the SVG, sometimes by ~4,000×.** `metal test 5.lbrn2` is 1.45 MB gzipped
   as SVG and 0.1 KB as geometry JSON, because the SVG inlines the placed photo's base64.
   Excluding bitmap data is what makes this cheap.
2. **The biggest files are the cheapest.** `pics.lbrn2` is 24 MB on disk and contains 2 shapes;
   every photo-engraving file looks like that. Their cost is *fetching* the bytes out of the file
   layer, not parsing them — which is the argument for doing the work in a job rather than on a
   browser-facing request.

## 4. Architecture

A new preview **kind**, `"geometry"`, produced by the existing preview pipeline and served as a
blob.

```
Measure button
  → GET /files/:node_id/geometry            (session-authed JSON, FilesController#geometry)
      → Maker::Previews::Enqueue.call(kind: "geometry")
          → Maker::GeneratePreviewJob        (existing; forwards kind: to the renderer)
              → Maker::Previews::Lbrn2.render(bytes, kind: "geometry")
                  → Maker::Previews::LbrnGeometry.build(doc)   (new)
              → attaches JSON as the Preview's asset, status: ready
      ← { status: "ready", url: <blob url> }
  → lbrnmeasure Stimulus controller fetches the blob, builds SVG, hit-tests, reports
```

### Why this shape

- The expensive parts are already solved here. Whole-file reads happen in a job, so the 24 MB
  photo files never block a request. `MAX_PREVIEW_BYTES` already refuses files too big to be worth
  rendering; `retry_on Maker::FileBytes::FetchError` already handles a transient byte-store blip;
  `commit_if_current` already stops a slow parse of v1 attaching itself to a row that moved to v2.
- Invalidation is `version_id`, which the preview pipeline already gets right. A hand-rolled cache
  key would be re-deriving it.
- The worst-case 281 KB payload leaves via the blob URL — off Rails, consistent with §15.

### The `kind` seam

`Enqueue.call` already takes `kind:` (defaulting to `"thumbnail"`), `GeneratePreviewJob` already
passes `kind: preview.kind` to any renderer whose `render` signature declares it
(`render_with`), and `Maker::Previews::Mesh` already branches on it. `Preview`'s uniqueness
validation is scoped `%i[user_id kind]`, so a second row for the same node is valid by design.

**Note for the implementer:** `model_glb` is declared in `KINDS` but *refused* by `Mesh`, so
nothing in production exercises this seam today. `"geometry"` is its first real user. Expect to
find rough edges the existing tests do not cover.

## 5. Server changes

### 5.1 `Maker::Preview`

```ruby
KINDS = %w[thumbnail model_glb render geometry].freeze
```

### 5.2 `Maker::GeneratePreviewJob#asset_ext`

Add `when "application/json" then ".json"`. Without it the attachment lands as `.bin` — the stored
`content_type` is still correct, but the filename is wrong and misleading.

### 5.3 `Maker::Previews::Lbrn2.render` gains `kind:`

Mirrors `Mesh#render`'s existing branch:

```ruby
def render(lbrn2_bytes, size: 512, kind: "thumbnail")
  return LbrnGeometry.render(lbrn2_bytes) if kind == "geometry"
  # ...unchanged thumbnail path...
end
```

`render_with` inspects the method's parameters, so adding the kwarg is what opts this renderer in.
Every other kind keeps today's behaviour byte-for-byte.

### 5.4 `Maker::Previews::Lbrn2.each_geometry` gains a 6th yielded value

Today:

```ruby
yield cut_index, points, closed, ellipse, image
```

Becomes:

```ruby
yield cut_index, points, closed, ellipse, image, object_id
```

`object_id` is a monotonic counter incremented **once per non-Group `<Shape>` reached by the
walk**, in document order. A `Group` emits no geometry of its own — `walk_shapes` recurses into its
`<Children>` and `next`s — so it consumes no id; its children get their own, which is what makes a
group transparent to measurement exactly as it is to drawing.

**A Text's `<BackupPath>` inherits its parent Text's id**, so alt-clicking one letter reports the
whole sign. `walk_shapes` already emits the `BackupPath` immediately after its `Shape`, so this is
a matter of passing the same value twice, not new traversal.

**This is the only change to the shared traversal, and it must stay additive.** Ruby's block arity
is lenient, so the two existing callers — `to_svg` (5 params) and `job_size` (4 params) — are
unaffected. §14's one-traversal rule is preserved: the geometry payload is built by the same walk
that draws the thumbnail and computes job size, so the two can never be computed from different
geometry. That is the exact failure `LbrnMetadata` already shipped once, when it kept a private
second copy of the traversal and independently inherited every dialect bug.

### 5.5 `Maker::Previews::LbrnGeometry` (new)

```ruby
{
  "v": 1,
  "job":    { "w": 302.4, "h": 210.0, "x": -12.0, "y": -8.5 },
  "shapes": [
    { "o": 7, "c": "2", "b": [x0, y0, x1, y1], "d": 6.2, "k": 1, "i": 0,
      "p": [[x, y], [x, y], ...] }
  ]
}
```

| key | meaning |
|---|---|
| `v` | payload schema version — `1`. The client refuses an unknown version rather than mis-drawing. |
| `job` | the document bbox plus its origin; the client's initial `viewBox`. Same geometry as `Lbrn2.job_size`, but carried at this payload's 2-decimal precision — `job_size` rounds to 1 (see the tolerance note in §7). |
| `o` | object id (§5.4) — the grouping key for alt-click. |
| `c` | `CutIndex`. Not rendered today; kept because it is the only field that cannot be recovered client-side, and it costs ~1% of the payload. |
| `b` | `[min_x, min_y, max_x, max_y]` in mm, **from full-resolution geometry**. |
| `d` | diameter in mm, present only when the contour is circular (§5.5.2). |
| `k` | `1` closed, `0` open. |
| `i` | `1` when the contour is a placed bitmap. |
| `p` | drawing points, possibly decimated (§5.5.1). |

Coordinates round to **2 decimal places** (0.01 mm).

**Bitmap base64 is excluded.** This is the single decision that makes the payload cheap (§3), and
it is not an oversight to be "fixed" later: a measuring view has no use for the photo, and
including it costs up to 1.45 MB gzipped on one file. A bitmap draws as a plain placeholder
rectangle, flagged by `i`.

Parsing must go through **`Lbrn2.parse_document`**, never a fresh `Nokogiri::XML(bytes)`. That
method carries the `huge` flag; without it libxml2 caps a single attribute at 10 MB and `recover`
hands back a **truncated tree** — root intact, every `Shape` after the inlined photo gone. Two of
the 58 real files hit this, and the failure is silent: a clean-looking parse reporting no geometry.

**A corrupt document raises; an empty one does not.** `render` raises `Lbrn2::ParseError` when
`doc.root` is nil, matching `to_svg`, so the job marks the preview `failed`. A document that parses
but genuinely holds no shapes returns the empty payload and goes `ready` — the client has an honest
message for that. Collapsing the two makes a corrupt file present as a working Measure view reading
"No measurable geometry in this file", which is a lie about the file rather than a graceful
degradation.

#### 5.5.1 Decimation

- Contours of **≤ 32 points ship intact**.
- Larger contours ship **every 3rd point, plus the last point** (so a closed contour still closes).

All the savings live in the big text-outline contours — `bookmark.lbrn2` averages 278 points per
contour — and the threshold is what stops a 12-point circle degenerating into a triangle.

**`b` is computed from full-resolution geometry, before decimation, always.** Thinning points is a
drawing concession; it must never move a reported number. An implementation that decimates first
and measures after will pass any "does it draw" test while silently under-reporting every curve.

#### 5.5.2 Circle detection

A contour gets `d` when **all three** hold:

1. it is closed (`k == 1`), **and**
2. it has **at least 12 points**, **and**
3. every point lies within **2%** of the mean radius measured from the bbox centre.

Then `d = (w + h) / 2`, computed from **full-resolution** points like every other measurement.

**Condition 2 is not padding, and dropping it is the trap.** A square's four corners are all
equidistant from its centre — so are any regular polygon's vertices — which means the radius test
*alone* calls every square round. A `Rect` emits exactly 5 points, a bezier circle 49, and an
`Ellipse` 33, so a 12-point floor separates them cleanly. Accepted and deliberate: a genuine
16-sided polygon will be reported as round. It is 20 mm across either way, and the alternative
(an area test as well) buys accuracy nobody asked for.

This is a circularity test, **not** a `w == h` test — a `w == h` test calls every square round for
a different reason. It deliberately catches circles drawn as four bezier segments, the usual form
for a hole imported from DXF/SVG, which the parser's existing `ellipse` flag does not: that flag
only fires for `Type="Ellipse"` under an axis-aligned transform.

### 5.6 `FilesController#geometry` + route

`GET /files/:id/geometry` — a member route on `resources :files`, so the param is `:id` and carries
the node_id, exactly as the sibling `blob` route already does (`blob_file_path(@node.node_id)`).
The path helper is `geometry_file_path(node_id)`.

```ruby
resources :files, only: %i[index create show destroy] do
  member do
    get "blob"
    get "geometry"   # new
  end
end
```

The action calls `Maker::Previews::Enqueue.call(user:, node_id:, name:, version_id:,
kind: "geometry")` and answers JSON:

| preview state | response |
|---|---|
| `pending` / `processing` | `{ "status": "pending" }` |
| `ready` | `{ "status": "ready", "url": <blob url> }` |
| `failed` | `{ "status": "failed", "error": <preview.error> }` |
| `unsupported` | `{ "status": "unsupported", "error": <preview.error> }` |

This mirrors `GET /files/thumbnails`'s existing shape so the polling code is a known quantity.
Backend-neutral: it reads bytes through `Maker::FileBytes` like every other preview, and touches
no capability gate.

## 6. Client changes

### 6.1 `FilesController#preview_kind` gains `:lbrn`

Returned **before** the `:thumbnail` branch for `lbrn`/`lbrn2`, exactly as `:model3d` is returned
before it for meshes. The thumbnail is still generated and still serves as the poster.

**Regression risk to check explicitly:** `.lbrn2` no longer takes the `:thumbnail` branch, so the
new branch must reproduce all of its states — ready poster, "Generating preview…", and the
no-preview fallback. The Laser Settings panel is unaffected: it reads `@thumbnail.metadata` from
the `kind: "thumbnail"` row, and geometry is a separate row.

### 6.2 `lbrnmeasure` Stimulus controller

Resting state is unchanged — LightBurn's colour PNG plus a **Measure** button. Clicking fetches,
swaps in the interactive view, and offers **✕ Image** to return. The bar mirrors
`model-viewer-bar`.

**Rendering.** The controller builds the SVG in the DOM with `createElementNS`, from numbers only
— **no server-sent markup, no `innerHTML`**. `Maker::Previews::Svg` rasterizes precisely because
the web layer refuses to inline SVG; building elements from coordinates sidesteps that rule rather
than carving an exception into it.

**Hit-testing is the browser's, not ours.**

- Closed contours: `fill: transparent`.
- Open contours: transparent stroke widened in screen space via `vector-effect: non-scaling-stroke`.
- Contours are **appended in descending bbox-area order**, so smaller shapes land on top and the
  browser's natural topmost-wins dispatch yields "smallest containing shape wins" for free.

That is the entire selection algorithm. No point-in-polygon code.

**Readout**, in a bar below the canvas:

- `40.0 × 20.0 mm`, or `⌀6.2 mm` when `d` is present.
- For a contour in a multi-contour object: `· part of a 5-contour path (⌥ for 80.0 × 40.0 mm)`.
  Alt-click unions the bboxes of every contour sharing `o` — client-side, no round-trip. The hint
  is what keeps the modifier from being an undiscoverable interaction.
- Hover highlights the contour under the cursor.

**Zoom / pan.** Scroll to zoom, drag to pan, by manipulating the SVG `viewBox`. Without it a 3 mm
hole in a 300 mm design is ~5 px on a 512-wide canvas, and the dense files are exactly the ones
worth measuring.

**Poll ceiling.** The job's `retry_on ... attempts: 5` with polynomial backoff can run for minutes.
The client polls a bounded number of times with backoff, then degrades to "Still generating —
reload to check." It must not poll indefinitely.

**Degenerate cases.** Zero contours renders "No measurable geometry in this file", not a blank
canvas. A photo-engraving file measures its placed image's rectangle, which is a real answer.

### 6.3 Error surfacing

The resting PNG stays visible under every failure state.

| state | shown |
|---|---|
| `unsupported` | the job's own message verbatim — it already names `PREVIEW_MAX_BYTES` and the ceiling |
| `failed` | the error, with Download still available |
| poll ceiling reached | "Still generating — reload to check." |
| unknown payload `v` | "This preview needs a newer version of the page — reload." |

Note what is deliberately **not** in that table: a document that parses but holds no shapes is not
an error at all. It reaches `ready` with an empty payload and the client says "No measurable
geometry in this file". Only an unparseable document raises (§5.5), and it lands in `failed`.

## 7. Testing

Every guard below is **mutation-checked** (§15): after it goes green, break the thing it guards and
confirm it goes red, then restore.

**The guard that matters:**

> The union of the geometry payload's bboxes, put through `Lbrn2.job_size`'s own `round(1)`,
> must equal `Lbrn2.job_size` exactly.

The rounding step is part of the assertion, not a fudge: the payload carries 2 decimals and
`job_size` emits 1, so comparing the raw floats would fail on correct output. Round once, then
demand equality — a tolerance band would let a real divergence hide inside it.

This ties the new output to the existing one, and goes red if anyone later optimises the walk for
one caller. Mutate by applying decimation to all contours, or by dropping `BackupPath` emission.

Around it:

- **Every payload field is pinned BY VALUE, not by presence.** Learned the expensive way: `job`'s
  origin, `c`, `i` and `PRECISION` were each mutable to a wrong value with all 136 tests green.
  `key?` is not a test. `i` is the only thing standing behind the bitmap-exclusion promise, and
  `job`'s origin places every shape in the client's viewBox.
- **`b` is invariant under decimation** — the reported bbox equals the full-resolution bbox.
  Mutate by computing `b` after decimating. The **union-over-the-document** form of this assertion
  cannot catch it, for two compounding reasons: `BEZIER_SAMPLES % DECIMATE_STRIDE == 0` means no
  original vertex is ever dropped, and where a contour *does* shrink, a co-located Rect already
  bounds the union. It needs a **per-shape** assertion on a fixture whose ellipse is not shadowed.
  (Asserting the decimated points fall inside the bbox is decorative — they are a subset of the
  points the bbox was measured over, so it holds under any implementation.)
- **The stride/sample coupling is asserted directly** — `BEZIER_SAMPLES % DECIMATE_STRIDE == 0`,
  plus a check that every original vertex survives `decimate`. It spans two files and two
  constants, and breaks silently.
- **Circle detection asserts both directions** — a bezier-drawn circle IS round *and* a square is
  NOT. Asserting only the first still passes with the tolerance loosened to 50%, which is §15's
  "assert the narrowest true thing, then mutate to prove each assertion carries weight".
- **Object grouping** — a Text's `BackupPath` shares its parent Text's `o`. Mutate by giving it its
  own id.
- **The traversal change is additive** — `to_svg` and `job_size` outputs are byte-identical before
  and after the 6th yielded value, characterized on the existing fixtures.
- **The endpoint is driven as a real request** through all four states, never by setting statuses
  in Ruby. Same reason §14a's capability-gating tests were green while unable to fail.
- **System test** clicks a contour and asserts the readout text. Hermetic on
  `test/fixtures/files/real-export.lbrn2`, following `addon_bundle_test.rb`'s rule of never
  reaching for a corpus a fresh clone does not have.

**Two fixtures are missing and must be added — verified, not assumed.** The existing three cover:

| fixture | contains |
|---|---|
| `real-export.lbrn2` | 1 Group, 3 Path, 1 Rect |
| `sample.lbrn2` | 1 Ellipse, 1 Line, 1 Rect |
| `laser-settings.lbrn2` | 1 Ellipse, 1 Rect, 1 Text |

**No fixture has a `<BackupPath>`, and none has a bezier-drawn circle.** So the object-grouping
test and the circle-detection test have nothing to run against today. Note that
`laser-settings.lbrn2`'s Text is not sufficient: without a `BackupPath` a Text contributes no
geometry at all, which is the whole reason that element is parsed.

Add two minimal fixtures rather than weakening either assertion:

1. **`text-backup-path.lbrn2`** — a Text with a `<BackupPath>` whose `PrimList` yields more than one
   contour (an "O" or a two-letter string), for object grouping.
2. **`bezier-circle.lbrn2`** — a circle written as four `B` segments in a `PrimList` (LightBurn's
   own form, and the form an imported DXF/SVG hole takes), plus a square of the same width and
   height in the same file, so the both-directions circularity assertion has its negative case.

**Both fixtures must be authored in the dialect LightBurn actually writes**, verified against the
corpus, not invented:

- `<BackupPath Type="Path" CutIndex="N">` **carries a `Type` attribute** (74 instances across the
  corpus, all `Type="Path"`). Without it, `emit_shape`'s `case shape["Type"]` matches no arm and
  the fixture emits nothing — a test that passes while proving nothing.
- `B<a> <b>` `PrimList` segments are real: 42 of the 58 files use them.

This is the trap `real-export.lbrn2` exists to document — `sample.lbrn2` is hand-authored in a form
LightBurn has never emitted, and the parser that matched it drew 1.0% of real shapes. Author both
new fixtures against `real-export.lbrn2`'s dialect, and add a test that asserts the parser reads
the expected contour count out of each *before* relying on either.

**Gates.** Bare `bin/ci` — all gates, and the three test legs (`test`, `test-share`, `test-s3`)
must report identical counts.

**The 58 real files stay a manual probe, not a gate.** Land the measurement harness as a rake task
pointed at a path. It is the only real-format validation set — the repo fixtures are hand-authored
in a dialect LightBurn never emits — and it cannot live in CI.

## 8. Files touched

| file | change |
|---|---|
| `app/models/maker/preview.rb` | `KINDS` += `"geometry"` |
| `app/jobs/maker/generate_preview_job.rb` | `asset_ext` += `application/json` |
| `app/services/maker/previews/lbrn2.rb` | `render` gains `kind:`; `each_geometry` yields a 6th value |
| `app/services/maker/previews/lbrn_geometry.rb` | **new** — payload builder, decimation, circularity |
| `app/controllers/files_controller.rb` | `#geometry` action; `preview_kind` gains `:lbrn` |
| `config/routes.rb` | `get "geometry"` member route |
| `app/views/files/show.html.erb` | `:lbrn` preview branch |
| `app/javascript/controllers/lbrnmeasure_controller.js` | **new** |
| `app/assets/stylesheets/*` | measure bar / canvas styles |
| `lib/tasks/lbrn.rake` | **new** — corpus geometry report (manual probe) |
| `test/fixtures/files/text-backup-path.lbrn2` | **new** — Text + multi-contour `BackupPath` (§7) |
| `test/fixtures/files/bezier-circle.lbrn2` | **new** — 4-segment bezier circle + same-size square (§7) |
| `test/...` | unit, endpoint, and system tests per §7 |

## 9. Non-goals

- No overlay onto LightBurn's own render (registration across real files is the risky part, and
  outlines are cheaper to trust).
- No replacement of the PNG as the resting state.
- No per-layer colouring of the outline view. LightBurn does not write layer colours into the file
  — not one of 150 `CutSetting` blocks across the corpus carries a `<color>` — and reproducing the
  built-in palette would mean hard-coding ~30 colours guessed from thumbnails.
- No cut-length, bed position, or layer/speed/power in the readout.
- No client-side re-implementation of the lbrn2 parser. A second copy of that traversal is this
  repo's recorded failure shape, and §14 already names the instance where it happened.
