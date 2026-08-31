# CLAUDE.md

Project context and architecture for an AI coding agent (Claude Code) and human
developers. Working name: **Maker Server** (rename freely).

> **How this file is scoped.** It holds what is *permanently* true about **this repo — the maker
> app**: architecture, the data model, and the **invariants a future editor must not undo** (§14).
> It does **not** narrate finished work — every arc (dates, branches, suite counts, per-phase
> detail) lives in **the record (§11)**, which is canonical. Keep it that way: this
> file is loaded into an agent's context on *every* session, so length here is a tax on every
> future task, and a rule buried in 600 lines of history is a rule nobody reads.
>
> **It also holds only what MOST tasks need.** An invariant that binds one area — addons, the
> Measure view, deploy secrets, backup — lives in **`docs/invariants/<area>.md`** with a stub under
> its §14 anchor naming the paths that trigger it. That is not a demotion and those files are not
> optional: **read the pointed-at file before touching the paths its stub names.** Rules move there
> to be *found when they apply* instead of skimmed on every unrelated session.
> `test/docs_hygiene_test.rb` fails if a stub loses its file or this file outgrows its ceiling.
>
> **It also does not describe the sibling repos.** The sync engine and the Rust client have their
> own repositories and their own CLAUDE.md (§3). Rules about how the changelog is built, how
> commits are sequenced, how chunks are refcounted, or how a mount adapter works belong **there** —
> what belongs here is only what a *maker-app* task needs. When you find yourself needing the
> other half, you are probably in the wrong repo; check §3 before adding it back.
>
> **Do not renumber the sections.** Code comments cite them by number — **323 `§` references across
> `app/` and `lib/`** on 2026-08-25 (`grep -rhoE "§[0-9]+[a-j]?" app/ lib/ | sort | uniq -c | sort -rn`),
> led by `§14a` 53, `§15` 36, `§14c` 27, `§10` 25, `§6` 20. The same applies to §12's item numbers,
> cited as `§12.7`, `§12.12`, "§12 item 11" — which is why a CLOSED item keeps its slot.
> **A section that MOVES keeps its anchor here:** §14c/g/h/i are now stubs pointing into
> `docs/invariants/`, so every existing citation still resolves.
> *(Until 2026-08-25 this read "`§15` ~141, `§9` ~175, `§10` ~107, `§5` ~95" — four figures summing
> to 518 in a tree containing 323 in total. The rule was right; its evidence was invented. §15's
> "verify a commit reference the way you verify a guard" binds on counts too.)*

---

## 1. What we're building

A self-hostable server + client for managing a maker's working life:

- **Files** — 3D files (STL, 3MF, OBJ), CAD (STEP/IGES, native Fusion/FreeCAD/
  SolidWorks), LightBurn (`.lbrn2`), with versioning and in-browser preview.
- **Inventory** — materials/components on hand, quantities, locations, suppliers.
- **Projects** — hardware + firmware + software, with tasks, a build log, attached
  files, and a BOM that links to inventory.

Two deployment modes:
1. **Self-hosted** — runs on the user's own box (e.g. Unraid).
2. **Managed (SaaS)** — we host it; we monetize hosting.

Commercial product. **Licensing: prefer permissive (MIT/Apache/BSD) for full
commercial rights** — avoid copyleft (GPL/AGPL) in anything we depend on or ship
(see §9). Everything built so far is permissive.

---

## 2. Core architecture — the maker app and its library

**This repo is a Rails 8 web app.** It owns projects, inventory, the model library, previews, the
`/tools` addon gallery, and the `v1/maker/*` API. It does **not** own file sync.

Where the bytes live is chosen per deployment by **`LIBRARY_BACKEND`**, behind one port
(`app/services/file_layer/` — §14a):

| value | bytes live in | catalog comes from |
|---|---|---|
| `share` | a mounted directory (NAS over SMB/NFS) | polling the store (`Library::Scanner`) |
| `s3` | the user's own S3-compatible bucket | polling the store (`Library::S3Observer`) |
| `chunk_remote` | a **standalone sync server** reached over HTTP | a locally-mirrored `nodes` table |

**`chunk` — the embedded engine — is REFUSED, not aliased** (retired 2026-08-25; §12.12).

**The one architectural idea worth carrying in your head** is why `chunk_remote` mirrors instead
of asking: a remote-mounted filesystem does not work over the WAN (synchronous metadata
round-trips, ~1 s/file — measured, `docs/roads-not-taken.md`). So metadata reads answer from a
**local** table and the WAN is never in the metadata path. **That is a rule, not a description:**
§14a forbids closing the resulting staleness with a synchronous pull in a read path. The mirror
is refreshed by this app's own writes and by one recurring job, and bounded staleness (~2 min) is
the accepted trade — the same trade `Library::ScanJob`'s poll already makes for share/s3.

The sync engine's own design — chunking, versions, the changelog, conflict records — is
**`chaim354/tinkerex-sync`'s** concern. The wire between us is specified in
`docs/sync-protocol.md`; the client half this app implements is §6.

---

## 3. Components

**In this repo:**

| Component | Path | Role |
|---|---|---|
| **server** | repo root (Rails 8) | The maker host: `Maker::*` models and web layer, the `v1/maker/*` API, `User`/`Node`/`Device`, and the `FileLayer` factory. |
| **FileLayer port** | `app/services/file_layer/` | The seam between the maker layer and whatever holds the bytes, chosen by `LIBRARY_BACKEND`. All three adapters boot, index, write, deliver. Invariants: **§14a**. |
| **Library scan** | `app/services/library/` | Share/S3 indexing: `Scanner` + `S3Observer` **observe**, one shared `Reconciler` **decides**. Invariants: **§14b**. |
| **Addons (Tools)** | `app/services/maker/addons/`, `app/controllers/tools/`, `sidecar/` | The `/tools` gallery + per-addon UI; output lands via one path (`Maker::Addons::LibraryOutput`). Two GPL sidecars, HTTP-only. Invariants: **§14c**. |
| **Project intake** | `app/services/maker/project_intake.rb` | A project's library folder files itself. Invariants: **§14f**. |
| **stl-thumbnailer** | `tools/stl-thumbnailer` | Pure-CPU (no GPU/OpenGL/Mesa) STL→PNG renderer, Rust (`euc`, Apache-2.0). Compiled into the Rails image at build time and exec'd off `PATH` by `Maker::Previews::Stl` — a **server-side** tool despite being Rust, which is why it lives here and not with the client crates. |

**Sibling repos — each has its own CLAUDE.md; do not re-document them here:**

| repo | role | how it reaches us |
|---|---|---|
| `chaim354/tinkerex-sync` | The chunk/version/changelog engine + its own host app. **Not a dependency of this repo** — no gem, `Sync::` is undefined in this process. | Runs as the **`sync` Kamal accessory**; this app talks to it over HTTP as a client (§6). Devices sync against it directly, never against this app. |
| `chaim354/tinkerex-client` | Rust crates (`fs-provider`, the per-OS mounts, `sync-client`, `sync-engine`) + the Tauri desktop app. Extracted 2026-08-20. | Syncs against the sync server. Clone as a sibling (`../tinkerex-client`) for the CI legs in §13 that need it. |

---

## 4. Tech stack (decided)

| Layer | Choice |
|---|---|
| Backend | **Rails 8** (Solid Queue/Cache wired and used; Solid Cable is configured but this app has NO cable endpoint — §14e) |
| Server DB | **Postgres** (managed) / **SQLite** (self-host) — same adapter-agnostic models |
| Object storage | **S3-compatible** — R2 (managed), SeaweedFS/MinIO/their S3 (self-host) |
| Library backend | **`share` / `s3` / `chunk_remote`** — see §2 |
| Preview | Server-side thumbnails (vipsthumbnail/pdfium/resvg subprocesses) + Three.js in the browser |
| Addon bundles | Served by the **`addons` Kamal accessory** (`chaim354/tinkerex-addons`) — publishing the bundle image IS the addon deploy; Rails is never rebuilt (§14c) |

Chunking, the desktop client and the mount adapters are `tinkerex-client`'s stack, not this
app's.

---

## 5. Data model

**This app's own tables** (Postgres managed / SQLite self-host, one adapter-agnostic codebase):

- **Maker layer** — `maker_projects`, `maker_models`, `maker_items`, `maker_inventory_items`,
  `maker_inventory_transactions`, `maker_boms`, `maker_bom_lines`, `maker_suppliers`,
  `maker_locations`, `maker_collections`, `maker_collection_items`, `maker_tags`,
  `maker_taggings`, `maker_tasks`, `maker_build_log_entries`, `maker_notes`, `maker_sheets`,
  `maker_print_runs`, `maker_previews`, `maker_file_attachments`, `maker_addon_states`,
  `maker_addon_state_revisions`, `maker_addon_files`.
- **Identity** — `users`, `user_identities`, `devices`.
- **The library catalog** — `nodes(node_id, parent, name, kind, current_version, deleted)`. On
  share/s3 the scan populates it; **on `chunk_remote` it is a MIRROR of the sync server's tree**
  and `remote_manifest_chunks` holds the manifests `FileLayer::ChunkRemote` reads.
- **`users.head_seq`** survives and is still written by `User#next_seq!` (and read by
  `V1::DevicesController`).

**THE EIGHT SYNC-ENGINE TABLES ARE GONE** — `versions`, `manifest_chunks`, `chunks`,
`changelog_entries`, `pending_commits`, `conflicts`, `file_locks`, `share_links` were dropped on
2026-08-25 (`DropRetiredSyncEngineTables`) after verifying 0 rows on every live deployment. They
live in `tinkerex-sync` now. **Do not reintroduce a model, association or query naming any of
them here** — the guard in `test/architecture_invariants_test.rb` asserts zero such references,
including the bare `has_many` spellings (`user.versions`, `user.chunks`, …), because a
`user.versions.find_by(...)` emits no constant token for a const-only check to catch.

**Two columns are NOT edges into `versions`, and reading them as such is a recorded mistake:**
`maker_previews.version_id` and `maker_file_attachments.version_id` hold a backend-polymorphic
**`content_token`** — a version UUID on chunk_remote, a **content hash** on share/s3.

Versioning is native only on `chunk_remote`, where it is the sync server's. **Share and s3 are
current-state only** — a deliberate departure, §14a.

---

## 6. Talking to the sync server (`chunk_remote` only)

`docs/sync-protocol.md` is the normative wire spec. **This app implements the CLIENT half and
serves none of it** — `/v1/changes`, `/v1/tree`, `/v1/commit`, `/v1/chunks/*`, `/v1/conflicts`,
`/v1/locks`, `/v1/trash`, `/v1/nodes` and `/v1/share_links` are **not routed here** (§12.12). A
desktop client syncs against `tinkerex-sync`, never against this app.

`FileLayer::ChunkRemote` (~1000 lines, `app/services/file_layer/chunk_remote*`) calls exactly
eight endpoints: `/v1/tree`, `/v1/changes`, `/v1/commit`, `/v1/commit/:id/finalize`,
`/v1/chunks/download`, `/v1/nodes`, `/v1/trash/:id/restore`, and `/v1/admin/libraries`.

Three things about that client matter enough to be invariants, and all three are in §14a:
- **Reads answer from the local mirror**, refreshed by this app's own five write verbs plus
  `FileLayer::RemoteChangelogPullJob` — **never** by a pull in a read path.
- **The transport is per-user and holds no cache**, because `FileLayer.current` memoizes one
  adapter for the whole process.
- **`presignable` is FALSE** — this app cannot verify that a URL another server signed points
  off-box, so it streams.

What checks the wire is **`bin/ci test-chunk-remote`**, which boots a real `tinkerex-sync` host
app and runs the full suite against it, plus that repo's own conformance corpus.

---

## 7. Deployment

| | Managed | Self-host |
|---|---|---|
| Rails | cloud | user's box |
| DB | Postgres (Neon/RDS) | SQLite |
| Storage | R2 | their S3 (SeaweedFS/MinIO) |
| Tenancy | `user_id` scoping | single user |

Same models, same API, same client — only the hosts/creds differ. Switching DB is config-only
(the code is adapter-agnostic; tested on SQLite).

**A share/s3 deployment sets NO `STORAGE_BACKEND` and NO `CHUNK_*`** — see §14a for the 500 that
caused. Since Arc D Part 2 **no code in this repo reads `STORAGE_BACKEND` or any `CHUNK_*` storage
knob at all**; those are the sync server's, set on the `sync` accessory or in that repo's env. The
one `CHUNK_*`-looking variable this app *does* read is **`CHUNK_REMOTE_URL`**, which is just the
sync server's address.

**Bare "deploy" means the three Unraid destinations — `chunk_remote` (the base), `share`, `s3`.**
Deploy OVH only on explicit request. `docs/DEPLOY.md`.

> **Historical note, kept because the cost was real:** Arc D Part 1 added a fourth destination,
> `remote`, and bare "deploy" excluded it — **an excluded destination drifts**, which is how
> `chunk_remote` reached Stage 5 having never run on hardware. Arc D Part 2 folded `remote` into
> the base, so the base destination IS `chunk_remote` now (`config/deploy.yml`) and bare "deploy"
> covers it. Discharged, not deleted quietly.

