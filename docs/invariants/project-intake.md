# Project-folder intake

> CLAUDE.md §14f's area file. Read before touching `app/services/maker/project_intake.rb`,
> `app/services/maker/project_discovery.rb`, `app/services/maker/attach_to_project.rb`,
> `app/services/maker/project_folders.rb`, `app/services/maker/project_folder_listing.rb`,
> `app/jobs/maker/project_intake_job.rb`, `app/jobs/maker/project_discovery_job.rb`, or
> `Library::ScanJob`'s post-reconcile sequence. The arc that produced it — measurements, what each
> guard caught, what was deliberately left out — is in `docs/STATUS.md`.

## Discovery — a folder under `Projects/` becomes a project

- **STATELESS — POSITION IS THE MARKER, EXACTLY THE PRINCIPLE THE FILING SWEEP BELOW ALREADY
  APPLIES ONE DIRECTORY LEVEL DOWN.** Any live directory directly under `Projects/` that no
  project claims becomes a project. No watermark, no `adopted` column, no first-run exemption —
  `Maker::ProjectDiscovery.adoptable` reads `nodes` fresh on every run, and the only record of
  "already handled" is a `maker_projects` row whose `folder_node_id` names that folder. A "seen"
  column would be a second source of truth for the same fact, and the two would drift the day
  anything writes to only one of them.

- **`discovered_at` IS THIS SWEEP'S OWN MARK, AND IT IS NOT THE SEEN-COLUMN THE BULLET ABOVE
  FORBIDS** (stage 4, S4-6). One `Time.current` for the whole run — these folders were discovered
  together, and a per-row clock read would make that legible nowhere while costing the same — and
  **nothing else in the app writes it**: not the web form, not `Projects::AdoptionsController`
  (which passes `discovered_at: nil` explicitly and says why at its own `create!`), not the v1 API,
  whose permit list does not name it. That is what lets `projects/_card` read
  `discovered_at.present?` as "the app made this, I did not" rather than as a proxy for it, and it
  is half of the **New** badge (`discovered_at` set, `opened_at` still nil). **It is never read to
  decide whether to adopt.** `adoptable` still asks `nodes` and the claim and nothing else, so
  statelessness is untouched — a mark the sweep WRITES for a page and a mark the sweep READS to skip
  work are different things, and only the second would be the second source of truth.

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
  **SINCE STAGE 4, S4-6 THE MECHANISM HAS A NAMED BUTTON, AND THAT IS A SENTENCE, NOT A SECOND
  WRITE.** `ProjectsController#destroy` takes `dismiss=1`, which changes the **flash and nothing
  else** — both paths call `archive!`, so the write is identical by construction rather than by two
  callers agreeing, and a second route performing it would be the drift this codebase refuses. The
  "Not a project" button renders on `projects/show` only when `discovered_at` is present: a project
  made by hand was never adopted, so the phrase means nothing there. Archive's own `turbo_confirm`
  says the previously-undocumented half out loud for a discovered project — its folder stays in the
  library, and the app will not adopt it again.

