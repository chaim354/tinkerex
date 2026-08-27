# Git-tracked projects

Every maker project is a real git repository. This file holds the rules that bind INSIDE that
feature; the port verbs it stands on are CLAUDE.md §14a, and the intake exemption it needs is
`project-intake.md`.

**Read this before touching** `app/services/maker/git/**`, `app/jobs/maker/git/**`,
`Library::ScanJob`'s commit step, or `config/recurring.yml`'s `git_project_commit` entry.

Design and phase plans: `docs/superpowers/specs/2026-08-27-git-tracked-projects-design.md`. Read
its §2 before proposing any change of approach — three plausible architectures were killed by
evidence there, and two of them were killed *after* being proposed.

---

## The shape

Git data is durable **in the library**, never an app volume and never a database — written through
the non-cataloging repo-data verbs (§14a). `rugged` operates on an **ephemeral cache**; on `share`
the library is already a filesystem, so the repo is operated on in place and the maker gets
`git log` in Finder. Consolidation into packs is part of the commit loop, not a background tidy-up.

**Why packfile-level and not object-level**, because this is the one thing worth carrying in your
head: JGit's DHT backend stored git OBJECTS in a distributed database and was removed from JGit —
no database kept up with the access patterns. Its successor, JGit DFS, moved to **packs as immutable
blobs**, which is what every backend here is good at. Same store, opposite verdict, decided only by
what you put in it. Do not reopen object-level storage.

---

## What must not be undone

- **THE MANAGED MARKER MUST BE READ BEFORE IT IS WRITTEN, AND A REPOSITORY WITHOUT IT IS REFUSED.**
  `Repo#ensure_initialized!` wrote `tinkerex.managed` unconditionally, which destroyed the one
  question it exists to answer at the exact moment of asking: a repository already at `git_dir` and
  not carrying the marker is by definition not ours, and the app adopted it on sight. Found on the
  share box, where `Projects/TheFlightWall_OSS` is a project folder holding the maker's own clone —
  the next pass would have stamped our marker into their `.git/config`, run `index.clear` over their
  staged work, put a bot commit of 2,305 files on their `refs/heads/main`, and rewritten their index
  file. **"Already exists" is "libgit2 can open it", never "the directory is there"**: the hydrated
  backends' own `hydrate!` runs `mkdir_p(cache_dir)` first, so a directory that exists is the normal
  first-pass state, and an empty `.git` a maker made by hand is not a repository either — you cannot
  create one by creating the folder. A failure to open is *not a repository*, not an error (measured
  on rugged 1.9.6: absent path → `Rugged::OSError`, empty or fragmentary directory →
  `Rugged::RepositoryError`), and the same open answers both the refusal and the "should I init"
  question so the two cannot drift. **A `.git` that is a FILE is always foreign** — a `gitdir:`
  pointer means somebody else's linked worktree, and it is checked first because a pointer whose
  target is missing raises `OSError`, which otherwise reads as "nothing here" and sends `mkdir_p` at
  an existing file. The refusal lives at the write, not in a predicate a caller must remember: every
  door into `hydrate!` inherits it.

- **THE REFUSAL IS A SKIP, NOT A FAILURE, AND IT IS SAID ONCE A DAY.** `ProjectCommit#call!` rescues
  `Repo::UnmanagedRepository` and returns `nil` — its already-documented answer for "nothing to
  record" — so the project is skipped and every other project's pass is untouched. It is *not* left
  to `CommitJob`'s per-project `rescue StandardError`, which counts a project as FAILED and prints an
  error line: that is right for a NAS that blinked and wrong for a standing, correct, permanent
  state, and it would make "N FAILED" meaningless on any box where one maker keeps their own clone in
  `Projects/`. A silent skip is not acceptable either — a maker whose project never gains history
  deserves a line saying why — so the WARN is claimed through `Rails.cache` with `unless_exist:`,
  once per project per `REFUSAL_LOG_INTERVAL`. A cache is the right store *because* losing it is
  harmless: an expiry, a deploy or a store that keeps nothing costs one extra line and never silence.
  (§14e's scar is this mechanism failing the other way — a rate limit backed by the test env's
  NullStore fires never. Measured, not assumed: `NullStore#write` returns true every time, so the
  test env logs on every pass.)

