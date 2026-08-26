# Auto-catalogued models: shelves, and the sweep that fills /models

**Date:** 2026-08-25
**Status:** design approved, not implemented
**Branch:** `claude/3mf-stl-models-9266dc`
**Repo:** this one only. Nothing here touches the sync engine or the client (§14j).

---

## 1. What is true today

`.stl` and `.3mf` are *already* models everywhere except the one place the word is a noun:

- **The vocabulary agrees.** `Maker::FileAttachment::ROLE_BY_EXT` maps `stl 3mf obj step stp` to
  role `"model"`, and `Maker::ProjectFolders` files them into `Projects/<slug>/models/`.
- **The file page agrees.** `FilesController`'s `:model3d` branch gives `.stl`/`.3mf`/`.obj` the
  interactive Three.js viewer.
- **The catalog does not.** A `Maker::Model` row exists only if someone walked the **Import model**
  flow (`models#new` → `importer_controller.js`). Every other door — a plain Files upload, a device
  push through the mount, a NAS drop the scanner picks up, `Maker::Addons::LibraryOutput`, a move,
  a trash restore — leaves a file with `role: "model"` and no catalog entry. `/models` shows what
  you imported, not what you have.

This spec closes that: the catalog becomes a view over the library rather than a record of one
import flow.

---

## 2. The rule

**A folder is either a *shelf* or a *model*, and the nearest shelf ancestor decides.**

For a file whose role is `model`, walk up its ancestors to the nearest shelf:

| where the file sits | what the model is |
|---|---|
| direct child of the shelf | **the file itself** — a one-file model |
| deeper | **the shelf's direct child folder** on the path down to it, claiming its whole subtree |

`3D Models/` is a shelf, so `3D Models/benchy.stl` is a one-file model and `3D Models/Enclosure/`
is one model holding every part, PDF and render beneath it — including `Enclosure/parts/*.stl`,
which are parts of that model, not models of their own. Mark `3D Models/Enclosure/` a shelf too and
its children become models instead. `Projects/<slug>/models/` behaves identically, which is why the
rule is stated once rather than twice.

A file with no shelf ancestor is **not catalogued**. That is reachable — delete the root shelf row —
and it is a legitimate choice, not a gap.

---

## 3. Decisions taken, with the argument

Each was settled during design and is recorded so it is not relitigated.

