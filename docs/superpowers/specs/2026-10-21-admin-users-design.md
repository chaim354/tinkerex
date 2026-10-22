# Admins add, reset, promote and delete accounts in the browser: design

**Date:** 2026-10-21 · **Status:** design approved by the owner, awaiting a plan · **Source:** the
owner's request of 2026-10-21 ("the admin should be able to add users in gui"), with three choices
put to them and answered: an admin flag rather than "every account" or "the oldest account"; the
admin types the password rather than an invite link; and the page also resets passwords,
promotes/demotes admins and deletes accounts. Facts cite `main` at 665fdd7c.

## The problem

A self-hosted server has exactly one way to add a second account: a console task, run through
`docker compose exec` with the password in an environment variable (`lib/tasks/tinkerex.rake`,
`tinkerex:owner`; `docs/INSTALL.md` §4). The sign-up page is closed after the first account
(`lib/tinkerex/registration.rb`), `REGISTRATION=open` is refused at boot on share and s3, and a
fresh install has no mail server, so "forgot password" cannot work either; its only fix is the
sibling task `tinkerex:password`. Both are correct and both are what a household member's
"can you add me?" should not require.

There is also **no admin today**. "The first account is the owner" is true only in the sense that
it came first: `users` has no role column (`db/schema.rb`), and every account can do everything —
including change the library folder for everyone (`Settings::LibraryController`'s header comment
says so on purpose). A GUI that adds accounts needs someone it is *for*.

## Decisions

- **An `admin` boolean on `users`**, default false, not null. *Alternatives weighed and declined by
  the owner:* any signed-in account may add users (matches today's flat model, but anyone could mint
  accounts); the oldest account is the owner, derived (no migration, but the role can never move).
- **The first account is admin, decided in the doors that already decide "first"** — the sign-up
  form (`Users::RegistrationsController#build_resource`, beside `skip_confirmation!`) and
  `tinkerex:owner` (beside its `first` local) — **not a `User` callback.** A `before_create` would
  also fire for the demo account, which `Tinkerex::DemoReset.create_account!` mints on a server where
  it is the only account, and for every test's first user, since the suite has no user fixtures.
  This is the same argument `Library::ScanJob.enqueue_first_for` makes for the first scan.
- **The migration marks the oldest existing account admin.** Every live deployment then has one
  without a console visit. The demo account (`DEMO_ACCOUNT_EMAIL`, read when the migration runs) is
  passed over for the oldest real one, so OVH gets a working admin too.
- **`bin/rails 'tinkerex:admin[EMAIL]'` grants admin from the console.** The recovery door: an
  OIDC-only server (`User.from_omniauth` mints the first account and is deliberately not an admin
  door — the provider decides who signs in, not who administers), a server whose only admin was the
  demo, or a bad edit. Same shape and same refusals as its two siblings.
- **The demo account is never an admin, whatever its row says.** Strangers are signed into it by one
  click (`lib/tinkerex/demo.rb`). One predicate answers "may this account administer" —
  `admin? && !Tinkerex::Demo.demo?(user)` — and both the gate and the hub row ask it.
- **The admin types the password; the account is confirmed on the spot.** No invite link, no mail,
  nothing that expires. *Alternative weighed and declined:* a one-time set-your-password link,
  which keeps the password from the admin but adds a token, an expiry and a page. The password field
  is visible text with no confirmation field, because the admin is going to read it out or paste it;
  Devise's 10–128 length (`config/initializers/devise.rb`) applies.
- **The page lives at `/settings/users`**, a "Users" row on the Settings hub shown only to admins.
  `ShellHelper`'s `"settings" => %w[settings]` already lights Settings for every `settings/…`
  controller, so the sidebar needs no change.
