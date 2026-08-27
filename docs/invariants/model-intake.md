# The model catalog and shelves

> CLAUDE.md §14k's area file. Read before touching `app/services/maker/model_intake.rb`,
> `app/services/maker/library_tree.rb`, `app/models/maker/shelf.rb`,
> `app/controllers/shelves_controller.rb`, `app/jobs/maker/model_intake_job.rb`, or the
> `origin` / `auto_node_id` / `dismissed_at` columns on `maker_models`. The arc that produced it —
> measurements, what each guard caught, what was deliberately left out — is in `docs/STATUS.md`.

- **A FOLDER IS EITHER A SHELF OR A MODEL, AND THE NEAREST SHELF ANCESTOR DECIDES.** A model-role
  file directly under a shelf is its own one-file model; anything deeper belongs to the shelf's
  direct child folder, which claims its whole subtree. **Nearest, not furthest** — `chain.index`,
  never `rindex`: marking a folder inside a model a shelf is how a user splits one model into
  several, and the furthest match silently ignores them. Mutation-checked.
- **A SHELF IS A PATH PATTERN AND A MODEL IS A NODE ID. The two identities differ on purpose and
  neither may be "unified".** Only a pattern can express `Projects/*/models` — one rule over a
  folder per project, none of which need exist. Only a node_id survives a rename: `Library::
  Reconciler` pairs by `(content_hash, size)` and keeps a renamed node's `node_id` (§14b), so a
  path key would abandon a renamed folder's row and mint a second, leaving two models for one
  folder. The cost of path-keyed shelves — a renamed folder silently stops matching — is paid by
  the settings page's live/missing indicator, which is therefore not decoration.
- **THE WILDCARD CLAUSE IN `Shelf`'S PATH VALIDATION CANNOT BE DELEGATED, and composing the two
  library-name checks is not enough.** `*` is an ordinary legal filename byte, so
  `valid_leaf_name?("*x")` is TRUE and `reserved?("*x")` is FALSE — neither composed check knows
  this class has a wildcard syntax at all. Without the explicit clause `Projects/*x/models` saves
  happily and then matches nothing, forever, silently.
- **`Shelf.seed_once!` USES `find_or_create_by!`, AND `create!` IS A PERMANENT-FAILURE STATE.** A
  user holding a seed path *without* the stamp raised "Path has already been taken" on every later
  call — permanently, because the stamp that would stop it being retried is written after the rows,
  and this sits on the recurring sweep's first line. Reachable two ways: a process dying between
  the rows and the stamp, and anyone creating `""` themselves before their first sweep.
  `RecordNotUnique` is rescued to a stamp for the concurrent case (the settings page and the sweep
  racing), on the same reading `Models::AttachmentsController#create` records for a double-clicked
  Attach.
- **SEEDING HAPPENS ONCE, GUARDED BY `users.shelves_seeded_at`.** Ensuring the three defaults on
  every sweep would resurrect every row a user deleted — the fight-the-user shape §14f exists to
  prevent. Both first-touch doors, the settings page and the sweep, call the same method so neither
  has to be first.
- **DELETING AN AUTO MODEL DISMISSES IT; DESTROYING IT MAKES THE SWEEP RECREATE IT.** The row is
  the memory. `Maker::ModelIntake` must look up existing rows **without** the `catalogued` scope —
  filtering dismissed rows out of its own lookup is exactly how they come back, and the partial
  unique index on `(user_id, auto_node_id)` turns that into a `RecordNotUnique` rather than a
  duplicate. An IMPORT-origin model still destroys: nothing recreates it. **The button on
  `models/show` branches too** — one "Delete … (files are kept)" confirm describes only the second
  branch, and told a user their model was being deleted at the moment the row was about to survive.
- **AN EMPTIED AUTO MODEL IS HIDDEN, NOT DISMISSED.** Hiding is reversible and dismissal is not, so
  reusing dismissal for "its files went away" means a folder that refills stays gone forever. The
  index drops auto models with no attachments off the **already-loaded** association; the rows age
  out through `Maker::AttachmentReaper` on the ordinary grace window. Do not add a second reaper,
  and do not reach for `where.missing` — it is a second query that can disagree with what the cards
  render.
