//! Supervised background daemon: one call mounts the filesystem **and** runs the sync
//! loop + the ActionCable nudge, all sharing a single `Arc<SqliteProvider>`.
//!
//! Unlike the raw `fuser::mount2` (which blocks the calling thread), [`Daemon::start`]
//! uses `spawn_mount2` so the FUSE session runs on its own thread — the daemon is
//! non-blocking and can be `start()`/`stop()`'d by a host with its own event loop (the
//! Tauri app). The `maker-syncd` CLI calls [`Daemon::run_until_unmounted`] to block.
//!
//! Three threads, one provider:
//! - the FUSE session thread (kernel callbacks → `fs-provider`),
//! - the sync thread (`sync_tick` on a nudge or the poll fallback),
//! - the nudge thread (`LibraryChannel` `{head_seq}` → wake the sync thread).

use std::net::SocketAddr;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{mpsc, Arc};
use std::thread::{self, JoinHandle};
use std::time::Duration;

use fs_provider::{LocalChunkStore, SqliteProvider};
use sync_client::ServerClient;

use crate::{PresignedIO, SyncEngine};

// FUSE bits — Linux only (macOS → WebDAV, Windows → WinFsp).
#[cfg(target_os = "linux")]
use crate::{EngineInvalidate, Invalidate};
#[cfg(target_os = "linux")]
use crate::EngineHydrator;
#[cfg(target_os = "linux")]
use fs_fuse::FuseAdapter;
#[cfg(target_os = "linux")]
use fuser::MountOption;

/// Default poll fallback interval (the nudge is the fast path; this bounds staleness if
/// the WebSocket is down).
pub const DEFAULT_POLL: Duration = Duration::from_secs(2);

/// Everything the daemon needs to mount + sync one library on this device.
#[derive(Clone, Debug)]
pub struct DaemonConfig {
    /// Where to expose the filesystem (a directory on macOS/Linux).
    pub mountpoint: PathBuf,
    /// Local SQLite tree (created if absent).
    pub db: PathBuf,
    /// Local content-addressed chunk cache dir (created if absent).
    pub chunk_dir: PathBuf,
    /// Rails sync server base URL, e.g. `http://localhost:3001`.
    pub server_url: String,
    /// This device's bearer token (from registration).
    pub token: String,
    /// Poll fallback interval.
    pub poll: Duration,
    /// Localhost port for the WebDAV mount path (macOS). Ignored by the FUSE `Daemon`.
    pub webdav_port: u16,
}

impl DaemonConfig {
    pub fn new(
        mountpoint: impl Into<PathBuf>,
        db: impl Into<PathBuf>,
        chunk_dir: impl Into<PathBuf>,
        server_url: impl Into<String>,
        token: impl Into<String>,
    ) -> Self {
        Self {
            mountpoint: mountpoint.into(),
            db: db.into(),
            chunk_dir: chunk_dir.into(),
            server_url: server_url.into(),
            token: token.into(),
            poll: DEFAULT_POLL,
            webdav_port: 9988,
        }
    }
}

/// A running FUSE mount + its two background loops (Linux). Drop (or
/// [`stop`](Self::stop)) unmounts and tears the loops down. macOS uses [`WebdavMount`],
/// Windows uses [`WinfspMount`].
#[cfg(target_os = "linux")]
pub struct Daemon {
    stop: Arc<AtomicBool>,
    session: Option<fuser::BackgroundSession>,
    sync_handle: Option<JoinHandle<()>>,
    mountpoint: PathBuf,
}