---

## 8. Multi-tenancy & security

- **Tenant = user** (one library, the user's own devices). Isolation = ordinary Rails `user_id`
  scoping.
- **ON `chunk_remote`, "TENANT = USER" HOLDS ON THE SYNC SERVER TOO, SINCE ARC C (2026-08-24) — IT
  DID NOT BEFORE.** Before Arc C, `FileLayer::ChunkRemote#transport` read one process-wide
  `CHUNK_REMOTE_TOKEN`, so every maker user's writes reached the sync server as the SAME device
  belonging to the SAME sync-server user — two maker users on one `chunk_remote` deployment shared
  one remote library and could see each other's files. `users.sync_device_token` (encrypted,
  per-row) plus `FileLayer::ChunkRemote::Provisioning` (`POST /v1/admin/libraries`, gated by a
  distinct `SYNC_ADMIN_TOKEN` operator credential a device token can never satisfy) give each
  maker user their OWN remote library, lazily, on first library use — mutation-checked: restoring
  the old shared memo reproduces the leak deterministically, `200 of 400` threaded observations
  carrying the wrong user's token (`test/services/file_layer/chunk_remote/transport_isolation_test.rb`).
  Full argument, including why the fix is deliberately NOT thread-local caching either: §14a.
- **Bytes never flow through Rails.** Rails is the control plane only. (§15; the one deliberate
  departure is the share backend — §14a.)
- **Registration creates a new account only** (no `find_or_create_by` takeover); a device joins an
  existing library via **`POST /v1/devices/login`** (email + password → a 256-bit device token) or,
  from an already-authenticated device, `POST /v1/devices` to add a sibling. **Pairing codes were
  the earlier mechanism and are gone** (`DevicePairing` / `device_pairings` dropped, `18c623a`).
  Web auth is Rails 8 built-in (signup/confirm/login/reset) with an OmniAuth seam. Real OAuth/OIDC
  email verification is the later upgrade; the device-token mechanism underneath stays.
- **Device tokens are 256-bit, SHA256-digested at rest.** A device token is the **only** credential
  the whole v1 API accepts, including all fourteen `v1/maker/*` controllers — which is why
  `devices` is deliberately ungated (§14a) and why `Device` is owned here, not by the sync server.

---

## 9. Licensing (don't relitigate)

- **Prefer permissive: MIT / Apache-2.0 / BSD.** Everything we use/ship is permissive (Rails MIT,
  SQLite PD, our crates Apache).
- **Avoid GPL/AGPL** in dependencies and shipped artifacts. SeaweedFS (Apache) is the self-host S3
  backend (not MinIO, which is AGPL). The FUSE-driver side of this rule belongs to
  `tinkerex-client` — drivers are user-installed, never bundled — and is recorded there.
- **GPL sidecars are invoked over HTTP, never linked** — and shipping them has its own three rules
  (§14c).

---

## 10. Repo layout

```
/                Rails 8 maker app (app/, config/, db/) + docs/ (incl. DEPLOY.md)
/tools           stl-thumbnailer: a Rust STL→PNG renderer, but a SERVER-side tool (compiled
                 into the Rails image, exec'd by Maker::Previews::Stl) — not a client crate,
                 which is why it lives here rather than with the rest of the Rust code.
/sidecar         GPL services invoked over HTTP only: boxes (GPL-3.0), openscad (GPL-2.0)
/ops             Scripts that run ON the box, not in the app — backup-db.sh, installed by
                 bin/backup-cron-install. No gate covers these; invariants in §14i.
/docs            sync-protocol.md, SYNC_SERVER.md, DEPLOY.md, roads-not-taken.md,
                 architecture-sync-engine.md, adr/
/docs/invariants §14's AREA rules, one file per area — addons.md, measure-view.md,
                 deploy-secrets.md, backup-restore.md, model-intake.md. NOT optional reading and NOT
                 demoted: each is §14 material that binds only inside its own subsystem,
                 pointed at from a stub under its original §14 anchor. Read the file before
                 touching the paths its stub names. Guard: test/docs_hygiene_test.rb.
```

**There is no `/engines` and no `/client` here.** The sync engine went to
`chaim354/tinkerex-sync` and the Rust crates to `chaim354/tinkerex-client`, both on 2026-08-20;
since 2026-08-25 neither is a *dependency* of this repo either (§12.12). Clone them as siblings
(`../tinkerex-sync`, `../tinkerex-client`) for the two §13 legs that need them.

**`db/migrate/` still creates the eight engine tables for THIS app, and those migrations were
deliberately never rewritten.** A LATER migration DROPS them (`DropRetiredSyncEngineTables`,
2026-08-25), which is not the same thing and is not forbidden by that rule: **adding a drop runs
forward everywhere, where rewriting history does not** — a rewrite invents timestamps that make
already-migrated databases fail with "table already exists," fixable only by hand-inserting
`schema_migrations` rows on every live database.

> **Both stale `/docs` files were dealt with on 2026-08-25 (§12.13).** `docs/SYNC_SERVER.md`
> **moved** to `chaim354/tinkerex-sync` — it was not stale about its subject, it was in the wrong
> repository — leaving a redirect stub here because ~8 documents and `config/database.yml` cite the
> old path. `docs/architecture-sync-engine.md` is **marked HISTORICAL**: it is the pre-split v1
> design and describes all three repos at once, so it is kept for the *why* (the WAN measurement,
> the coarse-protocol argument) and explicitly not for what any repo contains.
> `docs/sync-protocol.md` is current and remains the normative wire spec.

---

## 11. Status

**The canonical record is the self-hosted Kaneo at `http://kaneo.home`, project `tinkerex`**
— every completed arc as a closed `arc` issue, open work as open `open-work` issues, deploys as
`deploy` issues, and corrections as COMMENTS on the arc they correct. Read it with `bin/log search
"<query>"` / `bin/log show N`; write it with `bin/log` and nothing else (§13). Do not re-narrate it
here.

**THIS BASE URL IS DEFINED HERE AND NOWHERE ELSE.** Code comments cite a bare `tinkerex#N`, so the
instance can move without touching them. `docs/STATUS.md` held this record until 2026-08-26 and was
migrated in full — 110 arcs, `tinkerex#6`–`#115` — then deleted. Its text is still in git history
(`git show <sha>:docs/STATUS.md`); nothing was pruned.

Where things stand: the full stack runs **on real hardware**. Rails is deployed via Kamal on an
Unraid VM, and all **three `LIBRARY_BACKEND` values are deployed live**. The maker web layer
(projects, model library, previews, `/tools` addons, current-project, 3D viewer, file
organization) is server-rendered Hotwire on `Maker::*` models. The desktop client mounts and syncs
on all three OSes against the sync server — that half's status lives in `tinkerex-client`.

---

## 12. What's open

**A FROZEN POINTER TABLE. The state lives in the record (§11); only the NUMBERS live here**, because
code cites `§12.7` and `§12 item 11` by number — 21 such citations in `app/ lib/ test/ config/`.
**Never renumber, and never add an item here** — new open work is `bin/log open`, which needs no
slot. A closed item keeps its row for the same reason it always did: the citation must resolve.

1. Real OAuth/OIDC email verification → `tinkerex#118`
2. At-rest chunk encryption → `tinkerex#119`
3. Sharing → `tinkerex#120`
4. Selective sync needs an app surface → `tinkerex#121`
5. Managed-Postgres at scale → `tinkerex#122`
6. Windows CI coverage is skipped, not passing (Linux landed 2026-08-31) → `tinkerex#123`
7. `SQLite3::BusyException` — the write path it needed left with the engine → `tinkerex#124`
8. `FilesController#index` render cost → `tinkerex#125`
9. No web UI for inventory, BOM, suppliers, locations, collections, tags → `tinkerex#126`
10. A device push DOES nudge project-folder filing → `tinkerex#127` *(closed)*
11. Project-scoped upload duplicate-check scope → `tinkerex#128`
12. Embedded `chunk` retired; the sync engine is not a dependency → `tinkerex#129` *(closed)*
13. The two pre-separation `/docs` files are dealt with → `tinkerex#130` *(closed)*

## 13. Build & run cheatsheet (for a fresh context)

```sh
# ALL local gates, one command (this is what CI runs, by name):
bin/ci                 # bin/ci --list for gate names; config/ci.rb is the single definition.
                       # 7 gates (6 under CI -- `setup` is local-only, bin/ci --list-ci):
                       #   setup style scan test test-s3 test-chunk-remote system
                       # THE THREE BACKEND LEGS ARE share / s3 / chunk_remote and must report
                       # IDENTICAL run counts (§15). `test` IS the share leg -- it ran embedded
                       # chunk until 2026-08-25, and `test-share` was folded into it rather than
                       # left as the same leg twice. `test-no-engine` is gone: no engine is the
                       # only mode there is now, and every gate exercises it.

# ONE gate needs a SIBLING CHECKOUT. `test-chunk-remote` drives this app against a real
# chaim354/tinkerex-sync HOST app, booting it via bin/sync-server. A missing checkout fails
# loudly and names the clone command rather than falling through to a connection error. It runs
# the FULL suite there, not just a journey file, because there is no in-process chunk backend
# left to carry that coverage:
gh repo clone chaim354/tinkerex-sync ../tinkerex-sync

# Server tests (SQLite; proves adapter-agnosticism)
bin/rails test
# The other two backend legs need their env or they DON'T look like a missing var --
# LibraryBackendCheck refuses to boot, which reads as a broken backend (see ci.yml verbatim):
LIBRARY_PATH=$(mktemp -d) LIBRARY_BACKEND=share bin/rails test
# The s3 leg additionally needs the five LIBRARY_S3_* stub knobs -- see ci.yml's test-s3-backend.

# Boot a sync server locally (its own repo's app, on $SYNC_PORT, default 3002):
bin/sync-server prepare && bin/sync-server start

# SECRETS: no `export` before a deploy. `bin/secret VAR op://tinkerex/Item/field` resolves every
# credential (exported shell value wins, else 1Password) and backs each .kamal/secrets* file.
# ALWAYS preflight first -- kamal expands `$(...)` through Ruby BACKTICKS, which discard exit
# status, so an unreadable secret becomes an EMPTY one that deploys silently (§14g):
bin/secrets-preflight --all      # or: (omit) | s3 | share | ovh

# RECORDING WORK -- bin/log is the SINGLE write door onto the Kaneo at kaneo.home. MCP may READ
# it and never writes. Token via bin/secret (op://tinkerex/kaneo/credential); never `export`.
bin/log setup                    # create the labels, idempotently (safe to re-run)
bin/log arc --from-pr 261        # arc issue built from the merged PR body
bin/log open "<t>" | close N | deploy --image SHA | note N "<text>" | search "<q>" | show N | status
# EXIT CODES ARE LOAD-BEARING. 3 = unreachable, and a WRITE was spooled to $LOG_SPOOL_DIR (default
# tmp/log-pending/<branch>.md); a 502 counts as unreachable, there is NO auto-replay, and
# `bin/log status` exits 4 until you file it. 5 = a BUG in bin/log -- NOT spooled, do not proceed.
# It needs no gem, but an inherited RUBYOPT force-requiring bundler applies before its first line,
# so a caller inside a bundled process must clear those names, as bin/sync-server does (§14j).

# THE SYNC SERVER runs as a Kamal ACCESSORY, not a service -- that is what gives it the FIXED
# container name `tinkerex-sync`, the stable network alias this app puts in CHUNK_REMOTE_URL. A
# Kamal *service* gets a per-deploy `<name>-<sha>` name, so `http://tinkerex-sync:3000` does not
# resolve to one (measured: 000). A standalone service deployed from tinkerex-sync's own
# deploy.yml COLLIDES with this accessory on the `service=tinkerex-sync` label -- one shape per box.
kamal accessory boot sync            # first time
kamal accessory reboot sync          # pick up a new :latest, or an env change

