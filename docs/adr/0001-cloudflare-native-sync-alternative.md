# ADR 0001 — Cloudflare-native sync as an alternative to JuiceFS

- **Status:** Proposed / **deferred** (captured for the record, not adopted)
- **Supersedes:** nothing. The adopted path remains JuiceFS mount + a serverless
  metadata engine (Upstash/Neon).
- **Context:** Explored after asking whether D1 / Durable Objects could back
  JuiceFS metadata (they can't — no driver, wrong latency shape for a mounted
  FS). This ADR sketches the architecture where those Cloudflare primitives
  *do* fit: a custom **sync** service instead of a mounted filesystem.

---

## 1. Why consider it

- **Scale-to-zero economics.** D1 and Durable Objects are serverless — no
  always-on Redis/Postgres per tenant (the fixed cost flagged in the R2
  analysis). You pay per request, idle cost ≈ $0.
- **DO-per-user is a natural tenant boundary** — isolation, a single-writer
  authority (kills conflict races), and a built-in WebSocket event hub for
  propagation, all in one primitive that hibernates when idle.
- **Native dedup + versioning.** A content-addressed chunk store makes
  block-level delta sync and cheap version history fall out for free — the v2
  goal, without JuiceFS.
- **Free R2 egress** means direct client↔R2 byte transfer costs nothing.

## 2. The model shift

From **"mount a remote POSIX filesystem"** (JuiceFS) to **"sync a local folder
to a content-addressed service"** (Dropbox/Seafile-shaped). Every device holds
full copies (on-demand can be layered later — see §7).

## 3. Components

| Component | Role |
|---|---|
| **R2** | Content-addressed **chunk** store. Key: `users/<uid>/chunks/<chunkhash>`. |
| **Durable Object (per user)** | Single-writer authority for that user's library: commit log, current versions, conflict detection, **WebSocket change-event hub**. Hibernates when idle. |
| **D1 (per user, or per-user tables)** | File metadata + immutable version history (the `Asset`/`FileVersion` index): paths, version → manifest, timestamps. |
| **Worker (stateless edge)** | Auth (OIDC/JWT), routes a request to the caller's DO, **mints short-lived presigned R2 URLs**. Bytes never pass through it. |
| **Client (Tauri sync agent)** | Watches a local folder (`notify` + scan), chunks files, talks the sync protocol. Repurposes the existing app from mount-controller to sync-engine. |
| **Preview tier (NOT Cloudflare)** | Tessellation (FreeCAD/CadQuery) can't run on Workers — stays on Rails + Solid Queue or a container tier. |

## 4. Data flow

```
                 ┌──────────────────────── Cloudflare ────────────────────────┐
  Maker client   │                                                            │
  (sync agent)   │   Worker (edge)            Durable Object (per user)        │
     │           │   - auth                   - single-writer authority       │
     │ 1. authed │   - route → user DO        - commit log / current versions │
     │  commit   │   - mint presigned URLs    - WebSocket hub                 │
     ├──────────────────► ───────────────────────► ─┐                         │
     │           │           which chunks missing?  │  ◄──► D1 (per user)      │
     │ 2. missing chunks   ◄──────────────────────  ┘     files, versions,    │
     │   + presigned PUTs                                 chunk manifests      │
     │  ◄────────────────                                                      │
     │           │                                                            │
     │ 3. PUT only missing chunks DIRECTLY to R2 (presigned; no Worker in path)│
     ├──────────────────────────────────────────►  R2 (content-addressed)     │
     │           │                                                            │
     │ 4. "commit" → DO writes new version to D1 (atomic, single-writer)       │
     │ 5. DO pushes change event over WS → other devices pull manifest,        │
     │    GET changed chunks from R2 (presigned)                              │
     └────────────────────────────────────────────────────────────────────────┘
```

## 5. How it handles the hard problems

- **Data plane purity.** Bytes go client↔R2 directly via presigned URLs; the
  Worker/DO never touch file bytes. Same principle as the JuiceFS design.
