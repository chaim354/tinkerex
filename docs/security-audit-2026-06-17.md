> **HISTORICAL — RESCUED, NOT RE-VERIFIED.** Recovered from the deleted branch
> `night/security-audit` (tip `cb90ed8`) on 2026-09-01; it existed nowhere else. It audits the
> tree as of **2026-06-17**, when the sync engine and the Rust client still lived in this repo,
> so several locations it cites (`client/maker-app/…`, `Sync::*`) are no longer here at all.
> **No finding below has been re-checked against the current tree.** Some are visibly addressed
> — CLAUDE.md §14e now carries both a CSP bullet and a rate-limiting one, and §14a makes
> `disposition:` required rather than defaulted — but treat every mapping as a lead to verify,
> not a status. Kept for the reasoning and the threat model, which is why §10 keeps
> `docs/architecture-sync-engine.md` on the same terms.

# Security Audit — Maker Server (Tinkerex)

**Date:** 2026-06-17
**Auditor:** External penetration test (authorized, code-only; no live exploitation)
**Branch audited:** `night/security-audit` (off `maker-lite/phase0`, HEAD `70c5b34`)
**Scope:** Rails server (`app/`, `config/`, `lib/`), Rust client (`client/`). All layers per the engagement brief.

> Methodology note: findings are grounded in the **actual code**, not in `CLAUDE.md`/`docs/`.
> Where the developers' docs claim a property the code does not deliver, that gap is called
> out explicitly. The codebase is, on the whole, carefully written — tenant scoping is
> consistent and the per-user chunk keyspace genuinely defeats the dedup-disclosure class of
> attack (see "Checked and found safe"). The findings below are the real divergences.

---

## Severity summary

| Severity | Count | Items |
|---|---|---|
| Critical | 0 | — |
| High | 1 | H1 (device token stored in world-readable temp dir, no expiry/revocation) |
| Medium | 4 | M1 (no TLS/HSTS enforcement + insecure session cookie), M2 (inline serving of attacker-controlled file bytes → stored XSS in app origin), M3 (no CSP at all), M4 (no IP rate limiting on auth → account-lockout DoS + credential stuffing) |
| Low | 4 | L1 (commit `finalize` with `verify:false` in v1 path), L2 (dev blob endpoint has no per-user auth), L3 (unsanitized values interpolated into generated preview SVG), L4 (symlink-target / name fully trusted from server in client apply) |
| Info | 2 | I1 (test-signup + dev-blob seams), I2 (mass-assignment of unvalidated foreign-key ids) |

---

## High

### H1 — Device bearer token persisted in plaintext in a world-readable temp directory; tokens never expire or get revoked

**Severity:** High
**Location:** `client/maker-app/src-tauri/src/lib.rs:117-187` (`app_base`, `creds_path`, `save_token`, `load_token`); server side `app/models/device.rb:11-29`.

**What an attacker can do.** A device token is a 256-bit bearer credential that grants **full
read/write access to the entire user library** (it is the only auth the v1 API and ActionCable
require). The client writes it in cleartext to:

```
std::env::temp_dir()/maker-app/credentials.json
```

`creds_path()` derives from `app_base() = std::env::temp_dir().join("maker-app")`, and
`save_token` does a plain `std::fs::write(creds_path(), json)` with no restrictive permissions,
no OS keychain, no encryption. On a shared *nix host `std::env::temp_dir()` is `/tmp` (mode
1777, world-readable+traversable); any local user (or any other app/process running as the
victim, or a backup/sync tool that captures `/tmp`) can read the file and exfiltrate the bearer
token. The file persists across reboots only if `/tmp` does, but on macOS it lands in a
per-user but still non-keychain temp dir, and on any box a co-resident process reads it trivially.

Once stolen, the token works from anywhere:
```
curl -H "Authorization: Bearer <stolen>" https://server/v1/tree
curl -H "Authorization: Bearer <stolen>" https://server/v1/chunks/download -d 'hashes[]=...'  # presigned GETs to all the victim's bytes
```

