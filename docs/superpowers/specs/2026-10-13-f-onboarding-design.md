# F — Onboarding and in-app explanation: design

**Date:** 2026-10-13 · **Status:** design, executed the same day (plan:
`docs/superpowers/plans/2026-10-13-f-onboarding.md`) · **Source:** `docs/AUDIT-2026-10-12-readiness.md`
§2.3 ("a stranger's first hour") and `docs/user-stories.md`'s `rough` rows 1.3, 2.11, 4.7.

## The problem

A maker who is not the author signs in to an empty library and is told "No files yet. Upload one."
Nothing says that the folder on the NAS is the library, that it is scanned every fifteen minutes,
that a folder under `Projects/` becomes a project, or that loose files at a project's root are
filed into type folders by a sweep — the app moves their files and explains itself only afterwards.
The Tools page tells them to set environment variables. When the share is unmounted the pages
render from the catalog with grey tiles and no word about why. There is no help page, no way to
rename or move a file from the browser, a failed preview looks like a file type with no preview,
and the shell has no skip link.

## Decisions

- **The empty states say where files come from, per backend.** One partial, branching on the
  port's capabilities: a scannable library names the folder-on-the-server path and the Rescan
  action; a syncable one names the desktop app; every backend names Upload. Home, Files and
  Projects use it. Home's empty state becomes a three-step getting-started panel (files in,
  `Projects/` folders become projects and loose files get filed, Tools) that disappears on its own
  once a file exists — no cookie, no dismissal state to store.
- **Intake is explained before it moves anything.** The Projects empty state says what a
  `Projects/` folder becomes and that root files are filed; the Files page says the same, in one
  line, at the top of any project folder; the Help page carries the full account with a link to
  the Filing rules. Nothing about the sweep's behaviour changes.
- **A Help page at `/help`**, session-authed, server-rendered, reachable from the rail's foot (a
  Help button beside Settings), the getting-started panel and the Tools empty state. Factual and
  short: the library and the three backends in plain words, scan cadence and Rescan, upload, trash
  and restore; projects, discovery, filing, archiving, publishing; models and shelves; tools and
  why some are missing; accounts (owner, closed sign-ups, mail, the console doors in the operator's
  words); where the source and the issues live.
- **Operator vocabulary leaves user-facing pages.** The Tools empty state and the greyed-card
  reason speak to the maker ("No tools are installed on this server", "needs the openscad service,
  which this server doesn't run"); the environment-variable names move behind a collapsed "for the
  person running this server" line and into Help and `docs/INSTALL.md`.
- **An unreachable library is said, not hidden.** `Current.library_unreachable` (a
  `CurrentAttributes` flag) is set exactly where the port raised `FetchError` and was rescued into
  degraded output — the thumbnail map — and the layout renders one banner when it is set, naming
  the likely cause per backend. The banner never probes the port itself: a page that did not touch
  the port says nothing, so no request pays a network round trip for the sentence.
- **Rename and Move to folder from the browser**, for files and folders, as two member routes on
  files backed by `Maker::MoveNode` (which already takes a new parent and an optional new name).
  A collision answers "a file named X is already there", a bad name answers the port's own
  reason, a backend that refuses directory moves (s3) answers the 422 the controller already maps.
  Inside a git working tree the actions are hidden: bytes git owns do not go through the port
  (`docs/invariants/git-editing.md`).
- **A failed preview says so**: the tile keeps the type icon and gains a title and a mark, so
  "no preview for this type" and "the render failed" stop looking identical.
- **A skip link** is the first thing in the body, targeting `main#main`.

## Out of scope

Story 4.6 (a fresh install re-mints node ids, losing annotations) — a data-model change that needs
its own spec. A web UI for collections and items. Per-user onboarding state in the database.

## Invariants this adds (CLAUDE.md §14d candidate, one line)

`Current.library_unreachable` is set only where a `FetchError` was rescued into degraded output;
the banner reads it and never probes the port.
