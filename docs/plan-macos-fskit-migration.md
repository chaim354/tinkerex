# macOS FSKit migration — sketch

A forward-looking design sketch (NOT an implementation) for moving the macOS mount path from
**WebDAV** (`fs-webdav`, native `mount_webdav`) to **FSKit**, Apple's native, kext-free
filesystem-extension framework. Scoped per `docs/superpowers/specs/2026-06-12-phase2b-ci-fskit-design.md`.
This ends as a committed doc; no code lands from it.

---

## 1. Why move off WebDAV

WebDAV got us a *native, no-kext* macOS mount when FUSE-T's FSKit build couldn't mount on
macOS 26 (silent fail; the System-Settings extension toggle greyed — see `CLAUDE.md` and
`docs/STATUS.md`). It works and is verified live, but it has structural ceilings:

- **HTTP semantics, not filesystem semantics.** `mount_webdav` speaks a chatty HTTP protocol to
  our in-process `dav-server`; metadata timeouts (not active invalidation) drive freshness, so
  the Option-B `invalidate(ino)` seam is a no-op on macOS today (we lean on cache timeouts).
- **No POSIX-mode / xattr fidelity, weaker mtime control** vs a real FS surface (the conformance
  runs already flagged POSIX-perms gaps as deliberate on WebDAV).
- **Not the principled endpoint.** Linux has FUSE, Windows has WinFsp→CfAPI; macOS should have a
  native in-process FS too. FSKit is that — permissive (no GPL kext, satisfies §9), Apple-shipped,
  and the peer of the other two mounts over the *same* `Provider`.

## 2. The key architectural call: FSKit ≈ FUSE, not ≈ CfAPI

This is the most important framing for whoever builds it. macOS offers **two** native models:

| Model | Shape | Our analogue | Used by |
|---|---|---|---|
| **FSKit** (`FSUnaryFileSystem`/`FSVolume`) | A full **userspace filesystem** the kernel mounts; you answer `lookup`/`enumerate`/`read`/`write`/`create`/`remove`/`rename` callbacks | **`fs-fuse`** (in-process FS over `Provider`, hydrate-on-read) | replacing FUSE/NFS-style mounts |
| **File Provider** (`NSFileProviderExtension`) | A **placeholder / on-demand sync** surface (materialize-on-demand, dehydrate) | **`fs-cfapi`** (placeholders, FETCH_DATA, pin/unpin) | iCloud Drive, Dropbox, OneDrive |

The user asked for **FSKit**, so this sketch targets the FUSE-shaped model: a full FS over the
`Provider` with **hydrate-on-read**, NOT a placeholder model. Practically that means
**`fs-fskit` mirrors `fs-fuse` far more than `fs-cfapi`** — the write path is *direct* callbacks
(`createItem`/`removeItem`/`renameItem` → `Provider`), with none of CfAPI's NOTIFY/pre-op-ACK
dance or `delete_by_node_id`/placeholder bookkeeping. The Phase 2b B1–B4 work informs it only by
analogy (the same operations, simpler plumbing). If we later want true on-demand
dehydration/"free up space" on macOS, that's a **File Provider** effort, tracked separately — call
that out so the two don't get conflated.

## 3. Module shape

```
client/fs-fskit/                 # parallels client/fs-fuse
  Cargo.toml                     # cfg(target_os = "macos"); inert empty crate elsewhere
  src/lib.rs                     # Rust side: the FsKitBridge over Arc<SqliteProvider> + Hydrate
  swift/                         # the FSKit extension (Swift) — an .appex bundled in maker-app
    MakerFSExtension.swift       # FSModule / FSUnaryFileSystem / FSVolume conformances
    Bridge.swift                 # @_cdecl Swift ↔ Rust FFI shims
```

- A `sync_engine::FsKitMount` (in `client/sync-engine/src/daemon.rs`, `#[cfg(target_os = "macos")]`)
  wired behind the per-OS `Mount` alias in `client/maker-app/src-tauri/src/lib.rs` — exactly how
  `WebdavMount`/`FuseMount`/`CfApiMount` are selected today. WebDAV stays reachable behind a
  cargo feature for one release (same pattern as the Windows WinFsp→CfAPI flip, Task B5).
- It reuses the **same shared seams** already built: `Arc<SqliteProvider>` (the `impl Provider for
  Arc<P>` from the daemon work), the `Hydrate` hook (chunk-miss → presigned GET → cache → retry),
  the Option-B **real-nanos mtime** (`set_mtime`/`apply_remote` write the source mtime verbatim),
  and the `Invalidate` seam — which on FSKit becomes a **real** active invalidation (see §5),
  unlike the WebDAV no-op.

## 4. The Swift/Rust FFI boundary

FSKit is Swift/ObjC-only; the FS logic stays in Rust (`Provider`). Mirror how `fs-cfapi` bridges
the `windows` crate, but in the opposite direction (Swift calls *into* Rust):

