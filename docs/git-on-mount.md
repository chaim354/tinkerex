# Git on the mounted sync filesystem — findings + MVP

> **HISTORICAL — not re-verified.** Written before the repository split of 2026-08-20, when the
> sync engine and the Rust client still lived here (they are `chaim354/tinkerex-sync` and
> `chaim354/tinkerex-client` now). Kept for its reasoning and its measurements; it does not
> describe what this repository contains today. The current map is `docs/README.md`.


**Question:** does a `git` repository work *inside* the Maker Server mounted sync
filesystem (the `fs-provider` tree surfaced via FUSE/WebDAV/CfAPI)?

**Short answer:** **Yes for the everyday loop** (`init`/`add`/`commit`/`status`/
`log`/`diff`/`branch`/`checkout`) — the model already supported the hard parts
(atomic `index.lock`→`index` rename, `O_EXCL` lockfiles, exec-bit). The **one real
gap was symlinks** (the tree modeled only `File`/`Dir`, so any symlink hit `EPERM`);
this MVP **adds symlink support** end to end. **Hardlinks remain a documented gap**
(git degrades gracefully — see below).

---

## What git needs → how the model maps

| Git requirement | Where it lands | Status |
|---|---|---|
| Many small files + nested `mkdir` (objects, refs) | `create`/`mkdir`, SQLite tree | ✅ works |
| Atomic rename over existing (`index.lock`→`index`) | `Provider::rename` POSIX-replace + tombstone | ✅ works (already hardened) |
| `O_EXCL` lockfile create (`*.lock`) | `create` → `AlreadyExists` (EEXIST) on dup | ✅ works |
| Exec bit on hooks / 100755 blobs | `set_mode`, synced in `mode` column | ✅ works + syncs |
| `stat`/`lstat`/`readdir` ordering | `getattr`/`readdir` (name-ordered) | ✅ works |
| fsync/durability | `flush` finalizes a content-addressed manifest atomically | ✅ works |
| **Symlinks** (store mode 120000, checkout via `symlink(2)`) | **NEW: `Kind::Symlink` + target blob** | ✅ **added (this MVP)** |
| mmap on packfiles (read mmap over FUSE) | FUSE read path serves bytes; kernel mmaps over it | ✅ works on real FUSE (read-only mmap) |
| **Hardlinks** (`clone --local`, alternates) | tree is `(parent,name)`-unique → 2 names→1 inode not modeled | ❌ **documented gap** (git falls back to copy) |

---

## The MVP that was implemented: symlinks

`Kind::Symlink` was added to the node model, carrying the link **target bytes** in a
new `nodes.symlink_target` BLOB column.

- **Provider seam:** `Provider::symlink(parent, name, target) -> Attr` and
  `Provider::readlink(ino) -> Vec<u8>` (default impls return `NotSupported`, so any
  other Provider/adapter is unaffected; `SqliteProvider` stores + syncs).
- **Sync round-trip:** `SyncNode.symlink_target` is exported by `export_tree` /
  `sync_node` and restored by `apply_remote`, so a symlink **replicates device→device
  byte-identical** (the target is the content; no chunks/manifest).
- **FUSE adapter:** `fs-fuse` now implements the `symlink`/`readlink` kernel callbacks
  (previously a hard `EPERM` stub) and maps `Kind::Symlink → FileType::Symlink` in
  `getattr`/`readdir`.

### Tested at which layer

- **Provider level (runs on macOS, hermetic):** `client/fs-provider/tests/git_on_mount.rs`
  — symlink create/readlink/readdir/dup, **sync round-trip** (`export_tree`/`apply_remote`
  and outbox→`sync_node`→`apply_remote`), symlink-target change propagation; plus
  git-critical-op guards (index.lock atomic rename, O_EXCL lockfile, exec-bit-survives-sync,
  loose-object fanout).
