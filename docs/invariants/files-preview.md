# The file-type vocabulary and the preview surfaces

§14d/§14b material for the Files pages, the preview renderers and the thumbnail poll. Moved out of
CLAUDE.md on 2026-08-26 because it binds inside one subsystem and was being skimmed on every
unrelated session. Read this before touching `app/models/maker/file_attachment.rb`,
`app/services/maker/previews/`, `FilesController#preview_kind`/`#index`/`#thumbnails`,
`app/views/files/`, `app/javascript/controllers/thumbs_controller.js`, or `Node`'s display scopes.

## ONE file-type vocabulary, and it reaches the RENDERERS too

`FilesHelper::EXT_FAMILIES` is **derived** from `ROLE_BY_EXT`. `FilesController#preview_kind`'s
`:text` branch and `Maker::Previews::Registry`'s TextThumb entries are **both**
`Maker::FileAttachment.text?` / `TEXT_EXTENSIONS`. **Add an extension in `ROLE_BY_EXT` only.**

The Registry hand-listed **4** text extensions while `preview_kind` called **37** text, so 33 of
them (`.rb`, `.py`, `.gcode`, `.yml`, `.csv`, `.scad`, every `.c` and `.h`) got the source viewer
and a **blank grid cell** — `Enqueue.call` returns nil for a name no renderer claims, so no row is
ever created. No test spanned the two layers; each table looked right alone.

**STAGE 3, S3-1: `ROLE_BY_EXT` IS NOW THE SEED OF THE FILING MAP, NOT THE FILING MAP ITSELF.**
`Maker::ProjectFolders.folder_for(user, name)` no longer answers straight out of `ROLE_BY_EXT` +
`ROLE_FOLDERS` — it reads `Maker::FilingRules.for(user)`, a per-user table seeded ONCE from those
two (`ROLE_BY_EXT`'s extension → role → `ROLE_FOLDERS`'s role → folder) on a user's first read, then
edited at `/settings/filing`. That does not loosen this file's own rule: an extension still needs a
`ROLE_BY_EXT` entry to be SEEDED with any folder at all (an extension nobody has wired stays
answerable only as `"other"`, the fallback every per-user row lookup shares), so "add an extension
in `ROLE_BY_EXT` only" is still where a new extension's file-type identity is decided — it is only
the FILING destination that a user may now override afterward. `default_folder_for(name)` is the
old pure function preserved verbatim (no user, no override) for the seed's own use and for a
caller with no user in hand.

Two consequences of the one table:

- Every extension must satisfy `FilesController::EXT_RE` (`/\A[a-z0-9]{1,8}\z/`) or it renders a
  filter chip that links and **silently does nothing**. `markdown` is the bound, at exactly 8.
- The `role` column is **behavioural** — cover-image selection reads `image`/`model`, and
  `Models::AttachmentsController` dispatches `ExtractPdfMetadataJob` on `instructions`, so `pdf`
  must stay `instructions`. A third copy in `importer_controller.js`'s `roleFor` has drifted; it is
  browser-only and the server re-derives authoritatively.

## `:kicanvas` is a preview kind with NO `ROLE_BY_EXT` entry behind it, on purpose

`FilesController::KICANVAS_EXTS` (`kicad_sch`, `kicad_pcb` — stage 3, S3-2) is written out beside
`preview_kind`, the same way `MEASURABLE_EXTS` already is, and for the same first reason: neither
extension can EARN a `ROLE_BY_EXT` entry, because both fail `EXT_RE` (an underscore, and
`kicad_sch`/`kicad_pcb` are 9 characters against an 8-character bound) — the exact failure this
file's own warning two paragraphs up describes. Adding one anyway would render a filter chip that
links and does nothing.

That absence is also what keeps a `.kicad_sch`/`.kicad_pcb` file OFF the thumbnail-poll cell for
free: `Maker::Previews::Registry.for_filename` (what `_grid.html.erb`/`_list.html.erb` check
before wiring up `thumb_cell_data`) has no renderer registered for either extension and never will
by way of this table, so both files render as a plain name/badge, the same branch any other
non-renderable file takes. Nothing had to be taught to skip them — they were never in scope. The
type filter's chip row is excluded the same way, independently: `ext_facets` tallies real
extensions and drops anything failing `EXT_RE` before a chip is ever built.

