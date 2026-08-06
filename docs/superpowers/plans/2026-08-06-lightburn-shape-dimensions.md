# LightBurn Per-Shape Dimensions Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Click a contour in the `.lbrn2` file view and see its dimensions in mm.

**Architecture:** A new `"geometry"` preview kind flows through the existing `Maker::Previews`
pipeline — `Enqueue` → `GeneratePreviewJob` → `Lbrn2.render(kind: "geometry")` → a JSON payload
attached as the Preview's ActiveStorage asset and served from its blob URL. A Stimulus controller
fetches that payload behind a **Measure** button, builds an SVG in the DOM from the coordinates,
and lets the browser hit-test clicks.

**Tech Stack:** Rails 8, Nokogiri, Stimulus/Hotwire, ActiveStorage, Minitest.

**Spec:** [`docs/superpowers/specs/2026-08-06-lightburn-shape-dimensions-design.md`](../specs/2026-08-06-lightburn-shape-dimensions-design.md)

---

## Orientation for someone new to this codebase

Read these before starting. They are short and each one prevents a specific silent failure:

- **`CLAUDE.md` §14a, §14b, §15.** The project's invariants. §15's **mutation-check rule** is not
  optional here: after a guard goes green, break the thing it guards, confirm it goes red, restore.
  This repo's dominant failure mode is a green suite over something that never worked.
- **`app/services/maker/previews/lbrn2.rb`** header comment. The `.lbrn2` dialect LightBurn
  actually writes is not the obvious one; an earlier parser drew 1.0% of real shapes.
- **`test/fixtures/files/real-export.lbrn2`.** The reference dialect. Any new fixture copies its
  form. `sample.lbrn2` is hand-authored in a form LightBurn has never emitted — do not copy it.

**Running things:**

```bash
bin/rails test test/services/maker/previews/lbrn2_test.rb
```

```bash
bin/ci
```

`bin/ci` is the full gate (~40 s) and is what CI runs. The three test legs (`test`, `test-share`,
`test-s3`) must report **identical** counts.

---

## File Structure

| file | responsibility |
|---|---|
| `app/services/maker/previews/lbrn2.rb` | **modify** — `each_geometry` yields a 6th value; `render` gains `kind:` |
| `app/services/maker/previews/lbrn_geometry.rb` | **new** — builds the JSON payload: bboxes, decimation, circularity |
| `app/models/maker/preview.rb` | **modify** — `KINDS` gains `"geometry"` |
| `app/jobs/maker/generate_preview_job.rb` | **modify** — `asset_ext` gains `application/json` |
| `app/controllers/files_controller.rb` | **modify** — `#geometry` action; `preview_kind` gains `:lbrn` |
| `config/routes.rb` | **modify** — `get "geometry"` member route |
| `app/views/files/show.html.erb` | **modify** — the `:lbrn` preview branch |
| `app/javascript/controllers/lbrnmeasure_controller.js` | **new** — fetch/poll, draw, hit-test, readout, zoom |
| `app/assets/stylesheets/application.css` | **modify** — measure surface styles |
| `lib/tasks/lbrn.rake` | **new** — corpus geometry report (manual probe, not a gate) |
| `test/fixtures/files/bezier-circle.lbrn2` | **new** — 4-segment bezier circle + same-size square |
| `test/fixtures/files/text-backup-path.lbrn2` | **new** — Text + multi-contour `BackupPath` |
| `test/services/maker/previews/lbrn_geometry_test.rb` | **new** — payload unit tests |
| `test/integration/web/lbrn_geometry_test.rb` | **new** — endpoint, driven as real requests |
| `test/system/lbrn_measure_test.rb` | **new** — click a contour, assert the readout |

### Test conventions in this repo — verified, and NOT what you would guess

Checked against the tree, because the first draft of this plan guessed all four wrong:

- **Web/controller tests live in `test/integration/web/`**, not `test/controllers/` (which holds
  only `current_project_controller_test.rb`, `projects/`, `tools/`). They are
  `module Web; class XTest < ActionDispatch::IntegrationTest`.
- **There are NO Rails model fixtures.** `test/fixtures/` contains only `action_text/`, `addons/`
  and `files/`. There is no `users(:one)` — a test creates its own `User` and signs in.
- **Sign-in is a per-file helper**, not a shared one, and it uses the real password flow:
  ```ruby
  PASSWORD = "correct horse battery staple".freeze

  def sign_in(email = "web@example.com")
    user = User.find_by(email:) ||
           User.create!(email:, password: PASSWORD, confirmed_at: Time.current)
    post user_session_path, params: { user: { email:, password: PASSWORD } }
    user
  end
  ```
- **A test whose fixtures are backend-shaped must say so** with `pin_file_layer_backend("chunk")`
  in `setup` (31 of the 43 web tests do). `FileLayer.current` otherwise reads the ambient
  `LIBRARY_BACKEND`, so the share leg points a chunk-shaped test at the Share adapter and it fails
  looking for bytes on a disk that has none. That failure is the honest signal, not a bug.
  `files_flow_test.rb` also carries a chunk `upload(name, bytes)` helper mirroring the browser's
  two-phase presigned flow — copy it rather than reinventing it.

`LbrnGeometry` is a separate file from `Lbrn2` deliberately: `lbrn2.rb` is already 590 lines and
carries the parser's hard-won dialect knowledge. The payload builder is a different
responsibility — shaping already-parsed geometry for a client — and belongs beside it, not inside.

---

## Task 1: Fixtures in the real dialect

Two tests in this plan have nothing to run against today: no existing fixture has a
`<BackupPath>`, and none has a bezier-drawn circle. Author both **first**, and prove the parser
reads them before anything depends on them.

**Files:**
- Create: `test/fixtures/files/bezier-circle.lbrn2`
- Create: `test/fixtures/files/text-backup-path.lbrn2`
- Modify: `test/services/maker/previews/lbrn2_test.rb`

- [ ] **Step 1: Create `test/fixtures/files/bezier-circle.lbrn2`**

A circle of radius 10 centred at (0,0) as four cubic segments (`k = 0.5523 × r = 5.523`), plus a
20 × 20 square well clear of it. The circle's four vertices sit on the axes, so its bounding box is
exactly 20 × 20 — the same as the square's, which is the point: the square is the negative case for
circularity, and a `w == h` test cannot tell them apart.

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!-- Hand-authored, but in the dialect real LightBurn writes (see real-export.lbrn2):
     <XForm> is a CHILD element, <VertList> is "V<x> <y>c0x..c0y..c1x..c1y..", and
     <PrimList> carries "B<a> <b>" cubic segments (42 of the 58 real files use them).

     TWO SHAPES, ONE BOUNDING BOX EACH, BOTH 20 x 20 mm:
       circle  r=10 at (0,0)   -> x -10..10, y -10..10   MUST report d
       square  20x20 at (50,0) -> x  40..60, y -10..10   MUST NOT report d
     They are the same size on purpose. A w==h test passes both; the circularity test
     must separate them. The square is the assertion that carries the weight.
-->
<LightBurnProject AppVersion="1.6.00" FormatVersion="1" MaterialHeight="0">
    <CutSetting type="Cut">
        <index Value="0"/>
        <name Value="C00"/>
        <speed Value="20"/>
        <maxPower Value="80"/>
    </CutSetting>
    <Shape Type="Path" CutIndex="0" VertID="1" PrimID="1">
        <XForm>1 0 0 1 0 0</XForm>
        <VertList>V10 0c0x10c0y5.523c1x10c1y-5.523V0 10c0x-5.523c0y10c1x5.523c1y10V-10 0c0x-10c0y-5.523c1x-10c1y5.523V0 -10c0x5.523c0y-10c1x-5.523c1y-10</VertList>
        <PrimList>B0 1B1 2B2 3B3 0</PrimList>
    </Shape>
    <Shape Type="Rect" CutIndex="0" W="20" H="20" Cr="0">
        <XForm>1 0 0 1 50 0</XForm>
    </Shape>
</LightBurnProject>
```

- [ ] **Step 2: Create `test/fixtures/files/text-backup-path.lbrn2`**

`<BackupPath>` **must carry `Type="Path"`** — all 74 instances in the real corpus do, and without it
`emit_shape`'s `case shape["Type"]` matches no arm and the fixture silently emits nothing. The
`BackupPath`'s `<XForm>` is already in document space and composes with nothing (see the comment in
`walk_shapes`), so it is written as identity here.

Two disjoint square contours in one `BackupPath` stand in for two letters, **plus a Rect** — see
Task 2 Step 5 for why the second shape is load-bearing rather than decorative. It sits inside the
30 × 10 span so no span assertion changes. (`Lbrn2.apply` negates Y, so verify the placement rather
than trusting the arithmetic here.)

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!-- A Text and its rendered outline, in the real dialect. Three facts this pins:
       1. <BackupPath> carries Type="Path" (74/74 in the real corpus). Without it,
          emit_shape matches no arm and this fixture proves nothing while passing.
       2. A Text itself emits NO geometry — the BackupPath is the only outline.
       3. The BackupPath's PrimList yields TWO disjoint contours (two "letters"),
          which is what makes this the object-grouping fixture: both contours must
          share the Text's object id, so alt-click reports the whole word.
     Contours: A x 0..10 y 0..10, B x 20..30 y 0..10.  Object bbox: 30 x 10 mm.
-->
<LightBurnProject AppVersion="1.6.00" FormatVersion="1" MaterialHeight="0">
    <CutSetting type="Cut">
        <index Value="0"/>
        <name Value="C00"/>
        <speed Value="20"/>
        <maxPower Value="80"/>
    </CutSetting>
    <Shape Type="Text" CutIndex="0" Str="AB">
        <XForm>1 0 0 1 0 0</XForm>
        <BackupPath Type="Path" CutIndex="0" VertID="21" PrimID="21">
            <XForm>1 0 0 1 0 0</XForm>
            <VertList>V0 0c0x1c1x1V10 0c0x1c1x1V10 10c0x1c1x1V0 10c0x1c1x1V20 0c0x1c1x1V30 0c0x1c1x1V30 10c0x1c1x1V20 10c0x1c1x1</VertList>
            <PrimList>L0 1L1 2L2 3L3 0L4 5L5 6L6 7L7 4</PrimList>
        </BackupPath>
    </Shape>
    <Shape Type="Rect" CutIndex="0" W="6" H="6" Cr="0">
        <XForm>1 0 0 1 15 5</XForm>
    </Shape>
</LightBurnProject>
```

> The trailing Rect is **not decoration** — it is the second reference point that makes the object-id
> sequence observable, and without it Task 2's mutation check cannot fail. It sits inside the
> 30 × 10 span (x 12..18, y 2..8) so the span assertions below are unaffected. Add a line to the
> fixture's own header comment saying so, with that consequence named.

- [ ] **Step 3: Write the failing test that proves the parser reads both fixtures**

A fixture in the wrong dialect is this repo's recorded trap, so validate the fixtures themselves
before anything depends on them. Append to `test/services/maker/previews/lbrn2_test.rb`, inside the
existing test class:

