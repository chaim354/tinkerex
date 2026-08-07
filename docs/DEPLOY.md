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

## 5. Test accounts on the Unraid box

**THIS SECTION IS THE ONE PLACE THESE ARE RECORDED.** A credential that lives only in a session
transcript is gone the moment that session ends — which is exactly how the account below got lost
once already, sending the next reader to a two-month-old handoff doc naming an account that no
longer worked.

| backend | container name prefix | account | password |
|---|---|---|---|
| chunk | `tinkerex-web-<sha>` | `demo@tinkerex.local` | `MakerDemo2026!` |
| share | `tinkerex-web-share-<sha>` | `demo@tinkerex.local` | `MakerDemo2026!` |
| s3 | `tinkerex-web-s3-<sha>` | `demo@tinkerex.local` | `MakerDemo2026!` |

**THE THREE ROWS BEING IDENTICAL IS A CONVENTION, NOT A MECHANISM** — they are three separate
accounts in three separate databases that happen to have been given the same address and password.
Nothing keeps them in sync: a password reset on one leaves the other two alone, and a future account
added to one backend only is an ordinary state, not a bug. Keep the table per-row for that reason
even while the rows agree; collapsing it to a single line is how the next reader concludes that
fixing one fixed all three.

**A PASSWORD IS IN GIT HERE ON PURPOSE, AND THE REASON IS LOAD-BEARING.** This box is a
non-production test/dev deploy (despite `RAILS_ENV=production`), its `ENABLE_TEST_SIGNUP` seam is
deliberately open, and it is reachable only on the LAN and the tailnet. **Never record a managed-SaaS
or internet-facing credential here** — those resolve through 1Password per §2b and must not acquire
a second, plaintext home. If this box ever stops being a throwaway, this table moves to 1Password
with it.

**EACH BACKEND HAS ITS OWN SQLite VOLUME** (`tinkerex_storage`, `tinkerex_storage_share`,
`tinkerex_storage_s3`) — so each has its **own `users` table**. That is the mechanism behind the
paragraph above: an account created on one does not exist on the others. A login that works on share
and fails on chunk is this, not a broken deploy.

List what actually exists, rather than trusting the table. This walks all three and labels each,
which is also how you learn the running SHA:

```sh
ssh kamal1@192.168.1.95 'for c in $(docker ps --format "{{.Names}}" | grep "^tinkerex-web"); do
  echo "=== $c"
  docker exec "$c" bin/rails runner "puts User.pluck(:email)"
done'
```

**`docker ps -f name=…` MATCHES ON SUBSTRING, NOT EXACTLY** — so `name=tinkerex-web` returns **all
three** container ids, and the obvious `docker exec $(docker ps -qf name=tinkerex-web) …` then feeds
docker a second id where it expects the command. Iterating over names, as above, sidesteps it. If you
do want one backend at a time, anchor the pattern — and note that `[0-9a-f]` is what isolates chunk,
because both `share` and `s3` begin with a letter that is not hex:

```sh
ssh kamal1@192.168.1.95 'docker exec $(docker ps -qf name="^tinkerex-web-[0-9a-f]")  bin/rails runner "puts User.pluck(:email)"'   # chunk
ssh kamal1@192.168.1.95 'docker exec $(docker ps -qf name="^tinkerex-web-share-")    bin/rails runner "puts User.pluck(:email)"'   # share
ssh kamal1@192.168.1.95 'docker exec $(docker ps -qf name="^tinkerex-web-s3-")       bin/rails runner "puts User.pluck(:email)"'   # s3
```

Create one (the seam is open on all three; it creates a **confirmed** account, no email
verification — `app/controllers/v1/test_users_controller.rb`):

```sh
curl -X POST http://share.tinkerex.home/v1/test/users \
  -H 'Content-Type: application/json' \
  -d '{"email":"demo@tinkerex.local","password":"MakerDemo2026!"}'
```

Reset a forgotten one, keeping its library, attachments and BOM links:

```sh
ssh kamal1@192.168.1.95 'docker exec -i $(docker ps -qf name=tinkerex-web-share) bin/rails runner -' <<'RUBY'
u = User.find_by(email: "demo@tinkerex.local")
abort "no such user" unless u
u.update!(password: "MakerDemo2026!", confirmed_at: u.confirmed_at || Time.current)
puts "#{u.email} updated"
RUBY
```