The browser-side renderer is KiCanvas (vendored, `vendor/javascript/kicanvas.js`), not a
server-side thumbnail — this is the one preview kind in this table with no `Maker::Previews`
renderer standing behind it at all, by design (KiCad rendering on the server is explicitly out of
scope, spec §6). `FilesHelper#kicad?` reads `FilesController::KICANVAS_EXTS` rather than holding a
second copy of the two extensions, so `projects/_schematics.html.erb`'s membership test and
`preview_kind`'s `:kicanvas` branch can never name a different set of formats.

**A `controls="basic"` embed makes Chrome fetch `<page dir>/$$:0:$$` once, and that is upstream's
bug, not the page's** (stage 3, S3-4; `tinkerex#252`). KiCanvas's `kc-ui-icon` renders a sprite
icon as `<use xlink:href="${sprites_url}#name">` through its `html` tagged template, which stands
in a `$$:<i>:$$` placeholder for every non-Literal interpolation, clones the template into the
document, and substitutes afterwards — and an SVG `<use>` with an external href fetches on
creation, relative to the page. The request 404s and is aborted when the real href lands; the icon
renders. Linux Chrome logs it at SEVERE, macOS Chrome does not, so the phone sweep ignores exactly
that message (`WebHelpers::KICANVAS_PLACEHOLDER_FETCH`) and nothing wider. The fix belongs in
`bin/build-kicanvas` (a `Literal` around the href) or upstream; do not route the placeholder to a
204 to hide it, and do not widen the ignore.

## `:gerber` is `:kicanvas`'s MIRROR IMAGE — same shape, opposite answer on one question

`FilesController::GERBER_EXTS` is **derived** from `Maker::FileAttachment::ROLE_BY_EXT`'s `pcb`
role, where `KICANVAS_EXTS` directly above it is written out — and the difference is a fact about
the extensions, not a style choice. `kicad_sch`/`kicad_pcb` **cannot** earn a `ROLE_BY_EXT` entry
(an underscore, nine characters — they fail `EXT_RE`), so a hand list is the only option available
to them. Every Gerber extension **passes** `EXT_RE` (`gbrjob` is the longest, at six), so it lives
in the one vocabulary and the constant reads it. **Add a Gerber extension in `ROLE_BY_EXT` only** —
the filing rules, the type-filter chips and this branch all follow from it, and a second literal
list in the controller is the drift §14d exists to stop.

That also means Gerbers behave like every other role and *unlike* KiCad files on the surfaces
`ROLE_BY_EXT` feeds: they get a type-filter chip, they get a `Type` column value, and `role_for`
answers `pcb`, which is what files a board's layer set into `pcb/` instead of scattering it through
`other`. What they do **not** get is a thumbnail: no `Maker::Previews` renderer is registered for
any of them and none will be, so `Registry.for_filename` answers nil and the grid renders the plain
extension badge — the same branch any other non-renderable file takes, with nothing taught to skip
them. **A server-side PCB renderer is out of scope on licensing grounds** (gerbv is GPL, §9); the
render happens in the browser, from `vendor/javascript/tracespace.js` (MIT), and the file page's
`:gerber` branch is the only place it is offered.

**The `pcb` role is deliberately NOT in `TEXT_ROLES`, and `preview_kind` returns `:gerber` BEFORE
the text branch.** Both are true on purpose and each alone would be enough: a Gerber layer is plain
ASCII and a `.gbrjob` is JSON, so either mistake alone renders a source viewer where the board
should be. The role's absence is the real guard (it also keeps `TextThumb` from claiming them); the
early return is the one that reads. `test/controllers/files_controller_preview_kind_test.rb` asserts
on the CONSTANT for that reason — asserting through `preview_kind` alone would stay green while
`pcb` was added to `TEXT_ROLES`.

