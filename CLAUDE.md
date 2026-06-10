# CLAUDE.md

Project context and architecture for an AI coding agent (Claude Code) and human
developers. Working name: **Maker Server** (rename freely).

---

## 1. What we're building

A self-hostable server + client for managing a maker's working life:

- **Files** — 3D files (STL, 3MF, OBJ), CAD files (STEP/IGES, native Fusion/FreeCAD/SolidWorks), and LightBurn projects (`.lbrn2`), with versioning and in-browser preview.
- **Inventory** — what materials and components are on hand (filament, electronics, fasteners, raw stock), with quantities, storage locations, and suppliers.
- **Projects** — work that spans **hardware, firmware, and software**, with tasks, a build log, attached files, and a bill of materials that links to inventory.

It ships in **two deployment modes**:

1. **Self-hosted** — runs on the user's own box (e.g., an Unraid server), files reachable on the LAN as a mounted drive.
2. **Managed (SaaS)** — we host it; users mount their library remotely over the internet.

This is intended to be a **commercial product**, so third-party licensing is a hard constraint (see §10). Avoid copyleft (GPL/AGPL) in anything we redistribute.

---

## 2. Tech stack (decided)

| Layer | Choice | Notes |
|---|---|---|
| Backend | **Ruby on Rails 8** | Solid Queue (jobs, no Redis), Solid Cache, Kamal 2 deploy |
| Database | **PostgreSQL** | JSON columns, full-text search, room to grow |
| Object storage | **S3-compatible** | Cloud (R2 / B2 / S3) for managed; user's own MinIO/SeaweedFS for self-host |
| File mount (client) | **rclone mount** (MIT) | `--vfs-cache-mode full`; on-demand caching; bundled as a sidecar |
| Near-instant propagation | **ActionCable → `rclone rc vfs/refresh`** | object storage has no change-polling; we push refresh events ourselves |
| Client app | **Tauri** (Rust core + web UI) | bundles rclone; drives it via the rclone rc HTTP API |
| Self-host LAN option | **SMB share (Samba)** | single live copy = inherently instant; Rails indexes the same dir via inotify |
| 3D preview (browser) | **Three.js** | loaders for STL/OBJ/3MF/GLTF |
| CAD conversion (server) | **FreeCAD CLI / CadQuery (OpenCASCADE)** | tessellate STEP/IGES → mesh/GLTF + thumbnail, in background jobs |
| Auth | OAuth/OIDC-style | tokens in OS keychain; short-lived **STS** storage creds minted by Rails |

---

## 3. Core architecture: control plane vs. data plane

The single most important rule: **file bytes never flow through Rails.**

- **Data plane** — `maker app → mounted drive → rclone → object storage`. The client moves bytes directly to storage. Rails is not in this path.
- **Control plane** — Rails owns identity, file/project/inventory metadata, the file index, preview generation, and credential minting. The client talks to Rails for auth, config, and change events.

This separation is what keeps the system robust and lets us swap the sync engine later (see §6, §8).

### Near-instant propagation (the subtle part)

`rclone mount` makes a save reach storage within a couple of seconds (`--vfs-write-back`). The hard part is the **other** machine seeing it: S3-compatible backends do **not** support change-polling, so a second mount won't notice a remote change until `--dir-cache-time` expires (default 5 min).

**Solution:** when a file lands in storage, Rails pushes a "file changed" event over **ActionCable** to other connected clients; each client's rclone controller calls **`rclone rc vfs/refresh dir=…`** for that path. The other mount then shows the change within ~1–2 s. End-to-end latency ≈ write-back delay + push + refresh ≈ 2–4 s.

---

## 4. Deployment modes

### Self-hosted (LAN)
Simplest path: expose the library as an **SMB share** (Samba; native on Unraid). There is a single live copy on the server, so propagation is genuinely instant with no caching games, no full local copies, and no client install. Rails indexes/watches the same directory with **inotify**.

### Managed (SaaS)
Raw SMB can't be exposed over the internet. The **client app** runs `rclone mount` against our cloud bucket over HTTPS with `--vfs-cache-mode full`, and gets near-instant freshness via the ActionCable → `vfs/refresh` channel.

### Unified option
For a single client codebase, always use rclone mount against an S3 endpoint — the user's own MinIO/SeaweedFS for self-host, our cloud bucket for managed. Trades the LAN's true-instant single-source behavior for one consistent client. **Decide this early** (see §11 open questions).

---

## 5. Data model (the maker layer in Rails)