```ruby
test "bezier-circle fixture parses as one closed circle and one closed square" do
  doc = Maker::Previews::Lbrn2.parse_document(fixture("bezier-circle.lbrn2"))
  shapes = []
  Maker::Previews::Lbrn2.each_geometry(doc) { |_c, pts, closed, *| shapes << [ pts, closed ] }

  assert_equal 2, shapes.length, "expected exactly the circle and the square"
  assert shapes.all? { |(_pts, closed)| closed }, "both contours must be closed"

  circle, square = shapes.sort_by { |(pts, _)| pts.map(&:first).min }
  assert_operator circle[0].length, :>=, 12, "a 4-segment bezier circle must flatten to >= 12 points"
  assert_equal 5, square[0].length, "a Rect emits 4 corners plus the closing point"

  # Both are 20 x 20 mm. That is the whole point of this fixture.
  [ circle, square ].each do |(pts, _)|
    xs = pts.map(&:first); ys = pts.map(&:last)
    assert_in_delta 20.0, xs.max - xs.min, 0.05
    assert_in_delta 20.0, ys.max - ys.min, 0.05
  end
end

test "text-backup-path fixture yields two contours from the BackupPath" do
  doc = Maker::Previews::Lbrn2.parse_document(fixture("text-backup-path.lbrn2"))
  contours = []
  Maker::Previews::Lbrn2.each_geometry(doc) { |_c, pts, *| contours << pts }

  assert_equal 3, contours.length,
               "the Text emits nothing; its BackupPath yields two contours, plus the Rect"

  all_x = contours.flatten(1).map(&:first)
  all_y = contours.flatten(1).map(&:last)
  # The Rect sits INSIDE the letters' span, so these are unchanged by its presence.
  # If they move, the Rect was placed wrong.
  assert_in_delta 30.0, all_x.max - all_x.min, 0.01, "the two letters span 30 mm"
  assert_in_delta 10.0, all_y.max - all_y.min, 0.01, "the two letters span 10 mm"
end
```

If `lbrn2_test.rb` has no `fixture` helper, add this private method to the class:

```ruby
private

def fixture(name) = File.binread(Rails.root.join("test/fixtures/files", name))
```

- [ ] **Step 4: Run the tests**

```bash
bin/rails test test/services/maker/previews/lbrn2_test.rb
```

Expected: **PASS**. These fixtures exercise the parser as it already is — nothing is being built
yet. A failure here means the fixture XML is in the wrong dialect, not that the parser is broken.
Fix the fixture, not the parser.

- [ ] **Step 5: Commit**

```bash
git add test/fixtures/files/bezier-circle.lbrn2 test/fixtures/files/text-backup-path.lbrn2 test/services/maker/previews/lbrn2_test.rb
git commit -m "test: lbrn2 fixtures for bezier circles and text BackupPaths"
```

---

## Task 2: `each_geometry` yields an object id

**Files:**
- Modify: `app/services/maker/previews/lbrn2.rb` (`each_geometry`, `walk_shapes`, `emit_shape`)
- Modify: `test/services/maker/previews/lbrn2_test.rb`

- [ ] **Step 1: Write the failing test**

Append to `test/services/maker/previews/lbrn2_test.rb`:

```ruby
test "each_geometry yields an object id that groups a Text with its BackupPath" do
  doc = Maker::Previews::Lbrn2.parse_document(fixture("text-backup-path.lbrn2"))
  ids = []
  Maker::Previews::Lbrn2.each_geometry(doc) { |_c, _p, _k, _e, _i, oid| ids << oid }

  # Document order: the Text's two BackupPath contours (the letters) yield first, then
  # the Rect placed beside them.
  assert_equal 3, ids.length

  # THE GROUPING CLAIM, checked POSITIONALLY rather than via a deduplicated count. A
  # count alone cannot tell "the two letters share one id, and the Rect gets its own"
  # apart from "the second letter collides with the Rect's id while the first is split
  # off alone" — both give ids.uniq.length == 2. That second, WRONG shape is exactly
  # what a per-contour-id mutation produced here, undetected, until this was asserted
  # positionally: [1, 2, 2] has 2 unique values and is dense from 1, same as the correct
  # [1, 1, 2], so neither an aggregate count nor a density check catches it.
  assert_equal ids[0], ids[1],
               "both BackupPath contours belong to ONE object (the Text), so alt-click reports the whole word"
  assert_not_equal ids[0], ids[2], "the Rect beside the Text must be a different object"

  # THE ASSERTION THAT CATCHES THE ORIGINAL BUG, and the reason the Rect is in this
  # fixture at all. A Text yields no geometry of its own, so its counter tick is
  # observable ONLY through the BackupPath reusing it. Give the BackupPath a fresh id
  # instead and the Text's tick is burned unobserved, leaving a GAP: the ids become
  # [2, 2, 3] rather than [1, 1, 2]. With only one Shape in the fixture, both behaviours
  # look like "two the same" and nothing could tell them apart — which is why the Rect
  # had to be added at all.
  assert_equal (1..ids.uniq.length).to_a, ids.uniq.sort,
               "object ids must be dense from 1 — a gap means a tick was burned on an unyielded shape"
end

test "each_geometry gives separate shapes separate object ids, and Groups consume none" do
  doc = Maker::Previews::Lbrn2.parse_document(fixture("real-export.lbrn2"))
  ids = []
  Maker::Previews::Lbrn2.each_geometry(doc) { |_c, _p, _k, _e, _i, oid| ids << oid }

  # real-export.lbrn2: a Rect, two Paths (one an instance), and a Group holding one Path.
  # The Group emits nothing itself, so four drawable shapes -> four distinct ids.
  assert_equal 4, ids.length
  assert_equal 4, ids.uniq.length, "each non-Group Shape gets its own object id"
end

test "the existing callers are unaffected by the new yielded value" do
  %w[real-export.lbrn2 sample.lbrn2 laser-settings.lbrn2].each do |name|
    bytes = fixture(name)
    doc = Maker::Previews::Lbrn2.parse_document(bytes)
    # job_size destructures 4 params, to_svg 5. Ruby block arity is lenient, so a 6th
    # value must change neither. This is CLAUDE.md's one-traversal rule, asserted.
    assert Maker::Previews::Lbrn2.job_size(doc), "#{name} must still report a job size"
    assert_match(/<svg/, Maker::Previews::Lbrn2.to_svg(bytes), "#{name} must still render SVG")
  end
end
```

- [ ] **Step 2: Run to verify it fails**

```bash
bin/rails test test/services/maker/previews/lbrn2_test.rb -n "/object id/"
```

Expected: **FAIL** — `ids` is `[nil, nil]`, so `assert_equal 1, ids.uniq.length` passes by accident
on the first test but `assert_equal 4, ids.uniq.length` fails on the second with
`Expected: 4, Actual: 1`.

- [ ] **Step 3: Implement**

In `app/services/maker/previews/lbrn2.rb`, replace `each_geometry`:

```ruby
      # THE one traversal, shared with LbrnMetadata so the thumbnail and the reported job size
      # can never disagree. Yields every drawable leaf as
      #   (cut_index, [[x, y], ...], closed?, ellipse_or_nil, image_or_nil, object_id)
      # with the points already transformed into SVG space (composed affine, then Y-flipped).
      #
      # The last three are RICHER RENDERINGS OF THE SAME POINTS, never a substitute for them: a
      # measuring caller (`job_size`) reads only the points and is correct ignoring all of them,
      # which is what lets an ellipse stay exact, a bitmap show its photo, and a measuring client
      # group contours by object without any of them changing what the file measures.
      #
      # `object_id` counts NON-GROUP `<Shape>` elements in document order. A Group emits nothing
      # of its own — walk_shapes recurses into <Children> and `next`s — so it consumes no id, which
      # is what keeps a group transparent to measurement exactly as it is to drawing. A Text's
      # <BackupPath> deliberately REUSES its parent Text's id: the outline IS the text, so
      # alt-clicking one letter must report the whole word rather than one contour of it.
      def each_geometry(doc, &block)
        return if doc.root.nil?

        walk_shapes(doc.root, IDENTITY, GeometryIndex.new(doc), hidden_cuts(doc), Counter.new, &block)
      end

      # A mutable counter threaded through the recursive walk. A plain Integer would be copied
      # into each recursive frame, so a Group's children would restart the numbering and two
      # different shapes could share an id.
      class Counter
        def initialize = @n = 0
        def succ! = (@n += 1)
      end
```

Replace `walk_shapes` (only the signature, the `emit_shape` calls, and the recursion change):

```ruby
      def walk_shapes(parent, parent_xform, index, hidden, counter, &block)
        parent.xpath("./Shape").each do |shape|
          world = compose(parent_xform, shape_xform(shape))

          if shape["Type"] == "Group"
            kids = shape.at_xpath("./Children")
            walk_shapes(kids, world, index, hidden, counter, &block) if kids
            next
          end

          # Before the BackupPath below, so hiding a Text hides its outline too.
          next if hidden.include?(cut_key(shape["Type"], shape["CutIndex"]))

          object_id = counter.succ!
          emit_shape(shape, world, index, object_id, &block)

          # A Text stores its rendered outline in `<BackupPath>`. Three things about it:
          #
          # It is NOT a `<Shape>`, so a `//Shape` sweep never sees text at all — all 74 Text
          # shapes in this corpus contributed nothing to any bounding box.
          #
          # Its `<XForm>` is already in DOCUMENT space: it composes with nothing, not the
          # Text's own transform and not the groups around it. 64 of the 74 write the very
          # same matrix as their Text, so composing the pair doubles the translation — that
          # is what threw "Polster Library" clean off its sign. The other 10 settle what the
          # value actually is: in logo.lbrn2 a Text at (99.216, -127.493) sits inside a group
          # scaled 0.825 at (249.244, 245.2), and 0.825 * 99.216 + 249.244 = 331.09 is
          # exactly the BackupPath's own e — it is group ∘ text, already flattened.
          #
          # And it shares its Text's object_id rather than taking a new one, because the
          # outline IS the text. Give it its own and alt-clicking a letter reports that
          # letter's contour instead of the word.
          bp = shape.at_xpath("./BackupPath")
          emit_shape(bp, shape_xform(bp), index, object_id, &block) if bp
        end
      end
```

Replace `emit_shape`'s signature and its four `yield`s:

```ruby
      def emit_shape(shape, world, index, object_id)
        cut = shape["CutIndex"]

        case shape["Type"]
        when "Rect", "Bitmap"
          # Both are centered on the XForm origin and sized by W/H.
          w = num(shape["W"]); h = num(shape["H"])
          return if w.nil? || h.nil?

          corners = [ [ -w / 2, -h / 2 ], [ w / 2, -h / 2 ], [ w / 2, h / 2 ], [ -w / 2, h / 2 ] ]
          pts = corners.map { |(x, y)| apply(world, x, y) }
          image = shape["Type"] == "Bitmap" ? bitmap_image(shape, world, pts) : nil
          yield cut, pts + [ pts.first ], true, nil, image, object_id
        when "Ellipse"
          rx = num(shape["Rx"]); ry = num(shape["Ry"])
          return if rx.nil? || ry.nil?

          # Sampled rather than emitted straight as cx/rx: a real XForm carries scale AND
          # rotation (0.866 -0.5 0.5 0.866 = 30°, seen on this corpus), and neither survives
          # `apply(xform, 0, 0)` + raw Rx/Ry. When the transform turns out to be axis-aligned
          # the samples collapse back to an exact <ellipse>; otherwise they stay a polygon.
          pts = (0...ELLIPSE_SAMPLES).map do |i|
            t = i * (2 * Math::PI / ELLIPSE_SAMPLES)
            apply(world, rx * Math.cos(t), ry * Math.sin(t))
          end
          yield cut, pts + [ pts.first ], true, (axis_aligned?(world) ? ellipse_from(pts) : nil), nil, object_id
        when "Path", "Line"
          verts, prims = index.geometry_for(shape)
          polylines(verts, prims).each do |pts, closed|
            yield cut, pts.map { |(x, y)| apply(world, x, y) }, closed, nil, nil, object_id
          end
        end
      end
