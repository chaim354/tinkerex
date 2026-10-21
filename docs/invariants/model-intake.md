# The model catalog and shelves

> CLAUDE.md §14k's area file. Read before touching `app/services/maker/model_intake.rb`,
> `app/services/maker/library_tree.rb`, `app/jobs/maker/model_intake_job.rb`,
> `app/services/maker/model_intake/prune.rb`, `app/services/maker/model_folder.rb`,
> `app/services/maker/model_projects.rb`,
> `app/views/files/_model_strip.html.erb`, `Files::ModelsController` (the 3D models view),
> `ModelsController`'s file-tree helpers and redirects, or the `origin` / `auto_node_id` /
> `folder_node_id` / `dismissed_at` columns on `maker_models`. The arc that produced it —
> measurements, what each guard caught, what was deliberately left out — is in `docs/STATUS.md`.

- **A FOLDER IS EITHER A SHELF OR A MODEL, AND THE NEAREST SHELF ANCESTOR DECIDES.** A model-role
  file directly under a shelf is its own one-file model; anything deeper belongs to the shelf's
  direct child folder, which claims its whole subtree. **Nearest, not furthest** — `chain.index`,
  never `rindex`: the built-in shelves nest (`""` sits above every `*`, and `*`'s `Projects` above
  `Projects/*/models`), so the furthest match makes the root everyone's shelf and each top-level
  folder one model — the collapse `*` exists to prevent. Mutation-checked.
- **A SHELF IS A PATH PATTERN AND A MODEL IS A NODE ID. The two identities differ on purpose and
  neither may be "unified".** The patterns are `Maker::ModelIntake::SHELVES` — `""`, `*`, `Models`,
  `Projects/*/models` — FIXED IN CODE since 2026-10-20; until then they were per-user rows edited
  at `/settings/shelves`, and every live user held exactly these four when that page went.
  `classify` takes them as `patterns:` so a test can build a fixture with no shelf above a file;
  nothing in production passes any. Only a pattern can express `Projects/*/models` — one rule over
  a folder per project, none of which need exist. Only a node_id survives a rename: `Library::
  Reconciler` pairs by `(content_hash, size)` and keeps a renamed node's `node_id` (§14b), so a
  path key would abandon a renamed folder's row and mint a second, leaving two models for one
  folder. **The cost of a path-keyed shelf is now visible only as models disappearing**: the
  settings page's live/missing indicator went with the per-user rows. Renaming a project's
  `models/` folder stops `Projects/*/models` matching it and its files key to the project's own
  folder, which the project claims — so the models there stop growing and a new mesh is never
  catalogued, with nothing saying why. (A top-level `Models/` is safe to rename: `*` still names
  it, which is also why two patterns naming one folder is not an ambiguity — the shelves are a SET.)
- **THE PER-USER SHELF RULES WENT WITH THE PER-USER SHELVES (2026-10-20)** — the wildcard clause in
  `Shelf`'s path validation, `seed_once!`'s `find_or_create_by!`, and seeding once behind
  `users.shelves_seeded_at` guarded code that no longer exists; their story is in git history.
