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

# system deps: Docker, Ruby (for the kamal gem), git, curl
sudo apt update
sudo apt install -y curl git ruby-full build-essential
curl -fsSL https://get.docker.com | sudo sh
sudo usermod -aG docker kamal1
exit                       # log out/in so the docker group takes effect
```
```sh
ssh kamal1@192.168.1.95    # back in, now in the docker group
docker run hello-world     # sanity: docker works without sudo

sudo gem install kamal -v '~> 2.11'
kamal version

# local image registry (localhost ⇒ Docker treats it as insecure-OK automatically)
docker run -d -p 5000:5000 --restart always --name registry registry:2

# Kamal SSHes to the "server" (192.168.1.95) — even though that's this same box — so
# kamal1 needs key auth to itself:
[ -f ~/.ssh/id_ed25519 ] || ssh-keygen -t ed25519 -N "" -f ~/.ssh/id_ed25519
cat ~/.ssh/id_ed25519.pub >> ~/.ssh/authorized_keys
ssh -o StrictHostKeyChecking=accept-new kamal1@192.168.1.95 true   # prime known_hosts
```

## 2. Get the code onto the VM

From your **Mac** (the repo includes `config/master.key`, which is *not* in git, so
copy the working tree rather than `git clone`; `target/` and `node_modules` are skipped):

```sh
rsync -az --exclude '**/target' --exclude '**/node_modules' \
  /Users/charlesschwartz/Desktop/tinkerex/ kamal1@192.168.1.95:~/tinkerex/
```
(`.git` is included so Kamal can tag the image by revision; the tree is committed/clean.)

## 3. Deploy (on the VM)

```sh
cd ~/tinkerex
export CHUNK_SECRET_ACCESS_KEY=secret      # the SeaweedFS secret key

kamal setup     # first run: builds the image, pushes to localhost:5000, boots
                # kamal-proxy + the app on :80, runs db:prepare (migrates the 4 SQLite
                # DBs incl. Solid Cable for the nudge). Later deploys: `kamal deploy`.
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
