# Deploy the sync server with Kamal (build on the Mac → ghcr → both boxes pull)

The image is built **once on the Mac** (the control machine) and pushed to **GitHub Container
Registry** (`ghcr.io/chaim354/tinkerex`). Both target servers pull that same amd64 image — no
Docker build, no repo checkout, and no source transfer to either server.

| | Unraid (home LAN) | OVH (prod-like test) |
|---|---|---|
| Host | `kamal1@192.168.1.95` | `ubuntu@15.204.216.249` |
| Kamal config | `config/deploy.yml` (default) | `+ config/deploy.ovh.yml` overlay (`-d ovh`) |
| Chunk storage | SeaweedFS `192.168.1.8:8333` | Cloudflare R2 |
| Deploy command | `kamal deploy` | `kamal deploy -d ovh` |

> **Why build on the Mac?** Both servers are amd64 and the Mac is arm64, so Kamal cross-builds
> amd64 via buildx (QEMU). Measured cold build is **~84 s** (incremental deploys hit the gem/apt
> layer cache and are much faster), so there's no need to build on a server or ship the repo to
> one. An earlier setup built on the VM (local `localhost:5000` registry) / on the OVH box
> (`builder: remote:`); both are retired — see "Migrating off the old on-box build" below.

> **Keep the build context lean.** The build context is the repo minus `.dockerignore`. We
> exclude `client/` (~15 GB Rust workspace), `.claude/` (~700 MB agent worktrees), `docs/`,
> `test/`, `ci/`, `scripts/`. With those out the context is ~tens of KB; leave them in and it
> balloons to **8 GB+** and every build crawls.

---

## 1. One-time prerequisites

### On the Mac (control machine)
- **Docker Desktop** (buildx, with QEMU for linux/amd64) — already set up.
- **Kamal** — `kamal version` (2.11+).
- **SSH key access** to both servers as the deploy user (`kamal1@…`, `ubuntu@…`). Test:
  `ssh kamal1@192.168.1.95 true && ssh ubuntu@15.204.216.249 true`.
- **Secrets — no exports needed.** `.kamal/secrets*` resolve them from 1Password via `bin/secret`.
  Check before deploying (this is the only reliable check — see below):
  ```sh
  bin/secrets-preflight          # base (chunk);  or: s3 | share | ovh | --all
  ```
  An exported shell value still WINS over 1Password, so a one-off deploy can point at a different
  credential without editing a tracked file:
  ```sh
  export CHUNK_SECRET_ACCESS_KEY=<some other secret>   # optional override
  ```

### On each server (one time)
The server only **runs** containers and **pulls** from ghcr — it needs no Ruby, no repo, no
local registry, no buildx.
```sh
# Docker (only hard requirement). After this, log out/in so the docker group applies.
curl -fsSL https://get.docker.com | sudo sh
sudo usermod -aG docker <kamal1|ubuntu>
# The box must reach ghcr.io to pull the private image; Kamal logs it in during deploy
# using KAMAL_REGISTRY_PASSWORD. Sanity: docker run hello-world  (no sudo).
```

## 2. Deploy

First deploy to a fresh box uses `setup` (boots kamal-proxy + the app, runs db:prepare); after
that, `deploy`.

```sh
cd /Users/charlesschwartz/Desktop/tinkerex   # the git tree must be committed/clean
bin/secrets-preflight --all                  # unlock 1Password if this reports EMPTY

# Unraid (SeaweedFS):
kamal setup            # first time on this box;  later: kamal deploy

# OVH (R2) — credentials come from .kamal/secrets.ovh, no export needed:
kamal setup -d ovh     # first time;  later: kamal deploy -d ovh
```

Kamal builds the amd64 image on the Mac **once per deploy**, pushes it to ghcr, then each target
pulls and boots it. (To push once and deploy to both without rebuilding: `kamal build push`
then `kamal deploy --skip-push` / `kamal deploy -d ovh --skip-push`.)

## 2b. How secrets resolve

Every credential goes through **`bin/secret VAR op://Vault/Item/field`**: an exported shell value
wins, otherwise it reads 1Password. One definition, used by `.kamal/secrets*` and both sidecar
builds.

**Which file feeds which destination.** Kamal reads exactly
`[.kamal/secrets-common, .kamal/secrets.<destination>]` — so **`.kamal/secrets` is NOT read when
`-d` is passed**; it is the *base* (chunk) destination's own file, not a shared one.

| destination | files read | credential |
|---|---|---|
| base (chunk, Unraid) | `secrets-common` + `secrets` | `CHUNK_SECRET_ACCESS_KEY` ← SeaweedFS `seaweednew` |
| `-d s3` | `secrets-common` + `secrets.s3` | `LIBRARY_S3_SECRET_ACCESS_KEY` ← same `seaweednew` |
| `-d share` | `secrets-common` + `secrets.share` | none — a share container holds no storage credential |
| `-d ovh` | `secrets-common` + `secrets.ovh` | `CHUNK_SECRET_ACCESS_KEY` ← **Cloudflare R2**, plus `CHUNK_ACCESS_KEY_ID` |

