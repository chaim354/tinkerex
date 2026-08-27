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

## Known limitation, stated rather than implied

`commit_all!` — the chunk_remote schedule, which has no scan to anchor to — passes no
`scan_started_at`, so "settled" there means "not touched since this job started" rather than a full
quiet interval. The mitigation is real but partial: the mirror row is written by a changelog pull,
and the pull writes only once the SERVER accepted the commit, so the bytes are already whole. If
that is ever not enough, the fix is a default of one tick back rather than `Time.current`.
