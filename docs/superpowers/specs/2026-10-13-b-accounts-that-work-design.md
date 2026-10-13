# B — Accounts that work: design

**Date:** 2026-10-13 · **Status:** design, executed the same day (plan:
`docs/superpowers/plans/2026-10-13-b-accounts-that-work.md`) · **Source:**
`docs/AUDIT-2026-10-12-readiness.md` §1 items 1–2, §2.1 item 6, and the two items A left open
(tinkerex#345, #346).

## The problem

A stranger who installs the app today cannot get an account, and an operator who exposes it cannot
keep strangers out:

1. Signup is open everywhere, with no mode to close it (`:registerable`, unconditional).
2. On `share` and `s3` every account indexes the same library, so an open signup hands a stranger
   the owner's files. Only the absence of a mail server stops it.
3. No mail server can be configured without editing Ruby: `production.rb` ships the scaffold's
   commented `smtp_settings`, so confirmation mail never leaves the box and the account is stuck.
4. The from-address is a literal (`no-reply@tinkerex.app`).
5. Behind Cloudflare, `request.remote_ip` is Cloudflare's edge node, so every per-IP throttle A
   shipped keys on the wrong address on the one public box (tinkerex#345, measured).

## Decisions (the ones the audit said only the owner could make, taken as recommended)

- **Share and s3 stay single-owner.** Per-user roots are not built. `REGISTRATION=open` on those
  backends is **refused at boot**, the same shape as `LibraryBackendCheck`.
- **Registration is closed by default in production** (`REGISTRATION` unset or `closed`), open in
  development and test so the existing suite keeps driving the open flow. `open` is for
  `chunk_remote` deployments and the managed service, where tenancy is per user.
- **The first account is the owner.** With registration closed and no user in the database, the
  sign-up page is allowed exactly once; the account it creates is confirmed on the spot (no mail
  needed) and signed in; after that the page answers a "sign-ups are closed" page (403) and the
  "Sign up" link is gone. No role column: "the first account" is the whole mechanism, YAGNI.
- **Mail is configured by environment**, never by editing a file: `SMTP_ADDRESS` turns SMTP on;
  `SMTP_PORT`, `SMTP_USER_NAME`, `SMTP_PASSWORD`, `SMTP_DOMAIN`, `SMTP_AUTHENTICATION`,
  `SMTP_STARTTLS` refine it; `MAIL_FROM` is the sender and defaults to `no-reply@<APP_HOST>`.
  When unconfigured in production the sign-up and resend pages say so in one sentence, and the boot
  log says so once. The existing delivery-failure rescue stays as the backstop.
- **Cloudflare's published ranges are trusted proxies**, pinned in the repo with the date they were
  fetched and a rake task to refresh them. `request.remote_ip` is then the visitor on the OVH box
  and unchanged everywhere else, because Rails takes the right-most untrusted address and a direct
  request never carries a Cloudflare hop. Never key on `CF-Connecting-IP` alone: any direct request
  can forge it.
- **Console doors for an owner with no mail**: `bin/rails tinkerex:owner[EMAIL]` (create a confirmed
  account) and `bin/rails tinkerex:password[EMAIL]` (reset), the password read from
  `TINKEREX_PASSWORD`, never from argv.

## Out of scope

Per-user roots on share/s3 (a later arc if the managed service ever wants shared boxes);
OIDC/OAuth verification (§12.1); the signup email oracle in the test seam (closed everywhere by A).

## Invariants this adds (go to CLAUDE.md §8)

- `REGISTRATION=open` is refused at boot on `share` and `s3`; a committed destination on those
  backends never sets it (deploy hygiene test).
- The first account on a closed server is confirmed without mail; every later one needs mail or a
  console door. The sign-up page tells the visitor which case they are in.
