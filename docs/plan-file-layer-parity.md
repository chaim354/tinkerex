# Plan — File/Sync Layer to Full Parity

**Date:** 2026-06-15 · **HEAD:** `bab90bb` · **Audience:** project owner + coding agent.
**Scope:** close the *remaining* gaps between Maker Server's file/sync layer and production
sync products (Dropbox / Google Drive / OneDrive / Nextcloud / Seafile / Syncthing). The data
plane is already best-in-class (CDC + block-delta + native versioning + 3-OS native mounts +
real auth + web UI MVP). This is gap-closing, **not** a rebuild.

**Companion docs (read first, don't relitigate):** `CLAUDE.md` (§6 protocol, §9 licensing,
§14 learnings), `docs/parity-roadmap.md` (the sequenced backbone this plan implements),
`docs/research-sync-competitors.md`, `docs/feature-set-and-workflows.md`, `docs/HANDOFF.md`.

**Hard constraints applied to every item (from `CLAUDE.md` / parity-roadmap gating filters):**
1. Self-hostable **and** managed — nothing cloud-vendor-locked as a *baseline*.
2. Permissive licensing only (MIT / Apache-2.0 / BSD); no GPL/AGPL in deps or shipped artifacts.
3. Device-token + single-use pairing stays the durable client credential underneath.
4. Bytes never transit Rails — presigned URLs + content-addressed chunks only.
5. No remote-mounted FS; local-first metadata. (Settled. Do not revisit.)

---

## 1. Executive summary + sequenced master list

### What's already DONE (verified against code/STATUS/HANDOFF — removed from this plan)

These roadmap items shipped and are **not** re-planned here, only their *remaining slivers* are:

- **Auth baseline** — Rails 8 built-in: signup → email-confirm → login → reset, `Session`
  model, `UserIdentity` + `User.from_omniauth` + `omniauth_callbacks_controller` **seam wired
  but inert** (no provider gem). 1 HIGH OAuth-takeover bug fixed. (Gap G3 = light it up.)
- **Selective sync ENGINE** — `client/fs-provider/src/subscriptions.rs` (include/exclude rules
  keyed by `node_id`, subtree resolution, default-include) + the hydration gate. **No app/web
  UI.** (Gap G1.)
