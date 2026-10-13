# Research: the Maker App Layer — what to build, in what order, and why

> **HISTORICAL — not re-verified.** Written before the repository split of 2026-08-20, when the
> sync engine and the Rust client still lived here (they are `chaim354/tinkerex-sync` and
> `chaim354/tinkerex-client` now). Kept for its reasoning and its measurements; it does not
> describe what this repository contains today. The current map is `docs/README.md`.


**Date:** 2026-06-15 · **Audience:** project owner (engineer) · **Scope:** the product layer
(§12 step 9) that sits on top of the already-built local-first sync engine —
**Projects, Inventory, BOM, and file preview** for hardware / 3D-print / CNC / laser /
electronics makers.

This is a prioritized, evidence-backed recommendation. It does **not** relitigate the file
layer (that's `docs/research-sync-competitors.md` + `docs/parity-roadmap.md`); it assumes the
file layer as a *given foundation* and asks: given a versioned, content-addressed,
`node_id`-referenceable file vault that already exists, **what product do we build on it, and
what's the highest-leverage first slice?**

---

## 0. The one-paragraph thesis

Every tool a maker uses today is a **silo**: Manyfold organizes 3D files but knows nothing
about your parts; InvenTree tracks parts + BOMs but treats CAD as dumb attachments with no
versioning or preview; Spoolman tracks filament but nothing else; build logs live in
Hackaday.io / Notion / a `README.md` disconnected from both. **Nobody owns the graph that
connects a *project* → its *design files* (versioned) → its *BOM* → the *inventory* it
consumes.** We already own the hardest piece of that graph — a Dropbox-class versioned file
vault with stable `node_id`s — that the 3D-file managers bolt on badly and the inventory tools
don't have at all. **The product is the connective tissue, and the file layer is the moat the
competitors can't cheaply replicate.** Build *Projects* first as the spine, hang versioned
files and a BOM off it, then Inventory, then preview as the polish that makes the whole thing
feel alive.

---

## 1. The competitive landscape (what makers actually use, and where it hurts)

### 1a. 3D-file / model management

| Tool | Killer feature | What makers complain is missing | Self-host / license |
|---|---|---|---|
| **Manyfold** | Self-hosted DAM for 3D print files: in-browser 3D preview (THREE.js + server-side Mittsu render), tags/collections, **version history**, ActivityPub federation to share/subscribe across instances. The closest analog. | No inventory, no BOM, no notion of a *project* (it's a library, not a workshop). Federation is its differentiator but irrelevant to a private maker. ~475 open issues. **No parts/electronics side at all.** | Self-host (Rails + Postgres + Sidekiq). **⚠️ AGPL-3.0 — copyleft. Study patterns, do NOT vendor code.** |
| **Printventory** | Directory-scan + catalog STL/3MF (≤50 MB), 3D preview, tags/designer tracking, **print-status tracking** (printed / planned / in-progress), source URLs, **AI auto-tagging**, optional server mode. | Electron desktop-first; 50 MB cap; no real versioning (scans a folder, doesn't *own* version history); no inventory/BOM; no projects. | Freemium desktop app. Not self-host-first, closed. |
| **GyroidVault / printBed / Modelist** | Various self-hosted "model library" takes; thumbnails + tags. | Same gap: library, not workshop. No BOM/inventory/project graph. | Mixed. |
| **Thingiverse / Printables / MakerWorld / MyMiniFactory** | Discovery + community + remixes; MakerWorld has one-click print into Bambu Handy. | **Cloud-locked, not your data**; MakerWorld is a Bambu walled garden (2025 firmware lockdown — Bambu Connect middleware). No private/self-host story. | SaaS, proprietary. |

**Pattern:** the self-hostable model managers are all **libraries** (organize files), not
**workshops** (run projects that consume parts). And the best of them, Manyfold, is **AGPL** —
which (a) we can't borrow code from per §9, and (b) means a permissive competitor in this exact
niche is *open territory*. Makers repeatedly describe the core pain as **lost/mis-versioned
files** ("spending hours tweaking a model only to lose the final version, or printing the wrong
file"; Stratasys: ~15% of print-shop hours wasted tracking down work-order state). Our file
layer already *solves the versioning pain* the file managers bolt on weakly — that's the wedge.

### 1b. Inventory / parts / BOM

| Tool | Killer feature | What makers complain is missing | Self-host / license |
|---|---|---|---|
| **InvenTree** ⭐ | The closest BOM/inventory analog and **the one to study hardest.** Parts + categories + **stock by location** + supplier/manufacturer records; **multi-level BOMs**; **Build Orders** that *allocate* stock against a BOM (intent-to-consume, auto-allocate oldest-first, substitutes); **barcode** scan-in (DigiKey/Mouser/LCSC/TME) + supplier part-import; full REST API + plugin system. | CAD/3D files are **dumb attachments** — no versioning, no preview, no link to a design-file *version*. It's an inventory/MRP system that happens to attach files, not a design tool. Heavyweight Django/React; "ERP for parts," not maker-cozy. | Self-host (Django + Postgres). **✅ MIT — permissive. Safe to study the data model and integrate via its REST API.** |
| **PartsBox** | Low-friction electronics ERP/MRP/PLM; shares a parts DB with KiCad/Altium; "meta-parts" group interchangeable substitutes; BOM pricing + small-batch production. | Cloud SaaS, proprietary, electronics-only (no 3D/CNC/laser side). | SaaS, proprietary. |
| **BOMIST / Part-DB / PartKeepr** | Free tiers / self-host for electronics parts. | Electronics-only; aging (PartKeepr); no design-file integration. | Mixed (Part-DB is AGPL — ⚠️). |
| **Spoolman** ⭐ | **The filament-inventory standard.** Tracks every spool: material, color, manufacturer, weight, **remaining filament**; **auto-decrements as you print** via OctoPrint/Klipper/Moonraker; clean REST API + community filament DB; SQLite. | Filament-only by design. No parts/fasteners, no BOM, no projects. | Self-host (Python + SQLite). **✅ Permissive (MIT-style).** Integrate, don't rebuild. |

**Pattern:** InvenTree is the gold standard for the *parts → BOM → build → stock-allocation*
graph and is **MIT**, so we can study its data model freely and even integrate it. But it has
the inverse weakness of Manyfold: **it treats design files as dead weight.** Our advantage is
that our "BOM line" can point at a *versioned `node_id`* (this STEP at version 7), and our
"part" can be a physical component *or* a design file — InvenTree structurally can't do that.

### 1c. Build logs / project tracking

Makers cobble this together from **Hackaday.io project pages** (chronological build logs +
components list, but cloud-locked and social), **GitHub** (great for firmware/versioning, wrong
shape for hardware + a build narrative), and **Notion/Obsidian** (flexible but disconnected from
the actual files and parts). There is **no self-hosted tool that unifies a build log with the
versioned design files and the BOM/inventory it consumes.** This is the clearest white space.

### 1d. File preview expectations

The bar is set by in-browser viewers: **Online3DViewer** (`3dviewer.net`) imports STL, 3MF, OBJ,
STEP, IGES, BREP, PLY, AMF and more via **three.js + occt-import-js + rhino3dm + web-ifc**, all
**MIT**. For our stack:

- **STL / 3MF / OBJ / PLY:** trivial — three.js loaders, client-side, MIT.
- **STEP / IGES / BREP** (the CAD formats makers actually design in): **occt-import-js** — an
  Emscripten/WASM build of OpenCASCADE that converts STEP→mesh **in the browser**, MIT
  (the `kovacsv` projects). This is the unlock: CAD preview with **no server-side FreeCAD job
  required** for v1.
- **Thumbnails (the cheap 80%):** 3MF files from every modern slicer (Prusa/Bambu/Cura) **embed
  a PNG thumbnail** — extract it with **lib3mf** (BSD-2, 3MF Consortium) for an instant
  gallery, zero rendering. For STL, **stl-thumb** (Rust, MIT) renders a thumbnail offscreen.
- **LightBurn (`.lbrn2`):** XML; a 2D SVG-ish preview is a small custom parser, low priority.

**Licensing for preview is clean across the board** (three.js MIT, occt-import-js MIT, lib3mf
BSD, stl-thumb MIT) — no landmines. (Watch: `web-ifc` is for IFC/BIM, irrelevant to us; skip.)

---

## 2. The differentiation argument (vs cobbling Manyfold + InvenTree + Hackaday)

If a maker today wants the full picture they run **three+ disconnected apps** and manually keep
them in sync. The thing none of them has — and that we are *uniquely* positioned to build — is
**one graph**:

```
   Project "Lamp v2"
     ├── Build log (dated entries, photos, notes)
     ├── Tasks
     ├── Files  ──────────►  node_id @ version   ← OUR file layer (versioned, preview-able)
     │     enclosure.step @ v7, base.stl @ v3, firmware/ …
     └── BOM
           ├── line: 4× M3×8 bolt   ──►  Inventory part (qty on hand, location, supplier)
           ├── line: 1× enclosure   ──►  FILE node_id @ v7  (a BOM line that IS a design file!)
           └── line: 0.2 kg PLA     ──►  (Spoolman spool, via integration)
```

Three structural advantages no competitor combination has:

1. **BOM lines that reference a versioned design-file `node_id`, not a dead attachment.** "This
   build consumed enclosure.step **at version 7**." When you rev the CAD, the project records
   *which version* shipped. InvenTree can't (no file versioning); Manyfold can't (no BOM).
2. **The file vault is already best-in-class** (CDC + block-delta + native versioning beat
   Nextcloud/ownCloud/Seafile per the sync research). Competitors bolt a weak file story onto a
   strong inventory app or vice-versa. **We bolt a strong product onto a strong file vault.**
3. **Permissive + self-host + managed, one codebase.** Manyfold (AGPL) can't be the commercial
   permissive self-host+SaaS play; InvenTree is MIT but is ERP-shaped, not maker-cozy, and has
   no design-file DNA. The unoccupied square is **"permissive, self-hostable, file-first maker
   workshop."** That's us.

The moat is the **file layer × the graph**. A competitor can clone our Projects UI in a weekend;
they cannot cheaply clone a versioned content-addressed sync engine underneath it.

---

## 3. Ranked feature list for the maker app layer

Effort key: **S** ≈ days · **M** ≈ 1–2 weeks · **L** ≈ multi-week. Every item notes how it
leverages the existing file layer (`node_id` refs + versioning + the existing web file browser /
version-history / restore UI).

### MUST-HAVE (the core graph)

**1. Projects (the spine) — S→M.**
*What:* a `Project` entity (name, description, status, tags) that **owns/links a folder of files
by `node_id`**, plus simple **tasks** and a chronological **build log** (dated markdown entries +
attached photos/files). *Why makers want it:* the unmet need — a self-hosted workshop home for
"everything about Lamp v2" that *stays attached to the actual files*, replacing the
Hackaday.io/Notion/`README` sprawl. The build-log + "which file version shipped" combo is the
white space (§1c). *Leverages the file layer:* directly — a project references files by stable
`node_id`; "attach file" reuses the existing browser; build-log entries can pin a file *version*.
*Complexity:* **S** for the entity + file links + build log; **M** with tasks + the project-scoped
file view. *Licensing:* none (our own Rails models). **This is the recommended first slice — see §4.**

**2. Inventory (parts on hand) — M.**
*What:* `Part` (name, category, description, optional design-file `node_id`), `StockItem`
(quantity, **location**, supplier, cost, **min-stock threshold** → low-stock flag), `Location`
tree (bins/shelves/drawers). Model the **part-vs-stock split** straight from InvenTree (a Part is
the *type*; StockItems are *physical quantities at locations*) — it's the proven shape and it's
MIT to study. *Why makers want it:* one of the three product pillars (§1 CLAUDE.md); "where are
my M3 bolts, how many left, who do I reorder from." *Leverages the file layer:* a Part can *be* a
design file (`node_id`) — a printed bracket is simultaneously inventory and a versioned model,
which InvenTree structurally can't express. *Complexity:* **M** (location tree + stock
transactions are the real work). *Licensing:* none (study InvenTree's MIT model, write our own).

**3. BOM that links files ↔ inventory — M.**
*What:* a `Project`/assembly has BOM lines; each line references **either an Inventory `Part`**
(4× M3 bolt) **or a design-file `node_id` @ version** (1× enclosure.step @ v7), with quantity +
notes. A "build" action can **allocate/decrement** stock (InvenTree's intent-to-consume model,
kept simple for v1). *Why makers want it:* closes the loop — a project knows what it's made of,
in parts *and* files, and what a build consumes. This is the **integration centerpiece** and the
single biggest differentiator (§2). *Leverages the file layer:* the killer move — **a BOM line
that points at a versioned `node_id`.** *Complexity:* **M** (the link table is easy; stock
allocation/decrement is the depth — ship link-only first, allocation second). *Licensing:* none.

### SHOULD-HAVE (makes it feel alive)

**4. In-browser file preview (STL/3MF/OBJ + 3MF thumbnails) — S→M.**
*What:* click a file in the web UI → interactive 3D view; gallery thumbnails for the file browser.
*Why makers want it:* core to a 3D/CAD tool (CLAUDE.md §1 "in-browser preview"); the visual
payoff that makes Projects/Inventory feel like a *maker* tool, not a spreadsheet. It's also the
most-demoed feature of every competitor. *Leverages the file layer:* renders bytes hydrated
on-demand from the existing chunk store; **3MF embedded-thumbnail extraction (lib3mf) needs only
the file's first chunks** — pairs with progressive/range hydration (already built). *Complexity:*
**S** for STL/OBJ/3MF via three.js + thumbnails via lib3mf/stl-thumb; **M** to also do STEP.
*Licensing:* **clean** — three.js MIT, lib3mf BSD-2, stl-thumb MIT.

**5. STEP/IGES CAD preview (occt-import-js) — M.**
*What:* extend the viewer to the formats makers actually *design* in (STEP/IGES/BREP) via the
WASM OpenCASCADE importer, **client-side, no server job**. *Why makers want it:* CAD preview is
the hard one every viewer struggles with; doing it self-hosted + in-browser is a standout.
*Leverages the file layer:* same hydrate-and-render path as #4. *Complexity:* **M** (WASM
integration, large-file handling, mesh tessellation tuning). *Licensing:* **occt-import-js is
MIT** — but **verify the bundled OpenCASCADE build's license terms** (OCCT core is LGPL-2.1 with
an exception; the WASM port ships MIT — confirm the exact artifact before shipping). *Watch-item.*

**6. Print/job history + settings capture — S→M.**
*What:* per-file or per-project, log "printed on , 0.2 mm layer, PLA, 4 h, success/fail" with
notes. *Why makers want it:* the recurring file-management pain (§1d) is "which settings/version
actually printed well"; Printventory's print-status tracking exists *because* of this need.
*Leverages the file layer:* a print record pins a **file `node_id` @ version** → "this exact
version printed great at these settings." *Complexity:* **S** (a log table) → **M** with the
optional integrations below. *Licensing:* none.

### NICE-TO-HAVE (ecosystem + reach)

**7. Spoolman integration (filament inventory) — S.**
*What:* don't rebuild filament tracking — **integrate Spoolman's REST API** so a project/print
record can reference a spool and optionally decrement it. *Why:* Spoolman is the de-facto standard
with auto-decrement from OctoPrint/Klipper; reinventing it is wasted effort. *Complexity:* **S**
(API client + a link field). *Licensing:* clean (Spoolman is permissive; we just call its API).

**8. Supplier part lookup / barcode (Octopart / LCSC / DigiKey / Mouser) — M.**
*What:* add a part by scanning a supplier barcode or looking up an MPN; auto-fill manufacturer/
supplier/datasheet (InvenTree's barcode + part-import model). *Why makers want it:* hand-entering
electronics parts is the #1 inventory friction. *Complexity:* **M** (per-supplier API quirks, API
keys; Octopart's API is now paid/Nexar — prefer free LCSC/distributor barcodes first).
*Licensing:* clean code-wise; **watch the data-source terms** (Octopart/Nexar API is commercial,
rate-limited — a *managed-tier* feature, not a self-host default). *Watch-item.*

**9. OctoPrint / Moonraker / printer integration — M→L.**
*What:* push a file to a printer, pull job status into the project's print history. *Why:* closes
the loop to the physical print. *Complexity:* **M→L** (the Bambu 2025 lockdown makes their
ecosystem hostile; OctoPrint/Klipper/Moonraker are the open, integrable targets — see OctoEverywhere's
matrix). *Licensing:* OctoPrint core is AGPL — **integrate via its REST API, never vendor code.**
*Watch-item.* Lower priority; defer until the core graph + preview prove out.

**10. Tags / collections / full-text search across the graph — S→M.**
*What:* tags on projects/parts/files; search "everything about the lamp." *Why:* organization is
table-stakes (every competitor leads with it). *Complexity:* **S→M** (Postgres FTS / SQLite FTS5;
adapter-agnostic per §7). *Licensing:* none. Fold in incrementally.

### DON'T-BUILD (or defer hard)

- **ActivityPub federation (Manyfold's signature).** Wrong audience for a private maker workshop;
  high complexity; defer indefinitely unless a sharing product emerges.
- **Full ERP/MRP** (purchase orders, sales orders, production planning). InvenTree's territory;
  over-serves the solo maker. Stop at parts + BOM + simple build allocation.
- **Real-time co-editing / Office-style collab.** Out of scope (matches the sync roadmap's
  don't-chase).
- **Rebuilding filament tracking.** Integrate Spoolman (#7) instead.

---

## 4. Recommended FIRST SLICE — validate the handoff's "Projects" call

**Verdict: the handoff is right — build Projects first — but with a sharp scoping rule that makes
it a vertical slice, not a hollow shell.**

**Why Projects first (the case):**
1. **It's the spine the other two pillars hang off.** Inventory and BOM only deliver their unique
   value *in the context of a project* ("what does Lamp v2 consume"). A BOM with no project is just
   a parts list (InvenTree already does that better); a BOM *inside a project that links versioned
   files* is the differentiator. Projects is the entity that makes the graph a graph.
2. **It exercises the file layer immediately and proves the integration thesis** — "attach a
   versioned file to a project, pin which version, open its history/restore." That reuses the
   *existing* web file browser + version/restore UI (already built), so the marginal cost is the
   `Project` model + the `node_id` link, not new file plumbing. Fastest path to a *demonstrably
   differentiated* artifact.
3. **It's the clearest white space** (§1c): no self-hosted tool unifies a build log with the
   versioned files it documents. Inventory (InvenTree) and filament (Spoolman) are *solved* by
   permissive incumbents we can integrate; Projects-over-a-versioned-vault is *unoccupied*.
4. **Lowest risk, highest learning.** It's mostly our own Rails models over a file layer we
   control — no external API quirks, no WASM, no barcode hardware. We learn how the product layer
   should reference `node_id`s *before* committing to the heavier Inventory/BOM data model.

**The scoping rule (so it's a real slice, not a toy):** ship Projects with **(a) file
attachment-by-`node_id` + version pinning** (reusing the existing browser/version UI) and **(b) a
dated build log**, and **(c) one preview format wired in** (STL/3MF via three.js — feature #4's
cheap half). That trio — *a project, its versioned files, and you can see them* — is the smallest
thing that already beats "a Notion page + a folder" and shows the moat. Tasks, then Inventory, then
the BOM link, then STEP preview follow in that order.

**Sequence:** **1) Projects + file links + build log + STL/3MF preview (first slice)** → 2) Tasks +
project-scoped file view + 3MF thumbnails → 3) Inventory (parts/stock/locations) → 4) BOM linking
files↔inventory (the centerpiece) → 5) STEP/IGES preview → 6) print history → 7) Spoolman + supplier
lookup → 8) printer integration. Brainstorm the same-Rails-app-vs-separate and web-vs-Tauri-surface
question before cutting code (the handoff flags this).

