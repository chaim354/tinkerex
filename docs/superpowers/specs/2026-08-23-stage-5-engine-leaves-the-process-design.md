# Design: Stage 5 — the engine leaves the process

> **Status:** DESIGN. 2026-08-23. Branch `claude/stage-5-design`.
>
> **One-liner:** embedded `chunk` is **retired**. `chunk_remote` becomes the only chunk-family
> backend, so the maker app reaches the sync engine over HTTP and by no other means — which is
> the shape a Rust rewrite can be dropped into without touching the maker app.

**Predecessor:** `2026-08-20-chunk-repo-separation-design.md`, whose Stages 1–4 are all complete
(client extracted, port widened, engine extracted to `chaim354/tinkerex-sync`, `chunk_remote`
selectable). This document is Stage 5 and it finishes what that one started: Stage 4 made the
maker app *able* to run without the engine; Stage 5 makes it *unable* to run with it.

---

## 0. Goal

**A Rust rewrite of the sync engine must be a deployment change, not a code change.** That is
only true when the maker app's sole channel to the engine is the v1 wire. Today it has two: the
wire (`chunk_remote`) and direct Ruby (`chunk`). One of them has to go, and it is the Ruby one.

End state for `LIBRARY_BACKEND`:

| value | bytes live | catalog | engine in-process |
|---|---|---|---|
| `chunk_remote` | standalone sync server's storage | changelog delta mirrored into local `nodes` | **no** |
| `share` | mounted NAS | `Library::Scanner` poll | no |
| `s3` | bucket | `S3Observer` poll | no |

`chunk` is deleted. In this repository that means, concretely: no `tinkerex-sync` gem, no eight
sync tables in `db/migrate`/`db/schema.rb`, **zero** `Sync::` references anywhere in `app/`,
`lib/` or `config/`, and no v1 sync routes drawn here.

What stays host-owned: `users`, `nodes` (the mirror), `devices` (the credential for
`/v1/maker/*`, per §14j), `remote_manifest_chunks`, and every `maker_*` table.

---

## 1. What is still coupled — measured, not assumed

Every row below was checked against the tree on `main` at `7e6e794`, not inferred.

| Coupling | Site |
|---|---|
| The gem, loaded conditionally | `Gemfile:28`, `config/application.rb:18` |
| v1 sync routes drawn here | `config/routes.rb:315` |
| Four initializers | `sync_hooks.rb`, `sync_capabilities.rb`, `postgres_pooler_check.rb`, `finalize_verification.rb` |
| Three recurring jobs | `config/recurring.yml:24,38,54` |
| Seven `has_many` into engine models | `app/models/user.rb:32-38` |
| The changelog sequence allocator | `User#next_seq!`, `users.head_seq` |
| A coalesced-broadcast seam | `app/services/library_broadcast.rb:23` |
| The one sanctioned chunk-internals call | `app/services/maker/addons/library_output.rb:143` |
| A dev-only blob server | `app/controllers/dev_blobs_controller.rb:33-34` |
| The consolidated-migration generator | `lib/engine_schema.rb`, `db/engine_schema.rb`, `test/engine_schema_test.rb` |
| The cross-repo auth-parity guard | `test/v1_auth_parity_test.rb` |
| The engine-absent boot smoke | `test/integration/no_engine_boot_test.rb`, `SYNC_ENGINE`, `LibraryBackend.engine_wanted?` |
| Eight tables in this app's schema | `changelog_entries`, `chunks`, `conflicts`, `file_locks`, `manifest_chunks`, `pending_commits`, `share_links`, `versions` |

### 1.1 `chunk_remote` is further from parity than STATUS.md implies

STATUS.md records Stage 4 as "12/12 verbs" and "not yet deployed or exercised against a real
remote server." Both true. What it does not record is that three things are **broken or absent**
— found by reading the adapter and probing a real boot, not by reading the ledger.

**(a) The mirror never refreshes except after this app's own writes.** `refresh!` is called from
exactly five sites — `mkdir`, `move`, `delete`, `undelete`, `finalize_upload`
(`chunk_remote.rb:179,188,198,207,242`) — and `ChangelogSync` has no other caller anywhere in
`app/`, `lib/` or `config/`. There is no periodic pull and no ActionCable subscription, though
design §6 promised the `{head_seq}` nudge. **A file pushed from a desktop mount is invisible in
the maker UI indefinitely**, until the maker app happens to write something itself.

**(b) Every addon save raises `NameError`.** Verified by booting the backend:

