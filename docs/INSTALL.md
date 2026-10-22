# Installing Tinkerex

A self-hosted library for a maker's files, run with Docker Compose on your own machine — a Mac, a
Windows machine or a Linux box. This page is the whole of what a new install needs: the quick start,
the settings you can change, the optional pieces, and — in section 7, with the advanced options'
own rows in section 9 — **the reference for every environment variable the app reads**. Those
tables are guarded by `test/install_docs_test.rb`, which fails the build when the code reads a
variable this page does not name, so they are current by construction rather than by promise.

**This page installs the `share` backend, the default**: your files stay plain files in a folder,
the app indexes them, and that folder stays yours — editable with anything else; it can also be a
network share on another computer (section 3). Sections 1 to 8 are that path, and they are all a new
install needs.

The other ways to run it — your own S3 bucket instead of a folder, the sync server that gives each
account its own library with versions, and Postgres instead of SQLite — are **a work in progress**.
They are collected in section 9, Advanced, and nothing before it depends on them.

## 1. What you need

- **Docker.** On a Mac or a Windows machine, [Docker Desktop](https://www.docker.com/products/docker-desktop/).
  On Linux, Docker Engine with the Compose plugin. Either way `docker compose version` must say
  2.24 or newer.
- **A folder for your files**, or an empty one: the folder you put the compose file in is the
  library.
- Nothing else: no Ruby, no database server, no mail server, no secrets to generate. The database is
  SQLite in a Docker volume, and the session secret is generated on the first start and kept there.

Four images are pulled: the app, the two tools (a box generator and OpenSCAD) and the small server
that holds the tool bundles. The app image is built for amd64 and arm64, so an Apple-silicon Mac or a
Raspberry Pi-class box runs it natively; STEP, IGES, OBJ and the other mesh formats get a generic
icon instead of a thumbnail on arm64 (F3D ships no Linux arm64 build; STL, SVG, DXF, LightBurn, PDF,
images and Gerber all render). The three Tools images are published for amd64 only (OpenSCAD is an
x86 AppImage; the other two are built that way today), and the compose file says so, so Docker
Desktop on an Apple-silicon Mac pulls them and runs them under emulation; section 3 has the note for
an arm64 Linux box. The author runs this on a Mac and on Linux; the Windows path has not been run.

## 2. Quick start

Put [`docker-compose.yml`](../docker-compose.yml) (download it from this repository) in the folder
that holds your files — or in an empty folder — and in that folder:

> **Or make one with your settings filled in** at <https://tinkerex.com/install/compose>: your
> folder or network share, port, user and mail, written into the file for you. The page builds the
> file in your browser and sends nothing you type anywhere, passwords included. Any Tinkerex server
> has the same page at `/install/compose`.

```sh
docker compose up -d
docker compose logs -f web      # until Puma reports it is listening; Ctrl-C leaves it running
```

Whatever folder the file is in becomes the library: it is indexed, uploads land in it, and deleted
files move to a `.trash/` inside it. So not your Downloads folder.

The first start pulls the four images. `curl http://localhost:8080/up` answers `200` once the app is
ready; the compose healthcheck polls the same path. Open `http://localhost:8080`.

**If a container exits**, `docker compose logs web` has the reason, and it is one sentence naming the
problem. The app refuses to boot on a misconfiguration rather than starting and failing later.

### First run: the first account is the owner

With no account yet, the sign-up page works and says so: *"This is the server's first account. It
becomes the owner and needs no email confirmation."* Create it; you are signed in, as the server's
admin. **After that, sign-ups are closed** — the page answers "Sign-ups are closed" and the link
disappears — and an admin adds more accounts under Settings → Users (section 4). No mail server is
involved in any of this.

**Then the app asks once which folder is the library.** The next screen names the mounted folder — *the folder your docker-compose.yml is in*, or the path you
typed in `LIBRARY_HOST_PATH` — and says what will happen to it: it is indexed every 15 minutes,
uploads land in it, and deletions move into its `.trash/`. **Use this folder** confirms it.
**Choose a folder inside it** opens a folder picker over it, to make the library one folder within
it; the picker lists folders only, never a dot-folder, `.trash`, a link or another hidden or
reserved name, and **Use this folder** then confirms the one you picked. The first scan runs after
you confirm, not at sign-up. Until then nothing is scanned and every page brings you back to that
screen, except Help, changing your email or password, and signing out. Creating the first account
with `bin/rails tinkerex:owner` (section 4) confirms the whole mounted folder itself, so a console
install is not asked.

**To change it later**, an admin opens Settings → Library folder. The folder is every account's
library, so only an admin chooses or changes it: any other account sees the same page read-only, and
one that signs in before the folder is first confirmed waits there until an admin confirms it. With
files already indexed it offers two outcomes. **Switch to this folder** keeps each file's projects,
notes and tags when the new folder holds the same files (the old one moved or renamed on the host);
if it holds a different set, the
scan refuses, the way it refuses an unmounted share (`LIBRARY_SCAN_MAX_DELETE_PCT`, 20%), and the
page says so. **Start over with this folder** forgets the catalog — every indexed file, its
previews, notes, pins and the 3D models found in it. Projects, tasks, inventory and BOMs stay, and
each project keeps its folder when the new library has a folder at the same path (say
`Projects/Desk Lamp`); a project whose folder is not there shows it as removed, as it would if you
deleted the folder. It never deletes or moves anything on disk.

### Where your files come from

- **The folder the compose file is in is your library** — or the folder you name in section 3, or
  a folder you choose inside it (above). Once you have confirmed it, it is indexed on every start,
  every 15 minutes, and whenever you press **Rescan library** on the Files page. Anything you put
  in the folder by other means — a copy over the network, a slicer saving into it — appears on the
  next scan.
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

### The Tools gallery

Tools are add-ons that run inside the app and save their output into your library — a box generator
and an OpenSCAD editor are the two that exist. They are the other three containers the compose file
starts, so the gallery is live from the first start. The two tool images are GPL-licensed, which is
why they are separate processes talked to over HTTP and never linked into the app. All three Tools
images are amd64-only today, so on an arm64 Linux box without x86 emulation those three containers
cannot start; the app comes up on its own, and the gallery says its tools are unavailable.

## 3. Settings: your folder, your user, your port

Everything here is optional. A setting goes in a file named `.env` beside the compose file, one
`NAME=value` per line, followed by `docker compose up -d` again; `.env.example` in the repository
lists every line with its default.

- **`LIBRARY_HOST_PATH`** — the folder that holds your files, when it is not the compose file's own
  folder. An absolute path (`/mnt/user/files`, `/Users/you/Workshop`, `C:\Users\you\Workshop`) or
  one relative to the compose file. On a Mac or Windows the folder must be under a location Docker
  Desktop shares with containers, which by default includes your home directory. On Windows a
  folder on the Windows drive works; a large library is faster inside the WSL2 filesystem. The app
  is a view of that folder, not a copy: uploads land in it, deleted files move to its `.trash/`, and
  anything another program puts there is indexed within 15 minutes. To pick the library from a
  wider folder, mount a parent here — `~` works on Docker Desktop and Linux — run
  `docker compose up -d` once, and choose the library inside it in the browser (section 2). Docker
  lets the app see only what is mounted, which is why this line is still needed.
- **`PUID` and `PGID`** (Linux) — the user and group the app runs as inside the container. By
  default it runs as **the owner of your folder**, so there is nothing to set when the folder is
  yours or an Unraid share (`99`/`100`). Set them when the folder is owned by root (the default is
  then `1000`; `id -u` and `id -g` print yours) or to run as a different user on purpose. Set both
  or neither: with `PUID` alone, `PGID` is `1000`. Files the app writes into your folder are owned
  by that user, and the boot checks it can write there. A folder you choose inside it in the
  browser must be writable by that user too; when it is not, the page refuses it, names the user
  as `uid:gid`, and tells you to set `PUID` and `PGID` in `.env` to that folder's owner.
  Docker Desktop on Mac and Windows presents your folders as writable by any user, so there is
  nothing to set there. The app never changes your folder's ownership — it only probes it — with
  one exception: an empty folder owned by root (the one Docker itself creates on Linux for a
  missing bind-mount source) is made the app user's, so a fresh install works on the first start.
- **`TINKEREX_PORT`** — the port on this machine, default `8080`.
- Accounts and mail are section 4; every other variable is in section 7.

### A network share instead of a folder

When your files are on another computer — a NAS, or a folder shared from a Mac or a Windows
machine — Docker can connect to the SMB share itself, with nothing mounted on this machine first and
no `.env`. Everything goes in `docker-compose.yml`, which carries the lines commented out:

1. In the `web` service's `volumes:`, delete the `${LIBRARY_HOST_PATH:-.}:/library` line and
   uncomment `- library:/library` below it.
2. At the end of the file, uncomment the `library:` volume and fill in the share:

   ```yaml
     library:
       driver_opts:
         type: cifs
         device: "//192.168.1.50/Files"
         o: "username=you,password=your-password,vers=3.0,uid=1000,gid=1000,file_mode=0664,dir_mode=0775"
   ```

   `device` is `//<server>/<share name>`; a space in the share name stays as it is inside the
   quotes. The server can be a DNS name or an IP address; if it does not connect by name (a `.local`
   name often does not resolve inside Docker), use the IP. For a guest share, `guest` replaces
   `username=…,password=…`. In the password, write `$` as `$$` (compose reads `$` as the start of a
   variable) and a comma as `,,` (the options are a comma-separated list). `uid=1000,gid=1000` make
   the share's files belong to the user the app runs as, which is what lets it write there; leave
   them. `vers=3.0` suits a Mac, Windows 10 or later and current NAS systems; an older NAS may need
   `vers=2.1`.
3. Optionally, set `LIBRARY_HOST_PATH:` in the `web` service's `environment:` to the share's address
   (`//192.168.1.50/Files`). It only names the folder on the setup page, which otherwise says "the
   folder your docker-compose.yml is in".

Then `docker compose up -d`. The first run is the same as with a folder (section 2): the share is
the mounted folder, and you can choose a folder inside it.

**The share must be reachable when the app starts.** Docker connects to it as the container starts,
so while the other computer is off or asleep the app does not start: `docker compose up -d` stops
with an error naming the share (`no route to host`, or `permission denied` for a wrong password),
and Docker does not retry by itself. Run it again once the share is reachable; the same goes for a
container Docker could not start after this machine restarted. Once the app is running, a share that
drops — the other computer restarting — reconnects by itself within seconds of coming back.
Meanwhile pages answer from the catalog, and a scan is refused rather than mistaking the missing
share for deleted files.

**Changing the share settings.** Docker keeps them in the volume, so editing the file is not enough:
`docker compose up -d` asks *"Volume … exists but doesn't match configuration in compose file.
Recreate (data will be lost)?"* and, unanswered, keeps the old settings. The data it means is only
those settings; your files stay on the share. Run `docker compose down`, then
`docker volume rm <folder>_library` (`<folder>` is the name of the folder the compose file is in;
`docker volume ls` shows it), then `docker compose up -d`.

The password is in `docker-compose.yml` in plain text, and in Docker's record of the volume
(`docker volume inspect`), so keep the file to yourself (`chmod 600 docker-compose.yml` on a Mac or
Linux). Docker masks it in its error messages.

### Building from source instead of pulling

With a clone of this repository and a sibling checkout of `chaim354/tinkerex-addons` at
`../tinkerex-addons` (or `TINKEREX_ADDONS_PATH`), the overlay `docker-compose.build.yml` builds all
four images on this machine:

```sh
git clone https://github.com/chaim354/tinkerex.git && git clone https://github.com/chaim354/tinkerex-addons.git
cd tinkerex
docker compose -f docker-compose.yml -f docker-compose.build.yml up -d --build
```

The first build downloads a few hundred megabytes of renderers and compiles two small Rust tools;
allow several minutes. It is the path for an arm64 Linux box (the OpenSCAD image cannot be built
there without x86 emulation — start the other three by name: `… up -d --build web boxes addons`;
the box generator and the bundle server build natively), for a machine without registry access,
and for working on the app. In a clone the overlay binds `./library` (gitignored) to `/library`
instead of the clone's own folder, so the repository itself is never indexed.

## 4. Mail and more accounts

**Mail.** The app sends two kinds of message: account confirmation and password reset. Nothing is
sent until `SMTP_ADDRESS` is set; with it unset the boot log says so once, and the sign-up page tells
a visitor that the server cannot send email yet. **`APP_HOST`** — the host name or address people
reach this server at, with no scheme (`maker.example.net`, `192.168.1.20`) — is required as soon as
`SMTP_ADDRESS` is set, and the boot refuses the pair without it: it is what the links in mail point
at. Without mail it need not be set. `SMTP_PORT` (587), `SMTP_USER_NAME` and
`SMTP_PASSWORD` (authentication is used only when a user name is given), `SMTP_AUTHENTICATION`
(`plain`), `SMTP_DOMAIN` (the HELO name, default `APP_HOST`) and `SMTP_STARTTLS` (on unless set to
`false`) are the rest. `MAIL_FROM` is the sender address, default `no-reply@<APP_HOST>`.

**Who may sign up.** `REGISTRATION` is `closed` by default in production: the first account is the
owner and nobody else gets the page. **`REGISTRATION=open` is refused at boot**, on purpose: every
account indexes the *same* folder, so an open sign-up would hand any visitor your files. (Open
sign-ups belong to the sync server, an advanced backend where each account has its own library —
section 9.)

**Adding an account.** The first account is the server's admin, and an admin manages accounts under
**Settings → Users**, with no mail involved:

- **Add an account**: an email, a password you choose and pass on to the person (at least 10
  characters, shown as you type it), and whether it is an admin too. It is confirmed on the spot.
  Every account on a folder or bucket library sees the same files, and can change and delete them.
- **On an account's own page**: set a new password (this also confirms the account and unlocks it
  after too many wrong passwords, and signs it out of every browser; a desktop app already signed in
  keeps syncing), make it an admin or stop it being one, or delete it, by typing its address. Deleting
  removes its projects, notes, tags and its copy of the catalog; every file in the library stays.

