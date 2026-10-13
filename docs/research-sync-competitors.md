# Research: tinkerex sync vs. major virtual-drive systems (2026-06-14)

> **HISTORICAL — not re-verified.** Written before the repository split of 2026-08-20, when the
> sync engine and the Rust client still lived here (they are `chaim354/tinkerex-sync` and
> `chaim354/tinkerex-client` now). Kept for its reasoning and its measurements; it does not
> describe what this repository contains today. The current map is `docs/README.md`.


Comparison of our file-sync architecture against Dropbox, Google Drive, Nextcloud,
ownCloud/oCIS, OpenCloud, Seafile, and Syncthing — with a ranked list of what to build
next. Grounded in our docs (`CLAUDE.md`, `architecture-sync-engine.md`,
`sync-protocol.md`, `versioning.md`, `STATUS.md`) + primary engineering sources (cited).

---

## 1. Our model in brief

- **Local-first metadata** — each device backs its FS with a local SQLite tree; the WAN
  is never in the `stat`/`readdir`/`open` path.
- **Async sync via a server changelog** — Rails 8 is source of truth; each mutation
  appends one `changelog(seq, …)` row + bumps `head_seq`; devices pull `seq > cursor`.
  ActionCable `{head_seq}` nudge (~39 ms) + cursor-delta poll fallback.
- **CDC + content addressing** — FastCDC (~1–4 MB chunks), SHA-256-keyed, deduped +
  refcounted; an edit re-chunks locally and uploads only new hashes.
- **Bytes never transit Rails** — presigned PUT per missing chunk + prefix-scoped read
  token for GET; chunks go client ⇄ object storage (R2 / SeaweedFS) directly.
- **Native versioning** — a version = an immutable manifest sharing chunks; restore
  re-points a node at an old manifest with zero new blocks.
- **Per-OS native mounts over one `Provider`** — Linux FUSE, Windows CfAPI (default,
  driverless), macOS WebDAV.
- **Concurrency** — conflict detection via `base_version_id` (stale base → recorded
  conflict, keep both, keep/split) + best-effort TTL advisory locking.
- **Tenant = user.** Deferred: sharing/multi-user, selective sync, chunk encryption.

**One-line:** a Seafile-shaped CDC/block sync engine wearing Dropbox/OneDrive-shaped
on-demand-placeholder clothing, with a Rails control plane instead of bespoke infra.

---

## 2. Per-system comparison (summary)

| System | Metadata | Chunking / dedup | Hydration | Versioning | Notable |
|---|---|---|---|---|---|
| **Dropbox (Nucleus)** | local/remote/synced **three-tree** + planner, stable id, atomic moves | ≤4 MB CDC blocks, SHA-256, Magic Pocket content-addressed blob store | Smart Sync placeholders (CfAPI on Win) | server 30-day | **Trinity** fault-injection test harness; LAN sync (deprecated, CVE-2021-28171); bandwidth throttling; selective sync |
| **Google Drive** | local cache + sqlite metadata | **not public** (inferred opaque-object) | virtual drive + pin/online-only | server-side | less relevant as block-model comparison |
| **Nextcloud** | csync 3-way + per-folder journal, ETag + fileid | **upload chunking only** (fixed 5–10 MiB), server reassembles; **no dedup, no block-delta** | CfAPI virtual files | whole-file copies | 1-byte change to 1 GB file = full re-upload |
| **ownCloud classic** | same csync/ETag lineage | same fixed-chunk-upload | — | whole-file | common ancestor of Nextcloud |
| **oCIS (Go rewrite)** | **decomposedfs** (UUID node files, nodeid→parentid), MessagePack metadata | **not CDC / not block-deduped** | — | revisions as separate node files | first-class **Spaces** (sharing primitive); server-side sophistication |
| **OpenCloud** | ≈ identical to oCIS (2025 fork) | same | same | same | licensing/governance signal, not new technique |
| **Seafile** ⭐ | **git-like** Repo→Commit→FS→Block, content-hash FS object ids | **CDC ~8 MB blocks**, content-addressed + deduped | — | git-like commit graph | **closest sibling**; DB metadata + object-store blocks = our split; **virtual repos** = sharing + selective sync |
| **Syncthing** | per-file change-version, global model from peer union | **fixed power-of-2 blocks** (128 KiB–16 MiB) → weak insert-delta | — | versioning configurable | P2P Block Exchange Protocol; mesh peer transfer |

---

## 3. Delta analysis

