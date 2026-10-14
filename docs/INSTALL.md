# Installing Tinkerex

A self-hosted library for a maker's files, run with Docker Compose on your own machine. This page
is the whole of what a new install needs: the quick start, the optional pieces, and — in section 8
— **the reference for every environment variable the app reads**. That table is guarded by
`test/install_docs_test.rb`, which fails the build when the code reads a variable this page does
not name, so it is current by construction rather than by promise.

The first path here is the **`share` backend**: you point the app at a folder of files, it
indexes them, and that folder stays yours — plain files on disk, editable with anything else. The
sync server (section 5) is the second path. Pointing the app at your own S3 bucket is a third,
described at the end of section 2.

## 1. What you need

- **Docker Engine with the Compose plugin**, v2.24 or newer (`docker compose version`). The
  chunk_remote overlay uses Compose's `!override` tag, which arrived in 2.24.
- **A Linux box, amd64.** arm64 also works, with two gaps: F3D ships no Linux arm64 build, so
  STEP, IGES, OBJ and the other mesh formats get a generic icon instead of a thumbnail (everything
  else — STL, SVG, DXF, LightBurn, PDF, images, Gerber — renders); and the OpenSCAD tool's image is
  x86_64-only (an AppImage), so that one addon is unavailable there.
- **A folder of files**, or an empty folder to start with. The first build downloads a few hundred
  megabytes of renderers and compiles two small Rust tools; allow several minutes.
- Nothing else: no Ruby, no database server, no mail server on day one. SQLite is the database and
  lives in a Docker volume.

## 2. Quick start (the share backend)

```sh
git clone https://github.com/chaim354/tinkerex.git
cd tinkerex
cp .env.example .env
```

Open `.env` and set the three lines at the top:

1. **`SECRET_KEY_BASE`** — `openssl rand -hex 64`. It signs sessions; keep it, because changing it
   signs everyone out.
2. **`LIBRARY_HOST_PATH`** — the folder that holds (or will hold) your files, on this machine.
   The container runs as **user id 1000** and must be able to write there (uploads land in it,
   deleted files move to its `.trash/`). If uid 1000 is your own account — it is the first
   ordinary user on most Linux systems; `id -u` tells you — there is nothing to do. Otherwise:
   `sudo chown -R 1000:1000 /path/to/files`, or grant that uid write access another way (a group,
   an ACL). A folder that is not writable refuses the boot with a message that says so; it is not
   indexed read-only.
3. **`APP_HOST`** — the host name or address people will type to reach this server, without a
   scheme: `maker.example.net`, or `192.168.1.20`. It is what links in email point at.

Then:

```sh
docker compose up -d --build
docker compose logs -f web      # until Puma reports it is listening; Ctrl-C leaves it running
```

Open `http://<that host>:8080` (`TINKEREX_PORT` in `.env` changes the port). `curl
http://localhost:8080/up` answers `200` once the app is ready; the compose healthcheck polls the
same path.

**If the container exits**, `docker compose logs web` has the reason, and it is almost always one
sentence naming a setting: a missing `.env` (`env file … not found` — you skipped the `cp`), a
library folder that is not writable by uid 1000, or a blank `SECRET_KEY_BASE`. The app refuses to
boot on a misconfiguration rather than starting and failing later.

### First run: the first account is the owner

With no account yet, the sign-up page works and says so: *"This is the server's first account. It
becomes the owner and needs no email confirmation."* Create it; you are signed in. **After that,
sign-ups are closed** — the page answers "Sign-ups are closed" and the link disappears — until you
either open them (`REGISTRATION`, section 4) or add accounts from the console (also section 4).
No mail server is involved in any of this.

### Where your files come from

- **The folder is indexed** on start, every 15 minutes after that, and whenever you press
  **Rescan library** on the Files page. Anything you put in the folder by other means — a copy
  over the network, a slicer saving into it — appears on the next scan.
- **Uploads in the browser land in the folder** as ordinary files, so the folder remains the
  truth and the app a view of it.
