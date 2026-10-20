# Tinkerex

A self-hosted library for a maker's files — 3D models (STL, 3MF, OBJ), CAD (STEP, IGES, native
formats), laser files (LightBurn, SVG, DXF), PDFs, Gerbers, images — with thumbnails rendered on the
server, a 3D viewer in the browser, projects with tasks, a build log and a bill of materials,
inventory, and a Tools gallery of add-ons that save their output straight into the library. The
desktop sync client lives in `chaim354/tinkerex-client` and is still being brought up.

## Status

It runs on real hardware, every day, for its author. There are three ways to hold the files, chosen
per deployment: a **folder you point it at** (a NAS share, a directory on the box), **your own S3
bucket**, or the **sync server** (`chaim354/tinkerex-sync`), which adds per-account libraries,
versions and restore, and is what the desktop client syncs against. The first two keep your files as
plain files you can edit with anything else. It is open source under the Apache License 2.0, and the
images are published on ghcr.io under `chaim354`.

## Quick start

You need Docker: Docker Desktop on a Mac or Windows machine, or Docker Engine with the Compose
plugin on Linux. Download [`docker-compose.yml`](docker-compose.yml) into the folder that holds your
files, or into an empty folder, and in that folder:

```sh
docker compose up -d
```

Open `http://localhost:8080`, create the first account, then confirm the folder, or pick one inside
it. Nothing to generate, edit or chown first; the full guide, with every setting you can change, is
**[`docs/INSTALL.md`](docs/INSTALL.md)**.

## First run

The first account you create is the owner: it is confirmed on the spot, without a mail server, and
sign-ups close behind it. Later accounts come from the console, as section 4 of the guide shows; open
sign-ups exist only with the sync server, where each account has its own library. The folder the
compose file is in is your library, files and all. To keep the file somewhere else,
`LIBRARY_HOST_PATH=/path/to/files` in a `.env` beside it names the folder instead. Files on another
computer's network share work too: the compose file carries the lines for it, commented out, and the
guide's section 3 walks through them.

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
| `chaim354/tinkerex-sync` | The sync server: chunks, versions, the changelog; a single Rust binary. | MIT |
| `chaim354/tinkerex-client` | The desktop client: the mounts and the sync engine, in Rust. | Apache-2.0 |
| `chaim354/tinkerex-addons` | The addon bundles the Tools gallery serves. | MIT |

## Developing

`bin/setup` prepares a development checkout. `bin/ci` runs every gate, and `bin/ci --list` names
them; the suite runs once per library backend — `test` (share), `test-s3` and `test-chunk-remote`,
the last against a sibling checkout of `tinkerex-sync` — and the three must report identical run
counts. `CLAUDE.md` is the architecture: the port between the app and whatever holds the bytes, the
data model, and the invariants that a change must not undo.

## Licence

Copyright 2026 Charles Schwartz. Licensed under the Apache License, Version 2.0 (`LICENSE`); you may
not use this repository except in compliance with it. The sibling repositories are MIT
(`tinkerex-sync`, `tinkerex-addons`) and Apache-2.0 (`tinkerex-client`). Every dependency shipped
is permissive as well (`CLAUDE.md` §9); the two GPL sidecars are separate images invoked over HTTP,
never linked.
