# Implementation Plan — Direct-Client JuiceFS (no gateway)

**Status:** active · **Last updated:** 2026-06-10

## Decision recap

- **JuiceFS client runs directly on each user machine** (inside the Tauri app). No
  server-side gateway. Bytes and metadata flow client → cloud directly.
- **Metadata engine: Postgres.** Managed = **Neon** (serverless, built-in pooler,
  scale-to-zero, password auth). Self-host = Postgres + PgBouncer (later).
- **Block storage: Cloudflare R2** (S3-compatible, free egress), one bucket,
  `tenants/<id>/` prefix per tenant.
- **Isolation = volume-per-tenant** (JuiceFS has no internal ACL), enforced by four
  layers: per-tenant Postgres role, per-tenant R2 prefix+token, per-tenant
  encryption key, and short-lived broker-minted credentials.
- **Trade accepted:** WAN metadata latency (client → cloud Postgres), softened by
  JuiceFS client-side metadata caching. Multi-device freshness is ours to own.

## Architecture

```
  Tauri client (user machine)          Rails (control plane)         Cloud
  ┌─────────────────────────┐  OAuth    ┌──────────────────┐
  │ juicefs sidecar (mount) │ ────────► │ Auth / identity  │
  │ mount controller (FSM)  │           │ Credential broker│── mint scoped, short-lived
  │ keychain (tokens+creds) │ ◄──────── │ Provisioner      │   PG creds + R2 token + enc key
  └───────┬─────────────────┘  creds    └──────────────────┘
          │ metadata (PG wire, scoped role, sslmode=verify-full)
          ▼
   ┌──────────────────────────┐   provision: juicefs format
   │ Neon (managed PG+pooler)  │ ◄──────────────────────────
   │ db + role per tenant      │
   └──────────────────────────┘
          │ block GET/PUT (prefix-scoped token, per-tenant encrypted)
          ▼
   ┌──────────────────────────────────────────────────────────────┐
   │ R2: one bucket, tenants/<id>/ prefix per tenant               │
   └──────────────────────────────────────────────────────────────┘
```

## Components

1. **JuiceFS in Tauri** — bundle `juicefs` sidecar per OS; `CredentialSource`
   (OAuth → fetch `{metadata DSN, R2 token, enc key, volume}` from broker); mount
   controller injects them into `juicefs mount` with WAN cache flags; refresh loop +
   graceful re-mount on R2 token rotation; OS keychain for secrets.
2. **Neon (metadata)** — db + role per tenant; **direct** endpoint for JuiceFS
   (avoids the pooler prepared-statement question), **pooled** endpoint available for
   many-client scaling once verified.
3. **Credential broker (Rails)** — validate OAuth → resolve tenant → return
   short-lived tenant-scoped PG creds + R2 prefix token + enc key + volume name.
   Revocation = rotate / `ALTER ROLE … NOLOGIN`.
4. **Provisioner (Rails)** — on signup: create Neon db+role, gen enc key, create R2
   prefix+token, run `juicefs format`. Idempotent; clean up on half-failure.

## Required pieces beyond "client + pooler + broker" (the gaps)

- **The Neon project/cluster** itself (db + role per tenant).
- **Provisioning service** (distinct from the broker) — including running
  `juicefs format` server-side with master R2 creds.
- **Encryption key management** (KMS / Vault / Rails encrypted credentials).
- **Auth / identity** (OAuth/OIDC) — broker can't mint without it.
- **FUSE driver bootstrap** on client (WinFsp / FUSE-T / libfuse).
- **Mount lifecycle state machine** (SignedOut → … → Mounted → Degraded → Remounting
  → Error), with health checks, backoff, sleep/wake, network up/down.
- **Postgres backups / PITR** — metadata is irreplaceable; + periodic `juicefs dump`.
- **TLS + region placement** — Neon + R2 in the region nearest users to cut WAN RTT.
- **Multi-device freshness** (optional) — short cache TTLs or an ActionCable
  push-invalidation channel.
- **Observability** — mount health, failed-auth/refresh alerts, provisioning failures.

## Security model (four-layer isolation)

