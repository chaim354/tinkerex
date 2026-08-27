# Git-tracked projects

**Date:** 2026-08-27
**Branch:** `claude/git-viewer-e1994c` (the branch name predates the design — it began as a read-only git viewer)
**Scope:** this repo. No sync-engine or client change.

---

## 1. The ask

Every project is git tracked, on **all three backends**, with version history visible in the
GUI — including **per-version thumbnails for models and CAD**, where a text diff is worthless and
two renders side by side are not.

Two hard constraints from the user, both stated explicitly:

- **No app volume.** Durable state on a Kamal volume is rejected. (Filed separately as
  `tinkerex#160` — Active Storage is on one *today*, and previews with it.)
- **Do not reinvent the wheel.** Use the pattern that already works.

---

## 2. What was rejected, and why

This section exists because three of these were proposed *in this design conversation* and killed by
evidence. Recording them stops the next reader re-deriving them.

### 2.1 Git objects in a database — REJECTED, and it was built once

**JGit DHT** stored git objects in a distributed database. It was **removed from JGit**: *"no
database could keep up with the access patterns."* A clone of linux-2.6 (2M objects / 400 MB) took
**15–30 minutes**; index overhead ran ~23 bytes per object, adding ~62.6 KiB per 1 MiB of real data,
with an OBJECT_INDEX table of 223 MiB for that one repo.

This kills `libgit2-backends` (MySQL/SQLite/Redis/Memcached), `gitgres`, and any custom
`git_odb_backend` — all object-level. `gitgres` is additionally experimental (12 commits, no
releases) and **cites this same failure in its own README**.

### 2.2 Repositories in object storage — REJECTED by every implementation

Forgejo's own documentation: repositories in object storage are **unsupported**, because they shell
out to `git`, and *"git manages a lot of small objects, uses random read and write access… while S3
is optimized to store large, immutable objects."* Their `[storage]` sections cover attachments, LFS,
avatars, repo-avatars, repo-archive, packages and Actions artifacts — **never repositories**.

GitHub (Spokes/DGit) stores *real git repos on local NVMe* — "no SAN, no distributed filesystem, no
clever block layer" — and gets durability from **three-way replication at the packfile level**.
GitLab's Gitaly/Praefect is the same shape. **Nobody relocates git; they replicate it.**

### 2.3 An app volume — REJECTED by the user

Correctly. It is undurable, unbacked-up, and this repo already has one holding Active Storage that
nothing sweeps or archives (`tinkerex#160`).

### 2.4 What survived

**JGit DFS** — the design the DHT failure *produced*, and what Gerrit runs on. It moved from
object-level to **packfile-level**: refs with compare-and-swap, packs as immutable blobs.

**The distinction is the entire lesson, and it is a granularity argument, not a storage-medium one.**
A packfile is a large immutable object, which is what every backend here is good at. An individual
git object is small and randomly accessed, which is what they are all bad at. Same store, opposite
verdict, decided only by what you put in it.

---

## 3. Architecture

```
Library (share / s3 / chunk_remote)          Rails container
┌──────────────────────────────┐            ┌───────────────────────────┐
│ Projects/<slug>/             │            │  ephemeral cache          │
│   cad/body.step   ← primary  │  hydrate   │  /tmp/repos/<project>/    │
│   docs/notes.md      bytes   │ ─────────► │    a real git repo        │
│   .git/                      │            │    rugged operates here   │
│     objects/…     ← DURABLE  │  persist   │                           │
│     refs/…           git data│ ◄───────── │  losable by design        │
└──────────────────────────────┘            └───────────────────────────┘
```

Three claims, each load-bearing:

1. **The library is the only durable store.** No app volume, no app-owned bucket. Git data lives
   beside the files it describes, in the user's own storage, on every backend.
2. **The container cache is ephemeral and rebuildable.** That is what makes a real git
   implementation usable without durable local state — and it is the difference between a cache and
   a volume.
3. **On share, the cache step is skipped.** The library *is* a real filesystem, so the repo is
   operated on in place. Same code path, one branch at hydration. The user gets `git log` in Finder
   for free, which is the strongest single argument for git over a bespoke version store.

### 3.1 Library

**`rugged`** (libgit2 bindings).

