# LightBurn Laser-Settings Panel — Design

**Date:** 2026-07-24
**Status:** Approved (brainstorm), pending implementation plan

## Summary

Parse the laser "recipe" out of LightBurn (`.lbrn` / `.lbrn2`) files during the existing
preview pass, store it as structured JSON on the preview, and render it as a **Laser settings**
panel on the file detail page — beside the preview, taking about half the width.

Today the LightBurn renderer ([`app/services/maker/previews/lbrn2.rb`](../../../app/services/maker/previews/lbrn2.rb))
only produces an **image**: it returns the embedded `<Thumbnail>` when present, else reconstructs
the geometry as an SVG. All the operational data in the file — per-layer speed/power/passes, job
size, target machine — is parsed only far enough to pick stroke colours, then discarded. This
feature surfaces it.

## Motivation

A `.lbrn2` file is a complete laser job: which layers cut vs. engrave, at what speed and power,
how many passes, on what machine, at what size. For a maker cataloguing laser files, that "recipe"
is the single most useful thing to see at a glance — more useful than the outline thumbnail. It is
all already in the XML; we just aren't showing it.

## Scope

**In scope**

- A `Maker::Previews::LbrnMetadata` parser: `.lbrn`/`.lbrn2` bytes → a plain metadata Hash.
- The `Lbrn2` renderer returns that Hash in its result (`metadata:`), computed independently of
  which image path (embedded thumbnail vs. SVG) was taken.
- A new `metadata` JSON column on `maker_previews`; `GeneratePreviewJob` persists it.
- A **Laser settings** panel on `/files/:id` for lightburn files, laid out beside the preview
  (~half width, stacking on narrow screens).
- A one-time backfill (rake task) to re-render existing lightburn previews so they gain metadata.

**Fields shown** (all parseable from the XML; only fields actually present are rendered):

- **Per layer:** name (e.g. `C00`), colour (swatch), mode (Cut / Fill / Image), speed, power
  (max, plus min when it differs), passes.
- **Summary:** job size (W × H mm), material height, machine (device name), layer count, shape
  count, any text strings in the file, LightBurn version.

**Out of scope (YAGNI)**

- Air-assist, per-layer priority, project `<Notes>` fields (easy to add later; left out to stay lean).
- A panel on the model detail page (lightburn files are reached via the file page).
- Estimated run time (LightBurn computes it live; it is not stored in the file).
- Editing settings, or writing back to the file.

## Metadata shape

`LbrnMetadata.parse(bytes)` returns either `nil` (not a parseable LightBurn file) or a Hash of the
form below. Every key is optional — the parser emits only what it finds, so the panel and the tests
must treat any field as possibly-absent. String keys (it round-trips through a JSON column).

```ruby
{
  "app_version"     => "1.4.00",           # root AppVersion
  "format_version"  => "1",                # root FormatVersion
  "machine"         => "Ortur LM2",        # root DeviceName (attr or child), when present
  "material_height" => 3.0,                # root MaterialHeight (mm), when present
  "job"             => { "width" => 120.0, "height" => 80.0 },  # geometry bbox in mm
  "shape_count"     => 42,
  "text"            => ["MAKER", "est. 2026"],  # strings from Text shapes
  "layers"          => [
    { "index" => "0", "name" => "C00", "color" => "#e11d48",
      "mode" => "Cut",  "speed" => 15.0,  "power_max" => 85.0, "power_min" => 85.0, "passes" => 2 },
    { "index" => "1", "name" => "C01", "color" => "#16a34a",
      "mode" => "Fill", "speed" => 200.0, "power_max" => 30.0, "power_min" => 30.0, "passes" => 1 },
    { "index" => "2", "name" => "C02", "color" => "#2563eb",
      "mode" => "Image","speed" => 150.0, "power_max" => 40.0, "power_min" => 20.0, "passes" => 1 }
  ]
}
```

