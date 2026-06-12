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
//!    with `CfExecuteOperation(TRANSFER_DATA)`.
//! 3. A pulled remote content change calls [`CfApiInvalidate::invalidate`] →
//!    `CfUpdatePlaceholder` (+ dehydrate), so the next read re-fetches (the CfAPI analogue of
//!    the FUSE `notify_inval_inode`).
//!
//! Phase 2 (NOT here): capturing **local** edits (the OS owns the on-disk bytes) via a USN /
//! `ReadDirectoryChangesW` watcher → `Provider::ingest_bytes` → push → `CfSetInSyncState`.
//!
//! UNVERIFIED on Windows: authored on macOS against `windows` 0.61; compiled by the
//! `cfapi-windows` CI job, runtime-smoke per `BUILD.md`. Gaps flagged `LIMITATION:`/`PHASE 2:`.

use std::collections::HashMap;
use std::ffi::c_void;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};

use fs_provider::{Kind, Provider, SqliteProvider, ROOT_INO};
use widestring::U16CString;
use windows::core::{GUID, PCWSTR};
use windows::Win32::Foundation::{CloseHandle, HANDLE, STATUS_SUCCESS};
use windows::Win32::Storage::CloudFilters::*;
use windows::Win32::Storage::FileSystem::{
    CreateFileW, FILE_ATTRIBUTE_NORMAL, FILE_FLAGS_AND_ATTRIBUTES, FILE_FLAG_BACKUP_SEMANTICS,
    FILE_GENERIC_READ, FILE_GENERIC_WRITE, FILE_SHARE_DELETE, FILE_SHARE_READ, FILE_SHARE_WRITE,
    OPEN_EXISTING,
};

use crate::{unix_nanos_to_filetime, FileIdentity};

/// On-demand hydration hook: "make `node_id`'s chunks local" (presigned GET into the cache).
/// The sync engine supplies it (see `sync_engine::CfApiMount`); a bare local mount passes
/// `None` and serves only already-cached chunks.
pub type Hydrate = Arc<dyn Fn(&str) + Send + Sync>;

/// A fixed provider id for the sync-root registration (one logical cloud provider). A real
/// multi-account build would derive this per user; one constant is fine for v1.
const PROVIDER_ID: GUID = GUID::from_u128(0x6d_61_6b_65_72_00_00_00_00_00_00_00_00_00_00_01);
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
    U16CString::from_str(s).expect("path has no interior NUL")
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

    // Connect the callback table. The terminator entry has Type CF_CALLBACK_TYPE_NONE.
    let callbacks = [
        CF_CALLBACK_REGISTRATION {
            Callback: Some(fetch_data_callback),
            Type: CF_CALLBACK_TYPE_FETCH_DATA,
        },
        CF_CALLBACK_REGISTRATION {
            Callback: None,
            Type: CF_CALLBACK_TYPE_NONE,
        },
    ];
    let mut key = CF_CONNECTION_KEY::default();
    unsafe {
        CfConnectSyncRoot(
            PCWSTR(path_wide(root).as_ptr()),
            callbacks.as_ptr(),
            Some(state as *const c_void),
            CF_CONNECT_FLAG_REQUIRE_PROCESS_INFO | CF_CONNECT_FLAG_REQUIRE_FULL_FILE_PATH,
            &mut key,
        )
        .map_err(win_err)?;
        (*state).connection_key.lock().unwrap().replace(key);
    }

    populate(&provider, root)?;

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
    // Full hydration + full population: every placeholder is created up front (Phase 1
    // skips on-demand FETCH_PLACEHOLDERS), and a read fully hydrates the file.
    let policies = CF_SYNC_POLICIES {
        StructSize: std::mem::size_of::<CF_SYNC_POLICIES>() as u32,
        Hydration: CF_HYDRATION_POLICY {
            Primary: CF_HYDRATION_POLICY_PRIMARY(CF_HYDRATION_POLICY_FULL.0 as i16),
            Modifier: CF_HYDRATION_POLICY_MODIFIER(CF_HYDRATION_POLICY_MODIFIER_NONE.0 as i16),
        },
        Population: CF_POPULATION_POLICY {
            Primary: CF_POPULATION_POLICY_PRIMARY(CF_POPULATION_POLICY_FULL.0 as i16),
            Modifier: CF_POPULATION_POLICY_MODIFIER(CF_POPULATION_POLICY_MODIFIER_NONE.0 as i16),
        },
        InSync: CF_INSYNC_POLICY_NONE,
        HardLink: CF_HARDLINK_POLICY_NONE,
        ..Default::default()
    };
    unsafe {
        CfRegisterSyncRoot(
            PCWSTR(path_wide(root).as_ptr()),
            &registration,
            &policies,
            CF_REGISTER_FLAG_UPDATE,
        )
        .map_err(win_err)?;
    }
    Ok(())
}

