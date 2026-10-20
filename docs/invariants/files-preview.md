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

**Stage 4, S4-2 added the three formats the bench itself produces**: `mage` (MillMage) under a new
`cnc_design` role, `lbrn` (LightBurn v1) as `laser` beside `lbrn2`, and `ai` (Illustrator) as
`vector` beside `svg`/`dxf`. `cnc_design` and `gcode` are two ROLES sharing one FOLDER (`cnc/`), the
shape `instructions`/`document` already had with `docs/` — a role is what
`Maker::ModelIntake::EXCLUDED_ROLES` denies a model and what a panel heading reads, so the CNC
*project* and the toolpath it exports must not share one.

**`.heic`, `.heif`, `.tif` AND `.tiff` ARE `image` BY ROLE AND NOT INLINE, AND THE TWO LISTS ARE
DIFFERENT ON PURPOSE (2026-09-08, tinkerex#285).** An iPhone original and a scanner's TIFF file into
`images/`, the photo door takes them and libvips thumbnails them (libheif is in the shipped image —
`vips --vips-config` in the running container says so, verified before the extension was added) — and
no browser this app targets renders either as `<img>` bytes. `Maker::FileAttachment::INLINE_IMAGE_EXTS`
(`inline_image?`) is the browser's list; `FilesController#preview_kind`'s `:image` branch and every
surface that embeds raw bytes (`projects/_hero`, `public/projects/_page`, `models/_hero_poster` and the models page gallery) ask it,
not the role — a role-keyed check there rendered a broken picture for a `.heic` cover, which the
thumbnail branch shows correctly. `ico` is inline and not a role for the same reason in reverse.
Existing users got the four filing rules and their `other`-role attachments re-derived by
`SeedImageFilingRulesAndRederiveRoles`, the S4-2 shape.

**`.ai` IS REGISTERED TO THE PDF RENDERER BY NAME AND RETRACTED BY CONTENT** (stage 4, S4-2).
Illustrator's "Create PDF Compatible File" has been on by default for two decades, so an `.ai` off a
maker's disk begins `%PDF-` with Illustrator's private stream appended and pdfium renders page 1 of
it exactly as it renders any PDF; one saved with that option OFF is a bare PostScript stream nothing
here can open, and the name cannot tell the two apart. `Maker::Previews::Pdf::MAGIC` is therefore
checked at byte 0 as the FIRST statement of `render` — **not in `available?`, which takes no
bytes** — and a miss raises `Maker::GeneratePreviewJob::Unsupported`, because `failed` is what
`Maker::Previews::Enqueue` re-enqueues and a PostScript `.ai` would then wear an error badge and
re-render on every scan forever. That makes `Pdf` and `GerberZip` the two renderers whose claim a
read retracts on IDENTITY (the bytes are another format than the name says); `Gerber` refuses by
content too, on EMPTINESS, which is a different question. The check is on the BYTES, so a `.pdf`
that is not a PDF now gets the same terminal `unsupported` instead of pdfium's exit code in an error
badge — a deliberate behaviour change for `.pdf`. `FilesController#preview_kind` answers
`:thumbnail` for `.ai` and deliberately **not** `:pdf`: that branch embeds the bytes for the
browser's own viewer, which a browser handed a file named `.ai` downloads instead of rendering. The
ROLE stays `vector` — where a file lives and what picture we can make of it remain two questions.

Three consequences of the one table:

- Every extension must satisfy `FilesController::EXT_RE` (`/\A[a-z0-9]{1,8}\z/`) or it renders a
  filter chip that links and **silently does nothing**. `markdown` is the bound, at exactly 8.
- The `role` column is **behavioural** — cover-image selection reads `image`/`model`, and
  `Models::AttachmentsController` dispatches `ExtractPdfMetadataJob` on `instructions`, so `pdf`
  must stay `instructions`. A third copy in `importer_controller.js`'s `roleFor` has drifted; it is
  browser-only and the server re-derives authoritatively.
- **STORED ROLES FOLLOW THE TABLE BY ONE RULE, NOT BY A MIGRATION PER WIDENING** (F-S33-1,
  2026-10-19). `role` is written with the row, so a row attached before `ROLE_BY_EXT` learned its
  extension says `other`. `Maker::FileAttachment.classify_unclassified!(user)` re-reads a user's
  `other` rows against TODAY's table and rewrites the ones it now names: daily for every user
  (`Maker::ClassifyAttachmentRolesJob`, `config/recurring.yml`) and on demand with
  `rake maker:classify_roles`, the moment a widening deploy lands. So the ROLE half of a widening is
  the table edit and nothing else: no re-derive migration, and no test of an old migration to touch.
  Seven widenings carried that half by hand-copied migration (eight migrations rewrite stored roles;
  the eighth is the one re-classification, `lbrn2` vector → laser) and two never got one
  (`nc`/`tap`/`ngc` on 2026-07-31; the Gerber extensions on 2026-09-06, whose `SeedPcbFilingRules`
  seeds filing rules only), which left an electronics project's hero on a photo instead of its
  board. **`other` is the only value it rewrites**: it means "nothing classified this name when the
  row was written", and every other value is a decision (a photo door's `image`, a v1 client's post)
  that is never rewritten. Its limits, by construction: a RE-classification (the `lbrn2` vector →
  laser move) and an extension removed from the table still need a migration, and the per-user
  FILING map above is a separate store whose existing users still need a top-up migration per
  widening (`Maker::FilingRules.seed!`'s `exists?` guard).

## `:kicanvas` is a preview kind with NO `ROLE_BY_EXT` entry behind it, on purpose

`FilesController::KICANVAS_EXTS` (`kicad_sch`, `kicad_pcb` — stage 3, S3-2) is written out beside
`preview_kind`, the same way `MEASURABLE_EXTS` already is, and for the same first reason: neither
extension can EARN a `ROLE_BY_EXT` entry, because both fail `EXT_RE` (an underscore, and
`kicad_sch`/`kicad_pcb` are 9 characters against an 8-character bound) — the exact failure this
file's own warning two paragraphs up describes. Adding one anyway would render a filter chip that
links and does nothing.

**THE FILING MAP HAS ITS OWN, WIDER KEY RULE SINCE STAGE 4, S4-2, AND THE SPLIT IS THE POINT.**
`Maker::FilingRule::KEY_RE` (`/\A[a-z0-9_]{1,12}\z/`) admits `kicad_sch`/`kicad_pcb` where `EXT_RE`
cannot, so both extensions now carry a FILING destination (`pcb`, seeded from
`Maker::FilingRules::BEYOND_ROLE_BY_EXT` for a new user and from `db/migrate/20260907120100` for an
existing one) while still carrying no ROLE. `EXT_RE` is untouched and `ROLE_BY_EXT` must still meet
it: a chip that links and does nothing is exactly what an entry there would produce. A filing rule
renders no chip and grants no role — it answers one question, "which subfolder" — which is what lets
it carry a key the vocabulary cannot. So "neither extension can EARN a `ROLE_BY_EXT` entry" stays
true, and "living outside `ROLE_BY_EXT` means the app has no opinion about these two" is now false:
it has a filing opinion and only a filing opinion. `KEY_RE` is deliberately NOT a second copy of
`EXT_RE` drifting; it is a different question with a different bound, and `filing_rule_test.rb`
asserts both directions in one test.

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
to them. (They CAN carry a FILING rule since stage 4, S4-2 — `Maker::FilingRule::KEY_RE` is the
filing map's own, wider key; see the `:kicanvas` section — but a role, never.) Every Gerber extension **passes** `EXT_RE` (`gbrjob` is the longest, at six), so it lives
in the one vocabulary and the constant reads it. **Add a Gerber extension in `ROLE_BY_EXT` only** —
the filing rules, the type-filter chips and this branch all follow from it, and a second literal
list in the controller is the drift §14d exists to stop.

That also means Gerbers behave like every other role and *unlike* KiCad files on the surfaces
`ROLE_BY_EXT` feeds: they get a type-filter chip, they get a `Type` column value, and `role_for`
answers `pcb`, which is what files a board's layer set into `pcb/` instead of scattering it through
`other`. **And since 2026-09-07 they get a thumbnail too** — see the tracespace-under-node paragraph
at the end of this section. Until then this file said "no `Maker::Previews` renderer is registered
for any of them and none will be" and gave the reason as **"a server-side PCB renderer is out of
scope on licensing grounds (gerbv is GPL, §9)"**, which was reasoning from ONE renderer's licence to
every renderer's absence: tracespace is MIT and was already vendored for the browser, so the licence
argument never reached it. The browser render is unchanged and remains the only INTERACTIVE one —
`vendor/javascript/tracespace.js`, offered by the file page's `:gerber` branch and nowhere else.

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
the answer is cached in `Rails.cache` by `(node_id, content token)` with **a nil from the BYTES
cached too**, so a zip of firmware stays known-not-a-board until its content changes — **and a nil
from the PORT never**. The port's `FetchError`/`NotFound` are rescued OUTSIDE the fetch, because
activesupport writes a nil block result unless `skip_nil`: rescued inside it, an unmounted share
was cached as "not a board" for the cache's 30 days under a key that does not move when the share
comes back (both file pages lost the board, and `ProjectIntake` filed the zip as source). The
namespace is `-v2` since that fix (2026-10-19), which is what retired the nils already written.
The token is `content_hash` or `current_version_id` — the port's own `content_token`, read off the
catalog's two columns rather than through a second `stat` call (`Maker::Previews::MissingBackfill`
gets the same value from the port's bulk `stat_all`; this is the one reader of the pair off the
catalog). An unknown `size` (NULL) is refused, never read: the bound has to hold before any read,
and `nil.to_i` would pass it.

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
the one preview kind that is, beside the `.gbrjob` read that already lives there. **Filing reads the
zip, and the vocabulary does not** (stage 4, S4-2; story 2.8): `zip` stays role `source_archive` —
right for a Printables download, and what `preview_kind`, the badge and `ROLE_BY_EXT` still answer —
but `Maker::ProjectIntake#place` asks `Maker::GerberArchive.for` about a `.zip` loose at a project's
ROOT and files a board into the maker's own Gerber-layer folder (`pcb/` by default) instead of the
source folder. It is the ONE filing decision in that class that reads bytes, and it uses the same
bounded, cached reader this page does, so the sweep and the file page cannot disagree about what a
board is. A zip already in a subfolder is still never moved — root = inbox is unchanged. The rule is stated beside the code in three places that must sweep together:
`Maker::GerberArchive`'s header, `FilesHelper#gerber_archive_entry` (the ONE wire shape, built by
`FilesController#show`), and `gerber_controller.js`'s `filesFor`.

**A GERBER IS A FILE LIKE ANY OTHER ON THE PROJECT PAGES, AND THE BOARD RENDERS ONLY ON ITS OWN
FILE PAGE** (2026-09-06, at the user's request). The private and public project pages' Fabrication
panels — one inline viewer per folder, grouped by `Maker::GerberSets` (one board per folder, a zip
a board of its own, the list and the stack two different lists) — are gone, and the grouping with
them; `git show 2addf8f:app/services/maker/gerber_sets.rb` holds it. What remains of `GerberSets` is
`job_layer_names`, the `.gbrjob` reader behind a job file's page. A layer's page shows that layer; a
`.gbrjob`'s and a zip's page show the board; **a loose set with no job file is one layer per page**
— the one thing the panel could do that the file page cannot, deliberately not rebuilt.

**A PUBLIC PROJECT GETS THE BOARD TOO SINCE STAGE 4, S4-5**, on exactly those terms: the layer's,
the job file's or the zip's OWN page, at `/u/:handle/:slug/files/:id/view`. Until then this file
recorded "a public project therefore has no board render … there is no public file page to mount a
viewer on" — true of the pages that existed, false of the pages that exist, and the reason to state
a rule's *condition* rather than its conclusion.

**A `.gbrjob`'s SIBLING WALK IS ONE ANSWER AND THE URL IS THE CALLING PAGE'S.**
`FilePreview#gerber_layers_for` takes a `url:` lambda, so the two pages cannot disagree about which
layers a board HAS — only about how to address one. The private lambda never refuses; the public one
is `Maker::PublicProject#layer_url_for`, which asks the same `permits?` that `deliverable!` asks and
answers **nil** for a sibling this project does not publish. **BOTH arms drop the refusal** — the
job arm `filter_map`s, the single-layer arm `.compact`s — so a board renders WITHOUT an unpublished
layer instead of pointing a visitor at a URL the byte route would refuse, and **a board built
entirely of unpublished layers is no board**, not board chrome drawn around a null layer. The
single-layer arm shipped returning `[nil]`, which is not empty; a refusal must reach the viewer as
an absent layer on both arms or on neither.

**THE STAGE'S PAN, ZOOM AND FIT ARE `app/javascript/lib/svg_pan_zoom.js`, SHARED WITH THE MEASURE
VIEW — never a second copy.** The maths was `measure_controller.js`'s (the wheel-zoom-about-the-
cursor, the `xMidYMid meet` letterbox conversion, the `[span/500, span*4]` clamp, the screen-pixel
pan slop, the pointer capture) and moved out on 2026-09-06 so the Gerber stage could have the same
hands; both controllers now install the one module (§14d, "a verb more than one controller performs
gets a named service"). Two consequences a later editor can undo by accident: the module needs
`preserveAspectRatio="xMidYMid meet"` on the element it is handed, which is why BOTH callers set it
and the module does not; and `.gerber-viewer .model-viewer-stage svg` carries **`touch-action:
none`**, without which the
browser claims a two-finger gesture for its own scroll and the pinch handler never receives the
second pointer — not degraded, never fired. **No Measure system test drives a wheel or a drag**, so
`test/system/gerber_test.rb`'s zoom, pan and Fit cases are the only pin the shared maths has.

**A LAYER TOGGLE RE-COMPOSES FROM THE ONE `renderLayers` RESULT AND NEVER RE-FETCHES.**
`gerber_controller.js` keeps that result and hands `renderBoard` a **filtered `layers` list**
(probed against the vendored bundle with a real Fusion export: it composes both sides correctly),
so hiding a layer costs a re-compose and a re-serialise — not a fetch, a parse or a plot, which on
a twelve-layer board is seconds rather than milliseconds. Hiding every layer renders an empty
board and is allowed; the way back is the same click. The current view survives a toggle **and** a
Top/Bottom switch, both of which replace the whole `<svg>` — `home` is read off the FIRST render
and kept, because tracespace places every side and every layer on one viewBox and re-reading it per
render would make `Fit` mean "the current picture's box", which for a board with its outline hidden
is not the board.

**THE VIEWER WEARS THE 3D VIEWER'S CHROME AND FETCHES NOTHING UNTIL LAUNCHED.** The `:gerber`
branch is a `.model-viewer.gerber-viewer`: at rest a poster (since 2026-09-07 the server-rendered
thumbnail, plus a sentence and the Download button) with a `View layer` / `View board` button, then the same stage and bar as
`:model3d` — dims, Fit, Fullscreen, ✕ Image — plus Top/Bottom and one toggle per layer for a
stackup. The `.model-viewer*` classes are the 3D viewer's because the chrome IS the 3D viewer's,
defined once in `pages/preview.css`; `.gerber-viewer` adds only what an `<svg>` stage needs
(`color`, the grab cursor, `touch-action: none`, a wrapping bar). `model-viewer--ready` goes on
BEFORE the fetch for the 3D viewer's reason (the stage must have a size when the SVG lands).
**✕ Image KEEPS the parsed render**, so re-opening is a re-compose and no fetch — pinned by the
resource timeline in `test/system/gerber_test.rb`. **A RELAUNCH DURING THE FIRST FETCH JOINS IT**:
`load()` shares ONE in-flight promise and adopts `this.ts`/`this.rendered` only behind its
generation check, so two renders can never race to own the render the stage and the layer toggles
(ids fresh per render) were built from — the loser's toggle otherwise said "hidden" over a layer
still drawn, silently. **The dims are the board's physical size in mm, taken off the RENDER and
never off the painted `<svg>`**: `renderLayers` writes `width`/`height` onto the SVG it emits, but
`renderBoard` — every "View board" page — writes neither, so a size read off the element was empty
on exactly the pages that say "board". tracespace places every per-layer render on the one board
shape, so the FIRST layer's `properties.width`/`.height` are the board's own extent in both branches
(`mm` or `in`, converted); `load()` reads it once per render. The layer toggles are still **built by
the controller** into the template's tools span (their labels are tracespace's `type`/`side`,
unknowable before the parse) and read their state off the hidden set, so a layer hidden before ✕
Image stays hidden after the re-open; Fit, Fullscreen, ✕ Image and the side buttons are in the
template because they are known without a parse. The toggle wording ("top copper", "top silk",
"drill") is the vocabulary the panel's row badges used; the badges went with the panel and the words
stayed. A Turbo-restored snapshot of an open viewer is reset to the poster on connect — the fresh
controller holds no render for it.

**THE THUMBNAIL IS TRACESPACE TOO, UNDER NODE, FROM THE SAME BUILD** (2026-09-07). `bin/build-tracespace`
runs esbuild TWICE over ONE pinned `node_modules` — `vendor/javascript/tracespace.js` for the
browser, `tools/gerber-svg/tracespace.mjs` for node — so the tile, the poster and the viewer are one
picture and **there is no second Gerber parser anywhere in this app**. (The two artifacts are
byte-identical today, measured; that is a coincidence of the flags — `--platform=node` externalises
the two builtins the browser build marks by hand — and not a reason to ship one.)
`tools/gerber-svg/render.mjs` takes `layer <file>` or `board <file>…` and writes SVG on stdout; it is
**exec'd as a subprocess exactly like resvg, pdfium, f3d and stl-thumbnailer**, and nothing links
node into Rails. **`Maker::Previews::Gerber` claims every `pcb` extension but `.gbrjob`**, derived
from `ROLE_BY_EXT` and never a second list — a job file is JSON naming its siblings, and a renderer
is handed ONE file's bytes and can reach no directory, so its picture is unbuildable and it stays
the one `pcb` extension with no renderer (`registry_test.rb` pins the subtraction and the equality
with `GERBER_EXTS`).

**`Maker::Previews::GerberZip` claims `zip`, and what a non-Gerber zip costs is stated rather than
hidden**: every zip in a library now gets a preview row and ONE bounded read, and a zip of firmware
terminates in the job's ordinary `unsupported` state and is never read again until its content
changes. That is the price of a thumbnail on the artefact a fab house is actually handed, and it is
bounded first by the job's own 32 MB `MAX_PREVIEW_BYTES`. `Maker::GerberArchive.listing_from`
decides which members are the board, so the renderer and the zip's own file page cannot disagree
about the stack. **Members are extracted UNDER THEIR BASENAME into one subdirectory per member, and
NEVER under the entry's own path** — a zip's entry names are user data and may say `../` (the
per-member subdirectory is also what lets two folders' `copper_top.gbr` both keep the basename
tracespace identifies a layer from), and resolved through **`Maker::GerberArchive.entries_by_name`**
rather than `zip.find_entry` — the listing reports names SCRUBBED to UTF-8 while an entry's own name
is ASCII-8BIT as read off the archive, so `Cámara_top.gbr` missed its member and answered
`unsupported` for a board with nothing wrong with it. Bounded again by `MAX_MEMBERS` (64) and
`MAX_EXTRACTED_BYTES` (64 MB), both refused as `unsupported`.

**THE BYTE BOUND IS TWO CHECKS AND NEEDS BOTH — the declared sizes are the PRE-CHECK, the capped
read is the BOUND.** Summing the central directory's DECLARED sizes before inflating anything is
cheap, honest about the ordinary oversized export, and free (those sizes are already read) — but it
is not a bound, because a declared size is a claim made by the archive and rubyzip does not hold the
inflater to it: `Zip::Inflater#read` (3.6.0) never consults `decompressed_size`, and only
`PassThruDecompressor`, for STORED entries, does. Measured: a hand-built 407 KB zip declaring
`size: 100` passed the pre-check and inflated **209 MB** into the tempdir, ran 104 s and got node
OOM-killed. So each member is also READ under a cap against a running total — `read(remaining + 1)`,
refused before it is written when it comes back longer than the budget. Neither check replaces the
other.

**THE NODE SUBPROCESS IS THE ONE RENDERER HERE WITH A WALL-CLOCK BOUND** (`GERBER_RENDER_TIMEOUT`,
default 60 s; `Maker::Previews::Gerber.run_node` kills and raises `RenderError`). Its siblings are
each handed ONE file the job has already capped; this one's runtime is driven by decompressed,
user-supplied geometry, and the 104 s probe above held a Solid Queue worker for its whole duration.
`popen3` with stdout and stderr drained in their own threads, never a single-threaded read: a
board's SVG is several MB, so one reader deadlocks on the pipe and the timeout then fires on a
render that was working.

**THE HAIRLINE STYLESHEET IS NOT APPLIED, AND THAT IS WHY `SvgRasterizer.to_png` GREW A
`stylesheet:` KWARG.** `STYLESHEET` exists for sources that draw in hairlines (a LightBurn file, a
DXF) and pins every stroke to 1.5 device pixels; a tracespace render carries the APERTURE'S OWN
DIAMETER (measured: a 0.5 mm round aperture emits `<path stroke-width="0.5">`), so applying it would
paint a 0.5 mm signal trace and a 2 mm power trace as one line — and on a composed board it would
put a 1.5 px border around the substrate, mask and drill `<rect>`s, which inherit
`stroke="currentColor"` at width 0. `stylesheet: nil` passes NO `--stylesheet` flag; the default is
unchanged, so every other caller is untouched. **A layer that plots nothing is `unsupported`, not
`failed`** — an empty `.gbo` is what a board with no bottom silkscreen exports, tracespace renders
it at `viewBox="0 0 0 0"` and resvg refuses that outright, and `failed` is the state `Enqueue`
treats as "retry me" (so it would be an error badge, re-rendered forever, on a file nothing is wrong
with). `render.mjs` answers exit 4 for it and `Gerber#run_node` maps that one code.

**`available?` GATES ON NODE **AND** THE VENDORED BUNDLE**, and a box missing either degrades every
Gerber to `unsupported` — the graceful path `Stl`/`Mesh`/`Pdf` take without their binaries. Both
halves are needed because each is separately absent on a real box: a dev machine has node and no
bundle until `bin/build-tracespace` has run; the deploy image had the bundle and no node before
2026-09-07. **The CI runner image carries node for the reason it carries resvg** — without it every
render assertion in `gerber_test.rb`/`gerber_zip_test.rb` SKIPS, which is green over nothing.

**"CONVERT THE GERBERS AND USE THE 3D VIEWER" WAS ASKED AND REFUSED** — `docs/roads-not-taken.md`
§10. A board export is a 2D artefact and the fab house reads exactly what tracespace draws; there
is no permissively licensed Gerber→mesh pipeline, and extruding copper and mask polygons needs
booleans and hundreds of thousands of triangles to arrive at a worse picture of the same layers.
What was actually wanted was the 3D viewer's *interaction*, which is a viewBox — hence the shared
module above, plus layer toggles a mesh could not offer.

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

**IT BINDS ON TWO URL BUILDERS SINCE STAGE 4, S4-5, AND ON ONE PARTIAL.** `named_blob_file_path` is
the maker's; `Maker::PublicProject#file_url_for(id, filename:)` is a visitor's, and its `filename:`
rides the public route's optional glob for this rule's sake and KiCanvas's (which is also why that
route is `format: false`). Both pages hand the result to `files/viewers/_model3d.html.erb` as the
strict local `named_url:`, so the partial cannot pick a builder: there is ONE place the rule can be
broken, not one per page.