#[cfg(target_os = "linux")]
impl Daemon {
    /// Mount and start syncing. Returns once the mount is live (non-blocking). The nudge
    /// thread is detached (a dropped socket just falls back to the poll; it's reaped on
    /// process exit / when the receiver drops at stop).
    pub fn start(cfg: DaemonConfig) -> crate::Result<Self> {
        let store = Box::new(LocalChunkStore::new(&cfg.chunk_dir)?);
        let provider = Arc::new(SqliteProvider::open(&cfg.db, store)?);
        let client = ServerClient::with_token(&cfg.server_url, &cfg.token);
        let stop = Arc::new(AtomicBool::new(false));
        let (nudge_tx, nudge_rx) = mpsc::channel::<i64>();

        // Active cache-invalidation hook. Shared by the sync loop + the freshness adapter so
        // whichever pull applies a content change is the one that drops the kernel cache.
        // Its FUSE notifier is injected after the mount is up (set_notifier below) — see
        // EngineInvalidate's docs for the construction-cycle break.
        let invalidate = EngineInvalidate::new();
        let inval_dyn: Arc<dyn Invalidate> = Arc::new(invalidate.clone());

        let sync_handle = {
            let provider = provider.clone();
            let client = client.clone();
            let stop = stop.clone();
            let poll = cfg.poll;
            let inval = inval_dyn.clone();
            thread::spawn(move || sync_loop(provider, client, stop, nudge_rx, poll, Some(inval)))
        };
        {
            let client = client.clone();
            let stop = stop.clone();
            thread::spawn(move || nudge_loop(client, stop, nudge_tx));
        }

        let hydrator = Arc::new(EngineHydrator::new(provider.clone(), client.clone()));
        let freshness = Arc::new(crate::EngineFreshness::new(provider.clone(), client.clone(), Some(inval_dyn.clone())));
        let remote_lock = Arc::new(crate::EngineRemoteLock::new(provider.clone(), client.clone()));
        let fs = FuseAdapter::with_hydrator(provider.clone(), hydrator)
            .with_freshness(freshness)
            .with_remote_lock(remote_lock);
        let opts = [
            MountOption::FSName("maker".into()),
            MountOption::AutoUnmount,
            MountOption::DefaultPermissions,
        ];
        // spawn_mount2 runs the FUSE session loop on its own thread and returns a handle
        // that unmounts on drop — the non-blocking counterpart to mount2.
        let session = fuser::spawn_mount2(fs, &cfg.mountpoint, &opts)?;
        // Now the session exists, hand its notifier to the invalidation hook (both the sync
        // loop and the freshness adapter share it; before this they no-op harmlessly).
        invalidate.set_notifier(session.notifier());

        Ok(Self {
            stop,
            session: Some(session),
            sync_handle: Some(sync_handle),
            mountpoint: cfg.mountpoint,
        })
    }

    pub fn mountpoint(&self) -> &Path {
        &self.mountpoint
    }

    /// True while the FUSE session thread is still serving.
    pub fn is_running(&self) -> bool {
        match &self.session {
            Some(s) => !s.guard.is_finished(),
            None => false,
        }
    }

    /// Unmount and stop both loops. Idempotent (also runs on `Drop`).
    pub fn stop(&mut self) {
        self.stop.store(true, Ordering::Relaxed);
        // Dropping the session unmounts (its `_mount` guard); we don't `join()` it to
        // avoid panicking if the FUSE worker returned an error during teardown.
        self.session.take();
        if let Some(h) = self.sync_handle.take() {
            let _ = h.join();
        }
    }

    /// Block until the mount ends (Ctrl-C / `umount` / `AutoUnmount`), then stop the
    /// loops. For the CLI; a GUI host uses [`start`](Self::start) + [`stop`](Self::stop).
    pub fn run_until_unmounted(mut self) {
        if let Some(session) = self.session.take() {
            session.join(); // blocks; unmounts + joins the FUSE worker
        }
        self.stop();
    }
}

#[cfg(target_os = "linux")]
impl Drop for Daemon {
    fn drop(&mut self) {
        self.stop();
    }
}

/// The **WebDAV** mount path — serves the provider over localhost HTTP and mounts it
/// with the OS's native WebDAV client, instead of FUSE. This is the macOS path (FUSE-T
/// can't mount on macOS 26+); the sync + nudge loops are identical to [`Daemon`]. Same
/// `start`/`stop`/`is_running`/`mountpoint` shape, so a host can alias one or the other
/// per platform.
pub struct WebdavMount {
    stop: Arc<AtomicBool>,
    rt: Option<tokio::runtime::Runtime>, // owns the WebDAV server task; drop = shutdown
    sync_handle: Option<JoinHandle<()>>,
    mountpoint: PathBuf,
}

