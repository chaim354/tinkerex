# Readiness audit — presentable, usable, safe (2026-10-12)

**Scope:** `chaim354/tinkerex` (main @ `3771cf29`; origin/main is 6 commits ahead via PR #388, merged
today) and the three siblings `tinkerex-sync`, `tinkerex-client`, `tinkerex-addons` (each one PR behind
origin/main: the "public-safety-review" PRs #21, #11, #17 merged today). Read-only: nothing was modified,
deployed, or checked out. Four parallel read-only audits plus direct probes of the live hosts.
Every claim carries its evidence; **CONFIRMED** = the code path was read end to end, **PLAUSIBLE** =
not fully confirmable from the repo (live config, GitHub settings).

Companion gates that ran clean today: `bin/ci scan` (brakeman: 0 warnings, 2 obsolete ignore entries),
`bundler-audit check --update` (0 vulnerabilities, advisory DB of 2026-10-10).

---

## 0. Live state, measured

| probe | result |
|---|---|
| `https://tinkerex.com/up` | 200; `/users/sign_up` 200; `http://` → 301 |
| `https://tinkerex.com/explore` | **404** — the route landed 2026-09-06 (`6c1b9b3e`), so the OVH image predates it by ≥5 weeks |
| `https://www.tinkerex.com/*` | **525** at Cloudflare's edge; the origin answers 404 for that Host (kamal-proxy has no app registered for it) |
| OVH overlay | declares **no** `proxy:` block, so it inherits the base's `hosts: chunk.tinkerex.{local,home}` (`config/deploy.yml:59-62`; the design intended `tinkerex.com` + an origin cert — `docs/superpowers/specs/2026-07-26-ovh-tinkerex-domain-tls-design.md`) — **PLAUSIBLE: the next `kamal deploy -d ovh` routes only the LAN names and takes the apex down** |
| `ENABLE_TEST_SIGNUP` on tinkerex.com | inherited from the base at the last OVH deploy (`config/deploy.yml:119`); PR #388 blanks it in the overlay but **that is not deployed** (PR body: "The OVH change is not deployed") |
| last recorded deploy | tinkerex#341 = `3771cf29` (the slice-7 merge) to the three Unraid destinations |
| Kaneo record | 341 tasks, **24 open**; `bin/log status` clean, but #388 and today's three sibling PRs have no arc filed |

---

## 1. SAFE — findings, ranked

**Fixed by sub-project A (`docs/superpowers/plans/2026-10-12-a-stop-the-bleeding.md`, same day):**
items 4, 5, 7, 8 and 10 below, and the §0 OVH proxy row — on `main` once that PR merges, on the
live OVH box once it is deployed (`-d ovh`, explicit request per CLAUDE.md §7). The rest stand.

1. **On `share` and `s3` every account indexes the same library root.** Open registration there hands a
   stranger read/write/delete on the operator's files. `app/jobs/library/scan_job.rb:126-131,155-158`
   (one `adapter.root`, every user enqueued); `app/services/file_layer/share.rb:10-11,637-640` (root +
   `storage_path`, no user segment); `app/services/file_layer/s3.rb:51,1158-1164` (prefix + rel, no user).
   Per-user isolation exists only on `chunk_remote` (§8). Today only the absent mail server stops it, and
   the test seam bypasses that. **critical · CONFIRMED.** Fix shape: a registration gate that is closed by
   default on self-host and refuses open signup unless the backend is per-user; longer term a per-user
   root/prefix on share/s3.
2. **No "registration closed" mode exists.** `app/models/user.rb:108` (`:registerable` unconditional),
   `config/routes.rb:49-56`, no gate in `app/controllers/users/registrations_controller.rb`; grep for
   `ALLOW_SIGNUP|REGISTRATION_|invite|allowlist` is empty. On chunk_remote a stranger gets a lazily
   provisioned remote library on your sync server. **high · CONFIRMED.**
3. **Going public turns fork PRs into code execution on the LAN runners.** `.github/workflows/ci.yml:4`
   (`on: pull_request`) with `runs-on: [self-hosted, linux]` (`:145,167,176,196,208,220,239`);
   `ops/ci-runner-stack.yml:131-134` grants `SYS_PTRACE` + `seccomp:unconfined` on the Unraid Docker
   host that reaches `.95/.2/.7`. GitHub's default requires approval only for first-time contributors.
   **high · PLAUSIBLE** (repo settings not visible from code). Fix: "Require approval for all outside
   collaborators", or `if: github.event.pull_request.head.repo.full_name == github.repository`, and
   network-isolate the runners.
4. **`ENABLE_TEST_SIGNUP: true` is the base deploy default, and the seam is an email oracle.**
   `config/deploy.yml:119-120`; `config/routes.rb:524-526`; `app/controllers/v1/test_users_controller.rb:14-23`
   answers 201 + `user_id` for an existing address with no password check, and mints confirmed accounts
   otherwise, unthrottled. **medium · CONFIRMED.** Fix: blank in the base, set only in the harness env.
5. **`POST /v1/devices/login` has no per-IP throttle.** Credential stuffing, and a trivial lockout DoS:
   lockable locks after 10 misses for 1 h (`config/initializers/devise.rb:239-242`) and the lock also
   blocks web sign-in. `app/controllers/v1/devices_controller.rb:13-41` has no `rate_limit`; web login is
   throttled (`users/sessions_controller.rb:13`). `ActionController::API` includes `RateLimiting`, one line.
   **medium · CONFIRMED.**
6. **Private-page thumbnails are perpetual unauthenticated signed URLs.** `files_controller.rb:382,483`,
   `application_helper.rb:54`, `v1/maker/previews_controller.rb:114` use `url_for(preview.asset)` →
   `/rails/active_storage/blobs/redirect/<signed_id>` served outside `ApplicationController`;
   `ActiveStorage.urls_expire_in` is nil (nothing in `config/` sets it). Residual of #278, which was fixed
   on the public surface only. **medium-low · CONFIRMED.** Fix: `config.active_storage.urls_expire_in`.
7. **The unlisted-project token `k` is written to logs.** `config/initializers/filter_parameter_logging.rb:6-8`
   filters `token` but not `k`; `csp_reports_controller.rb:60-70` logs `document-uri` with its query.
   **low-medium · CONFIRMED.**
8. **Anonymous surfaces are unthrottled and do real work.** No `rate_limit` in `app/controllers/public/*`;
   a page render enqueues up to 100 render jobs (`maker/previews/thumbnail_map.rb:40,129-141`), `#view`
   enqueues geometry (`public/files_controller.rb:74,158-169`); on share the byte route streams any size
   through Puma (`concerns/file_delivery.rb:80`). **medium-low · CONFIRMED.**
9. **Session: idle timeout 2 weeks (`devise.rb:213`), `Secure` cookie only under `FORCE_SSL`**
   (`production.rb:39-45`), which only OVH sets (`deploy.ovh.yml:163`). **low · CONFIRMED.**
10. **`APP_HOST` is set by no destination** (`git grep APP_HOST config/deploy*.yml .kamal/` is empty), so
    confirmation and reset links point at `APP_HOST-IS-NOT-SET.invalid` (`production.rb:116-119`);
    `config.hosts` is unset (`:140-147`). Mailer links do NOT come from the request Host, so a crafted
    Host cannot poison a reset link. **function blocker · CONFIRMED.**
11. **Supplier URL is unvalidated → `javascript:` href (self-XSS).** `app/views/suppliers/index.html.erb:18`;
    `app/models/maker/supplier.rb:21` validates name only. **low · CONFIRMED.**
12. **Publish hygiene.** The demo password is in history (`git log -S'MakerDemo2026'` → `d1057f07 e504d412
    8bbe3352 da9d4232`); #388 says to rotate the three `demo@tinkerex.local` accounts. Identifiers that go
    public with the repo: OVH IP + ssh user (`deploy.ovh.yml:26,29`, `DEPLOY.md:9,33`), R2 account id +
    bucket (`deploy.ovh.yml:141-142`), SeaweedFS access-key id + LAN endpoint (`deploy.s3.yml`), 1Password
    vault/item names, LAN topology across 31 docs files. A regex sweep of all 2,283 commits found no
    credential-shaped strings; `config/*.key` was never committed. **low · CONFIRMED.**
13. Sync accessory proxied with `ssl: false` (`config/deploy.yml:341-345`): device bearer tokens in plain
    HTTP on LAN/Tailscale. Fine while nothing forwards `sync.*` to the internet. **low · CONFIRMED.**
14. Registration still says "already been taken" (enumeration); paranoid mode covers the other doors
    (`devise.rb:102`). **low · CONFIRMED.**
15. Authenticated uploads buffer up to 256 MB in memory per request (`share.rb:829-833`) × 16 threads. **low.**
16. Client: device token plaintext in `credentials.json` (owner-only, atomic — `src-tauri/src/lib.rs:313-329`);
    `csp: null` with `withGlobalTauri: true` (`tauri.conf.json:10,19`). **low · PLAUSIBLE.**
17. Addons: the GPL guard's second half runs only if a `LICENSE*`/`COPYING*` file exists under `addons/`
    (`test/no_gpl_in_bundle_image_test.sh:21-26`); no CI at all. **low · PLAUSIBLE weakness, no violation found.**

**Open record rows that are already fixed on main — close them:**
- **#278** fixed: `public/files_controller.rb:90-110` (302 to a 5-minute service URL, `expires_in 1.minute`);
  every public view uses `pub.preview_url_for`; guarded in `test/architecture_invariants_test.rb`.
- **#279** fixed: `public/users_controller.rb:16,27-34,59-61,76-77` (`PAGE = 60`, one COUNT, bounded covers).
- **#283** fixed: `maker/public_project.rb:239-241,297-317`; `public/boms_controller.rb:21`; `public/bundles_controller.rb:36`.
- **#126** mostly stale: inventory items, BOM, suppliers/locations, tags have web UI (see §2.3).
- **#134** fixed by #388 — close once OVH is deployed.

**Checked and found safe** (with the file that proves it): `Public::` is sessionless
(`public/base_controller.rb:6`, `shell_helper.rb:85-89`, guard in `architecture_invariants_test.rb:1066-1112`);
visibility/unlisted compare constant-time (`public/base_controller.rb:37-51`); `Maker::PublicProject#permits?`
is the one authority (`public_project.rb:456-481,518-523`); path traversal (`share.rb:637-640,727-743`;
`s3.rb:1158-1164`); delivery forces SVG/HTML to attachment + nosniff (`concerns/file_delivery.rb:23-26,43-44,63-69`);
addon proxy: URL only from ENV by manifest name, 20 MB streaming cap, content-type allowlist excluding SVG
(`tools/addons_controller.rb:873-877,1279-1285`; `service_proxy.rb:23-116`); v1 tokens 256-bit, SHA-256 at
rest (`device.rb:11-25`); CSRF skipped only on the CSP sink and the addon asset GET; no `html_safe`/`raw`/
`innerHTML` on user content; Markdown through Rails' sanitizer (`maker/markdown.rb:30-40,85-89`); Devise
10..128 chars, stretches 12, paranoid, lockable, reset 6 h, deletion requires password; `bin/secret` keeps
values on fd1; `bin/sync-server` prints the env file redacted (origin); nothing copyleft is linked (LGPL
`occt-import-js` wasm shipped unmodified with licence + source pointer; GPL sidecars are separate images
over HTTP; F3D/OCCT as a subprocess; rugged is GPLv2-with-linking-exception).

---

## 2. USABLE — what blocks a stranger, in the order they hit it

### 2.1 Installing the web app (self-host)

1. **Nothing tells them anything.** `README.md:1-24` is the Rails scaffold; `docs/DEPLOY.md:1` is titled
   "Deploy the sync server with Kamal" and is the author's Mac→ghcr→Unraid/OVH runbook.
2. **No image they can pull.** Every image is a private ghcr package (`config/deploy.yml:64-73`;
   `ghcr.io/chaim354/tinkerex-sync` and `…/tinkerex-addons` answer 403 anonymously — measured). Package
   visibility is set at first push and does **not** follow the repo's. Buildable from a clone, **amd64 only**
   (`Dockerfile:109,123,128` hard-code x86_64 F3D/pdfium).
3. **`config/credentials.yml.enc` is committed and baked into the image.** A stranger must regenerate it;
   `SECRET_KEY_BASE` alone boots share/s3, but **chunk_remote needs the three `active_record_encryption.*`
   keys that exist only in the author's credentials** (`config/initializers/active_record_encryption.rb:1-9,42`)
   — the raise is lazy and fires on the first per-user provisioning (`user.rb:40`; `chunk_remote/provisioning.rb:59`).
4. **`LIBRARY_BACKEND` unset is the worst case:** the factory defaults to `share` (`app/services/file_layer.rb:170`)
   but the boot guard's default is `chunk` (`lib/library_backend_check.rb:95-100`), which matches no arm —
   the app **boots cleanly, then 500s on the first library touch**.
5. **Background work silently never runs** without `SOLID_QUEUE_IN_PUMA` (`config/puma.rb:38`) or a `bin/jobs`
   container: scans, thumbnails, trash purge, intake, changelog pull are all recurring tasks
   (`config/recurring.yml`). Stock `RAILS_MAX_THREADS=3` starves once a sidecar is proxied (author runs 16).
6. **No first account can be completed.** Signup is open but `:confirmable` with `allow_unconfirmed_access_for
   = 0.days` (`devise.rb:157`); **no SMTP knob exists at all** (`production.rb:121-128` commented; credentials
   hold only `secret_key_base` and `active_record_encryption` — measured); `APP_HOST` set nowhere; the
   failed delivery is rescued into "Your account was created, but the confirmation email could not be sent"
   (`users/registrations_controller.rb:20-23`). No admin role, no first-user bootstrap (`users` has no role
   column; `user.rb:164-170` only reserves the handle "admin"). Escape hatches: the test seam or `rails runner`.
7. **share** needs `LIBRARY_PATH` writable as uid/gid 1000 by a real touch-probe (`library_backend_check.rb:147-206`;
   `Dockerfile:167-169`); an unmounted mount point is indistinguishable at boot; `.trash/` lives inside the
   share; **every user indexes the same path** (§1.1). **s3**: three required knobs, path-style forced, bucket
   CORS manual (`DEPLOY.md:743-776`), validated live only on SeaweedFS and R2. **chunk_remote**: the sync
   server (private image), `SYNC_ADMIN_TOKEN` byte-identical on both, the encryption keys (item 3), and a
   device token issued on the sync host's CLI — the maker app's own `/v1/devices/login` mints a maker-API
   token only.
8. **Durability.** One volume `/rails/storage` holds the four SQLite DBs **plus** Active Storage previews
   (`production.rb:25`; record #160: not backed up); WAL-safe backup is only `sqlite3 .backup` and the only
   tooling is author-specific (`ops/backup-db.sh`, `bin/backup-cron-install`); all accessories run `:latest`
   unpinned (`deploy.yml:239,246,258,309`); regenerating credentials after chunk_remote users exist makes
   every `sync_device_token` undecryptable.
9. **Tools gallery** is empty without the private addons image; greyed cards tell the user to set
   `ADDON_SERVICE_<X>_URL` (`maker/addons/registry.rb:55-56`; `tools/home/index.html.erb:19-21`).

Complete env-var table, services table and a described docker-compose for `share` and `chunk_remote`:
see the install-path audit's tables, reproduced in §5 below.

### 2.2 The desktop client (tinkerex-client)

1. **The GUI's only sign-in door does not exist on the production sync server.** `index.html:30-52` →
   `main.js:209-214` → `src-tauri/src/lib.rs:488-497` → `sync-client/src/lib.rs:455-469` posts
   `/v1/devices/login`; the sync server draws no such route (`v1_routes.rb:33-83`; Rust `http/mod.rs:49-79`)
   and says so on purpose (`host/app/controllers/v1/devices_controller.rb:4-17`); the maker app serves that
   login but none of `/v1/commit|changes|tree|chunks`. **The shipping app cannot sign in and mount against
   any live server.** Workarounds, undocumented for users: hand-write `credentials.json` with a token from
   `tinkerex-sync device issue`, or the CLI daemons. **CONFIRMED.**
2. **Nothing runnable exists.** No Release, no tags, `build-app.yml` has **never run** (`gh run list` empty);
   unsigned on every OS (`build-app.yml:16-18`); no updater (`tauri.conf.json:1-33`, no `tauri-plugin-updater`);
   no crash reporting.
3. **Identity is boilerplate:** `productName`/window title `maker-app`, `com.chaim.maker-app`, v0.2.1;
   `description = "A Tauri App"`, `authors = ["you"]` (`src-tauri/Cargo.toml:4-5`); first-run form ships
   `http://localhost:3001`, `maker@example.com`, `/tmp/MakerDrive` (`index.html:36,40,48`).
4. OS prerequisites unchecked (Linux libfuse + `user_allow_other`; Windows interactive session —
   `SETUP.md:39-57,160-163`); no offline indicator (`lib.rs:1258-1264`); sync-engine's 92 tests are not in CI;
   Linux/Windows legs never run (one macOS runner, `CI_RUNNERS=macos`).
5. No root README (the app README is the Tauri template); `SETUP.md:87-93` boots a Rails app that does not
   exist here; three comments still say Windows = WinFsp (`sync-engine/Cargo.toml:22`, `daemon.rs:27`,
   `src-tauri/src/lib.rs:13`); dangling references to `docs/building-the-app.md` and `ci/runners/README.md`.
6. The five open PRs #5–#9 are no longer parked WIP: #5/#6/#8 are docs-only records, #7 (themes) and #9
   (pjdfstest liveness) are small and green — merge or close.

### 2.3 The web app itself (a stranger's first hour)

1. **Silent file moves are explained only after the fact.** The intake sweep files loose files and discovery
   turns `Projects/<folder>` into projects (`docs/invariants/project-intake.md`); the only user-facing
   sentences are post-hoc (`projects/_attachments.html.erb:44,104`; `settings/filing_rules/index.html.erb:8-11`).
2. **The empty library never says where files come from.** `home/index.html.erb:21`, `files/index.html.erb:171`,
   `projects/index.html.erb:74` say "Upload"; zero mention of the share path or the desktop client anywhere
   in `app/views`.
3. No in-app help or about link (zero in `app/views/layouts`, `app/views/shared`); scaffold error pages
   (`public/404.html:129`, `500.html`, `422.html`); PWA description is the single word "Tinkerex."
   (`pwa/manifest.json.erb:19`); `config/locales/en.yml:31` still says `hello: "Hello world"`.
4. No Rename/Move for files or folders from the web (design amendment `2026-10-08-structural-redesign-design.md:367-368`;
   user story 1.3); failed previews fall back silently to the extension icon (`thumbs_controller.js:73-76`);
   no banner when the library is unreachable — list pages render from the catalog with thumbnails degraded
   to `{}` (`concerns/page_nodes.rb:15-19`) and only an action produces the alert.
5. **User stories (`docs/user-stories.md`, 50):** 16 works · 29 rough · 3 missing · 1 built-unused · 1 by
   design. The Coverage table at `:149-150` is stale (6.7 moved to `works` on 09-09) and the persona is the
   author by name (`:30`). The notable `missing`: **4.6 — a fresh install re-mints node ids, so notes, tasks,
   build log, tags and boxes do not survive re-pointing at the same NAS** (a self-hoster reinstalling loses
   their annotations).
6. **Models vs web UI:** zero web routes for `Maker::Collection`/`CollectionItem` and `Maker::Item` (v1 only);
   `Tagging` has no door of its own; suppliers/locations are index+create+destroy only; inventory items and
   BOM are full — so record #126 is largely stale.
7. Accessibility basics present (`lang="en"`, 182 `aria-*`, 98 labels, 16/19 `alt`), **no skip link**, 8 of 36
   Stimulus controllers handle keys; i18n is English literals everywhere (fine, stated).

### 2.4 The sync server (tinkerex-sync)

1. **Cutover is done (2026-10-07 18:22 UTC) but the watch week is unrecorded:** nothing records a daily check
   or the first nightly `sync` backup succeeding (cutover plan §0.5 `:210-212`); `bin/backup-status` is the check.
2. **Footgun:** `bin/build-and-push` defaults `SYNC_IMPL=ruby` and moves `:latest` (`:66,76,106-110`); a bare
   run followed by `kamal accessory reboot sync` silently rolls production back to Ruby. Not in any
   remaining-steps list.
3. **The Ruby host cannot be deleted yet:** the conformance verifier boots `test/dummy` and draws
   `Sync.draw_v1_routes` (`test/conformance_test.rb:11,54-62,144`), and the maker's `bin/ci test-chunk-remote`
   still boots the Ruby arm by default (D4, blocked on cargo in `ci/runner/Dockerfile`). Remaining: three
   `gc --dry-run`s then `SYNC_SCHEDULER: "1"` (D3), §9 decommission, D4, client CI URLs, flip build-and-push.
4. **Per endpoint change, five things move** (not three): Ruby + tests, Rust + tests, the corpus re-recorded,
   `docs/sync-protocol.md` in the maker repo, `client/sync-client`.
5. Auth parity Ruby↔Rust is equivalent by reading (`authentication.rb:28-34` ≡ `auth.rs:22-48`; admin door
   `libraries_controller.rb:130-140` ≡ `auth.rs:52-66`) and pinned only by the corpus (`12-edge-cases.yml:479-498`,
   `11-admin.yml:23-87`); not pinned: non-`Bearer` header verbatim, trimming, the 503-when-unset case,
   `last_seen_at`; nothing covers the maker app's third copy.
6. CI: one macOS runner; the Postgres suite, `CONFORMANCE_DATABASE_URL` and S3 round-trip are manual
   (`crates/tinkerex-sync/README.md:91-96`). `Dockerfile.rust:14` builds on floating `rust:1-bookworm`
   while CI pins 1.99.0.
7. Standalone Rust run recipe exists and is coherent (`config.rs:58-131`; `Dockerfile.rust:51-54`;
   `main.rs:114-121` `device issue`); only `crates/tinkerex-sync/README.md` documents it.

---

## 3. PRESENTABLE

1. **Licence.** Maker repo: **no LICENSE** (all rights reserved by default); sync: MIT (`MIT-LICENSE`,
   `gemspec:17`, both `Cargo.toml`); client: Apache-2.0 in all ten crates, root `LICENSE` added today in
   PR #11; addons: MIT. CLAUDE.md §1 says "commercial product" and governs dependencies only.
2. **README.** Maker: scaffold stub. Sync: sells "a mountable Rails engine" (`README.md:1-10`), says "the maker
   app is not pointed at it yet" (`:158-159`, false since 2026-08-25), `:48-51` tells the maker app to set a
   variable it no longer reads; `CLAUDE.md:39-40,316-317` say Ruby runs production (false since 10-07);
   `config/deploy.yml:5-8` is a documented trap. Client: none at root. Addons: current; `README.md:69-70`
   overstates manifest fields; links into a private repo.
3. **Naming.** "Maker Server" (CLAUDE.md §1, `docs/schema-map.html` title) vs "Tinkerex" in every UI string
   (54 + 29 occurrences) vs "maker-app" / "Maker — Sync" / volume "Maker" in the client; sender
   `no-reply@tinkerex.app` (`devise.rb:27`).
4. **docs/ (top level, 50 files):** 7 current, 8 historical-and-marked, ~30 stale-and-unmarked (June-2026,
   pre-separation: `plan-*.md`, `research-*.md`, `cfapi-*`, `versioning.md`, `building-the-app.md`,
   `r2-migration.md`, the two 07/08 audits, `plan-addon-api.md`), 3 delete candidates (`HANDOFF*.md`),
   1 author-only (`DEPLOY.md`: 47 LAN-IP/`op://`/`ssh kamal1@` hits, a stray `</content></invoke>` at
   `:791-792`, dead `STORAGE_BACKEND: memory`/`CHUNK_ENDPOINT` knobs at `:741-742,787-789`).
   `docs/superpowers/`: 192 tracked files; specs are the only written product intent (keep); 20 plans carry
   LAN IPs/`op://` refs. `docs/sync-protocol.md:29,138` says 25 endpoints (26) and "not yet deployed".
5. **GitHub.** Maker repo: empty description/homepage/topics; no releases in any repo; branch protection
   unavailable on the free plan while private (public unlocks it); 8 dependabot PRs open, one of which can
   never pass (`#209`: `test-chunk-remote` clones a private sibling); 5 stale client PRs; locally 28 stale
   `.claude/worktrees/agent-*` and 17 untracked `" 2"` duplicates; client has untracked `.git-rewrite/` and
   `ci/runners 2`.
6. **Record.** #388 and today's sibling PRs unfiled; #278/#279/#283/#126 stale-open; #134 closable after the
   OVH deploy.

---

## 4. Decomposition — sub-projects in recommended order

| # | sub-project | size | closes |
|---|---|---|---|
| A | **Stop the bleeding on the live surface.** Give the OVH overlay its own `proxy` host + origin cert, deploy #388 there, rotate the demo accounts, blank the test seam in the base, throttle device login, filter `k`, set `APP_HOST`/`FORCE_SSL` per destination, `urls_expire_in`, close the stale record rows, file the four arcs. Before any repo goes public: outside-collaborator approval + runner isolation. | days | §1.3–§1.7, §1.10, §1.12, §0 |
| B | **Accounts that work.** SMTP env knobs, `APP_HOST`, a registration mode (closed by default on self-host; open only where tenancy is per-user), a first-owner bootstrap (rake task or first-signup-is-owner), delete the test seam from the base, single-tenant share/s3 made explicit. | 1–2 weeks | §1.1, §1.2, §2.1.6 |
| C | **A stranger can install it.** Public images or a documented build, docker-compose + Unraid template for `share` and `chunk_remote`, credentials regeneration (or encryption keys from env), the `LIBRARY_BACKEND` guard-default fix, `SOLID_QUEUE_IN_PUMA` default, previews volume in backups, pinned accessory tags, a real README + install guide, prune `docs/`. | 2–3 weeks | §2.1, §3.2, §3.4 |
| D | **The desktop client can sign in.** Decide where device enrolment lives (the maker app brokering a sync-server token through its admin door is the shape §8 already built), then: product name + identifier, first-run form, OS prerequisite checks, offline indicator, signing/notarization, `app-v*` releases, updater. | 4–8 weeks, cross-repo | §2.2 |
| E | **Finish the Rust cutover.** Record the watch week, flip `build-and-push`'s default, D3/D4, §9 decommission, rewrite sync README/CLAUDE, Postgres in CI. | 1–2 weeks | §2.4 |
| F | **Onboarding and explanation.** Empty states that name the three ways files arrive, explain intake/discovery before it moves anything, help page, error pages, rename/move, library-unreachable banner, hide operator vocabulary, story 4.6. | 2–3 weeks | §2.3 |
| G | **Presentable repos.** Licence decision, READMEs, naming, GitHub metadata, stale PRs/worktrees/duplicates, mark or delete stale docs, fix sibling contradictions. | 1 week | §3 |

A → B → C → G → F is the self-host web-app path; D and E are parallel tracks. D does not have to block a
first release if the first audience is NAS self-hosters on the `share` backend.

---

## 5. Reference tables (from the install-path audit)

### Environment variables the maker app reads (⚑ = required for that mode, no default)

| var | req? | default | needed by | read at |
|---|---|---|---|---|
| `RAILS_MASTER_KEY` / `SECRET_KEY_BASE` | one ⚑ | — | boot; encryption keys only via master key | `Dockerfile:6`; `DEPLOY.md:184-249` |
| `LIBRARY_BACKEND` | ⚑ (unset = boots then 500s) | factory `share` / guard `chunk` | everything | `file_layer.rb:170`; `library_backend_check.rb:95` |
| `LIBRARY_PATH` | ⚑ share | — | share | `share.rb:10`; `library_backend_check.rb:148` |
| `LIBRARY_S3_BUCKET`, `_ACCESS_KEY_ID`, `_SECRET_ACCESS_KEY` | ⚑ s3 | — | s3 | `library_backend_check.rb:45`; `s3.rb:24-27` |
| `LIBRARY_S3_REGION` / `_ENDPOINT` / `_PREFIX` | opt | `auto` / nil / nil | s3 | `s3.rb:25-29` |
| `CHUNK_REMOTE_URL`, `SYNC_ADMIN_TOKEN` | ⚑ chunk_remote (token identical on the sync server) | — | chunk_remote | `library_backend_check.rb:78,117-128`; `provisioning.rb:130-137` |
| `SOLID_QUEUE_IN_PUMA` | ⚑ single-container | unset = no jobs | all background work | `puma.rb:38` |
| `RAILS_MAX_THREADS` | opt | 3 | perf (author: 16) | `puma.rb:28` |
| `APP_HOST`, `FORCE_SSL` | ⚑ for working mail links / TLS | placeholder / off | mail URLs, cookies | `production.rb:39-45,116-119` |
| `ENABLE_TEST_SIGNUP` | dangerous | off | `POST /v1/test/users` | `test_users_controller.rb:15` |
| `DATABASE_URL` (+ `DB_SSLMODE`, `SOLID_*_DATABASE_URL`) | opt | SQLite | Postgres mode | `database.yml:49-53,99-119` |
| `ADDON_SOURCE_URL` / `ADDON_SOURCE_PATH` | opt | empty gallery | Tools | `addons/source.rb:25-32` |
| `BOXES_SIDECAR_URL`, `OPENSCAD_SIDECAR_URL` | opt | addon greyed | Tools | `addons/services.rb:35,41` |
| `ADDON_SERVICE_MAX_TIMEOUT`, `ADDON_SAVE_MAX_FILES`, `ADDON_SAVE_MAX_BYTES` | opt | 120 s / 8 / 4 MB | addons | `service_proxy.rb:46,62`; `addons_controller.rb:12,33` |
| `LIBRARY_TRASH_DAYS`, `LIBRARY_SCAN_MAX_DELETE_PCT`, `PREVIEW_MAX_BYTES` | opt | 30 / 20 / 32 MB | share/s3, scan, previews | `trash_purge_job.rb:33`; `reconciler.rb:57`; `generate_preview_job.rb:59` |
| `PROJECT_ORGANIZE_MAX_MOVES`, `PROJECT_DISCOVERY_MAX`, `MODEL_CATALOG_MAX_MODELS` | opt | 500 / 50 / 200 | intake | `project_intake.rb`; `project_discovery.rb`; `model_intake.rb` |
| `*_BIN` renderer paths, `GERBER_RENDER_TIMEOUT` | opt | image provides | thumbnails | `Dockerfile:177-197` |
| `OMNIAUTH_ENABLED`, `OIDC_*` | opt | off | OIDC login | `initializers/omniauth.rb:4-15` |
| SMTP | **no variable exists** | — | confirmation mail | `production.rb:121-128` |

### Services for a full install

| service | image | pullable by a stranger? | required? |
|---|---|---|---|
| Rails app | `ghcr.io/chaim354/tinkerex` | no; buildable, amd64 only | yes |
| DB | SQLite on `/rails/storage` (Postgres optional) | n/a | — |
| Sync server | `ghcr.io/chaim354/tinkerex-sync` | no; buildable from clone with no secret | chunk_remote only |
| Addons host | `ghcr.io/chaim354/tinkerex-addons` | no; buildable; or `ADDON_SOURCE_PATH` at a checkout | optional (empty gallery) |
| boxes / openscad sidecars | `ghcr.io/chaim354/{boxes,openscad}-sidecar` | no; `sidecar/*/Dockerfile` builds them | optional (greyed) |
| S3 store | user's own (SeaweedFS, R2 validated) | n/a | s3 only |
| SMTP | none configured, no knob | n/a | needed for confirmable signup |
| Job runner | in-Puma or `bin/jobs` | — | yes |

### docker-compose, described (not written)

**`share`, single user:** one `web` service from the image or `build: .`; `ports 8080:80`; healthcheck
`/up`; volumes `tinkerex_storage:/rails/storage` and `<library dir>:/library` (host dir owned by 1000);
env `SECRET_KEY_BASE` (or `RAILS_MASTER_KEY` with regenerated credentials), `LIBRARY_BACKEND=share`,
`LIBRARY_PATH=/library`, `SOLID_QUEUE_IN_PUMA=true`, `RAILS_MAX_THREADS=16`, `APP_HOST`; optional
`boxes`/`openscad` services built from `sidecar/` with their `*_SIDECAR_URL`s. Until B lands, the first
account needs `ENABLE_TEST_SIGNUP=true` once or a `rails runner` snippet.

**`chunk_remote`:** add a `sync` service (built from the sibling) with `STORAGE_BACKEND=local`,
`CHUNK_LOCAL_DIR` on a volume, its own `SECRET_KEY_BASE`, the shared `SYNC_ADMIN_TOKEN`, port 3000 for
devices; `web` gets `LIBRARY_BACKEND=chunk_remote`, `CHUNK_REMOTE_URL=http://sync:3000`, the same token,
and **`RAILS_MASTER_KEY` + regenerated credentials carrying `active_record_encryption.*`**.

---

## 6. Before a repo goes public — the steps that are impossible while it is private

1. **Actions → "Require approval for all outside collaborators"** on each repo, in the same
   sitting as the visibility flip:
   `gh api -X PUT repos/chaim354/<repo>/actions/permissions/fork-pr-contributor-approval -f approval_policy=all_external_contributors`.
   The API refuses this on a private repo (measured 2026-10-12: "Fork PR approval is not allowed
   for private repositories"), which is why `.github/workflows/ci.yml` carries its own fork guard on
   every job, pinned by `test/ci_hygiene_test.rb`. The siblings' workflows do not carry one yet.
2. **Branch protection on `main`** (required checks = the seven `ci.yml` jobs; no force-push) — also
   unavailable on the free plan while private (the API answers 403 "Upgrade to GitHub Pro or make
   this repository public").
3. **ghcr package visibility** is set per package and does NOT follow the repo
   (`config/deploy.yml:64-73`). Decide which images a stranger may pull and flip them deliberately;
   three of the packages answered 403 anonymously on 2026-10-12.
4. **Rotate anything that was ever a literal in history** — the demo password
   (`git log -S'MakerDemo2026'`) per §1.12; grep the history, not the tree.
5. **Runner isolation**: the Unraid runner containers reach the LAN (`ops/ci-runner-stack.yml`);
   put them on their own network before the first outside PR is approved.
6. **Workflow token permissions** are already read-only (`default_workflow_permissions: read`,
   measured); keep them so.