Your own account is changed on the Account page, behind your current password, and the only admin
cannot delete their account while other accounts exist. An install from before admins existed made
its oldest account the admin when it updated (passing over the demo account, if there is one).

**From the console.** Three tasks do the same with no browser: create an account (confirmed; the
first one on a server is the admin), reset a password and confirm the account, and make an account
an admin, which is the way back for a server with no admin left — one whose accounts all came from
single sign-on, say. A password is read from `TINKEREX_PASSWORD`, never from the command line, so
that it stays out of your shell history and out of `ps`; the `read -rs` below prompts for it without
echo:

```sh
read -rs TINKEREX_PASSWORD && export TINKEREX_PASSWORD
docker compose exec -e TINKEREX_PASSWORD web bin/docker-entrypoint bin/rails 'tinkerex:owner[someone@example.net]'
docker compose exec -e TINKEREX_PASSWORD web bin/docker-entrypoint bin/rails 'tinkerex:password[someone@example.net]'
unset TINKEREX_PASSWORD
docker compose exec web bin/docker-entrypoint bin/rails 'tinkerex:admin[someone@example.net]'
```

`bin/docker-entrypoint` in front of the command runs it as the same user the server runs as
(`PUID`). A bare `docker compose exec` runs as root, and a task that creates files would leave them
owned by root.

