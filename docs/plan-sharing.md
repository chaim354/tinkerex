# Sharing / Multi-User Implementation Plan

> **HISTORICAL — not re-verified.** Written before the repository split of 2026-08-20, when the
> sync engine and the Rust client still lived here (they are `chaim354/tinkerex-sync` and
> `chaim354/tinkerex-client` now). Kept for its reasoning and its measurements; it does not
> describe what this repository contains today. The current map is `docs/README.md`.


> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development
> (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps
> use checkbox (`- [ ]`) syntax for tracking.

> **STATUS (2026-06-17, branch `night/sharing`): a deliberately SHALLOW first slice is BUILT
> and green — read-only share *links* to a single immutable version.** The full Spaces design
> below (cross-user read/write libraries, per-Space keyspace, multi-feed client) remains
> **planned, not built** — it requires the deep core changes this plan analyzes (re-keying the
> chunk store + widening tenancy from user to Space). The shallow slice sidesteps all of that:
> a redeemed link mints presigned GETs against the **owner's own** existing keyspace
> (`chunks/<user_id>/<hash>`), scoped to exactly the target version's manifest chunk hashes, so
> it adds controlled cross-user **read** access with **zero** chunk re-keying and **zero**
> tenancy change. What landed:
> - `ShareLink` model + migration (`db/migrate/20260617000006_create_share_links.rb`) — a
>   capability token (`token_digest` only), version-scoped, with expiry + revoke.
> - `Sharing::Links` service (`app/services/sharing/links.rb`) — `create_for_version!` /
>   `redeem` / `revoke!` + a read-only `Capability` that presigns ONLY the version's own chunks.
> - API: `POST`/`DELETE /v1/share_links` (authenticated owner) +
>   `GET /v1/share/:token` & `POST /v1/share/:token/download` (anonymous; the link token is the
>   auth — `ShareController` deliberately does not inherit the device-auth `BaseController`).
> - Tests: `test/models/share_link_test.rb`, `test/services/sharing/links_test.rb`,
>   `test/integration/v1/share_links_test.rb` (full server suite 442/0). Invariants preserved:
>   bytes-out-of-Rails (presign-only), version-scoped mint, revoke/expire cut access on the next
>   request.
>
> **Still NOT built (everything below):** write sharing, viewer/editor/owner roles, member
> management, per-Space keyspace, multi-feed client sync, the Shared/ mount root. Those are the
> deep slice and follow this plan's phases. Note also the **password-protected link** and
> **editor-role link** variants in Decision 3 are not in the shallow slice (links are read-only,
> no password) — add them with the Space work, or as a small follow-up if a password-gated
> public link is wanted before Spaces.

**Goal:** Let a user share a folder/library with a *different* user — viewer/editor/owner
roles, per-folder grants, and public share links — without breaking the "bytes never
through Rails", "untamperable per-key presign", and "local-first metadata" invariants.

**Architecture:** Introduce a **Space** — a shareable unit of files with its **own changelog
feed** and its **own chunk keyspace** `chunks/space/<space_id>/<hash>`, distinct from a
user's personal library (which becomes the user's implicit "home Space"). Membership
(`SpaceMembership`, role-bearing) is what the presigner consults to mint URLs, so a chunk in
a Space is readable by exactly its members — the controlled cross-user byte path. A device's
sync loop pulls its **home feed + N joined Space feeds** in parallel; commits, conflicts, and
locks are scoped *per Space*, reusing today's per-user machinery with the scope key widened
from `user_id` to `(owner_kind, owner_id)`.

**Tech Stack:** Rails 8 (models, `Sync::*` services, v1 API, ActionCable), Postgres/SQLite
(adapter-agnostic, no PG-only SQL), S3-compatible storage (R2/SeaweedFS) via presigned URLs,
Rust client (`fs-provider` multi-feed cursors, `sync-engine` multi-feed loop, `sync-client`
Space API). **No GPL/AGPL deps** (CLAUDE.md §9).

---

## Reading order / grounding (read before Task 1)

- `CLAUDE.md` §5 (data model), §6 (sync protocol), §8 (multi-tenancy & security), §9 (licensing).
- `docs/parity-roadmap.md` §C4 (sharing = the product fork; auth → sharing → encryption order).
- `docs/research-sync-competitors.md` §2 (oCIS **Spaces**, Seafile **virtual repos**) — the two
  precedents this plan follows.
- `docs/plan-file-layer-parity.md` G12 (sharing depends on G2 hardened-PG + G3 OAuth).
- Models: `app/models/user.rb` (esp. `next_seq!` + lock ordering), `node.rb`, `changelog_entry.rb`,
  `device.rb`, `version.rb`, `chunk.rb`, `manifest_chunk.rb`, `conflict.rb`, `file_lock.rb`.
- Services: `app/services/sync/{commit,mutation,changes,tree,conflicts,locks,gc,retention_policy}.rb`.
- Storage: `app/services/storage/{chunk_store,s3_chunk_store,local_chunk_store,memory_chunk_store}.rb`
  (the per-user `key_for(user_id, hash)`).
- Controllers: `app/controllers/v1/{base_controller,chunks_controller,commits_controller,changes_controller,tree_controller,nodes_controller,conflicts_controller,locks_controller}.rb`,
  `app/controllers/v1/chunks/blob_controller.rb`, `app/controllers/concerns/authentication.rb`.
- Routes: `config/routes.rb` (the `namespace :v1` block).
- Tests to extend: `test/integration/v1/tenant_isolation_test.rb`, `test/services/sync/*`,
  `client/sync-engine/tests/{integration.rs,two_device_e2e.rs,fault_injection.rs}`,
  `client/fs-provider/tests/convergence.rs`.

---

## The three hard architectural decisions (decided here — do not relitigate during build)

### Decision 1 — Data model: a **Space** with its **own changelog feed** (NOT grafted into per-user changelogs)

A **Space** is the shareable unit: a tree of nodes + versions + chunks + a **changelog** with
its own monotonic `seq`. Each user gets an implicit **home Space** (their existing library) at
account creation; shared folders are additional Spaces. Today's per-user tables become
per-**owner** tables where the owner is *polymorphic over a Space*, not a User.

**Why a per-Space feed and not grafting into each member's per-user changelog:**
- Grafting means every shared commit must fan-out-write a changelog entry into *every* member's
  per-user feed (N writes per commit, N `next_seq!` locks, N× changelog growth, and a
  revocation must rewrite history). A per-Space feed is **one** append the members *pull*.
- It matches oCIS Spaces and Seafile virtual-repos (research §2): the share is a first-class
  container with its own history, joined/left independently, revoked by removing membership —
  no history rewrite.
- The sync engine already pulls "entries where `seq > cursor`" from one feed. N feeds = N
  cursors + N pulls, a small generalization (Task 19), versus inventing fan-out semantics.

**Concretely:** introduce `owner_kind`/`owner_id` (or a `space_id` FK) on
`nodes/versions/chunks/manifest_chunks/changelog_entries/pending_commits/conflicts/file_locks`.
`head_seq` moves from `users` to `spaces`. The personal-library path is preserved by making
each user's home Space the default owner — **the single-tenant model becomes "everyone has
exactly one Space (their home)"**, so existing behavior is a special case, not a rewrite (this
is the migration story, Task 2 + Phase 7).

### Decision 2 — The chunk-keyspace problem (THE CRUX): **per-Space keyspace + membership-scoped presign**

Today: `chunks/<user_id>/<hash>`, SigV4-signed → cross-user access is *structurally
impossible* (CLAUDE.md §8). Sharing **requires** a controlled cross-user byte path. Three
options were evaluated:

| Option | How | Verdict |
|---|---|---|
| **(A) Per-Space keyspace** `chunks/space/<space_id>/<hash>`; presigner mints a URL iff the requester is a **member** of that Space (membership-scoped, not user-scoped). | Storage + dedup are **per-Space**. The presign key carries `space_id`, signed; Rails checks membership before signing. | **CHOSEN.** |
| (B) Copy-on-share — duplicate the shared subtree's chunks into the recipient's keyspace. | Keeps per-user keys untouched. | Rejected: doubles storage per share, breaks live collaboration (a new commit isn't auto-copied), and a multi-member Space needs N copies. |
| (C) Grant table the presigner consults, chunks stay in owner's keyspace `chunks/<owner_user>/<hash>`. | A `chunk_grants` row per (chunk, grantee). | Rejected: per-chunk grant explosion (a Space has millions of chunks), and the presign key still points at the *owner's* user prefix, re-opening exactly the cross-user-prefix surface §8 closed. |

**Why (A) preserves both invariants:**
- *Bytes never through Rails:* unchanged — the data plane is still presigned PUT/GET straight
  to object storage; only the key prefix and the authorization predicate change.
- *Untamperable presign:* the `space_id` is **inside the signed key**, exactly as `user_id` is
  today. A member of Space X cannot retarget a URL at Space Y's prefix (the signature won't
  verify), and Rails refuses to *sign* a key for a Space the requester isn't a member of. So
  cross-Space access is impossible by the same mechanism that makes cross-user access
  impossible today — we widen the unit from user to Space, we do not weaken the mechanism.