Identity is **content-hash keyed from day one** (a per-version checksum). This is cheap now, is how we detect changes, and is the foundation the future chunk/dedup engine needs — retrofitting it later is painful, so do it up front.

- **Asset** — a logical file. `path`, `content_type`, `current_version_id`, extracted metadata (bounding box, triangle count, layer info), `project_id?`.
- **FileVersion** — immutable version history for an Asset. `checksum` (e.g. SHA-256), `byte_size`, `created_at`, storage key. Copy-on-change: a new checksum = a new version.
- **Project** — spans hardware/firmware/software. Has many Assets, a build log (journal entries), tasks, and links to firmware/software git repos.
- **Bom / BomItem** — a project's bill of materials; each item references an InventoryItem and a quantity.
- **InventoryItem** — `name`, `quantity`, `location/bin`, `category`, `supplier`, optional barcode/QR.
- **Derived artifacts** (thumbnails, preview meshes) — owned entirely by the app via **Active Storage**; regenerable, never the source of truth.

Canonical files live in object storage (data plane). Active Storage is used **only** for app-owned derived artifacts, never for the canonical maker files.

---

## 6. File indexing & preview pipeline

Trigger sources, depending on mode:
- Self-host SMB: **inotify** watcher on the library directory.
- Managed/object-storage: bucket event notification → webhook, **or** the client reports the change after upload.

On a change event, enqueue a **Solid Queue** job that:
1. Confirms the file is fully written (handle atomic save/rename, debounce rapid autosaves).
2. Computes the checksum; creates a FileVersion if the content changed.
3. Extracts metadata (dimensions, triangle count, `.lbrn2` layers, etc.).
4. Generates a web preview (Three.js-loadable mesh) — for STEP/IGES, tessellate via FreeCAD CLI / CadQuery first — plus a thumbnail.
5. Upserts the Asset index.

**Exclude churn:** filter out backup/temp/lock files (FreeCAD `.FCStd1` / `.FCBak`, LightBurn autosave/backup, lock files) so they don't sync or index.

> CPU note: the conversion/tessellation jobs are the only CPU-heavy part of the system (spiky, multi-core). The sync client is light. Spec server cores for previews, not for sync.

---

## 7. Client app (Tauri) — structure & lifecycle

One installed app per machine. Bundles the rclone binary as a **sidecar** and the FUSE driver; wraps them in our own UI, auth, and config.

**Modules**
- **UI layer** — tray, windows, sign-in.
- **App core** — event bus + state machine; the coordinator and the seam for future features.
- **Auth** — OAuth/OIDC login; tokens in the OS keychain (Keychain / Credential Manager / libsecret).
- **rclone controller** — starts `rclone rcd` (remote-control mode) and drives it over the localhost rc API: issue mount, query stats, refresh cache, unmount. Supervises health (mount responsive, not just process alive), restarts with backoff, pins critical flags.

**Mount lifecycle** — model explicitly as a state machine:
`SignedOut → Authenticating → FetchingConfig → DriverMissing → Mounting → Mounted → Degraded → Remounting → Error → Unmounting`.
Transitions are driven by four event sources: token expiry, network up/down, OS sleep/wake, rclone process health. Handle sleep/wake and network loss explicitly so you never leave a hung mount.

**Extensibility** — features subscribe to the event bus and reuse the shared API client + the ActionCable connection. Future: selective per-project sync, local preview/index, conflict UI, "register files to a project."

---

## 8. Auth & storage credentials

Two layers, kept separate:
1. **User auth** — browser/webview OAuth/OIDC flow → short-lived access token + refresh token, stored in the OS keychain. Never a plaintext file.
2. **Storage auth** — the client never holds permanent S3 keys. It calls a Rails endpoint that uses **STS** to mint **temporary, prefix-scoped** credentials with an expiry. The controller feeds them to rclone and refreshes before they lapse. Rails alone holds master keys → a stolen laptop has a small, self-expiring blast radius.

---

## 9. Roadmap / phasing

### v1 (MVP) — ship the simple thing
- Rails app: Assets, FileVersions, Projects, BOM, Inventory, previews.
- rclone mount + `--vfs-cache-mode full`; ActionCable → `vfs/refresh` for near-instant.
- **Whole-file upload** (no chunking). Fine for LightBurn (`.lbrn2` is tiny) and typical CAD on a LAN.
- Self-host via SMB **or** rclone-to-S3; managed via rclone-to-cloud.
- Single user, a few of their own devices. Simple conflict handling.
- Content-hash file identity in place (enables v2).

