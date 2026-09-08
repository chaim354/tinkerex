# Editing and committing in a repository

§14a/§14b/§14d material for the git surface a maker sees on a repository they brought into the
library. Written with `tinkerex#178` and kept out of CLAUDE.md because it binds inside one
subsystem: the rules are here, the story is in the spec and in Forgejo (§11). Read this before
touching `app/services/maker/git/`, `app/services/library/working_tree.rb`,
`app/controllers/repo_commits_controller.rb`, `app/views/repo_commits/show.html.erb`,
`app/controllers/repo_histories_controller.rb`,
`FilesController#update`/`#history`/`#history_blob`/`#restore`, `test/support/git_repo_fixture.rb`,
or `app/javascript/controllers/{editor,diffview,history}_controller.js`.

The first nine rules came from the edit/save/commit slice (PRs #281-#283). The nine after them came
from history and restore
(`docs/superpowers/specs/2026-08-30-git-history-and-restore-design.md`): six are that spec's part
10, two of them carrying the measurement that produced them, and three are findings from building
it — each a fact about git or rugged that reads as tidiable and is not. **None of the nine was
derived by reading the code**, which is why each states what breaks when it is undone rather than
what the code does.

The ten after THOSE came from the staging panel
(`docs/superpowers/specs/2026-08-30-staging-panel-design.md`): five are that spec's part 7, and five
are findings from building it — three of them facts about rugged or a shared predicate that a
plausible tidy-up gets wrong, one a vocabulary that must not be reused, and one that is **not a rule
at all**. The last is a recorded IMPRECISION: the panel's `:ignored` label is slightly wrong about
git, inherited rather than introduced, and it is written down so the next reader recognises it
instead of half-fixing it.

One section below is not a rule but an EXCEPTION to the first one — stage 4's README door (S4-4,
`docs/superpowers/specs/2026-09-07-stage-4-bench-maker-design.md` §2 D3). It sits SECOND, directly
after the rule it excepts, so a reader meets the two in the same breath, and it is outside the
three counts above.

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

## The Markdown exception: a project's README is editable without a repository

**Stage 4, S4-4 (spec §2 D3).** `FilesController#update` refuses a file that is not inside a
working tree, and every rule in this file is why. **One door is exempt**:
`PATCH /projects/:id/readme` (`Projects::ReadmesController#update`) writes the project folder's own
README on **any** backend, repository or not.

**Why this one and not the others.** The refusal exists because a save on share or s3 overwrites
with no undo, and git is the undo. For documentation the alternative is not "edit it somewhere
safer" — it is **no README at all**: on the measured share deployment, 0 of 9 real projects have
one the page shows (spec §2 D3; §1 holds the count and, in its findings 1 and 4, why it is zero).
A rule that protects a file nobody ever writes has protected nothing. So the trade is **named on
the editor** — "This library keeps no history for this file; saving replaces it." on share and s3,
nothing on chunk_remote, decided by `capabilities.versioned?` — and the maker chooses with the cost
in front of them.

**What still holds, unchanged, and what breaks if you undo any of it.**

- **The bytes go through the port**, `Maker::TextSave` → `Maker::Addons::LibraryOutput.write_bytes!`
  → `FileLayer#write` / the two-phase upload. Never `File.write`, never a delete-then-create: both
  orphan every attachment, BOM line and tag on the node, silently (§14a).
- **`replace: true`, so the node survives.** A README is attachable, taggable and BOM-linkable like
  any other file.
