# Pin npm packages by running ./bin/importmap

pin "application"
pin "@hotwired/turbo-rails", to: "turbo.min.js"
pin "@hotwired/stimulus", to: "stimulus.min.js"
pin "@hotwired/stimulus-loading", to: "stimulus-loading.js"
pin_all_from "app/javascript/controllers", under: "controllers"

# JSZip 3.10.1 — MIT/GPLv3 dual-licensed (we use it under MIT) — https://github.com/Stuk/jszip
# JSZip (browser standalone build) — used by importer_controller to unzip a downloaded model
# bundle client-side; no zip bytes ever reach Rails (§15/§10 untouched). Vendored via
# `bin/importmap pin jszip@3.10.1/dist/jszip.min.js` (the plain `pin jszip` resolves to the
# package's Node/CJS `main` entry, which drags in ~17 Node-stream polyfills, one with a
# `#`-prefixed filename that breaks as a served asset URL — the browser dist build only needs
# two small shims). Renamed to the bare "jszip" specifier/"jszip.js" filename post-download so
# `import JSZip from "jszip"` resolves; the vendored bytes themselves are untouched.
pin "jszip", to: "jszip.js" # @3.10.1
# ALSO a transitive dependency of the `generators` addon bundle's `clone` pin (clone.js
# bare-imports "buffer" — the bundle itself now lives in the chaim354/tinkerex-addons repo, served
# by the `addons` Kamal accessory in production, Phase B), which resolves through this HOST pin —
# the merged per-addon importmap (Tools::AddonsController#merged_importmap) draws every host pin
# before adding the addon's own, so an addon never has to re-pin something the host already
# provides. Removing this pin would break `generators`' save flow with no local error pointing here.
pin "buffer" # @2.1.0
pin "process" # @2.1.0
# buffer.js (above) ships a relative import, `../../_/C7GZrc4O.js`, to an internal jspm shared
# chunk that `bin/importmap pin` does NOT vendor (it's not a top-level package, so it's invisible
# to the generate response's import list) and that Propshaft's flat /assets/* serving could never
# satisfy as a literal relative path even if placed locally. Fetched the real chunk from the same
# jspm CDN via Importmap::Packager#download (so the bytes are genuine, not hand-written) and
# repointed buffer.js's one import line at this bare specifier instead of the dangling relative
# path. Without this, `import JSZip from "jszip"` 404s in the browser via buffer.js's dead import.
pin "jszip-buffer-chunk" # jspm.io internal chunk for @jspm/core@2.1.0's browser buffer shim

# SortableJS 1.15.7 — MIT — https://github.com/SortableJS/Sortable. Drag-to-reorder for the page
# editor (layout_editor_controller.js). Vendored via `bin/importmap pin sortablejs@1.15.7`, which
# jspm resolves to the package's own `modular/sortable.esm.js` — an ES module with a default export
# and NO bare imports, so there is no transitive pin and no jspm shared chunk to patch (the jszip
# notes above are the counterexample). Licence in vendor/javascript/LICENSE-sortablejs.md.
# Hand-rolled pointer dragging was rejected for touch, auto-scroll and drop placement in a
# two-column grid (spec 2026-09-09-page-editor §5).
pin "sortablejs" # @1.15.7

pin "lib/chunk_upload", to: "lib/chunk_upload.js"
# The chooser modal, imported by BOTH filechooser_controller (the form field) and addon_controller
# (which hands it to a bundle as ctx.chooseFolder). A host pin, so it is drawn into every addon's
# merged importmap too — but a bundle must NOT import it by this specifier: the contract is the
# ctx function, so that this path stays the host's to change without republishing a bundle.
pin "lib/file_chooser", to: "lib/file_chooser.js"
pin "lib/zip_bundle", to: "lib/zip_bundle.js"
pin "lib/zip_unpack", to: "lib/zip_unpack.js"

