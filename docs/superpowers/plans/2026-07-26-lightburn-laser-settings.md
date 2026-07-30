# LightBurn Laser-Settings Panel Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Parse the laser "recipe" (per-layer speed/power/passes, job size, machine, …) out of LightBurn `.lbrn`/`.lbrn2` files during the existing preview pass, store it as JSON on the preview, and show it as a panel beside the preview on the file detail page.

**Architecture:** A new `Maker::Previews::LbrnMetadata` parser (Nokogiri) turns the XML into a plain Hash. The existing `Lbrn2` renderer calls it and returns it under `metadata:` in its result — so it rides the one render pass, independent of whether the image came from the embedded `<Thumbnail>` or the SVG fallback. `GeneratePreviewJob` persists that into a new `metadata` JSON column on `maker_previews`. The file detail page renders a `_lbrn_settings` partial beside the preview when the thumbnail preview has metadata. No sync/storage coupling — this is entirely catalog-side (CLAUDE.md §10).

**Tech Stack:** Rails 8, Nokogiri (MIT) for XML, ERB + plain CSS for the panel, Minitest integration tests (`assert_select`) run green on all three library backends (chunk/share/s3).

---

## Background the implementer needs

- **The renderer contract:** every `Maker::Previews::*` renderer's `render(bytes, size:)` returns a Hash `{ bytes:, content_type:, width:, height: }`. `GeneratePreviewJob#perform` attaches `result[:bytes]` and stores `result[:width]`/`result[:height]`. We add an optional `metadata:` key that only `Lbrn2` sets.
- **`Lbrn2` today** ([`app/services/maker/previews/lbrn2.rb`](../../../app/services/maker/previews/lbrn2.rb)): `render` returns the embedded `<Thumbnail>` PNG (`EmbeddedThumbnail.extract`) when present, else geometry → SVG (`Svg.render`). It already has reusable, **module-function** helpers we lean on: `normalize_color` (LightBurn 0x00BBGGRR int → `#rrggbb`), `parse_xform`, `apply` (affine + Y-flip), `vertices`, `num`, and a nested `BBox` class. All are callable as `Lbrn2.<name>` / `Lbrn2::BBox`.
- **Reading values attr-or-child:** LightBurn stores a `CutSetting`'s fields as child elements with a `Value` attribute (`<speed Value="15"/>`) in real exports, but sometimes as bare attributes. `Lbrn2#cut_colors` already reads both forms; the parser mirrors that.
- **The file page** ([`app/controllers/files_controller.rb`](../../../app/controllers/files_controller.rb) `#show`, ~line 196): sets `@kind = preview_kind(@node.name)` and `@thumbnail = current_user.maker_previews.find_by(node_id:, version_id: token, kind: "thumbnail")`. For `.lbrn`/`.lbrn2`, `preview_kind` returns `:thumbnail` (via `Registry.for(ext)`), so the page shows a server-rendered PNG and `@thumbnail.metadata` is available. **No controller change is needed** — `@thumbnail` is already loaded.
- **JSON column precedent:** `maker_models.print_settings` is `t.json` (native JSON on Postgres, JSON-over-TEXT on SQLite; reads back as a Hash, no `serialize`). We mirror it on `maker_previews`.
- **Test conventions:** parser/job tests are `ActiveSupport::TestCase` / `ActiveJob::TestCase` under `test/`; the web request test lives in `test/integration/web/files_flow_test.rb` (has a `sign_in` + `upload(name, bytes) -> node_id` helper; `setup` pins `chunk`). The suite runs on three CI legs (`bin/rails test`, `LIBRARY_BACKEND=share`, `LIBRARY_BACKEND=s3`).

## Metadata shape (string keys — it round-trips a JSON column)

```ruby
{
  "app_version" => "1.7.00", "format_version" => "1",
  "machine" => "Ortur LM2", "material_height" => 3.0,
  "job" => { "width" => 40.0, "height" => 20.0 },
  "shape_count" => 3, "text" => ["MAKER"],
  "layers" => [
    { "index"=>"0", "name"=>"C00", "color"=>"#ff0000", "mode"=>"Cut",
      "speed"=>15.0, "power_max"=>85.0, "power_min"=>85.0, "passes"=>2 },
    { "index"=>"1", "name"=>"C01", "color"=>"#00ff00", "mode"=>"Fill",
      "speed"=>200.0, "power_max"=>30.0, "power_min"=>30.0, "passes"=>1 }
  ]
}
```

Only layers referenced by a shape's `CutIndex` are kept; every field is best-effort (omitted when absent); a non-LightBurn or malformed input returns `nil`.

## File structure

