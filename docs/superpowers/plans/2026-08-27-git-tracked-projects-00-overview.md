# Git-tracked projects — phase overview

> **For agentic workers:** this file is NOT executable on its own. It fixes the phase order and the
> shared interfaces so the five per-phase plans cannot drift apart. **Read this, then execute the
> plan for your phase.** Use `superpowers:subagent-driven-development` or
> `superpowers:executing-plans` for the phase plan itself.

**Design:** [`docs/superpowers/specs/2026-08-27-git-tracked-projects-design.md`](../specs/2026-08-27-git-tracked-projects-design.md)
— read §2 (what was rejected and why) before proposing any change of approach. Three plausible
architectures were killed by evidence there, and two of them were killed *after* being proposed.

**Goal:** every maker project is a real git repository on all three backends, with version history
in the GUI including per-version thumbnails for models and CAD.

**Architecture:** git data is durable in the **library** (never an app volume, never a database),
written through a new **non-cataloging** port verb. `rugged` operates on an **ephemeral container
cache** hydrated from that data; on `share` the library is already a filesystem so the cache step is
skipped. Consolidation into **packs** is part of the commit loop, not a background tidy-up — §4.1
measures an unpacked repo as unhydratable on s3 and chunk_remote.

**Tech stack:** Rails 8, `rugged` (libgit2), a hand-written undeltified pack writer
(`docs/superpowers/specs/2026-08-27-git-tracked-projects-packwriter.rb`, already built and verified),
`diff-lcs` in phase 4.

---

## Phase order — do not resequence without reading this

| phase | plan | delivers | risk |
|---|---|---|---|
| 1 | `01-port-door.md` | Port verbs + `repo_storable`. **No git.** | low |
| 2 | `02-engine.md` | Repo lifecycle, rugged, pack writer. **Not wired to `ScanJob`.** | low |
| 3 | `03-turning-it-on.md` | `ScanJob` wiring, settle detection, repo init, tracking rule, **§8.1 relaxation** | **HIGH** |
| 4 | `04-gui.md` | Version list, historical thumbnails, mesh A/B | moderate |
| 5 | `05-refinement.md` | Size threshold, repack policy, cache retention | low |

**The §8.1 relaxation belongs in phase 3 and an earlier draft had it last.** Project intake breaks
the instant a project folder becomes a working tree — which is the moment commits start. Landing the
relaxation later means phase 3 *creates* the breakage and phase 5 *repairs* it, with every project
silently unfiled in between and **nothing going red**, because no test today asserts that a project
folder is not a repo. Same phase as the switch-on, or the switch-on is unsafe.

**Track-by-role is in phase 3 too**, for the same class of reason: phase 3 without it commits every
STL and STEP as content, which is the storage explosion §5 exists to prevent.

---

## Shared interfaces — defined once, used by every phase

Any plan that disagrees with this section is wrong. Change it here first.

### The port verbs (phase 1 creates, phases 2–5 consume)

```ruby
# All four raise FileLayer::NotImplementedError on a backend whose
# capabilities.repo_storable? is false. `rel` is relative to the project's `.git`
# directory — "objects/pack/pack-abc.pack", "refs/heads/main", "HEAD".
FileLayer.current.write_repo_data(user, project:, rel:, io:)         # -> nil
FileLayer.current.read_repo_data(user, project:, rel:)               # -> String (binary)
FileLayer.current.list_repo_data(user, project:, prefix: nil)        # -> Array<String> of rels
FileLayer.current.delete_repo_data(user, project:, rel:)             # -> nil
```

**`read_repo_data` raises `FileLayer::NotFound` for a missing rel** and `FileLayer::FetchError` for
a transient transport failure — the same split the existing read path uses, for the same reason
(§14a: an unmounted share must never read as "permanently gone").

**None of these create a `Node`.** That is the entire point; see phase 1.

### The capability (phase 1)

```ruby
FileLayer::Capabilities = Data.define(:versioned, :syncable, :presignable, :scannable,
                                      :port_writable, :dir_deletable, :repo_storable)
```

True on all three backends today. **That agreement is three samples, not an identity** — see
phase 1 for the argument this capability must carry, per §14b's standing warning about
`scannable`/`port_writable`/`dir_deletable`.

### The git layer (phase 2 creates)

```ruby
Maker::Git::PackWriter.write(dir, objects)   # objects: [[oid_hex, type, payload], ...]
                                             # -> { name:, bytes:, count: }
Maker::Git::Repo.for(project)                # -> Maker::Git::Repo
  #hydrate!                                  # library -> cache (no-op on share)
  #commit!(paths:, message:)                 # -> oid String, or nil if nothing changed
  #consolidate!                              # loose -> one pack; returns pack name or nil
  #persist!                                  # cache -> library
  #head_oid                                  # -> String or nil
  #log(limit:)                               # -> Array<Maker::Git::CommitInfo>
  #blob_at(oid:, path:)                      # -> String (binary)
Maker::Git::CommitInfo = Data.define(:oid, :message, :author, :time, :parent_oids)
```

### The tracking rule (phase 3 creates)

```ruby
Maker::Git::Tracking.mode_for(name)          # -> :content | :pointer
Maker::Git::Tracking.pointer_for(node)       # -> String, the 3-line pointer body
```

**Derived from `Maker::FileAttachment::ROLE_BY_EXT`, never a second extension table.** §14d records
that a parallel hand-written list is exactly the drift `FilesHelper::EXT_FAMILIES` was rewritten to
end.

### The bookkeeping table (phase 2 creates)

```ruby
# maker_git_repos
#   project_id   :integer  not null, unique, FK -> maker_projects
#   head_oid     :string
#   last_commit_at :datetime
```

An **index, not a source of truth.** The authoritative "this repo is app-managed" marker is a git
config key, `tinkerex.managed = true`, written at init — it travels with the repo, so a maker who
drops their *own* repo into `Projects/` is never mistaken for a managed one (§8.1).

---

## Invariants every phase must respect

Each has a named consequence. None is a style preference.

| rule | consequence if broken |
|---|---|
| **The repo verbs create no `Node`** | A live node under `.git` is a ghost no scan can pair; its tombstone trips the mass-deletion guard and refuses that scan **and every scan after it, permanently**. §14b records four such wedges |
| **`NotImplementedError` stays un-rescued** | It is a `ScriptError`, not a `StandardError` — `rescue => e` and `retry_on` silently miss it. Gate on the capability *before* the call (§14a) |
| **Mutation-check every guard** | Break the thing a new test forbids, confirm RED, restore. This repo's dominant failure mode is a green suite over something that never worked (§15) |
| **Historical previews render on demand** | Eager per-version generation re-creates the row+blob leak §14b collapsed `Maker::Preview` to fix |
| **Backend legs report identical run counts** | `bin/ci test`, `test-s3`, `test-chunk-remote`. A structural difference means a test depends on ambient `LIBRARY_BACKEND` (§15) |
| **Track-by-role derives from `ROLE_BY_EXT`** | A second extension table drifts; §14d has the receipts |

---

## Definition of done, per phase

- `bin/ci` green — every gate `bin/ci --list-ci` names, not a hand-picked subset.
- The three backend legs report **identical run counts** (±2 assertions is the known flap,
  `tinkerex#131`; a structural difference is a real bug).
- `bin/ci test-chunk-remote` needs `../tinkerex-sync` checked out. From a worktree, set
  `TINKEREX_SYNC_DIR`.
- Every new guard mutation-checked, with the mutation named in the commit message.
- The arc filed with `bin/log arc --from-pr <n>` **as the PR opens**, not afterwards (§15).
