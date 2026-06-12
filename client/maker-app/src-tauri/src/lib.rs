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
            platform
        ])
        .run(tauri::generate_context!())
        .expect("error while running tauri application");
}