Three things about that snippet are deliberate. **`confirmed_at` is set only when currently null** —
an account predating confirmation otherwise resets fine and still bounces to the confirmation page,
which reads as a wrong password. **It aborts on nil** instead of raising `NoMethodError` on a
mistyped address. And **the heredoc is quoted (`<<'RUBY'`)**, which is not styling: interactive
**zsh performs history expansion on `!` inside DOUBLE quotes**, so the obvious one-liner dies on
`MakerDemo2026!` — and on `update!` — with `zsh: event not found`. Single quotes suppress it;
`%q(...)` in Ruby avoids nesting quotes at all if you want a one-liner.

---

## 6. Backup & restore

**A nightly runs on the box at 03:30 America/New_York**, backing up all three deployments to the
Unraid array and keeping 14 per deployment. Day to day you only need:

```sh
bin/backup-status                                # schedule, last run, inventory, staleness
```

```sh
bin/backup-cron-install                          # install/refresh the nightly (idempotent)
bin/backup-cron-install --uninstall              # remove just the crontab entry
bin/backup-db share                              # ad-hoc, pulled down to this Mac
bin/restore-db share box:latest --into rehearsal # rehearse the newest nightly; live untouched
bin/restore-db share box:latest                  # the real thing (prompts; backs up first)
```

`share` is `bin/backup-db`'s default; `chunk` and `s3` take the same arguments. Everything talks to
the *volumes*, not through the app, so **a backup needs no deploy and no downtime** —
`bin/restore-db` is the only one that stops anything, and only for the seconds it takes to swap the
files in.

**`ops/backup-db.sh` IS THE ONLY IMPLEMENTATION; the rest are callers.** It runs on the VM (the
nightly invokes it from cron, `bin/backup-db` scp's the current copy up and calls it with
`--to-stdout`). Two copies of this would eventually be two copies with different bugs — that is
this repo's recorded failure shape, not a hypothetical. Change `ops/backup-db.sh` and re-run
`bin/backup-cron-install` to push it.

**Where the archives live:** `//192.168.1.146/backups/tinkerex-backups`, mounted into the helper
container as the Docker CIFS volume `tinkerex_backups` — the same driverless mechanism
`deploy.share.yml` uses for the library, so no host `sudo mount`, no fstab, no cifs-utils. Note
`appdata` is **read-only to guest** and cannot be used; the `backups` share was created for this.
The VM's own disk was rejected deliberately: it is 31 GB with 12 GB free and it is the *same*
virtual disk the live databases sit on, so it would protect against a bad migration and not against
losing the VM. **A backup that shares a failure domain with its source is half a backup.**

**DO NOT `docker volume rm tinkerex_backups`.** Kamal only ensures a volume EXISTS; if this one were
removed, the next reference would recreate it as a **plain empty local volume on the VM** — the
nightly would go on reporting success while writing into the very disk this arrangement avoids, and
the real archives on the array would simply stop being visible. Same warning, same reason, as the
library volume's.