**The trigger set is `role_for(name) == "model"`, not a fresh `%w[stl 3mf]`.** CLAUDE.md §14d
allows exactly one file-type vocabulary and this repo has already paid for the alternative twice
(`FilesHelper::EXT_FAMILIES` was rewritten to end a drifted second copy; `importer_controller.js`
still carries a third, recorded under STATUS's "Still open"). Consequence, stated plainly rather
than discovered: `.obj`, `.step` and `.stp` are catalogued too. That is the same superset every
other surface in the app already treats as a model.

**A shelf is a PATH PATTERN; a model is a NODE ID.** The two identities are deliberately different
because they answer different questions.

- A shelf must be able to say `Projects/*/models` — one rule covering a folder per project, none of
  which exists yet. No node_id expresses that, so shelves are stored as paths with a single-segment
  `*` wildcard, `""` meaning the library root.
- A model's identity must survive a rename. `Library::Reconciler`'s pairing by
  `(content_hash, size)` keeps a renamed node's `node_id` — that is §14b's headline promise — so
  keying on node_id means renaming `3D Models/Enclosure/` to `3D Models/Enclosure v2/` keeps one
  catalog entry, where a path key would abandon the old one and mint a second.

The cost of path-keyed shelves is that a rename silently breaks a *shelf* rule. It is made visible
rather than argued away: see §5.

**Deleting an auto-created model dismisses it; it does not destroy it.** A destroyed row is
recreated by the next sweep, and the user deletes it again — §14f's recorded failure mode ("would
fight the user every 15 minutes"), which on `chunk_remote` also costs a changelog entry per round.
`dismissed_at` is the memory. Import-origin models keep today's behaviour and destroy, because
nothing recreates them.

**The sweep reads `nodes`; it hooks no door.** §14f names seven doors a file can arrive through and
the eighth that silently skips the rule. `nodes` is the catalog all three backends populate, so one
reader covers every door present and future. This is `Maker::ProjectIntake`'s argument, applied to
the same problem one level up.

**Title is the folder or file base name, verbatim.** No humanizing pass. `enclosure_v2` stays
`enclosure_v2` rather than becoming `Enclosure V2`, and `benchy.3mf` titles as `benchy`. The user
named the folder; a transform that produces `Benchy 3Mf` is worse than no transform, and the title
is editable on the model page. Slug generation reuses `Maker::Model#ensure_slug`, which is already
collision-proof (`-2`, `-3`, …) precisely because import could not afford a validation failure.

**Cover needs no new code.** `Maker::Model#cover_node_id` already derives one — explicit override,
else first image, else first model file's rendered thumbnail, else first attachment.

**No eager nudge in v1, and therefore only ONE cap.** The design discussion carried two caps
(`MAX_MODELS` / `EAGER_MAX_MODELS`) by analogy with `MAX_MOVES`/`EAGER_MAX_MOVES`. The second one
disappears because nothing in a web request calls the sweep: `ProjectFolderIntake`'s eager path is
where §14f's measured latency problems live, and cataloguing is not urgent the way filing a file
into the folder you are looking at is. `ModelIntake.for_node` still exists as an entry point (the
rake task uses it), so a nudge can be added later — **and if it is, it needs its own cap**, for the
reason §14f states at both constants. Recorded so the missing constant reads as a decision rather
than an omission.

**The sweep attaches only to models it created.** A file appearing later under
`3D Models/Enclosure/` attaches to that auto model on the next pass. A file appearing under
`Models/<slug>/` — an import-origin model — is left alone: Import owns those rows, and silently
growing someone's curated model is a surprise the sweep has no mandate for.

---

## 4. Data model

Two new columns and one new table. All adapter-agnostic (§14e).

```
maker_shelves
  user_id      integer  not null
  path         string   not null   # "" = library root; segments joined by "/"; one "*" per segment
  created_at / updated_at
  index [user_id, path] unique

maker_models
  + origin       string   not null default "import"   # "import" | "auto"
  + auto_node_id string   null                        # the folder or file this was derived from
  + dismissed_at datetime null
  index [user_id, auto_node_id] unique  (partial where auto_node_id is not null)
```

`origin` defaults to `"import"` so every existing row is correct without a backfill.

**Path validation reuses the existing doors, it does not spell them again.** Each segment goes
through `Maker::MoveNode.valid_leaf_name?` (syntax) and `Library::ReservedNames.reserved?` (the
library's own namespace) — the same pair `LibraryBrowseController#create_folder` and
`Tools::AddonsController#parse_files` ask, for the reason §14b gives: a private, weaker spelling is
how `..` becomes a live node. `*` is the one exception, accepted as a whole segment only.

**Seeding happens once.** A new `users.shelves_seeded_at` stamp guards it. Without that, deleting
every shelf row would resurrect all three on the next sweep — the same fight-the-user shape as
recreating a dismissed model. Existing users are seeded by the migration; new users at creation.
The three seeded rows:

| path | why it ships as a shelf |
|---|---|
| `""` | the library root — without it the entire library is one model |
| `Models` | where Import already writes `Models/<slug>` |
| `Projects/*/models` | your stated case: each file its own model, each subfolder one model |

All three are ordinary deletable rows. `Projects/*/models` renders in the UI as a pattern row that
the folder picker cannot produce but that you can remove.

---

## 5. Settings UI

New `ShelvesController` (session-authed web layer, §14d) at `/settings/shelves`, linked from the
`/models` toolbar.

- One row per shelf: the path, a **live / missing** indicator, and Remove.
- The indicator is what makes path-keying honest. A row whose path resolves to no live folder says
  `no folder at this path` inline instead of quietly cataloguing nothing. A wildcard row reports how
  many folders it currently matches.
- **Add shelf** opens the existing chooser (`filechooser_controller.js` over
  `LibraryBrowseController#children`) rather than a textarea — no new picker, and the path it writes
  is derived from the chosen node's crumbs.
- Removing the last shelf is allowed, with an inline note that nothing will be catalogued.

Both new templates must satisfy `test/stimulus_hygiene_test.rb` (every `data-controller` name
resolves) and `test/integration/web/template_hygiene_test.rb` (no ERB comment quoting a `%>`).

---

## 6. The sweep

`Maker::ModelIntake`, modelled on `Maker::ProjectIntake` and sharing its shape:

- `.for_user(user)` — the whole library, capped
- `.for_node(user:, node:)` — one subtree, uncapped entry point for the rake task
- `.sweep_all!` — the schedule's fan-out, with the backend gate in the class method, matching
  `Library::ScanJob.scan_all!` and `Maker::ProjectIntakeJob.sweep_all!`
- `Result` / `RunResult` `Data` types carrying `created`, `attached`, `skips` (reason-tagged) and
  `status`, so `rake models:catalog` can print what happened and why without a second traversal

**Query cost is constant in N, and asserted as constant, never as a literal** — the counts differ
per `LIBRARY_BACKEND` and a literal pins one leg while failing the other two
(`page_query_budget_test.rb`'s stated rule). One pass:

1. `pluck` every live **dir** node (`node_id, parent_node_id, name`) and build the path index in
   memory. Dirs are a small fraction of a library, and this is what avoids a per-file ancestor walk.
2. Resolve each shelf pattern against that index.
3. One pass over live file nodes whose `role_for(name) == "model"`, assigning each to its model by
   the §2 rule.
4. Create missing models (skipping any node already claimed by a row, dismissed or not), then
   `insert_all` attachments with `unique_by: index_maker_file_attachments_uniqueness`
   (`user_id, attachable_type, attachable_id, node_id`) so a re-sweep is one statement and not one
   query per file. `insert_all` bypasses timestamp autofill, so `created_at`/`updated_at` are set
   explicitly.

`MAX_MODELS = 200` bounds an unattended run's churn — absolute, not a percentage, for the reason
`MAX_MOVES` gives: the intended first run catalogues 100% of what is there, so a percentage would
guard against success. Overridable by env, matching `PROJECT_ORGANIZE_EAGER_MAX_MOVES`'s precedent.

**Scheduling mirrors the project intake exactly, including why the two backends differ:**

- `chunk_remote` — a `Maker::ModelIntakeJob.sweep_all!` entry in `config/recurring.yml`, every 15
  minutes, `limits_concurrency to: 1, key: user_id, on_conflict: :discard`.
- share / s3 — `sweep_all!` **declines** on a `scannable` backend, and `Library::ScanJob` calls the
  intake inline at the end of its own `perform`, strictly after the reconcile. §14f states why that
  ordering is a correctness constraint and not a convenience, and this sweep inherits the same
  exposure: it reads paths the Scanner has just observed.

---

## 7. Edge cases, each with its answer

| case | answer |
|---|---|
| shelf inside a model folder | nearest ancestor wins; the inner shelf's children become models and the outer model stops at it |
| model folder renamed | node_id key — same catalog entry, title left as the user last had it |
| model folder deleted (tombstoned) | the model row survives; `Maker::AttachmentReaper`'s existing grace window handles the attachments, exactly as for an imported model |
| a file moves between shelves | it detaches from the old model and attaches to the new one on the next pass |
| a loose file moves into a folder | the folder model claims it; the one-file model it leaves behind is now empty, and is hidden by the row below |
| an auto model has no live files left | **hidden from `/models`, not dismissed and not destroyed.** The row survives holding whatever title and tags the user gave it, and reappears the moment a model-role file returns to that folder. Dismissal must not be reused here: it is the user's "I do not want this", and it is permanent — an emptied folder that refills would stay gone |
| `Models/<slug>` already imported | claimed by `folder_node_id`; skipped |
| user dismisses, then adds a file | stays dismissed. The dismissal is about the folder, not its contents |
| two shelves match one folder | identical outcome — the set of shelves is a set, not an ordered list |
| a shelf path names a file | ignored, and reported as `missing` in the UI (only dir nodes resolve) |

---

## 8. Testing

Every guard gets mutation-checked (§15) — break the thing it guards, confirm red, restore.

- **Rule resolution, table-driven** over one fixture tree: loose file, folder model, nested subtree,
  shelf-inside-model, wildcard match, root shelf deleted, no shelf at all. This is the unit that has
  to be right; everything else is plumbing.
- **Idempotence** — sweep twice, assert zero new rows and zero new attachments the second time.
  Mutation: drop the claimed-node check → red.
- **Dismissal survives a sweep.** Mutation: remove the `dismissed_at` filter → red. Per §15's
  timestamp warning, assert on the **row** (no second model exists) rather than on a timestamp
  compared at `.to_i`, which cannot fail when both writes land in the same second.
- **Seeding happens once.** Delete all shelves, sweep, assert still empty. Mutation: remove the
  `shelves_seeded_at` guard → red.
- **Cap.** `MAX_MODELS + 5` candidate folders → exactly `MAX_MODELS` created, `status` says it
  capped.
- **Query cost constant in N** — 5 folders and 50 folders take the same number of queries.
- **Path validation** — `..`, a leading `/`, `.trash`, and a NUL byte are all refused at the
  settings door, driving the real request rather than posting a Ruby hash (§14e: the suite being
  green is not evidence a guard works if the precondition is never established; and §14d: assert the
  rendered field name, because a `form_with` missing `scope:` is invisible to a hash-POSTing test).
- **All three backend legs** — `bin/ci test`, `test-s3`, `test-chunk-remote` must report identical
  run counts (§15). Nothing here may branch on the backend.

---

## 9. Out of scope

- **No eager nudge** — §3 records the reasoning and what adding one would owe.
- **No change to the Import flow.** It keeps writing `Models/<slug>` with `origin: "import"`.
- **No thumbnail work.** Previews already generate for these nodes; the catalog reads them.
- **Not narrowing the trigger set to `stl`/`3mf`** — §3.
- **No per-model attachment cap.** The run cap bounds models per pass; attachments go in one
  `insert_all`.

---

## 10. Docs obligations (part of the branch, not a follow-up)

Per §15 and the "Keeping the docs honest" rules:

- **`docs/invariants/model-intake.md`** — the new area file, holding: the nearest-shelf rule, why
  shelves are paths and models are node_ids, why dismissal is not deletion, why seeding is once, and
  the single-cap decision. A **stub under a new `§14k` anchor** in CLAUDE.md names the paths that
  send a reader there. New anchor, no renumbering — code cites §14a–§14j by number.
- **`docs/STATUS.md`** — one entry for this arc, amended in place as the work lands, with measured
  numbers (sweep cost on a real library, models created on the live share deployment). Written in
  this branch, not afterwards.