- **Rust exposes a C ABI** (`#[no_mangle] pub extern "C"`) over the `Provider`: `fskit_lookup`,
  `fskit_enumerate`, `fskit_read(ino, off, len, *buf)`, `fskit_write`, `fskit_create`,
  `fskit_remove`, `fskit_rename`, `fskit_getattr`, `fskit_setattr` — each translating FSKit's
  item-identifier model to our `ino`/`node_id`. A leaked `Box<FsKitBridge { provider, hydrate }>`
  handle is passed back and forth as an opaque pointer (the `CfState`/`Box::into_raw` pattern from
  `fs-cfapi`).
- **Swift calls them** from the `FSVolume.Operations` conformances; the extension is packaged as an
  `.appex` with the FSKit entitlement, bundled in the Tauri app and registered with the system.
- Item identity: FSKit uses `FSItem` + 64-bit identifiers — map directly to our `ino` (stable
  per-device), with `node_id` carried for cross-device identity exactly as the other mounts do.

## 5. Hydration + write-capture mapping

- **Read / hydrate:** FSKit `read(_:from:into:)` → `fskit_read` → `Provider::read`; on a
  `ChunkMissing` the bridge runs the **same** `EngineHydrator` (presigned GET) then retries — the
  exact mechanism `fs-fuse` uses. No placeholder state machine.
- **Active invalidation:** a pulled remote change calls the `Invalidate` seam. FSKit can purge the
  kernel cache for an item (the FSKit analogue of FUSE's `notify_inval_inode`, abi-7-12) — so the
  macOS `invalidate(ino)` becomes a real call instead of the WebDAV timeout no-op. This is the
  same primitive slot the Option-B plan reserved (`docs/plan-real-mtime-and-invalidation.md`).
- **Write capture:** direct — FSKit `createItem`/`removeItem`/`renameItem`/`write` → the
  corresponding `Provider` mutation (`create`+`ingest`/`flush`, `unlink`, `rename`) → outbox →
  push. This is the FUSE write path, *not* the CfAPI NOTIFY/ACK path; the B0 primitives
  (`delete_by_node_id` etc.) aren't needed here since FSKit hands us parent+name like FUSE does.

## 6. Verification posture

Like CfAPI, **live FSKit behavior is macOS-only and can't be exercised in a Linux/MSVC CI job**:
- Build/typecheck: the Rust `fs-fskit` crate builds in the existing matrix; the Swift extension
  needs Xcode on the **self-hosted macOS runner** (now available via Track A's `macos` runner).
- A `macos-fskit-smoke` job (the macOS analogue of `windows-smoke`/`mount-conformance`): mount the
  FSKit volume, run the rclone⇄FS + fsx data-integrity suites already in
  `client/test-conformance/` against it, assert a write round-trips to the server. Until that
  exists, the manual smoke (mount in Finder via the app, push/read-back hash-match) is the gate —
  the same bring-up loop CfAPI used.

## 7. Open questions / risks (resolve before committing to build)

1. **The greyed-toggle root cause.** Why FUSE-T's FSKit build couldn't mount on macOS 26 (silent
   fail, greyed System-Settings toggle) must be understood first — it may be an entitlement /
   signing / provisioning issue that bites our own extension identically. **De-risk with a minimal
   "hello-world" FSKit extension that mounts an empty volume before investing in the bridge.**
2. **macOS version floor.** FSKit is recent (Sequoia 15.4+, mature in macOS 26). Setting the floor
   drops older macOS users — keep **WebDAV as the fallback** for them (the cargo-feature gate makes
   this a config choice, not a fork).
3. **Packaging & signing.** The `.appex` needs the FSKit entitlement, a Developer ID, notarization,
   and system registration from inside a Tauri app bundle — non-trivial and not yet proven in our
   build. Spike this early.
4. **FSKit vs File Provider, deliberately.** If "Always keep on this device / Free up space"
   (true dehydration) becomes a macOS requirement, FSKit is the wrong tool — that's a File Provider
   project. Decide up front that FSKit = "native full mount" and dehydration-on-macOS is out of
   scope (or a separate later track), so the goalposts don't move mid-build.
5. **Stability to ship.** Confirm FSKit is production-stable for a third-party FS (Apple positioned
   it as the FUSE successor, but real-world third-party deployments are still young). If not, the
   WebDAV fallback stays the shipping default until it is.

**Bottom line:** FSKit is the right principled macOS endpoint and slots cleanly over the existing
`Provider` + hydrate + invalidate + Option-B-mtime seams as a FUSE-shaped mount. The work is
mostly the **Swift extension + FFI bridge + packaging/signing**, not new sync logic. Gate the
build on de-risking the greyed-toggle/signing issues (#1, #3) with a hello-world extension first,
and keep WebDAV behind a feature flag as the fallback.
