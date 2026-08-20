# Design: separating the chunk system into its own repo and project

> **Status:** DESIGN. 2026-08-20. Branch `claude/chunk-version-repo-separation-8c3d4c`.
>
> **One-liner:** The sync engine becomes a standalone product in its own repo, and the
> maker app keeps it as **one of four** pluggable storage backends — embedded or remote.

---

## 0. Goal

All four of the following, in one arc, staged so each stage ships alone:

1. **Sellable standalone** — the sync engine runs without the maker app: own deploy, own DB.
2. **Cut the weight** — 36k lines of Rust and four CI workflows leave the maker repo.
3. **Independent release** — ship maker without redeploying sync, and the reverse.
4. **Clean boundary** — the maker/sync seam is enforced, not a convention that leaks.

(1) is the binding constraint and subsumes the rest. (4) is delivered early, by Stage 2,
rather than deferred to the end.

---

## 1. What is actually coupled

Measured, not assumed.

**Tables.** Only `Sync::*` ever writes `versions`, `chunks`, `manifest_chunks`,
`changelog_entries`, `pending_commits`, `conflicts`, `file_locks`, `devices` — eight
chunk-only tables. `Library::Reconciler` writes `nodes` directly and mentions `Sync::`
only in comments.

| | Tables |
|---|---|
| Chunk-only | the eight above |
| **Straddler** | `nodes` — all three backends populate it; 24 maker files key on `node_id` |
| Maker | all `maker_*`, ~~`share_links`~~, ActiveStorage / ActionText |
| Shared | `users`, `user_identities` |

> **⚠️ THIS TABLE IS SUPERSEDED — see `2026-08-20-stage-3-boundary-design.md` §6.** It was built
> from a `Sync::`-shaped view of the code, and the sync engine's own models are **bare top-level
> constants** (`Version`, `Device`, `ManifestChunk`…), so a `Sync::` grep could not see them. Three
> corrections, one of them severe:
>
> - **`share_links` belongs to the ENGINE, not Maker.** Share links are chunk-only by construction
>   (`require_capability! :versioned`), and `lib/schema_map.rb:53` — a *tested* artifact already in
>   this repo — files them under "Sync control plane". Filing them under Maker here was wrong.
> - **`Sync::Gc.apply_retention!` READS `share_links`** (`gc.rb:106-114`) to protect the versions
>   live share links point at. Split the two and nightly retention **silently destroys the bytes
>   behind URLs users have already shared.** Not a build break — a quiet data-loss bug.
> - **`users` is a straddler too**: `head_seq` is engine state on the shared tenant row, and
>   `postgres_pooler_check` exists solely to protect its locking semantics — booting for every
>   deployment, including share/s3, which have no changelog.
>
> §5's "the engine declares them as host requirements, the way Devise expects a `User`" describes
> only one direction. The dependency runs **both ways**, in five places.

**Code.** Most `Sync::` references sit *inside* what moves (the v1 sync API's twelve
controllers, three reaper jobs). The genuine maker→sync seam is **six call sites in five
files**, and every one exists because the port refuses the operation:

| File | Calls | Refused verb |
|---|---|---|
| `app/controllers/files_controller.rb` | `Sync::Commit.begin/finalize`, `Sync::SubtreeDelete.call` | `write`, `delete` |
| `app/controllers/trash_controller.rb` | `Sync::Trash.restore` | `undelete` |
| `app/services/maker/addons/library_output.rb` | `Sync::Commit.begin/finalize` | `write` |
| `app/services/maker/move_node.rb` | `Sync::Mutation.apply(op: "move")` | `move` |
| `app/services/maker/library_folder.rb` | `Sync::Mutation.apply(op: "mkdir")` | `mkdir` |

**The Rust crates are already free.** No Ruby depends on `client/`; the string "maker"
inside those crates is binary naming (`maker-mount`, `maker-cfapi`), not coupling. The
only ties are `bin/ci test-app` (which shells into `client/maker-app`) and
`test/ci_hygiene_test.rb`'s workflow guards.