**Why it works.** `Device.authenticate` only checks `find_by(token_digest: digest(token))` — there
is **no expiry, no rotation, no per-token revocation endpoint, and no binding to IP/device
fingerprint**. `touch_seen!` updates `last_seen_at` but nothing ever invalidates a token. So a
single filesystem read = permanent account compromise until the user deletes the device row
(there is no UI/endpoint shown for that either). `CLAUDE.md §8` states the token is "256-bit,
SHA256-digested at rest" — true on the **server**, but the **client** holds the live plaintext
in `/tmp`, which the docs gloss over.

**Fix recommendation.**
- Store the token in the OS secret store (macOS Keychain / Windows Credential Manager / libsecret),
  e.g. via the `keyring` crate, instead of a temp-dir JSON file.
- At minimum, write it under the app's private data dir (`$XDG_DATA_HOME`/`~/Library/Application
  Support`) with `0600` perms — never `std::env::temp_dir()`.
- Server-side: add token expiry + a revoke/rotate endpoint and a "sign out all devices" action;
  consider binding tokens to a last-seen IP/UA and alerting on change.

---

## Medium

### M1 — Production does not enforce TLS; session cookies are not marked Secure / no HSTS

**Severity:** Medium
**Location:** `config/environments/production.rb:31` (`# config.force_ssl = true` — commented out), `:28` (`# config.assume_ssl` commented out). No `config/initializers/session_store.rb` (defaults; no `secure:`/`same_site:` override).

**What an attacker can do.** With `force_ssl` disabled, Rails does not (a) redirect HTTP→HTTPS,
(b) set `Secure` on the session/`remember_me` cookies, or (c) emit HSTS. If the deployment ever
terminates or proxies plain HTTP (the documented self-host story is an Unraid box on a LAN, and
the Kamal/`deploy.*.yml` configs don't guarantee TLS to the origin), a network attacker (same
LAN, malicious Wi-Fi, on-path) can read the Devise session cookie in cleartext and hijack the
authenticated web session, or strip TLS on first contact. The human-auth web surface
(`FilesController`, `TrashController`, all Devise flows) is entirely cookie-authed.

**Why it works.** The whole-app HTTPS enforcement switch is commented out and no session-store
initializer re-asserts `secure: true`. The brief's framing — "the password crosses the wire once
(TLS)" — is an assumption the app code does not enforce.

**Fix.** Set `config.force_ssl = true` in production (with `assume_ssl` if behind a TLS-terminating
proxy), and explicitly configure the session store with `secure: true, same_site: :lax,
httponly: true`. For pure-LAN self-host, document the TLS requirement loudly.

### M2 — `FilesController#blob` serves attacker-controlled file bytes **inline** with an attacker-controlled Content-Type → stored XSS in the application origin

**Severity:** Medium (self-stored XSS today; rises if file sharing to other users lands)
**Location:** `app/controllers/files_controller.rb:85-111` (`blob`), and `app/views/files/show.html.erb:24-30`.

**What an attacker can do.** `blob` sets:
```ruby
response.headers["Content-Type"] = Marcel::MimeType.for(name: filename)   # derived from the file NAME
response.headers["Content-Disposition"] = ...disposition: "inline"...      # inline unless ?download=1
```
So a user who uploads `pwn.svg` or `pwn.html` (the upload path accepts any name/bytes) and then
opens `/files/:id/blob` is served the bytes **inline, same-origin, with `text/html` or
`image/svg+xml`**. SVG and HTML both execute JavaScript when rendered inline. `show.html.erb`
additionally embeds SVG files via `<img src=blob>` (img-loaded SVG won't run script, but a direct
visit to the blob URL, or a `text/html` file, will). Script then runs in the Tinkerex origin with
the victim's session cookie — it can drive the whole web app as the victim.

Note this is the **opposite** of how the *preview* assets are served: ActiveStorage forces
`image/svg+xml` to `attachment` (verified — `content_types_to_serve_as_binary` includes
`image/svg+xml` in Rails 8.1), so the preview path is safe. This custom `blob` endpoint bypasses
that protection.

Today it is primarily **self-XSS** (a user can only reach their own files; `find_by!(node_id:)`
is `current_user`-scoped). Severity is Medium not Low because (a) there is **no CSP** to blunt it
(M3), (b) the share-link feature already exists and the planned "Spaces" sharing would let one
user's uploaded HTML/SVG be opened by another, turning this into cross-user stored XSS, and (c)
it's a latent footgun the moment any "view this file" link is shared.