**THE EIGHT VIEWER PARTIALS ARE SHARED BY A SESSION-AUTHED PAGE AND A SESSIONLESS ONE, SO EVERY URL
AND EVERY USER-SCOPED OBJECT ARRIVES AS A STRICT LOCAL** (`app/views/files/viewers/_image _pdf
_kicanvas _gerber _code _model3d _measure _static`, rendered by `files/show.html.erb` and by
`public/files/view.html.erb`; the branch that picks one is `FilePreview#preview_kind`, a CONCERN
rather than a shared superclass because the two controllers deliberately have none — §14d). **No
route helper and no `current_user`/`capabilities` call is permitted inside one.** A partial must not
be able to tell which page it is on; that is the whole reason one copy can serve both, and it is
what a maker-only fact (the repo banner, History, Notes, the commit link) stays on `show.html.erb`
for. Break it and a PRIVATE route renders in a visitor's DOM with a 200 and nothing red —
`blob_file_path("id")` planted in `_static` was measured doing exactly that, because the Public
scan's `SESSION_ACCESSOR` has no route-helper arm and the `public/` templates call `public_*_path`
legitimately. `test/architecture_invariants_test.rb`'s Public scan now globs this directory and
enforces BOTH arms: the session accessors, and any `*_path`/`*_url` identifier the partial's own
`locals:` line does not declare — read off the partial, so the allowlist cannot drift from the
signature.