---

## 2. End state

**Four repos.** `tinkerex-addons` already exists and is untouched by this arc.

```
tinkerex          this repo, becomes the maker app
                  Maker::*, Hotwire UI, /tools, previews, sidecar/
                  the FileLayer port + four backends

tinkerex-sync     a Rails ENGINE plus a thin standalone host app
                  Sync::*, Storage::*, LibraryChannel,
                  the v1 sync API, the eight chunk tables, reaper jobs

tinkerex-client   the Rust crates and the Tauri desktop app
                  12 crates, ~36k LOC, test-conformance/

tinkerex-addons   unchanged
```

**The maker app ends with four storage choices.**

| `LIBRARY_BACKEND` | Bytes live | Catalog comes from |
|---|---|---|
| `chunk` | engine mounted in-process, same DB | `Sync::Commit` writes `nodes` directly |
| `chunk_remote` | standalone sync server, its own DB | changelog delta mirrored into local `nodes` |
| `share` | mounted NAS | `Library::Scanner` poll |
| `s3` | bucket | `S3Observer` poll |

`chunk` and `chunk_remote` are **the same engine in two deployment shapes**. Embedded is
the self-host answer — one process, one DB, no second service to run. Remote is the SaaS
answer. This is CLAUDE.md §7's "one protocol, two hosts" applied one level up, and it is
what makes goal 1 reachable without abandoning self-host simplicity.

### 2.1 What binds the two apps: the wire, not shared code

**Decision: no `tinkerex-core` gem.** The v1 API is already the contract. Two apps may
carry different `nodes` columns indefinitely as long as the changelog serialization is
stable. This is the same model as the addons split (`api_version` plus a manifest, no
shared code, Rails never rebuilt when a bundle is).

What replaces the gem is a **protocol conformance suite** both repos run: request/response
fixtures the sync server must satisfy, which the maker adapter is also tested against.
`client/test-conformance/` is the precedent in spirit but tests **mounts**, not the wire.
This suite is new work and it is the only thing standing between this design and silent
structural drift. It is not optional.

Rejected: extracting `User`, `Node`, `Capabilities`, `FileInfo`, `Delivery` and the error
classes into a ~400-line gem. It would forbid structural drift, but it imposes three-way
lockstep releases from Stage 3 onward — a large process cost for a small amount of code,
and the wire contract is what actually binds the systems.

### 2.2 Auth federation

**Decision: the maker app authenticates as a device.** The user connects their library
once; maker calls `POST /v1/devices/login` (email + password → a 256-bit device token) and
stores the token encrypted per user via Rails `encrypts`. Every later call carries
`Bearer <token>`.

This adds **zero** new server surface — that endpoint exists and already replaced the
pairing-code flow. Tokens are revocable from the existing devices list.

Accepted cost: two accounts per person, and the maker app becomes a new concentration of
long-lived bearer credentials. OIDC (CLAUDE.md §12.1, already open work on its own) is the
intended successor and supersedes this without disturbing the device-token mechanism
underneath, which the Rust clients need regardless.

---

## 3. Stage 1 — `client/` leaves

Move the twelve crates, the Tauri app and `test-conformance/` to `tinkerex-client`, with
`rust-client.yml`, `build-app.yml`, `cross-os-e2e.yml`, `install-app-on-runners.yml` and
the client portion of `nightly.yml`.