| | |
|---|---|
| **Licence** | libgit2 is GPL-2.0 **with a linking exception**, written to permit linking from a program under any licence. §9's GPL concern does not bite — unlike shipping the `git` CLI, which would put a GPL binary in the image |
| **Covers** | commits, trees, blobs, refs, index, diffs, revwalk — the entire hot path |
| **Does NOT cover** | **packbuilder, repack, gc — confirmed absent by introspecting rugged 1.9.6 / libgit2 1.9.6 itself**, not by reading the README. See below |
| **Cost** | a native extension in the Docker build (needs `cmake`) |

**Measured against the built gem, 2026-08-27:**

- `Rugged::Repository` exposes **69 instance methods and not one** matches `pack`, `repack`, `gc` or
  `prune`.
- Object access is `exists?` / `lookup` / `read` / `read_header` / `write` — **loose objects only**.
- `Rugged::Packbuilder`, `Rugged::Indexer`, `Rugged::Odb` and `Rugged::ObjectDatabase` are all
  **undefined**. `Rugged::IndexerError` *is* defined — an error class for a facility that was never
  bound, which is a good summary of how partial the binding is here.
- `Rugged::Backend` exists with **zero class methods and zero instance methods**. So custom ODB
  backends are not merely "C, not Ruby" as an earlier draft of this spec put it — they are not
  reachable from rugged at all. That closes §2.1's door from a second direction, though §2.1 had
  already closed it on merit.

This is why §9.1's pack writer exists, and it is now a verified requirement rather than an inferred
one.

Rejected alternatives: the **`git` CLI** (GPL-2.0 in a shipped image; this repo's answer to GPL is an
HTTP sidecar, which is heavy plumbing around something whose job is filesystem access) and **`gix`**
(Apache-2.0/MIT and production-grade as a library — Cargo uses it — but its shipped CLI binaries are
explicitly marked unstable, and it buys nothing rugged lacks except packing, see §9.1).

---

## 4. Repo lifecycle

| step | what happens | needs |
|---|---|---|
| **hydrate** | copy `.git/**` from library → cache. Skipped on share | port read (§6) |
| **commit** | build index from changed paths, write tree, write commit, update ref | rugged |
| **persist** | copy new/changed objects and refs back → library | port write (§6) |
| **consolidate** | collapse loose objects into a pack | **not in rugged — §9.1** |

Consolidation is **part of the loop, not a background tidy-up**: §4.1 measures an unconsolidated repo
as unhydratable on s3 and chunk_remote, so a window that commits without packing leaves the project
unusable on two of three backends.

**Locking.** Two workers must not operate one project's repo concurrently. `Library::ScanJob`
already enforces one scan per user, which covers the scan-triggered path; any eager path added later
must take the same lock. A ref update is compare-and-swap and a lost update is a lost commit, not
corruption — but the cache directory is not concurrency-safe and must be.

### 4.1 Measured: hydration and consolidation (2026-08-27)

Spiked against a synthetic maker project built the way §5 routes one — 60 text files across
src/include/docs/config/test, plus 30 LFS-style pointer files standing in for STL and STEP — with
scan-shaped churn (1–5 files per commit, a pointer rewritten every sixth). Script:
`2026-08-27-git-tracked-projects-spike.sh`, committed beside this file — `./spike.sh <dir> <commits>`.

**Growth is linear at ~7.5 objects per commit.**

| commits | loose objects | `.git` allocated |
|---|---|---|
| 100 | 835 | 3.4 MB |
| 500 | 3,789 | 15.0 MB |
| 1,500 | 11,287 | 44.6 MB |

**Loose vs packed, at 1,500 commits:**

| | loose | packed | ratio |
|---|---|---|---|
| files in `.git` | 11,310 | **29** | **390×** |
| local copy time | 2.88 s | ~0.00 s | — |

**The size numbers needed a second look, and the first reading was wrong.** `du` reports *allocated*
blocks, and 3,807 loose objects averaging **318 bytes** each are almost entirely 4 KB-block padding:

| 500 commits | |
|---|---|
| apparent bytes | 1,183 KB |
| allocated on APFS | 15,228 KB — **12.9× inflation** |
| packed, delta-compressed | 267 KB |
| **true compression ratio** | **4.4×**, not the 27× the allocated figure implies |

**Two consequences, and they point the same way.**

*The problem with loose objects is FILE COUNT, not bytes.* Object storage has no block padding, so
loose costs ~1.2 MB there either way. What costs is **11,287 requests instead of 2** — the same
"small objects, random access" shape §2.2 records every git host refusing, and the same synchronous
metadata round-trip §2/§14e is built around avoiding.

