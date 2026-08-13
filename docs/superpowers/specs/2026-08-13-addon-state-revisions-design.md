# Addon state revisions, prefilled reopen, and the file → generator link

**Date:** 2026-08-13
**Status:** design approved, not implemented
**Repos:** this one (host) **and** `chaim354/tinkerex-addons` (the boxes bundle) — two PRs, host first

---

## 1. What is broken today

A saved box is a `Maker::AddonState` row: `name`, `data` (the addon's own `{generator, params}`
shape) and a bundle of `Maker::AddonFile` rows tying it to the library nodes it produced. The save
door (`Tools::AddonsController#create`) **only ever `create!`s**. There is no update, no delete and
no lineage — `state:crud` is `false` at `Maker::Addons::Host::LEVEL` 2.

Three consequences, all user-visible:

1. **Five tweaks to one box are five unrelated rows all called "shelf box".** The saved rail lists
   every one of them. Nothing records that they are the same design, and the params of the version
   that actually fit the shelf are indistinguishable from the four that did not.
2. **The library file is overwritten while the rows pile up.** A re-save under the same name
   collides, the bundle's `confirm()` answers the 409, `LibraryOutput` rewrites the file *keeping
   its node* — and then a brand-new state row is minted pointing at that same node. So N rows share
   one file, and only the newest row's params describe its bytes.
