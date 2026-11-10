# Roads not taken — abandoned & superseded approaches

Institutional memory for paths the project **deliberately did not take** (or took, then
replaced). The point is to stop us re-litigating settled decisions (`CLAUDE.md` §14
exists for the same reason). Each entry is deliberately short: **what we considered → why
we rejected it → where the full detail lived → the current approach.** The blow-by-blow
how-to for the dead paths is intentionally *not* here — it's in git history at the commits
named below. Trimmed long-form notes used to live in `docs/plan-direct-client.md`,
`docs/adr/0001-cloudflare-native-sync-alternative.md`, and the abandoned-path sections of
`CLAUDE.md` / `docs/STATUS.md` / `docs/architecture-sync-engine.md`.

> If you're tempted to revive one of these, read the rejection rationale first. Most were
> rejected against a **hard constraint** (self-hostability §7, permissive licensing §9,
> WAN latency, or tenant=user) that hasn't changed.

---

## 1. Remote-mounted filesystem over the WAN (rclone / JuiceFS mount) — ABANDONED

- **Considered:** mount the user's library as a remote POSIX filesystem (JuiceFS or rclone
  over WebDAV), so the OS talks straight to remote metadata + bytes.
- **Why rejected:** synchronous metadata round-trips are **~150 ms–1 s per file** over the
  WAN (Phase 0, measured). No production system (Dropbox/Google Drive/OneDrive) mounts a
  remote FS — they all use **local metadata + async sync + on-demand byte hydration.** A
  remote mount is structurally too slow; this is the single reason the current architecture
  exists.
- **Full detail lived in:** the Phase-0 runbook in `docs/plan-direct-client.md` (the
  JuiceFS-direct-client plan) and `docs/architecture-sync-engine.md` "Why this exists".
- **Current approach:** the **local-first sync engine** (`CLAUDE.md` §2,
  `docs/architecture-sync-engine.md`). Each device backs its FS with a local SQLite tree;
  the WAN is never in the `stat`/`readdir`/`open` path.
- **Leftover code:** `client/juicefs-backend` + `client/maker-app-core` (the Tauri
  mount-controller + JuiceFS WebDAV backend) are relics of this path — **reference only.**

## 2. JuiceFS as the data plane — ABANDONED

- **Considered:** JuiceFS (FUSE FS over an object store + a metadata engine) as the whole
  file layer.
- **Why rejected:** three independent problems — (a) chatty metadata over the WAN (the §1
  latency problem); (b) **no internal ACL**, so multi-tenancy needs a volume-per-tenant +
  per-tenant DB roles + a gateway (the opposite of our simple `user_id` scoping); (c)
  FUSE-**driver licensing** friction (§9). Edge-SQLite (Cloudflare D1, Turso) was evaluated
  as a JuiceFS metadata backend and also fails — no driver + chatty-metadata latency.
- **Full detail lived in:** `docs/plan-direct-client.md` (four-layer isolation, Neon
  pooler-vs-direct, provisioning), `CLAUDE.md` §14.
- **Current approach:** FastCDC content-defined chunking + a content-addressed manifest
  model + Rails/Postgres/SQLite metadata. Dedup + versioning are native. Tenant = user with
  ordinary Rails scoping.

## 3. Cloudflare-native sync (Workers + Durable Objects + D1 + R2) — DEFERRED, not adopted

- **Considered:** a custom sync service on Cloudflare primitives — DO-per-user as the
  single-writer authority + WebSocket hub, D1 for per-user metadata, R2 for chunks, a
  stateless Worker for auth + presigned-URL minting. Elegant: collapses propagation,
  conflict, versioning/dedup, and isolation into one stack at ~$0 idle.