| hydration at 1,500 commits | packed | loose |
|---|---|---|
| s3 | ~3–5 GETs, ~1.1 MB | **11,287 GETs**, billed, every time |
| share over SMB | ~30 metadata round trips | **11,310** |
| chunk_remote | a handful of mirror rows | 11,287 rows and reads |

*Incremental packing works exactly as the design needs.* Twenty commits on top of an already-packed
repo produced 161 loose objects; `git repack -d` collapsed them into **one 38 KB pack + 5.5 KB idx,
leaving the existing pack untouched** and loose back at 2. So a consolidation window costs **2 new
immutable files**, and old packs are never rewritten — precisely the JGit DFS shape (§2.4).

Packs do accumulate, so a full repack is needed when the pack count grows; git's own
`gc.autoPackLimit` default of 50 is a sane rule to borrow rather than invent.

---

## 5. What gets tracked

**Not everything.** Git stores each version of a binary as a whole compressed object and binary
deltas on meshes are near-worthless, so twenty saves of a 50 MB STEP file is ~1 GB in `.git`,
permanently — and git cannot prune reachable history without rewriting it.

The pattern every git host already uses for this is **LFS**: large binaries leave the repo, a
pointer stays. We adopt the *pattern*, not the protocol — a pointer file is three lines of text and
we need no LFS server.

| files | in the repo as | why |
|---|---|---|
| `code`, `document`, `instructions` roles, and extensionless text (`TEXT_BASENAMES`) | **content** | small, diffable, this is what git is for |
| `model`, `cad`, `laser`, `image`, `archive` roles | **pointer** — `content_hash` + size | large, undiffable, and the bytes are already in the library |
| anything over a size threshold, whatever its role | **pointer** | a 400 MB `.md` is still a 400 MB blob |

**Derived from `ROLE_BY_EXT`, never a second table.** §14d records that a hand-written parallel
extension list is exactly the drift `FilesHelper::EXT_FAMILIES` was rewritten to end.

**The pointer resolves against content the library already has**, because `Library::Reconciler`
computes a `content_hash` for every file today. So a pointer to the *current* version costs nothing
extra.

**Honest limit, and it must be stated in the UI, not just here.** A pointer to a *superseded*
version resolves only where the store kept those bytes:

| backend | old binary versions | so a historical thumbnail |
|---|---|---|
| `chunk_remote` | the sync server keeps them | renders |
| `s3` | only if bucket versioning is enabled | renders, or is honestly marked unavailable |
| `share` | **gone** — the Finder overwrite destroyed them before any scan ran | is marked unavailable |

Text history is complete on every backend. Binary history is complete only where the store already
retained it. **The GUI shows "not kept" rather than pretending the version never existed.**

---

## 6. The port door

Git data must be written into `.git/**`, and three existing refusals stand in the way —
`FileLayer::Share#observable!`, `FileLayer::S3#observable!`, and `Library::ReservedNames.reserved?`.

**They must not simply be reversed.** They exist because `.git/**` is *unobserved*: a **cataloged**
write there creates a live node at a path no scan can pair, whose tombstone trips the mass-deletion
guard and refuses that scan **and every scan after it, permanently**. §14b records four such wedges.

**The resolution is a new port verb that writes bytes WITHOUT cataloging them.** No node, no ghost,
no wedge, and `.git/**` stays exactly as unobserved as it is today.

```
write_repo_data(user, project:, rel:, io:)    # rel is relative to the .git marker
read_repo_data(user, project:, rel:)
list_repo_data(user, project:, prefix:)
```

| backend | write | read | list |
|---|---|---|---|
| `share` | direct filesystem under the marker | filesystem | `Dir.children` |
| `s3` | `put_object` at the key | `get_object` | `list_objects_v2` |
| `chunk_remote` | the ordinary commit flow — **cataloging here is correct**, because its `nodes` table mirrors the sync server rather than a scan, and §14b records that those rows already exist | mirror + `read` | mirror |

**A new capability gates it** — call it `repo_storable`. Per §14b's standing warning, it must be
argued rather than observed: it asks *"can this backend hold opaque data outside the catalog?"*,
which is not `scannable` (where the catalog comes from), not `port_writable` (which door bytes go
in), and not `versioned`. It is true on all three today; that agreement is three samples, not an
identity.

---

## 7. Scan integration

`Library::ScanJob` runs **every 15 minutes** and its sequence is reconcile → discovery → project
intake → model intake. The commit step goes **after project intake**, so a file this app is about to
move is committed at its final path, not its old one.

### 7.1 The workflow this produces