**A DERIVED ASSET OF A PUBLIC FILE IS SERVED THROUGH `public_file_preview`, NEVER `url_for(asset)`**
(hardening, 2026-09-08; tinkerex#278). An Active Storage blob URL
(`/rails/active_storage/blobs/redirect/<signed_id>/…`) is **unauthenticated and never expires** —
`ActiveStorage.urls_expire_in` is nil — so a cover thumbnail lifted off a public page kept answering
after the project went private, and kept answering forever. `Public::FilesController#preview` asks
the SAME permission the byte route asks (`Maker::PublicProject#deliverable!`, and `current_preview`
for "current content, current renderer build") and then redirects to a **service** URL, which
carries `ActiveStorage.service_urls_expire_in` (5 minutes). It needs `include
ActiveStorage::SetCurrent` — a public controller stands on `ActionController::Base` (§14d) so it
inherits nothing of Active Storage's own, and `blob.url` raises without `Current.url_options`. A
global `urls_expire_in` was the alternative and is worse: it breaks a `loading="lazy"` image a
visitor scrolls to after the window, and still checks nothing about the project. **Every row with
nothing to serve and every unpermitted node is the same 404**, because an `<img>` cannot use a
status and because a stranger must not be able to tell the two apart. "Nothing to serve" is the
row's own predicate, split by kind: a thumbnail is served while `showable?` (an older build's
picture stays up through its rebuild, as the page that names the URL renders it), the Measure
payload only as `current_build?` (F-S08-2).