```

> Note the `Ellipse` arm previously yielded only five values (its `image` was implicit `nil`).
> It now yields six explicitly. The `Path`/`Line` arm likewise gains an explicit `nil` image.

- [ ] **Step 4: Run the tests**

```bash
bin/rails test test/services/maker/previews/lbrn2_test.rb
```

Expected: **PASS**, including the pre-existing tests in that file.

- [ ] **Step 5: Mutation-check the grouping guard**

> **Corrected during execution.** The obvious assertion here — "both contours share one id" — is
> one this mutation **cannot** fail, and the first run through this task proved it. With a single
> `<Shape>` in the fixture, both BackupPath contours come from ONE `emit_shape` call and share
> whatever id is passed, so a fresh id changes *which* id is shared, not *whether* it is. The Text
> itself yields no geometry, so there is no second reference point. That is a guard unable to fail
> for the reason it exists — this repo's recorded failure shape, reached by following the plan.
>
> The fix is a **second shape in the fixture**, which makes the Text's counter tick observable: it
> is *used* only if the BackupPath reuses it, so a fresh id leaves a **gap** in the id sequence.

Temporarily change the `BackupPath` line in `walk_shapes` to take a fresh id:

```ruby
          emit_shape(bp, shape_xform(bp), index, counter.succ!, &block) if bp
```

```bash
bin/rails test test/services/maker/previews/lbrn2_test.rb -n "/groups a Text/"
```

Expected: **FAIL** on the density assertion — the ids become `[2, 2, 3]` rather than `[1, 1, 2]`.

```
correct:  Text ticks 1 (yields nothing) → BackupPath reuses 1 (×2) → Rect ticks 2  → [1,1,2] dense
mutated:  Text ticks 1 (yields nothing) → BackupPath ticks 2  (×2) → Rect ticks 3  → [2,2,3] gap
```

Then **restore the original line** and re-run to confirm green.

**Run the second mutation too** — increment the id per-contour inside `emit_shape`'s `Path` arm.
It must go red on the **positional** assertion, not the density one.

> This is where a third gap turned up during execution, and it is worth reading before trusting any
> aggregate assertion in this file. Once the Rect existed, the per-contour mutation produced ids
> `[1, 2, 2]` — the second letter colliding with the Rect's id while the first was split off alone.
> That has two unique values and is dense from 1, **exactly like the correct `[1, 1, 2]`**, so both
> `uniq.length` and the density check stayed green over a plainly wrong grouping. Only a positional
> comparison separates them. Each mutation now fails a different, correctly-targeted assertion.

- [ ] **Step 6: Commit**

```bash
git add app/services/maker/previews/lbrn2.rb test/services/maker/previews/lbrn2_test.rb
git commit -m "feat(lbrn2): yield an object id from each_geometry"
```

---

## Task 3: `LbrnGeometry` — the payload, with the union guard

**Files:**
- Create: `app/services/maker/previews/lbrn_geometry.rb`
- Create: `test/services/maker/previews/lbrn_geometry_test.rb`

- [ ] **Step 1: Write the failing test**

```ruby
require "test_helper"

module Maker
  module Previews
    class LbrnGeometryTest < ActiveSupport::TestCase
      test "build returns a versioned payload with one entry per contour" do
        payload = build("real-export.lbrn2")

        assert_equal 1, payload["v"]
        assert_equal 4, payload["shapes"].length
        payload["shapes"].each do |s|
          assert s["b"].is_a?(Array) && s["b"].length == 4, "every contour carries a bbox"
          assert s["p"].is_a?(Array) && s["p"].length >= 2, "every contour carries drawing points"
          assert_includes [ 0, 1 ], s["k"]
          assert_kind_of Integer, s["o"]
        end
      end

      # THE GUARD THAT MATTERS. It ties the payload to the size the Laser Settings panel
      # already reports, so nobody can optimise the walk for one caller without this going red.
      # job_size rounds to 1dp and the payload carries 2, so round ONCE then demand equality —
      # a tolerance band would let a real divergence hide inside it.
      test "the payload's bboxes union to exactly job_size" do
        %w[real-export.lbrn2 sample.lbrn2 laser-settings.lbrn2 bezier-circle.lbrn2
           text-backup-path.lbrn2].each do |name|
          doc = Lbrn2.parse_document(fixture(name))
          expected = Lbrn2.job_size(doc)
          next if expected.nil?

          boxes = build(name)["shapes"].map { |s| s["b"] }
          w = boxes.map { |b| b[2] }.max - boxes.map { |b| b[0] }.min
          h = boxes.map { |b| b[3] }.max - boxes.map { |b| b[1] }.min

          assert_equal expected["width"],  w.round(1), "#{name}: payload width disagrees with job_size"
          assert_equal expected["height"], h.round(1), "#{name}: payload height disagrees with job_size"
        end
      end

      test "job carries the document bbox and its origin" do
        payload = build("real-export.lbrn2")
        job = payload["job"]

        assert_in_delta 110.0, job["w"], 0.01
        assert_in_delta 110.0, job["h"], 0.01
        assert job.key?("x") && job.key?("y"), "the client needs an origin for its viewBox"
      end

      test "render returns JSON bytes the job can attach" do
        result = LbrnGeometry.render(fixture("real-export.lbrn2"))

        assert_equal "application/json", result[:content_type]
        assert result[:bytes].bytesize.positive?
        assert_equal 4, JSON.parse(result[:bytes])["shapes"].length
      end

      private

      def fixture(name) = File.binread(Rails.root.join("test/fixtures/files", name))

      def build(name) = JSON.parse(LbrnGeometry.render(fixture(name))[:bytes])
    end
  end
end
```

- [ ] **Step 2: Run to verify it fails**

```bash
bin/rails test test/services/maker/previews/lbrn_geometry_test.rb
```

Expected: **FAIL** with `NameError: uninitialized constant Maker::Previews::LbrnGeometry`.

- [ ] **Step 3: Implement**

Create `app/services/maker/previews/lbrn_geometry.rb`:

```ruby
require "json"

module Maker
  module Previews
    # LightBurn (.lbrn/.lbrn2) -> a compact geometry payload for the browser's Measure view.
    #
    # This is the SECOND artifact derived from one .lbrn2, alongside the thumbnail: same file,
    # same traversal, different shape. It exists because a measuring client needs coordinates and
    # the thumbnail is a PNG — LightBurn's own embedded render, which has no mapping back to mm.
    #
    # BUILT ON `Lbrn2.each_geometry`, NEVER ON A PRIVATE WALK. That is CLAUDE.md's one-traversal
    # rule and it is not stylistic: `LbrnMetadata` once kept a second copy of this traversal and
    # independently inherited every dialect bug the parser had, so a file could render one way and
    # report a size computed from different geometry with nothing to catch it. The test asserting
    # this payload's bboxes union to `Lbrn2.job_size` is what keeps the two tied together.
    module LbrnGeometry
      module_function

      SCHEMA_VERSION = 1

      # Contours at or below this ship every point. Above it they are thinned (DECIMATE_STRIDE).
      #
      # All the savings live in big contours — bookmark.lbrn2 averages 278 points each — and the
      # floor is what stops a 12-point circle degenerating into a triangle. Measured over the 58
      # real exports: thinning above this cuts the worst file from 734 KB to 281 KB gzipped.
      DECIMATE_ABOVE = 32
      DECIMATE_STRIDE = 3

      # Circularity, for the readout's diameter. THREE conditions, and the point count is the one
      # most likely to be trimmed as redundant — it is not. A square's four corners are all
      # equidistant from its centre (so are any regular polygon's vertices), so the radius test
      # ALONE calls every square round. A Rect emits 5 points, a bezier circle 49, an Ellipse 33.
      # Accepted: a genuine 16-gon reports as round. It is that many mm across either way.
      MIN_CIRCLE_POINTS = 12
      CIRCLE_TOLERANCE = 0.02

      # mm, to 0.01.
      PRECISION = 2

      # Returns { bytes:, content_type: } — the shape GeneratePreviewJob attaches.
      def render(lbrn2_bytes)
        doc = Lbrn2.parse_document(lbrn2_bytes)
        { bytes: JSON.generate(build(doc)), content_type: "application/json" }
      end

      def build(doc)
        shapes = []
        min_x = min_y = Float::INFINITY
        max_x = max_y = -Float::INFINITY

        Lbrn2.each_geometry(doc) do |cut, points, closed, _ellipse, image, object_id|
          next if points.length < 2

          xs = points.map(&:first)
          ys = points.map(&:last)
          x0, y0, x1, y1 = xs.min, ys.min, xs.max, ys.max
          min_x = x0 if x0 < min_x
          min_y = y0 if y0 < min_y
          max_x = x1 if x1 > max_x
          max_y = y1 if y1 > max_y

          entry = {
            "o" => object_id,
            "c" => cut,
            "b" => [ x0, y0, x1, y1 ].map { |v| v.round(PRECISION) },
            "k" => closed ? 1 : 0,
            "i" => image ? 1 : 0,
            "p" => decimate(points).map { |(x, y)| [ x.round(PRECISION), y.round(PRECISION) ] }
          }
          # EVERY MEASUREMENT COMES FROM THE FULL-RESOLUTION POINTS, above and here. Decimation
          # is a drawing concession; it must never move a reported number. An implementation that
          # thins first and measures after passes any "does it draw" test while silently
          # under-reporting every curve.
          d = diameter(points, closed, x0, y0, x1, y1)
          entry["d"] = d.round(PRECISION) if d

          shapes << entry
        end

        {
          "v" => SCHEMA_VERSION,
          "job" => job_box(min_x, min_y, max_x, max_y),
          "shapes" => shapes
        }
      end

      def job_box(min_x, min_y, max_x, max_y)
        return { "w" => 0.0, "h" => 0.0, "x" => 0.0, "y" => 0.0 } if min_x == Float::INFINITY

        { "w" => (max_x - min_x).round(PRECISION), "h" => (max_y - min_y).round(PRECISION),
          "x" => min_x.round(PRECISION), "y" => min_y.round(PRECISION) }
      end

      # Every DECIMATE_STRIDE-th point, always keeping the last so a closed contour still closes.
      def decimate(points)
        return points if points.length <= DECIMATE_ABOVE

        out = points.each_slice(DECIMATE_STRIDE).map(&:first)
        out << points.last unless out.last == points.last
        out
      end

      # The contour's diameter in mm when it is round, else nil. See MIN_CIRCLE_POINTS.
      #
      # Measured from the BBOX CENTRE, not the centroid. A closed contour repeats its first point
      # as its last, so a centroid is pulled toward that vertex by one duplicate — small, but it
      # is a bias with no reason to exist when the bbox centre is exact for any symmetric shape.
      def diameter(points, closed, x0, y0, x1, y1)
        return nil unless closed && points.length >= MIN_CIRCLE_POINTS

        width = x1 - x0
        height = y1 - y0
        return nil if width <= 0 || height <= 0

        cx = (x0 + x1) / 2.0
        cy = (y0 + y1) / 2.0
        radii = points.map { |(x, y)| Math.hypot(x - cx, y - cy) }
        mean = radii.sum / radii.length
        return nil if mean <= 0
        return nil if radii.any? { |r| ((r - mean) / mean).abs > CIRCLE_TOLERANCE }

        (width + height) / 2.0
      end
    end
  end
end
```

- [ ] **Step 4: Run the tests**

```bash
bin/rails test test/services/maker/previews/lbrn_geometry_test.rb
```

Expected: **PASS**, all four.

- [ ] **Step 5: Mutation-check the union guard**

Temporarily make `build` compute the bbox from decimated points:

```ruby
          xs = decimate(points).map(&:first)
          ys = decimate(points).map(&:last)