```
$ LIBRARY_BACKEND=chunk_remote SYNC_ENGINE=0 CHUNK_REMOTE_URL=… CHUNK_REMOTE_TOKEN=x \
    RAILS_ENV=test bin/rails runner '…'
engine_wanted=false
Sync defined? nil
ChunkStore defined? nil
backend=FileLayer::ChunkRemote
port_writable=false
```

`port_writable: false` sends `Maker::Addons::LibraryOutput#write` down `#write_chunk`, which calls
`Sync::Storage::ChunkStore.current.put` (`library_output.rb:143`) — a constant that does not exist
in that process. Nothing tests it: the three legs are `chunk`/`share`/`s3`, and
`grep -rln "LibraryOutput" test/services/file_layer/chunk_remote/` is empty.

**(c) `LibraryBroadcast.batch` degrades to a bare `yield`** (`library_broadcast.rb:21`). Its own
comment argues that is the honest answer without the engine, and on share/s3 it is — they have no
changelog, so there is nothing to coalesce. On `chunk_remote` there *is* one, and the seam has a
second job it is not doing: see §3.B3.

**The list above is what one reading pass found.** This repo's record is that reading
undercounts — §14j's own words are "an inventory built by grepping `Sync::` will undercount", and
Stage 1's plan counted four CI jobs booting a Rails server where there were seven. The size of
Arc B is therefore **not** knowable from this document. That is the whole argument for §2.

---

## 2. Sequencing: the contract lands first, and it lands red

Four arcs, each shippable, in this order:

| Arc | What | Why it is here |
|---|---|---|
| **A** | The contract: a real `test-chunk-remote` gate + a portable conformance corpus | Converts "chunk_remote works" from an argument into an executed fact, and **measures** Arc B |
| **B** | Parity: close every gap the gate exposes | Cannot be scoped before A runs |
| **C** | Per-user enrolment | Independent of A/B; must precede D |
| **D** | Packaging, live proof, then deletion | The deletion is last, after the replacement is proven on real hardware |

The alternative — fix the three known gaps first and build the gate at the end — was rejected
because the gap list would stay a reading exercise until the moment the working backend is
deleted. §14e states the rule this arc is applying: *checking beats reasoning*, and a probe is
cheaper than the argument it replaces.

**Arc A's gate is expected to land RED.** That is the signal being bought. A gate introduced
green was never allowed to tell anyone anything.

**Each arc gets its own implementation plan, and Arc B's cannot be written until Arc A has run.**
This document is deliberately an arc-of-arcs rather than a single plan: A, C and D are scopable
now, B is not, and a plan that pretended otherwise would commit to the pre-written gap list §1.1
says explicitly is an undercount. Start with a plan for Arc A alone.

---

## 3. The arcs

### Arc A — the contract

**A1. `test-chunk-remote` becomes a `bin/ci` gate.** It checks out `chaim354/tinkerex-sync` as a
sibling, boots its `host/` with `STORAGE_BACKEND=local`, and runs the full maker suite under
`LIBRARY_BACKEND=chunk_remote`. The sibling-checkout-plus-symlink shape is already established by
`.github/workflows/client-contract.yml` for `tinkerex-client`; this is the same move for the
other repo.

**It runs against the REAL server, not a fake, and that is a decision rather than a convenience.**
§14e records `FakeS3`: it decoded `copy_source` with `CGI.unescape` while the adapter encoded with
`CGI.escape` — exact inverses, so **79 of 80 tests were green over silent permanent data loss**
on any filename containing a space. A hand-written stub for a 25-endpoint wire is that failure
with a much larger surface. The rule §14e draws from it — *assert the wire format, not the
round-trip* — is what A2 exists to satisfy.

**A2. The portable conformance corpus**, owned by `tinkerex-sync` (the server side owns the
server contract). Three parts:

- **Scenarios** — ordered files, each a named sequence of steps of the form
  `{ request: {method, path, body|query}, expect: {status, matchers} }`, with capture placeholders
  for server-assigned values (`$node_id`, `$commit_id`, `$seq`) bound from earlier responses.
  Ordering is load-bearing: a changelog is a sequence, and half these endpoints are only
  meaningful against state a previous step created.
- **A format spec** — a JSON Schema plus prose, sufficient for someone to write a runner in a
  language that is not Ruby. This is the point of the artifact.
- **A Ruby runner** in the sync repo, run by that repo's CI against its own server.

**The scenarios are RECORDED from a real server, never hand-authored.** Hand-authoring them
re-creates the `FakeS3` shape one level up: fixtures written from the same misunderstanding the
implementation holds will agree with it. The recording pass is a one-time harness; the recorded
corpus is then checked in and becomes the thing that must not change silently.

