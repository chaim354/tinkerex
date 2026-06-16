# Cost model & cheapest-hosting recommendation

**Maker Server** — a self-hostable + managed-SaaS, local-first file **sync engine** for
makers. This doc models the cost of running the **managed (SaaS)** deployment and
recommends the cheapest **prod-like remote test box** for latency/perf work.

**Pricing dated 2026-06.** Every figure is sourced inline. Cloud prices are regional and
tiered — where that matters it is called out. Several budget hosts repriced in early-mid
2026 (Hetzner +30%, Oracle free-tier halved, Fly free tier gone), so the figures here are
a 2026-06 snapshot, not a forward guarantee.

The architecture that makes this model what it is (read these first):
- **Bytes never flow through Rails** (`CLAUDE.md` §8). The Rails box only signs presigned
  URLs and serves the control plane; chunk bytes move **client ⇄ object storage directly**.
  So the compute host is *not* bandwidth-heavy — it is a small always-on Docker host.
- **Object storage = Cloudflare R2** (`CLAUDE.md` §4/§7), whose **zero egress** is the
  whole structural advantage (§1 below). The R2 unit economics were already worked out in
  `docs/r2-migration.md` §4 and are reused verbatim here.
- **Chunks are content-defined (FastCDC ~1 MB avg), content-addressed, deduped, and
  refcounted; versions are kept, GC sweeps refcount-0 chunks** (`CLAUDE.md` §5, `Sync::Gc`,
  `RETENTION_POLICY=tiered`). Dedup + retention are what *bound* the per-user storage and
  op counts below.

---

## 1. Per-user VARIABLE cost (scales with users)