```

```bash
bin/rails test test/services/maker/previews/lbrn_geometry_test.rb -n "/union to exactly/"
```

> **Corrected during execution — this mutation does NOT fail, and the reason is worth more than
> the gap.** `Lbrn2::BEZIER_SAMPLES` is 12 and `DECIMATE_STRIDE` is 3, and **12 % 3 == 0**, so
> every original LightBurn vertex lands on a kept index (0, 12, 24, 36, 48 on the circle — all
> multiples of 3). Decimation drops only *intermediate curve samples*, never a vertex, so the
> circle's bbox is byte-identical either way. The other fixtures hide it differently: their
> 33-point Ellipse *does* shrink in isolation, but a co-located Rect already bounds the job union
> in every affected dimension.
>
> That coupling is a genuinely good property — it is why measurement is safe and why the drawing
> keeps its corners — but it spans two constants in two files and breaks silently if either moves.
> So it gets **asserted directly** rather than relied on:
>
> ```ruby
> assert_equal 0, Maker::Previews::Lbrn2::BEZIER_SAMPLES % LbrnGeometry::DECIMATE_STRIDE
> ```
>
> plus a per-contour check that every original vertex survives `decimate`. Mutation: set
> `DECIMATE_STRIDE = 5`, confirm red, restore.
>
> The union guard still earns its place — it ties the payload to `job_size` — but a **per-shape**
> decimation test on a fixture whose ellipse is not shadowed by a Rect (`laser-settings.lbrn2`) is
> what actually catches a measure-after-thinning bug. Both are in the suite.

- [ ] **Step 6: Commit**

```bash
git add app/services/maker/previews/lbrn_geometry.rb test/services/maker/previews/lbrn_geometry_test.rb
git commit -m "feat(lbrn2): geometry payload builder tied to job_size"
```

---

## Task 4: Decimation and circularity, asserted in both directions

Task 3 implemented both; this task proves they carry weight. Splitting it keeps each guard's
mutation check honest — a test written in the same breath as its implementation tends to assert
what the code does rather than what it should do.

**Files:**
- Modify: `test/services/maker/previews/lbrn_geometry_test.rb`

- [ ] **Step 1: Write the failing tests**

Insert before the `private` section:

```ruby
test "decimation thins big contours but never moves a reported bbox" do
  doc = Lbrn2.parse_document(fixture("bezier-circle.lbrn2"))
  full = {}
  Lbrn2.each_geometry(doc) do |_c, points, _k, _e, _i, oid|
    xs = points.map(&:first); ys = points.map(&:last)
    full[oid] = [ xs.min, ys.min, xs.max, ys.max ].map { |v| v.round(2) }
  end

  build("bezier-circle.lbrn2")["shapes"].each do |s|
    assert_equal full[s["o"]], s["b"], "the reported bbox must equal the FULL-resolution bbox"

    # And the thinned drawing points must all fall inside it.
    s["p"].each do |(x, y)|
      assert_operator x, :>=, s["b"][0] - 0.01
      assert_operator y, :>=, s["b"][1] - 0.01
      assert_operator x, :<=, s["b"][2] + 0.01
      assert_operator y, :<=, s["b"][3] + 0.01
    end
  end
end

test "a contour above the threshold is actually thinned, and a small one is left alone" do
  shapes = build("bezier-circle.lbrn2")["shapes"]
  doc = Lbrn2.parse_document(fixture("bezier-circle.lbrn2"))
  counts = {}
  Lbrn2.each_geometry(doc) { |_c, points, _k, _e, _i, oid| counts[oid] = points.length }

  big = shapes.find { |s| counts[s["o"]] > Maker::Previews::LbrnGeometry::DECIMATE_ABOVE }
  small = shapes.find { |s| counts[s["o"]] <= Maker::Previews::LbrnGeometry::DECIMATE_ABOVE }

  assert big,   "the bezier circle should exceed the threshold"
  assert small, "the 5-point square should not"
  assert_operator big["p"].length, :<, counts[big["o"]], "a big contour must be thinned"
  assert_equal counts[small["o"]], small["p"].length,    "a small contour must be untouched"
end

# BOTH DIRECTIONS. Asserting only that the circle is round still passes with the tolerance
# loosened to 50% — the square is the assertion that carries the weight.
test "a bezier circle reports a diameter and a same-sized square does not" do
  shapes = build("bezier-circle.lbrn2")["shapes"].sort_by { |s| s["b"][0] }
  circle, square = shapes

  assert_in_delta 20.0, circle["d"], 0.05, "the circle must report d"
  assert_nil square["d"], "a 20x20 square is NOT round, however equidistant its corners are"

  # They are deliberately the same size, so w==h cannot be what separated them.
  assert_in_delta circle["b"][2] - circle["b"][0], square["b"][2] - square["b"][0], 0.05
end

test "an open contour never reports a diameter" do
  # real-export.lbrn2's Path #7 is L0 1L1 2 — open.
  assert build("real-export.lbrn2")["shapes"].any? { |s| s["k"].zero? }, "fixture must have an open contour"
  build("real-export.lbrn2")["shapes"].each do |s|
    assert_nil s["d"], "an open contour has no diameter" if s["k"].zero?
  end
end
```

- [ ] **Step 2: Run them**

```bash
bin/rails test test/services/maker/previews/lbrn_geometry_test.rb
```

Expected: **PASS** — Task 3 already implemented the behaviour. If any fail, the implementation is
wrong, not the test.

- [ ] **Step 3: Mutation-check circularity — the point-count floor**

Temporarily set `MIN_CIRCLE_POINTS = 4`:

```bash
bin/rails test test/services/maker/previews/lbrn_geometry_test.rb -n "/square does not/"
```

Expected: **FAIL** — `assert_nil square["d"]` reports `20.0`, because the square's four corners are
equidistant from its centre. This is the defect the floor exists to prevent. **Restore to 12.**

- [ ] **Step 4: Mutation-check circularity — the tolerance**

Temporarily set `CIRCLE_TOLERANCE = 0.5`:

```bash
bin/rails test test/services/maker/previews/lbrn_geometry_test.rb -n "/square does not/"
```

Expected: **PASS** — and that is the point. A 50% tolerance is obviously wrong yet this test stays
green, because the point-count floor is doing the work. It demonstrates why the assertion needed
both directions *and* why one mutation is not proof. **Restore to 0.02.**

> **Corrected during execution: the tolerance was completely unguarded.** Set to `1_000_000` and
> all eight tests stayed green. Closed with an inline-XML `<Shape Type="Ellipse" Rx="10" Ry="9">`
> — LightBurn's own Ellipse path, so no hand-rolled bezier maths and no new fixture file. Its
> radius varies ~5.5% about the bbox centre: round enough to be a plausible candidate, outside the
> 2% tolerance. At 0.02 it reports no `d`; at 0.5 it reports `d = 19.0`. That is now test 9, and it
> is the only thing standing between `CIRCLE_TOLERANCE` and any value at all.

- [ ] **Step 5: Commit**

```bash
git add test/services/maker/previews/lbrn_geometry_test.rb
git commit -m "test(lbrn2): pin decimation invariance and both-directions circularity"
```

---

## Task 5: Wire the `geometry` kind into the preview pipeline

**Files:**
- Modify: `app/models/maker/preview.rb:12`
- Modify: `app/jobs/maker/generate_preview_job.rb` (`asset_ext`)
- Modify: `app/services/maker/previews/lbrn2.rb` (`render`)
- Modify: `test/services/maker/previews/lbrn2_test.rb`

- [ ] **Step 1: Write the failing test**

Append to `test/services/maker/previews/lbrn2_test.rb`:

```ruby
test "render(kind: geometry) returns the JSON payload" do
  result = Maker::Previews::Lbrn2.render(fixture("real-export.lbrn2"), kind: "geometry")

  assert_equal "application/json", result[:content_type]
  assert_equal 4, JSON.parse(result[:bytes])["shapes"].length
end

test "render defaults to the thumbnail and is unchanged by the new kwarg" do
  result = Maker::Previews::Lbrn2.render(fixture("real-export.lbrn2"))

  assert_equal "image/png", result[:content_type]
  assert result[:metadata].present?, "the thumbnail path still carries LbrnMetadata"
end

test "geometry is an accepted preview kind and json maps to a .json asset" do
  assert_includes Maker::Preview::KINDS, "geometry"
  assert_equal ".json", Maker::GeneratePreviewJob.new.send(:asset_ext, "application/json")
end
```

- [ ] **Step 2: Run to verify it fails**

```bash
bin/rails test test/services/maker/previews/lbrn2_test.rb -n "/geometry/"
```

Expected: **FAIL** — `ArgumentError: unknown keyword: :kind`.

- [ ] **Step 3: Implement — `Preview::KINDS`**

In `app/models/maker/preview.rb`:

```ruby
    # `geometry` is a JSON payload, not an image — the coordinates behind the .lbrn2 Measure view.
    # It is the FIRST kind to exercise the kind seam end to end: `model_glb` is declared here but
    # refused by Mesh, so nothing in production produced a second artifact until this one.
    KINDS = %w[thumbnail model_glb render geometry].freeze
```

- [ ] **Step 4: Implement — `asset_ext`**

In `app/jobs/maker/generate_preview_job.rb`:

```ruby
    def asset_ext(content_type)
      case content_type
      when "image/svg+xml"     then ".svg"
      when "image/png"         then ".png"
      when "image/jpeg"        then ".jpg"
      when "model/gltf-binary" then ".glb"
      when "application/json"  then ".json"
      else ".bin"
      end
    end
```

- [ ] **Step 5: Implement — `Lbrn2.render`**

Replace `render` in `app/services/maker/previews/lbrn2.rb`:

```ruby
      # Embedded thumbnail FIRST — a LightBurn file carries its own full-colour render in a
      # <Thumbnail Source="base64png"> attribute, which is far better than re-drawing the geometry
      # as outlines. Fall back to the hand-rolled geometry parser (-> SVG -> PNG) only when a file
      # has no embedded thumbnail (older LightBurn versions, or a hand-authored file).
      #
      # `kind` selects the ARTIFACT, mirroring Mesh's branch. "geometry" is a JSON payload of
      # coordinates for the browser's Measure view — deliberately NOT an image, which is why
      # RendererContractTest still passes: that test never passes `kind`, so it exercises the
      # thumbnail path and its "must be an inline-safe raster" assertion stays true of it.
      def render(lbrn2_bytes, size: 512, kind: "thumbnail")
        return Maker::Previews::LbrnGeometry.render(lbrn2_bytes) if kind == "geometry"

        meta = Maker::Previews::LbrnMetadata.parse(lbrn2_bytes)
        img = Maker::Previews::EmbeddedThumbnail.extract(lbrn2_bytes) ||
              Maker::Previews::Svg.render(to_svg(lbrn2_bytes, size:), size:)
        img.merge(metadata: meta)
      end
```

- [ ] **Step 6: Run the full preview suite**

```bash
bin/rails test test/services/maker/previews/
```

Expected: **PASS**, including `renderer_contract_test.rb` — its `render_with` never passes `kind:`,
so `Lbrn2` still returns a PNG for it.

- [ ] **Step 7: Commit**

```bash
git add app/models/maker/preview.rb app/jobs/maker/generate_preview_job.rb app/services/maker/previews/lbrn2.rb test/services/maker/previews/lbrn2_test.rb
git commit -m "feat(previews): add the geometry preview kind"
```

---

## Task 6: The `GET /files/:id/geometry` endpoint

**Files:**
- Modify: `config/routes.rb:67-82`
- Modify: `app/controllers/files_controller.rb`
- Create: `test/integration/web/lbrn_geometry_test.rb`

- [ ] **Step 1: Write the failing test**

Drive real requests. A test that sets preview statuses in Ruby and asserts on them proves nothing
about the endpoint — that is the shape §14a's capability-gating tests had when nine of them could
not fail for the reason they existed.

Follow `test/integration/web/files_flow_test.rb` for structure: `module Web`, the local `sign_in`
helper, `pin_file_layer_backend("chunk")`, and its two-phase `upload(name, bytes)` helper. Read
that file first and copy its conventions rather than inventing them.

```ruby
require "test_helper"