| File | Responsibility | Change |
|---|---|---|
| `db/migrate/*_add_metadata_to_maker_previews.rb` | `metadata` JSON column | **New** (generated) |
| `app/services/maker/previews/lbrn_metadata.rb` | XML → recipe Hash | **New** |
| `app/services/maker/previews/lbrn2.rb` | +`BBox#dimensions` helper; `render` returns `metadata:` | Modify |
| `app/jobs/maker/generate_preview_job.rb` | persist `result[:metadata]` | Modify (1 line) |
| `app/views/files/_lbrn_settings.html.erb` | the panel | **New** |
| `app/views/files/show.html.erb` | two-column preview+panel when metadata present | Modify |
| `app/assets/stylesheets/application.css` | `.lbrn-settings` + `.preview-row` | Modify |
| `app/services/maker/previews/lbrn_backfill.rb` | re-enqueue existing lightburn previews | **New** |
| `lib/tasks/previews.rake` | `previews:backfill_lbrn` thin wrapper | **New** |
| `test/fixtures/files/laser-settings.lbrn2` | richer fixture | **New** |
| `test/services/maker/previews/lbrn_metadata_test.rb` | parser tests | **New** |
| `test/services/maker/previews/lbrn2_test.rb` | render returns metadata | Modify |
| `test/jobs/maker/generate_preview_job_test.rb` | persists metadata | Modify |
| `test/services/maker/previews/lbrn_backfill_test.rb` | backfill logic | **New** |
| `test/integration/web/files_flow_test.rb` | panel renders / absent | Modify |

---

## Task 1: `metadata` JSON column on `maker_previews`

**Files:** Create (generate): `db/migrate/*_add_metadata_to_maker_previews.rb`; updates `db/schema.rb`.

- [ ] **Step 1: Generate the migration**

Run:
```bash
bin/rails generate migration AddMetadataToMakerPreviews metadata:json
```

- [ ] **Step 2: Confirm the migration body**

Open the generated file; it must read exactly (edit to match if the generator differs):
```ruby
class AddMetadataToMakerPreviews < ActiveRecord::Migration[8.0]
  def change
    add_column :maker_previews, :metadata, :json
  end
end
```

- [ ] **Step 3: Migrate**

Run:
```bash
bin/rails db:migrate
```
Expected: migrates cleanly; `db/schema.rb` now shows `t.json "metadata"` in `create_table "maker_previews"`.

- [ ] **Step 4: Verify the column exists**

Run:
```bash
bin/rails runner 'puts Maker::Preview.column_names.include?("metadata")'
```
Expected: `true`.

- [ ] **Step 5: Commit**

```bash
git add db/migrate db/schema.rb
git commit -m "feat(lbrn): add metadata json column to maker_previews"
```

---

## Task 2: `Maker::Previews::LbrnMetadata` parser (TDD)

**Files:**
- Create: `test/fixtures/files/laser-settings.lbrn2`
- Test: `test/services/maker/previews/lbrn_metadata_test.rb`
- Create: `app/services/maker/previews/lbrn_metadata.rb`
- Modify: `app/services/maker/previews/lbrn2.rb` (add `BBox#dimensions`)

- [ ] **Step 1: Create the fixture**

Write `test/fixtures/files/laser-settings.lbrn2` with exactly:
```xml
<?xml version="1.0" encoding="UTF-8"?>
<LightBurnProject AppVersion="1.7.00" FormatVersion="1" DeviceName="Ortur LM2" MaterialHeight="3">
  <CutSetting type="Cut">
    <index Value="0"/>
    <name Value="C00"/>
    <speed Value="15"/>
    <maxPower Value="85"/>
    <minPower Value="85"/>
    <numPasses Value="2"/>
    <color Value="255"/>
  </CutSetting>
  <CutSetting type="Scan">
    <index Value="1"/>
    <name Value="C01"/>
    <speed Value="200"/>
    <maxPower Value="30"/>
    <minPower Value="30"/>
    <numPasses Value="1"/>
    <color Value="65280"/>
  </CutSetting>
  <CutSetting type="Cut">
    <index Value="2"/>
    <name Value="C02"/>
    <speed Value="100"/>
    <maxPower Value="50"/>
    <color Value="16711680"/>
  </CutSetting>
  <Shape Type="Rect" CutIndex="0" W="40" H="20" XForm="1 0 0 1 50 30"/>
  <Shape Type="Ellipse" CutIndex="1" Rx="10" Ry="10" XForm="1 0 0 1 50 30"/>
  <Shape Type="Text" CutIndex="0" Str="MAKER" XForm="1 0 0 1 0 0"/>
</LightBurnProject>
```
(Three CutSettings, but index `2` is referenced by no shape, so it must be dropped. The Text shape carries the string. Colours: `255` → `#ff0000`, `65280` → `#00ff00`.)

- [ ] **Step 2: Write the failing tests**

