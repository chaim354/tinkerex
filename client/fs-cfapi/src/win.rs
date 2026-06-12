//! Windows Cloud Filter API FFI — the live mount. `#[cfg(windows)]` only.
//!
//! Flow (Phase 1 — the download/read half):
//! 1. [`mount`] registers the folder as a **sync root** (`CfRegisterSyncRoot`) with full
//!    hydration + population policy, connects the callback table (`CfConnectSyncRoot`), and
//!    **populates every node as a dehydrated placeholder** from the local `Provider` tree
//!    (`CfCreatePlaceholders`).
//! 2. A read of a dehydrated file raises **FETCH_DATA**; [`fetch_data_callback`] resolves the
//!    placeholder's `FileIdentity` → `node_id`, runs the hydrate hook (presigned GET into the
//!    chunk cache), reads the requested range from the `Provider`, and hands the bytes back
//!    with `CfExecute(TRANSFER_DATA)`.
//! 3. A pulled remote content change calls [`CfApiInvalidate::invalidate`] →
//!    `CfUpdatePlaceholder` (+ dehydrate), so the next read re-fetches (the CfAPI analogue of
//!    the FUSE `notify_inval_inode`).
//!
//! Phase 2 (NOT here): capturing **local** edits (the OS owns the on-disk bytes) via a USN /
//! `ReadDirectoryChangesW` watcher → `Provider::ingest_bytes` → push → `CfSetInSyncState`.
//!
//! Runtime-UNVERIFIED on Windows, but it **typechecks for the Windows target** — built on
//! macOS via `cargo check --target x86_64-pc-windows-gnu` (windows 0.61) and by the
//! `cfapi-windows` CI job. Runtime behavior needs the smoke test in `BUILD.md`. Gaps flagged
//! `LIMITATION:`/`PHASE 2:`.

use std::collections::HashMap;
use std::ffi::c_void;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};

use fs_provider::{Kind, Provider, SqliteProvider, ROOT_INO};
use widestring::U16CString;
use windows::core::{GUID, PCWSTR};
use windows::Win32::Foundation::{CloseHandle, STATUS_SUCCESS, STATUS_UNSUCCESSFUL};
use windows::Win32::Storage::CloudFilters::*;
use windows::Win32::Storage::FileSystem::{
    CreateFileW, FILE_ATTRIBUTE_NORMAL, FILE_BASIC_INFO, FILE_FLAGS_AND_ATTRIBUTES,
    FILE_FLAG_BACKUP_SEMANTICS, FILE_GENERIC_READ, FILE_GENERIC_WRITE, FILE_SHARE_DELETE,
    FILE_SHARE_READ, FILE_SHARE_WRITE, OPEN_EXISTING,
};

use crate::{unix_nanos_to_filetime, FileIdentity};

/// On-demand hydration hook: "make `node_id`'s chunks local" (presigned GET into the cache).
/// The sync engine supplies it (see `sync_engine::CfApiMount`); a bare local mount passes
/// `None` and serves only already-cached chunks.
pub type Hydrate = Arc<dyn Fn(&str) + Send + Sync>;

/// A fixed provider id for the sync-root registration (one logical cloud provider). A real
/// multi-account build would derive this per user; one constant is fine for v1.
const PROVIDER_ID: GUID = GUID::from_u128(0x6d61_6b65_7200_0000_0000_0000_0000_0001);
const PROVIDER_NAME: &str = "Maker";
const PROVIDER_VERSION: &str = "1.0";

/// Shared state the FETCH_DATA callback reaches via the connection's callback context. Leaked
/// (`Box::into_raw`) for the connection's lifetime and reclaimed on disconnect.
struct CfState {
    provider: Arc<SqliteProvider>,
    hydrate: Option<Hydrate>,
    connection_key: Mutex<Option<CF_CONNECTION_KEY>>,
}

/// A live CfAPI sync root: registered, connected, populated. Drop disconnects + unregisters.
pub struct CfApiMountHandle {
    root: PathBuf,
    state: *mut CfState,
    stop: Arc<AtomicBool>,
}

// The raw `*mut CfState` is only ever touched behind the connection (single owner); the
// handle is moved to one thread. Mark Send so it can live in the daemon's mount slot.
unsafe impl Send for CfApiMountHandle {}

fn to_wide(s: &str) -> U16CString {
    U16CString::from_str(s).expect("string has no interior NUL")
}

fn path_wide(p: &Path) -> U16CString {
    U16CString::from_os_str(p.as_os_str()).expect("path has no interior NUL")
}