# The Measure view's to-scale print — pagination and sheet rendering, imported by
# measure_controller.js. A HOST pin like the two above, so it is drawn into every addon's merged
# importmap too. A bundle must NOT import it — the `boxes` bundle ships its own sheet.js
# precisely so neither repo can break the other (the module header argues that in full).
pin "lib/print_sheet", to: "lib/print_sheet.js"

# One geometry-payload shape -> one SVG element, and the `el`/`unionBox` doors that used to live in
# lib/print_sheet. Imported by print_sheet, by measure_controller and by lib/export_svg, so all
# three draw the same element for the same shape. HOST pins like the ones above; a bundle must NOT
# import either — they read this app's own geometry payload, which is not part of the addon API.
pin "lib/shape_svg", to: "lib/shape_svg.js"
pin "lib/export_svg", to: "lib/export_svg.js"

# ONE viewBox pan/zoom for every SVG stage — imported STATICALLY by measure_controller.js (which is
# where the maths was written) and by gerber_controller.js. A HOST pin like the ones above; a bundle
# must NOT import it, since it takes an <svg> element this app built. Preloaded on purpose, unlike
# the lazy bundles below: it is ~4 KB and both importers are plain controller modules the page
# already loads, so `preload: false` would only cost a second round trip on a page that is certain
# to want it.
pin "lib/svg_pan_zoom", to: "lib/svg_pan_zoom.js"

# The source viewers' ext -> language table (plus our own g-code and OpenSCAD stream modes).
# A HOST pin like the three above, so it is drawn into every addon's merged importmap — but a
# bundle must NOT import it: it takes the CodeMirror namespace as an argument, so it is only
# meaningful to a controller that already holds the bundle. DYNAMIC-imported from there, beside
# "codemirror" itself, so neither ships on a page with no text file.
#
# THREE CONTROLLERS NOW, not one: codeview (read-only), editor (editable, inside a working tree)
# and diffview (the commit box's inline diff). The count is not load-bearing — what is, is that
# every one of them dynamic-imports, so this never ships on a page with no text file.
pin "lib/codemirror_languages", to: "lib/codemirror_languages.js", preload: false

# Which CodeMirror theme the page wants, read from html[data-theme]. A HOST pin for the same
# reason as the languages table directly above — it takes the CodeMirror namespace as an argument
# rather than importing the bundle, so it is only meaningful to a controller that already holds
# it, and it is DYNAMIC-imported from all three so neither it nor the bundle ships on a page with
# no text file. There is no pin_all_from for app/javascript/lib: every module in it is pinned by
# name, so a new one that nothing pins resolves to nothing and its importer's dynamic import
# rejects — which in these three controllers degrades silently to the plain <pre>.
pin "lib/codemirror_theme", to: "lib/codemirror_theme.js", preload: false

# THE ADDON SDK — a HOST pin, which is the whole point: merged_importmap draws every host pin before
# the addon's own, so a bundle imports "@maker/addon-sdk" without declaring anything in its manifest
# and without the host shipping a copy per addon. Unlike lib/file_chooser directly above (which a
# bundle must NOT import — its contract is the ctx function), this specifier IS the public contract:
# it is what docs/addon-api-v1.md tells authors to import, so the SPECIFIER may never change while
# api_version 1 lives, even though the file behind it may move freely.
pin "@maker/addon-sdk", to: "maker/addon_sdk.js"