**Why it works.** No allowlist of inline-safe content types; `disposition` defaults to `inline`;
Content-Type is taken from the user-named file.

**Fix.** Force `Content-Disposition: attachment` for everything except a small allowlist of known-safe
types (images excluding SVG, plain text, PDF-with-care), serve a sandboxing `Content-Type:
text/plain` or `X-Content-Type-Options: nosniff` for the rest, and never serve `text/html` or
`image/svg+xml` inline from the app origin. Ideally serve user file bytes from a separate,
cookieless origin/domain.

### M3 — No Content-Security-Policy is configured

**Severity:** Medium
**Location:** `config/initializers/content_security_policy.rb` (entire policy block is commented out — the file ships the Rails template with nothing enabled).

**What an attacker can do.** There is no CSP header on any response. This removes the primary
defense-in-depth mitigation for the XSS surface in M2 (and L3), and for any future XSS. A single
injected `<script>` has unrestricted ability to load remote code and exfiltrate.

**Why it works.** The initializer never calls `config.content_security_policy`, so Rails emits no
CSP.

**Fix.** Enable a restrictive CSP (`default-src 'self'`, `script-src 'self'` + a nonce for the
importmap, `object-src 'none'`, `base-uri 'none'`, `frame-ancestors 'none'`). The app already uses
importmap + a CSP nonce comment is present in the template — wiring it up is low-cost.

### M4 — No IP-based rate limiting on authentication endpoints (account-lockout DoS + credential stuffing)

**Severity:** Medium
**Location:** No `rack-attack` (or equivalent) in `Gemfile`/`config`. Auth surface: `app/controllers/v1/devices_controller.rb#login`, all Devise controllers (`sessions`, `passwords`, `registrations`, `confirmations`). Devise `:lockable` configured at `config/initializers/devise.rb` (`maximum_attempts = 10`, `lock_strategy = :failed_attempts`, `unlock_strategy = :time`, `unlock_in = 1.hour`).

**What an attacker can do.**
1. **Account-lockout DoS:** because `lock_strategy = :failed_attempts` with `:time` unlock, an
   unauthenticated attacker who knows a victim's email can send 10 wrong passwords to
   `POST /v1/devices/login` (or the web sign-in) and **lock that account for an hour**, repeatable
   indefinitely → targeted denial of service against any known user.
2. **Credential stuffing / spray:** there is no IP throttle, so an attacker can spread guesses
   across many accounts (≤10 each) at high volume without tripping per-account lockout, and can
   hammer `POST /users/password` (reset) and registration to enumerate/send mail-bombs. The
   `devices#login` handler is careful to return one generic 401 (good, no user enumeration there),
   but volume is unbounded.

**Why it works.** Lockable mitigates single-account brute force but is itself a DoS primitive, and
nothing caps requests per source IP.

**Fix.** Add `rack-attack` (or Rails 8 `rate_limit`) with per-IP throttles on `/v1/devices/login`,
`/users/sign_in`, `/users/password`, `/users/confirmation`, and registration; consider per-IP +
per-account combined counters; prefer a temporary IP-block over (or alongside) account lockout to
avoid the lockout-DoS.

---

## Low

### L1 — v1 `commit/finalize` runs with `verify: false`: a client can publish a version referencing chunks it never uploaded

**Severity:** Low (data-integrity / self-corruption; **not** cross-user disclosure)
**Location:** `app/controllers/v1/commits_controller.rb:20-25` (calls `Sync::Commit.finalize` with no `verify:` → default `false` at `app/services/sync/commit.rb:44`).

**What an attacker can do.** In `Commit.begin`, the server tells the client which manifest chunks
are "missing" (those the user has no `Chunk` row for). At `finalize` with `verify: false`, the
server creates the immutable version + changelog entry and `upsert_chunks!` inserts `Chunk` rows
(refcount=1) for the manifest hashes **without confirming the bytes were actually PUT to storage**.
A malicious/buggy client can therefore register a node/version whose chunks don't exist in its
keyspace — the file is corrupt on hydration (404), a self-inflicted integrity problem and a way to
create dangling `Chunk` rows.