**THE SHARED PARTIALS THEREFORE BUILD NO ASSET URL EITHER.** `files/_thumb.html.erb` — fourteen
render sites, eleven private and three under `app/views/public/projects/` — and the four viewer
partials that poster a thumbnail (`_static`, `_model3d`, `_measure`, `_gerber`) take it as a strict
local (`url:`, `thumbnail_url:`), built by the maker's page with `ApplicationHelper#preview_src`
(the one private spelling, nil for any row that is not `showable?`) and by a visitor's with
`Maker::PublicProject#preview_url_for`, which carries `link_params` so an unlisted project's hero
keeps its `k`. **A THIRD ARM of the Public seam guard** refuses `\burl_for\b` AND `\bpreview_src\b`
outside ERB comments in those nine files and in EVERY PUBLIC TEMPLATE, and it exists precisely
because the second arm cannot see this: that pattern wants the `_path`/`_url` SUFFIX a route helper
carries, and its own comment says `url_for(thumbnail.asset)` is not matched. The public templates
are in the scan because `ApplicationHelper` is in a public view context too, so `preview_src` is
callable there — measured in review: a public panel swapped to it rendered a blob URL with the
partial-only arm green. `assert_no_private_urls` (one definition, `test/support/public_fixture.rb`)
refuses `/rails/active_storage/` in a public response body beside the private `/files/` URLs it
already refused — **where a suite CALLS it on a page with a ready picture** (the preview suite and
the file-view suite, which seeds one ready thumbnail for exactly that reason); the structural fence
is the guard arm, the behavioural one is those calls, and a suite that calls neither proves nothing
about blob URLs. **The MAKER's own page still emits a blob URL and that is the decision, not an
oversight** — it is session-authed — which is what makes this a split rather than a global
replacement, pinned by its own test in `public_preview_test.rb`.