The app is **not in the write path** on share, so tracking is necessarily after the fact:

1. You save from Fusion to the NAS. Instant, unchanged, no app involvement.
2. **Nothing happens for 0–15 minutes.** `recurring.yml` states why: *"inotify does not reliably
   fire for other machines' writes over SMB/NFS, so polling is the honest mechanism."*
3. The scan runs; the Reconciler sees changed mtime/size/hash.
4. The app commits.

Consequences to accept deliberately: **commits are machine-made and batched** (eight saves in
fifteen minutes is one commit, with no message from you); **a `.git` folder appears** in each project
and deleting it in Finder silently destroys the history; **there is no conflict protection** —
two machines editing is still last-writer-wins, exactly as today.

### 7.2 Settle detection — required, not optional

A slicer writing a 200 MB 3MF takes tens of seconds. A scan landing mid-write would commit a
**truncated file as a legitimate version**.

**A file is eligible to commit only when settled**: identical size and mtime across two consecutive
observations. Anything unsettled waits for the next tick. This is a correctness requirement and must
be designed in, not discovered.

---

## 8. What changes in the maker layer

### 8.1 `:in_working_tree` must be relaxed — deliberately, and narrowly

`Maker::AttachToProject#refusal_for` returns `:in_working_tree` **unconditionally**, and
`Maker::ProjectIntake` asks it for every loose file at a project's root
(`project_intake.rb:706`). Making every project folder a working tree would therefore switch off the
intake sweep **for every project** — §14f's whole feature.

The refusal exists because *moving a tracked file is a delete plus an untracked add* **when the app
is not the one committing**. Once the app performs the move *and* the commit, git records a rename.

**New rule:** refuse for repos the app does not manage; allow-and-commit for project repos it does.
The distinction must be stored, not inferred — a marker in the repo (a config key written at init)
rather than "is this under `Projects/`", so a maker who drops their own repo into `Projects/` is
still protected.

### 8.2 Preview rows

§14b collapsed `Maker::Preview` to one row per `(user, node, kind)` **because** one-row-per-version
leaked a row and a blob on every save. Per-version thumbnails must not undo that.

**Historical renders are generated on demand** — when History is opened, never on save — and cached
with retention. The leak was *eager generation*, not the existence of old thumbnails.
`GeneratePreviewJob#commit_if_current` is untouched: the current row still repoints, and a historical
render must never be able to claim it.

---

## 9. Open questions

Each names its fallback, so none of them blocks a start.

### 9.1 Consolidation — BLOCKING, and §4.1 reversed the earlier answer

rugged documents **no packbuilder, repack or gc** (verified against its README, 2026-08-27).

An earlier draft of this section ranked **"defer consolidation and measure"** first, on the reasoning
that it degrades slowly and visibly. **§4.1 measured it and that is wrong.** Unconsolidated, a
1,500-commit project needs **11,287 GETs to hydrate on s3** and 11,310 metadata round trips over SMB,
*every time a container starts cold* — against 3–5 requests packed. That is not slow degradation, it
is the exact access pattern §2.2 records every git host refusing to serve from object storage.

**So consolidation is required from day one, which promotes rugged's missing packbuilder from a
maintenance-phase gap to a blocking dependency.** That dependency has now been spiked and resolved.

#### The minimal Ruby pack writer — BUILT AND VERIFIED (2026-08-27)

`2026-08-27-git-tracked-projects-packwriter.rb`, committed beside this file. ~70 lines: a per-object
type+size varint header, zlib data, trailing SHA-1, and a sorted idx v2. Deltas are **optional in the
pack format**, so an undeltified pack is a valid pack. This is the easy half of the packfile problem —
*reading* deltified packs is the hard half, and this design never needs it, because it only ever
reads packs it wrote.

**Verified by real git, not by inspection.** Objects were packed, then **every loose object deleted**,
so git had nothing but the Ruby-written pack to read:

| check | 254 objects | 11,214 objects |
|---|---|---|
| OIDs recomputed independently | 254/254 match git | — |
| `git verify-pack -s` | non delta: 254 | non delta: 11,214 |
| `git fsck --full --strict` | **clean** | **clean** |
| history walkable | 40 commits | 1,501 commits |
| content readable | blob + tree + annotated tag | blob from 900 commits back |
| `git clone` | **succeeds** | — |

**Performance is a non-issue.** 11,214 objects took **0.86 s** end to end (0.67 s reading loose,
0.18 s writing the pack). A real consolidation window is ~150 objects, i.e. single-digit
milliseconds.

