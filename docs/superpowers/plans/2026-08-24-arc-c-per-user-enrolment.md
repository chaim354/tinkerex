# Arc C — per-user enrolment

> **For agentic workers:** REQUIRED SUB-SKILL: superpowers:subagent-driven-development or
> superpowers:executing-plans. Steps use `- [ ]` checkboxes.

**Goal:** each maker user gets its own library on the sync server, instead of every user's writes
arriving as one device belonging to one sync-server user.

**Design:** `docs/superpowers/specs/2026-08-23-stage-5-engine-leaves-the-process-design.md`, Arc C.

**Two repos.** Tasks 1–2 are in `../tinkerex-sync`; Tasks 3–6 are here. The sync half must merge
and be pinned before the maker half can use it — the same cross-repo shape Arc B's `put_chunk`
had, and it blocked a task there, so it is sequenced deliberately this time.

---

## The defect

`ChunkRemote#transport` reads **one process-wide `CHUNK_REMOTE_TOKEN`** (`chunk_remote.rb:441-442`).
Every maker user's writes reach the sync server as a single device belonging to a single
sync-server user. Fine for self-host, where tenant = user (§8). Wrong for anything multi-user: two
maker users share one remote library and can see each other's files.

## THE SHARPEST RISK IN THIS ARC — read before writing any code

**`transport` is memoized as `@transport` on the adapter, and `FileLayer.current` is ONE instance
shared by every Puma thread.** Memoizing a per-user transport there hands user A's token to user B
— a cross-tenant credential leak, not a correctness nit, and it would pass every single-user test.

`FileLayer::ChunkRemote#batch` already faced exactly this and solved it with a `Thread.current`
frame (Arc B Task 3) — its comment says why in as many words. **Follow that precedent.** Whatever
you build, the test that matters is: two threads, two users, each sees only its own token.

---

## Task 1 (sync repo): `POST /v1/admin/libraries`

**Files:** `app/controllers/sync/v1/admin/libraries_controller.rb`, `lib/tinkerex_sync/v1_routes.rb`,
tests, `conformance/scenarios/11-admin.yml`

- [ ] **A distinct operator credential, `SYNC_ADMIN_TOKEN`, NOT a device token.** It can mint
  libraries; a device token cannot be allowed to. Compare with `ActiveSupport::SecurityUtils
  .secure_compare` rather than `==`, and refuse to boot — or refuse the endpoint — when it is unset,
  rather than defaulting to something. **An unset admin credential must never mean "allow".**
- [ ] Creates a `User` plus its first `Device`, returns `{ user_id, device_id, device_token }`.
  The token is shown once; only its digest is stored, matching `sync:device:issue`.
- [ ] **Idempotency:** decide what a repeat call for the same email does and say why. Creating a
  second library for one email silently is worse than refusing.
- [ ] **This breaks design §6's "zero new server endpoints are required" and the commit must say
  so.** That claim was about the file-layer verbs, every one of which already had an endpoint.
  Provisioning was never among them. State the exception rather than letting the doc quietly
  become wrong.
- [ ] Corpus scenario, recorded not authored. It must cover the refusals: no token, wrong token,
  a device token used as an admin token. **The coverage assertion derives from the drawer, so a new
  route with no scenario fails it** — that is the guard working.
- [ ] `rake test`, `rake test:host`, conformance green.

## Task 2 (sync repo): ship it

- [ ] PR, CI green, merge. **The maker half cannot start until this is on `main`** — `Gemfile.lock`
  pins `branch: main` and pointing it at a feature branch is a landmine.

---

## Task 3 (maker repo): Rails encryption, which is not configured today

**Files:** `config/credentials.yml.enc`, `config/application.rb` or an initializer, `docs/DEPLOY.md`

- [ ] `bin/rails db:encryption:init` and store the three keys in credentials. **Verify by reading
  them back**, not by trusting the generator.
- [ ] **This is an operational change, not just a code one.** Every deployment needs the keys, and
  they arrive via `RAILS_MASTER_KEY` — already deployed, so the cost is bounded, but
  `docs/DEPLOY.md` must say what happens to an encrypted column if that key is ever rotated.
- [ ] **Decide `support_unencrypted_data` deliberately and write down why.** The column is new and
  empty, so it can be `false` from the start — which is stricter and worth taking while it is free.

## Task 4 (maker repo): the per-user token

**Files:** a migration, `app/models/user.rb`, `app/services/file_layer/chunk_remote.rb`

- [ ] `users.sync_device_token`, `encrypts :sync_device_token`.
- [ ] **NOT deterministic.** A deterministic encryption is only needed to query by the value, and
  nothing queries by a token — deterministic buys nothing here and leaks equality.
- [ ] `ChunkRemote#transport` becomes per-user. Kill the `@transport` memo or scope it so two users
  on two threads cannot collide. **Write the two-user two-thread test first** — it is the whole
  point of the task.
- [ ] `CHUNK_REMOTE_TOKEN` survives only as the bootstrap credential for the admin call. Say that
  where it is read, so nobody restores the old meaning.

## Task 5 (maker repo): lazy provisioning

**Files:** a service, `app/services/file_layer/chunk_remote.rb`

- [ ] On a user's first library use with no `sync_device_token`, call `POST /v1/admin/libraries`
  and store the returned token.
- [ ] **Exactly once per user, under concurrency.** Two simultaneous requests for a fresh user must
  not create two libraries. Use a lock or a unique constraint and prove it with a concurrent test —
  §14e's `next_seq!` deadlock is the recorded precedent for taking this seriously.
- [ ] **A provisioning failure must be a `FetchError`, not a `NotFound`.** The sync server being
  unreachable is retryable and renders 503; telling a user their library does not exist because a
  provisioning call timed out is the §14a mistake in a new place.

## Task 6: the full-suite leg this unblocks

Arc A recorded that the full maker suite cannot run against a remote sync server because one token
maps every test's user to one library. **That is what this arc removes.**

- [ ] Try it: run the whole suite under `LIBRARY_BACKEND=chunk_remote` against a real server.
- [ ] **Report what happens honestly.** If it works, this is the leg Arc A deferred and it should
  become a gate. If it does not, say precisely what still blocks it — the answer is worth more than
  an optimistic claim, and Arc A's own value came from measuring rather than predicting.
- [ ] `bin/ci` bare, green. STATUS.md + CLAUDE.md, same branch, same PR (§15).