Write `test/services/maker/previews/lbrn_metadata_test.rb`:
```ruby
require "test_helper"

module Maker
  module Previews
    class LbrnMetadataTest < ActiveSupport::TestCase
      setup { @bytes = File.binread(Rails.root.join("test/fixtures/files/laser-settings.lbrn2")) }

      test "parses root-level project fields" do
        m = Maker::Previews::LbrnMetadata.parse(@bytes)
        assert_equal "1.7.00", m["app_version"]
        assert_equal "1", m["format_version"]
        assert_equal "Ortur LM2", m["machine"]
        assert_equal 3.0, m["material_height"]
        assert_equal 3, m["shape_count"]
        assert_equal ["MAKER"], m["text"]
      end

      test "keeps only layers referenced by a shape, in index order" do
        layers = Maker::Previews::LbrnMetadata.parse(@bytes)["layers"]
        assert_equal 2, layers.length, "the unused CutSetting (index 2) is dropped"
        assert_equal %w[0 1], layers.map { |l| l["index"] }
      end

      test "parses per-layer settings incl. mode mapping (Scan -> Fill) and colour" do
        layers = Maker::Previews::LbrnMetadata.parse(@bytes)["layers"]
        c00, c01 = layers
        assert_equal({ "index"=>"0", "name"=>"C00", "color"=>"#ff0000", "mode"=>"Cut",
                       "speed"=>15.0, "power_max"=>85.0, "power_min"=>85.0, "passes"=>2 }, c00)
        assert_equal "Fill", c01["mode"], "LightBurn 'Scan' shows as 'Fill'"
        assert_equal "#00ff00", c01["color"]
        assert_equal 200.0, c01["speed"]
      end

      test "computes job size from the shape bounding box (mm)" do
        job = Maker::Previews::LbrnMetadata.parse(@bytes)["job"]
        assert_equal 40.0, job["width"]
        assert_equal 20.0, job["height"]
      end

      test "returns nil for a non-LightBurn document" do
        assert_nil Maker::Previews::LbrnMetadata.parse("<svg><rect/></svg>")
      end

      test "returns nil (never raises) for malformed input" do
        assert_nil Maker::Previews::LbrnMetadata.parse("<<<not xml")
        assert_nil Maker::Previews::LbrnMetadata.parse("")
      end

      test "omits fields it cannot find rather than emitting nils" do
        bare = %(<LightBurnProject><CutSetting><index Value="0"/></CutSetting>) +
               %(<Shape Type="Rect" CutIndex="0" W="10" H="10" XForm="1 0 0 1 0 0"/></LightBurnProject>)
        m = Maker::Previews::LbrnMetadata.parse(bare)
        refute m.key?("machine")
        refute m["layers"].first.key?("speed")
      end
    end
  end
end
```

- [ ] **Step 3: Run the tests to verify they fail**

```bash
bin/rails test test/services/maker/previews/lbrn_metadata_test.rb
```
Expected: FAIL — `NameError: uninitialized constant Maker::Previews::LbrnMetadata`.

- [ ] **Step 4: Add `BBox#dimensions` to `lbrn2.rb`**

In `app/services/maker/previews/lbrn2.rb`, inside `class BBox`, add this method (e.g. right after `empty?`):
```ruby
        # [width, height] of the accumulated box, or nil when empty. Used by LbrnMetadata for job size.
        def dimensions
          return nil if empty?

          [ @max_x - @min_x, @max_y - @min_y ]
        end
```

- [ ] **Step 5: Implement the parser**