module Web
  # The .lbrn2 Measure view's coordinate endpoint. Chunk-shaped (it uploads through
  # Sync::Commit's two-phase flow), so it pins the backend and says so — see
  # test_helper#pin_file_layer_backend.
  class LbrnGeometryTest < ActionDispatch::IntegrationTest
    include ActiveJob::TestHelper

    setup do
      pin_file_layer_backend("chunk")
      Storage::ChunkStore.reset!
      @user = sign_in
      @node_id = upload("measure.lbrn2", file_fixture_bytes("real-export.lbrn2"))
    end

    test "requires authentication" do
      delete destroy_user_session_path
      get geometry_file_path(@node_id)
      assert_redirected_to new_user_session_path
    end

    test "answers pending while the preview is being generated" do
      get geometry_file_path(@node_id)

      assert_response :success
      assert_equal "pending", response.parsed_body["status"]
    end

    test "answers ready with a blob url once the preview is generated" do
      perform_enqueued_jobs { get geometry_file_path(@node_id) }
      get geometry_file_path(@node_id)

      assert_response :success
      body = response.parsed_body
      assert_equal "ready", body["status"]
      assert body["url"].present?, "a ready geometry preview must expose its blob url"
    end

    test "the ready payload is the geometry, not an image" do
      perform_enqueued_jobs { get geometry_file_path(@node_id) }
      preview = @user.maker_previews.find_by!(node_id: @node_id, kind: "geometry")

      assert_equal "application/json", preview.asset.content_type
      assert_equal 4, JSON.parse(preview.asset.download)["shapes"].length
    end

    test "surfaces a failed preview rather than 500ing" do
      preview_for(@node_id).update!(status: "failed", error: "boom")
      get geometry_file_path(@node_id)

      assert_response :success
      assert_equal "failed", response.parsed_body["status"]
      assert_equal "boom", response.parsed_body["error"]
    end

    test "surfaces unsupported with the job's own message" do
      preview_for(@node_id).update!(status: "unsupported",
                                    error: "lbrn2 is 40 MB, over the 32 MB preview ceiling")
      get geometry_file_path(@node_id)

      assert_equal "unsupported", response.parsed_body["status"]
      assert_match(/over the 32 MB preview ceiling/, response.parsed_body["error"])
    end

    test "404s for a node this user does not own" do
      other = User.create!(email: "other@example.com", password: PASSWORD, confirmed_at: Time.current)
      stranger = other.nodes.create!(node_id: SecureRandom.uuid, name: "theirs.lbrn2", kind: "file")

      get geometry_file_path(stranger.node_id)
      assert_response :not_found
    end
  end
end
```

> **`preview_for`, `file_fixture_bytes`, `upload` and `sign_in` are yours to write** — model them
> on `files_flow_test.rb`. `preview_for` should call `Maker::Previews::Enqueue` the same way the
> action does (or find the row it created) so the test manipulates a REAL row rather than
> constructing one whose `version_id` may not match what the endpoint looks up. Getting that wrong
> produces a test that passes while the endpoint is broken.
>
> The cross-user test is the one most likely to pass for the wrong reason — a node id that does not
> exist 404s whether or not the action scopes by user. It must create a node owned by a DIFFERENT
> user. Mutation-check it by dropping the `current_user` scope in the action (Step 6).

- [ ] **Step 2: Run to verify it fails**

```bash
bin/rails test test/controllers/files_geometry_test.rb
```

Expected: **FAIL** with `NameError: undefined local variable or method 'geometry_file_path'`.

- [ ] **Step 3: Add the route**

In `config/routes.rb`, inside the existing `resources :files` block:

```ruby
    member do
      get "blob"
      # The .lbrn2 Measure view's coordinate payload. A SECOND preview kind for the same node
      # (kind: "geometry"), so this neither replaces nor disturbs the thumbnail. The payload
      # itself leaves via the blob URL, off Rails — this action only reports where it is.
      get "geometry"
    end
```

- [ ] **Step 4: Implement the action**

In `app/controllers/files_controller.rb`, beside `#thumbnails`:

```ruby
  # GET /files/:id/geometry (JSON) — the coordinate payload behind the .lbrn2 Measure view.
  #
  # Enqueue-and-report, NOT render-and-wait. Parsing means reading the whole file out of the
  # file layer, and the biggest .lbrn2 files are photo engravings — 24 MB on disk for two shapes —
  # so doing it inline would block a browser request on a multi-megabyte fetch. The job already
  # owns that work, along with the MAX_PREVIEW_BYTES ceiling, the FetchError retry policy, and
  # commit_if_current's version-race guard.
  #
  # Same response shape as #thumbnails so the client's polling code is a known quantity.
> **Two bugs corrected during execution — this code as first written did not work.** Both were
> found by running it, not by reading it, and both made one of the plan's own tests fail:
>
> 1. **Calling `Enqueue.call` unconditionally makes the `"failed"` branch DEAD CODE.** `Enqueue`
>    resets a failed row to `pending` and re-enqueues *whenever it is called* — right for a
>    one-shot nudge at upload time, wrong for a passive poll. `preview.status` could never still
>    read `"failed"` by the time the `case` reads it, and a client polling a permanently broken
>    file would re-enqueue a doomed render on **every poll**. Fixed by reading the existing row for
>    the current `content_token` first and only falling through to `Enqueue` when none exists.
> 2. **A plain `get` defaults to `:html`**, so `RecordNotFound` reached the class-level
>    `rescue_from`'s html branch and answered **302 to `files_path`** rather than 404 — right for
>    `#show`/`#blob`, which render a page, and flatly contrary to this action's own "same shape as
>    `#thumbnails`" contract. A JSON poller reading that redirect's body sees neither a status key
>    nor a 404. Fixed with a local `rescue`.
>
> Accepted consequence of (1), stated rather than discovered later: **a `failed` geometry preview is
> terminal until the file's content changes.** That is honest — a transient byte-store failure
> surfaces as `FetchError`, which `retry_on` handles and which leaves the row `processing` (so the
> client keeps polling and it self-heals), so `failed` genuinely means the parse failed. Re-saving
> the file changes the token and retries automatically.

```ruby
  def geometry
    node = current_user.nodes.present.find_by!(node_id: params[:id])
    token = FileLayer.current.stat(current_user, node_id: node.node_id)&.content_token
    return render json: { status: "pending" } if token.nil?

    preview = current_user.maker_previews.find_by(node_id: node.node_id, version_id: token, kind: "geometry")
    preview ||= Maker::Previews::Enqueue.call(user: current_user, node_id: node.node_id,
                                              name: node.name, version_id: token, kind: "geometry")
    # nil = no renderer for this filename. Terminal and honest: the Measure button is only
    # rendered for .lbrn/.lbrn2, so reaching here otherwise is a client bug, not a wait.
    return render json: { status: "unsupported", error: "no geometry for #{node.name}" } if preview.nil?

    case preview.status
    when "ready"
      render json: { status: "ready",
                     url: (url_for(preview.asset) if preview.asset.attached?) }
    when "failed", "unsupported"
      render json: { status: preview.status, error: preview.error }
    else
      render json: { status: "pending" }
    end
  rescue ActiveRecord::RecordNotFound
    head :not_found
  end
```

- [ ] **Step 5: Run the tests**

```bash
bin/rails test test/controllers/files_geometry_test.rb
```

Expected: **PASS**.

- [ ] **Step 6: Mutation-check the ownership scope**

Temporarily drop the user scope:

```ruby
    node = Node.present.find_by!(node_id: params[:id])
```

Expected: **RED** on "404s for a node this user does not own" — the stranger's node is now found
and the action answers 200 instead of 404. If it stays green, the test is asserting against a
node id that does not exist anywhere, which 404s either way; fix the test, not the mutation.
**Restore the scope.**

- [ ] **Step 7: Commit**

```bash
git add config/routes.rb app/controllers/files_controller.rb test/controllers/files_geometry_test.rb
git commit -m "feat(files): GET /files/:id/geometry endpoint"
```

---

## Task 7: The `:lbrn` preview branch

**Files:**
- Modify: `app/controllers/files_controller.rb` (`preview_kind`)
- Modify: `app/views/files/show.html.erb:130`
- Modify: `test/integration/web/lbrn_geometry_test.rb` (the file Task 6 created)

- [ ] **Step 1: Write the failing test**

Append to `test/integration/web/lbrn_geometry_test.rb`, reusing its `setup` and helpers:

```ruby
test "an lbrn2 file page offers the Measure surface" do
  get file_path(@node_id)

  assert_response :success
  assert_select "[data-controller='lbrnmeasure']", 1
  assert_select "[data-lbrnmeasure-url-value]", 1
  assert_select "button[data-action='lbrnmeasure#load']", 1
end

test "a non-lbrn file page does not" do
  other = upload("drawing.dxf", file_fixture_bytes("sample.dxf"))
  get file_path(other)

  assert_response :success
  assert_select "[data-controller='lbrnmeasure']", 0
end

# The :lbrn branch replaces the :thumbnail branch for these files, so everything that
# branch handled has to still work. A ready thumbnail is the resting state — Measure is a
# button, not a replacement.
test "the lbrn page still shows its thumbnail poster when one is ready" do
  perform_enqueued_jobs { get file_path(@node_id) }
  get file_path(@node_id)

  assert_response :success
  assert_select ".lbrn-measure-fallback img", 1
end

test "the lbrn page says so while the thumbnail is still generating" do
  get file_path(@node_id)

  assert_response :success
  assert_select ".lbrn-measure-fallback", text: /Generating preview/
end
```

- [ ] **Step 2: Run to verify it fails**

```bash
bin/rails test test/integration/web/lbrn_geometry_test.rb -n "/Measure surface/"
```

Expected: **FAIL** — `Expected exactly 1 element matching "[data-controller='lbrnmeasure']", found 0`.

- [ ] **Step 3: Implement `preview_kind`**

In `app/controllers/files_controller.rb`, insert **above** the `:thumbnail` return:

```ruby
    # LightBurn -> the interactive Measure view (lbrnmeasure_controller.js), which supersedes the
    # static thumbnail the way :model3d does for meshes. The thumbnail is still generated and is
    # still what the page shows at rest — Measure is a button, not a replacement, because
    # LightBurn's own embedded render is in colour and ours is black outlines.
    return :lbrn if %w[lbrn lbrn2].include?(ext)
```

- [ ] **Step 4: Implement the view branch**

In `app/views/files/show.html.erb`, insert **before** the `elsif @kind == :thumbnail` branch:

```erb
  <% elsif @kind == :lbrn %>
    <%# LightBurn: the colour thumbnail at rest, with a button that swaps in a measurable outline
        view built from the geometry payload. Mirrors the 3D viewer's lazy pattern — nothing is
        fetched until the user asks, which matters because the payload reaches 281 KB on the
        densest real files. %>
    <div class="lbrn-measure"
         data-controller="lbrnmeasure"
         data-lbrnmeasure-url-value="<%= geometry_file_path(@node.node_id) %>">
      <div class="lbrn-measure-stage" data-lbrnmeasure-target="stage"></div>
      <div class="lbrn-measure-bar">
        <span class="lbrn-measure-dims" data-lbrnmeasure-target="dims"></span>
        <span class="lbrn-measure-launch">
          <button type="button" class="btn small" data-action="lbrnmeasure#load">Measure</button>
        </span>
        <span class="lbrn-measure-actions">
          <button type="button" class="btn small ghost" data-action="lbrnmeasure#reset">Reset view</button>
          <button type="button" class="btn small ghost" aria-label="Return to image"
                  data-action="lbrnmeasure#showPoster">✕ Image</button>
        </span>
      </div>
      <div class="lbrn-measure-fallback" data-lbrnmeasure-target="fallback">
        <% if @thumbnail&.status == "ready" && @thumbnail.asset.attached? %>
          <img src="<%= url_for(@thumbnail.asset) %>" alt="Preview of <%= @node.name %>" class="preview-image">
        <% elsif %w[pending processing].include?(@thumbnail&.status) %>
          <p class="muted">Generating preview…</p>
        <% else %>
          <p class="muted">No inline preview for this file.</p>
          <%= link_to "Download #{@node.name}", blob_file_path(@node.node_id, download: 1), class: "btn" %>
        <% end %>
      </div>
    </div>
```

> The fallback reproduces **all three** thumbnail states. `.lbrn2` no longer reaches the
> `:thumbnail` branch, so anything that branch handled and this one does not is a regression.

- [ ] **Step 5: Add styles**

In `app/assets/stylesheets/application.css` (match the file's existing conventions; mirror the
`.model-viewer` rules directly above/below wherever they live):

```css
.lbrn-measure { position: relative; }
.lbrn-measure-stage { display: none; width: 100%; aspect-ratio: 1; }
.lbrn-measure--ready .lbrn-measure-stage { display: block; }
.lbrn-measure--ready .lbrn-measure-fallback { display: none; }
.lbrn-measure-stage svg { width: 100%; height: 100%; touch-action: none; cursor: crosshair; }
.lbrn-measure-stage svg.is-panning { cursor: grabbing; }
.lbrn-measure-bar { display: flex; align-items: center; gap: .5rem; margin-top: .5rem; }
.lbrn-measure-dims { flex: 1; font-variant-numeric: tabular-nums; }
.lbrn-measure-actions { display: none; }
.lbrn-measure--ready .lbrn-measure-actions { display: inline-flex; gap: .25rem; }
.lbrn-measure--ready .lbrn-measure-launch { display: none; }
.lbrn-contour { fill: transparent; stroke: currentColor; stroke-width: 1; vector-effect: non-scaling-stroke; }
.lbrn-contour--open { fill: none; stroke-width: 1; }
.lbrn-contour--hit { stroke: transparent; stroke-width: 8; fill: none; vector-effect: non-scaling-stroke; }
.lbrn-contour--hover { stroke: #2b7; stroke-width: 2; }
.lbrn-contour--selected { stroke: #d40; stroke-width: 2.5; }
.lbrn-bitmap { fill: rgba(128, 128, 128, .18); stroke: #888; stroke-dasharray: 4 3; vector-effect: non-scaling-stroke; }
```

- [ ] **Step 6: Run the tests**

```bash
bin/rails test test/integration/web/
```

Expected: **PASS**. Run the whole directory, not just the new file — `preview_kind` is shared, and
`files_flow_test.rb` / `page_query_budget_test.rb` are the ones most likely to notice a change to
what the show page renders.

- [ ] **Step 7: Commit**

```bash
git add app/controllers/files_controller.rb app/views/files/show.html.erb app/assets/stylesheets/application.css test/integration/web/lbrn_geometry_test.rb
git commit -m "feat(files): lbrn preview branch with a Measure surface"
```

---

## Task 8: The Stimulus controller — fetch, poll, draw

**Files:**
- Create: `app/javascript/controllers/lbrnmeasure_controller.js`

No new test in this task — Task 12's system test covers the whole client. Verify by hand here.

- [ ] **Step 1: Create the controller**

```javascript
import { Controller } from "@hotwired/stimulus"

// Measure view for LightBurn files: click a contour, read its size in mm.
//
// The page shows LightBurn's own colour PNG at rest. That render is a raster with no mapping back
// to millimetres, so measuring needs a vector surface — this controller fetches the server's
// geometry payload (GET /files/:id/geometry -> a blob URL) and builds an SVG from the coordinates.
//
// BUILT WITH createElementNS FROM NUMBERS, NEVER innerHTML. Maker::Previews::Svg rasterizes user
// SVG precisely because the web layer refuses to inline it; constructing elements from parsed
// coordinates sidesteps that rule instead of carving an exception into it.
//
// Lazy by design: nothing is fetched until Measure is clicked. The payload reaches 281 KB gzipped
// on the densest real files, and most .lbrn2 pages are never measured.
const SVG_NS = "http://www.w3.org/2000/svg"
const SCHEMA_VERSION = 1

// The job's retry_on uses polynomial backoff over 5 attempts, which can run for minutes — far
// longer than anyone watches a spinner. Poll a bounded number of times, then say so honestly.
const POLL_DELAYS_MS = [400, 800, 1500, 2500, 4000, 6000]

export default class extends Controller {
  static values = { url: String }
  static targets = ["stage", "dims", "fallback"]

  connect() {
    this.aborted = false
    this.selected = null
  }

  disconnect() {
    this.aborted = true
    clearTimeout(this.pollTimer)
  }

  async load() {
    this.setStatus("Loading geometry…")
    try {
      const payload = await this.fetchPayload()
      if (this.aborted || !payload) return
      this.draw(payload)
    } catch (e) {
      console.warn("[lbrnmeasure] keeping the thumbnail:", e)
      this.setStatus(e.message || "Could not load geometry.")
    }
  }

  showPoster() {
    this.element.classList.remove("lbrn-measure--ready")
    this.stageTarget.replaceChildren()
    this.setStatus("")
    this.selected = null
  }

  // Poll the endpoint until it reports ready, then fetch the payload from the blob URL it names.
  async fetchPayload() {
    for (let attempt = 0; attempt <= POLL_DELAYS_MS.length; attempt++) {
      const res = await fetch(this.urlValue, { headers: { Accept: "application/json" } })
      if (!res.ok) throw new Error(`Geometry request failed (${res.status}).`)
      const body = await res.json()

      if (body.status === "ready" && body.url) {
        const blob = await fetch(body.url)
        if (!blob.ok) throw new Error("Could not read the geometry payload.")
        const payload = await blob.json()
        if (payload.v !== SCHEMA_VERSION) {
          throw new Error("This preview needs a newer version of the page — reload.")
        }
        return payload
      }
      if (body.status === "failed" || body.status === "unsupported") {
        throw new Error(body.error || "No geometry available for this file.")
      }
      if (attempt === POLL_DELAYS_MS.length) break
      this.setStatus("Generating geometry…")
      await this.sleep(POLL_DELAYS_MS[attempt])
      if (this.aborted) return null
    }
    throw new Error("Still generating — reload to check.")
  }

  sleep(ms) {
    return new Promise((resolve) => { this.pollTimer = setTimeout(resolve, ms) })
  }

  draw(payload) {
    this.payload = payload
    this.byObject = new Map()
    for (const s of payload.shapes) {
      if (!this.byObject.has(s.o)) this.byObject.set(s.o, [])
      this.byObject.get(s.o).push(s)
    }

    if (!payload.shapes.length) {
      this.setStatus("No measurable geometry in this file.")
      return
    }

    const svg = document.createElementNS(SVG_NS, "svg")
    const pad = Math.max(payload.job.w, payload.job.h) * 0.02
    this.home = [payload.job.x - pad, payload.job.y - pad,
                 payload.job.w + pad * 2, payload.job.h + pad * 2]
    this.setViewBox(svg, this.home)
    svg.setAttribute("preserveAspectRatio", "xMidYMid meet")

    // SMALLEST CONTOUR WINS, VIA PAINT ORDER. Appending in DESCENDING bbox-area order puts small
    // shapes on top, so the browser's own topmost-wins hit dispatch selects the hole rather than
    // the plate it sits in. That is the entire selection algorithm — no point-in-polygon code.
    const ordered = [...payload.shapes].sort((a, b) => this.area(b) - this.area(a))
    for (const s of ordered) svg.appendChild(this.contourNode(s))

    this.stageTarget.replaceChildren(svg)
    this.svg = svg
    this.element.classList.add("lbrn-measure--ready")
    this.setStatus(`${payload.shapes.length} shapes · click one to measure`)
    this.bindInteractions(svg)
  }

  area(s) {
    return Math.max(s.b[2] - s.b[0], 0.01) * Math.max(s.b[3] - s.b[1], 0.01)
  }

  // A bitmap draws as a dashed placeholder: its base64 is excluded from the payload on purpose
  // (one real file is 1.45 MB as SVG and 0.1 KB as geometry), and a measuring view has no use
  // for the photo — only for the rectangle it occupies.
  contourNode(shape) {
    const node = document.createElementNS(SVG_NS, shape.k ? "polygon" : "polyline")
    node.setAttribute("points", shape.p.map(([x, y]) => `${x},${y}`).join(" "))
    node.setAttribute("class", shape.i ? "lbrn-bitmap" : (shape.k ? "lbrn-contour" : "lbrn-contour lbrn-contour--open"))
    node.__shape = shape
    return node
  }

  // Replaced in full by Task 9. Defined now because draw() calls it — without this stub the
  // controller throws "bindInteractions is not a function" the moment Measure is clicked, and
  // Task 8's hand-verification step would fail for a reason that has nothing to do with drawing.
  bindInteractions(_svg) {}

  setViewBox(svg, [x, y, w, h]) {
    svg.setAttribute("viewBox", `${x} ${y} ${w} ${h}`)
    this.view = [x, y, w, h]
  }

  setStatus(text) {
    if (this.hasDimsTarget) this.dimsTarget.textContent = text
  }
}
```

- [ ] **Step 2: Verify by hand**

```bash
bin/rails server -p 3001
```

Open a `.lbrn2` file page, click **Measure**. Expected: outlines appear, the bar reads
"N shapes · click one to measure". Clicking does nothing yet — that is Task 9.

- [ ] **Step 3: Commit**

```bash
git add app/javascript/controllers/lbrnmeasure_controller.js
git commit -m "feat(lbrn2): Measure view fetches and draws the geometry payload"
```

---

## Task 9: Hit-testing, the readout, and alt-click

**Files:**
- Modify: `app/javascript/controllers/lbrnmeasure_controller.js`

- [ ] **Step 1: Add the interaction methods**

Insert before the closing brace of the class:

```javascript
  bindInteractions(svg) {
    svg.addEventListener("pointermove", (e) => this.hover(e))
    svg.addEventListener("pointerleave", () => this.clearHover())
    svg.addEventListener("click", (e) => this.pick(e))
  }

  shapeAt(event) {
    const node = event.target
    return node && node.__shape ? node : null
  }

  // WHAT WAS HIT IS NOT ALWAYS WHAT TO STYLE. An open contour is hit through a transparent fat
  // twin (see contourNode), so highlighting the node the event landed on would change the colour
  // of something invisible and nothing would appear to happen. `__visible` points at the drawn
  // line; closed contours are their own hit target and have none.
  styleNode(node) {
    return node.__visible || node
  }

  hover(event) {
    if (this.panning) return
    const node = this.shapeAt(event)
    if (node === this.hovered) return
    if (this.hovered) this.styleNode(this.hovered).classList.remove("lbrn-contour--hover")
    this.hovered = node
    if (this.hovered) this.styleNode(this.hovered).classList.add("lbrn-contour--hover")
  }

  clearHover() {
    if (this.hovered) this.styleNode(this.hovered).classList.remove("lbrn-contour--hover")
    this.hovered = null
  }

  pick(event) {
    if (this.didPan) { this.didPan = false; return }
    const node = this.shapeAt(event)
    if (!node) return

    if (this.selected) this.styleNode(this.selected).classList.remove("lbrn-contour--selected")
    this.selected = node
    this.styleNode(node).classList.add("lbrn-contour--selected")

    const shape = node.__shape
    const siblings = this.byObject.get(shape.o) || [shape]
    // Alt-click widens to the whole <Shape> object — every contour the parser gave the same
    // object id, which for a Text is its entire rendered outline rather than one letter.
    const useObject = event.altKey && siblings.length > 1
    this.setStatus(useObject ? this.objectLabel(siblings) : this.contourLabel(shape, siblings))
  }

  contourLabel(shape, siblings) {
    let label = this.sizeLabel(shape)
    if (siblings.length > 1) {
      const box = this.unionOf(siblings)
      label += ` · part of a ${siblings.length}-contour object (⌥ for ${this.dims(box)})`
    }
    return label
  }

  objectLabel(siblings) {
    return `${this.dims(this.unionOf(siblings))} · whole object, ${siblings.length} contours`
  }

  // ⌀ only when the server said so. Circularity is decided server-side, from full-resolution
  // points, so the client never re-derives a measurement from the thinned drawing points.
  sizeLabel(shape) {
    return shape.d != null ? `⌀${this.mm(shape.d)} mm` : this.dims(shape.b)
  }

  dims(box) {
    return `${this.mm(box[2] - box[0])} × ${this.mm(box[3] - box[1])} mm`
  }

  unionOf(shapes) {
    return [
      Math.min(...shapes.map((s) => s.b[0])), Math.min(...shapes.map((s) => s.b[1])),
      Math.max(...shapes.map((s) => s.b[2])), Math.max(...shapes.map((s) => s.b[3]))
    ]
  }

  mm(n) {
    return (Math.round(n * 10) / 10).toLocaleString()
  }
```

The hit target for an **open** contour is its stroke, which is thin. Widen it without changing what
is drawn, by giving each open contour an invisible fat twin. In `contourNode`, replace the return
for open contours — change the method to:

```javascript
  contourNode(shape) {
    const node = document.createElementNS(SVG_NS, shape.k ? "polygon" : "polyline")
    const points = shape.p.map(([x, y]) => `${x},${y}`).join(" ")
    node.setAttribute("points", points)
    node.setAttribute("class", shape.i ? "lbrn-bitmap" : (shape.k ? "lbrn-contour" : "lbrn-contour lbrn-contour--open"))
    node.__shape = shape
    if (shape.k || shape.i) return node

    // An open polyline has no interior to click and a hairline stroke to aim at. Group it with a
    // transparent fat twin so the hit area is finger-sized while the drawn line stays 1px.
    const group = document.createElementNS(SVG_NS, "g")
    const hit = document.createElementNS(SVG_NS, "polyline")
    hit.setAttribute("points", points)
    hit.setAttribute("class", "lbrn-contour--hit")
    hit.__shape = shape
    hit.__visible = node // so hover/selection colours the drawn line, not the invisible twin
    group.appendChild(hit)
    group.appendChild(node)
    return group
  }
```

Also add `pointer-events: stroke` to the hit twin's rule in `application.css`, so it is explicit
rather than relying on `visiblePainted` treating a transparent stroke as painted:

```css
.lbrn-contour--hit { stroke: transparent; stroke-width: 8; fill: none; pointer-events: stroke; vector-effect: non-scaling-stroke; }
```

- [ ] **Step 2: Verify by hand**

Restart the server, open a `.lbrn2` page, click **Measure**, then click a contour.

Expected: the contour highlights and the bar reads e.g. `40 × 20 mm`. On a circle: `⌀20 mm`. On a
contour belonging to a multi-contour object: `… · part of a 3-contour object (⌥ for 30 × 10 mm)`,
and alt-clicking shows the object size.

- [ ] **Step 3: Commit**

```bash
git add app/javascript/controllers/lbrnmeasure_controller.js
git commit -m "feat(lbrn2): click a contour to read its dimensions"
```

---

## Task 10: Zoom and pan

**Files:**
- Modify: `app/javascript/controllers/lbrnmeasure_controller.js`

Without this a 3 mm hole in a 300 mm design is ~5 px, and the dense files are the ones worth
measuring.

- [ ] **Step 1: Add zoom/pan and wire `reset`**

Add to `bindInteractions`:

```javascript
    svg.addEventListener("wheel", (e) => this.zoom(e), { passive: false })
    svg.addEventListener("pointerdown", (e) => this.startPan(e))
    svg.addEventListener("pointermove", (e) => this.movePan(e))
    svg.addEventListener("pointerup", (e) => this.endPan(e))
    svg.addEventListener("pointercancel", (e) => this.endPan(e))
```

Add these methods:

```javascript
  reset() {
    if (this.svg && this.home) this.setViewBox(this.svg, this.home)
  }

  // Zoom about the cursor, so the feature under the pointer stays under it.
  zoom(event) {
    event.preventDefault()
    const [x, y, w, h] = this.view
    const factor = event.deltaY > 0 ? 1.15 : 1 / 1.15
    const span = Math.max(this.home[2], this.home[3])
    const nextW = Math.min(Math.max(w * factor, span / 500), span * 4)
    const nextH = h * (nextW / w)

    const p = this.toUserSpace(event)
    this.setViewBox(this.svg, [
      p.x - (p.x - x) * (nextW / w), p.y - (p.y - y) * (nextH / h), nextW, nextH
    ])
  }

  startPan(event) {
    if (event.button !== 0) return
    this.panning = this.toUserSpace(event)
    this.didPan = false
    this.svg.setPointerCapture(event.pointerId)
    this.svg.classList.add("is-panning")
  }

  movePan(event) {
    if (!this.panning) return
    const p = this.toUserSpace(event)
    const dx = this.panning.x - p.x
    const dy = this.panning.y - p.y
    if (Math.abs(dx) > 0.01 || Math.abs(dy) > 0.01) this.didPan = true
    const [x, y, w, h] = this.view
    this.setViewBox(this.svg, [x + dx, y + dy, w, h])
  }

  endPan(event) {
    if (!this.panning) return
    this.panning = null
    this.svg.releasePointerCapture?.(event.pointerId)
    this.svg.classList.remove("is-panning")
  }

  // Screen px -> the SVG's own user units (mm), which is what viewBox maths needs.
  toUserSpace(event) {
    const rect = this.svg.getBoundingClientRect()
    const [x, y, w, h] = this.view
    // preserveAspectRatio="xMidYMid meet" letterboxes: the scale is the SMALLER of the two,
    // and the unused axis is centred. Ignoring that makes the cursor drift on non-square files.
    const scale = Math.min(rect.width / w, rect.height / h)
    const offX = (rect.width - w * scale) / 2
    const offY = (rect.height - h * scale) / 2
    return {
      x: x + (event.clientX - rect.left - offX) / scale,
      y: y + (event.clientY - rect.top - offY) / scale
    }
  }
```

`didPan` is why `pick` starts with `if (this.didPan)` — a drag ends in a `click` event, and
without it every pan would also re-select whatever was under the cursor.

- [ ] **Step 2: Verify by hand**

Scroll to zoom (the point under the cursor stays put), drag to pan, click **Reset view**. Then
confirm a click after a drag does **not** change the selection.

- [ ] **Step 3: Commit**

```bash
git add app/javascript/controllers/lbrnmeasure_controller.js
git commit -m "feat(lbrn2): zoom and pan the Measure view"
```

---

## Task 11: System test

**Files:**
- Create: `test/system/lbrn_measure_test.rb`

- [ ] **Step 1: Write the test**

Hermetic on repo fixtures — never the 58-file corpus, which a fresh clone does not have. Follow
`test/system/addon_bundle_test.rb` for this repo's system-test setup and sign-in helper.

System tests already have a shared helper module — `test/system/support/web_helpers.rb`, included
by `ApplicationSystemTestCase` — providing `sign_in_as(email)`, `project_with_folder`, and
`assert_no_console_errors(ignoring:)`. Use them; do not hand-roll a sign-in or a raw
`logs.get(:browser)` check. Note the base class **drains the browser log buffer in `setup`**
because Selenium reuses one Chrome across a file and the log is a drain — a backlog from one test
otherwise fails the next.

```ruby
require "application_system_test_case"

class LbrnMeasureTest < ApplicationSystemTestCase
  setup do
    @user = sign_in_as
    @node = create_library_file(@user, "measure-me.lbrn2", "bezier-circle.lbrn2")
  end

  test "clicking a contour reports its dimensions" do
    visit file_path(@node.node_id)
    click_on "Measure"

    assert_selector ".lbrn-measure--ready svg polygon", minimum: 2, wait: 10

    # The square is at x 40..60; the circle at -10..10. Click the square's outline.
    find("svg polygon:last-of-type").click
    assert_text "20 × 20 mm"
  end

  test "clicking the bezier circle reports a diameter" do
    visit file_path(@node.node_id)
    click_on "Measure"
    assert_selector ".lbrn-measure--ready svg polygon", minimum: 2, wait: 10

    find("svg polygon:first-of-type").click
    assert_text "⌀20 mm"
  end

  test "the page renders without console errors" do
    visit file_path(@node.node_id)
    click_on "Measure"
    assert_selector ".lbrn-measure--ready", wait: 10

    assert_no_console_errors
  end
end
```

> **`create_library_file` does NOT exist — you must write it.** Check `test/system/support/` and
> the other system tests for how they get bytes into the library, and follow whatever they do.
> Whatever you write must work on all three `LIBRARY_BACKEND` legs, since `bin/ci` runs them all
> and their counts must match.
>
> `assert_no_console_errors` is this repo's established way of catching client defects integration
> tests cannot see — it caught two shipped CSP defects. It takes an `ignoring:` list; do not reach
> for it to silence a real error.

- [ ] **Step 2: Run it**

```bash
bin/rails test:system TEST=test/system/lbrn_measure_test.rb
```

Expected: **PASS**.

- [ ] **Step 3: Mutation-check the paint order**

In the controller, temporarily sort ascending so big shapes land on top:

```javascript
    const ordered = [...payload.shapes].sort((a, b) => this.area(a) - this.area(b))
```

Add a temporary check that clicking inside the circle still reports `⌀20 mm`. With a fixture whose
shapes do not overlap this may stay green — if so, note in the test file that **paint order is not
covered by a fixture today** and say why, rather than leaving a silent gap. **Restore the sort.**

- [ ] **Step 4: Commit**

```bash
git add test/system/lbrn_measure_test.rb
git commit -m "test(system): measure a contour in the lbrn2 view"
```

---

## Task 12: The corpus probe rake task

**Files:**
- Create: `lib/tasks/lbrn.rake`

The 58 real exports are the only real-format validation set and cannot live in CI. This makes the
measurement repeatable without pretending it is a gate.

- [ ] **Step 1: Create the task**

```ruby
# frozen_string_literal: true

namespace :lbrn do
  desc "Geometry payload report over a directory of real .lbrn2 files (manual probe, NOT a gate)"
  task :geometry_report, [ :dir ] => :environment do |_t, args|
    dir = args[:dir] or abort "usage: rake 'lbrn:geometry_report[/path/to/lbrn2/files]'"
    files = Dir.glob(File.join(File.expand_path(dir), "**", "*.lbrn2"))
    abort "no .lbrn2 files under #{dir}" if files.empty?

    require "zlib"
    rows = files.filter_map do |path|
      bytes = File.binread(path)
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      json = Maker::Previews::LbrnGeometry.render(bytes)[:bytes]
      ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round(1)
      payload = JSON.parse(json)
      { name: File.basename(path), contours: payload["shapes"].length, ms:,
        kb: (json.bytesize / 1024.0).round(1),
        gz: (Zlib::Deflate.deflate(json, 6).bytesize / 1024.0).round(1) }
    rescue StandardError => e
      warn "SKIP #{File.basename(path)}: #{e.class}: #{e.message}"
      nil
    end

    rows.sort_by! { |r| -r[:gz] }
    printf("%-38s %8s %8s %9s %10s\n", "file", "contours", "ms", "json KB", "gzipped KB")
    rows.each { |r| printf("%-38s %8d %8s %9s %10s\n", r[:name][0, 38], r[:contours], r[:ms], r[:kb], r[:gz]) }

    med = ->(k) { v = rows.map { |r| r[k] }.sort; v[v.length / 2] }
    puts "\n#{rows.length} files · median #{med.(:gz)} KB gzipped, #{med.(:ms)} ms · " \
         "worst #{rows.first[:gz]} KB (#{rows.first[:name]})"
  end
end
```

