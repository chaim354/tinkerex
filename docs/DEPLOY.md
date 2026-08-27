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

### Active Record encryption keys (config/credentials.yml.enc)

Arc C's per-user sync-server device token (`users`, Task 4) is the first column in this app to use
`encrypts`. The three keys it needs — `primary_key`, `deterministic_key`, `key_derivation_salt` —
were generated once with `bin/rails db:encryption:init` and live inside
`config/credentials.yml.enc` under `active_record_encryption:`, alongside `secret_key_base`.
`config/initializers/active_record_encryption.rb` has the argument for pairing them with
`support_unencrypted_data: false` from day one.

**No new deploy plumbing — say this plainly rather than implying otherwise.** These keys reach
every deployment exactly the way `secret_key_base` always has: `RAILS_MASTER_KEY` decrypts
`config/credentials.yml.enc` at boot, and `RAILS_MASTER_KEY` is *already* resolved for all four
destinations from one line — `.kamal/secrets-common`'s `RAILS_MASTER_KEY=$(cat
config/master.key)`, read by base, s3, share and ovh alike (§2b). Confirmed live on 2026-08-24,
not assumed:

```
$ bin/secrets-preflight --all
base   ok  RAILS_MASTER_KEY (32 bytes)
s3     ok  RAILS_MASTER_KEY (32 bytes)
share  ok  RAILS_MASTER_KEY (32 bytes)
ovh    ok  RAILS_MASTER_KEY (32 bytes)
```

Same 32 bytes, same file, all four — because every destination reads the *same* local
`config/master.key` fresh at deploy time rather than a per-destination copy. The encryption keys
therefore ship the moment `config/credentials.yml.enc` is committed and any of the four is next
deployed; there is nothing destination-specific to configure, and nothing to add to
`.kamal/secrets*`.

**If `RAILS_MASTER_KEY` is ever rotated, every already-encrypted column becomes unreadable —
unless the rotation carries the plaintext credentials forward.** The three encryption keys live
*inside* the file `RAILS_MASTER_KEY` decrypts; they are not derived from `RAILS_MASTER_KEY`
itself. So rotating the master key is safe for encrypted data **only if** the rotation is
decrypt-with-old → re-encrypt-with-new (the `active_record_encryption:` block carried over
byte-for-byte), never regenerate-`config/credentials.yml.enc`-from-scratch. Verified, not assumed:
a `RAILS_MASTER_KEY` that is present but simply *wrong* (doesn't match the ciphertext) doesn't
degrade gracefully — it raises `ActiveSupport::MessageEncryptor::InvalidMessage` uncaught, out of
Devise's own `secret_key_base`-reading initializer, and takes the boot down. That's a different
failure than the *empty*-key case a few sections up (`Missing secret_key_base`, from a worktree
with no `config/master.key`) — both crash-loop and fail kamal-proxy's health check, so kamal keeps
the old container either way, but the error text an operator sees differs.

Before rotating:

1. Decrypt the current `config/credentials.yml.enc` with the *current* `config/master.key` and
   hold that plaintext briefly — never committed, never logged, same handling as the keys
   themselves get (this doc's own instructions never print a key value, and neither should you).
2. Generate the new master key.
3. Re-encrypt the *same* plaintext under the new key (`active_record_encryption:` unchanged;
   rotate `secret_key_base` too if that's also the goal).
4. Commit the newly-encrypted `config/credentials.yml.enc` and replace `config/master.key` locally
   — **together, in one change**, before redeploying anything. Each `kamal deploy` builds a fresh
   image from the current commit (baking in whatever `config/credentials.yml.enc` that commit
   has) and separately resolves `RAILS_MASTER_KEY` from the *local* `config/master.key` at that
   same moment — so shipping one half of the pair without the other to any destination reproduces
   the crash above on that box.
5. Only discard the old master key once every destination has redeployed from the new pair and
   passed its health check.

**Losing `config/master.key` outright — not rotating it, losing it, with no backup** — is
unrecoverable rather than merely inconvenient: the three encryption keys exist nowhere else, were
never derived from anything else, and nothing in object storage or the database can reconstruct
them. Every encrypted column becomes permanently unreadable, the same single-point-of-failure that
already exists for `secret_key_base` (losing it today invalidates every session) — this just
extends that existing risk to cover encrypted columns too, rather than introducing a new one.

Rotating the encryption keys *themselves* — as opposed to the outer master key protecting the file
they live in, e.g. after a suspected compromise of `primary_key` — is a different and harder
operation (`config.active_record.encryption.previous`, re-encrypting every existing row with the
new key before the old one can be retired). Out of scope here; nothing in this repo does it yet.

## 3. Verify

```sh
curl -s -o /dev/null -w '%{http_code}\n' http://192.168.1.95/up    # Unraid → 200
curl -s -o /dev/null -w '%{http_code}\n' http://15.204.216.249/up  # OVH → 200
kamal app logs -f            # add -d ovh for the OVH box
```

### The `.git` purge migration — automatic, but know it exists

`PurgeRepoMetadataNodes` (`db/migrate/20260826120000_*`) removes library nodes already indexed
BENEATH a `.git` directory, keeping the `.git` marker itself. It runs as part of `db:migrate`,
which kamal does **before** it boots the new containers — that ordering is the whole point, not a
detail: the same deploy stops the observers descending into `.git`, so without the purge the first
`Library::ScanJob` tick afterwards sees every one of those nodes vanish at once. Its output names
what it did:

    -- destroyed 4812 node(s) indexed beneath a .git directory
       -> KEPT 9f2c… (user 3) — a file attachment points at it

A `KEPT` line is a node the purge REFUSED to destroy because something points at it — a file
attachment, or a project's or model's cover image. Destroying one would silently orphan that
reference. Nothing is required of you, but those files are inside a repo's `.git` and the next scan
will tombstone them normally — worth a look if the project cares.

**On a `chunk_remote` deployment it declines, and says so:**

    -- declined: FileLayer::ChunkRemote is not a scannable backend, so nothing here indexed the
       contents of a .git and nothing scans them away

That is correct, not a misconfiguration. There the `nodes` table MIRRORS the sync server's tree,
the mass-deletion guard never runs (`Library::ScanJob` gates on the same capability), and
`app/models/node.rb` records that `.git`'s contents are HIDDEN there rather than removed.

**The one failure mode.** If a library was scanned by the new code before the migration ran, that
scan REFUSES with `Library::Scanner::UnsafeScan` — a mass-deletion guard trip, so **nothing was
deleted**; the library simply stops scanning. The message reads:

    scan would tombstone 20/21 observable files (95.2% > 20%). Refusing — is the share mounted?
    Set LIBRARY_SCAN_MAX_DELETE_PCT to override.

It asks about the mount because that is the usual cause, and after this deploy it is the wrong
diagnosis. Fix:

    kamal app exec --reuse "bin/rails runner 'Library::RepoMetadataPurge.call'"

then let the next scheduled scan run. The service is idempotent, so a re-run is free. **Do NOT
reach for `LIBRARY_SCAN_MAX_DELETE_PCT`** — raising it would let that scan tombstone the nodes
instead of removing them, which leaves a revivable row per file and disarms the guard for whatever
goes wrong next.

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

**A nightly runs on the box at 03:30 America/New_York**, backing up all four databases — the three
maker deployments *and* the `sync` accessory's own — to the Unraid array, keeping 14 each. Day to
day you only need:

```sh
bin/backup-status                                # schedule, last run, inventory, staleness
```

```sh
bin/backup-cron-install                          # install/refresh the nightly (idempotent)
bin/backup-cron-install --uninstall              # remove just the crontab entry
bin/backup-db share                              # ad-hoc, pulled down to this Mac
bin/restore-db share box:latest --into rehearsal # rehearse the newest nightly; live untouched
bin/restore-db share box:latest                  # the real thing (prompts; backs up first)
bin/restore-db share box:latest --no-pre-backup  # ...when the state you'd back up is the problem
```

**That 03:30 America/New_York is ASSERTED, not assumed.** A crontab time is a *local* time, so the
claim only holds if the VM's clock agrees — and a stock Ubuntu server is `Etc/UTC`, which would fire
the same line at 23:30 Eastern with nothing looking wrong. `bin/backup-cron-install` now reads the
box's zone back and **refuses to install on a mismatch**, before it touches anything; `bin/backup-status`
re-reads it on every run, so a zone changed *after* install cannot go on quietly contradicting this
page. `BACKUP_TZ=<zone>` is how you accept a different one deliberately (update this section to match
if you do). Deliberately **not** `CRON_TZ=`: a cron that does not implement it — busybox, and it is
not required by POSIX — parses that line as an ordinary environment assignment and ignores it, which
is a guard that silently does nothing.

`share` is `bin/backup-db`'s default; `chunk` and `s3` take the same arguments. Everything talks to
the *volumes*, not through the app, so **a backup needs no deploy and no downtime** —
`bin/restore-db` is the only one that stops anything, and only for the seconds it takes to swap the
files in.

**Before changing any of these five scripts, read CLAUDE.md §14i** — the CROSS-FILE things not to
undo, each with the consequence named. The single-site rules are not there and are not weaker for it:
they live in a comment on the very line you would have to edit, and in this section. `bin/ci` runs
none of this code, so nothing in the suite goes red for any of it — prove a change against stubs,
never the live NAS or a real volume.

**`ops/backup-db.sh` IS THE ONLY IMPLEMENTATION; the rest are callers.** It runs on the VM (the
nightly invokes it from cron, `bin/backup-db` pushes the current copy up and calls it with
`--to-stdout`). Two copies of this would eventually be two copies with different bugs — that is
this repo's recorded failure shape, not a hypothetical. Change `ops/backup-db.sh` and re-run
`bin/backup-cron-install` to push it.

**`bin/backup-cron-install` IS THE ONLY THING THAT WRITES `~/tinkerex-ops/backup-db.sh`.** An ad-hoc
`bin/backup-db` pushes to a **per-run temp path** and deletes it afterwards. It used to `scp` straight
onto the installed copy, which meant every ad-hoc run — including the pre-restore one fired from
inside `bin/restore-db`, in the middle of an incident — silently replaced the implementation cron
would execute that night with whatever happened to be in that person's checkout. Two unsynchronised
writers to one remote file is not "one implementation, two callers"; it is a way for an unrelated
command to change the nightly. One source file in git, one installer, one installed copy.

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

**AND THE NIGHTLY NOW CHECKS THAT FOR ITSELF, because the warning above is only as good as whoever
read it.** `ops/backup-db.sh --to-volume` inspects the volume first and **refuses to run** unless it
has a device option — i.e. is a driver-opt volume rather than a local directory — pinging
`status=down` so the monitor goes red instead of green. Note a missing volume is not an error to
Docker: `docker run -v tinkerex_backups:/dst` **creates** it, so the job would have written ~44 MB a
night to the VM's own disk, verified its own archives there quite happily, and reported success,
while `bin/backup-status` read the same recreated name and called it healthy. `bin/backup-cron-install`
has always compared the exact path, but that check runs while a human is watching and this one runs
at 03:30 for months. The division is deliberate: the installer knows `BACKUP_NAS`/`BACKUP_SUBDIR` and
insists on the exact device; the nightly is handed only a volume name and asks the weaker, sufficient
question. Do not thread the path through the crontab line to make it exact — a bare `%` in a cron
command is a newline, and this box has a share whose name contains a space.

**If the installer refuses because the volume points somewhere unexpected, deleting it is the wrong
move** — and it is the move most likely to be aimed at the *right* volume, because the commonest way
to reach that branch is a run whose `BACKUP_NAS`/`BACKUP_SUBDIR` are wrong rather than a genuinely
stray volume. Inspect it (`docker volume inspect`, and `ls` it through a container), then either
re-run with those two set to compose the path it already points at, or — if you really are moving to
a different share — re-run with `BACKUP_VOLUME=<new-name>` to build the new one alongside, and
retire the old only once a nightly has been seen writing into it. Every other step the installer
takes is undone by re-running it; that one is not.

**Retention prunes only after a verified write, and only files it named.** `--keep N` keeps the N
newest *per deployment*; a failed run skips pruning entirely, because the one thing worse than a
missing backup is a good one aged out by a broken run. Verified by planting foreign files
(`notes.txt`, another deployment's archive, an unrelated tarball) and confirming a `--keep 1` run
pruned its own destination to one and touched nothing else.

**`--keep` (and so `BACKUP_KEEP`) must be an integer ≥ 1; anything else is refused before the run
starts.** There is no value meaning "keep everything". `0` and negatives both select *every* archive
including the one just written, and a non-number silently prunes nothing for ever — and since the
prune runs *after* the success ping, either would be a monitor reporting green over the loss. Note
this deliberately **diverges from `LIBRARY_TRASH_DAYS`, where `0` means "keep forever"**
(CLAUDE.md §14a): that is a duration, where the generous reading is safe, and this is a count, where
`0` reads as "keep zero" and the only honest response to a typo is to refuse it.

**`bin/backup-status` fails loud on staleness** rather than printing a date — but it only speaks
when asked, which is what the push monitors below are for.

### Monitoring — Uptime Kuma push monitors

**RUN UPTIME KUMA ON THE UNRAID HOST, NOT THE KAMAL VM.** A monitor sharing a host with the thing
it monitors cannot report the failures that matter most — VM off, Docker wedged — because it is off
too, and its silence is indistinguishable from everything being fine. It is the same argument that
put the archives on the array instead of `/dev/vda2`, applied one level up.

Install from Community Apps (default port 3001), then add **one Push monitor per backed-up
database** — `tinkerex backup (chunk)`, `(share)`, `(s3)`, **`(sync)`**. Heartbeat Interval
**90000** (25 h, so the 03:30 run has an hour of slack), Retries **0**. Copy each push URL, then:

```sh
PING_CHUNK=http://192.168.1.146:3001/api/push/aB1 \
PING_SHARE=http://192.168.1.146:3001/api/push/cD2 \
PING_S3=http://192.168.1.146:3001/api/push/eF3 \
PING_SYNC=http://192.168.1.146:3001/api/push/gH4 \
  bin/backup-cron-install
