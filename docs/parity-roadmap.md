# Parity Roadmap — Maker Server vs. mainstream cloud drives

> **HISTORICAL — not re-verified.** Written before the repository split of 2026-08-20, when the
> sync engine and the Rust client still lived here (they are `chaim354/tinkerex-sync` and
> `chaim354/tinkerex-client` now). Kept for its reasoning and its measurements; it does not
> describe what this repository contains today. The current map is `docs/README.md`.


**Date:** 2026-06-14 · **Branch context:** `auth-caching-security` (merged to `main`)
**Audience:** project owner (engineer). **Scope:** desktop sync engine + Rails control
plane. **Explicitly out of scope:** mobile (deprioritized) and the web UI (a separate MVP
is in progress — referenced here as in-flight, not planned here).

This is a sequenced plan to reach *selective* parity with Dropbox/Drive/Nextcloud/Seafile
where it serves the maker product, and to *deliberately not* chase parity where it doesn't.
Every "we have / we lack" claim is anchored to our own docs; every competitor rationale to
`docs/research-sync-competitors.md`. Confirmed-vs-inferred is flagged inline.

## Gating filters (apply to every item below)

These come straight from `CLAUDE.md` and are non-negotiable. Each recommendation is
filtered through all four:

1. **Self-hostable AND managed/SaaS** (`CLAUDE.md` §7) — anything cloud-vendor-locked
   (D1/Durable-Objects/Clerk-only/Auth0-only) breaks self-host and is disqualified or
   demoted to managed-only-optional.
