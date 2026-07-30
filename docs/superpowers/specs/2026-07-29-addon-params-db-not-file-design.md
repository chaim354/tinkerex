# Addon params live in the DB, not in a library file

**Date:** 2026-07-29
**Status:** approved, not implemented
**Scope:** `boxes`, `generators`, `openscad` — all three addons

## 1. What this is, and what it is not

Every addon save currently writes **two** files into the library: its real output (SVG / 3MF) and a
`<name>-<id>.params.json` recording the parameters that produced it.

**The params are already in the database.** `Maker::AddonState#data` is a `json` column holding each
addon's own shape (`{ generator:, params: }` for boxes and generators; `{ generator:, node_id:,
params: }` for openscad), and every reader in the app already goes to *that*: the show pages'
Generator/Source line, "Duplicate & tweak", and the "prior" rail on boxes' `new`.

**Nothing reads the file.** It is write-only. So this is not "add DB storage" — it is **stop writing
the second file**, and replace the one job it actually did: making the params readable and portable
outside the app.

## 2. Decisions

| Decision | Choice | Why |
|---|---|---|
| Scope | **All three addons** | The three `LibraryOutput.write` calls are identical. Fixing one would leave three addons with different bundle shapes for no stated reason, and the next reader has to discover why. |
| Files already written | **Left in place** | They are ordinary library files the user may have renamed, organized, or attached to a project. A migration must not delete user bytes. |
| Join rows already written | **Deleted** | The `AddonFile` row is what makes the file part of the addon *bundle*. With the concept gone, the row is the only thing still asserting it. |
| Replacement | **Params list on the show page + a JSON download** | Preserves both jobs of the removed file (readable, portable) without storing anything. |
| `LibraryOutput` | **Untouched** | It is role-agnostic by design and has no idea what "parameters" meant. |

## 3. The removal

Drop the second entry from the `files:` array in three `create` actions:

- `app/controllers/tools/boxes_controller.rb:75`
- `app/controllers/tools/generators_controller.rb:34`
- `app/controllers/tools/openscad_controller.rb:69`

Each is left writing exactly one file, role `output`.

**Nothing downstream breaks, and the reason is worth stating** rather than assumed: the boxes "prior"
rail selects its thumbnail with `files.find { |f| f.role == "output" }`
(`app/views/tools/boxes/new.html.erb:44`) — by role, not by index — so a one-element bundle is fine.
`attach_addon_files_to_current_project` maps over whatever it is handed. The show pages iterate
`@state.files`. No caller indexes into the array.

Two consequences, both intended:

- New saves stop enqueuing a preview for the JSON file (`LibraryOutput.enqueue_preview` runs per
  file, and a `.json` gets a "document" thumbnail nobody looked at).
- The show pages' "Bundle" list now has a single entry. **Keep the list** — its comment already
  anticipates more output formats, and that is still true.

## 4. The replacement surface — one, not three

`Maker::AddonState` is deliberately addon-agnostic ("nothing here is addon-specific"), so the
replacement is too. No per-addon branching, no three copies.

### 4.1 `Tools::AddonParamsController#show`

```
GET /tools/addon_states/:id/params  ->  tools_addon_params_path(state)
```

One action: `send_data JSON.pretty_generate(state.data)`, `type: "application/json"`,
`disposition: "attachment"`, `filename: "#{state.name.parameterize.presence || state.addon_key}-#{state.id}.params.json"`.

- **Scoped through `current_user.maker_addon_states.find`.** Another user's id raises
  `RecordNotFound` → the app's existing 404. Tenant isolation by construction, not by a check that
  can be forgotten.
- Inherits `Tools::BaseController`, so it is session-authed like every other addon surface.
- **The route is declared at top level, not inside `namespace :tools`.** `config/routes.rb` documents
  two inflector traps that made `openscad`'s routes hand-written; one shared route avoids
  relitigating either.
- `state.name.parameterize` can be blank (a name of only emoji or punctuation), hence the
  `addon_key` fallback. The per-addon fallbacks in the `create` actions (`box`/`drawing`/`model`)
  are not worth reproducing here — this filename is a download hint, not a library name.

### 4.2 `app/views/tools/shared/_params.html.erb`

A `dl.meta` of `state.data["params"]` plus the download link. Rendered by all three show pages
(`tools/boxes/show`, `tools/generators/show`, `tools/openscad/show`), after each page's existing
bundle section — the three pages are structured differently (boxes and openscad open with a
`dl.meta`, generators opens with the live editor), and the partial is self-contained enough not to
care.

