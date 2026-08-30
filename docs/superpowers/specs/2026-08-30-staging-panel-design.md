# The staging panel: committing what tinkerex did not edit

The last piece of `tinkerex#178`, after edit/commit (PR #281–#283) and history/restore (PR #284).

> **Citation convention.** A bare `§` is **CLAUDE.md**; this document's sections are **part N**. The
> two prior designs are cited as **the commit spec**
> (`2026-08-28-edit-and-commit-in-a-repo-design.md`) and **the history spec**
> (`2026-08-30-git-history-and-restore-design.md`).

---

## 1. What this is, and what it gives up

The commit box lists **only what tinkerex edited**. This adds a second group listing **everything
else git sees**, unchecked and collapsed, so a maker can commit work they did outside the app.

**IT DELIBERATELY WEAKENS A SAFETY PROPERTY, AND THAT IS THE WHOLE DECISION HERE.** The commit spec
did not merely arrange for the box to avoid the maker's other work — it made the box *structurally
incapable* of touching it, because unedited paths were never offered. After this change the
protection is *not by default, and one deliberate click away*. That is a real reduction, taken
knowingly, and it is why the pre-checked group stays exactly as it is: the safe thing remains what
happens if you press Commit without thinking.

**Measured, on the live share deployment (2026-08-30), which is what makes this worth building:**

| repo | dirty (non-ignored) | shape |
|---|---|---|
| `catan` | 58 | **all `:worktree_new`** — `.DS_Store`, then `design/boxv1-5.svg`, `boxv2-6.svg`, `boxv3.svg`, … |
| `TheFlightWall_OSS` | 6 | 5 tracked modifications + 1 untracked; 13 further paths `.gitignore`d |
| `ESPHome-Projection-Clock` | 2 | both untracked |

`catan`'s 58 are not noise. They are the maker's real design files, uncommitted because the retired
sweep only ever committed pointer files. Today the box counts them and offers nothing.

**Out of scope:** rename detection, branch switching, `git add -p`/partial hunks, amend, stash, and
anything touching `.gitignore`d paths. Per-hunk revert remains `tinkerex#184`.

---

## 2. Three groups, in one box

| group | source | checked | note |
|---|---|---|---|
| **Edited in tinkerex** | `maker_repo_edits`, reconciled against git | **yes** | today's behaviour, unchanged |
| **Other changes** | everything else git sees | no, collapsed | the new capability |
| **OS clutter** | `Library::OsClutter` names | no, labelled | "tinkerex never creates these" |

**`.gitignore`d paths never appear at all.** git refuses them without `-f`; offering them would be
offering something that cannot happen.

**OS CLUTTER IS LISTED, NOT HIDDEN, AND THE DISTINCTION IS LOAD-BEARING.** This app refuses to
*create* `.DS_Store` at every door — `Library::ReservedNames` blocks minting it, `Library::OsClutter`
drops it from the catalog — so offering to *commit* one without comment would be the app
contradicting itself. But hiding it from a **staging** surface is a different and worse thing than
hiding it from a browse surface: git will still show it in the terminal, and a panel that disagrees
with `git status` is the lie this arc has now avoided three times. §14b's own rule is that
`OsClutter` is a display filter and never a scan skip; this is the staging analogue. It is shown,
unchecked, and labelled with the app's opinion — which informs without overriding.

**Binary files are listed and committable, and say "binary — no diff".** git commits them fine;
only the diff view cannot help.

**Renames are not detected** (the history spec's `--follow` limitation, one layer down). A rename
appears as a delete plus an add, and the panel says so — a maker who sees both halves and is told
why can act; one who sees them unexplained files a bug.

---

## 3. `#full_status` — a reader, capped like the walk

`Maker::Git::LocalRepo` gains `#full_status(limit:)` beside `#status_for(paths)`. Same `Row` shape;
it **enumerates** rather than answering about named paths.

```ruby
FullStatus = Data.define(:rows, :truncated_count)
DEFAULT_STATUS_LIMIT = 500
```

**IT IS CAPPED FOR THE SAME REASON THE HISTORY WALK IS**, and the number is not decoration: a
repository can hold thousands of dirty paths, `catan` already holds 58, and every row costs a
content comparison against HEAD's blob (part 4). Over CIFS that is the cost the history spec
measured at ~15 ms per object. **`truncated_count` reaches the view** — a truncated list that does
not say so is the same lie as a capped walk reporting "no history".

**ONE STATE SPLITS IN TWO, AND CONFLATING THEM IS A REAL BUG.** `#row_for` currently answers
`:missing` for any path with no file on disk. That is two different situations:

- **`:deleted`** — present in HEAD, absent from the working tree. A real change, committable.
- **`:missing`** — absent from both. A stale `maker_repo_edits` row, which the box already drops.

Left conflated, either every stale row becomes a committable deletion or every real deletion is
silently dropped. Both are silent.

---

## 4. Deletions in `CommitPaths` — the risky half

`#stage` inserts, reading bytes from the working directory. It gains a second branch: a selected
path **absent from the working tree and present in HEAD's tree** has its entry **removed**,
recursing through parent trees, pruning a tree that becomes empty. The index takes `remove` rather
than `add` for those paths.

**THE DANGER IS NOT DROPPING THE ENTRY YOU SELECTED — IT IS DROPPING ONE YOU DID NOT.** That is the
`index.clear` bug's shape exactly: a change correct about the files it was asked about, wrong about
everything else, passing every bytes-oriented test. It gets the same guard, stated as an invariant:

> **An unselected deleted file still exists in the new tree.** Its bytes are HEAD's, untouched.

The existing rule — *HEAD's tree with the selected paths replaced* — is unchanged. "Replaced"
simply now includes "replaced with nothing" for a path the maker deleted and selected.

**A DELETION IS STILL NOT A `delete` THROUGH THE PORT.** Nothing here removes a file from the
working tree or the catalog; the maker already deleted it, in Finder or their editor, and this only
records that in git. Part 1's scope holds: this feature adds a reader and one narrow writer.

---

## 5. Refusals

Inherited unchanged from the commit box — nothing new is invented:

| Condition | Answer |
|---|---|
| lock file / detached HEAD / operation in progress | the whole box refuses, as today |
| `local_worktree?` false | no box at all, as today |
| path `.gitignore`d | never listed |
| path is OS clutter | listed, unchecked, labelled |
| binary | listed, committable, no diff offered |
| more than `DEFAULT_STATUS_LIMIT` dirty paths | listed to the cap, remainder counted |
| a selected path that vanished between render and submit | dropped with a notice, not a 500 |

That last one is not hypothetical: the box is a form over a working tree the maker is also using.
`CommitPaths` already re-reads each path at commit time; the panel must word the outcome.

---

## 6. Testing

**One fixture carrying all five states at once** — added, modified, deleted, clutter, ignored — so
the grouping is provable in a single pass rather than five fixtures that can drift apart.

**Mutation checks, each with its actual output recorded in the commit that introduces it:**

| Break this | Must go RED |
|---|---|
| drop an unselected deleted path from the tree | **the one that matters.** An unselected deletion must survive with HEAD's bytes |
| collapse `:deleted` back into `:missing` | a real deletion is offered; a stale row is not |
| list `.gitignore`d paths | they never appear |
| hide OS clutter instead of labelling it | it appears, unchecked |
| drop `truncated_count` | a capped list says so |
| pre-check the "Other changes" group | only the tinkerex-edited group is checked on load |

That last one guards the property part 1 gives up deliberately: the reduction is *unchecked by
default*, and a change that pre-checks the wider group removes the whole protection while leaving
every other test green.

**Three legs identical.** The panel pins a share library; the presence tests do not pin and assert
absence on the other two rather than skipping (§14e).

**A system test**, because the box is fetch-populated and a `data-controller` that resolves to
nothing is a silent no-op (§14d): expand "Other changes", check one path, commit, and confirm the
others are untouched in the resulting tree.

### The gate `bin/ci` cannot provide

On the share deployment against `catan` (58 untracked, real design files) and `TheFlightWall_OSS`
(5 tracked modifications that must stay untouched): open the box, confirm the groups are right,
commit one file from "Other changes", and confirm with real `git` that the other 57 — and
TheFlightWall's 5 — are exactly as they were.

---

## 7. Candidate invariants

For `docs/invariants/git-editing.md` (18 rules today):

1. Only the tinkerex-edited group is checked on load. The wider group is opt-in per commit; a change
   that pre-checks it removes the protection part 1 knowingly reduced.
2. An unselected deleted path survives in the new tree, with HEAD's bytes.
3. `:deleted` and `:missing` are distinct: in-HEAD-and-gone versus in-neither.
4. `.gitignore`d paths are never listed; OS clutter is listed, unchecked and labelled — hiding it
   from a staging surface makes the panel disagree with `git status`.
5. `#full_status` is capped and `truncated_count` reaches the view.