**A3. `docs/sync-protocol.md`** grows from its current 215 lines to normative coverage of all 25
endpoints `Sync::V1_ROUTES` draws, cross-checked against the corpus so that prose and fixtures
cannot drift independently. A Rust implementer reads A3 and is graded by A2.

**Gate count during Arc A: nine** (`setup`, `style`, `scan`, `test`, `test-share`, `test-s3`,
`test-no-engine`, `system`, `test-chunk-remote`).

### Arc B — parity

Three items are known. The gate names the rest, and the plan must be written to accept that.

**B1. Freshness.** A `remote_changelog_pull` entry in `recurring.yml`, per user, gated to
`chunk_remote` — the `command:`-with-the-gate-in-a-class-method shape `library_scan` and
`project_folder_intake` already use, and required for the same reason §14j gives (Solid Queue
resolves a `class:` at load and reads one file with no merge mechanism).

Design §6's answer was an ActionCable subscription to the sync server. Rejected here, not
forever: it needs a long-lived WebSocket client living inside a request/response Rails app, which
means a supervised thread or a fourth process, and a dropped subscription fails by going quietly
stale — the failure mode a poll does not have. A **sync→maker webhook** is the follow-up that
makes the lag near-zero, and it is named as follow-up work, **not in scope**.

Accepted consequence: the maker UI lags the sync server by up to the pull interval. Desktop
clients are unaffected — they get the server's own nudge.

**B2. Addon saves — `put_chunk` becomes a port verb.** Signature
`put_chunk(user, begun:, hash:, bytes:)`, where `begun` is the `UploadBegun` the caller already
holds — it carries both `missing` (what the caller iterates) and `put_urls` (what only the remote
adapter reads), so neither adapter is handed a field the other cannot use. `FileLayer::Chunk`
implements it as `Sync::Storage::ChunkStore#put`; `FileLayer::ChunkRemote` as an HTTP PUT to
`begun.put_urls[hash]`.

This deletes §14c's "one legitimate direct `Sync::Storage::ChunkStore` call in the maker layer."
`test/architecture_invariants_test.rb` pins that count at exactly one and names the file; after
B2 the count is **zero**, which is the concrete, executable measure of "totally separated."