- **Real FUSE + real `git` (gold standard, Linux/Docker):**
  `client/test-conformance/git-on-fuse.sh` (+ `git-on-fuse-docker.sh` wrapper) mounts
  `maker-mount` over `SqliteProvider` and runs the actual `git` binary through the kernel
  mount: `init/add/commit/status/diff/log/branch/checkout`, **`ln -s` + `git add` + commit +
  `readlink` + `git ls-files` confirming mode 120000**, and `git clone --local` (with a
  `--no-hardlinks` fallback assertion). This is **Linux-only** (fuser links only on Linux);
  run it in CI or via the Docker wrapper from a macOS/Windows box.

  **Status on this build box (macOS):** the Docker wrapper **compiled `fs-fuse` cleanly on
  Linux and reached the live mount step** (the first run surfaced + fixed a real bug —
  fuser 0.17 rejects `AutoUnmount` under the Owner ACL; hence `MAKER_MOUNT_NO_AUTOUNMOUNT`).
  Full end-to-end execution could **not** complete here because **this Docker Desktop setup
  does not expose `/dev/fuse` to containers** (`docker run --device /dev/fuse …` never
  starts — a host/VM limitation, not a harness bug; verified directly). The harness is
  therefore **gated for a Linux CI runner / native-Linux box**, where `/dev/fuse` is real.
  This is the documented fallback the task anticipated: Provider-level coverage is the
  primary signal on macOS; the real-FUSE leg runs in CI.

---

## Workflows: works vs. doesn't (with the reason for each gap)

| Workflow | Through the mount | Notes |
|---|---|---|
| `git init` | ✅ | dirs + small files |
| `git add` / `git commit` | ✅ | object writes + `index.lock`→`index` atomic rename |
| `git status` / `git diff` / `git log` | ✅ | stat/readdir/read |
| `git branch` / `git checkout` | ✅ | tree swap; tested file appears/disappears across branches |
| symlink in repo (`ln -s`, checkout) | ✅ **(new)** | `Kind::Symlink`; `readlink` returns the target; git records 120000 |
| `git clone --local <repo>` | ⚠️ | git **tries hardlinks**; if the FS lacks `link(2)` git **automatically falls back to copying** (works, just no dedup). `--no-hardlinks` is the explicit path. |
| `git clone --local` *with* hardlink dedup | ❌ | **hardlinks unsupported** — see gap |

### Why hardlinks are a gap (and why it's OK for an MVP)

The tree enforces `UNIQUE(parent_ino, name)` and one row per name; a hardlink is **two
names pointing at one inode/content**. Modeling it means refcounted inode identity
distinct from the path — a real change to the data model with cross-device-identity and
delete-semantics implications. **Git does not require it:** `git clone --local` uses
hardlinks only as an optimization and **degrades to a plain copy** when `link(2)` fails
(and `--no-hardlinks` / a non-local clone never try). So git is fully functional without
hardlink support; only the local-clone storage optimization is lost. Recommended to leave
as a documented gap.

---

## End-to-end **server** sync of symlinks: the remaining piece

Symlinks round-trip through the **Provider** and the **in-process replica path**
(`apply_remote`/`sync_node`) today, and the wire `SyncNode.symlink_target` field exists.
**The Rails server does not yet model a symlink-kind node** (no schema/endpoint carrying
the link target), so `sync-engine`'s push **explicitly skips** `Kind::Symlink` (logged,
never silently corrupting the tree). Closing this is the follow-up:

1. Server: allow `kind = 'symlink'` on `nodes` + a `symlink_target` column on the
   version/commit (or a tiny inline-content path), surfaced in the tree + changelog views.
2. `sync-engine`: route `Kind::Symlink` through a `mkdir`-shaped metadata commit that
   carries the target (replace the skip), and populate `symlink_target` in the
   server→`SyncNode` conversions.
3. Extend the two-device real-mount E2E (`two-device-fuse.sh`) with a symlink case.

---

## Recommended follow-ups

1. **Server symlink support** (above) — promote symlink sync from Provider/in-process to
   full client⇄server⇄client.
2. **WebDAV/CfAPI/WinFsp symlink surfacing** — `fs-webdav` treats a symlink as a non-dir
   (no native WebDAV symlink); decide per-adapter behavior (macOS `mount_webdav` has no
   symlink verb, so a repo with symlinks on macOS is the weakest surface — document it).
3. **Hardlinks** — only if a concrete need appears; otherwise keep the documented gap.
4. **Wire `git-on-fuse.sh` into the Linux mount-conformance CI job** (it is self-contained
   and CI-automatable like `two-device-fuse.sh`).
