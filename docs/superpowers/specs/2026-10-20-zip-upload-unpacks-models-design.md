# A model .zip uploaded anywhere unpacks — design

2026-10-20. Branch `claude/zip-upload-and-model-attach`, shared with
`2026-10-20-attach-model-to-project-design.md` (independent; either can ship first). Facts cite
`main` at e14a589e.

The owner's request, verbatim: "Import .zip model should work from generic upload".

What prompted it: `Projects/stargate/` on the live share. A Printables zip uploaded through the
top-bar Upload was filed whole into `archives/` by project intake, and the model files had to be
unzipped by hand beside it.

Decisions taken with the owner before this was written:

| question | answer |
|---|---|
| What happens to a zip holding 3D model files? | Unpacked automatically, no extra click |
| Where do the files go? | A new folder named after the zip, in the folder Upload "Saves to"; at a project root, in its `models/` |
| The original zip? | Discarded — only the unpacked files are saved, as the Import page does |
| Where does the unpacking happen? | In the browser (JSZip), through the existing per-file upload doors |

## Today

- **The Import page** (`/models/new`, `importer_controller.js`) opens a zip with JSZip, creates a
  `Maker::Model` plus `Models/<slug>/` and its subfolders (`ModelsController#create` →
  `#ensure_folders`), then uploads every entry through `uploadPortFile` / `uploadChunkFile`
  (`lib/chunk_upload.js`) and attaches each to the model. No zip bytes reach Rails.
- **The top-bar Upload** (`layouts/_topbar_upload.html.erb`) has two flows chosen by
  `capabilities.port_writable?`: share/s3 is a plain multipart form whose `onchange` submits it to
  `FilesController#create`; chunk_remote is `uploader_controller.js`, which loops the selection
  through `uploadChunkFile`. Both upload a `.zip` as one file. In a project, `Maker::ProjectIntake`
  then files it into `archives/` (or `pcb/` for a board zip).
- **The rule this follows** is `Maker::GerberArchive`'s: *the server lists, the browser extracts.*
  Unpacking stays in the browser on every backend.

## What the user sees

Upload through the top bar, on any backend. For each `.zip` in the selection the page reads the
zip's directory. **If any entry is a model-role file**, the zip is unpacked instead of uploaded:
the status reads "Unpacking <name>.zip — 4/18" and each entry is uploaded on its own. Everything
else in the same selection, and any zip with no model-role entry (Gerbers, firmware, a source
dump), uploads exactly as today.

When the selection was one model zip, the browser lands on the new folder; otherwise a clean run
reloads the page it was on. **Anything that went wrong keeps the status line on screen and does not
reload** — a reload would wipe the one line naming what was unpacked, what uploaded as it is, and
what failed.

**"Model-role" is the server's vocabulary, not a second list.** The page receives the extensions
`Maker::FileAttachment::ROLE_BY_EXT` maps to `"model"` (stl, 3mf, obj, step, stp, gltf, glb, ply,
off, dae, wrl, 3ds, fbx, 3dm, amf, iges, igs, brep at e14a589e) as a data attribute. The importer's
own `MODEL_EXT` (five extensions) is the drift this avoids; the importer keeps its role labels for
its summary line, which is display only.

## Where the files go

A new folder named after the zip without `.zip`, inside the upload's destination — the folder the
Upload button says it "Saves to" (`FolderDestination`), or the folder the chooser returned on a
page with none.

1. **At a project root the folder goes in `models/`, the shelf the catalog reads.** When the
   destination is a project's own folder (`Maker::Project#folder_node_id`), the unpack folder is
   created inside `models/` (`Maker::ProjectFolders::ROLE_FOLDERS["model"]`) — always, NOT where
   the maker's filing rules send an `.stl`: those are per user and can say `prints/` or `other/`,
   which no shelf names, so a folder there would never be catalogued. Stargate becomes
   `Projects/stargate/models/stargate-with-a-working-iris-model_files/`. Anywhere else, including
   a project's subfolder, the destination is used as it is.
2. **One wrapper folder is dropped.** When every entry sits under the same single top-level
   directory, that level is removed, so a zip of `widget/…` does not become `widget/widget/…`.
3. **Clutter is skipped:** any path segment starting with `.` (which covers `__MACOSX/._*` and
   `.DS_Store`) and the `__MACOSX` directory itself. Entries that are directories are skipped;
   their files carry the structure.
4. **A taken name gets a number.** If the destination already holds a file or folder with that
   name, the folder is `<name> 2`, then `<name> 3`, and so on. Re-uploading the same zip never
   collides with the first copy's files.

The catalog then sees an ordinary model folder: `Maker::ModelIntake`'s shelves (`Models`, `*`,
`Projects/*/models`) make it a model with no new rule.

## Components

1. **`app/javascript/lib/zip_bundle.js` (new).** `listZipBundle(file)` → `[{ name, dir, load }]`,
   LAZY: it reads the archive's index only, and `load()` inflates one entry when it is about to be
   uploaded, so a zip with no model is never decompressed and a model zip never sits in memory
   whole. `readZipBundle(file)` → `[{ name, dir, blob }]` is the EAGER form, for the Import page.
   Both share the clutter skip, wrapper strip and `dir/name` de-dupe moved out of
   `importer_controller.js#choose`; "does it hold a model?" is `lib/zip_unpack.js#splitSelection`
   asking the listed names (there is no `hasModel`). The importer's title derivation, roles and
   summary stay where they are. One reader, so the Import page and Upload cannot disagree about
   what a zip holds.