Only layers **referenced by at least one shape's `CutIndex`** are included (a `.lbrn2` carries 30
CutSetting entries by default; showing the empty ones would be noise). `layers` is ordered by
`index`.

## Parsing

New module `Maker::Previews::LbrnMetadata` (Nokogiri, MIT — CLAUDE.md §9), a sibling of `Lbrn2`.

- **`parse(bytes) -> Hash | nil`** — `Nokogiri::XML(bytes){ |c| c.recover }`; return `nil` if the
  root is missing or not `LightBurnProject`. Wrap the body so a `Nokogiri::XML::SyntaxError` (or any
  `StandardError`) returns `nil` rather than raising — the panel is best-effort and must never turn
  a renderable file into a failed preview.
- **Layers** — reuse the reading style already in `Lbrn2#cut_colors` (values live as either an
  attribute `cs["speed"]` or a child `<speed Value="…">`; handle both). Per `<CutSetting>`: `type`
  attribute → mode (`Cut` → `"Cut"`, `Scan` → `"Fill"`, `Image` → `"Image"`; anything else passes
  through capitalized); `<name>`; `<color>` via the existing `Lbrn2.normalize_color` (0x00BBGGRR →
  `#rrggbb`); `<speed>`, `<maxPower>`, `<minPower>`, `<numPasses>` as numbers.
- **Which layers to keep** — collect the set of `CutIndex` values used by `//Shape`; keep only
  CutSettings whose index is in that set.
- **Shapes / text / size** — `shape_count` = `//Shape` count; `text` = the string of each
  `Type="Text"` shape (LightBurn stores it as a `Str`/`<Str>` value — read attr-or-child, skip
  blanks); `job` width/height = the geometry bounding box. **Reuse `Lbrn2`'s existing bbox math**
  (`apply` + `BBox`) so size matches the thumbnail exactly rather than duplicating the transform
  logic.
- **Root fields** — `AppVersion`, `FormatVersion`, `MaterialHeight`, and `DeviceName` (attribute or
  a `<DeviceName>`/device-settings child; best-effort, omit if absent).

**Exact attribute vs. child placement varies by `FormatVersion`.** The parser reads attr-or-child
for every value (as `cut_colors` already does), and the plan verifies names against a real
LightBurn-exported file, not only the minimal `test/fixtures/files/sample.lbrn2`.

### Integration with the renderer

`Lbrn2.render` currently returns the image result. Extend it to also attach metadata:

```ruby
def render(lbrn2_bytes, size: 512)
  meta = Maker::Previews::LbrnMetadata.parse(lbrn2_bytes)      # nil-safe
  img  = Maker::Previews::EmbeddedThumbnail.extract(lbrn2_bytes) ||
         Maker::Previews::Svg.render(to_svg(lbrn2_bytes, size:), size:)
  img.merge(metadata: meta)
end
```

The metadata is parsed from the XML regardless of whether the image came from the embedded
`<Thumbnail>` or the SVG fallback — so it is available for essentially every lightburn file, not
only hand-authored ones.

## Storage

- **Migration:** add `t.json "metadata"` to `maker_previews` (nullable). Mirrors
  `Maker::Model#print_settings` (`t.json` — native JSON on Postgres, JSON-over-TEXT on SQLite;
  Rails serializes/deserializes, so `preview.metadata` reads back as a Hash). No `serialize` call
  needed.