> **⚠️ "NEARLY FREE" IS WRONG — see `docs/superpowers/plans/2026-08-20-stage-1-extract-client.md`.**
> Three real couplings this section misses:
>
> 1. **`client/stl-thumbnailer` IS a Ruby dependency at Docker build time.** `Dockerfile:61-64`
>    compiles it; `:141` ships the binary; `.dockerignore:58-62` excludes `/client/` and re-includes
>    exactly this crate. `Maker::Previews::Stl` execs it. Move `client/` naively and **every STL and
>    3MF thumbnail in production stops rendering.** It is a SERVER-side tool misfiled under
>    `client/`; the plan re-files it to `tools/` first, as a prerequisite.
> 2. **Four CI jobs boot a real Rails server** to test the Rust crates against it
>    (`rust-client.yml`'s `engine-integration`; `nightly.yml`'s `e2e-linux`, `e2e-macos`,
>    `stress-load-and-multifiletype-linux`). Those two workflows split; they do not move.
> 3. **Self-hosted runners register PER REPOSITORY.** Each physical box needs a second runner
>    service against the new repo — and only the macOS runner is registered today, so the moved
>    Linux/Windows workflows would be *skipped, not passing*.
>
> Also: `scripts/r2-cutover/smoke.sh` shells into `client/sync-engine` and is run by hand during
> storage cutovers, so nothing goes red when it breaks.

Both repos need their own copy of the `ci_hygiene_test.rb` workflow guards, and `bin/ci`'s
`test-app` gate travels with `client/maker-app`. `bin/ci` in the maker repo drops from
eight gates to seven.

Delivers goal 2 on day one. Requires no code change to the Rails app.

---

## 4. Stage 2 — widen the port

The load-bearing stage, and the one that deliberately reopens CLAUDE.md §14a. It happens
**in this repo, with no repo changes**, and it is independently valuable.

**The problem.** The six call sites reach around the port into `Sync::*`. In remote mode
there is no `Sync::*` in the process to reach.

**The resolution: bytes and metadata are different problems.**

### 4.1 Metadata verbs — chunk starts implementing them

No bytes, so §15 does not bind. `delete`, `move`, `mkdir` and `undelete` stop raising:

| Verb | Embedded chunk | Remote chunk |
|---|---|---|
| `delete` | `Sync::SubtreeDelete.call` | `DELETE /v1/nodes/:id` |
| `move` | `Sync::Mutation.apply(op: "move")` | `POST /v1/nodes/:id/move` |
| `mkdir` | `Sync::Mutation.apply(op: "mkdir")` | `POST /v1/nodes` |
| `undelete` | `Sync::Trash.restore` | `POST /v1/trash/:id/restore` |

§14a's four per-op refusal constants and its "name the real door each time" rule go away,
because the port *becomes* the door. The sharpest trap that rule protected survives
verbatim in the embedded column: `delete` is **`Sync::SubtreeDelete`**, never
`Sync::Mutation.apply(op: "delete")`, which tombstones only the node it is handed and
orphans every descendant.

### 4.2 Bytes — the two-phase flow becomes a port verb

The port does **not** grow a byte-taking `write` for chunk; that would push bytes through
Rails and break §15. It grows the presigned two-phase pair instead:

- `begin_upload(user, parent_node_id:, name:, manifest:)` → presigned PUT URLs for missing chunks
- `finalize_upload(user, commit_id:)` → version and seq

Embedded delegates to `Sync::Commit.begin/finalize`. Remote posts to `/v1/commit` and
`/v1/commit/:commit_id/finalize` and receives presigned URLs **pointing at object
storage** — so bytes touch neither Rails app. §15 holds, and in remote mode it holds
harder: the bytes bypass two servers rather than one.

`Chunk#write` (byte-taking) keeps raising `NotImplementedError`, un-rescued and loud, so
§14a's rule that `NotImplementedError` is a `ScriptError` and must never be rescued
survives with a smaller domain.

### 4.3 What this buys beyond the split

Four of §14d's five `port_writable?` branch copies collapse — `FilesController#destroy`,
`TrashController#restore`, `Maker::MoveNode` and `Maker::LibraryFolder#mkdir` all stop
asking the question. Only `Maker::Addons::LibraryOutput` keeps its branch, because the
two-phase upload genuinely *is* a different flow. Goal 4 is paid for here rather than
deferred to Stage 4.