2. **`POST /files/unpack_folder` (new, JSON, `Files::UnpacksController#create`).** Params
   `{ parent_node_id, name, dirs: [] }`. Resolves the destination (rule 1 above — at a project root
   always `models/`), picks a free name (rule 4), creates the folder and every requested
   subfolder, and answers `{ folder_node_id, folder_url, folder_map: { "" => id, "sub/dir" => id } }`.
   Creates folders only — never bytes, so §15 is untouched. The same guards as
   `ModelsController#ensure_folders` and `LibraryBrowseController#create_folder`:
   `Maker::MoveNode.valid_leaf_name?` and `Library::ReservedNames.reserved?` on the folder name and
   on every subfolder segment. `name` must be a String (a JSON array is refused, not stringified),
   and the NUMBERED name is checked again, since `" 2"` can push a long name past the byte limit. A
   subfolder with a bad or dot-prefixed segment is left out, so its files fall back to the root as
   the importer's do; at most `MAX_DIRS = 1000` subfolders per request. The parent must be one of
   `current_user`'s live dir nodes (or blank for the library root). Folder creation goes through
   `Maker::LibraryFolder`, so all three backends share it. `FileLayer::FetchError` → 503, an
   invalid name → 422, another user's parent → 404.
3. **The top-bar Upload, both flows.**
   - chunk_remote: `uploader_controller.js#upload` gains the branch — model zips are unpacked
     through `unpack_folder` + `uploadChunkFile` per entry; other files keep their current loop.
   - share/s3: a new `zip-upload` Stimulus controller on the form. On `change` it reads the
     selection; with no model zip it calls `requestSubmit()` exactly as the inline `onchange` does
     today (the inline handler moves into the controller). With one, it takes over the selection:
     model zips unpack through `unpack_folder` + `uploadPortFile`, and the other files go up one
     by one through `uploadPortFile` into the same `parent_node_id`.
   - `upload_pick_controller.js` (pages with no folder) is unchanged: it writes the destination
     into the field and the value both flows already read.
4. **The catalog nudge: `POST /files/unpacked` (new, JSON) `{ folder_node_id }`.** After the last
   entry, the page posts once. The server checks that the folder is `current_user`'s and enqueues
   `Maker::ModelIntakeJob.perform_later(user_id:)` (its `limits_concurrency` already discards a
   duplicate). The model card then appears in seconds rather than at the next 15-minute sweep.
   Enqueuing is not sweeping: nothing sweeps inside the request.

## Failures

- **One entry fails** (a name refused, a network error): it is skipped and the rest continue —
  the importer's rule and `uploader_controller.js`'s. The status names each failure.
- **No entry lands:** the status says the unpack failed. The folder `unpack_folder` made stays;
  the browser never deletes.
- **A zip JSZip cannot read** (corrupt, encrypted): it uploads as an ordinary file, as today, and
  the status says it could not be opened.
- **The tab closes mid-unpack:** a partly filled folder, the same exposure the Import page has
  today. The catalog sweep still catalogues what landed.

## Out of scope

- The Import page's own flow (a `Maker::Model` with `origin: "import"`, a source URL, per-file
  model attachments) does not change beyond reading zips through `zip_bundle.js`.
- Zips arriving any other way (the desktop client, Finder on the share, the build-log
  "Upload & attach" control) are not unpacked.
- No server-side unzip, no size cap beyond the browser's own memory (a 30 MB model zip is
  ordinary).

## Limitations

- **A project adopted outside `Projects/` does not get its unpacked folder catalogued as a model of
  its own.** `models/` is a shelf only under `Projects/*/models`; elsewhere the `*` shelf above the
  project decides. Probed: at `3D/lamp/` nothing is catalogued (the project claims its own folder,
  which is that shelf's child); at a top-level `lamp/`, itself a shelf, all of `models/` is
  catalogued as ONE model titled `models`. The files land either way.

## Tests

- **`unpack_folder`:** a plain folder destination; a project root → `models/`, even when the
  user's filing rule sends `stl` elsewhere; a project subfolder used as-is; a taken name →
  `<name> 2`; reserved and invalid names refused; a bad subfolder segment falls back to the root;
  another user's parent → 404; blank parent → library root. Pinned to a fresh share library: they
  assert where folders go, not which backend holds them (Maker::LibraryFolder is the
  backend-neutral door, tested on its own).
- **`unpacked`:** enqueues `Maker::ModelIntakeJob` for the current user; another user's folder →
  404.
- **The seam** (`unpack_to_models_panel_test.rb`): unpack at a project root, upload an STL into the
  returned folder, sweep → the project's Models panel (`Maker::ProjectModels`) has a model titled
  after the zip.
- **`zip_bundle.js`:** through the Import page's existing system test (it must still import a
  fixture zip) plus a wrapper-folder fixture.
- **System, per backend leg** (the upload controls branch on `port_writable?`, so an assertion
  must too): upload a fixture zip holding an STL through the top bar → the unpacked folder with
  the STL and no zip; upload a zip with no model file → the zip as a file; upload at a project
  root → the folder lands in `models/`.
