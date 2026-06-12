//! Tauri backend for the Maker client.
//!
//! Commands drive the native sync daemon. Auth is **token-persisted**: a device
//! registers (or pairs) once, the bearer token is saved under the app dir, and later
//! starts reuse it — we never re-register (which the hardened server refuses for an
//! existing email anyway). Additional devices join via a pairing code:
//! `create_pairing` on a signed-in device → `sync_pair` on the new one.
//!
//! The mount backend is chosen per-OS — all expose the same `start`/`stop`/`is_running`/
//! `mountpoint` API:
//! - **macOS:** WebDAV + native `mount_webdav` (FUSE-T can't mount on macOS 26+).
//! - **Linux:** FUSE (`fuser`).
//! - **Windows:** WinFsp (drive letter; needs `winfsp-x64.dll` on the search path).

use std::path::PathBuf;
use std::sync::Mutex;

use tauri::State;

#[cfg(target_os = "macos")]
type Mount = sync_engine::WebdavMount;
#[cfg(target_os = "linux")]
type Mount = sync_engine::Daemon;
#[cfg(target_os = "windows")]
type Mount = sync_engine::WinfspMount;

/// Holds the running mount (or `None` when stopped).
#[derive(Default)]
struct AppState(Mutex<Option<Mount>>);

// ---- credential persistence (register/pair once, reuse the token) ------------------

fn app_base() -> PathBuf {
    std::env::temp_dir().join("maker-app")
}

fn creds_path() -> PathBuf {
    app_base().join("credentials.json")
}

fn creds_key(server: &str, email: &str) -> String {
    format!("{server}|{email}")
}

/// The saved device token for this (server, email), if this device has registered/paired.
fn load_token(server: &str, email: &str) -> Option<String> {
    let data = std::fs::read_to_string(creds_path()).ok()?;
    let map: serde_json::Value = serde_json::from_str(&data).ok()?;
    map.get(creds_key(server, email))?.as_str().map(str::to_string)
}

fn save_token(server: &str, email: &str, token: &str) {
    let mut map: serde_json::Map<String, serde_json::Value> = std::fs::read_to_string(creds_path())
        .ok()
        .and_then(|s| serde_json::from_str(&s).ok())
        .unwrap_or_default();
    map.insert(creds_key(server, email), serde_json::Value::String(token.to_string()));
    let _ = std::fs::create_dir_all(app_base());
    if let Ok(json) = serde_json::to_string_pretty(&map) {
        let _ = std::fs::write(creds_path(), json);
    }
}

// ---- mounting ----------------------------------------------------------------------

/// Mount + start the sync loop with an already-obtained device `token`. Shared by
/// `sync_start` and `sync_pair`.
fn mount_with_token(
    state: &State<AppState>,
    server_url: &str,
    mountpoint: &str,
    token: String,
) -> Result<String, String> {
    use sync_engine::DaemonConfig;

    let mut guard = state.0.lock().unwrap();
    if guard.as_ref().is_some_and(|m| m.is_running()) {
        return Err("already mounted — unmount first".into());
    }

    let db = app_base().join("tree.db");
    let chunks = app_base().join("chunks");
    std::fs::create_dir_all(&chunks).map_err(|e| format!("chunk dir: {e}"))?;
    // On Windows the mount point is a drive letter (e.g. "Z:"), not a directory to create.
    #[cfg(not(target_os = "windows"))]
    std::fs::create_dir_all(mountpoint).map_err(|e| format!("mountpoint: {e}"))?;

    let cfg = DaemonConfig::new(mountpoint, db, chunks, server_url, token);
    let mount = Mount::start(cfg).map_err(|e| format!("mount failed: {e}"))?;
    let mp = mount.mountpoint().display().to_string();
    *guard = Some(mount);
    Ok(format!("mounted at {mp}"))
}