3. **Re-saving a box that is NOT in a project category folder is a hard dead end.** The door runs
   two collision checks against two different folders. `refuse_taken_names!` asks about the folder
   the user *picked* and raises a terminal 422 ("already exists … Rename the save or pick another
   folder"); `resolve_placements` asks about the *category* folder the intake sweep will file into
   and raises the answerable 409. A box that was swept into `Projects/<slug>/design/` leaves the
   picked folder vacant, so it reaches the answerable 409 — but a box saved to a plain library
   folder is still sitting there, hits the 422, and **cannot be re-saved at all without renaming.**

Alongside that, two navigation gaps: clicking a saved box opens a read-only detail view whose
"Duplicate & tweak" button is the *second* click before you reach a prefilled form; and nothing
anywhere links a library file back to the addon that produced it, though `maker_addon_files.node_id`
has recorded it since the framework shipped.

---

## 2. Decisions taken, with the argument

These were settled during design. Each is recorded with its reasoning so it is not relitigated.

**A box is one row; revisions are snapshots in a child table.** The alternative — `lineage_id` +
`revision` columns, every save still a row — was rejected because `GET /tools/:key/states` would
then return five entries where a box used to be one. Publishing a bundle *is* the deploy and Rails
is never rebuilt (CLAUDE.md §14c), so every already-published bundle — `generators`, `openscad`, and
any older `boxes` — would start showing duplicates on a host that merely deployed. Keeping the
states list one-entry-per-box means those bundles need no change and simply *stop* seeing
duplicates.

**A collision with the box's own file is an approved replace, not a question.** This is the rule the
whole feature rests on. Revising a box is precisely the case where hitting your own file is the
intent; every other collision keeps today's answer. It is also what closes §1.3 — the 422 dead-end
disappears for the one case where it was always wrong, and stays put for the case it exists for.

**No new capability name; `Host::LEVEL` 2 → 3.** Revising is the same `library:write` door growing
an optional parameter, so a capability that would be `true` exactly when `library:write` is carries
no information — the identical argument `Maker::Addons::Host` already records for binary output.
`min_host: 3` is how a bundle requires it, and `hostLevel` is already in `ctx`. **`state:crud` stays
reserved and `false`**: it names the direct `PATCH`/`DELETE /tools/:key/states/:id` endpoint from
the API spec §7.5, which this is not.

**One file per box, overwritten — no per-revision archive.** Chunk mode keeps the old bytes in its
native version chain; share and s3 do not, which is CLAUDE.md §14a's recorded deliberate departure
and not something this arc reopens. Restoring an old design means loading its params and saving,
which becomes the next revision. Consequence stated plainly: **on share/s3 the bytes of revision 3
are gone once revision 4 is written.** The params are not, which is what makes the design
recoverable.

**The history is thin, by choice.** No delete, no prune, no diff, no per-revision annotation. Load
an old revision's values back into the form is the whole point; everything else was considered and
deferred.

**The deep link is resolved server-side into `ctx`, not parsed from `window.location` by the
bundle.** The host validates ownership before handing the id over, and the bundle continues to know
nothing about the host's URL shape — which is the reason `ctx` exists at all.

---

## 3. Data model

New table, `maker_addon_state_revisions`:

| column | notes |
|---|---|
| `addon_state_id` | FK, `null: false` |
| `revision` | integer, `null: false` |
| `data` | json, `null: false`, default `{}` — the params **as saved** |
| `created_at` | `null: false` |

Unique index on `[addon_state_id, revision]`.

**There is no `updated_at`, and its absence is the point:** a revision is an immutable snapshot. A
row that could be edited would let the history disagree with itself, and nothing in the design ever
needs to rewrite one.

`maker_addon_states` gains **one** column: `revision`, the current number, default 1.
**Deliberately not two.** Nothing deletes a revision, so the count equals the current number; a
separate count column earns its place the day pruning lands, and adding it now would be a second
value to keep in step for no present reader.

`Maker::AddonState has_many :revisions, dependent: :destroy` (the `User` → states cascade already
exists, so a destroyed user takes revisions with it).

**Backfill:** every existing state gets a revision-1 row carrying its current `data` and its own
`created_at`. Non-destructive, and every existing box comes out of the migration with a coherent
one-entry history rather than an empty one.

---

## 4. The save door

`POST /tools/:key` gains an optional `state_id`.

**Absent** — exactly today's behaviour: a new box at `revision: 1`, plus its revision-1 snapshot.

**Present** — revise:

1. Resolve through `current_user.maker_addon_states.for_addon(@addon.states_key)`. Unknown, another
   user's, or another addon's namespace → **404 JSON**, never a 500 and never a silent fallback to
   creating a new box. Scoped by `states_key` rather than `key` for the same reason `#states` is:
   that is the data scope, while `key` builds routes.
2. Compute `own_node_ids = state.files.pluck(:node_id)`. In **both** `refuse_taken_names!` and
   `render_would_replace`, a colliding node in that set is an approved replace; anything else keeps
   today's answer (422 terminal / 409 answerable respectively).
3. Update `name` and `data`, increment `revision`, insert the snapshot — **inside the transaction
   that already wraps the file writes**, so a save that fails partway leaves no revision claiming a
   save that did not happen. That is the same argument the existing transaction comment makes about
   the state row itself.
   **A revision therefore renames the box** whenever the editor's Name field changed, and that is
   deliberate: `name` is a property of the design, not of one snapshot. The consequence to hold in
   mind is that the new name derives a new output filename, so the old file stops being a collision
   target and stays in the library under its old name — the rename does not move or rewrite it.
4. `AddonFile` rows upsert by `node_id`. A row whose file the bundle stopped emitting is **left
   alone** — that file is still an ordinary library file the user may have renamed or attached to a
   project, and CLAUDE.md §14c's "a migration must not delete user bytes" applies to a save door too.

`Host::LEVEL` → 3, in the same commit, per §14c's bump rule.

---

## 5. Reading the history

`GET /tools/:key/states` gains `revision` per entry. **Additive keys only** — every existing key
keeps its meaning, so the payload a published bundle reads is untouched.

The history itself is lazy: **`GET /tools/:key/states/:id/revisions`** → `[{revision, data,
created_at}]`, newest first, user- and `states_key`-scoped like everything else. Inlining it into
the list was rejected: a 20-revision × 40-param history across every saved box would bloat the
gallery's first paint for data nobody has expanded.

Five path segments, so there is **no ordering hazard with `tools/:key`** — Rails requires a
segment-count match, the same recorded reason `tools/addon_states/:id/params` is safe. It goes in
the same routes block regardless, to keep the addon surface together.

---

## 6. The deep link

`GET /tools/:key?state=<id>` resolves server-side into `ctx.launch = { stateId: … }`, exposed by the
SDK as `host.launch`.

An unknown, foreign, or other-addon id is **silently ignored** and the page renders normally. A
stale bookmark or a deleted box must not 404 the tool — and the id is only ever a *hint* about which
box to open, never an authorization decision.

---

## 7. File → box reverse lookup

- **New index on `maker_addon_files.node_id`.** Today's `[addon_state_id, node_id]` composite is
  useless in this direction.
- **New `Maker::AddonOrigin`**: given a user and a list of node_ids, returns
  `{node_id => {state:, addon_key:}}` in **one** query (join to states, scope by user). The count
  must be **constant in N** — `test/integration/web/page_query_budget_test.rb` already asserts
  constancy for these pages, and an N+1 here is a per-row lookup on a 2000-node library.
- **Mapping `addon_key` (a `states_key`) to a page:** prefer the registered addon whose own `key`
  matches — the normal case, since `Registry` defaults `states_key` to `key` — else the first addon
  declaring that `states_key`, else no link. Where two addons share a `states_key` this is a
  deterministic guess rather than a fact; worst case it opens the sibling that declared the shared
  key.
- **The Registry is consulted only when the bulk query found a hit.** A library with no addon-made
  files never touches the addon source, which is a network call behind a 5-minute cache. If that
  source is down the entry is simply absent — the page is unaffected.

### Surfaces

| Surface | Change |
|---|---|
| `files/_list.html.erb`, `files/_grid.html.erb` | `data-addon-open-url` on the cell → an **"Edit in <Addon>"** entry in `filemenu_controller.js` |
| `projects/_attachment_group.html.erb` | the same attribute; the filemenu is already mounted there |
| `files/show.html.erb` | a visible **"Edit in Box Generator"** button in the action row, plus a meta line naming the box and revision |

`filemenu_controller.js` builds every entry from a `data-` attribute and omits the entry when the
attribute is absent, so this is one attribute per surface and one entry in the controller — and a
surface opts out by saying nothing.

---

## 8. The bundle (`chaim354/tinkerex-addons`)

1. **`boxes.js`** — on mount, if `host.launch?.stateId` names a fetched state, open the editor
   directly in editing mode instead of the gallery.
2. **`gallery.js`** — left-click a saved box opens **the editor, prefilled, editing that box** (it
   opened the read-only detail view). Right-click opens a small menu: *Open prefilled* / *Open the
   file* / *Details*.
3. **`editor.js`** —
   - an "Editing **shelf box** · v3" header when editing, with **Save as new box** beside **Save to
     library**;
   - the save sends `stateId` when editing and omits it for a new box;
   - a thin **History** panel — revision + date, click loads those params into the form — fetched
     lazily from §5's endpoint on first expand;
   - the 409 dialog becomes *"Replace shelf-box.svg — save as revision 4 of 'shelf box'?"*, and its
     retry carries `stateId`, so an accidental same-name save started from a blank generator joins
     the right lineage instead of minting a second one.
4. **`show.js`** — kept, demoted to the right-click *Details* entry. It is the only place that lists
   the bundle's files, so deleting it would lose a surface to save a click.
5. **`manifests.json`** — `min_host: 3` for `boxes`.

`generators` and `openscad` need no change and keep working — which is what §2's first decision
bought.

---

## 9. Out of scope

- Revision delete, prune, diff, and annotation.
- Per-revision file archive (see §2).
- `state:crud`'s direct `PATCH`/`DELETE` endpoints.
- Paging on `/states`, which is unbounded today and stays that way — already recorded in the API
  spec §7.5.
- A **standalone** rename — changing a box's name without saving a revision. Renaming *while*
  revising works (§4.3); there is no rename-only path, because there is no direct state endpoint
  (that is `state:crud`).

---

## 10. Testing

Host:

- Revising produces **one** box, not two: `revision` 2, one new snapshot row, and the file's
  `node_id` **survives** (asserted directly — a replace written as delete-then-create passes any
  bytes-oriented test while orphaning every attachment, per §14a).
- **The collision exemption, mutation-checked in both directions**: the box's own node → an approved
  replace; a *different* file sitting at that name → still refused. This is the guard most likely to
  be written so that it cannot fail, and it is the one that must be broken and seen to go red.
- A `state_id` belonging to another user, or to another addon's `states_key` → 404 **with no write
  performed**.
- The `/states` payload shape pinned, so a change visible to a published bundle goes red here.
- The deep link with an unknown or foreign id → still 200, `ctx.launch.stateId` nil.
- Reverse lookup query count **constant in N**, and **no Registry call** on a library with no addon
  files.
- All three `LIBRARY_BACKEND` legs, because the replace path genuinely differs: Share's
  temp-then-rename, S3's `put_object`, and chunk's new version against `base_version_id`.

Bundle: its own tests. The host's `test/system/addon_bundle_test.rb` is fixture-driven
(`test/fixtures/addons/`) and is unaffected by anything published in the other repo.

---

## 11. Sequencing and risks

**The host PR merges and deploys before the bundle publishes `min_host: 3`.** Published the other
way round, boxes greys out on a host that has not caught up — which is the ordering §14c already
requires and the failure the `min_host` mechanism exists to make legible rather than silent.

Risks:

- The `states_key` ambiguity in §7 is a deterministic guess, not a fact. Recorded rather than solved.
- On share/s3 a revision's bytes are unrecoverable once superseded (§2). The params are not.

---

## 12. Invariants to record in `CLAUDE.md` §14c

Written in the same branch as the code, per §15:

- A save carrying `state_id` **revises**; a collision with one of that box's **own** `AddonFile`
  node_ids is an approved replace, and every other collision keeps its existing answer. The
  exemption applies to **both** collision checks — `refuse_taken_names!` (picked folder, terminal
  422) and `resolve_placements` (category folder, answerable 409) — because a box living in a plain
  library folder only ever reaches the first one.
- A revision row is **immutable**: no `updated_at`, never rewritten.
- `maker_addon_states.revision` is the current number and there is **no count column**, because
  nothing deletes a revision. Add one with the deletion, not before.
- **`Host::LEVEL` 3 is the whole feature detect for revising.** No capability name was added, for
  the same reason binary output has none. `state:crud` remains reserved for the direct endpoints.
- `GET /tools/:key/states` stays **one entry per box** for the life of `api_version: "1"` — that is
  what lets already-published bundles keep working across this change.
- The file → box reverse lookup consults the **Registry only when the bulk node query found a hit**,
  so an addon-free library never makes that network call.
