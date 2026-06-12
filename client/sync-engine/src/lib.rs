//! The sync daemon. Bridges `fs-provider` (local SQLite tree + chunk cache) and
//! `sync-client` (the server API) to **push** local changes and **pull** remote
//! ones, with on-demand **hydration** of chunk bytes.
//!
//! Chunk bytes move through a pluggable [`ChunkIO`]:
//! - [`SharedDirIO`] — a shared local directory (test/dev stand-in for the cloud).
//! - [`PresignedIO`] — PUT/GET to the presigned URLs the server mints (R2/SeaweedFS).
//!
//! Metadata always flows through the real server API. `sync_once` is the loop body.

use std::collections::HashMap;
use std::path::PathBuf;
#[cfg(target_os = "linux")] // only the FUSE EngineHydrator holds an Arc
use std::sync::Arc;

use fs_provider::{ChunkLoc, Kind, SqliteProvider, SyncNode};
use sync_client::{Change, ChunkRef, CommitBegin, ServerClient, TreeNode};

mod daemon;
pub use daemon::{DaemonConfig, WebdavMount, DEFAULT_POLL};
#[cfg(target_os = "linux")]
pub use daemon::Daemon;
#[cfg(target_os = "windows")]
pub use daemon::WinfspMount;

#[derive(Debug, thiserror::Error)]
pub enum Error {
    #[error("fs: {0}")]
    Fs(#[from] fs_provider::FsError),
    #[error("api: {0}")]
    Api(#[from] sync_client::Error),
    #[error("io: {0}")]
    Io(#[from] std::io::Error),
    #[error("no presigned url for {0}")]
    NoUrl(String),
}

pub type Result<T> = std::result::Result<T, Error>;

/// Moves chunk bytes to/from "the cloud".
pub trait ChunkIO {
    /// Upload `hash`'s bytes. `put_urls` are from `commit_begin` (presigned PUTs).
    fn put(&self, hash: &str, put_urls: &HashMap<String, String>, bytes: Vec<u8>) -> Result<()>;
    /// Download `hash`'s bytes. `get_url` is from `/chunks/download` (or `None`).
    fn get(&self, hash: &str, get_url: Option<&str>) -> Result<Vec<u8>>;
}

/// The cloud is a local directory. Stand-in for R2/SeaweedFS in tests/dev; ignores
/// the presigned URLs and keys bytes by content hash.
pub struct SharedDirIO {
    dir: PathBuf,
}

impl SharedDirIO {
    pub fn new(dir: impl Into<PathBuf>) -> std::io::Result<Self> {
        let dir = dir.into();
        std::fs::create_dir_all(&dir)?;
        Ok(Self { dir })
    }
    fn path(&self, hash: &str) -> PathBuf {
        self.dir.join(hash)
    }
}

impl ChunkIO for SharedDirIO {
    fn put(&self, hash: &str, _urls: &HashMap<String, String>, bytes: Vec<u8>) -> Result<()> {
        std::fs::write(self.path(hash), bytes)?;
        Ok(())
    }
    fn get(&self, hash: &str, _url: Option<&str>) -> Result<Vec<u8>> {
        Ok(std::fs::read(self.path(hash))?)
    }
}

/// PUT/GET to the presigned URLs the server mints — the production transport
/// (R2 / SeaweedFS S3). Bytes go client ⇄ storage directly.
pub struct PresignedIO<'a> {
    client: &'a ServerClient,
}

impl<'a> PresignedIO<'a> {
    pub fn new(client: &'a ServerClient) -> Self {
        Self { client }
    }
}

impl ChunkIO for PresignedIO<'_> {
    fn put(&self, hash: &str, put_urls: &HashMap<String, String>, bytes: Vec<u8>) -> Result<()> {
        let url = put_urls.get(hash).ok_or_else(|| Error::NoUrl(hash.to_string()))?;
        self.client.upload_chunk(url, bytes)?;
        Ok(())
    }
    fn get(&self, hash: &str, get_url: Option<&str>) -> Result<Vec<u8>> {
        let url = get_url.ok_or_else(|| Error::NoUrl(hash.to_string()))?;
        Ok(self.client.download_chunk(url)?)
    }
}

pub struct SyncEngine;

impl SyncEngine {
    /// Push the whole local tree to the server, uploading missing chunks via `io`.
    /// (Idempotent; used by the examples/tests. The running daemon uses
    /// [`push_outbox`](Self::push_outbox) for incremental pushes.)
    pub fn push(provider: &SqliteProvider, client: &ServerClient, io: &dyn ChunkIO) -> Result<()> {
        for node in provider.export_tree()? {
            push_node(provider, client, io, &node)?;
        }
        Ok(())
    }

