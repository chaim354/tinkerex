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