- **Progressive/range hydration** — `hydrate_range` (fetch only chunks overlapping a read).
  (Done; G6 is only the per-filetype opt-in *policy* polish — folded into G1's UI work, minor.)
- **Bandwidth controls** — `client/sync-engine/src/throttle.rs` `ThrottledChunkIO` token bucket,
  config via `DaemonConfig`. **No UI / no schedule.** (Gap G7, small.)
- **Trash / undelete** — `Sync::Trash` service + `trash_controller` + web Trash view + restore.
  (Done. Retention window defines undelete horizon.)
- **GC / retention** — `Sync::RetentionPolicy` + nightly `RetentionJob` + S3 `delete_object`.
  (Done — but see G4: the **orphaned-chunk reaper** is a known hole it can't see.)
- **Postgres** — config-only switch validated 56/0 on Docker. (Gap G2 = *managed* hardening.)
- **Adversarial fault harness** (`fault_injection.rs`), two-device E2E, conformance — done.

### Remaining gaps to full parity (this plan)

| # | Gap | Effort | Class | Depends on |
|---|---|---|---|---|
| **G1** | Selective-sync **UI** + online-only/pinned per-folder toggles | **M** | differentiator | selective-sync engine (done) |
| **G2** | Managed-Postgres hardening (TLS, pooler, concurrent-commit load) | **S–M** | table-stakes (managed) | — |
| **G3** | OAuth/OIDC **live** (light up the OmniAuth seam) | **M** | table-stakes (managed) | auth baseline (done) |
| **G4** | Orphaned-chunk reaper (never-finalized commits leak bytes) | **S** | correctness/cost | — |
| **G5** | Change-batching / debounce for big CAD autosaves | **S** | polish/efficiency | — |
| **G6** | Per-filetype progressive-hydration policy + pin/unpin lifecycle | **S** | differentiator polish | G1 UI seam |
| **G7** | Bandwidth/throttle **UI** + optional schedule | **S** | polish | throttle engine (done) |
| **G8** | Symlink / special-file / ctime-atime handling **decision + guardrail** | **S** | correctness boundary | — |
| **G9** | Search (server-side name/path; later content) | **S–M** | table-stakes | — |
| **G10** | Delta-on-the-wire audit (confirm block-delta is truly minimal) | **S** | verification | — |
| **G11** ✅ | Large-file & many-file **scale** validation (10k+ files, >10 GB) — DONE (2 N+1s fixed) | **M** | verification | — |
| **G12** | Sharing / multi-user (shared folders, links, permissions) | **L** | PRODUCT FORK | G2, G3 |
| **G13** | LAN sync / peer block transfer (Syncthing-style) | **M–H** | differentiator | — (mind CVE) |
| **G14** | At-rest / E2EE chunk encryption (per-user AEAD) | **M–L** | differentiator (SaaS trust) | everything else first |
| **G15** | Web/mobile parity (mobile = explicitly deferred; web read-path gaps) | **M** | deferred | — |

### The single recommended sequence (rationale in §17)

1. **G4 orphaned-chunk reaper** — *S, do first.* Live cost/correctness leak on managed R2;
   small, independent, no UX. Quick win that protects the cost story.
2. **G1 selective-sync UI** + **G6 hydration policy** + **G7 bandwidth UI** — *M, the engines
   exist; this is the surfacing arc.* Highest ergonomic leverage for makers; ship together as
   the "online-only / pin / throttle" settings surface.
3. **G2 managed-Postgres hardening** — *S–M.* Required before sharing and before scaling the
   managed tier; independent, do in parallel with #2.
4. **G5 change-batching** + **G8 special-file guardrail** + **G10 delta audit** — *S each,
   polish/verification batch.* Cheap correctness/efficiency wins.
5. **G9 search** — *S–M.* Table-stakes drive feature; pairs with the web UI.
6. **G11 scale validation** — *M.* Prove 10k-file / multi-GB libraries before sharing widens
   the blast radius.
7. **G3 OAuth/OIDC live** — *M.* Required *before* sharing (can't share with an unverified user).
8. **G12 sharing / multi-user** — *L, the deliberate product fork.* Gated on validated demand;
   needs real auth (G3) + hardened PG (G2).
9. **G13 LAN sync** — *M–H.* Mid/late; the CVE-2021-28171 cross-user lesson is load-bearing.
10. **G14 encryption — LAST.** Makes every other feature opaque to debug; build once mechanics
    are proven. Get the AEAD/KDF design reviewed before a line of code.
11. **G15 mobile** — out of scope per the roadmap mandate; web read-path gaps folded into G9.

**The single most important next thing to build: G4 (orphaned-chunk reaper) immediately**
(tiny, fixes a live storage-cost leak), then **G1 selective-sync UI** as the first real arc —
it's the maker week-one pain point and the engine is already done, so it is the highest
leverage-per-effort feature remaining.

---

## 2. G1 — Selective-sync UI + online-only / pinned per-folder toggles

**Goal / user-facing behavior.** In the web UI (and Tauri app) a user right-clicks a folder
and picks **Online-only** (metadata-only placeholder, bytes on demand) or **Always keep on
this device** (pinned, proactively hydrated). A laptop holds *Active Projects* resident while
a 90 GB archive stays tree-only. Per-device — each device has its own view.

**Why now.** Research #2 = highest-leverage ergonomic gap; engine is *done*
(`subscriptions.rs`), only the surface is missing (`HANDOFF.md`: "API on the provider/engine;
no app UI yet").

**Affected components.**
- *fs-provider:* already has `subscriptions` table + include/exclude resolution. Add (if absent)
  a query to list effective rules per node for the UI; expose "is in scope" + "is hydrated" per
  node.
- *sync-engine:* the hydration gate already consults subscriptions on pull. Add a `set_rule`
  command surface + a **dehydrate-on-exclude** action (drop resident chunks for a now-excluded
  subtree via `ChunkStore::delete`, dedup-safe — only chunks not referenced by any in-scope file).
- *Tauri / web UI:* folder context menu → toggle; a per-folder status icon (cloud = online-only,
  check = resident, pin = always-keep). The web UI is server-rendered Rails; selective-sync state
  is **client-local** (never pushed), so the *web* UI can only show/set rules for the device
  it's running beside (the local daemon) — expose via a small localhost daemon endpoint or a
  Tauri command. **Confirm:** web UI selective-sync only makes sense co-located with a daemon;
  pure-browser users have no local FS, so this is a desktop-app feature primarily.
- *per-OS adapters:* on **CfAPI** map online-only → dehydrated placeholder
  (`CfDehydratePlaceholder`) and pinned → `CfHydratePlaceholder` + the pin flag (the OneDrive
  model — already partially wired per `plan-windows-cfapi-migration.md` B6). On **FUSE** the
  online-only file simply stays a cache-miss-hydrates-on-read node (current behavior). On
  **WebDAV** (macOS) there's no placeholder concept — document as "online-only = not proactively
  hydrated" (degrades gracefully, on-demand still works).

**Data-model / schema.** None server-side (deliberately — selectivity is client policy, server
tree stays complete). Client `subscriptions` table already exists.

**Protocol / API.** None server-side. New *local* command(s): `set_subscription(node_id, rule)`,
`list_subscriptions()`, `effective_rule(node_id)`.

**Hard problems / risks.**
- **Dehydrate-safety:** excluding a folder must not drop chunks shared (dedup) with an in-scope
  file. Gate every `delete` on a refcount check against in-scope manifests.
- **CfAPI pin semantics:** pin/unpin↔hydrate is B6 "code-complete, needs interactive verify"
  (HANDOFF blocker 7) — finish that here.
- **Web vs desktop:** be explicit that selective sync is a *device* policy; the web browser is
  not a device with a local FS.

**Test plan.** Extend `two_device_e2e`: device B excludes a subtree → confirms metadata still
present, bytes not proactively fetched, on-demand open still hydrates. Extend the convergence
harness to run with a random exclude/include rule set and assert tree convergence is unaffected
(rules never change the tree, only hydration). CfAPI: extend `cfapi-conformance.ps1` with a
pin/unpin/online-only cycle. Unit: dehydrate-safety (shared-chunk not dropped).

**Licensing.** None new.

**Effort: M.**

---

## 3. G2 — Managed-Postgres hardening

**Goal.** A real managed Postgres deploy (Neon/RDS/Supabase) is production-safe, not just
"config-only validated on Docker" (HANDOFF blocker 6).

**Affected components.** `config/database.yml`, `config/puma.rb`, deploy config (`config/deploy.yml`
Kamal), `Sync::Mutation`/`next_seq!` (the `FOR UPDATE` row lock).

**Data-model / schema.** None. This is operational hardening.

**Specifics to close (each a checklist item):**
- **TLS `sslmode`** — `require`/`verify-full` in the managed `DATABASE_URL`; document CA bundle.
- **Connection pooler mode** — MUST be **session or transaction** mode, **never statement**:
  `next_seq!` uses `SELECT … FOR UPDATE` which a statement-mode pooler (PgBouncer statement)
  breaks. Document + add a boot-time assertion or a smoke test that `FOR UPDATE` holds across
  the pooler.
- **Concurrent-commit load test** — N devices committing to one user concurrently; assert
  `head_seq` is gapless + monotonic and no lost changelog entries under contention (this is the
  one place PG vs SQLite semantics could diverge).
- **Solid Queue/Cache/Cable backing store** — decide whether they move off SQLite to PG (or
  Redis) for the managed tier; today they're SQLite-backed which doesn't share across managed
  app instances. **Decision needed:** PG-backed Solid* for managed multi-instance.

**Hard problems / risks.** The `next_seq!` lock under a transaction pooler is the subtle one —
prove it with a concurrent test against a real pooler, not just direct PG.

**Test plan.** New `test/integration/concurrent_commit_load_test.rb` (or extend the Rust
`concurrency_load.rs` to point at a PG-backed server): K threads, one user, assert seq integrity.
Run the existing 144 server tests against PG in CI (a `postgres` matrix leg).

**Licensing.** PG client (`pg` gem) is permissive. PgBouncer is BSD-ish (PostgreSQL license) —
clean, and it's user-installed infra, not shipped.

**Effort: S–M.**

---

## 4. G3 — OAuth/OIDC live (light up the OmniAuth seam)

**Goal.** "Sign in with Google" (managed) and "bring your own OIDC" (self-hostable IdP) as
*additive* login methods. Proves email ownership — the gap the device-pairing bootstrap can't.

**Affected components.** Rails only (sync engine never sees the IdP — gating filter #3). The
seam is **already built**: `User.from_omniauth`, `UserIdentity`, `omniauth_callbacks_controller`,
routes drawn. This gap = add the gem + a provider + config + finish the security around linking.

**Data-model / schema.** None — `user_identities(provider, uid, user_id)` exists.

**Protocol / API.** None for the sync client. Browser-only: `/auth/:provider/callback`.

**Steps.**
1. Add `gem "omniauth"` (MIT) + `omniauth_openid_connect` (MIT) + `omniauth-rails_csrf_protection`
   (CSRF for the request phase — required, OmniAuth GET-CSRF advisory).
2. Configure provider middleware in `config/initializers/omniauth.rb` from ENV (so self-host can
   point at their own IdP; managed points at Google/etc.).
3. **Security (already partially handled — verify):** the HIGH OAuth-takeover bug (linking an
   OAuth identity to an existing account via an *unverified* email) was fixed; confirm
   `User.from_omniauth` only auto-links when the IdP asserts `email_verified` AND re-verify via
   the `omniauth_email_verified?` path. Unverified OAuth email → do NOT link to an existing
   password account; create-new or force confirmation.
4. Hosted SSO (WorkOS/Auth0) = managed-only optional, same seam — do NOT make self-host depend
   on it (gating filter #1).

**Hard problems / risks.** Account-linking takeover (the known HIGH) — keep the verified-email
gate. CSRF on the OmniAuth request phase — use `omniauth-rails_csrf_protection`.

**Test plan.** `test/integration/omniauth_test.rb`: mock auth hash (verified email →
links/creates; unverified email → does NOT auto-link to an existing account; new uid → new
identity). Re-run the security review on the linking path (brakeman).

**Licensing.** omniauth + omniauth_openid_connect + omniauth-rails_csrf_protection = all MIT.
Self-hosted IdP options are Apache/MIT (Authentik MIT, Ory Hydra Apache, Keycloak Apache) — all
pass filter #2; **none mandatory** (BYO-OIDC is optional).

**Effort: M.**

---

## 5. G4 — Orphaned-chunk reaper

**Goal.** Bytes uploaded for a commit that **never finalizes** are reclaimed. Today they leak:
the orphan sweep walks DB rows, and a never-finalized chunk has **no `chunks` row**
(`docs/torn-writes-and-batching.md` §4; HANDOFF parked follow-up).

**Why first.** Pure cost/correctness, no UX, independent, **S** — a clean quick win that
protects the managed R2 cost story. The biggest "free win" remaining.

**Affected components.** `app/services/sync/gc.rb`, a new sweep step + `RetentionJob` (or a
dedicated `OrphanReaperJob`); the storage adapter's `list_objects` + `delete_object`.

**The mechanism.** Two complementary approaches (do **(a)**, consider **(b)**):
- **(a) Stale `pending_commits` sweep (DB-driven, safe):** a `pending_commit` older than a TTL
  (e.g. 24 h) that never finalized is abandoned. For each, its `manifest_json` lists the chunk
  hashes it uploaded; any hash with **no `chunks` row** (or refcount 0 and not referenced by any
  finalized manifest) and not re-used by a live commit → `delete_object`. Then delete the stale
  `pending_commit`. This catches the common case (client uploaded chunks via presigned PUT, then
  crashed/abandoned before finalize).
- **(b) Storage-vs-DB reconciliation (belt-and-suspenders):** periodically `list_objects` under
  `chunks/<user>/` and delete any object with **no `chunks` row at all** (and not referenced by
  any unfinalized-but-live pending commit, with a generous age grace so an in-flight upload isn't
  reaped). More thorough but heavier; gate behind a longer interval + an age floor.

**The critical safety invariant.** **Never delete a chunk an in-flight commit just PUT but
hasn't finalized.** Use a generous age floor (object `LastModified` older than the longest
plausible commit, e.g. 24 h) AND check live `pending_commits`. This is the one place a bug
deletes live data.

**Data-model / schema.** Optional: add `pending_commits.created_at` index for the TTL sweep
(it already has `created_at`). No new tables.

**Protocol / API.** None.

**Test plan.** New `test/services/sync/orphan_reaper_test.rb`: (1) a pending commit that
uploaded chunks then never finalized → its orphan chunks deleted, finalized chunks untouched;
(2) age-floor honored (a fresh pending commit's chunks are NOT reaped); (3) a chunk shared with
a finalized manifest is NOT deleted. Extend `fault_injection.rs` to crash a client mid-commit
(after PUT, before finalize) and assert the reaper later cleans up with zero impact on finalized
data.

**Licensing.** None new (uses the existing S3 adapter `delete_object`/`list_objects`).

**Effort: S.**

---

## 6. G5 — Change-batching / debounce for big CAD autosaves

**Goal.** A CAD app that autosaves a 200 MB assembly every 30 s, or rewrites many files in a
burst, doesn't trigger a push per keystroke-save. A short debounce (2–3 s) coalesces a rapid
edit burst into one outbox drain (`research §3`, HANDOFF parked follow-up).

**Affected components.** `client/sync-engine/src/daemon.rs` (the sync tick / outbox drain);
optionally `fs-provider` outbox enqueue.

**The mechanism.** Add a configurable **debounce window** to the daemon loop: when an outbox
entry arrives, wait `debounce_ms` (default ~2 s) for further entries before draining, resetting
the timer on each new entry (with a **max-wait cap** so a continuous-write file still flushes,
e.g. cap at 10 s). This is a pure scheduling change — the push path is unchanged. Block-delta
already minimizes *bytes* per save; debounce minimizes *commits* per burst (fewer versions,
fewer changelog entries, fewer nudges).

**Hard problems / risks.**
- **Don't debounce so long that a crash loses work** — debounce delays the *push*, not the local
  write (local SQLite + chunk cache already durable). The risk is a window where a save isn't yet
  on the server. Keep the window short + capped; make it configurable.
- **Versioning interaction:** debounce means fewer intermediate versions kept. That's *desirable*
  (200 autosaves → a handful of versions), but document it — it's a deliberate behavior change.
- **Interaction with conflict detection:** the coalesced commit still carries the latest
  `base_version_id`; no change to conflict semantics.

**Test plan.** Unit test the debounce scheduler (N rapid enqueues within the window → 1 drain;
enqueues spanning > max-wait → flush at the cap). Extend `concurrency_load.rs` with a
rapid-autosave pattern and assert the number of committed versions is bounded while final content
is correct. `fault_injection`: crash during the debounce window → the local write is durable and
pushes on restart.

**Licensing.** None.

**Effort: S.**

---

## 7. G6 — Per-filetype progressive-hydration policy + pin/unpin lifecycle

**Goal.** `hydrate_range` exists (range-fetch chunks overlapping a read). This gap adds the
**policy**: which file types open *whole* (mmap'd apps backfire on range) vs which open
*header-only* (slicer/CAD metadata peek). Plus finish CfAPI pin/unpin↔hydrate lifecycle (B6).

**Affected components.** `sync-engine` hydrate hook (a small policy table by extension);
`fs-cfapi` pin/unpin (B6 polish, HANDOFF blocker 7); the G1 UI (a "stream large files" toggle).

**Data-model / schema.** None — a static/config policy map (e.g. `.3mf`/`.step` → range-ok;
`.exe`/anything mmap'd → whole-file).

**Hard problems / risks.** A wrong policy (range-hydrating an app that mmaps) causes repeated
faults; default to whole-file and opt-in range per known-safe type.

**Test plan.** Extend `multifiletype_conformance.rs`: a large file of a range-ok type opened
with a header read fetches only the covering chunks (assert chunk-fetch count). CfAPI: pin a
file → resident offline; unpin → dehydrated.

**Licensing.** None.

**Effort: S.** (Mostly folds into G1.)

---

## 8. G7 — Bandwidth / throttle UI + optional schedule

**Goal.** Surface the existing `ThrottledChunkIO` caps in the UI ("limit upload to 2 MB/s"),
and optionally a schedule ("throttle 9–5, full speed overnight").

**Affected components.** `DaemonConfig` (caps already plumbed) → a settings panel (Tauri/web
co-located with the daemon) → live-reload the `RateLimiter` rate. Schedule = a small time-of-day
check that swaps the active cap.

**Data-model / schema.** None server-side (client-local config).

**Hard problems / risks.** Live-updating the shared `Arc<RateLimiter>` rate without restarting
the daemon — add a `set_rate()` on the limiter (it's a `Mutex<Bucket>` already).

**Test plan.** Unit: `set_rate` changes effective throughput mid-stream. The token-bucket already
has tests; add a schedule-swap unit test.

**Licensing.** None.

**Effort: S.**

---

## 9. G8 — Symlink / special-file / ctime-atime handling decision + guardrail

**Goal.** Today uid/gid/symlinks/hardlinks/special files/ctime/atime are **deliberately not
synced** (`feature-set-and-workflows.md` caveats — "meaningless for a personal maker drive").
The *gap* isn't to sync them — it's to **handle them safely and predictably** instead of
silently dropping or corrupting. A symlink in a synced folder today is undefined behavior.

**Decision (recommended):** keep them out of scope, but make the boundary **explicit and safe**:
- **Symlinks:** on ingest, detect a symlink and either (a) skip it with a logged warning + a UI
  "unsupported file" marker, or (b) store it as a tiny special node (kind=`symlink`, target in a
  1-chunk manifest) that round-trips but isn't followed. Recommend **(b)** — cheap, lossless,
  and CAD project trees occasionally contain relative symlinks. Mode bit already round-trips.
- **Special files (FIFO/device/socket):** skip + warn (never meaningful in a maker library).
- **Hardlinks:** treat as independent files (content-addressing dedups the bytes anyway).
- **ctime/atime:** stay unsynced (mtime is preserved, which is what build tools need). Document.

**Affected components.** `fs-provider` ingest (detect file kind), the `nodes.kind` enum, each
mount's enumerate (render a symlink node).

**Data-model / schema.** `nodes.kind` may gain `symlink` (client + server). Small migration.

**Hard problems / risks.** Cross-OS symlink semantics (Windows symlinks need privilege) — on a
platform that can't materialize a symlink, render it as a placeholder/text file with a warning.

**Test plan.** `posix_semantics.rs`: a symlink ingests + round-trips as a `symlink` node (or is
cleanly skipped+warned, per the chosen option); a FIFO is skipped+warned, never corrupts the
tree. Convergence harness: a tree containing a symlink converges identically.

**Licensing.** None.

**Effort: S.**

---

## 10. G9 — Search

**Goal.** Find a file by name/path across the whole library (the archive that's online-only on
this device still appears in results — metadata is local). Later: content search (indexed
text/CAD metadata, a maker-app concern).

**Affected components.** Server: a `GET /v1/search?q=` over `nodes` (name LIKE / FTS) scoped to
`current_user`. Web UI: a search box. Client: local SQLite already has the full tree → a local
`search(query)` on `fs-provider` gives **instant offline** name search (no WAN — local-first
filter #1). Do **both**: local for the desktop app (instant), server endpoint for the web UI.

**Data-model / schema.** Optional FTS index on `nodes.name` (SQLite FTS5 / PG `pg_trgm` or
`tsvector`). Start with `name ILIKE`/`LIKE` (adapter-agnostic, no extension) — add FTS only if
slow at scale (ties into G11).

**Hard problems / risks.** Adapter-agnostic search (SQLite vs PG FTS differ) — start with a
portable `LIKE`/`ILIKE` + index; only reach for FTS5/`tsvector` behind an adapter shim if needed.
Content search = a separate (maker-app) indexing job; out of scope for the file layer beyond name.

**Test plan.** Server: `nodes` search scoping (a user only finds their own nodes — extend
`tenant_isolation_test.rb`). Client: `fs-provider` name-search unit test incl. an online-only
node (metadata present → found without hydration).

**Licensing.** None (built-in DB features).

**Effort: S–M.**

---

## 11. G10 — Delta-on-the-wire audit

**Goal.** *Verify* (not build) that an edit to a large file uploads only the truly-changed
chunks — i.e. FastCDC boundaries are stable across an in-place edit so a 1-byte change in a 1 GB
file uploads ~1 chunk, not the whole tail. The chunking tests assert boundary stability; this
gap closes the loop with an **end-to-end byte-accounting** assertion against the live transfer
path (we already *beat* Nextcloud here — prove it with a number).

**Affected components.** A test/example only; no production change expected. If the audit finds a
re-chunk regression, fix in `fs-provider` chunking.

**Test plan.** New `examples/delta_accounting.rs` (or extend `two_device_e2e`): write a large
file, edit one region, push, and assert the count/bytes of *newly uploaded* chunks ≈ the edited
region size + at most a couple of boundary chunks — not the file size. Run across edit positions
(head/middle/tail/insert/delete) since an *insert* shifts boundaries (CDC handles this; a
fixed-block system wouldn't — that's the whole point vs Syncthing).

**Licensing.** None.

**Effort: S.**

---

## 12. G11 — Large-file & many-file scale validation

**Goal.** Prove the engine holds at production scale before sharing widens the surface: a library
with **10k–100k files** and **multi-GB / >2 GB single files**. `concurrency_load.rs` does up to
50 devices; this is about *tree size* and *file size*, not device count.

**Affected components.** Verification-first; likely findings: `Sync::Changes` N+1 (noted in
`CLAUDE.md` §12 step 6 as still-open), changelog pagination at depth, local SQLite index coverage
for huge trees, memory during a full-resync of a huge tree, FastCDC throughput on a >2 GB file
(and any u32/u64 offset assumptions).

**Hard problems / risks.**
- **N+1 in `Sync::Changes`** — preload manifests; a 100k-entry resync must not issue 100k queries.
- **Full-resync of a huge tree** — must stream/page, not load the whole tree into memory.
- **>2 GB file offsets** — confirm `offset`/`length` are `i64`/`u64` end-to-end (schema uses
  `bigint` — good; verify the Rust path).

**Test plan.** New `tests/scale.rs` (feature-gated, slow): build a 10k-node tree, time a
full-resync + a delta pull; build a 3 GB single file, push + hydrate + verify byte-for-byte;
assert query counts on resync are O(pages), not O(nodes). Add a CI "scale" leg (nightly).

**Licensing.** None.

**Effort: M.**

### G11 — DONE (2026-06-16). What was found + fixed.

**Two N+1s confirmed + fixed (the headline).** Both bulk read serializers issued
per-row `find_by`s inside the page loop:

| Serializer | Before (per page) | After | Fix |
|---|---|---|---|
| `Sync::Tree` (snapshot) | **~1.75 queries/node** (351 for 200 nodes) | **3 queries** flat | batch-load versions + manifests |
| `Sync::Changes` (delta) | **~2.6 queries/entry** (527 for 200 entries) | **5 queries** flat | batch-load nodes + versions + manifests |

At 1000 nodes/entries the fixed paths are **3 and 5 queries** respectively (33 ms / 31 ms
on SQLite) — O(pages), not O(nodes). The fix is *batch loading* (not `includes`): the tree
has **no AR associations on the string keys** (`node_id`/`version_id`/`manifest_id` are
matched via `find_by`), so each serializer now `pluck`s the key set for the page and does
one `WHERE … IN (…)` per related table, grouping manifests in memory via the shared
`Sync.load_manifests` helper (`app/services/sync.rb`). Portable — no PG-only SQL, correct
on SQLite + Postgres. Regression backstop: `test/services/sync/scale_test.rb` asserts the
query count stays a small constant and does **not** grow with page size (it fails loudly on
the pre-fix code — 351/527 queries).

**End-to-end at the 10k target.** `client/sync-engine/tests/scale.rs` (server-backed,
skips offline; CI-fast at the default 400 files, scales via `SCALE_FILES`) builds a deep
tree on device A, pushes it, then full-resyncs device B (paginated `/v1/tree` →
`apply_remote` of the whole snapshot), does a bounded delta pull, and hydrates a file
byte-for-byte. Measured at **`SCALE_FILES=10000`** (memory backend, SharedDirIO data
plane): local build 2.3 s; **full-resync of 10,100 nodes 6.4 s**; **a 1-file delta pull
atop 10k = 7.8 ms** (the proof the delta path does NOT walk the tree); hydrate verified.

**>2 GB offsets — confirmed safe.** `ChunkLoc.offset`/`length` are `u64` in `fs-provider`
and stored as `i64` in SQLite (i64 max ≈ 9.2 EB); the server columns are `bigint`. No
u32 truncation on the offset path. (A literal multi-GB-single-file byte run was **not**
executed here — it's I/O-bound, not a correctness/query question; flagged below.)

**Out of scope / flagged (not query-count problems):**
- **Push of a 10k-file tree is ~113 s** — the outbox drains as a *sequential* per-file
  two-phase `commit` (begin→upload→finalize), one HTTP round-trip set per file. This is
  inherently O(files) *work* (not an N+1), dominated by request latency. A batched/
  pipelined commit endpoint (or concurrent outbox drain) is the lever; tracked separately,
  not a correctness gate.
- **Real managed-Postgres numbers** — the query *counts* are adapter-agnostic and proven,
  but absolute latency over a network DB + a session/transaction-mode pooler (G2) should be
  measured on a real managed deploy. The `IN (…)` lists are bounded by the page `limit`
  (≤5000 tree / ≤2000 changes), well within Postgres parameter limits.
- **A literal >2 GB / 3 GB single-file** push+hydrate (FastCDC throughput) — the offset
  *types* are verified; an actual multi-GB byte run is an I/O benchmark left for a manual/
  nightly leg.

---

## 13. G12 — Sharing / multi-user (the product fork)

**Goal / behavior.** Share a folder with a **different user** (co-designer, fabricator):
read/write or read-only; optionally a public/expiring **link**. The jump from "private
multi-device sync" to "collaboration platform" — research #7, the biggest gap, a **product
decision**, gated on validated demand.

**Affected components (broad — this is the one true re-architecture).**
- *Server models:* a **`Space`** (shared library) or a `Share(node_id, grantee_user, role)` —
  the 37signals `active_record_tenanted` slot-in (`CLAUDE.md` §8) is the migration path.
  **Changelog scoping** must change: today the changelog is per-**user**; a shared space needs
  its **own feed** that all members pull. This is the deep change.
- *Authz:* per-node/per-space roles (owner/editor/viewer); every `nodes`/`commit`/`chunks`
  endpoint re-scoped from `current_user.nodes` to "nodes the user can access via ownership OR a
  share."
- *Cross-user dedup rework:* chunks are per-user-keyed `chunks/<user>/<hash>` (deliberately —
  isolation, §8). Sharing means a chunk visible to two users → either **per-space** chunk
  namespaces (`chunks/<space>/<hash>`, clean but re-keys storage) or a careful cross-user grant
  (reopens the surface §8 closed — **avoid**). Recommend **per-space keyspace**: a shared folder
  lives in a space; its chunks key by space; the presigned-URL minter grants on space membership.
- *Client:* the daemon subscribes to **multiple feeds** (own + each space); the local tree gains
  a "shared with me" root. `bind_library` extends to multiple libraries.
- *Web UI:* share dialog, member list, role picker, link generation.

**Data-model / schema.** New `spaces`, `space_memberships(space, user, role)`, `shares` (or
links table `share_links(token_digest, node_id, role, expires_at)`); `nodes`/`versions`/`chunks`/
`changelog_entries` gain a `space_id` (or stay user-scoped with a join through memberships —
decide). This is the largest schema change in the plan.

**Protocol / API.** New: `POST /v1/spaces`, `POST /v1/spaces/:id/members`, `POST
/v1/nodes/:id/share`, `GET /v1/shares`, link redemption; changelog pull gains a `space_id` /
multi-feed dimension.

**Hard problems / risks.**
- **Changelog scoping** is the crux — a clean per-space feed vs. a unified feed with ACL filter.
  Per-space feed is cleaner and scales; pick it deliberately.
- **Cross-user dedup** reopens the isolation surface §8 closed — per-space keyspace contains it.
- **Conflict detection across users** — the `base_version_id` model already handles concurrent
  edits; extend conflict ownership to "who in the space."
- **Encryption interaction (G14):** E2EE + sharing = sharing keys (per-space key wrapped per
  member) — a hard sub-problem; another reason G14 comes after G12 is decided.
- **It's a business-model decision** — defer to validated demand (research #7).

**Test plan.** New `test/services/sync/sharing_test.rb` + `tests/sharing_e2e.rs`: user A shares a
folder with user B; B pulls the space feed, edits, A converges; a viewer-role user cannot commit;
cross-space isolation (B can't see A's *unshared* nodes — extend `tenant_isolation_test.rb`
heavily); presigned-URL grant is space-scoped (B can't fetch A's private chunks). Run
`fault_injection` with two users in a shared space.

**Licensing.** `active_record_tenanted` (37signals, MIT) is the pattern reference. None blocking.

**Effort: L.** The deliberate fork — commit to it on demand, not speculatively.

---

## 14. G13 — LAN sync / peer block transfer

**Goal.** Two devices on the same LAN (workstation + laptop) exchange chunks **directly**, not
round-tripping through the cloud — faster, no egress. Server stays the metadata source of truth;
LAN is an alternate *transport* for the same content-addressed bytes.

**Affected components.** A new `client/lan-sync` crate (or a module in `sync-engine`): mDNS/UDP
peer discovery + a small chunk-fetch protocol; the hydrator tries a LAN peer before the presigned
GET (`EngineHydrator` gains a peer-first path), falling back to the cloud.

**Data-model / schema.** None server-side. A local peer registry.

**The mechanism.** mDNS advertises `(library_id, device_id)`; a peer requests a chunk by hash; the
holder returns bytes; the requester **verifies `sha256(bytes) == hash`** (the content address *is*
the integrity check — a peer can't lie about a chunk's content).

**Hard problems / risks — the load-bearing security lesson.**
- **NEVER serve a chunk cross-user / cross-library** (Dropbox **CVE-2021-28171**). A LAN peer must
  prove same-library membership *before* any byte moves: derive a **shared per-library secret**
  from the device tokens (or a pairing-derived key) and require a challenge/response; only then
  honor a chunk request, and only for hashes the requester's manifests entitle. This is the one
  place a naive implementation leaks data — design it first.
- **Encryption interaction (G14):** peers exchange ciphertext (fine), but key possession still
  gates *use* — LAN transfers opaque blobs; decryption is local.
- **NAT/discovery edge cases** — mDNS only works on the same L2 segment; fall back to cloud always.

**Test plan.** New `tests/lan_sync.rs`: two in-process peers, one holds a chunk, the other fetches
it over the LAN transport and verifies the hash; a **cross-library peer is refused** (the security
test — must fail closed); a tampered chunk is rejected (hash mismatch). Integration: a hydrate
prefers a LAN peer, falls back to cloud when the peer is gone.

**Licensing.** mDNS via `mdns-sd` (MIT) or similar permissive crate — check at add time.

**Effort: M–H.**

---

## 15. G14 — At-rest / E2EE chunk encryption (LAST)

**Goal.** The client encrypts each chunk with an AEAD **before** the presigned PUT, so object
storage (R2/SeaweedFS) only ever holds ciphertext — the SaaS trust story for makers shipping
commercial/IP-sensitive CAD. Research #3; sequenced **last** on purpose.

**Design (from parity-roadmap §B — the canonical spec; summarized).**
- **Cipher:** AES-256-GCM or XChaCha20-Poly1305 (permissive crates: `aes-gcm`/`chacha20poly1305`/
  `ring`). Each chunk sealed independently (`nonce ‖ ciphertext ‖ tag`) so range/on-demand
  hydration survives.
- **Content-addressing (the crux):** naive encryption (random nonce) breaks
  `sha256(plaintext)` addressing and kills dedup. Use **convergent / keyed-HMAC addressing**:
  address by `HMAC-SHA256(user_chunk_key, plaintext)` and derive a deterministic per-chunk
  nonce/key from that MAC → identical plaintext under the same user key → identical ciphertext →
  **per-user dedup survives** (cross-user dedup is already gone). Tahoe-LAFS / Seafile-encrypted-
  library pattern.
- **Key management:** self-host = passphrase → Argon2id master key, client-held, HKDF per-chunk
  keys; **key loss = data loss** (loud recovery-code export at setup). Managed = same client-side
  derivation by default (true E2E); optional server-escrow recovery as a product toggle.
- **Pairing (filter #3):** a new device must also obtain the user key — fold a **wrapped key into
  the existing single-use pairing payload** (avoid a second secret channel).

**Affected components (the blast radius — why it's last).** Manifest hashes (`manifest_id` →
keyed-HMAC), the local chunk cache (keyed by new address, stores ciphertext, decrypt-on-serve),
every mount's hydrate hook, the `commit → {missing, put_urls}` dedup negotiation (now over
ciphertext addresses), and **debuggability** (you can no longer `sha256` a stored object to verify
it — every integrity check needs the key). This is exactly why every *other* feature ships first.

**What it does NOT break:** cross-user dedup (already gone), bytes-out-of-Rails (Rails mints URLs
for opaque keys, never read bytes), versioning (manifests still share chunks, keyed differently).

**Test plan.** Crypto KATs + tamper-fails-open; determinism (same plaintext+key → same address;
different users → different addresses); **re-run `two_device_e2e` + `fault_injection` +
conformance with encryption ON** (convergence + no-loss + byte-for-byte plaintext to the user must
still hold over ciphertext); explicit key-loss test (clean unrecoverable error, no partial
corruption, no plaintext leak).

**Licensing.** AEAD/KDF crates all Apache/MIT — clean (filter #2).

**Effort: M–L.** **Get the AEAD + KDF design reviewed before writing a line** (key loss = data
loss). Last functional item; ongoing hardening continues alongside.

---

## 16. G15 — Web / mobile parity

**Mobile = explicitly out of scope** per the parity-roadmap mandate (deprioritized). Not planned.

**Web read-path parity** is mostly done (browser file browser: upload/download/inline-view/
soft-delete/trash, bytes off Rails). Remaining web slivers fold into other gaps: **search**
(G9), **selective-sync caveat** (G1 — the browser is not a device with a local FS; document
that online-only is a desktop feature), **share dialog** (G12). No standalone work item.

**Effort: (folded into G1/G9/G12).**

---

## 17. Sequencing rationale (the master plan, expanded)

The order maximizes leverage-per-effort while respecting dependencies and the deliberate
"encryption last" rule.

1. **G4 reaper first** — it's a *live cost leak* (not a feature), tiny (S), zero UX, fully
   independent. Highest-value-per-hour remaining; ship immediately.
2. **G1 + G6 + G7 (the "device settings" arc)** — the selective-sync/hydration/throttle *engines
   all exist*; this surfaces them. Highest *ergonomic* leverage (maker week-one pain: a laptop
   surviving a 100 GB library). One coherent UI arc.
3. **G2 managed-Postgres** — independent, prerequisite for the managed tier scaling and for
   sharing; do in parallel with #2.
4. **G5 + G8 + G10 (polish/verification batch)** — three S items: debounce (efficiency),
   special-file guardrail (correctness boundary), delta audit (prove the data-plane claim).
5. **G9 search** — table-stakes drive feature; pairs with the web UI.
6. **G11 scale validation** — prove 10k-file/multi-GB before sharing widens the blast radius;
   likely surfaces the known `Sync::Changes` N+1.
7. **G3 OAuth/OIDC live** — required *before* sharing (can't share with an unverified user).
8. **G12 sharing** — the deliberate product fork (L); gated on validated demand; needs real auth
   (G3) + hardened PG (G2).
9. **G13 LAN sync** — mid/late; design the CVE-2021-28171 cross-user guard first.
10. **G14 encryption — LAST** — turns everything opaque; build once the mechanics are proven
    against plaintext, content-addressed bytes you can `sha256` and eyeball.

**Don't-chase (deliberately, per roadmap §D):** three-tree reconcile/planner (the fault harness
already found+fixed the real bugs — don't rebuild speculatively); generic real-time co-editing
(we're a maker vault, not Google Docs); full POSIX-perms parity (uid/gid — meaningless for a
personal drive; mode/`+x` is enough); mobile.

**The product-altitude reminder (from the roadmap):** the differentiators here (selective sync
for huge libraries, progressive hydration of giant CAD, LAN sync on the shop bench, E2EE for
commercial IP) are worth **more** than the last 10% of generic-drive parity. The real moat is the
**maker app layer** (preview/inventory/projects/BOM, `CLAUDE.md` §12 step 9) — this sync work
exists to support it, not to out-Dropbox Dropbox.
