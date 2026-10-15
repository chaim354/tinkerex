# J — The compose file's folder is the library, and the app runs as its owner: design

**Date:** 2026-10-15 · **Status:** design, awaiting a plan · **Source:** the owner's question of
2026-10-15 ("how can I make connecting it to a folder already on the system simpler") and the two
answers chosen ("do both"), plus one judgment call confirmed below. Builds directly on I
(`2026-10-14-i-simple-self-host-design.md`, merged as #406 and deployed everywhere). Facts cite
`main` at fd498356.

## The problem

After I, a stranger who already has a folder of files still pays three things to use it:

1. **A second file and a variable name.** The compose file mounts `${LIBRARY_HOST_PATH:-./library}`
   (`docker-compose.yml:23`), so an existing folder means knowing to create `.env` beside the
   compose file, knowing the variable's name, and running `docker compose up -d` a second time.
   The quick start cannot hide that step today.
2. **On Linux, the folder's owner.** The entrypoint defaults `PUID`/`PGID` to 1000
   (`bin/docker-entrypoint`), so a folder owned by anyone else needs `id -u`, `id -g` and two more
   `.env` lines, or the probe refuses the boot.
3. **Nothing on screen says which folder.** `app/views/shared/_where_files_come_from.html.erb:31-37`
   says "the library folder on the server" without naming it — the handoff's §3.1, still open.

## Decisions

The owner's, 2026-10-15:

- **The directory the compose file sits in is the library.** The instruction for an existing folder
  becomes "put `docker-compose.yml` in the folder that holds your files and run `docker compose up
  -d` there", and for a new user "in an empty folder" — one sentence for both cases, no `.env`.
- **The foot-gun is accepted.** Running the file from `~/Downloads` makes Downloads the library,
  with a `.trash/` inside it. The guide says so in one sentence, and the first screen names the
  folder (below) so the mistake is visible at once.
- **The compose file shows up as a file in the library root.** It is in the folder, so it is in the
  folder. No skip-list entry: a root-only skip would have to be threaded through the scanner, the
  share adapter's write guard and seven name-check call sites, and §14b records four bugs that came
  from exactly that kind of addition. `.env` is a dot-file the display already hides.
- **When `PUID` is unset, the app runs as the folder's owner.** Explicit `PUID`/`PGID` still win.

## 1. The compose file's folder is the library

`docker-compose.yml` mounts `${LIBRARY_HOST_PATH:-.}:/library`. Compose resolves a relative
source against the compose file's own directory, never the shell's working directory, so
`docker compose -f /some/where/docker-compose.yml up -d` indexes `/some/where` wherever it is run
from. `LIBRARY_HOST_PATH` in `.env` still overrides it, for the person who wants the file in one
place and the library in another.

**The build overlay (`docker-compose.build.yml`) puts the mount back to `./library`.** Compose
merges a service's `volumes` by container path, so an overlay entry `./library:/library` replaces
the base file's `/library` mount and leaves the storage volume alone — checked with
`docker compose config` rather than assumed; `volumes: !override` listing both mounts is the
fallback if the merge does not behave. In a clone "." is the repository, and nobody wants the
repository indexed with a `.trash/` inside it; the `/library/` line in `.gitignore` stays for that
case, and the developer recipe is unchanged.

Nothing else about the folder changes: the app is a view of it, uploads land in it, deletes move
into its `.trash/`, the boot probes it by writing a file, the scan runs every 15 minutes.

## 2. The app says which folder

Compose passes the setting through as **display-only**: `LIBRARY_HOST_PATH: ${LIBRARY_HOST_PATH:-}`
in the `web` service's `environment`. The app reads it in exactly one place, a helper the shared
partial uses, and nothing else — not the port, not the guard, not a path the process opens. Three
states, by what the variable carries:

| `LIBRARY_HOST_PATH` in the container | who sets it that way | the sentence |
|---|---|---|
| absent | the Kamal destinations, any non-compose deployment | today's: "The library folder on the server is your library …" |
| present and empty | the compose file with nothing overridden | "The folder your `docker-compose.yml` is in is your library …" |
| present and non-empty | the compose file with `.env` or the shell setting it | "`<the value, as typed>` is your library …" |

The value is shown as typed because it is what the person typed; a wrong value can only mislead a
sentence, which is the reason it must stay display-only. The rest of the sentence (the 15-minute
scan, Rescan under More actions on the Library page) is unchanged, so the existing assertions in
`test/integration/web/where_files_come_from_test.rb` keep passing in the absent state; the two new
states get their own assertions. The same partial feeds Recent's getting-started panel, the
Library's empty state and the Projects page, so all three say the same thing.

This closes the handoff's §3.1 (`docs/superpowers/plans/2026-10-14-i-install-and-onboarding-handoff.md`).

## 3. Run as the folder's owner

In `bin/docker-entrypoint`, when the container starts as root:

- If `PUID` is unset, and the library folder (`$LIBRARY_PATH`, default `/library`) is a directory
  whose owner uid is **not 0**, `PUID` becomes that uid and `PGID` becomes that folder's gid.
- Otherwise `PUID` defaults to 1000 as today, and so does `PGID`.
- An explicit `PUID` or `PGID` always wins, each on its own; `PUID` set with `PGID` unset keeps
  `PGID` at the inferred or default value exactly as the bullet above decides it.
- Everything after that is unchanged: the app's own directories are made that user's when their
  owner differs, an empty root-owned folder is adopted, the drop happens through `setpriv`, and
  `PUID=0` stays root.

What this buys: a Linux user whose folder is their own needs nothing; an Unraid share owned by
`nobody:users` runs as 99:100 with no fields filled in; a folder on a NAS export whose owner is some
other uid runs as that uid, which is the only uid that can write there anyway. A root-owned
non-empty folder behaves as today (1000, then the probe decides). On Docker Desktop the bind mount
reads as root-owned and writable by anyone, so the default stays 1000 and nothing changes there.

The one boot-time log line says which uid was chosen and why ("PUID inferred from /library's
owner" vs "PUID default" vs "PUID set"), so a surprising uid is one `docker compose logs web` away.

## 4. Docs and the template

- **README** quick start: steps 2 and 3 become "download `docker-compose.yml` into the folder that
  holds your files, or into an empty folder" and "`docker compose up -d` in that folder"; step 5's
  "a `library/` folder has appeared" goes, replaced by "that folder is your library".
- **`docs/INSTALL.md`** §2: the same two sentences, plus the one-sentence warning about Downloads.
  §3: `LIBRARY_HOST_PATH` is now the override for "the file here, the library there"; the
  `PUID`/`PGID` bullet says the default is the folder's owner and when to set them anyway (a
  root-owned folder, or a different user on purpose). §8: the `LIBRARY_HOST_PATH` row moves out of
  "Compose only" (the app now sees it, display-only) and the `PUID`/`PGID` row's default becomes
  "the library folder's owner, else 1000".
- **`.env.example`**: the `LIBRARY_HOST_PATH` comment says the default is the compose file's own
  folder; the `PUID`/`PGID` comment says the default is the folder's owner.
- **`unraid/tinkerex.xml`**: `PUID`/`PGID` become `Display="advanced" Required="false"` with an
  empty default and a description saying the share's owner is used when empty (99/100 on a stock
  share). The library path field is unchanged — Unraid users still pick the share in the form.
- **`lib/library_backend_check.rb`**'s "does not exist" message: "default: the compose file's own
  folder" replaces "default: ./library beside the compose file".
- The handoff's §3.1 gets a "shipped by J" line.

## 5. Verification and guards

**Tests, each mutation-checked:**

- `test/compose_hygiene_test.rb`: the base file mounts `${LIBRARY_HOST_PATH:-.}:/library` and
  carries `LIBRARY_HOST_PATH: ${LIBRARY_HOST_PATH:-}` in `web`'s environment; the build overlay
  overrides `web`'s volumes to `./library` (and keeps the storage volume).
- `test/docker_entrypoint_test.rb`: with `PUID` unset and a library folder owned by the test's own
  uid:gid, `setpriv` is called with those ids and the folder is not chowned; with the folder
  absent, 1000:1000; with `PUID` set and `PGID` unset, no inference runs: `PUID` wins and `PGID`
  is 1000, today's behaviour. The root-owned case still belongs to the Linux run.
- `test/integration/web/where_files_come_from_test.rb`: the three sentences, driven by setting the
  environment variable absent, empty and to a path; the empty-state pages say the same.
- `test/install_docs_test.rb` keeps the env table honest (the `LIBRARY_HOST_PATH` row moves, the
  `PUID`/`PGID` row changes).

**Real runs, recorded in the arc:**

- **This Mac, Docker Desktop:** `docker-compose.yml` copied into a temp folder that already holds
  a few files (and nothing else of the repo), images from the local build; the stack comes up, the
  existing files appear in the Library on the first scan, the compose file itself is listed in the
  root, Recent's panel says "the folder your docker-compose.yml is in", an upload lands beside the
  existing files. Then the build overlay from the clone to confirm "." did not become the library
  there (the clone's `library/` is used).
- **The Linux Docker host:** a folder owned by uid 1500 with files in it and NO `PUID` set: the
  app runs as 1500 (the log line says "inferred"), the files are indexed, a write lands as 1500;
  the same with `PUID=1000` set explicitly: the probe refuses, as today.

## 6. Out of scope

Hiding the compose file from the display (accepted as shown; a display-only root rule would be a
later, separate decision), the sync-server overlay, the S3 overlay, Windows runs, and the two
follow-ups I left (multi-arch Tools images; the ungated reset mail).