/// Create a (dehydrated) placeholder for every node, directories before their children, so
/// the whole tree is browsable in Explorer immediately. Each placeholder carries the
/// `node_id` as its `FileIdentity` and the real mtime as `LastWriteTime`.
fn populate(provider: &SqliteProvider, root: &Path) -> std::io::Result<()> {
    // BFS the tree so a parent's on-disk directory exists before its children are created.
    let mut queue: Vec<(u64, PathBuf)> = vec![(ROOT_INO, root.to_path_buf())];
    while let Some((ino, dir)) = queue.pop() {
        let children = provider.readdir(ino).map_err(fs_err)?;
        // Build the placeholder array for this directory in one CfCreatePlaceholders call.
        let mut creates: Vec<PlaceholderHolder> = Vec::new();
        for c in &children {
            let attr = provider.getattr(c.ino).map_err(fs_err)?;
            let node_id = provider
                .node_id_for(c.ino)
                .map_err(fs_err)?
                .unwrap_or_default();
            creates.push(PlaceholderHolder::new(&c.name, &node_id, attr.size, attr.mtime, c.kind == Kind::Dir));
            if c.kind == Kind::Dir {
                queue.push((c.ino, dir.join(&c.name)));
            }
        }
        if !creates.is_empty() {
            let mut infos: Vec<CF_PLACEHOLDER_CREATE_INFO> = creates.iter().map(|h| h.info()).collect();
            let mut processed = 0u32;
            unsafe {
                CfCreatePlaceholders(
                    PCWSTR(path_wide(&dir).as_ptr()),
                    infos.as_mut_ptr(),
                    infos.len() as u32,
                    CF_CREATE_FLAG_NONE,
                    Some(&mut processed),
                )
                .map_err(win_err)?;
            }
        }
    }
    Ok(())
}

/// Owns the wide-string + identity backing storage for one `CF_PLACEHOLDER_CREATE_INFO`
/// (the struct holds raw pointers into these, so they must outlive the create call).
struct PlaceholderHolder {
    name: U16CString,
    identity: Vec<u8>,
    size: u64,
    mtime_filetime: u64,
    is_dir: bool,
}

impl PlaceholderHolder {
    fn new(name: &str, node_id: &str, size: u64, mtime_nanos: i64, is_dir: bool) -> Self {
        Self {
            name: to_wide(name),
            identity: FileIdentity::from_node_id(node_id).0,
            size: if is_dir { 0 } else { size },
            mtime_filetime: unix_nanos_to_filetime(mtime_nanos),
            is_dir,
        }
    }
    fn info(&self) -> CF_PLACEHOLDER_CREATE_INFO {
        // CfAPI metadata times are i64 (100 ns ticks since 1601) — exactly our FILETIME u64.
        let t = self.mtime_filetime as i64;
        let attrs = if self.is_dir { 0x10 /* FILE_ATTRIBUTE_DIRECTORY */ } else { FILE_ATTRIBUTE_NORMAL.0 };
        CF_PLACEHOLDER_CREATE_INFO {
            RelativeFileName: PCWSTR(self.name.as_ptr()),
            FsMetadata: CF_FS_METADATA {
                FileSize: self.size as i64,
                BasicInfo: windows::Win32::Storage::FileSystem::FILE_BASIC_INFO {
                    CreationTime: t,
                    LastAccessTime: t,
                    LastWriteTime: t,
                    ChangeTime: t,
                    FileAttributes: attrs,
                },
            },
            FileIdentity: self.identity.as_ptr() as *const c_void,
            FileIdentityLength: self.identity.len() as u32,
            // Mark the placeholder in-sync (just populated from the source of truth); a later
            // content change dehydrates it via CfUpdatePlaceholder. Disable on-demand
            // population since Phase 1 fully populates up front.
            Flags: CF_PLACEHOLDER_CREATE_FLAG_MARK_IN_SYNC | CF_PLACEHOLDER_CREATE_FLAG_DISABLE_ON_DEMAND_POPULATION,
            ..Default::default()
        }
    }
}

