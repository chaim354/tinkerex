# Re-saving an addon output overwrites, after a confirmation

**Branch:** `claude/addon-save-overwrite` (stacks on `claude/file-mover-autosort-bug-c83346`, PR #136)
**Second repo:** `chaim354/tinkerex-addons` — three bundles carry the dialog.

## The problem this closes

Reported as "`harbor-number-v4.svg` did not autosort" while v3 and v5 did. Reproduced: **v4 was
saved twice.**

1. Save #1 → written to `Projects/harbor-signs/`, intake files it into `design/`.
2. Save #2 (same name, tweaked drawing) → `refuse_taken_names!` checks **the folder the user
   picked** (the project root), which is now empty of that name because copy #1 moved to `design/`.
   So the door accepts it.
3. Intake tries to move copy #2 into `design/` → `Maker::MoveNode::Collision` → it stays at the
   project root. Permanently, on every later sweep.

The door's collision check and the sorter's collision check **look at different folders**. That is
CLAUDE.md §12 item 11, recorded as an open product question; this plan answers it.

PR #136 already made the door *say* what happened. This makes the re-save do the thing the user
meant.

## The decision

**Overwrite the existing file, after an explicit confirmation.** Not auto-rename (the user is
iterating on one drawing, not accumulating copies), not silent overwrite (destroys work without
asking).

## The invariant this must not break

**`node_id` NEVER CHANGES.** A delete-then-create would orphan every attachment, BOM link and tag
pointing at the old file — §14a's recorded landmine ("a new `node_id` → every attachment orphaned,
by a scan that did nothing wrong, with no error anywhere"). So "overwrite" means **replace the
content of the existing node**, never replace the node.

That is also why the temp-and-rename is not a detour here: `File.rename` over an existing dest is
atomic on POSIX, so the disk half of a replace is already written and already safe against the
15-minute scan.

## Design

### 1. Detect at the door, against the CATEGORY folder

New shared check: for a save whose `parent_node_id` is a project folder's root, the name's real
destination is `Projects/<slug>/#{Maker::ProjectFolders.folder_for(name)}/`. Ask
`Maker::MoveNode.collision?` there, not only at the picked folder.

Lives beside the existing `refuse_taken_names!` and reuses `ProjectFolders.folder_for` — the same
pure function `#place` and `#project_intake_sentence` already agree on. **No fourth copy of the
category vocabulary.**

Scoped to project-folder roots on purpose: a save into an ordinary library folder has no category
destination and keeps today's behaviour exactly.

### 2. Answer a confirmation, don't just refuse

`Tools::AddonsController#create` → **409 Conflict**, JSON, naming each colliding file and the
folder it would replace in. Distinguishable from the existing 422 (`unsupported_operation`) so a
bundle can tell "you must rename" from "confirm and I'll replace".

**Old bundles degrade honestly:** they branch on `res.ok`, so a 409 reads as "Save failed." — no
silent stranding, which is already better than today. New bundles show the dialog.

### 3. Overwrite preserving `node_id`

`Maker::Addons::LibraryOutput.write(..., replace: true)`:

- **chunk** — `Sync::Commit` against the **existing** `node_id` with `base_version_id` = its current
  version. This is what versioning is *for*; no port involvement at all (chunk writes never go
  through the port). The old bytes stay restorable.
- **share / s3** — needs `FileLayer#write(..., replace: true)`:
  - `Share#write` — skip the `File.exist?` refusal; after the rename, **find the live node at that
    `rel` and update** `size`/`mtime`/`content_hash` instead of `create!`-ing a new one.
  - `S3#write` — skip the head-then-put clobber check (`put_object` is atomic, §14a), same node
    reuse.
  - Chunk's port `write` still raises — unchanged, it is not a door.

**§14a is not being relaxed.** Its clobber refusal is the default for an *unasked* write; `replace:`
is a distinct, opt-in verb a user has just confirmed. The refusal stays the default on every
adapter and every existing caller.

### 4. The two doors differ, and only one is finishable in this repo

- **`Tools::OpenscadController#create`** — server-rendered, so a full Rails confirm (re-render with
  an "Overwrite" button) is buildable here end to end.
- **`Tools::AddonsController#create`** — driven by a `fetch()` in a bundle. Server answers the 409;
  the dialog is a change in `tinkerex-addons` (`addons/generators/generators.js:108`,
  `addons/boxes/editor.js:196`, `addons/boxes-next/editor.js:196` — all three share the shape
  `res.ok ? "Saved." : "Save failed."`).

## Order of work

1. Port: `write(..., replace:)` on `Share` + `S3`, node reuse, tests per adapter.
2. `LibraryOutput.write(replace:)` — chunk's versioned path + the port path.
3. The category-folder collision check at both doors.
4. The 409 contract + `overwrite` param on `Tools::AddonsController`.
5. OpenSCAD's server-rendered confirm.
6. Bundle dialogs in all three addons (second repo, second PR).

Each step mutation-checked per §15. Steps 1–5 are one PR here; step 6 is its own PR there, and the
server half ships first so the bundles have something to talk to.

## Deliberately out of scope

- **Auto-rename.** `Maker::MoveNode.available_name` already computes `… (2)` for the existing
  conflict prompt; if a "Save a copy instead" button is wanted later it is a small addition to the
  same dialog, not a different design.
- **A project-wide name scan.** §12.11's broader question ("should a project-scoped upload
  duplicate-check across the whole project") stays open. This closes the case that actually bites —
  the destination the file is about to be filed into — without a library-wide scan on every save.
- **The eager cap's silent `Result`** (`moved=0, skipped=0, skips=[]`), still indistinguishable from
  "nothing to file". Reporting gap, not a stuck file.