/// Register + connect + populate. Returns a handle that tears everything down on drop.
pub fn mount(provider: Arc<SqliteProvider>, root: &Path, hydrate: Option<Hydrate>) -> std::io::Result<CfApiMountHandle> {
    std::fs::create_dir_all(root)?;
    register_sync_root(root)?;

    let state = Box::into_raw(Box::new(CfState {
        provider: provider.clone(),
        hydrate,
        connection_key: Mutex::new(None),
    }));

    // The callback table must outlive the connection, so leak it (one small leak per mount).
    // Terminated by a CF_CALLBACK_TYPE_NONE entry. On-demand population: the platform raises
    // FETCH_PLACEHOLDERS when Explorer opens a directory, and FETCH_DATA when a file is read.
    let callbacks: &'static [CF_CALLBACK_REGISTRATION] = Box::leak(Box::new([
        CF_CALLBACK_REGISTRATION { Type: CF_CALLBACK_TYPE_FETCH_PLACEHOLDERS, Callback: Some(fetch_placeholders_callback) },
        CF_CALLBACK_REGISTRATION { Type: CF_CALLBACK_TYPE_FETCH_DATA, Callback: Some(fetch_data_callback) },
        CF_CALLBACK_REGISTRATION { Type: CF_CALLBACK_TYPE_NONE, Callback: None },
    ]));

    let root_w = path_wide(root);
    unsafe {
        let key = CfConnectSyncRoot(
            PCWSTR(root_w.as_ptr()),
            callbacks.as_ptr(),
            Some(state as *const c_void),
            CF_CONNECT_FLAG_REQUIRE_PROCESS_INFO | CF_CONNECT_FLAG_REQUIRE_FULL_FILE_PATH,
        )
        .map_err(win_err)?;
        (*state).connection_key.lock().unwrap().replace(key);
    }
    eprintln!("cfapi: connected sync root at {}", root.display());

    Ok(CfApiMountHandle { root: root.to_path_buf(), state, stop: Arc::new(AtomicBool::new(false)) })
}

fn register_sync_root(root: &Path) -> std::io::Result<()> {
    let display = to_wide(PROVIDER_NAME);
    let version = to_wide(PROVIDER_VERSION);
    // SyncRootIdentity is an opaque per-root blob; the root path is a fine identity.
    let identity = path_wide(root);
    let registration = CF_SYNC_REGISTRATION {
        StructSize: std::mem::size_of::<CF_SYNC_REGISTRATION>() as u32,
        ProviderName: PCWSTR(display.as_ptr()),
        ProviderVersion: PCWSTR(version.as_ptr()),
        SyncRootIdentity: identity.as_ptr() as *const c_void,
        SyncRootIdentityLength: (identity.len() * 2) as u32,
        ProviderId: PROVIDER_ID,
        ..Default::default()
    };
    // Full hydration (a read fetches the whole file) + **partial/on-demand** population: the
    // platform raises FETCH_PLACEHOLDERS as Explorer opens each directory, and we answer from
    // the provider's *current* tree — so we don't depend on the local tree being populated at
    // mount time (the sync loop fills it asynchronously).
    let policies = CF_SYNC_POLICIES {
        StructSize: std::mem::size_of::<CF_SYNC_POLICIES>() as u32,
        Hydration: CF_HYDRATION_POLICY {
            Primary: CF_HYDRATION_POLICY_FULL,
            Modifier: CF_HYDRATION_POLICY_MODIFIER_NONE,
        },
        Population: CF_POPULATION_POLICY {
            Primary: CF_POPULATION_POLICY_PARTIAL,
            Modifier: CF_POPULATION_POLICY_MODIFIER_NONE,
        },
        InSync: CF_INSYNC_POLICY_NONE,
        HardLink: CF_HARDLINK_POLICY_NONE,
        ..Default::default()
    };
    let root_w = path_wide(root);
    unsafe {
        CfRegisterSyncRoot(PCWSTR(root_w.as_ptr()), &registration, &policies, CF_REGISTER_FLAG_UPDATE)
            .map_err(win_err)?;
    }
    Ok(())
}