/// Register this device (first ever, on this server+email) or reuse a saved token, then
/// mount + sync against `server_url`. If the account already exists elsewhere, instructs
/// the user to pair instead (the secure multi-device path).
#[tauri::command]
fn sync_start(
    state: State<AppState>,
    server_url: String,
    email: String,
    mountpoint: String,
) -> Result<String, String> {
    use sync_client::{Error, ServerClient};

    let token = if let Some(t) = load_token(&server_url, &email) {
        t // already registered/paired on this device — reuse the token, never re-register
    } else {
        let mut client = ServerClient::new(&server_url);
        match client.register(&email, "maker-app") {
            Ok(reg) => {
                save_token(&server_url, &email, &reg.device_token);
                reg.device_token
            }
            Err(Error::Server { status: 409, .. }) => {
                return Err("This account already exists on another device. On a signed-in \
                            device choose “Add a device” to get a pairing code, then use \
                            “Pair this device” here with that code."
                    .into());
            }
            Err(e) => return Err(format!("register failed: {e}")),
        }
    };

    mount_with_token(&state, &server_url, &mountpoint, token)
}

/// Redeem a pairing code to join an existing library on this (new) device, then mount.
#[tauri::command]
fn sync_pair(
    state: State<AppState>,
    server_url: String,
    email: String,
    code: String,
    mountpoint: String,
) -> Result<String, String> {
    use sync_client::ServerClient;

    let mut client = ServerClient::new(&server_url);
    let reg = client
        .pair(&email, &code, "maker-app")
        .map_err(|e| format!("pairing failed: {e}"))?;
    save_token(&server_url, &email, &reg.device_token);
    mount_with_token(&state, &server_url, &mountpoint, reg.device_token)
}

/// On a signed-in device, mint a pairing code for adding another device. Returns the
/// code to display to the user.
#[tauri::command]
fn create_pairing(server_url: String, email: String) -> Result<String, String> {
    use sync_client::ServerClient;

    let token = load_token(&server_url, &email)
        .ok_or("this device isn't signed in yet — start syncing first")?;
    let client = ServerClient::with_token(&server_url, token);
    let p = client.create_pairing().map_err(|e| format!("couldn't create a code: {e}"))?;
    Ok(p.code)
}

// ---- file browser + versioning (queries the server's synced tree) ------------------

#[derive(serde::Serialize)]
struct BrowseEntry {
    node_id: String,
    parent_node_id: Option<String>,
    name: String,
    kind: String,
    size: u64,
}

/// List the whole library tree (paginated server-side, flattened here). The frontend
/// builds the folder hierarchy from parent_node_id.
#[tauri::command]
fn browse(server_url: String, email: String) -> Result<Vec<BrowseEntry>, String> {
    use sync_client::ServerClient;
    let token = load_token(&server_url, &email).ok_or("this device isn't signed in yet")?;
    let client = ServerClient::with_token(&server_url, token);

    let mut out = Vec::new();
    let mut after = 0;
    loop {
        let tree = client.tree(after).map_err(|e| format!("browse failed: {e}"))?;
        if tree.nodes.is_empty() {
            break;
        }
        for n in &tree.nodes {
            out.push(BrowseEntry {
                node_id: n.node_id.clone(),
                parent_node_id: n.parent_node_id.clone(),
                name: n.name.clone(),
                kind: n.kind.clone(),
                size: n.size.unwrap_or(0),
            });
        }
        match tree.next_after_id {
            Some(id) => after = id,
            None => break,
        }
    }
    Ok(out)
}

#[derive(serde::Serialize)]
struct VersionEntry {
    version_id: String,
    size: u64,
    created_at: String,
}

/// Version history of a file (newest first) — the basis for restore.
#[tauri::command]
fn file_versions(server_url: String, email: String, node_id: String) -> Result<Vec<VersionEntry>, String> {
    use sync_client::ServerClient;
    let token = load_token(&server_url, &email).ok_or("this device isn't signed in yet")?;
    let client = ServerClient::with_token(&server_url, token);
    let vs = client.versions(&node_id).map_err(|e| format!("versions failed: {e}"))?;
    Ok(vs
        .versions
        .into_iter()
        .map(|v| VersionEntry { version_id: v.version_id, size: v.size, created_at: v.created_at })
        .collect())
}

