# Stage 3 design pass — where the boundary actually falls

> **Status:** DESIGN. 2026-08-20. Prerequisite for any Stage 3 implementation plan.
>
> **One-liner:** The parent design assumes the maker↔sync dependency runs one way. It runs **both
> ways**, in five places it does not mention — and one of them is silent data loss.

**Parent design:** `docs/superpowers/specs/2026-08-20-chunk-repo-separation-design.md`. This
document does not replace it; it corrects §1's table and §5's model, which were built from a
`Sync::`-shaped view of the code.

---

## 0. Why this pass exists

The parent design §5 frames Stage 3 as: *"`User` and `Node` stay in the maker app; the engine
declares them as host requirements, the way Devise expects a `User`."* One direction — engine needs
host data.

A measurement of the whole tree says otherwise. **The engine calls host business logic, reads a
host table for correctness, and writes a column onto the host's own `users` row; while the host's
v1 API cannot boot or authenticate a single request without the engine.** The Devise analogy
describes none of that.

Two things follow. First, §1's straddler table is wrong: it names `nodes` as the only straddler and
files `share_links` under "Maker". Second — and this is the part worth internalising — **the
`Sync::` namespace was never the boundary.** The engine's own models are bare top-level constants
(`Version`, `Device`, `ManifestChunk`…), so every audit built from a `Sync::` grep, including
Stage 2's seam guard and the parent design's own "six call sites in five files", was measuring one
visible slice of a larger graph. Stage 2's guard is still correct about what it claims; it just
claims less than its name suggests.

---

## 1. The finding that changes the plan: `Sync::Gc` reads `share_links`

`app/services/sync/gc.rb:106-114`, `referenced_version_ids`, unions live share-link `version_id`s
into the set retention refuses to prune. Its own comment says why: *"a live share link's frozen
version: presigned GETs against its manifest would dangle."* It runs nightly via `RetentionJob` —
one of the three reaper jobs the parent design moves wholesale to `tinkerex-sync`.

**Split `share_links` from `Sync::Gc` and retention silently prunes versions live share links still
point at.** Not a boot failure, not a red test — a nightly job quietly destroying the bytes behind
URLs users have already sent to other people. It is the highest-severity item in this document and
it is absent from the parent design entirely.

### Resolution: `share_links` moves to the engine

Not a compromise — it is where the feature already lives, on evidence the parent design missed:

- **Share links cannot exist on share or s3 at all.** `V1::ShareLinksController:20` gates on
  `require_capability! :versioned`, and `Sharing::Links.create_for_version!` does
  `user.versions.find_by!(...)` — a real `versions` row is structurally required. `versioned` is
  true on chunk and false on the other two (§14a). The feature is chunk-only by construction.
- `share_links.version_id` and `.manifest_id` are references into two moving tables.
- `Sharing::Links.redeem` queries `ManifestChunk` directly and presigns through
  `Storage::ChunkStore` — both engine-internal once it moves.
- **`lib/schema_map.rb:52-53` already files `share_links` under "Sync control plane"**, and that
  file is *tested* (`bin/rails schema:map:check`). Someone reached this conclusion before this
  investigation, independently, and the parent design's table contradicts a checked artifact
  already in the repo.

Moving it makes the GC dependency engine-internal and closes the parent design's hazard #1 in the
same stroke. **What the host loses is nothing it has:** a share/s3 deployment has no share links
today.

**`lib/schema_map.rb` and `docs/schema-map.html` are a primary input to Stage 3, not something to
rebuild.** `EDGES` is a literal, test-enforced enumeration of every app-level cross-table reference.
One caveat before trusting it wholesale: it labels `maker_previews.version_id` and
`maker_file_attachments.version_id` as hard edges into `versions`, while the runtime treats that
column as a backend-polymorphic `content_token` — a version UUID on chunk, a content hash on
share/s3 (`FileLayer::FileInfo`). Both readings are true; neither is authoritative. §5 below picks.

---

## 2. The engine calls host business logic

`V1::CommitsController#finalize` calls `Maker::Previews::Enqueue.call` (`:41`) and
`Maker::ProjectIntakeJob.nudge` (`:49`), with a comment defending both. `CommitsController` is the
two-phase commit — unambiguously the engine. So the engine depends on maker preview rendering and
project-intake filing.

This is categorically different from "the engine needs `Node`". It is not shared *data*; it is the
engine reaching into the host's *features*.