/// Build the placeholder holders for the direct children of `dir_ino` from the provider's
/// current tree. Each carries the child's `node_id` as `FileIdentity` and its real mtime.
/// The returned holders own the name/identity backing storage the `CF_PLACEHOLDER_CREATE_INFO`
/// pointers reference, so they must outlive the CfAPI call that consumes them.
fn placeholders_for_dir(provider: &SqliteProvider, dir_ino: u64) -> Vec<PlaceholderHolder> {
    let children = match provider.readdir(dir_ino) {
        Ok(c) => c,
        Err(e) => {
            eprintln!("cfapi: readdir(ino {dir_ino}) failed: {e}");
            return Vec::new();
        }
    };
    let mut holders = Vec::new();
    for c in &children {
        let size = provider.getattr(c.ino).map(|a| a.size).unwrap_or(0);
        let mtime = provider.getattr(c.ino).map(|a| a.mtime).unwrap_or(0);
        let node_id = provider.node_id_for(c.ino).ok().flatten().unwrap_or_default();
        holders.push(PlaceholderHolder::new(&c.name, &node_id, size, mtime, c.kind == Kind::Dir));
    }
    holders
}

/// Owns the wide-string + identity backing storage for one `CF_PLACEHOLDER_CREATE_INFO`
/// (the struct holds raw pointers into these, so they must outlive the create call).
struct PlaceholderHolder {
    name: U16CString,
    identity: Vec<u8>,
    size: i64,
    mtime_ticks: i64,
    is_dir: bool,
}

impl PlaceholderHolder {
    fn new(name: &str, node_id: &str, size: u64, mtime_nanos: i64, is_dir: bool) -> Self {
        Self {
            name: to_wide(name),
            identity: FileIdentity::from_node_id(node_id).0,
            size: if is_dir { 0 } else { size as i64 },
            // CfAPI metadata times are i64 (100 ns ticks since 1601) — exactly our FILETIME.
            mtime_ticks: unix_nanos_to_filetime(mtime_nanos) as i64,
            is_dir,
        }
    }
    fn info(&self) -> CF_PLACEHOLDER_CREATE_INFO {
        let attrs = if self.is_dir { 0x10 /* FILE_ATTRIBUTE_DIRECTORY */ } else { FILE_ATTRIBUTE_NORMAL.0 };
        CF_PLACEHOLDER_CREATE_INFO {
            RelativeFileName: PCWSTR(self.name.as_ptr()),
            FsMetadata: CF_FS_METADATA {
                FileSize: self.size,
                BasicInfo: FILE_BASIC_INFO {
                    CreationTime: self.mtime_ticks,
                    LastAccessTime: self.mtime_ticks,
                    LastWriteTime: self.mtime_ticks,
                    ChangeTime: self.mtime_ticks,
                    FileAttributes: attrs,
                },
            },
            FileIdentity: self.identity.as_ptr() as *const c_void,
            FileIdentityLength: self.identity.len() as u32,
            // Mark in-sync (just populated from the source of truth); a later content change
            // dehydrates it via CfUpdatePlaceholder. Disable on-demand population — Phase 1
            // fully populates up front.
            Flags: CF_PLACEHOLDER_CREATE_FLAG_MARK_IN_SYNC | CF_PLACEHOLDER_CREATE_FLAG_DISABLE_ON_DEMAND_POPULATION,
            ..Default::default()
        }
    }
}

/// Build a `CF_OPERATION_INFO` for answering a callback (shared by the transfer ops).
unsafe fn op_info_for(info: &CF_CALLBACK_INFO, op_type: CF_OPERATION_TYPE) -> CF_OPERATION_INFO {
    CF_OPERATION_INFO {
        StructSize: std::mem::size_of::<CF_OPERATION_INFO>() as u32,
        Type: op_type,
        ConnectionKey: info.ConnectionKey,
        TransferKey: info.TransferKey,
        CorrelationVector: info.CorrelationVector as *const _,
        SyncStatus: std::ptr::null(),
        RequestKey: info.RequestKey,
    }
}