- **The last admin cannot be removed, and only one door needs a guard for it.** The Users page never
  acts on the signed-in account (your own account is the Account page's, behind your password), and
  the one acting is an admin, so demoting or deleting *another* account there always leaves at least
  one. A last-admin check on that page could never fire, so it would be a guard nobody can make
  fail (§15); there is none. The one door that can remove the last admin is the Account page's
  self-delete, which refuses while other accounts exist. A server with accounts and no admin is
  recoverable only from the console. Two admins demoting each other in the same instant can both
  succeed; recorded, not guarded, because the console task repairs it.
  *(Amended while planning: the design first had a last-admin refusal on the Users page as well.)*

## The page

### List

One row per account, newest last, in the existing `settings-list` component, so it fits 375px without
a sideways scroll (design-system.md rule 11). Each row: the email; an "admin" mark; "you"
on the signed-in account; last sign-in (`last_sign_in_at`, "never" when nil). The email links to that
account's own page (`/settings/users/:id/edit`), which holds the three actions below; the "you" row
links to the Account page instead.

### Add an account

Email, password (visible text, `autocomplete="new-password"`), and a "Make this account an admin"
checkbox. On submit:

- `User.create!(email:, password:, admin:, confirmed_at: Time.current)` — confirmed, so Devise sends
  no confirmation mail whether or not `SMTP_ADDRESS` is set. Validation errors (taken email, short
  password, bad address) re-render the form with Devise's own messages.
- **On a scannable backend (share, s3) a scan is queued for the new account at once.** Each account
  holds its own catalog of the one library, filled by `Library::ScanJob` per user; without this the
  new account opens an empty library and the Getting started panel until the next 15-minute sweep.
  Gated on `scannable?`; the folder is confirmed by construction, because the page sits behind
  `require_library_folder!`.
- The form says what the account will see, keyed on the backend: on share and s3, that **every
  account sees the same library folder and can edit and delete every file in it**
  (keyed on `capabilities.syncable?`, true only on chunk_remote); on chunk_remote, that the account
  gets its own library, created on first use (`FileLayer::ChunkRemote::Provisioning`).

### Reset a password

A form on the account's page with one visible password field. A blank password is refused
explicitly: `User#password_required?` answers false for a passwordless (OIDC) account, so Devise
would save a blank one as a silent no-op. It sets the password, sets `confirmed_at` if it was
nil, and clears a lock (`locked_at`, `failed_attempts`) — the GUI twin of `tinkerex:password`, plus
the unlock, since a locked-out user is the usual reason to be here. Devise stores the password's salt
in the session, so the account is signed out of its other browser sessions by Devise's existing
behaviour. **Device tokens are not revoked**: a desktop client keeps syncing. That is deliberate
scope, stated on the form.

The admin resets their **own** password on the Account page, which asks for the current one; every
action here refuses the signed-in account and redirects there.

### Make / remove admin

A button on the account's page (`button_to`, PATCH, the state asked for rather than a toggle).
The demo account cannot be made admin (refused; the predicate would ignore it anyway, and a row
saying "admin" over an account that is not would mislead).

### Delete an account

A section of the account's page that names what goes — the account's projects, notes, tags,
pins and its copy of the library catalog — and what stays: **every file on disk**. The admin types
the account's email to confirm; a mismatch re-renders with an error. Then `user.destroy`, the
existing cascade (`app/models/user.rb`'s `dependent:` list, checked complete by
`test/models/tenant_cleanup_test.rb`).

Refused: deleting **yourself** (the Account page does that, behind your password —
`Users::RegistrationsController#destroy`). On chunk_remote the page
also says the account's library **on the sync server is not removed**: none of the eight endpoints
this app calls (CLAUDE.md §6) deletes one.

### Who reaches it

- `before_action :require_account_manager!` on every action. A non-admin (and the demo) is redirected to
  `/settings` with "Only an admin can manage accounts." (`303`), the same shape as
  `refuse_demo_account!`.
- The page stays behind `require_library_folder!` like every other page: an admin on a fresh share
  install confirms the folder before adding anyone, so the new account's first scan has a folder.
- Session-authed web only (§14d). No v1 endpoint.

## The Account page change

`Users::RegistrationsController#destroy` refuses when the signed-in account is the last admin and
any other account exists, re-rendering the Account page with the reason. The sole account on a
server may still delete itself, as today.

## Testing

Integration tests drive the real forms and assert the **rendered field names** (§14d: a nested-hash
POST cannot see a missing `scope:`). Each guard is mutation-checked (§15) — break it, see red,
restore.

- **Gate:** a non-admin and the demo account are redirected from every action; the hub row renders
  for an admin only.
- **Add:** the new account can sign in through the real sign-in form; it is confirmed; no mail is
  delivered; a scan is enqueued on share/s3 and not on chunk_remote; a taken email and a short
  password re-render with errors.
- **Reset:** the old password fails and the new one signs in; a locked account is unlocked; a blank
  password is refused, for a passwordless account too.
- **Admin toggle:** promote and demote work; the demo cannot be promoted.
- **Delete:** a wrong email changes nothing; the right one removes the account.
- **Self:** every action on the signed-in account redirects to the Account page and changes nothing.
- **Account page:** the last admin with other accounts present cannot self-delete; the sole account
  can.
- **First admin:** the first sign-up and the first `tinkerex:owner` account are admin; a second
  account from either door is not; `tinkerex:admin` promotes and refuses an unknown email.
- **Migration:** the oldest account is marked admin and no other.

The three backend legs must report identical RUN counts (`bin/ci`). Assertions that differ by
backend (the scan enqueue, the form's library sentence) branch on the capability, never on the
ambient `LIBRARY_BACKEND` name.

## Docs

- `docs/INSTALL.md` §4: "Adding an account" leads with Settings → Users; the console tasks stay, as
  the path with no admin signed in. `tinkerex:admin` joins them.
- CLAUDE.md §8's registration bullet gains that the first account is admin and admins add accounts
  at Settings → Users. **The file is at its ratchet ceiling (1,354 lines, `test/docs_hygiene_test.rb`)**,
  so the edit replaces words within existing lines rather than adding one.

## Not in scope

- **Making the library-folder change admin-only.** Today any account changes it for everyone; with
  an admin role that is arguably wrong, but it is a behaviour change to an existing page and gets its
  own decision. *Decided the same day: admin-only, first run included; other accounts see the page
  read-only (`Settings::LibraryController`'s header).*
- Invite links, revoking device tokens on reset, an audit log of admin actions, and removing a
  deleted account's library from the sync server.
