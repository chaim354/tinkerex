# Edit and commit files in a git repository the maker brought

`tinkerex#178`. Supersedes `tinkerex#161`, which was reverted whole in `c3b2430` before any of this
was written. **Read part 2 before changing the approach** — four shapes were rejected with evidence.

> **Citation convention.** A bare `§` is **CLAUDE.md** — that is what code comments in this repo mean
> by one. This document's own sections are cited as **part N**.

| | |
|---|---|
| Issue | `tinkerex#178` (`bin/log show 178`) |
| Reverted predecessor | `tinkerex#161`, revert `c3b2430`, table drop `dc1a847` |
| Reference material still on disk | `docs/superpowers/specs/2026-08-27-git-tracked-projects-*` |

---

## 1. What this is

A maker has a git project. They drop it in the share. They want to read it in tinkerex, make a small
edit, and commit it — without leaving the app.

**In scope**

- Adopt repositories the maker brought. No repository is ever created by this app again.
- An editable source view for text files **inside a working tree**.
- **Save** — writes the file through the port, reusing the node.
- **Commit** — a separate action, batching pending saves under one message, with an inline
  diff and per-hunk revert.

**Out of scope, deliberately**

- Any history UI — a commit list, blame, commit-vs-commit compare. Its own issue.
- A full staging panel over everything `git status` sees. `tinkerex#178` flags it as materially
  bigger and it is.
- Version history for projects with **no** repository. `tinkerex#178` carves it out explicitly, and
  part 9 depends on that carve-out holding.
- Any automatic commit. Every commit is user-initiated. There is no sweep, no recurring job, no
  15-minute tick.
- Branching, merging, remotes, push, pull, stash, tags.

---

## 2. The shapes that were rejected, and why

**An app-created repository per project, committed by a sweep** — `tinkerex#161`, reverted. Measured
against the real library: the app-created repositories were almost entirely pointer files (catan 57
of 58 tracked, jewelry-box 17 of 18), and on share the bytes those pointers named no longer existed,
so the history recorded that something changed and could not show it. On the two repositories the
maker actually brought, honouring `.gitignore` left nothing to commit but `.DS_Store` and a local
settings file — both of which this app refuses everywhere else. Git is right for code-shaped projects,
which the maker already has as repositories, and wrong for the asset-shaped ones the sweep was
creating repositories for.

**Committing on every backend, via a hydrated cache** — rejected here, and it is the bulk of what
`tinkerex#161` built. `s3` and `chunk_remote` have no filesystem to hand to git, so rugged can only
run against a materialised copy. `tinkerex#161` measured that at **11,287 GETs on a cold container**
for an unpacked repository. See part 9 for the one form of this that is still worth wanting, and what
blocks it.

**Editing files that are not in a repository** — rejected for this design. §14a: share and s3 are
current-state only, so a save there destroys the previous bytes and there is no version table to
recover from. Inside a repository, git is the undo. Outside one, the answer to "can I get that back"
would depend on which backend is deployed — one condition with two answers, the shape §14a spends
five bullets warning about. This becomes available the moment the version story `tinkerex#178`
carved out exists.

**Marking app commits** — a distinct author, or a trailer. Right for `tinkerex#161`'s automatic
sweep; wrong now that a human chooses the files, writes the message and presses the button. A
distinct author misattributes deliberate work to a machine and breaks `git blame` as a way of asking
who decided something. A trailer is unremovable once it is in history.

---

## 3. Architecture — two write doors

The single idea to carry: **bytes the catalog tracks go through the port; bytes git owns never do.**

### 3a. Save goes through the port

`FileLayer.current.write(user, parent_node_id:, name:, io:, replace: true)` on share and s3; the
two-phase `begin_upload`/`put_chunk`/`finalize_upload` pair on chunk_remote, which is the shape
`Maker::Addons::LibraryOutput` already proves on every backend.

`replace: true` is load-bearing and already carries its own §14a rule: **it must reuse the existing
node.** A replace written as delete-then-create passes any bytes-oriented test while orphaning every
attachment, BOM link and tag — nothing errors, nothing logs.

### 3b. Commit bypasses the port entirely

rugged writes blobs, trees, the commit and the ref straight into `<repo>/.git/`.

It **must** bypass the port: `FileLayer::Share#observable!` refuses any destination at or beneath a
`.git` marker (`Library::RepoMetadata.marker_prefix`), so a port write there fails by construction.

