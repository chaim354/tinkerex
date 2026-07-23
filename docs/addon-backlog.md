# Addon backlog

A running idea list for `/tools` addons, captured from a brainstorming session (2026-07).
Not a plan — a menu to pick from. See `docs/superpowers/specs/2026-07-20-addon-framework-boxes-design.md`
for how addons are built (registry + `AddonState`/`AddonFile` + `Maker::Addons::LibraryOutput`).

## How to read this

An addon takes one of two **shapes**, which drives licensing and effort:

- **Permissive library, in-process** — a Ruby gem / small service bundled directly (MIT/Apache/BSD).
- **GPL sidecar, isolated** — the boxes.py pattern: a separate container invoked over HTTP so GPL
  code never touches the permissive Rails app (§9 in `CLAUDE.md`).

And it runs on one of two **sides**:

- **Client** — pure browser (JS/Stimulus). Rails just serves the page and saves the output via the
  existing `LibraryOutput`. Cheapest, most self-contained.
- **Server** — needs a sidecar engine, a server-side library, the maker DB (inventory/projects/BOM),
  or an external API.

The leverage is **shared engines**: build one engine, get many addons. Those are grouped below.
Anything that **produces a file** (SVG/STL/DXF/PDF/image) drops into the library and auto-thumbnails
with the `Maker::Previews` renderers already shipped.

Tags: `[client]` `[server]` · `[lib]` permissive dep · `[sidecar]` GPL-isolated · `[api]` external. ⭐ = standout.

---

## Client add-ons (browser-side, grouped by engine)

### Engine — Maker.js (Apache-2.0) · form → 2D SVG/DXF
Build the param-driven drawing harness once, reuse for a whole family. These are boxes.py-shaped but
simple enough to compute in JS (no sidecar):
- **Material test grid** ⭐ — power × speed sweep (the laser classic; most obviously-missing generator)
- Kerf & focus test cards
- Living-hinge / lattice-flex pattern
- Bolt-circle / hole-pattern → DXF
- Inlay generator (kerf-comp male/female)
- Badge / keychain / tag maker

### Engine — Method Draw / svg-edit (MIT) · embeddable SVG canvas
- In-app **laser SVG editor** — add cut/score/engrave layer conventions + kerf offset

### Engine — Kiri:Moto (MIT) · in-browser CAM
- SVG/DXF/STL → **G-code toolpaths** (laser + CNC)

### Engine — browser canvas (no dependency)
- Halftone / dither for engraving (image → dithered SVG)

### No engine — pure JS calculators / reference
- **Maker Calculators gallery** ⭐ — Ohm's law, LED resistor, GT2 belt, gear/pulley ratio, stepper
  resolution, board-foot, material weight, print cost… (one addon, ~15 tools)
- Feeds & speeds calculator (math is client; the bit library that feeds it is Server → inventory)
- Tap/drill & thread-pitch charts

---

## Server add-ons (grouped by engine)

### Engine ① — OpenSCAD sidecar (GPL-isolated) · `.scad` + params → STL ⭐ one engine, whole catalog
- Gridfinity bins/baseplates
- Gears / pulleys / threaded parts (3D)
- Nameplate / extruded-text → STL
- Ultimate Box Maker (enclosures)
- Calibration prints (temp tower, tolerance, retraction)
- Generic "wrap any `.scad`" Customizer

### Engine ② — CadQuery / build123d sidecar (Apache-2.0) · Python → STEP/STL
- Parametric CAD parts (permissive; produces real **STEP**, not just mesh)