**Retention prunes only after a verified write, and only files it named.** `--keep N` keeps the N
newest *per deployment*; a failed run skips pruning entirely, because the one thing worse than a
missing backup is a good one aged out by a broken run. Verified by planting foreign files
(`notes.txt`, another deployment's archive, an unrelated tarball) and confirming a `--keep 1` run
pruned its own destination to one and touched nothing else.

**`bin/backup-status` fails loud on staleness** rather than printing a date — but it only speaks
when asked, which is what the push monitors below are for.

### Monitoring — Uptime Kuma push monitors

**RUN UPTIME KUMA ON THE UNRAID HOST, NOT THE KAMAL VM.** A monitor sharing a host with the thing
it monitors cannot report the failures that matter most — VM off, Docker wedged — because it is off
too, and its silence is indistinguishable from everything being fine. It is the same argument that
put the archives on the array instead of `/dev/vda2`, applied one level up.

Install from Community Apps (default port 3001), then add **one Push monitor per deployment** —
`tinkerex backup (chunk)`, `(share)`, `(s3)`. Heartbeat Interval **90000** (25 h, so the 03:30 run
has an hour of slack), Retries **0**. Copy each push URL, then:

```sh
PING_CHUNK=http://192.168.1.146:3001/api/push/aB1 \
PING_SHARE=http://192.168.1.146:3001/api/push/cD2 \
PING_S3=http://192.168.1.146:3001/api/push/eF3 \
  bin/backup-cron-install
```

**A PUSH MONITOR IS A DEAD-MAN'S SWITCH — it alerts on the ABSENCE of a ping.** That is the whole
reason to prefer it over anything the job reports about itself: cron unloaded, the VM powered off,
the script killed before reaching its own error handler. None of those can send a message, and all
of them stop the heartbeat.

Four behaviours are deliberate, and each was mutation-checked by breaking the thing it guards:

- **A failing run sends `status=down` immediately** rather than waiting out the 25-hour window. A
  backup that runs and fails is knowable in seconds; making you wait a day discards the one case
  the job *can* report on itself. The vanished-container arm pings too.
- **A failed ping NEVER fails the backup.** The backup is the product, the ping is telemetry about
  it. Letting curl's exit status through would turn "Uptime Kuma is rebooting" into "last night's
  backup failed" — and, since a nonzero exit skips the prune, into a slow disk leak as well.
- **An ad-hoc `bin/backup-db` does NOT ping.** A manual backup to someone's laptop is not the
  nightly; if it touched the heartbeat, a nightly dead for a week would read healthy for exactly as
  long as someone kept rescuing it by hand.
- **`bin/backup-cron-install` MERGES `ping.env`, it does not overwrite it.** That installer is what
  you re-run to push a script change, so a merge that dropped unmentioned keys would silently
  unwire every monitor the next time anyone fixed a typo — and they would sit green until their
  windows lapsed. Tokens live only on the box (`~/tinkerex-ops/ping.env`, chmod 600), never in git.

**`docker cp`, `cp` and a raw volume tarball ALL PRODUCE A TORN DATABASE HERE.** These run in WAL
mode (`PRAGMA journal_mode` → `wal`), so committed state is split between `production.sqlite3` and
its `-wal` sidecar, and Puma + Solid Queue are writing throughout. A non-atomic copy of the pair
still **opens** and mostly answers queries — the corruption surfaces later, on one row, with nothing
to tie it back. `bin/backup-db` drives `sqlite3 .backup` (SQLite's online-backup API, defined
against concurrent writers) instead, which is the entire reason the script exists rather than a
one-line `scp`.

**THE ARCHIVE CARRIES THE ACTIVE STORAGE BLOBS TOO, AND THAT IS NOT PADDING.**
`config.active_storage.service = :local`, so every preview asset sits on the *same* volume under
`/rails/storage/<xx>/<yy>/`. They are **not** rebuildable from a restored database:
`Maker::Previews::MissingBackfill` skips any node that already HAS a preview row, so a DB-only
restore leaves every row at `ready` pointing at a file that no longer exists — blank thumbnails
across every surface, no error, no job, nothing to notice. Share's archive is ~34 MB for 1872 nodes
and 1326 blobs; there is nothing to be gained by splitting them.

Not in the archive, and not missing: the **library bytes**. On share they live on the NAS
(`//192.168.1.146/3D Printing`) and on chunk in SeaweedFS. What this backs up is the **catalog** —
nodes, projects, models, attachments, tags, print log, users — which is the part that only exists
here.

**REHEARSE THE RESTORE BEFORE YOU NEED IT.** `--into <suffix>` restores into `<volume>-<suffix>` and
reads it back with the deployment's own image, so extraction, file ownership and the app's own view
of the data are all exercised against real bytes while the live container keeps serving. Verified
this way on share, from both sources: four databases restored `rails:rails`, 1326 blob files, 1872
nodes readable. Drop the scratch volume afterwards with `docker volume rm <volume>-<suffix>`.

**`box:` restores in place, without a round trip.** A nightly archive lives inside a CIFS volume, so
it is not a path on the VM's filesystem at all — fetching 34 MB down to the Mac only to push the
same 34 MB back would be the obvious and wrong way to use one. `box:latest` resolves to the newest
archive for that deployment; `box:<filename>` names one from `bin/backup-status`.

**Three of these scripts got bitten by the same thing: `ssh` flattens its arguments into one command
string that the remote shell re-splits.** An empty trailing argument vanishes into whitespace (so
`$4` is unset and `set -u` kills the script on line 2); a share name containing a space —
`//host/3D Printing`, which this box has — arrives as two arguments; and `"-v vol:/backups:ro"`
passed as one argument becomes two, shifting every positional after it. Pass space-free values, use
`${4:-}` for optionals, and `printf %q` anything that could contain a space.

Both scripts verify rather than assume — `PRAGMA integrity_check` on every snapshot **in the
container before the transfer is paid for**, then again locally on what actually landed; and
`bin/restore-db` checks the archive **before** it stops anything, because taking a deployment down
and only then discovering the tarball is short is the one failure that ordering removes. It also
runs `bin/backup-db` first, since restoring the wrong archive is an ordinary mistake and making it
unrecoverable is a choice.

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