# THE SYNC SERVER IS A SECOND DATABASE ON THE BOX and the backup scripts know it as `sync`:
bin/backup-db sync                                   # ad-hoc, to this Mac
bin/restore-db sync <archive> --into rehearsal --yes # throwaway volume, live untouched
bin/backup-status                                    # all four destinations
```

**Working on the sync engine or the desktop client?** You are in the wrong repo — there is
nothing to edit here, and since 2026-08-25 neither is a dependency of this one (no gem, no
`Gemfile.lock` pin, no `bundle update` step, no cross-repo schema guard). What couples them now is
the **wire**, checked by `bin/ci test-chunk-remote` here and by each sibling's own suite.

```sh
gh repo clone chaim354/tinkerex-sync   ../tinkerex-sync     # then: bundle install && bundle exec rake test
gh repo clone chaim354/tinkerex-client ../tinkerex-client   # its CLAUDE.md has the cargo/mount cheatsheet
```

**NO CI LEG HERE REACHES INTO `tinkerex-client` ANY MORE (2026-08-25).** `nightly.yml` and
`client-contract.yml` are deleted: both tested sync↔client with **no code from this repo
involved**, and both were broken in ways only measurement showed. `client-contract.yml` had never
run once — its only real job is linux-gated and `CI_RUNNERS` is `macos`, so every run reported
SUCCESS having run only `preflight`. `nightly.yml` still booted THIS app's Rails and pointed the
Rust client at it, three hours after Arc D Part 2 stopped routing `/v1/commit` here. Corrected
recipes went to the siblings in
`docs/superpowers/specs/2026-08-25-cross-repo-ci-handoff.md`. **`ci.yml` is the only workflow
left** — seven jobs, all macos: `preflight` plus one per gate, each invoking `bin/ci <gate>`. This repo's half of the wire contract
is `bin/ci test-chunk-remote`, which is not moving.

**Env gotchas in this build box (may differ on yours):** no local Postgres/libpq (dev & test run
on SQLite); macOS keeps creating `" 2"`-suffixed duplicate files in the repo (some sync client?) —
they broke a build once; `find . -name '* 2.*' -delete` to sweep.

## 14. Invariants and hard-won learnings (don't relitigate)

> The condensed **abandoned/superseded approaches** (remote mount, JuiceFS data plane,
> Cloudflare-native sync, WinFsp-as-default, last-writer-wins, the `mtime=now` hack, FSKit)
> — *what was considered → why rejected → current approach* — live in
> **`docs/roads-not-taken.md`**. Read it before reviving any of them.

Each line below cost a real bug **in this repo**. the record (§11) has the full story for any of
them. Invariants belonging to the sync engine or the desktop client live in those repos'
own CLAUDE.md — see §3 and §14j.

**Seven subsections live in `docs/invariants/` and are stubs here** — 14c (addons), 14f (project
intake), 14g (deploy secrets), 14h (Measure), 14i (backup), 14k (the model catalog), 14l (git
editing). They are §14 material, not an appendix: each binds hard inside its own subsystem and not
at all outside it, so it is loaded when it applies rather than skimmed on every unrelated session.
**Read the file before touching the paths its stub names.** Anything below that binds on only one
area belongs there too, with a stub here.

### 14a. The FileLayer port

- **`LIBRARY_BACKEND=chunk_remote|share|s3`, chosen per DEPLOYMENT, not per user — and `chunk` is
  REFUSED, not aliased.** Embedded `chunk` was retired 2026-08-25 (§12.12): `Sync::` is undefined
  in this process, so `FileLayer.build` raises `ArgumentError` on the old value rather than quietly
  serving chunk_remote — a deployment still carrying it is misconfigured, and substituting a backend
  would hand it an empty library that reads as data loss. **The default is `share`**, the only
  hermetic backend left; nothing in production relies on that, since every Kamal destination sets
  `LIBRARY_BACKEND` explicitly. `chunk_remote` is the maker app as a SYNC CLIENT: reads answer from
  a locally-mirrored `nodes`, writes go over the v1 API, **the engine is not in the process at
  all**. Capabilities `versioned`/`syncable` true, **`presignable` FALSE** — it cannot verify that a
  URL another server signed points off-box, so it streams.
  Reads — `stat`/`stat_all`/`read`/`download`/`trashed` — are answered by all three adapters, as
  are the metadata writes `mkdir`/`move`/`delete`/`undelete`. Only the BYTE write (`write`) is
  **Share + S3 only**: chunk_remote's upload is the two-phase `begin_upload`/`finalize_upload`
  pair, never `write`.
- **A share/s3 deployment sets NO `STORAGE_BACKEND` and NO `CHUNK_*`.** `STORAGE_BACKEND`
  defaults to `s3` *outside test*, so resolving a chunk store on a v1 request once made a
  share deployment's **entire v1 API answer 500** (`KeyError: CHUNK_BUCKET`) — including
  login and every gated endpoint, which returned 500 instead of 501. The suite was green
  with **and without** the fix, because the gating tests set `FileLayer.current` and never
  touched `STORAGE_BACKEND` (`memory` in test, `s3` in production).
- **`ChunkRemote` ANSWERS the four metadata verbs and refuses only the BYTE write.** Until Stage 2
  (2026-08-20) the chunk family refused `mkdir`/`move`/`delete`/`undelete` per-op, each naming its
  real door, because the maker layer branched around the port (§14d used to count five
  `port_writable?` copies for exactly this). It no longer can: in remote chunk mode there is no
  `Sync::*` in the process to branch into, so every one of them goes over the wire.
  **`delete` on a directory must reach the server's CASCADING delete, never a per-node tombstone**
  — a tombstone applied to the node alone **orphans every descendant**. That is why
  `dir_deletable` is true here (next bullet) and it is the one trap this bullet has always existed
  to protect. The cascade itself is the sync server's code and its rules live in that repo's
  CLAUDE.md; what binds *here* is that this adapter must not invent a per-node substitute.
  **`write` still refuses, and must**: it takes an IO, and a server-side byte write would push
  bytes through Rails (§15).
- **`dir_deletable` (the 6th capability) is NOT `syncable`, though the two agree on all three
  backends today.** It answers one question for one caller, `FilesController#destroy`: may this
  backend's `delete` be handed a DIRECTORY? chunk_remote true (the sync server's delete cascades the whole
  subtree); share false (children are stranded at paths that no longer exist while their bytes
  sit in `.trash`, which the scan refuses to look at); s3 false (no directory and no rename — a
  dir node's key does not exist). It exists because `#destroy` stopped branching on
  `port_writable?` once the chunk family started answering `delete`, which made one call have
  two answers —
  the shape §14a forbids. Agreement across three backends is three samples, not an identity —
  the same coincidence `scannable` was added to stop encoding twice (`is_a?(Share)`).
- **`begin_upload`/`put_chunk`/`finalize_upload` are port verbs, and NONE of the three is the
  byte-taking `write` above.** The port never holds a byte: `begin_upload` returns presigned PUT
  URLs for whichever chunks the store is missing, and the caller PUTs straight to object storage —
  except `Maker::Addons::LibraryOutput`, which generates bytes server-side and has no client to
  presign for, so it calls the port's own `put_chunk` instead, and `finalize_upload` records the
  version. That is what keeps §15 true for a chunk_remote upload. **`put_chunk` is a PORT VERB
  rather than one shared call**: until Arc B it *was* one shared call (`Storage::ChunkStore#put`,
  dialled straight from `LibraryOutput`), which is a `NameError` on any deployment not loading the
  engine in-process — `chunk_remote` is exactly that, so **every addon save there raised**, measured
  against a live standalone server. It also could not be shared with the embedded adapter, where a
  presigned URL for a memory/local store can point BACK AT RAILS and a server-side PUT to it is a
  **loopback into the same Puma pool** (§14e's reentrancy bug). Only the adapter knows which
  situation it is in, which is why the caller cannot decide. The maker layer now names **zero**
  chunk-internals references (§14c).
- **`finalize_upload` broadcasts by DEFAULT, with exactly one explicit opt-out** —
  `Maker::Addons::LibraryOutput` passes `broadcast: false`, preserving what addon saves have
  always done (never nudged live devices; open item, the record (§11)). `mkdir`/`move`/
  `delete`/`undelete` broadcast unconditionally, so a caller cannot forget; this verb has two
  callers wanting different behaviour for one fact, so it defaults to the safe answer (notify)
  rather than delegating the choice — an unwritten third caller that forgets to opt out gets a
  working nudge, not a silent gap.
- **AN ORPHANED RESTORE IS REFUSED, ON EVERY BACKEND THAT CAN REACH THE STATE — AND THIS REVERSED
  AN EARLIER RULE** (which reparented an orphan to the library ROOT). Since `delete` cascades a
  whole directory in one call, restoring a CHILD before its PARENT is the **mainline** case, not an
  edge case — and reparenting permanently scatters that folder's contents to the root. **A refusal
  is recoverable — restore the folder, then the file; a scatter is not.** `FileLayer::ChunkRemote`
  posts no `to_root` and takes the sync server's strict default, so the 409 reaches
  `Transport#interpret` as `UnsupportedOperation` with a message naming the ACTION ("restore the
  folder first"), not just the failure. Pinned by the shared mutation contract
  (`adapter_mutation_contract.rb`) gated on `dir_deletable?`: share and s3 cannot reach this state
  through the port at all, so there is no door producing a live child under a tombstoned parent for
  them to disagree about. The device-facing half — why the sync server's trash controller keeps a
  caller-supplied `to_root:` — is that repo's rule. **The web `TrashController` chooses the refusal
  on the user's behalf** because a browser Restore click has no prompt to offer.
- **THE LOCAL MIRROR IS DELIBERATELY STALE BETWEEN PULLS, AND ONLY THE RECURRING JOB MAY CLOSE
  THAT GAP — NEVER A READ PATH.** `FileLayer::ChunkRemote#refresh!` has five TRIGGERING operations,
  all this app's own writes — `mkdir`/`move`/`delete`/`undelete`/`finalize_upload` — and
  `ChangelogSync`'s only OTHER caller in `app/`, `lib/` or `config/` is the job named next. A node
  another device or the sync server creates is invisible to the maker UI until one of those five
  fires; driven and confirmed, not reasoned. `FileLayer::RemoteChangelogPullJob` is the sanctioned
  freshness mechanism: a per-user recurring pull (`config/recurring.yml`, every 2 minutes), gated to
  `chunk_remote` by a CLASS check rather than a `Capabilities` member — `syncable` was true for
  embedded chunk AND chunk_remote alike and could not tell "this `nodes` table mirrors a REMOTE
  changelog" from "the engine shares this app's database in-process". (Only chunk_remote is left;
  the class check stays, because a future syncable backend faces the same ambiguity.) **Do not "fix"
  staleness with a synchronous pull in `FilesController#index` or any other read** — that is exactly
  the WAN-in-the-metadata-path §2 forbids, paid per request instead of once every 2 minutes, and the
  journey suite pins AGAINST it (a plain read asserted NOT to see a server-side node). Bounded
  staleness (~2 min) is the trade, the same one `Library::ScanJob`'s poll makes for share/s3.
- **`LibraryBroadcast.batch` HAS TWO ANSWERS, AND THE SPLIT IS "IS THERE A CHANGELOG TO COALESCE
  AGAINST", NOT "IS THE ENGINE LOADED."** Share and s3 get a bare `yield` — no changelog at all,
  nothing to coalesce, so that is the SAME behaviour with the bookkeeping removed, not a degraded
  one. `chunk_remote` has no engine in-process yet DOES have a changelog, over HTTP: left alone, an
  eager `Maker::ProjectIntake` sweep paid one changelog PULL per mutation — a batch of 3 moves cost
  3 pulls, measured, two WAN round trips per file. `FileLayer::ChunkRemote#batch` coalesces in a
  `Thread.current` frame, **DELIBERATELY never an ivar on `self`**: one adapter instance is shared
  across every Puma thread, so per-batch state on the object leaks one request's batch into
  another's unrelated mutation. Its `ensure` pulls exactly once on ANY exit, not only success,
  because every move that ran before an exception has already committed on the SERVER.
  **`mkdir` IS DELIBERATELY NOT DEFERRED and must not be made "uniform" with `move`** —
  `Maker::LibraryFolder#ensure_segment` reads the mirror row back in the SAME call that creates it,
  so deferring turns an ordinary new category folder into `ActiveRecord::RecordNotFound`.
  `delete`/`undelete`/`finalize_upload` keep their unconditional `refresh!` for the identical
  reason: each hands a caller state read from the row the pull just wrote. **`move` alone has no
  such reader** — `Maker::MoveNode#apply_move` treats the RELOAD as the return value, never
  trusting what `move` hands back — which is what makes deferring safe there and only there.
- **`ChunkRemote#transport` IS PER-USER (Arc C) AND DELIBERATELY HOLDS NO CACHE AT ALL — NOT AN
  IVAR, AND NOT `Thread.current` EITHER**, which is the part easy to get wrong by analogy with
  `#batch` two bullets up. `FileLayer.current` memoizes ONE adapter for the whole process, so an
  ivar memo here is not a per-request cache, it is PROCESS-WIDE STATE: the pre-Arc-C
  `@transport ||=` handed every other user the first caller's token until restart. Restoring that
  one line still reproduces the leak deterministically — **`200 of 400` threaded observations carry
  the WRONG user's token** (`transport_isolation_test.rb`). `Thread.current` would be strictly
  WORSE, not merely unnecessary: `#batch` caches real cross-call work, whereas `Transport.new` is
  four ivar assignments opening no connection — and **Puma REUSES threads across unrelated
  requests**, so a thread-cached transport serves a LATER user the FIRST user's token, and a
  since-rotated one forever. The ONE exception is the constructor-injected `transport:` (checked
  first, returned unconditionally) — a test's explicit "give every caller this object", not a cache
  anything resolves into. **The mutation-check is "put `@transport ||=` back", never "add a
  different kind of cache": anything keyed on less than the user is the shape of the bug.**
  Arc C in full, including lazy provisioning under concurrency: the record (§11).
- **`port_writable` IS NOT "accepts uploads"** — the single most-misread name here. It
  answers *which upload flow the UI drives*: true → POST bytes to the port (share, s3);
  false → drive the port's own `begin_upload`/`finalize_upload` presigned flow (chunk_remote).
  `chunk_remote` accepts uploads all day — that flow **is** how a chunk upload happens — so
  the "can this deployment take uploads" reading **hides the upload button in the
  product's main deployment**. It is also not `!syncable?` and not `scannable`; the full
  argument is at `app/services/file_layer/capabilities.rb`.
- **The 501 is a capability gate BEFORE the call, never a `rescue NotImplementedError`.**
  `NotImplementedError` is a **`ScriptError`, not a `StandardError`**, so `rescue => e` and
  ActiveJob's `retry_on` silently do **not** catch it — a rescue-based gate doesn't have a
  gap, it doesn't work, failing to exactly the 500 that was forbidden. A 501 from
  `ChunkRemote#write` would also be *factually wrong* (the caller used the wrong door), and a
  controller rescue would launder an s3 **misconfiguration** into a routine response.
  Keep `NotImplementedError` un-rescued and loud. **`test/architecture_invariants_test.rb`
  enforces this** — it is no longer a grep you are trusted to remember to run.
- **Ungated on purpose:** **`devices`** (gating it makes a share deployment's whole v1 API
  unauthenticatable, since a device token is the only credential the API accepts — and the
  plan's own test stayed green because it minted a token in Ruby instead of calling the
  endpoint), and **`V1::ShareController`** (the anonymous redeem side of public file links —
  nothing to do with `FileLayer::Share`; a 501 would disclose the backend to any stranger).
  Two gates are not the capability they look like: **`chunks#download` → `syncable`, NOT
  `presignable`** (S3 is presignable with no chunks to hydrate), and **v1 `trash` →
  `syncable`** (it's the *sync server's* trash, not the share `.trash` directory). `begin_upload`/`finalize_upload` gate on
  `syncable`, not `!port_writable?`.
- **`S3` is the one backend where `presignable` is TRUE and `versioned` is FALSE** — that
  combination is its point. §15 (bytes out of Rails) **survives** there (a bucket has a URL
  signer); §5 (keep versions) does **not**. The other two agree (chunk_remote true/true, share
  false/false), so S3 is the counterexample that forbids collapsing one into the other.
- **Two deliberate invariant departures, scoped to storage we don't own — do NOT "fix"
  these back.** §5 can't hold on a plain share (the user's overwrite in Finder destroys the
  old bytes) → share/s3 are **current-state only**, restore stays chunk_remote-only. §15 can't hold
  for a mounted directory, which has nothing to presign → share streams via **`send_file`**.
- **`send_file` + `x_sendfile_header` is the whole X-Accel story — there is no nginx here.**
  Deployment is kamal-proxy (Go) and `x_sendfile_header` is **nil**, so `Rack::Sendfile`
  no-ops and `Rack::Files` is the only branch that runs. The knob stays **commented** in
  `production.rb`: enabling it would **silently serve empty bodies** for every share download.
- **`Delivery`'s three variants are three MECHANISMS** — `Redirect(url)` (s3) /
  `SendFile(path)` (share) / `Stream(enum)` (chunk_remote) — and
  `FilesController` consumes them **without ever constructing a path**. `disposition:` is
  **required, not defaulted**: nil makes `ContentDisposition.format` emit a header with no
  disposition type, which browsers resolve as **inline** — a silent cross-backend
  divergence, on S3 only, where the value is signed into the URL.
- **`stat_all(user, node_ids:) -> Hash keyed by node_id` is a port verb**, and **a missing
  node is an ABSENT KEY, not a raise** — `stat` is asked about one node so `NotFound` is its
  whole answer, but a bulk caller holds a **list**, and a row tombstoned mid-page must not
  404 the page. The shared contract pins three things, and **only the third fails for a
  loop** (`node_ids.map { stat }` is behaviorally identical): the query count must be
  **constant in N**, asserted as constant rather than a literal (chunk_remote needs 2, share/s3 1).
- **THE TWO TOMBSTONE KINDS — the thing most likely to get "simplified" away.** A **scan**
  tombstone **keeps** `storage_path`; a **trash** tombstone **NULLs it** and is revivable
  only by `undelete`. Collapse them and `Reconciler#create_or_revive!` hands a **new,
  unrelated file the trashed node's `node_id`** — with every attachment, BOM link and tag —
  while the old bytes await an `undelete` that then collides. Silent.
- **Trash layout `.trash/<node_id>/<name>`, keyed by `node_id`** — which is *why* two
  same-named deletes can't collide, and why `undelete` has one place to look.
- **`undelete` is a FOURTH port verb.** "Undelete is just a move back" is *precluded*:
  `move` starts with `live_node!` (a tombstone isn't live) and resolves via `storage_path`,
  which is NULL — it would rename the library root.
- **Order is load-bearing both ways:** `delete` is **move-then-tombstone** (the reverse
  fails *silently* — the next scan resurrects it); `undelete` is **move-then-revive**.
  `EXDEV` → `FetchError`, **never** a copy+delete fallback.
- **`delete` refuses directories; `move` ALLOWS them.** A dir delete strands children at
  paths that no longer exist while their bytes sit in `.trash`, where the scan refuses to
  look. A moved dir leaves the bytes observable **at an observable destination**, so pairing
  rescues the children — that qualifier is load-bearing (see §14b). On **S3 both refuse
  dirs**, because there is no directory and no rename: a dir node's key doesn't exist.
- **An unmounted share must never read as "your file is permanently gone":** `undelete` and
  `read` raise **`FetchError`** (retryable → 503), not `NotFound` (terminal → 404).
  `FetchError` → 503 and `UnsupportedOperation` → 422 are mapped once at `FilesController`.
- **A clobber is `UnsupportedOperation`, and ALL THREE VERBS moved together.** Both adapters
  once raised `NotFound`, so a duplicate-name upload said "File not found." about a file in
  the list behind the alert. "The destination is taken" is ONE condition that
  `write`/`move`/`undelete` all meet — fixing only `write` leaves one condition with two
  answers inside one adapter. `FetchError` would be worse: it is the *retryable* answer and a
  clobber never succeeds on retry. If a caller must branch, the answer is a **subclass**.
  (This also broke `TrashController`, which rescued `NotFound` but not
  `UnsupportedOperation` → an uncaught 500, **while its own rescue comment already named
  that case**. The gap was in the CONTROLLER, which is why no adapter suite could find it.)
- **`LIBRARY_TRASH_DAYS`** default **30**; **`0` = keep forever, NOT purge everything**
  (`0.days.ago` is *now*, so the obvious implementation deletes the lot). Purges by
  entry-dir mtime, never touches the row, and **empties `.trash` but never removes `.trash`
  itself** (an empty root reads as unmounted → would flip `undelete`'s error class).
- **The boot guard touch-probes for writability; `File.writable?` is NOT the check** — it
  tests POSIX mode bits, not effective access, and is wrong under exactly the NFS/SMB ACLs
  this backend targets. It must run in **`after_initialize`**: app constants aren't
  autoloadable while initializers run, so the naive version raised `uninitialized constant
  Library` and **took the boot down while every test stayed green** (test env skips it).
  **The S3 boot guard does NO NETWORK** — a boot depending on a third party turns a blip
  into a crash loop. Config *presence* is what boot can honestly check.
- **`FileLayer.build` TELLS `check!` WHICH BACKEND IT RESOLVED; the guard's no-arg default is the
  BOOT INITIALIZER's question and is deliberately DIFFERENT.** Calling `check!` with no arguments
  let it re-read ENV with a default (`chunk`) Arc D Part 2 left behind when `build`'s became
  `share` — so **the one backend reachable WITHOUT setting `LIBRARY_BACKEND` was the one the guard
  never checked**, and `Share.new` raised a bare `KeyError` that broke `bin/ci setup`, a gate no CI
  job runs (`LOCAL_ONLY_GATES`). Do NOT instead match the guard's own default to `build`'s:
  measured, that refuses an unconfigured dev box's BOOT and moves the same failure one step
  earlier. A port that cannot be CONSTRUCTED is not a scannable one — `Library::RepoMetadataPurge`
  declines with a `reason`, rescuing `LibraryBackendCheck::Error` alone, never `KeyError` (too
  broad) and never around the sweep (§15's silent-success shape).
- **`write(..., replace: true)` IS AN OPT-IN BESIDE THE CLOBBER REFUSAL, NOT A RELAXATION OF IT.**
  The refusal is still the default on both writable adapters and every existing caller omits the
  kwarg; `replace:` exists for a door that has just asked a user "this would replace `design/x.svg`
  — overwrite?" and been told yes. **It MUST reuse the existing node.** A replace written as
  delete-then-create passes any bytes-oriented test while orphaning every attachment, BOM link and
  tag — the landmine two bullets down, whose signature is that nothing errors and nothing logs.
  Pinned in `adapter_write_contract.rb` beside the clobber test, asserting **`node_id` survives**,
  not merely the content. Cheap on both backends because each already had the hard part: Share's
  temp-then-rename is atomic over an existing destination and `put_object` overwrites by definition,
  so a replace **skips** work rather than adding it. **The two adapters resolve "the file being
  replaced" DIFFERENTLY and must keep doing so** — the port asks by `storage_path` (what it derived
  the destination from), chunk_remote's `LibraryOutput#existing_at` asks by `(parent, name)` because
  chunk_remote nodes have no `storage_path` at all. A test fixture built with `nodes.create!` has a NULL
  `storage_path`, which cannot exist on share/s3: the lookup misses, a second node is created, and
  the leg splits chunk-green / share-red.
- **THE IDENTITY LADDER** (`FileLayer::S3::ObjectIdentity`). One namespaced value answers
  two different questions: `content_token` need only be an opaque content-*state* token, but
  `content_hash` must be content-*determined* for move-pairing — and **a multipart ETag is
  not**. Ladder: **`sha256:`** (FULL_OBJECT only — a COMPOSITE sha256 is a
  checksum-of-checksums, so the *type* is required, not the checksum alone) → **`md5:`** (a
  **32-hex** single-part ETag is the md5 — 32-hex, not merely "dash-free") → **`etag:`**
  (moves degrade to delete+create — a *missed* rename, never a *wrong* pairing). **TOTAL by
  construction, never nil**: `Reconciler#plan_moves` **drops** a nil-hash observation from
  `candidates`, and candidates become the leftovers that get indexed → the object is **never
  indexed at all**, no error, no log. **Quotes come off in exactly ONE place** (S3 quotes
  every ETag in list, head *and* put). Blind spot: an **SSE-KMS** object has a 32-hex ETag
  that is *not* the content md5, so the rung-3 warning count reads **zero while no move
  pairs at all**.
- **`LIBRARY_S3_HEAD_FOR_CHECKSUM` is NOT implemented — do not document it as working.** An
  observer cannot know what is new (the Reconciler does), so a HEAD there is
  per-object-per-**scan**: 2M billed requests every 15 min on a 2M-object bucket, not 2M
  once. Consequence: the **`sha256:` rung is unreachable from any production path today**.
  Download-and-hash was rejected on §1's own terms — a full billed egress to index a library
  the user already has is the cost the on-ramp exists to avoid.
- **LANDMINE — copy → delete → TOMBSTONE.** "Tombstone only after the copy confirms" is
  necessary but **not sufficient**: if the **delete** fails after a tombstone, the next scan
  finds an unclaimed key with **no tombstone to revive by path** → a **new `node_id`** →
  **every attachment orphaned**, by a scan that did nothing wrong, with no error anywhere.
  (`undelete` is the same landmine: copy → revive → sweep the trash copy best-effort, last.)
- **`key_for` REJECTS, never normalizes** — `expand_path` would turn `a/../b` into a *valid*
  key and silently read the wrong object. We sign **path-style** URLs, so a `..` segment
  lands in the URL path and any normalizing proxy resolves it out of our bucket.
- **`S3#write` has NO temp-and-rename, and its ABSENCE is the thing to read carefully** — a
  reader who knows `Share#write` will see a missing step and "restore" it. Share renames
  because a half-written file is *visible* the whole time; **put_object is atomic**, so a
  temp key would only add a second, unobservable ghost. Clobber is refused, but it is a
  `head`-then-`put` **CHECK, NOT A LOCK** (TOCTOU; S3 has no portable conditional put).
  `put_object`'s response carries no `last_modified` → **two billed HEADs per write**.
- **`Share#write` stamps mtime from the file's own stat, not the clock** — the scan compares
  against it.

### 14b. The library scan

- **`scannable` is not `!syncable?` and not `port_writable`.** It asks *"does this backend's
  catalog come from polling the store?"* (chunk false — its tree is the changelog; share/s3
  true). It agrees with `port_writable` on all three backends we have, so the distinction
  must be **argued, not observed**: `scannable` asks where the *catalog* comes from,
  `port_writable` asks which door *bytes* go in, and a notification-driven backend splits
  both. Agreement across three samples is not identity; it is three samples. Both job gates
  (`ScanJob`, `TrashPurgeJob`) key on `scannable?` — keying on `is_a?(FileLayer::Share)`
  would answer false for S3 and **silently never index the library**.
- **The Reconciler is the reusable half; the Scanner is not.** A `Dir.children`/`lstat`/
  symlink walk is irreducibly filesystem-shaped, so S3 gets its own `S3Observer` over
  `list_objects_v2` and both feed the **same** `Reconciler` — which matters because *every
  one of phase 2a's bugs lived in the logic a second copy would have duplicated*.
- **The mass-deletion guard counts the POST-PAIRING tombstone set, never vanished paths** —
  a rename vanishes its old path, so the naive guard refuses the very reorganization the
  feature exists for. Pairing by `(content_hash, size)` is what makes **a rename keep its
  `node_id`, so project attachments survive a NAS reorganization** — the headline promise.
- **`Pathname#find` silently swallows `EACCES`** and drops the unreadable subtree — for a
  tombstoner that is a mass-deletion bug wearing a clean scan. Hence the hand-rolled walk +
  `unreadable_dirs`, which must be excluded from **both** sides of the guard's fraction *and*
  from `vanished_paths`. (`ignore_error: false` aborts the whole walk, order-dependently.)
- **THE SKIP-LIST BLIND SPOT — four instances so far, each found only after the previous
  explanation said it couldn't happen.** Wherever the app moves bytes **into** a skipped
  region (`TRASH_PREFIX` `.trash`, root-anchored; `TEMP_PREFIX` `.maker-tmp-`, skipped at
  **any depth**) while leaving a live node pointing at the old path, it creates ghosts the
  Reconciler **can never pair** — pairing needs an *observation* as the partner, and a
  skipped path produces none. The tombstone then trips the mass-deletion guard, **refusing
  that scan and every scan after it, permanently**. The four: `write`'s temp file; `delete`
  on a directory; `write`/`move` accepting `.trash` as a destination (which also turns
  `.trash` into a file, breaking **every delete in the library**); and `Share#undelete`
  reconstructing its destination from a poisoned parent. A sentence that had to be
  retracted: *"delete is uniquely exposed, because a move leaves the bytes observable at the
  new path"* — false; a move is self-healing only when its **destination** is observable.
  **Assume every path that writes is exposed until you have checked it** (`observable!`).
- **`observable!` CANNOT COVER CHUNK, SO THE DOOR DOES — `Library::ReservedNames.reserved?`.**
  On chunk there **is no path through an adapter** (not `port_writable`), so the commit path is
  driven directly and no `observable!` exists to reach. Probed through the real doors: a
  `.DS_Store`/`.trash`/`.maker-tmp-x` output was **302 + a live node on chunk** and **422 on
  share/s3** — §14a's one-condition-two-answers, with the main deployment on the wrong side.
  **THREE web doors mint a leaf name and all three now ask two questions in the same breath**:
  `Maker::MoveNode.valid_leaf_name?` (syntax) then `ReservedNames.reserved?` (the library's own
  namespace) — `Tools::AddonsController#parse_files`, `LibraryBrowseController#create_folder`,
  `FilesController#begin_upload`. The last had **neither** and was the weakest door in the app
  (`begin=200, finalize=200`, a live node named `"../../escape.txt"` in the changelog); it is
  `syncable`-gated, so **no cross-backend leg could ever have caught it**. Three things not to
  undo: the predicate is the **UNION** of the two adapters' guards, because a door cannot know
  which backend is deployed and the intersection is the same divergence sign-flipped; it is
  **composed from `Scanner::TRASH_PREFIX`/`TEMP_PREFIX`/`OsClutter`, never a fourth copy of the
  strings**; and it is **NOT folded into `valid_leaf_name?`**, which `Maker::MoveNode#call` also
  calls on names that already exist — a macOS mount pushes `.DS_Store` nodes through finalize by
  design, so folding would make a population the product creates permanently unmovable.
- **A LISTING IS NOT A SNAPSHOT.** `list_objects_v2` paginates, and a failure on page 7 of
  40 is a **well-formed lie** that reads exactly like the user deleting 82% of their library.
  It is the `EACCES` problem again minus the escape hatch: `unreadable_dirs` scopes a gap to
  a *subtree*, but a page boundary is an arbitrary key range that scopes to nothing.
  **Complete-or-abort is the only honest answer** (`Scanner::UnsafeScan`). Two more it must
  not inherit by assumption: **dir-marker objects** (`cad/`, minted by the S3 console) would
  become a phantom *file* node beside the real dir node; and **`valid_encoding?` does NOT
  transfer** — it asks about the string's *tag*, and an ASCII-8BIT string is always valid, so
  the naive port waves a `\xFF` key straight into `storage_path`. Filenames on a real NAS
  **are not guaranteed to be valid UTF-8**.
- **`Share#absolute_path` must never resolve a NULL `storage_path` to the library root.**
  `#download` handed that **directory** to `send_file`; `read`/`delete`/`move` escaped only
  by *accident* (EISDIR, EINVAL). `allow_root:` is **gone**, not switched off.
- **A `Maker::Preview` is ONE ROW PER `(user, node, kind)`, REPOINTED as content moves** (was
  one per *version*, which leaked a row + blob on every save). Two consequences that are easy
  to undo by accident: **`GeneratePreviewJob` must compare-and-set** (`#commit_if_current`) —
  with one row, a slow render of v1 finishing after v2 would attach v1's bytes to a row
  claiming v2 and mark it ready, a wrong image shown as current, which the row-per-version
  key made impossible *by construction*; and **`POST /v1/maker/previews` answers 422 for a
  superseded version** rather than repointing the live row backwards.
- **The scan must enqueue a thumbnail on BOTH the create/revive branch AND the in-place
  content change.** The second was missing: previews resolve by `[node_id, content_token]`,
  so a file re-saved in place stranded its row on content that no longer existed and went
  blank on every surface — the ordinary case on a mounted NAS (LightBurn, a slicer), which is
  why it read as a format bug. **A scan cannot repair that backlog and should not try** (those
  nodes are now `unchanged?` and correctly skipped); the sweep is
  `Maker::Previews::MissingBackfill` (`rake previews:backfill_missing`).
- **Reconciler perf, and its own comment was the lesson.** The old comment argued *"dwarfed
  by the hashing, not worth an index"* — but hashing is LINEAR and that scan was QUADRATIC,
  so the crossover was built in. A no-op scan now `pluck`s the compared columns instead of
  instantiating a live node per file, and `best_pairing` buckets candidates by `[hash, size]`.
  *Still inherent:* an all-byte-identical bucket costs O(N) per probe, because the
  deterministic tie-break must compare the old path against every identical candidate —
  removing that trades the no-lost-file guarantee for speed.

- **`.git` IS THE ONE SKIP THAT KEEPS ITS ENTRY, AND THE INVERSION IS LOAD-BEARING.**
  `Scanner::TRASH_PREFIX`, `TEMP_PREFIX` and `Library::OsClutter` skip the ENTRY, so no node ever
  exists. A repo's `.git` **directory node is observed and indexed**; only its CONTENTS are
  dropped. The marker is the evidence a directory IS a working tree — it is what
  `Maker::AttachToProject`'s `:in_working_tree` asks the database for — and it exists on all three
  backends, since `chunk_remote` mirrors whatever the desktop client synced. Skip the marker too
  and the intake sweep goes back to filing a repo's root files away by category. Not a fifth
  skip-list wedge: a wedge needs a live node at a path no observation can pair, and the marker is
  observed. `Library::RepoMetadata` owns the one definition — `marker?` (leaf), `marker_prefix`
  (at-or-beneath, what the write guards refuse), `internal?` (strictly beneath, derived from
  `marker_prefix` so the two can never drift about which paths have a marker at all). The port
  refuses `.git` and everything under it as a write DESTINATION on both writable adapters, and
  `ReservedNames` refuses minting it at the doors — `OsClutter`'s law, which is why the write
  guards' contract needs a NEGATIVE case: with only refusals asserted, `rel.include?(".git")`
  passes every test while making `.gitignore` and `.github/**` unwritable.
- **`Node.outside_repo_metadata` hides the marker in BOTH `FilesController#index` scopes**, and it
  goes on the `scope =` assignment, not the `.order` chain — `@match_count`/`@child_count` read the
  same object, so one line lower the truncation banner counts rows the page never renders.

### 14c. Addons and GPL sidecars → **`docs/invariants/addons.md`**

**Read that file before touching** `app/services/maker/addons/`, `app/controllers/tools/`,
`sidecar/`, the addon SDK, or the save door. It holds the GPL-sidecars-over-HTTP rules and the three
shipped bugs behind them, the one output path (`Maker::Addons::LibraryOutput`), the manifest/registry
refusals, the ctx + capability contract and `Host::LEVEL`, the save door's two wire shapes and its
collision rules, the service proxy's content-type allowlist, and the SDK's reject-never-normalize
rules. Moved out of this file on 2026-08-25 because it is *area* knowledge — 540 lines paid for on
every session and needed on few. Nothing was dropped; this anchor stays because code cites `§14c`.

### 14d. The maker web layer

- **Server-rendered Hotwire on `Maker::*` models, session-authed — NEVER the device-token v1
  API.** `/v1/*` is Bearer-token; the web app is cookies. Consequence: web controllers are not
  limited to what the JSON API exposes.
- **The `port_writable?` two-door branch is now written out ONCE** (`Maker::Addons::LibraryOutput`)
  — it was five until Stage 2 gave the chunk family its four metadata verbs and the other four
  callers (`Maker::LibraryFolder#mkdir`, `FilesController#destroy`, `TrashController#restore`,
  `Maker::MoveNode`) stopped branching, because the port started answering instead of refusing.
  **`LibraryOutput` keeps its branch, and it has the argument the other four lacked**: the
  two-phase presigned upload genuinely IS a different flow from POSTing bytes, not the same verb
  behind two doors. A NEW copy needs that same argument. (Excluded on purpose:
  `require_capability!` gates and views that pick an upload FORM — those select a UI, which is
  `port_writable`'s stated job.) **THIS COUNT IS NOT §14c's chunk-internals-reference count** —
  both read "one" until Arc B by coincidence, not identity, the same warning this file gives about
  `scannable`/`port_writable`/`dir_deletable` agreeing on three backends. This one is still ONE;
  the OTHER went to zero when `put_chunk` became a port verb, without touching this branch at all.
- **A verb more than one controller performs gets a named service** — `Maker::MoveNode`,
  `Maker::AttachToProject`, `Maker::LibraryFolder` — rather than being re-inlined per action.
- **NOTHING HERE REACHES `Sync::` AT ALL — the seam guard asserts ZERO, WITH NO ALLOWLIST.**
  `test/architecture_invariants_test.rb` is Ripper-token-checked rather than a `/Sync::/` regex,
  because a regex false-positives on `app/jobs/library/trash_purge_job.rb`'s own operator-facing
  error string, which names "Sync::Gc" in prose with zero real references. The guard once carried
  an exception list (the v1 API, the reaper jobs, `channels/`, and `chunk.rb` itself, which was the
  one sanctioned door); Arc D Part 2 removed the engine from this process entirely, so the
  allowlist went with it and the assertion is now unconditional — **stronger than what it
  replaced, and it must stay that way.** Before Stage 2 the controllers reached into `Sync::`
  wherever the port refused an operation (`FilesController#destroy`, `TrashController#restore`,
  `FilesController`'s own upload flow); the arc that closed it is in the record (§11). The tripwire
  is about **new** work: **if a maker-layer change needs to touch sync, the changelog, conflicts,
  locks, or the mounts, the boundary is wrong — stop** (§14j). A violation fails `bin/ci`.
- **CODEMIRROR IS ONE VENDORED BUNDLE AND EXACTLY ONE IMPORTMAP PIN. Never
  `bin/importmap pin @codemirror/*`.** Two copies of `@codemirror/state` make facets and
  `StateField`s fail to match by object identity, and CM6 responds by **silently ignoring the
  extension** — no error, no console warning, the editor just renders without the feature.
  `test/ci_hygiene_test.rb` fails the build if a per-package pin appears, and asserts it parsed the
  importmap first so it cannot go vacuous. The artifact is built by `bin/build-codemirror` from
  `vendor/javascript/codemirror-entry.js` with **all 40 resolved packages pinned** — pinning only
  the direct ones leaves `@codemirror/state` itself floating, and a build-twice digest check passes
  over that happily, because the registry does not move in two minutes.

- **The file-type vocabulary and the preview surfaces → `docs/invariants/files-preview.md`.**
  Read it before touching `Maker::FileAttachment`'s tables, `app/services/maker/previews/`,
  `FilesController#preview_kind`/`#index`/`#thumbnails`, `app/views/files/`, `thumbs_controller.js`
  or `Node`'s display scopes. **Add an extension in `ROLE_BY_EXT` only** — that file holds why
  (`EXT_RE`, the behavioural `role` column, extensionless text, the thumbnail poll's terminal
  answer, and why dot-file hiding is a display filter and never a scan skip).
- **A `form_with` that is missing `scope:` emits param names the controller's `require`
  rejects — and a nested-hash test cannot see it.** Two shipped instances: `form_with model:`
  on a **namespaced** model scopes to `maker_project[...]` while the controller required
  `:project`; and `form_with url:` with **no `model:`/`scope:`** has a blank `object_name`, so
  `fields_for :task` emitted `name="[task][title]"`, which Rack parses to the **literal key
  `"[task]"`** → `ParameterMissing` → **a hard 400 on every Add since the panel shipped**.
  Note `button_to ... params:` builds hidden inputs *without* the builder, so sibling buttons
  keep working and it reads as a feature quirk. Plain `f.text_field` on a blank `object_name`
  is safe (flat `name="title"`); **`fields_for` is what interpolates brackets**. Both were
  invisible to a green suite because the tests POSTed `params: { x: {...} }` as a Ruby hash,
  which bypasses the form entirely. **Assert the rendered field name.**
- **AN ERB COMMENT ENDS AT ITS FIRST `%>`, SO ONE THAT QUOTES A SNIPPET CONTAINING ONE PRINTS ITS
  OWN PROSE INTO THE PAGE** — and **no `assert_select` in this suite can see it**, because the
  defect produces a TEXT NODE and every assertion here asks about ELEMENTS. Shipped once, in
  `files/_ext_filter.html.erb`; three lines of a code comment sat in the middle of the Files page
  through a fully green run and were found by opening the page. Never write `<%= … %>` or a bare
  `%>` inside a `<%# … %>`; describe the wrong spelling in words. Guarded on the RENDERED OUTPUT by
  `test/integration/web/template_hygiene_test.rb` (a static template scan was tried first and is
  weaker — it has to guess whether the text after a terminator was meant to be markup or prose).
- **A `data-controller` NAME THAT RESOLVES TO NOTHING IS A SILENT NO-OP, SO DELETING A STIMULUS FILE
  CAN DELETE A FEATURE WITH NOTHING ANYWHERE GOING RED.** Stimulus neither throws nor warns on an
  identifier it cannot resolve — the page renders perfectly and the behaviour is simply absent. Two
  deleted controllers left the openscad editor opening on an empty grey preview panel for **nine
  days**, while its request test stayed green throughout: a request test proves the endpoint works
  and nothing about whether the only thing that CALLS it has gone inert. Guarded by
  **`test/stimulus_hygiene_test.rb`**, which DERIVES every registered identifier from the filenames
  by replicating stimulus-loading's own rule rather than listing them (a new controller needs no
  test edit), and sweeps **both** spellings — `data-controller="a b"` (several names per attribute)
  and the Rails `data: { controller: "a" }` hash, which a literal-attribute grep misses. The reverse
  direction — a controller file no view names — is deliberately NOT an error. `data-controller` is
  the COMPLETE set, not merely the convenient one: Stimulus resolves `data-action` and
  `data-*-target` only for a controller attached through it.
- **`back_target_path` COMPARES THE REFERER'S ORIGIN AND THEN DISCARDS IT** — only a root-relative
  path ever reaches an `href`, so a cross-origin referer is DROPPED, never sanitised and re-emitted.
  Do not "improve" it into accepting a URL param: the referer is chosen precisely because a file
  page has seven entry points and a param would be seven call sites that must agree plus an eighth
  that silently reverts to `files_path`. A referer equal to the current page must keep falling back —
  notes and move conflicts both redirect to the page they came from.
- **A DELETED FILE IS HIDDEN FROM A PROJECT IMMEDIATELY AND ITS ROW DESTROYED ONLY AFTER THE GRACE
  WINDOW, AND THE ASYMMETRY IS THE POINT.** `Library::Reconciler` tombstones rather than destroys, so
  a tombstone is one undo away from returning with the **same `node_id`** — which is what every
  attachment, BOM link and tag is keyed on. Hiding is reversible, so `ProjectsController#show` does it
  at once; destroying is not, so `Maker::AttachmentReaper` waits. Collapsing the two — destroying on
  sight — turns "restore from Trash" into "restore, then re-file it into every project by hand".
  `Maker::DeadNodes` owns the one definition of `reapable?`, shared with the preview reaper; its index
  reads `user.nodes`, **NOT `.present`**, because a tombstone is exactly what tells "revivable" from
  "gone for good" and filtering it out reaps every tombstone with no grace at all.
- **A `*_belongs_to_user` VALIDATION GUARDED ON `if: <fk>.present?` MAKES A DANGLING ID LOCK THE
  WHOLE ROW, SO EVERY REFERENCED MODEL NEEDS A `dependent:` — AND `:nullify` IS THE WRONG ONE FOR
  `Maker::BomLine#inventory_item_id`.** A dangling id *is* present, so the check runs on every save
  and refuses edits to unrelated fields; `Supplier`→items/bom_lines and `Location`→items therefore
  nullify. A BOM line cannot: `exactly_one_target` then sees no target and refuses the row anyway —
  the identical permanent lock with a different message — so `InventoryItem#release_bom_lines`
  copies the item's name into `part_name` (and its supplier, where the line names none and that
  supplier still resolves — copying a *dangling* one recreates this very lock on the row just
  rescued) and only then drops the pointer. Never "tidy" that callback into a `dependent:` on the
  association; the statements must run in that order, and the name is unrecoverable one moment
  later. **The targetless filter tests `[nil, ""]` and BOTH ARMS ARE REACHABLE** — the API accepts a
  create carrying a blank `part_name`/`node_id` beside an inventory item, because
  `exactly_one_target` counts with `present?` — so narrowing it to `nil` converts that line to
  nothing and locks it. The whole method is user-scoped, unlike the *association-level* nullifies on
  Supplier/Location, because it writes this user's data into a row: clearing a pointer can only
  repair an illegal cross-tenant reference, whereas writing a name into someone else's row would
  disclose one.

### 14e. Architecture and process

- **A remote-mounted filesystem does NOT work over the WAN.** rclone/JuiceFS mount =
  synchronous metadata round-trips → ~1 s/file (Phase 0, measured). Every production system
  uses **local metadata + async sync + on-demand hydration**. That pivot is the whole reason
  this architecture exists, and it is why `chunk_remote` mirrors rather than asks (§2). Do not
  go back to a remote mount. (`docs/roads-not-taken.md`; JuiceFS itself was abandoned for chatty
  WAN metadata, no internal ACL, and FUSE-driver licensing.)
- **Edge-SQLite (Cloudflare D1, Turso) can't back a mount** — no driver + chatty-metadata
  latency. They *would* fit the coarse-manifest model, but we use Rails + Postgres/SQLite to
  stay self-hostable (D1/DO are Cloudflare-locked → break self-host).
- **The sync model makes multi-tenancy SIMPLE** (coarse API + `user_id` scoping) — the
  opposite of the mount model's credential gymnastics. Tenant = user for v1.
- **Permissive licensing is a hard constraint** (§9).
- **DB: Postgres managed, SQLite self-host, one adapter-agnostic codebase.** No PG-only SQL in
  the hot path.
  **`User#next_seq!` SURVIVES HERE WITH NO CALLER IN THIS APP, AND THAT IS NOT DEAD CODE TO
  SWEEP.** `users.head_seq` is still served to a joining device by `V1::DevicesController` as
  its starting changelog cursor. The method's lock-ordering rule — take `FOR UPDATE` on the user
  row FIRST, before any FK insert takes `FOR KEY SHARE`, or two concurrent commits deadlock on
  the upgrade — governs the sync server's commit path and lives in **that repo's** CLAUDE.md now.
  Its five callers are all there. Do not reintroduce that rule, or a pooler boot guard for it,
  here: nothing in this process takes the lock. (`lib/postgres_pooler_check.rb` is gone; a
  comment in `app/models/user.rb` still points at it and at `Sync.engine_present?`, and is stale.)
  **A statement-mode pooler still breaks the sync server** — that constraint did not disappear,
  it relocated.

- **`config.active_storage.variant_processor = :disabled`, and it must stay that way.**
  `load_defaults 8.1` sets it to `:vips`, which loads `ImageProcessing::Vips` → `ruby-vips` at
  boot. This app deliberately ships **no `ruby-vips`**: every thumbnail shells out to the
  `vipsthumbnail` BINARY, precisely so there is no in-process libvips thread pool to deadlock the
  fork-based parallel test runner. That was silently inert until activestorage **8.1.3.1** (the
  CVE-2026-66066 fix) added an eager `require "image_processing/vips"`, whose LoadError message
  ("ImageProcessing::Vips requires the ruby-vips gem") matches **neither** arm of the engine's own
  `rescue` (`/libvips/`, `/image_processing/` — note the underscore), so it re-raised and **took
  the whole boot down**. `:disabled` is the engine's supported answer and removes that CVE's code
  path STRUCTURALLY rather than leaving it merely unreachable by argument. **Do not "fix" this by
  adding `ruby-vips`** — that reintroduces the deadlock the subprocess design exists to avoid.
- **Server presigning is local** (HMAC) — you can verify chunk URLs without the storage being
  reachable.
- **`database.yml`'s `timeout:` IS A PRODUCTION SETTING AND A CONCURRENCY CEILING, NOT A TEST KNOB.**
  It sits in the `default: &default` anchor, so **self-host SQLite inherits it**, and it is how long
  a writer waits for SQLite's single write lock. Raised 5000 → **15000** on 2026-08-20 after §12.7
  was diagnosed: the failure is a stalled **fsync**, not bad lock logic, so the waiter raises while
  nothing is actually wrong. **Do not raise it further as a reflex** — production runs
  `RAILS_MAX_THREADS: 16` on one Puma worker, so 16 requests can each sit here for the full wait and
  occupy every thread, the same head-of-line argument §14c makes for `ADDON_SERVICE_MAX_TIMEOUT`.
  15 s covers an fsync stall; if writes still time out the answer is fewer concurrent writers or a
  faster disk. **`PRAGMA busy_timeout` reads 0 and that is EXPECTED** — Rails applies it through
  the gem's `busy_handler_timeout`, which has NO READER, so only behaviour proves the setting took
  effect: `test/sqlite_concurrency_test.rb` times a blocked writer, and pins WAL + IMMEDIATE too.
- **A FAKE THAT SHARES THE CODE'S MISUNDERSTANDING CONFIRMS IT.** `FakeS3` decoded
  `copy_source` with `CGI.unescape` while the adapter encoded with `CGI.escape` — exact
  inverses, so **79/80 tests were green** over **silent permanent data loss on any filename
  with a space** (form encoding turns `Bracket v2.stl` into `Bracket+v2.stl`; real S3 reads
  `+` as a literal plus, so the copy read a nonexistent key and the delete removed the right
  one). Fixed with per-segment `ERB::Util.url_encode`. **Assert the WIRE format, not the
  round-trip**, and mutation-check a guard by reverting the code it guards. Watch for this
  shape wherever a fake and the code under test share an assumption.
- **Checking beats reasoning.** A final whole-branch review found five real bugs of which
  **four were already recorded as unreachable, deferred, or verified** — the contribution was
  *probing*, not thinking. Corollary: **a stale open-list is worse than none**, because it
  spends the next reader's attention on finished work — **and in the other direction it hides
  unfinished work behind a row that says done**, which is how the 2026-08-19 audit's own ledger
  came within one `git branch -D` of destroying a fix it had recorded as landed (§15).
- **A REFERENCE COUNT IS NOT A COUPLING COUNT.** The "68 of 224 references" figure that deferred the
  chunk retirement twice (§12.12) was the wrong number to plan from: **36 of 43 app-side and 11 of
  68 test-side hits were PROSE**, and the real coupling was 7 wiring sites and 57 test files, 60 of
  whose references sat in one file that was then deleted. Grep, then read what you counted.
- **The suite being green is not evidence a guard works** if the guard's precondition is
  never established in test (see the `STORAGE_BACKEND` 500 in §14a, and the form `scope:` bug
  in §14d). Drive the real request.
- **A SECURITY GATE REPORTS ON THE CODE, NEVER ON HOW CURRENT THE SCANNER ITSELF IS.** The Rails
  scaffold's `bin/brakeman` unshifts `--ensure-latest`, so `bin/ci scan` exited **5/1 with zero
  warnings and no code change** the day brakeman cut a release — and §15 makes a red `bin/ci` block
  every PR, so an upstream release stopped all work until someone bumped the pin, which the next
  release re-breaks. Offline it does not even fail cleanly: `Gem.latest_spec_for` returns nil and
  ensure_latest raises `NoMethodError`. Gem freshness belongs to **Dependabot** (already weekly),
  off the critical path. A binstub that injects flags is also a **second, invisible definition of a
  gate** that `config/ci.rb` claims to define alone. `rails app:update` will offer the line back;
  `test/ci_hygiene_test.rb` refuses it, and refuses any other injected argument.
- **A SOLID STORE IS NOT WIRED UNTIL `config.<x>_store` SAYS SO.** Solid Cache shipped with its
  gem, `config/cache.yml`, a `cache` role in `database.yml`, `db/cache_schema.rb` and a
  persistent volume — and `config.cache_store` left at the Rails scaffold comment, so production
  resolved to a `FileStore` in the container's `tmp/`, wiped every deploy. Queue and Cable were
  wired; the third was missed while §4 claimed all three. **Resolve it by running
  `Rails.application.config.cache_store`, not by reading the file.**
- **THIS APP IS NOT A BROADCASTER** — no channel, no subscriber. Deleting the `mount` from
  `config/routes.rb` does **not** remove `/cable`: ActionCable's engine re-prepends it from
  `mount_path` in an `after_initialize`. A device's nudge is `tinkerex-sync`'s. `test/cable_absent_test.rb`.
- **RATE LIMITING COUNTS IN A CACHE, AND `NullStore#increment` RETURNS NIL.**
  `ActionController`'s `rate_limiting` is `count = store.increment(...)` then
  `if count && count > to`, so a throttle backed by the test env's default store fires **never**
  — a rate-limit test then fails for the wrong reason, and a "normal requests still work" test
  passes whether or not the throttle exists. `config.action_controller.cache_store` is the knob
  (real store for limits, caching still off). **Counters key on `request.remote_ip`, which is
  127.0.0.1 for every integration test**, so `test_helper.rb` clears them per test — without
  that, one worker's budget is spent across its whole suite and unrelated tests fail as
  `302 → /users/sign_in`.
- **A CSP HEADER THAT PARSES IS NOT A CSP THAT WORKS — only a browser knows.** Two defects
  shipped past every integration test and were caught by the system tests' SEVERE-console check:
  an empty `'nonce-'` (`session.id` is nil before a session exists, so anonymous pages made
  Chrome **discard the whole `script-src` directive**), and `frame-ancestors 'none'` contradicting
  the app's own same-origin PDF iframes. Ship a policy **report-only** first, and keep
  `frame-ancestors` consistent with `X-Frame-Options` (`SAMEORIGIN` → `'self'`).
- **`assert_select "[attr=?]", /regex/` DOES NOT REGEX-MATCH — it builds an EQUALITY selector and
  can never pass.** rails-dom-testing's `SubstitutionContext#matcher_for` interpolates a Regexp
  straight into the selector (`"\"#{value}\""`), so `[title=?]` with `/Needs a newer…/` compiles to
  `[title="(?-mix:Needs a newer…)"]` and matches an attribute whose literal text is that. Regex
  matching on an **ATTRIBUTE** needs the gem's own `:match('attr', ?)` pseudo-class; `[attr*=?]`
  with a plain String is the simpler alternative. (`text: /…/` is a different code path and does
  match — this is about attributes only.) Verified against rails-dom-testing **2.3.0**: `[title=?]`
  finds 0 elements where `:match('title', ?)` finds 1. It fails as a test that **can never go
  green** rather than as a false green — the better direction, but only once you know why.
- **Query cost is a property nothing asserts unless you assert it.** `projects#show` went from
  flat to +1 query per build-log entry when rich text arrived and the eager load was not extended
  — invisible to a green suite, while `models#show` carried the correct pattern the whole time.
  Guards live in `test/integration/web/page_query_budget_test.rb` and assert **constancy in N**,
  never a literal: the counts differ per `LIBRARY_BACKEND`, so a literal pins one leg and fails
  the other two.
- **AN APP MUST NOT POINT A SYNCHRONOUS HTTP CLIENT AT ITSELF.** Serving addon bundles from this
  app's own `public/` over `ADDON_SOURCE_URL` made every asset fetch a **nested** request into the
  same Puma pool already servicing the outer one — reentrancy, not just extra load. Measured, not
  theorized: one bundle's module graph against a stock 3-4-thread dev/Capybara pool stalled most
  requests **14-24 seconds** and several outright **404'd**, `Net::HTTP`'s read timeout firing
  before a thread ever freed up. Fixed by `ADDON_SOURCE_PATH` (`Maker::Addons::Source::Local`),
  reading `public/addons` off disk in dev/test; `ADDON_SOURCE_URL` stays for the genuinely separate
  static container, which has its own pool and is structurally immune. A smaller effect alongside:
  even `Source::Local` needs more than Puma's stock `threads 3, 3` in a real `bin/rails server`,
  because `config.enable_reloading = true`'s per-request interlock adds overhead that several
  near-simultaneous asset requests expose — `RAILS_MAX_THREADS=16` fixed it; production and the
  test env don't carry it.
- **A GUARD THAT SKIPS ON THE THING IT ASSERTS IS VACUOUS.** A boot test that skipped when
  `defined?(Sync)` meant the mutation which loaded the engine skipped every test and reported
  **success**. Skip on whether the leg was **invoked**, so absence is the claim rather than the
  precondition. Found by mutation-checking, not by reading.
- **A GUARD THAT SCANS A DIRECTORY DIES SILENTLY WHEN THE DIRECTORY LEAVES.** Two architecture
  guards were `assert_empty offenders` over a glob of `engines/tinkerex-sync/**`; the extraction
  made that glob `[]`, which satisfies `assert_empty` perfectly, so "the sync engine never reaches
  into the maker layer" went on **passing over nothing** — its sibling failed only by luck, because
  its stale-exception check happened to name a file that had ceased to exist. **Assert the scanned
  set is NON-EMPTY before trusting what it reports.** This generalises past the extraction: any
  guard whose subject is a path can be silently retired by a move.

### 14f. Project-folder intake → **`docs/invariants/project-intake.md`**

**Read that file before touching** `app/services/maker/project_intake.rb`,
`app/services/maker/project_discovery.rb`, `app/services/maker/attach_to_project.rb`,
`app/services/maker/project_folders.rb`, `app/jobs/maker/project_intake_job.rb`,
`app/jobs/maker/project_discovery_job.rb`, or `Library::ScanJob`'s post-reconcile sequence. It
holds both halves of the feature: **Discovery** — a folder dropped directly under `Projects/` with
no claimant becomes its own project, the statelessness and dismissal rules, the two caps, the
can't-fail slug, and why `#place` resolves under the folder's own node rather than a path rebuilt
from the slug — and **Filing** — the sweep that attaches and files what is loose at a project
folder's root: the seven doors it must cover with one reader instead of a hook per door, the two
collision checks (409 vs 422), the eager-nudge and changelog-pull triggers, and the ScanJob
ordering that makes a race a correctness bug rather than a timing quirk. Moved out of this file on
2026-08-26, together with the new rules the discovery feature earned — 245 lines total that bind
only inside project intake. Nothing was dropped; this anchor stays because code cites `§14f` — 32
references across 22 files in `app/`, `lib/` and `test/` (`grep -rl '§14f' app/ lib/ test/`).

### 14g. Deploy secrets → **`docs/invariants/deploy-secrets.md`**

**Read that file before touching** `.kamal/secrets*`, `bin/secret`, `bin/secrets-preflight`,
`config/deploy*.yml`, or an accessory's env. It holds why the preflight is not optional (kamal
cannot notice an unreadable secret), the per-destination rule, what may live in `secrets-common`,
the redirection-order leak, and the accessory-secrets rule. `docs/DEPLOY.md` is the operator
companion. Nothing was dropped; this anchor stays.

### 14h. Shape measurement, the Measure view → **`docs/invariants/measure-view.md`**

**Read that file before touching** `app/services/maker/previews/`, `Maker::Previews::Geometry` and
the four formats that feed it, `measure_controller.js`, `lib/print_sheet.js`, or anything that reads
a `maker_previews` row. It holds the per-format `PAYLOAD_REVISION` arithmetic, the
`available?`/`available_for?` split, the flattening and thinning rules (measure before thinning), the
circularity floor, the preview staleness axes, Z-up, and the print sheet's mm-scale mechanism.
Moved out on 2026-08-25 — 351 lines that bind only inside the preview stack. Nothing was dropped;
this anchor stays because code cites `§14h`.

### 14i. Backup and restore → **`docs/invariants/backup-restore.md`**

**Read that file before touching** `ops/backup-db.sh`, `bin/backup-db`, `bin/restore-db`,
`bin/backup-status`, or `bin/backup-cron-install`. **Nothing in `bin/ci` can go red for any of it** —
it is shell, cron and docs, and the shared failure mode is *you find out when you need a restore*.
The single-site rules live inside `ops/backup-db.sh` itself; that file carries the cross-file ones,
including the unencrypted-archives decision. Nothing was dropped; this anchor stays.

---

### 14j. The maker/sync boundary

> **THE BOUNDARY IS A NETWORK, NOT A NAMESPACE (2026-08-25, Arc D Part 2 — §12.12).** This
> section used to run to 286 lines describing a boundary enforced by static analysis, back when
> the sync engine was a **gem in this process**: guards counting `Sync::` references, a capability
> seam so the engine named no host constant, a byte-identical schema check across two repos, a
> `require: false` gem loaded only when `engine_wanted?`. **None of that machinery exists here any
> more.** The engine is not a dependency; `Sync::` is undefined; `bin/ci`'s seam guard asserts
> ZERO references with **no allowlist**, which is stronger than anything those exception lists
> could express.
>
> **The engine-side rules moved to `chaim354/tinkerex-sync`'s own CLAUDE.md** — `isolate_namespace`
> and the `sync_` table-prefix trap, the route drawer, `Sync::Hooks`, host obligations, the dummy
> app, refcount GC and `next_seq!` ordering. Do not re-derive them here; if you need one, you are
> working in the wrong repo.
>
> **What couples the two repos now is the WIRE**, and what checks it is `bin/ci test-chunk-remote`
> here (the full suite against a booted sync-server host app) plus the conformance corpus there.

Four rules survive on **this** side of the boundary:

- **A BUNDLED RUBY PROCESS THAT SPAWNS A SECOND RAILS APP MUST STRIP `BUNDLE_GEMFILE`/`RUBYOPT`
  FIRST, OR THE CHILD SILENTLY BOOTS AGAINST THE WRONG GEMFILE.** `bin/ci` (via `config/boot.rb`'s
  `require "bundler/setup"`) sets `BUNDLE_GEMFILE` to THIS repo's Gemfile and a `RUBYOPT` that
  force-requires `bundler/setup`, **process-wide** — every child inherits both. A second Rails
  app's own ordinary `config/boot.rb` does `ENV["BUNDLE_GEMFILE"] ||= …`, and `||=` means the
  INHERITED value wins. Reproduced directly: exporting those three and nothing else turned a working
  `POST /v1/admin/libraries` into a bare 404 on an otherwise-identical boot, while `/up` and
  `/v1/devices/whoami` kept answering — the two locked versions are close enough to boot either way,
  and ROUTE DRAWING was where they had diverged. `bin/sync-server`'s `unset_inherited_bundler_env`
  clears `BUNDLE_GEMFILE`/`BUNDLE_BIN_PATH`/`BUNDLE_LOCKFILE`/`BUNDLER_VERSION`/`BUNDLER_SETUP`/
  `RUBYOPT`/`RUBYLIB` — deliberately **not** `PATH`/`GEM_HOME`/`GEM_PATH`, which is how the shell
  finds `ruby` at all. **This protects only `bin/sync-server`.** The next script shelling out to a
  second bundled Ruby process from inside a `bin/ci`-launched one gets no protection and hits the
  identical failure: silent, plausible-looking, invisible until the lockfiles drift.
- **`V1::BaseController` STANDS ON `ActionController::API`.** It briefly inherited the engine's
  base controller so the fourteen `v1/maker/*` controllers rode the engine's v1 infrastructure — a
  superclass resolves when the class body loads, so with no engine this app's own API had no base
  class and could not eager-load. It deliberately does **not** include a capability gate: checked,
  not assumed — no controller under `app/controllers/v1/` calls `require_capability!`.
- **`Device` IS HOST-OWNED AND STAYS HERE.** Its token is the ONLY credential the whole v1 API
  accepts, including all fourteen `v1/maker/*` controllers, so an app that did not own it could not
  authenticate its own API without the sync server reachable. The sync server carries its own
  `devices` table; the two are separate populations joined only by the per-user
  `users.sync_device_token` (§8).
- **DEVICE AUTH IS DUPLICATED ACROSS THE TWO REPOS BY STRUCTURAL NECESSITY.** Neither side can
  require the other in the case that matters. There was a parity test comparing the two method
  bodies while they shared a process; it went with the extraction, and **nothing checks that
  agreement now.** If you change device-token verification here, change it there in the same
  breath — that obligation has no guard behind it.

### 14k. The model catalog and shelves → **`docs/invariants/model-intake.md`**

**Read that file before touching** `app/services/maker/model_intake.rb`, `app/models/maker/model.rb`,
`app/models/maker/item.rb`, `app/models/maker/shelf.rb`, `app/services/maker/library_tree.rb`,
`app/controllers/shelves_controller.rb`, `app/jobs/maker/model_intake_job.rb`, or the
`origin`/`auto_node_id`/`dismissed_at` columns on `maker_models`. Nearest-shelf; a shelf is a PATH and a
model a NODE ID; dismissing is not deleting; ScanJob ordering; `LibraryTree#path_for` cycle-guard/memo
rules (now binding `FilesController`/`Tools::LibraryFolders`); and why Model and Item are TWO catalogs.

### 14l. Editing, committing and history in a repository → **`docs/invariants/git-editing.md`**

**Read that file before touching** `app/services/maker/git/`, `app/services/library/working_tree.rb`,
`app/controllers/repo_{commits,histories}_controller.rb`, `FilesController#update`/`#history`/
`#restore`, the `editor`/`diffview`/`history` Stimulus controllers, or `test/support/git_repo_fixture.rb`.
Eighteen rules there; the ones most often undone: bytes the catalog tracks go through the port and
bytes git owns never do; ask `local_worktree?`, never an adapter class; `index.clear` is never
written; content against HEAD's blob, never a stat; a `.lock` is refused, never deleted; the history
walk is ALWAYS capped and `stopped` reaches the view; restore writes a pending edit, never a commit.

## 15. Working agreements for the coding agent

- Permissive licenses only (§9); check new deps.
- **Keep bytes out of Rails** — presigned URLs, control plane only.
  **Active Storage's `direct_uploads` route is REMOVED**, because it was the one standing hole
  in this: `ActiveStorage::DirectUploadsController` descends from
  `ActiveStorage::BaseController`, **not** `ApplicationController`, so it shipped live and
  **unauthenticated** — an anonymous POST minted a real `Blob` and returned a signed upload
  URL. `config/routes.rb` shadows it with a 404. **The shadow path derives from
  `ActiveStorage.routes_prefix` and must never be hard-coded** (the engine scopes its own
  routes to that prefix, so a literal silently stops shadowing if it is ever configured), and
  `draw_routes = false` is NOT the fix — `Maker::Preview` uses `has_one_attached :asset`
  served via `url_for`, so the blob routes are load-bearing. Verify by driving a real request:
  `recognize_path` reports the engine's route for a proc endpoint and is the wrong instrument.
  Rich text is text-only on the server too (`Maker::TextOnlyRichText`), not just in the editor.
- **Local-first**: metadata reads hit local tables, never the WAN (§2, §14a).
- Adapter-agnostic server code (SQLite + Postgres) without perf compromise.
- **Versioning and restore are the sync server's** on `chunk_remote`; share and s3 are
  current-state only, deliberately (§14a). Do not add a version table here.
- **MUTATION-CHECK EVERY GUARD YOU WRITE.** After a test that exists to *forbid* something goes
  green, break the thing it guards and confirm it goes **RED** — then restore. A guard that has
  never failed has not been shown to work. This is the cheapest defence against this repo's
  dominant failure mode, **a green suite over something that never worked**: the `scope:` form bug
  twice, the nine capability-gating tests that *could not fail for the reason they existed*,
  `FakeS3`'s inverse encoding (79/80 green over silent data loss), and the sidecar-licence guard
  whose discovery filter skipped the worse case. Every time someone did mutation-check, it paid
  immediately. `bin/ci` is ~40 s, so there is no budget argument.
  **Assert the narrowest true thing, then mutate to prove each assertion carries weight** — in
  `ArchitectureInvariantsTest`, a mutation that keeps the count at 1 while *moving* the reference
  is caught only by the second assertion; count alone would have passed.
  **A TIMESTAMP COMPARED AT `.to_i` IS A GUARD THAT USUALLY CANNOT FAIL** — a recurring near-miss,
  twice in one arc (2026-08-13). `.to_i` is whole **seconds**, and the row you are asserting about
  was written in the same second as the thing you fear overwrote it, so the mutation stays green.
  Two fixes, both cheap: separate the two events in time (`travel_to(3.days.ago)` around the setup,
  so a `now()`-style regression fails by three orders of magnitude instead of by nothing), or assert
  a **content** column that is nil until something writes it rather than a timestamp at all.
- Write tests; prefer a **probe over an argument** — §14e.
- **Do not add sync-engine or desktop-client knowledge to this file.** If a change here needs to
  reason about how the changelog is built, how commits are sequenced, how chunks are refcounted, or
  how a mount adapter works, the boundary is wrong — stop, and check whether the work belongs in
  `tinkerex-sync` or `tinkerex-client` instead (§3, §14j).

- **EXECUTING A PLAN WITH SUBAGENTS: `.claude/commands/execute-plan.md` IS THE DEFAULT AND
  OVERRIDES ANY GENERIC SUBAGENT-DRIVEN LOOP A SKILL OFFERS.** Read it before dispatching; you do
  not need to be asked. Batch by FILE, run independent tasks in PARALLEL, no spec-compliance stage,
  and CAP each quality review to named claims — quality reviews themselves stay FULL-DEPTH. That
  file carries the measurements, and `/execute-plan` is the same content if you prefer to invoke it.

### Finishing work: commit, push, and open the PR without asking

On a **`claude/*` or other non-default branch**, when the work is complete and the gates are
green, **commit, push, and open a PR — do not stop to ask.** That is standing authorization;
treat it as the default close-out for a task, and use `/finish-branch` to run it.

- **Green means bare `bin/ci`** — every gate `bin/ci --list-ci` names, not a hand-copied list
  here. (This bullet itself carried a stale list for a while: it named a `test-share` gate that
  does not exist and excluded `test-chunk-remote` from the rule below, contradicting both §13 and
  `config/ci.rb`'s own comment. Read the tool, not the prose.)
- **The three backend legs are `test` (share), `test-s3` and `test-chunk-remote`, and all three
  must report identical run counts.** `test-chunk-remote` is included *because* it runs the full
  suite — `config/ci.rb` says so in as many words: there is no in-process chunk backend any more,
  so if it ran less, **the primary deployment's backend would be the only one without full
  coverage.** It needs `../tinkerex-sync` checked out (§13).
  **`bin/ci` PRINTS the three counts and never COMPARES them** — the rule has always relied on a
  human reading them, and `tinkerex#131` records a small pre-existing flap (±2
  assertions, ±1 skip) that varies between runs of the *same* leg, so it is nondeterminism rather
  than a backend dependency. A ±2 difference is the known flap; a structural one means a test
  depends on the ambient `LIBRARY_BACKEND` and is a real bug.
- **Merging always needs an explicit go-ahead.** Never merge, never `--admin`-merge, never
  push to `main`.
- If the gates are red or the work is partial, **stop and report** — do not open a PR to
  "get it reviewed".
- State plainly in the PR what was verified and what was not.
- **THE ARC'S RECORD IS PART OF THE WORK, FILED AS THE PR OPENS — never a tidy-up afterwards.**
  `bin/log arc --from-pr <n>` after `gh pr create`, then **`bin/log close <n>` at merge — an arc
  NEVER closes itself**: the PRs are on GitHub, the record is a self-hosted Kaneo, nothing bridges
  them (`tinkerex#154` merged and deployed with its arc still open). Deferred, it does not happen: a
  feature ran to eight merged PRs while its record described the algorithm the second had deleted —
  and it is cheapest written while the numbers are in front of you, which a later pass reconstructs
  badly. **The arc IS the PR body**, one command. One arc is one issue; a correction is `note`.
- **THE DEPLOY-RECORD EXCEPTION TO "never push to `main`" IS GONE, AND THAT IS A SIMPLIFICATION.**
  It existed because a deploy happens AFTER the merge, so its record could not live in the work's own
  PR, and a follow-up PR per deploy is the deferral this rule forbids. `bin/log deploy --image <sha>`
  files an issue instead — no file, nothing to commit, nothing to push. **There is now no sanctioned
  path that writes to `main` directly.**

### CI

- **CI runs on SELF-HOSTED runners only — never GitHub-hosted.** Every job uses
  `runs-on: [self-hosted, linux|macos|windows]`. GitHub bills *only* hosted runners
  (`ubuntu/macos/windows-latest`; macOS 10×, Windows 2×); self-hosted are **free**. So
  **never add `*-latest`** to a workflow.
- **RUNNERS ARE REGISTERED PER REPOSITORY. THIS REPO'S ARE FOUR LINUX CONTAINERS ON THE UNRAID
  BOX** — `ci/runner/Dockerfile` + `ops/ci-runner-stack.yml`, on Docker host **192.168.1.146**
  (not .7 = NPM, not .95 = the Kamal VM). Measured 2026-08-31 via
  `gh api repos/:owner/:repo/actions/runners`: `tinkerex-unraid-1..4` online, labels
  `[self-hosted, Linux, X64, maker-unraid]`. CI was a developer's own MacBook, one job at a time,
  until then, and the siblings still are. **Re-measure rather than trusting this** — hence the date.
  Needs an **admin-scoped** token; `administration` is not grantable to a workflow `GITHUB_TOKEN`,
  so it **403s from inside Actions**.
- **`ci.yml`'s jobs target `linux`, and it is the ONLY workflow here** since the cross-repo suites
  left (2026-08-25). `linux` is the family `preflight` itself runs on, so it is the circular case
  `test/ci_hygiene_test.rb` exempts — **keep the `CI_RUNNERS`/`ci/preflight.sh` mechanism anyway**:
  it fixed a five-week outage and the failure it prevents is silent. A job matching no online runner
  does **not** fail — it queues 24 h at 0 elapsed, is auto-cancelled, and the PR sits UNSTABLE. Any
  future macos/windows job MUST be `needs: preflight` + `if:`-gated; the guard **derives** the
  exempt family from preflight's own `runs-on` rather than naming one. **Windows coverage is
  skipped, not passing.**
- **`ruby/setup-ruby` must NOT appear in a job that could be the Mac** — it assumes a hosted
  `/Users/runner` layout. The guard exempts a job whose labels prove otherwise, so a `linux` job may
  use it; none does, because the image bakes mise ruby 3.4.7 matching `.ruby-version`.
- Self-hosted machines are persistent: make dep-install steps idempotent (`config/ci.rb`'s review
  found **334 accumulated `tmp.*` directories** on the mac runner). On Unraid it binds on DISK too:
  `/var/lib/docker` is a **50 GB loop** whose exhaustion takes down every container on the box, so
  work dirs are bind-mounted to the array and an image rebuild must `docker builder prune -af`.

### Keeping the docs honest

- **THE RECORD (§11) is where an arc gets narrated. This file is not.** Add dates, branch
  names, suite counts and per-phase detail there.
- **What belongs HERE is an invariant** — something a future editor could undo by accident.
  Put it in §14, one line, with the consequence named. If it needs a paragraph of story to
  justify, the story goes in STATUS.md and the rule comes here. **This rule was systematically
  broken and then enforced:** on 2026-08-25, 49 of §14's 211 bullets carried their own case history
  and occupied 672 lines — 36% of §14 — and eight of nine sampled evidence figures were ALREADY in
  STATUS.md, so it was duplication rather than unique content. Write the rule; link the story.
- **AN INVARIANT THAT BINDS ONE AREA GOES IN `docs/invariants/<area>.md`, WITH A STUB UNDER ITS §14
  ANCHOR.** Not a demotion — the point is that a rule is loaded when it APPLIES instead of skimmed
  on every session that never touches it, and the stub names the paths that should send a reader
  there. **Keep the §14 anchor whatever you move**, because code cites sections by number and a
  citation resolving to nothing is worse than a long file. `test/docs_hygiene_test.rb` fails if a
  stub loses its file, a file loses its stub, or this file passes its line ceiling — and the
  ceiling is a **ratchet**: lower it as the file shrinks; argue in review before raising it.
- **AND IT MUST BE AN INVARIANT OF *THIS* REPO.** A rule about the sync engine or the desktop
  client goes in that repo's CLAUDE.md, however hard-won it was here. This file is loaded on every
  session; a rule nobody working in this repo can act on is pure tax. (Both sibling files carry an
  explicit "inherited, not audited" header — if you verify a section there, rewrite it and drop
  the warning for that section.)
- Update this file **and** file the arc when the architecture moves — **in the branch that
  moves it**, per the close-out rule in §15. A record written later is written from
  memory, and the measured numbers that make one worth reading are the first thing lost.
- **A DOC ROW THAT NAMES A COMMIT IS A CLAIM, AND NO GATE CAN CHECK IT — `bin/verify-fix-log`.**
  Nothing in `bin/ci` reads a ledger row, so a row is only as true as the moment someone wrote it.
  The 2026-08-19 log was wrong about its own contents three times while being right about the code:
  a row recorded **LANDED** naming a SHA that belonged to a **different fix** (the work existed only
  on an unmerged branch, and a `-D` sweep would have destroyed it with nothing going red); a row
  still reading **NOT FIXED** after the fix merged, because the prose was updated and the table was
  not; and **13 of 68 references** pointing at pre-cherry-pick SHAs that are not on `main`, three of
  them unresolvable once the source branches were deleted. **Run it while writing or amending a
  ledger** — that is when all three were made. It is deliberately not a gate: it reads a dated
  snapshot of finished work, so gating it would check frozen history on every PR forever.
  **Verify a commit reference the way you verify a guard, or it is decoration.**
