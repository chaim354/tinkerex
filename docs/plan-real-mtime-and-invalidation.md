# Plan: preserve real mtime + active cache invalidation (Option B)

**Status:** planned, not implemented. Hand-off doc for the implementing agent.
**Decision:** chosen over (A) the current `mtime = now`-on-pull hack and (C) disabling the
kernel page cache. See the rationale + CfAPI/File-Provider forward-compat analysis below.

## Why

`mtime` is currently doing two incompatible jobs. On pull, `apply_remote` stamps
`mtime = now` (and `flush` does too) so the kernel's FUSE attr cache (1 s TTL) notices a
change and re-reads — the freshness fix. But that **destroys the real modification time**:
on every device a synced file looks "just modified," which (a) breaks incremental build
tools (`make`/`ninja`/`cargo` rebuild everything; with clock skew can *miss* a rebuild) and
(b) shows the sync time, not the edit time, in file managers.

Option B splits the two jobs:
1. **Preserve the real mtime** end-to-end (sync it as metadata; apply it on pull) — so a
   file has one true, stable mtime everywhere.
2. **Invalidate the OS cache explicitly** when a node's content changes on pull, instead of
   relying on an mtime bump — via an adapter hook (FUSE `notify_inval_inode`, etc.).

**This also future-proofs the native-API migrations.** Windows → CfAPI and macOS → File
Provider both use the same model: *you* own the truth, set the placeholder's metadata
(including `LastWriteTime` / `contentModificationDate`), and signal changes explicitly
(`CfUpdatePlaceholder` / `signalEnumerator`). Option B's two primitives map 1:1 onto those;
Option A's mtime-bump has **no** equivalent and would have to be unwound at migration. So B
is a down-payment on CfAPI, not a detour.

## Design

### 1. An adapter `Invalidate` hook (the key abstraction)
Add a hook trait alongside the existing `Hydrate` / `Freshness` / `RemoteLock` traits (same
pattern — see `client/fs-fuse/src/lib.rs` and `EngineHydrator`/`EngineFreshness` in
`client/sync-engine/src/lib.rs`):

```rust
// fs-fuse (and parallel hooks in fs-webdav / fs-winfsp)
pub trait Invalidate: Send + Sync {
    /// A pulled change altered this inode's content — drop the OS-level cache so the next
    /// read re-fetches. Best-effort.
    fn invalidate(&self, ino: u64);
}
```

The **sync loop** calls it: in `SyncEngine::pull_changes` / `apply_change`, after
`apply_remote` updates a node whose `manifest_id` actually changed, call
`invalidate(ino)`. Implement per adapter:
- **fs-fuse (Linux):** `fuser`'s `Notifier` (`SessionUnmounter`/`Notifier` from
  `spawn_mount2`'s `BackgroundSession`) → `notify_inval_inode(ino, 0, 0)`. The `Daemon`
  (`client/sync-engine/src/daemon.rs`) already owns the session handle — thread the
  `Notifier` into an `EngineInvalidate` hook.
- **fs-winfsp / fs-webdav (today):** no clean push-invalidation; rely on short metadata
  timeouts (document as weaker). Implement the hook as a no-op or a best-effort equivalent.
- **CfAPI / File Provider (future):** `CfUpdatePlaceholder` (optionally dehydrate) /
  `signalEnumerator`. The hook is the seam that makes these "just another adapter."

Build the hook abstraction even though only FUSE has a strong impl today — that's what
makes the CfAPI/File-Provider migration a drop-in.

### 2. Preserve real mtime through the stack
Mirror exactly the cross-stack threading already done for `mode` and `version_id` (commits
on this branch — use them as the template):
- **fs-provider:** stop stamping `mtime = now` in `apply_remote` and `flush`. Instead:
  - `flush` sets mtime to the file's real modification time. Source it from the FUSE
    `setattr(mtime)` the kernel sends, falling back to "now" only for a genuinely new local
    write. (Add a `set_mtime(ino, mtime)` provider method + wire `fs-fuse` `setattr`'s
    `mtime`/`atime` args to it.)
  - `apply_remote` writes the **synced** mtime from `SyncNode`, not `now`.
  - Add `mtime` to `SyncNode`; carry it in `export_tree` / `sync_node`.