- **A NESTED WORKING TREE IS PRUNED WHOLE — THE MARKER'S PARENT AND EVERYTHING BELOW IT.** The same
  refusal one level down, and found on the same box:
  `Projects/ESPHome-Projection-Clock/.claude/worktrees/<x>/` is a working tree inside a project whose
  root has no repository at all. Skipping only the marker leaves every file *beside* it committed
  into our history, which is the identical mistake with a smaller radius. It is the marker's PARENT
  that is pruned, because `.git/**` contents are never indexed (`Library::RepoMetadata`'s asymmetry)
  and so there is nothing under the marker to exclude. **A `.git` FILE counts here, where
  `Maker::AttachToProject#walk_for_marker` deliberately requires a directory** — the two answer
  different questions: a linked worktree and a submodule write a `gitdir:` pointer file, git treats
  that folder as a working tree either way, and the pointer is also exactly what was being committed
  as `.git.ptr`. Pruning its parent drops it with its siblings, so there is no separate "never commit
  a file named `.git`" rule to keep in step. **The project's own root marker is exempt only when it
  is a DIRECTORY**: that is the marker every managed project acquires on its first commit, so
  pruning on it would stop the feature dead at the second pass, while whether *that* repository is
  ours is the previous bullet's question. The exemption is not extended to a pointer file at the
  project root — we only ever create a directory there. Detection stays at **one query per level**
  (`kind: "dir"` OR a child named `.git`); this runs per project per scan over thousands of nodes, so
  a query per node is not available. **This is not a build-artifact ignore list and must not grow
  into one**: `.pio/libdeps` and `node_modules` are still committed, except where a dependency was
  vendored as a clone and kept its own `.git` — which this prunes incidentally, as a working tree,
  not because of its name. Whether build output belongs in a project's history is a separate product
  decision; an extension list invented here is the drift §14d keeps recording.

- **CONSOLIDATION IS IN THE COMMIT LOOP, NOT DEFERRED.** Measured: a 1,500-commit project
  unconsolidated needs **11,287 GETs to hydrate on s3** against ~3 packed, and 11,310 metadata
  round trips over SMB against ~30 — every cold container start. A window that commits without
  packing leaves the project unusable on two of three backends. The order is **commit →
  consolidate → persist**; persisting first pushes loose objects into the library and they then
  have to be deleted again.

- **`Maker::Git::PackWriter` EXISTS BECAUSE rugged HAS NO PACKBUILDER**, measured against the built
  gem rather than read off its README: `Rugged::Repository` exposes 70 instance methods and not one
  matches pack/repack/gc/prune; `Packbuilder`, `Indexer` and `Odb` are undefined; `Backend` has zero
  methods, so custom ODB backends are unreachable from rugged at all. There is no rugged-shaped
  shortcut to look for later.

- **THE UNDELTIFIED PACK AND THE POINTER RULE HOLD EACH OTHER UP.** The writer costs **5x on bytes**
  against `git gc` (3.9 MB vs 784 KB at 1,500 commits) and buys the entire **390x file-count**
  reduction, which is the term that matters. Five times SMALL is still small — but only because
  everything large is a pointer. **Weaken `Maker::Git::Tracking` and this trade dies with it.**

- **CONTENT vs POINTER IS `Maker::FileAttachment.text?`, NEVER A SECOND EXTENSION TABLE.** A
  hand-written role list is the drift `FilesHelper::EXT_FAMILIES` was rewritten to end (§14d), and
  it is not hypothetical here: the plan's own `%w[code document instructions]` routed **`manual.pdf`
  to content** — the `instructions` role is PDF and PDF only, a binary committed WHOLE, which is the
  exact failure the module exists to prevent — while contradicting its own tests for `.gcode` and
  `.scad`. `text?` already spans all three axes: text roles, `TEXT_EXTS` (`.scad` is `cad_source`
  and text anyway, and a role check loses diffs on the one CAD format that has them), and
  `TEXT_BASENAMES` (`LICENSE`/`Makefile`/`README` have no extension at all, and a repo root is full
  of exactly those). **Pointer is the DEFAULT**: an unknown format wrongly made a pointer costs one
  indirection; wrongly made content it puts an unbounded binary into history that cannot be removed.

- **SIZE OVERRIDES ROLE, AND `Maker::Git::ProjectCommit` MUST KEEP PASSING IT.**
  `Tracking::MAX_CONTENT_BYTES` demotes anything past it to a pointer whatever the name says,
  because a text NAME says nothing about the bytes behind it and a 400 MB `.md` committed as
  content is stored whole in every version, forever. The commit path is the only door that can put
  bytes into a history git cannot prune, so it is the only caller that must pass `size:` — drop
  that one argument and the ceiling still exists, still has tests and never fires, which is §15's
  recorded knob-shipped-inert shape. Pinned by `project_commit_test.rb`'s over-ceiling test, which
  drives the real pass rather than the predicate. **The number is REASONED, NOT MEASURED** — the
  constant says so in as many words and names the two checkable figures behind it (`TextDiff::MAX_BYTES`
  and the 3.9 MB pack above); `rake git_tracking:size_distribution` is the read-only instrument for
  replacing it with a real p99, and it deliberately asks the ROLE-ONLY question, because a report
  filtered by the current ceiling hides exactly the files that would argue for a different one.

- **CROSSING THE CEILING IS A DELETE PLUS AN ADD, AND IT IS DECIDED RATHER THAN INHERITED.** A text
  file that grows past `MAX_CONTENT_BYTES` moves from `notes.md` to `notes.md.ptr` and git records
  exactly that. Keeping the path stable would mean committing the pointer body AT `notes.md`, which
  makes "is this a pointer" a question about the BLOB rather than the path — ambiguous, and it
  reinterprets every repository already committed under the `.ptr` convention. "Once content, always
  content" needs HEAD's tree to decide and permanently exempts the very file the ceiling exists for.

- **A POINTER'S `oid` CARRIES `content_hash` VERBATIM, NAMESPACE AND ALL.** That value is §14a's
  identity-ladder output — `sha256:` on chunk_remote, `md5:` or `etag:` on s3. Stripping the prefix
  to look like an LFS `sha256` oid states an algorithm the bytes were never hashed with, and an
  `etag:` value is content-STATE rather than content-DETERMINED, which a reader must be able to tell.
  **A pointer to a SUPERSEDED version resolves only where the store kept those bytes** — the sync
  server on chunk_remote, bucket versioning on s3, and NOWHERE on share, where the maker's Finder
  overwrite destroyed them before this app saw them. The UI must say "not kept" rather than render a
  real commit as missing or corrupt.

- **SETTLE DETECTION IS CORRECTNESS, NOT LATENCY TUNING.** A slicer writing a 200 MB 3MF takes tens
  of seconds; a commit made mid-write records a TRUNCATED FILE as a legitimate version and looks
  entirely normal afterwards. A node is eligible only if untouched since the scan STARTED, which
  `Library::Reconciler` gives for free (it writes the node on every in-place content change), so no
  new column. **The anchor is captured at the top of `ScanJob#perform`, before the observer runs** —
  anchor it where the commit step is reached and every row that scan just touched reads as settled.
  The cost is one tick: a late commit is invisible, a corrupt one is permanent.

- **THE COMMIT STEP RUNS AFTER PROJECT INTAKE.** The intake MOVES files; committing first records
  every file at its old path and then again at its new one, doubling the history and making the
  first commit describe a layout that no longer exists. Git keeps whatever it was told, so that
  history is wrong permanently rather than until the next pass.

- **`call!` RETURNS BEFORE HYDRATING WHEN NOTHING SETTLED**, and that is load-bearing rather than an
  optimisation: `hydrate!` mints `.git`, which is the marker `Maker::AttachToProject` reads. A pass
  with nothing to do must not open the repository, or it freezes that project against the intake
  sweep for no reason.

- **HEAD MUST FOLLOW THE BRANCH WE COMMIT TO.** libgit2's `init_at` writes `refs/heads/master` while
  this app commits to `refs/heads/main`; leave it and the history is intact and INVISIBLE — `git
  log` answers "your current branch 'master' does not have any commits yet". Assert `rev-list HEAD`,
  never `rev-list refs/heads/main`: naming the branch explicitly passes either way and hides it.
  In place, `core.bare` is false and the index is WRITTEN, or `git status` reports every tracked
  file as DELETED — which to a maker looking at their own folder reads as "the app deleted my files".

- **PATHS ARE DERIVED PER NODE, NEVER PER BACKEND.** `storage_path` where the node and the folder
  both carry one; otherwise `Maker::LibraryTree#path_for` (§14k's one definition) with the folder's
  own path subtracted. chunk_remote nodes have NO `storage_path`, and deriving only from it made the
  whole feature silently inert on **the base deployment** (§7) with nothing erroring. Both of
  `path_for`'s nil returns must be checked — that is the `:broken` sentinel check its own header
  demands, and forgetting it fails QUIETLY because `:broken` answers `.name` too.

- **ONE PASS PER PROJECT AT A TIME.** Two concurrent passes both read HEAD, both build a tree from
  it, and the loser's `Rugged::Commit.create` updates the ref off a parent that is no longer the
  head — one commit silently orphaned. The limit is on the SCHEDULED fan-out only, because
  concurrency controls apply at enqueue and `ScanJob`'s inline `perform_now` must not be discardable.

- **THE CACHE IS EPHEMERAL AND ANYTHING NOT PERSISTED IS LOST.** It is keyed by user and project id,
  which are NOT unique over time in a transactional test suite — every test rolls back and the next
  mints the same ids, hydrating the previous test's repository. That is why `cache_root:` is
  injectable; production never reuses an id.

---

## Showing it (phase 4)

- **HISTORICAL RENDERS LIVE IN THEIR OWN TABLE AND ARE MINTED ONLY ON OPENING HISTORY.** §14b
  collapsed `Maker::Preview` to one row per `(user, node, kind)` because one-row-per-version leaked
  a row and a blob on every save — and the leak was **eager generation on save**, not the existence
  of old thumbnails. So `maker_version_previews` is separate, `Maker::Preview` is untouched, and
  `GeneratePreviewJob#commit_if_current` keeps its compare-and-set, which is what stops a historical
  render ever claiming the current row. Break any of those three and the bug §14b records is back.
  It keys on `project_id` (tenancy through a real FK — a `user_id` column additionally forces
  `TenantCleanupTest` edits), and `last_viewed_at` is the retention key rather than `created_at`,
  because a version nobody opens should age out even if rendered recently.

- **THE RENDER CACHE IS SWEPT ON ITS OWN WINDOWS, NEVER ON `Maker::DeadNodes::GRACE`.**
  `Maker::VersionPreviewReaperJob` (daily, `version_preview_retention`) destroys a row and purges
  its blob, and that is safe for a reason the two 30-day reapers cannot claim: **the row is a cache
  and losing it loses nothing** — the commit is in the repository, the version still names its
  `content_token`, and `HistoryController#mint_missing` re-mints and re-renders on the next open. So
  their 30 days is a **safety floor** (a tombstone is one undo from returning with the same
  `node_id`, and reaping early destroys the user's own filing) that this sweep has no reason to
  inherit; copying it would be copying a number whose justification is absent. **Two windows, split
  on terminal vs non-terminal**, which is the line `VersionPreview::STATES` already draws:
  `RETENTION` (90 days) ages out a finished answer, weighed as bytes on a Kamal volume
  (tinkerex#160) against a re-render the maker watches — WAN-fetched on `chunk_remote`, so err long.
  `PENDING_RETENTION` (1 day) is a **repair, not a reclaim**: `mint_missing` enqueues only
  `if row.previously_new_record?`, so a render that never resolved is never restarted by any number
  of page views and the tile spins forever — destroying the row is the only thing that fixes it, and
  `RenderVersionPreviewJob`'s `discard_on ActiveRecord::RecordNotFound` exists so racing an
  in-flight job is safe by construction. A weekly cadence would make that one-day window eight days
  of spinner, which is a window written and then not honoured.

- **OPENING HISTORY MUST NEVER MINT `.git`.** `hydrate!` creates the marker, and that marker is what
  `Maker::AttachToProject`'s `:in_working_tree` reads — so a read path that hydrates would switch
  off `docs/invariants/project-intake.md`'s filing for the project being *looked at*. Both doors
  (`#show` and `#compare`) go through one `never_committed?` guard that returns before anything opens
  the repo.

- **FOUR PAGE STATES, AND THREE OF THEM LOOK LIKE "NO HISTORY".** `ok`; `empty` (the ordinary case
  for a project older than the feature, or one whose files never settled — 500ing here is how a
  feature gets switched off in production); `unreachable` (`FetchError`, an unmounted share,
  RETRYABLE — rendering "you have no history" for a sleeping NAS is §14a broken in the UI); and
  `unavailable` (`NotFound`, terminal, which must not wear the retryable wording). The same split
  governs a tile: `not_kept` is terminal, a transient failure stays `pending` so the retry can
  still succeed.

- **AN UNAVAILABLE VERSION IS RENDERED, NEVER OMITTED.** Omitting it tells the maker their file has
  less history than it does, quietly. A greyed "not kept" tile is the truth.

- **A POINTER VERSION NEVER GETS A TEXT DIFF**, and the gate is `Tracking.mode_for`, never "do these
  bytes look like text". Diffing two content hashes is noise; the visual A/B is what that case is
  for. The diff is capped per side on BOTH lines and bytes — `Diff::LCS.sdiff` is near-free on
  ordinary edits and **quadratic on ambiguity**, which is the shape g-code and CSV actually reach
  (measured on the build box: 2,000 lines 0.18 s, 10,000 lines 5.4 s, 20,000 lines 23.9 s), and a
  byte cap catches what a line cap cannot see, because minified JSON is one line and can be 10 MB.
  **Refusal is WHOLE** — no rows at all, with the measured size named — because a truncated diff
  that looks complete is the well-formed lie this file keeps recording. Bytes are re-tagged binary
  BEFORE they are measured: `String#count` RAISES on a UTF-8-tagged string carrying an invalid
  sequence, which turns the binary refusal into a 500 on exactly the input it exists for.

- **`test/stimulus_hygiene_test.rb` IS DIRECTIONAL AND CANNOT CATCH A MISSING DECLARATION.** It
  derives registered identifiers from filenames and flags a `data-controller` naming nothing; the
  converse is deliberately not an error. So a rename of `version_compare_controller.js` IS caught,
  but deleting the attribute from the view is not — that one is covered by asserting the declaration
  in the integration tests, in two places, because a `data-controller` that resolves to nothing is a
  silent no-op that once left a feature inert for nine days behind a green request test (§14d).

---

## Known limitation, stated rather than implied

**A file that has crossed the size ceiling shows only ONE half of its history.**
`VersionHistory#for_path` derives the mode from the NAME alone, so it looks at `notes.md` or at
`notes.md.ptr` but never both — while a file that crossed has real versions at each. Nothing is lost
from the repository; what is lost is that the page renders half of it without saying so, which is
the shape "AN UNAVAILABLE VERSION IS RENDERED, NEVER OMITTED" exists to refuse. It is stated here
rather than fixed because the fix is not local to the ceiling: the mode of a historical version is a
property of the COMMIT, not of the filename, so `for_path` has to resolve it per commit (two
`blob_at` calls per commit against `LOG_LIMIT`), and `Projects::HistoryController#content_tracked?`
then has to answer for a PAIR whose two sides can disagree. The exposure is bounded by the ceiling
being 16x `TextDiff::MAX_BYTES`: any file that crosses it was already past the diff cap, so the half
that goes missing was never diffable.


`commit_all!` — the chunk_remote schedule, which has no scan to anchor to — passes no
`scan_started_at`, so "settled" there means "not touched since this job started" rather than a full
quiet interval. The mitigation is real but partial: the mirror row is written by a changelog pull,
and the pull writes only once the SERVER accepted the commit, so the bytes are already whole. If
that is ever not enough, the fix is a default of one tick back rather than `Time.current`.