Crucially, this is **not** a cross-user data-disclosure bug: chunks live under
`chunks/<user_id>/<hash>`, and the attacker's later `presign_get(current_user.id, hash)` points at
**their own** empty keyspace, so referencing a hash another user happens to own yields a 404, not
the victim's bytes. (See the dedup analysis in "Checked and found safe.") The **web** upload path
already passes `verify: true` (`files_controller.rb:70`), so it's only the desktop v1 path that
skips verification.

**Why it works.** `finalize`'s default is `verify: false` and the v1 controller doesn't override it.

**Fix.** Pass `verify: true` from `V1::CommitsController#finalize` (matching the web path), or make
`true` the default. The cost is an `exists?`/HEAD per missing chunk at finalize.

### L2 — Dev blob endpoint reads/writes any storage key with no per-user authorization

**Severity:** Low (dev/test only — **not** mounted in production)
**Location:** `app/controllers/dev_blobs_controller.rb` + `app/services/storage/memory_chunk_store.rb:71-78` (`read_blob_key`/`write_blob_key`), routed only `unless Rails.env.production?` (`config/routes.rb:37-39`).

**What an attacker can do.** `GET/PUT /dev/blobs/*key` takes the **full storage key** (`chunks/<user_id>/<hash>`)
straight from the URL path and reads/writes it with no signature and no ownership check
(`skip_forgery_protection`, no auth filter). Anyone who can reach a non-production instance can read
or overwrite **any** user's chunk bytes by guessing/observing keys. This is gated behind
`Rails.env != production` and `MemoryChunkStore`, so it should never exist in a real deployment —
but a staging box, a `RAILS_ENV=development` misconfig, or a dev instance exposed on a LAN would
leak cross-user bytes.

**Why it works.** The dev blob route deliberately trusts the key (it's a local stand-in for object
storage), unlike the `local` backend's signed `V1::Chunks::BlobController` which HMAC-verifies the
URL.

**Fix.** Even in dev, scope `/dev/blobs` to the authenticated user (or reuse the same HMAC-signing
scheme as `LocalChunkStore`). Add a boot-time assertion that neither the dev-blob route nor
`MemoryChunkStore` is ever active under a production-like env / public bind.

### L3 — Unsanitized field values interpolated into generated preview SVG (lbrn2 / dxf)

**Severity:** Low
**Location:** `app/services/maker/previews/lbrn2.rb:68-82` (`normalize_color` returns the raw string verbatim when it starts with `#`) and `:127-128`, `:170-176` (interpolated into `stroke="#{stroke}"`); `app/services/maker/previews/dxf.rb` numeric paths are coerced via `Float()` (safe), but lbrn2 stroke colors are not.

**What an attacker can do.** A crafted `.lbrn2` file with a `<CutSetting>` color like
`#000"/><script>...` flows through `normalize_color` (which returns `s` unchanged because it
`start_with?("#")`) into the emitted SVG string unescaped, injecting arbitrary SVG/JS into the
generated preview asset. **However**, the preview asset is stored via ActiveStorage and served
with a forced `attachment` disposition for `image/svg+xml` (verified), so it does **not** execute
inline — which is why this is Low, not Medium. It would become exploitable if the preview SVG were
ever rendered inline (or piped through the `blob`-style inline path of M2).

**Why it works.** `normalize_color` trusts any `#`-prefixed string; the SVG is built by string
interpolation with no escaping.

**Fix.** Validate stroke colors against a strict `#[0-9a-fA-F]{3,8}` regex (reject otherwise), and
generally emit preview SVG via a builder that escapes attribute values rather than raw interpolation.

### L4 — Client apply trusts server-supplied node names and symlink targets (path/symlink content)

**Severity:** Low (inherent to a sync engine; defense-in-depth gap)
**Location:** `client/fs-provider/src/lib.rs` (`apply_remote` writes `node.name`, `node.symlink_target` verbatim; `:1656` comment explicitly notes it does *not* normalize `.`/`..`).