`CHUNK_SECRET_ACCESS_KEY` names a **different credential** on Unraid than on OVH. That is the
whole reason these are per-destination files: `secrets-common` cannot tell the two apart, and
whichever one it hardcoded would be pushed to the other box.

**Only truly-common keys may go in `secrets-common`, and that is correctness, not tidiness.**
Kamal expands secrets with `::Dotenv.parse`, and `InlineCommandSubstitution` runs every `$(…)` in
a parsed file **eagerly** — not lazily per key. `secrets-common` is read by every destination, so
a credential parked there makes `kamal deploy -d share` shell out for something a share container
never holds. `test/deploy_hygiene_test.rb` enforces this.

### ⚠️ Always preflight — kamal cannot notice an unreadable secret

Kamal expands `$(…)` through Ruby **backticks, which discard exit status**. A locked vault makes
`bin/secret` exit 1, the substitution yields `""`, and `Kamal::Secrets#[]` hands that empty string
to the deploy **without raising** (a *missing* key raises; an *empty* one does not). An empty
`KAMAL_REGISTRY_PASSWORD` then surfaces as a confusing `docker login` failure.

```sh
bin/secrets-preflight --all
```

It resolves every key the merged deploy config declares, through the real `Kamal::Secrets`, and
fails loudly on anything empty. It prints names and byte lengths only, never values.

Two things it catches that nothing else does:

- **A worktree has no `config/master.key`** (gitignored + untracked), so `RAILS_MASTER_KEY`
  resolves empty, the container boots to `Missing secret_key_base`, the health check fails and
  kamal keeps the old container. Fix: `cp <main-checkout>/config/master.key config/master.key`.
- **`op whoami` is not a readiness check.** The desktop integration authorizes *per read*, so
  `op whoami` reports "account is not signed in" on a perfectly usable vault. Only an `op read`
  exit code means anything.

### Unattended runs (CI, cron, background agents)

`op read` uses **`OP_SERVICE_ACCOUNT_TOKEN`** when it is in the env and falls back to
desktop-app/biometric auth when it is not — **same command, no second code path**, so nothing in
`.kamal/secrets*` changes. A service account is what you want anywhere there is no unlocked
desktop app to approve a read: the desktop integration re-locks on its own timeout, and a hung
authorization looks like `error initializing client: authorization timeout`.

**The vault split is already done.** Every reference is `op://tinkerex/…`, a vault holding only
this project's items (`ghcr.io`, `seaweednew`, `R2`, `OVHcloud`, `tinkerex-origin`). Two reasons it
is not `Personal`:

- **A service account CANNOT be granted access to a Personal or Private vault** — 1Password's own
  CLI refuses it (`op service-account create --help`). Leaving the items in `Personal` makes the
  unattended path impossible, not merely untidy.
- Anything that can run `op` on this machine — including a coding agent — can read every item in
  whatever vault the references point at. A project vault bounds that to four items.

Service accounts **are** available on a personal (Individual/Families) plan; only the *Private
vault* restriction applies. The published rate limits list "1Password and 1Password Families" as
its own tier at 1,000 reads/day, which is far above what deploys use (a full
`bin/secrets-preflight --all` costs ~8 reads).

To mint one (yours to do — the token is a bearer credential and is never committed):

```sh
op service-account create tinkerex-deploy --vault tinkerex:read_items --expires-in 90d
```

The token prints **once** and is never retrievable again — save it to 1Password immediately. Then
give it to the runner as a secret env var and verify:

```sh
OP_SERVICE_ACCOUNT_TOKEN=… bin/secrets-preflight --all   # prints which auth path it used
```

⚠️ **Do not `export` it into your interactive shell.** A bare `export OP_SERVICE_ACCOUNT_TOKEN=ops_…`
writes the credential to `~/.zsh_history` in plaintext. Use `read -rs OP_SERVICE_ACCOUNT_TOKEN &&
export OP_SERVICE_ACCOUNT_TOKEN`, or scope it to the single command as above.

**There is no CI consumer today.** All six workflows in `.github/workflows/` reference zero
GitHub secrets (`grep -c '${{ secrets\.'` → 0 in each): the test gates run on SQLite with stub
env, and `cross-os-e2e.yml` uses a fixed test account. So a service account is currently only
worth minting for unattended *deploys* — wire it into CI when a job first needs a real credential.

## 3. Verify

```sh
curl -s -o /dev/null -w '%{http_code}\n' http://192.168.1.95/up    # Unraid → 200
curl -s -o /dev/null -w '%{http_code}\n' http://15.204.216.249/up  # OVH → 200
kamal app logs -f            # add -d ovh for the OVH box
```

## 4. Point clients at it

From a client on the same network (reaches the Rails box and the chunk store):
```sh
(cd client/sync-client && SERVER_URL=http://192.168.1.95 cargo run --example e2e)
(cd client/sync-engine && SERVER_URL=http://192.168.1.95 cargo run --example presigned_roundtrip)
```
…or in the Tauri app, set **Sync server URL** and Mount.

