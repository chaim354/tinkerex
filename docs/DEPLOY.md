# Deploy the sync server with Kamal (Unraid VM, all-on-the-box)

Target: the Ubuntu 26.04 VM at **`kamal1@192.168.1.95`**. We run Kamal *on the VM* and
push to a local registry on the same box — no cloud account, no Docker on your Mac.
Chunk storage is **SeaweedFS** (`192.168.1.7:8333`), so clients move real bytes.

`config/deploy.yml` is already set for this (server `192.168.1.95`, user `kamal1`,
registry `localhost:5000`, `STORAGE_BACKEND=s3` + `CHUNK_*`). The SeaweedFS secret is
read from your shell (`CHUNK_SECRET_ACCESS_KEY`) so it never lands in git.

> **Why you run these, not me:** the VM has no Docker/Ruby/Git yet and `sudo` needs a
> password (no passwordless sudo), so the privileged setup + `kamal setup` must be run
> by you. I can rsync the repo over for you (non-privileged) — just ask.

---

## 1. One-time host setup (on the VM, as `kamal1`)

```sh
ssh kamal1@192.168.1.95

# Docker (only hard requirement). After this, log out/in so the group applies.
curl -fsSL https://get.docker.com | sudo sh
sudo usermod -aG docker kamal1
exit
```
```sh
ssh kamal1@192.168.1.95    # back in, in the docker group
docker run hello-world     # sanity: docker works without sudo

# Run Kamal via its official image — no Ruby needed on the host. Save this wrapper:
cat > ~/kamalw <<'WRAP'
#!/bin/bash
exec docker run --rm \
  -v "$HOME/tinkerex:/workdir" -w /workdir \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -v "$HOME/.ssh:/root/.ssh" \
  -e CHUNK_SECRET_ACCESS_KEY="${CHUNK_SECRET_ACCESS_KEY:-secret}" \
  -e KAMAL_REGISTRY_PASSWORD="${KAMAL_REGISTRY_PASSWORD:-kamalpass}" \
  ghcr.io/basecamp/kamal:latest "$@"
WRAP
chmod +x ~/kamalw && ~/kamalw version

# Local registry on 127.0.0.1:5000 WITH htpasswd auth (see the registry note in
# config/deploy.yml for why 127.0.0.1 + auth, not bare localhost):
mkdir -p ~/registry-auth
docker run --rm --entrypoint htpasswd httpd:2 -Bbn kamal kamalpass > ~/registry-auth/htpasswd
docker run -d -p 127.0.0.1:5000:5000 --restart always --name registry \
  -v ~/registry-auth:/auth -e REGISTRY_AUTH=htpasswd \
  -e REGISTRY_AUTH_HTPASSWD_REALM=Registry \
  -e REGISTRY_AUTH_HTPASSWD_PATH=/auth/htpasswd registry:2

# Kamal SSHes to the "server" (192.168.1.95) — the same box — so kamal1 needs key auth
# to itself:
[ -f ~/.ssh/id_ed25519 ] || ssh-keygen -t ed25519 -N "" -f ~/.ssh/id_ed25519
cat ~/.ssh/id_ed25519.pub >> ~/.ssh/authorized_keys
ssh -o StrictHostKeyChecking=accept-new kamal1@192.168.1.95 true   # prime known_hosts
```

## 2. Get the code onto the VM

From your **Mac** (the repo includes `config/master.key`, which is *not* in git, so
copy the working tree rather than `git clone`; `target/` and `node_modules` are skipped):

```sh
rsync -az --exclude 'target' --exclude 'node_modules' --exclude '.DS_Store' \
  --exclude '.claude' --exclude 'app/.kamal' --exclude 'app/config' \
  /Users/charlesschwartz/Desktop/tinkerex/ kamal1@192.168.1.95:~/tinkerex/
```
(`.git` is included so Kamal can tag the image by revision; the tree must be committed/
clean. `app/.kamal` + `app/config` are stray scaffold and are excluded.)

## 3. Deploy (on the VM)

```sh
cd ~/tinkerex
export CHUNK_SECRET_ACCESS_KEY=secret KAMAL_REGISTRY_PASSWORD=kamalpass

~/kamalw setup   # first run: builds (host dockerd, driver: docker), pushes to
                 # 127.0.0.1:5000, boots kamal-proxy + the app on :80, runs db:prepare
                 # (the 4 SQLite DBs incl. Solid Cable for the nudge). Later: `~/kamalw deploy`.
```

## 4. Verify

```sh
curl -s -o /dev/null -w '%{http_code}\n' http://192.168.1.95/up   # → 200
kamal app logs -f                                                 # watch boot/requests
```

## 5. Point clients at it

From your **Mac** (same LAN, reaches both the server and SeaweedFS):

```sh
# cross-stack demos against the deployed server
(cd client/sync-client && SERVER_URL=http://192.168.1.95 cargo run --example e2e)
(cd client/sync-client && SERVER_URL=http://192.168.1.95 cargo run --example nudge)
(cd client/sync-engine && SERVER_URL=http://192.168.1.95 cargo run --example presigned_roundtrip)
```
…or in the Tauri app, set **Sync server URL** to `http://192.168.1.95`, then Mount.

A full two-device test: device A (Mac mount) writes a file → it pushes to the VM →
SeaweedFS gets the chunk → device B (second mount, same email) gets the nudge and
hydrates the bytes.

---

## Notes & gotchas

- **No sudo for Kamal itself.** After `usermod -aG docker kamal1`, Kamal drives Docker
  without sudo. `sudo` is only for the apt installs and the Docker install script.
- **Updating the deployment:** rsync the tree again (step 2), then `kamal deploy`.
- **SeaweedFS reach:** the *server* only signs URLs (local HMAC) — it never contacts
  SeaweedFS. Each *client* PUT/GETs `CHUNK_ENDPOINT` directly, so that host must be
  reachable from every client device (your Mac is).
- **Control-plane-only smoke test:** set `STORAGE_BACKEND: memory` in `deploy.yml`
  (drop the `CHUNK_*`) to test tree/changelog/nudge without SeaweedFS.
- **HTTP, no TLS:** `assume_ssl`/`force_ssl` are off (LAN test); the nudge works because
  ActionCable request-forgery protection is disabled (token-authed cable, not cookies).
- **Persistence:** the 4 SQLite DBs live on the `tinkerex_storage` volume and survive
  redeploys. `kamal app exec 'bin/rails db:version'` to inspect.