/// FETCH_DATA: the kernel needs bytes for a dehydrated placeholder. Resolve node → hydrate →
/// read the requested range → hand it back with `CfExecute(TRANSFER_DATA)`. **Always** answers
/// (success or an error completion) — an unanswered FETCH_DATA hangs the reading app to a
/// timeout.
unsafe extern "system" fn fetch_data_callback(
    info: *const CF_CALLBACK_INFO,
    params: *const CF_CALLBACK_PARAMETERS,
) {
    if info.is_null() || params.is_null() {
        return;
    }
    let info = &*info;
    let params = &*params;
    let state = info.CallbackContext as *const CfState;
    if state.is_null() {
        return;
    }
    let state = &*state;

    let fetch = params.Anonymous.FetchData;
    let offset = fetch.RequiredFileOffset;
    let length = fetch.RequiredLength;

    // Try to produce the bytes; on any failure, answer with an error status so the app's read
    // fails fast instead of hanging.
    let data: Option<Vec<u8>> = (|| {
        let identity = std::slice::from_raw_parts(info.FileIdentity as *const u8, info.FileIdentityLength as usize);
        let node_id = FileIdentity(identity.to_vec()).to_node_id()?;
        eprintln!("cfapi: FETCH_DATA node={node_id} off={offset} len={length}");
        if let Some(h) = &state.hydrate {
            h(&node_id);
        }
        let ino = state.provider.ino_for_node_id(&node_id).ok().flatten()?;
        state.provider.read(ino, offset as u64, length as u32).ok()
    })();

    let op_info = op_info_for(info, CF_OPERATION_TYPE_TRANSFER_DATA);
    let mut op_params = match &data {
        Some(bytes) => CF_OPERATION_PARAMETERS {
            ParamSize: std::mem::size_of::<CF_OPERATION_PARAMETERS>() as u32,
            Anonymous: CF_OPERATION_PARAMETERS_0 {
                TransferData: CF_OPERATION_PARAMETERS_0_0 {
                    Flags: CF_OPERATION_TRANSFER_DATA_FLAG_NONE,
                    CompletionStatus: STATUS_SUCCESS,
                    Buffer: bytes.as_ptr() as *const c_void,
                    Offset: offset,
                    Length: bytes.len() as i64,
                },
            },
        },
        None => {
            eprintln!("cfapi: FETCH_DATA failed off={offset} len={length} — reporting error");
            CF_OPERATION_PARAMETERS {
                ParamSize: std::mem::size_of::<CF_OPERATION_PARAMETERS>() as u32,
                Anonymous: CF_OPERATION_PARAMETERS_0 {
                    TransferData: CF_OPERATION_PARAMETERS_0_0 {
                        Flags: CF_OPERATION_TRANSFER_DATA_FLAG_NONE,
                        CompletionStatus: STATUS_UNSUCCESSFUL,
                        Buffer: std::ptr::null(),
                        Offset: offset,
                        Length: 0,
                    },
                },
            }
        }
    };
    if let Err(e) = CfExecute(&op_info, &mut op_params) {
        eprintln!("cfapi: CfExecute(TRANSFER_DATA) failed: {e}");
    }
}

/// FETCH_PLACEHOLDERS: Explorer opened a directory — enumerate its children from the
/// provider's *current* tree and hand them back as placeholders via
/// `CfExecute(TRANSFER_PLACEHOLDERS)`. Resolving the directory: a child dir carries its
/// `node_id` as `FileIdentity`; the sync root itself has no node identity, so an
/// unrecognized identity means the root (`ROOT_INO`). Always answers (an unanswered
/// enumeration hangs Explorer to a timeout).
unsafe extern "system" fn fetch_placeholders_callback(
    info: *const CF_CALLBACK_INFO,
    _params: *const CF_CALLBACK_PARAMETERS,
) {
    if info.is_null() {
        return;
    }
    let info = &*info;
    let state = info.CallbackContext as *const CfState;
    if state.is_null() {
        return;
    }
    let state = &*state;

    // Which directory? Root unless the FileIdentity maps to a known node.
    let dir_ino = {
        let identity = std::slice::from_raw_parts(info.FileIdentity as *const u8, info.FileIdentityLength as usize);
        FileIdentity(identity.to_vec())
            .to_node_id()
            .and_then(|nid| state.provider.ino_for_node_id(&nid).ok().flatten())
            .unwrap_or(ROOT_INO)
    };

    let holders = placeholders_for_dir(&state.provider, dir_ino);
    let mut infos: Vec<CF_PLACEHOLDER_CREATE_INFO> = holders.iter().map(|h| h.info()).collect();
    eprintln!("cfapi: FETCH_PLACEHOLDERS dir_ino={dir_ino} → {} entries", infos.len());

    let op_info = op_info_for(info, CF_OPERATION_TYPE_TRANSFER_PLACEHOLDERS);
    let mut op_params = CF_OPERATION_PARAMETERS {
        ParamSize: std::mem::size_of::<CF_OPERATION_PARAMETERS>() as u32,
        Anonymous: CF_OPERATION_PARAMETERS_0 {
            TransferPlaceholders: CF_OPERATION_PARAMETERS_0_4 {
                // Mark the dir fully populated so the platform won't re-ask.
                Flags: CF_OPERATION_TRANSFER_PLACEHOLDERS_FLAG_DISABLE_ON_DEMAND_POPULATION,
                CompletionStatus: STATUS_SUCCESS,
                PlaceholderTotalCount: infos.len() as i64,
                PlaceholderArray: infos.as_mut_ptr(),
                PlaceholderCount: infos.len() as u32,
                EntriesProcessed: 0,
            },
        },
    };
    if let Err(e) = CfExecute(&op_info, &mut op_params) {
        eprintln!("cfapi: CfExecute(TRANSFER_PLACEHOLDERS) failed: {e}");
    }
}