It **safely can**: `Library::Scanner` declines the descent into `.git`, so a write there produces no
observation, therefore no node, therefore no ghost — and therefore none of §14b's four skip-list
wedges, whose signature is a permanent scan refusal.

> **This asymmetry is the thing most likely to be "tidied" later.** A future reader will notice the
> commit path skips the port and route it back through. It fails immediately, which is the good case;
> the rule above is written down so it does not get argued about first.

### 3c. One new capability: `local_worktree`

`FileLayer::Capabilities` is a `Data.define` with six members today. This adds a seventh.

> **Is the library a real filesystem this process can hand to git in place?**

| | share | s3 | chunk_remote |
|---|---|---|---|
| `local_worktree` | **true** | false | false |

Named for the question it answers, not for who says yes today — CLAUDE.md §14a records `port_writable` as "the
single most-misread name here". It agrees with **no** existing capability (`scannable` is true for
s3; this is not), so there is no coincidence to mistake for an identity, which is the warning §14b
attaches to `scannable`/`port_writable`/`dir_deletable` agreeing across three backends.

**Never `is_a?(FileLayer::Share)`.** §14b records that class check as what would have made
`Library::ScanJob` answer false for S3 and silently never index the library. Widening commits to
another backend later must be a new *answer*, never a rewrite. See part 12 for why this one cannot be
mutation-checked behaviourally.

---

## 4. Eligibility — where the affordance appears

`Library::WorkingTree.root_for(node)` walks ancestors for a live child directory named `.git` and
returns **that directory's parent** — the repository root node — or nil.

This is `Maker::AttachToProject#in_working_tree?` **moved, not copied**: that method answers a
boolean, this answers the root, and `AttachToProject` is rewritten to ask this one and compare
against nil. §14d: a verb more than one caller performs gets a named service. Its existing rules come
with it — `present` and `kind: "dir"` are both load-bearing (a tombstoned `.git` is not a working
tree; a `.git` **file** is a submodule or linked-worktree pointer and is deliberately not a marker),
the ancestor walk stays capped at `MAX_ANCESTOR_WALK`, and the per-parent memo stays, because
`Maker::ProjectIntake` sweeps every file at a project root through it.

**Projects are irrelevant to eligibility.** `Maker::ProjectDiscovery` only adopts folders directly
under `Projects/`, so keying on projects would exclude `Code/TheFlightWall_OSS` — one of the two real
repositories `tinkerex#178`'s evidence was measured against — and would make "drop your repo in the
share and it works" depend on where you dropped it.

**The four repositories the old sweep created become ordinary repositories by doing nothing.**
Nothing reads the `tinkerex.managed` config key any more; there is no "ours" versus "theirs"
distinction left to maintain, and none is to be reintroduced.

---

## 5. Data model

One table.

```
maker_repo_edits
  user_id             bigint, FK, indexed
  repo_root_node_id   string   -- the .git marker's PARENT
  node_id             string   -- the edited file
  timestamps
  unique index (user_id, node_id)
  index (user_id, repo_root_node_id)
```

**No stored path.** The catalog is the one source; the path is recomputed on read via
`Maker::LibraryTree#path_for`. A stored path would let the table disagree with the library the moment
a node moved, and there would be no way to tell which was right.

Like `maker_file_attachments`, `node_id` is a bare string with no foreign key — the same population
and the same precedent, including `Maker::AttachmentReaper`/`Maker::DeadNodes` for rows whose node is
gone for good. **Reconciliation on open (part 6 step 5) is the correctness mechanism**, not the reaper;
the reaper is housekeeping.

Rows are written only where `local_worktree` is true. On the other backends a save is just a save,
and a row would be state nothing could ever clear.

---

## 6. The flow

1. **Open a text file.** `Library::WorkingTree.root_for(node)` → repository root, or nil. Nil means the
   view stays read-only exactly as today: no affordance, no error, no explanation needed. This is most
   of the library.

2. **The view mounts editable**, through `Compartment` — already exported from
   `vendor/javascript/codemirror-entry.js`, whose own comment records it was kept for "the deferred
   editing arc". Two hard preconditions:
   - a text role, by `Maker::FileAttachment::ROLE_BY_EXT` / `TEXT_ROLES` — the one vocabulary, never a
     second table (§14d);
   - **the fetch was not truncated.** `codeview_controller` reads at most `MAX_BYTES` (200,000) and
     appends `… (truncated)`. Saving that buffer would truncate the file. Over the cap is read-only.

