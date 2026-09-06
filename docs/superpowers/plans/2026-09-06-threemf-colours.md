# 3MF in the model viewer — slicer colours and declared units

> **For agentic workers:** execute per `.claude/commands/execute-plan.md`. One implementer (the
> slice is one coherent unit), one capped review. Steps use checkbox (`- [ ]`) syntax.

**Goal:** a `.3mf` opens in the 3D viewer **wearing the colours its slicer gave it** — each object in a
Bambu Studio or PrusaSlicer project painted with its extruder's filament colour — and a 3MF that
declares a unit other than millimetres (Onshape exports `unit="meter"`) **measures right**.

**What was measured (2026-09-06, the user's library, real browser against the dev server):**
- Online3DViewer 0.18.0 routes 3MF through three.js's `3MFLoader` (`ImporterThree3mf`, with an
  sRGB→linear colour converter). Standard 3MF colours (`m:colorgroup`, `basematerials`) DO arrive —
  an Onshape export renders its `#CEA47E` as per-vertex colours, correctly linearised. Nothing to fix
  there.
- three's loader IGNORES `<model unit="…">`. The same Onshape part (`unit="meter"`, 1.9 m long) shows
  "0 × 1 × 0.6 mm" in the dims line, 1000× short, and `model.GetUnit()` is `Unknown`. The controller's
  own comment claims 3MF units are converted by the importer; that claim is false and is corrected here.
- A Bambu Studio project (`Metadata/model_settings.config` + `Metadata/project_settings.config`)
  renders every object in the viewer's default grey: the filament colours are Bambu metadata, not
  3MF materials, and the loader cannot know them. Its meshes arrive UNNAMED (Bambu's `<object>` has no
  `name`; names live in `model_settings.config`), so a name match is impossible — but every three.js
  mesh in the scene carries `userData.originalMeshInstance.id.meshIndex`, the engine's own import
  index, which is exact. Meshes share ONE material object, so a per-mesh colour needs a clone.
- Import order is deterministic: `<build><item>` order, components depth-first (O3DV's `AddObject`
  walks three's object tree children-first, one mesh per leaf; three's loader builds items in file
  order and resolves `p:path` components into `3D/Objects/*.model`).