    /// Incremental push: drain the local outbox (dirty `node_id`s queued by FUSE
    /// writes), sending only what changed. Order is parents-first (the outbox preserves
    /// insertion order). The SQLite lock is **never held across WAN I/O** — each
    /// provider call locks and releases on its own — so the metadata path stays local.
    pub fn push_outbox(provider: &SqliteProvider, client: &ServerClient, io: &dyn ChunkIO) -> Result<()> {
        for (node_id, op) in provider.outbox_list()? {
            if op == "delete" {
                match client.delete_node(&node_id) {
                    Ok(_) => {}
                    // The node may never have reached the server (created then deleted
                    // before this drained). Treat "unknown" as already-gone.
                    Err(sync_client::Error::Server { status: 404, .. }) => {}
                    Err(e) => return Err(e.into()),
                }
            } else {
                // 'upsert'. If the node vanished between enqueue and now (a delete races
                // ahead), there's nothing to send — just drop the stale entry.
                match provider.sync_node(&node_id)? {
                    Some(node) => push_node(provider, client, io, &node)?,
                    None => {}
                }
            }
            provider.outbox_clear(&node_id)?;
        }
        Ok(())
    }

    /// Initial sync: apply the full-tree snapshot (paginated) to the local provider.
    pub fn pull_snapshot(provider: &SqliteProvider, client: &ServerClient) -> Result<i64> {
        let mut after = 0;
        let mut head;
        loop {
            let tree = client.tree(after)?;
            head = tree.head_seq;
            for n in &tree.nodes {
                provider.apply_remote(&tree_node_to_sync(n))?;
            }
            match tree.next_after_id {
                Some(id) if !tree.nodes.is_empty() => after = id,
                _ => break,
            }
        }
        Ok(head)
    }

    /// Incremental: apply changelog entries since `cursor`. Returns the new cursor.
    /// Pages through the delta — the server caps each response, so a device that's many
    /// changes behind (the offline-reconnect case) **must** loop or it silently skips
    /// every entry past the first page. Uses the default page size.
    pub fn pull_changes(provider: &SqliteProvider, client: &ServerClient, cursor: i64) -> Result<i64> {
        Self::pull_changes_paged(provider, client, cursor, 500)
    }

    /// [`pull_changes`](Self::pull_changes) with an explicit page size (for tests that
    /// want to force multi-page pulls cheaply). Loops `changes(cursor, page)` until the
    /// device is caught up, advancing the cursor to the **last applied entry's seq** each
    /// round — never to the global `head_seq`, which would jump past un-applied entries.
    pub fn pull_changes_paged(
        provider: &SqliteProvider,
        client: &ServerClient,
        mut cursor: i64,
        page: i64,
    ) -> Result<i64> {
        let mut checked_floor = false;
        loop {
            let resp = client.changes_paged(cursor, page)?;

            // Full-resync backstop: if the changelog was pruned past our cursor, the
            // delta has a hole (we'd silently skip the pruned entries). Detect it on the
            // first round via `oldest_seq` and fall back to a full snapshot instead. A
            // fresh device (cursor 0, nothing pruned → oldest_seq ≤ 1) never trips this.
            if !checked_floor {
                checked_floor = true;
                if resp.oldest_seq > cursor + 1 {
                    return Self::pull_snapshot(provider, client);
                }
            }

            if resp.changes.is_empty() {
                // Caught up: no more entries beyond `cursor`. head_seq is the new floor.
                return Ok(resp.head_seq.max(cursor));
            }
            for ch in &resp.changes {
                apply_change(provider, ch)?;
            }
            // Advance only as far as we actually applied; loop for the next page.
            cursor = resp.changes.last().map(|c| c.seq).unwrap_or(cursor);
        }
    }

