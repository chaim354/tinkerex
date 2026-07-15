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
- Secrets in your shell before any deploy (sourced via `.kamal/secrets*`, never committed):
  ```sh
  export KAMAL_REGISTRY_PASSWORD=<ghcr PAT: write:packages to push, read:packages to pull>
  export CHUNK_SECRET_ACCESS_KEY=<SeaweedFS secret (Unraid) | R2 secret (OVH)>
  # OVH only — R2 Access Key ID (the secret stays in CHUNK_SECRET_ACCESS_KEY):
  export CHUNK_ACCESS_KEY_ID=<R2 token Access Key ID>
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
export KAMAL_REGISTRY_PASSWORD=... CHUNK_SECRET_ACCESS_KEY=...

# Unraid (SeaweedFS):
kamal setup            # first time on this box;  later: kamal deploy

# OVH (R2) — also export CHUNK_ACCESS_KEY_ID first:
kamal setup -d ovh     # first time;  later: kamal deploy -d ovh
```

Kamal builds the amd64 image on the Mac **once per deploy**, pushes it to ghcr, then each target
pulls and boots it. (To push once and deploy to both without rebuilding: `kamal build push`
then `kamal deploy --skip-push` / `kamal deploy -d ovh --skip-push`.)

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
- **HTTP, no TLS** on these LAN/test boxes (`assume_ssl`/`force_ssl` off). The ActionCable nudge
  works because request-forgery protection is disabled (token-authed cable, not cookies).
- **Control-plane-only smoke test:** set `STORAGE_BACKEND: memory` (drop the `CHUNK_*`) to test
  tree/changelog/nudge without a chunk store.
- **Persistence:** the SQLite DBs live on the `tinkerex_storage` volume and survive redeploys —
  `kamal app exec 'bin/rails db:version'` to inspect.
</content>
</invoke>