**A `.gbrjob` IS READ ON THE SERVER, and a zipped export is the other** — between them the only two
preview inputs the server opens. `Maker::GerberSets.job_layer_names` opens the job file through the
port to learn which layers the export claims — one port read per job file, bounded by `READ_LIMIT`
and by the catalog's own size column, never a query. Every failure (unreadable, unmounted, invalid JSON, no `FilesAttributes`, names
nothing this folder holds) collapses to nil and falls back to "every Gerber in the directory",
because that is the honest answer when nothing has told us otherwise. `Path` is matched by
`File.basename` against the rows already in hand, **never resolved as a path**: exporters write any
prefix they like, and resolving would reach outside the folder or land on a name that repeats.

**A ZIPPED EXPORT IS A BOARD OF ITS OWN, AND THE SERVER ONLY LISTS IT.** Every CAM tool hands a
board over as a `.zip` (Fusion's "CAM outputs", Altium, KiCad's fabrication plugin, JLCPCB's
`Gerber_*.zip`) and that zip is the artefact a fab house takes, so `Maker::GerberArchive` makes it
a board where it lies — nobody has to unzip it into the library, which is the report this came
from. **ONE bounded port read per archive, judged on the catalog's own `size` column FIRST**
(`GerberArchive::READ_LIMIT`, 16 MB — past it the zip is something else and is never opened), and
the answer is cached in `Rails.cache` by `(node_id, content token)` with **nil cached too**, so a
zip of firmware stays known-not-a-board until its content changes. The token is `content_hash` or
`current_version_id` — the port's own `content_token`, read off the catalog's two columns rather
than through a second `stat` call (`Maker::Previews::MissingBackfill` gets the same value from the
port's bulk `stat_all`; this is the one reader of the pair off the catalog). An unknown `size`
(NULL) is refused, never read: the bound has to hold before any read, and `nil.to_i` would pass it.

**rubyzip LISTS and never extracts; JSZip in the BROWSER does** (§15 — Rails serving extracted
layers would put bytes through the control plane on every backend, and the browser must fetch the
zip to render it anyway). The server reads the central directory, keeps the members whose extension
is in `GERBER_EXTS`, and hands the browser the member PATHS; `gerber_controller.js` fetches the zip
once through the same URL a download uses and names each member by its **BASENAME**, which is what
tracespace identifies a layer from (probed: Fusion's `copper_top_l1.gbr` three directories down is
identified correctly from the basename alone). An inline `.gbrjob` member picks the stack
**downward only**, matched by basename — `GerberSets`'s folder rule applied inside the archive,
with every failure falling back to "every layer in the zip". **A zip is never merged with the loose
layers beside it**: an export is complete by construction, so a zip beside a loose set in one
folder is TWO boards.

The zip's **own file page IS the board** (a stackup, with Top and Bottom, like a `.gbrjob`'s).
`preview_kind` stays **NAME-ONLY** — the zip branch is decided in `FilesController#show` by a READ,
the one preview kind that is, beside the `.gbrjob` read that already lives there. **Filing is
untouched**: `zip` stays role `source_archive`, so a Gerber zip loose at a project's ROOT is still
filed into the source folder by the intake sweep (the sweep runs before any read and decides by
name), while one already in a subfolder is never moved — a content-aware refiling is a separate
decision. The rule is stated beside the code in four places that must sweep together:
`Maker::GerberArchive`'s header, `Maker::GerberSets`' class comment and `#archive_boards`,
`FilesHelper#gerber_layers_for` / `#gerber_archive_entry` (the ONE wire shape all three pages
build), and `gerber_controller.js`'s `filesFor`.

**One board is one FOLDER.** A project holds a main board and a daughterboard; grouping by project
would stack both folders' copper into an image of nothing real. `Maker::GerberSets` owns that rule
and both Fabrication panels (private and public) read it, the arrangement `PublicProject#kicad_rows`
already establishes for Schematics. The panel's file LIST and the viewer's STACK are different
lists — a stray layer beside a job-driven export is listed and not stacked — and a panel that
rendered only what it stacked would make those files invisible.

