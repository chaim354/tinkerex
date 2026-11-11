# Tinkerex

A self-hosted library for a maker's files — 3D models (STL, 3MF, OBJ), CAD (STEP, IGES, native
formats), laser files (LightBurn, SVG, DXF), PDFs, Gerbers, images — with thumbnails rendered on the
server, a 3D viewer in the browser, projects with tasks, a build log and a bill of materials,
inventory, and a Tools gallery of add-ons that save their output straight into the library.

**Try it first:** the public demo at <https://tinkerex.com> signs you in with one click, with nothing
to install.

## Status

It runs on real hardware, every day, for its author. It holds your files in a **folder you point it
at** — a directory on the box, or a NAS share — as plain files you can edit with anything else, and
the install below sets it up. It is open source under the Apache License 2.0, and the images are
published on ghcr.io under `chaim354`.

## Quick start

You need Docker: Docker Desktop on a Mac or Windows machine, or Docker Engine with the Compose
plugin on Linux.

1. Download [`docker-compose.yml`](docker-compose.yml) into the folder that holds your files, or
   into a new, empty folder. That folder becomes your library.
2. In that folder, run `docker compose up -d --pull always`. The first start takes a few minutes;
   `--pull always` fetches the newest images even if Docker kept older ones from an earlier try.
3. Open <http://localhost:8080> and create your account. The first account is the owner and admin,
   and it needs no email.
4. Confirm the folder, or pick one inside it, then take the short welcome tour or skip it.

After the first account nobody else can sign up: the owner adds people under **Settings → Users**.
To keep the compose file somewhere else, `LIBRARY_HOST_PATH=/path/to/files` in a `.env` beside it
names the folder instead, and a network share on another computer works too. The full guide, with
every setting you can change, is **[`docs/INSTALL.md`](docs/INSTALL.md)**.

## Where files come from

The folder you pointed it at. It is indexed on start, every 15 minutes, and on the Rescan button;
uploads in the browser land in it as ordinary files; deletions move files to a `.trash/` folder inside
it; folders under `Projects/` become projects. The app is a view of the folder, not a copy of it.

## The Tools gallery

Add-ons — a box generator and an OpenSCAD editor — are the other three containers the compose file
starts, so the gallery is live from the first start. They run as separate processes reached over
HTTP (the two tools are GPL-licensed and are never linked into the app).

## Updating and backups

Update with `docker compose pull && docker compose up -d`; the database migrates on start. Back up
the `tinkerex_storage` volume's database with SQLite's `.backup` (never copy the live file) and your
folder with anything. Both recipes are in the guide.

## The repositories

| repository | what it is | licence |
|---|---|---|
| `chaim354/tinkerex` (this one) | The web app: library, previews, projects, inventory, Tools. | Apache-2.0 |
| `chaim354/tinkerex-addons` | The addon bundles the Tools gallery serves. | MIT |

## Developing

`bin/setup` prepares a development checkout. `bin/ci` runs every gate, and `bin/ci --list` names
them. `CLAUDE.md` is the architecture: the port between the app and whatever holds the bytes, the
data model, and the invariants that a change must not undo.

## Security

Found a vulnerability? Report it privately through the repository's Security tab, as
[`SECURITY.md`](SECURITY.md) describes, rather than in a public issue.

## Licence

Copyright 2026 Charles Schwartz. Licensed under the Apache License, Version 2.0 (`LICENSE`); you may
not use this repository except in compliance with it. The addon bundles (`tinkerex-addons`) are MIT.
Every dependency shipped is permissive as well (`CLAUDE.md` §9); the two GPL sidecars are separate
images invoked over HTTP, never linked.