`tinkerex:owner` refuses an address that already exists and a password under 10 characters;
`tinkerex:admin` refuses an unknown address and the demo account.

**Single sign-on** through an OpenID Connect provider is its own door: `OMNIAUTH_ENABLED` plus the
four `OIDC_*` values in the table. A provider login creates a confirmed account whatever
`REGISTRATION` says — the provider decides who may sign in.

## 5. Updating

```sh
docker compose pull
docker compose up -d                # with the same -f overlay as before, if you use one,
                                    # or set COMPOSE_FILE in .env once
```

The database migrates itself when the container starts (the entrypoint runs `db:prepare` before
Puma). `.env` is yours and nothing here touches it; `.env.example` in the repository may gain lines
in a new release, so `diff` it against yours now and then. A library scan runs on start, so a file
that changed on disk while the app was down is picked up. An install from before the library folder
could be chosen is not asked: it keeps the whole mounted folder as its library. Building from source
instead: `git pull` in the clone, then the overlay command from section 3 with `--build`.

## 6. Backups

Everything the app keeps is in two places:

- **The `tinkerex_storage` volume**, mounted at `/rails/storage` in the `web` container: four
  SQLite files (`production.sqlite3` is the one that matters; the cache, queue and cable files are
  disposable), the thumbnails, and `secret_key_base`, the session secret generated on the first
  start — a restored volume keeps everyone signed in, a lost one only signs everyone out. Compose
  names the volume `<project>_tinkerex_storage`;
  `docker volume ls` shows it.