- **THE SWEEP NEVER CALLS THE PORT AND NEVER CALLS `ensure_library_folder!`.** It writes database
  rows only, which is what makes it identical on all three backends and testable without a library
  on disk. `folder_node_id` is set from the dir key the classifier already resolved; calling the
  ensure would MINT `Models/<slug>` for every model as a side effect of merely looking — the bug
  §14f records for `Projects::AttachmentsController#relocate`, at library-sweep scale.
- **ONE CAP, NOT TWO, AND THE SECOND IS OWED BY WHOEVER ADDS A NUDGE.** `MAX_MODELS` bounds an
  unattended run's churn and is absolute rather than a percentage, because the intended first run
  catalogues 100% of what is there. `Maker::ProjectIntake` carries a second, smaller cap only
  because it has an entry point inside a browser request; nothing here does. **A nonsense override
  falls back rather than crashing:** `Integer("-5")` SUCCEEDS, so the rescue never sees a negative —
  it reaches `todo.first(-5)` and raises "negative array size" from inside the recurring job, far
  from the typo that caused it.
- **IN `Library::ScanJob` THE CATALOG RUNS AFTER THE RECONCILE *AND* AFTER THE PROJECT INTAKE, and
  both orderings change the ANSWER, not the timing.** After the reconcile because the catalog reads
  paths and an unsettled path is a wrong answer (§14f). After the project intake because that step
  MOVES files: a `.stl` loose at `Projects/desk-lamp/` has no shelf nearer than the library root, so
  catalogue first and the whole `Projects` folder becomes its model — where after the move it sits
  under the seeded `Projects/*/models` shelf and is its own. Nothing reaps an auto model, so the
  wrong row is permanent. Pinned by a test that fails on the swapped order.
- **`Maker::LibraryTree`'s ancestor walk MUST keep its cycle guard, and BOTH callers must check the
  `:broken` sentinel.** A parent cycle is unrepresentable on a mount and perfectly representable in
  a row set; an unguarded walk HANGS the sweep rather than failing it. Forgetting the sentinel check
  fails differently in each caller and quietly in one: `:broken` answers `.name` (Ruby 3+), so in
  `path_for` it becomes an ordinary-looking path segment, while in `ancestors_of` it raises
  `NoMethodError`. An unresolvable chain answers `nil`, which callers skip — a library-wide sweep
  must not abort over one broken node.