**The S3 caveat is KiCanvas's, unchanged**: the viewer's fetch follows a presigned redirect to the
bucket, which reads only under the bucket's CORS rule and the `connect-src` the port names — the
same two halves as the 3D viewer and the KiCanvas embed (stated once, under `:model3d` below).

## `:model3d` is the browser's own viewer, and Online3DViewer is what decides its list

**The engine is ONE vendored bundle and its WebAssembly importers are SEPARATE FILES.**
`bin/build-o3dv` esbuild-bundles `online-3d-viewer@0.18.0`'s `source/engine/main.js` into
`vendor/javascript/o3dv.js` (one importmap pin, `preload: false`, dynamic-imported by
`modelviewer_controller.js` on the click, the KiCanvas/tracespace pattern) and copies the OpenCascade,
rhino3dm and Draco importers into `public/o3dv/<version>/`. **Build from `source/`, never from the
package's own `build/engine/o3dv.module.js`** — that file leaves nine bare imports unresolved
(`three`, five `three/examples/jsm/loaders/*`, `fflate`), so vendoring it resolves `three` through
this app's pin, 0.185.1 against the engine's own 0.176.0, and needs five new pins nothing else wants.

**The `three` pins are now an ADDON CONTRACT and nothing else.** No file in this repo imports
`three` any more. `chaim354/tinkerex-addons`' openscad bundle dynamic-imports `three`,
`three/addons/controls/OrbitControls.js` and `three/addons/loaders/3MFLoader.js` through the HOST
importmap (`Tools::AddonsController#merged_importmap`), so removing any of those five pins —
including the transitive `three-core` and `fflate` — breaks that addon at runtime with no local
error pointing at the pin. `STLLoader.js` and `OBJLoader.js` are the two that addon does not import,
which is the only reason they could be retired with the old viewer.

**Upstream fetches its wasm importers from jsdelivr, and `bin/build-o3dv` REWRITES those URLs.**
0.18.0 exposes no setter for this: `LoadExternalLibrary` injects a `<script src>` at a hard-coded
CDN URL and `CreateOcctWorker` fetches a worker script, string-patches it and runs it from a `blob:`
URL. All three are wrong here — `script-src 'self'` refuses both shapes, a self-hosted box on an
isolated network has no jsdelivr, and §9's vendoring rule is "no CDN". The build script patches them
to `/o3dv/<version>/`, replaces the blob worker with a plain same-origin one (the worker's own
`importScripts` and emscripten's `locateFile` both resolve beside it, so nothing else needed
patching), and then **refuses to ship a bundle that still contains a jsdelivr string, or one that
does not contain the local paths** — the second half being what stops a patch that deleted rather
than replaced. `test/system/o3dv_test.rb` asserts the same thing from the browser: the page requests
our worker and requests nothing from a CDN.

**occt-import-js is LGPL-2.1 and that is fine, on the posture the image already takes for OCCT.**
It is a separate WebAssembly file the browser fetches and runs on its own; nothing links against it
and none of it is copied into our bundle, which is the LGPL's own dynamic-use case, and replacing it
means dropping a different build into `public/o3dv/<version>/`. The `Dockerfile` makes the identical
argument for OCCT inside the F3D subprocess ("OCCT is LGPL and stays process-isolated"). Its licence
text, and OpenCASCADE's, ship beside the wasm. **web-ifc (MPL-2.0) is NOT shipped** and `.ifc` is
absent from the viewable list, so nothing can reach that importer. §9.

**`'wasm-unsafe-eval'` in `script-src` is what keeps the CAD importers working when the policy is
enforced.** Chrome refuses `WebAssembly.instantiate` under a `script-src` carrying neither it nor
`'unsafe-eval'`; it permits no `eval`, no `new Function` and no string timer, so it is not the
widening `'unsafe-eval'` would be. Report-only today, so today it only keeps the report log clean.

**THE URL MUST CARRY THE FILENAME — `named_blob_file_path`, never `blob_file_path`.** The engine
picks its importer from the fetched URL's own trailing extension (`GetFileExtension`), never from
the bytes or a Content-Type. This is KiCanvas's rule exactly, with the same symptom when it is
broken: the viewer simply never recognises the file, and the page falls back to the poster with
nothing in the console pointing at the URL. Both templates and the model page's `data-url` options
use the named route.