- *Dedup:* survives **within a Space** (its members dedup against each other). Cross-Space
  dedup is lost — but cross-user dedup is *already* lost today (per-user keyspace), so we lose
  nothing relative to the status quo, and we gain dedup among collaborators on the same Space.
- *Encryption seam (future, Phase B of parity-roadmap):* a per-Space keyspace is also the
  right unit for a per-Space content key — flag for the encryption plan (Risks).

The presigner signature changes from `key_for(user_id, hash)` to `key_for(space_id, hash)`,
and `chunks#download` / `Sync::Commit#begin` gate on **Space membership** instead of chunk
ownership. The self-host `local` blob path (`chunks/blob/...`) changes identically.

### Decision 3 — Permissions, roles, and share links

- **Roles** (on `SpaceMembership`): `viewer` (read + hydrate), `editor` (read + commit/move/
  delete/lock), `owner` (editor + manage members + manage links + delete Space). The home
  Space's owner is the user; cannot be removed.
- **Per-folder grants** (v1.1, Phase 5): the v1 unit is the *whole Space*. A "share this
  subfolder" is implemented by **promoting the subtree into its own Space** (the oCIS model)
  rather than sub-Space ACLs — keeps the authz check O(1) per request (membership of the
  Space the node belongs to) instead of a per-node ancestor walk. Sub-folder ACLs within a
  Space are explicitly deferred (Risks).
- **Share links** (`ShareLink`): a capability token granting `viewer` (or `editor`) to anyone
  with the URL. Properties: `role`, optional `expires_at`, optional `password_digest`
  (bcrypt), `revoked_at`. A link redeem mints a **scoped, link-derived read capability** — NOT
  a device token and NOT full membership — so revoking the link instantly cuts access (the
  presigner checks the link is live on every URL mint). Public/expiring/password all enforced
  server-side at redeem + at every presign.
- **Revocation:** removing a `SpaceMembership` or revoking a `ShareLink` takes effect on the
  **next presign** (≤ presign TTL, 15 min PUT / 60 min GET) — already-minted URLs live out
  their short TTL, which is the same bound that exists today. No history rewrite.
- **Enforcement happens in exactly two places** (so the audit surface is small): (1) the
  **presigner gate** (can this requester get bytes for this Space?), and (2) the
  **mutation/commit gate** (can this requester write to this Space?). Read-metadata
  (`changes`/`tree`) gates on membership too, but leaking *metadata* without bytes is the
  lower-severity surface; bytes are the crux.

---

## File Structure (what each new/changed unit owns)

**New models (Phase 1):**
- `app/models/space.rb` — the shareable container; holds `head_seq`, `next_seq!` (moved off
  User), `kind` (`home`/`shared`). One clear responsibility: be the changelog-owning tenant.
- `app/models/space_membership.rb` — `(space, user, role)`; the authz source of truth.
- `app/models/share_link.rb` — capability token (`token_digest`, `role`, `expires_at`,
  `password_digest`, `revoked_at`); link redemption + liveness check.

**New services (Phase 4–5):**
- `app/services/sync/membership.rb` — `member?(space:, user:)`, `role_for`, `can_write?`,
  `can_read?`. The *single* authz predicate every controller calls. (DRY: never inline an
  authz check in a controller.)
- `app/services/sharing/links.rb` — create/redeem/revoke a `ShareLink`; password + expiry +
  revocation checks. One responsibility: link lifecycle.

**Changed (scope key widens `user` → `space`):**
- `Storage::ChunkStore` + 3 backends — `key_for(space_id, hash)`, `presign_*(space_id, …)`,
  `exists?/list/delete(space_id, …)`.
- `Sync::Commit`, `Sync::Mutation`, `Sync::Changes`, `Sync::Tree`, `Sync::Conflicts`,
  `Sync::Locks`, `Sync::Gc`, `Sync::RetentionPolicy` — operate on a `space` not a `user`.
- All `V1::*` sync controllers — resolve the target Space from the request + gate on membership.

**New controllers (Phase 2/5):**
- `app/controllers/v1/spaces_controller.rb` — list/create Spaces, list/add/remove members.
- `app/controllers/v1/share_links_controller.rb` — create/list/revoke links.
- `app/controllers/share_redeem_controller.rb` (web, no bearer) — public link landing + redeem.

**Rust client (Phase 6):**
- `client/fs-provider` — a `space_id` column on the local tree + a per-Space cursor in
  `sync_state`; `feeds` table listing joined Spaces.
- `client/sync-engine` — `sync_tick` iterates feeds; mount roots Spaces under
  `/<MakerDrive>/Shared/<space_name>` alongside the home tree.
- `client/sync-client` — `list_spaces`, `pull_changes(space_id, cursor)`,
  `commit(space_id, …)`, `redeem_link`.

---

## PHASE 0 — Decision record + scope freeze

### Task 1: Write the ADR locking the three decisions

**Files:**
- Create: `docs/adr/0007-sharing-spaces.md`

- [ ] **Step 1: Write the ADR**

Document, in `docs/adr/` house style (see existing ADRs): (a) Space-with-own-feed over
grafting; (b) per-Space keyspace `chunks/space/<space_id>/<hash>` over copy-on-share/grant
table; (c) Space-as-share-unit with link capabilities over per-node ACLs; (d) the explicit
dependency order **auth(G3) → sharing → encryption(G14)** and the explicit non-goals
(sub-folder ACLs within a Space, real-time co-editing, cross-Space dedup).

- [ ] **Step 2: Cross-link**

Add a one-line pointer to this ADR from `docs/parity-roadmap.md` §C4 and
`docs/plan-file-layer-parity.md` G12. Note in `CLAUDE.md` §8 that "tenant = user" is now
"tenant = Space; a user's home Space is their library" (one-line; do not restructure §8).

- [ ] **Step 3: Commit**

```bash
git add docs/adr/0007-sharing-spaces.md docs/parity-roadmap.md docs/plan-file-layer-parity.md CLAUDE.md
git commit -m "docs(sharing): ADR 0007 — Spaces, per-space keyspace, link capabilities"
```

---

## PHASE 1 — Schema: introduce Space as the changelog-owning tenant

> **Invariant to preserve throughout:** every existing single-user behavior is the special
> case "user has one home Space". No PG-only SQL; `next_seq!`'s `FOR UPDATE`/reload pattern is
> copied verbatim from `User`, only the locked row changes from a user to a Space.

### Task 2: Create `spaces` + `space_memberships`, backfill a home Space per user

**Files:**
- Create: `db/migrate/XXXXXX_create_spaces.rb`
- Create: `db/migrate/XXXXXX_create_space_memberships.rb`
- Create: `db/migrate/XXXXXX_backfill_home_spaces.rb`
- Create: `app/models/space.rb`
- Create: `app/models/space_membership.rb`
- Modify: `app/models/user.rb` (add `has_many :space_memberships`, `:spaces, through:`,
  `home_space`)
- Test: `test/models/space_test.rb`, `test/models/space_membership_test.rb`

- [ ] **Step 1: Write the failing model test**

```ruby
# test/models/space_test.rb
require "test_helper"
class SpaceTest < ActiveSupport::TestCase
  test "next_seq! is monotonic and locks the space row" do
    space = Space.create!(kind: "home", head_seq: 0)
    assert_equal 1, space.next_seq!
    assert_equal 2, space.next_seq!
    assert_equal 2, space.reload.head_seq
  end

  test "a user gets exactly one home space" do
    user = User.create!(email: "a@example.com")
    assert_equal 1, user.spaces.where(kind: "home").count
    assert user.home_space.present?
    assert_equal "owner", user.space_memberships.find_by(space: user.home_space).role
  end
end
```