- **Deleting in the app moves the file to `.trash/`** inside the folder (keyed by an id, so two
  deletes of the same name never collide), and empties entries older than `LIBRARY_TRASH_DAYS`
  (30 days) once a day. Restore is on the Trash page.
- **Folders under `Projects/` become projects**: a folder dropped directly under `Projects/` is
  discovered on the next sweep (every 15 minutes) and gets a project page with its files attached;
  loose files at a project folder's root are filed into category sub-folders.
- **Thumbnails** are rendered in the background after a scan; a large library takes a while to
  fill in. They live in the `tinkerex_storage` volume, not in your folder.
- A rename on disk keeps the file's identity (its attachments, tags and project links) as long as
  the content is unchanged; a scan that would remove more than `LIBRARY_SCAN_MAX_DELETE_PCT` (20%)
  of the library at once is refused and logged, because that is what an unmounted share looks like.

### Your own S3 bucket instead of a folder

The `s3` backend indexes an S3-compatible bucket (SeaweedFS, MinIO, R2, AWS) the same way: the
object is the truth, no versions, current state only. There is no template for it; the recipe is a
small overlay, because `docker-compose.yml` fixes `LIBRARY_BACKEND` and the `/library` mount for the
share path. Save this as `docker-compose.s3.yml`, put the five `LIBRARY_S3_*` values in `.env`, and
start with `-f docker-compose.yml -f docker-compose.s3.yml`:

```yaml
services:
  web:
    environment:
      LIBRARY_BACKEND: s3
      LIBRARY_PATH: ""
    volumes: !override
      - tinkerex_storage:/rails/storage
```

`LIBRARY_S3_BUCKET`, `LIBRARY_S3_ACCESS_KEY_ID` and `LIBRARY_S3_SECRET_ACCESS_KEY` are required;
`LIBRARY_S3_ENDPOINT` for anything that is not AWS; `LIBRARY_S3_PREFIX` to use one folder of the
bucket. The boot checks that they are present and nothing more — a wrong credential surfaces on
first use, never as a crash loop.

## 3. The Tools gallery (optional)

Tools are add-ons that run inside the app and save their output into your library — a box
generator and an OpenSCAD editor are the two that exist. They need three more containers: two
sidecars built from this repo's `sidecar/` directory (GPL-licensed, which is why they are separate
processes talked to over HTTP and never linked into the app), and a tiny static server for the addon
bundles, built from a sibling checkout.

```sh
git clone https://github.com/chaim354/tinkerex-addons.git ../tinkerex-addons
```

In `.env`, uncomment the three lines under "The Tools gallery" — `BOXES_SIDECAR_URL`,
`OPENSCAD_SIDECAR_URL` and `ADDON_SOURCE_URL` — then:

```sh
docker compose --profile tools up -d --build
```

Without the profile the gallery page is empty and says why. On arm64, where the OpenSCAD image
cannot be built, start the other two by name: `docker compose --profile tools up -d --build web boxes
addons`; the OpenSCAD tool then shows as unavailable and the box generator works. To make the profile
stick so that plain `docker compose up -d` includes it, put `COMPOSE_PROFILES=tools` in `.env`.

## 4. Mail and more accounts

**Mail.** The app sends two kinds of message: account confirmation and password reset. Nothing is
sent until `SMTP_ADDRESS` is set; with it unset the boot log says so once, and the sign-up page tells
a visitor that the server cannot send email yet. `SMTP_PORT` (587), `SMTP_USER_NAME` and
`SMTP_PASSWORD` (authentication is used only when a user name is given), `SMTP_AUTHENTICATION`
(`plain`), `SMTP_DOMAIN` (the HELO name, default `APP_HOST`) and `SMTP_STARTTLS` (on unless set to
`false`) are the rest. `MAIL_FROM` is the sender address, default `no-reply@<APP_HOST>`.