- **DELETING AN AUTO MODEL DISMISSES IT; DESTROYING IT MAKES THE SWEEP RECREATE IT.** The row is
  the memory. `Maker::ModelIntake` must look up existing rows **without** the `catalogued` scope —
  filtering dismissed rows out of its own lookup is exactly how they come back, and the partial
  unique index on `(user_id, auto_node_id)` turns that into a `RecordNotUnique` rather than a
  duplicate. An IMPORT-origin model still destroys: nothing recreates it. **The button branches
  too, on `models/show` AND on the Library's model strip (`files/_model_strip`), with the same two
  branches and the same wording on both** — "Remove from catalog" (the files stay and the next
  scan will not re-add it) for an auto model, "Delete" with "(files are kept)" for an import. One
  "Delete … (files are kept)" confirm describes only the second branch, and told a user their model
  was being deleted at the moment the row was about to survive. The strip carries what the page
  did, so the button exists twice; a change to either copy is a change to both
  (`model_strip_test.rb` pins the strip's auto branch).
- **AN EMPTIED AUTO MODEL IS HIDDEN, NOT DISMISSED.** Hiding is reversible and dismissal is not, so
  reusing dismissal for "its files went away" means a folder that refills stays gone forever. The
  3D models view (`Files::ModelsController#index`, the old index) and `Maker::ModelFolder.model_in`
  both drop auto models with no attachments off the **already-loaded** association; the rows age
  out through `Maker::AttachmentReaper` on the ordinary grace window. Do not add a second reaper,
  and do not reach for `where.missing` — it is a second query that can disagree with what the cards
  render.
- **A MODEL CLAIMS ITS FOLDER, NOT EVERY FILE UNDER IT — THREE FILTERS, AND ALL THREE ARE
  LOAD-BEARING (2026-09-02).** Until then a folder model attached its ENTIRE subtree with every
  role, which is the rule this file used to state as a feature ("still letting the PDF inside a
  model folder attach to it"). Measured on the real share library the day it changed: **6 folder
  models held 2,441 attachments, 32 of them meshes** — `Projects/TheFlightWall_OSS`, a firmware
  repo, was one "3D model" with 2,305 files including 1,273 sources under `.pio/build/**`, and
  `warso main/plans 1` gave three `.obj` files a model that also held the three `.dxf` drawings
  beside them, which is the report that opened it. The filters, in `classify`:
  **(1)** a key nothing model-role claims is not a model — unchanged, and how `notes.pdf` loose on
  a shelf becomes nothing; **(2)** a file joins only from a folder that is *part of the model* —
  the model's own folder, **or** one that itself holds one of the model's meshes; **(3)**
  `EXCLUDED_ROLES`.
- **`parent == key` IS NOT IMPLIED BY THE `model_dirs` ARM AND DELETING IT SILENTLY EATS THE
  ORDINARY DOWNLOAD LAYOUT.** `Kit/notes.pdf` beside `Kit/stl/part.stl` has no mesh in the model's
  own folder at all, so without that clause the PDF is dropped. In the other direction a one-file
  model's key is the FILE, so `parent == key` is never true there and the `model_dirs` arm is the
  one that covers it. Both arms are mutation-checked; each alone goes red.
- **`EXCLUDED_ROLES` IS A DENYLIST, AND THE DIRECTION IS THE SAFE ONE.** A role added to
  `Maker::FileAttachment::ROLE_LABELS` later joins models by default; an allowlist would drop it
  with nothing going red. The line it draws is *is this the model, or its own artefact* —
  `vector` (dxf/svg, ai), `laser` (lbrn2, lbrn) and `cnc_design` (mage) are 2D cut jobs that merely
  share a folder, `code` is a firmware tree, `gcode` is sliced OUTPUT, `document` is READMEs and
  name lists. **`other` and
  `image` STAY, and narrowing this to `model` alone is the tempting wrong fix**: an `.obj` loads
  its material from the `.mtl` (role `other`) and its texture from the image beside it, so a
  model-role-only filter ships a mesh that renders untextured. Membership is pinned against
  `ROLES` — a typo excludes nothing and every other test still passes for the wrong reason.
- **A FOLDER A PROJECT CLAIMS IS THE PROJECT'S, NOT THE CATALOG'S**, on exactly the terms an
  IMPORT-origin model's folder already was — look, do not take. `*` makes `Projects` a shelf, so
  without this a folder directly under it became one model holding its whole tree. It asks **who
  claims the folder**, never "does this path start with `Projects/`", and `claimed_folders` has
  **THREE CLAIMANTS since F-S07-1 (2026-10-19)**: an import, a project row, and **discovery BY
  POSITION** — `Maker::ProjectDiscovery.positional_claims`, every folder discovery owns whether or
  not it has adopted it yet, public and UNCAPPED, with discovery's own `adoptable` defined through
  it. The third replaced an ordering invariant that never held: this rule used to lean on
  `Library::ScanJob` running discovery first, but discovery is capped (`MAX_PROJECTS`) even inside
  that sequence and is an independent schedule on `chunk_remote`, so a folder it had not reached
  became one auto model and then a project too — both, until `rake models:prune`. A positional
  claim always becomes a real one (archiving keeps the claim; a v1 hard delete is re-adopted), so
  "not yet" reads as "claimed". **It is discovery's reader, never a path test here**: a dot-folder
  under `Projects/` is nobody's and is still catalogued — pinned, and a path test goes red. **Both
  row queries are unscoped on status** — an ARCHIVED project keeps `folder_node_id` and still claims
  its folder, the same reading `adoptable`'s own `claimed` set and the `catalogued` scope run on. A
  user who DELETES a project releases a folder nothing else claims (one adopted outside
  `Projects/`), which is the row-is-the-memory rule again; a folder directly under `Projects/`
  stays discovery's, which adopts it again. `Maker::ModelIntake::Prune` asks this same method, so
  it also destroys an auto row over a folder discovery has not adopted yet — one it would destroy
  after the adoption anyway. **The claim is applied BEFORE `existing` is looked up**, so a row the
  old rule already wrote stops accreting too rather than only new folders being spared.
  **THERE ARE TWO WAYS A PROJECT COMES TO CLAIM A FOLDER SINCE STAGE 4, S4-6 — the sweep and
  `Projects::AdoptionsController`, which adopts one folder ANYWHERE — AND THE RULE ABOVE IS
  UNCHANGED BY THAT**, precisely because it asks WHO CLAIMS and never where the folder sits. What
  the door adds is the repair the sweep cannot do: in the SAME TRANSACTION as the `maker_projects`
  row it **destroys** the `origin: "auto"` model whose `auto_node_id` is that folder — the same
  call `Maker::ModelIntake::Prune` makes for an auto model over a project-claimed folder, so one
  state has one answer. `for_user` drops a claimed key before `existing` is looked up, so accretion
  stops the instant that row exists — but the ROW SURVIVES (that method's own comment says
  clearing it is `Prune`'s job), so without this `designs/tray` is a project AND a model at once,
  with the model's card offering Delete for a thing that is now a build. **DESTROYED, NOT
  DISMISSED, AND THAT REVERSED A FIRST VERSION** (S4-6's review measured it): a dismissal is the
  maker's own "not a model" and is irreversible by design, so a dismissed row kept the folder OUT
  of the catalog after the project was deleted — against the rule above that deleting the project
  releases the folder — while `Prune` destroyed the same row on its next pass. Destroying it lets
  the next sweep recreate the model the moment the project goes; pinned by a test that destroys
  the adopted project and sweeps. **Keyed on `auto_node_id`** — the sweep's own identity for the
  row — and the test's fixture gives the model a DIFFERENT `folder_node_id`, so a lookup keyed on
  the wrong column goes red (the first fixture set both to the same node and could not tell them
  apart). The `origin: "auto"` clause beside it is belt-and-braces, since `Maker::ModelIntake` is
  the only writer of `auto_node_id` and always writes `origin: "auto"` with it. **AUTO ONLY**:
  nothing recreates an IMPORT-origin model, so there is nothing for the sweep to be told, and that
  folder's row is left alone on the same look-do-not-take terms.
- **`models/show`'S FILES PANEL SHOWS THE MODEL'S FILES WITH THE FOLDER'S SHAPE — IT IS NOT A
  FOLDER BROWSER.** `build_file_tree` walks `folder_node_id`'s subtree for the NESTING an imported
  zip had, then keeps only what `@attachments` claims. The two were the same set while a folder
  model claimed everything under it, which is exactly why the panel was written unfiltered and why
  tightening the attach rule left it listing the `.dxf` files the catalog had just let go, under a
  heading counting them — the fix would have been invisible on the page that reports the bug.
  Measured before changing it: on all three IMPORT models in the live library the two sets are
  identical (68/68, 42/42, 1/1), so filtering only ever moves an auto model. **A directory with
  nothing surviving beneath it is dropped with its files**, or a `docs/` holding one unclaimed
  `names.txt` opens onto nothing; the recursion collapses an empty branch from the leaves up. It
  reads `@attachments`, ALREADY partitioned against the live-node index, so it adds no query (the
  page budget is asserted constant in N) and inherits `PageNodes`' tombstone rule instead of
  re-deriving it. **The count in the heading is derived from the same tree** — a panel that
  filtered while `@file_count` did not is the same contradiction one line higher up. **It binds
  only on the page that survives slice 5**: a model whose folder shows its strip never renders
  `models/show` (the next rule), and the strip does not repeat this panel, because the folder's own
  listing is the folder browser there. The panel renders for the models that keep the page.
- **THE MODEL STRIP AND THE REDIRECTS REPLACE THE MODEL PAGE FOR A MODEL WITH A FOLDER TO LAND ON,
  AND FOR NO OTHER (structural redesign slice 5).** `files/_model_strip` sits above that folder's
  files carrying what `models/show` did — cover, status, details, print settings, notes, Edit, the
  destroy button above and the print log — and `/models/:id` 302s there. There is no "manual"
  origin to carve one exception out by, so **the page survives for every model with no strip to
  land on**: a one-file model (about half of what the sweep creates), an import whose
  `Models/<slug>` was never made or is in the trash, and a model whose folder a project claims.
  Redirecting those would land the maker on a folder that shows nothing of what they clicked. The
  strip does NOT repeat the page's 3D viewer, gallery, instructions PDFs or file tree (the listing,
  the inspector and the workspace show those files), and it is not a selection item
  (`files-preview.md`, "The inspector"). `/models` 301s to the Library's 3D models view,
  `/files/models`, keeping `q`/`status`/`tag`/`sort`; import stays at `/models/new`, and its
  `model_url` lands on the new folder through the same redirect.
- **`Maker::ModelFolder` IS THE ONE ANSWER TO "WHICH MODEL DOES THIS FOLDER SHOW?" AND "WHERE DOES
  `/models/:id` GO?", AND IT KEYS ON `folder_node_id`, NEVER `auto_node_id`.** `model_in` feeds
  `FilesController#index`'s strip and `landing_folder_id` feeds `ModelsController#show`'s redirect,
  and the second is DEFINED through the first (`model_in(user, id)&.id == model.id`), so the two
  cannot disagree about whether a model has a strip to land on. `folder_node_id` is the column every
  folder model sets: an IMPORT's `Models/<slug>` sets only it, an auto FOLDER model sets both to the
  folder, and a one-file auto model's `auto_node_id` is a FILE on a shelf. Keyed on `auto_node_id`,
  every import loses its strip (a mutation `model_folder_test.rb` catches). `model_in` reads
  `catalogued`, hides an emptied auto model off the eager-loaded association (the rule above that
  hides rather than dismisses it), and lets the OLDEST VISIBLE row win — several rows can name one
  folder until `rake models:prune` runs, and a stale emptied auto row must not hide a live import
  beside it. It does not check a project's claim, because `FilesController` asks only when
  `@folder_project` is nil; `landing_folder_id` checks the claim itself, along with a live dir node.
  **`/models/:id` is a 302, never a 301**: the answer changes when the folder is trashed, restored
  or claimed, and a browser caches a 301 indefinitely. **Neither function calls the port or
  `ensure_library_folder!`** — rendering a folder or following a link must not mint one, the
  sweep's own rule below. Pinned by `test/services/maker/model_folder_test.rb` and
  `test/integration/web/models_redirects_test.rb`.
- **THE 3D MODELS VIEW IS GROUPED BY PROJECT (`Maker::ModelProjects`, 2026-10-20), AND A MODEL'S
  PROJECT IS THE NEAREST PROJECT-CLAIMED FOLDER AT-OR-ABOVE ITS KEY — WALKED FROM THE KEY'S PARENT
  WHEN THE KEY IS A FILE.** A one-file auto model's `auto_node_id` is the file (the bullet above),
  and `Maker::LibraryTree` indexes dirs only, so walking from the key itself finds no chain and
  files every one-file model under "Not in a project" — the first live probe made exactly that
  mistake and reported 0 of 42 models in a project where 9 were. Groups come AFTER the filters and
  the sort (a filtered-out group never renders, the sort holds inside each), projects by name, loose
  last, and a page with no model in any project is the plain grid with no headings. Archived
  projects keep their group, on the claim rule above. Constant in queries, pinned with models nested
  in project folders by `page_query_budget_test.rb`; `model_projects_test.rb` and
  `models_by_project_test.rb` carry the rest, each mutation-checked.
- **THE CATALOG'S SHELVES ARE NOT A SETTING ANY MORE, AND NOTHING ON THE 3D MODELS VIEW POINTS AT
  ONE (2026-10-20).** They were a Settings rule at `/settings/shelves` from slice 5 (and at
  `/models/shelves` from 2026-09-10 until then) until they became `Maker::ModelIntake::SHELVES`.
  That path now belongs to the project-folder Shelves page (`Settings::ShelvesController`, the
  filing folders; CLAUDE.md §14f's area, not this file's), so a "which folders count as models"
  link there would land a maker on a page about something else — `models_redirects_test.rb` pins
  its absence. **ONLY ONE REDIRECT MAY EXIST BETWEEN THE TWO OLD PATHS**: `/models/shelves` still
  301s to `/settings/shelves`, declared above `resources :models` or it matches
  `models#show id=shelves`, and a `settings/shelves → /models/shelves` line is a redirect loop
  (`moved_reference_pages_test.rb` follows every old path to a page that renders).
- **`Maker::ModelIntake::Prune` IS THE REPAIR HALF, AND IT IS NOT IN THE SWEEP ON PURPOSE.**
  `attach_all` only ever ADDS the pairs it is missing, so tightening the rule fixes what is written
  NEXT and leaves every row the loose rule wrote in place — a rule change here is not self-applying.
  A sweep that deleted what its plan no longer claims would also delete what a user attached BY
  HAND through `Models::AttachmentsController#create`, unattended, every fifteen minutes:
  `maker_file_attachments` has **no column saying which door wrote a row**. So the repair is
  `rake models:prune`, **dry by default** (`APPLY=1` writes). Four guards, each mutation-checked
  independently: it touches **folder models only** (a one-file model's key is its file, so the
  sweep never gave it a second row — and `folder_node_id` nil would make `inside?` compare against
  the library root, which every node's ancestry reaches, making every hand-attached row prunable at
  once); it leaves **a tombstoned node** to `Maker::AttachmentReaper`'s grace window, since
  `classify` reads `.present` and a tombstone otherwise looks exactly like a file the rule no
  longer claims; it leaves **a node outside the model's own folder that the current rule places in
  NO model** alone, because it may be a hand attach and nothing in the row says otherwise — NOT
  because the sweep cannot have written it (see "Not covered" below); and an **unresolvable
  ancestry answers "not inside"**, keeping the row. Its liveness query is deliberately NOT
  `.present` — with `.present` a tombstone has no parent, so `inside?` protects it by accident and
  the liveness clause can be deleted green. **"Places in no model" is F-S07-2's fix (2026-10-19),
  and a MOVE is why**: the guard asked only "outside?", but a move keeps the node_id (§14b), so a
  mesh moved from `Widget/` into `Lamp/` kept its `Widget` row forever beside the `Lamp` row the
  next sweep wrote — one file, two models. A node the rule places under ANOTHER key (another model,
  or a folder a project or an import claims) belongs there wherever it sits. No column tells that
  moved file from a hand attach of another model's file, so such an attach is detached too, and
  the dry run cannot tell them apart either: it prints a per-model COUNT (`detach 2 files from
  "Widget"`), never which files. What bounds that risk is that the attach door's only caller today
  is the importer, posting to the import it has just created. Pinned both ways in
  `model_intake_prune_test.rb`: the moved mesh is RED under the old guard, and a PDF no model owns
  is RED with the guard deleted (that fixture must not be another model's file — that is the
  moved-into-a-model shape). **Not covered:** a file the sweep attached that then MOVED where the
  rule places it in NO model (`Widget/guide.pdf` to `Manuals/`) keeps its stale `Widget` row — on
  purpose, by this guard, because that row is indistinguishable from a hand attach and keeping is
  the safe answer; and a ONE-FILE model whose file moved keeps its row, because the first guard
  skips one-file models entirely. Those states, and retiring Prune into a reconciling sweep, are
  F-S07-2's full design, which REVERSES this bullet and is the owner's to reopen
  (`docs/AUDIT-2026-10-19-simplification.md` §4, measure-first).
- **THE SWEEP NEVER CALLS THE PORT AND NEVER CALLS `ensure_library_folder!`.** It writes database
  rows only, which is what makes it identical on all three backends and testable without a library
  on disk. `folder_node_id` is set from the dir key the classifier already resolved; calling the
  ensure would MINT `Models/<slug>` for every model as a side effect of merely looking — the bug
  §14f records for `Projects::AttachmentsController#relocate`, at library-sweep scale.
- **ONE CAP, NOT TWO, AND THE SECOND IS OWED BY WHOEVER ADDS A NUDGE.** `MAX_MODELS` bounds an
  unattended run's churn and is absolute rather than a percentage, because the intended first run
  catalogues 100% of what is there. `Maker::ProjectIntake` carries a second, smaller cap only
  because it has an entry point inside a browser request; nothing here does. **The top bar's unpack
  nudge (`Files::UnpacksController#finish`, 2026-10-21) owes no second cap:** it only ENQUEUES
  `Maker::ModelIntakeJob` and never sweeps in the request, so the run is the ordinary job — bounded
  by `MAX_MODELS`, and a nudge while another run holds the job's `limits_concurrency` slot is
  discarded. It CAN overlap a share/s3 scan: `Library::ScanJob` runs its catalog step as
  `ModelIntakeJob.perform_now`, which that limit (applied at enqueue) never sees, so two runs for
  one user can race to create the same auto model. The unique indexes (`(user_id, auto_node_id)`,
  `(user_id, slug)`) make the loser raise `RecordNotUnique` rather than write a duplicate — the
  scan's rescue logs it, the nudged job fails with no retry — and the next scan or nudge catalogues
  what the loser left. **A nonsense override
  falls back rather than crashing:** `Integer("-5")` SUCCEEDS, so the rescue never sees a negative —
  it reaches `todo.first(-5)` and raises "negative array size" from inside the recurring job, far
  from the typo that caused it.
- **IN `Library::ScanJob` THE CATALOG RUNS AFTER THE RECONCILE *AND* AFTER THE PROJECT INTAKE. The
  first ordering changes the ANSWER everywhere; the second still can, but not under `Projects/`.**
  After the reconcile because the catalog reads paths and an unsettled path is a wrong answer
  (§14f). After the project intake because that step MOVES files, and a move can re-key a file —
  measured (2026-10-19) on a project adopted at a TOP-LEVEL folder with filing on, whose root is
  itself a `*` shelf: catalogue first and a loose `lid.stl` becomes its own one-file model, which
  then makes the intake refuse to move it (`:model_bundle`), for good. Under `Projects/` the swap
  costs a scan and nothing more: a file loose at a project's root keys to the project's folder,
  which is claimed (the bullet above), so it is catalogued once the intake has moved it under
  `Projects/*/models`. This bullet used to say the `Projects/` case made one permanent model; that
  stopped being true in two steps (the `*` seed, then the claim rule) while the sentence stayed.
  `IntakeOrderTest` is RED on the swap with `[]`; the top-level case has no test yet. Discovery's
  own place before the catalog is timing only since F-S07-1 (`project-intake.md` says why).
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
- **`path_for` IS THE ONE ANCESTRY DEFINITION, AND THE WEB LAYER ASKS IT TOO** — among its callers
  outside this sweep are `FilesController#folder_paths_for` (the flat view's Folder column) and
  `Tools::LibraryFolders` (the addon save-folder picker). Those two each carried a
  byte-identical whole-dir pluck with its own in-memory walk, and the three disagreed on a parent
  cycle: `nil` here, a literal `"…"` spliced into the rendered path there, and unbounded recursion
  in the third — `SystemStackError`, a 500 on every `/tools/:addon` page for that user. **Do not
  re-inline a fourth walk.** A caller that cannot skip an unresolvable node degrades `nil` ITSELF,
  in one named place (`Tools::LibraryFolders#folder_label`); the primitive stays strict, because a
  lenient mode on it invites each caller to pick a fallback without arguing for it — which is how
  the three answers happened.
- **THE TRIGGER SET IS `Maker::FileAttachment.role_for(name) == "model"`, never a fresh extension
  list** (§14d, one file-type vocabulary). Consequence, stated rather than discovered: `.obj`,
  `.step` and `.stp` are catalogued alongside `.stl` and `.3mf`.
- **`plan.titles.fetch(key)` HAS NO DEFAULT ON PURPOSE.** `classify` writes `titles[key]` on the
  line above the one that adds the key, so a key with no title is unreachable — and the tempting
  `fetch(key, key)` would ship a model **titled `d-enc`** if it ever became reachable, a visible bug
  wearing a successful sweep.
- **THE STEADY-STATE PASS WRITES NOTHING AND IS CONSTANT IN QUERY COUNT — both asserted — AND
  LINEAR IN PAYLOAD, which is not.** `attach_all` plucks the (model, node) pairs that exist and
  inserts only the missing ones, `Maker::ProjectIntake#attach`'s pluck-and-reject (F-S07-2,
  2026-10-19). It used to re-send one `INSERT … ON CONFLICT DO NOTHING` carrying every owned file,
  every tick: a write statement, so on SQLite it took the single write lock in order to write
  nothing. Measured on `model_intake_test.rb`'s library, a no-op sweep is 9 statements, all reads
  (one more once a `Projects/` root exists); the pluck is the statement the INSERT was, so the
  count did not move. `writes_during` there is the guard, with the FIRST sweep as its positive
  control — a helper blind to writes goes red there instead of passing — and any unconditional
  write turns it red. The pluck still reads every owned pair: fine at the sizes measured (6,000
  files in one folder completes), worth knowing before anyone shortens the 15-minute interval.
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
