# H — The public demo on tinkerex.com: design

**Date:** 2026-10-14 · **Status:** design, executed the same day (plan:
`docs/superpowers/plans/2026-10-14-h-public-demo.md`) · **Source:** the owner's decision — "for the
hosted version on my server I just want to have a demo for now and not allow sign up" — and the
choice of shape: **a one-click sandbox that resets nightly** (over a read-only demo or published
credentials).

## The problem

Sign-ups on tinkerex.com are closed (sub-projects A and B: `REGISTRATION: closed`, `/users/sign_up`
answers 403). A visitor therefore meets a sign-in form and nothing else: no way in, nothing to look
at. The "demo account" that exists today is an ordinary console-created account on the author's LAN
deployments with a password in 1Password — a way for the author to test, not a demo.

## Decisions

1. **Demo mode is one deployment setting, `DEMO_ACCOUNT_EMAIL`.** Blank (every destination but OVH)
   means nothing below exists: no route, no button, no job work. Set, it names the shared demo
   account; `Tinkerex::Demo` (`lib/tinkerex/demo.rb`) is the one place that reads it and answers
   `enabled?`, `email`, `account` (the `User`, or nil until the setup task creates it) and
   `demo?(user)`.
2. **One click signs a visitor in.** `POST /demo` (`DemoSessionsController#create`) signs the
   visitor into the demo account with a plain Devise session (no "remember me"), rate-limited per
   IP, 404 when demo mode is off or the account does not exist. The sign-in page shows a **Try the
   demo** button above the form with one sentence ("A shared account that resets every night;
   nothing you do here is private"), and the sign-up link that is closed anyway is replaced by that
   sentence. Signed in as the demo account, the shell carries a banner saying the same and when the
   next reset is.
3. **The demo account cannot escape the sandbox.** Guarded on `Tinkerex::Demo.demo?(current_user)`
   or on the email, each refusal a sentence rather than a 500: it cannot change its email, password
   or handle or delete itself (`Users::RegistrationsController#update`/`#destroy`); a password-reset
   request for its email sends nothing and answers exactly as any other email does (no
   enumeration); it cannot publish a project (`visibility` other than `private` is refused on create
   and update, so tinkerex.com never hosts a visitor's content); it cannot enrol a device
   (`POST /v1/devices/login` answers 403 `demo_account`, and `POST /v1/devices` the same); and an
   upload above `DEMO_MAX_UPLOAD_BYTES` (default 25 MB, per file, both upload doors) is refused with
   the limit named. Everything else — uploads, folders, projects, notes, tools, the 3D viewer — works,
   because that is what a demo is for. The existing per-IP throttles and the nightly reset bound the
   rest.
4. **The reset destroys and re-seeds, through the port.** `Tinkerex::DemoReset` (a service with the
   user injected) deletes every live top-level node of the demo library through `FileLayer.current`
   (a directory delete cascades on every backend, §14a), purges the library's trash with an explicit
   "now" cutoff (the adapter call, not the env-driven job, whose `0` means keep forever), destroys
   the `User` row (its `dependent:` chain is the tenant cleanup, `app/models/user.rb`) and recreates
   it with the same email, the handle `demo`, a random password nobody is told, and `confirmed_at`
   set; then writes the seed set from `db/seeds/demo/` through the port (`mkdir` + `write`), and runs
   `Library::ScanJob.perform_now(user_id:)`, whose post-reconcile sequence turns `Projects/Desk Lamp`
   into a project and files its loose root files. Visitors signed in as the old row are signed out by
   the reset, which is right. `Tinkerex::DemoResetJob` runs it from `config/recurring.yml` every day
   at 04:00 and is a no-op unless demo mode is on; `bin/rails tinkerex:demo:setup` creates the
   account and runs the first reset, `tinkerex:demo:reset` runs one by hand.
5. **The seed set is the repository's own sample files**, committed under `db/seeds/demo/`: a
   `Welcome.md` at the root that says what the demo is, a `Projects/Desk Lamp/` folder with a README,
   an STL, an SVG, a Gerber zip and a KiCad schematic (so the project page, the 3D viewer, the vector
   preview, the board view and the filing sweep all have something to show), a `Models/cube.3mf` and
   a `Laser/*.lbrn2`. Small, deterministic, replaceable by the owner's own files later (the task
   takes a directory argument).
6. **OVH carries `DEMO_ACCOUNT_EMAIL: demo@tinkerex.com`**; the Unraid destinations carry nothing
   (their console demo account stays what it is). `docs/INSTALL.md` documents the two knobs for a
   self-hoster who wants a demo of their own; `docs/DEPLOY.md` §5 becomes the OVH demo's runbook
   (setup, reset by hand, what resets, what a visitor sees).

## Out of scope

A visitor-facing landing page beyond the sign-in page; per-visitor sandboxes; a storage quota on the
whole demo library (the nightly reset and the per-file cap bound it); moving the author's LAN demo
accounts onto this mechanism.

## Verification

Every guard is a request test on the share leg (demo mode switched by `ENV`), mutation-checked;
the reset runs for real on the share leg against a fresh library (`use_fresh_share_library!`): a
populated demo library and rows become exactly the seed set, indexed, with the project discovered
and its root files filed; the job is a no-op with demo mode off; the deploy-hygiene test pins OVH
on and the three Unraid destinations off; the install-docs guard pins the two rows. After the
deploy: the button on tinkerex.com signs in, the banner shows, and the next morning's log shows the
reset ran.

## Invariant this adds (CLAUDE.md §8, one line)

The demo account is signed in by one click, cannot change its credentials, publish, or enrol a
device, and is destroyed and re-seeded nightly through the port; nothing of it exists unless
`DEMO_ACCOUNT_EMAIL` is set.
