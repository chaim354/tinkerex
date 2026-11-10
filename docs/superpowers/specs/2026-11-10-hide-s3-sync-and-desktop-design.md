# Stop mentioning s3, sync and the desktop client — design

**Date:** 2026-11-10 · **Status:** approved in conversation, awaiting spec review

## Goal

Nothing a person reads names the `s3` backend, the sync server (`chunk_remote`), the sibling repos
`chaim354/tinkerex-sync` and `chaim354/tinkerex-client`, or the desktop client. The product reads as
what most installs are: a library over a folder or a NAS share.

**This is wording only.** No backend, deployment, route, job, test leg or CI gate is removed. The
base Unraid deployment (`chunk_remote`), the Unraid `s3` destination and the public OVH box (`s3`)
keep running on the same code.

## What counts as "a person reads"

| reader | in scope | stays as it is |
|---|---|---|
| a stranger installing | `README.md`, `SECURITY.md`, `docs/INSTALL.md`, `.env.example`, `docker-compose*.yml`, `docs/README.md`, `docs/addon-api-v1.md`, `docs/guides/mcp.md` | |
| anyone using any deployment | the landing page, Help, Settings, the account page, flash and alert text, API error bodies | |
| a user of an **s3** deployment (the public OVH demo is one) | text shown only when the backend is s3: reworded so it names no bucket and no S3 | |
| a user of the **chunk_remote** deployment (the author's own) | | text shown only when `syncable?`: it describes that deployment truthfully |
| the operator | | `docs/guides/DEPLOY.md`, boot refusals, log lines, `bin/` output |
| a developer or agent | | `CLAUDE.md`, `docs/invariants/`, `docs/reference/roads-not-taken.md`, code comments, tests, CI |

## Changes

1. **Install docs.**
   - `docs/INSTALL.md` loses §9's "Your own S3 bucket" and "The sync server" subsections, their
     rows in the advanced-variables table, and every other s3/sync/desktop mention.
   - `README.md` loses the desktop-client sentence, the "S3 bucket or sync server" sentence and
     the two sibling-repo rows. Its developer paragraph says `bin/ci` runs every gate instead of
     naming the s3 and chunk_remote legs.
   - `SECURITY.md` drops the two sibling repos from its scope, and its backend sentence stops
     naming `s3`.
   - `.env.example`, `docker-compose.yml`, `docs/README.md`, `docs/addon-api-v1.md` and
     `docs/guides/mcp.md` lose their mentions.
   - `docker-compose.chunk_remote.yml` is deleted.
2. **`docs/sync-protocol.md` moves to `chaim354/tinkerex-sync`**, the server it specifies. That repo
   and `chaim354/tinkerex-client` repoint their citations to it, in one PR each. Here, `CLAUDE.md`
   and code comments cite it as `tinkerex-sync`'s `docs/sync-protocol.md`.
3. **Text every deployment shows.**
   - The landing page's "A NAS share, an S3 bucket or a sync server" becomes "A folder or a NAS
     share".
   - Help's admin paragraph stops naming "the three library backends", and its `REGISTRATION=open`
     sentence names the sync server only when `syncable?`.
   - "Desktop app" wording in Settings, Settings → Devices, Settings → Users and the account page
     becomes "connected app" or "device". A device is a desktop app or an assistant.
   - The `versioned` and `syncable` refusals in `LibraryCapabilities::CAPABILITY_ABSENT` stop
     naming s3 and the sync engine.
4. **s3-only text, reworded neutrally:**
   - Help's and `shared/_where_files_come_from`'s bucket paragraphs;
   - the unreachable-library banner's "storage bucket isn't answering";
   - the Settings Library row's "storage bucket";
   - any `FileLayer::S3`, `S3::ObjectIdentity` or `Library::S3Observer` error message that can
     reach an alert, a flash or a JSON error body.
5. **Guards.**
   - `test/install_docs_test.rb` gets an exempt group for the s3 and chunk_remote variables, with
     its reason. The group is derived from `LibraryBackendCheck::S3_REQUIRED` and
     `CHUNK_REMOTE_REQUIRED` plus a short named list of their optional variables, so a new
     variable the code reads still has to be documented or classified.
   - `install_docs_test` and `deploy_hygiene_test` drop `docker-compose.chunk_remote.yml` from
     their file lists.
   - A new rendered-output test asserts that the landing page and Help, rendered on a share
     deployment, contain none of the hidden words. It is mutation-checked by putting one back.

## Verification

- Full `bin/ci`.
- The new rendered-output test.
- A sweep that greps every in-scope file and rendered page for `S3`, `bucket`, `chunk_remote`,
  `sync server`, `tinkerex-sync`, `tinkerex-client` and `desktop app`, and finds nothing outside
  the "stays" column.

## Out of scope

- Removing either backend, the device API or a deployment.
- Changing the sibling repos beyond the `sync-protocol.md` move.
- The GitHub repo's description, which already names none of these.
