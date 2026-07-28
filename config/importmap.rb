# Pin npm packages by running ./bin/importmap

pin "application"
pin "@hotwired/turbo-rails", to: "turbo.min.js"
pin "@hotwired/stimulus", to: "stimulus.min.js"
pin "@hotwired/stimulus-loading", to: "stimulus-loading.js"
pin_all_from "app/javascript/controllers", under: "controllers"
pin_all_from "app/javascript/generators", under: "generators"

# JSZip 3.10.1 — MIT/GPLv3 dual-licensed (we use it under MIT) — https://github.com/Stuk/jszip
# JSZip (browser standalone build) — used by importer_controller to unzip a downloaded model
# bundle client-side; no zip bytes ever reach Rails (§15/§10 untouched). Vendored via
# `bin/importmap pin jszip@3.10.1/dist/jszip.min.js` (the plain `pin jszip` resolves to the
# package's Node/CJS `main` entry, which drags in ~17 Node-stream polyfills, one with a
# `#`-prefixed filename that breaks as a served asset URL — the browser dist build only needs
# two small shims). Renamed to the bare "jszip" specifier/"jszip.js" filename post-download so
# `import JSZip from "jszip"` resolves; the vendored bytes themselves are untouched.
pin "jszip", to: "jszip.js" # @3.10.1
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

# Maker.js 0.19.2 — Apache-2.0 — https://maker.js.org — the client-side geometry engine for the
# Generators addon (Tools::GeneratorsController; app/javascript/generators/*). Vendored as the jspm
# ESM build (`bin/importmap pin makerjs`), NOT the `dist/browser.maker.js` standalone build: that one
# is a non-standalone Browserify bundle that exposes only Browserify's `require` (no importable global
# or default export — verified), so `import makerjs from "makerjs"` can't resolve it. The jspm build
# has a real `export default` and pulls makerjs's four deps below.
# CAUTION: `clone` imports "buffer", which reuses the SAME hand-patched vendor/javascript/buffer.js as
# jszip (repointed at "jszip-buffer-chunk"). Re-running `bin/importmap pin makerjs` (or jszip)
# RE-DOWNLOADS buffer.js and reverts that patch (a dangling `../../_/…` import) — breaking BOTH. If you
# re-pin, `git checkout vendor/javascript/buffer.js` afterward.
pin "makerjs" # @0.19.2
pin "bezier-js" # @2.6.1
pin "clone" # @1.0.4
pin "graham_scan" # @1.0.5
pin "kdbush" # @2.0.1

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
# jszip/Maker.js notes above). Attachments are disabled at the element, so @rails/activestorage is
# not imported.
pin "lexxy", to: "lexxy.js"
pin "@rails/actiontext", to: "actiontext.esm.js"
