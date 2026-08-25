# Arc D Part 1 — a real remote deployment

> **For agentic workers:** REQUIRED SUB-SKILL: superpowers:subagent-driven-development or
> superpowers:executing-plans. Steps use `- [ ]` checkboxes.

**Goal:** run `chunk_remote` against a real standalone sync server **on hardware**, as a fourth
deployment alongside chunk / share / s3 — without retiring anything.

**Design:** `docs/superpowers/specs/2026-08-23-stage-5-engine-leaves-the-process-design.md` §4,
steps D1–D3. **D4 (the deletion) is deliberately NOT in this plan.**

---

## Why this is staged, and what the number was

Arc D as designed ends by retiring embedded `chunk`: gem out, eight tables out, every `Sync::`
reference out. Measured before starting, that costs **68 of 224 test files** (30%) — every one
naming `Sync::` or `FileLayer::Chunk`, 47 of them pinning the chunk backend explicitly. Arc C's
Task 6 had already measured the same thing from the other side: 818 of 2504 tests fail in a real
`chunk_remote` boot, almost entirely for that reason.

The design never counted it. So the deletion becomes its own arc, scoped against a **proven**
remote deployment instead of a predicted one — which is also what the design's own **Risk #2**
already required: *"D3 must land before D4."*

There is a real insight in that 68, and the deletion arc should start from it: **`FileLayer::Chunk`
lives in the gem, so this repo is testing an adapter it does not ship.** Some of those files belong
in `chaim354/tinkerex-sync`, which is a different job from rewriting them.

---

## Task 1: publish the sync server image

**Repo:** `../tinkerex-sync`

- [ ] It has a `Dockerfile` building `host/` (EXPOSE 3000, `SQLITE_DATABASE` or `DATABASE_URL`).
  **Nothing publishes it.** Add a build+push path.
- [ ] Follow this repo's own precedent — `bin/build-boxes-sidecar` / `bin/build-openscad-sidecar`
  are the shape, and the `addons` accessory is the closest analogue: an image built and pushed
  from its own repo, consumed here by tag.
- [ ] **Build for the right architecture.** The Unraid box is x86-64; the dev machine is ARM64.
  `kamal build` handles this for the app; a hand-rolled build will silently produce an image that
  cannot run there. State which you produced and how you know.
- [ ] Verify by **running the pushed image**, not by trusting the push: `docker run` it, hit
  `/up`, confirm 200.

## Task 2: the `sync` accessory and a fourth destination

**Repo:** here.

- [ ] A `sync` accessory in `config/deploy.yml`, on the same host, **internal-only** (no `port:`),
  reachable on the kamal network as `tinkerex-sync` — the exact shape `addons`, `boxes` and
  `openscad` already use. Its own volume for `host/storage`.
- [ ] A fourth destination, `config/deploy.remote.yml`, running `LIBRARY_BACKEND=chunk_remote`
  with `CHUNK_REMOTE_URL: http://tinkerex-sync`. **A fourth deployment, not a repointing** — the
  three existing backends keep working, so this proves the remote path without taking anything
  away. That is the whole point of staging.
- [ ] **`SYNC_ADMIN_TOKEN` becomes a real credential.** Generate one, store it in the `tinkerex`
  1Password vault, and reference it from `.kamal/secrets.remote` — **never `secrets-common`**
  (§14g: `InlineCommandSubstitution` expands every `$(…)` eagerly, so a credential parked there
  makes a `-d share` deploy shell out for something a share container never holds, and
  `deploy_hygiene_test.rb` already guards this).
- [ ] **`deploy.ovh.yml` must blank `CHUNK_REMOTE_URL`, and `deploy_hygiene_test.rb`'s pattern must
  widen to cover it** — that guard matches `/_SIDECAR_URL\z|\AADDON_SOURCE_URL\z/`, a naming
  convention rather than a category, and §14c records that `ADDON_SOURCE_URL` itself went unguarded
  until someone widened it by hand. Mutation-check the widening.
- [ ] `bin/secrets-preflight --all` must resolve **five** destinations and say so.

## Task 3: backups — a second database nothing backs up

- [ ] `ops/backup-db.sh` backs up the maker database. **The sync server has its own**, and nothing
  touches it. A restore that recovers the maker app and not its chunk catalog recovers a library
  that cannot resolve a single file.
- [ ] Extend it, or install a second cron. **§14i binds here**: nothing in `bin/ci` can go red for
  any of this, the shared failure mode is *you find out when you need a restore*, and the invariant
  is that it must be **rehearsed**, not reasoned about.
- [ ] **Rehearse the restore.** Prove the archive restores into a working sync server, the way
  `bin/restore-db` does for the maker DB. An unrehearsed backup is a belief.

## Task 4: the live two-box proof

**This is what the whole staging exists to produce.**

- [ ] Deploy the accessory and the `remote` destination.
- [ ] Provision a real library through `POST /v1/admin/libraries` and confirm the maker app
  provisions lazily on first use, against the real server, over the real network.
- [ ] **Drive a real desktop mount → sync server → maker UI round-trip, byte-for-byte.** STATUS.md
  has recorded since Stage 4 that `chunk_remote` has never been exercised against a real remote
  server on hardware. This closes that, or finds why it cannot.
- [ ] Health on all **four** deployments; the three existing ones must be untouched.
- [ ] **Report what breaks.** Something will. Arc A's value was measuring rather than predicting,
  and a live box is the first place several of these paths have ever run.

## Task 5: the record

- [ ] `docs/STATUS.md` — amend the Stage 5 entry (§15: one arc, one entry).
- [ ] `CLAUDE.md` — §7's deployment table gains a fourth destination; §13's cheatsheet gains the
  accessory; §14g gains whatever the secrets work taught.
- [ ] **State plainly that `chunk` is NOT retired** and why the deletion was deferred, with the 68
  number. A reader must not infer from "chunk_remote is deployed" that chunk is gone.
- [ ] `bin/ci` bare green.