impl WebdavMount {
    pub fn start(cfg: DaemonConfig) -> crate::Result<Self> {
        let store = Box::new(LocalChunkStore::new(&cfg.chunk_dir)?);
        let provider = Arc::new(SqliteProvider::open(&cfg.db, store)?);
        let client = ServerClient::with_token(&cfg.server_url, &cfg.token);
        let stop = Arc::new(AtomicBool::new(false));
        let (nudge_tx, nudge_rx) = mpsc::channel::<i64>();

        // Same sync + nudge threads as the FUSE Daemon.
        let sync_handle = {
            let provider = provider.clone();
            let client = client.clone();
            let stop = stop.clone();
            let poll = cfg.poll;
            thread::spawn(move || sync_loop(provider, client, stop, nudge_rx, poll, None))
        };
        {
            let client = client.clone();
            let stop = stop.clone();
            thread::spawn(move || nudge_loop(client, stop, nudge_tx));
        }

        // Hydrate-on-read: resolve the WebDAV ino → node_id and pull missing chunks.
        let hydrate: fs_webdav::Hydrate = {
            let p = provider.clone();
            let c = client.clone();
            Arc::new(move |ino: u64| {
                if let Ok(Some(node_id)) = p.node_id_for(ino) {
                    let io = PresignedIO::new(&c);
                    if let Err(e) = SyncEngine::hydrate(&p, &c, &io, &node_id) {
                        eprintln!("webdav hydrate ino {ino}: {e}");
                    }
                }
            })
        };

        // WebDAV server on its own multi-thread runtime (dropped on stop → shutdown).
        let addr: SocketAddr = ([127, 0, 0, 1], cfg.webdav_port).into();
        let rt = tokio::runtime::Builder::new_multi_thread().enable_all().build()?;
        rt.spawn(fs_webdav::serve(provider, addr, Some(hydrate)));

        // Mount via the native client once the server is listening.
        std::fs::create_dir_all(&cfg.mountpoint)?;
        thread::sleep(Duration::from_millis(400));
        mount_native(&addr, &cfg.mountpoint)?;
        println!("WebDAV mounted at {} (http://{addr}/)", cfg.mountpoint.display());

        Ok(Self { stop, rt: Some(rt), sync_handle: Some(sync_handle), mountpoint: cfg.mountpoint })
    }

    pub fn mountpoint(&self) -> &Path {
        &self.mountpoint
    }

    pub fn is_running(&self) -> bool {
        !self.stop.load(Ordering::Relaxed)
    }

    pub fn stop(&mut self) {
        self.stop.store(true, Ordering::Relaxed);
        unmount_native(&self.mountpoint);
        self.rt.take(); // drop the runtime → WebDAV server task is cancelled
        if let Some(h) = self.sync_handle.take() {
            let _ = h.join();
        }
    }
}

impl Drop for WebdavMount {
    fn drop(&mut self) {
        self.stop();
    }
}

#[cfg(target_os = "macos")]
fn mount_native(addr: &SocketAddr, mp: &Path) -> std::io::Result<()> {
    let status = Command::new("/sbin/mount_webdav")
        .args(["-S", "-v", "Maker", &format!("http://{addr}/")])
        .arg(mp)
        .status()?;
    if !status.success() {
        return Err(std::io::Error::other(format!("mount_webdav exited {status}")));
    }
    Ok(())
}

#[cfg(not(target_os = "macos"))]
fn mount_native(_addr: &SocketAddr, _mp: &Path) -> std::io::Result<()> {
    // Non-macOS: the server is up; mount with the OS's WebDAV client (gio/davfs/net use).
    Ok(())
}

fn unmount_native(mp: &Path) {
    let _ = Command::new("/sbin/umount").arg(mp).status();
}

