# I — Self-host in one file: design

**Date:** 2026-10-14 · **Status:** design, awaiting a plan · **Source:**
`docs/superpowers/plans/2026-10-14-i-install-and-onboarding-handoff.md` §2 and the owner's decisions
of 2026-10-14 (below). Builds on B (`2026-10-13-b-accounts-that-work-design.md`: the first account is
the owner, sign-ups closed) and C (`2026-10-13-c-install-path-design.md`: the compose files, the env
table, `docs/INSTALL.md`). Facts cite `main` at c68ba86f.

## The problem

C made the app installable by a stranger with Docker on a Linux box. The path it left has five stops
before the first account, and each one is a place a careful person stops:

1. **Clone the repository**, to get a compose file and an env template.
2. **Hand-edit three values in `.env`**: a session secret generated with `openssl`, the folder path,
   and a host name (`.env.example:8-20`). A missing `.env` is a boot error (`docker-compose.yml:15`
   lists it as required).
3. **`chown -R 1000:1000` the folder** (`docs/INSTALL.md:40-44`), because the image is hard-wired to
   uid 1000 (`Dockerfile:174-176`) and the boot probes the folder by writing to it
   (`lib/library_backend_check.rb`, `writable!`). Rewriting the ownership of a NAS folder is the step
   the handoff flagged as the one most likely to stop someone.
4. **Build the image from source** for several minutes (`docker-compose.yml:11-12`, `build: .`),
   because every ghcr package is private — measured today: an anonymous pull of
   `ghcr.io/chaim354/tinkerex:latest` answers 403.
5. **The Tools gallery is behind a profile** that needs a sibling checkout of `tinkerex-addons` and
   builds two more images (`docker-compose.yml:27-45`). The box generator is the single most-used
   feature of the real library, and a stranger's gallery is empty.

Docker Desktop on a Mac or Windows machine was not a target at all: the guide says "a Linux box,
amd64" (`docs/INSTALL.md:13`), the image is amd64 only (`config/deploy.yml:224-225`, `arch: amd64`),
and nothing was ever run there.

## Decisions

The owner's, 2026-10-14:

- **Share only.** The simple path is the `share` backend: one folder. The sync-server overlay
  (`docker-compose.chunk_remote.yml`) stays as C left it and is not part of this work.
- **The images go public.** The owner flips four ghcr packages — `tinkerex`, `boxes-sidecar`,
  `openscad-sidecar`, `tinkerex-addons` — so the quick start pulls. Package visibility is per
  package and independent of the repository's; it is one-way.
- **The quick start is one compose file that includes the Tools gallery.** No profile, no sibling
  checkout, no `.env` unless something is being overridden.
- **It runs under Docker Desktop on Mac and Windows** as well as Docker Engine on Linux.
- **The main image is multi-arch, amd64 and arm64**, so Apple silicon runs it natively.
- **Tags are `latest`** in the quick start, which Kamal already pushes on every deploy. Pinning
  waits for releases to exist.
- **Zero required settings.** Each of the four hand-set values is removed by a code change
  (section 3), not by a wizard: the secret is generated and kept, the backend and path are image
  defaults, the host name is required only with mail, and the uid is taken from `PUID`/`PGID`.

## 1. What a stranger does

1. Install Docker Desktop (Mac, Windows) or Docker Engine with the Compose plugin (Linux).
2. Make a folder and download one file into it: `docker-compose.yml`.
3. `docker compose up -d`. Four images pull. Nothing to generate, edit or chown.
4. Open `http://localhost:8080` and create the first account. It is the owner; sign-ups close.
5. A `library/` folder has appeared beside the compose file. Files dropped there appear within
   15 minutes or on Rescan; uploads land in it; Tools works.

To use an existing folder: one line in an optional `.env`, `LIBRARY_HOST_PATH=/path/to/files`.
To run as a particular user on Linux: `PUID` and `PGID` in the same file. Everything else is the
existing env table, all optional.

## 2. The compose file

`docker-compose.yml` becomes:

```yaml
services:
  web:
    image: ${TINKEREX_IMAGE:-ghcr.io/chaim354/tinkerex:latest}
    ports:
      - "${TINKEREX_PORT:-8080}:80"
    env_file:
      - path: .env
        required: false
    environment:
      PUID: ${PUID:-1000}
      PGID: ${PGID:-1000}
      BOXES_SIDECAR_URL: http://boxes:8000
      OPENSCAD_SIDECAR_URL: http://openscad:8000
      ADDON_SOURCE_URL: http://addons
    volumes:
      - tinkerex_storage:/rails/storage
      - ${LIBRARY_HOST_PATH:-./library}:/library
    healthcheck:            # unchanged: curl /up, 30s, start_period 90s
    restart: unless-stopped
  boxes:
    image: ghcr.io/chaim354/boxes-sidecar:latest
    restart: unless-stopped
  openscad:
    image: ghcr.io/chaim354/openscad-sidecar:latest
    platform: linux/amd64   # the image is x86-only (an AppImage); Docker Desktop emulates it
    volumes:
      - openscad_cache:/cache
    restart: unless-stopped
  addons:
    image: ghcr.io/chaim354/tinkerex-addons:latest
    restart: unless-stopped
volumes:
  tinkerex_storage: {}
  openscad_cache: {}
```