The data plane is R2. The dimensions that bill (Standard storage class, 2026-06,
`docs/r2-migration.md` §4, confirmed against current R2 pricing
[[R2 pricing]](https://r2drop.com/blog/cloudflare-r2-free-tier-guide)
[[R2 pricing 2]](https://leanopstech.com/blog/cloudflare-r2-pricing-2026/)):

| Dimension | R2 Standard rate (2026-06) | What drives it here |
|---|---|---|
| Storage | **$0.015 / GB-month** | total live (deduped, per-user) chunk bytes; GC/retention bounds it |
| Class A ops (writes/mutations) | **$4.50 / million** | each **PUT** of a *missing* chunk, `head_object` in `finalize verify:true`, `delete_object` in GC |
| Class B ops (reads) | **$0.36 / million** | each chunk **GET** (cold hydration) |
| **Egress** | **$0.00** | hydration bandwidth — **free** |
| Free tier | 10 GB storage + 1M Class A + 10M Class B / month | absorbs a small footprint outright |

**Why the op counts stay low (the dedup/FastCDC/retention bound):** we only PUT *missing*
chunks (`commit_begin` returns `put_urls` only for the missing set), so re-saving an
unchanged file is ~0 PUTs and a 1-byte edit re-uploads only the changed ~1 MB chunk, not
the file. At a ~1 MB average chunk a 100 MB file is ~100 PUTs **one-time** and ~100 GETs
per *cold* hydrate; warm reads hit the local SQLite-backed chunk cache and cost **nothing**.
The keep-versions policy adds chunks only for *changed* regions (a new version = a manifest
re-pointing mostly-shared chunks), and `RETENTION_POLICY=tiered` + nightly GC sweep prune
old-version refcount-0 chunks so storage tracks the *working set*, not cumulative history.

### Three maker profiles (assumptions stated)

| | **Light** | **Typical** | **Heavy** |
|---|---|---|---|
| Stored bytes, post-dedup | 5 GB | 30 GB | 150 GB |
| Files | ~2,000 | ~15,000 | ~80,000 |
| New/changed bytes per month | 0.5 GB | 4 GB | 25 GB |
| → new chunks PUT/mo (~1 MB avg) | ~500 | ~4,000 | ~25,000 |
| → finalize `head_object` (1/chunk, verify) | ~500 | ~4,000 | ~25,000 |
| Cold reads (hydrations) per month | 1 GB | 8 GB | 50 GB |
| → chunk GET/mo (~1 MB avg) | ~1,000 | ~8,000 | ~50,000 |
| Egress (free on R2) | 1 GB | 8 GB | 50 GB |

(Makers store large but *compressible-poorly* binaries — STL/3MF/STEP/CAD — that change in
bursts around a project, then go cold. Reads are dominated by re-opening recent project
files and new-device full hydrations, modeled as the "cold reads" row. Warm re-reads are
local-cache hits and cost nothing.)

### $/user/month (showing the math)

Storage = GB × $0.015. Class A = (PUTs + head_objects + a little GC) × $4.50/1e6.
Class B = GETs × $0.36/1e6.

| | **Light** | **Typical** | **Heavy** |
|---|---|---|---|
| **Storage** | 5 × 0.015 = **$0.075** | 30 × 0.015 = **$0.45** | 150 × 0.015 = **$2.25** |
| **Class A** (PUT+verify+GC) | ~1,100 × 4.5e-6 = **$0.005** | ~8,400 × 4.5e-6 = **$0.038** | ~52,000 × 4.5e-6 = **$0.234** |
| **Class B** (GET) | 1,000 × 3.6e-7 = **$0.0004** | 8,000 × 3.6e-7 = **$0.003** | 50,000 × 3.6e-7 = **$0.018** |
| **Egress** | $0.00 | $0.00 | $0.00 |
| **Total $/user/mo (gross, pre-free-tier)** | **~$0.08** | **~$0.49** | **~$2.50** |

**Storage dominates; ops are rounding error; egress is zero.** The variable cost per user
is **~$0.08 (Light) → ~$0.50 (Typical) → ~$2.50 (Heavy)** per month. The shared 10 GB +
1M/10M R2 free tier further offsets the first chunk of aggregate usage (it is account-wide,
not per-user, so it mostly helps at low total user counts).

### The zero-egress advantage, quantified

R2's free egress is the dominant structural win for a sync product, where read/hydration
bandwidth is the large, unpredictable cost on egress-billed stores. The **same cold-read
bytes** on S3-class egress (~$0.09/GB,
[[AWS egress via DO comparison]](https://docs.digitalocean.com/platform/billing/bandwidth/)):

| | Light (1 GB) | Typical (8 GB) | Heavy (50 GB) |
|---|---|---|---|
| R2 egress | $0.00 | $0.00 | $0.00 |
| S3-egress equivalent @ $0.09/GB | $0.09 | $0.72 | $4.50 |

For the Heavy profile, **S3 egress alone (~$4.50) would nearly triple the all-in per-user
cost** (~$2.50 → ~$7.00) — and egress is the *unbounded* term (a user re-syncing a new
laptop, or a project that gets re-opened repeatedly, scales reads without bound). On R2 that
term is pinned at $0. This is why R2 is the managed object-storage choice (`CLAUDE.md` §7).

---

## 2. FIXED costs (independent of user count, at small scale)

The always-on managed control plane. Bytes go direct to R2, so the compute host is small
and **not** bandwidth-billed for sync traffic.

| Component | Small-scale choice | $/month |
|---|---|---|
| **Kamal Rails host** (control plane only, 2–4 GB / 2 vCPU Docker VM) | Hetzner CX22 / DO 2GB tier | **~$5–14** (see §3) |
| **Database** | Self-managed Postgres in a container *on the same box* | **$0** (uses the host above) |
| — *or* managed Postgres | Neon Launch ($5 min) / Supabase Pro ($25) | **+$5–25** |
| **Domain + TLS** | domain ~$12/yr ≈ $1/mo; TLS via kamal-proxy/Let's Encrypt | **~$1** |
| **R2 base** | within free tier at small scale | **~$0** initially |
| **Backups/snapshots** | host snapshot add-on | **~$1–2** |

**Realistic fixed-cost floor for a small managed deployment: ~$7–15/month** (single small
VM running Rails + Postgres-in-a-container + Solid Queue/Cache/Cable, R2 in free tier, one
domain). That is the *all-in* floor before any per-user variable cost.

**What scales the fixed floor up:**
- **Managed Postgres** instead of on-box (TLS `sslmode`, a session/transaction-mode pooler
  for `next_seq! … FOR UPDATE`, per `docs/SYNC_SERVER.md`). Neon **Launch** is usage-based
  with a **$5/mo minimum**, $0.106/CU-hr compute, $0.35/GB-mo storage
  [[Neon pricing]](https://neon.com/pricing); Supabase **Pro** is **$25/mo** + compute
  [[Supabase pricing]](https://uibakery.io/blog/supabase-pricing). Below a few hundred
  users, **on-box Postgres in a container is the cheapest correct option** and keeps the
  floor at one VM.
- **Multiple Rails instances** (HA / throughput): the §G2 work moves Solid Queue/Cache/Cable
  onto the shared managed Postgres so you can run >1 stateless app instance
  (`docs/SYNC_SERVER.md`) — at that point you add VM(s) + a load balancer + managed PG, and
  the floor moves to the **$30–60/mo** range.
- **R2 once aggregate storage exceeds the 10 GB free tier** — but that is variable (§1), not
  fixed, and stays cheap (storage-dominated, egress free).

---

## 3. Cheapest Kamal HOSTING — ranked comparison (the actionable ask)

**Goal:** a cheap, **prod-like, remote** test box to run extensive latency/perf testing
against, then tear down. Requirements: runs Docker + Kamal; **2–4 GB RAM / 2 vCPU is
plenty** (control plane only — bytes go direct to R2); public IP + HTTPS; and — the key
point — a location that gives **realistic client↔server RTT** (NOT same-LAN as the dev box;
that realism is the whole reason for a second box, vs. the existing Unraid/SeaweedFS Kamal
setup which the user keeps for fast local dev).

All of these run Docker, so Kamal works. Kamal needs: SSH key access, a host in the `docker`
group, and either a registry (Docker Hub/GHCR or a local one as in `docs/DEPLOY.md`) — no
provider-specific blocker on any of them. Prices are 2026-06; **EUR↔USD ~1.08**.

| Rank | Provider / plan | Specs | $/mo | Incl. bandwidth | Overage | Regions (for realistic RTT) | Kamal/Docker notes |
|---|---|---|---|---|---|---|---|
| **1** | **Hetzner Cloud CX22** | 2 vCPU / 4 GB / 40 GB | **~$5–6** (€4.49–4.59 + small US surcharge) | **20 TB** | €1/TB | **US: Ashburn VA + Hillsboro OR**, + DE/FI/SG | Cleanest Docker host; US regions give real transcontinental RTT |
| **2** | **DigitalOcean Basic 2 GB** | 2 vCPU / 2 GB / 60 GB | **$18** (1 vCPU/2GB = $12) | 2 TB pooled | $0.01/GB | NYC/SFO/TOR/LON/AMS/FRA/BLR/SGP/SYD | Best DX/docs; pricier; many regions for RTT choice |
| **3** | **Vultr Cloud Compute (Regular)** | 1 vCPU / 2 GB / 55 GB | **~$10** | 2–3 TB | $0.01/GB | 30+ global incl. many US + intl | Lots of PoPs → pick a realistic-distance region |
| **4** | **Akamai/Linode 2 GB** | 1 vCPU / 2 GB / 50 GB | **$12** | included (generous) | $0.005/GB | 11+ global | Solid, stable pricing post-Akamai |
| **5** | **Scaleway DEV1-S** | 2 vCPU / 2 GB | **~$7** (€6.42) | **included, no egress fee** | — | FR (Paris), NL (Amsterdam), PL (Warsaw) | EU-only regions → good if testing from EU; far from US |
| **6** | **OVHcloud VPS** | ~2 vCPU / 2–4 GB | **~$5–6** (€5.49 start) | **unlimited traffic** | — | EU, CA (Beauharnois), US | Unlimited BW; CA/US regions; setup a bit more manual |
| **7** | **AWS Lightsail $7** | 2 vCPU / 1 GB / 40 GB | **$7** (only 1 GB RAM) | 2 TB | ~$0.09/GB | All AWS regions | 3 mo free for new accts; RAM low; AWS-region RTT realism |
| **8** | **Fly.io shared-cpu-1x 2 GB** | 1 shared vCPU / 2 GB | **~$5 VM + ~$2 IPv4** | metered | **$0.02/GB (NA/EU)** | global edge | **Free tier gone in 2026**; metered egress; Fly Machines model not a classic Kamal SSH host |
| — | **Oracle Cloud Free Tier (Ampere A1)** | up to 2 OCPU / 12 GB (was 4/24 pre-2026-06-15) | **$0** | **10 TB** | — | OCI regions incl. US | **$0 + 10 TB** is unbeatable, BUT: ARM64 (build arm images), reclaim-if-idle risk, capacity-constrained signups, free-tier halved 2026-06-15. Great as a *bonus* box, risky as the *primary* test box |

Sources: Hetzner [[pressroom new CX]](https://www.hetzner.com/pressroom/new-cx-plans/)
[[price adjustment]](https://docs.hetzner.com/general/infrastructure-and-availability/price-adjustment/)
[[CX22 review]](https://bestusavps.com/reviews/hetzner/);
DigitalOcean [[pricing]](https://www.digitalocean.com/pricing/droplets)
[[bandwidth]](https://docs.digitalocean.com/platform/billing/bandwidth/);
Vultr [[pricing]](https://onedollarvps.com/pricing/vultr-pricing);
Linode/Akamai [[pricing]](https://bestusavps.com/reviews/linode/);
Scaleway [[DEV1-S]](https://www.vpsbenchmarks.com/hosters/scaleway/plans/dev1-s)
[[instances pricing]](https://www.scaleway.com/en/pricing/virtual-instances/);
OVH [[pricing]](https://blog.ovhcloud.com/pricing-evolution-of-public-cloud-bare-metal-and-vps-at-ovhcloud/);
Lightsail [[pricing]](https://www.cloudzero.com/blog/amazon-lightsail-pricing/);
Fly.io [[pricing]](https://fly.io/docs/about/pricing/);
Oracle [[free tier]](https://www.oracle.com/cloud/free/)
[[2026 free-tier change]](https://cloudpricecheck.com/free-tier/oracle).

> **Hetzner pricing caveat:** Hetzner ran a large list-price adjustment (~+30%) on
> **2026-04-01** and a further adjustment effective **2026-06-15**; aggregator sites
> disagree on the exact post-adjustment CX22 figure (≈€4.49–€4.59/mo base + a per-hour US
> location surcharge). Treat ~$5–6/mo as the right order of magnitude and confirm the live
> price in the Hetzner console at order time. Even post-increase it remains the price/spec
> leader.

### Recommendation

**Top pick: Hetzner Cloud CX22, deployed in a US region (Ashburn VA or Hillsboro OR).**
- **~$5–6/mo for 2 vCPU / 4 GB / 40 GB + 20 TB traffic** — the best spec-per-dollar by a
  wide margin, and 4 GB RAM gives comfortable headroom for Rails + Postgres-in-a-container +
  Solid Queue/Cable on one box.
- **It satisfies the actual requirement — realistic RTT.** Hetzner now has **US locations**
  (Ashburn, Hillsboro), so from the user's dev machine you get genuine transcontinental
  WAN latency (tens of ms each way) to exercise the presign-RTT + R2-RTT legs the latency
  harness measures (`docs/r2-migration.md` §5) — exactly what the current LAN-bound Unraid
  box *cannot* show. Pick Ashburn for east-coast realism or Hillsboro for west-coast; pick a
  DE/FI region if you want to test a deliberately *far* client↔server path.
- **Trivial to spin up + tear down** (hourly billing, monthly cap), clean Ubuntu Docker
  host — drops straight into the `docs/DEPLOY.md` Kamal flow (swap `192.168.1.95` for the
  cloud host's IP/user; use GHCR or Docker Hub instead of the LAN-local registry).
- **20 TB included** means even if you do route some test bytes oddly, you won't hit egress
  surprises — though in normal operation sync bytes go to R2, not through this box.

**Runner-up: DigitalOcean Basic Droplet.** ~$12 (1 vCPU/2 GB) to $18 (2 vCPU/2 GB) — ~2–3×
Hetzner's price, but the **best developer experience, docs, and snapshot/teardown tooling**,
and the **widest region menu** (NYC/SFO/TOR/LON/FRA/BLR/SGP/SYD) for dialing in a specific
client↔server distance. Worth the premium if you value the polish or want to A/B several
geographic distances quickly. (Vultr at ~$10 is a cheaper near-equivalent with even more
PoPs if you want more region granularity than DO at a lower price.)

**Bonus, not primary: Oracle Cloud Free Tier (Ampere A1).** $0 for up to 2 OCPU / 12 GB +
10 TB egress is genuinely free and prod-capable, but it's **ARM64** (build arm64 images),
signups are capacity-constrained, idle instances can be reclaimed, and the free allotment
was *halved* on 2026-06-15. Excellent to keep as a free always-on secondary test endpoint
(e.g. a deliberately-distant region), but don't make your primary perf-test box depend on a
free tier that can disappear mid-test.

> The user is **keeping** SeaweedFS + the Unraid Kamal box for fast *local* dev/testing.
> This new box is **specifically** for prod-like *remote* testing, so realistic network
> distance is the deciding factor — which is why a US-region Hetzner CX22 (cheap **and**
> genuinely remote) wins over a marginally-closer or same-continent option.

---

## 4. SaaS pricing implications (sanity check)

Per-user **variable** cost (§1): Light ~$0.08, Typical ~$0.50, Heavy ~$2.50 per month.
Small **fixed** floor (§2): ~$7–15/mo at one VM.

**Gross margin at common price points (variable cost only):**

| Price point | vs Light ($0.08) | vs Typical ($0.50) | vs Heavy ($2.50) |
|---|---|---|---|
| **$5/mo** | ~98% | ~90% | ~50% |
| **$10/mo** | ~99% | ~95% | ~75% |

Even the **Heavy** maker is ~50% gross margin at $5/mo and ~75% at $10/mo; the typical user
is **90%+**. The zero-egress R2 model is what keeps the heavy tail profitable — on S3 egress
the Heavy user (~$7 all-in, §1) would be **negative margin at $5** and thin at $10.

**Break-even on the fixed floor:** at a ~$10/mo price with a ~$8 typical gross margin per
user, the **~$7–15/mo fixed floor is covered by ~1–2 paying users**. Even at $5/mo
(~$4.50 typical margin), **~2–3 users** cover the floor. The fixed cost is negligible; the
business is gated by acquisition, not infrastructure.

**Takeaway:** infrastructure is not the constraint. Storage-dominated, egress-free unit
economics give **90%+ gross margin on the typical user** and stay **positive even on heavy
users at $5/mo**, and the fixed control-plane floor is trivial (covered by a couple of
subscribers). Price on value/positioning, not on cost recovery.

---

### Sources

- Cloudflare R2 pricing 2026: <https://r2drop.com/blog/cloudflare-r2-free-tier-guide>,
  <https://leanopstech.com/blog/cloudflare-r2-pricing-2026/> (and `docs/r2-migration.md` §4)
- Hetzner Cloud: <https://www.hetzner.com/pressroom/new-cx-plans/>,
  <https://docs.hetzner.com/general/infrastructure-and-availability/price-adjustment/>,
  <https://bestusavps.com/reviews/hetzner/>, <https://costgoat.com/pricing/hetzner>
- DigitalOcean: <https://www.digitalocean.com/pricing/droplets>,
  <https://docs.digitalocean.com/platform/billing/bandwidth/>
- Vultr: <https://onedollarvps.com/pricing/vultr-pricing>
- Linode/Akamai: <https://bestusavps.com/reviews/linode/>
- Scaleway: <https://www.vpsbenchmarks.com/hosters/scaleway/plans/dev1-s>,
  <https://www.scaleway.com/en/pricing/virtual-instances/>
- OVHcloud: <https://blog.ovhcloud.com/pricing-evolution-of-public-cloud-bare-metal-and-vps-at-ovhcloud/>
- AWS Lightsail: <https://www.cloudzero.com/blog/amazon-lightsail-pricing/>
- Fly.io: <https://fly.io/docs/about/pricing/>
- Oracle Cloud Free Tier: <https://www.oracle.com/cloud/free/>,
  <https://cloudpricecheck.com/free-tier/oracle>
- Neon Postgres: <https://neon.com/pricing>
- Supabase: <https://uibakery.io/blog/supabase-pricing>
