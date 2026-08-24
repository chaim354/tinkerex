# Arc B work-list — measured, not predicted

**Source:** `test/integration/chunk_remote_journey_test.rb` run under
`LIBRARY_BACKEND=chunk_remote` against a real `tinkerex-sync` host on 2026-08-24, commit
`f2e25f7` ("Arc A found a fourth gap the reading pass missed"), working tree clean.
Raw output: `10 runs, 106 assertions, 3 failures, 1 errors, 0 skips`.

The suite was captured **twice** in the same server session — once exactly as prescribed
(`tmp/journey-run.txt`, seed 34426) and once with `TESTOPTS="-v"` for a per-test verdict
(`tmp/journey-run-v.txt`, seed 23901), Minitest randomizing execution order differently each
time. Both runs produced the **identical** summary line and the identical four failures with
byte-identical messages — not a flake, not order-dependent. Both files are gitignored
(`tmp/*`) and are local evidence for this write-up, not part of the commit.

| # | Test | Verdict | Failure, verbatim | Predicted by the spec? |
|---|---|---|---|---|
| 1 | the journey suite does not skip when a server is configured | PASS | — | n/a — the skip canary |
| 2 | an upload round-trips byte-for-byte through the sync server | PASS | — | no |
| 3 | an uploaded file appears on the files page | PASS | — | no |
| 4 | a folder can be created, and a file moved into it | PASS | — | no |
| 5 | a file can be deleted, listed in trash, and restored | PASS | — | no |
| 6 | a directory delete cascades, because dir_deletable is true on chunk_remote (three levels) | PASS | — | no |
| 7 | a node created directly on the sync server becomes visible without a local write | FAIL | "a node pushed by another device never reaches the mirror: there is no periodic pull and no ActionCable subscription, so the maker UI cannot see it at all" | YES — gap (a) |
| 8 | an addon save writes its output into the library | ERROR | `NameError: uninitialized constant Maker::Addons::LibraryOutput::Sync` (full backtrace below) | YES — gap (b) |
| 9 | a batch of moves costs one changelog pull, not one per move | FAIL | "a batch of 3 moves pulled the changelog 3 times; batch must defer the refresh so an eager project-intake sweep is not 2 WAN round-trips per file." — `Expected: 1 / Actual: 3` | YES — gap (c) |
| 10 | restoring a child before its parent restores it to the root, per §14a's restore-order trap | FAIL | "Expected response to be a redirect to \<http://www.example.com/files\> but was a redirect to \<http://www.example.com/trash\>." | **NO — gap (d), found by running it** |

The shape matches what the arc expected: **10 tests, 6 passing, 4 failing** (3 Minitest
failures + 1 Minitest error). No discrepancy from the predicted shape, no extra failure, no
flake between the two captures. The one nuance worth being precise about: row 8 is a Minitest
**error** (an uncaught `NameError`), not a **failure** (a failed assertion) — the run's own
summary line distinguishes the two (`3 failures, 1 errors`), so the Verdict column does too
rather than flattening both into "FAIL."

## Cause and fix, gaps (a)–(c)

These three were anticipated by the spec (Task 5 of the Arc A plan, written before any of them
was run) and the captured failures match that anticipation exactly — no surprises here, just
the measured confirmation with file:line citations, verified against the code directly rather
than restated from memory.

### Gap (a) — no freshness pull

`refresh!` (`app/services/file_layer/chunk_remote.rb:292-294`) is the only thing that calls
`ChangelogSync.new(user, transport:).call`, and `ChangelogSync` has no other caller anywhere in
`app/`, `lib/`, or `config/` (grep-verified across all three). `refresh!` itself is called from
exactly five places, all of them **this app's own writes**: `mkdir` (chunk_remote.rb:179),
`move` (:188), `delete` (:198), `undelete` (:207), `finalize_upload` (:242). A node another
device or the server itself creates is invisible to this app until this app happens to write
something of its own — confirmed by the test, which posts a node straight to the server's
`/v1/nodes` and then loads `files_path`, which never refreshes the mirror as a side effect of a
plain read.

