//! The **CfAPI** sync daemon CLI (Windows) — the driverless counterpart to `maker-syncd`.
//! Registers a Cloud Filter sync root, populates it from the local tree, runs the continuous
//! sync loop + ActionCable nudge, and hydrates files on demand (presigned GET) when read in
//! Explorer. Phase 1: download/read + remote-change invalidation. See
//! `client/fs-cfapi/BUILD.md` for the smoke test.
//!
//!   maker-cfsyncd <sync-root-dir> <db> <chunk_dir> <server_url> <device_token>

#[cfg(not(target_os = "windows"))]
fn main() {
    eprintln!("maker-cfsyncd is the Windows CfAPI daemon. On Linux use maker-syncd (FUSE); on macOS use the Maker app (WebDAV).");
    std::process::exit(1);
}

#[cfg(target_os = "windows")]
fn main() {
    use sync_engine::{CfApiMount, DaemonConfig};

    let mut args = std::env::args().skip(1);
    let (root, db, chunk_dir, server_url, token) =
        match (args.next(), args.next(), args.next(), args.next(), args.next()) {
            (Some(a), Some(b), Some(c), Some(d), Some(e)) => (a, b, c, d, e),
            _ => {
                eprintln!("usage: maker-cfsyncd <sync-root-dir> <db> <chunk_dir> <server_url> <device_token>");
                std::process::exit(2);
            }
        };

    let cfg = DaemonConfig::new(root, db, chunk_dir, server_url, token);
    let mp = cfg.mountpoint.display().to_string();
    let mount = match CfApiMount::start(cfg) {
        Ok(m) => m,
        Err(e) => {
            eprintln!("failed to start CfAPI mount: {e}");
            std::process::exit(1);
        }
    };
    use std::io::IsTerminal;
    if std::io::stdin().is_terminal() {
        // Interactive use: wait for Enter, then unmount cleanly.
        println!("CfAPI sync root at {mp} — browse it in Explorer. Press Enter to unmount.");
        let mut line = String::new();
        let _ = std::io::stdin().read_line(&mut line);
        drop(mount); // Drop disconnects + unregisters the sync root
    } else {
        // Headless (service / CI / Start-Process): stdin is EOF immediately, so DON'T read it —
        // that would unmount the moment we mounted. Stay mounted until the process is terminated
        // (Ctrl-C / kill). `mount` is kept alive for the lifetime of the loop.
        println!("CfAPI sync root at {mp} — running headless; terminate the process to unmount.");
        loop {
            std::thread::sleep(std::time::Duration::from_secs(3600));
        }
    }
}