/// The **WinFsp** mount path (Windows) — a drive letter via `fs-winfsp`, same
/// `start`/`stop`/`is_running`/`mountpoint` API as the FUSE/WebDAV backends. The WinFsp
/// host handle isn't `Send`, so it lives on its own thread; the sync + nudge loops are
/// identical to the others.
#[cfg(target_os = "windows")]
pub struct WinfspMount {
    stop: Arc<AtomicBool>,
    fs_thread: Option<JoinHandle<()>>,
    sync_handle: Option<JoinHandle<()>>,
    mountpoint: PathBuf,
}

#[cfg(target_os = "windows")]
impl WinfspMount {
    pub fn start(cfg: DaemonConfig) -> crate::Result<Self> {
        let store = Box::new(LocalChunkStore::new(&cfg.chunk_dir)?);
        let provider = Arc::new(SqliteProvider::open(&cfg.db, store)?);
        let client = ServerClient::with_token(&cfg.server_url, &cfg.token);
        let stop = Arc::new(AtomicBool::new(false));
        let (nudge_tx, nudge_rx) = mpsc::channel::<i64>();

        // Same sync + nudge threads as the other backends.
        let sync_handle = {
            let provider = provider.clone();
            let client = client.clone();
            let stop = stop.clone();
            let poll = cfg.poll;
            thread::spawn(move || sync_loop(provider, client, stop, nudge_rx, poll, None))
        };
        {
            let client = client.clone();
            let stop = stop.clone();
            thread::spawn(move || nudge_loop(client, stop, nudge_tx));
        }

        // Hydrate-on-read: WinFsp ino → node_id → pull missing chunks.
        let hydrate: fs_winfsp::Hydrate = {
            let p = provider.clone();
            let c = client.clone();
            Arc::new(move |ino: u64| {
                if let Ok(Some(node_id)) = p.node_id_for(ino) {
                    let io = PresignedIO::new(&c);
                    if let Err(e) = SyncEngine::hydrate(&p, &c, &io, &node_id) {
                        eprintln!("winfsp hydrate ino {ino}: {e}");
                    }
                }
            })
        };

        // The WinFsp `Mounted` handle isn't `Send`, so create/hold/drop it on a dedicated
        // thread. It reports mount success/failure back so `start` can surface errors.
        let mountpoint = cfg.mountpoint.to_string_lossy().to_string();
        let (ready_tx, ready_rx) = mpsc::channel::<crate::Result<()>>();
        let fs_thread = {
            let provider = provider.clone();
            let stop = stop.clone();
            thread::spawn(move || match fs_winfsp::start_mount(provider, &mountpoint, Some(hydrate)) {
                Ok(mounted) => {
                    let _ = ready_tx.send(Ok(()));
                    while !stop.load(Ordering::Relaxed) {
                        thread::sleep(Duration::from_millis(150));
                    }
                    drop(mounted); // unmount on stop
                }
                Err(e) => {
                    let _ = ready_tx.send(Err(std::io::Error::other(format!(
                        "winfsp mount failed: {e:?}"
                    ))
                    .into()));
                }
            })
        };

        match ready_rx.recv() {
            Ok(Ok(())) => {}
            Ok(Err(e)) => return Err(e),
            Err(_) => {
                return Err(std::io::Error::other("winfsp mount thread exited").into());
            }
        }
        println!("WinFsp mounted at {}", cfg.mountpoint.display());

        Ok(Self {
            stop,
            fs_thread: Some(fs_thread),
            sync_handle: Some(sync_handle),
            mountpoint: cfg.mountpoint,
        })
    }

    pub fn mountpoint(&self) -> &Path {
        &self.mountpoint
    }

    pub fn is_running(&self) -> bool {
        !self.stop.load(Ordering::Relaxed)
    }

    pub fn stop(&mut self) {
        self.stop.store(true, Ordering::Relaxed);
        if let Some(h) = self.fs_thread.take() {
            let _ = h.join(); // unmounts on the way out
        }
        if let Some(h) = self.sync_handle.take() {
            let _ = h.join();
        }
    }
}