- **Your library folder.**

SQLite runs in WAL mode, so **never `docker cp` or `tar` a live `production.sqlite3`** — the file
alone is not the database. Ask SQLite for a consistent copy instead, then take that:

```sh
docker compose exec web bin/docker-entrypoint sqlite3 /rails/storage/production.sqlite3 ".backup /rails/storage/backup.sqlite3"
docker compose cp web:/rails/storage/backup.sqlite3 "./tinkerex-$(date +%F).sqlite3"
docker compose exec web bin/docker-entrypoint rm /rails/storage/backup.sqlite3
```

Keep that file with a copy of your library folder (any file-level tool; the folder is plain files).
Thumbnails need no backup:
`docker compose exec web bin/docker-entrypoint bin/rails previews:backfill_missing` regenerates any
that are missing.

**Restore**: stop the stack, put the backup file in place with a one-off container, start it. The
copy goes through the image's entrypoint, so the restored file belongs to the app's user (`PUID`):

```sh
docker compose down
docker compose run --rm --no-deps -v "$PWD/tinkerex-2026-10-13.sqlite3:/restore.sqlite3" \
  web sh -c 'rm -f /rails/storage/production.sqlite3-wal /rails/storage/production.sqlite3-shm && cp /restore.sqlite3 /rails/storage/production.sqlite3'
docker compose up -d
```