**Where we match or beat the field (don't relitigate):**
- CDC + block dedup + block-delta-on-edit — matches Dropbox/Seafile, **beats**
  Nextcloud/ownCloud/oCIS/OpenCloud (whole-file) and Syncthing (fixed blocks). Right call
  for large 3D/CAD.
- Native versioning with zero-copy restore — as good as Dropbox/Seafile, better than
  whole-blob-revision systems.
- Bytes out of the control plane via presigned URLs — cleaner than Nextcloud
  (bytes through PHP/WebDAV), self-hostable in a way Magic Pocket isn't.
- Local-SQLite-first metadata — matches the industry consensus.

**Gaps where proven techniques exist that we lack:**

| Gap | Proven by | Our status |
|---|---|---|
| Selective sync | Dropbox, Seafile virtual repos | deferred |
| Sharing / multi-user | oCIS/OpenCloud Spaces, Seafile | deferred (tenant=user) |
| Adversarial concurrency harness | Dropbox **Trinity** | have convergence/property suites, no fault-injection on the engine state machine |
| Three-tree reconcile + stable-id atomic moves | Dropbox Nucleus | linear changelog + per-node chain; concurrent move-into-move untested |
| E2E / at-rest chunk encryption | Seafile encrypted libs | designed-for, not built |
| LAN sync / peer block transfer | Dropbox (hist.), Syncthing | none |
| Bandwidth scheduling/throttling | Dropbox | none |
| Retention/GC **policy job** | Dropbox 30-day, Time Machine | mechanism built, **policy + S3 delete not wired** |
| Partial / range hydration | CfAPI progressive hydration | per-chunk on read, no big-file range policy |
| Real OAuth/OIDC email verification | all managed services | pairing-code bootstrap done, OIDC deferred |

---

## 4. Top things to implement (ranked)

**Highest-leverage: #1–#4** — close a gap a maker hits in week one, fit our
chunk/manifest/changelog model with little/no new infra, and protect data integrity or
the SaaS trust story.

1. **★ Retention/GC policy job + S3 `delete_object`** — *Low effort.* Scheduled Solid
   Queue job: tiered keep-set per node → existing `prune_version!` → `sweep_orphans!`,
   and actually wire the S3 delete. **Versioning large CAD without pruning grows storage
   unbounded — a live cost/correctness bug, not a feature.** Keep `current_version` +
   pinned invariant; self-host defaults to keep-all.
2. **★ Selective sync** — *Medium.* Per-device subtree subscriptions; unsubscribed
   folders stay metadata-only placeholders. Client-side subscription state + hydration
   gate; keep the server tree complete (selectivity is a client policy, not a partial
   server tree). #1 ergonomic gap for makers with 100s of GB.
3. **★ E2E / at-rest chunk encryption (per-user key)** — *Medium.* Encrypt each chunk
   before PUT; content addressing switches to hash-of-ciphertext / per-user HMAC to keep
   dedup (already per-user). Underpins the SaaS trust story. Get the AEAD + KDF design
   reviewed first; key loss = data loss.
4. **★ Adversarial sync-engine test harness (our "Trinity")** — *Medium.* Fault
   injection + randomized timing + concurrent local/remote mutation against the engine
   state machine, beyond today's deterministic suites. We already found 2 foundation bugs
   by testing; this finds the unhappy-path rest. Time-box to documented failure modes.

**Second tier (#5–#9):**
5. **LAN sync / peer block transfer** — *Med-High.* mDNS/UDP discovery + hash-verified
   peer chunk fetch. Great for workstation+laptop+NAS on one LAN. Security: never serve a
   chunk cross-user (learn from Dropbox CVE-2021-28171).
6. **Bandwidth scheduling / throttling** — *Low-Med.* Client-side rate caps in the
   chunk-transfer layer; no protocol change.
7. **Sharing / multi-user (Spaces-style)** — *High.* New authz + cross-user dedup rework
   + changelog scoping. Business-model decision; defer to validated demand.
8. **Real OAuth/OIDC email verification** — *Medium.* OmniAuth/OIDC; device-token +
   pairing stays underneath.
9. **Partial / progressive hydration policy** — *Low-Med.* Manifest already maps
   ranges→chunks; wire CfAPI/File-Provider hydration hooks to range-fetch. Opt-in per
   file type (some apps read-whole/mmap).

**Watch-list (#10–#11):**
10. **Three-tree reconcile + planner (Nucleus)** — *High, core rework.* Don't build
    speculatively; let #4 surface whether we actually have concurrency bugs first.
11. **Pinned versions + per-version size attribution (UI)** — *Low.* `pinned` flag exempt
    from GC + "this version added N MB"; complements #1.

**Bottom line:** the data plane is already best-in-class. Leverage is not re-architecting
the engine — it's (1) wiring retention so storage doesn't grow unbounded, (2) selective
sync so a laptop survives a 100 GB library, (3) encryption so the SaaS story holds, and
(4) an adversarial harness so the unhappy paths are proven — all fitting the existing
model without new infra. Sharing (#7) and a three-tree planner (#10) are the only items
needing genuinely new architecture.

## Sources
Dropbox: [Nucleus rewrite](https://dropbox.tech/infrastructure/rewriting-the-heart-of-our-sync-engine),
[Testing/Trinity](https://dropbox.tech/infrastructure/-testing-our-new-sync-engine),
[Magic Pocket](https://dropbox.tech/infrastructure/inside-the-magic-pocket),
[Project Infinite](https://dropbox.tech/infrastructure/going-deeper-with-project-infinite),
[LAN Sync](https://dropbox.tech/infrastructure/inside-lan-sync).
Nextcloud: [Desktop architecture](https://docs.nextcloud.com/desktop/latest/architecture.html),
[WebDAV chunking](https://docs.nextcloud.com/server/stable/developer_manual/client_apis/WebDAV/chunking.html).
oCIS: [decomposedfs](https://owncloud.dev/ocis/storage/storagedrivers/),
[Spaces](https://owncloud.dev/architecture/collaborative-storage/).
OpenCloud: [vs oCIS](https://github.com/orgs/opencloud-eu/discussions/262).
Seafile: [Data model](https://manual.seafile.com/latest/develop/data_model/),
[FS mgmt / CDC](https://deepwiki.com/haiwen/seafile/3-file-system-management).
Syncthing: [BEP v1](https://docs.syncthing.net/specs/bep-v1.html).
CfAPI: [Build a cloud sync engine](https://learn.microsoft.com/en-us/windows/win32/cfapi/build-a-cloud-file-sync-engine).

**Sourcing caveats:** Google Drive's block/dedup model is not publicly documented
(characterized as a placeholder/virtual-FS redirector; block layer inferred). Dropbox's
chunking specifics come from the Magic Pocket posts + secondary sources, not the Nucleus
post itself.
