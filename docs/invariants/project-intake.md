# Project-folder intake

> CLAUDE.md §14f's area file. Read before touching `app/services/maker/project_intake.rb`,
> `app/services/maker/project_discovery.rb`, `app/services/maker/attach_to_project.rb`,
> `app/services/maker/project_folders.rb`, `app/jobs/maker/project_intake_job.rb`,
> `app/jobs/maker/project_discovery_job.rb`, or `Library::ScanJob`'s post-reconcile sequence. The
> arc that produced it — measurements, what each guard caught, what was deliberately left out — is
> in `docs/STATUS.md`.

## Discovery — a folder under `Projects/` becomes a project

- **STATELESS — POSITION IS THE MARKER, EXACTLY THE PRINCIPLE THE FILING SWEEP BELOW ALREADY
  APPLIES ONE DIRECTORY LEVEL DOWN.** Any live directory directly under `Projects/` that no
  project claims becomes a project. No watermark, no `adopted` column, no first-run exemption —
  `Maker::ProjectDiscovery.adoptable` reads `nodes` fresh on every run, and the only record of
  "already handled" is a `maker_projects` row whose `folder_node_id` names that folder. A "seen"
  column would be a second source of truth for the same fact, and the two would drift the day
  anything writes to only one of them.

- **THE CLAIM LOOKUP IS UNSCOPED, AND THAT IS THE ENTIRE DISMISSAL MECHANISM.** `adoptable` reads
  `user.maker_projects.where.not(folder_node_id: nil)` with no `archived_at` filter, so an archived
  project keeps its `folder_node_id` and the sweep passes over its folder forever. Filtering
  archived rows out of the sweep's own lookup is exactly how a dismissed thing comes back —
  `docs/invariants/model-intake.md` records the identical mistake for the `catalogued` scope on
  `Maker::Model`. **The row is the memory.** Stated plainly, because it is easy to miss the other
  way: `V1::Maker::ProjectsController#destroy` calls `destroy!` — a hard delete — so a device
  deleting a project whose folder still exists on disk gets that project BACK on the next sweep;
  the folder was never the thing that got deleted. The web UI is unaffected —
  `ProjectsController#destroy` calls `archive!`, which only touches `status`/`archived_at`, so the
  row and its claim on the folder survive either way.