- [ ] **Step 2: Run it; verify it fails**

Run: `bin/rails test test/models/space_test.rb -v`
Expected: FAIL — `uninitialized constant Space`.

- [ ] **Step 3: Write the migrations**

```ruby
# db/migrate/XXXXXX_create_spaces.rb
class CreateSpaces < ActiveRecord::Migration[8.0]
  def change
    create_table :spaces do |t|
      t.string  :space_uuid, null: false        # stable cross-device id
      t.string  :kind, null: false, default: "shared" # home | shared
      t.string  :name
      t.bigint  :head_seq, null: false, default: 0
      t.references :created_by, foreign_key: { to_table: :users }
      t.timestamps
    end
    add_index :spaces, :space_uuid, unique: true
  end
end
```

```ruby
# db/migrate/XXXXXX_create_space_memberships.rb
class CreateSpaceMemberships < ActiveRecord::Migration[8.0]
  def change
    create_table :space_memberships do |t|
      t.references :space, null: false, foreign_key: true
      t.references :user,  null: false, foreign_key: true
      t.string :role, null: false, default: "viewer" # viewer | editor | owner
      t.timestamps
    end
    add_index :space_memberships, %i[space_id user_id], unique: true
    add_index :space_memberships, %i[user_id space_id]
  end
end
```

```ruby
# db/migrate/XXXXXX_backfill_home_spaces.rb
class BackfillHomeSpaces < ActiveRecord::Migration[8.0]
  def up
    User.reset_column_information
    User.find_each do |u|
      next if Space.exists?(kind: "home", created_by_id: u.id)
      space = Space.create!(space_uuid: SecureRandom.uuid, kind: "home", created_by_id: u.id, head_seq: 0)
      SpaceMembership.create!(space:, user: u, role: "owner")
    end
  end
  def down; end
end
```

- [ ] **Step 4: Write the models**

```ruby
# app/models/space.rb
class Space < ApplicationRecord
  KINDS = %w[home shared].freeze
  belongs_to :created_by, class_name: "User", optional: true
  has_many :space_memberships, dependent: :destroy
  has_many :members, through: :space_memberships, source: :user
  has_many :share_links, dependent: :destroy
  validates :space_uuid, presence: true, uniqueness: true
  validates :kind, inclusion: { in: KINDS }

  # COPIED from User#next_seq! — same lock-ordering contract (lock the tenant row FIRST,
  # before any FK-bound write in the commit transaction). See app/models/user.rb comment.
  def next_seq!
    lock!
    new_seq = head_seq + 1
    update_column(:head_seq, new_seq)
    new_seq
  end
end
```

```ruby
# app/models/space_membership.rb
class SpaceMembership < ApplicationRecord
  ROLES = %w[viewer editor owner].freeze
  belongs_to :space
  belongs_to :user
  validates :role, inclusion: { in: ROLES }
  validates :user_id, uniqueness: { scope: :space_id }
  def can_write? = role.in?(%w[editor owner])
  def can_manage? = role == "owner"
end
```

```ruby
# app/models/user.rb  (additions only — keep next_seq! for now; Task 5 moves callers)
has_many :space_memberships, dependent: :destroy
has_many :spaces, through: :space_memberships
def home_space = spaces.find_by(kind: "home")
```

Wire home-Space creation into account creation: in the place a `User` is first persisted with
a verified identity (registration / `from_omniauth`), create the home Space + owner membership
(extract a `User#ensure_home_space!` and call it). Backfill covers existing rows.

- [ ] **Step 5: Run the test; verify it passes**

Run: `bin/rails test test/models/space_test.rb test/models/space_membership_test.rb -v`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add db/migrate app/models/space.rb app/models/space_membership.rb app/models/user.rb test/models/space_test.rb test/models/space_membership_test.rb
git commit -m "feat(sharing): Space + SpaceMembership models, home-space backfill"
```

### Task 3: Add `space_id` to the per-tenant tables (nullable, backfilled to home Space)

**Files:**
- Create: `db/migrate/XXXXXX_add_space_to_tenant_tables.rb`
- Create: `db/migrate/XXXXXX_backfill_space_id.rb`
- Modify: `app/models/{node,version,chunk,manifest_chunk,changelog_entry,pending_commit,conflict,file_lock}.rb`
  (add `belongs_to :space, optional: true`)
- Test: `test/models/node_test.rb` (extend)

- [ ] **Step 1: Write the failing test**

```ruby
# test/models/node_test.rb  (add)
test "a node belongs to a space" do
  user = User.create!(email: "n@example.com")
  node = user.nodes.create!(node_id: SecureRandom.uuid, name: "f", kind: "file",
                            space: user.home_space)
  assert_equal user.home_space, node.space
end
```

- [ ] **Step 2: Run it; verify it fails**

Run: `bin/rails test test/models/node_test.rb -v`
Expected: FAIL — `unknown attribute 'space'` / no `space_id` column.

- [ ] **Step 3: Write the migration (add nullable `space_id` + index on each table)**

```ruby
# db/migrate/XXXXXX_add_space_to_tenant_tables.rb
class AddSpaceToTenantTables < ActiveRecord::Migration[8.0]
  TABLES = %i[nodes versions chunks manifest_chunks changelog_entries
              pending_commits conflicts file_locks]
  def change
    TABLES.each do |t|
      add_reference t, :space, foreign_key: true, null: true, index: true
    end
  end
end
```

```ruby
# db/migrate/XXXXXX_backfill_space_id.rb
class BackfillSpaceId < ActiveRecord::Migration[8.0]
  def up
    # Each existing row's owner user has exactly one home Space (Task 2 backfill).
    say_with_time "backfill space_id from owning user's home space" do
      execute <<~SQL
        UPDATE nodes SET space_id = (
          SELECT s.id FROM spaces s WHERE s.created_by_id = nodes.user_id AND s.kind = 'home'
        ) WHERE space_id IS NULL
      SQL
      # ...repeat for the other 7 tables (each has user_id today).
    end
  end
  def down; end
end
```

- [ ] **Step 4: Add `belongs_to :space, optional: true` to each model**

For each of the 8 models add `belongs_to :space, optional: true`. Keep `belongs_to :user`
(dual-keyed during migration; Phase 7 decides whether `user_id` is dropped or kept as a
denormalized convenience — keeping it is cheaper and lets `tenant_isolation_test` keep
asserting per-user scoping during transition).

Add to `changelog_entry.rb`: widen uniqueness to the Space — `validates :seq, uniqueness:
{ scope: :space_id }` (was `scope: :user_id`). Add to `node.rb`:
`validates :node_id, uniqueness: { scope: :space_id }`.

- [ ] **Step 5: Run the test; verify it passes**

Run: `bin/rails test test/models/node_test.rb -v`
Expected: PASS.

- [ ] **Step 6: Run the FULL existing suite — nothing may regress**

Run: `bin/rails test`
Expected: PASS (all existing tests; `space_id` is nullable + backfilled, so the per-user paths
are unaffected). **Gate: do not proceed if anything fails.**

- [ ] **Step 7: Commit**

```bash
git add db/migrate app/models
git commit -m "feat(sharing): add nullable space_id to tenant tables + backfill to home space"
```

---

## PHASE 2 — Space API (control plane: create/join/list, members)

### Task 4: Membership predicate service + Spaces controller

**Files:**
- Create: `app/services/sync/membership.rb`
- Create: `app/controllers/v1/spaces_controller.rb`
- Modify: `config/routes.rb` (v1 block)
- Test: `test/services/sync/membership_test.rb`,
  `test/integration/v1/spaces_test.rb`

- [ ] **Step 1: Write the failing service test**

```ruby
# test/services/sync/membership_test.rb
require "test_helper"
class Sync::MembershipTest < ActiveSupport::TestCase
  setup do
    @owner = User.create!(email: "o@example.com")
    @other = User.create!(email: "x@example.com")
    @space = Space.create!(space_uuid: SecureRandom.uuid, kind: "shared", created_by: @owner)
    SpaceMembership.create!(space: @space, user: @owner, role: "owner")
  end
  test "owner can read and write" do
    assert Sync::Membership.can_read?(space: @space, user: @owner)
    assert Sync::Membership.can_write?(space: @space, user: @owner)
  end
  test "non-member cannot read or write" do
    refute Sync::Membership.can_read?(space: @space, user: @other)
    refute Sync::Membership.can_write?(space: @space, user: @other)
  end
  test "viewer can read but not write" do
    SpaceMembership.create!(space: @space, user: @other, role: "viewer")
    assert Sync::Membership.can_read?(space: @space, user: @other)
    refute Sync::Membership.can_write?(space: @space, user: @other)
  end