### Engine ③ — Geometry/CAD processing sidecar (FreeCAD-cli LGPL · Assimp BSD · Manifold Apache)
- **STEP/IGES → STL converter** ⭐ (closes a current preview gap — STEP/OBJ/IGES aren't previewable today)
- Mesh repair / heal (Manifold)
- Universal mesh convert STL↔3MF↔OBJ↔PLY (Assimp)
- STL → stacked laser slices

### Engine ④ — `Maker::Previews` (already built!) · register a renderer — cheapest server adds
- Gerber preview (tracespace, MIT)
- G-code thumbnail

### Engine ⑤ — Label/code gen (Ruby: rqrcode + barby, MIT) → SVG/PDF
- QR code generator
- Barcode generator
- **Inventory label sheets** ⭐ (name + QR/barcode that deep-links to the item's location)
- Cable / component / resistor labels

### Engine ⑥ — G-code parser (Ruby)
- Cost/time estimator
- Color-change / M600 inserter
- Filament auto-decrement (also hits Engine ⑦)

### Engine ⑦ — inventory/projects/BOM data model ⭐⭐ THE MOAT (nothing else has this data)
- **"Can I build this?"** — BOM vs stock → shortfall + shopping list
- Low-stock reorder / shopping-list export
- Bin finder / location map (pairs with QR labels)
- Project → printable build report
- Tool library (endmills/bits as inventory) — backs the feeds & speeds calc
- Barcode scan-to-inventory (client scanner UI + this)

### Engine ⑧ — external-API integration (server HTTP client + secret store)
- Part lookup → inventory (Octopart / LCSC / DigiKey)
- Send-to-printer (OctoPrint / Moonraker / Bambu)
- Import from Onshape (MCP already connected) / Thingiverse / Printables

### Engine ⑨ — image processing (vtracer MIT Rust CLI · PIL/numpy)
- Raster → SVG trace (vtracer — shells out like the resvg/stl-thumbnailer binaries)
- Lithophane (image → STL)

### Engine — nesting (SVGnest, MIT)
- Cut-list optimizer · irregular-shape sheet nesting
- (SVGnest is JS → can run client-side in a web worker; push big jobs to the server)

### Spans both sides
Barcode scan-to-inventory (client scanner + server DB) · feeds & speeds (client calc + server tool
library) · filament auto-decrement (client trigger + server parse + DB).

---

## CNC / hobbyist tooling — complements MillMage

MillMage = LightBurn's CNC counterpart (launched Feb 2026, $99/$199): design + CAM (Pockets, Profiles,
Drills, **Dogbone Slots**, Rest Pockets, Fluting) + GRBL control. Its own positioning: it **assumes you
know feed rates, spindle speeds, and workholding** — unlike LightBurn, which hobbyists could pick up
cold. That assumed knowledge (plus machine calibration and post-CAM gcode chores) is the addon surface —
the ecosystem tooling laser users get for free but CNC users don't.

**A. Feeds & speeds** `[client calc + server library → ⑦]` — the #1 thing it punts on
- **Feeds & speeds calculator** ⭐⭐ — chip load, SFM→RPM, feed, DOC/WOC, MRR + hobby-router
  rigidity/spindle-power sanity check
- **Bit library** — router bits/endmills as inventory items → auto-fill the calculator
- **Material recipe book** — starting numbers per material × bit, saved + tunable
- *(Differentiator vs G-Wizard/FSWizard: theirs are standalone; yours is wired to real bit inventory + the project being cut)*

**B. Calibration & test cuts — the CNC "material test grid"** `[client/server → new G-code engine]`
- **Feeds & speeds test coupon** ⭐⭐ — slots sweeping feed × RPM × DOC to dial in a material
- Fit/tolerance coupon (pegs + pockets at stepped offsets → press vs slip fit)
- Steps/mm & backlash calibration (cut a known square, measure, get GRBL `$100–102`/backlash)
- Cutter runout / true-diameter probe

**C. Machine maintenance generators** `[client/server → G-code engine]`
- **Spoilboard surfacing / stock flattening** ⭐ — parametric gcode (area, bit dia, stepover, DOC)
- Hold-down screw pattern → drill gcode

**D. Workholding** `[client → Maker.js]`
- Clamp / cam-clamp / fence / stop-block generators → DXF/gcode

**E. Post-CAM utilities on the gcode/.mage in your library** `[server → ⑥ + ④]`
- **G-code toolpath preview** ⭐ — thumbnail the paths (rides Previews); spot a rapid-through-stock
- Time & cost estimator (real cut time incl. rapids + tool changes)
- Envelope / bounds checker (does it fit my machine? where's origin/Z-zero?)
- **Manual-tool-change splitter** ⭐ — split a multi-bit job into per-tool files / insert `M0` pauses

**F. Stock planning** `[server → ⑦]`
- Cut-list / sheet-goods optimizer + offcut tracking

**Skip — MillMage already does these:** dogbone slots, rest pockets, fluting, firmware-specific gcode
output (no post-processor needed), V-carve / relief / True Nesting (Pro). Only worth building for
non-MillMage flows.

---

## Purpose-built SVG editors for laser/CNC (research findings)

A full interactive **editor** can't be a headless sidecar (boxes.py works because it's params-in →
SVG-out). For a web app an embeddable editor must be **browser JS** — desktop OSS (Inkscape/LibreCAD)
can only run headless for conversion, not embed.

| Tool | Type | License | Embeddable? |
|---|---|---|---|
| Cuttle | Purpose-built browser laser editor | Proprietary SaaS | No — best design reference |
| LightBurn | Purpose-built desktop laser editor | Proprietary | No (already interop via `.lbrn2`) |
| **Method Draw / svg-edit** | General browser SVG editor | **MIT** | **Yes** — `svgcanvas.js` embeds |
| **Maker.js** | Programmatic 2D → SVG/DXF/PDF | **Apache-2.0** | Yes, as a library (generators) |
| **Kiri:Moto** | Browser CAM → G-code | **MIT** | Yes — but CAM, not editing |
| MeerK40t | Laser control + light editing | MIT | No — Python/wx desktop |
| Inkscape + laser extensions | Desktop editor + ecosystem | GPL | No |

**Conclusion:** there is no permissive, browser-embeddable, purpose-built-for-laser SVG editor to drop
in. Best paths: (1) lean on **generators** (fits the architecture, users keep LightBurn/Inkscape);
(2) a **Maker.js** parametric-drawing addon (80% of the value, fraction of the effort); (3) embed
**Method Draw** + laser conventions if in-app freehand editing is truly wanted.

---

## Additions — 2026-07-22 brainstorm

Genuinely additive to the menu above. The backlog's thesis is "one **engine** → many addons"; these add
a second leverage axis: **shared _data_ → many addons** (the inventory moat is the original example).
⭐ = standout / high-leverage.

**Shared-data addons (make many generators smarter):**
- **Machine library ⭐** `[server → new data model]` — each machine's specs (bed/work area, laser wattage,
  spindle power, travel, Z). Like the tool library, but *feeds* bounds-checker, feeds & speeds, surfacing,
  and test-coupon generators so they stop re-asking machine facts.