**Who may sign up.** `REGISTRATION` is `closed` by default in production: the first account is the
owner and nobody else gets the page. **`REGISTRATION=open` is refused at boot on the share and s3
backends**, on purpose: every account on those backends indexes the *same* folder or bucket, so an
open sign-up would hand any visitor your files. Open sign-ups are for the sync server (section 5),
where each account has its own library.

**Adding an account without mail.** Two console tasks create or reset an account, confirmed on the
spot. The password is read from `TINKEREX_PASSWORD`, never from the command line, so that it stays
out of your shell history and out of `ps`; the `read -rs` below prompts for it without echo:

```sh
read -rs TINKEREX_PASSWORD && export TINKEREX_PASSWORD
docker compose exec -e TINKEREX_PASSWORD web bin/rails 'tinkerex:owner[someone@example.net]'
docker compose exec -e TINKEREX_PASSWORD web bin/rails 'tinkerex:password[someone@example.net]'
unset TINKEREX_PASSWORD
```

The first refuses an address that already exists and a password under 10 characters; the second
resets the password and confirms the account if it was not.

**Single sign-on** through an OpenID Connect provider is its own door: `OMNIAUTH_ENABLED` plus the
four `OIDC_*` values in the table. A provider login creates a confirmed account whatever
`REGISTRATION` says — the provider decides who may sign in.

## 5. The sync server (chunk_remote)

The `share` backend is one folder, one library, current state only. The **sync server** is what
gives each account its own library, keeps every version of every file, makes trash restore and
history possible, and is what the desktop client (`chaim354/tinkerex-client`) syncs against. On
this backend the app is itself a client of the sync server: it reads file metadata from a local
mirror and sends writes over HTTP. Your files then live inside the sync server's volume as
content-addressed chunks, not as plain files on disk.

It is a compose overlay that adds a `sync` service, built from a sibling checkout of
`chaim354/tinkerex-sync` (its `Dockerfile.rust`, a single static binary):

```sh
git clone https://github.com/chaim354/tinkerex-sync.git ../tinkerex-sync
```

In `.env`, fill in the block under "The sync server":

- `SYNC_SECRET_KEY_BASE` — `openssl rand -hex 64`. The sync server's own session secret; it signs
  the URLs chunks are fetched from.
- `SYNC_ADMIN_TOKEN` — `openssl rand -hex 32`. **The same value reaches both services**: the app
  uses it to create a library on the sync server for each new account, and the sync server checks it
  against its own copy.
- `SYNC_PUBLIC_URL` — the address your other devices reach the sync server at, scheme included:
  `http://<this host>:3001` (the published port below), or the name a reverse proxy in front of it
  answers to. The desktop app is handed it when it signs in. The app itself keeps using
  `http://sync:3000`, a name only the compose network resolves, so the two are never the same.
- `ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY`, `ACTIVE_RECORD_ENCRYPTION_DETERMINISTIC_KEY` and
  `ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT` — `openssl rand -hex 16` each (any string of 32 or
  more characters works). They encrypt each account's sync credential in the database. **Keep them
  with your backups**: losing them makes every stored sync credential unreadable, and there is
  nothing to derive them from.

Then start with both files:

```sh
docker compose -f docker-compose.yml -f docker-compose.chunk_remote.yml up -d --build
```

(or put `COMPOSE_FILE=docker-compose.yml:docker-compose.chunk_remote.yml` in `.env` and keep typing
plain `docker compose`). The overlay switches the app to `LIBRARY_BACKEND=chunk_remote`, drops the
`/library` mount, points it at `http://sync:3000` on the compose network, and publishes the sync
server on port **3001** (`TINKEREX_SYNC_PORT`) — that published port is what devices and the desktop
client connect to, so it has to be reachable from them, and `SYNC_PUBLIC_URL` has to name it as they
see it. The sync server runs with its scheduler on (`SYNC_SCHEDULER: "true"` in the overlay): expired
pending commits are reaped hourly, orphaned chunk bytes weekly, and retention keeps every version —
nothing you uploaded is ever pruned. `REGISTRATION=open` is allowed here.