end
```

- [ ] **Step 2: Run it; verify it fails**

Run: `bin/rails test test/services/sync/membership_test.rb -v`
Expected: FAIL — `uninitialized constant Sync::Membership`.

- [ ] **Step 3: Write the service**

```ruby
# app/services/sync/membership.rb
module Sync
  # The SINGLE authz predicate for Space access. Every sync controller resolves a target
  # Space and calls one of these — never inline an authz check. Returns booleans; the
  # controller maps false to 403/404 (404-on-read to avoid leaking Space existence).
  module Membership
    def self.role(space:, user:)
      return nil if user.nil? || space.nil?
      space.space_memberships.find_by(user_id: user.id)&.role
    end
    def self.can_read?(space:, user:)  = role(space:, user:).in?(SpaceMembership::ROLES)
    def self.can_write?(space:, user:) = role(space:, user:).in?(%w[editor owner])
    def self.can_manage?(space:, user:) = role(space:, user:) == "owner"
  end
end
```

- [ ] **Step 4: Write the Spaces controller + routes**

```ruby
# app/controllers/v1/spaces_controller.rb
module V1
  class SpacesController < BaseController
    # GET /v1/spaces -> the Spaces this user can sync (home + joined shared).
    def index
      spaces = current_user.spaces.select(:id, :space_uuid, :kind, :name, :head_seq)
      render json: { spaces: spaces.map { |s| serialize(s) } }
    end

    # POST /v1/spaces { name } -> create a shared Space owned by the caller.
    def create
      space = Space.create!(space_uuid: SecureRandom.uuid, kind: "shared",
                            name: params.require(:name), created_by: current_user)
      SpaceMembership.create!(space:, user: current_user, role: "owner")
      render json: serialize(space), status: :created
    end

    # POST /v1/spaces/:space_uuid/members { email, role } -> add a member (owner only).
    def add_member
      space = current_user.spaces.find_by!(space_uuid: params[:space_uuid])
      return forbid unless Sync::Membership.can_manage?(space:, user: current_user)
      invitee = User.confirmed.find_by!(email: params.require(:email).to_s.downcase)
      role = params.fetch(:role, "viewer")
      m = SpaceMembership.find_or_initialize_by(space:, user: invitee)
      m.update!(role:)
      render json: { ok: true }, status: :created
    end

    # DELETE /v1/spaces/:space_uuid/members/:user_id -> revoke (owner only; never the last owner).
    def remove_member
      space = current_user.spaces.find_by!(space_uuid: params[:space_uuid])
      return forbid unless Sync::Membership.can_manage?(space:, user: current_user)
      m = space.space_memberships.find_by!(user_id: params[:user_id])
      return render(json: { error: "cannot remove last owner" }, status: :unprocessable_entity) if last_owner?(space, m)
      m.destroy!
      head :no_content
    end

    private
    def serialize(s) = { space_uuid: s.space_uuid, kind: s.kind, name: s.name, head_seq: s.head_seq }
    def forbid = render(json: { error: "forbidden" }, status: :forbidden)
    def last_owner?(space, m) = m.role == "owner" && space.space_memberships.where(role: "owner").count <= 1
  end
end
```

```ruby
# config/routes.rb  (inside namespace :v1, near the devices block)
resources :spaces, only: %i[index create], param: :space_uuid do
  member do
    post   "members",            to: "spaces#add_member"
    delete "members/:user_id",   to: "spaces#remove_member"
  end
end
```

- [ ] **Step 5: Write the integration test (create, add member, list, non-member 403)**

```ruby
# test/integration/v1/spaces_test.rb — owner creates Space, adds a confirmed user as viewer,
# the viewer sees it in GET /v1/spaces, a non-owner gets 403 on add_member,
# remove_member of the last owner is 422. (Use the device-token auth helper used by the
# other v1 integration tests.)
```

- [ ] **Step 6: Run the tests; verify they pass**

Run: `bin/rails test test/services/sync/membership_test.rb test/integration/v1/spaces_test.rb -v`
Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add app/services/sync/membership.rb app/controllers/v1/spaces_controller.rb config/routes.rb test/services/sync/membership_test.rb test/integration/v1/spaces_test.rb
git commit -m "feat(sharing): Space CRUD + membership API + Sync::Membership authz predicate"
```

**Risk (this phase):** `add_member` by email enables enumeration of registered emails. Return a
generic 201 whether or not the email exists for an *invite*; only attach membership if a
**confirmed** user matches. (Confirmed-only is why **G3 OAuth/email-verification must land
first** — Risks.)

---

## PHASE 3 — Presigner + storage: per-Space keyspace (THE CRUX)

> This is the load-bearing phase. The data plane stays presigned + bytes-out-of-Rails; only
> the key prefix (`user_id` → `space_id`) and the authorization predicate (chunk-ownership →
> Space membership) change.

### Task 5: Re-key the ChunkStore from user to Space

**Files:**
- Modify: `app/services/storage/chunk_store.rb` (interface)
- Modify: `app/services/storage/s3_chunk_store.rb` (`key_for(space_id, hash)`, all 5 methods)
- Modify: `app/services/storage/local_chunk_store.rb` (key + HMAC over `space_id`)
- Modify: `app/services/storage/memory_chunk_store.rb`
- Test: `test/services/storage/chunk_store_key_test.rb`

- [ ] **Step 1: Write the failing test**

```ruby
# test/services/storage/chunk_store_key_test.rb
require "test_helper"
class ChunkStoreKeyTest < ActiveSupport::TestCase
  test "s3 key is space-scoped" do
    store = Storage::S3ChunkStore.new(bucket: "b", region: "us-east-1",
              access_key_id: "k", secret_access_key: "s", endpoint: "http://x:8333")
    assert_equal "chunks/space/42/abc", store.send(:key_for, 42, "abc")
  end
  test "local presign+verify round-trips on a space id" do
    url = Storage::LocalChunkStore.new.presign_get(7, "deadbeef")
    q = Rack::Utils.parse_query(URI(url).query)
    assert Storage::LocalChunkStore.verify(7, "deadbeef", q["exp"], q["sig"])
    refute Storage::LocalChunkStore.verify(8, "deadbeef", q["exp"], q["sig"]) # other space rejected
  end
end
```

- [ ] **Step 2: Run it; verify it fails**

Run: `bin/rails test test/services/storage/chunk_store_key_test.rb -v`
Expected: FAIL — key is `chunks/<id>/...` (no `space/` segment) and/or the verify accepts the
wrong scope id.

- [ ] **Step 3: Change `key_for` + signatures to take a `space_id`**

In each backend, rename the first param `user_id` → `space_id` and change the key prefix to
`"chunks/space/#{space_id}/#{hash}"`. Keep the method *names* (`presign_put`, `presign_get`,
`exists?`, `list`, `delete`) — only the semantics of arg 1 change. For `LocalChunkStore` the
HMAC must be computed over `space_id` (so a URL signed for Space 7 cannot be replayed for
Space 8 — the test above asserts this). For `S3ChunkStore`, `space_id` is inside the signed
key, so SigV4 already binds it.

> **Key-prefix migration note:** existing objects live under `chunks/<user_id>/<hash>`. Since
> each user's home `space_id` ≠ their `user_id`, switching the prefix orphans existing bytes.
> Two options, decided in Phase 7: (a) a one-time storage copy/rename `chunks/<user_id>/` →
> `chunks/space/<home_space_id>/` (S3 server-side copy + delete; the reaper cleans the old
> prefix), or (b) a `legacy_key` fallback in `presign_get`/`exists?` that also checks the old
> `chunks/<user_id>/` prefix until re-uploaded. **Choose (a)** for managed (clean keyspace);
> document (b) as the zero-downtime self-host path. Add this to Task 18.

- [ ] **Step 4: Run the test; verify it passes**

Run: `bin/rails test test/services/storage/chunk_store_key_test.rb -v`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add app/services/storage test/services/storage/chunk_store_key_test.rb
git commit -m "feat(sharing): re-key ChunkStore from user to space (chunks/space/<id>/<hash>)"
```

### Task 6: Gate `chunks#download` (presign) on Space membership