- **`path_for`'S MEMO RESOLVES THE WHOLE CHAIN AND *THEN* WRITES, NEVER PER HOP — a cache is where
  the `:broken` sentinel comes back.** Writing an entry as the walk climbs caches a PARTIAL PREFIX,
  so a folder whose grandparent is tombstoned reads back on the next lookup as a top-level folder
  that does not exist: a wrong path where the un-memoized walk gave `nil`, and quiet, which is the
  bullet above's failure mode arriving through a new door. On success each visited id is cached with
  its OWN path (the walk's ids run nearest-first and its segments furthest-first); on `:broken`
  every id the walk touched is cached `nil`, which is sound because they all share the broken
  suffix. Mutation-checked by two tests that go red on a per-hop write.
- **`path_for` IS THE ONE ANCESTRY DEFINITION AND HAS THREE CALLERS OUTSIDE THIS SWEEP** —
  `ShelvesController`, `FilesController#folder_paths_for` (the flat view's Folder column) and
  `Tools::LibraryFolders` (the addon save-folder picker). The last two each carried a byte-identical
  whole-dir pluck with its own in-memory walk, and the three disagreed on a parent cycle: `nil` here,
  a literal `"…"` spliced into the rendered path there, and unbounded recursion in the third —
  `SystemStackError`, a 500 on every `/tools/:addon` page for that user. **Do not re-inline a fourth
  walk.** A caller that cannot skip an unresolvable node degrades `nil` ITSELF, in one named place
  (`Tools::LibraryFolders#folder_label`); the primitive stays strict, because a lenient mode on it
  invites each caller to pick a fallback without arguing for it — which is how the three answers
  happened.
- **THE TRIGGER SET IS `Maker::FileAttachment.role_for(name) == "model"`, never a fresh extension
  list** (§14d, one file-type vocabulary). Consequence, stated rather than discovered: `.obj`,
  `.step` and `.stp` are catalogued alongside `.stl` and `.3mf`.
- **`plan.titles.fetch(key)` HAS NO DEFAULT ON PURPOSE.** `classify` writes `titles[key]` on the
  line above the one that adds the key, so a key with no title is unreachable — and the tempting
  `fetch(key, key)` would ship a model **titled `d-enc`** if it ever became reachable, a visible bug
  wearing a successful sweep.
- **THE STEADY-STATE PASS IS CONSTANT IN QUERY COUNT AND LINEAR IN PAYLOAD, and only the first is
  asserted.** A no-op sweep costs 7 queries whatever the library size (measured), but the seventh is
  one `INSERT … ON CONFLICT DO NOTHING` carrying every owned file — re-sent every tick, writing
  nothing. Fine at the sizes measured (6,000 files in one folder completes); worth knowing before
  anyone shortens the 15-minute interval.
- **THE SWEEP DOES NOT ATTACH TO IMPORT-ORIGIN MODELS.** A folder an import already claims is that
  model's — look, do not take. Both halves are pinned: no auto row is created for it, *and* its
  files are left unattached, which is the more damaging half and the one nothing was checking.

## `Maker::Model` and `Maker::Item` are two catalogs, not one catalog twice

- **BOTH SURVIVE, AND `tinkerex#153` IS WHERE THAT WAS DECIDED — do not re-open it as a merge.**
  The two tables overlap on title/description/origin/source_url and both hang `file_attachments`,
  `taggings` and `tags` off a polymorphic pointer, which reads exactly like duplication. It is not.
  **`Maker::Model` is the WEB app's catalog** — a 3D-print model specifically, swept in by
  `Maker::ModelIntake`, shelf-scoped, dismissible, 8 views and full CRUD. **`Maker::Item` is the
  DESKTOP client's catalog** — any maker artefact (`ITEM_TYPES` is
  `model_3d/cad/lightburn/electronics/other`), zero web routes, created only by a POST to
  `/v1/maker/items`. Neither vocabulary fits inside the other: an Item has no `print_status` and a
  Model has no way to say "this is a LightBurn job".
- **THE DELETION IS BLOCKED BY A SHIPPED CONSUMER, WHICH IS THE FACT THE ISSUE ASKED FOR AND THE
  ONE A FUTURE READER WILL NOT HAVE.** `chaim354/tinkerex-client` drives both `/v1/maker/items`
  and `/v1/maker/collections` end to end: `client/maker-app/src/index.html` has a **Library tab**
  in its nav (`data-view="library"`), `src/library.js` invokes twelve `maker_*` Tauri commands,
  `src-tauri/src/lib.rs` registers them, and `sync-client/src/maker.rs` calls the endpoints.
  Removing either table breaks that tab. **Any future removal is a wire deprecation with a client
  release behind it, never a deletion in this repo** — and the check is a grep of that repo, not a
  grep of this one, which is why nothing in `bin/ci` can tell you. Measured 2026-08-26.
- **THE TWO `origin` COLUMNS ANSWER DIFFERENT QUESTIONS AND THEIR CONSTANTS ARE NAMED FOR THE
  QUESTIONS, NOT THE COLUMN.** `Maker::Item::ACQUISITION_ORIGINS` (`self_made`/`downloaded`/
  `modified`) is how the physical thing was obtained; `Maker::Model::ROW_ORIGINS`
  (`import`/`auto`) is which door wrote the database row. Both were spelled `ORIGINS` until
  2026-08-26, one file apart, which cost a standing comment telling readers not to map between
  them. **Do not "tidy" either back to `ORIGINS`**; the collision is what made the comment
  necessary. The COLUMNS stay named `origin` on both — the client sends that key.
- **Known asymmetries, recorded so they read as gaps rather than as bugs.** `Maker::Task`'s
  `TASKABLE_OWNERS` names `Maker::Item` and `Maker::Project` but **not** `Maker::Model`, and
  `maker_collection_items.item_id` points at `maker_items.id`, so a collection cannot hold a
  Model. Both are absences, not breakage; closing either is a feature with a wire change, and
  collections have no web UI at all (§12.9).