3. **Save** POSTs the text and the `content_token` the editor loaded with.
   - The server re-reads the file's current token. **Mismatch → refuse, nothing written**: the maker
     edited it elsewhere meanwhile, and last-write-wins would destroy that edit silently and, on share,
     irrecoverably.
   - Match → the part 3a port write. Then upsert one `maker_repo_edits` row, where `local_worktree`.

4. **The page reports pending work** — "2 pending changes in ESPHome-Projection-Clock". Where
   `local_worktree` is false it says instead that the edit will sync down to the machine holding the
   repository, where the maker commits with their own git.

5. **Review** reconciles every pending row against git rather than trusting it:
   - path recomputed from the catalog; row dropped if the node is gone or has moved out of this
     repository;
   - **content compared against HEAD's blob** — never a stat comparison (part 8);
   - identical to HEAD → row dropped, they committed it elsewhere;
   - `Rugged::Repository#path_ignored?` → listed, **not committable**, with the reason. Silently
     omitting a file the maker can see is the gap; git itself requires `-f`.
   - Other dirty paths are **counted, never listed** — "4 other changes in this repo, not included" —
     so the box never misrepresents the repository while staying out of staging-panel scope.
   - The diff is `@codemirror/merge`'s `unifiedMergeView`: inline, still editable, one revert button per
     hunk. A revert is another Save through the same door — there is no second write path.

6. **Commit.**
   - Tree = **HEAD's tree with the selected paths replaced.** Read the existing tree, replace those
     entries, write the new trees up to the root.
   - Parent = HEAD. Unborn HEAD is **allowed**: an ordinary first commit with no parents.
   - Author = repo-local `user.name`/`user.email` if both are set. **`Rugged::Config.global` reads the
     *container's* config and is meaningless here**, so there is no second git source to fall back to.
     The fallback is the tinkerex account: `users.email`, with the address's local-part as the name —
     **checked against `db/schema.rb`, `users` has no name column**, only `email`. If it ever grows one,
     that becomes the name, and this line is the reason to change it.
   - Ref updated **compare-and-swap** on its old target.
   - Index updated **for the committed paths only**.
   - The committed rows are deleted.

> **`index.clear` must never be written.** It is what the reverted code did, and it turns "commit these
> two files" into "commit whatever is lying around the maker's working tree". The symmetric error is
> leaving the index untouched, which leaves the committed paths reporting as modified in the maker's own
> `git status`. Read it, update those entries, write it back.

---

## 7. Refusals

Every one is decided **before** anything is written.

| Condition | Answer | Why not something else |
|---|---|---|
| No `.git` marker | no Edit affordance | Not an error — this is most of the library |
| Not a text role, or buffer truncated | read-only | Saving a truncated buffer truncates the file |
| `local_worktree` false | Save yes, Commit absent | Their own machine has real git on that repository |
| `content_token` changed since load | **refuse the save** | Last-write-wins destroys the other edit silently; unrecoverable on share |
| A `.lock` file present | refuse, **never delete** | part 8 |
| Detached HEAD | refuse the commit | Committing there makes work nothing references |
| Merge / rebase / cherry-pick in progress | refuse the commit | Half-finished operations belong to real git, not a web form |
| Unborn HEAD | **allowed** | An ordinary first commit. Not an edge case to refuse |
| Path ignored by `.gitignore` | listed, not committable | Silent omission is the gap; git needs `-f` |
| Ref moved under us | refuse, re-show | Compare-and-swap. Two commits must not lose one |
| Share unmounted | `FetchError` → 503 | Existing mapping. Never `NotFound`, which reads as "your file is gone" |
| `.git` is a **file** | no affordance | `RepoMetadata`: the rule is a *directory* named `.git`. Inherited deliberately |

---

## 8. The share backend is a **network** filesystem

`share` is a NAS over SMB/NFS (§2 of CLAUDE.md). The argument for commits being share-only is that
share is a real filesystem — and git's assumptions about filesystem semantics are exactly what does
not hold reliably over a network. This repository has already paid for that once: §14a records
`File.writable?` being the wrong writability check because it tests POSIX mode bits, "wrong under
exactly the NFS/SMB ACLs this backend targets".

That is an assumption to harden, not a conclusion to reverse — the alternative is hydration, which is
worse on its own terms (parts 2 and 9). Four rules follow.

1. **Never trust git's stat cache for our correctness.** Attribute caching over NFS/SMB can make a
   stat-based "unchanged" answer wrong. Part 6 step 5 compares **content against HEAD's blob**; this makes
   that an invariant with a reason rather than an accident someone later optimises into a stat check.