**KNOWN AND NOT FIXED HERE, TWICE.** The OWNER's preview of a **private** project already renders
dead public URLs (`file_url_for` names the public route, which 404s while the project is private);
thumbnails now behave the same way, and the proposed fix is `Maker::PublicProject.new(project, urls:
:owner)` — filed as open work. And an **unknown `kind`** (`/preview/other`) does not 404: the `kind:
/thumbnail|geometry/` constraint keeps it off this action, but `files/:id(/*filename)` one line below
matches with a decorative `filename`, so it serves the file's own bytes with a 200. Behind the same
`deliverable!`, so it is surprising rather than a leak — pinned in both directions by
`public_preview_test.rb`.

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
it out of `cad/` on the user's NAS) and `.svg` stays `vector`. **The widening's FILING rules reach
existing users ONCE, by a data migration, never by a re-seed on read**
(`db/migrate/20260906140000_rederive_model_roles_and_seed_filing_rules.rb`, the shape
`SeedPcbFilingRules` set): `Maker::FilingRules.seed!` stays guarded by `exists?` because
`/settings/filing` promises a removed rule files into `other`, so the migration tops up only users
who already hold rules (a user with none is seeded in full on their first read). It also re-derived
`other` attachment roles on the thirteen extensions, ghost nodes skipped, and its `down` takes only
those extensions on both doors — the folder column is free-form, and a hand-made rule filing
something else into `models` must survive a rollback. **That ROLE half is no longer a migration's
job** (F-S33-1, 2026-10-19): `Maker::FileAttachment.classify_unclassified!`, run daily, applies the
same `other`-only rule to every extension the table names (the third consequence of the one table,
above), so the next widening's migration carries the filing top-up alone.