- [ ] **Step 2: Run it against the real corpus**

```bash
bin/rails "lbrn:geometry_report[~/Documents/3d printing copy]"
```

Expected: 58 rows. Sanity-check against the spec's §3 table — median around 5 KB gzipped, worst
around 281 KB. **A large divergence means the decimation or the payload shape regressed**; the
numbers in the spec were measured with exactly this payload definition.

- [ ] **Step 3: Commit**

```bash
git add lib/tasks/lbrn.rake
git commit -m "chore(lbrn2): rake probe for geometry payload size over a real corpus"
```

---

## Task 13: Documentation

**Files:**
- Modify: `CLAUDE.md` (§14a area — add a short §14h)
- Modify: `docs/STATUS.md`

CLAUDE.md holds invariants a future editor could undo by accident; STATUS.md narrates the arc.
Keep them on their own sides of that line.

- [ ] **Step 1: Add the invariants to CLAUDE.md**

Insert a new subsection after §14g, and **do not renumber anything**:

```markdown
### 14h. LightBurn shape measurement

- **EVERY REPORTED NUMBER COMES FROM FULL-RESOLUTION POINTS; DECIMATION IS DRAWING-ONLY.**
  `LbrnGeometry` thins contours over 32 points 3:1 to keep the payload small (the worst real file
  drops 734 KB → 281 KB gzipped), and computes `b` and `d` **before** thinning. Measure after
  thinning and every curve under-reports, silently, while every "does it draw" test stays green.
- **`DECIMATE_STRIDE` IS COUPLED TO `Lbrn2::BEZIER_SAMPLES`, ACROSS TWO FILES, AND THE STRIDE MUST
  DIVIDE THE SAMPLE COUNT.** 12 % 3 == 0, so an original LightBurn vertex lands on every kept
  index and decimation drops only *intermediate curve samples* — never a vertex. That is why a
  thinned curve keeps its extremes and its corners. Set either constant so the division stops
  holding and contour bboxes begin to move under decimation, silently. Asserted directly in
  `lbrn_geometry_test.rb`, because it is invisible from either file alone.
- **The payload's bboxes must union to `Lbrn2.job_size`** — asserted in
  `lbrn_geometry_test.rb`, rounding once to `job_size`'s 1dp before demanding equality. This is
  what keeps the measure view and the Laser Settings panel on ONE traversal; the second copy is
  the failure §14b already records for `LbrnMetadata`.
- **CIRCULARITY NEEDS THE 12-POINT FLOOR, NOT JUST THE RADIUS TEST.** A square's four corners are
  all equidistant from its centre — as are any regular polygon's vertices — so radius variance
  alone calls every square round. A `Rect` emits 5 points, a bezier circle 49, an `Ellipse` 33.
  Accepted consequence: a genuine 16-gon reports as round. `bezier-circle.lbrn2` pins both
  directions, and the square is the assertion that carries the weight.
- **`each_geometry`'s 6th yielded value (`object_id`) counts NON-GROUP `<Shape>`s, and a Text's
  `<BackupPath>` REUSES its parent's** — the outline *is* the text, so alt-clicking one letter
  must report the whole word. A Group consumes no id, which is what keeps it transparent to
  measurement exactly as it is to drawing.
- **Bitmap base64 is EXCLUDED from the geometry payload, deliberately.** It is the single reason
  the payload is cheap: `metal test 5.lbrn2` is 1.45 MB gzipped as SVG and 0.1 KB as geometry
  JSON. A measuring view needs the rectangle, not the photo. Restoring it re-inflates every
  photo-engraving file by three orders of magnitude.
- **`geometry` is the FIRST kind to exercise the preview `kind` seam end to end.** `model_glb` is
  declared in `Preview::KINDS` but refused by `Mesh`, so nothing produced a second artifact from
  one file until this. `RendererContractTest` still passes because its `render_with` never sends
  `kind:` — it exercises the thumbnail path, where "must be an inline-safe raster" stays true.
- **The Measure view builds its SVG with `createElementNS`, never `innerHTML`.**
  `Maker::Previews::Svg` rasterizes precisely because the web layer refuses to inline SVG;
  constructing elements from parsed coordinates sidesteps that rule rather than excepting it.
- **Hit-testing is paint order, not geometry.** Contours are appended in DESCENDING bbox-area
  order so the browser's own topmost-wins dispatch selects the hole rather than the plate around
  it. Sorting the other way silently makes small features unclickable.
- **`FilesController#geometry` READS THE EXISTING PREVIEW ROW BEFORE CALLING `Enqueue`, and that is
  not interchangeable with the eager upload-time call.** `Enqueue.call` resets a `failed` row to
  `pending` and re-enqueues *whenever called* — correct for a one-shot nudge, wrong for a poll.
  Unconditional, it makes the action's own `"failed"` branch **dead code** and re-enqueues a doomed
  render on every poll of a permanently broken file. Accepted consequence: a `failed` geometry
  preview is terminal until the content changes — honest, because a transient byte-store failure is
  a `FetchError`, which leaves the row `processing` and self-heals.
- **`#geometry` rescues `RecordNotFound` LOCALLY, and the class-level `rescue_from` is why.** That
  handler branches on request format and answers a plain `get` — html, the default with no Accept
  header — with a **302 to `files_path`**. Right for `#show`/`#blob`, which render a page; wrong
  for a JSON poller, which would read a redirect body containing neither a status key nor a 404.
```

- [ ] **Step 2: Record the arc in `docs/STATUS.md`**

Add an entry in the file's established format covering: the branch, the measurements over the 58
real exports that sized the payload, the new `geometry` preview kind, the two new fixtures and why
they were needed, and the suite counts from `bin/ci`.

- [ ] **Step 3: Commit**

```bash
git add CLAUDE.md docs/STATUS.md
git commit -m "docs: record the shape-measurement invariants (§14h) and the arc"
```

---

## Task 14: Full gate

- [ ] **Step 1: Run the complete gate**

```bash
bin/ci
```

Expected: **all gates green** — style, scan, test, test-share, test-s3, system. The three test legs
must report **identical** counts. A count that differs by leg means something in this change is
backend-dependent, which nothing here should be: the endpoint reads bytes through
`Maker::FileBytes` like every other preview and touches no capability gate.

- [ ] **Step 2: Re-run the corpus probe as a final sanity check**

```bash
bin/rails "lbrn:geometry_report[~/Documents/3d printing copy]"
```

Expected: 58 rows, no `SKIP` lines. A skip means a real file now fails to parse — investigate
before opening the PR.

- [ ] **Step 3: Open the PR**

Per `CLAUDE.md`'s close-out rule, a green `bin/ci` on a `claude/*` branch is standing authorization
to commit, push, and open a PR — but **not** to merge. State plainly in the PR what was verified
(the fixtures, the mutation checks, the corpus probe) and what was not (Linux and Windows CI are
skipped, not passing — only the macOS runner is registered).

---

## Self-review notes

**Spec coverage.** Every section of the spec maps to a task: §5.1–5.3 → Task 5; §5.4 → Task 2;
§5.5 → Tasks 3–4; §5.6 → Task 6; §6.1 → Task 7; §6.2 → Tasks 8–10; §6.3 → Task 8's
`fetchPayload`; §7 → Tasks 1, 3, 4, 6, 11; §8 → the File Structure table; §9 non-goals are not
implemented anywhere, which is correct.

**Four defects the self-review caught and fixed inline** (recorded so a reader knows they were
looked for, not missed): `draw()` called `bindInteractions` a task before it existed, so Task 8's
hand-check would have thrown rather than drawn — now stubbed; `diameter` measured from the
centroid while the spec said bbox centre, a bias introduced by a closed contour's duplicated first
point — now the bbox centre; hover and selection styled the transparent hit twin on open contours,
so highlighting them would have changed nothing visible — now routed through `styleNode`; and a
dead `dataset.shape` write left over from an earlier draft.

**Corrections made during execution, kept here rather than quietly patched** — both were guards
that could not fail for the reason they existed, i.e. the failure mode this plan is written to
avoid, reached by following the plan:

1. **Task 1's fixture was not asserted to be round.** The bbox is pinned by the circle's four
   on-axis vertices, so swapping the `c0`/`c1` handles yields a four-lobed shape with radii
   4.14–10.0 while every assertion stays green. Closed-ness and point count are equally blind.
   Fixed by a per-point radius assertion; real spread is 0.0026 mm against a 0.01 tolerance.
2. **Task 2's mutation check could not fail.** With one `<Shape>` in the fixture, both BackupPath
   contours come from a single `emit_shape` call and share whatever id is passed — so a fresh id
   changes which id is shared, not whether. Fixed by adding a second shape, which turns the
   difference into an observable gap in the id sequence.
3. **And the fix to (2) opened a third hole, in the other mutation.** With the Rect present, a
   per-contour-id mutation yields `[1, 2, 2]` — one letter colliding with the Rect — which has the
   same unique count *and* the same density as the correct `[1, 1, 2]`. Both aggregate assertions
   stayed green over a plainly wrong grouping; only a positional comparison separates them. Full
   reasoning at Task 2 Step 5.

4. **Task 3's union mutation could not fail either**, for a reason worth more than the gap:
   `BEZIER_SAMPLES % DECIMATE_STRIDE == 0`, so decimation drops only intermediate curve samples and
   never an original vertex. Now asserted directly rather than relied on. Task 3 Step 5.
5. **`CIRCLE_TOLERANCE` was unguarded at any value** — `1_000_000` left all eight tests green.
   Closed with an inline-XML ellipse that is round-ish but outside 2%. Task 4 Step 4.

The lesson worth carrying into the remaining tasks: **an aggregate assertion (count, uniq, density,
sum, or a union over a whole document) is the shape most likely to be green over a wrong answer.**
Four of these five were one. A union in particular hides any per-item error that some other item
already bounds — which is exactly how (4) stayed green on three separate fixtures.

Two of the five were found by implementers reporting an honest negative result on a mutation the
plan told them to expect to pass. That is the single highest-value behaviour in this loop; a
subagent that "fixes" a mutation check until it goes red would have buried all four.

Both were caught by review and by an implementer who reported an honest negative result instead of
a clean one. That is the process working; neither would have been visible in a green suite.

**Known soft spots, flagged rather than hidden:**

- Task 6's test helpers (`sign_in_as`, fixtures, a `.lbrn2` node) and Task 11's
  `create_library_file` are written against conventions this plan asserts but did not verify.
  Both steps say to check the existing tests and adapt. If the helper does not exist, write it —
  do not weaken the test to fit what does.
- Task 11's paint-order mutation check may not go red, because `bezier-circle.lbrn2`'s two shapes
  do not overlap. The step says to record that gap in the test file rather than claim coverage.
- The CSS in Task 7 assumes `application.css` is where these rules belong. Match whatever
  convention the `.model-viewer` rules already follow.