2. **A lock file present → refuse, never delete.** `index.lock` or a ref `.lock` means another git may
   hold this repository, or a crashed one left it behind. Deleting another process's lock is how
   repositories get corrupted. Refuse with an operator-facing message naming the file.

3. **Keep the write window two operations wide.** Objects are content-addressed and safe to write
   early. Only the ref update and the index update need locks; do everything else first.

4. **Probe libgit2's locking on the real mount before the PR.** Whether `O_CREAT|O_EXCL` is atomic
   depends on the mount and the protocol version — NFSv3 is the notorious case. This is measurable on
   the actual Unraid share and unmeasurable by reasoning. Folded into part 11's gate.

**If the probe comes back bad**, the fallback is not hydration. It is to commit only when no lock is
present and the mount passes a write-then-read-back check — the same touch-probe shape §14a already
uses at boot, for the same reason.

---

## 9. Road not taken: git on s3 without a filesystem

Recorded so the next session does not re-derive it. **Also to be added to `docs/roads-not-taken.md`**,
whose own header rule is to read it before reviving any of these.

Prompted by Cursor's "Git at any scale" (their Continuity platform). What that architecture actually
is: a **normal git repository on fast local NVMe serving every read**, with a write-ahead log in S3
underneath as the durable source of truth. It is a durability and replication layer *under* a local
repository, not a way to run git without one — a replica with no local copy **materialises it from the
WAL**, which is the hydration step by another name. Their answer to hydration cost is not the WAL: it
is that the WAL carries **packfiles**, and only the primary repacks.

**`tinkerex#161` had already reached that central insight independently** — measured, packed: ~1.1 MB
across 3 files, sub-millisecond; unpacked: 11,287 GETs — which is why it put consolidation in the
commit loop rather than in a background tidy-up. Stated plainly, because the revert could be misread
as repudiating all of it: **the reverted design's storage thinking was right. Its product model was
what was wrong.**

Three things worth taking if this is ever revived:

1. **S3 conditional GET / CAS.** A metadata-only conditional GET is under 10 ms, and compare-and-swap
   on an index object gives linearizable updates with no lock and no lease. A cleaner atomicity
   primitive than anything `tinkerex#161` had, and plausibly newer than its design work.
2. **Packs are the unit, never loose objects.** The 11,287-GET figure *is* the loose-object tax.
3. **The warm-cache / source-of-truth split** — a sharper framing of "ephemeral container cache".

**The smaller idea that needs no WAL, and the thing that blocks it.** A commit is a *partial* read of
the DAG: the ref, the HEAD commit, and the trees along the path to each changed file. Two files at
depth three in a 2,305-file repository is roughly 8 objects read and 8 written, not 11,287. The
blocker is the physical-versus-logical mismatch that article names: in a real repository those objects
sit inside a packfile, delta-compressed, so an individual object cannot be fetched — it needs the
`.idx`, range requests into the pack, and delta-chain reconstruction. And **rugged cannot help**:
`tinkerex#161` verified `Rugged::Backend` exposes zero methods and `Odb`, `Indexer` and `Packbuilder`
are undefined, so there is no custom object database to plug in.

**None of this bears on chunk_remote.** The reason not to commit there was never cost: the maker's own
machine has that repository checked out with real git, and a server-side commit moves refs under a
live working copy. A WAL does not fix a racing checkout. `local_worktree` is the seam any of this
would plug into.

---

## 10. Components

**New**

| | |
|---|---|
| `app/services/library/working_tree.rb` | walk to the nearest `.git`, return the root node |
| `app/services/maker/git/local_repo.rb` | `Maker::Git::LocalRepo` — open a repository, status-for-paths, lock and state checks |
| `app/services/maker/git/commit_paths.rb` | `Maker::Git::CommitPaths` — HEAD's tree with selected paths replaced; ref CAS; index update |
| `app/models/maker/repo_edit.rb` + migration | part 5 |
| `FilesController#update` | Save |
| `RepoCommitsController` | review + commit, session-authed (§14d: never the v1 API) |
| `app/javascript/controllers/editor_controller.js` | editable mount, dirty tracking, save |
| `@codemirror/merge` in the bundle | part 13 |
| `local_worktree` in `FileLayer::Capabilities` | part 3c |