The sync server keeps its database and every chunk in the `tinkerex_sync_storage` volume; it has
its own small set of variables, listed at the end of the table in section 8.

## 6. Updating

```sh
git pull
docker compose up -d --build        # with the same -f overlay or --profile as before,
                                    # or set COMPOSE_FILE / COMPOSE_PROFILES in .env once
```

The database migrates itself when the container starts (the entrypoint runs `db:prepare` before
Puma). `.env` is not tracked by git, so `git pull` never touches it; `.env.example` is, and a new
release may add lines to it — `diff .env.example .env` after an update shows anything new to
consider. A library scan runs on start, so a file that changed on disk while the app was down is
picked up.

## 7. Backups

Everything the app keeps is in two places:

- **The `tinkerex_storage` volume**, mounted at `/rails/storage` in the `web` container: four
  SQLite files (`production.sqlite3` is the one that matters; the cache, queue and cable files are
  disposable) and the thumbnails. Compose names the volume `<project>_tinkerex_storage`;
  `docker volume ls` shows it.
- **Your library folder** (share) — or, on chunk_remote, the **`tinkerex_sync_storage`** volume at
  `/rails/host/storage` in the `sync` container, which holds the sync server's database and every
  chunk.

SQLite runs in WAL mode, so **never `docker cp` or `tar` a live `production.sqlite3`** — the file
alone is not the database. Ask SQLite for a consistent copy instead, then take that:

```sh
docker compose exec web sqlite3 /rails/storage/production.sqlite3 ".backup /rails/storage/backup.sqlite3"
docker compose cp web:/rails/storage/backup.sqlite3 "./tinkerex-$(date +%F).sqlite3"
docker compose exec web rm /rails/storage/backup.sqlite3
```

Keep that file with a copy of your library folder (any file-level tool; the folder is plain files).
Thumbnails need no backup: `docker compose exec web bin/rails previews:backfill_missing` regenerates
any that are missing. For the sync server, the same `.backup` against
`/rails/host/storage/production.sqlite3` in the `sync` container plus a copy of its
`chunk-store/` directory — or stop the stack and copy the whole volume.

**Restore**: stop the stack, put the backup file in place with a one-off container, start it:

```sh
docker compose down
docker compose run --rm --no-deps -v "$PWD/tinkerex-2026-10-13.sqlite3:/restore.sqlite3" \
  --entrypoint sh web -c 'rm -f /rails/storage/production.sqlite3-wal /rails/storage/production.sqlite3-shm && cp /restore.sqlite3 /rails/storage/production.sqlite3'
docker compose up -d
```

## 8. Environment reference

Every variable the app reads, plus the ones only `docker compose` reads (marked *compose*) and the
sync server's own (marked *sync*). "Required" means required for that backend or feature; the
default is what you get when the variable is unset. The compose files set the ones marked *set by
compose*; the rest come from `.env`.