**What an attacker can do.** A malicious or compromised server (or a future cross-user sharing bug)
can push a node whose `name` is `..`-laden or whose `symlink_target` points outside the mount
(e.g. `/etc/passwd` or `../../`). The provider stores names as DB rows keyed by `parent_ino` (a
tree, not host-path concatenation), so the VFS layer resolves `..` itself and a stray name doesn't
directly escape — but synced **symlink targets are stored and returned verbatim** via `readlink`,
so a synced symlink can point anywhere on the host, and a process following it (the user, a build
tool, git-on-mount) reads/writes outside the library. This is the standard "trust the server" risk
every sync client carries, and the design intentionally syncs symlink targets (git-on-mount), so
it's noted as a hardening item rather than a discrete bug.

**Fix.** Where feasible, reject or sandbox absolute / `..`-escaping symlink targets on apply, or
surface them to the user; treat the server as semi-trusted in the apply path.

---

## Info

### I1 — Test/dev-only auth seams are correctly gated (verify the env at deploy)
`POST /v1/test/users` (`v1/test_users_controller.rb`) is gated by BOTH `!Rails.env.production?`
**and** `ENV["ENABLE_TEST_SIGNUP"]`, and the route is only drawn `unless Rails.env.production?`.
The dev-blob route is likewise non-production-only. These are correctly fenced; the only residual
risk is a misconfigured `RAILS_ENV`. Recommend a boot-time guard that hard-fails if
`ENABLE_TEST_SIGNUP` is set in a production-like deployment.

### I2 — Mass-assignment of unvalidated foreign-key ids in maker controllers
Several maker params permit foreign-key ids that aren't ownership-validated at assignment, e.g.
`file_attachments` accepts arbitrary `node_id`/`version_id` (`v1/maker/file_attachments_controller.rb:33`),
`tasks` accepts polymorphic `taskable_type`/`taskable_id` (`v1/maker/tasks_controller.rb:41`),
`inventory_transaction.apply!` stores an unvalidated `project_id`. These only **store** an id the
attacker already supplied — no other user's data is read back through them (renders echo the id,
not the referenced record), so they are not IDOR-for-disclosure. `bom_line` is the good pattern:
it validates `inventory_item_belongs_to_user`. Recommend extending that validation pattern (confirm
the referenced `node_id`/`taskable`/`project_id` belongs to `current_user`) to the others for
integrity and to prevent dangling cross-tenant references.

---

## What I checked and found SAFE (coverage)