**THE ENGINE NORMALISES UP-AXIS AT IMPORT, SO THE CONTROLLER MUST NOT.** Each importer declares its
format's up direction and `ThreeModelLoader` rotates the three object by -90° about X wherever that
is Z — so the scene is always Y-up and a per-format camera table (which the Three.js viewer needed,
because neither STLLoader nor 3MFLoader rotated anything) now lays every STL on its side instead of
fixing it. The consequence for the DIMENSIONS is the trap: `Viewer#GetBoundingBox` reads the
ROTATED scene and reports a Z-up file's height as its depth — measured, a 20 x 10 x 5 STL read back
as "20 × 5 × 10 mm". `OV.GetBoundingBox(model)` walks the imported model's own vertices, through
mesh INSTANCES so an assembly's node transforms are applied, and is the only honest source.

**A 3MF's UNITS AND ITS SLICER COLOURS COME FROM THE SERVER'S MANIFEST, NOT FROM THE IMPORTER.**
Two facts about a `.3mf` reach the browser as data because three.js's `3MFLoader` cannot supply
either. It **ignores `<model unit>`** — measured, an Onshape export declaring `unit="meter"` and
standing 1.9 m tall read "0 × 1 × 0.6 mm", 1000x short — so `showDims()` multiplies by a factor the
server read, and the controller's own comment claiming "the formats that declare a unit (3MF, FCStd)
already converted by their importer" was FALSE and is corrected. And it cannot see a slicer's
**filament colours**: Bambu Studio and PrusaSlicer keep the palette and the per-object extruder in
their own `Metadata/*.config`, so every part of a Bambu project rendered in the viewer's default
grey. `Maker::ThreeMfManifest` reads both — **one bounded port read, judged on the catalog's `size`
column first and cached in `Rails.cache` by content token with the bytes' nil cached and a port
failure never, `Maker::GerberArchive`'s shape exactly** — and `FilesController#show` /
`ModelsController#show` hand it over as data attributes (per `<option>` on the model page: the
manifest is a fact about one FILE and the switcher swaps files). Since slice 5 the model page
renders only for a model with no folder strip to land on; the Library's model strip carries no
viewer, so in a model folder the manifest reaches the viewer through the file page.

**The colours are applied BY THE ENGINE'S MESH INDEX, and three rules keep that safe.** The match is
`userData.originalMeshInstance.id.meshIndex`, never a name — a Bambu `<object>` carries no `name`
attribute at all, so a name match applies nothing. The server therefore answers **one colour per
leaf mesh in `<build><item>` order with components resolved depth-first**, which is the order the
loader builds and the engine numbers; **resource order is not build order** and a walk over
`<resources>` paints a real Bambu project's parts in each other's colours. Nothing is applied unless
the list length **equals `model.MeshCount()` exactly** (a wrong colour on the wrong part is worse
than grey); a mesh carrying its own vertex colours is left alone — the reachable case is a slicer
project whose meshes still carry the `m:colorgroup` they were imported with, NOT a plain CAD export,
whose manifest is all-null and never reaches that guard (it is unpinned: the review measured its
removal green); and the material is **cloned first**, because the engine gives every mesh built from
one 3MF material the same material object. **Painting is out of scope** — Bambu
`paint_color` and PrusaSlicer `slic3rpe:mmu_segmentation` are per-triangle assignments the loader
drops, and a PrusaSlicer volume is a triangle RANGE of one mesh, so a Prusa object's colour is its
whole mesh's.

