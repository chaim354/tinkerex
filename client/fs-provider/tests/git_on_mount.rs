//! Git-on-mount: does a git repository work inside the Maker Server sync filesystem?
//!
//! Git is the canonical "small-files + atomic-rename + lockfile + symlink" workload. These
//! tests simulate, at the `Provider` level (the layer that runs on every OS), the exact
//! syscall sequences `git` issues — so we get a real signal on macOS where `fs-fuse` can't
//! link. The gold-standard real-FUSE signal lives behind a Linux/Docker harness (see the PR
//! notes); this suite is the mechanical backstop for the git-critical operations.
//!
//! What git needs (mapped to the model):
//! - many small files + `mkdir` (objects, refs)            → File/Dir, already supported
//! - atomic rename over an existing name (`index.lock`→`index`) → `rename` POSIX-replace, supported
//! - O_EXCL lockfile create (`*.lock`)                      → create must fail EEXIST if present
//! - chmod exec bit (hooks, mode 100755 blobs)              → `set_mode`, already synced
//! - **symlinks** (a repo can contain/check out a symlink)  → NEW: `Kind::Symlink` + target
//! - hardlinks (`clone --local` object dedup)               → documented gap (git degrades)

mod common;
use common::*;

use fs_provider::{FsError, Kind, Provider};

// ---------------------------------------------------------------------------
// Symlink support — the git-critical gap this MVP closes.
// A git repo can store a symlink (mode 120000); `git checkout` then calls
// symlink(2) to materialize it, and `git status`/`git add` call lstat+readlink.
// ---------------------------------------------------------------------------

#[test]
fn symlink_then_readlink_roundtrips_the_target() {
    let p = provider();
    let attr = p.symlink(ROOT, "link", b"target/path.txt").unwrap();
    assert_eq!(attr.kind, Kind::Symlink);
    // lstat reports the symlink itself (size = target length).
    let st = p.getattr(attr.ino).unwrap();
    assert_eq!(st.kind, Kind::Symlink);
    // readlink returns the stored target bytes verbatim.
    assert_eq!(p.readlink(attr.ino).unwrap(), b"target/path.txt");
}

#[test]
fn symlink_shows_in_readdir_as_a_symlink() {
    let p = provider();
    p.symlink(ROOT, "link", b"elsewhere").unwrap();
    let entry = p.readdir(ROOT).unwrap().into_iter().find(|e| e.name == "link").unwrap();
    assert_eq!(entry.kind, Kind::Symlink);
}

#[test]
fn readlink_on_a_regular_file_is_an_error() {
    let p = provider();
    let f = write_file(&p, ROOT, "f", b"not a link");
    assert!(matches!(p.readlink(f), Err(FsError::NotSupported) | Err(FsError::NotFound)));
}

#[test]
fn symlink_duplicate_name_is_already_exists() {
    let p = provider();
    p.symlink(ROOT, "link", b"a").unwrap();
    assert!(matches!(p.symlink(ROOT, "link", b"b"), Err(FsError::AlreadyExists)));
}

// ---------------------------------------------------------------------------
// Symlinks must round-trip through sync (export_tree / sync_node / apply_remote)
// or a checked-out symlink would vanish (or arrive empty) on the other device.
// ---------------------------------------------------------------------------

#[test]
fn symlink_round_trips_through_export_and_apply() {
    let (a, b, _store) = shared_store_pair();
    a.symlink(ROOT, "link", b"../objects/pack").unwrap();

    // export_tree carries the kind + target; apply on B reconstructs it.
    replicate_tree(&a, &b);

    let st = b.lookup(ROOT, "link").unwrap();
    assert_eq!(st.kind, Kind::Symlink);
    assert_eq!(b.readlink(st.ino).unwrap(), b"../objects/pack");
}

#[test]
fn symlink_round_trips_through_sync_node_outbox() {
    // The daemon path: a local symlink enqueues an outbox upsert; sync_node yields a
    // SyncNode the replica applies. (sync_to drives outbox→sync_node→apply_remote.)
    let (a, b, _store) = shared_store_pair();
    a.symlink(ROOT, "HEAD", b"refs/heads/main").unwrap();

    sync_to(&a, &[&b]);

    let st = b.lookup(ROOT, "HEAD").unwrap();
    assert_eq!(st.kind, Kind::Symlink);
    assert_eq!(b.readlink(st.ino).unwrap(), b"refs/heads/main");
}

#[test]
fn changing_a_symlink_target_propagates() {
    let (a, b, _store) = shared_store_pair();
    a.symlink(ROOT, "cur", b"v1").unwrap();
    sync_to(&a, &[&b]);
    // Atomic-swap a symlink the way tooling does: new temp link, rename over.
    a.symlink(ROOT, "cur.tmp", b"v2").unwrap();
    a.rename(ROOT, "cur.tmp", ROOT, "cur").unwrap();
    sync_to(&a, &[&b]);

    let st = b.lookup(ROOT, "cur").unwrap();
    assert_eq!(b.readlink(st.ino).unwrap(), b"v2");
}
