# History and restore for adopted git repositories

The remainder of `tinkerex#178`, after the edit/save/commit slice shipped (PR #281, #282, #283).

> **Citation convention.** A bare `§` is **CLAUDE.md**. This document's own sections are **part N**.
> The shipped slice's design is `docs/superpowers/specs/2026-08-28-edit-and-commit-in-a-repo-design.md`,
> cited as **the commit spec**.

| | |
|---|---|
| Issue | `tinkerex#178` |
| Depends on | `Maker::Git::LocalRepo`, `Maker::RepoEdit`, `Library::WorkingTree`, the commit box |
| Scope chosen | **read + restore**, **both surfaces**, file-first |

---

## 1. What this is

A maker looking at a file in a repository they brought can see what happened to it, look at an old
version, diff it against what is there now, and put it back.

**In scope**

- **File history** — the commits that touched this path, on the file page.
- **Repository history** — a commit list for the whole repository, on its own page.
- **View** a file's content at a commit.
- **Diff** a commit's version against the working tree, reusing the inline diff already built.
- **Restore** — write that old content back as a pending edit, which then flows through the existing
  Save → commit box path. No second write mechanism.

**Out of scope**

- Commit-vs-commit compare (side-by-side `MergeView`). The bundle can do it; nothing here needs it,
  and it is a second diff surface to design.
- Blame, branch switching, checkout, merge, push/pull.
- Rename following — see part 6, stated as a limitation rather than silently absent.
- Version history for projects with **no** repository. Still its own design (the commit spec, part 2).
- Any change to the staging-panel scope: the commit box still lists only what tinkerex edited.

---

## 2. Two corrections to the reasoning that led here

Recorded because both were mine, and one was load-bearing in an argument I made to the user.

**"A repo-wide commit list for `catan` opens on 58 commits of pointer churn."** False. Measured on
the live share deployment on 2026-08-30:

| repo | commits | dirty paths |
|---|---|---|
| catan | **1** | 58 |
| jewelry-box | **2** | 18 |
| laser-mount | **1** | 16 |
| test2 | **1** | 1 |
| TheFlightWall_OSS | **333** | 5 |
| ESPHome-Projection-Clock | **12** | 2 |

The 58 was **dirty working-tree paths**, not commits. The four sweep-created repositories have almost
no history at all, and history never shows uncommitted noise. That argument was one of three reasons
given for preferring the file surface; it should not have been offered, and it is not relied on here.

**"The pointer/content distinction from `tinkerex#161` will matter."** It does not, for the same
reason: those repositories have one or two commits each. `tinkerex#161`'s `VersionHistory` needed
`available` because the app was *creating* pointer history; this design creates none. What survives
from that file is its rule, which part 5 adopts: **an unavailable thing is rendered, never hidden.**

---

## 3. The measurement that shapes everything

Taken on the live share deployment, against `TheFlightWall_OSS` (333 commits) over its real CIFS/SMB
mount — `//192.168.1.146/3D Printing`, `cache=strict, actimeo=1, soft, nounix`:

| operation | cold | warm |
|---|---|---|
| full walk, 333 commits | **4,917 ms** | — |
| path-filtered over all 333 | 3,388 ms | — |
| walk capped at 25 | 104 ms | 1 ms |
| walk capped at 50 | 89 ms | 5 ms |

~15 ms per commit cold is a network round trip per object; the repository is one packfile plus 256
loose-object directories. **Two rules follow, and neither is an optimisation.**

1. **THE WALK IS ALWAYS CAPPED.** An uncapped walk is ~5 s on a 333-commit repository, and 333
   commits is small. Nothing may offer "all history".
2. **HISTORY LOADS ASYNCHRONOUSLY, NEVER IN THE PAGE RENDER.** A cold capped walk is ~100 ms and a
   cold deep one is seconds; the file page must not wait on either. It is fetched after render, the
   same shape `codeview_controller` already uses for file bytes.

**A third consequence, and it is a product decision rather than a perf one.** Path filtering is
sparse: only **1** of the last 50 commits touched `README.md`, while **28** of all 333 did — roughly
one in twelve. So a capped walk can legitimately find nothing. **It must never say "no history".**
It says *"no changes to this file in the last N commits"* and offers to look further. Saying "no
history" for a file with 28 changes is the same class of lie as hiding an unavailable version.

---

## 4. Architecture — one walker, two questions

`Maker::Git::History`, constructed from a `Maker::Git::LocalRepo`.

```
Maker::Git::History.new(local_repo)
  #for_repo(limit:, walk_limit:)          -> Result
  #for_path(rel, limit:, walk_limit:)     -> Result
  #blob_at(oid, rel)                      -> String or nil
```

**BOTH QUESTIONS COME OFF ONE WALK, FROM DAY ONE, even though the file surface is what the maker
reaches first.** The alternative — build the file surface now and a repository one later — produces
two walkers that disagree about ordering, caps and what "stopped early" means. The repository
question is the cheap one (no per-commit tree lookup at all); the path question adds one tree lookup
per commit walked. Sharing the walk costs nothing and forecloses that divergence.

```ruby
Entry  = Data.define(:oid, :message, :author_name, :author_email, :time)
Result = Data.define(:entries, :walked, :stopped) # stopped: :exhausted | :limit | :walk_limit

DEFAULT_LIMIT      = 25   # entries returned
DEFAULT_WALK_LIMIT = 250  # commits examined
MAX_WALK_LIMIT     = 2000 # the ceiling "look deeper" cannot pass
```

**THE NUMBERS COME FROM PART 3, NOT FROM TASTE.** At ~15 ms per commit cold, 250 is ~3.7 s worst
case — tolerable only because the fetch is asynchronous, and typically far less because the walk
stops at 25 entries first. "Look deeper" doubles `walk_limit` up to `MAX_WALK_LIMIT`; the ceiling
exists because 2000 commits cold is ~30 s and no amount of asynchrony makes that a good idea.

**Ordering is `Rugged::SORT_DATE`, set explicitly.** The walker's default ordering is unspecified by
libgit2, and a history list whose order depends on an implementation detail will one day reorder
itself for no reason anyone can explain.

**`stopped` IS NOT DECORATION AND MUST REACH THE VIEW.** It is the difference between "this file has
never changed" and "we stopped looking after 250 commits". Only `:exhausted` licenses the word
"none"; the other two must offer to look deeper. Dropping this member is how part 3's third rule
gets undone by someone tidying a "redundant" field.

**Path filtering compares the blob oid at each commit against its first parent's.** Absent in both →
not a touching commit; different → touching. `Rugged::TreeError` for a path a commit does not
contain is an ordinary "absent", not an error.

**FIRST PARENT ONLY.** A merge commit is compared against its first parent, so a change that arrived
through a merge is attributed to the merge rather than listed twice. This matches `git log`'s default
and is stated because the alternative looks more thorough and is noisier.

---

## 5. Surfaces

### 5a. File page — the primary one

A **History** panel below the editor, populated by a fetch after render (part 3 rule 2). Each entry
shows short oid, message subject, author and relative date, with three actions:

- **View** — the file at that commit, read-only, in the existing CodeMirror mount.
- **Diff** — that version against the working tree, in the existing `diffview_controller`.
- **Restore** — part 6.

When `stopped` is not `:exhausted`, the panel ends with the honest sentence from part 3 and a control
that re-fetches with a larger `walk_limit`.

### 5b. Repository page

`GET /repos/:root_id/history` — the same entries without a path filter, reached from the banner the
file page already renders (`.repo-banner`, built in PR #282). **It is reached from something that
already exists**: the missing-entry-point defect in PR #282 is recent enough that a new page without
a door would be the same mistake twice.

Each row links to the commit's changed paths, each of which links to that file's page. There is no
commit *detail* page: the row expands to a path list, and the paths are already routable.

---

## 6. Restore

**Restore writes the old bytes through the port and records a pending edit. It does not commit.**

```
POST /files/:id/restore/:oid
  -> blob_at(oid, rel)                                  the old content
  -> Maker::Addons::LibraryOutput.write_bytes!(replace: true)   the one port_writable? branch
  -> Maker::RepoEdit.record!                            it becomes pending
  -> redirect to the file page
```

The maker then sees it in the commit box, diffs it, and commits it or leaves it. **That is the whole
point of choosing restore-as-a-pending-edit over restore-as-a-commit:** it reuses a path that is
already built, already tested on real data, and already has a review step. A restore that committed
directly would need its own message, its own refusals and its own undo.

**Restore is gated on `local_worktree?`, exactly as committing is** — not because writing needs it
(the port writes on every backend) but because a restore the maker cannot then commit is a trap. On
other backends the History panel still shows and View/Diff still work; only Restore is absent, with
the same sentence the banner already uses.

**A restore that would write identical bytes is refused**, with "that version is already what is on
disk". Writing it would create a pending edit that the commit box immediately drops as `:unchanged`
— a button that appears to do nothing, which is the shape `tinkerex#184` exists to avoid.

**Renames are not followed** (`--follow` has no rugged equivalent; implementing it means detecting
similarity across trees). A file's history therefore starts at its current path. Stated in the panel
when `stopped == :exhausted` and the first commit is an add: *"history for this path begins here; if
the file was renamed, earlier changes are under its old name."* Guessing silently is worse.

---

## 7. Refusals

| Condition | Answer |
|---|---|
| No `.git` marker | no History panel — as today, no error |
| `LocalRepo#committable?` false (lock, detached, operation in progress) | history still shows; **Restore hidden**, with the refusal text |
| `local_worktree?` false | history shows; Restore absent |
| Unborn HEAD (no commits) | "No commits yet in this repository" |
| oid not in this repository | 404 — never resolve an oid from a different repo |
| path absent at that commit | View/Diff say so; Restore absent for that entry |
| Blob over the editable cap | View shows truncated and read-only; **Restore refused** (a truncated restore truncates the file) |
| Binary blob | listed in history; View/Diff/Restore all absent |
| Share unmounted | `FetchError` → 503, existing mapping |

---

## 8. Testing

**Mutation checks, each with its actual output recorded in the commit that introduces it:**

| Break this | Must go RED |
|---|---|
| remove the walk cap | a fixture repository with more commits than the cap: assert `walked <= walk_limit` |
| drop `stopped` from the result | a capped walk that finds nothing must not render "no history" |
| compare against all parents, not the first | a merge commit must appear once, not twice |
| let Restore write identical bytes | the no-op restore is refused |
| let Restore run without `local_worktree?` | absent on s3/chunk_remote |
| resolve an oid from another repository | 404 |
| restore a truncated blob | refused |

**The three legs stay identical.** History tests pin a share library via `GitRepoFixture`, so they
run the same everywhere. The surface-presence tests do **not** pin, and assert absence on the other
two legs rather than skipping (§14e).

**Fixtures must include a repository with more commits than the cap** — otherwise every cap test is
vacuous, which is the shape that made `tinkerex#185` invisible for a week.

**A system test** drives the panel in a browser: history loads, View renders, Diff renders, Restore
produces a pending edit that the commit box then offers. A `data-controller` that resolves to nothing
is a silent no-op (§14d), and the async fetch means a request test cannot see the panel at all.

### The gate `bin/ci` cannot provide

Before the PR is merged, on the share deployment against `TheFlightWall_OSS` (333 commits, the only
repository here with real history): open a file's history, confirm the capped walk returns in well
under a second warm, restore a version, and confirm it appears in the commit box. The performance
numbers in part 3 came from that box and nowhere else.

---

## 9. Files

**New:** `app/services/maker/git/history.rb`; `app/controllers/repo_histories_controller.rb`;
`app/views/repo_histories/show.html.erb`; `app/javascript/controllers/history_controller.js`;
`test/services/maker/git/history_test.rb`; `test/integration/web/repo_history_flow_test.rb`.

**Changed:** `FilesController` (`#history`, `#history_blob`, `#restore`); `config/routes.rb`;
`app/views/files/show.html.erb` (the panel mount); `app/javascript/controllers/diffview_controller.js`
(parameterise the "original" URL so it can diff any commit, not only HEAD);
`app/assets/stylesheets/application.css`; `test/support/git_repo_fixture.rb` (a many-commit builder).

**Not touched:** `Maker::Git::CommitPaths`, `Maker::RepoEdit`, `Library::WorkingTree`, the port, the
capability set. This feature adds a reader and one writer that reuses the existing write door.

---

## 10. Candidate invariants

For `docs/invariants/git-editing.md`, which already holds this area's rules:

1. The history walk is always capped, and the cap is a correctness rule: an uncapped walk measured
   4.9 s on a 333-commit repository over CIFS.
2. History loads asynchronously; it never blocks a page render.
3. `stopped` reaches the view. Only `:exhausted` licenses saying there is no history.
4. Path filtering compares against the **first** parent only.
5. Restore writes a pending edit and never commits.
6. A no-op restore is refused rather than producing an edit the commit box discards.