- **Job:** in [`GeneratePreviewJob`](../../../app/jobs/maker/generate_preview_job.rb), persist it
  next to the existing width/height:
  `preview.update!(status: "ready", width: result[:width], height: result[:height], metadata: result[:metadata], error: nil)`.
  `result[:metadata]` is `nil` for every other renderer (they don't set the key), leaving the column
  null — no change to their behaviour. No second byte-fetch: it rides the one render pass.

The row is already keyed by `(user, node_id, version_id, kind)`, so an edited file re-renders and
re-parses; the metadata lives on the **thumbnail** preview, which the file page already loads.

## UI

- **[`app/views/files/show.html.erb`](../../../app/views/files/show.html.erb):** when
  `@thumbnail&.metadata.present?` (only lightburn files ever have it), render the preview and a new
  `files/_lbrn_settings` partial as a two-column flex row (`flex-wrap: wrap`, each column
  `flex: 1 1 ~46%`, min-width so they stack on narrow). When there's no metadata, the `.preview`
  block renders exactly as today — **no other file type is affected**.
- **`app/views/files/_lbrn_settings.html.erb`** (new): reads `@thumbnail.metadata`; renders the
  layers `<table>` (colour swatch + name, mode, speed, power [`max` or `max / min`], passes) and a
  summary grid (job size, material height, machine, layer/shape counts), plus a text/version
  footer. Guards every field with `present?` so partial data still renders cleanly.
- **CSS:** a small `.lbrn-settings` block in `application.css` (table + summary grid + the
  two-column wrapper). No new JS.

## Edge cases & degradation

- **Not parseable** (older thumbnail-only file with unreadable geometry, malformed XML, or a
  non-lightburn file that somehow reaches the parser) → `metadata` is `nil` → **no panel**, the
  thumbnail renders normally. Same graceful contract as the rest of the preview system.
- **Partial data** (a field missing) → that row/cell is omitted; the panel still shows what it has.
- **`speed`/`power` units** — LightBurn stores speed in **mm/s** and power as a **percent** in the
  file; the panel labels them accordingly. (Verified against a real export in the plan.)

## Backfill

Existing lightburn previews predate the column and won't have metadata until their file is next
edited. Add a one-time **rake task** (`lib/tasks/previews.rake`, e.g. `previews:backfill_lbrn`) that
re-enqueues `GeneratePreviewJob` for every ready lightburn thumbnail preview whose `metadata` is
null. Idempotent (re-render is deterministic); safe to run repeatedly.

## Testing

- **Parser unit tests** (`test/services/maker/previews/lbrn_metadata_test.rb`): a richer fixture
  `.lbrn2` (≥2 CutSettings with distinct speed/power/passes, mixed Cut/Scan/Image modes, a Text
  shape, sized shapes, an unused CutSetting to prove it's dropped) → assert the parsed Hash field by
  field. Plus: a thumbnail-only / geometry-less file (returns the fields it can, no raise) and a
  malformed-XML input (→ `nil`, no raise).
- **Renderer test**: `Lbrn2.render` on a lightburn file returns `metadata:` alongside the image
  bytes; the embedded-thumbnail path still returns metadata too.
- **Job test**: rendering a lightburn file persists a non-null `metadata`; rendering a non-lightburn
  file (e.g. an SVG) leaves `metadata` null.
- **Request test** (`test/integration/web/files_flow_test.rb`): the file detail page for a lightburn
  file renders `.lbrn-settings` with the parsed values; a non-lightburn file renders no panel and
  its preview is unchanged. Runs green on all three backends (chunk / share / s3), matching the
  repo's CI legs.

## Files touched (anticipated)

- Create: `app/services/maker/previews/lbrn_metadata.rb`
- Modify: `app/services/maker/previews/lbrn2.rb` (return `metadata:` from `render`)
- Migration: add `metadata` json to `maker_previews`
- Modify: `app/jobs/maker/generate_preview_job.rb` (persist `result[:metadata]`)
- Create: `app/views/files/_lbrn_settings.html.erb`
- Modify: `app/views/files/show.html.erb` (two-column preview + panel for lightburn)
- Modify: `app/assets/stylesheets/application.css` (`.lbrn-settings`)
- Create: `lib/tasks/previews.rake` (backfill) — or extend an existing previews rake file if present
- Tests + a richer `.lbrn2` fixture

## Open questions

None outstanding. Field set, layout, and storage are settled; exact XML attribute names are
verified against a real export during implementation, with the parser reading attr-or-child either
way.