**Fix direction** (matches the test's own comment): a recurring per-user pull — a scheduled job
that calls `ChangelogSync` on an interval, or (longer-term, matching what `LibraryChannel` gives
the embedded `chunk` backend today) an ActionCable subscription to the remote host's own
broadcast.

### Gap (b) — addon save has no remote chunk-write verb

`ChunkRemote::CAPABILITIES` sets `port_writable: false` (chunk_remote.rb:51-54), so
`Maker::Addons::LibraryOutput.write` (library_output.rb:50) takes the `write_chunk` branch
(library_output.rb:133) instead of `write_port`. `write_chunk` calls
`Sync::Storage::ChunkStore.current.put(...)` directly (library_output.rb:143) — a constant that
lives in the `tinkerex-sync` gem. `LibraryBackend.engine_wanted?` (lib/library_backend.rb:42-46)
is false for `chunk_remote` (it only ever returns true for `chunk`, or when `SYNC_ENGINE` is
forced), so `config/application.rb:18`'s `require "tinkerex_sync" if
LibraryBackend.engine_wanted?` never runs and `Sync::Storage::ChunkStore` plainly does not exist
in this process. The captured error names the lookup precisely:
`uninitialized constant Maker::Addons::LibraryOutput::Sync` — Ruby's constant resolution walking
outward from the lexical scope it was called in and finding nothing at any level.

Full backtrace, verbatim from both captures:

```
NameError: uninitialized constant Maker::Addons::LibraryOutput::Sync
    app/services/maker/addons/library_output.rb:143:in 'block in Maker::Addons::LibraryOutput.write_chunk'
    app/services/maker/addons/library_output.rb:143:in 'Array#each'
    app/services/maker/addons/library_output.rb:143:in 'Maker::Addons::LibraryOutput.write_chunk'
    app/services/maker/addons/library_output.rb:50:in 'block in Maker::Addons::LibraryOutput.write'
    app/services/maker/addons/library_output.rb:47:in 'Array#each'
    app/services/maker/addons/library_output.rb:47:in 'Enumerable#each_with_index'
    app/services/maker/addons/library_output.rb:47:in 'Enumerator#each'
    app/services/maker/addons/library_output.rb:47:in 'Enumerable#map'
    app/services/maker/addons/library_output.rb:47:in 'Maker::Addons::LibraryOutput.write'
```

**Fix direction** (matches the test's own comment): a `put_chunk` port verb on
`FileLayer::ChunkRemote` that goes over the wire (the same presigned two-phase flow the UI
already drives for a browser upload, or a dedicated server-side endpoint), with
`LibraryOutput.write_chunk` calling the **port** instead of reaching into
`Sync::Storage::ChunkStore` directly.

### Gap (c) — batch does not coalesce on chunk_remote

`LibraryBroadcast.batch` (app/services/library_broadcast.rb:20-24) returns a bare `yield` — no
coalescing at all — whenever `LibraryBackend.engine_wanted?` is false (line 21), which is every
`chunk_remote` run. Separately, `FileLayer::ChunkRemote#move` (chunk_remote.rb:183-190) calls
`refresh!` unconditionally on line 188, with no awareness of an enclosing batch. The test wraps
three moves in one `LibraryBroadcast.batch` block and counts real `ChangelogSync.new` calls by
patching `.new` to count-then-delegate (not `Minitest::Mock#stub`, which this repo's pinned
minitest 6.0.6 no longer ships — see the test's own comment); three moves produced three pulls,
1:1.

**Fix direction** (matches the test's own comment): give `batch` a real implementation on
`chunk_remote` — e.g., a flag `move`/`mkdir`/`delete`/`undelete` check before calling `refresh!`,
suppressing the per-call pull while a batch is open and pulling once when the outer
`LibraryBroadcast.batch` block ends.

## What the spec did not predict

**GAP (d) — `chunk_remote` REFUSES a restore that embedded `chunk` performs.** This is the
finding the reading pass missed: Task 5 of the Arc A plan wrote three known-gap tests (a, b, c)
and expected nine tests total to skip cleanly with no server configured. The restore-order test
was added later, alongside deepening the cascade fixture past one level, and it is what actually
found this — confirmed here by running it, not by re-deriving the argument. It is §14a's own
forbidden shape — one condition, two answers, across two backends in the same family.

- `FileLayer::Chunk#undelete` (tinkerex-sync `app/services/file_layer/chunk.rb:497`) calls
  `Sync::Trash.restore(user:, node_id:, to_root: true)`. That `to_root: true` is unconditional
  and deliberate; §14a documents the resulting behaviour at length (an orphan comes back at the
  ROOT, and restore order is therefore not commutative).
- `FileLayer::ChunkRemote#undelete` (`app/services/file_layer/chunk_remote.rb:204-209`, the POST
  itself on line 206) posts an **empty body** to `/v1/trash/:node_id/restore`:
  `transport.post("/v1/trash/#{node_id}/restore", {})`.
- The standalone server's own endpoint, `Sync::V1::TrashController#restore`
  (tinkerex-sync `app/controllers/sync/v1/trash_controller.rb:54-55`), reads `to_root` from the
  request instead of hardcoding it — `ActiveModel::Type::Boolean.new.cast(params[:to_root])` —
  and an absent key casts to a falsy value. `Sync::Trash.restore` itself
  (tinkerex-sync `app/services/sync/trash.rb:30`) defaults `to_root: false` in its own signature,
  so this is the ONE caller (chunk's, in-process) that overrides the shared default; the
  standalone server's controller does not. Line 35: `raise ParentDeleted if orphaned && !to_root`
  — raises.
- That surfaces as **409** → `FileLayer::UnsupportedOperation`
  (`app/services/file_layer/chunk_remote/transport.rb:104`:
  `when 409, 422 then raise FileLayer::UnsupportedOperation, "#{path}: #{message}"`) →
  `TrashController`'s class-level rescue arm (`app/controllers/trash_controller.rb:38-40`):
  `redirect_to trash_index_path, alert: "Couldn't restore that item."` — instead of the success
  path three lines later (`app/controllers/trash_controller.rb:77-79`):
  `redirect_to files_path, notice: "Restored #{info.name}."`.

The captured failure confirms exactly this chain, stopping at the first assertion that diverges
(the test's own comment says it would, and it does — the second assertion,
`assert_nil flash[:alert]`, which would have shown the literal "Couldn't restore that item."
text, never ran because Minitest aborts a test at its first failed assertion):

```
Failure:
ChunkRemoteJourneyTest#test_restoring_a_child_before_its_parent_restores_it_to_the_root,_per_§14a's_restore-order_trap [test/integration/chunk_remote_journey_test.rb:256]:
Expected response to be a redirect to <http://www.example.com/files> but was a redirect to <http://www.example.com/trash>.
Expected "http://www.example.com/files" to be === "http://www.example.com/trash".
```

Redirecting to `/trash` (not `/files`) is only reachable through the rescue arm above, which is
what proves the 409 fired — the maker app never redirects to `trash_index_path` on any other
path through `#restore`.

So restoring a child while its parent is still tombstoned SUCCEEDS on `chunk` and is REFUSED on
`chunk_remote`. Arguably the safer failure mode — but it is not what §14a promises, and a user
moving between the two deployments gets different answers. Arc B's fix is to thread `to_root:`
through the port's `undelete` verb into that POST body; whether the default should be `true`
(matching chunk) or the refusal should be adopted by BOTH backends is a decision for that arc,
not this one. **Record it; do not fix it here.**

No other row's "Predicted" column is "no" — the four failures are exactly gaps (a) through (d)
and nothing else. Rows 2–6 passed with no failures of any kind in either capture.

## What this does NOT cover

This is **ten journey tests**, not the full maker suite (the Arc A plan's own template for this
document still said "nine journeys" — written before the restore-order test existed; ten is the
measured, current count). A green run of all ten — or, as captured, six green plus four gaps
already on Arc B's list — proves only that these ten specific flows work end-to-end against a
real standalone `tinkerex-sync` host. It does **not** prove the full maker feature set works
against `chunk_remote`. In particular, a reader should **not** conclude any of the following from
this run:

- **The full maker test suite passes against chunk_remote.** It has never been run against this
  backend and structurally cannot be, yet: `ChunkRemote` resolves a single process-wide token
  (chunk_remote.rb:327-328 per the Arc A plan), so every test's maker user maps to **one**
  sync-server user. The suite runs in parallel workers that would all write into that one shared
  library, and rolling back the maker DB between tests does not roll back the sync server's own
  state — a `mkdir "Projects"` in one test makes an identical `mkdir` in another a 409, a noise
  failure that says nothing about `chunk_remote`. Per-test library isolation needs a provisioning
  endpoint on the sync server, which is **Arc C**, not this arc. Separately, 63 of 218 test files
  in this repo build nodes with `user.nodes.create!` (255 occurrences) rather than through a real
  door; those read fine against `chunk_remote` (reads are local SQL) but any write verb against a
  hand-built node the server has never heard of would 404 for a reason that is a test-shape
  problem, not a `chunk_remote` defect — running the full suite today would dominate the
  inventory with exactly that noise rather than real findings.
- **Project intake, inventory/BOM, previews/thumbnails, or sharing work against chunk_remote.**
  None of those flows are exercised by this suite at all — it covers upload, byte-exact download,
  the files listing, folder creation, move, delete/trash/restore, a three-level directory-delete
  cascade, one freshness probe, one addon-save probe, and one batching probe. Nothing here touches
  `Maker::ProjectIntake`, BOM lines, inventory items, preview generation, or share links.
- **Multi-device convergence beyond the one freshness probe.** Test 7 proves a single node pushed
  directly via the server's own API is invisible until this app writes something of its own
  (gap a) — it does not exercise two live maker-app devices syncing against each other, conflict
  detection, or `Sync::Conflicts`.
- **Concurrent or high-volume behavior.** All ten tests run sequentially in one process against
  one local server; nothing here measures latency, throughput, or behavior under concurrent
  writers.

The full-suite leg is an Arc C follow-on, once per-test library provisioning exists.
