# Editing and committing in a repository

§14a/§14b/§14d material for the git surface a maker sees on a repository they brought into the
library. Written with `tinkerex#178` and kept out of CLAUDE.md because it binds inside one
subsystem: the rules are here, the story is in the spec and in Forgejo (§11). Read this before
touching `app/services/maker/git/`, `app/services/library/working_tree.rb`,
`app/controllers/repo_commits_controller.rb`, `FilesController#update`,
`app/javascript/controllers/editor_controller.js`, or
`app/javascript/controllers/diffview_controller.js`.

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

`repo.rb` is **418 lines** on that branch tip, measured on 2026-08-28 with
`git show claude/git-phase5-refinement:app/services/maker/git/repo.rb | wc -l`. The plan and two
commit messages say 583; that figure does not reproduce. Recorded rather than repeated, because §15
asks that a commit reference be verified the way a guard is.

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