**Files:**
- Modify: `app/controllers/v1/chunks_controller.rb`
- Modify: `config/routes.rb` (download now takes a Space)
- Test: `test/integration/v1/chunks_presign_test.rb`

- [ ] **Step 1: Write the failing test**

```ruby
# test/integration/v1/chunks_presign_test.rb
# A member of a Space gets presigned GET URLs for chunks owned by that Space.
# A NON-member requesting the same Space's chunks gets {} (no URLs) — the crux assertion.
# (Set up a shared Space with a chunk row scoped to it; one device-token member, one non-member.)
```

- [ ] **Step 2: Run it; verify it fails**

Run: `bin/rails test test/integration/v1/chunks_presign_test.rb -v`
Expected: FAIL — current `download` keys off `current_user.id`, has no Space concept.

- [ ] **Step 3: Rewrite `download` to resolve + gate the Space**

```ruby
# app/controllers/v1/chunks_controller.rb
module V1
  class ChunksController < BaseController
    # POST /v1/chunks/download { space_uuid, hashes: [...] } -> { urls: { hash => GET } }
    # Membership-scoped (the crux): only mint URLs if the caller is a MEMBER of the Space,
    # and only for hashes that Space actually references. The space_id is inside the signed
    # key, so a member of one Space cannot retarget a URL at another Space's prefix.
    def download
      space = resolve_space!
      return render(json: { urls: {} }, status: :forbidden) unless Sync::Membership.can_read?(space:, user: current_user)
      hashes = Array(params[:hashes]).map(&:to_s).uniq
      owned = space.chunks.where(chunk_hash: hashes).pluck(:chunk_hash).to_set
      store = Storage::ChunkStore.current
      urls = hashes.index_with { |h| owned.include?(h) ? store.presign_get(space.id, h) : nil }.compact
      render json: { urls: }
    end

    private
    # Resolve the target Space from the request and confirm the caller can even see it.
    def resolve_space!
      current_user.spaces.find_by!(space_uuid: params.require(:space_uuid))
    end
  end
end
```

`space.chunks` is `has_many :chunks` on `Space` (add it). Note `find_by!` on
`current_user.spaces` already restricts to spaces the caller is a member of, so a non-member
hits `RecordNotFound` (→ 404) — and the explicit `can_read?` is defense-in-depth for the
viewer/role nuance.

- [ ] **Step 4: Run the test; verify it passes**

Run: `bin/rails test test/integration/v1/chunks_presign_test.rb -v`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add app/controllers/v1/chunks_controller.rb app/models/space.rb test/integration/v1/chunks_presign_test.rb
git commit -m "feat(sharing): presigner gates chunk download on space membership"
```

### Task 7: Same gate on the self-host `local` blob path

**Files:**
- Modify: `app/controllers/v1/chunks/blob_controller.rb` (verify over `space_id`)
- Modify: `config/routes.rb` (`chunks/blob/:space_id/:hash`)
- Test: `test/integration/v1/chunks/blob_space_test.rb`

- [ ] **Step 1: Write the failing test** — a blob PUT/GET signed for Space A verifies; the
  same `sig` replayed with Space B in the path is `403` (the HMAC is over `space_id`).
- [ ] **Step 2: Run it; verify it fails.**
- [ ] **Step 3:** Rename the path param `:user_id`→`:space_id`; `verify_signature` passes
  `params[:space_id]` to `LocalChunkStore.verify`. Bytes still flow only for the self-host
  `local` backend (unchanged), now Space-scoped.
- [ ] **Step 4: Run it; verify it passes.**
- [ ] **Step 5: Commit** `feat(sharing): space-scope the self-host local blob path`.

---

## PHASE 4 — Sync protocol: per-Space commit / changelog / conflicts / locks

> Mechanical generalization: every `Sync::*` service takes a `space:` instead of (or in
> addition to) `user:`, and `next_seq!` locks the **Space** row. The lock-ordering contract
> (lock the tenant row first) is identical — see `User#next_seq!` comment.

### Task 8: `Sync::Commit` commits to a Space

**Files:**
- Modify: `app/services/sync/commit.rb` (thread `space:` through begin/finalize; presign with
  `space.id`; `space.next_seq!`; chunks/manifest/version/node/changelog scoped to `space`)
- Modify: `app/controllers/v1/commits_controller.rb` (resolve + write-gate the Space)
- Test: `test/services/sync/commit_test.rb` (extend with a shared-Space commit)