## 7. Environment reference

Every variable the share install reads, plus the ones only `docker compose` reads (marked
*compose*). The advanced options' variables — the s3 backend's, the sync server's and Postgres's —
are in section 9's own table; the two tables together name every variable the app reads. "Required"
means required for that feature; the default is what you get when the variable is unset. The compose
file sets the ones marked *set by compose*; the rest come from `.env`.

| variable | required? | default | what it does |
|---|---|---|---|
| **Core** | | | |
| `SECRET_KEY_BASE` | no | generated on the first start, kept at `storage/secret_key_base` in the volume | Signs sessions and cookies. Set it to use your own (`openssl rand -hex 64`); a blank value counts as unset. Changing or losing it signs everyone out and nothing else. |
| `LIBRARY_BACKEND` | no (the image defaults to `share`) | `share` | Where the files live. `share` (a folder) is the default and what this page installs; leave it unset. The other two values, `s3` and `chunk_remote`, are the advanced backends in section 9, a work in progress. Chosen per deployment, never per user. An explicit blank refuses the boot, and so does any value other than these three spelled exactly (`S3`, or a stray space, included). |
| `LIBRARY_PATH` | no | `/library` (the image default) | The folder mounted inside the container. The library is this folder or one chosen inside it in the browser (section 2). The boot checks that it exists, is a directory, and is writable by the app's user — by writing a probe file, because mode bits lie on network mounts. |
| `APP_HOST` | with `SMTP_ADDRESS` | `APP_HOST-IS-NOT-SET.invalid`, which without SMTP only ever lands in a message nothing can deliver | The host name (no scheme) that links in email point at; also the default HELO domain and the domain of the default sender. The boot refuses `SMTP_ADDRESS` without it. |
| `FORCE_SSL` | when behind TLS | off | Set to `1` when the server is reached over HTTPS through a reverse proxy: redirects plain HTTP, marks cookies secure, makes mail links `https`. Setting it with no TLS in front locks you out. |
| `RAILS_MAX_THREADS` | no | 3 (Puma), 5 (database pool); **the compose file sets 16** | Puma's thread count and the SQLite connection pool. 3 starves once a tool call is proxied through the app; 16 is what the author runs. |
| `SOLID_QUEUE_IN_PUMA` | no | **on** in production | Runs the background workers (scans, thumbnails, trash purge, project intake) inside the web container. `false`, `0` or `no` turns it off, for a split `bin/jobs` container. Outside production it is an opt-in, as it always was. |
| **Compose only** (`docker-compose.yml` reads these; the app never sees them, except `LIBRARY_HOST_PATH`, passed through display-only, and `PUID`/`PGID`, which reach the entrypoint) | | | |
| `LIBRARY_HOST_PATH` | no | the compose file's own folder (`.`) | The folder on the host bound to `/library`; a relative path is resolved against the compose file's directory. Also passed into the container display-only, so the Getting started panel and the Library folder page can name the folder ("the folder your docker-compose.yml is in", or the path as typed). Section 3. |
| `PUID`, `PGID` | no | the library folder's owner, else `1000` | The user and group the app runs as inside the container, and so the owner of every file it writes into your folder (section 3). Both unset, the folder's owner when it is not root, otherwise `1000`; with `PUID` set alone, `PGID` is `1000`. An Unraid share gives `99`/`100`; Docker Desktop needs nothing. The container starts as root and drops to them; `--user` on the container skips that and runs as given. |
| `TINKEREX_PORT` | no | `8080` | The host port the web app is published on. |
| `TINKEREX_IMAGE` | no | `ghcr.io/chaim354/tinkerex:latest` | The app image. `docker-compose.build.yml` builds `tinkerex:local` from the checkout instead. |
| `TINKEREX_ADDONS_PATH` | build overlay | `../tinkerex-addons` | Path to a checkout of `chaim354/tinkerex-addons`, the build context for the addon bundle server in `docker-compose.build.yml`. |
| `COMPOSE_FILE` | no | — | Docker's own: `COMPOSE_FILE=docker-compose.yml:docker-compose.build.yml` in `.env` saves typing `-f` on every command. |
| **Accounts and mail** (section 4) | | | |
| `REGISTRATION` | no | `closed` in production | `closed`: only the first account (the owner) can sign up. `open`: anyone can — **refused at boot**, because every account indexes one library. Only the sync server (section 9) accepts it. |
| `DEMO_ACCOUNT_EMAIL` | no | — (no demo) | Set it to turn the sign-in page into a demo: one click signs visitors into the shared account it names, which cannot change its credentials, publish or enrol a device, and is destroyed and re-seeded from `db/seeds/demo` every night at 04:00 UTC (run `bin/rails tinkerex:demo:setup` once to create it). **Every account indexes the same library, so visitors see all of it and the reset replaces all of it: set it only on a server that holds nothing else.** |
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
| **The Tools gallery** (section 2) | | | |
| `ADDON_SOURCE_URL` | *set by compose* (`http://addons`) | — | The addon bundle server. Takes precedence over the path below. |
| `ADDON_SOURCE_PATH` | no | `/rails/public/addons` in the image (empty) | A directory of addon bundles on disk, the alternative to a bundle server. Empty means an empty gallery. |
| `BOXES_SIDECAR_URL`, `OPENSCAD_SIDECAR_URL` | *set by compose* (`http://boxes:8000`, `http://openscad:8000`) | — (that addon shows as unavailable) | Where each sidecar listens. The variable name is `<SERVICE>_SIDECAR_URL`, so a future sidecar needs no code change. |
| `ADDON_SERVICE_MAX_TIMEOUT` | no | `120` | Ceiling, in seconds, on one sidecar call. |
| `ADDON_SAVE_MAX_FILES`, `ADDON_SAVE_MAX_BYTES` | no | `8`, `4000000` | How many files, and how many bytes in total, one addon save may write into the library. |
| **Library behaviour** | | | |
| `LIBRARY_TRASH_DAYS` | no | `30` | Days a deleted file stays in `.trash/` before the daily purge removes it. `0` keeps everything forever — it does not purge everything. |
| `LIBRARY_SCAN_MAX_DELETE_PCT` | no | `20` | A scan that would remove more than this percentage of the library is refused and logged — the shape of an unmounted share. |
| `PREVIEW_MAX_BYTES` | no | `33554432` (32 MB) | Files larger than this get no thumbnail. |
| `PROJECT_ORGANIZE_MAX_MOVES` | no | `500` | Cap on files one intake sweep files into a project folder's categories. |
| `PROJECT_ORGANIZE_EAGER_MAX_MOVES` | no | `25` | The same cap for the sweep that runs right after an upload, inside the request. |
| `PROJECT_DISCOVERY_MAX` | no | `50` | Cap on projects one discovery sweep creates from folders under `Projects/`. |
| `MODEL_CATALOG_MAX_MODELS` | no | `200` | Cap on models one catalogue sweep creates. |
| **Renderers** (the image provides all of these; only an install outside the image sets them) | | | |
| `F3D_BIN` | no | `/opt/f3d/bin/f3d` in the image | F3D, for OBJ, STEP, IGES, BREP and the mesh formats. Absent on arm64, where those files get a generic icon. |
| `PDFIUM_BIN`, `RESVG_BIN`, `STL_THUMBNAILER_BIN`, `VIPSTHUMBNAIL_BIN`, `NODE_BIN` | no | the binary's own name, on `PATH` | PDF pages, SVG/DXF/LightBurn, STL, images, and Node for the Gerber renderer. |
| `GERBER_RENDER_TIMEOUT` | no | `60` | Seconds allowed for one Gerber render. |
| **Do not set** | | | |
| `ENABLE_TEST_SIGNUP` | never | off | Opens an unauthenticated endpoint that creates confirmed accounts. It exists for the author's test boxes and prints a warning on every boot where it is on. |
| `RAILS_MASTER_KEY` | never (section 8) | — | |

