# C — A stranger can install it: design

**Date:** 2026-10-13 · **Status:** design, executed the same day (plan:
`docs/superpowers/plans/2026-10-13-c-install-path.md`) · **Source:** `docs/AUDIT-2026-10-12-readiness.md`
§2.1 and §5, plus the fact-finding recorded in the plan's "Facts" section. Builds on B
(`2026-10-13-b-accounts-that-work-design.md`): registration closed by default, first account is the
owner, mail by environment.

## The problem

Every deployment that exists was made by the author, from a Mac, with Kamal, 1Password and the
author's own hosts. A stranger with Docker on a Linux box cannot run the app:

1. **No image they can pull** (every ghcr package is private) and nothing says how to build one.
2. **The committed, encrypted credentials file is baked into the image.** With the author's master
   key absent, Rails silently reads empty credentials; a WRONG key crashes the boot; and
   `chunk_remote` needs three Active Record encryption keys that exist only in that file.
3. **With `LIBRARY_BACKEND` unset the app boots and then 500s on every request, including `/up`**:
   the CSP header's `connect_src` lambda calls `FileLayer.current` on every response, which raises
   `LibraryBackendCheck::Error` inside middleware, outside any controller rescue.
4. **Background work silently never runs** unless `SOLID_QUEUE_IN_PUMA` is set: scans, previews,
   trash purge, intake, the changelog pull.
5. The image is amd64-only by two hard-coded release assets (pdfium, F3D).
6. `README.md` is the Rails scaffold stub; there is no install guide, no compose file, no Unraid
   template, and the env reference lives only in the audit.

## Decisions

- **The first audience is a NAS or VPS self-hoster on the `share` backend**, one owner, no mail.
  `chunk_remote` is the second path, as a compose overlay that adds the sync server. `s3` is
  documented, not templated.
- **Strangers never set `RAILS_MASTER_KEY`.** `SECRET_KEY_BASE` is enough for share/s3. For
  chunk_remote, the three encryption keys come from `ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY`,
  `_DETERMINISTIC_KEY`, `_KEY_DERIVATION_SALT`, applied only when present so the author's
  credentials-based deployments are untouched. (Rails has no built-in ENV source for these; a
  config value set in an initializer is splatted over the credential value by the railtie.)
- **Production refuses to boot with `LIBRARY_BACKEND` blank**, in the initializer, exempting the
  asset-precompile boot (`SECRET_KEY_BASE_DUMMY`). The lib default stays `chunk`-shaped so an
  unconfigured development box still boots (CLAUDE.md §14a's measured rule).
- **Solid Queue runs inside Puma by default in production**; `SOLID_QUEUE_IN_PUMA=false|0|no` is a
  real off-switch for a split `bin/jobs` container. The author's destinations already set it to
  `true`, so nothing changes for them.
- **The image builds for arm64 too**, best-effort: pdfium by `TARGETARCH`; F3D only on amd64
  (upstream ships no Linux arm64 build), so arm64 loses STEP/IGES/OBJ thumbnails — the mesh
  renderer already degrades to `unsupported` when the binary is absent. The openscad sidecar stays
  amd64 (AppImage).
- **Compose over Kamal for strangers**: `docker-compose.yml` (share) with an optional `tools`
  profile for the two GPL sidecars and the addon bundle, built from this repo and a sibling
  checkout; `docker-compose.chunk_remote.yml` as an overlay. The image is built locally until the
  owner flips the ghcr packages public (an owner-only, per-package switch; audit §6).
- **The env reference is a guarded document**: `docs/INSTALL.md` carries every variable the app
  reads, and `test/install_docs_test.rb` fails when a variable the code reads is missing from it.
- **`README.md` becomes real**: what it is, quick start, first run, where files come from, the
  Tools gallery, updating and backups, the sibling repos. No licence is claimed for this repo —
  that decision is the owner's; the siblings' licences are stated.

## Out of scope

The ghcr visibility flip and multi-arch publishing in CI (owner actions / a later arc); pinning
accessory tags (collides with the sync cutover plan); pruning `docs/` (G); per-user roots on
share/s3; the desktop client's sign-in (D).

## Invariants this adds (CLAUDE.md §14a candidates, one line each)

- Production refuses to boot with `LIBRARY_BACKEND` blank; the lib default must not be changed to
  match (§14a).
- `ACTIVE_RECORD_ENCRYPTION_*` ENV overrides apply only when present — assigning nil would splat
  over the credential value and break the author's deployments.
- `docs/INSTALL.md` is the env reference and `test/install_docs_test.rb` keeps it complete.
