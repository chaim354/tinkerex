# D1 — The desktop client can sign in: Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking. `.claude/commands/execute-plan.md` governs batching: Tasks 1 and 2 (maker app, this repo) run in parallel worktrees; Task 3 (the client repo, `../tinkerex-client`) runs in parallel in that checkout on its own branch; Task 4 is the orchestrator's.

**Goal:** A maker types their Tinkerex server's address, email and password into the desktop app and it syncs — because the maker app answers the login with a sync-server grant. Design: `docs/superpowers/specs/2026-10-13-d-desktop-sign-in-design.md`.

**Facts (file:line on `origin/main` 0b161501 and `tinkerex-client` main 7a96edf, 2026-10-13):**
- Maker login: `app/controllers/v1/devices_controller.rb` — `login` (authenticate via Devise, `Device.register!(user:, name:)`, answer `{user_id, device_id, device_token, head_seq}` 201) and `create` (sibling via an existing maker token). `skip_before_action :authenticate_device!, only: :login`; a per-IP `rate_limit` on `login`. Tests: `test/integration/v1/device_login_test.rb`, `device_login_throttle_test.rb`.
- The user's bootstrap sync token: `FileLayer::ChunkRemote::Provisioning.new.call(user)` returns `users.sync_device_token`, provisioning the remote library first if blank (`POST /v1/admin/libraries` with `SYNC_ADMIN_TOKEN`); raises `FileLayer::FetchError` when the sync server is unreachable or refuses.
- The wire to the sync server: `FileLayer::ChunkRemote::Transport.new(base_url:, token:)` with `get(path, params)` / `post(path, body)` (`app/services/file_layer/chunk_remote/transport.rb:44-52`); `#interpret` maps 401/403 to `FetchError`, 409/422/501 to `UnsupportedOperation`. The sync server (Rust, `crates/tinkerex-sync/src/http/handlers.rs:58-74` in `../tinkerex-sync`) answers `POST /v1/devices {name}` → `201 {device_id, device_token}` and `GET /v1/devices/whoami` → `{user_id, device_id, head_seq}`.
- Boot guard: `lib/library_backend_check.rb:78` `CHUNK_REMOTE_REQUIRED = %w[CHUNK_REMOTE_URL SYNC_ADMIN_TOKEN]`, checked by `check_chunk_remote!` (:132-144) with a sentence naming what each knob is for. `test/lib/library_backend_check_test.rb` (verify the name with `ls test/lib/`).
- The local sync server for the chunk_remote leg: `bin/sync-server prepare` writes `tmp/sync-server.env` (`CHUNK_REMOTE_URL=http://127.0.0.1:$PORT`, `SYNC_ADMIN_TOKEN=…`, `CHUNK_REMOTE_TOKEN=…`, :176-182); `config/ci.rb`'s `test-chunk-remote` sources it (`set -a; . tmp/sync-server.env`). The journey helpers: `test/support/chunk_remote_journey.rb` (`skip_unless_remote_server`-style gating — read it) and `test/integration/chunk_remote_journey_test.rb`.
- Deploy config: `config/deploy.yml` base `env.clear` carries `LIBRARY_BACKEND: chunk_remote` and `CHUNK_REMOTE_URL: http://tinkerex-sync:3000`; the `sync` accessory's `proxy.hosts` are `sync.tinkerex.local` / `sync.tinkerex.home` with `ssl: false`. `test/deploy_hygiene_test.rb` re-derives each destination's merged config. `docker-compose.chunk_remote.yml` sets the web env and publishes the sync port as `${TINKEREX_SYNC_PORT:-3001}`; `.env.example` lists the knobs; `docs/INSTALL.md` has the env table (`CHUNK_REMOTE_URL` row at :310, `SYNC_ADMIN_TOKEN` at :311), guarded by `test/install_docs_test.rb`'s first-cell rule.
- Wire spec: `docs/sync-protocol.md` §3 "Authentication (device tokens)", lines 175-195: device enrolment is a host obligation; names `POST /v1/devices/login` on this app.
- Client (`../tinkerex-client`): `client/sync-client/src/lib.rs` — `RegisterResponse {user_id, device_id, device_token, head_seq}` (:60-63), `device_login` (:455-472), `whoami` (:549-555), `create_device` (:558-565), inline tests from :892. `client/maker-app/src-tauri/src/lib.rs` — `app_base()` (:126), `creds_path()`/`creds_key()`/`load_token()`/`save_token()` (:266-330), `mount_with_token(state, server_url, email, mountpoint, token)` (:426) building `DaemonConfig::new(mountpoint, db, chunks, server_url, token)` (:465), `sync_login` (:478-500), `browse` (:518) and the other commands that call sync routes through `ServerClient::with_token(&server_url, token)`; inline tests from :1358. UI: `client/maker-app/src/index.html:28-56` (the form), `src/main.js:198-240` (the sign-in call), `:420-440` (per-OS mount default). Identity: `src-tauri/tauri.conf.json`, `src-tauri/Cargo.toml:1-7`. JS tests: `client/maker-app/test/*.test.js` (node:test, run by that repo's `bin/ci test-app`). Crate CI: `.github/workflows/rust-client.yml:130-141` (`cargo test` per crate).

**Conventions that bind every task:** maker tests run with `LIBRARY_PATH=<abs path>/tmp/lib LIBRARY_BACKEND=share bin/rails test <files>` (empty `tmp/lib` before each run: `rm -rf tmp/lib && mkdir -p tmp/lib`); no `Object#stub` — copy the `replacing` helper from `test/integration/web/new_menu_test.rb:9`; ENV is stubbed by set/delete in `setup`/`teardown`; a guard that exists to forbid something is mutation-checked (break it, run the named test, paste the red line, restore with `git checkout -- <file>` and `rm -rf tmp/cache/bootsnap*`); `bin/rubocop` on touched Ruby; one commit per task with the trailer `Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>`, message written to a file and committed with `git commit -F` (no backticks or `!` in `-m`, zsh); no push. Client: `cargo test` in each touched crate, `cargo fmt` and `cargo clippy` if that repo's CI runs them (read `.github/workflows/rust-client.yml`), the JS tests with `node --test client/maker-app/test`.

**File ownership (no two tasks touch one file):**

| task | repo | files |
|---|---|---|
| 1 `SYNC_PUBLIC_URL` | tinkerex | `lib/library_backend_check.rb`, `test/lib/library_backend_check_test.rb`, `config/deploy.yml` (base `env.clear`), `test/deploy_hygiene_test.rb`, `docker-compose.chunk_remote.yml`, `.env.example`, `docs/INSTALL.md`, `test/install_docs_test.rb` (if its table needs the row), `bin/sync-server` (the env file), `config/ci.rb` (only if the leg needs more than the env file) |
| 2 the broker | tinkerex | `app/controllers/v1/devices_controller.rb`, `app/services/file_layer/chunk_remote/sync_grant.rb` (new), `test/services/file_layer/chunk_remote/sync_grant_test.rb` (new), `test/integration/v1/device_login_test.rb`, `test/integration/v1/device_sync_grant_journey_test.rb` (new, chunk_remote leg), `docs/sync-protocol.md` |
| 3 the client | tinkerex-client | `client/sync-client/src/lib.rs`, `client/maker-app/src-tauri/src/lib.rs`, `client/maker-app/src/index.html`, `client/maker-app/src/main.js`, `client/maker-app/src/session.js` (if the form state lives there — read it), `client/maker-app/test/session.test.js`, `client/maker-app/src-tauri/tauri.conf.json`, `client/maker-app/src-tauri/Cargo.toml`, `client/maker-app/README.md`, `README.md` (new, root), `CLAUDE.md` (the enrolment paragraph, :118-135) |

---

### Task 1: `SYNC_PUBLIC_URL` — the devices' door, named once and required where it matters

- [ ] **Step 1: Tests first.** In `test/lib/library_backend_check_test.rb` (or the existing chunk_remote check test — find it with `grep -rn "CHUNK_REMOTE_REQUIRED\|check_chunk_remote" test/`), add: chunk_remote with `CHUNK_REMOTE_URL` and `SYNC_ADMIN_TOKEN` but no `SYNC_PUBLIC_URL` raises `LibraryBackendCheck::Error` naming `SYNC_PUBLIC_URL`; with all three it passes; share with none of them passes. In `test/deploy_hygiene_test.rb`, add: the base destination's merged env carries `SYNC_PUBLIC_URL` beginning with `https://sync.`, and the share and s3 destinations carry none (read how that test derives merged config — `Kamal::Configuration` — and follow it; mutation: blank the base value → red). In `test/install_docs_test.rb`, confirm the first-cell rule will require a `SYNC_PUBLIC_URL` row once the knob exists (read the test; if it derives required knobs from `LibraryBackendCheck`, the row is mandatory and the test goes red until Step 2 — that is the point).

- [ ] **Step 2: Implement.**
  - `lib/library_backend_check.rb`: `CHUNK_REMOTE_REQUIRED = %w[CHUNK_REMOTE_URL SYNC_ADMIN_TOKEN SYNC_PUBLIC_URL]`; extend the error sentence: `SYNC_PUBLIC_URL` is the address DEVICES reach the sync server at (the desktop app receives it in its login answer), as opposed to `CHUNK_REMOTE_URL`, the address this app dials — on a Kamal box the internal alias and the proxied host name differ on purpose.
  - `config/deploy.yml` base `env.clear`: `SYNC_PUBLIC_URL: https://sync.tinkerex.home` right under `CHUNK_REMOTE_URL`, with a two-line comment pointing at the `sync` accessory's `proxy.hosts` (the devices' door) and saying the two addresses differ on purpose. Do not touch the overlays: share/s3 set `LIBRARY_BACKEND` to a non-syncable value and must not carry it; ovh declares no backend.
  - `docker-compose.chunk_remote.yml` web env: `SYNC_PUBLIC_URL: ${SYNC_PUBLIC_URL:?set it in .env to the address devices reach this host's sync port at, e.g. http://192.168.1.10:3001}`. `.env.example`: a `SYNC_PUBLIC_URL=` line with the same one-line explanation beside `SYNC_ADMIN_TOKEN`.
  - `docs/INSTALL.md`: a row `SYNC_PUBLIC_URL` | chunk_remote | — | "The sync server's address as seen from your other devices (the desktop app gets it from its login answer). `CHUNK_REMOTE_URL` is the same server as seen from the app; on a single box behind a reverse proxy they differ." Keep the first cell exactly the knob name.
  - `bin/sync-server` prepare (:176-182): write `SYNC_PUBLIC_URL=http://127.0.0.1:$PORT` beside `CHUNK_REMOTE_URL`, so the `test-chunk-remote` leg inherits it through `tmp/sync-server.env`; one comment line: the leg is one box, so both addresses are the local server. Check `config/ci.rb`'s `test-chunk-remote` script needs nothing else (it sources the file with `set -a`).

