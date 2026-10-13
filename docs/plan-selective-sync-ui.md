# Plan — selective-sync UI in the Tauri app

> **HISTORICAL — not re-verified.** Written before the repository split of 2026-08-20, when the
> sync engine and the Rust client still lived here (they are `chaim354/tinkerex-sync` and
> `chaim354/tinkerex-client` now). Kept for its reasoning and its measurements; it does not
> describe what this repository contains today. The current map is `docs/README.md`.


**Status:** plan only (the engine + provider APIs exist; the app wiring is the gap).
**Context:** while building the maker product surfaces (§12 step 9), the Settings surface
needed selective-sync (per-folder include/exclude) controls. The sync engine and provider
*already implement* selective sync, but the **mount types don't expose the running
provider at runtime**, so a live in-app control can't be wired without a small core change.
This doc is that change's plan.

## What already exists (don't rebuild)

The full selective-sync mechanism is built and tested at the engine/provider layer:

- `fs_provider::SqliteProvider`:
  - `subscribe(node_id) -> u64` / `unsubscribe(node_id) -> u64` — set an explicit
    include/exclude rule on a subtree (`subscriptions` table; `SubRule`).
  - `clear_subscription(node_id)` — drop the rule, fall back to ancestry/default.
  - `subscription_rules() -> Vec<(node_id, SubRule)>` — every explicit rule (for the UI
    to render current state).
  - `is_subscribed(node_id)` — the proactive-hydration gate (walks ancestry).
  - `dehydrate_subtree(node_id) -> usize` — reclaim bytes for an excluded subtree.
- `sync_engine::SyncEngine`:
  - `subscribe(provider, client, io, node_id)` — set the rule **and** immediately hydrate
    the now-in-scope files.
  - `unsubscribe(provider, node_id) -> usize` — set the rule and reclaim bytes.
  - `proactive_hydrate(...)` — the post-pull eager-hydration of in-scope files.

Semantics (from `fs-provider/src/subscriptions.rs` + `CLAUDE.md` §2): the **full tree
metadata always syncs** (navigation/convergence unaffected); selective sync only changes
whether a subtree's **bytes** are kept resident. An out-of-scope file still opens on demand
(the OneDrive online-only model) — graceful degradation, never an error.

## The gap

The Tauri app holds the running mount in `AppState(Mutex<Option<Mount>>)` where `Mount` is
the per-OS alias (`Daemon` / `WebdavMount` / `CfApiMount`). Each of those owns a private
`Arc<SqliteProvider>` (+ the `ServerClient` and `ChunkIO` it built at `start`). **None of
that is reachable from a command.** So `maker_*`-style command like `set_folder_synced`
can't call `SyncEngine::subscribe` — it has no handle to the provider/client/io.

## Proposed change (small, additive)

Add a runtime accessor + two thin operations to each mount type, behind one trait so the
`Mount` alias keeps a uniform API (mirrors the existing `start`/`stop`/`is_running`/
`mountpoint` shape):

```rust
// sync-engine
pub trait SelectiveSync {
    /// Current explicit rules (node_id, included?) for the running mount.
    fn subscription_rules(&self) -> crate::Result<Vec<(String, bool)>>;
    /// Include a subtree: set the rule + hydrate now.
    fn subscribe(&self, node_id: &str) -> crate::Result<()>;
    /// Exclude a subtree: set the rule + reclaim bytes. Returns chunks reclaimed.
    fn unsubscribe(&self, node_id: &str) -> crate::Result<usize>;
    /// Drop an explicit rule (fall back to ancestry/default).
    fn clear(&self, node_id: &str) -> crate::Result<()>;
}
```

Each mount already keeps the three collaborators it needs:

- `Daemon` / `WebdavMount` / `CfApiMount` clone `Arc<SqliteProvider>` into their loops;
  keep one clone on the struct.
- They built a `ServerClient` and the `ChunkIO` (presigned/local) at `start`; keep a
  handle (the `ServerClient` is cheap to clone; the `ChunkIO` is already an `Arc`/boxed).

`subscribe`/`unsubscribe`/`clear` just forward to `SyncEngine::{subscribe,unsubscribe}` /
`provider.clear_subscription`. `subscription_rules` maps `SqliteProvider::subscription_rules`
to `(node_id, included_bool)`.

**Locking:** these run on the command thread while the sync loop also touches the provider.
The provider is already `Arc` + internally `Mutex`-guarded (the daemon shares it across three
threads), so this is safe — same as the existing loop. Hydration during `subscribe` does
WAN I/O; run it without holding the app `AppState` mutex (clone the `Arc`s out first, drop
the guard, then call), exactly like `mount_with_token` avoids holding the lock across I/O.

## Tauri commands (after the core change)

```rust
#[tauri::command] fn selective_rules(state) -> Result<Vec<FolderRule>, String>
#[tauri::command] fn set_folder_synced(state, node_id, synced: bool) -> Result<(), String>
#[tauri::command] fn clear_folder_rule(state, node_id) -> Result<(), String>
```

`FolderRule { node_id, name, synced }` — joined against `browse` (already exists) so the UI
can show folder names. All resolve `state.0.lock()` → `as_ref()` → the `SelectiveSync`
methods; error if not mounted ("sign in first").

## UI (settings.js — the card is already stubbed)

The Settings view already has a "Selective sync" card (currently a planned-note). Replace
it with:

1. On `view:show == "settings"` (and mounted), call `browse` + `selective_rules`, render
   the **top-level folders** (parent_node_id == root, kind == dir) each with a checkbox:
   checked = synced (in scope). Default (no explicit rule) = synced, matching the
   "mirror everything" default.
2. Toggling a checkbox → `set_folder_synced(node_id, checked)`; show a spinner while it
   hydrates/reclaims, then a toast ("Downloaded N files" / "Reclaimed N MB").
3. A small "reset" affordance per folder → `clear_folder_rule`.

Show a disabled state with "Sign in to manage selective sync" when not mounted (the rules
live in the running mount's local tree).

## TDD

- **sync-engine:** a test that builds a `Daemon`/`WebdavMount` against a temp provider,
  calls `subscribe`/`unsubscribe` through the new trait, and asserts `subscription_rules`
  reflects it + `dehydrate_subtree` reclaimed (reuse the existing selective-sync provider
  tests as the backstop; the new test only covers the *accessor* plumbing).
- **maker-app:** the command layer is thin; unit-test any pure mapping
  (`SubRule → bool`, rule+browse join into `FolderRule`).
- **Live:** extend `examples/` with a subscribe→read-out-of-scope→on-demand-hydrate check
  against the running server (the engine already has the mechanism; this proves the app
  path end-to-end).

## Why deferred now

Adding a public provider accessor to all three mount types is a cross-crate API change to
the file layer (the overnight rule: deeper core changes → plan, don't hack). It's small and
well-scoped (the hard part — the selective-sync mechanism — is done), so it's a clean
next-pass task rather than something to fake in the UI tonight.