> **The names deliberately avoid every filename `tinkerex#161` used, and must keep doing so.** That
> revert removed `maker/git/repo.rb`, `project_commit.rb`, `commit_info.rb`, `pack_writer.rb`,
> `text_diff.rb`, `tracking.rb` and `version_history.rb`, all still reachable on
> `claude/git-phase5-refinement`. Had this reused `repo.rb`, a `git checkout <branch> -- <path>` would
> **overwrite** the new class with a 583-line one built for a model that no longer exists; at a
> different path the same command lands a visible second file instead. `CommitPaths` also names the
> safety property in the class itself — it commits *paths*, never the working tree (part 6).

**Changed**

- `Maker::AttachToProject` — asks `Library::WorkingTree` instead of owning the walk.
- `codeview_controller.js` — read-only stays the default; editable is opt-in per part 6 step 2.
- `vendor/javascript/codemirror-entry.js` and `bin/build-codemirror` — part 13.

**Reused, not rebuilt:** `write(replace: true)`; `Maker::Addons::LibraryOutput`'s two-phase shape;
`Library::RepoMetadata`, untouched; `Maker::LibraryTree#path_for`; the `FetchError` → 503 and
`UnsupportedOperation` → 422 mappings.

**Deliberately not rebuilt from `tinkerex#161`:** the ephemeral container cache, `repo_data_dir`, the
list/read/write repo-data port verbs, the pack writer, the repack job, `tinkerex.managed`,
`maker_git_repos`, `maker_version_previews`. All of it existed to make git work where there is no
filesystem; `local_worktree` says there is not one instead.

---

## 11. Testing

**Mutation checks.** §15: a guard that has never failed has not been shown to work. Each is named with
the change that must turn it red.

| Break this | Must go RED |
|---|---|
| tree build → `index.clear` + add_all | **The one that matters most.** Commit two edited files with a third dirty file present; assert the third is *not* in the commit. The reverted code's exact bug |
| drop the `content_token` check | Save with a stale token: refused, file unchanged on disk |
| drop the truncation check | A file over `MAX_BYTES` is not editable; a truncated buffer cannot be saved |
| drop the ref compare-and-swap | Two commits racing one ref; neither lost silently |
| `replace: true` → delete-then-create | `node_id` survives a save carrying an attachment and a tag |
| route the git write through the port | Fails immediately — `observable!` refuses `.git`. Proves part 3b is structural |
| leave the index untouched after commit | Committed paths report clean to a real `git status` |
| delete a stale `.lock` instead of refusing | part 8 rule 2 |

**The three backend legs report identical run counts.** Commit is share-only, but its tests **run
everywhere**, in a shared contract gated on `local_worktree?` — exactly as
`test/services/file_layer/adapter_mutation_contract.rb` is gated on `dir_deletable?`. On s3 and
chunk_remote they assert the **absence** of the affordance and that **Save still works**. They do not
`skip`: §14e, a guard that skips on the thing it asserts is vacuous.

**The wedge check — highest consequence, silent failure.** After a commit, run a full
`Library::Scanner` pass and assert **no node exists anywhere under `.git`**, the scan does not raise
`Scanner::UnsafeScan`, and the mass-deletion guard does not trip. §14b records four skip-list wedges,
each found only after the previous explanation said it could not happen, and a wedge refuses that scan
and every scan after it, permanently. The most important assertion is the **absence** of a row.

**Real repositories, not fixtures.** Build them with rugged in a tmpdir: commits, a `.gitignore` that
excludes a lot, a tracked-modified file, an untracked file, a binary file, and a repository with no
commits at all.

**A system test that actually types and saves.** Two silent-failure modes make this non-optional: a
Stimulus identifier that resolves to nothing is a no-op with no console warning (§14d — nine days,
once), and two copies of `@codemirror/state` make CM6 ignore an extension with no error at all. Only a
browser proves the diff rendered. `test/stimulus_hygiene_test.rb` picks up the new controller without
a test edit.

**Query budget.** `test/integration/web/page_query_budget_test.rb`: the file page's query count stays
**constant in the repository's size**. Asserted as constant, never a literal — the counts differ per
backend.

**A structural guard**, because one mutation cannot be caught behaviourally: see part 12.

### The gate `bin/ci` cannot provide

`tinkerex#161` was green through eight merged PRs while being wrong about the real library. Before the
PR opens, on the share deployment, against the two repositories the maker actually brought —
`TheFlightWall_OSS` and `ESPHome-Projection-Clock`:

1. edit, save, review, commit;
2. `git log`, `git status` and `git fsck` in a terminal on the box;
3. the part 8 rule 4 locking probe;
4. a `Library::ScanJob` tick afterwards, confirming no `UnsafeScan` and no nodes under `.git`.