/// Restore a file to an earlier version (creates a new version reusing the old
/// manifest — lossless). The sync loop then propagates it to every device.
#[tauri::command]
fn restore_version(
    server_url: String,
    email: String,
    node_id: String,
    version_id: String,
) -> Result<String, String> {
    use sync_client::ServerClient;
    let token = load_token(&server_url, &email).ok_or("this device isn't signed in yet")?;
    let client = ServerClient::with_token(&server_url, token);
    client.restore(&node_id, &version_id).map_err(|e| format!("restore failed: {e}"))?;
    Ok("restored".into())
}

// ---- conflicts (divergent offline edits) -------------------------------------------

#[derive(serde::Serialize)]
struct ConflictSideOut {
    version_id: String,
    size: u64,
    created_at: String,
    device_name: String,
}

#[derive(serde::Serialize)]
struct ConflictOut {
    node_id: String,
    name: Option<String>,
    current: Option<ConflictSideOut>,
    incoming: Option<ConflictSideOut>,
}

fn side(s: sync_client::ConflictSide) -> ConflictSideOut {
    ConflictSideOut { version_id: s.version_id, size: s.size, created_at: s.created_at, device_name: s.device_name }
}

/// Unresolved conflicts, with both sides' device + time + size, for the resolution prompt.
#[tauri::command]
fn conflicts(server_url: String, email: String) -> Result<Vec<ConflictOut>, String> {
    use sync_client::ServerClient;
    let token = load_token(&server_url, &email).ok_or("this device isn't signed in yet")?;
    let client = ServerClient::with_token(&server_url, token);
    let cs = client.conflicts().map_err(|e| format!("conflicts failed: {e}"))?;
    Ok(cs
        .conflicts
        .into_iter()
        .map(|c| ConflictOut { node_id: c.node_id, name: c.name, current: c.current.map(side), incoming: c.incoming.map(side) })
        .collect())
}

/// Resolve a conflict: keep one version as current (the other stays in history).
#[tauri::command]
fn resolve_conflict_keep(server_url: String, email: String, node_id: String, version_id: String) -> Result<String, String> {
    use sync_client::ServerClient;
    let token = load_token(&server_url, &email).ok_or("this device isn't signed in yet")?;
    let client = ServerClient::with_token(&server_url, token);
    client.resolve_conflict_keep(&node_id, &version_id).map_err(|e| format!("resolve failed: {e}"))?;
    Ok("kept".into())
}

/// Resolve a conflict: keep both — the incoming side becomes a new sibling file.
#[tauri::command]
fn resolve_conflict_split(server_url: String, email: String, node_id: String) -> Result<String, String> {
    use sync_client::ServerClient;
    let token = load_token(&server_url, &email).ok_or("this device isn't signed in yet")?;
    let client = ServerClient::with_token(&server_url, token);
    client.resolve_conflict_split(&node_id).map_err(|e| format!("split failed: {e}"))?;
    Ok("split".into())
}

#[tauri::command]
fn sync_stop(state: State<AppState>) -> Result<String, String> {
    let mut guard = state.0.lock().unwrap();
    match guard.take() {
        Some(mut m) => {
            m.stop();
            Ok("unmounted".into())
        }
        None => Err("not mounted".into()),
    }
}

#[tauri::command]
fn sync_status(state: State<AppState>) -> String {
    let guard = state.0.lock().unwrap();
    match guard.as_ref() {
        Some(m) if m.is_running() => format!("mounted at {}", m.mountpoint().display()),
        _ => "unmounted".into(),
    }
}

/// The OS (`"windows"`/`"macos"`/`"linux"`), so the frontend can default the mount point
/// sensibly — a drive letter on Windows, a directory elsewhere.
#[tauri::command]
fn platform() -> &'static str {
    std::env::consts::OS
}

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    tauri::Builder::default()
        .manage(AppState::default())
        .invoke_handler(tauri::generate_handler![
            sync_start,
            sync_pair,
            create_pairing,
            sync_stop,
            sync_status,
            platform,
            browse,
            file_versions,
            restore_version,
            conflicts,
            resolve_conflict_keep,
            resolve_conflict_split
        ])
        .run(tauri::generate_context!())
        .expect("error while running tauri application");
}