Write `app/services/maker/previews/lbrn_metadata.rb`:
```ruby
require "nokogiri"
require "set"

module Maker
  module Previews
    # LightBurn (.lbrn/.lbrn2) XML -> a structured "recipe" Hash for the file page's Laser
    # Settings panel: per-layer speed/power/passes/mode/colour + job size, machine, text, counts.
    #
    # Best-effort and NON-throwing: parse returns nil for a non-LightBurn or malformed document,
    # and omits any field it can't read, so it can never turn a renderable file into a failed
    # preview. Reuses Lbrn2's colour/geometry helpers (DRY) rather than re-deriving them.
    module LbrnMetadata
      module_function

      # Nokogiri returns strings; keep keys as strings so the Hash round-trips a JSON column.
      def parse(bytes)
        doc = Nokogiri::XML(bytes) { |c| c.recover }
        root = doc.root
        return nil if root.nil? || root.name != "LightBurnProject"

        used = doc.xpath("//Shape").filter_map { |s| s["CutIndex"] }.to_set

        {
          "app_version"     => root["AppVersion"],
          "format_version"  => root["FormatVersion"],
          "machine"         => device_name(root),
          "material_height" => Lbrn2.num(root["MaterialHeight"]),
          "job"             => job_size(doc),
          "shape_count"     => doc.xpath("//Shape").length,
          "text"            => text_strings(doc).presence,
          "layers"          => layers(doc, used).presence,
        }.compact.presence
      rescue StandardError
        nil
      end

      def layers(doc, used)
        doc.xpath("//CutSetting").filter_map do |cs|
          idx = val(cs, "index")
          next if idx.nil? || !used.include?(idx.to_s)

          {
            "index"     => idx.to_s,
            "name"      => val(cs, "name"),
            "color"     => (c = val(cs, "color")) && Lbrn2.normalize_color(c),
            "mode"      => mode(cs["type"]),
            "speed"     => Lbrn2.num(val(cs, "speed")),
            "power_max" => Lbrn2.num(val(cs, "maxPower")),
            "power_min" => Lbrn2.num(val(cs, "minPower")),
            "passes"    => (p = Lbrn2.num(val(cs, "numPasses"))) && p.to_i,
          }.compact
        end.sort_by { |l| l["index"].to_i }
      end

      # LightBurn 'Scan' is labelled 'Fill' in the UI; 'Cut'/'Image' pass through. Unknown -> nil.
      def mode(type)
        case type
        when "Cut"   then "Cut"
        when "Scan"  then "Fill"
        when "Image" then "Image"
        else type.presence
        end
      end

      # A value stored either as an attribute (cs["speed"]) or a child (<speed Value="..">/<speed>text).
      # Mirrors Lbrn2#cut_colors so both real-export forms parse.
      def val(node, key)
        node[key] || node.at_xpath(key)&.[]("Value") || node.at_xpath(key)&.text.presence
      end

      def device_name(root)
        root["DeviceName"] ||
          root.at_xpath(".//DeviceName")&.[]("Value") ||
          root.at_xpath(".//DeviceName")&.text.presence
      end

      def text_strings(doc)
        doc.xpath("//Shape[@Type='Text']").filter_map do |s|
          (s["Str"] || s.at_xpath("Str")&.[]("Value") || s.at_xpath("Str")&.text).to_s.strip.presence
        end
      end

      # Job size = the shapes' bounding box in mm. Reuses Lbrn2's transform + BBox; extracts each
      # shape's raw points here (small, and keeps Lbrn2's tested SVG path untouched).
      def job_size(doc)
        bbox = Lbrn2::BBox.new
        doc.xpath("//Shape").each do |shape|
          xform = Lbrn2.parse_xform(shape["XForm"])
          points_for(shape).each do |(x, y)|
            px, py = Lbrn2.apply(xform, x, y)
            bbox.add(px, py)
          end
        end
        w, h = bbox.dimensions
        w && { "width" => w.round(1), "height" => h.round(1) }
      end

      def points_for(shape)
        case shape["Type"]
        when "Rect"
          w = Lbrn2.num(shape["W"]); h = Lbrn2.num(shape["H"])
          return [] if w.nil? || h.nil?

          [ [ -w / 2, -h / 2 ], [ w / 2, -h / 2 ], [ w / 2, h / 2 ], [ -w / 2, h / 2 ] ]
        when "Ellipse"
          rx = Lbrn2.num(shape["Rx"]); ry = Lbrn2.num(shape["Ry"])
          return [] if rx.nil? || ry.nil?

          [ [ -rx, -ry ], [ rx, ry ] ]
        when "Line", "Path"
          Lbrn2.vertices(shape)
        else
          []
        end
      end
    end
  end
end
```

- [ ] **Step 6: Run the tests to verify they pass**

```bash
bin/rails test test/services/maker/previews/lbrn_metadata_test.rb
```
Expected: PASS (all 7).

- [ ] **Step 7: Confirm the existing Lbrn2 tests still pass (BBox change is additive)**

```bash
bin/rails test test/services/maker/previews/lbrn2_test.rb
```
Expected: PASS (unchanged).

- [ ] **Step 8: Commit**

```bash
git add app/services/maker/previews/lbrn_metadata.rb app/services/maker/previews/lbrn2.rb test/services/maker/previews/lbrn_metadata_test.rb test/fixtures/files/laser-settings.lbrn2
git commit -m "feat(lbrn): LbrnMetadata parser (layers/settings/size/machine/text)"
```

---

## Task 3: `Lbrn2.render` returns `metadata:` (TDD)

**Files:**
- Test: `test/services/maker/previews/lbrn2_test.rb`
- Modify: `app/services/maker/previews/lbrn2.rb` (`render`)

- [ ] **Step 1: Write the failing tests**

Add to `test/services/maker/previews/lbrn2_test.rb` (inside the class):
```ruby
      test "render attaches parsed metadata alongside the image (geometry path)" do
        skip "resvg not installed on this box" unless Maker::Previews::Lbrn2.available?
        result = Maker::Previews::Lbrn2.render(@lbrn2, size: 256)
        assert_equal "image/png", result[:content_type]
        assert_kind_of Hash, result[:metadata]
        assert result[:metadata]["layers"].present?, "layers parsed from the fixture"
      end

      test "render attaches metadata even when the embedded thumbnail is used" do
        png_b64 = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAAC0lEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="
        xml = %(<LightBurnProject AppVersion="1.7.00"><Thumbnail Source="#{png_b64}"/>) +
              %(<CutSetting type="Cut"><index Value="0"/><speed Value="12"/><color Value="255"/></CutSetting>) +
              %(<Shape Type="Rect" CutIndex="0" W="5" H="5" XForm="1 0 0 1 0 0"/></LightBurnProject>)
        result = Maker::Previews::Lbrn2.render(xml, size: 512)
        assert_equal 1, result[:width], "embedded 1x1 PNG returned verbatim"
        assert_equal "1.7.00", result[:metadata]["app_version"], "metadata parsed from XML regardless of image path"
      end
```