- **IT NEVER MINTS `Projects/` AND NEVER CALLS `ensure_library_folder!`.** `projects_root` looks
  the folder up with `find_by`, never find-or-create, so a user with no `Projects/` folder at all
  is simply not swept (`status: :no_projects_folder`). Calling the ensure would CREATE `Projects/`
  for every library that has never had one, as a side effect of merely looking — the same bug
  `Projects::AttachmentsController#relocate` once shipped ("the endpoint created `Projects/<slug>`
  as a side effect of being POSTed to"), now at library-sweep scale, on every user, every run.

- **`Maker::Project#ensure_library_folder!` MINTS ONLY WHEN `folder_node_id` IS NIL, AND A
  TOMBSTONED FOLDER IS NEVER SILENTLY RE-MINTED — FOR ANY PROJECT, NOT ONLY AN ADOPTED ONE**
  (stage 4, S4-6, decision 2). It used to re-mint whenever the column named a missing or tombstoned
  node, so deleting a project's folder in Finder — **the maker's own act** — was answered by a new
  empty `Projects/<slug>` appearing behind their back on the next page view, while the files they
  deleted sat in the trash under the OLD `node_id` where `undelete` could still find them (§14a's
  two tombstone kinds). Since a project's folder can now be a folder ANYWHERE, re-minting would
  additionally put a SECOND folder somewhere the maker never chose. **NIL IS PART OF THE CONTRACT,
  NOT A FAILURE**, and every caller answers it rather than raising: the Files panel renders "This
  project's folder is in the trash or was removed" with a link to Trash,
  `Maker::AttachToProject#move` returns `:unavailable` and leaves the bytes where they are, and
  `Maker::ProjectFolderListing` answers `available? == false`, so `ProjectsController#show` gives
  the top bar no destination and its Upload asks with the folder chooser rather than guess the
  root. (`Projects::UploadsController#upload_parent` was a fourth answer, landing the file at the
  library root, until F-S21-1 retired that controller's project-level route.) A project whose
  `folder_node_id` was never set — the form path — still mints, which is what
  `ProjectsController#create` depends on. **THE DOOR TESTS IN `projects_flow_test.rb` (two since
  F-S21-1) NEED THEIR REAL-SHARE FIXTURE AND MUST NOT BE "SIMPLIFIED" TO
  `project_folder_rows!`:** measured, with rows alone `Projects/` has no `storage_path`, so
  restoring the re-minting branch raised `FileLayer::NotFound` into each caller's rescue and all
  three guards of the time stayed GREEN over the regression they exist for — §15's green-suite
  shape, masked by the fixture rather than caught by the assertion.

- **DIRECT CHILDREN ONLY, AND DOT-FOLDERS ARE SKIPPED.** `adoptable` scopes to
  `parent_node_id: root.node_id` and rejects any name starting with `.`. Without the depth limit,
  `Projects/desk-lamp/models/` — a category folder this app created for an already-adopted project
  — would itself be adopted as a project named "models". Without the dot-folder rule: `.git` KEEPS
  ITS NODE on purpose (§14b — the marker is the evidence a directory is a working tree), so a repo
  checked out at the `Projects/` root would become a project literally titled `.git`.

- **`Maker::ProjectDiscovery.adoptable_name?` IS THE ONE DEFINITION OF THAT NAME RULE, AND IT HAS
  THREE CALLERS SINCE STAGE 4, S4-6.** The sweep's own `adoptable`,
  `Projects::AdoptionsController#refusal_for` (the second door, below) and the folder view's menu
  gate in `app/views/files/index.html.erb` (the control that opens that door) all ask it. A door or
  a control that spells the rule itself is the second copy §14d names a service to end, and one
  definition is also what keeps the control from OFFERING what the door would refuse. **It refuses a
  BLANK name too, and that arm is the door's, not the sweep's:** `Node` validates `name` presence so
  `adoptable` can never see one, but the door hands it whatever a row holds — and
  `nil.to_s.start_with?(".")` is FALSE, so the dot rule alone answers "yes, adoptable" for nil and
  mints a project that then fails `Maker::Project`'s own presence validation, a `RecordInvalid` at
  the user instead of a sentence.

- **A SECOND DOOR: `Projects::AdoptionsController` ADOPTS ONE FOLDER, ANYWHERE IN THE LIBRARY — AND
  IT IS A DOOR, NEVER A SWEEP** (stage 4, S4-6; spec decision D1). It writes ONE `maker_projects`
  row whose `folder_node_id` points at a live directory node, and nothing else: no mkdir, no move,
  no rename, and `Projects/` is never minted as a side effect. It shares this sweep's name rule
  (`adoptable_name?`) and its can't-fail slug (`Maker::Project.available_slug`) rather than spelling
  either, and **it never calls the port and never calls `ensure_library_folder!`** — which is what
  makes its whole test file rows-only and identical on all three CI legs. It refuses eight ways,
  cheapest first, each naming the ACTION that would work instead of merely the failure: no
  `node_id`; a node that is not a live directory of this maker's (a file, a tombstone, another
  user's row and a typo are ONE answer, deliberately — telling them apart discloses that an id
  exists); a dot or blank name; the `Projects/` root itself (adopting it would make one project
  holding every other project's folder, and would then claim the root against discovery, which reads
  the same column — silently switching this whole feature off); a folder any project already claims
  — **UNSCOPED ON STATUS, so archiving still dismisses**, and filtering archived rows out HERE is
  precisely how a dismissed folder comes back, with a button on it; a folder inside another
  project's folder; and a folder **strictly** inside a git working tree. An ancestor chain that
  cannot be resolved is refused as well, rather than adopted into a tree the app cannot describe.
  **THE STRICTNESS IS THE POINT IN BOTH DIRECTIONS:** `Library::WorkingTree#root_for` starts its
  walk at the node's PARENT, so a repository ROOT answers nil and IS adoptable, while `firmware/src`
  is refused — adopting it makes a project whose README, commits and history all sit OUTSIDE its own
  folder, so S4-1's repository card answers about a tree the project does not contain. A folder
  INSIDE `.git` falls under the same working-tree refusal, and is reachable only on `chunk_remote`:
  share and s3 index the `.git` marker but never its contents (§14b), so there is no node to post.

- **AN ADOPTED PROJECT IS CREATED WITH `autofile: false`; A DISCOVERED ONE KEEPS THE `true`
  DEFAULT, AND THE ASYMMETRY IS THE WHOLE POINT OF ADOPTING IN PLACE.** A folder the maker put under
  `Projects/` asked for the app's filing by being there; `designs/tray` did not, and saying "this is
  a project" is a statement about what it IS, not a request to rearrange it. Left on, the sweep
  moves `tray.svg` into `design/` and `notes.md` into `docs/` within fifteen minutes, unasked and
  unattended — the fight-the-user failure this file forbids one directory level down, arriving
  through a new door. The adoption flash says so in the same breath ("its files stay where they are,
  and automatic filing is off, so nothing moves"); the edit form's switch (S4-2) is where a maker
  turns it on. **`discovered_at` STAYS NIL ON AN ADOPTED PROJECT ON PURPOSE**: the maker made this
  one, so it is never "new to you" and never wears the badge.

- **DISCOVERY RUNS STRICTLY BEFORE THE FILING SWEEP, AND SINCE F-S07-1 (2026-10-19) THE ORDER
  CHANGES THE TIMING, NOT THE ANSWER**: a discovered project's loose files are filed in the SAME
  pass rather than the next. It used to change the answer — those files have no shelf nearer than
  `Projects` itself (the seeded `*`), so a model catalog that reached the folder before discovery
  made the WHOLE FOLDER one model, permanently — and **no ordering could close that**: discovery
  is CAPPED (`MAX_PROJECTS`) even inside `Library::ScanJob`'s own sequence, and on `chunk_remote`
  discovery and the catalog are independent schedules. `Maker::ModelIntake.claimed_folders` closes
  it instead, by asking discovery for **every folder it owns BY POSITION** —
  `Maker::ProjectDiscovery.positional_claims`, public and UNCAPPED, with `adoptable` defined as it
  minus what is already claimed — so a folder discovery has not reached is claimed all the same.
  **Any rule that decides what discovery will EVER adopt belongs in `positional_claims`**, never
  only in `adoptable` and never as a path test in the catalog, so the catalog follows it. Pinned in
  `test/jobs/library/scan_job_test.rb`'s `DiscoveryOrderTest`: every ordering mutation of `#perform`
  goes RED (a file left unfiled, or catalogued a scan late), and a capped run
  (`PROJECT_DISCOVERY_MAX=1`) must leave no auto model over the folder it has not reached — the
  assertion that used to stand on the ordering, moved there because no ordering can fail it any
  more. `Library::ScanJob#perform` sequences `discover_projects` →
  `intake_project_folders` → `intake_models` inline, all via `perform_now`, inside one call. There
  is no scan to sequence inside on `chunk_remote`, so `Maker::ProjectDiscoveryJob#chain_intake`
  enqueues the intake itself once a run has created something — **gated off scannable backends**,
  because a second, unsequenced filer there is the identical scan-overlap hazard the Filing section
  below already records (a move racing the Scanner's own observations).

- **THE SCAN BUTTON IS A SECOND SYNCHRONOUS CALLER OF DISCOVERY, ON `chunk_remote` ONLY, AND IT SITS
  BETWEEN THE PULL AND THE INTAKE** (`Projects::ScansController#pull_and_file`, stage 4, S4-6). The
  pull comes first because a folder another device pushed is not in the mirror until it lands, so
  discovery cannot adopt it before; discovery then precedes the intake in the order
  `Library::ScanJob` uses. That order no longer protects the model catalog — it used to read
  "filing before adopting hands the whole folder to the model catalog, permanently", and since
  F-S07-1 a folder discovery has not adopted yet is claimed by position (the bullet above), so it is
  never one model whichever runs first. **It calls the JOB with `perform_now`, not
  `Maker::ProjectDiscovery` directly** — the idiom `Library::ScanJob` already uses, and for the same
  two reasons: the job is the only place a run is LOGGED, and `#chain_intake` is what sweeps a
  project this call has just created (`.for_project` below it sweeps THAT project only). **`perform_now`
  creates no job row, so `limits_concurrency` does not engage here** (the bullet at the end of this
  section); what bounds the door is its own `rate_limit to: 3, within: 1.minute, by: current_user.id`.
  **On share/s3 the door ENQUEUES AND STOPS** — the scan-overlap race the Filing section records — so
  what discovery created is not knowable in-request there and **the New badge is the surface
  instead**, which is also how the unattended 15-minute sweep reports on every backend. A capped run
  says so in the same sentence ("N of M folders under `Projects/`; the rest on the next scan")
  rather than letting `created` read as "that was all of them" and sending a maker looking for
  folders the cap deferred.

- **THE SWEEP NEVER CALLS THE PORT.** `ProjectDiscovery.for_user` writes `maker_projects` rows and
  nothing else — no mkdir, no move, no bytes — which is what makes it identical on all three
  backends and testable without a library on disk.

- **`RunResult#names` IS WHAT THE RUN CREATED, IN THE SAME `ORDER BY node_id` ORDER `candidates`
  ITSELF USES** (stage 4, S4-6) — the determinism that makes a capped run reproducible and lets the
  next run continue where this one stopped instead of re-rolling the dice. It exists because a door
  can have a user in front of it, and `created` is a number: a number cannot answer "which
  folders?", the only question a maker watching a scan actually has. **It defaults to `[]`**, so the
  `:no_projects_folder` construction — and any `RunResult` a test builds by hand — reads as "created
  nothing" rather than raising. **Every member is spelled in the `Data.define`'s `initialize`**
  (`Library::Observation` is this repo's precedent for the shape), because an anonymous `**`
  forwarded through zsuper is a subtlety nobody should have to check.

- **THE CAP IS ABSOLUTE, NOT A PERCENTAGE — AND THE SECOND, SMALLER CAP BELONGS TO THE ONE ENTRY
  POINT INSIDE A REQUEST.** `MAX_PROJECTS` (50) bounds an unattended run's churn: the intended first
  run adopts 100% of what is sitting under `Projects/`, so a percentage would be guarding against
  success. This bullet used to read "ONE CAP, NOT TWO — AND WHOEVER ADDS A NUDGE OWES THE SECOND",
  on the grounds that nothing here had an entry point inside a browser request the way
  `Maker::ProjectIntake`'s eager nudge does. **Stage 4, S4-6 added one:**
  `Projects::ScansController#pull_and_file` runs a sweep synchronously inside a POST on
  `chunk_remote`. That door is where the second, smaller ceiling belongs — what bounds an unattended
  run is the wrong number for one that happens between a click and a redirect, and fifty adoptions
  plus fifty chained intakes is not a request. A nonsense override falls back
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
  **THERE IS A THIRD PATH SINCE STAGE 4, S4-6, AND IT IS OUTSIDE BOTH SEMAPHORES:**
  `Projects::ScansController#pull_and_file` calls this job with `perform_now` on `chunk_remote`, so
  it can race the recurring `sweep_all!` tick and mint two projects for one folder. What bounds it
  is that controller's `rate_limit`, which is not a semaphore and does not pretend to be. **Extend
  this bullet rather than adding a fourth beside it**, and note that the durable fix is a partial
  unique index on `(user_id, folder_node_id)` — filed as open work, because a `unique:` migration
  over an existing duplicate raises and takes the deploy down, so it needs a read-only probe of the
  three live databases before it is written.

## Filing

- **THE FOLDER NAMES COME FROM THE USER'S OWN FILING RULES (stage 3, S3-1), SEEDED FROM THE THIRTEEN
  ROLES PLUS THE KEYS THE VOCABULARY CANNOT CARRY — NOT FROM `Maker::ProjectFolders::ROLE_FOLDERS`
  DIRECTLY ANY MORE.**
  `Maker::ProjectFolders.folder_for(user, name)` reads `Maker::FilingRules.for(user)`: one row per
  extension, seeded once from `ROLE_FOLDERS` over `Maker::FileAttachment::ROLE_BY_EXT` on a user's
  first read and edited from then on at `/settings/filing`. Since stage 4, S4-2 (`cnc_design` was
  the thirteenth role) the seed ALSO writes one row per `Maker::FilingRules::BEYOND_ROLE_BY_EXT`
  entry — today `kicad_sch`/`kicad_pcb` → `pcb`, a literal folder because there is no role to look one
  up by — so the count a test asserts is `ROLE_BY_EXT.size + BEYOND_ROLE_BY_EXT.size`, never the first
  alone. `seed!`'s `exists?` guard stays a whole-batch guard: an existing user's new keys arrive by
  MIGRATION, once (`20260907120100`), because `/settings/filing` promises a removed rule files into
  `other` and a per-read top-up would resurrect it. Keep `BEYOND_ROLE_BY_EXT` small — every entry
  claims a real format the Files page cannot filter by. `default_folder_for(name)` stays the
  OLD pure function of the static, role-keyed vocabulary — kept for the seed itself (which cannot
  ask `FilingRules.for` the very map it is about to build) and for any caller with no user in hand.
  An extension with no rule files into `"other"`, a per-user, expected answer now rather than the
  loud `KeyError` an unmapped ROLE still gets (`default_folder_for`'s own `fetch` has no default,
  on purpose — see `Maker::ProjectFolders`'s header for the full argument for why these are not
  the same shape).
  **`#place` DOES NOT CALL `Maker::ProjectFolders.folder_for` AT ALL, AND THAT OMISSION IS
  LOAD-BEARING.** That method pays `Maker::FilingRules.for`'s `exists?` + `pluck` pair on EVERY
  call, so using it inside `#file_all`'s per-file loop would be a query pair per file across a run
  bounded at `MAX_MOVES` (500) — the identical per-file cost this file's own "the memo is per
  parent, not per node" bullet already warns about for `AttachToProject#refusal_for`, one layer up.
  `ProjectIntake` instead keeps its own `@filing_rules` memo (`Maker::FilingRules.for(@user)`, read
  ONCE for the whole sweep) and a private `#folder_for(name)` reading it directly — one query pair
  per PROJECT's sweep (a `ProjectIntake` instance is itself scoped to one project; see
  `.for_user`'s per-project loop), not one for a user's whole multi-project run and not one per
  file. `.destination_for` — a class method with no instance to memo on, called once per
  addon-output file rather than per sweep-file — still calls `Maker::ProjectFolders.folder_for`
  directly; its own call volume is bounded by one addon save's output count, never by the
  library's whole inbox, so it does not need the same memo.

- **THE PAGE LISTS THE FOLDER AND NEVER FILES OR MINTS IT.** `Maker::ProjectFolderListing` reads
  `folder_node_id`, answers liveness through the LibraryTree, and creates nothing; the one writer of the FOLDER
  on `projects#show` is the pre-existing best-effort `ensure_library_folder!`, which runs before the
  listing. The top bar's Upload saves into the LISTING's folder (`FolderDestination`, set only when
  `available?`), never into what the ensure returned, so the page shows and uploads into one
  folder. A file inside the folder with no attachment row is still listed — the folder is the
  relation the panel shows; `maker_file_attachments` stays the relation detach, cover and addon
  origin read. **The Files panel's "Recently changed" row (slice 6) reads
  `ProjectFolderListing#recent_files`**: ONE query over the subtree `files_in` already scopes,
  newest `updated_at` first, `[]` when the folder is unavailable, and like the rest of the listing
  it never mints and never files. It is deliberately **not** part of the capped, name-ordered
  listing: a folder past `FILE_CAP` has its newest files somewhere beyond the cap, so a row taken
  from the listing would show the newest of the first 300 names.

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

- **A README AT THE PROJECT ROOT IS ATTACHED AND NEVER FILED — `:project_readme`, the fourth
  refusal (stage 3, S3-4).** It is the project's own description and the public page renders it
  from the root (`Maker::PublicProject#readme` reads `listing.loose`); measured on the dev
  library, the sweep moved a freshly written README.md into `docs/` and the public page showed
  nothing. Keyed on the NAME (`Maker::Readme::NAMES`), never the extension — `notes.md` beside it
  is still filed. SCOPED with `within_own_folder:` like `:attached_elsewhere`, for the mirror
  reason: the sweep asks whether a file already at this root should be filed; the relocate door is
  a user moving a README in from elsewhere, and refusing there would strand it outside the folder.
  Guard: `project_intake_test.rb` ("a README at the root is attached but never filed away").

- **ROOT = INBOX, PLUS WHAT `other/` NO LONGER HOLDS — AND IT IS STATELESS.** Files at a project
  folder's own root are filed; anything in any other subfolder — including one filed "wrong" by
  hand — is never revisited, and no column records that a file was "handled." Position is the
  marker. Re-filing a subfolder would fight the user every 15 minutes, and on chunk each round of
  that fight is a changelog entry broadcast to every device.
  **`other/` is the one exception, on the owner's word (2026-10-20):** a file DIRECTLY in the
  project's `other/` (`Maker::ProjectFolders::OTHER`) whose extension has a rule naming another
  folder is re-sorted into it. `other/` is the sweep's own answer for "no rule for this", so such a
  file is the app's earlier "don't know", not the maker's filing — catan's three `.mage` files went
  into `other/` on 2026-09-06, the day before `.mage` got `cnc/`, and stayed there. What triggers it
  is a rule APPEARING (a vocabulary widening's migration, or an Add at `/settings/filing`), so the
  periodic sweep catches it; no nudge does, because no file arrival signals a rule change. Three
  things not to undo: **`Maker::ProjectIntake.resortable?` decides by NAME alone** and is the ONE
  predicate both `#call`'s selection and `.inbox_count` (both caps' count) use, so a cap counts
  exactly what the run files — and counting every file in `other/` instead would make a library
  full of unrecognised files refuse every run; **direct children only**, since a folder the maker
  made inside `other/` is their filing; and **a selected file whose destination works out to
  `other/` again stays put** (`:already_filed` — reachable as a board zip whose `gbr` rule names
  `other`), never a move onto its own parent reported as a filing every sweep. **The cost, accepted:**
  a file with a rule that the maker parks in `other/` by hand moves out on the next sweep; a folder
  of their own, anywhere else, is what keeps it.
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
  `skips` entry nothing but `rake projects:organize` prints. It was reachable without doing
  anything unusual while a current project attached an addon's output to whatever project
  was **current**, regardless of which folder the save dialog wrote it into (retired in
  slice 4 of the 2026-10-08 redesign); any second claim on a file at a project root still
  reaches it. `:not_a_file` and `:model_bundle` stay unconditional: the bundle
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
  `Maker::ProjectFolders.folder_for(user, name)`, reading the SAME per-user filing rules `#place`'s
  own memoized lookup reads a moment later, so prediction and behaviour cannot disagree as long as
  the user's rules have not changed in between. **The 422 has ONE exemption, and only one:** an addon save carrying
  `state_id` may land on a node that saved item itself produced, in either check (§14c's own-file
  rule). Naming the state is the consent; "the destination is taken" is still terminal for every
  collision with a file this save did not write.
- **THE SWEEP DECIDES BY NAME, WITH ONE CONTENT EXCEPTION, AND IT LIVES IN `#place` ALONE (stage 4,
  S4-2; story 2.8).** A `.zip` that `Maker::GerberArchive.for(user:, node:)` recognises as a board
  files where this maker files a Gerber *layer* (`filing_rules["gbr"]`, else `ROLE_FOLDERS["pcb"]`),
  not into `archives/` — the zip IS a layer set in a wrapper, so it is the same question, not a new
  kind of rule. Bounded three ways before any read: `archive?` is name-only so nothing but a `.zip`
  is opened; `.for` refuses a nil or over-`READ_LIMIT` (16 MB) size off the catalog's own column; the
  answer is cached by `(node_id, content token)` with **nil cached too**. An unreachable library
  answers "not a board" and the move one line later raises the same `FetchError`, so the zip is
  never filed *wrongly* — it is not filed. A dry run still reads: a bounded cached read is not a
  write, and the alternative is a dry run that predicts the wrong folder.
- **`.destination_for` CANNOT ANSWER THE BOARD-ZIP QUESTION, AND "prediction and behaviour cannot
  disagree" IS SCOPED, NOT BROKEN.** It is asked about a file a save is *about to write* — no bytes
  in the library, no node to read them from — so it must never grow a `node:` kwarg no caller can
  fill. Its one caller (`Tools::AddonsController#resolve_placements`) writes SVG and 3MF, so no
  bundle here or in `chaim354/tinkerex-addons` reaches the divergence. What keeps the user-facing
  sentence true anyway is the conflict's own row: the flash names the folder `#place` **actually
  tried**, recorded as it tried it, never re-derived from a name.
  **`ProjectIntake::Result` HOLDS `attached`, `status` AND ONE `Filing` PER INBOX FILE — `name`,
  `folder`, `skip` — AND NO COUNT OR LIST BESIDE THEM (F-S06-1).** `plan`, `skips`, `moved` and
  `skipped` are readers over those rows, so no count can disagree with its list; `#place` answers
  a `Filing` on every path, so there is no String-or-Symbol return to dispatch on; and a
  `:conflict` row carries the folder it tried, so there is no name-keyed map beside the skips for
  that folder to go missing from.
  `ProjectFolderIntake#left_unfiled_by_conflict?` and `#conflict_folder` both read
  `Result#conflict_folder(name)` **WITH NO FALLBACK**: re-deriving from the name is the wrong flash
  521bfb30 fixed, and the fallback that outlived the fix hid a conflict recorded without its folder
  behind a plausible answer. **Nothing here is called `conflicts`** — that is one of
  `architecture_invariants_test.rb`'s `ENGINE_ASSOCIATIONS`, matched as a bare ident, and the seam
  guard takes no allowlist.
- **`maker_projects.autofile` IS A STATEMENT ABOUT DIRECTORIES, NOT ABOUT KNOWING (stage 4, S4-2;
  story 4.3).** Off, `#call` still **attaches** everything it finds and files nothing — the same
  durable/best-effort split `@move` already encodes for the cap. Read in `#call`, the one method
  every entry point funnels through (`.for_user` loops `.for_project`, `.for_node` calls
  `.for_project`, the rake task and the scan door call `.for_project`), so no caller has to remember
  it and a future one gets it for free. Default true: every project did this before the column
  existed.
- **THE SWEEP RECORD HAS ONE WRITER, AND AN ATTACH-ONLY PASS IS NOT A SWEEP.** `#record_sweep!`
  stamps `last_swept_at`/`last_sweep_moves` with `update_columns` (no validation, no callback, no
  `updated_at` bump — this runs every 15 minutes forever and Recent orders by `updated_at`). It sits
  **below** `#call`'s `unless @move` return: `move: false` is `.for_node`'s over-the-eager-cap path,
  which declines to file, so stamping a 0 there would overwrite a real "filed 3 files" on every
  upload into a busy project. It **does** stamp when `autofile` is off — that pass was allowed to
  file and chose not to. `last_sweep_moves` is **nil until a sweep that was allowed to file has
  finished once**; nil and 0 are different facts (§15's timestamp-at-`.to_i` warning is why the
  column has no `default: 0`).
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
  browser-facing door without one: the save dialog starts where the tool last saved, mapped
  up to its project folder, so the user watched the redirect land on a file that visibly did
  not sort — 15 minutes on
  chunk, and on share/s3 there is no `project_folder_intake` schedule at all
  (`ProjectIntakeJob.sweep_all!` declines on a scannable backend), so it waits on
  `Library::ScanJob`'s poll. **ONE sweep per save, not one per file** (every file in a save
  shares `parent_node_id` and `.for_node` sweeps the owning PROJECT), **after** the attach
  per `ProjectFolderIntake`'s call-site rule. The conflict clause has one home,
  `#project_intake_sentence` — the doors differ on the LEAD-IN ("Uploaded grid.svg" vs
  "Saved “X”") and must not differ on what follows — and `#unfiled_by_conflict` is its plural
  form, because a save writes a SET and the colliding output need not be the first.
- **INTAKE IS NOW THE ONLY WAY TOOL OUTPUT REACHES A PROJECT (redesign slice 4, spec §9.3), AND
  OUTPUT SAVED OUTSIDE EVERY PROJECT FOLDER ATTACHES TO NONE — ON PURPOSE.**
  `attach_addon_files_to_current_project` went with the current project and nothing replaced it:
  `Tools::AddonsController#create` attaches nothing itself. Output saved anywhere inside a project
  folder is filed and attached by `Maker::ProjectIntake.for_node`, reached through the save door's
  eager nudge above (`.owning_project` walks up from the output's parent, so a subfolder counts;
  `#call` attaches the whole subtree and files only the root). Output saved outside every project
  folder belongs to no project, and that is the answer, not a gap — where the file landed is the
  relation, the same position-is-the-marker rule ROOT = INBOX states for filing. **Do not add an
  attach back to the save door keyed on anything but the folder**: one keyed on session or user
  state is the design `test/architecture_invariants_test.rb` now forbids by name, and attaching
  regardless of folder is what made `:attached_elsewhere`'s unscoped arm reachable (above).
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
- **AN INTERACTIVE SCAN DOOR MUST NOT FILE ON A SCANNABLE BACKEND — IT ENQUEUES AND STOPS.**
  `Projects::ScansController` (the per-project "Scan folder" button) is the SECOND door that
  refreshes the store on a user's command — `FilesController#rescan`, the Files page's "Rescan
  library" button, predates it and is `require_scannable!`-gated, so it never reaches this rule's
  chunk_remote half. On share/s3 this one calls `Library::ScanJob.enqueue_for` and
  files NOTHING itself: a move started from the request races the Scanner's own observations, and
  the bullet above is what that costs — a terminal 404 for a file that is not gone. The filing is
  already inside `ScanJob#perform`, after `observer.call`, and that is the only place it may be.
  Pinned by `project_scan_button_test.rb`'s "a scannable backend does NOT file synchronously",
  mutation-checked by adding the forbidden call.
  **On `chunk_remote` the same door DOES file synchronously, and the asymmetry is the rule, not an
  inconsistency**: there is no scan there, so there is no race, and the pull's own nudge
  (`ChangelogSync#nudge_project_intake`) covers LIVE ARRIVALS ONLY — a file already in the mirror
  but unfiled gets no nudge, so a pull-only button would find nothing to do and read as broken.
  The synchronous pull is **not** the one §14a forbids: that bars a pull in a READ path, and this
  is a POST.
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
  `#project_intake_notice` read the `:conflict` Filing out of the Result for exactly this, and
  every door that runs the nudge reads it: `FilesController#create` (the HTML flash and, since stage
  4 S4-3, the JSON `notice`), `#finalize_upload`'s JSON `notice` (S4-3), and the addon save door.
  Save-to-library (`measure_controller.js`) reads `notice` off both upload doors through
  `lib/chunk_upload.js`. `Projects::UploadsController#create` was a reader too until F-S21-1. Its
  build-log photos land at the library root, which no project owns, so it no longer runs the nudge.
