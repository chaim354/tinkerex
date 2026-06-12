//! Client-side caching & freshness. Two properties the mount depends on:
//!  1. A hydrated file supports random writes (the write path seeds from committed
//!     content — the adapter's open-for-write hydrates the whole file so this can't miss).
//!  2. A pulled remote change updates BOTH the content (new manifest → reader re-hydrates)
//!     AND `mtime` — the signal apps and the kernel use to notice a file changed and drop
//!     a stale cached copy. (mtime used to be permanently 0, so a same-size edit on
//!     another device was invisible: the "opened a minute later, didn't propagate" bug.)

mod common;
use common::*;

use fs_provider::Provider;

#[test]
fn flush_sets_a_nonzero_mtime() {
    let p = provider();
    let ino = write_file(&p, ROOT, "f.bin", b"hello");
    assert!(p.getattr(ino).unwrap().mtime > 0, "a committed file carries a real mtime, not 0");
}

#[test]
fn remote_update_bumps_mtime_and_serves_fresh_content() {
    // B has the file cached. A overwrites it. After B applies A's new manifest (what a
    // pull does), B must read the NEW content and see a bumped mtime — never the stale
    // copy. (Shared chunk store stands in for the cloud, so B can read A's chunks.)
    let (a, b, _dir) = shared_store_pair();
    let a_ino = write_file(&a, ROOT, "doc.txt", b"version one");
    replicate_tree(&a, &b);

    let b_ino = b.lookup(ROOT, "doc.txt").unwrap().ino;
    let m1 = b.getattr(b_ino).unwrap().mtime;
    let manifest1 = node_named(&b, "doc.txt").manifest_id;
    assert_eq!(read_all(&b, b_ino), b"version one");

    // A overwrites with different content (truncate+write → no stale tail).
    a.truncate(a_ino, 0).unwrap();
    a.write(a_ino, 0, b"a wholly different second version").unwrap();
    a.flush(a_ino).unwrap();
    replicate_tree(&a, &b); // B's pull applies the new manifest in place

    let m2 = b.getattr(b_ino).unwrap().mtime;
    assert_ne!(manifest1, node_named(&b, "doc.txt").manifest_id, "new content → new manifest");
    assert!(m2 > 0 && m2 >= m1, "mtime is set and advances on the update (cache-invalidation signal)");
    assert_eq!(read_all(&b, b_ino), b"a wholly different second version", "B reads fresh, not stale");
}

#[test]
fn random_mid_file_write_works_on_a_hydrated_file() {
    // Once the file's chunks are local (the adapter hydrates the whole file on
    // open-for-write), a seek-and-write into the middle reconstructs correctly — the
    // write path seeds the staging buffer from the committed content and overlays.
    let (a, b, _dir) = shared_store_pair();
    write_file(&a, ROOT, "part.bin", &vec![1u8; 2000]);
    replicate_tree(&a, &b);

    let b_ino = b.lookup(ROOT, "part.bin").unwrap().ino; // B shares A's chunks (hydrated)
    b.write(b_ino, 500, &[9u8; 10]).unwrap();
    b.flush(b_ino).unwrap();

    let out = read_all(&b, b_ino);
    assert_eq!(out.len(), 2000, "size preserved");
    assert_eq!(&out[500..510], &[9u8; 10], "the random write landed");
    assert_eq!(out[0], 1, "surrounding content intact");
}