### 4.4 What does not change

**`port_writable?` keeps its exact current meaning** — *which upload flow does the UI
drive*: true → POST bytes to the port (share, s3); false → drive the two-phase flow
(chunk, chunk_remote). The most-misread name in §14a is not being redefined, and the
"accepts uploads" misreading stays wrong for the same reason it was always wrong.

### 4.5 One genuine new divergence: `dir_deletable`

Chunk's `delete` can cascade a directory safely. Share's cannot — §14a: children are
stranded at paths that no longer exist while their bytes sit in `.trash`, where the scan
refuses to look. On S3 there is no directory and no rename at all.

Today `FilesController#destroy` hides this behind its `port_writable?` branch. After 4.3
it is one call with two answers, which §14a explicitly forbids. So it becomes a sixth
**capability**, `dir_deletable` (chunk and chunk_remote true; share and s3 false) — the
same move that added `scannable` when a coincidence between two questions became wrong.

---

## 5. Stage 3 — `Sync::*` becomes a mounted engine

> **THREE HAZARDS THE STAGE 2 CLOSE-OUT REVIEW FOUND, NONE OF WHICH §1's TABLE ACCOUNTS FOR.**
> Recorded here because they falsify part of that table, and a Stage 3 inventory built the obvious
> way will miss all three.
>
> 1. **`share_links` IS A SECOND STRADDLER, AND §1 BUCKETS IT WRONG.** The table above files it
>    under "Maker" (stays in `tinkerex`), but its own columns `version_id` and `manifest_id`
>    (`db/migrate/20260617000006_create_share_links.rb`) are foreign keys into two of the eight
>    chunk-only tables, and `Sharing::Links.redeem` queries `ManifestChunk` and calls
>    `Storage::ChunkStore.current` **directly, outside the port**. Whether
>    `v1/share_controller.rb` and `v1/share_links_controller.rb` are among the "twelve controllers"
>    that move is genuinely ambiguous — 14 v1 controllers minus `base` and `test_users` is 12,
>    which *would* include them. **Either resolution leaves a cross-repo dependency**: engine code
>    reaching into a maker-owned table, or host code reaching into two now-engine-owned models.
>    Decide it explicitly in Stage 3's own design, not at implementation time.
>
> 2. **`Node#current_version` QUERIES `Version`, WHICH MOVES.** Every adapter's `file_info` calls
>    it. §5 frames the `User`/`Node` relationship as one-directional — "the engine declares them as
>    host requirements" — and this is the reverse: **host code depending on an engine model.** Not
>    discussed anywhere in this document before now.
>
> 3. **AN INVENTORY BUILT BY GREPPING `Sync::` WILL UNDERCOUNT, for the same structural reason.**
>    The sync engine's own AR models are **not `Sync::`-namespaced** — `Version`, `ManifestChunk`,
>    `Chunk`, `PendingCommit`, `ChangelogEntry` are all bare top-level constants. Stage 2's seam
>    guard cannot see them either (wrong namespace), and the chunk-internals guard is scoped to
>    `app/**/maker` rather than the whole app, which is exactly how hazard 1 stayed invisible.
>    **Stage 3's audit must grep the bare model names and `Storage::` across all of `app/`**, not
>    just `Sync::`, and not just under `maker/`.

`Sync::*`, `Storage::*`, `LibraryChannel`, the v1 sync API's twelve controllers, the three
reaper jobs and the eight tables' migrations move to `tinkerex-sync`, shipped as a
mountable Rails engine. The maker app adds the gem and mounts it.

Chunk mode keeps working, in-process, unchanged — there is never a window where it is
broken, and there is never a second copy of `Sync::*` to maintain.

`User` and `Node` stay in the maker app; the engine declares them as host requirements,
the way Devise expects a `User`.

Delivers goals 3 and 4.

---