impl CfApiMountHandle {
    pub fn mountpoint(&self) -> &Path {
        &self.root
    }
    pub fn is_running(&self) -> bool {
        !self.stop.load(Ordering::Relaxed)
    }
    /// Block until stopped (for the `maker-cfapi` CLI; the caller sets `stop` on Ctrl-C/exit).
    pub fn run_until_ctrl_c(self) {
        while !self.stop.load(Ordering::Relaxed) {
            std::thread::sleep(std::time::Duration::from_millis(200));
        }
    }
    pub fn stop(&mut self) {
        self.stop.store(true, Ordering::Relaxed);
    }
}

impl Drop for CfApiMountHandle {
    fn drop(&mut self) {
        unsafe {
            if let Some(key) = (*self.state).connection_key.lock().unwrap().take() {
                let _ = CfDisconnectSyncRoot(key);
            }
            let root_w = path_wide(&self.root);
            let _ = CfUnregisterSyncRoot(PCWSTR(root_w.as_ptr()));
            // Reclaim the leaked state.
            drop(Box::from_raw(self.state));
        }
    }
}

/// Active cache invalidation for CfAPI — the [`sync_engine::Invalidate`]-shaped hook. On a
/// pulled content change, update the placeholder's metadata and **dehydrate** it so the next
/// read re-raises FETCH_DATA and pulls the new manifest. Resolves the on-disk path from the
/// `node_id` via the `Provider` tree.
pub struct CfApiInvalidate {
    provider: Arc<SqliteProvider>,
    root: PathBuf,
    paths: Mutex<HashMap<u64, PathBuf>>, // ino → absolute path cache (best-effort)
}

impl CfApiInvalidate {
    pub fn new(provider: Arc<SqliteProvider>, root: PathBuf) -> Self {
        Self { provider, root, paths: Mutex::new(HashMap::new()) }
    }

    /// Resolve an ino to its absolute path under the sync root by walking the name chain.
    fn path_for(&self, ino: u64) -> Option<PathBuf> {
        if let Some(p) = self.paths.lock().unwrap().get(&ino) {
            return Some(p.clone());
        }
        // DFS from root building paths until we hit `target`. O(tree) — fine for invalidation,
        // which is rare. PHASE 2: maintain an ino→path index during populate for O(1).
        let mut stack = vec![(ROOT_INO, self.root.clone())];
        while let Some((dir_ino, path)) = stack.pop() {
            for e in self.provider.readdir(dir_ino).ok()? {
                let child = path.join(&e.name);
                if e.ino == ino {
                    self.paths.lock().unwrap().insert(ino, child.clone());
                    return Some(child);
                }
                if e.kind == Kind::Dir {
                    stack.push((e.ino, child));
                }
            }
        }
        None
    }

    pub fn invalidate(&self, ino: u64) {
        let path = match self.path_for(ino) {
            Some(p) => p,
            None => return,
        };
        let path_w = path_wide(&path);
        unsafe {
            // Open a handle to the placeholder (backup semantics so dirs work too).
            let handle = match CreateFileW(
                PCWSTR(path_w.as_ptr()),
                (FILE_GENERIC_READ | FILE_GENERIC_WRITE).0,
                FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
                None,
                OPEN_EXISTING,
                FILE_FLAGS_AND_ATTRIBUTES(FILE_FLAG_BACKUP_SEMANTICS.0 | FILE_ATTRIBUTE_NORMAL.0),
                None,
            ) {
                Ok(h) => h,
                Err(_) => return,
            };
            // Update metadata + dehydrate the whole file so the next read re-fetches.
            let mut usn: i64 = 0;
            let _ = CfUpdatePlaceholder(
                handle,
                None,
                None,
                0,
                None,
                CF_UPDATE_FLAG_DEHYDRATE | CF_UPDATE_FLAG_MARK_IN_SYNC,
                Some(&mut usn),
                None,
            );
            let _ = CloseHandle(handle);
        }
    }
}

fn win_err(e: windows::core::Error) -> std::io::Error {
    std::io::Error::other(format!("cfapi: {e}"))
}
