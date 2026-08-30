# Editing and committing in a repository

§14a/§14b/§14d material for the git surface a maker sees on a repository they brought into the
library. Written with `tinkerex#178` and kept out of CLAUDE.md because it binds inside one
subsystem: the rules are here, the story is in the spec and in Forgejo (§11). Read this before
touching `app/services/maker/git/`, `app/services/library/working_tree.rb`,
`app/controllers/repo_commits_controller.rb`, `app/controllers/repo_histories_controller.rb`,
`FilesController#update`/`#history`/`#history_blob`/`#restore`, `test/support/git_repo_fixture.rb`,
or `app/javascript/controllers/{editor,diffview,history}_controller.js`.

The first nine rules came from the edit/save/commit slice (PRs #281-#283). The nine after them came
from history and restore
(`docs/superpowers/specs/2026-08-30-git-history-and-restore-design.md`): six are that spec's part
10, two of them carrying the measurement that produced them, and three are findings from building
it — each a fact about git or rugged that reads as tidiable and is not. **None of the nine was
derived by reading the code**, which is why each states what breaks when it is undone rather than
what the code does.

## Bytes the catalog tracks go through the port; bytes git owns never do

The file write is `Maker::Addons::LibraryOutput.write_bytes!(..., replace: true)` — the port, which
REUSES the node. The git write is rugged, straight into `.git`: blobs, trees, the commit, the index.
The two never swap doors. Only the PATH crosses, from `FileLayer::Share#absolute_path` into
`LocalRepo#workdir`.

Both directions fail, and only one of them fails loudly:

- **Routing the git write through the port** stops at `Share#observable!`, which refuses `.git` and
  everything beneath it (`Library::RepoMetadata.marker_prefix`) with
  `NotFound: "…" is a reserved path the library scan does not index`. That refusal is deliberate,
  not an oversight to work around: an unobservable path holding a live node is §14b's wedge, which
  trips the mass-deletion guard and refuses that scan **and every scan after it**.
- **Routing the file write around the port** — a plain `File.write`, or a delete-then-create
  "replace" — orphans every attachment, BOM link and tag on that node, because all of them are keyed
  on `node_id` (§14a). Nothing errors and nothing logs; that is the whole signature.

## Ask `local_worktree?`, never `is_a?(FileLayer::Share)`

`local_worktree?` and `is_a?(FileLayer::Share)` give the SAME answer on all three backends today —
share true, s3 and chunk_remote false — so swapping one for the other changes no behaviour anywhere
and **no behavioural test can go red for it**. The only instrument that can see it is
`test/architecture_invariants_test.rb`'s `test_the_git_surface_never_branches_on_an_adapter_class`,
which scans `app/services/maker/git/**`, `app/controllers/**` and `working_tree.rb`, skips comment
lines, and asserts each of the three arms is non-empty first.

The consequence is §14b's, already paid once: `Library::ScanJob`'s gate WAS an
`is_a?(FileLayer::Share)` check, it answered false for S3, and an S3 library was **silently never
indexed**. Widening commits to another backend is a new ANSWER in `FileLayer::Capabilities`, never a
rewrite of the callers.

## `index.clear` is never written — and the index is never left untouched either

`Maker::Git::CommitPaths` seeds its builder from **HEAD's tree** and inserts only the selected paths;
`refresh_index` then updates only those entries. Three ways to undo that, each with its own damage:

| mutation | what breaks |
|---|---|
| `index.clear` + `add_all` (what `tinkerex#161` did) | "commit these two files" becomes "commit whatever is lying around the maker's working tree". It passes every bytes-oriented test, because the bytes of the selected files are right; what is wrong is everything that came along. |
| leave the index alone after the commit | the index still holds the OLD blob for each committed path, so the maker's own `git status` reports it staged-and-different — the app reads as having half-done something. |
| `Rugged::Tree::Builder.new(repo)` with no source tree | the commit contains only the selected paths and **deletes the entire rest of the repository**. |

The write window is two operations wide on purpose (spec §8 rule 3): objects are content-addressed
and safe to write early, so only the ref update and the index write happen under a lock — and share
is a network filesystem, where the lock is the risky part.

## Compare content against HEAD's blob, never a stat

`LocalRepo#row_for` reads the file and compares bytes with HEAD's blob. Not fussiness — the backend:
`share` is a NAS over SMB/NFS, where attribute caching can make a stat-based "unchanged" answer
wrong. git's own stat cache is an optimisation it can afford because it is talking to a local disk.

A wrong "unchanged" is not a cosmetic error here. `RepoCommitsController#reconcile` treats
`:unchanged` as proof there is nothing to commit: the row leaves the box **and its `Maker::RepoEdit`
row is deleted**. The maker's edit is then absent from the commit surface with nothing saying why.

## A `.lock` file is refused, never deleted

`LOCK_FILES` (`index.lock`, `HEAD.lock`) produce a refusal sentence that asks the MAKER to remove the
file if they are sure nothing is running. Deleting another process's lock corrupts repositories:
the lock is how git makes a ref or index update atomic, and removing it lets two writers race the
same ref. A refusal costs a click; a corrupted repository costs the repository.

The same method refuses a half-finished operation (`MERGE_HEAD`, `REBASE_HEAD`, `CHERRY_PICK_HEAD`,
`REVERT_HEAD`, `BISECT_LOG`) and a detached HEAD, and it is ONE method so `committable?` and the
message can never disagree about why. An unmounted share is not a refusal sentence — `FetchError` is
re-raised, and §14a maps it to 503.

## A truncated buffer is never editable, and the SERVER is what enforces it

`FilesController::EDITABLE_MAX_BYTES` (200,000) gates both `#show`'s `@editable` and `#update`.
`editor_controller.js`'s `MAX_BYTES` is the courteous half of the same rule, not the enforcing half:
a refusal that lives only in JavaScript is one `curl` walks straight past, and saving a truncated
buffer **truncates the file**. Keep the two numbers equal; if they ever drift, the server's is the
one that decides.

## `Library::WorkingTree` is the one definition of the ancestor walk

It was MOVED out of `Maker::AttachToProject`, not copied — that class now asks it and compares
against nil. A second copy is the drift §14d names a service to end: one question with two
implementations, free to disagree. Four rules came with the walk:

- **The root is the marker's PARENT**, which is why `Library::RepoMetadata` keeps the `.git`
  directory node indexed at all.
- **`present` and `kind: "dir"` are both load-bearing.** A tombstoned `.git` is not a working tree;
  a `.git` FILE is a submodule's or linked worktree's `gitdir:` pointer, and nothing here reads that
  pointer, so treating it as a marker would be right by accident and wrong by construction.
- **The walk is capped** (`MAX_ANCESTOR_WALK`): `parent_node_id` is a plain string column with no
  foreign key, so a cycle is representable and an uncapped loop is an infinite loop in a request.
- **The memo is on the PARENT, not the node**, and it is what keeps the sweep and the file page flat.

Answering the same question by scanning a folder's CHILDREN for `.git` — or dropping the memo — reads
identically on a three-file fixture and costs a query per sibling on a repository the maker actually
brought. Pinned by `test/integration/web/page_query_budget_test.rb`'s "files#show inside a repository
does not grow with the repository", which asserts CONSTANCY IN N and never a literal.

## No file under `app/services/maker/git/` reuses a name `tinkerex#161` used

The reverted feature is still reachable on `claude/git-phase5-refinement`:
`app/services/maker/git/repo.rb`, `text_diff.rb`, `tracking.rb`, `project_commit.rb`,
`pack_writer.rb`, `commit_info.rb`, `version_history.rb`, plus `app/models/maker/git_repo.rb`,
`app/jobs/maker/git/{commit_job,repack_job}.rb` and `docs/invariants/git-tracked-projects.md`.

One `git checkout claude/git-phase5-refinement -- app/services/maker/git/repo.rb` is all it takes.
Distinct filenames (`local_repo.rb`, `commit_paths.rb`) are what make such a checkout land as a NEW
file rather than an OVERWRITE of a class that answers a different design — that one hydrates an
ephemeral cache and writes packs, for a `maker_git_repos` table this branch does not have.

**Nothing guards this**, and saying so is the point: no gate reads another branch, and a sentence
that implied one would be worse than the gap (§14j is the worked example).

**BOTH LINE COUNTS YOU WILL SEE ARE RIGHT, ABOUT DIFFERENT COMMITS**, and the near-miss is worth
keeping because §15 asks that a commit reference be verified the way a guard is — and then that the
verification itself be checked:

```sh
git show claude/git-phase5-refinement:app/services/maker/git/repo.rb | wc -l   # 418, the branch tip
git show c3b2430^:app/services/maker/git/repo.rb | wc -l                       # 583, main before the revert
git merge-base --is-ancestor claude/git-phase5-refinement c3b2430^             # true: the branch is BEHIND main
```

The plan and two commit messages say 583, which is what the revert actually deleted. Measuring the
branch instead gives 418 and reads as a contradiction; it is not, because more landed on main after
that branch merged. Either file is the wrong thing to restore, which is all this rule needs — but a
correction that had replaced one number with the other would have been confidently wrong, which is
the failure this paragraph now exists to prevent.

## The inline diff is a REVIEW surface, not an editor

`mergeControls` is false, pinned by `assert_no_selector ".commit-diff .cm-chunkButtons"` in
`test/system/repo_editor_test.rb`. Measured against the vendored bundle: `rejectChunk` dispatches a
document change and is NOT gated by `EditorState.readOnly`, so the button would work on the buffer
while nothing posts it — the maker would click "Revert hunk", watch the lines return, commit, and the
change would still be on disk. `acceptChunk` is worse: it edits HEAD's side of the diff. Making
revert real means posting the reverted buffer through `PATCH /files/:id` with its `base_token`; that
is a feature, not a flag flip.

The vocabulary is inverted here and it is easy to ship backwards: `original` is HEAD's blob and the
document is the working tree, so a control for that direction says **"Revert hunk"** and never
"Reject". A screenshot cannot show the difference — both spellings render an identical diff, and only
the word says which way the file moves. CM6's supported way to relabel is the phrase facet, because
the extension re-renders those buttons whenever the chunks change.

## The history walk is always capped, and the cap is correctness rather than tuning

Measured on the live share deployment against `TheFlightWall_OSS` (333 commits) over its real CIFS
mount — the only repository on that box with history deep enough to measure:

| walk | cold | warm |
|---|---|---|
| full, all 333 commits | **4,917 ms** | — |
| path-filtered over all 333 | 3,388 ms | — |
| capped at 25 | **104 ms** | **1 ms** |
| capped at 50 | 89 ms | 5 ms |

~15 ms per commit cold is a network round trip per object — the repository is one packfile plus 256
loose-object directories — and 333 commits is a *small* repository. So `Maker::Git::History` has no
"all history" call and must never grow one: both entry points take `walk_limit`, `MAX_WALK_LIMIT`
(2,000) is the ceiling "look deeper" cannot pass, and `FilesController#history_walk_limit` clamps
whatever the query string asks for, so a caller cannot spell an unbounded walk however it tries.

Two things keep the guard from going vacuous, and both are easy to undo while the tests stay green:

- **Assert `walked`, never `entries.size`.** Returning few entries is not the same as looking at few
  commits, and only the second is what costs the seconds. `test/services/maker/git/history_test.rb`
  asserts `result.walked` in both cap tests for exactly this reason.
- **The fixture must hold more commits than the cap** (`make_repo_with_commits!`). A walk that never
  reaches its limit proves nothing about the limit — the shape that kept `tinkerex#185` invisible.

## History arrives by fetch after the render, and nothing waits on it

`files#show` renders the panel's mount point and no rows; the rows come from
`GET /files/:id/history` as JSON, driven by `history_controller.js` — the same shape
`codeview_controller` already uses for file bytes.

The table above is the argument. A cold capped walk is ~100 ms and a "look deeper" walk at the
ceiling is ~30 s, so computing the list inside the render puts that in front of **every** file page
in a repository, including the ones where nobody opens the panel, and makes the ceiling unusable:
the deep walk is affordable only because no page is waiting behind it.

Moving it back into the render errors nothing and logs nothing — the JSON is identical, the panel
looks identical, and a request test cannot tell the difference because the rows were never in the
HTML to begin with. Only a clock sees it. The same asynchrony is why the panel's own coverage has to
be a system test: a request test can assert the MOUNT exists
(`test/integration/web/repo_history_flow_test.rb`, "the file page mounts the history panel"), and a
`data-controller` name that resolves to nothing is a silent no-op (§14d).

## `stopped` reaches the view, and only `:exhausted` licenses the word "none"

Path filtering is sparse. In the measured repository **1** of the last 50 commits touched
`README.md`, against **28** of all 333 — roughly one in twelve — so a capped walk can legitimately
find nothing about a file with a long history sitting just behind the cap. An empty `entries`
therefore usually means *we stopped looking*, and the panel must say "no changes to this file in the
last N commits" and offer to look further.

`Result#stopped` is `:exhausted | :limit | :walk_limit`, it crosses the wire verbatim in
`FilesController#history`, and `#no_history` deliberately reports the refusal code instead —
"no_repo", "no_worktree", "unavailable" — because none of those conditions established that a file
has no history either.

Tidy it away — drop the "redundant" member, collapse it to a boolean, or report a constant — and the
panel says "no history" about a file with 28 changes. Nothing goes red: `entries` really is empty,
so every bytes-oriented assertion still passes. What catches it is `history_test.rb`'s "a capped
path walk can find nothing and reports walk_limit, not exhausted" and its flow-test twin, and both
depend on `make_repo_with_commits!`'s `touch_every` to make filtering sparse enough for that state
to be reachable at all.

## Path filtering compares against the FIRST parent only

A commit touches a path when the blob oid at that path differs from the oid at the same path in its
**first** parent. Absent in both is not a change, and `Rugged::TreeError` for a path a commit does
not contain is an ordinary absence rather than an error. A change that arrived through a merge is
therefore attributed once, to the commit that made it — which is what `git log` does by default.

Comparing against every parent looks more thorough and is wrong twice over: it lists the same change
again at the merge, and it **drops the root commit**, whose `parents` is empty so `any?` is false.

That mutation is invisible without a merge whose two spellings disagree, which is the whole reason
`make_repo_with_merge!` exists: the merge takes the MAINLINE version of `tracked.txt`, so it is
treesame to its first parent and not to its second. First-parent gives `[c1, c0]`; every-parent
gives `[m, c1]` (probed). A merge fixture without that asymmetry makes the check unfalsifiable.

## Restore writes a pending edit and never commits

`POST /files/:id/restore/:oid` reads the old bytes with `blob_at`, writes them through
`Maker::Addons::LibraryOutput.write_bytes!(..., replace: true)` — the same door the editor's Save
uses, the one surviving `port_writable?` branch (§14d), and `replace: true` because reusing the node
is what keeps every attachment, BOM line and tag pointing at it (§14a) — and records a
`Maker::RepoEdit`. The maker then reviews it in the commit box like any other change.

A restore that committed directly would need its own message, its own refusals and its own undo, and
would put a version into history before anyone had looked at it. As a pending edit it is one click
from undone and rides a path that is already built, already tested, and already has a review step.

It is gated on `local_worktree?` even though the port writes on every backend, because a restore the
maker cannot then commit is a trap rather than a feature — and `chunk_remote` mirrors a repository's
`.git` into the catalog (§14b), so that is a state a real deployment reaches.

## A no-op restore is refused rather than performed

Restoring the bytes already on disk creates a pending edit that `RepoCommitsController#reconcile`
immediately drops as `:unchanged` — correctly, since it compares content against HEAD's blob. So the
maker clicks Restore, the page reloads, and the commit box shows nothing. That is indistinguishable
from the feature being broken, and it is the failure this repo names as its dominant one (§15): no
error, no log, a green suite over something that visibly did not work.

`FilesController#restore` compares the blob against `FileLayer.current.read` before writing anything
and answers "That version is already what is on disk." Removing the check does not break a test that
looks at bytes; it produces a button that appears to do nothing.

## Two identically-built repositories share commit oids

git content-addresses a commit: the oid is a hash of the tree, the parents, the message and both
identities, timestamps included. Two fixture repositories built the same way therefore have
**byte-identical commit oids** — probed, true — so "an oid from another repository" is an oid this
repository also contains, `blob_at` answers from the repository it was handed, and the test that
exists to stop a cross-repository oid resolving passes while exercising nothing at all.

`GitRepoFixture#fixture_commit_time` derives its base from the repository's NAME for this reason and
no other; it reads like arbitrary fixture noise and is the only thing making those repositories
distinct. `history_test.rb`'s "an oid from another repository is refused" asserts the two head oids
DIFFER before asserting the refusal — the non-vacuity assertion §14e asks for, at the one place the
vacuity would be silent.

## `Rugged::SORT_DATE` does not order commits within one second

git stores a commit time to whole seconds. A builder stamping `Time.now` on every commit gives them
all the same second, and libgit2 breaks that tie in an order it does not specify — probed on rugged
1.9.6: four same-second commits walked as **c3, c0, c1, c2**. Any "newest first" assertion over such
a fixture is luck rather than a test, and it can flip on a library upgrade with no code change.

`fixture_commit_time` gives a fixed, DISTINCT second per commit. This is §15's `.to_i` trap seen
from the other side: there a guard cannot fail because the two events it compares share a second;
here an ordering is unspecified for the same reason. Both are the same mistake — treating a
whole-second timestamp as though it distinguished things.

It is a separate rule from the walker's explicit `walker.sorting(Rugged::SORT_DATE)`, and both are
needed: the sorting call fixes what libgit2 leaves unspecified BETWEEN seconds, and the fixture
fixes what remains unspecified WITHIN one.

## `Maker::Git::History.new` dereferences the port, so `refusal` is checked strictly before it

The constructor reads `local_repo.rugged`, which resolves `workdir` through the port's
`absolute_path` — and `FileLayer::Share` is the ONLY adapter that defines one. Constructing the
walker before asking `LocalRepo#refusal` is therefore a `NoMethodError` **500** on s3 and
chunk_remote, where the intended answer is a refusal sentence.

Live rather than hypothetical: `chunk_remote` mirrors a repository's `.git` directory into the
catalog (§14b), so `Library::WorkingTree#root_for` answers a non-nil root there, the file page asks
for history, and the naive order runs. `LocalRepo#refusal` asks `local_worktree?` FIRST and returns
before touching `workdir` (probed), which is what makes it safe as the first line — and is also why
the extra capability check in `FilesController#restore` is about the SENTENCE the maker reads and
not about safety.

Both callers today are `FilesController#open_history` and `#restore`, and each has the check strictly
above the construction. A third must keep that order. The failure appears only on the s3 and
chunk_remote legs, which is why `repo_history_flow_test.rb`'s backend cases assert those legs'
answers rather than skipping (§14e) — a skip here would report success over the only two backends
that can reach the bug.