What changed and why:

- **No `build:` on any service.** With both `image:` and `build:` present, Compose builds when the
  image is not in the local cache instead of pulling it, which is exactly the slow path being
  removed. Building moves to an overlay, `docker-compose.build.yml`, that restores `build:` for all
  four services (`.`, `sidecar/boxes`, `sidecar/openscad`, `${TINKEREX_ADDONS_PATH:-../tinkerex-addons}`)
  with `:local` image names. It is the path for arm64 Linux, for a box with no registry access, and
  for developers; it needs a clone and the sibling checkout, and the guide says so in one paragraph.
- **`env_file` is optional** (`required: false`, Compose 2.24+, the version C already requires for
  `!override`). Today a missing `.env` is a boot error.
- **`LIBRARY_BACKEND` and `LIBRARY_PATH` leave the file**: they are image defaults now (section 3).
  The sync overlay still sets both on `web`, and a Compose `environment` merge works the same
  whether or not the base names them.
- **The Tools URLs are set here**, not as image defaults: the image must not assume sidecars
  exist, because the registry greys out a tool whose URL is blank, and a Kamal destination names
  its own. The three names are the same wiring the Kamal accessories use
  (`config/deploy.yml:143-156`, ports 8000 and 80).
- **`openscad` is pinned to `linux/amd64`.** Without the pin, Compose on an arm64 host fails that
  one service with "no matching manifest". With it, Docker Desktop runs it under emulation; a Linux
  arm64 host without emulation still fails it, and the other three come up — documented, not fixed.
- **The library default is `./library`**, a folder beside the compose file. On Linux, Docker creates
  a missing bind-mount source as root, which section 3 handles.

## 3. Four image changes

### 3.1 Backend and path are image defaults

The Dockerfile's final stage sets `ENV LIBRARY_BACKEND="share" LIBRARY_PATH="/library"`. Every
Kamal destination sets `LIBRARY_BACKEND` explicitly (`config/deploy*.yml`), the share destination
sets the path, and the two overlays set both, so nothing deployed changes. The production guard
`LibraryBackendCheck.required_in_production!` keeps its purpose unchanged: it refuses an explicit
blank, which is still the shape of a misconfigured destination. `test/deploy_hygiene_test.rb`'s
"every destination carries the knobs its resolved LIBRARY_BACKEND requires" treats an unset
backend as a problem; that stays deliberately stricter than the image, because a destination should
say its backend, and every destination does.

`check_share!`'s "does not exist" message names the mount: the folder is bound to `/library` with
`-v /path/to/files:/library`, or `LIBRARY_HOST_PATH` with the compose file. A bare `docker run`
with no mount keeps refusing — an unmounted `/library` inside the container would take uploads
into the container's own filesystem, which reads as data loss on the next recreate.

### 3.2 The session secret is generated and kept

`Tinkerex::SecretKeyBase.resolve` (new, `lib/tinkerex/`) answers in this order:

1. `ENV["SECRET_KEY_BASE"]` when present and non-blank. A blank value counts as unset, because
   `.env.example` has shipped `SECRET_KEY_BASE=` as a line to fill in and an old `.env` may still
   carry it.
2. `Rails.application.credentials.secret_key_base` when present — the author's deployments, which
   carry the master key.
3. `storage/secret_key_base`, inside the persistent volume: read when it exists and is non-blank;
   otherwise generated (`SecureRandom.hex(64)`), written atomically with mode 0600, and announced
   with one boot log line that names the file and says `SECRET_KEY_BASE` overrides it.

`config/environments/production.rb` assigns the result to `config.secret_key_base`. Rails 8.1.3.1's
setter takes any non-blank String (`railties/lib/rails/application/configuration.rb:535-545`), and
Devise derives its own key from it (`config/initializers/devise.rb:17` is commented out), so no
second secret exists. The resolver is skipped when `SECRET_KEY_BASE_DUMMY` is set — the asset
precompile at image build time, which must not write a secret into the image layer. Test and
development are untouched: Rails already generates a local secret there.