**The cost is 5× on bytes**, measured on the 1,500-commit repo: 3.9 MB undeltified against 784 KB
from `git gc`. (On the small repo it was only 1.2× — deltas earn their keep as history deepens, so
5× is the figure to plan with.)

**That is acceptable here, and §5 is the reason.** Five times *small* is still small: 3.9 MB to
hydrate across 3 files, against 11,287 requests unpacked. It is only tolerable because binaries are
pointers — if meshes were tracked as content, a 5× penalty would be fatal. §5 and this section hold
each other up, and weakening either one breaks the other.

**Swappable later, and nothing above it changes.** If the 5× ever matters, the fallback is `gix` for
packing only, as a Rust helper binary alongside rugged. It buys real delta compression at the cost of
two git implementations in one repo — which is why it is the fallback and not the plan.

**The premise is verified, not inferred.** rugged 1.9.6 was built and introspected (§3.1): zero
pack/repack/gc methods across `Rugged::Repository`'s 69, and `Packbuilder`, `Indexer` and `Odb`
undefined. The writer is required, and there is no rugged-shaped shortcut to look for later.

### 9.2 Cold hydration cost — RESOLVED, see §4.1

Measured. **Packed, it is a non-issue**: ~1.1 MB across 3–5 files for a 1,500-commit project, copying
in under a millisecond locally. The ephemeral-cache design holds and share-in-place stays an
optimisation rather than the only viable path.

The finding that matters is the one folded into §9.1: it is only a non-issue **because the repo is
packed**, and nothing in rugged packs it.

### 9.3 Commit authorship and messages — decided, revisit if it reads badly

**Default: a bot identity**, not the maker's. These commits are the app's observation that files
changed, not a claim that the user authored a change — and on share the user may genuinely have made
that edit from a machine the app knows nothing about. Attributing it to them is a small lie that
`git blame` would then repeat forever. Message names what changed and when.

Revisit only if `git log` reads unusably in practice; the fix is then cosmetic, not structural.

### 9.4 Init timing — decided

**At project creation**, and for existing projects, at first scan after the feature ships. There is
no history to import, so every existing project starts at one commit containing its current state.

Deliberately **not** user opt-in: a versioning feature nobody turned on protects nobody, and the
failure is silent — you discover it when you needed the history and it isn't there.

### 9.5 The size threshold has no number yet

§5 routes "anything over a size threshold" to a pointer regardless of role. That number is a phase-3
decision and needs measuring against a real library rather than picking a round figure here. Until it
has one, role alone decides, which is the conservative direction — text stays tracked, binaries do
not.

---

## 10. Phasing

The design is one thing; the implementation is not. Suggested order, each independently shippable:

| phase | delivers |
|---|---|
| **1** | The port door (§6) + capability. No git at all. Testable as "write, read and list opaque bytes under the marker on three backends." |
| **2** | Repo lifecycle (§4) + rugged + settle detection (§7.2) **+ the pack writer (§9.1, already built and verified)**. Commits happen; nothing shows them. The writer is in this phase, not deferred — §4.1 shows an unpacked repo is unhydratable on s3 and chunk_remote, so phase 2 without it only works on share. |
| **3** | Track-by-role and pointers (§5). |
| **4** | The GUI — version list, on-demand historical thumbnails, visual A/B for meshes. |
| **5** | `:in_working_tree` relaxation (§8.1), which is the riskiest change and wants the rest working first. |

---

## 11. Sources

- [Forgejo storage settings](https://forgejo.org/docs/latest/admin/setup/storage/) — repositories unsupported in object storage, with reasoning
- [Forgejo #2664](https://codeberg.org/forgejo/forgejo/issues/2664) — minio for git repos
- [JGit on DHT, jgit-dev](https://www.eclipse.org/lists/jgit-dev/msg01189.html) — the DHT failure
- [gitgres](https://github.com/andrew/gitgres) — experimental Postgres ODB, cites the DHT failure
- [libgit2-backends](https://github.com/libgit2/libgit2-backends) — object-level backends
- [gitoxide custom backends discussion](https://github.com/GitoxideLabs/gitoxide/discussions/1281)
- [How GitHub stores and serves git repositories](https://singhajit.com/how-github-stores-and-serves-git-repositories/) — Spokes/DGit
- [Gitaly Cluster](https://docs.gitlab.com/administration/gitaly/praefect/)
- [rugged](https://github.com/libgit2/rugged) — API coverage checked 2026-08-27