**The asymmetry is why this is a port verb and not one shared implementation.** On embedded chunk
a presigned URL for the memory or local store points at *Rails itself* (§14a says exactly this
about `Chunk#download`'s `is_a?(S3ChunkStore)` check), so a server-side PUT to it is a loopback
HTTP call into the same Puma pool — §14e's recorded reentrancy bug, which measured 14–24 second
stalls and outright 404s when `ADDON_SOURCE_URL` pointed at this app. The adapter must decide;
the caller cannot.

**B3. `LibraryBroadcast.batch` gets a real job on `chunk_remote`: defer the mirror refresh.**
Today every `move` calls `refresh!`, so `Maker::ProjectIntake`'s eager sweep costs **two WAN
round-trips per file inside a browser-facing request** (the mutation POST, then a full
`/v1/changes` pull). That is the same shape §14f already capped for S3 at `EAGER_MAX_MOVES_S3 = 5`
— three sequential unbatched calls per move, measured at 85–205 ms each against a real R2 bucket.

`batch` becomes "suppress intermediate `refresh!`, pull once at the end." Then **measure** before
choosing an eager cap for this backend. §14f's own recorded failure is a bullet that named an
asymmetry and left the number the same on all three backends for months; the answer is a
measurement, not a fourth guessed constant.

**B4. Whatever A1 turns red.** Unbounded by construction. The plan carries an explicit
triage step rather than a pre-written list.

### Arc C — per-user enrolment

Today `ChunkRemote` resolves **one process-wide token** (`chunk_remote.rb:327-328`,
`ENV.fetch("CHUNK_REMOTE_TOKEN")`), so every maker user's writes reach the sync server as a
single device belonging to a single sync-server user. Acceptable for self-host, where tenant =
user (§8). Not acceptable for anything multi-user.

**The mechanism is admin-token provisioning, not a password endpoint, and that is deference to a
decision already recorded in the other repo.** `host/app/controllers/v1/devices_controller.rb`
says so in its own header: *"DEVICE ENROLMENT, AND THERE IS DELIBERATELY NO PASSWORD LOGIN HERE…
adding a password endpoint would mean inventing a credential scheme — storage, reset, lockout,
rate limiting — for a server whose whole job is holding chunks."* Its first token is minted by an
operator (`bin/rails sync:device:issue`) and every later device is enrolled by an
already-authenticated one — which grows a **fleet inside one library** and cannot create a second
one, which is precisely what per-user isolation requires.

**Sync repo:** one new endpoint, `POST /v1/admin/libraries`, authenticated by a distinct operator
credential (`SYNC_ADMIN_TOKEN`, separate from any device token). It creates a sync user plus its
first device and returns that device token. No password, no session, no reset, no lockout.

This does break design §6's "zero new server endpoints are required" — honestly, and the scope of
that claim is worth stating: it was about the **file-layer verbs**, every one of which already had
an endpoint. Provisioning was never among them.

**Maker repo:** a `users.sync_device_token` column encrypted with Rails `encrypts`, provisioned
lazily on a user's first library use, and `ChunkRemote` resolving its transport **per user**.
`CHUNK_REMOTE_TOKEN` survives only as the bootstrap credential for the admin call.

**Deliberately not built:** OIDC. It is the recorded intended successor in both repos (CLAUDE.md
§12.1, and the sync host's own comment names it), and it supersedes this without disturbing the
device-token mechanism underneath — which the Rust clients need regardless.

### Arc D — packaging, proof, then deletion

**D1. The `sync` Kamal accessory.** Self-host runs it co-located on the same box, internal-only on
the Kamal network with its own volume — identical in shape to the `addons` accessory, which
`deploy.yml` already documents as the reason addon changes need no Rails deploy. Managed runs the
sync server as its own deploy on its own host. That is §7's "one protocol, two hosts" applied one
level up.

**Two different secrets mechanisms apply here and must not be conflated.** `CHUNK_REMOTE_URL` is
a cleartext env value naming an accessory, so `deploy.ovh.yml` must explicitly blank it **and
`test/deploy_hygiene_test.rb`'s pattern must widen to cover it** — that guard matches
`/_SIDECAR_URL\z|\AADDON_SOURCE_URL\z/`, a naming convention rather than a category, and §14c
records that `ADDON_SOURCE_URL` itself was silently unguarded until someone widened the pattern by
hand. `SYNC_ADMIN_TOKEN` and `CHUNK_REMOTE_TOKEN` are **secrets**, so they follow §14g instead:
per-destination in `.kamal/secrets.<dest>`, never in `secrets-common` — which the same test
already enforces, because `InlineCommandSubstitution` expands every `$(…)` in a parsed file
eagerly, so a credential parked there makes a `-d share` deploy shell out for something a share
container never holds.

**D2. Backups.** The sync server is a **second database `ops/backup-db.sh` does not touch.**
Either extend that script to take a second target or install a second cron entry. §14i is
explicit that nothing in `bin/ci` can go red for any of this and that the shared failure mode is
*you find out when you need a restore* — so this is a checklist item with a rehearsal, not a code
change with a test.

**D3. The live two-box proof, before anything is deleted.** Deploy the accessory on Unraid, point
a maker deployment at it, and verify a real desktop mount → sync server → maker UI round-trip
byte-for-byte. STATUS.md records that `chunk_remote` has never been run against a real remote
server; deleting the only chunk-family backend proven on hardware while its replacement is
unproven is the trade this step exists to refuse.

**D4. The deletion PR.** Everything in §1's table: gem, eight tables, every `Sync::` reference,
`head_seq`/`next_seq!`, the four initializers, the three recurring jobs, the routes drawer,
`lib/engine_schema.rb`, `db/engine_schema.rb`, `test/engine_schema_test.rb`,
`test/v1_auth_parity_test.rb`, `test/integration/no_engine_boot_test.rb`, `SYNC_ENGINE`,
`LibraryBackend.engine_wanted?`, `dev_blobs_controller`, and `LibraryBroadcast`'s engine arm.

`LibraryBackend::DEFAULT` moves from `"chunk"` to `"chunk_remote"`.

**Gate count after Arc D: seven** (`setup`, `style`, `scan`, `test-chunk-remote`, `test-share`,
`test-s3`, `system`). `test-no-engine` is **deleted, not adapted** — there is no longer an engine
that could be absent, so the leg's own claim has become vacuous, and §14j records what a guard
that skips on the thing it asserts is worth.

**D5. CLAUDE.md and `docs/STATUS.md`, in the same branch and the same PR** (§15). §14a's
four-backend table, §14j's whole section, §10's repo layout and §13's cheatsheet all move.

---

## 4. The developer loop, and one honest ergonomic cost

With `chunk` gone, the default backend needs a sync server. A bare `bin/rails test` will hit
`LibraryBackendCheck`'s refusal for a missing `CHUNK_REMOTE_URL` — which is the honest failure,
and is what §14a's boot guard is for, but it is a worse first-run experience than today's.

The plan therefore ships `bin/sync-server`: one command that boots the sibling checkout's `host/`
with `STORAGE_BACKEND=local` on a known port and prints the two env values to export. `bin/ci`'s
`test-chunk-remote` gate uses the same script, so there is one definition of "get a sync server"
rather than a script and a workflow that can drift.

`bin/ci` is ~40 s today; booting a Rails server for the default leg adds to every run. Stated,
not hidden.

---

## 5. Accepted costs

- **Every desktop client must be repointed at the sync server's URL.** In `chunk` mode clients
  enroll against the maker app; afterwards they cannot. This is the largest user-visible
  consequence in the arc and it has no mitigation — it is what "the engine is a separate service"
  means.
- The maker app's `POST /v1/devices` response drops `head_seq` (`v1/devices_controller.rb:39`).
  Without the engine it is 0 forever, and reporting a number that is structurally always zero is
  worse than omitting the key.
- **Share links stop being served by the maker app.** `share_links` is engine-owned (§14j:
  `Sync::Gc.apply_retention!` reads it, and splitting the two silently destroys the bytes behind
  URLs users have already sent). There is no maker web surface for them today — `grep`ing
  `app/controllers`, `app/views` and `config/routes.rb` for `share_link` returns nothing — so
  nothing user-visible is lost, only v1 API surface that moves to the sync server.
- Self-host becomes **two containers and two databases**.
- Mirror lag up to the pull interval, until the webhook is built.
- No data migration is provided. The live `chunk` deployment holds test users only; the box is
  recreated rather than migrated. An existing chunk deployment with real data has **no supported
  path** out, and that is a deliberate scope decision, not an oversight.

---

## 6. Verification

- **The three legs still report identical counts** (§15), with `chunk_remote` occupying `chunk`'s
  place. That guard survives the arc untouched, which is the test of whether the replacement is
  really a replacement.
- **Every new guard is mutation-checked** (§15). Specifically: B2's zero-hit assertion must go red
  when a direct chunk-internals call is planted; B1's job gate must go red when it fires on a
  non-`chunk_remote` backend; D1's `deploy_hygiene_test` widening must go red when `CHUNK_REMOTE_URL` is
  left un-blanked in `deploy.ovh.yml`, and its existing `secrets-common` arm must go red when
  either new token is parked there.
- **The conformance corpus is recorded from a running server and replayed in CI.** A corpus that
  drifts from the server it describes is the `FakeS3` failure with better branding.
- **D3 is a manual, recorded verification**, not a gate. §14i's framing applies: some things
  cannot go red in `bin/ci`, and the answer is to rehearse them, not to pretend a test covers them.

---

## 7. Risks

1. **The gate makes this repo's CI depend on `tinkerex-sync`'s `main`.** After Arc D there is no
   `Gemfile.lock` entry pinning it, so an unrelated push to the other repo can red this repo's
   gate for reasons that have nothing to do with the PR. **Mitigation: a recorded revision file**
   (`.sync-server-ref`) that the gate checks out, moved by a deliberate act — the same discipline
   `bundle update tinkerex-sync` provides today, which the Gemfile's own comment already describes
   as the point of pinning an exact revision.
2. **Retiring `chunk` deletes the only chunk-family backend ever proven on real hardware.** D3 is
   what buys that back and it must land before D4. If D3 cannot be completed, the arc stops at
   Arc C with `chunk` still present — a worse end state, but an honest one.
3. **`SYNC_ADMIN_TOKEN` is a new high-value credential** — it can mint libraries. It is per
   destination (§14g: `.kamal/secrets` is the base file, not a shared one) and must never live in
   `secrets-common`, which `deploy_hygiene_test.rb` already enforces for exactly this shape.
4. **Arc B's size is unknown until Arc A runs.** Three gaps were found by reading; §14j and Stage 1
   both record that reading undercounts. The plan must be written to expand at that point rather
   than to a pre-committed list.
5. **Two device namespaces now exist** — maker devices (the credential for `/v1/maker/*`) and sync
   devices (the credential for the sync server). They are unrelated tables in unrelated databases
   with the same name. `test/v1_auth_parity_test.rb` currently keeps the two *implementations*
   honest; after D4 it is deleted, because they are no longer two copies of one thing but two
   different things. That is correct, and it is also exactly the moment a future reader will
   assume they are still the same.

---

## 8. Out of scope, named so it is not re-derived

- **OIDC** (§12.1) — the successor to Arc C's device tokens, unchanged by this arc.
- **The sync→maker webhook** — makes B1's lag near-zero; the poll ships first.
- **At-rest chunk encryption** (§12.2) — deliberately last, unaffected.
- **The Rust rewrite itself.** This arc produces the two things it needs: a wire nothing else
  crosses, and a corpus it can be graded against.