| variable | required? | default | what it does |
|---|---|---|---|
| **Core** | | | |
| `SECRET_KEY_BASE` | yes | — | Signs sessions and cookies. `openssl rand -hex 64`. Changing it signs everyone out. The only secret a share or s3 install needs. |
| `LIBRARY_BACKEND` | yes, *set by compose* | — (the boot refuses a blank value in production) | Where the files live: `share` (a folder), `s3` (a bucket) or `chunk_remote` (the sync server). Chosen per deployment, never per user. |
| `LIBRARY_PATH` | share, *set by compose* (`/library`) | — | The folder inside the container to index. The boot checks that it exists, is a directory, and is writable by uid 1000 — by writing a probe file, because mode bits lie on network mounts. |
| `APP_HOST` | for mail links | `APP_HOST-IS-NOT-SET.invalid` | The host name (no scheme) that links in email point at; also the default HELO domain and the domain of the default sender. |
| `FORCE_SSL` | when behind TLS | off | Set to `1` when the server is reached over HTTPS through a reverse proxy: redirects plain HTTP, marks cookies secure, makes mail links `https`. Setting it with no TLS in front locks you out. |
| `RAILS_MAX_THREADS` | no | 3 (Puma), 5 (database pool) | Puma's thread count and the SQLite connection pool. `.env.example` sets 16, which is what the author runs. |
| `SOLID_QUEUE_IN_PUMA` | no | **on** in production | Runs the background workers (scans, thumbnails, trash purge, project intake, the changelog pull) inside the web container. `false`, `0` or `no` turns it off, for a split `bin/jobs` container. Outside production it is an opt-in, as it always was. |
| **Compose only** (`docker-compose.yml` reads these; the app never sees them) | | | |
| `LIBRARY_HOST_PATH` | share | `./library` | The folder on the host bound to `/library`. Writable by uid 1000 (section 2). A relative path is resolved against the compose file's directory. |
| `TINKEREX_PORT` | no | `8080` | The host port the web app is published on. |
| `TINKEREX_IMAGE` | no | `tinkerex:local` | The image to run. The default is built from this checkout by `--build`; set `ghcr.io/chaim354/tinkerex:latest` and run `docker compose pull` instead once that package is public. |
| `TINKEREX_ADDONS_PATH` | tools profile | `../tinkerex-addons` | Path to a checkout of `chaim354/tinkerex-addons`, the build context for the addon bundle server. |
| `TINKEREX_SYNC_PATH` | chunk_remote | `../tinkerex-sync` | Path to a checkout of `chaim354/tinkerex-sync`, the build context for the sync server. |
| `TINKEREX_SYNC_PORT` | no | `3001` | The host port the sync server is published on; what devices connect to. |
| `SYNC_SECRET_KEY_BASE` | chunk_remote | — | Becomes the sync server's own `SECRET_KEY_BASE`. `openssl rand -hex 64`; distinct from the app's. |
| `SYNC_SCHEDULER` | chunk_remote, *set by compose* (`"true"`) | — | The sync server's housekeeping: expired pending commits reaped hourly, orphaned chunk bytes weekly, retention that keeps every version. The app never reads it. |
| `COMPOSE_FILE`, `COMPOSE_PROFILES` | no | — | Docker's own: putting `COMPOSE_FILE=docker-compose.yml:docker-compose.chunk_remote.yml` or `COMPOSE_PROFILES=tools` in `.env` saves typing `-f` / `--profile` on every command. |
| **Accounts and mail** (section 4) | | | |
| `REGISTRATION` | no | `closed` in production | `closed`: only the first account (the owner) can sign up. `open`: anyone can — **refused at boot on share and s3**, where every account indexes one library. |
| `DEMO_ACCOUNT_EMAIL` | no | — (no demo) | Set it to turn the sign-in page into a demo: one click signs visitors into the shared account it names, which cannot change its credentials, publish or enrol a device, and is destroyed and re-seeded from `db/seeds/demo` every night at 04:00 UTC (run `bin/rails tinkerex:demo:setup` once to create it). **On share and s3 every account indexes the same library, so visitors see all of it and the reset replaces all of it: set it only on a server that holds nothing else.** |
| `DEMO_MAX_UPLOAD_BYTES` | no | `26214400` (25 MB) | The largest single file the demo account may upload, as a whole number of bytes. Anything else (`25MB`) refuses to boot while demo mode is on. |
| `SMTP_ADDRESS` | for mail | — (no mail) | The SMTP host. Setting it turns delivery on; everything below has a sensible default. |
| `SMTP_PORT` | no | `587` | |
| `SMTP_USER_NAME`, `SMTP_PASSWORD` | if the relay needs auth | — | Authentication is attempted only when a user name is given. |
| `SMTP_AUTHENTICATION` | no | `plain` | `plain`, `login` or `cram_md5`. |
| `SMTP_DOMAIN` | no | `APP_HOST` | The HELO name. |
| `SMTP_STARTTLS` | no | on | STARTTLS, on unless set to `false`. |
| `MAIL_FROM` | no | `no-reply@<APP_HOST>` | The sender of every message. |
| `TINKEREX_PASSWORD` | for the console tasks | — | The password `bin/rails tinkerex:owner` / `tinkerex:password` read, so that it never sits on a command line. |
| `OMNIAUTH_ENABLED` | no | off | Any value turns on OpenID Connect login. |
| `OIDC_ISSUER`, `OIDC_CLIENT_ID`, `OIDC_CLIENT_SECRET`, `OIDC_REDIRECT_URI` | with `OMNIAUTH_ENABLED` | — | The provider's issuer URL (discovery is used), the client credentials, and the callback URL registered with the provider. |
| **The s3 backend** (section 2) | | | |
| `LIBRARY_S3_BUCKET`, `LIBRARY_S3_ACCESS_KEY_ID`, `LIBRARY_S3_SECRET_ACCESS_KEY` | s3 | — | The bucket and credentials. The boot checks they are present; it never touches the network. |
| `LIBRARY_S3_ENDPOINT` | for non-AWS | — | The endpoint URL (SeaweedFS, MinIO, R2). Path-style requests are used. |
| `LIBRARY_S3_REGION` | no | `auto` | |
| `LIBRARY_S3_PREFIX` | no | — (the whole bucket) | A key prefix that is the library's root, e.g. `library/`. |
| **The sync server** (section 5) | | | |
| `CHUNK_REMOTE_URL` | chunk_remote, *set by compose* (`http://sync:3000`) | — | The sync server's address as seen from the app. |
| `SYNC_PUBLIC_URL` | chunk_remote | — | The sync server's address as seen from your other devices, scheme included; the desktop app is handed it when it signs in. With compose, `http://<this host>:3001` or the name a reverse proxy in front of that port answers to. `CHUNK_REMOTE_URL` is the same server as seen from the app, a name only the app's own network resolves, so the two differ on purpose. The boot refuses chunk_remote without it. |
| `SYNC_ADMIN_TOKEN` | chunk_remote | — | The operator credential the app uses to create each new account's library on the sync server. **Identical on both services.** `openssl rand -hex 32`. |
| `ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY` | chunk_remote | — (read from credentials, which a stranger's image cannot decrypt) | Encrypts each account's sync credential at rest. 32+ characters; **keep it**. |
| `ACTIVE_RECORD_ENCRYPTION_DETERMINISTIC_KEY` | chunk_remote | — | Same; the key for deterministic encryption. |
| `ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT` | chunk_remote | — | Same; the salt the two keys are derived with. |
| `STORAGE_BACKEND` | *sync*, set by the overlay | — | The sync server's chunk store: `local` (a directory in its volume) or `s3`. The overlay sets `local`. |
| `CHUNK_LOCAL_DIR` | *sync* | `/rails/host/storage/chunk-store` | Where the local chunk store lives, inside the `tinkerex_sync_storage` volume. |
| `CHUNK_PUBLIC_URL` | *sync*, no | the request's own host | The base URL the sync server writes into chunk download links. Unset, each client gets links on the host it connected through, which is right for this layout; set it only when a reverse proxy in front changes the public address. |
| **The Tools gallery** (section 3) | | | |
| `ADDON_SOURCE_URL` | tools profile | — | The addon bundle server; `http://addons` with the profile. Takes precedence over the path below. |
| `ADDON_SOURCE_PATH` | no | `/rails/public/addons` in the image (empty) | A directory of addon bundles on disk, the alternative to a bundle server. Empty means an empty gallery. |
| `BOXES_SIDECAR_URL`, `OPENSCAD_SIDECAR_URL` | tools profile | — (that addon shows as unavailable) | Where each sidecar listens: `http://boxes:8000`, `http://openscad:8000` with the profile. The variable name is `<SERVICE>_SIDECAR_URL`, so a future sidecar needs no code change. |
| `ADDON_SERVICE_MAX_TIMEOUT` | no | `120` | Ceiling, in seconds, on one sidecar call. |
| `ADDON_SAVE_MAX_FILES`, `ADDON_SAVE_MAX_BYTES` | no | `8`, `4000000` | How many files, and how many bytes in total, one addon save may write into the library. |
| **Library behaviour** | | | |
| `LIBRARY_TRASH_DAYS` | no | `30` | Days a deleted file stays in `.trash/` before the daily purge removes it (share and s3). `0` keeps everything forever — it does not purge everything. |
| `LIBRARY_SCAN_MAX_DELETE_PCT` | no | `20` | A scan that would remove more than this percentage of the library is refused and logged — the shape of an unmounted share. |
| `PREVIEW_MAX_BYTES` | no | `33554432` (32 MB) | Files larger than this get no thumbnail. |
| `PROJECT_ORGANIZE_MAX_MOVES` | no | `500` | Cap on files one intake sweep files into a project folder's categories. |
| `PROJECT_ORGANIZE_EAGER_MAX_MOVES` | no | `25` (`5` on s3) | The same cap for the sweep that runs right after an upload, inside the request. |
| `PROJECT_DISCOVERY_MAX` | no | `50` | Cap on projects one discovery sweep creates from folders under `Projects/`. |
| `MODEL_CATALOG_MAX_MODELS` | no | `200` | Cap on models one catalogue sweep creates. |
| **Renderers** (the image provides all of these; only an install outside the image sets them) | | | |
| `F3D_BIN` | no | `/opt/f3d/bin/f3d` in the image | F3D, for OBJ, STEP, IGES, BREP and the mesh formats. Absent on arm64, where those files get a generic icon. |
| `PDFIUM_BIN`, `RESVG_BIN`, `STL_THUMBNAILER_BIN`, `VIPSTHUMBNAIL_BIN`, `NODE_BIN` | no | the binary's own name, on `PATH` | PDF pages, SVG/DXF/LightBurn, STL, images, and Node for the Gerber renderer. |
| `GERBER_RENDER_TIMEOUT` | no | `60` | Seconds allowed for one Gerber render. |
| **Advanced: Postgres instead of SQLite** (not templated; the compose files run SQLite) | | | |
| `DATABASE_URL` | no | — (SQLite in the volume) | A `postgres://` URL switches every database to Postgres. |
| `DB_SSLMODE` | no | `prefer` for a localhost URL, else `require` | libpq's sslmode. |
| `DB_SSLROOTCERT` | no | — | Path to the CA certificate, when the server's certificate needs one. |
| `SOLID_CACHE_DATABASE_URL`, `SOLID_QUEUE_DATABASE_URL`, `SOLID_CABLE_DATABASE_URL` | no | `DATABASE_URL` with `_cache`, `_queue`, `_cable` appended to the database name | The three Solid databases. The derived databases must exist. |
| **Do not set** | | | |
| `ENABLE_TEST_SIGNUP` | never | off | Opens an unauthenticated endpoint that creates confirmed accounts. It exists for the author's test boxes and prints a warning on every boot where it is on. |
| `RAILS_MASTER_KEY` | never (section 9) | — | |

## 9. Never set `RAILS_MASTER_KEY`

The repository ships `config/credentials.yml.enc`, encrypted with a key only the author holds. The
app does not need it: with no master key, Rails reads that file as empty and takes
`SECRET_KEY_BASE` and the `ACTIVE_RECORD_ENCRYPTION_*` values from the environment instead, which is
what the compose files arrange. A master key that is *present but wrong* is a different case — Rails
tries to decrypt the file, fails, and the boot crashes with `ActiveSupport::MessageEncryptor::InvalidMessage`.
So leave it unset. The only reason to set it is if you have deleted `config/credentials.yml.enc` and
generated your own with `bin/rails credentials:edit`, in which case it is your key and your file.

## 10. Where the author's own deploy recipe lives

`docs/DEPLOY.md` describes how the author deploys this app — Kamal from a Mac, secrets from
1Password, three Unraid destinations and an OVH box. It is the record of those deployments, not an
install guide, and nothing in it is needed to run the compose files above.