### Resolution: invert it into a host-registered hook

The engine declares an extension point; the host subscribes in an initializer.

```ruby
# config/initializers/tinkerex_sync.rb, in the HOST
TinkerexSync.on_commit_finalized do |user:, node_id:, name:|
  Maker::Previews::Enqueue.call(user:, node_id:, name:, version_id: …)
  Maker::ProjectIntakeJob.nudge(user:, node_id:)
end
```

Three properties worth stating, because each is a decision:

- **A host that registers nothing still works.** The engine is sellable standalone (goal 1) only if
  its commit path does not require a preview pipeline to exist.
- **The hook runs AFTER the commit transaction commits**, never inside it. §14e's
  `enqueue_after_transaction_commit` finding is the precedent: a job whose argument is a row id,
  enqueued inside the caller's open transaction, loses the race against an in-Puma Solid Queue
  worker and is discarded silently.
- **Errors in a subscriber must not fail the commit.** A preview render failing is not a reason to
  reject bytes the client already uploaded. Rescue, log, move on — the same posture
  `Library::Reconciler#enqueue_thumbnail` already takes ("a render enqueue must NEVER fail the
  scan").

The same mechanism serves `Maker::ProjectIntake`'s use of `LibraryChannel.batch` (§4).

---

## 3. The host cannot boot its own v1 API without the engine

`V1::BaseController` references `Sync::Commit::InvalidManifest`, `Sync::Commit::KindConflict`,
`Storage::ChunkStore` and `Storage::LocalChunkStore` **at class-definition time** (`:14,21,52-53`),
and includes `Authentication`, whose `authenticate_device!` calls `Device.authenticate` on every v1
request. All **fourteen** `v1/maker/*` controllers inherit it.

So a share/s3 deployment's maker API — projects, tags, inventory, BOMs — cannot parse, let alone
authenticate, without the sync engine loaded. `V1::DevicesController`'s own comment says the quiet
part: *"a Device is not only a sync participant: its token is the ONLY credential the whole v1 API
accepts… including /v1/maker/*."*

This is the exact mirror of the parent design's concern, pointing the other way, and it is
unaddressed there.

### Resolution: `Device` and `Authentication` are HOST infrastructure, not engine

They are the v1 API's credential mechanism, which the maker API needs whether or not a sync engine
exists. Concretely:

- `Device`, `Authentication`, and `V1::BaseController`'s auth half stay in the host.
- The engine declares `Device` as a host requirement, alongside `User` and `Node`.
- `V1::BaseController`'s `rescue_from Sync::Commit::*` arms and its `Storage::` presign-base
  stashing move **down** into the sync controllers that need them, or become an engine-provided
  concern the host includes only when the engine is mounted. Stage 2 set the precedent: `Chunk`'s
  port verbs re-raise through `FileLayer`'s own vocabulary so callers never name a sync class.

In Stage 4, the standalone sync server carries its **own** `devices` table — that is how the maker
app authenticates to it (parent design §2.2). Same model name, two tables, two roles, exactly as
`nodes` does under the wire-only contract. That is consistent, not duplicated.

---

## 4. Three smaller straddles, each with a resolution

**`User#next_seq!` and the `head_seq` column.** `head_seq` is a `bigint` on the shared `users`
table, and `next_seq!` exists solely to serialize changelog sequence assignment under a row lock.
`lib/postgres_pooler_check.rb` and its initializer exist *only* to protect that lock's semantics,
and run at boot for **every** deployment including share/s3, which have no changelog.

→ **Engine-owned state that the engine's own migration adds to whatever `users` table it is pointed
at.** In embedded mode that is the host's table; in Stage 4 it is the sync server's own. The pooler
guard becomes engine-conditional — a share/s3 host with no engine mounted should not refuse to boot
over a locking rule for a column it does not have.

**`Maker::ProjectIntake` calls `LibraryChannel.batch`** (`:243,422`) to coalesce a sweep's nudges —
justified in its own comment as the difference between one broadcast and 500. If `LibraryChannel`
moves, this breaks.

→ The batching API is part of the engine's **public** surface. Maker calls
`TinkerexSync::LibraryChannel.batch`. In Stage 4's remote mode the moves go through the port
anyway, so coalescing becomes the remote adapter's concern — worth noting so nobody designs the
embedded answer as if it were permanent.

**`Node#current_version`** does `user.versions.find_by(...)` — host model, engine table. Called from
exactly six lines, all in `FileLayer::Chunk`.

→ **Move the lookup into the adapter and delete the method.** It has one consumer, and that
consumer is the one file allowed to know about versions. Note the codebase already avoids it in
bulk paths precisely because it is an N+1 (`V1::TrashController` uses `Sync.load_version_sizes`
instead, with a comment saying why).

---

## 5. Two things to decide, not to discover

**`maker_previews.version_id` / `maker_file_attachments.version_id`.** `lib/schema_map.rb` calls
these edges into `versions`; the runtime calls the column a backend-polymorphic `content_token`.

→ **The runtime reading wins, and `schema_map.rb` should be corrected.** The column holds a version
UUID on chunk and a content hash on share/s3 — a *foreign key that points at different tables
depending on deployment* is not a foreign key. Recording it as a hard edge would make Stage 3 move
two maker tables it must not move. Fix the map in the same pass, since it is tested and will
otherwise keep asserting the wrong shape.

**`conflicts` and `file_locks` have no formal FK to `users`** — `t.integer :user_id, null: false`
where every sibling uses `t.references … foreign_key: true`. No comment explains it.

→ **Add the FKs before either table crosses a repo boundary**, or record the omission deliberately.
An unenforced ownership edge is precisely what gets violated once the database is no longer shared.

---

## 6. The corrected picture

| | Parent design §1 said | Actually |
|---|---|---|
| Straddlers | `nodes` only | `nodes`, `users` (`head_seq`), `share_links`, `devices` |
| `share_links` | Maker — stays | **Engine** — chunk-only by construction; `lib/schema_map.rb` already said so |
| Dependency direction | engine → host | **both ways**, in five places |
| `Device` | (unmentioned) | **Host** — the v1 API's only credential, maker included |
| "twelve controllers move" | stated as fact | **not well-defined** — four independent reasons (§7) |

---

## 7. "Twelve controllers" is not a number

The parent design's arithmetic (14 v1 controllers − `base` − `test_users` = 12) fails four ways:

1. `v1/chunks/blob_controller.rb` sits a directory deeper under a third namespace (`V1::Chunks::`) —
   count it and the total is 15.
2. `devices_controller.rb` is shared auth infrastructure by its own documentation, not sync.
3. `share_controller.rb` and `share_links_controller.rb` were the ambiguity; §1 resolves them to the
   engine, which changes the count again.
4. **The codebase's own enforced boundary does not use a controller count.** Stage 2's guard treats
   `app/controllers/v1/**/*.rb` as one indivisible glob — which is exactly why it cannot see that 14
   of those 29 files are maker-owned data sitting inside a glob labelled sync.

**Stage 3 should classify by file, from the table in §6, and delete the count.** A number nobody can
reproduce is worse than a list.

---

## 8. What a Stage 3 implementation plan must additionally handle

- **`config/recurring.yml` is one host-owned file** scheduling engine jobs (`version_retention`,
  `orphan_chunk_reaper`, `pending_commit_reaper`) beside maker ones. Solid Queue reads it from the
  host; there is no engine-contributed-schedule mechanism configured. Either the host keeps entries
  naming engine job classes (simplest, and an explicit host obligation to document), or the engine
  ships a schedule fragment the host merges. **Decide it; do not let it surface at deploy time.**
- **`config/initializers/` has no boundary structure at all** — `finalize_verification.rb` (engine),
  `library_backend_check.rb` (host) and `postgres_pooler_check.rb` (engine, per §4) sit together
  undifferentiated.
- **`dev_blobs_controller.rb`** is a top-level non-v1 controller touching `Storage::` directly. It is
  in no controller count anywhere and belongs to the engine.
- **The existing guards will not catch a regression here.** `architecture_invariants_test.rb` scans
  `app/**/maker` for `/manifest_chunks|ChunkStore/` and separately lexes for the `Sync` token —
  neither sees `Device.register!` in `library_output.rb:161`, in the very file the first guard
  already flags for a different reason. **Stage 3 must widen both to the bare model names**, or its
  own boundary will be unenforced in exactly the way this document had to be written to discover.

---

## 9. Recommendation

**Do not write a Stage 3 implementation plan from the parent design as it stands.** Amend §1's
table and §5's model with §6 above first; then plan. The single change that most reduces Stage 3's
risk is moving `share_links` to the engine, because it converts the highest-severity finding — a
silent retention bug — into an engine-internal call that cannot be split by accident.