Failure is loud: a storage directory that cannot be written raises a clear error naming the volume
and the override, never a silent fallback to a per-boot random value that signs everyone out on
restart. The file lives beside `production.sqlite3` on purpose: whoever holds the volume holds the
database already, and a volume restore restores sessions with it. The backup section of the guide
names the file.

### 3.3 The host name is needed only for mail

`APP_HOST` feeds three things: mail links (`production.rb:117`), the SMTP HELO default and the
default sender (`lib/tinkerex/mail_settings.rb:20,34`). None is reached while `SMTP_ADDRESS` is
unset. `Tinkerex::MailSettings.validate!` (new) refuses the boot when `SMTP_ADDRESS` is set and
`APP_HOST` is blank, with a message saying links in mail need the host people reach the server at;
it is wired beside the existing boot validations (`config/initializers/registration.rb` is the
pattern). The `APP_HOST-IS-NOT-SET.invalid` placeholder stays as the no-mail default and is never
rendered, because no mail is sent. The env row changes from "for mail links" to "required when
`SMTP_ADDRESS` is set".

### 3.4 The container takes PUID and PGID

Today the image switches to uid 1000 at build time (`Dockerfile:176`, `USER 1000:1000`), so the
folder and the app-data volume must both be writable by that uid, and a Docker-created
`./library` on Linux is root-owned and refuses the boot. The change:

- **The Dockerfile drops `USER 1000:1000`.** The `rails` user and group (1000) are still created,
  the `COPY --chown` lines stay, and the container starts as root.
- **`bin/docker-entrypoint` drops privileges itself.** Running as root it reads `PUID` and `PGID`
  (default 1000 and 1000, integers only), makes the app's own writable directories the app user's —
  `/rails/storage`, `/rails/tmp`, `/rails/log`, `/home/rails` — with a recursive `chown` only when
  a directory's owner differs from the requested uid (first boot with a non-default uid, or a later
  change; zero cost on the common path), exports `HOME=/home/rails`, and re-executes itself with
  `setpriv --reuid=$PUID --regid=$PGID --clear-groups`. `setpriv` is util-linux and already in the
  base image (Debian trixie, measured); no package is added. The unprivileged half is today's
  script: `db:prepare` when the command is the server, then `exec`.
- **Started with `--user`, it skips all of that.** A non-root entrypoint cannot chown or setpriv,
  so it runs as given, which is today's behaviour and what `user:` in a compose file still means.
- **The library folder is never chowned**, with one narrow exception: a library folder that is
  empty AND owned by root is one Docker just auto-created for a missing bind-mount source, and it
  becomes the app user's. A folder with anything in it, or owned by anyone else, is only probed.
- **`docker compose exec` recipes go through the entrypoint.** `docker exec` runs as the image's
  user, now root, so a console task that creates files would leave them root-owned. The guide's
  recipes become `docker compose exec web bin/docker-entrypoint bin/rails 'tinkerex:owner[…]'`,
  which drops to the same uid as the server. The Kamal destinations set no `user` and name no
  `PUID`, so they start as root and drop to 1000:1000 — the same effective uid as today.

What this buys: a Linux user sets `PUID=$(id -u)` to match an existing folder, or lets a fresh
install adopt its auto-created one; Unraid sets 99:100 so uploads land on the share as
`nobody:users` instead of an unknown uid 1000, and its appdata needs no `chown` beforehand; on
Docker Desktop, where bind mounts are writable by any container uid, the defaults work untouched.

### 3.5 The published image is multi-arch

`config/deploy.yml`'s builder becomes `arch: [amd64, arm64]`. Kamal 2.12 builds both with buildx
and pushes one manifest under `:latest` and the sha tag; the Dockerfile already builds for arm64
(every stage is arch-neutral or picks by `TARGETARCH`, with the F3D stage leaving a README on
arm64). The cost is build time on the author's Mac, where the amd64 half is the emulated one today
and the arm64 half becomes the native one. The plan checks the pushed manifest lists both
platforms, and the Mac run (section 6) pulls the arm64 half.

## 4. Mac, Windows, Linux

- **Mac (Docker Desktop).** Apple silicon pulls the arm64 image natively; `openscad` runs under
  Rosetta from its amd64 pin. Bind mounts need the folder under a shared path, which the default
  settings cover for the home directory. File ownership is not a concern: Docker Desktop presents
  bind mounts as writable by the container's user.
- **Windows (Docker Desktop, WSL2 backend).** The same file from PowerShell. `./library` on the
  Windows drive works; a large library is faster inside the WSL2 filesystem, said in one sentence.
  Windows on ARM is out of scope.