#[cfg(target_os = "windows")]
impl Drop for WinfspMount {
    fn drop(&mut self) {
        self.stop();
    }
}

/// Adapts `fs_cfapi::CfApiInvalidate` to the engine's [`crate::Invalidate`] seam: a pulled
/// content change → `CfUpdatePlaceholder` + dehydrate, so the next read re-fetches (the CfAPI
/// analogue of FUSE `notify_inval_inode`). (The trait lives in the engine, so the adapter
/// crate can't implement it directly — this newtype bridges them.)
#[cfg(target_os = "windows")]
struct EngineCfInvalidate(fs_cfapi::CfApiInvalidate);

#[cfg(target_os = "windows")]
impl crate::Invalidate for EngineCfInvalidate {
    fn invalidate(&self, ino: u64) {
        self.0.invalidate(ino);
    }
}

/// The **CfAPI** mount path (Windows) — the driverless successor to [`WinfspMount`] (the
/// OneDrive model: a registered sync-root folder, on-demand hydration, native Explorer
/// integration; no GPL driver). Same `start`/`stop`/`is_running`/`mountpoint` shape so a host
/// can alias it in place of WinFsp. Phase 1: populate + hydrate + invalidate (the download
/// half); local-edit capture is Phase 2 (see `docs/plan-windows-cfapi-migration.md`).
///
/// Unlike WinFsp, the CfAPI callbacks run on the OS's own threads against a registered root,
/// so there's no FUSE-style session thread — we hold the `CfApiMountHandle` (Drop disconnects
/// + unregisters). The sync + nudge loops are identical to the other backends.
#[cfg(target_os = "windows")]
pub struct CfApiMount {
    stop: Arc<AtomicBool>,
    handle: Option<fs_cfapi::CfApiMountHandle>,
    sync_handle: Option<JoinHandle<()>>,
    mountpoint: PathBuf,
}

#[cfg(target_os = "windows")]
impl CfApiMount {
    pub fn start(cfg: DaemonConfig) -> crate::Result<Self> {
        let store = Box::new(LocalChunkStore::new(&cfg.chunk_dir)?);
        let provider = Arc::new(SqliteProvider::open(&cfg.db, store)?);
        let client = ServerClient::with_token(&cfg.server_url, &cfg.token);
        let stop = Arc::new(AtomicBool::new(false));
        let (nudge_tx, nudge_rx) = mpsc::channel::<i64>();

        // Pull the current tree before mounting (so the first enumeration shows the library)
        // and **reset the cursor to the snapshot head**. This must happen before the sync
        // thread starts (it reads the cursor once). A reused DB can carry a cursor from a
        // *different/larger* library that's ahead of this one's head_seq — then the delta pull
        // ("changes after <stale cursor>") returns nothing and remote edits never apply.
        // Snapshotting + resetting the cursor reconciles that.
        match SyncEngine::pull_snapshot(&provider, &client) {
            Ok(head) => {
                let _ = provider.set_cursor(head);
                println!("cfapi: initial pull complete (head_seq {head}, cursor reset)");
            }
            Err(e) => eprintln!("cfapi: initial pull failed (will populate as the loop catches up): {e}"),
        }

        // Cache-invalidation hook over CfUpdatePlaceholder (no construction cycle here — CfAPI
        // resolves paths + opens handles itself, so it needs no post-mount notifier).
        let inval: Arc<dyn crate::Invalidate> = Arc::new(EngineCfInvalidate(
            fs_cfapi::CfApiInvalidate::new(provider.clone(), cfg.mountpoint.clone()),
        ));

        let sync_handle = {
            let provider = provider.clone();
            let client = client.clone();
            let stop = stop.clone();
            let poll = cfg.poll;
            let inval = inval.clone();
            thread::spawn(move || sync_loop(provider, client, stop, nudge_rx, poll, Some(inval)))
        };
        {
            let client = client.clone();
            let stop = stop.clone();
            thread::spawn(move || nudge_loop(client, stop, nudge_tx));
        }

        // Hydrate-on-FETCH_DATA: CfAPI hands us the node_id (placeholder FileIdentity); pull
        // its missing chunks via presigned GET into the local cache.
        let hydrate: fs_cfapi::Hydrate = {
            let p = provider.clone();
            let c = client.clone();
            Arc::new(move |node_id: &str| {
                let io = PresignedIO::new(&c);
                if let Err(e) = SyncEngine::hydrate(&p, &c, &io, node_id) {
                    eprintln!("cfapi hydrate {node_id}: {e}");
                }
            })
        };

        // Register + connect (on-demand population via FETCH_PLACEHOLDERS). The handle keeps
        // the sync root alive.
        let handle = fs_cfapi::win::mount(provider.clone(), &cfg.mountpoint, Some(hydrate))?;
        println!("CfAPI sync root at {}", cfg.mountpoint.display());

        Ok(Self { stop, handle: Some(handle), sync_handle: Some(sync_handle), mountpoint: cfg.mountpoint })
    }

