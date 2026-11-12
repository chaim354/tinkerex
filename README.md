# Tinkerex

A self-hosted library for a maker's files — 3D models (STL, 3MF, OBJ), CAD (STEP, IGES, native
formats), laser files (LightBurn, SVG, DXF), PDFs, Gerbers, images — with thumbnails rendered on the
server, a 3D viewer in the browser, projects with tasks, a build log and a bill of materials,
inventory, and a Tools gallery of add-ons that save their output straight into the library.

**Try it first:** the public demo at <https://tinkerex.com> signs you in with one click, with nothing
to install.

## Quick start

You need a computer that stays on (a Mac, a Windows PC or a Linux machine) and about fifteen
minutes. **[The install guide](docs/INSTALL.md#2-quick-start)** walks through each step in more
detail.

1. **Install Docker Desktop**, the free program that runs Tinkerex
   ([Mac](https://docs.docker.com/desktop/setup/install/mac-install/),
   [Windows](https://docs.docker.com/desktop/setup/install/windows-install/)), and open it. On
   Linux, Docker Engine with the Compose plugin.
2. **Choose a folder for your files**: the one that holds them already, or a new, empty one. Not
   your Downloads folder. Tinkerex shows what is in it and saves your uploads into it.
3. **Download the setup file.** Open <https://tinkerex.com/install/compose>, press **Download**, and
   move the `docker-compose.yml` it saves into your folder.
4. **Start it.** Open a terminal in your folder. On a Mac, open Terminal, type `cd` and a space, drag
   the folder onto the window and press Return. On Windows, click the folder's address bar, type
   `powershell` and press Enter. Then paste this line and press Return:

   ```sh
   docker compose up -d --pull always
   ```

   The first start downloads for a few minutes.
5. **Open <http://localhost>** and create your account. The first account is the owner, and it
   needs no email. Nobody else can sign up; you add people under **Settings → Users**.

**From your other computers and phones**, Tinkerex is at `http://<computer's name>.local`. Name the
computer `tinkerex` and the address is **http://tinkerex.local**. On Linux, Tinkerex announces that
name itself. [Where to find and change the name](docs/INSTALL.md#open-it-from-your-other-computers).

**To add files from those computers**, share the folder with your computer's own file sharing. The
others then drag files into it like any network folder: [Mac](https://support.apple.com/guide/mac-help/mh17131/mac),
[Windows](https://support.microsoft.com/help/4092694),
[Linux](https://documentation.ubuntu.com/server/how-to/samba/file-server/). The
[install guide](docs/INSTALL.md#let-your-other-computers-add-files) has the short version of each.

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