**`--ready` MEANS "THE VIEWER IS OPEN", NOT "THE MODEL RENDERED".** `EmbeddedViewer` measures its
parent's `clientWidth`/`clientHeight` in its constructor and `.model-viewer-stage` is `display:none`
until that class lands, so the class must be added BEFORE the engine is constructed or the canvas is
0x0 forever. Success and failure are carried by `data-modelviewer-state` (`loading`/`ready`/
`failed`) instead, which is also what the system test drives. The failure contract is unchanged from
the Three.js viewer: any error puts the server-rendered thumbnail poster back.

**THE 3D VIEWER'S LIFECYCLE IS THE BOARD'S, PLUS ONE RULE THE ENGINE ADDS** (F-S22-1, 2026-10-19).
Four rules, each driven by `test/system/o3dv_test.rb`:

- **Connect rests the element.** A Turbo-restored snapshot of an open viewer is reset to the
  poster, as the board's is (the `:gerber` section above). The clone carries `--ready`, the state
  and the dims over a blank cloned canvas, and the fresh controller has no engine.
- **One staleness token.** `generation` is set in `initialize` and bumped by ✕ Image and by a
  disconnect, and only the latest load may act.
- **The engine is ONE record.** Its callbacks close over that record, never over a controller
  field. `Destroy()` does not stop a running import, so a callback routed through the controller
  let a released engine's late failure fail the next load.