## 8. Never set `RAILS_MASTER_KEY`

The repository ships `config/credentials.yml.enc`, encrypted with a key only the author holds. The
app does not need it: with no master key, Rails reads that file as empty and takes the session
secret from `SECRET_KEY_BASE` or, when that is unset, from the file generated into the volume on the
first start (and, on the sync server backend in section 9, the `ACTIVE_RECORD_ENCRYPTION_*` values
from the environment). A master key that is *present but wrong* is a different case — Rails
tries to decrypt the file, fails, and the boot crashes with `ActiveSupport::MessageEncryptor::InvalidMessage`.
So leave it unset. The only reason to set it is if you have deleted `config/credentials.yml.enc` and
generated your own with `bin/rails credentials:edit`, in which case it is your key and your file.

## 9. Advanced (a work in progress)

Sections 1 to 8 install the `share` backend, and it is the one to use. This section collects the
other ways to run Tinkerex. **Each is still a work in progress**: the steps are rougher than the
rest of this page — the sync server is built from source, and neither the s3 backend nor Postgres
has a template — and they may change from one release to the next. Reach for one only when a folder
cannot do what you need.

### Your own S3 bucket instead of a folder

The `s3` backend indexes an S3-compatible bucket (SeaweedFS, MinIO, R2, AWS) the same way: the
object is the truth, no versions, current state only. There is no template for it; the recipe is a
small overlay, because the image defaults to the share backend and `docker-compose.yml` binds the
`/library` folder. Save this as `docker-compose.s3.yml`, put the five `LIBRARY_S3_*` values in
`.env`, and start with `-f docker-compose.yml -f docker-compose.s3.yml`:

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

