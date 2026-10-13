# POSIX compatibility of the file layer

> **HISTORICAL — not re-verified.** Written before the repository split of 2026-08-20, when the
> sync engine and the Rust client still lived here (they are `chaim354/tinkerex-sync` and
> `chaim354/tinkerex-client` now). Kept for its reasoning and its measurements; it does not
> describe what this repository contains today. The current map is `docs/README.md`.


What the `fs-provider` seam (and the mounts over it) does and does **not** guarantee about
POSIX filesystem semantics, and **why** — so a maker's tools behave predictably and we
don't re-litigate the deliberate gaps. This is the file-layer companion to `CLAUDE.md` §14
and `docs/roads-not-taken.md`.

The guiding constraint: the file layer is a **content-addressed, asynchronously-synced,
local-first** store (`CLAUDE.md` §2). The server tree is a strict tree keyed by
`(parent, name) → one stable node_id`, each file version an immutable content-addressed
manifest. Any POSIX feature that fits that shape we honor; any feature that would require
breaking it (multiple names → one inode, ownership ACLs, non-portable special inodes) is a
**deliberate non-goal**, documented below rather than forced.

Conformance is asserted two ways:
- **Hermetic, gating** — `client/fs-provider/tests/posix_errno.rs`,
  `posix_semantics.rs`, `posix_times.rs`, `chunking.rs`, `convergence.rs`, `caching.rs`
  (run on any dev box incl. macOS: `cd client/fs-provider && cargo test`).
- **Real-kernel-mount, informational** — pjdfstest / fsx through a live FUSE mount
  (`client/test-conformance/*.sh`; Linux only, runnable from macOS via Docker —
  `pjdfstest-docker.sh`). Informational because the bulk of its remaining failures are
  the deliberate non-goals below.

---

## Supported (honored + tested)

These map cleanly onto the tree/manifest model and are enforced at the Provider seam:

| Area | Behavior |
|---|---|
| **Tree ops** | `create`/`mkdir`/`unlink`/`rmdir`/`rename`/`lookup`/`readdir` with POSIX errnos. |
| **rename** | Atomic replace-over-existing (the editor write-temp-then-rename save), dir-over-empty-dir, node_id stable across move, cycle guard (move into own subtree → EINVAL), self-rename no-op. |
| **errno correctness** | ENOENT / ENOTDIR / EISDIR / EEXIST / ENOTEMPTY / ENAMETOOLONG (255-**byte** `NAME_MAX`, counted in bytes not chars) / EINVAL — pinned per op in `posix_errno.rs`. |
| **Permission bits** | Full 12-bit mode (`07777`, incl. setuid/setgid/sticky) round-trips through `chmod` and **syncs** across devices (the executable bit survives). Type bits (`S_IFMT`) are stripped. |
| **Timestamps** | Real **mtime** preserved end-to-end in unix **nanoseconds** (the source device's mtime verbatim on pull — not the sync time; build tools keying on mtime work). **atime** is settable + readable but **device-local** (never synced). `utimensat` semantics (set one, leave the other) honored. |
| **truncate** | Grow (zero-fill) / shrink (drop tail) / `O_TRUNC` to empty without hydrating a placeholder. No stale tail on overwrite-with-shorter. |
| **Symlinks** | `symlink`/`readlink`; target bytes synced verbatim (git checkout works — `docs/git-on-mount.md`). Conventional `lrwxrwxrwx` mode. Subject to the same `NAME_MAX` / parent-kind rules as the other node-creating ops. |
| **Kind safety** | `read`/`write`/`truncate`/`ingest_bytes` reject a directory (EISDIR) or symlink (EINVAL) target — they cannot stamp a file manifest onto a non-file row and corrupt the tree. |
| **Advisory locks** | POSIX byte-range `F_SETLK`/`F_GETLK`/`F_UNLCK` (device-local; best-effort cross-device coordination layered above). |
| **Data integrity** | FastCDC chunking + content-addressed dedup; byte-for-byte across devices; fsx-clean data plane. |

---

## Deliberate non-goals (cannot fit the distributed / content-addressed model)

These are **not** bugs to fix — fixing them would break a core invariant. They surface as
pjdfstest failures concentrated in the `chown`/owner and special-file subtests.

### 1. Ownership: uid / gid / chown — NOT modeled
- **What:** no per-file owner/group; `chown`/`chgrp` are not honored; the owner-sensitive
  pjdfstest subtests (run as uid 65534) fail (EACCES / wrong uid,gid).
- **Why it's out of scope:** **tenant = user** (`CLAUDE.md` §8). A library is one user's own
  devices; there is exactly one owner. Per-file ownership ACLs are the JuiceFS-style
  multi-tenant problem the sync model deliberately avoids — isolation is ordinary Rails
  `user_id` scoping, not in-tree ACLs. Modeling uid/gid would add a cross-device-meaningless
  field (uids differ per machine) for no product value.
- **Workaround:** the mount runs as the user, who owns everything. Mode bits (rwx + special)
  *are* preserved and synced; only the owner identity is not.

### 2. Hardlinks: `link(2)` / `st_nlink > 1` — NOT supported (EPERM)
- **What:** creating a second name for the same inode fails; `nlink` is always 1.
- **Why it's out of scope:** the server tree is keyed `(parent, name) → one node_id`, and a
  version is an immutable content-addressed manifest. A hardlink means **two names → one
  inode with shared mutable content**: editing through one name must change the other. The
  changelog/manifest model has no representation for "same inode, two tree positions" — it
  would require a separate inode-identity layer beneath the tree, a core-model change.
- **Note:** content-addressed **dedup already gives the storage benefit** of hardlinks
  (identical files share chunks) without the shared-identity semantics. Two copies of the
  same bytes cost one copy on disk; they're just independent tree nodes.
- **Workaround:** none at the FS level. Tools that hardlink as an optimization (some
  build/backup tools) get two deduped copies instead — correct, just not nlink-visible.
- **A core-model change would be needed** to support true hardlinks → out of scope per the
  task's rule 5; not planned.

### 3. Special files: FIFO / socket / block & char device (`mknod`) — NOT supported (EPERM)
- **What:** `mkfifo`, `mknod c/b`, named sockets are rejected (the fs-fuse G8 guardrail;
  `mknod(S_IFREG)` for plain-file creation *is* accepted).
- **Why it's out of scope:** these inodes have **no portable cross-device meaning** — a
  device node's major/minor or a FIFO's kernel buffer is local kernel state, not file
  content to sync. The tree models only File / Dir / Symlink (the three with portable,
  syncable content). Storing a device node would sync a number that means something
  different (or nothing) on the next machine.
- **Workaround:** none; these don't belong in a synced maker library.

### 4. ctime (inode change time) — NOT separately tracked
- **What:** `Attr` carries `mtime` + `atime` but no distinct `ctime`. `getattr` reports
  mtime in the ctime slot at the adapter.
- **Why it's a constraint:** ctime is *device-local metadata-change* state with no
  cross-device meaning (every pull is a local metadata change at a different wall time);
  syncing it would be both wrong and chatty, like atime. mtime (true modification time) is
  the timestamp tools actually key on, and it *is* synced. A separate device-local ctime
  column could be added if a real tool needs it, but nothing observed does.
- **Status:** documented constraint, not a planned change.

### 5. per-component ENAMETOOLONG via unlink/rmdir/lookup of a >255-byte name
- **What:** the **node-creating** ops (`create`/`mkdir`/`rename`/`symlink`) return
  ENAMETOOLONG for a >255-byte component (tested). `unlink`/`rmdir`/`lookup` of a
  non-existent over-long name return ENOENT (the entry can't exist), where bare pjdfstest
  expects ENAMETOOLONG.
- **Why it's effectively a non-issue:** on a **real kernel mount** the VFS rejects an
  over-long component with ENAMETOOLONG *before the request reaches the filesystem*, so the
  end-to-end behavior is correct regardless of the Provider. The discrepancy only appears
  when pjdfstest runs directly against a FUSE path that forwards the long name. Adding a
  length check to every lookup/unlink/rmdir would put a redundant guard on the hot path for
  a case the kernel already handles. Left as-is intentionally.

---

## Gaps CLOSED in the `night/posix-compat` batch (2026-06-16)

All TDD (failing hermetic `fs-provider` test first), all within the distributed model — no
manifest/sync/protocol change:

1. **`symlink` now enforces `NAME_MAX`** (ENAMETOOLONG) like the other node-creating ops —
   it was the one that skipped `check_name_len`, leaking a generic Db error.
2. **`read`/`write`/`truncate` reject the wrong node kind** — a directory → EISDIR, a
   symlink → EINVAL. Previously `read(dir)` returned an empty buffer and `write`/`truncate`
   on a dir/symlink **corrupted the tree** by stamping a file manifest onto the row (a
   symlink lost its target; a dir became a file). `read(symlink)` returned the target bytes
   instead of EINVAL.
3. **`readdir` on a non-directory is ENOTDIR**, on a missing inode ENOENT — it was a bare
   `parent_ino = ?` query returning an empty Vec for a file/symlink/missing ino alike.
4. **`ingest_bytes`** (the CfAPI/Windows local-edit capture path) gained the same kind
   guard — re-ingesting onto a dir/symlink would corrupt the tree.

---

## Conformance run status (this batch)

- **Hermetic `fs-provider` suite:** green (run on macOS, gating).
- **pjdfstest via real FUSE (Docker):** ran here (`pjdfstest-docker.sh`). Residual failures
  concentrate in the deliberate non-goals above (chown/uid-gid, mkfifo/mknod, hardlink
  `link`→EPERM). **Observed a mount-process abort during the rmdir subtests** — a crash in
  the `fs-fuse` adapter binary (not the hermetic Provider), worth a dedicated look by the
  mount team; it does not affect the hermetic Provider guarantees.
- **fsx via real FUSE:** not run in this batch (Linux-only; runnable via the same Docker
  approach). The data plane it exercises (chunking/offset/truncate) is unchanged by this
  batch and is covered by the hermetic `chunking`/`caching`/`convergence` suites.
