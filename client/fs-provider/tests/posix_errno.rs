//! pjdfstest-style **errno conformance** for the operations our sync mount implements.
//!
//! pjdfstest checks the *exact* errno of every failure path (ENOENT / EEXIST / ENOTDIR /
//! EISDIR / ENOTEMPTY / ENAMETOOLONG / EINVAL), not just "it errored". Several of these
//! were wrong or silently succeeded before (e.g. `unlink` of a directory returned ENOENT
//! instead of EISDIR; `rename` of a file *over* an empty directory silently succeeded;
//! `rename` into a missing parent orphaned the node). Each test below pins one rule the
//! way the suite's `chmod`/`rename`/`unlink`/`rmdir`/`mkdir`/`open`/`truncate` `.t` files do.
//!
//! These are Provider-level (run on macOS, no kernel mount). The real-FUSE pjdfstest run
//! (`client/test-conformance/pjdfstest-fuse.sh`, Linux-only) exercises the same rules
//! through the kernel; the errno map lives in `fs-fuse::errno`.

mod common;
use common::*;

use fs_provider::{FsError, Provider};

// ---- unlink / rmdir target-kind errnos -------------------------------------------------

#[test]
fn unlink_of_a_directory_is_eisdir() {
    // POSIX: unlink() on a directory fails. Linux returns EISDIR (FreeBSD EPERM); we map
    // to EISDIR. It must NOT masquerade as ENOENT (which is what filtering kind='file' did).
    let p = provider();
    p.mkdir(ROOT, "d").unwrap();
    assert!(matches!(p.unlink(ROOT, "d"), Err(FsError::IsADirectory)));
    // The directory is untouched.
    assert!(p.lookup(ROOT, "d").is_ok());
}

#[test]
fn rmdir_of_a_file_is_enotdir() {
    // POSIX: rmdir() on a non-directory fails with ENOTDIR. Must not look like ENOENT.
    let p = provider();
    write_file(&p, ROOT, "f", b"x");
    assert!(matches!(p.rmdir(ROOT, "f"), Err(FsError::NotADirectory)));
    assert!(p.lookup(ROOT, "f").is_ok());
}
