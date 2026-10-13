# At-Rest / End-to-End Chunk Encryption Implementation Plan

> **HISTORICAL — not re-verified.** Written before the repository split of 2026-08-20, when the
> sync engine and the Rust client still lived here (they are `chaim354/tinkerex-sync` and
> `chaim354/tinkerex-client` now). Kept for its reasoning and its measurements; it does not
> describe what this repository contains today. The current map is `docs/README.md`.


> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Encrypt every chunk with an AEAD on the client *before* the presigned PUT, so object storage (R2/SeaweedFS) and the Rails control plane only ever hold ciphertext and **keyed** content addresses — the SaaS trust story for makers shipping commercial/IP-sensitive CAD.

**Architecture:** A per-user key hierarchy (passphrase → Argon2id master key → HKDF-derived sub-keys) lives **client-side only**. Each chunk is content-addressed by `HMAC-SHA256(addr_key, plaintext)` (keyed/convergent — per-user dedup survives, cross-user correlation is impossible), sealed with XChaCha20-Poly1305 under a per-chunk key/nonce derived deterministically from that same plaintext MAC, and stored as `nonce ‖ ciphertext ‖ tag`. The server is unchanged in *shape* — it still negotiates over opaque hash strings and mints presigned URLs for opaque keys — because the address is just a different string the client computes. The master key rides the existing single-use device-pairing channel (wrapped to each new device); a passphrase + recovery code is the root of trust. Metadata (node names) encryption is a deliberately-optional later phase with an explicit server-search/preview trade-off.