Probe over argument (§14e).

---

## 12. The mutation no behavioural test can catch

Swapping `local_worktree?` for `is_a?(FileLayer::Share)` gives the **same answer on all three backends
today**, so every test in part 11 stays green. Stated rather than papered over.

It needs a **structural** guard in `test/architecture_invariants_test.rb`: zero adapter class-checks in
the git code — the same instrument §14d uses to assert zero `Sync::` references with no allowlist. Per
§15, assert the narrowest true thing and mutate to prove each assertion carries weight: a mutation that
keeps a count while *moving* a reference is caught only by the second assertion.

---

## 13. `@codemirror/merge`

Measured in a scratch tree on 2026-08-28, not assumed:

| | |
|---|---|
| version / licence | **6.12.2, MIT** — CLAUDE.md §9 clean |
| duplicate `@codemirror/state` or `@lezer/*` | **none** — dedupes against the pinned 6.7.1 |
| bundle | 933,768 → **953,757** bytes (+19,989, +2.1%) |
| gzipped | ≈324,586 → **331,716** bytes (+7,130, +2.2%) |

The base rebuild reproduced the committed artifact **byte for byte** (sha256-identical), so the delta
is merge alone, and the pinned tree is genuinely reproducible rather than aspirationally so.

> **CORRECTED AFTER BUILDING IT.** This table first read +28,406 / +9,597, and that figure was
> measured against a **different export surface than this design ships**: the probe exported
> `MergeView` and `acceptChunk` as well, and the entry file exports only `unifiedMergeView`,
> `getChunks` and `rejectChunk`. esbuild tree-shakes the two-pane `MergeView` out, which is ~8.4 KB
> of the difference. Re-probed both ways against the same pinned tree: `export *` gives 963,132 and
> the three named exports give 953,757. The rule was right and its evidence was measured against
> the wrong thing — the failure this repo's own preamble records about its `§` reference counts.
> Raw bytes are the number to trust: an ad-hoc `gzip -9 -c` embeds the input filename in its header,
> so gzipped figures wobble by a byte or two between a scratch copy and the build script's own path.

**It goes into the vendored bundle, never a per-package importmap pin.** Add the export to
`vendor/javascript/codemirror-entry.js`, add the newly resolved versions to `bin/build-codemirror`'s
pin list — **the whole resolved tree, re-derived by the recipe in that file's header**, not the direct
packages — and rebuild. `test/ci_hygiene_test.rb` fails the build if a `pin "@codemirror/..."` line
appears. Two copies of `@codemirror/state` make CM6 ignore an extension silently.

**Rebuilding twice and comparing digests does not prove reproducibility** — `bin/build-codemirror`'s
own header says so: the registry does not move in two minutes. Only enumerating resolved versions does.

**One naming trap to carry into the UI.** CM6's accept/reject vocabulary is worded for merging a change
*in*. Here the original is HEAD and the document is the working tree, so "accept" means **revert**. It
is easy to ship backwards and a screenshot will not show it.

---

## 14. Consequences, stated rather than fixed

- A maker who edits two files in tinkerex and one in vim commits the third with their own git. The
  "4 other changes, not included" line is what keeps that from being a surprise.
- A loose `notes.md` outside any repository is still not editable. That is part 2's rejected shape and it
  reverses the day a version story exists.
- Binary files in a repository can be saved but show no diff. `unifiedMergeView` is text-only.
- On chunk_remote the maker gets the editor and no commit button. The edit reaches their machine by
  ordinary sync.
- Nothing here reaches `Sync::`, the changelog, conflicts, locks or the mounts (§14j).

---

## 15. Candidate invariants

For `docs/invariants/git-editing.md` with a stub under a new §14 anchor in `CLAUDE.md`, per §14's own
rule that an invariant binding one area is loaded when it applies rather than skimmed every session:

1. Bytes the catalog tracks go through the port; bytes git owns never do (part 3).
2. `local_worktree`, never `is_a?(FileLayer::Share)` (parts 3c and 12).
3. `index.clear` is never written; the index is updated for committed paths only (part 6).
4. Content against HEAD's blob, never a stat comparison (part 8 rule 1).
5. A lock file is refused, never deleted (part 8 rule 2).
6. A truncated buffer is never editable (part 6 step 2).
7. `Library::WorkingTree` is the one definition of the ancestor walk (part 4).
8. No file under `app/services/maker/git/` reuses a name `tinkerex#161` used (part 10).