- **Linux (Docker Engine).** `PUID`/`PGID` as above; the auto-created folder is adopted; an
  existing folder is probed. arm64 Linux runs the main image natively and loses `openscad` unless
  emulation is installed.

## 5. Docs and the template

- **`README.md`** quick start becomes section 1's five steps. The repositories table and the rest
  stay.
- **`docs/INSTALL.md`** sections 1–3 are rewritten around the compose file: what you need (Docker
  Desktop or Engine + Compose 2.24), the quick start, pointing it at your own folder, `PUID`/`PGID`,
  the Tools gallery being included, the build-from-source overlay in one paragraph, the arm64
  notes. Section 4 says `APP_HOST` comes with SMTP. Section 6 (updating) becomes
  `docker compose pull && docker compose up -d`. Section 7 (backups) names the secret file. The
  env table gains `PUID` and `PGID`, and changes `SECRET_KEY_BASE` (optional; generated and kept in
  the volume), `APP_HOST` (required with SMTP), `LIBRARY_BACKEND`/`LIBRARY_PATH` (image defaults),
  `TINKEREX_IMAGE` (defaults to the ghcr image) and `TINKEREX_ADDONS_PATH` (build overlay only).
  `test/install_docs_test.rb` enforces the rows.
- **`.env.example`** has nothing required: every line is a commented override, grouped as the
  folder, the port, the uid, mail, the sync server, advanced.
- **`unraid/tinkerex.xml`** gains `PUID` and `PGID` at 99 and 100, moves `SECRET_KEY_BASE` and
  `APP_HOST` to advanced and not required with descriptions saying why, and drops the comment
  asking for a `chown` of appdata. The sidecars are not in the template (one container per CA
  template); the gallery is empty there and says so, as today.
- The landing's "Install it yourself" link is unchanged.

## 6. Verification and guards

**Real runs, recorded in the arc with their results:**

- **This Mac, Docker Desktop:** the four-service stack from the compose file over a locally built
  arm64 image (`docker buildx build --platform linux/arm64 --load`), then poll `/up`, sign up
  through the real form, assert the second sign-up answers 403, upload a file, confirm it is in
  `./library`, open Tools and save a box, confirm the OpenSCAD card is live under emulation.
- **The Linux Docker host (192.168.1.146):** the same stack over a locally built amd64 image via
  the build overlay, three uid cases: the default with an auto-created `./library` (adopted,
  boots); `PUID=$(id -u)` against an existing folder owned by that uid (boots, an upload lands
  owned by it); a non-empty folder owned by another uid with the wrong `PUID` (refused by the probe,
  never chowned).
- **The pushed manifest** after the next deploy lists `linux/amd64` and `linux/arm64`.
- **Windows** gets no run: there is no Windows box. The guide says the Windows path is untested.

**Tests, each mutation-checked:**

- `Tinkerex::SecretKeyBase`: ENV wins; a blank ENV is ignored; credentials win over the file; the
  file is generated once with mode 0600 and reused; an unwritable directory raises with the
  message; `SECRET_KEY_BASE_DUMMY` skips.
- `Tinkerex::MailSettings.validate!`: SMTP without a host refuses; with a host passes; no SMTP passes.
- `bin/docker-entrypoint`, driven under `bash` with a stub `PATH` (`id`, `setpriv`, `chown` record
  their arguments): non-root runs the command straight; root calls `setpriv` with the requested
  ids and the original arguments; `chown` names exactly the app directories whose owner differs
  and never a non-empty library; `db:prepare` runs only for the server command.
- `test/compose_hygiene_test.rb` (new): `docker-compose.yml` has no `build:`, every image is on
  ghcr, `env_file` is optional, `openscad` is pinned to amd64, the three Tools URLs are set, the
  two volumes are named; the build overlay restores `build:` for all four services.
- The existing `install_docs_test.rb` and `deploy_hygiene_test.rb` keep passing; the latter's
  "no committed destination opens registration on a single-library backend" and secret checks are
  untouched.

## 7. Out of scope

The sync-server overlay (still builds from a sibling checkout; its own pass once that image is
public), the S3 overlay, the desktop client, the onboarding copy fixes in the handoff's §3, pinned
tags, a Windows run, `openscad` on arm64 Linux, and repository visibility. Until the repository is
public the compose file cannot be downloaded from GitHub by a stranger; the images alone are
enough to run it, and the file can be handed over by any other means.

## 8. The owner's items

- Make the four ghcr packages public (`tinkerex`, `boxes-sidecar`, `openscad-sidecar`,
  `tinkerex-addons`), one at a time on each package's GitHub page. Nothing in the plan blocks on
  it: both verification runs use locally built images through the build overlay.
- The first deploy after this merges builds multi-arch; expect it to be slower.