1. Per-tenant Postgres **role**, `CONNECT`-locked to its own database.
2. Per-tenant **R2 prefix** + scoped token.
3. Per-tenant **JuiceFS encryption key** (blocks useless cross-tenant).
4. **Short-lived, broker-minted** credentials; master creds only in Rails.

## Phased build (de-risk the scary part first)

- **Phase 0 — prove direct-client-over-WAN (1 tenant, Neon).** Manually format one
  volume on Neon + R2, mount from the client, **measure WAN metadata latency**, and
  **settle the Neon pooler vs. direct (prepared-statement) question**. *Details below.*
- **Phase 1 — Rails credential broker.** OAuth + `/volume/credentials` minting
  scoped short-lived creds; client fetch → mount → refresh.
- **Phase 2 — Provisioning service.** Automate onboarding (db/role + key + R2 +
  `juicefs format` + mapping), idempotent.
- **Phase 3 — Client hardening.** Mount FSM, refresh/re-mount, keychain, juicefs +
  FUSE-driver bundling, cache-tuning profile.
- **Phase 4 — Ops/security.** Pooler TLS + auth, Neon backups/PITR, revocation,
  observability, region placement.
- **Phase 5 (optional) — Multi-device freshness.** ActionCable push-invalidation.

## Top risks

1. **Pooler + JuiceFS prepared statements** (Neon pooled endpoint) — Phase 0.
2. **WAN metadata latency** — Phase 0 measurement decides if caching suffices.
3. **Provisioning atomicity** — half-formatted tenant must be cleanable.
4. **Metadata loss** — PITR from day one.
5. **Credential rotation vs. long mounts** — graceful re-mount built in, not bolted on.

---

## Phase 0 runbook (Neon + R2)

**Goal:** answer two questions — *(a) is WAN metadata latency tolerable?* and *(b)
does JuiceFS work against Neon's pooled endpoint, or must we use the direct one?*

**Prereqs (user provides):**
- A throwaway **Neon project** + database + a role/password. Capture BOTH connection
  strings: **direct** (`ep-xxx.<region>.aws.neon.tech`) and **pooled**
  (`ep-xxx-pooler.<region>.aws.neon.tech`).
- An **R2 bucket** + a **scoped token** (access key/secret) limited to a test prefix
  (e.g. `tenants/phase0/`). Revoke after the test.

**Step 1 — (optional) per-tenant encryption key:**
```bash
openssl genrsa -out phase0.pem 2048    # add -aes256 for a passphrase
export JFS_RSA_PASSPHRASE=             # empty if no passphrase
```

**Step 2 — format the volume (direct endpoint):**
```bash
juicefs format \
  --storage s3 \
  --bucket https://<ACCOUNT_ID>.r2.cloudflarestorage.com/<BUCKET>/tenants/phase0 \
  --access-key <R2_KEY> --secret-key <R2_SECRET> \
  --encrypt-rsa-key phase0.pem \
  "postgres://<role>:<pw>@ep-xxx.<region>.aws.neon.tech/<db>?sslmode=require" \
  phase0
```

**Step 3 — mount with WAN cache tuning:**
```bash
ACCESS_KEY=<R2_KEY> SECRET_KEY=<R2_SECRET> \
juicefs mount \
  "postgres://<role>:<pw>@ep-xxx.<region>.aws.neon.tech/<db>?sslmode=require" \
  ~/phase0 \
  --attr-cache 1 --entry-cache 1 --dir-entry-cache 1 \
  --background=false
```

**Step 4 — measure:**
```bash
juicefs bench ~/phase0 -p 1        # metadata + IO latency against Neon over WAN
# cold-listing feel:
time ls -R ~/phase0 >/dev/null
```

**Step 5 — settle the pooler question:** repeat Steps 2–3 using the **pooled** host
(`ep-xxx-pooler…`). If it errors on prepared statements ("prepared statement … does
not exist" / "unnamed prepared statement"), JuiceFS must use the **direct** endpoint
(or we disable prepared statements / use session pooling later). Record the result.

**Success criteria:**
- Mount works; `juicefs bench` completes; metadata-op latency is *usable* for the
  maker workload (large files, few cold listings).
- Clear answer on direct-vs-pooled for Neon.

**Cleanup:** `juicefs umount ~/phase0`; delete the R2 test prefix; revoke the R2
token; delete/pause the Neon project.