    pub fn mountpoint(&self) -> &Path {
        &self.mountpoint
    }

    pub fn is_running(&self) -> bool {
        self.handle.as_ref().is_some_and(|h| h.is_running())
    }

    pub fn stop(&mut self) {
        self.stop.store(true, Ordering::Relaxed);
        self.handle.take(); // Drop disconnects + unregisters the sync root
        if let Some(h) = self.sync_handle.take() {
            let _ = h.join();
        }
    }
}

#[cfg(target_os = "windows")]
impl Drop for CfApiMount {
    fn drop(&mut self) {
        self.stop();
    }
}

/// Push the outbox + pull the changelog delta on each nudge or poll-timeout. `inval`, when
/// present (the FUSE `Daemon`), drops the kernel cache for any inode a pull repoints at new
/// content; the WebDAV/WinFsp mounts pass `None` (no strong push-invalidation yet).
fn sync_loop(
    provider: Arc<SqliteProvider>,
    client: ServerClient,
    stop: Arc<AtomicBool>,
    nudge_rx: mpsc::Receiver<i64>,
    poll: Duration,
    inval: Option<Arc<dyn crate::Invalidate>>,
) {
    let mut cursor = provider.cursor().unwrap_or(0);
    println!("sync loop started (cursor {cursor}, poll {poll:?})");
    while !stop.load(Ordering::Relaxed) {
        let io = PresignedIO::new(&client);
        match SyncEngine::sync_tick_inval(&provider, &client, &io, cursor, inval.as_deref()) {
            Ok(new_cursor) => {
                if new_cursor != cursor {
                    if let Err(e) = provider.set_cursor(new_cursor) {
                        eprintln!("sync: persisting cursor failed: {e}");
                    }
                    cursor = new_cursor;
                }
            }
            Err(e) => eprintln!("sync tick error: {e}"),
        }
        // Wait for a nudge (pull now) or the poll fallback; coalesce a burst.
        match nudge_rx.recv_timeout(poll) {
            Ok(seq) => {
                while nudge_rx.try_recv().is_ok() {}
                println!("nudge: head_seq {seq} → pulling");
            }
            Err(mpsc::RecvTimeoutError::Timeout) => {}
            Err(mpsc::RecvTimeoutError::Disconnected) => break,
        }
    }
    println!("sync loop stopped");
}

/// Subscribe to the LibraryChannel; forward each `{head_seq}` to the sync loop.
/// Reconnects on socket drop (the poll covers correctness meanwhile).
fn nudge_loop(client: ServerClient, stop: Arc<AtomicBool>, nudge_tx: mpsc::Sender<i64>) {
    while !stop.load(Ordering::Relaxed) {
        let tx = nudge_tx.clone();
        if let Err(e) = client.watch_library(move |seq| {
            let _ = tx.send(seq);
        }) {
            eprintln!("nudge: {e} (falling back to poll; reconnecting)");
        }
        for _ in 0..10 {
            if stop.load(Ordering::Relaxed) {
                break;
            }
            thread::sleep(Duration::from_millis(100));
        }
    }
}