- **Cross-user chunk disclosure via content-addressed dedup (the headline concern).** Examined
  `Sync::Commit.begin`/`finalize`, `upsert_chunks!`, `ChunksController#download`, and all three
  chunk stores. Chunks are stored per-user at `chunks/<user_id>/<hash>`; every presign call uses
  the **requester's own** `user_id` (`current_user.id` in the controller, `owner_id` in sharing).
  Even though `begin` reveals which hashes are "missing" (a tiny existence oracle for a *guessed*
  hash) and a manifest can name any hash, finalizing only creates a `Chunk` row in the attacker's
  keyspace — the bytes referenced live under the victim's key, which the attacker can never presign
  or fetch. `ChunksController#download` additionally gates on `current_user.chunks.where(...)`
  ownership. **The dedup cross-user read is not exploitable.** (Residual: the missing-hash response
  is a hash-existence oracle, but with a SHA-256 preimage requirement it's not practically useful.)

- **Share links.** Token is `SecureRandom.urlsafe_base64(32)` (256-bit), stored only as a SHA-256
  digest; `redeem` re-checks `live?` (revoked/expired) on every request and re-reads the chunk set
  fresh from the immutable manifest, so a link mints presigned GETs for **exactly** that version's
  chunks under the owner's keyspace and nothing else. Revoke/expiry cut access on the next request.
  `ShareLinksController#destroy` is `current_user`-scoped (other users' link ids → 404). Sound.

- **Tenant scoping / IDOR across the v1 API and web controllers.** Every read/mutate in
  `v1/nodes`, `v1/trash`, `v1/locks`, `v1/conflicts`, `v1/search`, `v1/changes`, `v1/tree`,
  `v1/commits`, and all `v1/maker/*` controllers resolves records through `current_user.<assoc>`
  (or passes `user: current_user` into a `Sync::*`/`Sharing::*` service that scopes by `user_id`).
  `FilesController`/`TrashController` likewise (`current_user.nodes…`). I did not find an endpoint
  that fetches a record by a raw client id without a `current_user` scope.

- **SQL injection.** The item search (`v1/maker/items_controller.rb:15-19`) uses
  `sanitize_sql_like` + a bound `:q` placeholder. `Sync::Search.build_sql` interpolates only
  integer-coerced `user_id`/`limit`/`offset` and a `connection.quote`-bound pattern, with an
  adapter-quoted boolean literal. No string-interpolated user input reaches SQL.

- **CSRF on the cookie-authed web endpoints.** `config.load_defaults 8.1` enables
  `default_protect_from_forgery`, and the uploader JS sends `X-CSRF-Token`; the JSON
  `begin_upload`/`finalize_upload`/`destroy` actions inherit `ActionController::Base` forgery
  protection. The v1 API is bearer-token (cookieless) so it isn't CSRF-reachable from a browser.
  ActionCable request-forgery protection is disabled — acceptable because the cable connection
  authenticates by the `token` query param (`ApplicationCable::Connection`), not by cookie, so a
  cross-site cable connect can't ride the victim's session.

- **OAuth/OmniAuth account-takeover.** `User.from_omniauth` only auto-links an IdP email to an
  existing account when the IdP asserts the email **verified** AND the account has **no local
  password**; otherwise it raises `AccountLinkRefused`. Returning identities map by `(provider,uid)`.
  This correctly prevents a malicious/misconfigured IdP from hijacking a password account.

- **Device-login enumeration.** `V1::DevicesController#login` returns a single generic 401 for
  unknown/bad/unconfirmed/locked, and enforces `confirmable` + `lockable`. No user enumeration via
  status codes (the *volume* gap is M4).

- **Preview command injection.** `Mesh` invokes F3D via `Open3.capture3(*args)` (array form, no
  shell); the only filename-derived value is the tempfile **suffix**, sanitized with
  `delete_prefix('.').downcase`. No shell metacharacter reaches a command line.

- **Zip-slip in the 3MF extractor.** `ThreeMf` only *reads* entries into memory
  (`get_input_stream.read`); it never writes files out by entry name, so a malicious entry path
  (`../../evil`) cannot escape — there's no extraction-to-disk step to traverse.

- **SSRF in preview generation.** `Maker::FileBytes` fetches bytes only from the **server-controlled**
  presigned chunk URL for the file's own manifest; there is no user-supplied URL fetched
  server-side (`source_url` on items is stored/echoed, never fetched).

- **Preview SVG asset XSS.** ActiveStorage serves `image/svg+xml` with a forced `attachment`
  disposition (Rails 8.1 default `content_types_to_serve_as_binary` includes it), so the stored
  preview SVG does not execute inline. (The separate `FilesController#blob` inline path is the real
  issue — see M2.)

- **ERB output escaping.** The `files`/`trash` views render user values (`@node.name`, etc.) through
  default ERB `<%= %>` HTML-escaping; `turbo_confirm: "Delete #{node.name}?"` is a data attribute,
  also escaped. No `raw`/`html_safe`/`<%==%>` on user data was found in these views. (The brief's
  concern about `link_to ..., user_url` allowing `javascript:` hrefs does not apply — those
  `Maker::*` web views/controllers don't exist on this branch.)

- **Password/token hygiene.** Device tokens and share/reset tokens are `SecureRandom` + SHA-256
  digested at rest server-side; Devise bcrypt `stretches = 12` in non-test; `secret_key`/`pepper`
  use defaults (no hardcoded secrets committed in `devise.rb`).

---

## Notable doc-vs-code divergences (for the team)

- `CLAUDE.md §8`: "Client holds only a device token (256-bit, SHA256-digested at rest)." — The
  **server** digests it; the **client** stores the live plaintext token in `/tmp` (H1).
- `config/environments/development.rb:73` / `CLAUDE.md`: "the device token is the auth" justifies
  disabling ActionCable forgery protection — correct, but note the web UI itself is cookie-authed
  and depends on `force_ssl` (commented out) for cookie confidentiality (M1).
- The brief referenced `app/controllers/maker/*`, `LibraryController`, and `app/views/maker/library/*`;
  those do **not exist on this branch** (`maker-lite/phase0`). The web surface here is
  `FilesController` + `TrashController` + Devise. Audit them again once the maker-lite web gallery
  controllers land.