# Three.js r0.185.1 (MIT). Vendored from unpkg (the official ES build), NOT `bin/importmap pin
# three` (jspm): jspm splits the core into an internal `../_/…` chunk and minifies, the same
# dangling-relative-import class as JSZip above. The official build is cleaner: `three.module.js`
# re-exports `./three.core.js` (repointed to the bare "three-core" specifier), and `3MFLoader.js`
# imports fflate via a relative path (repointed to the bare "fflate"). OrbitControls imports only
# the bare "three". The addon specifier uses three's own "three/addons/…" alias so the code reads
# idiomatically. Verified: no dangling relative/URL import remains in any file.
#
# NOTHING IN THIS REPO IMPORTS THESE ANY MORE, AND THEY STAY ANYWAY — THEY ARE AN ADDON CONTRACT.
# The 3D viewer moved to Online3DViewer (pinned below), which bundles its own three, so the last
# host importer of these five pins is gone. `chaim354/tinkerex-addons`' openscad bundle
# dynamic-imports "three", "three/addons/controls/OrbitControls.js" and
# "three/addons/loaders/3MFLoader.js" THROUGH THIS MAP — Tools::AddonsController#merged_importmap
# draws every host pin before the addon's own, so a bundle never re-pins what the host provides
# (the @maker/addon-sdk pin above states the rule). Removing any of them breaks that addon at
# runtime with no local error pointing here, exactly as the `buffer` note above warns for
# `generators`. `three-core` and `fflate` are transitive: three.module.js and 3MFLoader import
# them by those bare specifiers.
#
# `STLLoader.js` AND `OBJLoader.js` WERE RETIRED WITH THE OLD VIEWER (2026-09-06) and their
# vendored files deleted. They are the two the openscad bundle does NOT import — checked against
# that repo, which is the only reason they could go while their five neighbours could not.
pin "three", to: "three.module.js" # @0.185.1 — addon contract (openscad)
pin "three-core", to: "three.core.js" # @0.185.1 — three.module.js's core (the only thing that imports it)
pin "fflate", to: "fflate.js" # MIT — 3MFLoader's unzip dependency (examples/jsm/libs/fflate.module.js)
pin "three/addons/controls/OrbitControls.js", to: "OrbitControls.js" # @0.185.1 — addon contract
pin "three/addons/loaders/3MFLoader.js", to: "3MFLoader.js" # @0.185.1 — addon contract
# CodeMirror 6 (MIT) — the source viewers (codeview_controller.js read-only,
# editor_controller.js editable, diffview_controller.js the commit box's inline diff),
# DYNAMIC-imported so the payload ships only on a page that shows a text file. ONE PIN FOR ONE BUNDLE, built by
# bin/build-codemirror from vendor/javascript/codemirror-entry.js — unlike everything else in
# vendor/javascript/, these are BUILT bytes rather than untouched upstream ones, which is why that
# script pins all 40 packages in the resolved tree and not just the 15 direct ones.
#
# NEVER add `pin "@codemirror/..."` lines beside this. Two copies of @codemirror/state make
# facets and StateFields fail to match by object identity, and CM6 responds by silently ignoring
# the extension — no error, no warning. test/ci_hygiene_test.rb fails the build if a per-package
# pin appears. To add a language, add it to codemirror-entry.js and rebuild.
pin "codemirror", to: "codemirror.js", preload: false # bundle: see bin/build-codemirror for pinned versions

# KiCanvas (MIT; notices in vendor/javascript/LICENSE-kicanvas.md) — KiCad schematics and boards
# rendered in the browser. ONE vendored build from a pinned commit (bin/build-kicanvas), the
# CodeMirror pattern: no npm package, no CDN. Imported LAZILY by kicanvas_controller.js on the
# pages that hold a .kicad_sch/.kicad_pcb, so nothing else downloads its 470 KB. The module
# has no exports; importing it registers <kicanvas-embed> and <kicanvas-source>.
#
# `preload: false` ON EVERY LAZY PIN, OR THE LAZINESS IS FICTION. importmap-rails 2.x emits a
# <link rel="modulepreload"> for every pin by default, so a bundle a controller dynamic-imports
# only when a file is opened was still FETCHED on every page -- measured on the dev server: the
# 477 KB kicanvas.js and the CodeMirror bundle in the sign-in page's preload set. The pin stays
# (a dynamic import still resolves through the map); only the preload hint goes.
# test/integration/web/lazy_bundles_test.rb drives a real page and pins it.
pin "kicanvas", to: "kicanvas.js", preload: false # bundle: see bin/build-kicanvas for the pinned commit

