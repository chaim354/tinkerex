//! Mac "host" for testing the Windows CfAPI client: bring up a synced library on macOS so
//! you can **drop files into Finder**, and print a **device token to paste on Windows**.
//!
//! It (1) gets a token — registers a fresh account from `EMAIL`, or reuses an existing
//! library if you pass `TOKEN`; (2) mints a *second* device token for the Windows box (same
//! library, no pairing-code dance — an authenticated device can mint device tokens directly);
//! (3) mounts the library at `~/MakerDrive` via WebDAV (native `mount_webdav`, shows in
//! Finder as "Maker") and runs the sync loop; (4) stays up until you press Enter.
//!
//! Drag files into `~/MakerDrive` → they push to the server → the Windows CfAPI mount
//! (`maker-cfsyncd`) populates + hydrates them.
//!
//!   # fresh library:
//!   SERVER_URL=http://192.168.1.95:3001 EMAIL=me@example.com cargo run --example mac_host
//!   # existing library (reuse a token you already have):
//!   SERVER_URL=http://192.168.1.95:3001 TOKEN=<existing-device-token> cargo run --example mac_host
//!
//! NOTE: for the Windows box to actually *hydrate* file bytes, the server must use the
//! S3/SeaweedFS chunk backend (STORAGE_BACKEND=s3 …), not the memory one. The deployed
//! Unraid server already does.

use std::time::{SystemTime, UNIX_EPOCH};

use sync_client::ServerClient;
use sync_engine::{DaemonConfig, WebdavMount};

fn main() {
    let server = std::env::var("SERVER_URL").expect("set SERVER_URL (e.g. http://192.168.1.95:3001)");
    let home = std::env::var("HOME").unwrap();
    let mp = format!("{home}/MakerDrive");

    // 1. Get a token for the library we'll host.
    let mut client;
    let mac_token = match std::env::var("TOKEN") {
        Ok(tok) => {
            // Reuse an existing library (your real files are already in it).
            client = ServerClient::with_token(&server, tok.clone());
            println!("✓ using existing library via TOKEN");
            tok
        }
        Err(_) => {
            // Fresh account. A unique fallback email avoids the account-exists conflict on re-run.
            let tag = format!("{:x}", SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_secs());
            let email = std::env::var("EMAIL").unwrap_or_else(|_| format!("maker-{tag}@example.com"));
            client = ServerClient::new(&server);
            let reg = client.register(&email, "mac-host").expect("register failed (email may already exist — pass TOKEN= instead)");
            println!("✓ registered new library: {email}");
            reg.device_token
        }
    };

    // 2. Mint a device token for the Windows machine (same library).
    let win = client.create_device("windows-cfapi").expect("mint windows device token");

    // 3. Mount the library on macOS so you can drop files in via Finder.
    let _ = std::fs::remove_file("/tmp/maker-mac-host.db");
    let _ = std::fs::remove_dir_all("/tmp/maker-mac-host-chunks");
    let cfg = DaemonConfig::new(&mp, "/tmp/maker-mac-host.db", "/tmp/maker-mac-host-chunks", &server, mac_token);
    let mount = WebdavMount::start(cfg).expect("WebdavMount::start (is the server reachable?)");

    println!("\n────────────────────────────────────────────────────────");
    println!("  Mounted at: {mp}   (Finder ▸ Locations ▸ Maker)");
    println!("  Drop files into that folder — they sync to the server.");
    println!();
    println!("  PASTE THIS ON WINDOWS as the device token:");
    println!("    {}", win.device_token);
    println!("  …and use SERVER_URL: {server}");
    println!("────────────────────────────────────────────────────────");
    println!("\nPress Enter to unmount and exit.");

    let mut line = String::new();
    let _ = std::io::stdin().read_line(&mut line);
    drop(mount);
    println!("✓ unmounted; done");
}