- **Versioning.** Each commit = an immutable **manifest** (ordered list of
  chunk hashes) in D1. Versions share chunks → history is nearly free. Restore =
  read a manifest, fetch its chunks. Simpler than JuiceFS `clone`.
- **Dedup + delta.** Client uses **content-defined chunking (FastCDC)** so an
  insertion doesn't re-chunk the whole file; it uploads only chunks the service
  doesn't already have. This is the v2 dedup engine, native.
- **Multi-tenancy / isolation.** DO-per-user *is* the boundary; the Worker only
  ever routes an authenticated user to their own DO. D1 is per-user.
- **Credentials.** The client holds **no standing storage creds** — only its
  user token. It receives **per-object, time-limited presigned R2 URLs** per
  operation. This is *more* secure than JuiceFS (which needed metadata + bucket
  creds on the client). Master R2 keys live only in the Worker's secrets.
- **Propagation.** The DO is the single source of truth *and* the event hub:
  on commit it pushes over WebSocket to the user's other devices, which pull the
  manifest diff and GET changed chunks. **No `vfs/refresh` hack, no polling.**
- **Conflict.** A commit carries its `base_version_id`. The DO, being the only
  writer, checks `current == base`; if not, it writes a **conflict version**
  (both kept, lossless). Single-writer makes this race-free by construction.

## 6. Why it's elegant

It collapses four things the JuiceFS design needs separate machinery for —
propagation, conflict handling, versioning/dedup, and per-tenant isolation —
into the DO + content-addressed-chunk model, on a stack that costs ~$0 at idle.

## 7. On-demand is still reachable later

The content-addressed chunk store + presigned GET is an ideal backend for the
**CfAPI / File Provider** providers already designed: a hydrate callback fetches
the file's chunks from R2. So "full-sync now, on-demand placeholders later"
composes — this isn't a dead end for the mount UX.

## 8. Trade-offs — why it's deferred, not adopted

1. **It's a full custom sync engine.** Chunker, manifest store, sync protocol,
   conflict handling, and a real sync client — i.e. building Seafile/Dropbox's
   core. Explicitly out of scope for the current MVP ("reimplementing Dropbox
   makes no sense at this stage").
2. **Self-hostability breaks — the big one.** D1, Durable Objects, and Workers
   are **proprietary Cloudflare services with no self-host equivalent.** The
   product's premise is *self-hostable + managed*. This path makes the managed
   build un-portable and the **self-host build impossible** on this stack.
   Mitigation would be abstracting the sync protocol so self-host runs
   Postgres + a server process implementing the same DO/D1 roles — i.e.
   maintaining **two backends**. That cost is the core reason to defer.
3. **Two control planes.** File sync moves to Cloudflare while Rails still owns
   the maker layer (projects/inventory/BOM/preview) — or you go all-in on
   Workers and drop Rails. Either way it's a bigger architectural commitment
   than the current single Rails control plane.
4. **Preview still needs separate compute.** Workers can't run FreeCAD/CadQuery
   (CPU/time limits, no native binaries), so the CPU-heavy tessellation tier
   stays off-Cloudflare regardless.
5. **DO/D1 limits.** D1 ~10 GB/database (shard per user, fine until a user has
   millions of files); DO single-threaded + region-pinned (acceptable for
   *async* sync, unlike a latency-critical mount; tolerable WAN behavior).
6. **Vendor lock-in** to Cloudflare for the entire sync path.

## 9. Decision

**Defer.** Keep JuiceFS mount + a serverless metadata engine (Upstash/Neon) as
the adopted path. Revisit this ADR if **all** of these become true:

- Managed SaaS is the dominant deployment and **self-host is dropped or
  abstracted** behind a second backend you're willing to maintain.
- A **mounted drive is no longer required** for v1 (full-sync is acceptable),
  with on-demand deferred to the CfAPI/File Provider layer.
- Idle-cost / per-tenant-isolation pressure outweighs the cost of building and
  owning a custom sync engine.

Until then, the DO-per-user model is the right tool for an architecture we have
deliberately *not* chosen — documented here so the option is understood, not
rediscovered.