- [ ] **Step 1: Write the failing test** — an editor commits a file into a shared Space; the
  version/node/changelog all carry that `space_id`; `space.head_seq` advanced (not the user's).
  A **viewer** commit is rejected (`can_write?` false → 403 at the controller).
- [ ] **Step 2: Run it; verify it fails** (Commit still keys off `user`).
- [ ] **Step 3: Implement** — change `self.begin`/`self.finalize` to accept `space:`; replace
  `user.next_seq!` with `space.next_seq!`; replace `user.chunks/versions/nodes/changelog_entries`
  with `space.*`; replace `store.presign_put(user.id, h)` with `store.presign_put(space.id, h)`.
  In `commits_controller`, `space = resolve_space!` + `head :forbidden unless can_write?`.
  **Keep `device_id` on the version** (cross-user attribution: a Space version records *which
  user's device* wrote it — needed for the cross-user conflict rule, Task 11).
- [ ] **Step 4: Run it; verify it passes.**
- [ ] **Step 5: Run the full `commit_test.rb` + `concurrent_seq_test.rb`** — the
  no-deadlock/gapless-seq guarantees must hold with the Space as the locked row.
  Expected: PASS.
- [ ] **Step 6: Commit** `feat(sharing): Sync::Commit writes to a Space; viewer commits rejected`.

### Task 9: `Sync::Mutation` (mkdir/delete/move/restore) on a Space

**Files:**
- Modify: `app/services/sync/mutation.rb` (`space.next_seq!`, `space.changelog_entries`)
- Modify: `app/controllers/v1/nodes_controller.rb` (resolve + write-gate the Space per action)
- Test: `test/services/sync/` (a mutation test in a shared Space)

- [ ] **Step 1–5:** failing test → run → implement (`apply(space:, node:, op:)`, lock the
  Space) → run → commit. Write-gate every mutating node action; reads (`versions`) gate on
  `can_read?`. Commit `feat(sharing): metadata mutations are space-scoped + write-gated`.

### Task 10: `Sync::Changes` + `Sync::Tree` serve a Space's feed

**Files:**
- Modify: `app/services/sync/changes.rb` (`space.changelog_entries.since`, `space.nodes`,
  `space.versions`, `space.head_seq`, `oldest_seq` per Space)
- Modify: `app/services/sync/tree.rb` (`space.nodes.present`, `space.versions`)
- Modify: `app/controllers/v1/{changes,tree}_controller.rb` (resolve + read-gate the Space;
  the `space_uuid` is a required param)
- Test: extend `test/services/sync/{changes_test,tree_test}.rb`

- [ ] **Step 1: Failing test** — `Sync::Changes.call(space:, since:)` returns only that Space's
  entries with that Space's `head_seq`; a member of Space A pulling Space B's feed via the
  controller gets 404 (not a member).
- [ ] **Step 2–4:** run → implement → run.
- [ ] **Step 5: Commit** `feat(sharing): changes/tree are per-Space feeds, read-gated`.

### Task 11: Cross-USER conflict detection (extend the per-user `base_version_id` model)

**Files:**
- Modify: `app/services/sync/conflicts.rb` (+ the conflict branch already in `Sync::Commit`)
- Test: `test/services/sync/conflicts_test.rb` (two *different users* in one Space)

- [ ] **Step 1: Write the failing test**

Today's conflict rule (Commit.rb lines 91–104) suppresses a conflict when the prior current
version came from the **same device** (a device racing its own echo). In a Space, two
**different users** can hold the same `base_version_id` and both commit. Test: user A (editor)
and user B (editor) both base on version V; B finalizes first (current→V_b); A finalizes with
base V → **must record a conflict** (not fast-forward), and the `conflict` changelog entry is
visible to *both* users on their next pull.

```ruby
# test/services/sync/conflicts_test.rb  (add)
test "two different users editing from the same base records a cross-user conflict" do
  # space with userA, userB both editors; both base on version V; B commits then A commits;
  # assert a Conflict row exists keyed by A's incoming version, op "conflict" in the feed.
end
```

- [ ] **Step 2: Run it; verify it fails OR mis-suppresses.** The same-device suppression must
  NOT fire across users (different devices belong to different users → already different
  `device_id`, so the existing guard is *correct* — but add the test to lock it, and audit
  that `device_id` uniqueness across users holds). Expected: confirm the conflict is recorded.
- [ ] **Step 3: Implement/confirm** — the existing `device_id != pending.device_id` guard
  already distinguishes users (devices are per-user). Add an explicit assertion + a comment in
  `commit.rb` that *cross-user* divergence is the primary conflict case in a Space. If any
  same-user-multi-device suppression incorrectly swallows a cross-user conflict, tighten to
  compare the version's **owning user** as well as device.
- [ ] **Step 4: Run it; verify it passes.**
- [ ] **Step 5: Commit** `feat(sharing): cross-user conflict detection in shared Spaces`.

### Task 12: Cross-USER advisory locks in a Space

**Files:**
- Modify: `app/services/sync/locks.rb` (`space.file_locks`; lock identity is `(space, device)`,
  and the "held_by_other" check must compare across users, which it already does via
  `device_id`)
- Modify: `app/controllers/v1/{nodes,locks}_controller.rb` (resolve + read-gate the Space)
- Test: `test/services/sync/locks_test.rb` (user A locks, user B sees not-by-me)

- [ ] **Step 1–5:** failing test (B sees A's live lock as held-by-other; respects TTL) → run →
  implement (`acquire(space:, node_id:, device:)`) → run → commit
  `feat(sharing): best-effort advisory locks span users within a Space`.

### Task 13: GC / retention per Space

**Files:**
- Modify: `app/services/sync/gc.rb`, `app/services/sync/retention_policy.rb`,
  `app/jobs/retention_job.rb`, `app/services/sync/chunk_reaper.rb` (iterate Spaces, not Users;
  `store.list/delete(space.id, …)`)
- Test: extend `test/services/sync/{gc_test,retention_policy_test,chunk_reaper_test}.rb`

- [ ] **Step 1: Failing test** — sweeping refcount-0 chunks in Space A does not touch Space B's
  identical-hash chunk (per-Space refcount + per-Space keyspace → no cross-Space delete). The
  reaper lists `chunks/space/<id>/` per Space.
- [ ] **Step 2–4:** run → implement → run.
- [ ] **Step 5: Commit** `feat(sharing): GC/retention/orphan-reaper iterate per Space`.

---

## PHASE 5 — Permissions surface: roles enforced + share links

### Task 14: `ShareLink` model + capability redeem

**Files:**
- Create: `db/migrate/XXXXXX_create_share_links.rb`
- Create: `app/models/share_link.rb`
- Create: `app/services/sharing/links.rb`
- Test: `test/models/share_link_test.rb`, `test/services/sharing/links_test.rb`

- [ ] **Step 1: Write the failing test**

```ruby
# test/services/sharing/links_test.rb
require "test_helper"
class Sharing::LinksTest < ActiveSupport::TestCase
  setup do
    @owner = User.create!(email: "o@example.com")
    @space = Space.create!(space_uuid: SecureRandom.uuid, kind: "shared", created_by: @owner)
    SpaceMembership.create!(space: @space, user: @owner, role: "owner")
  end
  test "redeem a live viewer link yields a read capability" do
    raw = Sharing::Links.create!(space: @space, role: "viewer").raw_token
    cap = Sharing::Links.redeem(raw)
    assert cap.can_read?
    refute cap.can_write?
  end
  test "expired link cannot be redeemed" do
    link = Sharing::Links.create!(space: @space, role: "viewer", expires_at: 1.hour.ago)
    assert_nil Sharing::Links.redeem(link.raw_token)
  end
  test "password-protected link requires the password" do
    link = Sharing::Links.create!(space: @space, role: "viewer", password: "hunter2")
    assert_nil Sharing::Links.redeem(link.raw_token, password: "wrong")
    assert Sharing::Links.redeem(link.raw_token, password: "hunter2")&.can_read?
  end
  test "revoked link cannot be redeemed" do
    link = Sharing::Links.create!(space: @space, role: "viewer")
    Sharing::Links.revoke!(link)
    assert_nil Sharing::Links.redeem(link.raw_token)
  end
end
```

- [ ] **Step 2: Run it; verify it fails** — `uninitialized constant Sharing::Links`.

- [ ] **Step 3: Migration + model + service**

```ruby
# db/migrate/XXXXXX_create_share_links.rb
class CreateShareLinks < ActiveRecord::Migration[8.0]
  def change
    create_table :share_links do |t|
      t.references :space, null: false, foreign_key: true
      t.references :created_by, foreign_key: { to_table: :users }
      t.string   :token_digest, null: false       # SHA256 of the raw capability token
      t.string   :role, null: false, default: "viewer"
      t.string   :password_digest                 # bcrypt; nil = no password
      t.datetime :expires_at
      t.datetime :revoked_at
      t.timestamps
    end
    add_index :share_links, :token_digest, unique: true
  end
end
```

```ruby
# app/models/share_link.rb
class ShareLink < ApplicationRecord
  has_secure_password :password, validations: false  # optional password
  belongs_to :space
  belongs_to :created_by, class_name: "User", optional: true
  attr_reader :raw_token
  ROLES = %w[viewer editor].freeze   # links never grant owner
  validates :role, inclusion: { in: ROLES }

  def live?  = revoked_at.nil? && (expires_at.nil? || expires_at.future?)
  def self.digest(raw) = Digest::SHA256.hexdigest(raw.to_s)
end
```

```ruby
# app/services/sharing/links.rb
module Sharing
  module Links
    # A read-or-write capability scoped to one Space, derived from a live link. NOT a device
    # token and NOT a membership — revoking the link cuts access on the next presign.
    Capability = Struct.new(:space, :role, keyword_init: true) do
      def can_read?  = true
      def can_write? = role == "editor"
    end

    def self.create!(space:, role: "viewer", expires_at: nil, password: nil, created_by: nil)
      raw = SecureRandom.urlsafe_base64(32)
      link = ShareLink.create!(space:, role:, expires_at:, created_by:,
                               token_digest: ShareLink.digest(raw))
      link.update!(password:) if password
      link.instance_variable_set(:@raw_token, raw)
      link
    end

    def self.redeem(raw, password: nil)
      link = ShareLink.find_by(token_digest: ShareLink.digest(raw))
      return nil unless link&.live?
      return nil if link.password_digest.present? && !link.authenticate_password(password.to_s)
      Capability.new(space: link.space, role: link.role)
    end

    def self.revoke!(link) = link.update!(revoked_at: Time.current)
  end
end
```

- [ ] **Step 4: Run the tests; verify they pass.**

Run: `bin/rails test test/models/share_link_test.rb test/services/sharing/links_test.rb -v`
Expected: PASS.

- [ ] **Step 5: Commit** `feat(sharing): ShareLink model + capability redeem (expire/password/revoke)`.

### Task 15: Share-link API + redeem endpoint + link-scoped presign

**Files:**
- Create: `app/controllers/v1/share_links_controller.rb` (owner: create/list/revoke)
- Create: `app/controllers/v1/link_access_controller.rb` (redeem → short-lived link session;
  presign GETs under a redeemed link)
- Modify: `app/controllers/v1/chunks_controller.rb` (accept a redeemed-link capability as an
  alternate authorization to membership, read-only)
- Modify: `config/routes.rb`
- Test: `test/integration/v1/share_links_test.rb`

- [ ] **Step 1: Write the failing test** — owner creates a viewer link; an anonymous client
  redeems it (with password if set) and can list the Space tree + presign **GET** (read) but
  **not** PUT/commit (write); after `revoke!`, the next presign returns 403.
- [ ] **Step 2: Run it; verify it fails.**
- [ ] **Step 3: Implement** — the redeem path issues a **link-scoped, short-TTL session token**
  (signed, carrying `space_id` + `role` + link id) that the read endpoints accept *in addition
  to* a device bearer token. Every presign under a link **re-checks `link.live?`** (so
  revocation is immediate-on-next-presign). Links are capped at `viewer`/`editor` — never owner,
  never member-management. The redeem session is **disjoint from device tokens** (Risks:
  link tokens must not be promotable to a device/library credential).
- [ ] **Step 4: Run it; verify it passes.**
- [ ] **Step 5: Commit** `feat(sharing): share-link API + link-scoped read capability + presign`.

### Task 16: "Share a subfolder" = promote subtree to its own Space

**Files:**
- Create: `app/services/sharing/promote_subtree.rb`
- Modify: `app/controllers/v1/spaces_controller.rb` (a `promote` action)
- Test: `test/services/sharing/promote_subtree_test.rb`

- [ ] **Step 1: Write the failing test** — promoting a subtree of the home Space into a new
  shared Space re-parents the subtree's nodes/versions/manifest-chunks/chunks under the new
  `space_id` (chunks **copied/re-keyed** into the new Space's keyspace, dedup-preserved within
  the source via refcount), emits a `delete` (move-out) in the source feed + a snapshot in the
  new feed, and the source user is `owner` of the new Space. Assert no bytes lost: every chunk
  the subtree referenced is present under `chunks/space/<new_id>/`.
- [ ] **Step 2: Run it; verify it fails.**
- [ ] **Step 3: Implement** — a transactional re-key of the subtree's rows to the new
  `space_id` + a storage copy of referenced chunk objects to the new keyspace (server-side S3
  copy; for `local`, a byte copy). This is the only place chunks cross keyspaces — gate it on
  `can_manage?` of the source Space and do it server-side so the client just re-pulls both
  feeds. Document the storage-copy cost.
- [ ] **Step 4: Run it; verify it passes.**
- [ ] **Step 5: Commit** `feat(sharing): promote a subfolder into its own shared Space`.

---

## PHASE 6 — Client: multi-feed sync loop + Shared mount surface

> The client today pulls **one** feed (home) with **one** cursor and mounts **one** tree. It
> must pull **home + N joined Spaces** and surface them under a `Shared/` root.

### Task 17: `fs-provider` — per-Space tree + cursor

**Files:**
- Modify: `client/fs-provider` schema (add `space_id` to local `nodes`; a `feeds` table:
  `space_id, space_uuid, name, kind, cursor`)
- Modify: `fs-provider` `apply_remote`/`apply_remote_delete`/`export_tree` to take a `space_id`
- Test: `client/fs-provider/tests/` (a multi-space apply test)

- [ ] **Step 1: Write the failing Rust test** — applying two feeds (home + one shared) keeps
  their trees disjoint by `space_id`; a `node_id` collision across Spaces does not merge (the
  local unique key becomes `(space_id, node_id)`).
- [ ] **Step 2: Run it; verify it fails** (`cargo test -p fs-provider`).
- [ ] **Step 3: Implement** — add `space_id` to the local schema + a `feeds` table; key the
  local tree by `(space_id, node_id)`; per-feed cursor in `sync_state`.
- [ ] **Step 4: Run it; verify it passes.**
- [ ] **Step 5: Commit** `feat(sharing/client): per-space local tree + per-feed cursor`.

### Task 18: `sync-client` — Space-aware API + key-prefix migration helper

**Files:**
- Modify: `client/sync-client` (typed `list_spaces`, `pull_changes(space_uuid, cursor)`,
  `commit(space_uuid, …)`, `presign download(space_uuid, hashes)`, `redeem_link`)
- Test: `client/sync-client/tests` (or an example against a running server)

- [ ] **Step 1–5:** failing test (list a created shared Space; pull its empty feed) → run →
  implement the `space_uuid` param on every call → run → commit
  `feat(sharing/client): Space-aware server API client`.
- Include the **legacy-key fallback** (Task 5 note) decision: client re-uploads on first
  shared commit; managed runs the server-side copy (Task 18 owns wiring the rake task
  `lib/tasks/chunks.rake` to copy `chunks/<user>/` → `chunks/space/<home>/`).

### Task 19: `sync-engine` — multi-feed `sync_tick` + Shared mount root

**Files:**
- Modify: `client/sync-engine` (`sync_tick` iterates `provider.feeds()`; push the home outbox +
  each shared Space's outbox; pull each feed's delta; nudge subscribes per-Space ActionCable
  channel)
- Modify: the mount layer — Spaces mount under `Shared/<space_name>/` beside the home tree
- Test: `client/sync-engine/tests/integration.rs` (extend)

- [ ] **Step 1: Write the failing test** — with two feeds, a commit in the shared Space pushes
  to that Space's outbox and pulls back via that Space's cursor without disturbing the home
  cursor; the convergence harness with two feeds keeps both trees independently convergent.
- [ ] **Step 2: Run it; verify it fails.**
- [ ] **Step 3: Implement** — generalize the loop over feeds; the hydrator presigns with the
  node's `space_uuid`; the nudge opens one ActionCable subscription per Space (`{space_uuid,
  head_seq}`). Update `LibraryChannel` server-side to broadcast per-Space (Task 20).
- [ ] **Step 4: Run it; verify it passes.**
- [ ] **Step 5: Commit** `feat(sharing/client): multi-feed sync loop + Shared/ mount root`.

### Task 20: Server ActionCable per-Space nudge

**Files:**
- Modify: `app/channels/library_channel.rb` (subscribe by `space_uuid` the device is a member
  of; broadcast `{space_uuid, head_seq}` on commit/mutation)
- Modify: the broadcast call sites (`Sync::Commit#finalize`, `Sync::Mutation#apply`)
- Test: `test/channels/library_channel_test.rb`

- [ ] **Step 1–5:** failing test (a member receives the Space's `head_seq` nudge; a non-member
  cannot subscribe) → run → implement (gate `subscribed` on `Sync::Membership.can_read?`) →
  run → commit `feat(sharing): per-Space ActionCable nudge, membership-gated subscribe`.

---

## PHASE 7 — Migration finalization + cutover

### Task 21: Decide + execute the chunk-key migration

**Files:**
- Modify: `lib/tasks/chunks.rake` (add `chunks:migrate_to_space_keyspace`)
- Create: `docs/sharing-migration.md`
- Test: `test/lib/chunk_key_migration_test.rb`

- [ ] **Step 1: Failing test** — given pre-migration objects under `chunks/<user>/<hash>` (use
  `MemoryChunkStore`/`LocalChunkStore`), the task copies them to
  `chunks/space/<home_space_id>/<hash>` and a subsequent `presign_get(home_space_id, hash)`
  resolves; the old prefix is reaped.
- [ ] **Step 2–4:** run → implement the copy + reap (S3 server-side copy; local byte copy) →
  run.
- [ ] **Step 5:** Write `docs/sharing-migration.md`: managed runs the copy task; self-host uses
  the `legacy_key` fallback in `presign_get`/`exists?` (re-uploads lazily). Commit
  `feat(sharing): chunk-keyspace migration task + migration doc`.

### Task 22: Decide the `user_id` column fate + tighten NOT NULL

**Files:**
- Create: `db/migrate/XXXXXX_make_space_id_not_null.rb`
- Modify: models (drop `optional: true` on `belongs_to :space`)

- [ ] **Step 1:** After backfill is verified (Task 3 + 21), make `space_id` `NOT NULL` on the 8
  tables; keep `user_id` as a denormalized convenience (cheaper than dropping; keeps existing
  per-user isolation tests meaningful). Document the decision in `docs/sharing-migration.md`.
- [ ] **Step 2: Run the full suite** `bin/rails test` — green.
- [ ] **Step 3: Commit** `feat(sharing): space_id NOT NULL after backfill`.

---

## PHASE 8 — Security audit (redo the tenant=user audit for Spaces)

> The isolation audit that made tenant=user safe (CLAUDE.md §8) must be redone for Spaces.
> This phase adds **adversarial** tests, not features.

### Task 23: Extend `tenant_isolation_test` to multi-USER multi-Space

**Files:**
- Modify: `test/integration/v1/tenant_isolation_test.rb`
- Create: `test/integration/v1/space_isolation_test.rb`

- [ ] **Step 1: Write the adversarial tests** (each MUST fail before the gates exist, pass
  after):
  - A non-member cannot: pull a Space's `changes`/`tree`; presign GET its chunks; commit/mkdir/
    move/delete/lock in it; subscribe to its ActionCable nudge; add/remove its members; create a
    link for it.
  - A **viewer** cannot write (commit/mutate/lock-as-exclusive) but can read/hydrate.
  - A presigned URL minted for Space A **cannot** be replayed against Space B (the signed key /
    HMAC binds `space_id`) — assert the `local` verify rejects the cross-Space `sig`, and assert
    the S3 key string differs.
  - A **revoked** member loses presign on the next mint; a **revoked link** loses presign on the
    next mint; an **expired link** is dead.
  - **No privilege escalation:** a link capability cannot be exchanged for a device token or
    membership; an editor cannot self-promote to owner; `remove_member` cannot remove the last
    owner.
  - **No cross-Space leakage via dedup:** an attacker who knows a chunk hash in Space B but is
    only a member of Space A gets `{}` from `chunks#download` for Space B (Task 6 assertion,
    re-stated as an attack).
- [ ] **Step 2: Run; verify the pre-gate versions fail and post-gate pass.**
- [ ] **Step 3: Commit** `test(sharing): multi-user multi-Space isolation + escalation audit`.

### Task 24: Extend the fault-injection + convergence harnesses to multi-Space

**Files:**
- Modify: `client/sync-engine/tests/fault_injection.rs`
- Modify: `client/sync-engine/tests/two_device_e2e.rs` (→ a two-USER variant)
- Modify: `client/fs-provider/tests/convergence.rs`

- [ ] **Step 1: Write the failing tests** — (a) a two-USER E2E: user A (editor) writes into a
  shared Space through a real mount, user B (editor on a second device/account) reads it
  byte-for-byte and writes back; (b) the fault harness drives randomized concurrent commits
  from **two users** into one Space + induced failures, asserting 0 silent losses and that
  every divergent edit becomes a recorded conflict (never a dropped write); (c) the convergence
  harness runs N Spaces with independent op streams and asserts per-Space tree convergence +
  no cross-Space bleed.
- [ ] **Step 2: Run; verify they fail without the multi-feed engine, pass with it.**
- [ ] **Step 3: Commit** `test(sharing): multi-user fault-injection + two-user E2E + multi-Space convergence`.

### Task 25: Security review pass + sign-off doc

**Files:**
- Create: `docs/sharing-security-review.md`

- [ ] **Step 1:** Run the project `security-review` skill over the diff. Document, per §8
  invariant: (1) bytes-out-of-Rails preserved (presign-only; the only byte path that touches
  Rails is the self-host `local` blob, now Space-scoped); (2) untamperable presign preserved
  (`space_id` inside the signed key/HMAC); (3) authz funneled through exactly `Sync::Membership`
  + `Sharing::Links` (grep the controllers — no inline authz); (4) link tokens disjoint from
  device tokens; (5) member/link revocation bound ≤ presign TTL. List residual risks +
  mitigations.
- [ ] **Step 2: Commit** `docs(sharing): security review + sign-off`.

---

## PHASE 9 — UI seam (web + Tauri) — thin surface only

> Per scope: surface the API; do **not** touch `Maker::*` product features. This is the file
> layer's share UI only.

### Task 26: Web share UI (Rails server-rendered, bytes off Rails)

**Files:**
- Create: `app/controllers/spaces_controller.rb` (web) + views: list Spaces, create a share,
  add member by email, create/copy/revoke a link, a public link-landing page (password prompt
  if set).
- Test: `test/integration/web/sharing_test.rb`

- [ ] **Step 1–5:** failing request test (owner creates a share via the web form, member sees
  it; a public link page prompts for password then lists the shared tree read-only) → run →
  implement thin views over the Phase-2/5 API → run → commit
  `feat(sharing/web): share management UI (members, links, public landing)`.

### Task 27: Tauri "Shared with me" surface

**Files:**
- Modify: `client/maker-app` (a Spaces list calling `list_spaces`; the Shared/ mount appears
  automatically from Task 19; a "create share / add member / make link" panel)
- Test: a Tauri command smoke test

- [ ] **Step 1–5:** failing → run → implement the commands wrapping `sync-client`'s Space API →
  run → commit `feat(sharing/app): Spaces panel + Shared/ surface in the Tauri app`.

---

## Risks & mitigations (whole-plan)

1. **The keyspace cutover (highest).** Re-keying `chunks/<user>/` → `chunks/space/<home>/`
   orphans live bytes if mis-ordered. Mitigation: nullable→backfill→NOT NULL staging (Phase 1/7),
   a tested migration task + a `legacy_key` fallback (Task 21), and the orphan reaper cleans the
   old prefix. Never delete the old prefix before the copy is verified.
2. **Auth dependency (hard).** Sharing-by-email needs **verified** identities (G3 OAuth/OIDC,
   `docs/parity-roadmap.md` §A). `add_member` is confirmed-only; do not ship sharing before G3
   lands. Note the seam, don't design G3 here.
3. **Encryption interaction (flag for the encryption plan).** Per-Space keyspace is the right
   unit for a **per-Space content key**, but E2EE + sharing = **key-sharing** (a new member must
   receive the Space key; revocation may need key rotation + re-encryption). This is the hard
   combo `docs/parity-roadmap.md` §B calls out. **Do not build encryption and sharing together**;
   record in the ADR (Task 1) that the encryption plan must treat the Space as the key boundary
   and that membership-revocation-vs-key-rotation is an open design item.
4. **Privilege escalation surface.** Two token kinds now exist (device tokens, link
   capabilities). They must stay disjoint (a link can never become a device/library credential).
   Audited in Task 25; tested in Task 23.
5. **Conflict semantics across users.** The same-device echo-suppression must not swallow a
   genuine cross-user conflict (Task 11). Devices are per-user so `device_id` already
   distinguishes users, but lock it with a test and a comment.
6. **Metadata leakage < byte leakage.** Read-gating `changes`/`tree` matters, but the crux is
   bytes; the audit (Task 23) prioritizes the presign gate. A 404 (not 403) on non-member reads
   avoids leaking Space existence.
7. **Self-host single-user simplicity.** A self-hoster with one user must see zero new
   complexity: their home Space is implicit, no Shared/ root unless they create a share. Verify
   the existing single-user E2E is untouched (Task 3 Step 6 gate; Task 22).
8. **`next_seq!` contention on a hot shared Space.** Many collaborators committing to one Space
   serialize on `space.next_seq!` (as users do today on `user.next_seq!`). The
   `concurrent_seq_test` guarantee must be re-run with a Space as the locked row (Task 8 Step 5).

## Dependency ordering (explicit)

**G3 OAuth/OIDC (real auth) → THIS (sharing) → G14 encryption.** Sharing cannot ship before
verified identities (Risk 2). Encryption is sequenced *after* sharing and must treat the Space
as its key boundary (Risk 3). Within this plan: Phase 1 (schema) → 2 (Space API) → 3 (presigner,
the crux) → 4 (sync protocol) → 5 (perms/links) → 6 (client multi-feed) → 7 (migration) → 8
(security audit) → 9 (UI). Phases 3 and 4 are the load-bearing correctness work; Phase 8 gates
release.

## Test strategy (whole-plan, summary)

- **Unit/service:** `Sync::Membership`, `Sharing::Links`, re-keyed `ChunkStore`, per-Space
  `Commit/Mutation/Changes/Tree/Conflicts/Locks/Gc`.
- **Integration (Rails):** `space_isolation_test` (the redone tenant audit — non-member,
  viewer-no-write, cross-Space presign replay, revocation, escalation, dedup-leak), `spaces_test`,
  `share_links_test`, per-Space `changes/tree/commit`.
- **Rust engine:** multi-feed `integration.rs`, **two-USER** `two_device_e2e`, multi-user
  `fault_injection` (0 silent losses; every divergence → recorded conflict), N-Space
  `convergence`.
- **Conformance/regression gate:** the **full existing server suite + the single-user E2E must
  stay green at every phase** (the home-Space special case must never regress) — run `bin/rails
  test` after Phases 1, 4, 7.

---

## Self-review notes

- **Spec coverage:** data model (Phase 1, Decision 1), chunk-keyspace crux (Phase 3, Decision 2),
  permissions/roles/links/revocation (Phase 5, Decision 3), sync-protocol changes incl.
  cross-user conflict + locks + selective-sync-of-Spaces (Phase 4 + Phase 6 multi-feed), security
  review redo (Phase 8), migration + auth/encryption dependencies (Phases 1/7 + Risks 2/3), UI
  seam (Phase 9). All present.
- **Out of scope honored:** no `Maker::*` / product-layer changes; Phase 9 is file-layer share UI
  only.
- **Type consistency:** `Sync::Membership.can_read?/can_write?/can_manage?`,
  `Sharing::Links.create!/redeem/revoke!`, `ChunkStore#presign_*(space_id, hash)`,
  `Space#next_seq!`, `space_uuid` as the stable wire id — used consistently across tasks.
