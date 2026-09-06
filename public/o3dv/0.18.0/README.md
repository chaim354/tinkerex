# Online3DViewer external importers — v0.18.0

Written by `bin/build-o3dv`; do not edit by hand. These are the WebAssembly importers
`vendor/javascript/o3dv.js` loads at runtime, from this directory rather than from jsdelivr (see
that script's header for why). Served static and unfingerprinted, so the version lives in the
directory name and `/o3dv/0.18.0/` is baked into the bundle.

| file | package | version | licence |
|---|---|---|---|
| `occt-import-js.{js,wasm}`, `occt-import-js-worker.js` | occt-import-js | 0.0.22 | **LGPL-2.1** (`license.occt-import-js.txt`), wrapping OpenCASCADE (`license.occt.txt`) |
| `rhino3dm.min.js`, `rhino3dm.wasm` | rhino3dm | 8.17.0 | MIT |
| `draco_decoder_nodejs.js`, `draco_decoder.wasm` | draco3d | 1.5.7 | Apache-2.0 |

**occt-import-js is the one LGPL thing this app ships to a browser** (STEP/IGES/BREP/FCStd). It is
a separate file the browser fetches and runs on its own; nothing links against it and no part of
it is copied into our bundle, which is the LGPL's own dynamic-use case — and the same posture the
Dockerfile already takes for OCCT inside the F3D subprocess. Replacing it is a matter of dropping a
different build in this directory. CLAUDE.md §9.

**web-ifc is deliberately absent** (MPL-2.0, file-level copyleft). `.ifc` is not in
`Maker::FileAttachment::VIEWABLE_3D_EXTS`, so no page can reach that importer.