- [ ] **Step 3: Run** `test/lib/library_backend_check_test.rb test/deploy_hygiene_test.rb test/install_docs_test.rb test/docs_hygiene_test.rb` plus `bin/rubocop lib/library_backend_check.rb`. Then `bin/sync-server prepare` and `cat tmp/sync-server.env` to show the new line (do not print `SYNC_ADMIN_TOKEN`'s value; grep for the `SYNC_PUBLIC_URL=` line only).

- [ ] **Step 4: Mutation-check** — drop `SYNC_PUBLIC_URL` from `CHUNK_REMOTE_REQUIRED` → the check test red; blank the deploy.yml value → the hygiene test red; restore.

- [ ] **Step 5: Commit** — "SYNC_PUBLIC_URL names the devices' door to the sync server, required on chunk_remote".

---

### Task 2: The login answer carries a sync grant, brokered with the user's own bootstrap token

- [ ] **Step 1: Read first** — `app/controllers/v1/devices_controller.rb` whole; `app/services/file_layer/chunk_remote/provisioning.rb` whole (how it dials the admin door, what it raises, how `admin_transport:` is injected for tests); `transport.rb` (`#interpret`'s mapping); `test/integration/v1/device_login_test.rb`; `test/support/chunk_remote_journey.rb` and `test/integration/chunk_remote_journey_test.rb` (how a test is gated to a REAL sync server and how it obtains a user with a provisioned library); `test/services/file_layer/chunk_remote/provisioning_test.rb` (how the fake admin transport is shaped — mirror it). CLAUDE.md §8 and §14a's transport bullet (no caching of per-user transports).

- [ ] **Step 2: Tests first.**
  - `test/services/file_layer/chunk_remote/sync_grant_test.rb` (unit, every leg): with a fake transport that records `POST /v1/devices` and answers `{device_id: 7, device_token: "sib"}` then `GET /v1/devices/whoami` with `{user_id: 3, device_id: 7, head_seq: 42}`, `SyncGrant.new(transport_for: …).call(user, device_name: "Ada's laptop")` returns `{url: ENV["SYNC_PUBLIC_URL"], device_token: "sib", user_id: 3, device_id: 7, head_seq: 42}`; the POST was made with the user's bootstrap token and the whoami with the NEW token (assert both — the second is the proof the grant works before it is handed out); a transport raising `FetchError` propagates it; the device name reaches the body.
  - `test/integration/v1/device_login_test.rb` additions (share leg answers `sync: null`): the answer carries `library: {backend: "share", syncable: false}` and `sync: nil`; on the s3 leg the same with `backend: "s3"` — derive the expected backend from `FileLayer.current` so the assertion is honest on every leg (`FileLayer.current.capabilities.syncable?` false → `sync` must be nil). Add: a syncable deployment whose grant raises `FetchError` answers `503 {error: "sync_unavailable"}` and **mints no Device** (stub the grant through `replacing` on the controller's grant builder or inject via a class-level seam; `Device.count` unchanged). Field names asserted on the parsed JSON.
  - `test/integration/v1/device_sync_grant_journey_test.rb` (chunk_remote leg only; gated the way the journey suite is gated so it SKIPS cleanly on share/s3 and the gate's zero-skip check still applies only to the journey file — read `config/ci.rb`'s comment on which file must report zero skips before deciding where this test lives; if the journey FILE is the only one allowed to touch the real server, add the test to `chunk_remote_journey_test.rb` instead and say so): a user logs in through `POST /v1/devices/login`; the answer's `sync.url` equals `ENV["SYNC_PUBLIC_URL"]` (set it in `setup` to `ENV["CHUNK_REMOTE_URL"]` when absent, restore in teardown — Task 1 plumbs it for real); `sync.device_token` is accepted by the real server's `GET /v1/devices/whoami` and names the same `user_id` as the user's bootstrap token's whoami; `sync.device_id` differs from the bootstrap device's; `POST /v1/devices` with the new MAKER token answers a second grant with yet another `device_id`.

- [ ] **Step 3: Implement.**
  - `app/services/file_layer/chunk_remote/sync_grant.rb`:
    ```ruby
    module FileLayer
      class ChunkRemote
        # THE SYNC GRANT A DEVICE RECEIVES WHEN IT SIGNS IN TO THE MAKER APP (D1, 2026-10-13).
        # The maker app holds each user's bootstrap device token on the sync server
        # (users.sync_device_token, minted by Provisioning through the operator door); with it this
        # class mints a SIBLING device for the signing-in machine (POST /v1/devices) and reads
        # head_seq back with the NEW token (GET /v1/devices/whoami) — which is also the proof the
        # token is accepted before it is handed out. Nothing is cached: a device that signs in
        # twice is two sync devices, exactly as it is two maker devices. The URL handed out is
        # SYNC_PUBLIC_URL, the devices' door, never CHUNK_REMOTE_URL, the app's own internal alias
        # (lib/library_backend_check.rb explains why they differ).
        #
        # `transport_for:` is injectable the way Provisioning's `admin_transport:` is: a
        # (base_url, token) -> transport builder, so a unit test can hand in a fake wire.
        class SyncGrant
          def initialize(provisioning: Provisioning.new, transport_for: nil)
            @provisioning = provisioning
            @transport_for = transport_for || ->(token) { Transport.new(base_url: ENV.fetch("CHUNK_REMOTE_URL"), token:) }
          end

          # -> { url:, device_token:, user_id:, device_id:, head_seq: }; raises FileLayer::FetchError
          # when the sync server cannot be reached or refuses (Transport#interpret's mapping).
          def call(user, device_name:)
            bootstrap = @provisioning.call(user)
            minted = @transport_for.call(bootstrap).post("/v1/devices", { name: device_name })
            who = @transport_for.call(minted.fetch("device_token")).get("/v1/devices/whoami")
            { url: ENV.fetch("SYNC_PUBLIC_URL"), device_token: minted.fetch("device_token"),
              user_id: who.fetch("user_id"), device_id: who.fetch("device_id"), head_seq: who.fetch("head_seq") }
          end
        end
      end
    end
    ```
    (Match `Transport#post`/`#get`'s actual return shape — read whether they return parsed JSON with string keys — and adjust `fetch` keys accordingly.)
  - `V1::DevicesController`: a private `sync_grant_for(user, device_name)` that returns `nil` unless `FileLayer.current.capabilities.syncable?`, else `SyncGrant.new.call(user, device_name:)`; `rescue FileLayer::FetchError` in `login`/`create` → `render json: { error: "sync_unavailable" }, status: :service_unavailable` BEFORE any `Device.register!` runs (order: authenticate → grant → register → render). Both actions add `library: { backend: <the backend name FileLayer exposes — find the existing accessor rather than reading ENV; grep "def backend" app/services/file_layer.rb>, syncable: … }` and `sync: grant` to the JSON. Keep the existing fields and status codes.
  - `docs/sync-protocol.md` §3: extend the host-obligation paragraph with the two new fields, the 503, and the sentence that the sync URL in the grant is the devices' door; keep the endpoint count sentences true (no new sync-server route is added; the maker app's own two routes change shape).

- [ ] **Step 4: Run** the three test files on the share env; the unit and login files under the s3 stub env from `config/ci.rb` if easy; `bin/rubocop` on touched Ruby. The journey test runs only inside `bin/ci test-chunk-remote` (the orchestrator) — say so.

- [ ] **Step 5: Mutation-check** — remove the whoami read (answer without proving the token) → the unit test's "whoami with the NEW token" assertion red; move `Device.register!` above the grant → the "mints no Device on 503" test red; restore.

- [ ] **Step 6: Commit** — "A device that signs in to the maker app receives a sync-server grant minted with the user's own bootstrap token".

---

### Task 3: The desktop app signs in to the Tinkerex server and syncs against the grant (`../tinkerex-client`)

- [ ] **Step 0: Branch.** In `/Users/charlesschwartz/Desktop/repos/tinkerex-client` (currently on `main` at 7a96edf, clean): `git checkout -b claude/d-desktop-sign-in`. Read that repo's `CLAUDE.md` first (its conventions, the enrolment paragraph :118-135, the crate cheatsheet), then the files named in Facts.

- [ ] **Step 1: `sync-client` — the answer's new shape, tests first.** In `client/sync-client/src/lib.rs` tests: `RegisterResponse` deserialises the OLD answer (no `sync`/`library`) with both `None`, and the NEW answer (`library: {backend, syncable}`, `sync: {url, device_token, user_id, device_id, head_seq}`) with both `Some`, plus `sync: null`. Implement: `#[derive(Deserialize)] pub struct SyncGrant { pub url: String, pub device_token: String, pub user_id: i64, pub device_id: i64, pub head_seq: i64 }`, `pub struct LibraryInfo { pub backend: String, pub syncable: bool }`, and on `RegisterResponse` `#[serde(default)] pub sync: Option<SyncGrant>`, `#[serde(default)] pub library: Option<LibraryInfo>`. `device_login` keeps setting `self.token` to the MAKER token (it is the maker app's client); callers pick the grant. Doc-comment the Dropbox-model paragraph to say the sync routes go to `sync.url`.

- [ ] **Step 2: Tauri — a credential record, tests first.** In `src-tauri/src/lib.rs` tests: `Credential` round-trips through `credentials.json` as an object `{"maker_token","sync_url","sync_token"}`; a legacy bare string loads as `Credential { maker_token: None, sync_url: <the typed server>, sync_token: <the string> }` (the author's `device issue` workaround keeps working); `sync_endpoint(server, email)` returns the grant's `(url, token)` for a record and the typed server for a legacy string; missing → the existing "this device isn't signed in yet" error. Implement `load_credential`/`save_credential` (atomic + owner-only as `save_token` is), replace every `load_token` caller: `mount_with_token` becomes `mount_with_grant(state, server_url, email, mountpoint, sync_url, sync_token)` and `DaemonConfig::new(…, sync_url, sync_token)`; `browse`, `file_versions`, `restore_version`, the conflict and lock commands, and `sync_status`-style readers resolve `(sync_url, sync_token)` through `sync_endpoint`. `account_dir` stays keyed by `(typed server, email)`.
  `sync_login`: if a credential exists, reuse it; otherwise `ServerClient::new(&server_url).device_login(...)`; if the answer has `sync: Some(g)`, save `{maker_token, sync_url: g.url, sync_token: g.device_token}` and mount against the grant; if `library.syncable == false`, save nothing to mount with and return `Err` with one sentence naming the backend ("This server keeps its files in a shared folder (`share`); there is nothing for this app to sync. Open the folder from your file manager instead." / "…in a storage bucket (`s3`)…"); if the answer has NO `sync` field at all (an older server), treat the typed server as the sync server and the maker token as the sync token, as the legacy case does.

- [ ] **Step 3: The first-run form and copy.** `src/index.html`: label "Tinkerex server" with `placeholder="https://tinkerex.example.com"` and an EMPTY value; email empty with `placeholder="you@example.com"`; mount default `~/Tinkerex`; the paragraph: "Sign in with the account you use on the web. Your password is sent once, over TLS, and never stored: this device keeps only its own token, which you can revoke from the server." `src/main.js:420-440`: Windows default `%USERPROFILE%\Tinkerex` (keep the CfAPI "sync-root folder" wording), macOS/Linux examples `~/Tinkerex`; the sign-in error path shows the server's sentence for a non-syncable library verbatim. If `src/session.js` holds the form's validation/state (read it and `test/session.test.js`), the empty-URL and empty-email validation messages live there with tests.

- [ ] **Step 4: Identity.** `src-tauri/tauri.conf.json`: `productName` "Tinkerex", `identifier` "com.tinkerex.desktop", window `title` "Tinkerex". `src-tauri/Cargo.toml`: `description = "The Tinkerex desktop app: signs in to a Tinkerex server and syncs a folder with its library"`, `authors = ["Tinkerex contributors"]`. Leave `app_base()`'s `maker-app` directory name (a rename is an account-state migration; say so in a one-line comment there). `client/maker-app/README.md`: replace the Tauri template with a real page (what it is, prerequisites per OS pointing at `SETUP.md`, how to run `cargo tauri dev`, where credentials live, that signing/releases are not set up yet). Root `README.md` for the repo: one screen — the crates, the app, how they relate to `chaim354/tinkerex` and `chaim354/tinkerex-sync`, the licence (Apache-2.0, `LICENSE`), where the cheatsheet is (`CLAUDE.md`). `CLAUDE.md` :118-135: the enrolment paragraph now says the app signs in to the MAKER app and syncs against the grant's URL; the integration suites' two modes are unchanged.

- [ ] **Step 5: Run** `cargo test` in `client/sync-client` and in `client/maker-app/src-tauri` (its own Cargo.lock; if the Tauri crate does not build on this Mac without extra system libraries, run `cargo test --lib` and say exactly what failed to build and why), `cargo fmt --all --check` and `cargo clippy` where `rust-client.yml` runs them, and `node --test client/maker-app/test`. Mutation-check the legacy-string case (make `load_credential` reject strings → its test red; restore).

- [ ] **Step 6: Commit** (one or two commits on `claude/d-desktop-sign-in` in that repo) — "The desktop app signs in to the Tinkerex server and syncs against the grant it is handed" and, if split, "The app is Tinkerex: identity, first-run form, README". Do NOT push.

---

### Task 4 (orchestrator): merge, gates, the cross-stack proof, docs, PRs

1. Merge Tasks 1 and 2 into `claude/d-desktop-sign-in` here; `bin/ci` (three identical run counts; the chunk_remote leg now exercises the grant against the real local server).
2. Cross-stack proof: with `bin/sync-server prepare && bin/sync-server start` and the maker app booted in `chunk_remote` mode (`LIBRARY_BACKEND=chunk_remote`, the env from `tmp/sync-server.env`, `ENABLE_TEST_SIGNUP=1`), run the client's `device_login` against the maker app (a tiny `cargo run --example` or the existing `two_device_e2e` path) and use the grant for `whoami` and `/v1/tree` on the sync server; record the numbers in both PR bodies.
3. CLAUDE.md §8: one line (ceiling 1,362 — pay for it by trimming history elsewhere); `docs/AUDIT-2026-10-12-readiness.md` §2.2 items 1 and 3 marked fixed by D1; `docs/user-stories.md` if a story's friction changes.
4. Two PRs, one per repo, each body naming the other; `bin/log arc --from-pr <n>` for the maker PR; `bin/log open` for D2 (prerequisite checks, offline indicator, Linux/Windows legs) and D3 (signing, releases, updater); the operator item for the owner: an NPM proxy host for `sync.tinkerex.home` if none exists.