As with a folder, every account indexes the same bucket, so `REGISTRATION=open` is refused at boot
here too, and deleted files move to a `.trash/` in the bucket that `LIBRARY_TRASH_DAYS` empties. The
sweep that files a project's loose files right after an upload moves at most 5 on this backend
(`PROJECT_ORGANIZE_EAGER_MAX_MOVES`, 25 on a folder); the 15-minute sweep files the rest.

### The sync server (chunk_remote)

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

In `.env`, fill in the block under "Work in progress: the sync server":

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

The sync server image is not yet pulled by the overlay — it is built from the checkout — so this
path still needs the clone above. Then start with both files:

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
nothing you uploaded is ever pruned. `REGISTRATION=open` is allowed here, and only here.

To update, `git pull` in `../tinkerex-sync` as well, and add `--build` to the command above.

**Backups.** The sync server keeps its database and every chunk in the `tinkerex_sync_storage`
volume, mounted at `/rails/host/storage` in the `sync` container; on this backend that volume takes
the place of the library folder in section 6. Take the same `.backup` against
`/rails/host/storage/production.sqlite3` in the `sync` container plus a copy of its `chunk-store/`
directory — or stop the stack and copy the whole volume.

### Postgres instead of SQLite

Not templated: the compose files run SQLite, and nothing here starts a Postgres server for you.
Setting `DATABASE_URL` to a `postgres://` URL switches every database to Postgres; the cache, queue
and cable databases are derived from it by name and must already exist.

### Reference: the advanced variables

The same columns as section 7. *compose* marks a variable only `docker compose` reads, *sync* one
only the sync server reads.