---

## 5. Specific integration opportunities (concrete, with licensing)

| Opportunity | How | License posture |
|---|---|---|
| **InvenTree-style part/stock/BOM data model** | Study its Part-vs-StockItem-vs-Location split + multi-level BOM + build-allocation; **write our own Rails models** in that shape (don't fork — different stack). Optionally integrate its REST API for users who already run it. | InvenTree **MIT** — free to study/integrate. |
| **Spoolman for filament** | Call its REST API; link a spool to a print/project; let Spoolman keep owning auto-decrement from OctoPrint/Klipper. | Permissive — integrate, don't rebuild. |
| **STL/3MF/OBJ preview** | three.js loaders, client-side. | three.js **MIT**. |
| **STEP/IGES/BREP preview** | **occt-import-js** (WASM OpenCASCADE), client-side, no server job. | occt-import-js **MIT**; **verify the bundled OCCT artifact's terms before shipping** (OCCT core is LGPL-w-exception). |
| **3MF thumbnails (cheap gallery)** | **lib3mf** to pull the slicer-embedded PNG; **stl-thumb** (Rust) for STL. Reuses progressive/range hydration (only needs head chunks). | lib3mf **BSD-2**, stl-thumb **MIT**. |
| **Supplier part lookup / barcode** | LCSC/DigiKey/Mouser/TME barcode parse + part import (InvenTree's approach). | Code clean; **Octopart/Nexar API is commercial/paid → managed-tier only.** |
| **Printer status → print history** | OctoPrint/Moonraker REST APIs (open). Avoid the Bambu walled garden. | **Integrate via API; OctoPrint core is AGPL — never vendor.** |

---

## 6. Licensing landmines (the two to watch)

1. **AGPL copyleft in the nearest analogs — Manyfold (AGPL-3.0) and OctoPrint (AGPL) and Part-DB
   (AGPL).** Per §9 we must avoid GPL/AGPL in deps and shipped artifacts. **Action: study their
   *patterns/data models* freely (ideas aren't licensable), but never copy code, and only ever
   touch OctoPrint/Spoolman/InvenTree across a network API boundary** (calling a separate AGPL
   service over REST does not infect our permissive code). This is *why* the closest analog
   (Manyfold) being AGPL is an opportunity, not a threat: there's no permissive incumbent in the
   "file-first maker workshop" square.

2. **The CAD-preview WASM artifact (occt-import-js / OpenCASCADE).** occt-import-js is MIT, but it
   embeds an OpenCASCADE build (OCCT core is **LGPL-2.1 with an exception**). For a permissive,
   self-host + managed product, **confirm the exact license of the shipped `.wasm` before
   bundling** — LGPL-with-exception linked as a separate WASM module is generally fine, but verify
   rather than assume. (If it ever looks risky, the **3MF embedded-thumbnail path (lib3mf, BSD)
   delivers 80% of the visual value with zero CAD-kernel licensing exposure** — a clean fallback.)

Everything else in the preview/inventory stack (three.js, lib3mf, stl-thumb, InvenTree's model,
Spoolman) is permissive and safe.

---

## Sources

3D-file managers:
[Manyfold (GitHub)](https://github.com/manyfold3d/manyfold) ·
[Manyfold LICENSE — AGPL-3.0](https://github.com/manyfold3d/manyfold/blob/main/LICENSE.md) ·
[Manyfold overview (medevel)](https://medevel.com/manyfold/) ·
[Printventory (GitHub)](https://github.com/TechJeeper/Printventory/blob/main/README.md) ·
[Printventory site](https://printventory.com/) ·
[MakerWorld/Bambu lockdown context (Tailscale)](https://tailscale.com/blog/bambuddy-bambu-lab-3d-printer-access)

Inventory / BOM:
[InvenTree LICENSE — MIT](https://github.com/inventree/InvenTree/blob/master/LICENSE) ·
[InvenTree BOM docs](https://docs.inventree.org/en/latest/manufacturing/bom/) ·
[InvenTree build/stock allocation](https://docs.inventree.org/en/1.1.x/manufacturing/allocate/) ·
[InvenTree DigiKey barcode plugin](https://docs.inventree.org/en/latest/plugins/builtin/barcode_digikey/) ·
[inventree-part-import (LCSC/DigiKey/Mouser/TME)](https://pypi.org/project/inventree-part-import/) ·
[PartsBox](https://partsbox.com/) ·
[Spoolman (GitHub)](https://github.com/Donkie/Spoolman/blob/master/README.md)

Preview libraries:
[Online3DViewer (three.js + occt-import-js, MIT)](https://github.com/kovacsv/Online3DViewer) ·
[occt-import-js (npm)](https://www.npmjs.com/package/occt-import-js) ·
[occt-import-js (GitHub)](https://github.com/kovacsv/occt-import-js) ·
[three.js](https://en.wikipedia.org/wiki/Three.js) ·
[lib3mf / 3MF thumbnails](https://products.fileformat.com/3d/cpp/lib3mf/) ·
[stl-thumb (Rust, MIT)](https://github.com/unlimitedbacon/stl-thumb)

Build logs / pain points:
[Hackaday project logs](https://hackaday.com/tag/project-log/) ·
[3D-print file-management pain (meshmayhem)](https://www.meshmayhem.com/post/mastering-the-art-of-3d-printing-file-management) ·
[Print-shop workflow waste (3DPrinterOS)](https://www.3dprinteros.com/) ·
[OctoEverywhere printer ecosystem matrix](https://octoeverywhere.com/)