2. **Permissive licensing only** — MIT / Apache-2.0 / BSD; **avoid GPL/AGPL** in deps and
   shipped artifacts (`CLAUDE.md` §9). This kills several otherwise-obvious choices below
   (e.g. Keycloak's licensing nuance, AGPL IdPs).
3. **Preserve device-token + single-use pairing underneath** (`CLAUDE.md` §8; live in
   `app/controllers/v1/auth_controller.rb`). Whatever auth we add sits *in front of* this
   bootstrap; the device token + `DevicePairing` mechanism stays the downstream credential.
4. **Bytes out of Rails + content-addressed chunks** (`CLAUDE.md` §6, §15;
   `docs/sync-protocol.md`). Presigned URLs only; Rails is control-plane + URL minter.

## What's already closed since the research doc was written

`docs/research-sync-competitors.md` §4 ranked nine gaps. Two of its top four have since
shipped (per `docs/STATUS.md`, 2026-06-14) and are **removed from this roadmap**:

- **Retention/GC policy job + S3 delete** (research #1) — **DONE**: `Sync::RetentionPolicy`
  (`keep_all` self-host / `tiered` managed), nightly `RetentionJob` via `config/recurring.yml`,
  real S3 `delete_object` in `sweep_orphans!`.
- **Adversarial sync-engine harness, "Trinity"** (research #4) — **DONE**:
  `client/sync-engine/tests/fault_injection.rs`, which *found and fixed two real changelog
  ordering bugs*.
- **Postgres deploy validation** (`CLAUDE.md` §12 step 8) — **DONE** (56/0 on PG/Docker).
- **G2 — managed-Postgres hardening** — **DONE** (2026-06-15): TLS/`sslmode` defaults
  (require for managed, verify-full + CA seam); **statement-pooler boot guard** (refuses to
  boot behind statement-mode pooling, which would break `next_seq!`'s `FOR UPDATE`);
  **concurrent-commit load test** (`test/services/sync/concurrent_seq_test.rb`, gapless 1..N,
  clean to 3840 concurrent commits on PG) — which **found + fixed a real PG deadlock** (FK
  KEY-SHARE vs `FOR UPDATE` lock-upgrade; fixed by locking the user row FIRST in every mutating
  transaction); and **Solid Queue/Cache/Cable moved onto managed Postgres** (own per-role DBs;
  self-host stays on SQLite). Full suite 149/0 on SQLite AND Postgres. See `docs/SYNC_SERVER.md`
  "Managed-Postgres hardening (G2)".

So the live roadmap is the remaining items: **auth/OIDC, selective sync, sharing, bandwidth
controls, trash UX, progressive hydration, LAN sync, and encryption (last).**

---

# A. Auth / account management — OPTIONS to decide

**This is a decision for you to make, not a unilateral call.** Below are the realistic
options for a Rails 8 app that must self-host *and* run managed, with the device-token +
pairing mechanism preserved underneath each.

### Where we are today (confirmed)

`register` is new-account-only (409 on an existing email — closed the `find_or_create_by`
takeover hole); additional devices join via a single-use, 10-min, SHA256-digested pairing
code (`DevicePairing` → `POST /v1/auth/pair`). This is the Syncthing/Plex bootstrap
(`auth_controller.rb`, `feature-set-and-workflows.md` Part 1 "Auth & devices"). What it
**doesn't** do: prove email ownership. There is no password, no email verification, no
password reset, no OAuth. `bcrypt`/`has_secure_password` is present in the Gemfile only as a
commented stub. That's the gap (`CLAUDE.md` §12 step 5; research #8).

### The key architectural framing

Auth and the device bootstrap are **two layers**, and they should stay two layers:

```
  [ human identity layer ]   ← what we're choosing in this section
        email + password / OAuth-OIDC / magic link → proves a PERSON owns an account
            │  (on success, an authenticated browser/app session)
            ▼
  [ device bootstrap layer ] ← UNCHANGED (gating filter #3)
        register-new-account  +  DevicePairing single-use code  → issues a device token
            │
            ▼
  [ device token ]           ← the durable credential the sync client actually uses
```

The human layer authenticates a *session*; from inside that session you either create the
account (first device) or mint a pairing code (Nth device). **Every option below changes
only the top box.** This is the cheap insurance that lets you defer the auth decision: the
sync engine never sees the identity provider.

### Option 1 — Rails 8 built-in authentication generator  ★ RECOMMENDED

`bin/rails generate authentication` — the scaffold shipped in Rails 8: `has_secure_password`
(bcrypt), a `Session` model with a signed cookie, and password-reset mailer wiring.

- **Licensing:** MIT (it's Rails itself). Clean.
- **Self-host story:** perfect — zero external dependency, runs identically on the user's
  Unraid box and on managed. This is the single biggest point in its favor given filter #1.
- **Composes with device+pairing:** trivially. The generated session controller is exactly
  the authenticated context from which you call the existing `register`/`pairing` paths. No
  impedance mismatch — both layers are plain Rails.
- **Email verification / reset:** verification is *not* in the generator (it gives reset, not
  signup confirmation) — you add a one-token-mailer confirmation step (~half a day). Reset is
  generated. Both run through Action Mailer, which self-host already needs for nothing-else, so
  this is the one new operational dependency (SMTP creds) — acceptable and standard.
- **OAuth/OIDC:** not included. Add `omniauth` + a provider strategy later *as an additive
  login method* (see Option 3) without ripping anything out — the generator's `User` model is
  just a normal model you can hang an `identities` association off.
- **Effort:** **S** (1–2 days incl. email confirmation).
- **Why it wins the dual constraint:** it is the only option that is simultaneously (a) zero
  new licensing risk, (b) zero new self-host moving parts, (c) native to Rails 8, and (d) a
  clean base to bolt OmniAuth onto for the managed tier later. It does the table-stakes
  (email+password, verification, reset) without betting the self-host story on anything.

### Option 2 — Devise (+ `:omniauthable`)

The long-standing Rails auth gem; `:confirmable` (email verification), `:recoverable`
(reset), `:lockable`, and OmniAuth integration all built in.

- **Licensing:** MIT. Clean.
- **Self-host story:** fine — it's a gem, no external service.
- **Composes with device+pairing:** fine, but Devise owns more of the request/response cycle
  (its controllers, routes, warden middleware). You'd be wrapping its session context to call
  the device bootstrap — slightly more surface than Option 1.
- **Email verification / reset:** both first-class out of the box (its main advantage over the
  Rails generator).
- **OAuth/OIDC:** `:omniauthable` is the well-trodden path.
- **Effort:** **S–M.** Less code than Option 1 for the email features, but more framework to
  learn/own, and Devise is heavier than this app needs (it's an API-first sync server, not a
  classic server-rendered web app).
- **Verdict:** the **fallback** if you decide you want `:confirmable`/`:lockable` for free and
  don't mind the heavier dependency. Reasonable; just more than required.

### Option 3 — OmniAuth + a self-hosted OIDC provider (Keycloak / Ory Hydra / Authentik)

Run your own identity provider; the Rails app is an OIDC *client* via `omniauth` +
`omniauth_openid_connect`.

- **Licensing:** the Rails-side gems are MIT/Apache (fine). **The IdP is the catch (filter #2):**
  *Authentik* is MIT (cleanest); *Ory Hydra* is Apache-2.0 (clean); *Keycloak* is Apache-2.0
  **but** is a heavyweight Java/Quarkus service. None are GPL/AGPL, so all *pass* the license
  filter — the problem is operational weight, not licensing.
- **Self-host story:** this is the tension. Asking a self-hoster to *also* stand up Keycloak/
  Hydra/Authentik next to Rails + Postgres + SeaweedFS is a real burden — it roughly doubles
  the self-host surface. *Confirmed friction*, not inference: the whole architecture's selling
  point is "Rails + Postgres + S3, nothing exotic" (`architecture-sync-engine.md` "Self-host vs
  managed"). A mandatory IdP undercuts that.
- **Composes with device+pairing:** cleanly — OIDC authenticates the session, device bootstrap
  is unchanged.
- **Effort:** **M** Rails-side, **+ ongoing ops** for the IdP.
- **Verdict:** **Not the default.** Best reserved as an *optional* managed-tier or
  enterprise-self-host integration ("bring your own OIDC"), layered on top of Option 1 via the
  same OmniAuth seam — not the baseline every self-hoster must run.

### Option 4 — Hosted IdPs (Auth0 / Clerk / WorkOS) — flag the self-host tension

- **Licensing:** N/A (SaaS), but **this directly violates filter #1 for self-host.** A
  self-hoster cannot depend on Auth0/Clerk/WorkOS without an internet round-trip to a vendor
  you don't control — that breaks the "runs on your own box" promise (`CLAUDE.md` §7).
- **Self-host story:** **disqualifying as a baseline.** Acceptable *only* as a managed-tier-only
  convenience behind the same OmniAuth/OIDC seam, never as the sole auth path.
- **Effort:** **S** to integrate, but the constraint cost is high.
- **Verdict:** **Rejected as baseline.** Optional managed-only add-on at most (e.g. WorkOS for
  enterprise SSO if you ever sell to teams). Do not make the self-host build depend on it.

### Option 5 — Authentication Zero (generator) — the middle ground

`authentication-zero` generates a fuller auth system than the Rails 8 generator (email
verification, password reset, 2FA scaffolding, sudo-mode, session management UI) as *your own
code* in your repo.

- **Licensing:** MIT, and crucially it generates code you own rather than a runtime dependency.
  Clean.
- **Self-host story:** identical to Option 1 — zero external service.
- **Composes with device+pairing:** same as Option 1 (plain Rails models/controllers).
- **Email verification / reset:** generated, included (its edge over the bare Rails generator).
- **Effort:** **S–M.** More generated code to review/own, but no framework lock-in.
- **Verdict:** a genuinely good middle ground — **the alternative to pick if the Rails 8
  generator feels too bare** (you want verification + 2FA + session management now) but you
  don't want Devise's framework weight. *Inference:* for this app's scale, Option 1 + a small
  custom confirmation step is leaner, but Option 5 is the defensible runner-up.

### Recommendation

**Pick Option 1 (Rails 8 built-in generator)** as the baseline, add a small email-confirmation
step, and **keep the OmniAuth seam open** so OIDC (Option 3, self-hostable IdP) and hosted SSO
(Option 4, managed-only) can be added *as optional login methods* later without disturbing the
device bootstrap.

- **Fallback:** **Option 5 (Authentication Zero)** if you want verification/2FA/session-mgmt
  generated now; **Option 2 (Devise)** if you specifically want `:confirmable`/`:lockable` as a
  maintained dependency.
- **Reasoning for the dual constraint:** Options 1/5/2 are the only ones that keep self-host
  dependency-free and licensing-clean. Options 3/4 fail the self-host-baseline test and belong
  *on top of* the OmniAuth seam, not under it.
- **OIDC's place (CLAUDE.md §12 step 5):** OAuth/OIDC sits *in front of* the existing bootstrap.
  The win it buys is **proving email ownership** (today's bootstrap proves device possession,
  not identity). Once a session is authenticated by any method, the unchanged flow runs:
  first device → `register`; subsequent device → mint a `DevicePairing` code → `pair`. The
  device token remains the credential the sync client and ActionCable use.

**Effort for the whole auth item: S (1–2 days)** for the baseline; OIDC is a later **M** add-on.

---

# B. Encryption — designed here, SEQUENCED LAST

Per-user at-rest / end-to-end chunk encryption: the client encrypts each chunk with an
authenticated cipher (AEAD) *before* the presigned PUT, so object storage (R2 / SeaweedFS)
only ever holds ciphertext. This is research #3 and `feature-set-and-workflows.md` Part 3
gap #2 — the SaaS trust story for makers shipping commercial/IP-sensitive CAD.

### Design

**1. Cipher & framing.** AES-256-GCM or XChaCha20-Poly1305 (both permissive — `ring`/
`aes-gcm`/`chacha20poly1305` crates are Apache/MIT; filter #2 clean). Each chunk is sealed
independently: `nonce ‖ ciphertext ‖ tag`. Per-chunk independence preserves the on-demand,
range-fetch hydration model (you can fetch and decrypt chunk *k* without the others).

**2. The content-addressing problem (the crux).** Today a chunk's key is `sha256(plaintext)`
→ `chunks/<user>/<hash>` (`sync-protocol.md`). Encrypt naively and identical plaintext yields
*different* ciphertext (random nonce) → addressing breaks and **dedup dies entirely**. Two fixes,
both keep per-user dedup (cross-user dedup is *already gone* — storage is per-user, so we lose
nothing there):

- **(a) Convergent / keyed-HMAC addressing (recommended):** address by
  `HMAC-SHA256(user_chunk_key, plaintext)` and *derive a deterministic per-chunk nonce/key from
  that same MAC*. Identical plaintext under the same user key → identical ciphertext → dedup
  survives **within the user**, which is all we have. This is the Tahoe-LAFS / Seafile-encrypted-
  library pattern (research §2 "Seafile encrypted libs").
- **(b) Hash-of-ciphertext addressing:** address by `sha256(ciphertext)`. Simpler, but a random
  nonce kills dedup even within a user; only viable if you make the nonce deterministic too — at
  which point it collapses into (a). **Go with (a).**

**3. Key derivation / management.**
- **Self-host:** a user master key derived from a passphrase via Argon2id (permissive), held
  client-side; per-chunk keys via HKDF from the master. **Key loss = data loss** — the server
  *cannot* recover ciphertext. This must be loud in the UX (recovery-code export at setup).
- **Managed:** same client-side derivation by default (true E2E — host can't read). Optionally a
  managed escrow/recovery mode (server-held wrapped key) for users who want recoverability over
  zero-knowledge — a product toggle, not a default.
- The device token + pairing layer is unaffected (filter #3): pairing a new device must also
  transfer/derive the user key (e.g. the pairing code carries a wrapped key, or the user
  re-enters the passphrase). *Inference:* fold key transfer into the existing single-use pairing
  payload to avoid a second secret-exchange channel.

**4. Blast radius — what changes on every read/write path.** This is the whole reason it goes
last:
- **Manifest hashes:** `manifest_id` = hash of the ordered chunk list — switches from plaintext
  hashes to keyed-HMAC addresses. Touches `manifests`/`manifest_chunks` on both server and
  client (`sync-protocol.md` data model).
- **Chunk cache:** the local content-addressed cache keys change; entries must be keyed by the
  new address and store ciphertext (decrypt on serve). Touches `fs-provider`'s chunk store and
  every mount's hydrate hook.
- **Dedup negotiation:** the `commit → {missing, put_urls}` exchange now negotiates over
  ciphertext addresses — server-side logic is unchanged in *shape* (it still compares hashes),
  but the hashes mean something different.
- **Debuggability:** you can no longer `sha256` a stored object to verify it matches a plaintext
  file — every integrity check now needs the key. **This is precisely why it must come after the
  other features are stable:** it makes debugging selective sync, sharing, LAN sync, and
  progressive hydration *harder*, because every byte on the wire and at rest is opaque.

**5. What it explicitly does NOT break:** cross-user dedup (already gone — per-user storage);
the presigned-URL / bytes-out-of-Rails model (Rails still mints URLs for opaque keys — it never
needed to read the bytes); versioning (manifests still share chunks, just keyed differently).

### Test strategy

- **Crypto unit tests:** known-answer vectors for the AEAD; round-trip seal/open; tamper a byte
  → open *must* fail (authenticity).
- **Determinism:** identical plaintext under the same user key → identical address (dedup
  invariant); different users → different addresses (isolation invariant).
- **Engine integration:** re-run the existing `two_device_e2e` and `fault_injection` suites with
  encryption *on* — convergence + no-data-loss must still hold over ciphertext.
- **Conformance:** re-run rclone⇄WebDAV / fsx⇄FUSE byte-for-byte (`client/test-conformance/`)
  with encryption on — the plaintext the *user* sees must be identical.
- **Key-loss / recovery:** explicit test that a lost key yields an unrecoverable-but-clean error
  (no partial corruption, no silent plaintext leak).

### Why last (one paragraph)

Encryption complicates *every* read and write path and makes the system opaque to inspection,
which makes debugging every *other* feature harder. The other roadmap items (selective sync,
sharing, LAN sync, progressive hydration) all manipulate chunks and manifests directly and are
far easier to get right against plaintext, content-addressed bytes you can `sha256` and eyeball.
Build and stabilize those first; then turn the whole thing opaque once the mechanics are proven.
Get the AEAD + KDF design reviewed before writing a line (research #3 says the same: "key loss =
data loss").

**Effort: M–L**, and it is the last functional item before/alongside ongoing hardening.

---

# C. The rest — sequenced, with effort + dependencies

Effort key: **S** ≈ days · **M** ≈ 1–2 weeks · **L** ≈ multi-week / architectural.

### C1. Selective sync — research #2, the top ergonomic gap  · effort M

**What:** per-device subtree subscriptions; an unsubscribed folder stays metadata-only (a
placeholder that is *never even enumerated for hydration*), so a laptop can hold *Active
Projects* while the 90 GB archive stays as tree-only metadata.
**Why it matters for makers (confirmed):** `feature-set-and-workflows.md` Part 3 gap #1 — makers
accumulate hundreds of GB; a laptop SSD can't hold the library and even placeholder enumeration
of everything is undesirable. Research ranks it the **highest-leverage ergonomic gap**.
**Where it fits the model:** **client-side policy, not a partial server tree** — the server tree
stays complete (`docs/sync-protocol.md` "Full tree on every device"). Add a client subscription
table + a hydration gate: unsubscribed subtrees are skipped by the hydrator and (on CfAPI/FUSE)
shown as deep placeholders. The changelog/manifest model is untouched — you still pull the full
changelog, you just *don't hydrate* the gated subtrees.
**Dependencies:** none hard. Pairs naturally with the in-progress web UI (folder-level
on/off toggles) and with **C5 progressive hydration** (same hydration-gate seam). Should land
**early** — it's the maker pain point and needs no new server architecture.

### C2. Trash / deleted-file recovery UX — versions already kept · effort S

**What:** a "Trash" / "recently deleted" surface to restore a deleted file or folder, time-boxed
(e.g. 30-day, matching Dropbox).
**Why it matters:** table-stakes safety net; makers fat-finger deletes of irreplaceable design
files.
**Where it fits — the key insight:** the *mechanism already exists.* Deletes are **tombstones**,
not hard deletes (`node.deleted`, `apply_remote_delete`), and versions are kept; restore re-points
a node at a manifest (`POST /nodes/:id/restore`). **What's missing is purely UX + a query**:
list tombstoned nodes within the retention window and expose an "undelete" (clear the tombstone,
re-point to last version). The retention/GC job (now wired) defines the window. This is mostly
a web-UI + one server endpoint job — **very cheap relative to its parity value.**
**Dependencies:** the in-progress web UI (the natural home for the Trash view); the now-wired
`RetentionPolicy` (defines how long undelete is possible). *Inference:* a few days, dominated by
UI.

### C3. Bandwidth controls (throttling / scheduling) — research #6 · effort S–M

**What:** client-side upload/download rate caps (and optionally a schedule, e.g. "throttle 9–5").
**Why it matters for makers (confirmed):** `feature-set-and-workflows.md` Part 3 gap #4 — makers
on home/shop connections pushing multi-GB projects need to keep usable internet.
**Where it fits:** **purely client-side, in the chunk-transfer layer — no protocol change**
(research #6 explicitly: "no protocol change needed"). A token-bucket rate limiter around the
presigned PUT/GET stream in `sync-engine`'s `ChunkIO`. Today "throttle" exists only for the
freshness-pull, not transfer.
**Dependencies:** none. Can land anytime; good "polish" filler between bigger items.

### C4. Sharing / multi-user — research #7, the biggest gap, a PRODUCT FORK · effort L

**What:** share a folder with a *different user* (a co-designer / fabricator) — Spaces-style.
**Why it matters:** `feature-set-and-workflows.md` Part 3 gap #6 — makers collaborate / hand off.
But note: it is the difference between "private multi-device sync" (what we are) and
"collaboration platform" (what Dropbox/Drive/Spaces are).
**This is a product decision, not just engineering** (research #7: "business-model decision; defer
to validated demand"). It is the **only item besides a three-tree planner that needs genuinely
new architecture** (research §3/§4): new authz, **cross-user dedup rework** (chunks are currently
per-user-keyed `chunks/<user>/<hash>` — sharing means a chunk visible to two users, which
reopens the cross-user-access surface the security model deliberately closed, `CLAUDE.md` §8),
and **changelog scoping** (today the changelog is per-user; a shared space needs its own feed).
**Where it fits / the slot-in:** `CLAUDE.md` §8 notes the 37signals `active_record_tenanted`
pattern "slots over the same models" if you go multi-user/db-per-tenant. That's the migration
path — but it's a deliberate fork of the tenancy model, not an incremental feature.
**Dependencies:** **auth (A) must be real first** (you can't share with a user whose email isn't
verified). Interacts heavily with **encryption (B)** — E2E + sharing means sharing keys, which is
a hard sub-problem; another reason B comes after the fork is decided. **Sequence this late and
deliberately**, gated on demand.

### C5. Partial / progressive hydration for huge files — research #9 · effort S–M

**What:** open a 2 GB file and read just its header (slicer/CAD metadata) without hydrating the
whole file.
**Why it matters for makers (confirmed):** `feature-set-and-workflows.md` Part 3 gap #3 — large
3D/CAD files; previewing/indexing shouldn't pull everything.
**Where it fits:** the manifest **already maps ranges → chunks** (`sync-protocol.md` flow #4);
the mounts currently fetch per-chunk-on-read but with **no big-file range strategy**. Wire the
CfAPI / FUSE / File-Provider hydrate hooks to range-fetch only the chunks covering the requested
byte range, opt-in per file type (some apps mmap/read-whole, so a blanket policy backfires).
**Dependencies:** shares the **hydration-gate seam with C1 (selective sync)** — build them
adjacent. Low risk, fits the model cleanly.

### C6. LAN sync / peer block transfer — research #5 · effort M–H

**What:** two machines (workstation + laptop) on the same shop LAN exchange chunks **directly**,
not round-tripping through the cloud.
**Why it matters for makers (confirmed):** `feature-set-and-workflows.md` Part 3 gap #5 — the
common maker setup (two machines + NAS on one switch); much faster, no egress.
**Where it fits:** mDNS/UDP peer discovery + **hash-verified** peer chunk fetch (the content
address *is* the integrity check — a peer can't lie about a chunk's bytes). Chunks stay
content-addressed; this is an alternate *transport* for the same bytes, with the server still
the metadata source of truth.
**SECURITY — the Dropbox lesson (do not skip):** research #5 explicitly cites **Dropbox
CVE-2021-28171** — *never serve a chunk cross-user over LAN.* A LAN peer must prove same-library
membership (e.g. a shared per-library secret derived from the device tokens) before any chunk
moves; verify the requested hash against the requester's own manifest entitlements. This is the
one place a naive implementation leaks data. Also composes awkwardly with **encryption (B)** —
peers would exchange ciphertext, which is fine, but key possession must still gate access.
**Dependencies:** none hard, but it's the most new-surface item after sharing. Mid/late.

---

# D. Recommended SEQUENCE (opinionated build order)

Ordered for dependencies and leverage. **"Table-stakes" = needed to be a credible drive;
"differentiator" = worth more to *this* product than generic parity; "don't-chase" = parity
that isn't worth it for Maker Server.**

1. **Auth baseline — Option 1 (Rails 8 generator) + email confirmation.**  ★ table-stakes ·
   **S (1–2 days).** Unblocks the web UI hardening and is a prerequisite for sharing. Keep the
   OmniAuth seam open for OIDC/SSO later. Do this *with/before* the in-flight web UI.
2. **Selective sync.**  ★★ differentiator (maker week-one pain) · **M.** Highest ergonomic
   leverage; client-side policy, no new server architecture. Build the hydration-gate seam here.
3. **Trash / undelete UX.**  ★ table-stakes · **S.** Cheap — mechanism exists; UX + one query.
   Slots into the web UI alongside selective sync.
4. **Progressive / range hydration.**  differentiator (huge CAD/3D files) · **S–M.** Reuses the
   #2 hydration-gate seam — build adjacent.
5. **Bandwidth controls.**  table-stakes-ish polish · **S–M.** Client-only; drop in anytime,
   good filler.
6. **OAuth/OIDC as an additive login method** (self-hostable IdP integration via the #1
   OmniAuth seam; hosted SSO managed-only).  table-stakes for the *managed* tier · **M.**
   Comes after the baseline proves out; required before/with sharing.
7. **Sharing / multi-user — the deliberate product fork.**  product decision · **L.** Gated on
   validated demand. Needs #1/#6 (real auth) first; `active_record_tenanted` slot-in. The only
   item (besides a three-tree planner) needing new architecture — commit to it deliberately.
8. **LAN sync / peer block transfer.**  differentiator (shop-bench setup) · **M–H.** Mid/late;
   mind the Dropbox CVE — never serve cross-user.
9. **Encryption (per-user AEAD chunks) — LAST.**  ★★ differentiator (SaaS trust) · **M–L.**
   Sequenced last on purpose (§B): it makes debugging everything above harder. Get the AEAD/KDF
   design reviewed first.

### Don't-chase (parity that isn't worth it for Maker Server)

- **Three-tree reconcile + planner (Dropbox Nucleus)** — research #10, *High, core rework.* Our
  fault-injection harness already found+fixed the real concurrency bugs; **do not rebuild the
  engine speculatively.** Let evidence, not parity envy, drive any move here.
- **Generic real-time co-editing / Office-style collaboration** — we are a maker file vault, not
  Google Docs. Out of scope.
- **Full POSIX-perms parity (uid/gid, symlinks, special files)** — deliberately gapped
  (`feature-set-and-workflows.md` caveats); meaningless for a personal maker drive. Mode/`+x` is
  preserved, which is enough.
- **Mobile** — out of scope per this doc's mandate.

### The product-altitude reminder

Maker Server is **not** a generic Dropbox. The items above that are *differentiators* (selective
sync for huge libraries, progressive hydration of giant CAD, LAN sync on the shop bench, E2E for
commercial IP) are worth **more** than chasing the last 10% of generic-drive parity. The data
plane is already best-in-class (CDC + block-delta + native versioning beat Nextcloud/ownCloud/
oCIS and Syncthing — research §3). The real product moat is the **maker app layer** (preview /
inventory / projects / BOM, `CLAUDE.md` §12 step 9) — which this sync work exists to support, not
to compete with Dropbox on its own turf.
