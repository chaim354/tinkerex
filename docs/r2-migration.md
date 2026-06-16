# Migrating chunk storage to Cloudflare R2

**Goal:** point the managed deployment's chunk data plane at a real Cloudflare **R2**
bucket (replacing the SeaweedFS box in `config/deploy.yml`), and confirm latency is
usable for sync. R2 is the §4/§7 managed object-storage choice: S3-compatible, **zero
egress fees**, SigV4 presigned URLs — a clean fit for our "bytes move client ⇄ storage
via per-user presigned URLs, never through Rails" model (§8).

This is **config-only** on the server: `STORAGE_BACKEND=s3` + the `CHUNK_*` env. No
application code changes are required — `Storage::S3ChunkStore` (which already presigns
PUT/GET via `aws-sdk-s3`) talks to R2 the same way it talks to SeaweedFS/AWS. This doc
records the compatibility verdict, the exact steps, the CORS policy the web UI needs,
cost notes, and how to measure latency before/after.

> **Status:** plan + verified-locally latency harness. R2 specifics below were confirmed
> against Cloudflare's R2 docs (S3 API compatibility, presigned URLs, region `auto`). The
> live R2 leg still needs real account credentials to run end-to-end — see
> [§7 What still needs real R2 creds](#7-what-still-needs-real-r2-creds).

---

## 1. R2 compatibility check — does `S3ChunkStore` work against R2?

**Verdict: YES, unchanged.** Our presign path (`app/services/storage/s3_chunk_store.rb`)
uses `aws-sdk-s3`'s `Aws::S3::Presigner` for `:put_object` / `:get_object`, which emits a
standard **AWS SigV4 query-string presigned URL** (`X-Amz-Algorithm=AWS4-HMAC-SHA256`,
`X-Amz-Credential`, `X-Amz-Date`, `X-Amz-Expires`, `X-Amz-SignedHeaders`,
`X-Amz-Signature`). R2 implements exactly this. The client (`ServerClient::upload_chunk`/
`download_chunk`, `PresignedIO`) does a plain `PUT`/`GET` to the URL — no SDK, no SigV4 on
the client — so whatever the server signs, R2 honors.

Item-by-item against how `S3ChunkStore.from_env` is wired today:

| Concern | R2 behavior | Our code | Verdict |
|---|---|---|---|
| **Endpoint** | `https://<accountid>.r2.cloudflarestorage.com` | `CHUNK_ENDPOINT` passed straight to `Aws::S3::Client.new(endpoint:)` | ✅ set `CHUNK_ENDPOINT` to the R2 endpoint |
| **Region** | R2's region is `auto`; empty and `us-east-1` **alias** to `auto` | `CHUNK_REGION` defaults to `"auto"` (we currently set `us-east-1` for SeaweedFS) | ✅ use `auto` (the default); `us-east-1` would also work |
| **Addressing (path vs vhost)** | R2 supports **both** path-style (`endpoint/<bucket>/<key>`) and virtual-host (`<bucket>.<acct>.r2...`) | We pass `force_path_style: true` | ✅ path-style is supported by R2; no change needed (vhost would also work) |
| **SigV4 signing** | Standard AWS SigV4 (SHA-256, `AWS4-HMAC-SHA256`) | `aws-sdk-s3` Presigner | ✅ identical |
| **`put_object` presign** | Supported | `presign_put` | ✅ |
| **`get_object` presign** | Supported | `presign_get` | ✅ |
| **`head_object`** (our `exists?`) | Supported | `exists?` (used by `Sync::Commit.finalize verify:true` to confirm bytes landed) | ✅ |
| **`delete_object`** (our `delete`) | Supported, idempotent (204 on missing key) | `delete` (GC sweep) | ✅ — same idempotency we already rely on |
| **Credentials** | An **R2 API token** → Access Key ID + Secret Access Key | `CHUNK_ACCESS_KEY_ID` / `CHUNK_SECRET_ACCESS_KEY` | ✅ |

### What in our presign code is AWS/SeaweedFS-specific and might bite

Reviewed `s3_chunk_store.rb` line by line — nothing that breaks on R2. Two notes:

1. **`force_path_style: true` is fine on R2** (R2 accepts path-style). It was needed for
   SeaweedFS (which is path-style-only). Leaving it on for R2 is harmless. If you ever
   prefer virtual-host addressing, drop the flag — but there's no reason to.
2. **`CHUNK_REGION` is currently `us-east-1`** in `config/deploy.yml` (for SeaweedFS). On
   R2 set it to `auto`. It will *also* work as `us-east-1` because R2 aliases it, but
   `auto` is the documented value and avoids surprise if Cloudflare ever tightens the alias.

**Signed-header gotcha (the one real difference to know about):** if the server presigns a
PUT that includes a signed `Content-Type` (i.e. `ContentType` is part of the signed
request), then the client's `PUT` **must** send a matching `Content-Type` header or R2
returns `403 SignatureDoesNotMatch`. **Our code does NOT sign a content-type** — `presign_put`
calls `presigned_url(:put_object, bucket:, key:, expires_in:)` with no `content_type:`, so
the only signed header is `host`. Our client `PUT`s raw bytes with no `Content-Type`. So
we're clear. **Do not add `content_type:` to the presign without also making every client
(Rust `upload_chunk` + the JS uploader) send the exact same `Content-Type`.**

---

## 2. CORS — required for the WEB UI's browser-side PUT/GET

The desktop client (`ServerClient`/`reqwest`) is not a browser, so it's **not** subject to
CORS. But the web UI (`app/javascript/controllers/uploader_controller.js` and
`FilesController#blob`) does browser-side `fetch(presignedUrl, {method:"PUT"})` and GET
straight to storage. The browser will send a **CORS preflight** (`OPTIONS`) for the
cross-origin PUT, and block the response of the GET, unless the R2 bucket has a CORS policy
allowing the web origin.

> SeaweedFS in the current LAN deploy didn't need this because the dev/`memory` web path
> uses same-origin `/dev/blobs`. The moment the web UI talks to `*.r2.cloudflarestorage.com`
> (a different origin), CORS is mandatory.

### Exact R2 CORS JSON

Apply this on the bucket (Dashboard → R2 → *bucket* → **Settings → CORS Policy**, or via
the S3 `PutBucketCors` API / `wrangler`). Replace the origin(s) with your real web app
origin(s):

```json
[
  {
    "AllowedOrigins": [
      "https://app.yourdomain.com"
    ],
    "AllowedMethods": ["GET", "PUT", "HEAD"],
    "AllowedHeaders": ["*"],
    "ExposeHeaders": ["ETag"],
    "MaxAgeSeconds": 3600
  }
]
```

Notes:
- **`AllowedOrigins`** — the exact scheme+host(+port) the browser loads the app from. Use
  the production web origin; add `http://localhost:3000` (and your dev port) as a second
  entry only while developing the web UI against R2. **No wildcard `*`** in production — it
  would let any site use a leaked presigned URL from a browser.
- **`AllowedMethods`** — `PUT` (upload), `GET` (download/preview), `HEAD` (range/exists
  probes some fetch paths do). We do not browser-`DELETE` (deletes are server-side via the
  control plane), so `DELETE` is omitted.
- **`AllowedHeaders: ["*"]`** — covers the preflight's `Access-Control-Request-Headers`.
  Our uploads currently sign only `host` and send no custom headers, so this is permissive
  but safe; if you later sign a `Content-Type`, `*` still covers it.
- **`ExposeHeaders: ["ETag"]`** — lets JS read the ETag after a PUT (useful if the uploader
  ever verifies the returned ETag; harmless otherwise).
- **`MaxAgeSeconds: 3600`** — caches the preflight for an hour to cut `OPTIONS` chatter.

There's no CORS for the desktop/daemon client — only the browser leg needs it.

---

## 3. Exact migration steps

### 3.1 Create the R2 bucket + a scoped API token

In the Cloudflare dashboard (or `wrangler`):

1. **R2 → Create bucket.** Name e.g. `maker-chunks-prod`. Pick a location hint near your
   users / your Rails host (or leave automatic). Note your **Account ID** (Dashboard →
   account home, or `wrangler whoami`) — the endpoint is
   `https://<ACCOUNT_ID>.r2.cloudflarestorage.com`.
2. **R2 → Manage R2 API Tokens → Create API token.**
   - Permission: **Object Read & Write** (we need PUT/GET/HEAD/DELETE on objects).
   - **Scope it to the single bucket** `maker-chunks-prod` (least privilege — the token
     can't touch other buckets).
   - TTL: long-lived for a server credential, or rotate on a schedule.
   - On creation Cloudflare shows the **Access Key ID** and **Secret Access Key** (the S3
     credentials). Copy both now — the secret is shown once.

### 3.2 Apply the CORS policy

Apply the JSON from §2 to `maker-chunks-prod` (Dashboard → bucket → Settings → CORS, or
`wrangler r2 bucket cors put maker-chunks-prod --rules ./cors.json`, or the S3
`PutBucketCors`). Only needed if the **web UI** will hit R2; the desktop client doesn't
care, so you can defer this until the web UI ships.

### 3.3 Set the server env

The chunk store reads these (see `app/services/storage/chunk_store.rb` →
`S3ChunkStore.from_env`, and `docs/SYNC_SERVER.md`):

```sh
STORAGE_BACKEND=s3
CHUNK_ENDPOINT=https://<ACCOUNT_ID>.r2.cloudflarestorage.com
CHUNK_BUCKET=maker-chunks-prod
CHUNK_REGION=auto
CHUNK_ACCESS_KEY_ID=<R2 token Access Key ID>
CHUNK_SECRET_ACCESS_KEY=<R2 token Secret Access Key>
```

Also ensure `aws-sdk-s3` is in the Gemfile for the managed deploy (it's `require`d lazily
by `S3ChunkStore`; `docs/SYNC_SERVER.md` already calls this out for the Postgres/managed
profile).

### 3.4 Deploy via Kamal (per `docs/DEPLOY.md`)

`config/deploy.yml` already declares the `CHUNK_*` env (clear) + `CHUNK_SECRET_ACCESS_KEY`
(secret, sourced from the shell so it's never committed). For R2:

1. Edit `config/deploy.yml` `env.clear`:
   ```yaml
   STORAGE_BACKEND: s3
   CHUNK_ENDPOINT: https://<ACCOUNT_ID>.r2.cloudflarestorage.com
   CHUNK_BUCKET: maker-chunks-prod
   CHUNK_REGION: auto
   CHUNK_ACCESS_KEY_ID: <R2 token Access Key ID>
   ```
   (Leave `CHUNK_SECRET_ACCESS_KEY` in `env.secret` — it's read from your shell.)
2. Export the secret in the deploy shell, then redeploy:
   ```sh
   export CHUNK_SECRET_ACCESS_KEY=<R2 token Secret Access Key>
   ~/kamalw deploy        # or: kamal deploy   (rsync the tree first per DEPLOY.md)
   ```
   Because the **server only signs URLs (local HMAC/SigV4 math) and never contacts the
   store** (`DEPLOY.md` "SeaweedFS reach" note), the Rails box does not even need network
   reach to R2 — but **every client device does** (clients PUT/GET R2 directly). R2's
   endpoint is public HTTPS, so any client with internet works (unlike the LAN-only
   SeaweedFS box).
3. **Smoke test** (real bytes through R2 via presigned URLs):
   ```sh
   (cd client/sync-engine && SERVER_URL=https://<your-server> cargo run --example presigned_roundtrip)
   ```
   A `PRESIGNED ROUNDTRIP OK` line = device A → R2 → device B byte-for-byte. Then run the
   latency harness (§5) against the same server.

### 3.5 Migrating EXISTING chunks (SeaweedFS → R2)

Chunks are **content-addressed and per-user-keyed**: every object lives at
`chunks/<user_id>/<sha256>` (`ChunkStore#key_for`), and the bytes equal their hash. So a
migration is just a **copy of the `chunks/` keyspace** from the old bucket to R2 — no
re-chunking, no manifest rewrite, no DB change (the DB stores hashes, not URLs; URLs are
minted per request). The hashes and keys are identical in both stores.

`rclone` is the right tool (it speaks both S3 endpoints). Example:

```sh
# rclone remotes: one for SeaweedFS, one for R2 (both S3 providers)
rclone config   # add: [seaweed] type=s3 provider=Other endpoint=http://192.168.1.7:8333 ...
                #      [r2]      type=s3 provider=Cloudflare endpoint=https://<acct>.r2.cloudflarestorage.com region=auto ...

# Dry-run, then copy the whole chunk keyspace (content-addressed → safe to re-run/resume)
rclone copy --dry-run seaweed:my-bucket/chunks r2:maker-chunks-prod/chunks
rclone copy           seaweed:my-bucket/chunks r2:maker-chunks-prod/chunks --transfers=32 --checkers=64

# Verify (size + hash); content-addressing makes a hash check authoritative
rclone check seaweed:my-bucket/chunks r2:maker-chunks-prod/chunks
```

Because chunks are immutable and content-addressed, the copy is **idempotent and resumable**
— re-running `rclone copy` only fills gaps. Do the bulk copy **before** the cutover, then a
final incremental `rclone copy` right after flipping `STORAGE_BACKEND`/`CHUNK_*` to catch
anything written in between. For a brand-new managed deployment with no prior data, skip
this entirely.

> A self-host user moving boxes does the same thing between any two S3 endpoints; nothing
> R2-specific.

### 3.6 Rollback

The switch is just env, and the old data is still intact, so rollback is fast and safe:

1. **Keep the SeaweedFS bucket untouched** through the cutover (don't delete source data
   until R2 is validated for a few days). The `rclone copy` above does not modify the
   source.
2. To roll back, revert `config/deploy.yml`'s `CHUNK_*` to the SeaweedFS values (or
   restore the prior file from git) and `kamal deploy`. Clients immediately go back to
   presigned-SeaweedFS URLs on their next commit/hydrate.
3. **Caveat — chunks written to R2 *only* during the R2 window:** if devices uploaded new
   chunks while R2 was live, those bytes exist only in R2. Before rolling back, run the
   reverse copy to backfill SeaweedFS:
   ```sh
   rclone copy r2:maker-chunks-prod/chunks seaweed:my-bucket/chunks
   ```
   (Again content-addressed → safe.) Then roll back the env. If you skip this, any file
   whose new chunks landed only in R2 will fail to hydrate on SeaweedFS until backfilled.
4. The control plane (Rails DB: tree, versions, manifests, changelog) is **unaffected** by
   the storage backend — it stores hashes, never URLs — so no DB rollback is involved.

---

## 4. Cost & limits notes

R2's headline fit is **zero egress** — hydration (GET) traffic, which for a sync engine is
the dominant and unpredictable cost on egress-billed stores (S3/GCS), is **free** on R2.
That's the single biggest reason R2 is the managed choice for a file-sync product.

R2 pricing dimensions that *do* apply (Standard storage class):

| Dimension | R2 (Standard) | What incurs it in our workload |
|---|---|---|
| **Storage** | ~$0.015 / GB-month | total live chunk bytes (deduped, per-user); GC/retention (`Sync::Gc`, `RETENTION_POLICY=tiered`) bounds this |
| **Class A ops** (writes/mutations) | ~$4.50 / million | each chunk **PUT** (upload of a *missing* chunk), plus `head_object` in `finalize verify:true`, plus `delete_object` in GC sweep |
| **Class B ops** (reads) | ~$0.36 / million | each chunk **GET** (hydration) |
| **Egress** | **$0** | hydration bandwidth — free |
| **Free tier** | 10 GB storage + 1M Class A + 10M Class B per month | covers a small managed footprint outright |

**Operation-volume implications for our chunk model:**
- **Dedup keeps Class A down.** We only PUT *missing* chunks (`commit_begin` returns
  `put_urls` for the missing set, and the JS uploader/`PresignedIO` skip the rest), so
  re-saving an unchanged or already-stored file is ~0 PUTs. FastCDC + content-addressing
  means a 1-byte edit re-uploads only the changed chunk(s), not the whole file.
- **`verify: true` adds one Class A (`head_object`) per chunk at finalize.** That's the
  `Sync::Commit.finalize verify:true` path the web UI uses (`FilesController#finalize_upload`).
  It's a correctness check (confirm bytes landed before creating the version). At ~$4.50/M
  it's negligible, but if commit volume ever explodes you could make verify sampling-based.
- **GET (Class B) is cheap and egress is free**, so aggressive hydration / re-reads are not
  a cost concern — the opposite of S3.
- **Chunk size is the main op-count lever.** Smaller chunks = more dedup granularity but
  more ops per file; larger chunks = fewer ops but coarser dedup. FastCDC's average chunk
  size is the knob. At a typical ~1 MB average chunk, a 100 MB file is ~100 PUTs (one-time)
  + ~100 GETs per cold hydrate — well inside the free tier for a single active user, and
  cheap beyond it.

No R2 hard limits bite us: object size limit (5 TiB single PUT / multipart) is far above
any chunk; there's no request-rate cap that a per-user sync client would hit.

---

## 5. Latency harness — how to measure before/after

A runnable benchmark lives at **`client/sync-engine/examples/chunk_latency.rs`**. It
exercises the **real production data plane** — the presigned-URL PUT/GET that
`PresignedIO`/`ServerClient` use — against whatever store the **server** is configured for.
The client only needs `SERVER_URL`; the store is decided by the server's
`STORAGE_BACKEND` + `CHUNK_*`. **So you benchmark R2 by pointing the *server* at R2 and
re-running the exact same command — no client change.**

It measures, per chunk size, over a small batch (to expose per-op overhead):

1. **presign-PUT** — `POST /v1/commit` round-trip that mints a presigned PUT URL
2. **PUT round-trip** — uploading the chunk bytes to that URL (client ⇄ storage)
3. **presign-GET** — `POST /v1/chunks/download` round-trip that mints a presigned GET URL
4. **GET round-trip** — downloading the bytes from that URL
5. **hydrate e2e** — presign-GET + GET (what a read-on-cache-miss actually pays)

Each op uses **fresh, incompressible bytes** (a unique content hash) so nothing is deduped
away or cache-hit — every measurement is a genuine round-trip. Reports min / median / p95 /
max / mean in ms, plus median PUT/GET throughput.

### Run it

```sh
# --- BASELINE: server on the `local` backend (real bytes, on-box, no object store) ---
STORAGE_BACKEND=local CHUNK_LOCAL_DIR=$PWD/tmp/chunk-store bin/rails server -p 3001
# (in another shell)
(cd client/sync-engine && SERVER_URL=http://localhost:3001 cargo run --release --example chunk_latency)

# --- AGAINST R2 (the migration target): point the SERVER at R2, run the SAME command ---
STORAGE_BACKEND=s3 CHUNK_ENDPOINT=https://<ACCOUNT_ID>.r2.cloudflarestorage.com \
  CHUNK_BUCKET=maker-chunks-prod CHUNK_REGION=auto \
  CHUNK_ACCESS_KEY_ID=<id> CHUNK_SECRET_ACCESS_KEY=<key> bin/rails server -p 3001
(cd client/sync-engine && SERVER_URL=http://localhost:3001 cargo run --release --example chunk_latency)

# --- BASELINE vs SeaweedFS (the current store), for comparison ---
STORAGE_BACKEND=s3 CHUNK_ENDPOINT=http://192.168.1.7:8333 CHUNK_BUCKET=my-bucket \
  CHUNK_REGION=us-east-1 CHUNK_ACCESS_KEY_ID=admin CHUNK_SECRET_ACCESS_KEY=secret \
  bin/rails server -p 3001
(cd client/sync-engine && SERVER_URL=http://localhost:3001 cargo run --release --example chunk_latency)
```

Knobs (env on the client run): `BENCH_SIZES` (comma KB list, default `64,1024,4096`),
`BENCH_BATCH` (ops per size, default `8`). E.g.
`BENCH_SIZES=64,256,1024,4096 BENCH_BATCH=16`.

> For a true R2 read of *user-perceived* latency, run the client from where a real user is
> (a laptop on residential internet), not from the Rails host — the presign call is
> server-RTT-bound and the PUT/GET are R2-RTT-bound, and those two RTTs differ.

### Baseline numbers measured here (`local` backend, all-on-localhost)

Run on this dev box: server `STORAGE_BACKEND=local`, client and server both on `localhost`
(so this is the **floor** — control-plane presign cost + loopback data plane, with **no
WAN and no object-store RTT**). `BENCH_BATCH=10`, release build:

| chunk size | presign-PUT (med) | PUT rt (med) | presign-GET (med) | GET rt (med) | **hydrate e2e (med)** | PUT MB/s | GET MB/s |
|---|---|---|---|---|---|---|---|
| 64 KB   | 4.8 ms | 2.2 ms | 3.3 ms | 2.3 ms | **5.7 ms** | 28 | 27 |
| 1024 KB | 5.1 ms | 3.5 ms | 3.1 ms | 3.0 ms | **6.3 ms** | 284 | 330 |
| 4096 KB | 5.4 ms | 5.2 ms | 2.8 ms | 4.7 ms | **7.6 ms** | 762 | 857 |

**Reading the baseline:** with no network in the path, per-op cost is dominated by the
**presign call** (the Rails `commit_begin` / `chunks/download` round-trip — ~3-5 ms) and a
small, size-scaling transfer cost. Hydrate-on-miss (presign + GET) is ~6-8 ms end-to-end.
This is the irreducible floor; **R2 adds the client↔R2 RTT to the PUT and GET legs** (and
the client↔Rails RTT to the presign legs). On a typical broadband client, expect each R2
PUT/GET to add roughly one round-trip (~tens of ms to the nearest R2 PoP) on top of the
transfer time — so a realistic R2 hydrate-e2e is on the order of presign-RTT + R2-RTT +
bytes/bandwidth. The harness will report the real figure once pointed at R2.

This is well within "usable for async sync": hydration happens on-demand on read, in the
background, and per-chunk — it's not in the metadata/`stat`/`readdir` path (which is local
SQLite, §2). Even a 50-100 ms per-chunk R2 hydrate is invisible for the local-first UX.

### Measured against LIVE R2 (2026-06-15)

Run with the server pointed at a real R2 bucket (`maker-chunks-prod`, location ENAM,
endpoint `https://<acct>.r2.cloudflarestorage.com`, region `auto`) and the client on this
dev box (residential link). The presign legs hit **localhost** Rails; the PUT/GET legs hit
**R2 directly** — so the table isolates the R2 WAN cost. `BENCH_BATCH=12`, release build.
**Compatibility confirmed live first** (`presigned_roundtrip` → `PRESIGNED ROUNDTRIP OK`,
and the chunk verified in the bucket at `chunks/<user_id>/<sha256>`, byte-for-byte).

| chunk size | presign-PUT (med) | PUT rt (med) | presign-GET (med) | GET rt (med) | **hydrate e2e (med)** | PUT MB/s | GET MB/s |
|---|---|---|---|---|---|---|---|
| 64 KB   | 12.7 ms | 131.7 ms | 6.7 ms | 78.7 ms  | **84.5 ms**  | 0.5  | 0.8  |
| 256 KB  | 13.4 ms | 158.7 ms | 7.4 ms | 87.8 ms  | **95.6 ms**  | 1.6  | 2.8  |
| 1024 KB | 11.7 ms | 194.6 ms | 7.1 ms | 102.0 ms | **109.3 ms** | 5.1  | 9.8  |
| 4096 KB |  8.7 ms | 380.9 ms | 7.3 ms | 196.9 ms | **204.8 ms** | 10.5 | 20.3 |

**Reading it:** the prediction above held — per-chunk hydrate is ~85-205 ms, invisible in
the local-first UX (metadata is local; hydrate is background/on-demand). The **presign legs
stayed fast** (~7-13 ms, localhost Rails) — the WAN cost is entirely the direct client↔R2
transfer, exactly the §8 design intent. **Two caveats worth acting on:**

1. **~75-80 ms fixed cost per R2 op** (a 64 KB GET takes ~79 ms vs a 7 ms localhost presign),
   plus modest per-op bandwidth → **poor small-chunk throughput** (0.8 MB/s GET at 64 KB,
   rising to 20 MB/s at 4 MB). **Root cause, confirmed in the code:** it is **NOT** per-request
   TLS handshake — `ServerClient` holds one pooled `reqwest::blocking::Client`
   (`client/sync-client/src/lib.rs:257`) reused for both presign (→ Rails) and byte transfer
   (→ R2, `upload_chunk`/`download_chunk`), so keep-alive amortizes the handshake. And presign
   is **batched per file** (`download_urls(&[hashes])` mints all of a file's GET URLs in one
   Rails round-trip; `commit_begin` returns all `put_urls`), so the Rails RTT is paid once per
   file, not per chunk. The cost is purely the **R2 round-trip latency paid SERIALLY** — the
   engine loops `io.get`/`io.put` one chunk at a time (`client/sync-engine/src/lib.rs:382`,
   `:519`). 64 KB ÷ 79 ms ≈ 0.8 MB/s because it is RTT-bound and one-at-a-time. **Optimization:
   parallelize/pipeline chunk hydration** (concurrent `io.get` across a bounded worker pool) —
   pooling is already in place, so this is the one lever. A large *cold* file is the only path
   that bites: `per-chunk-RTT × (chunks ÷ parallelism)`. At P=1 a 100 MB file ≈ 10 s; at P=8-16,
   ~1-1.5 s. Tracked as a follow-up; not a blocker (warm/incremental reads hit the local cache,
   and metadata never touches the WAN).
2. **Measurement origin matters** — this is *this dev box → R2 ENAM*. The production Rails
   host (Unraid VM) and real users will see different RTTs. Re-run from a representative
   client for user-perceived numbers (the harness needs only `SERVER_URL`).

---

## 6. Summary checklist

- [ ] Create R2 bucket `maker-chunks-prod` + scoped **Object Read & Write** API token.
- [ ] (web UI only) Apply the §2 CORS JSON to the bucket.
- [ ] Set `STORAGE_BACKEND=s3` + `CHUNK_ENDPOINT`/`CHUNK_BUCKET`/`CHUNK_REGION=auto`/
      `CHUNK_ACCESS_KEY_ID`/`CHUNK_SECRET_ACCESS_KEY` in `config/deploy.yml` (+ shell secret).
- [ ] Ensure `aws-sdk-s3` is in the managed Gemfile.
- [ ] (migration) `rclone copy seaweed:.../chunks → r2:.../chunks`, verify, then cut over;
      final incremental copy after the flip.
- [ ] `kamal deploy`.
- [ ] Smoke: `presigned_roundtrip` example → `PRESIGNED ROUNDTRIP OK`.
- [ ] Latency: `chunk_latency` example against R2; compare to the baseline table above.
- [ ] Keep SeaweedFS as rollback for a few days (don't delete source); know the reverse
      `rclone copy` for rollback of R2-only chunks.

---

## 7. What still needs real R2 creds

Everything in this doc is config + verified-locally tooling **except** the live R2 leg,
which needs a real Cloudflare account (Account ID + an R2 token). With creds, run, in order:

1. `presigned_roundtrip` against a server pointed at R2 → confirms presign + PUT + GET +
   `head_object` verify all work on R2 end-to-end (the compatibility verdict in §1, proven
   live).
2. `chunk_latency` against the same server → fills in the real R2 latency column to compare
   with the localhost baseline above.
3. (web UI) A browser upload/download against R2 → confirms the §2 CORS policy is correct
   (the desktop client can't catch a CORS mistake; only a real browser will).

I could not create a test bucket here: the connected Cloudflare account has **no R2 buckets
and I was not given credentials**, so I documented the manual dashboard/`wrangler` steps
rather than invent keys. The harness was proven against the `local` backend (numbers in §5)
so the measurement path is known-good before you point it at R2.