**Values can be multiline.** Boxes' `TrayLayout`/`FrontPanel`/`NightLightBox` section params are
newline-separated, so a value cell that collapses whitespace renders them as one mangled line. The
cell needs `white-space: pre-wrap` — a scoped rule (`.addon-params dd`) beside the existing
`dl.meta` rules in `application.css` (there is no such class today; `.mono` and `dl.meta` exist).

Empty `params` (`{}`) renders "No parameters." — the download link stays either way, since `data`
still carries `generator`.

### 4.3 The one asymmetry, on the record

The **display** lists `data["params"]`. The **download** serves the whole `data` hash — which is
byte-identical to the file being removed (all three addons wrote `JSON.pretty_generate` of the whole
hash).

That is deliberate. `generator` is what made the file self-describing: with it, you can tell what
produced the SVG sitting next to it; without it, the download is an anonymous bag of numbers. In the
*display*, `generator` is redundant — every show page already prints it above the list as
Generator / Source / subtitle. Openscad's `node_id` stays in the download for the same
faithfulness reason; it was already there.

## 5. Existing rows

A `def up`-only migration:

```sql
DELETE FROM maker_addon_files WHERE role = 'parameters'
```

- **Raw SQL via `execute`, not `Maker::AddonFile.where(...).delete_all`.** A migration is history and
  must not depend on a model that may later change or disappear. This SQL is valid on both SQLite and
  Postgres, per the adapter-agnostic rule.
- `down` raises `ActiveRecord::IrreversibleMigration`.
- **The bytes are untouched.** Three things that survive, all verified against the code rather than
  assumed:
  - A params file attached to a project keeps its `Maker::FileAttachment` — a separate record created
    at save time — so it stays visible in the project panel. It stops being part of the addon
    *bundle*, which is the whole point.
  - Its `Maker::Preview` rows stay valid: the node still exists, so the preview reaper (which reaps
    previews whose node is gone) will not touch them.
  - The file is self-describing in the library — the name embeds the state id.
- This is a one-way deletion of metadata on live data. That is the accepted trade; the alternative
  (leaving the rows) means the show pages keep listing a file the addon no longer produces.

## 6. Tests

Written failing-first, then the change.

**New — `test/controllers/tools/addon_params_controller_test.rb`**
- Serves `JSON.pretty_generate(state.data)` — the whole hash, including `generator`.
- `Content-Disposition` is `attachment` with the `<name>-<id>.params.json` filename.
- Another user's state id → 404.
- Unauthenticated → redirected to login (the `BaseController` contract).
- A state whose `name.parameterize` is blank falls back to `addon_key` in the filename.

**Changed — the three `create` tests.** They currently assert a two-file bundle and "both output
files (svg + params.json) must be the attached nodes"
(`boxes_controller_test.rb:287`, `generators_controller_test.rb:93,207`,
`openscad_controller_test.rb:278,303,362`). These invert to: the bundle is exactly one file with role
`output`; **no node named `*.params.json` exists in the library after a save** (asserting the absence
at the library level, not just the join level — the file is what we are removing); the project
attachment is that one node.

**New — show-page tests, all three addons.** Params rows render; a multiline value survives (assert
the newline is still in the response body, since that is exactly what a collapsing cell destroys);
the download link is present.

**Left alone deliberately:** `test/services/maker/addons/library_output_test.rb:25` and
`test/models/maker/addon_state_test.rb:11` use `role: "parameters"` as generic fixture data for
role-agnostic code. They prove the helper and the model take *any* role, which is still true and
still worth proving. The word no longer means anything in the app; in those two files it never did.

**The suite runs on all three legs** — `bin/rails test`, `LIBRARY_BACKEND=share`,
`LIBRARY_BACKEND=s3` — because `LibraryOutput` takes a different door per backend and the create
tests exercise it. Note CI cannot run (no linux runner registered), so all three legs are verified
locally.

## 7. Docs

- `app/models/maker/addon_file.rb` — the `role` comment still says `"output" | "parameters"`.
- `db/migrate/20260720235428_create_maker_addon_files.rb` — its `"output" | "parameters" | ...`
  comment is **left as-is**. A migration records what was true when it ran.
- `CLAUDE.md` §3 (Addons row) and `docs/STATUS.md`, per the working agreement that both move when the
  architecture does.

## 8. Out of scope

- Deleting the params files themselves, now or by a sweep task.
- Editing a saved state's params in place. "Duplicate & tweak" → Save creates a *new* state, and that
  flow is unchanged.
- Any change to `LibraryOutput`, the bundle model, or the `AddonFile` schema. The `role` column keeps
  earning its place the moment a second output format appears.