- **server:** store mtime on the node (`nodes.mtime`, carried through `pending_commits` like
  `mode`); `Commit`/`mkdir` accept + store it; `Sync::Tree` + `Sync::Changes` serialize it.
- **sync-client:** `CommitBegin.mtime`, `NodeView.mtime`, `TreeNode.mtime`.
- **sync-engine:** `push_node` sends mtime; `change_to_sync` / `tree_node_to_sync` read it.

### 3. Widen mtime resolution to nanoseconds (do this now)
Current mtime is `i64` **unix seconds**. CfAPI/NTFS use `FILETIME` (100 ns) and build tools
want sub-second precision. Store mtime as **nanoseconds** (i64 unix nanos, or a
`(secs, nanos)` pair) in `fs-provider.nodes`, the server `nodes` table, and on the wire.
Doing it now avoids re-introducing the coarseness *and* a second migration when CfAPI lands.
Conversions: unix-nanos ↔ FUSE `Duration` ↔ FILETIME (100 ns ticks since 1601) ↔ `NSDate`.

## Edit checklist (layer by layer)

- [ ] fs-provider: nanos `mtime` column (ALTER for old DBs); `set_mtime`; `flush`/`apply_remote`
      use real/synced mtime not `now`; `SyncNode.mtime`; export/sync/apply carry it;
      `Attr.mtime` → nanos; `file_attr` maps nanos → `SystemTime`.
- [ ] fs-fuse: `setattr(mtime/atime)` → `set_mtime`; `Invalidate` hook + impl; report nanos mtime.
- [ ] sync-engine: `EngineInvalidate` (holds the FUSE `Notifier`); call `invalidate(ino)` from
      `pull_changes` on a content change; `push_node` sends mtime; converters read it; wire into `Daemon`.
- [ ] sync-client: `CommitBegin.mtime`, `NodeView.mtime`, `TreeNode.mtime`.
- [ ] server: migration `nodes.mtime` + `pending_commits.mtime`; `Commit`/`mkdir` store;
      `Tree`/`Changes` serialize; controllers permit `:mtime`.
- [ ] remove the `now_secs()`-on-apply behavior; keep `now` only as the fallback for a brand-new local write with no kernel-supplied mtime.

## Testing

- fs-provider: a pulled node keeps the **source** mtime (not `now`) — `apply_remote` with a
  given mtime → `getattr` returns it; survives reopen. (Model on `tests/caching.rs`.)
- server: `Commit`/`Tree` round-trip mtime (model on the `mode` test in `commit_test.rb`).
- integration: A writes a file with mtime T, B pulls → B's `getattr` mtime == T (not sync
  time). (Model on `executable_bit_propagates_across_devices`.)
- **Invalidation can't be unit-tested** (needs a live FUSE kernel mount) — verify via the
  Linux CI `mount-conformance` path / a manual smoke test (edit on A, `cat` on B before vs.
  after, confirm fresh without the mtime hack). Note it in the PR.

## Gotchas

- The FUSE `Notifier` must outlive the mount and be callable from the sync thread; get it
  from `spawn_mount2`'s `BackgroundSession` in `Daemon::start`.
- WebDAV (macOS today) and WinFsp have weak/no explicit invalidation — B's freshness on
  those leans on short metadata timeouts until CfAPI/File-Provider land. Don't block on them.
- Keep the freshness-on-open pull (`EngineFreshness`) — it's complementary (it ensures the
  *tree* is current before an open; invalidation ensures the *kernel data cache* is current
  after a pull).
- Don't sync ownership (uid/gid) — meaningless across devices (intentional non-goal, same as
  the `mode` work).
