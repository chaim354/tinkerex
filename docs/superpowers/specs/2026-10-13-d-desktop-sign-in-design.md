# D1 — The desktop client can sign in: design

**Date:** 2026-10-13 · **Status:** design, executed the same day (plan:
`docs/superpowers/plans/2026-10-13-d-desktop-sign-in.md`) · **Source:** `docs/AUDIT-2026-10-12-readiness.md`
§2.2 items 1 and 3, §4 row D. **Cross-repo:** the server half lives here, the client half in
`chaim354/tinkerex-client` (`client/sync-client`, `client/maker-app`).

## The problem

The desktop app's only sign-in door posts `POST /v1/devices/login` to whatever URL the maker types,
then syncs against that same URL. The maker app serves the login and none of the sync routes; the
sync server serves the sync routes and no password login. **The shipping app cannot sign in and
mount against any live server** (audit §2.2.1, measured). The documented workarounds — hand-write
`credentials.json` with a token from `tinkerex-sync device issue`, or run the CLI daemons — are for
the author. The app is also still the Tauri template: `maker-app`, `com.chaim.maker-app`,
"A Tauri App" by "you", a first-run form prefilled with `http://localhost:3001`,
`maker@example.com` and `/tmp/MakerDrive`.

## What already exists, and decides the shape

- The maker app holds, per user, a **bootstrap device token on the sync server**
  (`users.sync_device_token`, encrypted), minted lazily through the operator door
  (`FileLayer::ChunkRemote::Provisioning` → `POST /v1/admin/libraries`, CLAUDE.md §8). That is the
  per-user remote library Arc C built.
- The sync server mints a **sibling device** for an existing library on `POST /v1/devices {name}`,
  authenticated by any device token of that library, and answers `GET /v1/devices/whoami` with the
  library's `head_seq` (the joining device's changelog cursor). Both are served by the Rust binary.
- The sync accessory is already reachable by devices through kamal-proxy as
  `sync.tinkerex.{local,home}` ("the DEVICES' door", `config/deploy.yml`), separate from the maker
  app's internal alias in `CHUNK_REMOTE_URL`.

So the audit's own suggestion is the design: **the maker app brokers.** A device signs in to the
Tinkerex server the maker already knows the address of, and receives everything it needs to sync.

## Decisions

1. **Enrolment lives in the maker app, and the login answer carries a sync grant.**
   `POST /v1/devices/login {email, password, device_name}` keeps its contract (maker device token,
   `user_id`, `device_id`, `head_seq`) and adds two fields:
   - `library: { backend: "share"|"s3"|"chunk_remote", syncable: bool }` — always.
   - `sync: { url, device_token, user_id, device_id, head_seq }` — on a syncable deployment: the
     app ensures the user's remote library (`Provisioning#call`), mints a sibling device on the sync
     server with the user's bootstrap token (`POST /v1/devices {name: device_name}`), reads
     `head_seq` back with the NEW token (`GET /v1/devices/whoami`, which also proves the token is
     accepted before it is handed out), and reports `SYNC_PUBLIC_URL` as `url`. On share/s3:
     `sync: null`.
   `POST /v1/devices {name}` (a sibling via an existing maker token) answers the same two fields.
   **Order inside `login`: authenticate → broker the sync grant → mint the maker device → respond.**
   A sync server that cannot be reached answers `503 sync_unavailable` with no maker device
   minted: a half-enrolled device that must sign in again anyway is worse than a clear retry.
   The grant is minted per login, never cached — a device that signs in twice is two sync devices,
   the same as two maker devices today.
2. **`SYNC_PUBLIC_URL` is the one new setting**, required on `chunk_remote` in production
   (`LibraryBackendCheck::CHUNK_REMOTE_REQUIRED`, the same boot-time presence check as
   `CHUNK_REMOTE_URL`): the address DEVICES reach the sync server at, as opposed to the internal
   alias the app itself dials. Base destination: `https://sync.tinkerex.home`. Compose: the overlay
   already publishes the sync port, so `.env.example` carries it (`http://<this host>:3001`).
   `docs/INSTALL.md` explains the two addresses. The `test-chunk-remote` gate sets it to the local
   server's URL so the brokered token is exercised against a real sync server on every run.
3. **The client stores a credential record, not a bare token.** `credentials.json` values become
   `{ "maker_token", "sync_url", "sync_token" }` keyed by `(typed server, email)` as today. A legacy
   bare-string value keeps working and means "this token is a sync token for the typed server" —
   the author's `device issue` workaround stays alive, and nothing is migrated on disk. Every
   command that talks to sync routes (`mount`, `browse`, versions, conflicts, locks) resolves
   `(sync_url, sync_token)` through one helper; the maker token is kept for the maker API later.
   A server answering `sync: null` gets no mount and one sentence naming why ("this server keeps
   its files in a shared folder / a storage bucket; there is nothing for this app to sync").
   An old server whose answer has no `sync` field at all is treated like the legacy string case
   (the typed server is the sync server), so the app still works against a sync server directly.
4. **The app is Tinkerex.** `productName`/window title `Tinkerex`, identifier
   `com.tinkerex.desktop`, Cargo `description`/`authors` real, the app README a real one. The
   on-disk data directory stays `maker-app` for now — it is an implementation path, a rename is a
   migration of every account's local tree, and nothing a stranger sees names it.
5. **The first-run form asks for the Tinkerex server, not "the sync server"**: an empty URL with a
   placeholder (`https://tinkerex.example.com`), an empty email, the password, and a mount point
   that defaults to `~/Tinkerex` (`%USERPROFILE%\Tinkerex` on Windows). The copy says what a
   device token is and that the password is sent once.

## Out of scope (D2 and D3, recorded in the record)

- **D2:** OS prerequisite checks (FUSE-T / libfuse + `user_allow_other` / CfAPI), an offline
  indicator, the sync-engine suites and the Linux/Windows legs in CI.
- **D3:** signing and notarization (an Apple Developer ID and a Windows certificate are the owner's
  decisions), `app-v*` releases, an updater, crash reporting.
- Story 4.6 and selective sync are unchanged.

## Verification

- Maker, share leg: login answers `library.backend` and `sync: null`; `SYNC_PUBLIC_URL` is not
  required there. Maker, chunk_remote leg (`bin/ci test-chunk-remote`, a real sync server): the
  brokered `sync.device_token` is accepted by that server's `whoami` and names the same library
  as the user's bootstrap token; a dead sync server answers 503 and mints no maker device.
- Client: `sync-client` parses old and new login answers; the Tauri credential record round-trips
  and a legacy string resolves to the typed server; the engine suites keep passing.
- Cross-stack, by hand before the PR opens: a maker app in `chunk_remote` mode against a local
  sync server, the client's `device_login` against the maker app, the returned grant used for
  `whoami` and `/v1/tree` on the sync server.

## Invariants this adds

Maker (CLAUDE.md §8, one line): a device enrols through the maker app and receives a sync-server
sibling token minted with the user's own bootstrap token; `SYNC_PUBLIC_URL` is the devices' door
and `CHUNK_REMOTE_URL` the app's, and they are different addresses on purpose. Client (its
CLAUDE.md): the typed server is the Tinkerex server; sync routes go to the grant's URL.