```

**`(sync)` IS FOURTH AND WAS UNPINGABLE UNTIL 2026-08-26.** `ops/backup-db.sh` reads `ping.env`
through an enumerated whitelist and had arms for only the first three, so a `PING_SYNC` written
into that file was never read: the monitor could not be pinged in either direction. If you created
that monitor before this fix it has been sitting **DOWN** every night over a backup that succeeded
— that stuck-red state *is* the symptom, and it clears on the first nightly after the installer is
re-run. If you never created it, `bin/backup-cron-install` has been printing `!! NO HEARTBEAT for:
sync` on every run; create it now.

**A PUSH MONITOR IS A DEAD-MAN'S SWITCH — it alerts on the ABSENCE of a ping.** That is the whole
reason to prefer it over anything the job reports about itself: cron unloaded, the VM powered off,
the script killed before reaching its own error handler. None of those can send a message, and all
of them stop the heartbeat.

Four behaviours are deliberate, and each was mutation-checked by breaking the thing it guards:

- **A failing run sends `status=down` immediately** rather than waiting out the 25-hour window. A
  backup that runs and fails is knowable in seconds; making you wait a day discards the one case
  the job *can* report on itself. The vanished-container arm and the wrong-output-volume refusal
  both ping too — **but only under `--to-volume`**, see the bullet below.
- **A failed ping NEVER fails the backup.** The backup is the product, the ping is telemetry about
  it. Letting curl's exit status through would turn "Uptime Kuma is rebooting" into "last night's
  backup failed" — and, since a nonzero exit skips the prune, into a slow disk leak as well.
- **An ad-hoc `bin/backup-db` does NOT ping, in EITHER direction.** A manual backup to someone's
  laptop is not the nightly; if an ad-hoc `up` touched the heartbeat, a nightly dead for a week would
  read healthy for exactly as long as someone kept rescuing it by hand. The mirror image was a real
  bug: the vanished-container arm sits *above* the `--to-stdout` branch, so it pinged unconditionally
  and an ad-hoc run against a missing container marked the **nightly's** monitor `down` — including
  the pre-restore backup inside `bin/restore-db`, i.e. exactly when someone is already dealing with
  an incident. Both directions corrupt the same signal. A `--to-stdout` failure is still reported,
  by exit status, to the person who is standing right there.
- **`bin/backup-cron-install` MERGES `ping.env`, it does not overwrite it.** That installer is what
  you re-run to push a script change, so a merge that dropped unmentioned keys would silently
  unwire every monitor the next time anyone fixed a typo — and they would sit green until their
  windows lapsed. Tokens live only on the box (`~/tinkerex-ops/ping.env`, chmod 600), never in git.

**Two traps live in the URL Uptime Kuma hands you, which is `…/api/push/TOKEN?status=up&msg=OK&ping=`
— the natural thing to do is paste it verbatim, and both were real bugs before they were guards.**

- **`ping.env` is PARSED, NEVER SOURCED.** That URL contains `&`, so `. ping.env` on an unquoted
  line makes bash read it as a **job separator**: the assignment runs in a background subshell, the
  variable is never set in this shell, and the ping silently does not happen. Sourcing also makes
  every value in that file executable shell. `ops/backup-db.sh` reads it with an explicit
  four-key whitelist, which takes values literally and can do neither. **The price is that the
  whitelist is enumerated: a new destination needs a new arm by hand, or its pings vanish
  silently** — that is exactly how `(sync)` went unpingable.
- **`ping_kuma` STRIPS ANY QUERY STRING** (`url="${url%%\?*}"`). Left on, `curl --get` appends a
  **second** `status`, Express/qs parses the duplicate into an **array**, and Kuma's
  `req.query.status === "down"` compares against an array and is false — so **every failure is
  recorded as UP**. The monitor stays green exactly when it must not, which is worse than having no
  monitor. Mutation-checked by configuring the verbatim UI URL, forcing a failure, and asserting
  the request carried exactly one `status=down`.

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

### The archives are unencrypted on a guest-writable share — a decision, not an oversight

Recording this because it was nowhere written down, and an unstated trade-off is indistinguishable
from one nobody noticed. **Accepted for a home LAN; revisit before this box is reachable from
anywhere else, and before `plan-encryption.md` lands** (CLAUDE.md §12.2 — at-rest chunk encryption is
deliberately last, and this is the same question one layer up).

The volume is mounted `guest,…,file_mode=0664,dir_mode=0775` against a share with guest access, so
**anyone on the LAN can read and delete 14 nights of every deployment's full production database**.
What that exposes, precisely:

- **Every user's `encrypted_password`** — bcrypt, so not readable, but offline-crackable at leisure
  once the file is copied. A weak password does not survive that; a strong one does.
- **`devices.token_digest` and `share_links.token_digest`** — SHA-256 of 256-bit random tokens. Not
  meaningfully crackable, and not usable as-is (the API compares against the digest of a presented
  token, so possessing the digest is not possessing the token).
- **The catalog itself, in the clear** — email addresses, sign-in IPs, every project, model and file
  name — plus **every preview blob**, which are thumbnails of the user's actual designs. This, not
  the digests, is the part with no cryptographic protection at all.
- **Deletion.** `dir_mode=0775` on a guest share means the archives can be removed by anyone who can
  reach it. A backup that a stranger can delete is not much of a backup, and nothing would report it
  until `bin/backup-status` went stale 30 hours later.

Not fixed here because every fix has a cost that wants deciding rather than assuming: an SMB user
with a real credential means a secret on the VM and in `bin/backup-cron-install`'s volume options;
`age`/`gpg` encryption of the tarball means a key that must itself survive the disaster the backup is
for, and a restore path that fails closed if it does not. Neither belongs in a review-follow-up commit.

**REHEARSE THE RESTORE BEFORE YOU NEED IT.** `--into <suffix>` restores into `<volume>-<suffix>` and
reads it back with the deployment's own image **as the user that image runs as**, so extraction, the
file ownership the `chown` just set, and SQLite's own view of the restored database are exercised
against real bytes while the live container keeps serving. Verified this way on share, from both
sources: four databases restored `rails:rails`, 1326 blob files, 1872 nodes readable. Drop the
scratch volume afterwards with `docker volume rm <volume>-<suffix>`.

**What the rehearsal does NOT do is boot the app, and this page used to say it did** while the check
ran as `--user 0` — root, which can read a file whatever its mode, so the root version could not fail
for the one reason a rehearsal exists. A bare `docker run` of the image has none of the environment
Kamal supplies: no `RAILS_MASTER_KEY` (boot dies on `secret_key_base`) and no `LIBRARY_BACKEND`/
`LIBRARY_PATH`, which `LibraryBackendCheck` refuses to start without (CLAUDE.md §14a). A "boot" here
would fail for reasons that have nothing to do with the archive. Running as the app's own user is
the strongest check available without reconstructing the deployment's whole environment, and unlike
the old one it can actually go red.

**`--no-pre-backup` exists because the safety net could block the emergency it is there for.**
`bin/restore-db` backs up the current state first, which is right — restoring the wrong archive is an
ordinary mistake and making it unrecoverable is a choice. But the commonest reasons to be restoring at
all (a corrupt database, a container that will not start) are exactly the reasons `bin/backup-db`
fails, and under `set -e` that aborted the restore with backup-db's own error and no hint that the
restore had been abandoned or that continuing was possible. **The default is unchanged** — a failed
pre-backup is still fatal — what is new is that the refusal names the way past itself.

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

Do **not** remove the `tinkerex_storage` Docker volume — it holds the SQLite databases and
survives redeploys.

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

## Which build is a sidecar accessory running?

Both sidecar build scripts bake the source commit into the image as an OCI label, so a **running**
accessory can name its own build — no registry access, no tag enumeration. Ask the container:

```sh
ssh unraid 'docker inspect tinkerex-openscad \
  --format "{{index .Config.Labels \"org.opencontainers.image.revision\"}}"'
```

(Same for `tinkerex-boxes`.) A `-dirty` suffix means the sidecar directory had uncommitted **or
untracked** changes at build time, so the commit named is not the whole story — a dirty build is
unauditable by construction, and the suffix says so rather than pretending otherwise. Two dirty
builds at one commit are indistinguishable, in the tag AND in the label; do not "fix" that by making
the tag unique, which would imply a dirty build is reproducible.

**An EMPTY line means no label, not an empty one.** An image built before this landed carries
`Config.Labels == {}`, and `docker inspect` prints a blank line and exits 0 — so a blank answer means
"rebuild this sidecar", not "the build is unknown". `docker ps` and
`kamal accessory details` cannot answer this — they print the run reference, `:latest`, and the
registry has no digest→tag reverse lookup, so the tags say only which builds exist.
