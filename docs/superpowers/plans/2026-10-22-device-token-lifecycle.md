# Device-token lifecycle (pentest H1b) and the three smaller findings

**Date:** 2026-10-22. **Record:** `tinkerex#465` (H1b), `#466` (M4b), `#467` (I2c), `#468` (L3).
**Source:** `docs/security-audit-2026-06-17.md` (historical, rescued), re-checked against `main`
at `b900fce5`. One PR carries all four; H1b is the only one with a design.

## What is true today (measured, not assumed)

- `devices` holds `name`, `token_digest`, `last_seen_at`, timestamps. `Device.authenticate` is a
  bare `find_by(token_digest:)`. A token lives until its row is deleted, and nothing deletes one.
- `last_seen_at` is stamped on EVERY authenticated v1 request (`V1::Authentication`, an
  unthrottled `update_column`). It is exact to the request, so a rule built on it needs no slack
  for a write throttle.
- There are four doors that change a password, and every one of them leaves device tokens
  working: the emailed reset (`Users::PasswordsController`, Devise's `reset_password_by_token`),
  the Account page (`Users::RegistrationsController#update`), an admin's reset
  (`Settings::UsersController#reset_password`), and `bin/rails tinkerex:password`. The demo reset
  creates a fresh account, never updates one, and the demo enrols no device.
- **The desktop client (`tinkerex-client` at `399ccdb`) has no 401 handling.** It calls the maker
  API only when the user acts: opening Library, Projects, Inventory or Previews, never on a timer
  and never during sync. A 401 from those views shows up as a raw error toast. Signing in again
  reuses the stored credential without contacting the server
  (`maker-app/src-tauri/src/lib.rs:665`), so the only way out is deleting the entry from
  `credentials.json` by hand. The sync loop uses the separate sync-grant token, against the sync
  server.
- **The sync server (`tinkerex-sync` at `b849e08`) cannot revoke a device.** Its only device routes
  are `POST /v1/devices` and `GET /v1/devices/whoami`, its `authenticate` has no expiry, and this
  app stores nothing that identifies the sibling it minted.

## Design

1. **Revocation is deleting the row.** A revoked token has no use, so it gets no `revoked_at`
   column, no filter in `authenticate`, and no reaper.
   - **The user's own devices:** `Settings → Devices` (`/settings/devices`,
     `Settings::DevicesController`, index + destroy). It lists name, when the device was added,
     when it was last used, and whether it has expired. Lookups are scoped through `current_user`.
   - **An admin, for another account:** a Devices section on `Settings → Users → <account>`, with a
     per-device Sign out button (`DELETE /settings/users/:id/devices/:device_id`). It sits behind
     the same `require_account_manager!` gate and the never-the-signed-in-account rule as the rest
     of that page.
2. **Every password change revokes the account's devices.** This is one `after_update` on `User`,
   keyed on `saved_change_to_encrypted_password?`. It is not four calls at four doors, because
   every door changes the password through that column, and a fifth door added later is covered
   without anyone remembering to. It runs inside the save's transaction, so a refused password
   revokes nothing. Each of the four doors has its own test.
3. **Expiry: a token unused for `DEVICE_IDLE_DAYS` (default 90) stops authenticating.** The clock
   is `last_seen_at`, or `created_at` for a device never used. `0` turns expiry off, the same
   convention as `LIBRARY_TRASH_DAYS`. `authenticate` refuses an expired token before stamping it,
   so a refusal never restarts the clock. The row stays, and the Devices page shows it as expired
   with a Remove button.
4. **chunk_remote: revoking a maker device does NOT revoke its sync sibling.** The wire has no
   door for it (above). This app now RECORDS the sibling's id (`devices.sync_device_id`, from the
   grant's `whoami`), so the follow-up only needs the sync server's endpoint and one call here.
   Devices enrolled before this change cannot be mapped. The Devices page says, on a syncable
   deployment, that file sync is not cut off.
5. **Device-auth parity is now deliberately broken.** §14j says a change to device-token
   verification here must be made in `tinkerex-sync` too. Expiry is such a change, and this task
   may not edit that repo. The comment in `V1::Authentication` and §14j now record the divergence,
   and the follow-up is filed.

## M4b, I2c, L3 (decided in the PR; summarised here)

- **M4b:** failed attempts no longer lock an account (`lock_strategy = :none`). Throttles replace
  the lock: per source (IPv4 address or IPv6 /64) at 10 per 3 minutes (the existing limit, re-keyed),
  and per account per source at 10 per hour (new). Both doors read their numbers from one module.
  One source can no longer keep an owner out.
- **I2c:** `Maker::FileAttachment` validates `node_id` against the user's own nodes **when it
  changes**, never on every save. A dangling id on an old row must not lock that row (§14d).
- **L3:** `Lbrn2.normalize_color` accepts only `#rgb`/`#rrggbb` and returns it unchanged; anything
  else becomes the default stroke. There is no revision bump, because valid colours render
  byte-identically.

## Decisions made without the owner

- **90 days of idle expiry, with a knob.** It is long enough that someone who opens the desktop
  app's maker views a few times a season never meets it, and short enough to retire a token left
  on an abandoned install. **What it can surprise:** a chunk_remote user who only syncs never
  touches the maker API, so that user's maker token idles out while sync carries on. The next time
  they open Library or Projects in the desktop app, they hit the client's 401 wedge. Sync itself
  cannot be interrupted by this, because it runs on a different token on a different server.
  **Existing tokens are not grandfathered:** a device last used more than 90 days before the
  deploy is expired at the deploy. `DEVICE_IDLE_DAYS=0` is the switch if that is wrong for the
  owner's own devices.
- **A password change on the Account page also signs out every device.** This includes the
  user's own change, not only a reset, because "change my password" is what someone does after
  losing a laptop. The Account page says so beside the field.
- **Revocation deletes, with no audit trail.** The list shows only what can still authenticate,
  plus expired rows waiting for Remove.
- **No lock at all, rather than a lock across all sources.** Any per-account limit counted across
  every source is a lever that lets the same attacker lock the owner out, which is the finding
  itself. Guessing spread across many sources is bounded by the 10-character password floor and
  bcrypt cost 12, not by a lock. The record of that trade is this line.
- **IPv6 keys on the /64**, because one host owns a whole /64, and per-address limits on IPv6 bound
  nothing.

## Follow-ups (filed, not done here)

- `tinkerex-client`: on a maker 401, drop the stale credential, ask for the password, and show
  "signed out". On a sync 401, stop the loop instead of retrying every 2 s under a "mounted" pill.
  Before re-enrolling, check that the outbox has drained, because a new grant rebinds the library
  and deletes the outbox.
- `tinkerex-sync`: a device-revoke door (`DELETE /v1/devices/:id`, scoped to the caller's user),
  plus idle expiry to match this one. After that, revoking here calls it with `sync_device_id`.