- [ ] **Step 2: Run to verify failure**

```bash
bin/rails test test/services/maker/previews/lbrn2_test.rb -n "/attaches/"
```
Expected: FAIL — `result[:metadata]` is nil (render doesn't set it yet).

- [ ] **Step 3: Update `render`**

In `app/services/maker/previews/lbrn2.rb`, replace the `render` method with:
```ruby
      def render(lbrn2_bytes, size: 512)
        meta = Maker::Previews::LbrnMetadata.parse(lbrn2_bytes)
        img = Maker::Previews::EmbeddedThumbnail.extract(lbrn2_bytes) ||
              Maker::Previews::Svg.render(to_svg(lbrn2_bytes, size:), size:)
        img.merge(metadata: meta)
      end
```
(Keep the surrounding comment; the behaviour is the same image, now with `metadata:` merged in.)

- [ ] **Step 4: Run to verify pass**

```bash
bin/rails test test/services/maker/previews/lbrn2_test.rb
```
Expected: PASS (new + existing).

- [ ] **Step 5: Commit**

```bash
git add app/services/maker/previews/lbrn2.rb test/services/maker/previews/lbrn2_test.rb
git commit -m "feat(lbrn): Lbrn2.render returns parsed metadata alongside the image"
```

---

## Task 4: `GeneratePreviewJob` persists `metadata` (TDD)

**Files:**
- Test: `test/jobs/maker/generate_preview_job_test.rb`
- Modify: `app/jobs/maker/generate_preview_job.rb`

- [ ] **Step 1: Read the existing job test's setup**

Open `test/jobs/maker/generate_preview_job_test.rb` and note how it builds a user + a preview + backing bytes (reuse that exact style — do not invent a new harness). The new tests must follow the file's existing pattern for creating a node, a `Maker::Preview`, and making the file's bytes readable.

- [ ] **Step 2: Write the failing tests**

Add two tests (adapt the setup helpers/names to match the ones already in this file):
```ruby
      test "persists parsed metadata for a LightBurn file" do
        skip "resvg not installed on this box" unless Maker::Previews::Lbrn2.available?
        bytes = File.binread(Rails.root.join("test/fixtures/files/laser-settings.lbrn2"))
        preview = build_ready_preview_for("design.lbrn2", bytes)   # <- existing-style helper
        Maker::GeneratePreviewJob.new.perform(preview.id, filename: "design.lbrn2")
        preview.reload
        assert_equal "ready", preview.status
        assert preview.metadata.present?, "metadata stored"
        assert_equal "Fill", preview.metadata["layers"].last["mode"]
      end

      test "leaves metadata null for a non-LightBurn file" do
        preview = build_ready_preview_for("logo.svg", "<svg><rect width='1' height='1'/></svg>")
        Maker::GeneratePreviewJob.new.perform(preview.id, filename: "logo.svg")
        preview.reload
        assert_nil preview.metadata
      end
```
> If the file has no `build_ready_preview_for`-style helper, use the same inline construction the other tests in this file already use to make bytes readable and a preview row exist; the key assertions are the two `preview.metadata` checks.

- [ ] **Step 3: Run to verify failure**

```bash
bin/rails test test/jobs/maker/generate_preview_job_test.rb -n "/metadata/"
```
Expected: FAIL — `preview.metadata` is nil for the LightBurn file (job doesn't persist it yet).

- [ ] **Step 4: Persist it in the job**

In `app/jobs/maker/generate_preview_job.rb`, change the success `update!` (currently):
```ruby
        preview.update!(status: "ready", width: result[:width], height: result[:height], error: nil)
```
to:
```ruby
        preview.update!(status: "ready", width: result[:width], height: result[:height],
                        metadata: result[:metadata], error: nil)
```
(`result[:metadata]` is nil for every renderer except `Lbrn2`, so all other file types keep a null column — no behaviour change.)

- [ ] **Step 5: Run to verify pass**

```bash
bin/rails test test/jobs/maker/generate_preview_job_test.rb
```
Expected: PASS (new + existing).

- [ ] **Step 6: Commit**

```bash
git add app/jobs/maker/generate_preview_job.rb test/jobs/maker/generate_preview_job_test.rb
git commit -m "feat(lbrn): persist preview metadata in GeneratePreviewJob"
```

---

## Task 5: The Laser-settings panel + two-column layout (TDD)

**Files:**
- Test: `test/integration/web/files_flow_test.rb`
- Create: `app/views/files/_lbrn_settings.html.erb`
- Modify: `app/views/files/show.html.erb`
- Modify: `app/assets/stylesheets/application.css`

- [ ] **Step 1: Write the failing request tests**

Add to `test/integration/web/files_flow_test.rb` (inside the class; uses the file's `sign_in`/`upload` helpers):
```ruby
    test "a LightBurn file's detail page shows the laser-settings panel beside the preview" do
      user = sign_in
      bytes = File.binread(Rails.root.join("test/fixtures/files/laser-settings.lbrn2"))
      node_id = upload("cut.lbrn2", bytes)
      # Give the thumbnail preview parsed metadata directly (this test targets the VIEW, not the job).
      # find_or_create_by!: the upload's finalize may already have created the pending thumbnail
      # preview row (Previews::Enqueue), so a bare create! would hit the (user,node,version,kind)
      # uniqueness index.
      token = FileLayer.current.stat(user, node_id:).content_token
      preview = Maker::Preview.find_or_create_by!(user:, node_id:, version_id: token, kind: "thumbnail")
      preview.update!(status: "ready", metadata: Maker::Previews::LbrnMetadata.parse(bytes))

      get file_path(node_id)
      assert_response :success
      assert_select ".preview-row.has-settings"
      assert_select ".lbrn-settings"
      assert_select ".lbrn-settings table tbody tr", 2          # two used layers
      assert_select ".lbrn-settings", text: /C00/
      assert_select ".lbrn-settings", text: /Fill/               # Scan -> Fill
      assert_select ".lbrn-settings", text: /Ortur LM2/
    end

    test "a non-LightBurn thumbnail file shows no laser-settings panel" do
      user = sign_in
      node_id = upload("cad.step", "ISO-10303-21;".b)
      token = FileLayer.current.stat(user, node_id:).content_token
      Maker::Preview.find_or_create_by!(user:, node_id:, version_id: token, kind: "thumbnail")
                    .update!(status: "ready")   # no metadata -> no panel

      get file_path(node_id)
      assert_response :success
      assert_select ".lbrn-settings", count: 0
      assert_select ".has-settings", count: 0
    end
```

- [ ] **Step 2: Run to verify failure**

```bash
bin/rails test test/integration/web/files_flow_test.rb -n "/laser-settings/"
```
Expected: FAIL — no `.lbrn-settings` / `.preview-row.has-settings` in the markup yet.

- [ ] **Step 3: Create the panel partial**

Write `app/views/files/_lbrn_settings.html.erb`:
```erb
<%# LightBurn laser "recipe" panel, shown beside the preview on a .lbrn/.lbrn2 file page.
    `meta` is the parsed Hash from Maker::Previews::LbrnMetadata (string keys). Every field is
    optional — render only what's present. %>
<section class="lbrn-settings">
  <div class="lbrn-head">
    <h2>Laser settings</h2>
    <% if meta["app_version"].present? %><span class="muted">LightBurn <%= meta["app_version"] %></span><% end %>
  </div>

  <% if meta["layers"].present? %>
    <table class="lbrn-layers">
      <thead>
        <tr><th>Layer</th><th>Mode</th><th class="num">Speed</th><th class="num">Power</th><th class="num">Passes</th></tr>
      </thead>
      <tbody>
        <% meta["layers"].each do |layer| %>
          <tr>
            <td>
              <% if layer["color"].present? %><span class="lbrn-swatch" style="background: <%= layer["color"] %>"></span><% end %>
              <%= layer["name"].presence || "C#{layer["index"]}" %>
            </td>
            <td><%= layer["mode"] %></td>
            <td class="num"><%= "#{layer["speed"].to_i} mm/s" if layer["speed"] %></td>
            <td class="num">
              <% if layer["power_max"] %>
                <%= layer["power_max"].to_i %>%<% if layer["power_min"] && layer["power_min"] != layer["power_max"] %> <span class="muted">/ <%= layer["power_min"].to_i %>%</span><% end %>
              <% end %>
            </td>
            <td class="num"><%= layer["passes"] %></td>
          </tr>
        <% end %>
      </tbody>
    </table>
  <% end %>

  <dl class="lbrn-summary">
    <% if meta.dig("job", "width") %><dt>Job size</dt><dd><%= meta["job"]["width"] %> × <%= meta["job"]["height"] %> mm</dd><% end %>
    <% if meta["material_height"] %><dt>Material</dt><dd><%= meta["material_height"] %> mm</dd><% end %>
    <% if meta["machine"].present? %><dt>Machine</dt><dd><%= meta["machine"] %></dd><% end %>
    <% if meta["shape_count"] %><dt>Layers / shapes</dt><dd><%= Array(meta["layers"]).size %> / <%= meta["shape_count"] %></dd><% end %>
  </dl>

  <% if meta["text"].present? %>
    <p class="lbrn-text muted">Text: <%= meta["text"].map { |t| "“#{t}”" }.join(", ") %></p>
  <% end %>
</section>
```

- [ ] **Step 4: Wrap the preview + panel in `show.html.erb`**

In `app/views/files/show.html.erb`, the preview is a single `<div class="preview"> … </div>` block (the `@kind` branches). Wrap it so the panel sits beside it when the thumbnail has metadata. Replace the opening `<div class="preview">` line with:
```erb
<div class="preview-row<%= " has-settings" if @thumbnail&.metadata.present? %>">
  <div class="preview">
```
and, immediately AFTER the matching closing `</div>` of `.preview` (the one before `<section class="notes-panel">`), add:
```erb
  <% if @thumbnail&.metadata.present? %>
    <%= render "files/lbrn_settings", meta: @thumbnail.metadata %>
  <% end %>
</div>
```
Net: `.preview` is unchanged and always rendered once; a `.preview-row` wrapper (flex only when `has-settings`) now contains it plus, for lightburn files, the panel.

- [ ] **Step 5: Add the CSS**

Append to `app/assets/stylesheets/application.css`:
```css
/* --- LightBurn laser-settings panel (beside the preview on a .lbrn/.lbrn2 file page) --- */
.preview-row.has-settings { display: flex; gap: 20px; align-items: flex-start; flex-wrap: wrap; }
.preview-row.has-settings > .preview { flex: 1 1 46%; min-width: 240px; }
.preview-row.has-settings > .lbrn-settings { flex: 1 1 46%; min-width: 260px; }
.lbrn-settings { border: 1px solid var(--line); border-radius: 10px; padding: 14px 16px; }
.lbrn-head { display: flex; align-items: baseline; justify-content: space-between; margin-bottom: 10px; }
.lbrn-head h2 { margin: 0; font-size: 16px; }
.lbrn-layers { width: 100%; border-collapse: collapse; font-size: 13px; }
.lbrn-layers th { text-align: left; color: var(--muted); font-weight: 600; padding: 5px 6px; border-bottom: 1px solid var(--line); }
.lbrn-layers td { padding: 5px 6px; border-bottom: 1px solid var(--soft); }
.lbrn-layers .num { text-align: right; font-variant-numeric: tabular-nums; }
.lbrn-swatch { display: inline-block; width: 11px; height: 11px; border-radius: 2px; vertical-align: middle; margin-right: 7px; }
.lbrn-summary { display: grid; grid-template-columns: auto 1fr; gap: 4px 12px; margin: 12px 0 0; font-size: 13px; }
.lbrn-summary dt { color: var(--muted); }
.lbrn-summary dd { margin: 0; font-weight: 600; }
.lbrn-text { font-size: 12px; margin: 10px 0 0; }
```

- [ ] **Step 6: Run to verify pass**

```bash
bin/rails test test/integration/web/files_flow_test.rb -n "/laser-settings/"
```
Expected: PASS.

- [ ] **Step 7: Run the whole file-flow suite (no regressions)**

```bash
bin/rails test test/integration/web/files_flow_test.rb
```
Expected: green.

- [ ] **Step 8: Commit**

```bash
git add app/views/files/_lbrn_settings.html.erb app/views/files/show.html.erb app/assets/stylesheets/application.css test/integration/web/files_flow_test.rb
git commit -m "feat(lbrn): laser-settings panel beside the preview on the file page"
```

---

## Task 6: Backfill existing LightBurn previews (TDD)

**Files:**
- Test: `test/services/maker/previews/lbrn_backfill_test.rb`
- Create: `app/services/maker/previews/lbrn_backfill.rb`
- Create: `lib/tasks/previews.rake`

- [ ] **Step 1: Write the failing test**

Write `test/services/maker/previews/lbrn_backfill_test.rb`:
```ruby
require "test_helper"

module Maker
  module Previews
    class LbrnBackfillTest < ActiveJob::TestCase
      def user = @user ||= User.create!(email: "bf@example.com", password: "correct horse battery staple", confirmed_at: Time.current)

      def preview_for(name, metadata: nil, kind: "thumbnail", status: "ready")
        nid = "node-#{name}"
        user.nodes.find_or_create_by!(node_id: nid) { |n| n.name = name; n.kind = "file" }
        Maker::Preview.create!(user:, node_id: nid, version_id: "v1", kind:, status:, metadata:)
      end

      test "re-enqueues only lightburn previews missing metadata" do
        needs = preview_for("a.lbrn2", metadata: nil)
        preview_for("b.lbrn2", metadata: { "app_version" => "1.7" })  # already has it -> skip
        preview_for("c.svg", metadata: nil)                            # not lightburn -> skip

        assert_enqueued_jobs 1, only: Maker::GeneratePreviewJob do
          Maker::Previews::LbrnBackfill.call
        end
        assert_enqueued_with(job: Maker::GeneratePreviewJob, args: [ needs.id ])
      end
    end
  end
end
```

- [ ] **Step 2: Run to verify failure**

```bash
bin/rails test test/services/maker/previews/lbrn_backfill_test.rb
```
Expected: FAIL — `uninitialized constant Maker::Previews::LbrnBackfill`.

- [ ] **Step 3: Implement the backfill service**

Write `app/services/maker/previews/lbrn_backfill.rb`:
```ruby
module Maker
  module Previews
    # One-time backfill: re-render LightBurn thumbnail previews created before the `metadata`
    # column existed, so they gain the laser-settings panel without the user re-saving the file.
    # Idempotent (re-render is deterministic) and safe to run repeatedly.
    module LbrnBackfill
      module_function

      LBRN_EXTS = %w[.lbrn .lbrn2].freeze

      def call
        scope = Maker::Preview.where(kind: "thumbnail", status: "ready", metadata: nil)
        count = 0
        scope.find_each do |preview|
          name = preview.user.nodes.find_by(node_id: preview.node_id)&.name.to_s
          next unless LBRN_EXTS.include?(File.extname(name).downcase)

          Maker::GeneratePreviewJob.perform_later(preview.id)
          count += 1
        end
        count
      end
    end
  end
end
```

- [ ] **Step 4: Run to verify pass**

```bash
bin/rails test test/services/maker/previews/lbrn_backfill_test.rb
```
Expected: PASS.

- [ ] **Step 5: Add the thin rake task**

Write `lib/tasks/previews.rake`:
```ruby
namespace :previews do
  desc "Re-render LightBurn thumbnails missing laser-settings metadata"
  task backfill_lbrn: :environment do
    n = Maker::Previews::LbrnBackfill.call
    puts "Enqueued #{n} LightBurn preview(s) for metadata backfill."
  end
end
```

- [ ] **Step 6: Smoke-test the task loads**

```bash
bin/rails previews:backfill_lbrn
```
Expected: prints `Enqueued 0 LightBurn preview(s) for metadata backfill.` on a clean dev DB (no error).

- [ ] **Step 7: Commit**

```bash
git add app/services/maker/previews/lbrn_backfill.rb lib/tasks/previews.rake test/services/maker/previews/lbrn_backfill_test.rb
git commit -m "feat(lbrn): one-time backfill task for existing lightburn previews"
```

---

## Task 7: Verification (full suite on all three backends + manual)

**Files:** none.

- [ ] **Step 1: Full suite (chunk)**

```bash
bin/rails test
```
Expected: green.

- [ ] **Step 2: Share backend leg**

```bash
LIBRARY_BACKEND=share LIBRARY_PATH=$(mktemp -d) bin/rails test
```
Expected: green.

- [ ] **Step 3: S3 backend leg**

```bash
LIBRARY_BACKEND=s3 LIBRARY_S3_BUCKET=ci-not-a-real-bucket LIBRARY_S3_REGION=us-east-1 \
LIBRARY_S3_ACCESS_KEY_ID=ci LIBRARY_S3_SECRET_ACCESS_KEY=ci LIBRARY_S3_PREFIX=library bin/rails test
```
Expected: green.

- [ ] **Step 4: Manual browser check**

Start the app (`bin/rails server -p 3001`), upload a real `.lbrn2` (ideally a multi-layer LightBurn export, not just the fixture), open its file page, and confirm: the **Laser settings** panel renders to the right of the preview (stacking if you narrow the window); the layer table shows colour swatch + mode + speed + power + passes; the summary shows job size / machine / counts. Then open a non-lightburn file (e.g. a STEP or an image) and confirm there is **no** panel and its preview is unchanged.

- [ ] **Step 5: (If real-export attribute names differed) reconcile**

If the real `.lbrn2` shows blank fields the fixture didn't, inspect its XML (`unzip -p` is not needed — it's plain XML) and confirm the child/attr names for `speed`/`maxPower`/`numPasses`/`DeviceName`/text against `LbrnMetadata#val`/`#text_strings`. The parser already reads attr-or-child; only add a name if a real export uses one not covered. Add a regression test with that snippet if so.

- [ ] **Step 6: Final commit (only if Step 5 changed anything)**

```bash
git add -A && git commit -m "test(lbrn): reconcile parser with a real LightBurn export"
```

---

## Self-review notes

- **Spec coverage:** parser + metadata shape (Task 2), renderer integration incl. embedded-thumbnail path (Task 3), `metadata` JSON column + job persistence (Tasks 1, 4), two-column panel on the file page with only-present-fields rendering (Task 5), backfill rake task (Task 6), 3-backend verification (Task 7). "Only used layers" (Task 2 test), "no panel / unchanged for non-lightburn" (Tasks 4, 5 tests), graceful nil on malformed (Task 2 test) all covered.
- **Type/name consistency:** the metadata Hash keys (`app_version`, `machine`, `material_height`, `job.width/height`, `shape_count`, `text`, `layers[].{index,name,color,mode,speed,power_max,power_min,passes}`) are identical across the parser (Task 2), the partial (Task 5), and every test. `LbrnMetadata.parse`, `Lbrn2::BBox#dimensions`, `LbrnBackfill.call` are defined before use.
- **No placeholders:** every code/command step is complete. The one soft spot — the exact helper names in the existing `generate_preview_job_test.rb` — is called out in Task 4 Step 1 (read and match the file's own style) rather than invented.