### v2 (later) — only when the limitation bites
- **Block-level delta + dedup**: content-defined chunking (FastCDC), content-addressed chunk store, upload only missing chunks. (Reference: **ByteSync**, MIT, has a working C# block-delta + dedup engine — extract or learn from it.)
- **On-demand placeholder files** via native OS providers if rclone mount UX isn't seamless enough: **CfAPI** (Windows), **File Provider** (macOS), **FUSE** (Linux).
- One-time **re-chunk backfill** job over existing files (background, not a migration blocker).

### Deferred / not now
- Don't build chunk-storage scaffolding in v1 — premature.
- Don't build multi-user shared-folder collaboration (much harder reconcile).

**Forward-looking discipline so v2 isn't blocked:** keep the sync engine behind an interface in the client (`push local changes / pull remote / status`), not raw rclone calls everywhere. Swapping rclone for a chunk engine should be an implementation change, not an app rewrite.

---

## 10. Key decisions & rationale (don't relitigate)

- **rclone mount, not bisync.** bisync stores full copies on every machine and syncs on a schedule — fails the "don't store everything" + "near-instant" requirements. mount is on-demand and (with our push-refresh) near-instant.
- **Not Seafile.** Technically ideal (block delta + on-demand SeaDrive) but **AGPLv3 server / GPLv2 client** — incompatible with a closed-source commercial product.
- **rclone is MIT** — safe to bundle and ship.
- **Syncthing is MPL-2.0** — commercially bundleable; it's the fallback delta engine, but it's full-sync only (no on-demand), so it doesn't fit the on-demand requirement.
- **ByteSync is MIT** — a sync/backup/dedup utility (not a mounted virtual drive), but its block-delta + dedup engine is a good reference/component for v2.
- **FUSE driver licensing:** WinFsp is GPLv3 with a commercial license (~$6k / 3 yr, no royalties). Prefer native **CfAPI** on Windows for v2 to avoid it. macFUSE licensing is restrictive → prefer **FUSE-T** on macOS.
- **MinIO is AGPLv3** — do **not** redistribute it. Managed build → use a cloud S3 provider. Self-host → let users bring their own S3-compatible endpoint (MinIO/SeaweedFS/etc.).
- **Near-instant on object storage is a custom feature** — S3 has no change-polling; we engineer it with `vfs/refresh` + our push channel. Code we were going to have anyway.

---

## 11. Critical implementation notes

**rclone mount flags (bake these in; don't expose as user choices):**
- `--vfs-cache-mode full` — required, or apps can't write/seek properly (macOS NFS mount is read-only without a cache mode).
- `--vfs-write-back 2s` (or similar) — how soon after close the upload starts.
- `--vfs-cache-max-size` / `--vfs-cache-max-age` — cap the local cache; put the cache dir on SSD.
- `--vfs-fast-fingerprint` — recommended for S3 (avoids slow per-object modtime calls).
- `--dir-cache-time` can be long since we refresh via `vfs/refresh` on push events.

**Other:**
- Exclude FreeCAD/LightBurn backup/temp/lock files from sync and indexing.
- Client signing/distribution is its own workstream: macOS **notarization**, Windows **code-signing**, FUSE driver bundling, auto-update.
- Indexer must handle atomic saves (write-temp-then-rename), debounce autosaves, and run a periodic reconcile scan to catch events missed while offline.

---

## 12. Suggested repo layout

```
/server     # Rails 8 app (control plane: models, jobs, API, ActionCable, STS broker)
/client     # Tauri app (rclone sidecar, mount controller, auth, UI)
/docs       # this file, ADRs, API reference
```

Monorepo is fine; the server and client deploy independently.

---

## 13. Non-goals for v1

- Chunking / delta sync infrastructure.
- Native placeholder-file OS integration (CfAPI/File Provider).
- Multi-user shared-folder collaboration and its conflict reconcile.
- Anything that puts file bytes through Rails.

---

## 14. Working agreements for the coding agent

- Follow Rails conventions; prefer boring, well-trodden solutions.
- Keep the **sync engine behind an interface** in the client.
- Keep **file bytes out of Rails** (control plane only).
- Use **content checksums** as file identity everywhere.
- Write tests for the indexing pipeline and the mount lifecycle state machine.
- Background work goes in **Solid Queue** jobs, not request cycles.
- When adding a third-party dependency, check its license against §10 (no GPL/AGPL in shipped artifacts).
- Update this file when a significant architecture decision changes.