| variable | required? | default | what it does |
|---|---|---|---|
| **The s3 backend** | | | |
| `LIBRARY_S3_BUCKET`, `LIBRARY_S3_ACCESS_KEY_ID`, `LIBRARY_S3_SECRET_ACCESS_KEY` | s3 | — | The bucket and credentials. The boot checks they are present; it never touches the network. |
| `LIBRARY_S3_ENDPOINT` | for non-AWS | — | The endpoint URL (SeaweedFS, MinIO, R2). Path-style requests are used. |
| `LIBRARY_S3_REGION` | no | `auto` | |
| `LIBRARY_S3_PREFIX` | no | — (the whole bucket) | A key prefix that is the library's root, e.g. `library/`. |
| **The sync server** | | | |
| `CHUNK_REMOTE_URL` | chunk_remote, *set by compose* (`http://sync:3000`) | — | The sync server's address as seen from the app. |
| `SYNC_PUBLIC_URL` | chunk_remote | — | The sync server's address as seen from your other devices, scheme included; the desktop app is handed it when it signs in. With compose, `http://<this host>:3001` or the name a reverse proxy in front of that port answers to. `CHUNK_REMOTE_URL` is the same server as seen from the app, a name only the app's own network resolves, so the two differ on purpose. The boot refuses chunk_remote without it. |
| `SYNC_ADMIN_TOKEN` | chunk_remote | — | The operator credential the app uses to create each new account's library on the sync server. **Identical on both services.** `openssl rand -hex 32`. |
| `ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY` | chunk_remote | — (read from credentials, which a stranger's image cannot decrypt) | Encrypts each account's sync credential at rest. 32+ characters; **keep it**. |
| `ACTIVE_RECORD_ENCRYPTION_DETERMINISTIC_KEY` | chunk_remote | — | Same; the key for deterministic encryption. |
| `ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT` | chunk_remote | — | Same; the salt the two keys are derived with. |
| `TINKEREX_SYNC_PATH` | chunk_remote, *compose* | `../tinkerex-sync` | Path to a checkout of `chaim354/tinkerex-sync`, the build context for the sync server. |
| `TINKEREX_SYNC_PORT` | no, *compose* | `3001` | The host port the sync server is published on; what devices connect to. |
| `SYNC_SECRET_KEY_BASE` | chunk_remote, *compose* | — | Becomes the sync server's own `SECRET_KEY_BASE`. `openssl rand -hex 64`; distinct from the app's. |
| `SYNC_SCHEDULER` | chunk_remote, *set by compose* (`"true"`) | — | The sync server's housekeeping: expired pending commits reaped hourly, orphaned chunk bytes weekly, retention that keeps every version. The app never reads it. |
| `STORAGE_BACKEND` | *sync*, set by the overlay | — | The sync server's chunk store: `local` (a directory in its volume) or `s3`. The overlay sets `local`. |
| `CHUNK_LOCAL_DIR` | *sync* | `/rails/host/storage/chunk-store` | Where the local chunk store lives, inside the `tinkerex_sync_storage` volume. |
| `CHUNK_PUBLIC_URL` | *sync*, no | the request's own host | The base URL the sync server writes into chunk download links. Unset, each client gets links on the host it connected through, which is right for this layout; set it only when a reverse proxy in front changes the public address. |
| **Postgres instead of SQLite** | | | |
| `DATABASE_URL` | no | — (SQLite in the volume) | A `postgres://` URL switches every database to Postgres. |
| `DB_SSLMODE` | no | `prefer` for a localhost URL, else `require` | libpq's sslmode. |
| `DB_SSLROOTCERT` | no | — | Path to the CA certificate, when the server's certificate needs one. |
| `SOLID_CACHE_DATABASE_URL`, `SOLID_QUEUE_DATABASE_URL`, `SOLID_CABLE_DATABASE_URL` | no | `DATABASE_URL` with `_cache`, `_queue`, `_cable` appended to the database name | The three Solid databases. The derived databases must exist. |

## 10. Where the author's own deploy recipe lives

`docs/DEPLOY.md` describes how the author deploys this app — Kamal from a Mac, secrets from
1Password, three Unraid destinations and an OVH box. It is the record of those deployments, not an
install guide, and nothing in it is needed to run the compose files above.