- **Why deferred (not adopted):** **self-hostability breaks** — D1/DO/Workers are
  proprietary Cloudflare services with no self-host equivalent, and the product's premise is
  *self-hostable + managed* (§7). It would also be a full custom sync engine (Dropbox's core)
  and split the control plane (sync on Cloudflare, the maker layer on Rails). Revisit only if
  *all* of: managed-only becomes dominant AND self-host is dropped, a mounted drive is no
  longer required, and idle-cost pressure outweighs building a custom engine.
- **Full detail lived in:** `docs/adr/0001-cloudflare-native-sync-alternative.md` (kept as
  the ADR of record; the architecture sketch + trade-off table stay there).
- **Current approach:** Rails 8 + Postgres/SQLite + S3-compatible storage — the same model
  on both deployment hosts (§7). The chunk/manifest/presigned-URL ideas from this ADR *did*
  carry forward; only the Cloudflare-proprietary substrate was rejected.

## 4. WinFsp as the default Windows backend — SUPERSEDED by driverless CfAPI

- **Considered (and shipped first):** `fs-winfsp` — a WinFsp adapter mounting a drive letter
  over the same `Provider`. Verified live.
- **Why superseded:** WinFsp is **GPL** and needs a user-installed driver + `winfsp-x64.dll`
  on PATH at runtime. The **Cloud Filter API (CfAPI)** is the driverless OneDrive model — no
  GPL driver (§9), native Explorer integration, on-demand hydration — so it's the better fit.
- **Current approach:** **CfAPI is the default Windows backend** (flipped 2026-06-14;
  `client/fs-cfapi`, verified live on Windows 11 incl. two-device A↔B). `fs-winfsp` stays
  reachable behind the `winfsp-backend` cargo feature for one release, then can be retired.
- **Detail:** `docs/plan-windows-cfapi-migration.md`, `docs/cfapi-write-path-findings.md`.

## 5. Last-writer-wins conflict handling — REPLACED by conflict detection + keep/split

- **Considered (v1):** silent last-writer-wins — a concurrent/offline edit overwrites the
  other, dropping data.
- **Why replaced:** silently dropping a maker's edit is unacceptable. (2026-06-12)
- **Current approach:** each commit sends its `base_version_id`; a stale base records a
  **conflict** (both versions kept) and the client prompts keep-one / split-into-two
  (`Sync::Conflicts`, `GET /v1/conflicts`, `POST /v1/nodes/:id/resolve_conflict`). A base
  that IS current is a clean fast-forward. (`CLAUDE.md` §6, `docs/sync-protocol.md`.)

## 6. `mtime = now`-on-pull freshness hack — REPLACED by Option B (real nanos mtime + active invalidation)

- **Considered (interim):** stamp `mtime = now` on every pulled change so readers re-read.
- **Why replaced:** it **destroyed the true modification time**, breaking `make`/`ninja`/
  `cargo` incremental builds (a maker's toolchain). (2026-06-12)
- **Current approach (Option B):** preserve the real mtime end-to-end in **unix nanoseconds**
  (the source device's mtime verbatim on `apply_remote`; `set_mtime` for `utimensat`/`cp -p`;
  server columns are bigint) **plus an explicit `invalidate(ino)` seam** — on FUSE the kernel
  `notify_inval_inode` instead of an mtime bump. (`docs/plan-real-mtime-and-invalidation.md`.)

## 7. FSKit as the macOS mount — DESIGNED, BLOCKED (not built); WebDAV is the live path

- **Considered:** FSKit, Apple's native kext-free filesystem-extension framework, as the
  principled macOS mount (peer of Linux-FUSE / Windows-CfAPI over the same `Provider`).
- **Why not the current path:** FUSE-T's FSKit build can't mount on macOS 26 (silent fail,
  greyed System-Settings toggle), and a first-party FSKit extension needs a **paid Apple
  Developer membership** ($99/yr) for the entitlement + signing + notarization — not yet
  available. So FSKit is a **design sketch, not built** (no `client/fs-fskit` crate exists).
- **Current approach:** **macOS uses WebDAV** (`fs-webdav`, native `mount_webdav`, no
  kext/FSKit) — fully working and verified live on macOS 26. FSKit stays the future
  principled endpoint behind a feature flag once a paid membership lands.
- **Detail:** `docs/plan-macos-fskit-migration.md` (forward-looking sketch; explicitly "no
  code lands from it"). Note: it parallels `client/fs-fuse`, not `fs-cfapi` (full mount, not
  placeholders).

## 8. Addons delivered as a Rails engine gem — ABANDONED after the host-side prep was built

- **Considered:** extract the three `/tools` addons + both GPL sidecars into a `maker-addons`
  repo, delivered back to the host as a **non-isolated Rails engine gem** that registers its
  addons from its own engine. Host keeps a six-surface SDK (`LibraryOutput`, `BaseController`,
  `LibraryFolders`, the current-project hooks, `AddonState`, `Registry.register`).
- **Why rejected:** it cannot deliver **independent deploy of an addon's UI**, which turned out to
  be the goal that mattered. An engine gem lives *inside the Rails image*, so changing a Box
  Generator view still means a gem bump and a full Rails redeploy. The original design scored this
  🟡 and said so plainly; the pivot came when independent deploy was named as the actual
  requirement rather than a nice-to-have. Two further costs made it worse: engine assets through
  importmap/propshaft needed a spike to de-risk, and the addon's tests would have lived in a
  different repo from the code they prove, because an engine dummy app would have had to
  reimplement the server (users, auth, `nodes`, a configured `FileLayer`) to test a form.
- **What was actually built, then abandoned:** `Tools::` namespacing of the three addon clients,
  `Maker::Addons::SDK_VERSION` + `require_sdk!` (a boot-time gem/host skew gate),
  `Registry.register` with per-addon `path:` procs, and the gallery rendering `addon.path_for`.
  **PR #115** — green on all gates, kept as reference rather than merged. It is **CLOSED**, not
  "left open" as this line claimed until 2026-09-01, and its branch
  `claude/tools-addons-separate-repo-d44dc8` was DELETED that day. Its spec and plan were rescued
  into this repo first and are now `docs/superpowers/specs/2026-08-02-tools-addons-separate-repo-design.md`
  and `docs/superpowers/plans/2026-08-02-addon-sdk-host-prep.md`.
- **What survived the pivot:** almost none of the above. The `path:` procs in particular solved
  per-addon route-helper variation, which the current approach removes entirely by collapsing to
  one generic route. Two *unrelated* findings from that work were worth keeping: the
  `assert_select` message-vs-comparator footgun, and `pin_all_from`'s lazy expansion making
  importmap wiring unverifiable by config inspection. **This line called them §14e invariants from
  2026-08-02 (PR #116), but the commit that wrote them (`11d02986`) lived only on the PR #115
  branch and never reached `main`.** Both were re-probed on 2026-10-22 (rails-dom-testing 2.3.0,
  importmap-rails 2.2.3), still held, and landed in CLAUDE.md §14e then: the first in the
  `assert_select`'s-arguments bullet, the second folded into the CSP bullet ("only a browser
  knows") as its importmap instance.
- **Current approach:** addons as **runtime-loaded manifest + plain-ESM bundles**, served by a
  permissive static container and proxied same-origin by one generic `Tools::AddonsController` —
  `docs/superpowers/specs/2026-08-02-addons-runtime-bundle-design.md`. Republishing a bundle *is*
  the deploy. Same-origin proxying is **forced** by the sidecars being internal-only (no `port:`)
  plus `script_src :self`, and it happens to remove the need for any addon token or write-back API.
- **Note for a future reader:** the repo actually built for that current approach is
  `chaim354/tinkerex-addons`, not the `maker-addons` name this abandoned engine-gem plan proposed
  above — don't go looking for a repo by that name. See CLAUDE.md §14c for the invariants and
  `tinkerex#57` (the 2026-08-03 arc, once STATUS.md's entry) in the record, CLAUDE.md §11.

---

## 9. Git on `s3` / `chunk_remote` without a local filesystem — DEFERRED, with the blocker named

- **Considered:** let the maker commit from inside tinkerex on every backend, not just `share`.
  Two shapes: (a) `tinkerex#161`'s hydrate-to-an-ephemeral-cache, and (b) a write-ahead log in
  object storage, prompted by Cursor's "Git at any scale" (their Continuity platform).
- **Why we rejected (a):** `s3` and `chunk_remote` have no filesystem to hand to git, so rugged can
  only run against a materialised copy. Measured in `tinkerex#161`: **11,287 GETs on a cold
  container** for an unpacked repository.
- **Why (b) does not rescue it:** Continuity's WAL is a **durability and replication layer *under*
  a normal git repository on fast local NVMe**, which serves every read. A replica with no local
  copy *materialises it from the WAL* — our hydration step by another name. Their answer to
  hydration cost is not the WAL: it is that the WAL carries **packfiles**, and only the primary
  repacks. `tinkerex#161` had already reached that same conclusion independently (packed ~1.1 MB
  across 3 files, sub-millisecond; unpacked 11,287 GETs), which is why it put consolidation in the
  commit loop. **Its storage thinking was right; its product model — app-created repos, a
  15-minute sweep, foreign repos refused — was what got reverted.**
- **Worth taking if this is revived:** S3 **conditional GET / CAS** (metadata-only conditional GET
  under 10 ms; compare-and-swap on an index object gives linearizable updates with no lock and no
  lease — plausibly newer than `tinkerex#161`'s design work); **packs are the unit, never loose
  objects**; and the **warm-cache / source-of-truth** split as a sharper framing of "ephemeral
  container cache".
- **The smaller idea, which needs no WAL:** a commit is a *partial* read of the DAG — the ref, the
  HEAD commit, and the trees along the path to each changed file. Two files at depth three in a
  2,305-file repository is roughly **8 objects read and 8 written**, not 11,287.
- **The blocker, and it is why this is deferred rather than planned:** in a real repository those
  objects live inside a packfile, delta-compressed, so an individual object cannot be fetched — it
  needs the `.idx`, range requests into the pack, and delta-chain reconstruction. And **rugged
  cannot help**: `tinkerex#161` verified `Rugged::Backend` exposes zero methods, and `Odb`,
  `Indexer` and `Packbuilder` are undefined, so there is no custom object database to plug in.
- **Does NOT apply to `chunk_remote` for a different reason entirely:** the objection there was
  never cost. The maker's own machine has that repository checked out with real git, so a
  server-side commit moves refs under a live working copy. A WAL does not fix a racing checkout.
- **Current approach:** commits are gated on the `local_worktree` capability — true on `share`
  only — and **Save works on all three backends**. `docs/superpowers/specs/2026-08-28-edit-and-commit-in-a-repo-design.md`,
  `tinkerex#178`. Widening this is a new *answer* to `local_worktree`, never a rewrite.

---

## 10. Gerber → 3D via the model viewer — REJECTED (2026-09-06)

- **Considered:** convert a board's Gerber/Excellon layers into a mesh and show it in the same
  Online3DViewer stage `:model3d` uses, so a PCB would get the 3D viewer's orbit, pan and zoom
  instead of a flat picture. Asked directly, in those words, which is why it is written down.
- **Why rejected:** three independent reasons. (a) **A board export is a 2D artefact** — the fab
  house reads exactly what tracespace draws, and the file page's job is to show *that*, faithfully,
  at any zoom; a render of an extruded approximation is a different document from the one being
  checked. (b) **There is no permissively licensed Gerber→mesh pipeline** (§9), so this is a
  polygon-boolean extruder we would own: copper, mask, silk and drill hits unioned and subtracted
  per layer. (c) **The cost buys worse fidelity** — an ordinary four-layer board is hundreds of
  thousands of triangles for a picture of the same layers with the trace edges rounded off by
  tessellation, and every drill hit is another boolean.
- **What was actually being asked for was the INTERACTION, not the third dimension** — move around
  and zoom in, which the 3D viewer happens to be where you meet it. That is a `viewBox`, and
  `measure_controller.js` already drove one.
- **Current approach:** tracespace's SVG plus **one shared viewBox pan/zoom**
  (`app/javascript/lib/svg_pan_zoom.js`, extracted from the Measure view so there is not a second
  copy of the maths), a `Fit` button, and **per-layer show/hide toggles** — which re-compose from
  the one `renderLayers` result and are a thing a mesh conversion could not have offered at all.
  `docs/invariants/files-preview.md`'s `:gerber` section, CLAUDE.md §14d.

---

## Active decisions (do NOT confuse with the above — these are CURRENT, not abandoned)

For clarity, these settled choices are **adopted**, not roads-not-taken:
- **Tenant = user** (one library, the user's own devices) — current, simplest portable model.
- **Permissive licensing** (MIT/Apache/BSD), avoid GPL/AGPL in deps/artifacts (§9).
- **Per-OS native mounts over one `Provider`** — Linux FUSE, Windows CfAPI, macOS WebDAV.
- **SeaweedFS (Apache)** as the self-host S3 backend, not MinIO (AGPL).
- **Postgres managed / SQLite self-host**, one adapter-agnostic codebase.