    /// Hydrate a file's chunks from the cloud into the local cache.
    pub fn hydrate(
        provider: &SqliteProvider,
        client: &ServerClient,
        io: &dyn ChunkIO,
        node_id: &str,
    ) -> Result<()> {
        let hashes = provider.node_manifest_hashes(node_id)?;
        let missing: Vec<String> = hashes.into_iter().filter(|h| !provider.has_chunk(h)).collect();
        if missing.is_empty() {
            return Ok(());
        }
        let urls = client.download_urls(&missing)?.urls;
        for h in &missing {
            let bytes = io.get(h, urls.get(h).map(String::as_str))?;
            provider.chunk_put(h, &bytes)?;
        }
        Ok(())
    }

    /// One whole-tree loop iteration: push the full tree, then pull remote changes.
    /// (Retained for the examples; the daemon uses [`sync_tick`](Self::sync_tick).)
    pub fn sync_once(
        provider: &SqliteProvider,
        client: &ServerClient,
        io: &dyn ChunkIO,
        cursor: i64,
    ) -> Result<i64> {
        Self::push(provider, client, io)?;
        Self::pull_changes(provider, client, cursor)
    }

    /// The daemon's loop body: drain the outbox (incremental push), then pull the
    /// changelog delta since `cursor`. Returns the new cursor to persist. This is the
    /// reusable tick the background sync thread calls on each interval.
    pub fn sync_tick(
        provider: &SqliteProvider,
        client: &ServerClient,
        io: &dyn ChunkIO,
        cursor: i64,
    ) -> Result<i64> {
        Self::push_outbox(provider, client, io)?;
        Self::pull_changes(provider, client, cursor)
    }
}

/// Push a single node (dir → `mkdir`; file → commit_begin → upload missing chunks →
/// finalize). Shared by whole-tree [`push`](SyncEngine::push) and incremental
/// [`push_outbox`](SyncEngine::push_outbox).
fn push_node(
    provider: &SqliteProvider,
    client: &ServerClient,
    io: &dyn ChunkIO,
    node: &SyncNode,
) -> Result<()> {
    match node.kind {
        Kind::Dir => {
            client.mkdir(&node.node_id, node.parent_node_id.as_deref(), &node.name, node.mode)?;
        }
        Kind::File => {
            let manifest: Vec<ChunkRef> = node
                .chunks
                .iter()
                .map(|c| ChunkRef { hash: c.hash.clone(), offset: c.offset, length: c.length })
                .collect();
            let size = node.chunks.iter().map(|c| c.length).sum();
            let commit_id = uuid::Uuid::new_v4().to_string();
            let begin = client.commit_begin(&CommitBegin {
                commit_id: commit_id.clone(),
                node_id: node.node_id.clone(),
                parent_node_id: node.parent_node_id.clone(),
                name: node.name.clone(),
                // The version this edit was based on — the server flags a conflict if it's
                // no longer current (a concurrent edit slipped in, e.g. while offline).
                base_version_id: node.version_id.clone(),
                size,
                manifest,
                mode: node.mode,
            })?;
            for hash in &begin.missing {
                let bytes = provider.chunk_get(hash)?;
                io.put(hash, &begin.put_urls, bytes)?;
            }
            let fin = client.commit_finalize(&commit_id)?;
            // Record the new server version so a follow-up edit bases on it (not the now
            // stale prior version, which would falsely conflict with our own push).
            provider.set_node_version(&node.node_id, &fin.version_id)?;
        }
    }
    Ok(())
}

/// Bridges the FUSE read path to the sync engine: on a chunk-cache miss the adapter
/// calls [`Hydrate::hydrate`], which fetches the file's chunks from the cloud via
/// presigned GET. Holds `Arc` clones shared with the mount + sync threads.
/// (FUSE only — macOS's `WebdavMount` uses an inline closure hydrator.)
#[cfg(target_os = "linux")]
pub struct EngineHydrator {
    provider: Arc<SqliteProvider>,
    client: ServerClient,
}

#[cfg(target_os = "linux")]
impl EngineHydrator {
    pub fn new(provider: Arc<SqliteProvider>, client: ServerClient) -> Self {
        Self { provider, client }
    }
}

#[cfg(target_os = "linux")]
impl fs_fuse::Hydrate for EngineHydrator {
    fn hydrate(&self, ino: u64) {
        let node_id = match self.provider.node_id_for(ino) {
            Ok(Some(id)) => id,
            Ok(None) => return,
            Err(e) => {
                eprintln!("hydrate: node_id lookup for ino {ino} failed: {e}");
                return;
            }
        };
        let io = PresignedIO::new(&self.client);
        if let Err(e) = SyncEngine::hydrate(&self.provider, &self.client, &io, &node_id) {
            eprintln!("hydrate: ino {ino} (node {node_id}) failed: {e}");
        }
    }
}

/// Freshness-on-access: on a file open, pull the changelog delta so the local tree
/// reflects the latest before serving (the read then hydrates the new manifest's chunks
/// on miss). Throttled so frequent opens don't hammer the server — the background loop +
/// nudge already keep us mostly current, so this only matters in the gap between ticks.
#[cfg(target_os = "linux")]
pub struct EngineFreshness {
    provider: Arc<SqliteProvider>,
    client: ServerClient,
    throttle: std::time::Duration,
    last: std::sync::Mutex<Option<std::time::Instant>>,
}

#[cfg(target_os = "linux")]
impl EngineFreshness {
    pub fn new(provider: Arc<SqliteProvider>, client: ServerClient) -> Self {
        Self { provider, client, throttle: std::time::Duration::from_millis(750), last: std::sync::Mutex::new(None) }
    }
}

/// Best-effort cross-device advisory lock over the server. Acquire on open-for-write,
/// release on close — both **non-blocking** (a background thread does the short-timeout
/// HTTP, so an offline open never waits; it just opens the local cached copy). The lock
/// is advisory: it lets connected clients avoid colliding, and conflict detection handles
/// whatever the lock can't (offline edits, ignored locks).
#[cfg(target_os = "linux")]
pub struct EngineRemoteLock {
    provider: Arc<SqliteProvider>,
    client: ServerClient,
}

#[cfg(target_os = "linux")]
impl EngineRemoteLock {
    pub fn new(provider: Arc<SqliteProvider>, client: ServerClient) -> Self {
        Self { provider, client }
    }
}

#[cfg(target_os = "linux")]
impl fs_fuse::RemoteLock for EngineRemoteLock {
    fn acquire(&self, ino: u64) {
        if let Ok(Some(node_id)) = self.provider.node_id_for(ino) {
            let client = self.client.clone();
            std::thread::spawn(move || {
                let _ = client.lock(&node_id); // best-effort; offline/held just no-ops
            });
        }
    }
    fn release(&self, ino: u64) {
        if let Ok(Some(node_id)) = self.provider.node_id_for(ino) {
            let client = self.client.clone();
            std::thread::spawn(move || {
                let _ = client.unlock(&node_id);
            });
        }
    }
}

#[cfg(target_os = "linux")]
impl fs_fuse::Freshness for EngineFreshness {
    fn refresh(&self) {
        {
            // Skip if we pulled very recently — the loop/nudge has us covered.
            let mut last = self.last.lock().unwrap();
            if last.is_some_and(|t| t.elapsed() < self.throttle) {
                return;
            }
            *last = Some(std::time::Instant::now());
        }
        let cursor = self.provider.cursor().unwrap_or(0);
        match SyncEngine::pull_changes(&self.provider, &self.client, cursor) {
            // Advance the cursor monotonically — the sync loop may also be advancing it
            // concurrently; a regression would just re-pull an already-applied (idempotent)
            // delta, so max() is the safe reconciliation.
            Ok(new) => {
                let cur = self.provider.cursor().unwrap_or(0);
                let _ = self.provider.set_cursor(cur.max(new));
            }
            Err(e) => eprintln!("freshness: catch-up pull failed: {e}"),
        }
    }
}

fn tree_node_to_sync(n: &TreeNode) -> SyncNode {
    let manifest = n.manifest.clone().unwrap_or_default();
    let manifest_id = (!manifest.is_empty()).then(|| sync_client::manifest_id(&manifest));
    let chunks = manifest
        .into_iter()
        .map(|c| ChunkLoc { hash: c.hash, offset: c.offset, length: c.length })
        .collect();
    SyncNode {
        node_id: n.node_id.clone(),
        parent_node_id: n.parent_node_id.clone(),
        name: n.name.clone(),
        kind: if n.kind == "dir" { Kind::Dir } else { Kind::File },
        manifest_id,
        chunks,
        version_id: n.version_id.clone(),
        mode: n.mode.unwrap_or(if n.kind == "dir" { 0o755 } else { 0o644 }),
    }
}

/// Apply one changelog entry to the local tree. The server soft-deletes, so a `delete`
/// change still carries the node (with `deleted: true`); treat either signal as a delete
/// and remove the node — and any descendants — locally. A *move* is not a delete: the
/// server models it as op `move` on the same stable node_id with a new parent/name, so it
/// falls through to `apply_remote` and updates the existing row in place (no duplicate).
fn apply_change(provider: &SqliteProvider, ch: &Change) -> Result<()> {
    // A `conflict` change records a divergent version that is NOT current — the node's
    // content is unchanged, so it must not be applied to the tree. It's surfaced to the
    // user via GET /v1/conflicts and resolved there.
    if ch.op == "conflict" {
        return Ok(());
    }
    let deleted = ch.node.as_ref().is_some_and(|n| n.deleted);
    if ch.op == "delete" || deleted {
        provider.apply_remote_delete(&ch.node_id)?;
    } else if let Some(sn) = change_to_sync(ch) {
        provider.apply_remote(&sn)?;
    }
    Ok(())
}

fn change_to_sync(ch: &Change) -> Option<SyncNode> {
    let view = ch.node.as_ref()?;
    // Deletes are applied by the caller (`apply_remote_delete`); never reconstruct a
    // tombstoned node here.
    if ch.op == "delete" || view.deleted {
        return None;
    }
    let manifest = ch.manifest.clone().unwrap_or_default();
    let manifest_id = (!manifest.is_empty()).then(|| sync_client::manifest_id(&manifest));
    let chunks = manifest
        .into_iter()
        .map(|c| ChunkLoc { hash: c.hash, offset: c.offset, length: c.length })
        .collect();
    Some(SyncNode {
        node_id: view.node_id.clone(),
        parent_node_id: view.parent_node_id.clone(),
        name: view.name.clone(),
        kind: if view.kind == "dir" { Kind::Dir } else { Kind::File },
        manifest_id,
        chunks,
        version_id: ch.version.as_ref().map(|v| v.version_id.clone()),
        mode: view.mode.unwrap_or(if view.kind == "dir" { 0o755 } else { 0o644 }),
    })
}