- **The `base_token` stale check** — a 409 on the file page, an alert on the project page, one
  `Maker::TextSave` result underneath. The editor edited some version; if the port's content token moved
  under it, the save is refused rather than discarding whatever moved it. **As of the catalog's last
  observation**: on share and s3 `stat` answers from the row, not the disk, so a desktop edit made
  after the last scan and before Save is overwritten (measured in S4-4's review). That window is
  §14b's bounded staleness, the no-history note is what names it to the maker, and closing it is a
  port question — do not "fix" it with a disk read in the door.
- **A `.lock` is still refused and never deleted**, and a detached HEAD or a half-finished
  operation still refuses — this door does not touch `Maker::Git::LocalRepo` at all, so it inherits
  those refusals by not having a git path to skip.
- **Restore is still git-only** and still writes a pending edit rather than committing. There is no
  "undo" on this door, which is exactly what the note on the editor says.
- **A pending `Maker::RepoEdit` is still recorded when the folder IS a working tree**, so a README
  saved in a repository shows up in the commit box like any other edit.
- **The 200,000-byte cap is still the SERVER's**, read from `FilesController::EDITABLE_MAX_BYTES`
  rather than copied.

**The exception is confined STRUCTURALLY, not by a name check.** The door takes **no node id from
the client**: it resolves the file through `Maker::Readme.row_in(listing.loose)` — the same call
both project-page cards render from — so the only file it can ever write is one of the six
`Maker::Readme::NAMES` at the project folder's root. There is no parameter to point somewhere else
and no predicate to loosen. D3's fuller wording ("Markdown is editable anywhere", story 2.13) is
**not** implemented: widening `FilesController#update` to any `.md` outside a repository is a second
door with its own surfaces — the file page's editor, its own no-history note, its stale thumbnail —
and **needs its own spec and its own slice**. Do not widen this one to get there.

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

**A THIRD reader, and it lives outside this rule's own guard.** `Maker::RepoCard` (stage 3, S3-2 —
the project page's repository card) asks `capabilities.local_worktree?` before opening
`LocalRepo.open` for git facts, the same way `RepoCommitsController`/`RepoHistoriesController` do —
but `app/services/maker/repo_card.rb` sits under `app/services/maker/`, one directory above the
`app/services/maker/git/**` glob `test_the_git_surface_never_branches_on_an_adapter_class` scans, so
a class check written there would NOT trip that guard. Nothing enforces this rule on that file
today; it is honoured by inspection, the same gap the previous paragraph already names for anything
outside the three scanned globs. The README half of that class is **`Maker::Readme`** since stage 3,
S3-4 — the public project page renders the project FOLDER's own README with the same reader, so the
card is now its first caller rather than the only copy — and it reads its file through the PORT
(`FileLayer.current.read`, this file's own opening rule — "bytes the catalog tracks go through the
port"), never `File.read` against `LocalRepo#workdir`: a README is a catalog file like any other,
not git's own working-tree read, and it is read on EVERY backend (share, s3, chunk_remote), not
gated on `local_worktree?` at all — only the commit/tag facts are.

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

## Only the tinkerex-edited group is checked on load

**THIS IS A SAFETY PROPERTY DELIBERATELY REDUCED, AND THE CHECKBOX IS WHAT IS LEFT OF IT.** The
commit box was not merely careful about the maker's other uncommitted work — it was *structurally
incapable* of touching it, because unedited paths were never offered. The staging panel offers them,
so the protection is now **not by default, one deliberate click away**. That reduction was taken
knowingly (spec part 1) and is not the thing to relitigate; which group arrives CHECKED is.

`RepoCommitsController#show` builds three groups and only the first is checked: the reconciled
`maker_repo_edits` rows, what tinkerex itself wrote. "Other changes" is unchecked and collapsed;
"OS clutter" is unchecked and labelled.

Pre-check either wider group and **the safe thing stops being what happens when a maker presses
Commit without reading**: one click commits `.DS_Store`, a half-finished experiment three folders
over, and whatever their editor left behind. The commit succeeds. Nothing errors. It is simply not
the commit anyone asked for — and on `catan`, the repository this feature exists for, that is 58
paths arriving pre-checked, `.DS_Store` among them.

**Exactly one case in the request suite can see it**, `repo_edit_flow_test.rb`'s "only the
tinkerex-edited group is checked on load" — and that it is the only one there is verified rather
than assumed: an assertion about a checked `paths[]` control appears **twice in that file and
nowhere else in it**. Its two `assert_operator … :>=` lines are the non-vacuity half (§14e), because
with nothing offered in the other groups "none of them is checked" would be true for the wrong
reason. A "Select all" control is per-GROUP for the same reason and must never be global: a global
one commits clutter by accident, which is this rule undone through a different door.

## An unselected deleted path survives in the new tree, with HEAD's bytes

`CommitPaths#stage` answers a selected path that is gone from the working tree with `#remove`
instead of reading bytes — "replaced with nothing" is what a maker who deleted the file in Finder is
asking for, and the class rule does not move. **The danger is not dropping the entry you selected;
it is dropping one you did not.**

That is `index.clear`'s shape one level down: a change right about the file it was asked about and
wrong about the one it wasn't, green on every bytes-oriented assertion, because the bytes of the
selected files really are correct. The tidier-looking spelling — walk HEAD's tree once and remove
everything absent from the workdir — silently deletes every path the maker has moved, renamed or
carried off somewhere else and did not select.

Measured, with the file restored byte-exactly from a `cp` snapshot afterwards: replacing the
per-path branch with a `walk_blobs` sweep over HEAD's tree turns **exactly one of the sixteen tests
in `commit_paths_test.rb` red** — "an UNSELECTED deleted path survives in the new tree with HEAD's
bytes", failing `Rugged::TreeError: the path 'a.txt' does not exist in the given tree` — and leaves
the other **fifteen green**. `repo_edit_flow_test.rb`'s "a path from Other changes commits, and only
it" asserts the same property through the real request. Delete either and the mutation is invisible.

## `:deleted` and `:missing` are distinct, and conflating them is silent in both directions

| state | on disk | in HEAD | what it is | committable |
|---|---|---|---|---|
| `:deleted` | no | yes | a real deletion the maker may want to record | **yes** |
| `:missing` | no | no | a stale `maker_repo_edits` row the box already drops | no |

`LocalRepo#row_for` asks `head_blob_for` before it labels; `Row#committable?` accepts `:deleted`;
`RepoCommitsController#reconcile` still drops `:missing`.

One `:missing` for both fails in whichever direction the collapse chose, and **neither direction
errors**: everything absent becomes `:missing` → a real deletion is never offered and cannot be
committed from the app at all; everything absent becomes `:deleted` → every stale row becomes a
committable deletion of a file that was never there, and a maker who selects the lot commits
removals of paths HEAD does carry.

Two tests, because either alone passes one arm of the collapse: `local_repo_test.rb`'s "a path in
HEAD and gone from the worktree is deleted, and committable" and "a path in neither HEAD nor the
worktree is missing, and NOT committable".

## `.gitignore`d paths are never listed; OS clutter IS listed, unchecked and labelled

The two look like one rule about noise and are opposites.

**`.gitignore`d is dropped in `LocalRepo#full_status`, not in the view.** git will not carry such a
path without `-f`, so offering it is offering something that cannot happen — the row would be a
checkbox whose only possible outcome is a refusal the maker cannot see coming.

**OS clutter goes the other way, and the browse-surface reasoning does not transfer.** This app
refuses to CREATE `.DS_Store` at every door (`Library::ReservedNames`) and drops it from the catalog
(`Library::OsClutter`), so offering to commit one *without comment* would be the app contradicting
itself. But hiding it from a **staging** surface is a different and worse thing than hiding it from
a browse surface: `git status` in the terminal still shows it, and a panel that disagrees with
`git status` is a lie about the repository — the same lie this file already refuses twice, in the
capped walk's `stopped` and in `truncated_count` below. It is shown, unchecked, and labelled with
the app's own opinion ("tinkerex never creates these"), which informs without overriding.

Hide it and the maker's terminal reports a dirty tree the panel calls clean, with no way to act on
it from the app. Offer it checked and rule 1 above is gone. Guarded by "the box shows three groups
with the right membership", which asserts both directions in one pass — `.DS_Store` present under
`clutter` and absent from `other`, `secret.log` present in **no** group.

## `#full_status` is capped, sorted before the cap, and `truncated_count` reaches the view

The history walk's argument, one object at a time: every row costs a content comparison against
HEAD's blob — "Compare content against HEAD's blob, never a stat", above — which over CIFS is the
~15 ms per object the history table measured. `catan` already carries 58 dirty paths and a repository can carry thousands, so
`DEFAULT_STATUS_LIMIT` is 500 and both halves of the cap are load-bearing:

- **`truncated_count` reaches the view.** A truncated list that does not say so is the same lie as a
  capped walk reporting "no history", and it is worse here, because the maker's conclusion is not
  "there is more to see" but "the app has seen everything, so the rest of my tree must be clean."
- **`paths.sort!` runs BEFORE `first(limit)`.** `Rugged::Repository#status` promises no order, so an
  unsorted cap keeps an arbitrary subset and two renders of one repository can offer different
  files — a difference nothing reports and no test asserting a COUNT can see.

Pinned by `local_repo_test.rb`'s "full_status is capped and says how many it did not list" and the
flow test's "a truncated list says how many paths it did not show", whose fixture writes
`DEFAULT_STATUS_LIMIT + 1` files. A fixture at or below the cap makes both vacuous — the shape that
kept `tinkerex#185` invisible.

**A loose end, recorded rather than left to be tripped over: `LocalRepo#other_dirty_count` now has
no production caller.** The panel lists those paths instead of counting them, and `truncated_count`
answers the "how many more" question it was built for. It is still exercised by "other dirty paths
are counted, not returned", and `local_repo.rb:92` cites it BY NAME for the fact that
`Rugged::Repository#status` takes a block and returns no enumerator. Removing the method is fine;
removing it and leaving that citation is a comment naming something that no longer exists — a
sentence read as a guarantee, which is exactly what `test/docs_hygiene_test.rb`'s citation guard
exists for one directory over. **Move the citation in the same commit, or keep the method.**

## `Library::OsClutter` is macOS-only on purpose, so `Thumbs.db` is the WRONG probe

The clutter group partitions on `Library::OsClutter.ignore?` and never on a list of names (§14b:
that predicate is composed once and copied nowhere, because the observers and the write guards must
not drift). A test that means to prove WHICH of the two is in use needs a name the literal misses
and the predicate catches — and the obvious pick is not one. Probed:

```ruby
Library::OsClutter.ignore?("Thumbs.db")      # => false
Library::OsClutter.ignore?("desktop.ini")    # => false
Library::OsClutter.ignore?("._sidecar.txt")  # => true
Library::OsClutter.ignore?("__MACOSX/a.stl") # => true
```

`NAMES` is macOS clutter and the constant says so in as many words: Windows clutter is deliberately
absent, because adding a name there is a real indexing-behaviour change AND a new write refusal, so
it is a decision to take explicitly rather than a net to widen. **The plan proposed `Thumbs.db` for
exactly this test.** It fails against CORRECT code, which is the worst kind of probe — a red that
reads as the guard having found a bug.

Use `._sidecar.txt` (the `APPLE_DOUBLE_PREFIX` rule, which no `%w[.DS_Store]` literal covers) or a
nested `__MACOSX` segment (`ignore?` matches **any path segment**, not just the leaf, which is what
lets one predicate serve the observers and the write guards). "OS clutter is partitioned by the
shared predicate, not by a list of names" uses the first.

## Binary is decided by CONTENT, never by `Maker::FileAttachment.text?`

git's own rule, and the panel takes it: a NUL byte within the first 8 kB
(`RepoCommitsController::BINARY_SNIFF_BYTES`).

**This is not the second-vocabulary mistake §14d warns about; it is a second AXIS.**
`Maker::FileAttachment.text?` answers a NAME question — "should the file page offer a source
viewer" — off an extension allowlist, and it **answers false for `.svg`** (probed). `catan`, the
58-dirty-path repository this whole feature exists for, is full of `.svg` design files, so the
name-based answer prints "binary — no diff" over every one of them: the panel refusing to diff the
exact files it was built to let a maker commit, while looking like it is working.

Adding `.svg` to `ROLE_BY_EXT` is still the fix for the FILE page (`files-preview.md`); it is not the
fix for this, and routing this question through that predicate re-couples two questions that merely
agree about most files. Guarded by "a binary path is committable and says so instead of mounting a
diff" — and **committable is half that assertion**: git commits a binary fine, so a change that
refuses one has broken more than the diff.

## `Rugged::Index#remove` raises, so `refresh_index` asks `index[rel]` first

Probed on rugged 1.9.6:

```ruby
index["ghost.txt"]        # => nil
index.remove("ghost.txt") # => Rugged::IndexError: index does not contain ghost.txt at stage 0
```

`CommitPaths#refresh_index` therefore branches three ways — `File.exist?` → `add`, `elsif index[rel]`
→ `remove`, else nothing. Drop the guard and a selected path in neither the working tree nor HEAD
(`:missing`, a stale row, harmless everywhere else in this class) raises **after
`Rugged::Commit.create` has written the commit and moved the ref**. The maker sees a 500, the commit
landed anyway, and the index was never written — the worst position in the whole write path, reached
by a path that had nothing to contribute in the first place.

The TREE half of that same case is safe with no guard, for an unrelated reason
(`Tree::Builder#remove` answers false for a name it does not hold), so the index half has to be
argued separately rather than assumed to follow from it. "a selected path in neither the worktree
nor HEAD is a no-op, not an error" covers both.

## `Rugged::Tree::Builder` has no `#size`, so emptiness is read off the WRITTEN tree

Its instance methods in rugged 1.9.6 are exactly `<<`, `[]`, `clear`, `insert`, `reject!`, `remove`,
`write` (probed). Asking a builder how many entries it now holds is a `NoMethodError`, so
`CommitPaths#remove` writes the sub-tree and asks the RESULT — `written.count.zero?` — then either
prunes the directory from its parent or re-inserts `written.oid`. The same `write` supplies the
decision and the oid, so nothing is written twice.

**A directory that lost its last entry is pruned, never re-inserted empty.** git has no empty
directories: re-inserting the emptied builder writes the empty-tree oid
(`4b825dc642cb6eb9a060e54bf8d69288fbee4904`, probed) where a directory used to be — a commit git
accepts and no client can explain. Pinned by "a directory emptied by a deletion is pruned from its
parent" and "a nested deletion prunes only its own entry".

## Known imprecision: the `:ignored` label is inherited, and it is slightly wrong about git

**Not a rule — a recorded inaccuracy**, written down so the next reader recognises it instead of
half-fixing it in the one place it is most visible.

A TRACKED file that `.gitignore` also matches is a real state, not a hypothetical. git reports it
modified (an ignore rule has no say over a file already in the index), so it survives
`full_status`'s `:ignored` filter; `LocalRepo#row_for` then asks `path_ignored?` before it compares
content and labels the row `:ignored`, and the panel lists it disabled, "ignored by .gitignore".

**git disagrees.** Probed on git 2.50.1: `git status --short` reports ` M build.log`, and
`git commit build.log -m …` commits it, exit 0. The panel refuses something git would do.

Listing it at all is deliberate — the terminal shows it, and the pending group has listed a
`.gitignore`d path this way since the commit box shipped, so dropping it here would give one
condition two answers depending on which group it landed in (§14a). The imprecision belongs to
`#row_for`, is inherited by the panel rather than introduced by it, and errs toward REFUSING, which
is the safe direction. Correcting it means asking whether the path is TRACKED — a new question for
`#row_for`, changing the pending group too. Do that deliberately, in that one place, or leave it
alone; **do not fix it in the panel only**, which is how one condition acquires two answers.
`repo_edit_flow_test.rb`'s "a tracked path .gitignore also covers is listed disabled rather than
dropped" pins the behaviour, not its correctness.