- The library (30 3MFs sampled): 15 Bambu projects, 3 PrusaSlicer, 3 `unit="meter"` CAD exports, 8
  plain. One Bambu file carries PAINTED triangles (`paint_color`, 236 of them) — **not in scope**
  (needs per-triangle materials from a custom parse; three's loader drops the attribute); say so.

**Architecture:**
- **The server reads the slicer metadata once; the browser applies it by mesh index.**
  `Maker::ThreeMfManifest.for(user:, node:)` (rubyzip + Nokogiri, both already dependencies) reads
  the 3MF through the port — bounded on the catalog's `size` column first, cached in `Rails.cache`
  by content token with nil cached, exactly `Maker::GerberArchive`'s shape — and answers
  `Manifest(unit_factor:, colors:)`: the millimetre factor for the root model's `unit`, and one
  `"#RRGGBB"`-or-nil per LEAF MESH in import order. `colors` is all-nil for a file with no slicer
  metadata (the engine's own materials stand), so a plain CAD export is untouched.
- **The pages that mount the viewer pass the manifest as data**: `files/show` on the element,
  `models/show` per `<option>` (the source select switches files), read in `load()` beside `url`
  and `format`. No new route.
- **`modelviewer_controller.js` applies colours after `onModelLoaded`** — only when the colour list's
  length equals `model.MeshCount()` (else nothing, `console.info`), only to meshes whose geometry
  carries no vertex colours (a colorgroup'd mesh keeps its own), cloning the material before setting
  `color` (they are shared) and updating `userData.threeMaterials` so the engine's own
  re-materialisation keeps it. `showDims()` multiplies by `unit_factor`.

**Tech:** rubyzip (BSD-2), Nokogiri (MIT), both in the Gemfile. No new dependency.

---

## Task A — the whole slice

**Files:**
- Create: `app/services/maker/three_mf_manifest.rb`, `test/support/three_mf_fixture.rb`,
  `test/services/maker/three_mf_manifest_test.rb`
- Modify: `app/controllers/files_controller.rb` (`#show`, the `:model3d` case),
  `app/controllers/models_controller.rb` (`@viewable_3d` entries gain `manifest`),
  `app/views/files/show.html.erb` (two data attributes on the viewer), `app/views/models/show.html.erb`
  (two data attributes on the element and on each option), `app/javascript/controllers/modelviewer_controller.js`,
  `test/integration/web/files_flow_test.rb`, `test/integration/web/models_flow_test.rb`,
  `test/system/o3dv_test.rb`, `docs/invariants/files-preview.md` (the `:model3d` section — **use the
  Edit tool on this file, never a whole-file rewrite: a sibling implementer is editing its `:gerber`
  section at the same time**).

### A.1 `Maker::ThreeMfManifest`

- [ ] Create `app/services/maker/three_mf_manifest.rb`:

```ruby
require "zip"

module Maker
  # WHAT A SLICER SAID ABOUT A 3MF THAT THE 3MF FORMAT ITSELF DOES NOT CARRY — read here, once, and
  # handed to the browser as data, because the viewer's importer (three.js's 3MFLoader, wrapped by
  # Online3DViewer) cannot know it and never will: Bambu Studio and PrusaSlicer keep a project's
  # filament colours and per-object extruder in their own Metadata/*.config files, and three's loader
  # also ignores the model's declared `unit` (measured: an Onshape export in metres came out 1000×
  # short on the dims line; see the plan in docs/superpowers/plans/2026-09-06-threemf-colours.md).
  #
  # THE ANSWER IS ORDERED THE WAY THE ENGINE IMPORTS: one colour per LEAF MESH, in `<build><item>`
  # order with components resolved depth-first — the order three's loader creates meshes and
  # Online3DViewer's `AddObject` numbers them. The browser matches by that index
  # (`userData.originalMeshInstance.id.meshIndex`), never by name: Bambu's objects have no `name`
  # attribute (the name lives in model_settings.config), so a name match would apply nothing.
  # A count mismatch on the client applies NOTHING — a wrong colour on the wrong part is worse
  # than grey.
  #
  # ONE BOUNDED PORT READ, CACHED BY CONTENT TOKEN, NIL INCLUDED — Maker::GerberArchive's shape and
  # its argument: judged on the catalog's own `size` first (an unknown size is refused), never opened
  # past READ_LIMIT, and a file that answers nil stays nil until its bytes change.
  #
  # NOT HANDLED, ON PURPOSE FOR NOW: painted triangles (Bambu `paint_color`, PrusaSlicer
  # `slic3rpe:mmu_segmentation`). Those are per-triangle extruder assignments the loader drops on
  # import; honouring them needs a custom parse into per-triangle materials, a different piece of
  # work. Volumes in a PrusaSlicer object with their own extruder are likewise triangle RANGES of
  # one mesh — the object's extruder is used for the whole mesh.
  #
  # EVERY FAILURE COLLAPSES TO nil — not a zip, no 3dmodel.model, malformed XML, unreadable store —
  # because every caller answers all of them the same way (no override, factor 1). `rescue` names
  # the port's two, Zip::Error and Nokogiri's SyntaxError, never a bare rescue.
  class ThreeMfManifest
    Manifest = Data.define(:unit_factor, :colors)

    EXT = "3mf".freeze
    # A slicer project is the model plus its thumbnails and settings; 64 MB is well past any of the
    # library's, and past it the read would stream that much off the user's store per page view.
    READ_LIMIT = 64 * 1024 * 1024
    CACHE_TTL = 30.days

    # The 3MF core spec's unit vocabulary, to millimetres. Absent or unknown → 1 (the spec's default
    # is millimeter).
    UNIT_TO_MM = {
      "micron" => 0.001, "millimeter" => 1.0, "centimeter" => 10.0,
      "inch" => 25.4, "foot" => 304.8, "meter" => 1000.0
    }.freeze

    CORE_NS = "http://schemas.microsoft.com/3dmanufacturing/core/2015/02".freeze

    def self.threemf?(name) = File.extname(name.to_s).downcase.delete(".") == EXT

    def self.for(user:, node:)
      return nil unless threemf?(node.name)
      return nil if node.size.nil? || node.size > READ_LIMIT

      token = node.content_hash.presence || node.current_version_id.presence
      Rails.cache.fetch([ "threemf-manifest", node.node_id, token ], expires_in: CACHE_TTL) do
        read(user:, node:)
      end
    end

    def self.read(user:, node:)
      manifest_from(FileLayer.current.read(user, node_id: node.node_id))
    rescue FileLayer::NotFound, FileLayer::FetchError
      nil
    end

    # PUBLIC AND PURE so the tests hand it bytes; `for` is the cached, port-reading door.
    def self.manifest_from(bytes)
      return nil if bytes.blank?

      Zip::File.open_buffer(StringIO.new(bytes.b)) do |zip|
        root = xml(zip, "3D/3dmodel.model") or return nil
        model = root.at_xpath("/c:model", "c" => CORE_NS) or return nil
        factor = UNIT_TO_MM.fetch(model["unit"].to_s.downcase, 1.0)
        leaves = leaf_meshes(zip, root)
        colors = Slicer.for(zip)&.colors_for(leaves) || Array.new(leaves.size)
        return Manifest.new(unit_factor: factor, colors:)
      end
    rescue Zip::Error, Nokogiri::XML::SyntaxError
      nil
    end

    # ... leaf_meshes(zip, root): walk <build><item objectid> in order; resolve each object in its
    # part (the root document, or the p:path file a component names — leading "/" stripped, relative
    # to the zip root); an object with <components> recurses in component order carrying the
    # ROOT item's object id and the component's own objectid; an object with <mesh> emits
    # Leaf.new(item_object_id:, object_id:, path:). A missing part file emits nothing for that
    # component (three's loader would fail that item too). Bound the recursion (depth 16) so a
    # self-referencing component cannot loop.
    #
    # ... xml(zip, path): the entry's bytes parsed with Nokogiri::XML (strict: raise on SyntaxError,
    # rescued above); nil when the entry is absent.
    #
    # Slicer.for(zip): Bambu if "Metadata/model_settings.config" exists, Prusa if
    # "Metadata/Slic3r_PE_model.config" exists, else nil.
    #
    # Bambu#colors_for(leaves): filaments = JSON.parse(project_settings.config)["filament_colour"]
    # (an Array of "#RRGGBB"; absent → all nil). For each leaf: the <object id=ITEM_OBJECT_ID>
    # element in model_settings.config; extruder = its <part id=LEAF_OBJECT_ID>'s
    # <metadata key="extruder"> if present, else the object's own <metadata key="extruder">;
    # colour = filaments[extruder - 1] (1-based; out of range or absent → nil), normalised to
    # "#RRGGBB" upper-case without alpha.
    #
    # Prusa#colors_for(leaves): extruder colours from "Metadata/Slic3r_PE.config" — the line
    # `; extruder_colour = #A;#B;#C` (split on ";", blanks → nil); per leaf: the
    # <object id=ITEM_OBJECT_ID> in Slic3r_PE_model.config, its <metadata type="object"
    # key="extruder" value="N"/> (N is 1-based; 0 or absent → nil); colour = extruder_colour[N-1].
  end
end
```

  Write the elided methods in full — small, private, each doing one thing; keep the class under
  ~200 lines. Verify with the real files if you can reach the share mount (`/Volumes/3D Printing`,
  `find … -iname '*.3mf'`): `bambu-keyboard-storage.3mf`-style files should answer two colours, an
  Onshape export `unit_factor 1000.0` with `[nil]`.

### A.2 The pages hand the manifest to the viewer

- [ ] `FilesController#show`: in the branch that prepares the `:model3d` page, add
  `@viewer_manifest = Maker::ThreeMfManifest.for(user: current_user, node: @node)` (nil for any
  non-3MF — `for` refuses by name first, so it is safe to call unconditionally).
  `app/views/files/show.html.erb`'s `.model-viewer` element gains
  `data-modelviewer-colors-value="<%= (@viewer_manifest&.colors || []).to_json %>"` and
  `data-modelviewer-unit-factor-value="<%= @viewer_manifest&.unit_factor || 1 %>"`.
- [ ] `ModelsController#show`: each `@viewable_3d` entry gains
  `manifest: Maker::ThreeMfManifest.for(user: current_user, node: @page_nodes[a.node_id])`;
  `models/show.html.erb`: the single-file case puts the two attributes on the element; the select's
  `<option>`s carry `data-colors` (JSON) and `data-unit-factor`; `load()` copies them into
  `colorsValue`/`unitFactorValue` beside `url`/`format`.
  **THE QUERY BUDGET**: `page_query_budget_test.rb` asserts constancy in N for these pages. A manifest
  read is a port read (one `live_node!` query on share) per 3MF on the page — fine for the file page
  (one node) and acceptable on the model page (one per 3D file, cached after the first view); state
  it in the controller comment and run the budget test.

### A.3 `modelviewer_controller.js`

- [ ] `static values = { url: String, format: String, lazy: Boolean, colors: Array, unitFactor: { type: Number, default: 1 } }`.
- [ ] In `load()`, beside `url`/`format`: `this.colorsValue = JSON.parse(opt.dataset.colors || "[]")`,
  `this.unitFactorValue = Number(opt.dataset.unitFactor || 1)`.
- [ ] `loaded(gen)`: after the generation check and before `showDims()`, `this.applyColors()`:

```js
  // THE SLICER'S COLOURS, APPLIED BY IMPORT INDEX — Maker::ThreeMfManifest's header has the whole
  // argument. Matched on `userData.originalMeshInstance.id.meshIndex`, the engine's own numbering
  // of the meshes it imported (meshes arrive unnamed from Bambu), and applied ONLY when the list is
  // exactly as long as the model: a mismatch means the walk and the loader disagreed, and painting
  // the wrong part is worse than grey. Meshes that carry their own vertex colours (a CAD export's
  // colorgroup) are left alone. The material is CLONED first — the engine gives every mesh the
  // same material object, so setting the colour on it would paint every part the last colour.
  applyColors() {
    const colors = this.colorsValue || []
    const model = this.viewer?.GetModel()
    if (!model || colors.length === 0 || colors.length !== model.MeshCount()) {
      if (colors.length) console.info(`[modelviewer] ${colors.length} colours for ${model?.MeshCount()} meshes; not applied`)
      return
    }
    const three = this.viewer.GetViewer()
    three.scene.traverse((obj) => {
      const index = obj.isMesh && obj.userData.originalMeshInstance?.id?.meshIndex
      if (index === undefined || index === null || index === false) return
      const hex = colors[index]
      if (!hex || obj.geometry.attributes.color) return
      const material = (Array.isArray(obj.material) ? obj.material[0] : obj.material).clone()
      material.color.set(hex)
      material.vertexColors = false
      material.needsUpdate = true
      obj.material = material
      if (Array.isArray(obj.userData.threeMaterials)) obj.userData.threeMaterials = [material]
    })
    three.Render()
  }
```
  Check the `id.meshIndex` path against the engine at runtime (the plan's probe read it as
  `userData.originalMeshInstance.id.meshIndex`); if the engine names it differently in 0.18.0's
  `threeconverter.js`, use that and say so.
- [ ] `showDims()`: multiply each dimension by `this.unitFactorValue` before formatting, and REWRITE
  the paragraph that says "the formats that declare a unit (3MF, FCStd) already converted by their
  importer" — 3MF is NOT (three's loader ignores `unit`); the factor comes from the server's manifest.

### A.4 Tests

- [ ] `test/support/three_mf_fixture.rb` (mirrors `mesh_fixture.rb`): builds 3MF zips in memory with
  rubyzip — `[Content_Types].xml`, `_rels/.rels` (the model relationship), `3D/3dmodel.model`.
  `cube_mesh_xml(size: 10)` (8 vertices, 12 triangles). `plain_3mf(unit: "millimeter")` — one object
  with the cube, one build item. `bambu_3mf(objects: [{ extruder: 1 }, { extruder: 2 }], filaments: %w[#161616 #F98C36 #FFFFFF])`
  — root model with N container objects each holding ONE component `p:path="/3D/Objects/object_K.model"`,
  build items in a DELIBERATELY NON-ID ORDER (e.g. ids 4 then 2) so an id-ordered walk fails the
  test, `3D/Objects/object_K.model` each holding the cube mesh, `Metadata/model_settings.config`
  (object id = the ROOT container id, a `<part id=K>` inside, extruder on the object and optionally on
  the part), `Metadata/project_settings.config` (`{"filament_colour": [...]}`), plus the `3D/_rels/3dmodel.model.rels`
  three's loader may look for. `prusa_3mf(objects: [{ extruder: 2 }], extruder_colours: %w[#FF0000 #00FF00])`
  — objects with meshes inline, `Metadata/Slic3r_PE_model.config`, `Metadata/Slic3r_PE.config`.
  `write_threemf!` = `MeshFixture#write_model!` with the bytes. **Verify the Bambu-shaped fixture
  actually loads in the viewer** (the system test below does; if three's loader needs a part it
  lacks, add the part — the real Bambu file's entries are listed in the plan's measurements).
- [ ] `test/services/maker/three_mf_manifest_test.rb` (share pinned, `GerberArchiveTest`'s shape):
  1. Bambu two objects, extruders 1 and 2 → `colors == ["#161616", "#F98C36"]`, in BUILD order;
  2. a part-level extruder overrides the object's; an extruder past the filament list → nil;
  3. Prusa object extruder 2 → `["#00FF00"]`; extruder 0 → `[nil]`;
  4. a plain export → `colors == [nil]`, `unit_factor == 1.0`; `unit="meter"` → `1000.0`; `inch` → `25.4`;
  5. not a zip → nil; a zip without `3D/3dmodel.model` → nil; malformed XML → nil;
  6. oversized and unknown `size` → nil and NO port read (the `counting_reads` technique);
  7. the cache: read once per content token, nil included (swap in a MemoryStore as GerberArchive's test does).
- [ ] `files_flow_test.rb`: the 3MF page carries `data-modelviewer-colors-value` (JSON of the manifest)
  and `data-modelviewer-unit-factor-value`; an STL page carries `[]` and `1`.
  `models_flow_test.rb`: with two 3D files, each `<option>` carries `data-colors`/`data-unit-factor`.
- [ ] `test/system/o3dv_test.rb`:
  1. a Bambu-shaped fixture with two cubes (extruders 1 and 2) reaches `ready`, and
     `page.evaluate_script` reading the scene's mesh materials (via `window.Stimulus.getControllerForElementAndIdentifier(el, "modelviewer").viewer.GetViewer().scene`,
     `material.color.getHexString()` per mesh ordered by `userData.originalMeshInstance.id.meshIndex`)
     returns `["161616", "f98c36"]`;
  2. a `unit="meter"` cube of 10 units reads "10,000 × 10,000 × 10,000 mm" in the dims line.
- [ ] **MUTATIONS (run for real, output in the PR, then `git checkout -- <file>`):**
  - M1 manifest: walk `<object>` elements in document order instead of `<build><item>` order → case 1 red;
  - M2 manifest: ignore the part-level extruder → case 2 red;
  - M3 controller: apply colours without the count check (`colors.length !== MeshCount` removed) —
    write the system case so it catches a wrong application: give the fixture THREE colours for two
    meshes and assert both stay default (`969aa9`-ish: read the default material colour once and
    compare) → red without the check;
  - M4 controller: `showDims()` without the factor → case 2 (system) red;
  - M5 manifest: unknown `size` no longer refused → case 6 red.
- [ ] Green: the three new/changed test files, `page_query_budget_test.rb`, `stimulus_hygiene_test.rb`,
  `template_hygiene_test.rb`, `lazy_bundles_test.rb`, `docs_hygiene_test.rb`; `bin/rubocop` on every
  Ruby file touched; then bare `bin/ci` once at the end (with `TINKEREX_SYNC_DIR` set).

### A.5 Docs

- [ ] `docs/invariants/files-preview.md`, `:model3d` section (Edit tool only): a paragraph —
  **3MF units and slicer colours come from the server's manifest, not the importer**: three's loader
  ignores `unit` (measured 1000× on an Onshape export) and cannot see Bambu/Prusa metadata; the
  manifest is one bounded, cached port read (GerberArchive's shape); colours are applied by the
  engine's mesh index, only on an exact count match, never to a mesh with vertex colours; painting
  is not handled and volumes use the object's extruder.
- [ ] Sweep every comment that claims 3MF units are converted by the importer:
  `grep -rn "declare a unit\|3MF, FCStd\|converted by their importer" app/ docs/invariants/`.

## Self-review

- Spec coverage: colours (A.1–A.3), units (A.1, A.3), both pages (A.2), tests + mutations (A.4), docs (A.5).
- Type consistency: `Manifest#colors` is an Array of `"#RRGGBB"`/nil, length = leaf count; the JSON on
  the page is that array; `applyColors` indexes it by `meshIndex`; `unit_factor` is a Float, the
  attribute a Number.
- Painting and Prusa volumes are excluded and written down in three places (class header, doc, PR).