# tracespace (MIT; notices in vendor/javascript/LICENSE-tracespace.md) — Gerber and Excellon drill
# files rendered in the browser as SVG, so this app ships NO server-side PCB renderer and no
# sidecar (gerbv is GPL, §9). ONE vendored build from pinned npm versions (bin/build-tracespace),
# the CodeMirror/KiCanvas pattern: no npm package at runtime, no CDN.
#
# `preload: false` FOR THE REASON KiCANVAS'S PIN ARGUES DIRECTLY ABOVE — the pin stays so a dynamic
# import resolves, only the modulepreload hint goes. gerber_controller.js is the ONE importer and it
# imports lazily on connect, so no page without a Gerber pays the 98 KB.
# test/integration/web/lazy_bundles_test.rb drives a real page and pins it.
#
# UNLIKE KiCanvas THIS MODULE HAS EXPORTS AND IS NOT A CUSTOM-ELEMENT REGISTRATION: the controller
# calls read/plot/renderLayers/renderBoard/stringifySvg itself and puts the resulting markup in the
# stage, which is why the SVG lands in the LIGHT DOM (KiCanvas paints into a shadow root).
pin "tracespace", to: "tracespace.js", preload: false # bundle: see bin/build-tracespace for the pinned versions

# Online3DViewer 0.18.0 (MIT; notices in vendor/javascript/LICENSE-o3dv.md) — the interactive 3D
# viewer (modelviewer_controller.js), which replaced the hand-rolled Three.js one on 2026-09-06 and
# with it grew the viewable set from three formats to nineteen. ONE vendored build from pinned npm
# versions (bin/build-o3dv), the CodeMirror/KiCanvas/tracespace pattern: no npm package at runtime,
# no CDN.
#
# BUILT FROM `source/engine/main.js`, NOT COPIED FROM THE PACKAGE'S OWN `build/engine/`. That
# shipped module leaves nine bare imports unresolved (`three`, five `three/examples/jsm/loaders/*`,
# `fflate`), so vendoring it would resolve `three` through the pins above — 0.185.1 against the
# engine's own 0.176.0 — and need five new pins nothing else wants. The bundle carries its own
# three, which is why the pins above are now an ADDON contract and nothing more.
#
# `preload: false` FOR THE REASON KiCANVAS'S PIN ARGUES ABOVE — the pin stays so a dynamic import
# resolves, only the modulepreload hint goes. This is the largest lazy bundle in the app (1.0 MB,
# 274 KB gzipped), and modelviewer_controller.js imports it only when the user clicks "View in 3D",
# so a page holding a 3D file does not pay for it either until then.
# test/integration/web/lazy_bundles_test.rb drives a real page and pins it.
#
# THE WASM IMPORTERS ARE NOT IN THE BUNDLE and are not pinned: OpenCascade (STEP/IGES/BREP/FCStd),
# rhino3dm (3DM) and the Draco glTF decoder are separate files under public/o3dv/0.18.0/ that the
# engine fetches at runtime — served static and unfingerprinted, which is why the version is in the
# DIRECTORY name. bin/build-o3dv rewrites upstream's hard-coded jsdelivr URLs to that path and
# refuses to ship a bundle that still names a CDN.
pin "online-3d-viewer", to: "o3dv.js", preload: false # bundle: see bin/build-o3dv for the pinned versions
# Lexxy (MIT) — the Action Text editor, replacing Trix. Served from the gem's own asset path, so
# there is nothing vendored under vendor/javascript and no jspm shared-chunk patching (see the
# jszip notes above). Attachments are disabled at the element, so @rails/activestorage is
# not imported.
pin "lexxy", to: "lexxy.js"
pin "@rails/actiontext", to: "actiontext.esm.js"