- **Material settings library ⭐** `[server → new data model]` — power/speed/passes per material × thickness
  (LightBurn's material library, web + shareable). The backlog only has the *CNC* recipe book; the **laser**
  equivalent is arguably the #1 wanted laser feature. Extends to 3D print profile presets.

**3D-print depth** (underrepresented vs. laser/CNC):
- **Spool / filament manager** `[server → ⑦]` — weight, cost/g, auto-decrement from the print log (a full
  manager, vs. the backlog's bare "filament auto-decrement").
- **G-code / 3MF print-settings inspector** `[server → ⑥]` — layer height, infill, temps, est. time/filament
  as a card (rides the G-code parser engine).
- **Print tuning journal** `[server → ⑦]` — structured notes tying a model + the settings that worked.

**Electronics depth** (backlog has only Gerber preview + part-lookup):
- **Resistor color-code decoder** (bidirectional) `[client]`, **EE calculator pack** (voltage divider, RC
  filter, 555 timer, LED array) `[client]` — fold into the Calculators gallery.
- **Pinout reference cards** `[client, reference]`; **PCB-BOM → inventory** matching `[server → ⑦ + ⑧]`.

**Woodworking / joinery** (underrepresented):
- **Finger / dovetail / box-joint generators** → DXF `[client → Maker.js]`; **1D lumber cut optimizer**
  `[client/server]` (distinct from the 2D sheet nester); **shelf-pin / hinge boring templates** → DXF.

**AI-assisted ⭐ (Claude-native — differentiates this stack):**
- **Natural-language → parametric params** `[server → ① / ②]` — describe a part → OpenSCAD/CadQuery inputs.
- **Auto-tag / describe uploaded models** from their thumbnails `[server → vision]`.
- **"What can I make from my inventory?"** `[server → ⑦]` — the AI cousin of the deterministic "Can I
  build this?".

**Model report / spec-sheet:**
- **STL/3MF dims + volume + material cost → PDF spec sheet** `[server → ③]` — derived from the *actual*
  uploaded geometry, vs. the backlog's manual-input print-cost calculator.

**Machine maintenance scheduler** `[server → ⑦/projects]` — machine-hours + consumables + service intervals
("replace laser tube at N hours", "lube CNC rails"). Pairs with the Machine library.

---

## Roadmap (sequenced)

Ordered by leverage × cost × dependency (client-only < permissive lib < GPL sidecar < external API; data
addons precede or pair with their consumers).

**Phase 1 — Client generators** *(no new infra; proves the client-only side, unproven until now)*
- **Maker.js harness → Material Test Grid ⭐** ← **specced:** `docs/superpowers/specs/2026-07-22-makerjs-generator-harness-design.md`
- then (same harness, each a JS module): kerf/focus cards, bolt-circle→DXF, living-hinge, inlay, badge/tag maker
- in parallel: **Calculators gallery ⭐** (~15 tools) folding in the new resistor decoder + EE pack

**Phase 2 — Shared-data addons + first consumers** *(the moat + the new data-leverage axis)*
- **Machine library ⭐**, **Material settings library ⭐** (new) → then **Feeds & speeds + bit/tool library**
  (consumes both), **Inventory QR/barcode label sheets ⭐** (Engine ⑤), **"Can I build this?" ⭐** (Engine ⑦)

**Phase 3 — Server sidecars** *(heavier; reuses the proven boxes.py deploy pattern)*
- **OpenSCAD sidecar ⭐** (Engine ①) → Gridfinity/gears/nameplate/calibration/generic customizer
- **STEP→STL ⭐** (Engine ③, closes a live preview gap), mesh convert/repair + the new **STL dims/volume/cost report**

**Phase 4 — G-code / CAM / post-processing**
- G-code + Gerber thumbnail previews (Engine ④, ride Previews — cheap), cost/time estimator,
  **manual-tool-change splitter ⭐**, bounds checker (consume Machine library), CNC test coupons,
  spoilboard surfacing, later Kiri:Moto

**Phase 5 — External APIs + AI + 3D-print depth**
- Part lookup→inventory, send-to-printer (OctoPrint/Moonraker/Bambu), the new **spool/filament manager +
  print-settings inspector + tuning journal**, the new **AI cluster** (NL→parametric, auto-tag, "what can I
  make"), **maintenance scheduler**, image (vtracer/lithophane/dither)

Engines ①, ⑤, ⑦ unlock ~18 addons between them; Engine ④ rides infrastructure already shipped. The two new
**data** addons (Machine + Material libraries) are the Phase-2 force multipliers — like inventory, they make
a dozen generator addons smarter.