- **IT NEVER MINTS `Projects/` AND NEVER CALLS `ensure_library_folder!`.** `projects_root` looks
  the folder up with `find_by`, never find-or-create, so a user with no `Projects/` folder at all
  is simply not swept (`status: :no_projects_folder`). Calling the ensure would CREATE `Projects/`
  for every library that has never had one, as a side effect of merely looking — the same bug
  `Projects::AttachmentsController#relocate` once shipped ("the endpoint created `Projects/<slug>`
  as a side effect of being POSTed to"), now at library-sweep scale, on every user, every run.

- **DIRECT CHILDREN ONLY, AND DOT-FOLDERS ARE SKIPPED.** `adoptable` scopes to
  `parent_node_id: root.node_id` and rejects any name starting with `.`. Without the depth limit,
  `Projects/desk-lamp/models/` — a category folder this app created for an already-adopted project
  — would itself be adopted as a project named "models". Without the dot-folder rule: `.git` KEEPS
  ITS NODE on purpose (§14b — the marker is the evidence a directory is a working tree), so a repo
  checked out at the `Projects/` root would become a project literally titled `.git`.

- **DISCOVERY RUNS STRICTLY BEFORE THE FILING SWEEP, AND THE ORDER CHANGES THE ANSWER, NOT THE
  TIMING.** A newly-discovered project's loose files sitting at its folder's root have no shelf
  nearer than `Projects` itself (the seeded `*` shelf), so if the model catalog looked first, the
  WHOLE FOLDER becomes one model — and nothing reaps an auto model, so the wrong row is permanent.
  **Verified by mutation** in `test/jobs/library/scan_job_test.rb`'s `DiscoveryOrderTest`: swapping
  the order leaves a `Maker::Model` titled after the project folder with `auto_node_id` and
  `folder_node_id` both equal to the folder's own `node_id` — a real folder swallowed whole, not
  merely a file left unfiled. `Library::ScanJob#perform` sequences `discover_projects` →
  `intake_project_folders` → `intake_models` inline, all via `perform_now`, inside one call. There
  is no scan to sequence inside on `chunk_remote`, so `Maker::ProjectDiscoveryJob#chain_intake`
  enqueues the intake itself once a run has created something — **gated off scannable backends**,
  because a second, unsequenced filer there is the identical scan-overlap hazard the Filing section
  below already records (a move racing the Scanner's own observations).

- **THE SWEEP NEVER CALLS THE PORT.** `ProjectDiscovery.for_user` writes `maker_projects` rows and
  nothing else — no mkdir, no move, no bytes — which is what makes it identical on all three
  backends and testable without a library on disk.

- **ONE CAP, NOT TWO — AND WHOEVER ADDS A NUDGE OWES THE SECOND.** `MAX_PROJECTS` (50) bounds an
  unattended run's churn and is absolute, not a percentage: the intended first run adopts 100% of
  what is sitting under `Projects/`, so a percentage would be guarding against success. Nothing
  here has an entry point inside a browser request the way `Maker::ProjectIntake`'s eager nudge
  does, so there is no second, smaller cap to keep in step — yet. A nonsense override falls back
  rather than crashing the job: `Integer("-5")` SUCCEEDS, so an unguarded rescue never sees a
  negative — it reaches `candidates.first(-5)` and raises "negative array size" from inside a
  recurring job, far from the typo that caused it.

- **THE SLUG IS `Maker::Project.available_slug`, NOT `#ensure_slug`.** A sweep cannot surface a
  validation error to anyone, and `#ensure_slug` can raise two different ways here: two discovered
  folders slugifying to the same value (`Desk Lamp` beside a hand-made `desk-lamp`), and any
  PURELY NON-LATIN name, which `slugify`'s `gsub(/[^a-z0-9]+/, "-")` reduces to `""` —
  `プロジェクト`, `Проект`, `模型` all blank out and then fail `validates :slug, presence: true`.
  `available_slug` gives discovery the same can't-fail treatment `Maker::Model#ensure_slug` already
  gives catalogued models: fall back to `"project"`, then append `-2`, `-3`, … until one is free.
  `#ensure_slug` itself stays untouched on purpose — a human typing a duplicate name into the web
  form SHOULD be told; only the sweep gets the import treatment.

- **`Maker::ProjectIntake#place` RESOLVES ITS DESTINATION UNDER THE PROJECT'S FOLDER NODE, NEVER A
  PATH REBUILT FROM THE SLUG.** A discovered project's folder is named whatever the user actually
  named it (`Projects/Desk Lamp`, slug `desk-lamp`) — folder name and slug agree only while
  `ensure_library_folder!` is the sole writer of `folder_node_id`, and discovery makes "the name is
  not the slug" the mainline case, not an edge case. Rebuilding `Projects/<slug>/…` from the slug
  would mint a SECOND, phantom tree and move the user's files into it, leaving the folder the user
  actually made empty of exactly the files that should have landed there. Resolving under
  `folder_node_id` instead is also what keeps `#place` agreeing with `.destination_for`'s
  prediction of the same category folder — the two cannot be allowed to disagree about where a
  file is going. The same hazard is reachable without discovery at all: the v1 API permits `:slug`
  directly (`V1::Maker::ProjectsController`), so a device can rename a project's slug after its
  folder was already minted under the old one.

- **`limits_concurrency` ON `ProjectDiscoveryJob` COVERS THE `sweep_all!` PATH ONLY —
  chunk_remote.** Solid Queue acquires the semaphore in an `after_create` on the job ROW, so it
  engages at ENQUEUE. `Library::ScanJob` calls this job with `perform_now`, which creates no row,
  so on share/s3 that limit protects nothing at all; what protects that path is
  `Library::ScanJob`'s OWN `limits_concurrency`, keyed the same way. Do not delete either as
  redundant with the other — they cover disjoint paths, and removing either reopens the
  duplicate-adoption race it alone prevents on the backends the other cannot reach.

## Filing

- **`:in_working_tree` IS UNSCOPED, UNLIKE `:attached_elsewhere` — DO NOT ADD A KWARG TO IT.** A
  refusal from `#refusal_for` does not mean "refuse the attachment": `#call` returns
  `relocation: (move(node) if refusal.nil?)`, so it means **attach the row, leave the bytes**,
  which is the right answer at all four callers. `:attached_elsewhere` needed `within_own_folder:`
  because its stated reason is positional and stopped applying to one caller; "do not move a file
  out from under git" has no such exception. **The detection itself is NOT here** — the ancestor
  walk lives in `Library::WorkingTree`, which the git editing surface asks for the repository ROOT
  node while this asks only whether one exists; keeping a boolean copy here would be one question
  with two implementations, the drift §14d names a service to end. `#refusal_for` memoizes that
  service per instance, because ITS memo is per PARENT, not per node — a sweep files N nodes under
  one parent and the ancestor walk is two queries per level (measured: 45 queries against 15 for
  ten files at depth four), so a fresh instance per call would throw the memo away once per file.

- **ROOT = INBOX IS THE WHOLE SORT RULE, AND IT IS STATELESS.** Only files at a project
  folder's own root are ever filed; anything already in a subfolder — including one filed
  "wrong" by hand — is never revisited, and no column records that a file was "handled."
  Position is the marker. Re-filing a subfolder would fight the user every 15 minutes, and
  on chunk each round of that fight is a changelog entry broadcast to every device.
- **A SWEEP OVER `nodes`, NOT A HOOK PER DOOR — because there are SEVEN doors and no
  funnel.** `FilesController#create` (share/s3), `#finalize_upload` (chunk),
  `Library::Reconciler` (the scan), a device push landing on the sync server,
  `Maker::Addons::LibraryOutput`, `Maker::MoveNode`, and a trash restore can all land a
  file under `Projects/<slug>/`. Hooking each is seven sites that must agree, and an
  EIGHTH would silently skip the rule — this repo's recorded failure shape (the five
  `port_writable?` copies, the Scanner's skip-list blind spot). Reading `nodes` — the
  catalog all three backends populate — covers every door, present and future, without
  touching any of them.
- **THE CHANGELOG PULL'S NUDGE TAKES LIVE FILE ARRIVALS ONLY, ASKS `maker_projects` ONCE PER PULL,
  AND IS DELIBERATELY NOT FED BY `full_resync`** (§12.10). `ChunkRemote::ChangelogSync#call` is
  where this app learns about a node another device pushed, so it nudges once per pull. A
  **directory** has nothing to file and a **tombstone** is a removal — neither is an arrival. The
  project lookup is **once for the whole pull, never per entry**: per-node, a page loop pays a query
  each to enqueue a job `limits_concurrency` discards anyway. And `full_resync` re-applies the
  **entire tree**, so every file there would look like an arrival. Mutation-checked in
  `changelog_sync_test.rb`.
- **ADDS NO NEW COPY OF THE `port_writable?` BRANCH — the count named in §14d stays
  five.** Moves run through `Maker::MoveNode`, mkdirs through `Maker::LibraryFolder`; both
  already branch correctly for the deployment, so `ProjectIntake` itself never asks the
  question.
- **READS `folder_node_id`, NEVER CALLS `Project#ensure_library_folder!`.** Calling the
  ensure would make a sweep CREATE `Projects/<slug>` for every project that never had one,
  as a side effect of merely looking — the same bug
  `Projects::AttachmentsController#relocate` once shipped, now at library-sweep scale. A
  project with no folder is simply not swept (`status: :no_folder`).
- **ASKS `Maker::AttachToProject#refusal_for` BEFORE EVERY MOVE — which is why that
  method is public.** Its three rules (`:not_a_file`, `:model_bundle`,
  `:attached_elsewhere`) are policy about where a file may go, not a suggestion; skipping
  them is exactly how `#relocate` once silently pulled a file out of a model's bundle
  folder while reporting success. `ProjectIntake#place` is a third door onto that one
  policy, not a second copy of it.
- **`:attached_elsewhere` IS THE ONE RULE THAT DOES NOT TRANSFER TO THE INTAKE, and it is
  scoped AT `#refusal_for` (`within_own_folder:`), never by `#place` filtering the answer.**
  Its stated reason is positional — "yanked out of the folder that project put it in" — and
  `#place`'s move is `Projects/<slug>/x` → `Projects/<slug>/<cat>/x`, so there is no other
  project's folder to yank it out of; `node_id` never changes, so the other project's
  attachment survives. Unscoped it was **silent and permanent**: a file any second project
  also claimed sat at the root through every 15-minute sweep forever, recorded only in a
  `skips` entry nothing but `rake projects:organize` prints. Reachable without doing
  anything unusual — `CurrentProject#attach_addon_files_to_current_project` attaches an
  addon's output to whatever project is **current**, regardless of which folder the save
  dialog wrote it into. `:not_a_file` and `:model_bundle` stay unconditional: the bundle
  rule is deliberately about the ATTACHMENT rather than the folder, so it makes no claim
  about where the file currently sits and has no equivalent argument for relaxing.
- **TWO COLLISION CHECKS, AGAINST TWO DIFFERENT FOLDERS, AND THE GAP BETWEEN THEM WAS A REAL BUG.**
  A door's own check (`refuse_taken_names!`) asks about the folder the user **picked** and is
  terminal ("pick another name" → **422** `unsupported_operation`). `Maker::ProjectIntake
  .destination_for` asks about the **category folder** the sweep will file into, and is answerable
  ("overwrite?" → **409** `would_replace`). A re-save goes straight through the gap: the first copy
  has already been filed, so the picked folder is vacant, the door accepts, and the sweep cannot
  place the second copy — which sits at the project root **forever**, two copies of one drawing in
  the library. That is §12 item 11 in the wild. **Keep 409 and 422 distinct**: a bundle must be able
  to tell "never succeeds on retry" from "say yes and it will", or it offers an Overwrite button for
  a save that can never take one. `destination_for` **creates nothing** — looking up a category
  folder must not mkdir it (`#relocate`'s recorded bug) — and takes its name from
  `Maker::ProjectFolders.folder_for`, the same pure function `#place` uses, so prediction and
  behaviour cannot disagree. **The 422 has ONE exemption, and only one:** an addon save carrying
  `state_id` may land on a node that saved item itself produced, in either check (§14c's own-file
  rule). Naming the state is the consent; "the destination is taken" is still terminal for every
  collision with a file this save did not write.
- **THE `state.id`-IN-THE-FILENAME EXEMPTION IS GONE WITH ITS DOOR, AND THAT IS A WIDENING, NOT A
  TIDY-UP.** `Tools::OpenscadController#create` could not reach the collision above because its
  output name embedded `state.id`, a fresh autoincrement per save, so two saves of one design under
  one name still produced two filenames — a confirm dialog there would have been UI for an
  unreachable branch, and dropping `state.id` turned `openscad_controller_test.rb` red. That door
  was retired on 2026-08-12 and **openscad now saves through `Tools::AddonsController#create` like
  every other addon**, where the name is whatever the BUNDLE sends. So the branch that was
  unreachable is now reachable for openscad too, and the 409 `would_replace` / 422 `name_taken`
  distinction below is what covers it. If a bundle chooses to embed a unique token in its output
  name it gets the old property back — but that is now the bundle's choice, made in another repo,
  and nothing in this one can assert it.
- **EVERY ADDON SAVE DOOR FIRES THE EAGER NUDGE — there is now exactly ONE**
  (`Tools::AddonsController#create`), and the concern is included on `Tools::BaseController` so a
  second inherits it. It was TWO until openscad's own door was retired. This was the last
  browser-facing door without one: the save dialog DEFAULTS to the current project's folder,
  so the user watched the redirect land on a file that visibly did not sort — 15 minutes on
  chunk, and on share/s3 there is no `project_folder_intake` schedule at all
  (`ProjectIntakeJob.sweep_all!` declines on a scannable backend), so it waits on
  `Library::ScanJob`'s poll. **ONE sweep per save, not one per file** (every file in a save
  shares `parent_node_id` and `.for_node` sweeps the owning PROJECT), **after** the attach
  per `ProjectFolderIntake`'s call-site rule. The conflict clause has one home,
  `#project_intake_sentence` — the doors differ on the LEAD-IN ("Uploaded grid.svg" vs
  "Saved “X”") and must not differ on what follows — and `#unfiled_by_conflict` is its plural
  form, because a save writes a SET and the colliding output need not be the first.
- **THE SCANJOB ORDERING — INTAKE STRICTLY AFTER THE RECONCILE, SAME JOB — IS A
  CORRECTNESS CONSTRAINT, NOT A CONVENIENCE.** A move made after the Scanner has captured
  its observations gets paired back by `(content_hash, size)` — `best_pairing` working
  exactly as designed — which re-points the node to its OLD path while the bytes sit at
  the new one. In that window a download does NOT get the retryable 503 (`library_present?`
  still reads true): `Share#download`'s `ENOENT` maps to `NotFound`, and `FilesController`
  renders that as a TERMINAL 404. Running the intake inline in `Library::ScanJob`, right
  after `observer.call`, makes the overlap impossible instead of merely unlikely — the
  reason `Maker::ProjectIntakeJob`'s own schedule declines on scannable backends (next
  bullet).
- **TWO CAPS, DELIBERATELY NOT ONE.** `MAX_MOVES` (500) bounds an unattended run's CHURN
  and is absolute, not a percentage — the only honest denominator is "files currently at
  project roots," of which the intended first run files 100%, so a percentage would be
  guarding against SUCCESS. `EAGER_MAX_MOVES` (25) bounds request LATENCY for `.for_node`,
  the one entry point that runs inside a browser-facing request (the eager nudge) rather
  than an unattended job. Collapsing them would let one upload's response wait on the cost
  `MAX_MOVES` is willing to accept for a background job.
- **THE EAGER CAP IS BACKEND-AWARE: `EAGER_MAX_MOVES = 25`, `EAGER_MAX_MOVES_S3 = 5`.** 25 was
  measured on chunk / local SQLite and is not an even bound across backends: `FileLayer::S3#move`
  is three sequential, unbatched network calls per file (a HEAD, a COPY, a DELETE), so 25 eager
  moves is **75 sequential S3 round-trips inside one browser-facing request** — at the 85–205 ms
  per call measured against a real R2 bucket, **six to fifteen seconds** an upload's response sits
  waiting. 5 keeps the same promise (a handful of files dropped in a folder file themselves
  immediately) at roughly a second. `PROJECT_ORGANIZE_EAGER_MAX_MOVES` still overrides on every
  backend. *(This bullet went on asserting a single even bound for months after the split landed —
  the stale-claim shape §15 warns about, in the file loaded into every session.)*
  - **`eager_max_moves` ASKS THE ADAPTER'S CLASS (`is_a?(FileLayer::S3)`), AND THAT IS NOT §14b's
    RECORDED TRAP.** That trap was a **gate** — `is_a?(Share)` decided *whether* to index, so an
    unrecognised backend was silently skipped and an S3 library never got indexed. This is a
    **threshold**, keyed on a property no adapter declares ("one move here is three round-trips"),
    and an unrecognised backend falls through to 25 — so it fails toward SLOW, never toward
    silence or data loss.
- **A CALLER MUST READ `intake_project_folder`'S RETURN VALUE, NOT JUST TRIGGER ITS SIDE
  EFFECT.** Every caller threw it away until a review caught it: a same-named upload whose eager
  nudge lost a collision at its destination folder reported a silent "Uploaded x." with no sign the
  file had stayed at the project root. `ProjectFolderIntake#left_unfiled_by_conflict?` /
  `#project_intake_notice` read the `:conflict` entry out of `Result#skips` for exactly this — but
  only in the **three** doors whose response a user actually sees (`FilesController#create`'s HTML
  branch, `Projects::UploadsController#create`, the addon save door). The JSON-only branches still
  run the intake and still file what they can; they just don't surface it, because nothing
  downstream reads that response key today.