/// FETCH_DATA: the kernel needs bytes for a dehydrated placeholder. Resolve node → hydrate →
/// read the requested range → hand it back with `CfExecuteOperation(TRANSFER_DATA)`.
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

    // Recover the node_id from the placeholder's FileIdentity.
    let identity = std::slice::from_raw_parts(info.FileIdentity as *const u8, info.FileIdentityLength as usize);
    let node_id = match FileIdentity(identity.to_vec()).to_node_id() {
        Some(n) => n,
        None => return,
    };

    // Ensure the chunks are local (presigned GET), then read the required range.
    if let Some(h) = &state.hydrate {
        h(&node_id);
    }
    let fetch = params.Anonymous.FetchData;
    let offset = fetch.RequiredFileOffset;
    let length = fetch.RequiredLength;

    let ino = match state.provider.ino_for_node_id(&node_id) {
        Ok(Some(i)) => i,
        _ => return,
    };
    let data = match state.provider.read(ino, offset as u64, length as u32) {
        Ok(d) => d,
        Err(_) => return, // a real impl reports CfExecuteOperation with an error status
    };

    // Hand the bytes to the kernel.
    let op_info = CF_OPERATION_INFO {
        StructSize: std::mem::size_of::<CF_OPERATION_INFO>() as u32,
        Type: CF_OPERATION_TYPE_TRANSFER_DATA,
        ConnectionKey: info.ConnectionKey,
        TransferKey: info.TransferKey,
        CorrelationVector: info.CorrelationVector,
        SyncStatus: std::ptr::null(),
        RequestKey: info.RequestKey,
    };
    let mut op_params = CF_OPERATION_PARAMETERS {
        ParamSize: std::mem::size_of::<CF_OPERATION_PARAMETERS>() as u32,
        Anonymous: CF_OPERATION_PARAMETERS_0 {
            TransferData: CF_OPERATION_PARAMETERS_0_2 {
                Flags: CF_OPERATION_TRANSFER_DATA_FLAG_NONE,
                CompletionStatus: STATUS_SUCCESS,
                Buffer: data.as_ptr() as *const c_void,
                Offset: offset,
                Length: data.len() as i64,
            },
        },
    };
    let _ = CfExecuteOperation(&op_info, &mut op_params);
}

impl CfApiMountHandle {
    pub fn mountpoint(&self) -> &Path {
        &self.root
    }
    pub fn is_running(&self) -> bool {
        !self.stop.load(Ordering::Relaxed)
    }
    /// Block until Ctrl-C, then tear down (for the `maker-cfapi` CLI).
    pub fn run_until_ctrl_c(self) {
        let stop = self.stop.clone();
        let _ = ctrlc_set(move || stop.store(true, Ordering::Relaxed));
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
            let _ = CfUnregisterSyncRoot(PCWSTR(path_wide(&self.root).as_ptr()));
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
        // Walk parents via readdir from the root. (O(tree) — fine for invalidation, which is
        // rare; PHASE 2: maintain an ino→path index during populate for O(1).)
        let p = self.resolve_by_walk(ino)?;
        self.paths.lock().unwrap().insert(ino, p.clone());
        Some(p)
    }

    fn resolve_by_walk(&self, target: u64) -> Option<PathBuf> {
        // DFS from root building paths until we hit `target`.
        let mut stack = vec![(ROOT_INO, self.root.clone())];
        while let Some((ino, path)) = stack.pop() {
            for e in self.provider.readdir(ino).ok()? {
                let child = path.join(&e.name);
                if e.ino == target {
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
        unsafe {
            // Open a handle to the placeholder (backup semantics so dirs work too).
            let handle = match CreateFileW(
                PCWSTR(path_wide(&path).as_ptr()),
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
        // Keep `provider`/`root` referenced even on the early-return paths.
        let _ = (&self.provider, &self.root);
    }
}

fn win_err(e: windows::core::Error) -> std::io::Error {
    std::io::Error::other(format!("cfapi: {e}"))
}
fn fs_err(e: fs_provider::FsError) -> std::io::Error {
    std::io::Error::other(format!("provider: {e}"))
}

/// Minimal Ctrl-C hook without a dep: install a console control handler.
#[allow(unused_variables)]
fn ctrlc_set(f: impl Fn() + Send + 'static) -> std::io::Result<()> {
    // PHASE 2: wire SetConsoleCtrlHandler. For the smoke test, the process is killed
    // directly; the Drop impl still unregisters the sync root on exit.
    Ok(())
}