**`VIEWABLE_3D_EXTS` AND THE RENDERER REGISTRY ARE TWO LISTS, AND THEY DO NOT MATCH.** The browser
list is the engine's importers minus four stated absences (`ifc` unshipped, `svg` owned by the
Measure branch which returns first, `bim` not a maker format, `brp` a second spelling of `brep`).
The server list is `f3d --list-readers` on the shipped 3.5.0, which has no reader for `3dm`, `amf`
or `fcstd` — so those three open in the browser and have no thumbnail, which is the honest answer:
registering them would create a preview row and a job for a render that can only fail. `3mf` is
absent from the F3D list for the opposite reason — it already has a better renderer, the slicer's
own embedded thumbnail. Both directions are asserted in `registry_test.rb`.

**A ROLE IS WHERE A FILE FILES, NOT WHETHER IT RENDERS**, and the 2026-09-06 widening is where that
is easiest to get wrong. `ROLE_BY_EXT` gained the mesh formats as `model`, but `.fcstd` is viewable
and stays `cad_source` (it is a FreeCAD project you go back and edit; making it a `model` would MOVE
it out of `cad/` on the user's NAS) and `.svg` stays `vector`. **The widening reaches existing users
ONCE, by a data migration, never by a re-seed on read**
(`db/migrate/20260906140000_rederive_model_roles_and_seed_filing_rules.rb`, the shape
`SeedPcbFilingRules` set): `Maker::FilingRules.seed!` stays guarded by `exists?` because
`/settings/filing` promises a removed rule files into `other`, so the migration tops up only users
who already hold rules (a user with none is seeded in full on their first read) and re-derives only
`other` attachment roles on the thirteen extensions, ghost nodes skipped. Its `down` takes only those
extensions on both doors — the folder column is free-form, and a hand-made rule filing something
else into `models` must survive a rollback.

**THE ENGINE NORMALISES UP-AXIS AT IMPORT, SO THE CONTROLLER MUST NOT.** Each importer declares its
format's up direction and `ThreeModelLoader` rotates the three object by -90° about X wherever that
is Z — so the scene is always Y-up and a per-format camera table (which the Three.js viewer needed,
because neither STLLoader nor 3MFLoader rotated anything) now lays every STL on its side instead of
fixing it. The consequence for the DIMENSIONS is the trap: `Viewer#GetBoundingBox` reads the
ROTATED scene and reports a Z-up file's height as its depth — measured, a 20 x 10 x 5 STL read back
as "20 × 5 × 10 mm". `OV.GetBoundingBox(model)` walks the imported model's own vertices, through
mesh INSTANCES so an assembly's node transforms are applied, and is the only honest source.

**`--ready` MEANS "THE VIEWER IS OPEN", NOT "THE MODEL RENDERED".** `EmbeddedViewer` measures its
parent's `clientWidth`/`clientHeight` in its constructor and `.model-viewer-stage` is `display:none`
until that class lands, so the class must be added BEFORE the engine is constructed or the canvas is
0x0 forever. Success and failure are carried by `data-modelviewer-state` (`loading`/`ready`/
`failed`) instead, which is also what the system test drives. The failure contract is unchanged from
the Three.js viewer: any error puts the server-rendered thumbnail poster back.

**ON S3 A VIEWER'S FETCH LEAVES THE ORIGIN, AND BOTH HALVES OF LETTING IT ARE STATED ONCE.** The
blob route answers a presigned redirect to the bucket, so the 3D viewer, KiCanvas, the Gerber viewer
and the public bundle all fetch cross-origin. The browser reads that response only if (1) the
bucket's CORS rule allows this app's origin — an operator step Rails cannot perform, `docs/DEPLOY.md`
— and (2) the CSP's `connect-src` names the bucket's origin, which
`config/initializers/content_security_policy.rb` asks the port for per response
(`FileLayer#presigned_origin`: the SDK's resolved endpoint on s3, nil on share and chunk_remote,
which stream from Rails). **Never hand-write a store address into the policy**: the s3 overlay's own
endpoint named the wrong host for three weeks after tinkerex#85's reboot moved SeaweedFS, and a copied
literal would have named it just as faithfully. S3-2 through S3-6 recorded this as "`connect-src`
blocks the fetch"; the policy is report-only, so it never did — the bucket had no CORS rule and,
latterly, no reachable endpoint. Pinned per leg by `content_security_policy_test.rb` and, for the
port's answer, by the shared adapter contract.

## Extensionless text is a SEPARATE AXIS, and it must not move files

`File.extname("LICENSE")` is `""`, and so is `File.extname(".gitignore")` — a leading dot with no
second dot is not an extension. **No entry in an extension table can ever reach those files.**
`TEXT_BASENAMES` covers them, matched on the whole downcased basename (the live library holds both
`Makefile` and `makefile`, so downcasing is load-bearing).

`Registry.for_filename` falls back to it; **`Registry.for` deliberately does NOT** — that door takes
a raw extension, and teaching it to also answer for `"LICENSE"` lets a caller holding a genuine
extension match a basename by coincidence.

**It grants no ROLE, and that is the point.** `role_for("LICENSE")` stays `"other"`, so
`Maker::ProjectFolders` keeps filing it where it files it today. Giving it `document` would MOVE it
into `docs/` on the user's NAS — a change to their files, not to a preview. Same split `.scad`
carries: role answers *where a file lives*, content type answers *how it is shown*.

## `/files/thumbnails` MUST answer for a node with no row

This was `next unless p`, which **omits the key** — and `thumbs_controller`'s `if (!entry) continue`
then leaves that cell spinning **and in the poll set**, so it burns all 40 tries and the spinner
stays on screen for as long as the page is open. The animation is CSS; ending the poll does not end
it.

The failure was worked around **three times at the callers** (`files/_list`, `files/_grid`, and
`models/_hero_poster`, whose comment describes this exact loop) and was **still live** in
`projects/_attachment_group`. Answering at the endpoint fixes every caller at once — including
`projects/_card` and `models/_card`, which hold only a `cover_node_id` and so *cannot* guard
themselves.

**The two no-row cases are different questions and must stay so:**

| cause | answer | why |
|---|---|---|
| nothing will ever render this name, or the node is not live (a tombstone) | `unsupported` | terminal; the client resolves it to a static badge |
| the name IS renderable, the row merely does not exist yet | **omit** | `backfill: false` on this door means a row is genuinely still coming |

Collapsing them trades a hung spinner for a **wrong** one, which is worse because it looks correct.
`thumbs_controller` also resolves stragglers to badges when polling gives up, so "forever" is not
reachable even if the endpoint is wrong.

## Dot-files are a DISPLAY filter, never a scan skip

`Node.visible_entries(show_hidden)` hides dot-prefixed names; `FilesController#resolve_hidden`
persists the choice in a **cookie**, like `view` and `sort`, because folder links carry only
`folder:` and a param would die on the first navigation. `requested == "1"` is what makes the
control two-way — `?hidden=0` is `present?`, so a `params[:hidden].present?` spelling turns dot-files
on and can never turn them off.

**Never move this to the observer.** The instant a name becomes unobservable, a live node still
pointing there is a ghost the Reconciler can never pair, whose tombstone trips the mass-deletion
guard and refuses that scan **and every scan after it, permanently** (§14b; four wedges so far).
Hiding a row that still exists, still syncs and still attaches to projects is trivially reversible.

`.git` is a **separate rule** and stays hidden even with hidden files shown: `Library::RepoMetadata`
keeps the marker indexed as the evidence a directory is a working tree, and on share/s3 nothing
beneath it is observed, so revealing it offers a folder that cannot be opened usefully.

Both scopes go on `FilesController#index`'s `scope =` assignment, **not** the `.order` chain —
`@match_count`/`@child_count` read the same object, so one line lower the truncation banner and the
pager count rows the page never renders.