- **One import per engine.** A load asked for while one runs is silently dropped
  (`ThreeModelLoader.LoadModel`'s `inProgress`). Before dropping it, `LoadModelFromInputFiles` has
  thrown away the running import's progress element, so that import throws and the engine is
  wedged until ✕ Image. A source switch therefore waits for the running import before asking for
  the next one. "`LoadModelFromUrlList` clears the viewer itself" holds only for an IDLE engine.

**ONE KNOWN COST REMAINS: AN ORPHANED IMPORT LOGS ONE CONSOLE ERROR.** Leave the page or press
✕ Image while a VALID file is still importing, and that import finishes on the destroyed engine.
It then tries to remove a progress element `release()` already took out of the stage, which logs
"Uncaught DOMException: Failed to execute 'removeChild' on 'Node'". This is cosmetic, and a failing
import does not reach it. The fix is a per-engine mount `<div>`. It needs a CSS rule beside the
addon-shared `.model-viewer-stage > div` and was left out of F-S22-1. A test that trips
`assert_no_console_errors` on this message has met this case.

**THE RESTORE IS PINNED FOR ALL THREE LAUNCHABLE VIEWERS** (the board, this one and the Measure view)
by one helper, `WebHelpers#back_through_turbo_cache`. It proves the page came out of Turbo's cache
before anything is asserted about it, because a Back that re-fetched the page would pass every
"rests at the poster" assertion against a page that was never open.

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

**NO PUBLIC SURFACE POLLS, BECAUSE THIS ENDPOINT IS SESSION-AUTHED** — so a visitor's poster is
whatever is SHOWABLE at render time (`Maker::Preview#showable?`: the current build, or an older
build's picture of this content while it rebuilds), and every public page says so honestly: those
thumbs, and for the rest either `files/_thumb`'s spinner markup standing still or
`files/viewers/_static`'s "Generating preview…", **a statement a reload resolves rather than a
promise the page can keep**.
What makes that statement true is the RENDER, not a poll:
`Maker::Previews::ThumbnailMap.for` backfills on an anonymous GET — the public project page has done
that since S3-4, and the public file page does it for its one node. Do not answer a missing public
poster by opening the poll to visitors; the write-on-render is the sanctioned mechanism and it is
bounded per `(node, content token, renderer build)`, plus one re-enqueue per
`Enqueue::STALLED_AFTER` for a row whose job was lost (`Enqueue.needs_job?`, restamped as it heals).

**A SPINNER TURNS ONLY INSIDE A POLL CELL.** components.css keys its animation on
`[data-thumbs-target~="cell"]`, the poll's own markup, so a surface with no cell, public or not, shows a
still ring and needs no rule of its own. F-S34-1 deleted `pages/public.css`'s hand-kept list of
non-polling containers, which had missed two of the six public render sites
(`test/system/thumb_spinner_test.rb`).

**S4-5 ADDED ONE ASYMMETRY DELIBERATELY: `FilesController#geometry` ENQUEUES AND
`Public::FilesController#geometry` NEVER WRITES.** The visitor's enqueue moved to the page render
(`#view`, once, through `Enqueue.call(…, retry_failed: false)`) because `Enqueue.call`'s DEFAULT
resets a `failed` row to `pending` and re-enqueues on EVERY call (§14h): on a door a stranger can
issue, an unguarded poll is a doomed render every two seconds for as long as a tab is open. The
flag is load-bearing, not politeness — dropping it reddens exactly one test, the failed-render
reload in `public_file_view_test.rb`, since `Enqueue.call` is already self-idempotent for a
`pending` row and only a `failed` one shows the cost. (It replaced a `current_preview` guard on
2026-10-19 that refused the failed row just as well but also skipped a row whose job was lost, so a
visitor's Measure view could spin with nothing coming.) This is `ThumbnailMap`'s required
`backfill:` flag drawn a second time: the render self-heals, the polled door must not write.

**THE MEASURE BAR'S SAVE CONTROLS EXIST ONLY WHERE THERE IS A LIBRARY TO SAVE INTO.**
`files/viewers/_measure.html.erb` takes a required `save:` local; the public page passes **false**
and renders neither the two Save twins NOR the four upload URLs behind them — not a disabled pair,
and not a private write path sitting in a stranger's DOM for nothing. Print and Download SVG stay on
both pages, being client-side work over a payload the visitor has already fetched, and withholding
them would cost a visitor the one thing the public Measure view is for. Absent targets are what
`measure_controller.js#refreshPrintBar`'s `has*Target` guards are for: unguarded, the throw comes
out of `draw()` and Measure is dead on that page, which no integration test can see.

## A file's connections are rows, not a computation

**A FILE'S CONNECTIONS ARE ROWS, NOT A COMPUTATION (stage 4, S4-8).** `maker_file_links` holds two
kinds — `derived_from` (from the derived file to its source) and `photo_of` (from the picture to
the file it shows) — as **bare node-id strings with no foreign key**, and **liveness is answered
at read time by `nodes.present`, never by the row**: `FilesController#show` drops a link whose
partner is a tombstone, and `Maker::AttachmentReaper` destroys it once that node's undo window
closes, from **either** column. That is deliberately unlike the three lineages this page already
computes by NAME per request (`.gbrjob` → its layers, a Gerber zip → its members, a README's
links), which stay computed because they are properties of the bytes rather than statements a
maker made. The direction of a link is decided in `Files::LinksController` from `kind`, never
posted, so no door can write one backwards.

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

**Build-output directories join the dot-dirs** (stage 4, S4-2): `Node.visible_entries` also hides a
**directory** named `node_modules` or `__pycache__` unless hidden files are shown —
`Library::BuildOutput` holds the names, and `Maker::ProjectFolderListing#hidden_dir?` asks the same
question for the walk. Gated on `show_hidden` like a dot-dir, not unconditional like `.git`, because
there is a real reason to open one (a linker map, a generated header). `build` is deliberately
**not** on the list: a lowercase `build/` is a folder a maker plausibly made themselves, it never
appeared in the measured share library, and the project page has no "Show hidden" control to get it
back with. Like every rule in this section it is a display filter only — never an observer skip and
never a write guard — and it hides the **entry**, not its descendants, the same recorded limit
`.git` carries on chunk_remote.

Both scopes go on `FilesController#index`'s `scope =` assignment, **not** the `.order` chain —
`@match_count`/`@child_count` read the same object, so one line lower the truncation banner and the
pager count rows the page never renders.

## The inspector is ONE node's frame, and it must stay that

`FilesController#inspector` (structural redesign, slice 3) is the Library's right-hand panel for one
selected file: a Turbo Frame body rendered **without the layout**, built from `files/_meta` and
`files/_attach` — the SAME partials the file page renders, so the two cannot drift. Six rules:

- **Constant in N.** It reads one node, its stat, its current thumbnail, its attach choices, a note
  COUNT, its addon origin and its library path. `page_query_budget_test.rb` asserts it does not grow
  with the file's notes or projects. A per-row query here is paid on every selection.
- **`current_thumbnail`, never `Enqueue.call`.** The panel is opened again and again; `call` resets a
  `failed` render (the S4-5 asymmetry above), so a direct call would re-queue a broken render on
  every click. `inspector_test.rb` seeds a `failed` row and asserts nothing is queued.
- **Swap mode, never reload mode.** Its `thumbs` controller carries no `reload` value. A reload-mode
  controller here would reload the WHOLE Files page when the render lands; the file page's preview
  row is the one surface that owns reload mode.
- **`target="_top"`.** Open, a project link and every form's redirect replace the Library, never just
  the panel. The Files page's own `turbo_frame_tag` carries it (Turbo does not copy the response
  frame's target onto the page's frame).
- **A missing node answers a frame, never the controller's redirect.** `rescue_from` sends HTML to
  `files_path`, which inside a frame loads the whole Library into the panel. A folder, a tombstone,
  another user's node, a bogus id and a node that vanishes between lookup and `stat` all answer
  `files/inspector_gone` with 404. **Never fold `FetchError` into that rescue**: an unmounted share is
  "couldn't reach", not "gone" (§14a), so if an adapter's `stat` ever starts raising it, it gets its
  own frame with a 503. No adapter's `stat` raises it today (it is a database read of the node).
- **The tiles stay links.** Selection (`selection_controller.js`) intercepts only a plain click; every
  tile keeps `href=file_path`, which the file menu's Open, a modifier click, Enter and no-JavaScript
  all rely on. **The model strip above a model folder's files (`files/_model_strip`, slice 5) is not
  a selection item**: nothing in it goes through `with_selection`, because a model is not a file in
  the listing, so it never opens this frame (`model_strip_test.rb` asserts no `data-selection-target`
  inside it). **Recent and the project hub have no inspector (slice 6), so their file tiles are
  never selection items either**: neither page mounts a `selection` controller, so nothing there goes
  through `with_selection`. Each tile links `FilesHelper#library_file_path`, the file's folder in the
  Library with `?selected=` naming it (a root file's link is `/files?selected=…`, since Rails drops
  the nil `folder`), and this frame then answers "what is this" and its Open reaches the file page.
  **The Library's own tiles keep `file_path`**, which selection intercepts: `library_file_path` there
  would send the file menu's Open, a modifier click and Enter back to the Library instead of the
  file. On the hub, Photos, Schematics and the hero keep `file_path` too.

**`PHOTO_EXTS` is a DISPLAY subset of the image role, not a second vocabulary.** `jpg jpeg heic heif`
— what a camera writes — get `.thumb.photo` (cropped to fill, on `--photo-stage`); PNG, GIF, WebP,
BMP and TIFF keep `contain`, being more often screenshots, renders and scans. The ROLE stays `image`
for all ten (`ROLE_BY_EXT`), and `file_attachment_test.rb` asserts `PHOTO_EXTS` is a subset of
`IMAGE_EXTS`, so adding an extension still happens in `ROLE_BY_EXT` alone.