**Tech Stack:** Rust client crates only for the crypto core (`fs-provider`, `sync-engine`, `sync-client`); Rails server changes are minimal and additive (a per-user `encryption_enabled` flag + a key-blob store, no chunk-byte awareness). Crypto crates: `chacha20poly1305` (XChaCha20-Poly1305, Apache/MIT), `hmac` + `sha2` (already a dep, MIT/Apache), `hkdf` (MIT/Apache), `argon2` (Apache/MIT), `zeroize` (Apache/MIT), `rand_core`/`getrandom` (MIT/Apache). **All permissive — passes CLAUDE.md §9 (filter #2).** No `ring` (so we avoid its mixed/BoringSSL licensing question entirely); pure-Rust RustCrypto crates throughout.

> **Scope guard:** This plan touches the **file/sync layer only** (`fs-provider`, `sync-engine`, `sync-client`, and the minimal Rails sync control plane). It does **NOT** touch the maker product layer (`Maker::*` models/controllers/services, `client/maker-app` product features). The maker app references files by `node_id` and is unaffected by how chunk bytes are stored.

---

## Captured requirements (the grounding — read before starting)

The canonical spec is `docs/parity-roadmap.md` §B and `docs/plan-file-layer-parity.md` §15 (G14). Both say the same thing; this plan turns it into staged, testable tasks. **Do not re-litigate the design decisions below — they are settled in those docs.**

### Why encryption is sequenced LAST (preserve this rationale verbatim)

Encryption complicates *every* read and write path and makes the system **opaque to inspection**. Today you can `sha256` any stored object and confirm it matches a plaintext file; once encrypted, every integrity check needs the key. That opacity makes debugging *every other feature* (selective sync, sharing, LAN sync, progressive hydration) harder, because every byte on the wire and at rest is meaningless without the key. So those features are built and stabilized **first**, against plaintext content-addressed bytes you can eyeball — and only then is the whole thing turned opaque. **This ordering is deliberate and must not be reversed.** `docs/parity-roadmap.md` D.9 and §B "Why last" are the source of truth.

### Threat model — what becomes opaque vs. what stays visible

Anchored to `CLAUDE.md` §8 (today: bytes never flow through Rails; storage is per-user `chunks/<user_id>/<hash>`; presigned per-object SigV4 URLs).

| Surface | Today (plaintext) | After this plan |
|---|---|---|
| Chunk **bytes** at rest in R2/SeaweedFS | Already opaque to Rails; **plaintext to the storage operator** | **Ciphertext** — opaque to storage operator AND a managed-host insider |
| Chunk **content address** (the hash) | Plaintext `sha256(plaintext)` — server/store sees it; identical content cross-user would correlate (but storage is per-user, so it doesn't today) | **Keyed `HMAC(addr_key, plaintext)`** — server can't reverse it to content; cannot correlate equal content across users even if storage were shared |
| **Manifest** (`manifest_id` + ordered chunk list) | Plaintext hash of chunk-hash list | Hash of the **keyed** chunk-address list — opaque |
| Node **names**, tree **structure**, **sizes**, **mtimes** | **Plaintext on the server** (the `nodes` table) | **Phase 6 (OPTIONAL):** names can be encrypted (server stores ciphertext names) at the cost of server-side search/preview. **Default in this plan: names + structure + sizes stay plaintext** (see the trade-off in Phase 6) |

**What E2EE buys (state plainly in the doc and to users):** the object store and a managed-host operator see only ciphertext chunks and keyed addresses; they cannot read file *content* or even tell two users share a file. **What is deliberately left visible (default):** the directory **structure**, file **names**, file **sizes**, and **mtimes** remain server-visible so server-side search (`Sync::Search`) and the server-rendered web UI tree keep working. Encrypting those is Phase 6, gated on whether the user values metadata-hiding over search/preview.

### The crux — keyed-HMAC (convergent) content addressing

Naive per-chunk-random-nonce encryption yields different ciphertext for identical plaintext → the content address breaks and **dedup dies entirely** (`docs/parity-roadmap.md` §B.2). Fix: address by `HMAC-SHA256(addr_key, plaintext)` and derive the per-chunk encryption key + nonce **deterministically** from that same MAC. Then identical plaintext under the same user key → identical address → identical ciphertext → **per-user dedup survives** (cross-user dedup is *already* gone — storage is per-user, so we lose nothing). This is the Tahoe-LAFS / Seafile-encrypted-library pattern. We **reject** convergent encryption with a *global* key (cross-user dedup but leaks content equality across users — a confirmed-plaintext attack) and we **reject** hash-of-random-ciphertext addressing (kills dedup). The keyed-per-user scheme is the settled choice.

### Key management (the make-or-break)

- **Master key:** derived client-side from a user passphrase via **Argon2id** (memory-hard). Never leaves the client in plaintext. **Key loss = data loss** — the server cannot recover ciphertext. This must be LOUD in the UX: a recovery code is exported at setup.
- **Sub-keys:** `addr_key` (for HMAC addressing) and `chunk_master` (for per-chunk key derivation) are **HKDF-SHA256** outputs from the master key with distinct `info` labels — domain separation so the addressing MAC key and the encryption key material are independent.
- **Multi-device:** a new device joins via the **existing single-use `DevicePairing` code** (`CLAUDE.md` §8, filter #3 — unchanged). The master key is **wrapped** (sealed under a key derived from the pairing code) and carried in the pairing payload, so the device gets the master key over the same channel — no second secret-exchange channel.
- **Recovery:** passphrase-derived KEK + a one-time recovery code (a high-entropy string the user stores offline). Either unwraps the master key. Managed tier *may* offer an opt-in server-escrow recovery (server holds a wrapped master key) as a **product toggle, off by default** — that trades zero-knowledge for recoverability and must be an explicit user choice.
- **Rotation:** master-key rotation re-wraps the per-device key blobs and re-derives sub-keys; chunk re-encryption is lazy (next write re-addresses under the new key). Scoped as a documented later concern (Phase 5 includes the wrap/unwrap seam that makes rotation *possible*; a full rotation tool is out of scope for the first landing).

### Blast radius — exact files (why it's last)

- `client/fs-provider/src/lib.rs` — the write path at **lines ~1730–1745** (`fn flush`-equivalent: FastCDC → `hex(Sha256::digest(bytes))` → `store.put` → `manifest_id = hash of chunk-hash list`). This is where addressing + (new) sealing happen.
- `client/fs-provider/src/chunkstore.rs` — `ChunkStore` stores/serves bytes by address; entries become ciphertext, keyed by the new address.
- `client/sync-engine/src/lib.rs` — `verify_chunk` (**lines ~796–800**, currently `sha256(bytes) == expected`) and `hydrate*` (**lines ~525–550**) — the integrity gate changes from plain-sha256 to keyed-address + AEAD-tag verification.
- `client/sync-client/src/lib.rs` — chunk transfer (`upload_chunk`/`download_chunk`) is **byte-agnostic and unchanged**; it already moves opaque blobs.
- **Server:** `app/services/sync/commit.rb` (`manifest_id_for`, missing-chunk negotiation) and `app/services/storage/chunk_store.rb` (`key_for`) are **address-agnostic** — they treat the hash as an opaque string, so they need **no logic change**; only a per-user `encryption_enabled` flag + key-blob storage is added.

### What it explicitly does NOT break

Cross-user dedup (already gone — per-user storage); bytes-out-of-Rails (Rails mints URLs for opaque keys, never reads bytes); versioning/restore (manifests still share chunks, just keyed differently). `docs/parity-roadmap.md` §B.5.

### Interaction with SHARING (flag, do NOT solve here)

E2EE + sharing = **key sharing**: a shared Space needs its own key, wrapped to each member. That is a genuinely hard sub-problem and is **out of scope for this plan**. **Dependency to record:** sharing (G12 / `docs/parity-roadmap.md` C4) should land **before** any attempt to make E2EE shareable; this plan implements **per-user** (single-tenant) E2EE only and must not assume shared keys. The Phase 5 key-wrap seam is designed so a future per-Space key can reuse the same wrap/unwrap machinery, but no sharing code is written here.

---

## File Structure

New and modified units, by responsibility. Crypto lives in **one focused new crate** (`client/fs-crypto`) so the primitives are testable in isolation and the provider/engine depend on a small, audited surface.

- **Create `client/fs-crypto/`** — a new crate: the entire crypto core (AEAD seal/open, keyed addressing, key hierarchy/HKDF, Argon2id KDF, key wrap/unwrap, recovery codes). One responsibility: turn plaintext + keys into `(address, sealed_bytes)` and back, and manage the key hierarchy. No I/O, no SQLite, no network — pure functions over byte slices + key types. This is the unit that gets reviewed hardest (key loss = data loss).
- **Modify `client/fs-provider/src/lib.rs`** — the write path calls `fs-crypto` to address+seal before `store.put`, and the read path opens after `store.get`. Gated by a per-provider `Option<UserKeys>` (None = plaintext, today's behavior).
- **Modify `client/fs-provider/src/chunkstore.rs`** — no logic change to the trait; it stays a byte-blob store. (Ciphertext is just bytes.) Documented that entries are now ciphertext when keys are present.
- **Modify `client/sync-engine/src/lib.rs`** — `verify_chunk` becomes encryption-aware (verify keyed address / AEAD tag); hydrate decrypts via the provider's keys after fetch.
- **Modify `client/sync-engine/src/daemon.rs`** — thread the `UserKeys` into the daemon (load on start from the key store; refuse to mount an encrypted library without keys).
- **Create `client/fs-crypto/src/keystore.rs`** (module) — on-device persistence of the wrapped master key (a file next to the chunk cache); load/unlock with passphrase or recovery code.
- **Modify `app/models/user.rb` + a migration** — add `encryption_enabled:boolean` (default false) and a `user_key_blobs` table (per-device wrapped master key, opaque to the server). Server stores/serves opaque blobs; never derives or reads a key.
- **Modify `app/controllers/v1/auth_controller.rb` + `devices_controller.rb`** — the pairing payload carries the wrapped master-key blob (additive field). No change to the device-token mechanism.
- **Create `docs/encryption-design.md`** — the threat model + key hierarchy diagram + recovery UX copy, linked from `STATUS.md`. (A design doc the agent fills in Phase 1, used as the review artifact before any crypto code ships.)

---

## Pre-flight (do once, before Phase 1)

- [ ] **Step 0a: Confirm the worktree is off `main` and clean.**

Run: `git -C /Users/charlesschwartz/Desktop/tinkerex/.claude/worktrees/agent-af8abaad62143fb44 status --short && git log --oneline -1`
Expected: clean tree; HEAD is a recent `main` commit.

- [ ] **Step 0b: Verify the crypto crates resolve to permissive licenses (CLAUDE.md §9).**

Run (from repo root): `cargo search chacha20poly1305 argon2 hkdf hmac zeroize 2>/dev/null | head` and confirm each crate's `license` field on crates.io reads `Apache-2.0 OR MIT` (RustCrypto convention).
Expected: every crate is `Apache-2.0 OR MIT` (or `MIT`). **If any pulls a GPL/AGPL transitive dep, STOP and report** — do not add it. (`cargo deny` is the mechanical check if configured; otherwise inspect `Cargo.lock` after Phase 1's `cargo build`.)

---

## Phase 1 — Crypto primitives + key hierarchy (the audited core)

**Outcome:** a standalone, pure, fully unit-tested `fs-crypto` crate. No provider/engine wiring yet — this is the reviewable nucleus. **Get this phase reviewed before Phase 2 (key loss = data loss).**

### Task 1.1: Scaffold the `fs-crypto` crate

**Files:**
- Create: `client/fs-crypto/Cargo.toml`
- Create: `client/fs-crypto/src/lib.rs`
- Modify: `client/Cargo.toml` (workspace members — add `fs-crypto`)

- [ ] **Step 1: Add the crate to the workspace and declare deps**

`client/fs-crypto/Cargo.toml`:

```toml
[package]
name = "fs-crypto"
version = "0.1.0"
edition = "2021"
license = "Apache-2.0"

[dependencies]
chacha20poly1305 = "0.10"   # XChaCha20-Poly1305 AEAD (Apache-2.0 OR MIT)
hmac = "0.12"               # HMAC-SHA256 keyed addressing (MIT OR Apache-2.0)
sha2 = "0.10"               # SHA-256 (MIT OR Apache-2.0) — already used elsewhere
hkdf = "0.12"               # sub-key derivation (MIT OR Apache-2.0)
argon2 = "0.5"              # Argon2id passphrase KDF (Apache-2.0 OR MIT)
zeroize = "1"               # wipe key material on drop (Apache-2.0 OR MIT)
rand_core = { version = "0.6", features = ["getrandom"] }  # CSPRNG for salts/recovery codes
hex = "0.4"
thiserror = "1"

[dev-dependencies]
hex-literal = "0.4"         # known-answer test vectors
```

Add `"fs-crypto"` to the `[workspace] members` list in `client/Cargo.toml`.

- [ ] **Step 2: Build the empty crate to confirm deps resolve to permissive licenses**

Run: `cd client && cargo build -p fs-crypto`
Expected: compiles; then run `cargo tree -p fs-crypto -f "{p} {l}" | grep -iE "gpl|agpl"` → **no output** (no copyleft pulled in). If GPL/AGPL appears, STOP and report (CLAUDE.md §9).

- [ ] **Step 3: Commit**

```bash
git add client/fs-crypto/Cargo.toml client/fs-crypto/src/lib.rs client/Cargo.toml client/Cargo.lock
git commit -m "feat(fs-crypto): scaffold crypto crate (permissive AEAD/KDF deps)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

### Task 1.2: AEAD seal/open (XChaCha20-Poly1305) with known-answer + tamper tests

**Files:**
- Create: `client/fs-crypto/src/aead.rs`
- Modify: `client/fs-crypto/src/lib.rs` (`mod aead; pub use aead::*;`)
- Test: inline `#[cfg(test)]` in `aead.rs`

- [ ] **Step 1: Write the failing tests**

```rust
// client/fs-crypto/src/aead.rs  (#[cfg(test)] mod tests)
use super::*;

#[test]
fn seal_then_open_roundtrips() {
    let key = ChunkKey([7u8; 32]);
    let nonce = ChunkNonce([3u8; 24]);
    let pt = b"hello maker world";
    let sealed = seal(&key, &nonce, pt);
    // framing: nonce(24) || ciphertext || tag(16)
    assert_eq!(&sealed[..24], &nonce.0);
    let opened = open(&key, &sealed).expect("open");
    assert_eq!(opened, pt);
}

#[test]
fn tampered_ciphertext_fails_to_open() {
    let key = ChunkKey([7u8; 32]);
    let nonce = ChunkNonce([3u8; 24]);
    let mut sealed = seal(&key, &nonce, b"secret cad geometry");
    let last = sealed.len() - 1;
    sealed[last] ^= 0x01; // flip a tag bit
    assert!(open(&key, &sealed).is_err(), "AEAD must reject tampered bytes");
}

#[test]
fn wrong_key_fails_to_open() {
    let nonce = ChunkNonce([3u8; 24]);
    let sealed = seal(&ChunkKey([7u8; 32]), &nonce, b"x");
    assert!(open(&ChunkKey([8u8; 32]), &sealed).is_err());
}
```

- [ ] **Step 2: Run to verify failure**

Run: `cd client && cargo test -p fs-crypto aead`
Expected: FAIL — `seal`/`open`/`ChunkKey`/`ChunkNonce` not defined.

- [ ] **Step 3: Implement seal/open**

```rust
// client/fs-crypto/src/aead.rs
use chacha20poly1305::{aead::{Aead, KeyInit}, XChaCha20Poly1305, XNonce};
use zeroize::Zeroize;

/// 256-bit per-chunk encryption key (derived, never stored).
#[derive(Clone)]
pub struct ChunkKey(pub [u8; 32]);
impl Drop for ChunkKey { fn drop(&mut self) { self.0.zeroize(); } }

/// 192-bit XChaCha20 nonce (deterministically derived per chunk).
#[derive(Clone)]
pub struct ChunkNonce(pub [u8; 24]);

#[derive(Debug, thiserror::Error)]
#[error("AEAD open failed (wrong key or tampered ciphertext)")]
pub struct OpenError;

/// Seal: returns `nonce(24) || ciphertext || tag(16)`.
pub fn seal(key: &ChunkKey, nonce: &ChunkNonce, plaintext: &[u8]) -> Vec<u8> {
    let cipher = XChaCha20Poly1305::new(key.0.as_ref().into());
    let ct = cipher
        .encrypt(XNonce::from_slice(&nonce.0), plaintext)
        .expect("XChaCha20-Poly1305 encrypt is infallible for in-memory input");
    let mut out = Vec::with_capacity(24 + ct.len());
    out.extend_from_slice(&nonce.0);
    out.extend_from_slice(&ct);
    out
}

/// Open: input is `nonce(24) || ciphertext || tag(16)`.
pub fn open(key: &ChunkKey, sealed: &[u8]) -> Result<Vec<u8>, OpenError> {
    if sealed.len() < 24 + 16 { return Err(OpenError); }
    let (nonce, ct) = sealed.split_at(24);
    let cipher = XChaCha20Poly1305::new(key.0.as_ref().into());
    cipher.decrypt(XNonce::from_slice(nonce), ct).map_err(|_| OpenError)
}
```

Wire `mod aead; pub use aead::*;` into `lib.rs`.

- [ ] **Step 4: Run to verify pass**

Run: `cd client && cargo test -p fs-crypto aead`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add client/fs-crypto/src/aead.rs client/fs-crypto/src/lib.rs
git commit -m "feat(fs-crypto): XChaCha20-Poly1305 seal/open with tamper-fails tests

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

### Task 1.3: Key hierarchy — Argon2id master + HKDF sub-keys

**Files:**
- Create: `client/fs-crypto/src/keys.rs`
- Modify: `client/fs-crypto/src/lib.rs` (`mod keys; pub use keys::*;`)
- Test: inline `#[cfg(test)]` in `keys.rs`

- [ ] **Step 1: Write the failing tests**

```rust
// client/fs-crypto/src/keys.rs  (#[cfg(test)] mod tests)
use super::*;

#[test]
fn passphrase_derivation_is_deterministic_given_salt() {
    let salt = [9u8; 16];
    let a = MasterKey::from_passphrase("correct horse battery staple", &salt).unwrap();
    let b = MasterKey::from_passphrase("correct horse battery staple", &salt).unwrap();
    assert_eq!(a.expose(), b.expose());
}

#[test]
fn different_passphrase_yields_different_master() {
    let salt = [9u8; 16];
    let a = MasterKey::from_passphrase("pass-a", &salt).unwrap();
    let b = MasterKey::from_passphrase("pass-b", &salt).unwrap();
    assert_ne!(a.expose(), b.expose());
}

#[test]
fn subkeys_are_domain_separated() {
    let m = MasterKey([42u8; 32]);
    let uk = m.derive_user_keys();
    // addr_key (HMAC) and chunk_master (encryption) must be independent
    assert_ne!(uk.addr_key, uk.chunk_master);
}

#[test]
fn user_keys_are_deterministic_from_master() {
    let m = MasterKey([42u8; 32]);
    assert_eq!(m.derive_user_keys().addr_key, m.derive_user_keys().addr_key);
}
```

- [ ] **Step 2: Run to verify failure**

Run: `cd client && cargo test -p fs-crypto keys`
Expected: FAIL — `MasterKey`/`UserKeys`/`derive_user_keys` not defined.

- [ ] **Step 3: Implement the key hierarchy**

```rust
// client/fs-crypto/src/keys.rs
use argon2::{Argon2, Algorithm, Params, Version};
use hkdf::Hkdf;
use sha2::Sha256;
use zeroize::Zeroize;

/// Root secret. Derived from a passphrase (Argon2id) or unwrapped from a key blob.
/// NEVER persisted in the clear; NEVER sent to the server.
pub struct MasterKey(pub [u8; 32]);
impl Drop for MasterKey { fn drop(&mut self) { self.0.zeroize(); } }
impl MasterKey {
    pub fn expose(&self) -> [u8; 32] { self.0 }

    /// Argon2id over a passphrase + 16-byte salt. Params are fixed so derivation is
    /// reproducible across devices (the salt is stored in the key blob, the params are
    /// constants here). m=19456 KiB, t=2, p=1 (OWASP baseline).
    pub fn from_passphrase(passphrase: &str, salt: &[u8; 16]) -> Result<Self, KeyError> {
        let params = Params::new(19_456, 2, 1, Some(32)).map_err(|_| KeyError::Kdf)?;
        let a2 = Argon2::new(Algorithm::Argon2id, Version::V0x13, params);
        let mut out = [0u8; 32];
        a2.hash_password_into(passphrase.as_bytes(), salt, &mut out)
            .map_err(|_| KeyError::Kdf)?;
        Ok(MasterKey(out))
    }

    /// Derive the per-user sub-keys via HKDF-SHA256 with distinct `info` labels
    /// (domain separation): the HMAC addressing key and the chunk-encryption master.
    pub fn derive_user_keys(&self) -> UserKeys {
        let hk = Hkdf::<Sha256>::new(None, &self.0);
        let mut addr_key = [0u8; 32];
        let mut chunk_master = [0u8; 32];
        hk.expand(b"maker/v1/chunk-address", &mut addr_key).unwrap();
        hk.expand(b"maker/v1/chunk-encrypt", &mut chunk_master).unwrap();
        UserKeys { addr_key, chunk_master }
    }
}

/// Derived working keys held in memory while a library is unlocked.
#[derive(Clone)]
pub struct UserKeys {
    pub addr_key: [u8; 32],     // HMAC-SHA256 key for content addressing
    pub chunk_master: [u8; 32], // HKDF root for per-chunk encryption keys
}
impl Drop for UserKeys {
    fn drop(&mut self) { self.addr_key.zeroize(); self.chunk_master.zeroize(); }
}

#[derive(Debug, thiserror::Error)]
pub enum KeyError {
    #[error("key derivation failed")] Kdf,
    #[error("key unwrap failed (wrong passphrase/recovery code)")] Unwrap,
}
```

Wire `mod keys; pub use keys::*;` into `lib.rs`.

- [ ] **Step 4: Run to verify pass**

Run: `cd client && cargo test -p fs-crypto keys`
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
git add client/fs-crypto/src/keys.rs client/fs-crypto/src/lib.rs
git commit -m "feat(fs-crypto): Argon2id master key + HKDF domain-separated sub-keys

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

### Task 1.4: Keyed content addressing + deterministic per-chunk key/nonce

**Files:**
- Create: `client/fs-crypto/src/address.rs`
- Modify: `client/fs-crypto/src/lib.rs` (`mod address; pub use address::*;`)
- Test: inline `#[cfg(test)]` in `address.rs`

- [ ] **Step 1: Write the failing tests (the dedup + isolation invariants)**

```rust
// client/fs-crypto/src/address.rs  (#[cfg(test)] mod tests)
use super::*;

fn uk(seed: u8) -> UserKeys { MasterKey([seed; 32]).derive_user_keys() }

#[test]
fn same_plaintext_same_user_same_address() {
    let k = uk(1);
    assert_eq!(chunk_address(&k, b"identical chunk"), chunk_address(&k, b"identical chunk"));
}

#[test]
fn different_users_different_address_for_same_plaintext() {
    // isolation invariant: per-user keyed addressing → no cross-user correlation
    assert_ne!(chunk_address(&uk(1), b"same bytes"), chunk_address(&uk(2), b"same bytes"));
}

#[test]
fn seal_for_chunk_is_deterministic_and_opens() {
    let k = uk(1);
    let pt = b"deterministic chunk";
    let (addr1, sealed1) = seal_chunk(&k, pt);
    let (addr2, sealed2) = seal_chunk(&k, pt);
    assert_eq!(addr1, addr2);          // dedup: same address
    assert_eq!(sealed1, sealed2);      // dedup: identical ciphertext (deterministic nonce)
    assert_eq!(open_chunk(&k, &sealed1).unwrap(), pt);
}

#[test]
fn open_chunk_rejects_address_mismatch() {
    let k = uk(1);
    let (_addr, sealed) = seal_chunk(&k, b"a");
    // verifying against the wrong address must fail (integrity gate)
    let wrong = chunk_address(&k, b"b");
    assert!(verify_and_open(&k, &wrong, &sealed).is_err());
}
```

- [ ] **Step 2: Run to verify failure**

Run: `cd client && cargo test -p fs-crypto address`
Expected: FAIL — `chunk_address`/`seal_chunk`/`open_chunk`/`verify_and_open` not defined.

- [ ] **Step 3: Implement keyed addressing + deterministic sealing**

```rust
// client/fs-crypto/src/address.rs
use crate::{ChunkKey, ChunkNonce, UserKeys, open, seal};
use hkdf::Hkdf;
use hmac::{Hmac, Mac};
use sha2::Sha256;

type HmacSha256 = Hmac<Sha256>;

/// The content address: hex `HMAC-SHA256(addr_key, plaintext)`. Keyed → the server
/// cannot reverse it to content, and two users with the same plaintext get different
/// addresses (cross-user isolation). Per-user dedup survives (same key + same plaintext
/// → same address).
pub fn chunk_address(keys: &UserKeys, plaintext: &[u8]) -> String {
    let mut mac = HmacSha256::new_from_slice(&keys.addr_key).expect("HMAC accepts any key len");
    mac.update(plaintext);
    hex::encode(mac.finalize().into_bytes())
}

/// Derive a per-chunk key + nonce deterministically from the chunk MAC, so identical
/// plaintext → identical ciphertext (dedup). HKDF over `chunk_master` salted by the MAC.
fn derive_chunk_crypto(keys: &UserKeys, mac: &[u8]) -> (ChunkKey, ChunkNonce) {
    let hk = Hkdf::<Sha256>::new(Some(mac), &keys.chunk_master);
    let mut key = [0u8; 32];
    let mut nonce = [0u8; 24];
    hk.expand(b"maker/v1/chunk-key", &mut key).unwrap();
    hk.expand(b"maker/v1/chunk-nonce", &mut nonce).unwrap();
    (ChunkKey(key), ChunkNonce(nonce))
}

/// Address + seal a plaintext chunk. Returns `(hex_address, nonce||ct||tag)`.
pub fn seal_chunk(keys: &UserKeys, plaintext: &[u8]) -> (String, Vec<u8>) {
    let mut mac = HmacSha256::new_from_slice(&keys.addr_key).unwrap();
    mac.update(plaintext);
    let mac_bytes = mac.finalize().into_bytes();
    let addr = hex::encode(&mac_bytes);
    let (key, nonce) = derive_chunk_crypto(keys, &mac_bytes);
    (addr, seal(&key, &nonce, plaintext))
}

/// Open a sealed chunk (no address check — used when the caller already trusts the source).
pub fn open_chunk(keys: &UserKeys, sealed: &[u8]) -> Result<Vec<u8>, crate::OpenError> {
    if sealed.len() < 24 { return Err(crate::OpenError); }
    // Re-derive the key from the plaintext MAC requires the plaintext; instead derive from
    // the stored nonce? No — the nonce IS derived from the MAC. We recover the key by
    // deriving from the MAC we recompute AFTER a tentative open. To avoid a chicken-and-egg,
    // open() only needs the key, which we derive from the MAC; but we don't have the MAC
    // pre-open. Resolution: the key is derived from `chunk_master` + the address, and the
    // address is supplied by the caller via `verify_and_open`. `open_chunk` is a thin wrapper
    // that trusts the embedded nonce to re-derive — see verify_and_open for the checked path.
    Err(crate::OpenError) // force callers through verify_and_open (the integrity gate)
}

/// The integrity gate used on hydrate: derive the per-chunk key from `address`, open, and
/// confirm the recovered plaintext re-addresses to `address` (AEAD tag + keyed-address
/// both checked). Replaces the old plain-sha256 verify.
pub fn verify_and_open(keys: &UserKeys, address: &str, sealed: &[u8]) -> Result<Vec<u8>, crate::OpenError> {
    let mac = hex::decode(address).map_err(|_| crate::OpenError)?;
    let (key, _nonce) = derive_chunk_crypto(keys, &mac);
    let pt = open(&key, sealed)?;                 // AEAD tag check
    if chunk_address(keys, &pt) != address {      // keyed-address check (defense in depth)
        return Err(crate::OpenError);
    }
    Ok(pt)
}
```

> **Design note for the implementer (record in `docs/encryption-design.md`):** the per-chunk key is derived from the **address** (the MAC), which is carried in the manifest, so `verify_and_open` has everything it needs without the plaintext. The nonce is also derived from the MAC and embedded in the sealed blob; on open we use the embedded nonce (via `open`) and the address-derived key, then re-address the recovered plaintext to confirm. `open_chunk` is intentionally a dead-end so all decrypts go through the checked `verify_and_open` gate.

- [ ] **Step 4: Run to verify pass**

Run: `cd client && cargo test -p fs-crypto address`
Expected: PASS (4 tests). (Remove the `seal_chunk` determinism test's reliance on `open_chunk`; it uses `verify_and_open` per the test code above.)

- [ ] **Step 5: Commit**

```bash
git add client/fs-crypto/src/address.rs client/fs-crypto/src/lib.rs
git commit -m "feat(fs-crypto): keyed HMAC content addressing + deterministic chunk sealing

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

### Task 1.5: Write the design doc + request review

**Files:**
- Create: `docs/encryption-design.md`

- [ ] **Step 1: Author the design doc**

Capture, in prose: the threat-model table (above), the key-hierarchy diagram (`passphrase → Argon2id → MasterKey → HKDF → {addr_key, chunk_master} → per-chunk {key, nonce}`), the keyed-address rationale, the recovery UX copy ("If you lose your passphrase AND your recovery code, your files are unrecoverable — we cannot reset it"), and the explicit statement that names/sizes/structure stay server-visible by default (Phase 6 trade-off). Link it from `docs/STATUS.md`.

- [ ] **Step 2: Commit + request human/crypto review of Phase 1**

```bash
git add docs/encryption-design.md docs/STATUS.md
git commit -m "docs: encryption design doc (threat model + key hierarchy)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

**CHECKPOINT — get the AEAD + KDF + addressing design reviewed before Phase 2** (`docs/parity-roadmap.md` §B: "Get the AEAD + KDF design reviewed before writing a line"; key loss = data loss).

---

## Phase 2 — Client-side encrypt/decrypt in the chunk path

**Outcome:** `fs-provider` seals on write and opens on hydrate when keys are present; with no keys it is byte-for-byte today's plaintext behavior. Gated behind a cargo feature `encryption` so the default build is unchanged until the path is proven.

### Task 2.1: Add an optional `UserKeys` to the provider

**Files:**
- Modify: `client/fs-provider/Cargo.toml` (dep on `fs-crypto`, feature `encryption`)
- Modify: `client/fs-provider/src/lib.rs` (provider holds `Option<UserKeys>`; setter)
- Test: inline in `lib.rs`

- [ ] **Step 1: Write the failing test**

```rust
#[test]
fn provider_defaults_to_plaintext_no_keys() {
    let p = test_provider(); // existing helper
    assert!(p.encryption_keys().is_none(), "no keys => plaintext mode (today's behavior)");
}
```

- [ ] **Step 2: Run to verify failure**

Run: `cd client/fs-provider && cargo test provider_defaults_to_plaintext`
Expected: FAIL — `encryption_keys` not defined.

- [ ] **Step 3: Implement the optional keys field + accessor**

Add `keys: std::sync::Mutex<Option<fs_crypto::UserKeys>>` to the provider struct (default `None`), a `pub fn set_encryption_keys(&self, k: fs_crypto::UserKeys)` and `pub fn encryption_keys(&self) -> Option<fs_crypto::UserKeys>` (clone out). Gate the `fs_crypto` import + these methods behind `#[cfg(feature = "encryption")]`; provide a `#[cfg(not(feature = "encryption"))]` stub `encryption_keys() -> Option<()>` returning `None` so call sites compile both ways. In `Cargo.toml`: `fs-crypto = { path = "../fs-crypto", optional = true }` and `[features] encryption = ["dep:fs-crypto"]`.

- [ ] **Step 4: Run to verify pass**

Run: `cd client/fs-provider && cargo test --features encryption provider_defaults_to_plaintext`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add client/fs-provider/Cargo.toml client/fs-provider/src/lib.rs client/Cargo.lock
git commit -m "feat(fs-provider): optional UserKeys behind 'encryption' feature (default plaintext)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

### Task 2.2: Seal on write — the FastCDC chunk loop addresses + seals when keys present

**Files:**
- Modify: `client/fs-provider/src/lib.rs:1730-1745` (the chunk loop)
- Test: inline in `lib.rs` (gated `#[cfg(feature = "encryption")]`)

- [ ] **Step 1: Write the failing test**

```rust
#[cfg(feature = "encryption")]
#[test]
fn encrypted_write_stores_ciphertext_addressed_by_keyed_hmac() {
    let p = test_provider();
    let keys = fs_crypto::MasterKey([5u8; 32]).derive_user_keys();
    p.set_encryption_keys(keys.clone());
    let ino = p.create_file("/secret.stl").unwrap();
    let plaintext = b"GEOMETRY-DATA".repeat(1000);
    p.write(ino, 0, &plaintext).unwrap();
    p.flush(ino).unwrap();
    // every stored chunk's address is the keyed HMAC and its bytes are ciphertext, not plaintext
    for addr in p.node_manifest_hashes("/secret.stl").unwrap() {
        let stored = p.chunk_get(&addr).unwrap();
        assert_ne!(stored, plaintext, "stored bytes must be ciphertext");
        assert!(fs_crypto::verify_and_open(&keys, &addr, &stored).is_ok());
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `cd client/fs-provider && cargo test --features encryption encrypted_write_stores_ciphertext`
Expected: FAIL — the write path still stores plaintext keyed by `sha256`.

- [ ] **Step 3: Implement the seal-on-write branch**

In the chunk loop, branch on `self.encryption_keys()`:

```rust
let (addr, store_bytes) = match self.encryption_keys() {
    #[cfg(feature = "encryption")]
    Some(keys) => fs_crypto::seal_chunk(&keys, bytes),   // (keyed_addr, nonce||ct||tag)
    _ => {
        let h = hex::encode(Sha256::digest(bytes));       // today's plaintext path
        (h, bytes.to_vec())
    }
};
self.store.put(&addr, &store_bytes)?;
chunk_rows.push((seq, addr, c.offset, c.length));
```

`manifest_id` is still `hash of the ordered address list` — unchanged shape, now over keyed addresses. (The `length`/`offset` recorded are the **plaintext** length/offset, so range math is unchanged; ciphertext is `length + 24 + 16` bytes but the manifest models plaintext layout.)

- [ ] **Step 4: Run to verify pass**

Run: `cd client/fs-provider && cargo test --features encryption encrypted_write_stores_ciphertext`
Expected: PASS. Also run `cargo test` (no feature) to confirm the plaintext path is untouched.

- [ ] **Step 5: Commit**

```bash
git add client/fs-provider/src/lib.rs
git commit -m "feat(fs-provider): seal+key-address chunks on write when encryption keys present

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

### Task 2.3: Open on read — `assemble`/`assemble_range` decrypt when keys present

**Files:**
- Modify: `client/fs-provider/src/lib.rs:526-600` (`assemble`, `assemble_range`)
- Test: inline in `lib.rs`

- [ ] **Step 1: Write the failing test**

```rust
#[cfg(feature = "encryption")]
#[test]
fn encrypted_roundtrip_reads_back_plaintext() {
    let p = test_provider();
    p.set_encryption_keys(fs_crypto::MasterKey([5u8; 32]).derive_user_keys());
    let ino = p.create_file("/m.3mf").unwrap();
    let pt = b"CAD".repeat(5000);
    p.write(ino, 0, &pt).unwrap(); p.flush(ino).unwrap();
    let got = p.read(ino, 0, pt.len() as u32).unwrap();
    assert_eq!(got, pt, "read must decrypt back to the exact plaintext");
}
```

- [ ] **Step 2: Run to verify failure**

Run: `cd client/fs-provider && cargo test --features encryption encrypted_roundtrip_reads_back`
Expected: FAIL — `assemble` returns ciphertext.

- [ ] **Step 3: Implement open-on-read**

In `assemble`/`assemble_range`, after `self.store.get(&hash)`, branch: if `encryption_keys()` is `Some`, `fs_crypto::verify_and_open(&keys, &hash, &bytes)?` to get plaintext; else use bytes as-is. For `assemble_range`, decrypt the **whole chunk** then slice the requested `[c_off, c_len]` window (the chunk is the AEAD unit — you cannot decrypt a sub-range of a sealed chunk). This preserves per-chunk range hydration: you still fetch only the chunks overlapping the range, you just decrypt each fetched chunk wholly.

- [ ] **Step 4: Run to verify pass**

Run: `cd client/fs-provider && cargo test --features encryption encrypted_roundtrip_reads_back`
Expected: PASS. Run the full `cargo test --features encryption` and `cargo test` suites.

- [ ] **Step 5: Commit**

```bash
git add client/fs-provider/src/lib.rs
git commit -m "feat(fs-provider): decrypt chunks on read when encryption keys present

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Phase 3 — Keyed content-addressing through the engine (hydrate verify + push)

**Outcome:** `sync-engine`'s integrity gate is encryption-aware: hydrate verifies the keyed address + AEAD tag instead of plain sha256, and decrypts before caching. Push is unaffected in shape (it uploads opaque addressed blobs).

### Task 3.1: Make `verify_chunk` encryption-aware

**Files:**
- Modify: `client/sync-engine/src/lib.rs:796-800` (`verify_chunk`) and `:525-550` (`hydrate*`)
- Modify: `client/sync-engine/Cargo.toml` (feature `encryption` forwards to `fs-provider`/`fs-crypto`)
- Test: `client/sync-engine/tests/` (new `encryption.rs` integration test, hermetic `SharedDirIO`)

- [ ] **Step 1: Write the failing test (hermetic, no server)**

```rust
// client/sync-engine/tests/encryption.rs
#[cfg(feature = "encryption")]
#[test]
fn hydrate_decrypts_and_verifies_keyed_address() {
    // device A: encrypted provider over a shared-dir chunk store → push bytes
    // device B: fresh provider, same keys → hydrate → read back identical plaintext
    // (use the existing two-provider shared-dir harness; set the same UserKeys on both)
    // assert: B reads byte-for-byte plaintext; a tampered stored blob fails verify.
}
```

- [ ] **Step 2: Run to verify failure**

Run: `cd client/sync-engine && cargo test --features encryption hydrate_decrypts`
Expected: FAIL — hydrate still does plain-sha256 verify and caches ciphertext without decrypting.

- [ ] **Step 3: Implement the encryption-aware gate**

In the hydrate per-chunk closure (`io.get` → verify → `provider.chunk_put`): when the provider has keys, replace `verify_chunk(h, &bytes)` with `fs_crypto::verify_and_open(&keys, h, &bytes)` and **store the ciphertext** in the cache unchanged (`provider.chunk_put(h, &bytes)`) — the provider's `assemble` decrypts on read (Phase 2.3). So the engine verifies the address+tag here (the integrity gate at the point remote bytes enter), and the provider decrypts at serve time. Keep `verify_chunk` (plain sha256) as the no-keys path. Add a `#[cfg(feature = "encryption")]` branch reading `provider.encryption_keys()`.

> **Decision recorded:** the cache stores **ciphertext** keyed by the keyed-address (decrypt-on-serve), matching `docs/parity-roadmap.md` §B.4 ("the local content-addressed cache… store ciphertext, decrypt on serve"). The engine's only job is to verify before it trusts a remote blob.

- [ ] **Step 4: Run to verify pass**

Run: `cd client/sync-engine && cargo test --features encryption hydrate_decrypts`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add client/sync-engine/src/lib.rs client/sync-engine/tests/encryption.rs client/sync-engine/Cargo.toml
git commit -m "feat(sync-engine): hydrate verifies keyed address + AEAD tag under encryption

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

### Task 3.2: Re-run convergence + fault-injection with encryption ON

**Files:**
- Modify: `client/sync-engine/tests/two_device_e2e.rs` (parameterize over encryption on/off)
- Modify: `client/sync-engine/tests/fault_injection.rs` (same)

- [ ] **Step 1: Parameterize the existing E2E + fault harness over an `encryption` flag**

Wrap the two-device and fault-injection scenarios so each runs once plaintext and once with a shared `UserKeys` set on both providers. The invariant is identical: A→B→edit→A converges byte-for-byte and the soak shows 0 silent losses — now over ciphertext.

- [ ] **Step 2: Run both suites with the feature**

Run: `cd client/sync-engine && cargo test --features encryption --test two_device_e2e --test fault_injection`
Expected: PASS — convergence + no-loss hold over ciphertext (`docs/parity-roadmap.md` §B test strategy).

- [ ] **Step 3: Commit**

```bash
git add client/sync-engine/tests/two_device_e2e.rs client/sync-engine/tests/fault_injection.rs
git commit -m "test(sync-engine): convergence + fault-injection pass with encryption ON

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Phase 4 — Key storage on device + multi-device distribution + recovery

**Outcome:** a device can persist its wrapped master key, unlock it with a passphrase or recovery code, and receive the key over the existing pairing channel. **No second secret channel.**

### Task 4.1: On-device key blob (wrap/unwrap) + recovery code

**Files:**
- Create: `client/fs-crypto/src/wrap.rs` (wrap/unwrap a master key under a KEK; recovery-code gen)
- Create: `client/fs-crypto/src/keystore.rs` (persist the wrapped blob next to the chunk cache)
- Modify: `client/fs-crypto/src/lib.rs`

- [ ] **Step 1: Write the failing tests**

```rust
// wrap.rs tests
#[test]
fn wrap_then_unwrap_with_passphrase() {
    let master = MasterKey([1u8; 32]);
    let blob = KeyBlob::wrap_with_passphrase(&master, "hunter2").unwrap();
    let back = blob.unwrap_with_passphrase("hunter2").unwrap();
    assert_eq!(master.expose(), back.expose());
}
#[test]
fn wrong_passphrase_fails_clean() {
    let blob = KeyBlob::wrap_with_passphrase(&MasterKey([1u8; 32]), "hunter2").unwrap();
    assert!(matches!(blob.unwrap_with_passphrase("wrong"), Err(KeyError::Unwrap)));
}
#[test]
fn recovery_code_unwraps_too() {
    let master = MasterKey([2u8; 32]);
    let (blob, code) = KeyBlob::wrap_with_recovery(&master).unwrap();
    assert_eq!(master.expose(), blob.unwrap_with_recovery(&code).unwrap().expose());
}
```

- [ ] **Step 2: Run to verify failure**

Run: `cd client && cargo test -p fs-crypto wrap`
Expected: FAIL — `KeyBlob` not defined.

- [ ] **Step 3: Implement wrap/unwrap**

`KeyBlob` = `{ salt: [u8;16], wrapped: Vec<u8> }`. `wrap_with_passphrase`: derive a KEK via `MasterKey::from_passphrase`-style Argon2id over the passphrase+salt, AEAD-seal the 32-byte master under the KEK (reuse `seal`/`open` with a nonce derived from the salt). `wrap_with_recovery`: generate a 256-bit recovery code (`getrandom`), Base32-encode it for the user, derive a KEK from it (HKDF), seal the master. `unwrap_*` reverse it; a wrong secret → AEAD open fails → `KeyError::Unwrap` (clean, no partial state). `keystore.rs` reads/writes the blob as a small JSON/CBOR file at `<chunks_dir>/../keyblob`.

- [ ] **Step 4: Run to verify pass**

Run: `cd client && cargo test -p fs-crypto wrap keystore`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add client/fs-crypto/src/wrap.rs client/fs-crypto/src/keystore.rs client/fs-crypto/src/lib.rs
git commit -m "feat(fs-crypto): key blob wrap/unwrap (passphrase + recovery code)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

### Task 4.2: Server stores opaque per-device key blobs (additive, server never reads a key)

**Files:**
- Create: `db/migrate/XXXX_add_encryption_to_users_and_key_blobs.rb`
- Modify: `app/models/user.rb` (add `encryption_enabled`), create `app/models/user_key_blob.rb`
- Modify: `app/controllers/v1/devices_controller.rb` + `auth_controller.rb` (pairing payload carries the wrapped blob)
- Test: `test/models/user_key_blob_test.rb`, `test/controllers/v1/pairing_encryption_test.rb`

- [ ] **Step 1: Write the failing server test**

```ruby
# test/controllers/v1/pairing_encryption_test.rb
test "pairing payload carries an opaque wrapped key blob the server never interprets" do
  # device A (authenticated) creates a pairing code AND uploads a wrapped master-key blob
  # device B redeems the code → receives the same opaque blob bytes
  # assert: server stored/returned the blob verbatim; no server code decodes it
end
```

- [ ] **Step 2: Run to verify failure**

Run: `bin/rails test test/controllers/v1/pairing_encryption_test.rb`
Expected: FAIL — no `user_key_blobs` table / no payload field.

- [ ] **Step 3: Implement the migration + opaque blob passthrough**

Migration: `add_column :users, :encryption_enabled, :boolean, default: false, null: false`; `create_table :user_key_blobs` with `user_id`, `device_id`, `blob` (binary/text, opaque), timestamps. `UserKeyBlob belongs_to :user`. In the pairing flow: an authenticated device may `POST` a wrapped blob alongside the pairing code; redemption returns it verbatim in the `/v1/auth/pair` response. **The server treats `blob` as opaque bytes — no parsing, no key material ever in plaintext server-side.** Device token + pairing mechanism unchanged (CLAUDE.md §8, filter #3).

- [ ] **Step 4: Run to verify pass**

Run: `bin/rails test test/controllers/v1/pairing_encryption_test.rb test/models/user_key_blob_test.rb`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add db/migrate app/models/user.rb app/models/user_key_blob.rb app/controllers/v1/devices_controller.rb app/controllers/v1/auth_controller.rb test/
git commit -m "feat(server): opaque per-device key blob over the pairing channel (encryption_enabled flag)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

### Task 4.3: Daemon loads keys on start; refuses to mount an encrypted library unlocked

**Files:**
- Modify: `client/sync-engine/src/daemon.rs` (unlock keys → `provider.set_encryption_keys`)
- Test: inline in `daemon.rs`

- [ ] **Step 1: Write the failing test**

```rust
#[cfg(feature = "encryption")]
#[test]
fn daemon_refuses_encrypted_library_without_unlock() {
    // a config marked encryption_enabled but with no unlocked keys must error on start,
    // not silently mount and write plaintext (which would leak).
}
```

- [ ] **Step 2: Run to verify failure**

Run: `cd client/sync-engine && cargo test --features encryption daemon_refuses_encrypted`
Expected: FAIL.

- [ ] **Step 3: Implement the unlock-on-start gate**

`DaemonConfig` gains an optional `encryption: Option<UnlockedKeys>`. On `start()`, if the library is encrypted (server `encryption_enabled` / a local marker) and no keys are unlocked → return an error (`Error::Locked`) before mounting. If keys are present → `provider.set_encryption_keys(keys)` before the first push/hydrate. The unlock itself (passphrase/recovery prompt → `KeyBlob::unwrap_*`) happens in the caller (Tauri app / CLI), out of scope for the daemon — the daemon just receives unlocked `UserKeys`.

- [ ] **Step 4: Run to verify pass**

Run: `cd client/sync-engine && cargo test --features encryption daemon_refuses_encrypted`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add client/sync-engine/src/daemon.rs
git commit -m "feat(sync-engine): daemon refuses to mount an encrypted library without unlocked keys

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

### Task 4.4: Explicit key-loss test (clean unrecoverable error, no plaintext leak)

**Files:**
- Modify: `client/sync-engine/tests/encryption.rs`

- [ ] **Step 1: Write the test**

```rust
#[cfg(feature = "encryption")]
#[test]
fn lost_key_yields_clean_error_no_partial_corruption_no_plaintext() {
    // encrypt+push with keys K; attempt hydrate+read with WRONG keys.
    // assert: verify_and_open errors cleanly; nothing decrypts; no plaintext is ever
    // written to the cache or served; the file simply cannot be read (data loss is clean).
}
```

- [ ] **Step 2: Run / verify it passes against the Phase 3 gate**

Run: `cd client/sync-engine && cargo test --features encryption lost_key_yields_clean_error`
Expected: PASS (the AEAD tag + address check already enforce this; this test pins the guarantee).

- [ ] **Step 3: Commit**

```bash
git add client/sync-engine/tests/encryption.rs
git commit -m "test(sync-engine): key-loss yields a clean unrecoverable error, no plaintext leak

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Phase 5 — Conformance + migration of existing plaintext libraries

**Outcome:** the external conformance suites pass with encryption ON (the *user-visible* plaintext is identical), and there is a documented, tested path to encrypt an existing plaintext library.

### Task 5.1: Re-run external conformance with encryption ON

**Files:**
- Modify: `client/test-conformance/webdav-rclone.sh`, `client/test-conformance/fsx-fuse.sh` (an `ENCRYPTION=1` mode that builds with `--features encryption` and sets keys)

- [ ] **Step 1: Add an encryption mode to the conformance scripts**

Each script, when `ENCRYPTION=1`, builds the mount with `--features encryption`, unlocks a fixed test passphrase, and runs the identical rclone/fsx workload. The assertion is unchanged: the plaintext the *user* sees through the mount is byte-for-byte correct (`docs/parity-roadmap.md` §B: "the plaintext the user sees must be identical").

- [ ] **Step 2: Run them**

Run: `ENCRYPTION=1 client/test-conformance/fsx-fuse.sh` (Linux) and `ENCRYPTION=1 client/test-conformance/webdav-rclone.sh`
Expected: 0 diffs / no mismatch — the data plane is byte-perfect under encryption.

- [ ] **Step 3: Commit**

```bash
git add client/test-conformance/webdav-rclone.sh client/test-conformance/fsx-fuse.sh
git commit -m "test(conformance): rclone+fsx byte-for-byte under encryption (user plaintext identical)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

### Task 5.2: Migrate an existing plaintext library to encrypted

**Files:**
- Create: `client/sync-engine/src/migrate_encrypt.rs` (re-address + re-seal every chunk under the new keys, rewrite manifests, re-push)
- Test: `client/sync-engine/tests/encryption.rs` (migration scenario)

- [ ] **Step 1: Write the failing migration test**

```rust
#[cfg(feature = "encryption")]
#[test]
fn migrate_plaintext_library_to_encrypted() {
    // build a plaintext library with N files; run migrate_encrypt(keys);
    // assert every chunk is now ciphertext at a keyed address, manifests re-point to the
    // new addresses, reads still return the exact original plaintext, and a second device
    // with the same keys converges.
}
```

- [ ] **Step 2: Run to verify failure**

Run: `cd client/sync-engine && cargo test --features encryption migrate_plaintext_library`
Expected: FAIL — `migrate_encrypt` not defined.

- [ ] **Step 3: Implement the migration**

`migrate_encrypt(provider, client, io, keys)`: for each file, read plaintext (hydrating from old plaintext chunks if needed), `set_encryption_keys`, re-`flush` to re-chunk+seal+re-address, which produces new manifests over keyed addresses; push the new versions (a normal commit — versioning keeps the old plaintext version until GC). Flip the server `encryption_enabled` flag at the end. Document that migration is **one-way** and that pre-migration versions remain plaintext until pruned (call this out — it is a real residual-plaintext window).

- [ ] **Step 4: Run to verify pass**

Run: `cd client/sync-engine && cargo test --features encryption migrate_plaintext_library`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add client/sync-engine/src/migrate_encrypt.rs client/sync-engine/tests/encryption.rs
git commit -m "feat(sync-engine): migrate an existing plaintext library to encrypted

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Phase 6 — Metadata / manifest encryption (OPTIONAL — explicit search/preview trade-off)

**Outcome:** *optionally*, node **names** are encrypted server-side so the server cannot read them. **This phase is gated on a product decision** and is OFF by default. Implement only if metadata-hiding is chosen over server-side search/preview.

### The trade-off to call out (record in `docs/encryption-design.md`)

Today the server reads node **names** for two features:
1. **Server-side search** (`Sync::Search` / `GET /v1/search`, `app/services/sync/search.rb`) — reads `nodes.name`. **Encrypting names BREAKS server-side search.** The replacement is **client-only search** (the client has plaintext names locally) — slower, no server index, but zero-knowledge.
2. **Server-rendered web UI** tree/preview/thumbnails — already cannot render encrypted **content** (bytes are opaque to the server once Phase 2 lands); encrypting **names** additionally blanks the server's file-browser labels (the web UI would show ciphertext names unless it decrypts client-side in the browser, which requires the key in the browser — a separate decision).

**Default chosen in this plan:** **names + structure + sizes stay plaintext** (server search + web UI keep working; only *content* is hidden). Phase 6 is the opt-in for users who want names hidden too and accept client-only search. **Do not build Phase 6 unless that product call is made.**

### Task 6.1 (CONDITIONAL): Encrypt node names; switch search to client-only

**Files:**
- Modify: `client/fs-provider/src/lib.rs` (seal `name` with a `name_key` HKDF sub-key before `export_tree`; open on `apply_remote`)
- Modify: `app/services/sync/search.rb` (return 501/empty when `encryption_enabled` — search is client-side)
- Modify: `client/sync-engine` (a local name-index search)
- Test: server test that search is disabled under encryption; client test that names round-trip encrypted

- [ ] **Step 1: Write the failing tests**

```rust
#[cfg(feature = "encryption")]
#[test]
fn node_names_round_trip_encrypted_through_server() {
    // export_tree seals names; the server stores ciphertext names; apply_remote on a second
    // device decrypts back to the exact plaintext name.
}
```
```ruby
test "server search is disabled (client-only) when encryption_enabled" do
  # GET /v1/search returns 501/empty for an encrypted library
end
```

- [ ] **Step 2: Run to verify failure**

Run: `cd client/fs-provider && cargo test --features encryption node_names_round_trip` and `bin/rails test -n /search.*encryption/`
Expected: FAIL.

- [ ] **Step 3: Implement name sealing + client-only search**

Add a `name_key` HKDF sub-key to `UserKeys`. Seal `name` (AEAD, deterministic nonce from a per-node id so the same name under one key is stable) before `export_tree`; open on `apply_remote`. The server stores the opaque name verbatim (already does — it's just a string). `Sync::Search` short-circuits to empty/501 when `user.encryption_enabled`. Add a client-side name search over the local plaintext tree.

- [ ] **Step 4: Run to verify pass**

Run the same commands.
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add client/fs-provider/src/lib.rs app/services/sync/search.rb client/sync-engine test/
git commit -m "feat: optional node-name encryption (client-only search trade-off)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Self-Review (run against parity-roadmap §B + plan-file-layer-parity §15)

**Spec coverage:**
- Cipher & framing (AEAD, `nonce‖ct‖tag`, per-chunk independence for range hydration) → **Task 1.2, 2.3**.
- Keyed-HMAC convergent addressing (per-user dedup survives; cross-user isolation; reject global-convergent + random-ciphertext) → **Task 1.4** (+ rationale in requirements).
- Key hierarchy (passphrase → Argon2id master → HKDF sub-keys) → **Task 1.3**.
- Self-host vs managed key management; key loss = data loss; recovery code → **Task 1.3, 4.1, 4.4** + design doc.
- Multi-device via the existing pairing channel (wrapped key, no second channel) → **Task 4.1, 4.2**.
- Blast radius (manifest hashes, chunk cache ciphertext + decrypt-on-serve, every hydrate hook, dedup negotiation over ciphertext addresses, debuggability) → **Task 2.2, 2.3, 3.1**; server address-agnostic → **Task 4.2** (only an opaque blob + flag).
- Does-NOT-break (cross-user dedup gone already, bytes-out-of-Rails, versioning) → preserved; no server byte awareness added.
- Sharing interaction flagged, not solved; dependency recorded → requirements "Interaction with SHARING".
- Why-last rationale preserved verbatim → requirements "Why encryption is sequenced LAST".
- Test strategy (KATs, tamper-fails, determinism, two-device + fault-injection ON, conformance ON, key-loss) → **Tasks 1.2, 1.4, 3.2, 4.4, 5.1**.
- Permissive licensing check → **Step 0b + Task 1.1 Step 2** (`cargo tree | grep -i gpl`).
- Metadata/search/preview trade-off as an explicit optional phase → **Phase 6**.

**Placeholder scan:** no TBD/TODO; every code step has concrete code; commands have expected output. The one prose "design note" (Task 1.4) documents the key-derivation-from-address resolution rather than leaving it implicit.

**Type consistency:** `UserKeys { addr_key, chunk_master }` (Task 1.3) is the type used in `chunk_address`/`seal_chunk`/`verify_and_open` (Task 1.4), `set_encryption_keys`/`encryption_keys` (Task 2.1), the seal-on-write branch (2.2), the open-on-read branch (2.3), and the hydrate gate (3.1). `MasterKey`/`ChunkKey`/`ChunkNonce`/`KeyBlob`/`KeyError`/`OpenError` are defined once and reused. Phase 6 adds a `name_key` sub-key to `UserKeys` — a forward extension, called out as such.

**Scope guard re-confirmed:** no `Maker::*` model/controller/service or `client/maker-app` product feature is touched. Server changes are confined to the sync control plane (`User` flag, an opaque `UserKeyBlob`, the pairing passthrough, and — only in optional Phase 6 — `Sync::Search`).

---

## Execution Handoff

This is a **docs/planning-only** deliverable (no code in this PR). When the team is ready to build it (after sharing/G12 and the other parity items, per the deliberate "encryption last" sequencing), execute with **superpowers:subagent-driven-development** (fresh subagent per task, review between tasks) — strongly recommended here because the Phase 1 crypto core is the highest-risk, most review-sensitive code in the project (key loss = data loss). **Get Phase 1 cryptographically reviewed before Phase 2.**