## 6. Stage 4 — standalone host and `FileLayer::ChunkRemote`

The engine gains a thin standalone host app supplying its own `User` and `Node`, and its
own database. The maker app gains `FileLayer::ChunkRemote`.

**Zero new sync-server endpoints are required.** Every verb already has one: mkdir
`POST /v1/nodes`, move `POST /v1/nodes/:id/move`, delete `DELETE /v1/nodes/:id`, undelete
`POST /v1/trash/:id/restore`, upload `POST /v1/commit` + `/finalize`, hydrate
`POST /v1/chunks/download`, catalog `GET /v1/changes`.

**The `nodes` straddler resolves by making the maker app a sync client.** It pulls
changelog deltas and applies them to its own `nodes`, exactly as `apply_remote` does in
Rust. `node_id` is a server-assigned UUID, so every attachment, BOM link and tag survives.
Reads stay local SQL, so §14a's constant-in-N query guarantee for `stat_all` holds
unchanged, and CLAUDE.md §2's "the WAN is never in the metadata path" holds for the maker
app for the first time.

The mirror is a second writer of `nodes`, but only one backend runs per deployment so it
cannot collide with `Library::Reconciler`. Its safety story is the changelog's own:
`Sync::Changes` reports `oldest_seq`, and a cursor below it triggers a full resync.
§14b's mass-deletion guard is Reconciler-only and deliberately does not apply — the
changelog is authoritative by construction, which is precisely why `scannable` is false.

**Freshness.** The maker app subscribes to `LibraryChannel` on the sync server as a device,
so it gets the `{head_seq}` nudge it currently gets for free in-process.

Delivers goal 1.

---

## 7. Verification

**CI grows a fourth backend leg.** `test`, `test-share`, `test-s3` gain
`test-chunk-remote`, driving the adapter against a real HTTP server. Running the engine
in-process behind a local Rack server is the cheap version; spawning the sync app is the
honest one. §15's rule that the legs report identical counts extends to four.

**Stage 2 rewrites every test that asserts a refusal *message* into one that asserts
*behaviour*.** Each is a guard, so each needs mutation-checking per §15. This is the
largest single test-churn item in the plan.

**The protocol conformance suite (§2.1) is the gate that replaces the gem.** Without it,
"the wire is the contract" is a claim nothing checks — this repo's recorded dominant
failure mode.

---

## 8. Risks

1. **Mirror freshness lag** (Stage 4) — mitigated by the ActionCable nudge; a dropped
   subscription degrades to a stale catalog, not a wrong one.
2. **Test churn in Stage 2** — large, and every rewritten guard must be mutation-checked.
3. **Credential concentration** (Stage 4) — maker holds N long-lived device tokens.
   Encrypted at rest, revocable, superseded by OIDC.
4. **`bin/ci test-app` and the `ci_hygiene_test.rb` guards** must exist in both repos
   after Stage 1, or a workflow invariant silently stops being checked.
5. **Schema drift** between the two `nodes` tables — accepted by design, bounded by the
   conformance suite.

---

## 9. CLAUDE.md corrections this arc must land

Found while measuring the split; both are wrong on `main` today and both bear on this
design.

- **§4** claims there is no `client/fs-fskit` crate on `main`. There is
  (`f40c101`). Stage 1 moves it with the rest of `client/`.
- **§8** describes the pairing code as the mechanism by which a device joins a library.
  `POST /v1/devices/login`'s own comment says it *"Replaces the pairing-code flow."* That
  endpoint is the auth join between the two apps (§2.2), so the stale description is
  directly load-bearing here.

---

## 10. Sequencing note

Stage 2 does not depend on Stage 1. Stages 1, 3 and 4 each require creating or pushing to
a repository — an outward-facing action needing explicit go-ahead. Stage 2 is entirely
in-repo, self-contained, and delivers goal 4 on its own, so it is the stage to implement
first from a standing start.
