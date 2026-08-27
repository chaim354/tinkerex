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
| **Does NOT cover** | packbuilder, repack, gc are **absent from its documented API** (verified against the README, 2026-08-27) |
| **Cost** | a native extension in the Docker build (cmake) |

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
| **consolidate** | collapse loose objects into a pack | **open, see §9.1** |

**Locking.** Two workers must not operate one project's repo concurrently. `Library::ScanJob`
already enforces one scan per user, which covers the scan-triggered path; any eager path added later
must take the same lock. A ref update is compare-and-swap and a lost update is a lost commit, not
corruption — but the cache directory is not concurrency-safe and must be.

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

### 9.1 Consolidation — the one real unknown

rugged documents **no packbuilder, repack or gc**. Loose objects therefore accumulate: roughly 7
objects per commit (blobs + trees + commit), ~20 commits/day/project, and nothing collapses them.

Cost is not the issue — that is ~140 small PUTs/day/project on s3, fractions of a cent. The issue is
that a repo with 100k loose objects is slow, and syncing it means 100k files.

Three ways out, in preference order:

1. **Defer.** Ship without consolidation and measure real growth first. Viable precisely because it
   degrades slowly and visibly rather than breaking.
2. **A minimal Ruby pack writer.** Writing an *undeltified* pack is genuinely small — header,
   per-object type+size varint, zlib data, trailing SHA — and git reads it fine, since deltas are
   optional in the format. This is the easy half of the packfile problem; *reading* deltified packs
   is the hard half and we never need it.
3. **`gix` for packing only.** A Rust helper binary alongside rugged. Two implementations for one
   repo is ugly and is the last resort.

### 9.2 Cold hydration cost

Unmeasured. For a text-plus-pointers repo it should be small, which is precisely why §5 keeps
binaries out. **Spike it before committing to the ephemeral-cache design** — if hydration is slow,
share-in-place stops being an optimisation and becomes the only viable path.

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
| **2** | Repo lifecycle (§4) + rugged + settle detection (§7.2). Commits happen; nothing shows them. |
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
