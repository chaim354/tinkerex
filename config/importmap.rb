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

pin "lib/chunk_upload", to: "lib/chunk_upload.js"
# The chooser modal, imported by BOTH filechooser_controller (the form field) and addon_controller
# (which hands it to a bundle as ctx.chooseFolder). A host pin, so it is drawn into every addon's
# merged importmap too — but a bundle must NOT import it by this specifier: the contract is the
# ctx function, so that this path stays the host's to change without republishing a bundle.
pin "lib/file_chooser", to: "lib/file_chooser.js"

# THE ADDON SDK — a HOST pin, which is the whole point: merged_importmap draws every host pin before
# the addon's own, so a bundle imports "@maker/addon-sdk" without declaring anything in its manifest
# and without the host shipping a copy per addon. Unlike lib/file_chooser directly above (which a
# bundle must NOT import — its contract is the ctx function), this specifier IS the public contract:
# it is what docs/addon-api-v1.md tells authors to import, so the SPECIFIER may never change while
# api_version 1 lives, even though the file behind it may move freely.
pin "@maker/addon-sdk", to: "maker/addon_sdk.js"

# Three.js r0.185.1 (MIT) — the interactive 3D viewer (modelviewer_controller.js), DYNAMIC-imported
# so the payload ships only on pages with a 3D file. Vendored from unpkg (the official ES build),
# NOT `bin/importmap pin three` (jspm): jspm splits the core into an internal `../_/…` chunk and
# minifies, the same dangling-relative-import class as JSZip above. The official build is cleaner:
# `three.module.js` re-exports `./three.core.js` (repointed to the bare "three-core" specifier), and
# `3MFLoader.js` imports fflate via a relative path (repointed to the bare "fflate"). OrbitControls/
# STL/OBJ import only the bare "three". The addon specifiers use three's own "three/addons/…" alias
# so the code reads idiomatically. Verified: no dangling relative/URL import remains in any file.
pin "three", to: "three.module.js" # @0.185.1
pin "three-core", to: "three.core.js" # @0.185.1 — three.module.js's core (the only thing that imports it)
pin "fflate", to: "fflate.js" # MIT — 3MFLoader's unzip dependency (examples/jsm/libs/fflate.module.js)
pin "three/addons/controls/OrbitControls.js", to: "OrbitControls.js" # @0.185.1
pin "three/addons/loaders/STLLoader.js", to: "STLLoader.js" # @0.185.1
pin "three/addons/loaders/OBJLoader.js", to: "OBJLoader.js" # @0.185.1
pin "three/addons/loaders/3MFLoader.js", to: "3MFLoader.js" # @0.185.1
# Lexxy (MIT) — the Action Text editor, replacing Trix. Served from the gem's own asset path, so
# there is nothing vendored under vendor/javascript and no jspm shared-chunk patching (see the
# jszip notes above). Attachments are disabled at the element, so @rails/activestorage is
# not imported.
pin "lexxy", to: "lexxy.js"
pin "@rails/actiontext", to: "actiontext.esm.js"