---

## Migrating off the old on-box build

The Unraid box was originally set up to build *on the VM* and serve from a local
`127.0.0.1:5000` registry (an earlier version of this doc). The OVH box used
`builder: remote: ssh://ubuntu@…` (build on the box). Both are retired in favor of the
build-on-Mac → ghcr flow above. After the **first `kamal deploy` from the Mac** cuts a box over
to pulling from ghcr, the old build apparatus on that box is dead weight and can be removed:

```sh
# Unraid — AFTER `kamal deploy` has cut it over to ghcr (verify the running container's image
# is ghcr.io/chaim354/tinkerex:…, NOT 127.0.0.1:5000/…, before removing anything):
ssh kamal1@192.168.1.95 '
  docker ps --format "{{.Names}} {{.Image}}"        # confirm ghcr image is live first
  docker rm -f registry                              # the local registry container
  docker buildx rm kamal-local                       # the on-box buildkit builder (if present)
  rm -rf ~/tinkerex ~/kamalw ~/registry-auth ~/*.log # the repo checkout + wrapper + logs
'
# OVH — the repo was an unused leftover (the app already pulls ghcr); removed during this migration.
```

Do **not** remove the `tinkerex_storage` Docker volume — it holds the SQLite databases (incl.
Solid Cable for the nudge) and survives redeploys.

---

## Notes & gotchas

- **No sudo for Kamal.** After `usermod -aG docker`, Kamal drives Docker without sudo on the
  servers; `sudo` is only for the one-time Docker install.
- **Bytes never flow through Rails.** The server only signs presigned URLs (local HMAC); each
  client PUT/GETs `CHUNK_ENDPOINT` directly, so that host must be reachable from every client.
- **3D viewer & bucket CORS (s3 / chunk-over-S3 backends).** The in-browser 3D viewer
  (`modelviewer_controller.js`) `fetch`es a model's raw bytes from `/files/:id/blob`. On the
  **s3** library backend — and for small single-chunk files on a **chunk** backend whose store is
  S3/SeaweedFS — that endpoint 302-redirects to a cross-origin presigned URL, which the browser
  only reads if the bucket returns CORS headers for the app origin. Rails can't set these (bytes
  bypass Rails by design — §15). Add a bucket CORS rule allowing `GET` from the app origin, e.g.:

  ```json
  [{ "AllowedOrigins": ["https://<app-host>"], "AllowedMethods": ["GET"],
     "AllowedHeaders": ["*"], "MaxAgeSeconds": 3600 }]
  ```

  (SeaweedFS: the bucket CORS API / `s3.configure`; R2/S3: the bucket's CORS config.) Without it,
  affected files **degrade to the static thumbnail** — nothing breaks. The **share** backend and
  multi-chunk files on the **chunk** backend are same-origin and need no CORS.
- **TLS is opt-in per host via `FORCE_SSL` (2026-07-30).** Set it to any non-empty value on a host
  reachable **from the internet**. It turns on `assume_ssl` (trust the terminating proxy's
  `X-Forwarded-Proto`), `force_ssl` (http→https redirect, HSTS, and — the one that matters —
  **the `Secure` flag on the session cookie**), plus an exclusion so kamal-proxy's plain-HTTP
  `/up` health check still passes (without it the check fails and the deploy rolls back).

  **Leave `FORCE_SSL` unset on the Unraid backends.** They are reached by IP over plain HTTP on
  the LAN; with it set they would redirect every request to a URL nothing serves. That asymmetry
  is why this is an env gate rather than a line in `production.rb` — before this, neither setting
  was enabled anywhere, so the internet-facing host had no HSTS and its session cookie was sent
  on plain-HTTP requests to the same host.

  The ActionCable nudge is unaffected either way: it works because request-forgery protection is
  disabled (token-authed cable, not cookies).
- **Control-plane-only smoke test:** set `STORAGE_BACKEND: memory` (drop the `CHUNK_*`) to test
  tree/changelog/nudge without a chunk store.
- **Persistence:** the SQLite DBs live on the `tinkerex_storage` volume and survive redeploys —
  `kamal app exec 'bin/rails db:version'` to inspect.
</content>
</invoke>

## Box Generator sidecar (addon framework, Plan B)

The Box Generator addon is backed by a **separate, GPL-3.0 Python container** (`sidecar/boxes`,
the forked `boxes.py`). It is internal-only (never published) and the Rails app talks to it over
the kamal network via `BOXES_SIDECAR_URL` (declared in `config/deploy*.yml`). Build/push + boot:

```sh
bin/build-boxes-sidecar        # the ghcr token comes from 1Password via bin/secret
bin/kamal accessory boot boxes        # first time; later: bin/kamal accessory reboot boxes
```

Then redeploy the app leg(s) so they pick up `BOXES_SIDECAR_URL`. Verify from an app container:
`curl -s http://tinkerex-boxes:8000/up` → `ok`. The addon then shows as available at `/tools`.
