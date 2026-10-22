> **HISTORICAL — RESCUED, NOT RE-VERIFIED.** The per-finding companion to `AUDIT-2026-08-26.md`,
> recovered with it on 2026-10-22 from `claude/codebase-simplification-audit-dbdd8d` (commit
> `07441e62`); everything below this note is byte-for-byte what that branch held. **Verified at
> `c290d4b`**, **acted on in `tinkerex#149`** (whose re-audit overrides any verdict here), and
> **superseded by `docs/AUDIT-2026-10-19-simplification.md`**. **Line numbers have drifted**: treat
> every file:line below as a lead to re-locate, not a citation.

# Simplification audit — full per-finding record

**Companion to [`AUDIT-2026-08-26.md`](AUDIT-2026-08-26.md). Read that first** — it carries the
coverage contract, the ranked order, and the corrections. This file is the raw detail, one entry
per finding, and is meant to be opened for the finding you are about to implement, not read
front to back.

Every claim below was produced by a bounded read-only lane and re-verified by the coordinator
against the working tree at **`c290d4b`**. Line numbers drift; re-check before acting.

**A verdict line marked REJECTED, NARROWED or DEMOTED overrides the lane's own text below it.**
The lane's original wording is kept verbatim rather than edited, so the disagreement stays visible.

---

## S01 — FileLayer port & capability contract

**Lane verdict:** `recommend`

### S01-1 — "Which backend is this deployment?" has three definitions and two of them spell the unconfigured state as `chunk`, a backend the factory refuses

> **COORDINATOR VERDICT — ACCEPT.** Verified against the tree; no narrowing applied.

- **Category:** state-representation  
- **Lane confidence:** medium

**Evidence**

- app/services/file_layer.rb:152 — `backend = ENV.fetch("LIBRARY_BACKEND", "share")`. This is the factory's answer: unset means share.
- app/services/file_layer.rb:185 — `raise ArgumentError, "unknown LIBRARY_BACKEND #{ENV['LIBRARY_BACKEND'].inspect}"`. The `case` has arms only for share/s3/chunk_remote, so the literal string `chunk` is a value this factory refuses outright (CLAUDE.md §14a: "`chunk` is REFUSED, not aliased").
- lib/library_backend.rb:18 — `DEFAULT = "chunk"`, and lib/library_backend.rb:22 — `def self.name(env: ENV) = env.fetch("LIBRARY_BACKEND", DEFAULT)`. On an unconfigured box this module answers "chunk" while FileLayer.build builds a Share. The two disagree about what the deployment IS.
- lib/library_backend_check.rb:95 — `def self.check!(env: ENV, backend: env.fetch("LIBRARY_BACKEND", "chunk"))`. A third, independent copy of the same env read with the same stale default.
- lib/library_backend_check.rb:101 — `# No `else`: an unknown backend is FileLayer.build's ArgumentError to raise, not this guard's.` This is what makes the "chunk" default work at all: it matches no `when` arm, so it means "check nothing". The sentinel for "unconfigured" is spelled as a retired backend name rather than as absence.
- `grep -rn "LibraryBackend\." app/ lib/ config/ db/ bin/` returns nothing (exit 1). The only remaining callers of `LibraryBackend.name` are four test files (test/system/uploader_test.rb:49, test/services/file_layer/chunk_remote/mutation_contract_test.rb:96, .../upload_test.rb:91, and prose in test/services/library_broadcast_test.rb:23).
- lib/library_backend.rb:3-6 — the module's own header states its reason for existing is being "asked early enough to decide whether to load the sync engine at all"; lib/library_backend.rb:24-30 states `engine_wanted?` and the `SYNC_ENGINE` knob "ARE BOTH GONE (Arc D Part 2)". The job that justified a pre-autoload copy of this question no longer exists, but the copy and its default survived it.
- app/services/file_layer.rb:132-151 — the recorded cost of exactly this drift: `check!` was called with no arguments, its default stayed on `chunk` while build's became `share`, "THE ONE BACKEND REACHABLE WITHOUT SETTING LIBRARY_BACKEND WAS THE ONE THE GUARD NEVER CHECKED", breaking `bin/ci setup` several frames away inside a migration.
- test/lib/library_backend_check_test.rb:6 — `assert_nothing_raised { LibraryBackendCheck.check!(backend: "chunk", env: {}) }`, and :84 — `LibraryBackendCheck.check!(backend: "chunk", env: { "LIBRARY_PATH" => d })` under the name "chunk mode writes no probe". The suite's expression of "unconfigured checks nothing" is also spelled as `chunk`, so the stale sentinel is pinned in three places at once.

**Current complexity / invalid states**

One fact — which of three backends this deployment runs — is read from ENV in three independent places with three independently-maintained defaults: "share" (file_layer.rb:152), "chunk" (library_backend.rb:18), "chunk" (library_backend_check.rb:95). Two of those defaults name a backend FileLayer.build raises ArgumentError on. The state "operator has not configured a backend" therefore has no representation of its own: it is encoded as a specific, retired, invalid backend name, and it behaves correctly only because check!'s case statement happens to have no arm for it — a load-bearing coincidence whose only nearby comment (library_backend_check.rb:101) explains a different thing. The drift between two of these three defaults has already shipped a real failure (file_layer.rb:132-151), and nothing prevents the third from drifting the same way: LibraryBackend.name can currently return a string naming a deployment the app cannot be running.

**Proposed representation**

Make absence representable, and have one function answer the question. `LibraryBackend.name(env: ENV) = env["LIBRARY_BACKEND"]` — nil means "not configured", which is what it actually is. FileLayer.build supplies the fallback where it belongs, at the one place that constructs an adapter: `backend = LibraryBackend.name || "share"`, then passes the resolved value to check! as it already does. LibraryBackendCheck.check! defaults `backend:` to `LibraryBackend.name(env:)` (nil), which matches no `when` arm exactly as "chunk" does today — byte-identical behaviour for the boot initializer, which file_layer.rb:144-151 measured and requires (an unconfigured dev box must still boot). `DEFAULT = "chunk"` and the "chunk" literal in check!'s signature both disappear. The two tests at library_backend_check_test.rb:6 and :84 are re-spelled `backend: nil`, which is what they mean. Because the resolution then has a single reader, a guard becomes writable that is impossible today: assert that with LIBRARY_BACKEND unset, LibraryBackend.name is nil and FileLayer.build yields the same class the fallback names.

**Why simpler**

It removes an invalid state from the representation rather than moving branching around. Today "unconfigured" and "configured as a retired backend" are the same string, so no reader can tell them apart, and the boot guard's correct behaviour rests on a missing `when` arm rather than on anything stated. Afterwards the unconfigured state is nil, the fallback exists once at the only site that needs one, and the number of places that can silently disagree about what this deployment is drops from three to one. It also retires a module whose documented purpose (a pre-autoload engine-loading decision) no longer exists and which has zero production callers — so the second copy of the question is not merely unified but deleted.

**Smallest credible implementation scope**

Smallest credible slice: (1) lib/library_backend.rb:18-22 — drop DEFAULT, return `env["LIBRARY_BACKEND"]`; (2) lib/library_backend_check.rb:95 — default `backend:` to `LibraryBackend.name(env:)`; (3) app/services/file_layer.rb:152 — `LibraryBackend.name || "share"`; (4) re-spell the two `backend: "chunk"` calls in test/lib/library_backend_check_test.rb as `backend: nil` and rename those tests. Optional follow-on, not required for the value: add the agreement assertion described above. Do not touch the `when` arms, the ArgumentError, the initializer, or the four test files that call LibraryBackend.name with LIBRARY_BACKEND explicitly set — their behaviour is unchanged.

**Affected files**

- `lib/library_backend.rb`
- `lib/library_backend_check.rb`
- `app/services/file_layer.rb`
- `test/lib/library_backend_check_test.rb`

**Regression risks and migration concerns**

The change is deliberately behaviour-neutral, which means §15's mutation-check rule cannot produce a red for it directly — restoring "chunk" as either default would keep the suite green, and that is precisely the hole being closed. State that plainly rather than claiming a guard exists. The one behavioural edge worth deciding explicitly is the empty string: LIBRARY_BACKEND="" currently reaches FileLayer.build's `else` and raises ArgumentError, so return `env["LIBRARY_BACKEND"]` rather than `.presence` unless that refusal is deliberately being relaxed. Also confirm nothing in the Kamal env or config/deploy*.yml references LibraryBackend::DEFAULT by name before deleting the constant — grep found no Ruby reference, but I did not read the deploy YAML.

**Validation required**

Existing coverage: test/lib/library_backend_check_test.rb (all arms, including the two "chunk mode" tests to be re-spelled), test/services/file_layer/build_chunk_remote_test.rb (pins that an unset/unknown LIBRARY_BACKEND behaves correctly and that build_with restores ENV), test/models/library/purge_repo_metadata_nodes_migration_test.rb:45 (explicitly pins check! with no arguments — the exact call the initializer makes, and the regression that broke `bin/ci setup`), test/services/file_layer/value_objects_test.rb. Additional validation required: all three backend legs (test, test-s3, test-chunk-remote) with identical run counts, since this touches the shared resolution path; plus one new assertion that with LIBRARY_BACKEND unset, LibraryBackend.name is nil and FileLayer.build yields a Share — that assertion IS mutation-checkable (restore `DEFAULT = "chunk"` and it goes red), which is the guard the current shape cannot have.

### S01-2 — MAX_BYTES is declared a port-wide invariant but enforced only by prose in each adapter — two implement it four times, chunk_remote implements it zero times

> **COORDINATOR VERDICT — PROMOTED.** Right finding, WRONG DOOR. GeneratePreviewJob already guards via refuse_if_oversized!/MAX_PREVIEW_BYTES. The unguarded caller is Maker::ExtractPdfMetadataJob#read_pdf_text:33 — no size check at all.

- **Category:** ownership  
- **Lane confidence:** high

**Evidence**

- app/services/file_layer.rb:100-102 — `# Cap to protect the job host when reading a whole file into memory. Port-wide: it applies` / `# to any backend, not just the chunk store.` / `MAX_BYTES = 256 * 1024 * 1024`. The constant lives at the port and its comment states a port-wide obligation.
- app/services/file_layer/share.rb:91 — `raise NotFound, "file exceeds #{MAX_BYTES} bytes" if size > MAX_BYTES` (read path, after File.size); share.rb:712-713 — `bytes = io.read(MAX_BYTES + 1).to_s.b` then the same raise (write path).
- app/services/file_layer/s3.rb:153 — `resp = @client.get_object(bucket: @bucket, key:, range: "bytes=0-#{MAX_BYTES}")` and s3.rb:158 — `raise NotFound, "file exceeds #{MAX_BYTES} bytes" if bytes.bytesize > MAX_BYTES`; plus s3.rb:1096-1097, the same pair again in `read_capped!` for the write path. Four enforcement sites across two adapters, two different mechanisms, each with its own copy of the message.
- `grep -c MAX_BYTES` over app/services/file_layer/chunk_remote.rb and all four files under app/services/file_layer/chunk_remote/ returns 0 for every one of them. The primary deployment's adapter does not reference the port's cap at all.
- app/services/file_layer/chunk_remote.rb:133-141 — `def read(user, node_id:, content_token: nil)` … line 140: `+"".b.tap { |buf| manifest.each { |c| buf << fetch_chunk(c, urls) } }`. The whole file is concatenated into one String with no size check anywhere in the method.
- test/services/file_layer/adapter_contract.rb — grep for MAX_BYTES / "exceeds" / "cap" returns no hit. The shared contract all three legs run pins capabilities, delivery variants and stat_all query counts, but never the read cap, so the omission cannot be caught by any leg.
- app/jobs/maker/generate_preview_job.rb:147 — `# incomplete. FileLayer::MAX_BYTES still backstops the read, so the failure mode of proceeding` — the stated justification for letting a node with an unknown `nodes.size` proceed past `refuse_if_oversized!` (generate_preview_job.rb:153: `return if size.nil? || size <= MAX_PREVIEW_BYTES`). That backstop does not exist on chunk_remote.
- app/jobs/maker/extract_pdf_metadata_job.rb:33 — `bytes = Maker::FileBytes.read(user, node_id: node.node_id)` with no size gate of its own, and :41 — `rescue FileLayer::NotFound # terminal (deleted file) -> quiet no-op`. The job is written against the capped behaviour: it rescues exactly the error the cap raises.
- app/services/maker/file_bytes.rb:14 — `MAX_BYTES = FileLayer::MAX_BYTES`, re-exported to the maker layer as if it were a guaranteed property of the port.
- db/schema.rb:398-407 — `remote_manifest_chunks` carries `t.bigint "length", null: false` per chunk, and app/services/file_layer/chunk_remote.rb:371-375 (`manifest_for`) loads those rows from the local mirror. The size is known before any byte moves, so enforcing the cap there costs no round trip.

**Current complexity / invalid states**

A single port-level rule — "a byte read never returns more than MAX_BYTES" — is expressed as a constant plus a sentence, then re-derived independently in each adapter. Two adapters implement it four times with two different mechanisms and two copies of the message; the third implements it not at all. Nothing in the shared adapter contract asks about it, so all three legs stay green over the gap. The result is one condition with two answers across backends, the shape §14a exists to forbid: the same 2 GiB file makes Maker::ExtractPdfMetadataJob a quiet no-op on share and s3 (NotFound, rescued at extract_pdf_metadata_job.rb:41) and an unbounded String allocation in the Solid Queue worker on chunk_remote. It has also already produced a false statement in a downstream comment (generate_preview_job.rb:147) that is being relied on as the reason an unknown-size node may proceed.

**Proposed representation**

Let the port own the RULE and leave the MECHANISM with the adapter — the two are conflated today. Concretely: (1) add one assertion to test/services/file_layer/adapter_contract.rb that `read` on an over-cap node raises NotFound, so the rule is checked structurally on all three legs instead of asserted in prose at file_layer.rb:100-101; (2) give FileLayer::ChunkRemote#read the cheap local pre-check the mirror already affords — refuse when `manifest.sum(&:length) > MAX_BYTES` before presigning, the exact analogue of Share's stat-then-refuse at share.rb:91, costing no round trip because `manifest_for` has already loaded the lengths. Do NOT hoist the mechanisms into a shared wrapper: s3.rb:145-153 argues at length that its range-GET is what actually bounds the read (get_object buffers the whole body before returning), and Share's File.size stat is equally local to its storage. The duplication worth removing is the unenforced obligation, not the three implementations.

**Why simpler**

It turns a constant-plus-prose contract into a stated, checkable one, and removes the need for every future adapter author to notice a sentence in file_layer.rb. Afterwards there is one place saying what the port promises about `read` (the contract test) and one place per adapter keeping that promise in whatever way its storage allows — instead of a promise made at the port, kept twice, broken once, and re-asserted as fact by a downstream comment. It also collapses a real cross-backend behavioural divergence into a single answer, which is what lets the maker layer keep treating FileLayer.current as one thing.

**Smallest credible implementation scope**

Smallest credible slice: one assertion in test/services/file_layer/adapter_contract.rb (over-cap read raises NotFound), plus roughly three lines in FileLayer::ChunkRemote#read between chunk_remote.rb:136 and :139 refusing on the summed manifest length. Optionally correct the now-false clause at app/jobs/maker/generate_preview_job.rb:147 in the same change. Nothing else moves: the constant, the two existing adapters, and all four existing enforcement sites stay exactly as they are.

**Affected files**

- `app/services/file_layer.rb`
- `test/services/file_layer/adapter_contract.rb`
- `app/services/file_layer/chunk_remote.rb`
- `app/jobs/maker/generate_preview_job.rb`

**Regression risks and migration concerns**

Main risk is over-reach: unifying the enforcement mechanism would undo s3.rb:145-153's argued range-GET and share.rb:707-713's cap+1 read, both recorded decisions — keep the fix to the rule, not the mechanism. Second, the contract assertion must be cheap: building a genuinely 256 MiB fixture on three legs is not acceptable, so it needs an injectable cap or a stubbed size rather than real bytes; if that seam cannot be added without contorting the adapters, the honest fallback is a chunk_remote-only test plus a comment naming the gap. Third, chunk_remote's cap is judged on the mirrored manifest, which can be stale — but that is the same locally-mirrored data every other chunk_remote read decision already uses (§14a), so it adds no new staleness axis. Finally, adding a refusal changes behaviour for any chunk_remote node over 256 MiB that previously read successfully; that is the intended correction, but it belongs in the PR body rather than shipped quietly.

**Validation required**

Existing coverage that must stay green: test/services/file_layer/adapter_contract.rb (all three legs), test/services/file_layer/share_test.rb and s3_test.rb (which exercise the existing cap paths), test/services/file_layer/chunk_remote/contract_test.rb and upload_test.rb, and the preview and pdf-metadata job tests, since both consume Maker::FileBytes.read. Additional validation required, and mandatory under §15: mutation-check the new contract assertion by removing the chunk_remote pre-check and confirming the chunk_remote leg goes RED — today that same deletion is invisible, which is the whole finding. Then confirm the three legs still report identical run counts.

### Cross-subsystem concerns raised by this lane

_Named, not solved — the lane was told to stay inside its boundary._

- The concrete code change for finding 2 lands in FileLayer::ChunkRemote#read (app/services/file_layer/chunk_remote.rb:133-141), which is the adapter lane, not mine. My finding is about where the rule is OWNED (file_layer.rb:100-102 declares it port-wide and then relies on prose); the adapter lane should own the mechanism.
- app/jobs/maker/generate_preview_job.rb:147 asserts "FileLayer::MAX_BYTES still backstops the read" as the justification for letting an unknown-size node proceed. That claim is false on chunk_remote. The comment belongs to the preview lane, but it is downstream evidence that the port's prose obligation is being relied on as if it were enforced.
- app/jobs/maker/extract_pdf_metadata_job.rb:33 reads bytes with no size gate of its own and rescues FileLayer::NotFound at line 41 — i.e. it is written against the capped behaviour. That job belongs to the intake/preview lane.
- test/services/file_layer/adapter_contract.rb has no assertion about the read cap at all. Adding one is the cheapest structural fix but it is a shared-contract file owned jointly by the three adapter lanes.

---

## S02 — FileLayer::Share adapter

**Lane verdict:** `recommend`

### S02-1 — Destination resolution is a four-step ladder retyped at four call sites; make it one named operation returning a (rel, path) pair

> **COORDINATOR VERDICT — NARROWED.** Keep the private composer; DROP the (rel, path) value type — `dest = resolve_inside!(rel)` sits on the line after `rel` is built, from `rel` alone, at all four sites. No reachable disagreement.

- **Category:** data-structure  
- **Lane confidence:** medium

**Evidence**

- app/services/file_layer/share.rb:201-204 — #write: `leaf!(name)` / `rel = join_rel(parent_dir_rel!(user, parent_node_id), name)` / `observable!(rel)` / `dest = resolve_inside!(rel)`, in that exact order.
- app/services/file_layer/share.rb:286-292 — #mkdir: the identical four steps, with the idempotent `existing` lookup interleaved between `observable!(rel)` (:288) and `dest = resolve_inside!(rel)` (:292).
- app/services/file_layer/share.rb:394-399 — #move: `leaf!(new_name)` then the same `join_rel(parent_dir_rel!(...))` / `observable!(rel)` / `resolve_inside!(rel)` triple, with `src = absolute_path(node)` computed alongside.
- app/services/file_layer/share.rb:482-494 — #undelete: the same triple, differing only in `parent_dir_rel!(..., live: false)` and in that it never calls `leaf!` (the name comes from the tombstone row, not a caller).
- app/services/file_layer/share.rb:279-281 — #mkdir's own header: "Reuses write's exact guards — leaf!/observable!/resolve_inside! — because a mkdir that skips them re-opens the scan-wedge bug class this file documents". The file already argues for one ladder, but expresses it as a convention to copy.
- app/services/file_layer/share.rb:483-492 — #undelete's comment: "THE FOURTH INSTANCE OF THE SKIP-LIST BLIND SPOT, and it was reported as unreachable, which was wrong... Every writing path here now asks -- write, move, and undelete -- which is the structural finding rather than three coincidences: assume every path that writes is exposed until checked."
- app/services/file_layer/share.rb:627-651 — `observable!`'s header: a destination that skips it lands "a live node at a path the scan never observes -> unpairable -> tombstoned -> the mass-deletion guard refuses that scan and EVERY SCAN AFTER IT", and additionally "EVERY DELETE IN THE LIBRARY breaks".

**Current complexity / invalid states**

There is no name in this file for "the destination this write verb is about to create". Instead, four verbs each rebuild it from the same four ordered primitives and then carry two loose, derived-and-must-agree locals: `rel` (a String, used in every error message and written into `storage_path`) and `dest` (a Pathname, the thing actually stat'd/renamed to). Nothing structural links them — `write` stores `rel` (:245) while stat'ing `dest` (:235) — and nothing structural forces the ladder to be complete. Completeness is enforced today by convention plus per-verb tests: `observable!` was added to `undelete` late (:483-492 records that its absence there was reported as unreachable and was not), and the write contract pins the refusal by enumerating verbs one at a time (adapter_write_contract.rb:212, :224, :243, :277, :288, :304). A fifth writing verb, or a fifth branch inside an existing one, is one forgotten line away from the permanent scan wedge described at :627-651, and the forgetting is silent.

**Proposed representation**

One private method — `destination!(user, parent_node_id:, name:, live: true)` — performing `parent_dir_rel!` → `join_rel` → `observable!` → `resolve_inside!` and returning a two-field value (a `Data.define(:rel, :path)`, or a frozen Struct) so the relative and absolute forms travel together and cannot be derived independently. The four call sites collapse to `dest = destination!(user, parent_node_id:, name:)` (and `live: false` in `undelete`), then use `dest.rel` / `dest.path`. `leaf!` deliberately stays OUTSIDE the helper at the three doors that take a caller-supplied name (`write`, `mkdir`, `move`): it validates a caller's input, not a destination, which is exactly why `undelete` does not call it on `node.name` today.

**Why simpler**

It gives an unnamed but load-bearing concept a name, and converts an invariant currently held by convention ("every writing path must ask `observable!` before it resolves") into one held by construction — you cannot obtain a destination without having asked. That is the same move `absolute_path` already made for the read side: its comment at share.rb:129-136 says it exists so there is exactly one choke point, "not a copy of it, because two copies of an escape guard drift and this file already makes that argument for live_node!". This finding is that argument applied to the write side, where the file has been bitten four times. It also removes the rel/path drift risk by making the pair a single value instead of two independently-derived locals.

**Smallest credible implementation scope**

share.rb only. Add ~8 lines (the helper plus the value type) beside `observable!`; delete 3 lines from each of four call sites. No signature, no capability, no behaviour change at the port boundary. The whole change is under 20 net lines and touches no other file.

**Affected files**

- `app/services/file_layer/share.rb`

**Regression risks and migration concerns**

One real behavioural edge: #mkdir currently resolves the path AFTER its idempotent early return (share.rb:289-292), so an eager helper resolves first. `resolve_inside!` is pure string math with no I/O, so there is no cost — but for a poisoned dir row whose `storage_path` escapes the root AND is already indexed, mkdir would now raise NotFound "path escapes the library root" where today it returns the existing node. That is arguably the more correct answer, but it is a change and must be pinned deliberately rather than discovered. Second: do NOT fold `leaf!` into the helper — `undelete` has never leaf!-checked `node.name`, and folding it in silently changes undelete's behaviour on a poisoned name. Third: `live:` must stay a parameter, not a default the helper hides; the write-path/undelete asymmetry is argued at share.rb:675-691 ("writing a NEW file into a folder the user deleted is a request to reconsider, while restoring a file that was already in there is a request to undo") and is load-bearing. Fourth, and worth stating plainly against CLAUDE.md's standing warning: I looked for an argument in this file that these four ladders should stay separate and found the opposite — :279-281 argues for reuse, and the one place the file DOES argue against sharing a guard (`deletable_file!` at :578-583) argues it on the grounds that delete's and move's answers genuinely differ, which is not true of `observable!`, whose reasoning is identical at all four sites.

**Validation required**

Already covered: test/services/file_layer/adapter_write_contract.rb:212-311 pins the reserved-path refusal for write, move, mkdir and undelete across every writable backend, and test/services/file_layer/share_test.rb:446 ("write and move refuse a path the scan would skip"), :476 ("undelete refuses to restore into a path the scan would skip"), :500 ("an upload named .trash does not wedge the scan or break delete library-wide") and :1093 ("mkdir refuses a reserved/unobservable name") pin it directly here. Also relevant: :532 and :775 (parent whose storage_path escapes the root) and :925 (undelete refuses a parent with no storage_path). Additional validation required, per CLAUDE.md §15: mutation-check the consolidated guard by deleting the `observable!` call inside the new helper and confirming all four of those share tests plus the four contract tests go RED, then restore — a single deletion should now break every verb, which is the property the change is buying. Add one test asserting mkdir's new answer for the poisoned-escaping-parent-plus-existing-node edge above.

### S02-2 — The terminal-vs-retryable errno policy is applied by hand at seven rescue sites in two silently different variants

> **COORDINATOR VERDICT — REJECTED.** Self-rejected by its author: "I RECOMMEND SKIPPING IT IF ONLY ONE CHANGE IS MADE." Dropped, not backlogged.

- **Category:** control-flow  
- **Lane confidence:** low

**Evidence**

- app/services/file_layer/share.rb:93-108 — #read's ENOENT arm: `unless library_present?` → `raise FetchError, "...ENOENT and the library root looks unmounted"`, else `raise NotFound`.
- app/services/file_layer/share.rb:160-171 — #download repeats that arm with byte-identical logic and identical message strings, and its own comment at :162 says "raises; the rescues below map it exactly as #read does".
- app/services/file_layer/share.rb:466-477 — #undelete's third copy of the same mount check, with a differently-worded message ("the trashed bytes are missing and the library root looks unmounted") and a differently-worded terminal answer ("its trashed bytes are gone (purged?)").
- app/services/file_layer/share.rb:228-232, :296-297, :425-426, :502-503 — four copies of `rescue SystemCallError => e; raise FetchError, "#{label}: #{e.class} (#{e.message})"` (label is `rel` in write/mkdir, `node_id` in move/undelete).
- app/services/file_layer/share.rb:323-326 and :420-423 — two comments existing solely to explain that `FileUtils.mkdir_p` must sit INSIDE the begin block, because "outside, its raw Errno escapes the SystemCallError -> FetchError mapping every other I/O call in this file goes through, and a bare Errno IS a StandardError — which is what burns a preview to a permanent 'failed'".
- app/services/file_layer/share.rb:109-117 — the policy statement itself, written once: "the DEFAULT must be the recoverable answer. Only ENOENT can mean 'genuinely deleted', so only ENOENT is terminal." Note that this holds only on the READ side: #write's rescue at :228 maps ENOENT to FetchError too, and nothing names that difference.

**Current complexity / invalid states**

One policy — which errno may be answered terminally — is expressed seven times, in two variants that look the same and are not. Read-side (read, download, and undelete's missing-bytes branch) treats ENOENT as terminal only if `library_present?`; write-side (write, mkdir, move, undelete's rename) treats every errno including ENOENT as retryable. Both are correct, but the asymmetry is invisible in the code and is recoverable only by reading two long comments plus the absence of an ENOENT arm on the write path. The failure mode of getting it wrong is silent and severe (share.rb:109-117: a raw Errno reaching the caller burns a preview to a permanent "failed" in GeneratePreviewJob's `rescue StandardError`), which is why two of the seven sites needed a dedicated comment just to say "keep this call inside the begin".

**Proposed representation**

Two named private raisers called from the existing rescue arms: `missing_or_unmounted!(label, err)` (the read-side ENOENT decision, one definition, used by read, download and undelete's missing-src branch) and `transient!(label, err)` (the SystemCallError → FetchError mapping, used by all four write sites). Deliberately raisers, not block wrappers: #write must `FileUtils.rm_f(tmp)` before raising (:229) and #delete keeps its distinct Errno::EXDEV message plus `discard_empty(dest_dir)` (:328-341), so a wrapper would need escape hatches that cost more than it saves.

**Why simpler**

Two named policies instead of seven hand-applied ones, and the read/write ENOENT asymmetry becomes something you can see at the call site (`missing_or_unmounted!` vs `transient!`) rather than something you infer from a missing rescue arm. A new I/O call site then has an obvious default to reach for, which is what the two "keep mkdir_p inside the begin" comments are currently doing in prose.

**Smallest credible implementation scope**

share.rb only. Two ~4-line private methods; seven rescue bodies become one-liners. Smallest credible slice, if you want only the highest-value part: collapse just the verbatim read/download ENOENT+SystemCallError pair (share.rb:93-117 and :164-171), leaving the write-side four alone.

**Affected files**

- `app/services/file_layer/share.rb`

**Regression risks and migration concerns**

THIS IS THE WEAKER OF MY TWO FINDINGS AND I RECOMMEND SKIPPING IT IF ONLY ONE CHANGE IS MADE. It changes no state representation and a reviewer could fairly call it line-count reduction; the brief warns against exactly that, and I am flagging it rather than dressing it up. Concretely: the three mount-check messages differ in wording today (:105 vs :166 vs :471) and #undelete's terminal message ("its trashed bytes are gone (purged?)", :477) is semantically different from #read's, so the helper must either take the message or the messages must be deliberately unified — and share_test.rb asserts on some of them. There is also no comment anywhere in this file arguing the seven sites must stay separate, so nothing in CLAUDE.md blocks it; the case against is purely that the payoff is small.

**Validation required**

Already covered: test/services/file_layer/share_test.rb:169 ("ENOENT with the library mounted is terminal NotFound"), :179 and :189 (ENOENT with an empty/missing root is TRANSIENT), :200/:207/:214/:225/:236 (ENOTDIR, ELOOP, EISDIR, EACCES, unreadable parent all TRANSIENT), :697 ("a trash dir that cannot be created is TRANSIENT, not a raw errno"), :1020 and :1034 (the same for move's and undelete's destination dirs), :940 ("undelete of a node whose trashed bytes are gone is terminal NotFound") and :956 ("undelete with the library unmounted is TRANSIENT, not a false 'purged'"). Additional validation required: mutation-check per §15 by making `transient!` raise NotFound and confirming :697/:1020/:1034 go RED, and by making `missing_or_unmounted!` skip the `library_present?` question and confirming :179/:189/:956 go RED. Also re-run all three backend legs — the messages are asserted in share-specific tests only, but FetchError→503 / NotFound→404 mapping is shared at FilesController.

### Cross-subsystem concerns raised by this lane

_Named, not solved — the lane was told to stay inside its boundary._

- app/services/file_layer/s3.rb carries the identical four-step destination ladder at four sites (s3.rb:274-277 write, :374-380 mkdir, :488-495 move, :607-610 undelete), differing only in `key_for_rel` where Share has `resolve_inside!`. The two adapters duplicate deliberately — share.rb:757-759 and s3.rb:117 both name this as the standing trade, and CLAUDE.md §14a says the two must resolve 'the file being replaced' differently — so I am NOT proposing to merge them. Naming it: if the ladder is given a name in Share, S3 should get the same shape in its own file so the two stay legible as parallel implementations rather than one refactored and one not.
- `observable!` (share.rb:650-673) composes its predicate from Library::Scanner::TRASH_PREFIX, Library::Scanner::TEMP_PREFIX, Library::OsClutter and Library::RepoMetadata.marker_prefix. That composition-not-copying is required by §14b and by the guard's own comment; any change here must keep reading those constants rather than the strings. The skip-list definitions themselves live in the Library::Scanner subsystem and are out of scope for me.
- share.rb:490 records that S3#undelete had the observable! guard 'since Phase 3' while Share did not — i.e. the two adapters' write-guard sets have drifted before and were reconciled by the shared adapter_write_contract. Whether that contract enumerates every guard (rather than every verb) is a question for whoever owns test/services/file_layer/adapter_write_contract.rb, not for this file.

---

## S03 — FileLayer::S3 adapter

**Lane verdict:** `recommend`

### S03-1 — The four mutating verbs each re-assemble the same destination-composition guard sequence by hand

> **COORDINATOR VERDICT — NARROWED.** Same as S02-1: composer yes, value type no.

- **Category:** control-flow  
- **Lane confidence:** medium

**Evidence**

- app/services/file_layer/s3.rb:274-277 — write: `leaf!(name)` / `rel = join_rel(parent_dir_rel!(user, parent_node_id), name)` / `observable!(rel)` / `key = key_for_rel(rel)`
- app/services/file_layer/s3.rb:375-380 — mkdir: the identical three lines (375-376), then the idempotence short-circuit, then `key = key_for_rel(rel)` at 380
- app/services/file_layer/s3.rb:493-495 — move: `rel = join_rel(parent_dir_rel!(user, new_parent_node_id), new_name)` / `observable!(rel)` / `dest_key = key_for_rel(rel)`
- app/services/file_layer/s3.rb:608-610 — undelete: the same three, with `live: false` on parent_dir_rel! and `node.name` in place of a caller-supplied leaf
- app/services/file_layer/s3.rb:1031-1033 — the guard's own header carries a leftover cross-task note, "NOTE FOR TASK 6: `move`'s destination needs this same guard", i.e. the sequence was demonstrably forgotten once and had to be flagged in prose to the next author
- app/services/file_layer/s3.rb:707-711 — trash_key composes through key_for_rel and DELIBERATELY not through observable! ("this key is the one legitimate exception to it") — the documented exception any helper must not absorb
- app/services/file_layer/s3.rb:1034-1055 — observable! is the single skip-list guard whose omission CLAUDE.md §14b records as having wedged the scan four times

**Current complexity / invalid states**

There is one fact here — "how this adapter turns (parent_node_id, leaf name) into a writable rel plus a bucket key" — and it is written out four times, as an ordered three-step sequence whose order is load-bearing: compose the rel from the parent's storage_path, run observable! on it, and only then derive the key. Nothing structural ties the three steps together; the only thing making the four verbs agree is that someone retyped the lines. The failure mode of getting it wrong is the one this file and CLAUDE.md §14b fear most: a verb that skips observable! lands a live node at a key the observer never observes, producing an unpairable ghost whose tombstone wedges the mass-deletion guard on that scan and every scan after it, permanently, with no error anywhere. The prose note left at s3.rb:1031-1033 for a later task is direct evidence that the copy-the-lines convention is what carries the rule between verbs.

**Proposed representation**

One private composer that owns the sequence, e.g. `destination!(user, parent_node_id, name, live: true)` returning the (rel, key) pair — a two-value return or a tiny Struct — and doing exactly `rel = join_rel(parent_dir_rel!(user, parent_node_id, live:), name)`, `observable!(rel)`, `key_for_rel(rel)`, in that fixed order. The four verbs then call it once. Deliberately NOT absorbed into it: `leaf!`, which validates CALLER INPUT and is correctly absent from undelete (whose name comes from the node, not the caller), so it stays at the top of write/mkdir/move; and `trash_key`, whose bypass of observable! is documented at s3.rb:707-711 and must remain a separate path.

**Why simpler**

It converts a remembered convention into a structural one: after the change there is no way to obtain a destination key in this adapter without having passed the skip-list guard, because the only function that produces the key runs it. Today a fifth destination-minting verb gets a working, plausible-looking implementation while silently missing the guard — which is precisely how the note at s3.rb:1031-1033 came to exist. It also removes the two silent divergence points among the existing four copies (which `live:` the parent lookup uses, and whether observable! precedes key derivation) by making them one decision instead of four.

**Smallest credible implementation scope**

One new ~6-line private method in app/services/file_layer/s3.rb and four call sites edited (write, mkdir, move, undelete). No signature, schema, or cross-file change. Roughly a dozen lines net.

**Affected files**

- `app/services/file_layer/s3.rb`

**Regression risks and migration concerns**

One real behavior change to decide on: mkdir currently derives its key AFTER the idempotence short-circuit (s3.rb:377-380), so a poisoned parent storage_path containing a `..` segment (reachable only via update_column, which the file's own comments treat as in scope) presently returns the existing dir node, whereas a hoisted key_for_rel would raise NotFound first. That is arguably the more correct answer, but it is a change and should be stated rather than slipped in — or avoided by having the composer return the rel with the key derived lazily. Second risk: undelete must keep `live: false`, so the keyword has to be threaded rather than defaulted away — collapsing it would make the last file in any emptied folder permanently unrestorable (s3.rb:1062-1068). Third: trash_key must not be routed through the composer.

**Validation required**

Already covered by existing tests, which is what makes this safe to attempt: test/services/file_layer/adapter_write_contract.rb:213-222 (write refuses OS-clutter destinations), :224-233 (move), :236-256 (undelete, through a poisoned parent), :277-312 (write/move/mkdir refuse `.git`), plus the negative case that follows it; and test/services/file_layer/s3_test.rb:366 and :1386 (write and move refuse the TRASH_PREFIX), :346 and :1368 (escape guard through a poisoned parent), :1609 and :1624 (mkdir idempotence and nesting), :1440 and :1459 (undelete into a subdirectory and into a tombstoned parent). Additional validation required: mutation-check the composer by deleting the observable! call inside it and confirming the write-contract clutter tests go red for all four verbs — the guard is only worth consolidating if the consolidated copy is proven to be the one doing the work.

### S03-2 — The identity ladder is a three-rung discriminated union whose decoders live outside the class that owns the encoding

> **COORDINATOR VERDICT — REJECTED.** Lane states it "buys no behavior change today"; the motivating fourth rung is blocked by LIBRARY_S3_HEAD_FOR_CHECKSUM, which CLAUDE.md 14a records as not implemented. Hypothetical extensibility.

- **Category:** state-representation  
- **Lane confidence:** medium

**Evidence**

- app/services/file_layer/s3/object_identity.rb:47 — `CONTENT_DETERMINED_PREFIXES = %w[ md5: sha256: ].freeze`, one view of the union
- app/services/file_layer/s3/object_identity.rb:95-97 — `content_determined?(identity)` answers question one via `start_with?(*CONTENT_DETERMINED_PREFIXES)`
- app/services/file_layer/s3.rb:780-784 — `etag_precondition(identity)` answers question two in a DIFFERENT file, by regex: `case identity.to_s when /\Amd5:(.+)\z/, /\Aetag:(.+)\z/ then %Q("#{Regexp.last_match(1)}")`
- app/services/file_layer/s3.rb:763-768 — the rung vocabulary is spelled out a third time, in prose, above that method (md5 -> match it, etag -> match it, sha256 -> send nothing)
- app/services/file_layer/s3.rb:756-761 — what the decode protects: without the precondition, "an unconditional copy would trash bytes the user never meant to lose and then delete them from their key"
- app/services/file_layer/s3/object_identity.rb:14-40 — the class header explicitly claims ownership of what the prefixes mean ("The namespacing is load-bearing, not decoration")

**Current complexity / invalid states**

`ObjectIdentity.for` produces a tagged union serialized as a prefixed string, and the class owns the ENCODE side completely (it is documented as "the ONE normalizer", and the quote-stripping is "the ONE place the quotes come off"). The DECODE side is split: one of the two orthogonal questions about a rung — is it content-determined? — is answered inside the class from a prefix list, and the other — is it a wire ETag we may send as If-Match? — is answered by a regex in s3.rb, with a third statement of the same table sitting in a prose comment above it. There is no structure asserting that the two predicates cover the same three rungs. Adding a fourth rung (AWS's newer full-object CRC32C checksums are the obvious candidate, and the header already anticipates a HEAD-based rung) means editing a list in one file and a regex in another; forgetting the second is SILENT — the case simply falls through to nil, the copy precondition stops being sent for those objects, and the only visible effect is the copy-safety guard quietly not being there any more.

**Proposed representation**

Put the union's table in the class that documents it: one RUNGS map, prefix -> { content_determined:, wire_etag: }, with `content_determined?` reading it and a new `ObjectIdentity.wire_etag(identity)` returning the raw ETag or nil. `S3#etag_precondition` then becomes `tag = ObjectIdentity.wire_etag(identity); %Q("#{tag}") if tag` — the quoting stays in the adapter, because quoting is a wire concern and the ladder is deliberately not a wire format (s3.rb:777-779 says exactly that).

**Why simpler**

One rung becomes one row answering both questions, so the two predicates cannot disagree about which rungs exist, and the third statement of the table (the prose at s3.rb:763-768) can shrink to the reason rather than re-listing the members. It also moves a rung-parsing regex out of the adapter, matching the ownership rule the ladder already states for the encode side. Be clear about the size: this is ~15 lines and buys no behavior change today — its whole value is that a future rung cannot be added while answering only one of the two questions, in a place where the wrong answer is silent.

**Smallest credible implementation scope**

Add the RUNGS table plus `wire_etag` to app/services/file_layer/s3/object_identity.rb; rewrite the four-line `etag_precondition` in app/services/file_layer/s3.rb to delegate and keep the quoting. Two files, no callers outside them change.

**Affected files**

- `app/services/file_layer/s3/object_identity.rb`
- `app/services/file_layer/s3.rb`

**Regression risks and migration concerns**

The genuine hazard is making `wire_etag` look like a general "give me the value" accessor and thereby inviting someone to return the sha256 payload from it — which is the exact bug s3.rb:766-768 exists to prevent (an If-Match that can never match refuses every delete and move of such an object, forever). The method must be named and documented by its QUESTION, not by its return type. Second, `nodes.content_hash` is shared with share mode, which stores a bare unprefixed SHA-256 hex (object_identity.rb:88-93), so any table lookup must keep answering "no" for unknown shapes rather than raising. Third: do not move the quoting into the ladder — the quotes are a wire value, and the class's whole identity argument is that its output is not one.

**Validation required**

Existing coverage: test/services/file_layer/s3/object_identity_test.rb:84-86 and :139-140 (content_determined? over all three rungs plus nil/empty), and test/services/file_layer/s3_test.rb:887-918, which asserts at the copy params that an md5 identity is sent QUOTED and a sha256 identity is not sent at all — that test alone pins the behavior end to end through #delete. Additional validation required: unit tests for `wire_etag` per rung in object_identity_test.rb (including the unprefixed share-mode value), and a mutation check — make the sha256 rung return its payload and confirm s3_test.rb:887 goes red on the `assert_nil seen` half.

### Cross-subsystem concerns raised by this lane

_Named, not solved — the lane was told to stay inside its boundary._

- app/services/file_layer/share.rb carries the identical four-copy destination sequence (share.rb:200-204 write, 286-291 mkdir, 396-399 move, 492-494 undelete), with resolve_inside! where S3 has key_for_rel. Finding 1's composer would apply there too — but CLAUDE.md §14a and s3.rb:116-120 forbid hoisting it into a shared base class, so if both adapters are cleaned up it must be done twice, independently. Naming this, not solving it; S02 owns Share.
- Library::S3Observer is the identity ladder's other consumer (app/services/library/s3_observer.rb:164 calls content_determined? to count unpairable objects, :510 calls ObjectIdentity.for). A RUNGS table in ObjectIdentity would be read from there unchanged, but if the observer's rung-3 warning is ever extended to distinguish rungs, that logic belongs in the ladder rather than the observer. Out of my boundary.
- Library::Reconciler#plan_moves (referenced at app/services/library/reconciler.rb:404) is what makes the ladder's totality load-bearing — a nil identity drops the observation from candidates and the object is never indexed. Neither of my findings touches totality, but any future change to ObjectIdentity.for's return contract has to be checked against that call site, which lives outside S03.

---

## S04 — FileLayer::ChunkRemote sync client

**Lane verdict:** `recommend`

### S04-1 — The pruned-gap probe is a second GET /v1/changes for data the first page already carries

> **COORDINATOR VERDICT — ACCEPT.** Verified against the tree; no narrowing applied.

- **Category:** control-flow  
- **Lane confidence:** high

**Evidence**

- app/services/file_layer/chunk_remote/changelog_sync.rb:34 — `resynced = full_resync_if_gapped` runs unconditionally before the paging loop, on every pull.
- app/services/file_layer/chunk_remote/changelog_sync.rb:110 — the probe is a full wire request: `body = @transport.get("/v1/changes", { since: cursor, limit: 1 })`, and only `body["oldest_seq"]` (line 111) and `body["head_seq"]` (line 114) are read; the one entry it fetched is discarded.
- app/services/file_layer/chunk_remote/changelog_sync.rb:39 — five lines later the loop immediately re-asks the same endpoint with the same cursor: `@transport.get("/v1/changes", { since: cursor, limit: PAGE })`.
- docs/sync-protocol.md:588-589 — the normative `GET /v1/changes` 200 body carries `"head_seq"` and `"oldest_seq"` as siblings of `"changes"`; they are properties of the changelog, not of `since` or `limit`, so the PAGE-sized request already contains everything the probe went to fetch.
- config/recurring.yml:158-160 — the schedule's own justification is already written as if this finding were implemented: "a changelog pull that finds nothing is ONE CHEAP GET per user in the common case (ChangelogSync#full_resync_if_gapped's own probe, which returns before any paging loop even starts)". The probe returns `false`, it does not return from `#call`; the loop then runs. The comment is false today.
- test/jobs/file_layer/remote_changelog_pull_job_test.rb:14-16 — the test fake's own comment states the real count: "one full_resync_if_gapped probe + one page GET, both reporting nothing to apply".

**Current complexity / invalid states**

Every pull costs two WAN round trips before it can conclude that nothing changed, and the no-op pull is overwhelmingly the common case: it runs on a 2-minute recurring schedule per user (config/recurring.yml:169-171) and again inside `refresh!` after each of mkdir, delete, undelete and finalize_upload (chunk_remote.rb:232, 270, 279, 351). The gap check and the first page ask the identical endpoint for overlapping data, split across two methods, and the split is not argued anywhere — the surrounding comment (changelog_sync.rb:100-108) explains the gap semantics but never why they need their own request. Two artefacts in the tree already record the cost as one request rather than two, so the split is not just redundant, it is invisible to readers.

**Proposed representation**

Fetch the first page once, read the gap fields off that same body, and reduce `full_resync_if_gapped` to a `gapped?(body)` predicate. Structurally: `body = fetch_changes` before the loop; `if gapped?(body) then full_resync(head_seq: body["head_seq"].to_i); resynced = true; body = fetch_changes end`; then a loop that applies `body["changes"]`, breaks on empty or short page, and re-fetches at the bottom. The gap is still evaluated exactly once, structurally (before the loop, not behind a flag inside it), which is the property that must survive.

**Why simpler**

One request answers one question instead of two requests answering one and a half. It deletes a method and a wire call from the hottest path this subsystem has, makes the no-op pull genuinely the "ONE CHEAP GET" that recurring.yml and the job test already claim it is, and removes the only place where the same endpoint is asked twice with the same cursor for different fields of the same response.

**Smallest credible implementation scope**

changelog_sync.rb only: rewrite `#call` (lines 33-86) to hoist the first fetch, replace `full_resync_if_gapped` (109-116) with a two-line `gapped?(body)` predicate keeping the exact `cursor.positive? && oldest.positive? && cursor < oldest` condition, and add a private `fetch_changes`. `full_resync`, `apply_page`, `upsert`, the cursor-advance guard and the nudge are untouched. Then correct the now-true comment at config/recurring.yml:158-160 and the fake's comment at remote_changelog_pull_job_test.rb:14-16.

**Affected files**

- `app/services/file_layer/chunk_remote/changelog_sync.rb`
- `config/recurring.yml`
- `test/jobs/file_layer/remote_changelog_pull_job_test.rb`

**Regression risks and migration concerns**

The one real hazard is the gap check becoming per-page instead of once. Today it cannot loop: the check runs before the loop and never again. If it were moved inside the loop, a server whose `oldest_seq` stays above the cursor would resync forever — and docs/sync-protocol.md:611-615 makes that reachable, since an emptied changelog reports `oldest_seq = head_seq + 1`, which is above even a caught-up cursor. So the check must stay outside the loop, evaluated at most once. Second hazard: when gapped, the first page's entries must be discarded, not applied, exactly as the probe discards them today — applying them before a resync would write partial post-prune state. This touches nothing CLAUDE.md §2/§6/§14a protect: it does not add a read-path pull, does not cache the transport, does not change what the five write verbs do, and does not touch #batch.

**Validation required**

test/services/file_layer/chunk_remote/changelog_sync_test.rb already covers the whole envelope and should pass unchanged — its FakeTransport answers `/v1/changes` from `@pages.fetch(params[:since], [])` with `head_seq`/`oldest_seq` on every response, and the gap tests (lines 111-141) use cursor 5 / oldest_seq 50 / `pages: { 50 => [] }`, which the folded shape drives identically. Nothing in the tree asserts an exact request count (refresh_after_write_test.rb:81-82 asserts `pulls >= 1`; remote_changelog_pull_job_test.rb:49,62 assert `assert_includes`), so no test pins the current two. Add the assertion that is missing: a no-op pull issues EXACTLY ONE `/v1/changes` GET, using FakeTransport#asked. Mutation-check per §15 by restoring the separate probe and confirming that new test goes red, and by freezing the gap predicate to `false` and confirming the resync tests go red. Also run bin/ci test-chunk-remote, which drives this against a real sync server.

### S04-2 — full_resync's tombstone sweep keeps a parallel in-memory copy of the whole remote tree

> **COORDINATOR VERDICT — ACCEPT.** Verified against the tree; no narrowing applied.

- **Category:** data-structure  
- **Lane confidence:** medium

**Evidence**

- app/services/file_layer/chunk_remote/changelog_sync.rb:122 — `seen = []`, an Array that accumulates one node_id for every live node on the server.
- app/services/file_layer/chunk_remote/changelog_sync.rb:131 — `seen.concat(nodes.map { |n| n["node_id"] })` per 1000-node page, so after the walk `seen` is a second, in-memory representation of exactly what lines 126-130 just wrote into `nodes`.
- app/services/file_layer/chunk_remote/changelog_sync.rb:137 — the sweep is one anti-join against that whole list: `@user.nodes.present.where.not(node_id: seen).update_all(deleted: true) if seen.any?` — a single `NOT IN` whose operand count is the size of the user's entire library, guarded by `seen.any?`.
- app/services/file_layer/chunk_remote/changelog_sync.rb:118-120 — the method's own comment states the sweep's purpose: "marks anything local that the server did not mention as deleted. Without that sweep a resync is additive and every file deleted while we were behind stays visible forever -- the exact failure a resync exists to repair." The `if seen.any?` guard on line 137 disables precisely that repair in the case where the server lists NO live nodes.
- app/services/file_layer/chunk_remote/changelog_sync.rb:57-60 — this file's own scale statement, in the sibling comment arguing for page-at-a-time commits: "a 200k-entry first sync". The sweep's operand list is sized by that same library.
- test/services/file_layer/chunk_remote/changelog_sync_test.rb:124-136 — the only test of the sweep ("a resync SWEEPS local rows the server no longer lists") uses a one-node tree, so neither the operand ceiling nor the empty-tree branch of `seen.any?` is exercised.

**Current complexity / invalid states**

The resync maintains two representations of the same fact — the rows it has just upserted, and `seen` — and reconciles them at the end with one statement whose size is proportional to the library. That representation produces two behaviours nobody chose: (1) a hard ceiling, because a `NOT IN` with one operand per live node runs into the database's bind-parameter limit (SQLite's default SQLITE_MAX_VARIABLE_NUMBER of 32,766; Postgres's 65,535) or, if inlined, a multi-megabyte statement — and this is the recovery path, so it fails exactly when the mirror is already known to be wrong; (2) an empty-tree hole, because `where.not(node_id: [])` looks degenerate, so the `if seen.any?` guard skips the sweep entirely when the server reports zero live nodes, leaving every local row live forever, which is the failure the comment three lines above says the sweep exists to repair. The guard carries no comment, so it is impossible to tell whether it is a deliberate crude mass-deletion guard (the shape §14b requires for share/s3 scans) or an artefact of the anti-join.

**Proposed representation**

Stop materialising the remote tree twice. Keep `seen` as a Set for membership, then compute the stale set locally and update it in bounded batches: `stale = @user.nodes.present.pluck(:node_id).reject { |id| seen.include?(id) }` followed by `stale.each_slice(1000) { |ids| @user.nodes.where(node_id: ids).update_all(deleted: true) }` inside the existing transaction. The `if seen.any?` special case disappears — an empty tree simply makes every local id stale — which forces the empty-tree question to be answered on purpose: either sweep (matching the method's stated contract) or refuse the resync as an unsafe observation with a named error and a comment, mirroring §14b's `Scanner::UnsafeScan` complete-or-abort rule. Do not leave it a silent no-op. (A `resync_token` column stamped at upsert time would remove the in-memory set entirely and is the better end state, but it needs a migration and is not the smallest slice.)

**Why simpler**

One rule instead of a rule plus an unexplained exception, and the sweep's cost stops being a function of how large the library is in a single statement. The anti-join currently forces the code to hold the entire remote id list in memory purely to phrase a negation the database cannot be asked directly; doing the difference in Ruby against a Set makes the intent ("rows this resync did not touch") legible and bounded, and removes the branch that silently inverts the method's documented behaviour.

**Smallest credible implementation scope**

changelog_sync.rb#full_resync only (lines 121-140): `Set.new` instead of `[]`, `merge` instead of `concat`, and the final `@user.transaction` block replaced by the plucked difference plus a batched `update_all`, with the empty-tree decision written down. `#call`, `#apply_page` and `#upsert` are untouched, and no schema changes.

**Affected files**

- `app/services/file_layer/chunk_remote/changelog_sync.rb`

**Regression risks and migration concerns**

The empty-tree case is a genuine judgement call, not a bug fix to apply blind: if the sync server can ever answer `/v1/tree` with an empty `nodes` array for a non-empty library (a permissions or provisioning fault), sweeping unconditionally tombstones the entire mirror, which is the mass-deletion shape §14b spends a whole guard on for share/s3. Whichever answer is chosen must be stated in a comment and pinned by a test. Second risk: the local `pluck` plus the Set is two id lists in memory where there was one — acceptable at 200k UUIDs, and the stamp-column alternative removes both. Nothing here touches §2/§6/§14a: the resync is already the sanctioned non-read-path pull, the transport is not cached, and the mutation verbs are unchanged.

**Validation required**

test/services/file_layer/chunk_remote/changelog_sync_test.rb:111-136 covers both resync tests and must stay green. Add two it does not have: a resync against a tree spanning more than one page (exercising the per-page merge plus a batched sweep), and a resync against an EMPTY tree asserting whichever behaviour is decided — that second test is the one that pins the `seen.any?` question, and per §15 should be mutation-checked by restoring `if seen.any?` and confirming it goes red. bin/ci test-chunk-remote drives the real server for the ordinary path.

### Cross-subsystem concerns raised by this lane

_Named, not solved — the lane was told to stay inside its boundary._

- A mid-stream chunk failure is delivered to the browser as a truncated 200. ChunkRemote#download builds a lazy Enumerator (chunk_remote.rb:164) whose per-chunk fetch can raise NotFound or FetchError (chunk_remote.rb:388-396), and FilesController's Stream branch (app/controllers/files_controller.rb:630-636) assigns it to response_body with no Content-Length, so status and headers are already sent when the raise happens. That is the same silent truncation chunk_remote.rb:143-153 refuses to redirect multi-chunk files in order to avoid. The node's byte size is known locally (nodes.size, written by ChangelogSync#upsert), so FileLayer::Delivery::Stream could carry it and the controller could set Content-Length — but Delivery and FilesController are outside this boundary. Naming only.
- The pruned-gap comparison may be off by one, and if so it is wrong in the protocol spec too. changelog_sync.rb:112 treats `cursor < oldest_seq` as a gap, but the client needs entries with `seq > cursor`, so `oldest_seq == cursor + 1` (nothing the client still needs was pruned) is not a gap. docs/sync-protocol.md:611-615 additionally specifies `oldest_seq = head_seq + 1` for an emptied changelog, which makes a fully caught-up cursor compare as gapped and would drive a full /v1/tree resync on every 2-minute pull once retention is enabled. The rule as coded matches the protocol doc's own prose, so the question belongs to chaim354/tinkerex-sync's wire spec, not to this adapter. Not fixed here, and finding 1's implementation must preserve the existing condition verbatim.
- RemoteManifestChunk rows are never reaped. ChangelogSync#store_manifest (changelog_sync.rb:205-214) replaces rows per version_id but nothing ever deletes the manifests of superseded versions, and the migration's header (db/migrate/20260821130000_create_remote_manifest_chunks.rb:18-19) states that keeping an old version's manifest is a contract requirement for `read(content_token: <older>)`. So the table grows without bound for the life of a library, with no owner. Whether that needs a retention sweep is a data-lifecycle question spanning maker_previews' content_token usage; flagged, not solved.

---

## S05 — Library reconciler

**Lane verdict:** `recommend`

### S05-1 — One in-memory model of the live tree: fold @dir_ids into #live, and give the mirror two named operations instead of five hand-maintained sites

> **COORDINATOR VERDICT — ACCEPT.** Verified against the tree; no narrowing applied.

- **Category:** index-or-collection  
- **Lane confidence:** high

**Evidence**

- app/services/library/reconciler.rb:98 — `@dir_ids = {} # rel_path => node_id, filled by ensure_dirs as it walks shallowest-first`: a SECOND index over the same live-tree state that `#live` already holds.
- app/services/library/reconciler.rb:595 — skip path stamps `@dir_ids[o.rel_path] = row.node_id`, where `row` is literally `live[o.rel_path]` (assigned at line 577). The value written is already reachable as `live[o.rel_path].node_id`.
- app/services/library/reconciler.rb:609 and 618-621 — write path stamps `@dir_ids[o.rel_path] = node.node_id` and, three lines later, `live[o.rel_path] = LiveRow.new(... node_id: node.node_id ...)`. Same fact, two places.
- app/services/library/reconciler.rb:686 — the only reader: `@dir_ids[dir] || live[dir]&.node_id`. The fallback already answers everything the first term answers (verified against both stamp sites above).
- app/services/library/reconciler.rb:591-594 — the comment 'THE `@dir_ids` STAMP IS NOT OPTIONAL ON THE SKIP PATH … skipping without filling it makes every file under an unchanged directory resolve its parent … to nil at worst — the tree, silently flattened.' A footgun that exists only because the second index exists.
- app/services/library/reconciler.rb:717-723 — '#live … mirrors `present`. Every site that tombstones, revives or re-stamps a node maintains it — FIVE of them … (That last one was missing, and an earlier version of this very comment enumerated only four while claiming "every" — probed in review, one stale key.)' The invariant is a prose promise repeated at five call sites, and it has already been broken once.
- app/services/library/reconciler.rb:450-453, 552-555, 618-621 — three separate 8-field `LiveRow.new(id:, node_id:, kind:, name:, mtime:, size:, content_hash:, parent_node_id:)` constructions, each built from a freshly-`update!`d node.
- app/services/library/reconciler.rb:310-311, 581-582, 671-672 and 161-164 — four copies of the same tombstone triple: load the row by id, `update!(deleted: true)`, `live.delete(path)`.

**Current complexity / invalid states**

The pass keeps two mutable in-memory representations of one fact (which node lives at which path): `#live` (path => LiveRow, mirroring `present`) and `@dir_ids` (dir path => node_id, a strict subset of what `#live` already holds). Consistency between the DB and `#live` is maintained by hand at five sites, and consistency between `#live` and `@dir_ids` at two more. Nothing structural enforces either: the file itself records that the five-site enumeration was written as four and that one stale key survived into review (l.150-160, l.717-723), and that omitting one `@dir_ids` stamp silently flattens the tree (l.591-594). The mapping node -> LiveRow is spelled out three times with eight fields each, and the tombstone-and-evict sequence four times.

**Proposed representation**

Make `#live` the single index for the pass and express the two things that happen to it as named operations. (a) Delete `@dir_ids` entirely; `parent_id_for` becomes `live[dir]&.node_id`, and the ensure_dirs skip path becomes a genuine `next` with nothing to remember. (b) Add `LiveRow.from(node)` (one definition of the 8-field mapping) plus two private helpers — `stamp_live!(node)` doing `live[node.storage_path] = LiveRow.from(node)`, and `retire!(node_or_row, path)` doing the load / `update!(deleted: true)` / `live.delete(path)` triple. The five maintenance sites then read as one line each and the invariant comment can point at two methods instead of enumerating call sites.

**Why simpler**

It removes a whole second index and the one documented 'not optional' stamp that goes with it, and it turns a prose invariant that has already been miscounted once into two named operations a reader can grep for. The three LiveRow constructions are provably equivalent to `LiveRow.from(node)`: apply_moves! already passes `node.kind`, and create_or_revive!/ensure_dirs pass the literals `"file"`/`"dir"` immediately after an `update!` that set exactly those values, so no field changes. Every §14b rule is untouched — the guard still reads the post-pairing `doomed` count, the two tombstone kinds still stay apart (`#live` remains `present`-only, l.729-732), pairing and the deterministic tie-break are not in scope, and no query is added or removed (the no-op query-budget test at test/services/library/reconciler_test.rb:651 stays at its current number).

**Smallest credible implementation scope**

Smallest credible slice is (a) alone: delete l.98, l.595, l.609, simplify l.686 to `live[dir]&.node_id`, and drop the now-moot l.591-594 paragraph — four lines of code. (b) is a separate, mechanical follow-up touching l.161-164, 310-311, 450-455, 552-555, 581-582, 618-621, 671-672.

**Affected files**

- `app/services/library/reconciler.rb`

**Regression risks and migration concerns**

One real behavioural divergence, in the kind-collision case only: today, if a path is observed as BOTH a dir and a file, ensure_dirs stamps @dir_ids, match_live_paths then tombstones that dir node and evicts it from #live (l.306-312), and a child of that path still resolves its parent to the tombstoned dir node via @dir_ids; with live-only lookup it would resolve to nil (library root). Both are defensible and neither is asserted: test/services/library/reconciler_test.rb:673-682 states outright that 'WHICH kind should win is not the Reconciler's question and is not asserted here — S3Observer drops the colliding file observation so this pair never reaches a production Reconciler', and app/services/library/s3_observer.rb:171-193 documents that filter (a filesystem entry cannot have two kinds, so the Scanner cannot produce it either). Name this in the commit rather than letting a future reader discover it. Second risk: the ensure_dirs skip path currently never touches #live, so removing @dir_ids makes correct parenting depend on the initial pluck holding the right node_id for an unchanged dir — true by construction, but worth a test rather than an argument.

**Validation required**

test/services/library/reconciler_test.rb covers the tree shape ('directory nodes are synthesized and parent the tree', l.225), the ensure_dirs write-back that prevents RecordNotUnique (l.683), dir revive/repair on the S3 shape (l.594-650), and the per-pass query budget (l.651). Missing and needed for this change: a test that a NEW file added under an ALREADY-INDEXED (skip-path) directory gets that directory's node_id as its parent — that is the exact case l.591-594 warns about and nothing currently pins it. Mutation-check per §15: delete one `live.delete(...)` in `retire!` and one `stamp_live!` call and confirm the suite goes red (today the missing fifth site was 'harmless by luck', l.150-157, so at least the ensure_dirs one must fail).

### S05-2 — Stamp the resolved identity onto the Observation instead of threading a parallel (observation, hash) tuple through pairing

> **COORDINATOR VERDICT — NARROWED.** Internally inconsistent: titled "stamp identity onto the Observation", scope says "No change to Observation". Keep the concrete trap it names — the pairing key is `[h, o.size]` on one side and `[node.content_hash, node.size]` on the other; the natural `[o.content_hash, o.size]` passes the s3 leg and silently stops every move-pair on share.

- **Category:** data-structure  
- **Lane confidence:** medium

**Evidence**

- app/services/library/observation.rb:40 — `Observation = Data.define(:rel_path, :size, :mtime, :dir, :content_hash)`: the observation already HAS a content_hash field.
- app/services/library/reconciler.rb:770 — `return o.content_hash if o.content_hash` in `hash_for`, so on S3 (where identity always arrives in the listing) the pair built one line later is literally `[o, o.content_hash]` — the same value carried twice.
- app/services/library/reconciler.rb:407 — `candidates = unmatched.filter_map { |o| (h = hash_for(o)) && [ o, h ] }` creates the two-element tuple that every downstream step then has to destructure.
- app/services/library/reconciler.rb:411 vs :505 — the pairing key is spelled `[ h, o.size ]` on the candidate side and `[ node.content_hash, node.size ]` on the vanished-node side. Two spellings of one key, one of which deliberately does NOT read `o.content_hash`.
- app/services/library/reconciler.rb:423-426 — `o, hash = pair; by_key[[ hash, o.size ]].delete_if { |c| c.equal?(pair) }; moves << [ node, o, hash ]`: the tuple has to be re-keyed by hand to find its own bucket.
- app/services/library/reconciler.rb:444-448, :165, :535 — the pair is destructured again in `apply_moves!` (`content_hash: hash`), in `#call`'s leftovers loop (`enqueue_thumbnail(create_or_revive!(o, hash), hash)`), and in `create_or_revive!(o, hash)`'s attrs.
- test/services/library/reconciler_test.rb:721-731 — `#with` is already an accepted, pinned mechanism on this Data ('#with must survive the default -- the S3 observer builds on it').

**Current complexity / invalid states**

Between `plan_moves` and `create_or_revive!`, an observation's identity lives in two places at once: `Observation#content_hash` (which may be nil on the lazy share path, and is authoritative on the S3 path) and a separately-carried `hash` in a `[o, h]` tuple (never nil). The pair `[o, h]` can represent a state that should not exist — `o.content_hash` set and disagreeing with `h` — and the code must remember, at seven sites, which of the two is the trustworthy one. The concrete trap is the pairing key: writing the natural spelling `[ o.content_hash, o.size ]` at l.411 instead of `[ h, o.size ]` would compile, pass the S3 leg (where they are equal), and silently stop pairing every move on the share leg — and a pairing failure is a tombstone, i.e. orphaned attachments, BOM links and tags. Nothing in the code prevents that edit.

**Proposed representation**

Resolve the identity once and put it on the object: `candidates = unmatched.filter_map { |o| (h = hash_for(o)) && (o.content_hash ? o : o.with(content_hash: h)) }`. `candidates`, `by_key`'s buckets, `best_pairing`'s return, `leftovers` and `create_or_revive!`'s argument all become plain Observations whose `content_hash` is non-nil by construction. Both sides of the pairing key then read the same field: `[o.content_hash, o.size]` and `[node.content_hash, node.size]`. `moves` becomes `[node, o]`, and `enqueue_thumbnail` can take the value off the node it was just handed.

**Why simpler**

One value in one place instead of the same value carried twice with a nullable copy alongside, and the illegal (disagreeing) combination stops being representable. It also collapses the two spellings of the pairing key into one, which is the seam most likely to be broken silently. It does not add a type — `Observation` already has the field, and `#with` is already exercised by an existing test. Nothing §14b protects changes: the bucket is still keyed by [hash, size], `min_by` over a `group_by`-ordered bucket keeps the deterministic tie-break and the same-element guarantee argued at l.462-475, and `filter_map`'s drop-a-nil-hash behaviour (l.393-406) is preserved verbatim.

**Smallest credible implementation scope**

One method plus its consumers: `plan_moves` (l.392-438), `best_pairing`'s signature/body (l.503-508), `apply_moves!` (l.443-455), `#call`'s leftovers loop (l.165-167), `create_or_revive!` (l.535-557). No change to `Observation`, to the observers, or to `hash_for`.

**Affected files**

- `app/services/library/reconciler.rb`

**Regression risks and migration concerns**

Two things must survive unchanged. (1) Identity, not equality, still decides bucket consumption and `claimed` (l.414, 419-424): `#with` returns a fresh frozen object, so `equal?` still separates two candidates that happen to be `==`, but the `compare_by_identity` hash and the `delete_if { equal? }` must be kept as-is — the comment at l.419-422 explains why, and l.464-466 notes rel_path uniqueness is an input property nothing enforces. (2) Allocation on a first S3 scan: stamping unconditionally would allocate one Observation per object across a whole bucket, so keep the `o.content_hash ? o : o.with(...)` short-circuit, which is free because `hash_for` returns that same value (l.770). Lower payoff than finding 1, and the current code is not wrong — this is about removing a silent-edit trap, not fixing a bug.

**Validation required**

Covered today by test/services/library/reconciler_test.rb: 'a RENAME keeps the node_id' (l.98), 'a MOVE to another directory keeps the node_id' (l.110), 'ambiguous identical files tie-break deterministically' (l.165), 'a move ONTO a tombstoned path pairs the move' (l.204), 'an unreadable NEW file is left for the next pass, not indexed half-formed' (l.288), and the supplied-hash pair at l.490-537 which drives the S3 shape. Additional validation: run the s3 leg as well as the share leg (they exercise the two arms of `hash_for`), and mutation-check by making the candidate-side key read a stale field — with the change, share and s3 must both go red, which is precisely what cannot happen today.

### Cross-subsystem concerns raised by this lane

_Named, not solved — the lane was told to stay inside its boundary._

- Scanner/S3Observer (S04): `observations` and `unreadable_dirs` must arrive together or the pass tombstones what it never looked at (reconciler.rb:75-83). The file itself floats `Scanner::Report = Data.define(:observations, :unreadable_dirs)` and declines it; that call is the observers', not the reconciler's.
- FileLayer::S3::ObjectIdentity: plan_moves' `filter_map` drop (reconciler.rb:393-406) silently never-indexes an observation with a nil hash, and its safety rests entirely on ObjectIdentity being TOTAL. That coupling is real and undefended by anything in this subsystem's tests.
- S3Observer's LANDMINE 7 filter (s3_observer.rb:171-193) is what keeps the one-path-two-kinds contradiction out of the reconciler. Finding 1's only behavioural divergence sits in that case, so if that filter is ever relaxed, revisit.

---

## S06 — Library observers (scanner + S3 observer)

**Lane verdict:** `recommend`

### S06-1 — S3Observer's dir accumulator is never used as the index it already is — every object re-derives an ancestor chain that is provably already present

> **COORDINATOR VERDICT — REJECTED.** Unmeasured by the lane's own admission, and the proposed early-out MANUFACTURES the hazard it guards: prefix-closure is emergent today, a precondition after.

- **Category:** index-or-collection  
- **Lane confidence:** medium

**Evidence**

- app/services/library/s3_observer.rb:117 — `dirs  = Set.new`, the accumulator for every synthesized directory path in the bucket.
- app/services/library/s3_observer.rb:150 — repo-metadata branch: `dirs.merge(dir_chain(Library::RepoMetadata.marker_prefix(rel)))`.
- app/services/library/s3_observer.rb:159 — directory-marker branch: `dirs.merge(dir_chain(rel))`.
- app/services/library/s3_observer.rb:167-168 — the file branch, i.e. the per-object hot path: `parent = File.dirname(rel)` then `dirs.merge(dir_chain(parent)) unless parent == "."`. This runs once for EVERY indexable object in the bucket.
- app/services/library/s3_observer.rb:544-547 — `dir_chain` is `parts = dir_rel.split("/")` then `parts.each_index.map { |i| parts[0..i].join("/") }`: it allocates a sub-array and a joined String for every ancestor level, unconditionally, with no reference to what `dirs` already holds.
- app/services/library/s3_observer.rb:203 — `shadowed, files = files.partition { |o| dirs.include?(o.rel_path) }` — the file asks `dirs` the membership question exactly once, at the very end, and never during accumulation.
- app/services/library/s3_observer.rb:531-534 — `dir_observations` sorts the whole set by `rel.count("/")`, confirming the set is the authoritative dir collection and that the Reconciler is handed one observation per distinct prefix, however many times it was merged.
- app/services/library/repo_metadata.rb:93-97 — `marker_prefix` returns a slash-joined path with no trailing separator, so the chain fed in at line 150 is the same shape as the other two call sites (this is what makes the closure argument hold for all three insertion points).
- app/services/library/s3_observer.rb:433-459 — `indexable?` rejects any key with an empty, "." or ".." segment before a key can reach `observe`, so `dir_chain` never sees a degenerate path (no leading/trailing-slash edge case to worry about in the early-out).

**Current complexity / invalid states**

`dirs` is a prefix-closed set by construction — every one of its three insertion sites (150, 159, 168) inserts a complete `dir_chain`, so if a prefix is in the set, all of its ancestors are too. That invariant is real and load-bearing (the Reconciler's `ensure_dirs` walks shallowest-first and resolves each dir's parent from the ones already created; a set that lost an intermediate prefix would leave descendants without a parent node), but it is stated nowhere and enforced only by the coincidence that all three writers happen to funnel through one helper. Because nothing consults the invariant, the per-object path at 167-168 re-derives the entire ancestor chain of a prefix the set almost always already contains: for a bucket of N objects at depth d, roughly N*(d split segments + d sub-arrays + d joined Strings + d Set probes), while the number of DISTINCT prefixes is typically a few orders of magnitude smaller. On this backend's own stated target — the "point it at my existing 2M-object bucket" on-ramp that `file_observation`'s comment at s3_observer.rb:491-494 prices listings for — that is tens of millions of throwaway String allocations per scan, repeated on the 15-minute schedule, inside a method that is simultaneously holding N Observations in memory. Nothing in the file, in CLAUDE.md §14b, or in the tests argues for re-deriving rather than consulting; unlike almost every other apparent redundancy in these two files (the three `nanos` copies at s3_observer.rb:555-559, the deliberately un-mirrored `TEMP_PREFIX` at 469-473, the always-empty `unreadable_dirs` at 78-96, the rejected `Scanner::Report` Data type at reconciler.rb:82-83), this one has no recorded argument behind it.

**Proposed representation**

Give the accumulator one door that owns the invariant. Smallest form: a private `record_dir(dirs, rel)` that returns early when `dirs.include?(rel)` and otherwise merges `dir_chain(rel)`, with the three sites at 150/159/168 calling it; the comment on it states the property that makes the early-out sound ("`dirs` is prefix-closed because every insertion is a whole chain, so a prefix already present implies all its ancestors are — do not add to this set except through here"). Slightly stronger form, if the invariant is judged worth making structural rather than documented: a tiny `DirPrefixes` collection wrapping the Set, exposing only `add_chain(rel)`, `include?(rel)`, and `each`/`sort_by` for `dir_observations` — so `dirs << rel` is not a thing a later edit can write at all. Either way the output is bit-for-bit identical (the Set already deduplicated; the merge was a no-op whenever the early-out fires) and `dir_chain`, the partition at 203, and `dir_observations` are untouched.

**Why simpler**

The set stops being a write-only bag that a separate function keeps recomputing inputs for, and becomes what it already is at line 203 — an index that answers "do I know this prefix?". The prefix-closure property that the Reconciler's parent resolution silently depends on moves from an emergent coincidence of three call sites into one named place that says it out loud, which is the same move `Library::RepoMetadata` made for `marker?`/`marker_prefix`/`internal?` (repo_metadata.rb:104-107, "ONE QUESTION MUST NOT BE SPELLED TWO WAYS"). The redundant work disappears as a consequence rather than as the goal. It is also squarely the shape CLAUDE.md §14b already records getting wrong once — the Reconciler's old comment argued per-item cost was "dwarfed by the hashing" while the scan was quadratic — i.e. per-object work in an observer assumed negligible and never measured.

**Smallest credible implementation scope**

One file: app/services/library/s3_observer.rb. Add the private `record_dir` (or the small collection), change the three `dirs.merge(dir_chain(...))` calls at 150, 159 and 168 to use it, and write the invariant in its comment. No change to `dir_chain`, `dir_observations`, `#observe`'s return value, `#indexable?`, the Reconciler, ScanJob, or any public signature. Roughly a dozen lines.

**Affected files**

- `app/services/library/s3_observer.rb`
- `test/services/library/s3_observer_test.rb`

**Regression risks and migration concerns**

The early-out is sound ONLY while every insertion is a complete chain. If a later edit adds a bare `dirs << rel` for some new key shape, prefix-closure breaks and the early-out then silently drops intermediate prefixes — descendants lose their parent node, which is the quiet-tree-damage failure mode this file already fears elsewhere. That risk is the argument for the `DirPrefixes` form over the bare private method: it makes the wrong spelling unavailable rather than merely discouraged. Second, smaller risk: this touches the exact loop that resolves LANDMINE 7 (the dir/file key collision at 203) and the repo-marker ordering at 149-153, both of which have hard-won, order-dependent semantics — the change must not reorder those branches, only alter what happens inside each one's merge. Third: this is a constant-factor win, not an asymptotic one; if the reviewer's bar is 'no perf change without a measurement', the honest answer is that no measurement exists here today and the finding's primary claim is the invariant, not the allocations.

**Validation required**

Existing coverage is strong and should stay green unchanged, since the output is identical: test/services/library/s3_observer_test.rb:83 ("synthesizes directory nodes from key prefixes so the tree still has parents"), :127 ("a directory-marker object with no children is still a directory"), :195 ("a collision on a derived ancestor drops the file and keeps the whole dir chain" — the multi-level chain case), :317 (".git becomes ONE synthesized dir node and its keys are dropped", the line-150 branch), :335 ("a directory-marker object INSIDE the repo does not mint a node beneath the marker", the ordering this must not disturb), and :485 (pagination, so the set survives across pages). Additional validation required: one new test asserting the emitted dir observations are PREFIX-CLOSED for a fixture mixing several depths, a marker object and a repo (assert every `rel_path` containing a slash has each of its ancestors present) — that is the assertion the early-out now depends on and nothing currently makes. Mutation-check it per §15: break closure deliberately (make one insertion site add only the leaf) and confirm the new test goes RED; a green mutation means the test is decorative.

### Cross-subsystem concerns raised by this lane

_Named, not solved — the lane was told to stay inside its boundary._

- Library::Reconciler (S05) is handed the complete observation list in memory — for the 2M-object bucket this backend advertises as its on-ramp, that is 2M Observation structs alive at once alongside the dirs set. Complete-or-abort makes streaming a non-starter, so this is a stated cost rather than a defect; naming it only because it is the memory ceiling the S06 hot loop feeds.
- The observer protocol ScanJob depends on (`.call` returning self, `#call`, `#observe`, `#unreadable_dirs`) is duck-typed with no shared contract test, unlike FileLayer's adapters which have test/services/file_layer/adapter_contract.rb and adapter_mutation_contract.rb. ScanJob.observer_for (scan_job.rb:152-157) is a plain `case/when` dispatch whose failure mode is a loud raise, so this is not urgent — but a third observer could satisfy the case arm and diverge on the protocol with nothing red. That belongs to ScanJob/test infrastructure, not to these two files.
- Library::Observation (observation.rb:40-53) is a five-field Data whose validity depends on `dir`: `size` is nil for dirs, `mtime` is nil for s3 dirs but a real value for share dirs, `content_hash` is nil for share files but always present for s3 files. A discriminated union would make the invalid combinations unrepresentable, but the type is the Reconciler's shared vocabulary and any change is centred on observation.rb + reconciler.rb, outside this boundary.

---

## S07 — Library jobs (scan and trash purge)

**Lane verdict:** `recommend`

### S07-1 — ScanJob's post-reconcile sequence is three copies of one step shape; make it one ordered table + one runner

> **COORDINATOR VERDICT — ACCEPT.** Verified against the tree; no narrowing applied.

- **Category:** control-flow  
- **Lane confidence:** medium

**Evidence**

- app/jobs/library/scan_job.rb:96-98 — `#perform` ends with three bare calls, `discover_projects(user)` / `intake_project_folders(user)` / `intake_models(user)`; this call sequence is the ONLY place the load-bearing order is actually expressed as code.
- app/jobs/library/scan_job.rb:222-227 — `def discover_projects(user)` is `Maker::ProjectDiscoveryJob.perform_now(user_id: user.id)` + `rescue StandardError => e` + `Rails.logger.error("Library::ScanJob: the reconcile SUCCEEDED but project discovery failed for user #{user.id}: #{e.class}: #{e.message}")`.
- app/jobs/library/scan_job.rb:273-278 — `def intake_project_folders(user)` is byte-for-byte the same shape against `Maker::ProjectIntakeJob`, differing only in the phrase "the project-folder intake".
- app/jobs/library/scan_job.rb:302-309 — `def intake_models(user)` is the same shape again against `Maker::ModelIntakeJob`, phrase "the model catalog".
- test/jobs/library/scan_job_test.rb:434-436 — the test's own comment: "the rescues are separate, and deleting the one in #intake_models left every test in the repo green until this existed" — i.e. an omitted copy of this policy is silent by construction.
- app/jobs/maker/project_discovery_job.rb:32 (`def perform(user_id:)`), and `grep -n 'def perform' app/jobs/maker/project_intake_job.rb app/jobs/maker/model_intake_job.rb` → :42 and :16, both `def perform(user_id:)` — all three callees share one interface, so nothing is being branched on.
- docs/invariants/project-intake.md:53 — "`Library::ScanJob#perform` sequences `discover_projects` → `intake_project_folders` → `intake_models` inline, all via `perform_now`, inside one call" — the invariant doc has to restate the order in prose because the code has no single artifact holding it.

**Current complexity / invalid states**

One policy — "after the reconcile commits, run these jobs in THIS order, each with perform_now, each independently rescued so a post-step failure cannot make a successful reconcile look like a failed job" — is written out three times as three near-identical private methods, and the order itself exists only as the sequence of three call lines at scan_job.rb:96-98. Two things follow. (1) The rescue is per-copy, so a fourth step (or an edited third) can omit it and nothing fails: the suite was green with #intake_models' rescue deleted until scan_job_test.rb:442 was written specifically to catch that. (2) The ordering constraint — which docs/invariants/project-intake.md:53 and model-intake.md:63 both describe as changing the ANSWER, not the timing — is spread across the call sequence plus ~90 lines of per-method prose (scan_job.rb:199-221, 229-272, 280-301) with no single place a reviewer can read the order off.

**Proposed representation**

A frozen ordered constant naming the steps, plus one runner that applies the shared policy:

```ruby
# STRICTLY IN THIS ORDER — each entry's reason is below; both swaps change the ANSWER.
POST_RECONCILE_STEPS = [
  [Maker::ProjectDiscoveryJob, "project discovery"].freeze,
  [Maker::ProjectIntakeJob,    "the project-folder intake"].freeze,
  [Maker::ModelIntakeJob,      "the model catalog"].freeze
].freeze

def run_post_reconcile(user)
  POST_RECONCILE_STEPS.each do |job, label|
    job.perform_now(user_id: user.id)
  rescue StandardError => e
    Rails.logger.error("Library::ScanJob: the reconcile SUCCEEDED but #{label} failed " \
                       "for user #{user.id}: #{e.class}: #{e.message}")
  end
end
```

The existing per-step prose stays — moved to sit above its entry in the constant, so the argument for each step's position is adjacent to the position itself rather than in a method body three screens away. `#perform` ends `warn_unreadable(...)` then `run_post_reconcile(user)`. This is NOT a registry or a new type: the callees already share one interface (`perform(user_id:)`), so no branching is being hidden — the table is literally the list the invariant doc already writes in prose.

**Why simpler**

The ordering invariant gets exactly one representation instead of two (call sequence + prose), and it becomes the thing a reviewer reads first. The "perform_now, independently rescued, log 'the reconcile SUCCEEDED but X failed'" policy gets one implementation instead of three, so omitting it stops being possible — the failure mode the suite demonstrably could not see (scan_job_test.rb:434-436) becomes unrepresentable rather than test-covered. Adding or reordering a step becomes a one-line data edit whose diff shows the order changing, which is what the §14f/model-intake hazards are actually about.

**Smallest credible implementation scope**

One file, app/jobs/library/scan_job.rb: add the constant, add `run_post_reconcile`, delete the three private methods, change three call lines in `#perform` to one. Preserve every existing comment verbatim, relocated above its constant entry. Update the two prose references in docs/invariants/project-intake.md:53 and the §14f/model-intake wording if they name the removed method names. No test edits required — all three failure tests stub the SERVICE (Maker::ProjectDiscovery/ProjectIntake/ModelIntake `.for_user`) and match on log text, not on method names.

**Affected files**

- `app/jobs/library/scan_job.rb`
- `docs/invariants/project-intake.md`
- `docs/invariants/model-intake.md`

**Regression risks and migration concerns**

Three real ones, stated plainly. (1) This repo deliberately favours long prose attached to a named method; a table risks the comments drifting from their entries in a way a method body resists — mitigate by keeping each comment immediately above its own entry, not as one block header. (2) docs/invariants/project-intake.md:53 cites the three method names, and nothing in bin/ci checks that a doc's method reference still resolves (`test/docs_hygiene_test.rb` only checks stubs and the line ceiling), so a stale name would go unnoticed — update it in the same change. (3) The loop's `rescue` must stay INSIDE the block (a `rescue` around the `each` would abort the remaining steps and silently change behaviour); this is the one way to get the refactor wrong and it is invisible to a reader skimming the diff, so mutation-check it. Counter-argument I could not dismiss: the current shape's cost is only ~10 lines of code, and the repo's comments (scan_job.rb:199, 229, 280) are individually well-argued rather than accidental duplication — this is a medium-confidence recommendation, not an obvious win.

**Validation required**

Existing coverage is sufficient and already mutation-hardened: test/jobs/library/scan_job_test.rb:390 ("a project discovery failure does not fail a scan that already succeeded", asserts the log text), :421 (the intake equivalent), :442 ("a model catalog failure...", asserts the log text and that the intake's work stands), :363 ("cataloguing runs after the project intake, so a filed file is its own model", IntakeOrderTest at :277) and DiscoveryOrderTest at :559 with :626 ("the model catalog never swallows the discovered folder as one model"). Additional validation required, per §15: after the refactor is green, mutation-check twice — reorder POST_RECONCILE_STEPS and confirm DiscoveryOrderTest:626 and IntakeOrderTest:363 go RED; then move the `rescue` outside the block and confirm scan_job_test.rb:442 goes RED (the model-catalog test is the one that proves the LAST step is still independently rescued). Both legs that run this path must pass: `bin/ci test` (share) and `bin/ci test-s3`.

### Cross-subsystem concerns raised by this lane

_Named, not solved — the lane was told to stay inside its boundary._

- Maker::ProjectDiscoveryJob, Maker::ProjectIntakeJob and Maker::ModelIntakeJob (S-other) all carry a `sweep_all!`/`self.` gate that is the exact inverse of Library::ScanJob's (`return if FileLayer.current.capabilities.scannable?` at project_discovery_job.rb:48-52 vs `return unless ... .scannable?` at scan_job.rb:123-125). That inverse pairing is the mechanism preventing a second unsequenced filer on share/s3 and it is stated in four separate files' comments; nothing derives one gate from the other. Naming only — do not touch from here.
- FileLayer::Share vs FileLayer::S3 (S-FileLayer) is the source of the repeated 'which adapters have a queue-serializable target' rule that both jobs in this boundary re-derive with `adapter.is_a?(FileLayer::Share)` (scan_job.rb:131, trash_purge_job.rb:252) and that FileLayer::RemoteChangelogPullJob's comment (remote_changelog_pull_job.rb:102) explicitly copies. If that ever needs one home it belongs to the port, not to these jobs.
- TrashPurgeJob issues one `delete_object` per object (trash_purge_job.rb:163) where the S3 API offers batched `delete_objects`; the per-entry rescue semantics at :165-172 would need re-deriving for a batch call. Efficiency, not state representation, and it touches the FileLayer::S3 client contract — out of scope here.

---

## S08 — Library namespace rules (reserved names, OS clutter, repo metadata)

**Lane verdict:** `recommend`

### S08-1 — RepoMetadataPurge walks UP from every node in the table; descending DOWN from the marker rows is the shape of the population it is trying to name

> **COORDINATOR VERDICT — ACCEPT.** Verified against the tree; no narrowing applied.

- **Category:** algorithm  
- **Lane confidence:** medium

**Evidence**

- app/services/library/repo_metadata_purge.rb:118-119 — the sweep is `Node.find_each do |node| doomed << node.id if beneath_marker?(node, cache) && !keep.include?(key(node)) end`: every node row in the whole table, for every user, is instantiated and interrogated, to find the (usually tiny, often empty) set beneath a `.git`.
- app/services/library/repo_metadata_purge.rb:207-209 and 216-218 — `beneath_marker?` answers by `RepoMetadata.internal?(path_for(node, cache))`, and `path_for` is `ancestors(node, cache).reverse.map(&:name).push(node.name).join("/")`. So per node the service rebuilds a full path string upward and `internal?` then splits it on "/" again (repo_metadata.rb:94 `rel.to_s.split("/")`) — a string round-trip per row purely to re-derive an ancestry fact the `parent_node_id` edges already hold.
- app/services/library/repo_metadata_purge.rb:222-235 — `ancestors` walks `parent_node_id` under `MAX_ANCESTOR_WALK.times`, and 243-249 `lookup` issues a `Node...find_by(user_id:, node_id:)` per uncached ancestor. The `cache` hash exists only to keep that upward walk from re-querying, and it is threaded by hand through `call`/`pin_referenced`/`beneath_marker?`/`path_for`/`ancestors`/`lookup`.
- app/services/library/repo_metadata_purge.rb:72-79 — the cap's own comment concedes the walk is unsound at the boundary: "A TRUNCATED WALK IS NOT 'THE SAFE DIRECTION'... a truncated path answers whatever its own suffix says... a `false` there is not safe: it leaves a live node beneath a marker at a path no observer will ever produce, which is precisely the ghost that re-arms the guard trip this service exists to prevent." The cap is defended only by "nothing below 64 levels deep can reach either case".
- db/schema.rb:392 — `t.index ["user_id", "parent_node_id"]` already exists on `nodes`; the downward direction is the indexed one. There is no index on `name`, so the one place a name query is needed (finding the markers) is a single scan in SQL rather than N row instantiations in Ruby.
- app/services/maker/attach_to_project.rb:249 — `@user.nodes.present.exists?(parent_node_id: id, kind: "dir", name: Library::RepoMetadata::DIR_NAME)`, and app/models/node.rb:29 — `scope :outside_repo_metadata, -> { where.not(name: Library::RepoMetadata::DIR_NAME) }`. Identifying a marker by SQL equality against `RepoMetadata::DIR_NAME` is already this repo's sanctioned spelling in two other places.
- test/services/library/repo_metadata_purge_test.rb:127-138 ("a node with a NULL storage_path is resolved by its parent chain") and 145-152 ("a trash-kind tombstone beneath the marker (path released) is purged too") — both fixtures are parent-chained rows with a NULL `storage_path`, i.e. exactly the rows a downward `parent_node_id` descent reaches and a `storage_path` query would not.

**Current complexity / invalid states**

Three coupled mechanisms exist to answer one question — "is this row inside a repo's metadata directory?" — from the wrong end. A full-table `find_each`, a per-node upward `parent_node_id` walk, and a hand-threaded ancestor cache together reconstruct a path string for every node in the database so that a path predicate can be asked about it. The cache is only needed because the walk is per-node; `MAX_ANCESTOR_WALK` is only needed because an upward walk on an FK-less string column can cycle; and the cap in turn creates a documented unsound answer (repo_metadata_purge.rb:72-79) that the file has to argue is unreachable. `path_for` also joins segments that `RepoMetadata.internal?` immediately splits apart again.

**Proposed representation**

Represent the doomed population as a subtree, not as a path predicate: find the markers once (`Node.where(name: RepoMetadata::DIR_NAME, kind: "dir")`, grouped by `user_id`), then breadth-first descend `parent_node_id` from each marker's children using the existing `[user_id, parent_node_id]` index, sliced like `DESTROY_BATCH` already slices destroys, carrying a `seen` Set of node_ids and a `parent_of` map built as you descend. The doomed set is everything the descent reaches; the marker itself survives because the descent starts at its children; outermost-wins holds because an inner `.git` is simply a descendant of the outer one; `.gitignore` / `notes/git/` survive because the marker is matched by whole-name SQL equality. `pin_referenced` becomes: intersect `referenced` with the doomed set, then walk the in-memory `parent_of` map upward to pin ancestors — no DB, no cap. `cache`, `lookup`, `ancestors`, `path_for`, `beneath_marker?` and `MAX_ANCESTOR_WALK` all go away.

**Why simpler**

It deletes five private methods, a hand-threaded mutable cache, and a magic cap together with the eight-line comment arguing the cap is not unsafe — because the descent has no truncation and no cycle hazard (a `seen` Set terminates exactly, rather than guessing a depth). It also removes the string round-trip: nothing needs to build or re-split a path to learn an ancestry fact the edges already encode. It is the more appropriate collection for the job — the population is a subtree, and the table already has the index for traversing subtrees. Two properties the current design maintains only by argument become structural: the marker surviving (you never enqueue it) and the cache being per-call (there is no cache).

I want to be explicit that the file argues AGAINST this, and say why I still think it is worth raising rather than dropping. repo_metadata_purge.rb:58-65 says "it asks Library::RepoMetadata.internal?, rather than testing an ancestor's name here... A local `name == DIR_NAME` comparison would be a third spelling of one question, free to drift from the two that already agree by construction." That argument is weaker than it reads, for a checkable reason: the spelling it forbids is already in the tree twice, against the same constant the module owns — `app/models/node.rb:29` and `app/services/maker/attach_to_project.rb:249`, the latter also adding the `kind: "dir"` check that repo_metadata.rb:38-42 says is part of the rule and that the path-based purge cannot make at all. So a descent would be the THIRD use of an established spelling, not a new one. The header's other claim — that asking `internal?` inherits whole-segment, outermost-wins and marker-survives "for nothing" — is true, but a descent gets all three structurally rather than by delegation. If the reviewer weighs the header's single-predicate argument above this, the honest fallback is to keep `internal?` and only replace the driver (find markers, descend, and ask `internal?` of the descent's own accumulated relative path), which still retires the cache, the cap and `find_each`.

**Smallest credible implementation scope**

One file. Rewrite `RepoMetadataPurge.call`'s decision pass plus `pin_referenced`; delete `beneath_marker?`, `path_for`, `ancestors`, `lookup`, `key`, `cache` and `MAX_ANCESTOR_WALK`. `decline_reason`, `referenced`, `DESTROY_BATCH`, the destroy slicing and `Result` are untouched. Roughly 60-70 lines removed, ~30 added. No schema change, no migration change (the migration only calls `.call` and reads `declined`/`reason`/`destroyed`/`skipped`).

**Affected files**

- `app/services/library/repo_metadata_purge.rb`
- `test/services/library/repo_metadata_purge_test.rb`

**Regression risks and migration concerns**

The behaviour must stay identical on the shapes the suite already pins, and all of them are parent-chained, so they should: NULL `storage_path` rows (test:127-138), trash-kind tombstones with a released path (test:145-152), the renamed-marker second run (test:272-286 — a descent re-reads markers every call, so it is naturally immune to the stale-memo bug that test exists for), `.gitignore`/`.github` negatives (test:104-110), pinned attachments and covers plus their kept ancestors (test:72-101, 242-256). Two things to get right in review: tombstoned rows must NOT be filtered out of the descent (do not reach for `.present`, which would leave exactly the rows test:145-152 pins), and the `parent_node_id` IN-lists must be sliced the way destroys already are so a wide repo does not build an unbounded bind list. One genuine behaviour delta to decide deliberately: a `.git` FILE node (the submodule/linked-worktree `gitdir:` pointer repo_metadata.rb:38-42 says is not a marker) would be excluded by `kind: "dir"` in a descent, where the path-based version ignores kind entirely — in practice unreachable, since a file node has no children, but it should be stated rather than discovered.

**Validation required**

The existing suite is a strong harness and should pass unchanged — do not weaken it. Add one test the current design cannot pass: a chain deeper than `MAX_ANCESTOR_WALK` beneath a marker (65+ nested directories, one file at the bottom) must be destroyed; today `ancestors` truncates and the file survives as the very ghost the service exists to prevent, per the comment at :72-79. Mutation-check the descent per §15 by making the marker query name something other than `RepoMetadata::DIR_NAME` and confirming test:56-70 goes red, and by starting the descent AT the marker instead of its children and confirming the "MARKER itself survives" assertion goes red. Also re-run test:279-295 (the end-to-end scan-does-not-trip-the-guard case), which is the only test that drives the real Scanner.

### S08-2 — Result's `declined` boolean is exactly `reason.present?`, so the type permits two meaningless states and a test exists only to police the pairing

> **COORDINATOR VERDICT — ACCEPT.** Verified against the tree; no narrowing applied.

- **Category:** state-representation  
- **Lane confidence:** medium

**Evidence**

- app/services/library/repo_metadata_purge.rb:99 — `Result = Data.define(:destroyed, :skipped, :declined, :reason)`. Both members describe the same fact.
- app/services/library/repo_metadata_purge.rb:103 — the only decline construction, `Result.new(destroyed: 0, skipped: [], declined: true, reason: refusal)` (reached only when `refusal` is non-nil, line 102), and :123 — the only success construction, `Result.new(destroyed: doomed.size, skipped:, declined: false, reason: nil)`. The two members are set in lockstep at both of the two construction sites; `declined: true, reason: nil` and `declined: false, reason: "..."` are constructible and mean nothing.
- app/services/library/repo_metadata_purge.rb:90-98 — the invariant is maintained in prose rather than by the type: "Both are `declined: true, destroyed: 0`... nil on a run that did the work, so a report of real work cannot carry a decline sentence beside it."
- test/services/library/repo_metadata_purge_test.rb:230-240 — a whole test, "a run that actually did the work reports no decline reason", whose stated purpose is that "`reason` could be populated unconditionally and the two tests above would still pass"; it asserts `assert_not result.declined` AND `assert_nil result.reason` back to back. The test exists because the two fields can disagree.
- db/migrate/20260826120000_purge_repo_metadata_nodes.rb:31 and :47 — the only production consumer branches on `if result.declined` and then immediately prints `result.reason`, i.e. it reads both members to get one fact.

**Current complexity / invalid states**

A four-member result type carries a boolean and a nullable string that are definitionally the same signal. Nothing enforces the pairing; a comment asserts it and a dedicated test checks it. The one real caller has to read both members to act on one decision.

**Proposed representation**

Drop `declined` and make `reason` the discriminator: `Result = Data.define(:destroyed, :skipped, :reason)`, with `def declined? = !reason.nil?` on the Data class so call sites keep reading as prose. `call` then returns `Result.new(destroyed: 0, skipped: [], reason: refusal)` or `Result.new(destroyed: doomed.size, skipped:, reason: nil)`, and the migration reads `if result.declined?` / `say "declined: #{result.reason}"` unchanged in shape.

**Why simpler**

The contradictory states stop being representable, so the prose invariant at :90-98 and the test at :230-240 that exists to police it both become unnecessary — the test can narrow to what it actually cares about (that a working run's `reason` is nil, which is now the same statement as "not declined"). It also preserves the rule the header cares most about, that `reason` carries the sentence and the caller never composes its own: with `reason` as the only decline signal, a caller literally cannot report a decline without printing the service's own words. This is a small change and I am not claiming otherwise; it earns its place because the redundancy currently costs a comment paragraph and a test rather than nothing.

**Smallest credible implementation scope**

One member removed from the Data definition, two constructor calls updated, one derived predicate added — all inside repo_metadata_purge.rb. Migration line 31 becomes `result.declined?`. Four test assertions (`result.declined` at test:181, 210, 238 and the migration test if it reads it) become `result.declined?`.

**Affected files**

- `app/services/library/repo_metadata_purge.rb`
- `db/migrate/20260826120000_purge_repo_metadata_nodes.rb`
- `test/services/library/repo_metadata_purge_test.rb`

**Regression risks and migration concerns**

Low, and the surface is fully enumerated by grep — `declined` appears only in the service, the migration and the purge test. The one thing not to lose: `declined?` must be derived from `reason`, not reintroduced as a stored member, or the change is purely cosmetic. Also keep the two decline sentences distinguishable (test:222-231 pins that) — nothing here touches their wording.

**Validation required**

test/services/library/repo_metadata_purge_test.rb must stay green with only the `declined` → `declined?` rename, in particular test:174-186 (chunk_remote declines, mirror rows survive), test:199-212 (unconfigured backend declines rather than raising) and test:222-231 (the two reasons read differently). Mutation-check per §15 by making `decline_reason` return a non-nil sentence on a scannable backend and confirming the survival assertions at test:180-186 go red — the same mutation the current `declined` flag is checked with. test/models/library/purge_repo_metadata_nodes_migration_test.rb exercises the migration's own branch and must be re-run.

### Cross-subsystem concerns raised by this lane

_Named, not solved — the lane was told to stay inside its boundary._

- FileLayer::Share#observable! (app/services/file_layer/share.rb:667-670) and FileLayer::S3#observable! (app/services/file_layer/s3.rb:1051-1053) each spell the same reserved-namespace disjunction that Library::ReservedNames.reserved? spells at the doors (reserved_names.rb:84-87). The STRINGS are correctly shared via Scanner::TRASH_PREFIX/TEMP_PREFIX/OsClutter/RepoMetadata, exactly as 14b requires, but the branch STRUCTURE now exists in three places and differs between them only in the TEMP_PREFIX arm (deliberately absent on S3, s3.rb:1027-1029 and 1038-1039). Whether a path-level predicate should live in Library:: alongside the leaf-level one belongs to the FileLayer adapters subsystem, not here. Naming it, not solving it.
- ReservedNames.reserved? refuses `.trash` as a minted LEAF at any depth (reserved_names.rb:84, `name == Scanner::TRASH_PREFIX`), while both adapters' observable! anchor `.trash` to the library ROOT (share.rb:667 `segments.first == TRASH_PREFIX`; s3.rb:1051 same) and the Scanner's own skip is root-anchored. So a user creating a folder literally named `.trash` inside `cad/` is refused at the web doors but would be perfectly observable on every backend. It is a strictly-safe over-refusal and arguably intended by the union rule, but it is not the union of what the adapters refuse, which is how the header (reserved_names.rb:25-38) describes itself. Worth a deliberate decision by whoever owns the doors; I am not proposing a change.
- app/models/node.rb:29's `outside_repo_metadata` hides the marker by name only and, as its own comment at node.rb:20-28 records, does not hide `.git` descendants on chunk_remote where the mirror carries them. That limitation is already recorded and consciously deferred; it is a Node/FilesController concern, not a namespace-rules one.

---

## S09 — Node catalog model + change broadcast

**Lane verdict:** `recommend`

### S09-1 — The ActionCable server surface is a vestige of the extracted sync engine: no channels, no broadcasters, no subscribers — and the one door left authenticates with the wrong credential

> **COORDINATOR VERDICT — ACCEPT.** Verified against the tree; no narrowing applied.

> **Schema gap in this entry:** Names `db/cable_migrate`, which does not exist. Omits the two files that actually wire Solid Cable: config/cable.yml and db/cable_schema.rb.

- **Category:** ownership  
- **Lane confidence:** high

**Evidence**

- app/channels/application_cable/connection.rb:6 — `device = Device.authenticate(request.params[:token])`; the cable connection identifies by a per-device token in the query string, the sync daemon's credential, not the web layer's cookie session (§14d: the web app is cookies, /v1 is Bearer).
- app/channels/application_cable/channel.rb:2 — `class Channel < ActionCable::Channel::Base`; `find app/channels -type f` returns exactly these two files, so there is no channel class in the repo at all. The engine's `app/channels/sync/library_channel.rb` left with the extraction (test/architecture_invariants_test.rb:361-374 narrates narrowing the guard glob to `app/channels/sync/**` and reclassifying these two files as host boilerplate).
- config/routes.rb:372-373 — `# ActionCable mount (change notifications)` / `mount ActionCable.server => "/cable"`; the endpoint is still mounted for notifications this app no longer sends.
- app/services/file_layer/chunk_remote.rb:344-347 — "`broadcast:` IS ACCEPTED AND UNUSED ... the SERVER broadcasts to the devices attached to it when the commit lands, and this app is one of those devices rather than the thing doing the notifying." Confirmed by grep: zero `ActionCable.server.broadcast` / `broadcast_to` / `broadcast_replace` in app/ or lib/, and zero `turbo_stream_from` in app/ (turbo-rails is installed, so Turbo::StreamsChannel exists but nothing subscribes).
- app/services/library_broadcast.rb:49-53 — the maker layer's only "broadcast" door now resolves to `FileLayer::ChunkRemote#batch` or a bare `yield`; neither touches ActionCable.
- config/environments/production.rb:80-84 and config/environments/development.rb:70-74 — `config.action_cable.disable_request_forgery_protection = true`, justified in both files by "native clients (the sync daemon)" connecting here; devices sync against tinkerex-sync now (CLAUDE.md §3), so the justification no longer describes this app.
- docs/DEPLOY.md:705-706 — "The ActionCable nudge is unaffected either way: it works because request-forgery protection is disabled (token-authed cable, not cookies)" — operator documentation asserting a live feature this repo cannot perform.

**Current complexity / invalid states**

Cable is a five-place surface with zero behavior: two channel classes, a routed /cable mount, a forgery-protection knob in two environments, a `cable` database role plus solid_cable and its own migrations/volume, and prose in DEPLOY.md and CLAUDE.md §4 asserting it works. The one class with logic, ApplicationCable::Connection, encodes an auth model (device token in the query string) that belonged to the extracted Sync::LibraryChannel. Anyone reading the app today has to reconstruct from four repos-worth of history that (a) nothing broadcasts, (b) nothing subscribes, and (c) the door that is open would reject the only plausible future user — a Turbo Stream from a cookie-authed browser sends no `?token`, so `reject_unauthorized_connection` fires and the stream silently never connects (the Stimulus-no-op failure mode §14d already records).

**Proposed representation**

State the fact structurally instead of leaving it to be re-derived: this app is not a broadcaster. Remove the cable *server* surface — `app/channels/application_cable/**`, the `mount ActionCable.server => "/cable"` line, and the two `disable_request_forgery_protection` knobs whose stated reason has moved to another repo. Then decide, separately and explicitly, on the infrastructure that only existed to feed it: the `cable` role in config/database.yml, the solid_cable gem, db/cable_migrate, and the DEPLOY.md/CLAUDE.md §4 sentences that claim a working nudge. If cable is to be kept for future Turbo Streams, keep it as an empty *cookie-session* connection (`verified_user` from the warden/session, matching §14d) — but do not leave a device-token door standing for a channel that no longer exists.

**Why simpler**

It deletes a whole subsystem rather than reorganizing one: one fewer routed endpoint, one fewer authentication mechanism in a codebase whose security story is deliberately two mechanisms (cookies for web, device token for /v1, §8/§14d), one fewer production config exception, and one fewer database role in a file that already carries a long comment explaining the four Solid stores. It also removes a documented claim that is false, which is exactly the failure mode CLAUDE.md §15 ("a stale open-list is worse than none"; "verify a commit reference the way you verify a guard") keeps paying for. This is the same move the repo already made for ActiveStorage direct uploads (§15) and `variant_processor = :disabled` (§14e): remove the code path structurally rather than leaving it merely unreachable by argument.

**Smallest credible implementation scope**

Small in this repo, deploy-facing beyond it. Code: delete two files, one route line, two env lines. Docs: DEPLOY.md:705-706 and CLAUDE.md §4's "all three wired" claim must move in the same branch (§15's close-out rule). Infrastructure (separable second step, operator's call): the `cable` entry in config/database.yml:112-115 and :128-131, solid_cable in Gemfile:52, db/cable_migrate, and whatever volume the cable SQLite file sits on.

**Affected files**

- `app/channels/application_cable/connection.rb`
- `app/channels/application_cable/channel.rb`
- `config/routes.rb`
- `config/environments/production.rb`
- `config/environments/development.rb`
- `config/database.yml`
- `Gemfile`
- `docs/DEPLOY.md`
- `CLAUDE.md`

**Regression risks and migration concerns**

(1) `rails/all` + turbo-rails keep ActionCable loaded; with the connection class gone, a future `turbo_stream_from` fails at connect with a NameError rather than working. That is loud rather than silent, but it must be a known consequence, not a surprise — hence the "keep an empty cookie-session connection" alternative. (2) Dropping the `cable` database is irreversible on a live box and touches Kamal volumes and database.yml's derive logic; do it as a separate step after the code removal, or not at all. (3) CLAUDE.md §4 asserts Solid Cable is wired — the audit trail must be corrected in the same branch or the next reader re-adds it. (4) The sibling repo `tinkerex-sync` genuinely does broadcast; do not let this change leak into an assumption about that repo (§14j).

**Validation required**

Before: `grep -rn 'ActionCable.server.broadcast|broadcast_to|turbo_stream_from' app lib` returns nothing and `find app/channels -type f` returns two files — assert the scanned set is non-empty first, per §14e's "a guard that scans a directory dies silently when the directory leaves". After: drive a real request (§14e/§15 — probe, don't reason) — a websocket upgrade to /cable must 404, and `Rails.application.routes.recognize_path('/cable')` is the wrong instrument for a mounted engine, so use the request. Full `bin/ci` including all three backend legs with identical run counts; boot must be clean in dev, test and production config (the cable knob removal touches two environment files). Mutation-check any new guard by re-adding an `app/channels/foo.rb` and confirming it goes red.

### S09-2 — "A folder's children" has four definitions — the one on Node has zero callers, and the three live ones disagree about which entries are visible

> **COORDINATOR VERDICT — ACCEPT (description corrected).** Conclusion holds — Node#children (node.rb:63-65) has no caller. But my "single grep hit" description was wrong: a repo-wide search returns 25, of which 23 are Dir.children, one is a JS DOM hit, and one (test/models/maker/location_test.rb:19) is a live caller of Maker::Location's OWN has_many :children — a different model.

- **Category:** ownership  
- **Lane confidence:** medium

**Evidence**

- app/models/node.rb:63-65 — `def children; user.nodes.present.where(parent_node_id: node_id); end`. Zero callers: grep for `children` across app/, lib/, bin/ and test/ (excluding `Dir.children`) finds only `Maker::Location`'s own `has_many :children` and a *comment* at app/controllers/files_controller.rb:149 that names `Node#children` as if it were the definition the controller follows.
- app/controllers/files_controller.rb:202-204 — `scope = current_user.nodes.present.where(parent_node_id: @folder&.node_id).visible_entries(@show_hidden)`, with a comment two lines up insisting the filter go on the `scope =` assignment so `@child_count` paginates what is actually shown (§14b).
- app/controllers/library_browse_controller.rb:13-15 — `scope = current_user.nodes.present.where(parent_node_id: parent&.node_id)`, then `where(kind: "dir")` unless `files=1`, then sorted in Ruby. No `visible_entries`, no `outside_repo_metadata` — so the folder chooser lists `.git` and every dot-directory that the Files page hides.
- app/javascript/lib/file_chooser.js:159-161 — `visible(entries)` filters only by extension (`if (!this.extensions) return entries`), so nothing on the client compensates for the missing server-side filter.
- app/controllers/models_controller.rb:210-216 — a third spelling, BFS: `kids = current_user.nodes.present.where(parent_node_id: frontier).to_a` with `frontier` an ARRAY of node_ids; also no visibility filter.
- app/models/node.rb:29 and :55-57 — `outside_repo_metadata` and `visible_entries(show_hidden)` live on Node and carry the whole `.git`/dot-entry argument, including "LIKE, NOT A RUBY FILTER, because #index counts with `.count` on this same scope before it loads rows". The vocabulary is model-owned; the traversal it applies to is not.

**Current complexity / invalid states**

Node owns the visibility vocabulary but not the traversal, so each caller re-derives the same three facts: children are keyed by the `node_id` STRING rather than the integer PK (re-explained at files_controller.rb:148-149), tombstones must be excluded via `present`, and *maybe* the display filters apply. Two of the three live callers omit the display filters, and nothing marks that as a decision rather than an oversight — the chooser and the Files page answer the same question ("what is in this folder?") two different ways, which is the one-condition-two-answers shape §14a keeps recording as a defect. Meanwhile the model's own attempt at the definition is unreferenced, so it can drift from all three without any gate noticing.

**Proposed representation**

Put the traversal on Node beside the vocabulary that already lives there — `scope :children_of, ->(parent_node_id) { present.where(parent_node_id:) }` (accepting an id or an array, which `where` already does, so ModelsController's BFS frontier keeps working) — and have `#children` either delegate to it or be deleted. Each caller then composes visibility explicitly: `Node.children_of(id).visible_entries(show_hidden)` on the display doors, a bare `children_of` where the raw tree is wanted (the BFS in ModelsController genuinely wants every row). The value is that "this caller does not hide dot-entries" becomes a visible omission at the call site instead of an absent line.

**Why simpler**

One definition of the catalog's parent/child edge instead of four, in the model that already owns `present`, `outside_repo_metadata` and `visible_entries` — and the divergence between the Files page and the folder chooser becomes a one-line, reviewable choice rather than something you find by reading three controllers side by side. It removes a dead method that currently reads like the authority (a controller comment cites it as such) while being wired to nothing.

**Smallest credible implementation scope**

Small: one scope added and one method removed or repointed in app/models/node.rb; three call sites rewritten mechanically. Deliberately NOT bundled: whether the chooser and the model tree should start hiding dot-entries is a product decision with its own test changes (test/integration/web/library_browse_test.rb seeds no dot-entries today, so unifying the filter would need new cases before it is safe to claim either behavior).

**Affected files**

- `app/models/node.rb`
- `app/controllers/files_controller.rb`
- `app/controllers/library_browse_controller.rb`
- `app/controllers/models_controller.rb`

**Regression risks and migration concerns**

(1) The temptation the change creates is to "fix" the divergence in the same commit by making every caller visible_entries — that would silently remove dot-folders from the addon/save-into chooser and from the model file tree, a user-visible behavior change that must be decided and tested on its own. (2) `children_of` must keep accepting an array (ModelsController's BFS depends on it) — a signature narrowed to a single id turns a one-query-per-depth walk into one per node. (3) Node has no unit test file at all (test/models/ contains no node_test.rb; the scopes are pinned indirectly by test/integration/web/files_git_marker_test.rb), so the new scope needs its own coverage rather than inheriting any.

**Validation required**

Add test/models/node_test.rb covering `children_of` with a single id and an array, and asserting it excludes tombstones; mutation-check it by dropping `present` and confirming red (§15). Re-run the existing indirect pins — test/integration/web/files_git_marker_test.rb, folder_nav_test.rb, library_browse_test.rb, and test/integration/web/page_query_budget_test.rb (query counts must stay constant in N, and the BFS rewrite is the one that could change them). Full `bin/ci`, all three backend legs, identical run counts.

### Cross-subsystem concerns raised by this lane

_Named, not solved — the lane was told to stay inside its boundary._

- The folder chooser (LibraryBrowseController#children -> lib/file_chooser.js) shows `.git` and dot-prefixed directories that the Files page hides, because it applies neither `outside_repo_metadata` nor `visible_entries`. Named, not solved — it is a product decision about what the chooser should offer, and it lives in the controller/JS subsystem.
- docs/DEPLOY.md:705-706 and CLAUDE.md §4 both describe a working ActionCable nudge served by this app; devices attach to the sync server now (CLAUDE.md §3). Documentation correction, outside this subsystem's files.
- config/environments/{production,development}.rb disable ActionCable request-forgery protection on the stated grounds that "the sync daemon" connects here with a device token. That justification belongs to the extracted repo; the knob is a config-subsystem concern.
- FileLayer::ChunkRemote#finalize_upload accepts a `broadcast:` kwarg it documents as unused (chunk_remote.rb:344-348) while §14a still describes it as "broadcasts by DEFAULT, with exactly one explicit opt-out". The kwarg's contract and the invariant text no longer match; that is the FileLayer subsystem's to reconcile.

---

## S10 — Preview orchestration & lifecycle

**Lane verdict:** `recommend`

### S10-1 — Give the (version_id, renderer_revision) staleness stamp ONE representation — it currently has five spellings, one of them hand-maintained by comment

> **COORDINATOR VERDICT — NARROWED.** The drift is ALREADY REPAIRED (missing_backfill.rb:85-90 now plucks all three columns). What remains is drift-proneness across four spellings, not a live defect. Confidence and rank lowered.

- **Category:** state-representation  
- **Lane confidence:** high

**Evidence**

- app/services/maker/previews/enqueue.rb:216-217 — `current_preview?` spells the pair as Ruby: `preview.version_id == version_id && preview.renderer_revision == revision_for_name(name, preview.kind)`. This is the canonical definition and ThumbnailMap already uses it.
- app/services/maker/previews/enqueue.rb:191-192 — `current_preview` re-spells the same pair as SQL: `find_by(node_id:, kind:, version_id:, renderer_revision: revision_for_name(name, kind))`.
- app/jobs/maker/generate_preview_job.rb:87 — `target = [ preview.version_id, preview.renderer_revision ]`, an anonymous positional 2-array, compared 84 lines later at app/jobs/maker/generate_preview_job.rb:171 — `return if [ preview.version_id, preview.renderer_revision ] != target`. Positional order is the only thing keeping the two literals in agreement.
- app/services/maker/previews/missing_backfill.rb:89-90 — `seen = user.maker_previews.where(kind: KIND, node_id: ids).pluck(:node_id, :version_id, :renderer_revision).to_set`, tested at app/services/maker/previews/missing_backfill.rb:109 — `next if seen.include?([ node.node_id, token, revision ])`. A fourth spelling, as a tuple Set.
- app/services/maker/previews/missing_backfill.rb:10-22 — the file's own comment concedes the cost: "Keeping the triple in step by hand is the price of that; if a FOURTH coordinate is ever added to `current_preview?`, it must be added here too", and records that it WAS the pair (node_id, version_id) until 2026-08-07, so the sweep reported "Enqueued 0" while every STL/3MF thumbnail in the library was stale.
- app/services/maker/previews/thumbnail_map.rb:104-113 — `previews_for` answers the identical batch question (which of these nodes already have a current row?) by loading the rows and calling the shared predicate, still one query: `.where(kind: "thumbnail", node_id: info.keys).select { |p| Enqueue.current_preview?(p, name: fi&.name, version_id: fi&.content_token) }.index_by(&:node_id)`. The precedent for the fix already exists inside this subsystem.

**Current complexity / invalid states**

"Which stamp was this artifact built under, and is it the current one?" is the single most load-bearing question in the subsystem (docs/invariants/measure-view.md:223-231: two independent staleness axes, and only the first existed once, which shipped mangled Measure payloads). It is written four different ways: a Ruby predicate, a SQL find_by, an anonymous positional 2-array in the job, and a plucked 3-tuple Set in the sweep. Only the first two share code. The tuple-Set copy has ALREADY drifted once and produced the exact failure the mechanism exists to prevent, and its comment now asks a future editor to remember to update it by hand. The job's array copy is unguarded in a different way: nothing structurally couples the element order at line 87 to the element order at line 171, and a mismatch would make commit_if_current either never write or always write — both silent.

**Proposed representation**

One value object for the pair — `Maker::Previews::Stamp = Data.define(:version_id, :renderer_revision)` — plus `Maker::Preview#stamp` and `Enqueue.stamp_for(name:, version_id:, kind:)`. Then: (a) `current_preview?` keeps its two blank guards and becomes `preview.stamp == stamp_for(...)`; `current_preview` passes `**stamp_for(...).to_h` to `find_by`; (b) `GeneratePreviewJob` captures `target = preview.stamp` and `commit_if_current` compares `preview.stamp != target` — both axes by construction, no positional literal; (c) `MissingBackfill` drops the pluck/Set entirely and adopts ThumbnailMap's shape: `rows = user.maker_previews.where(kind: KIND, node_id: ids).index_by(&:node_id)` then `existing = rows[node.node_id]; next if existing && Enqueue.current_preview?(existing, name: node.name, version_id: token)`. Still exactly one query per batch. The node_id member of the old triple becomes the index key, where it belongs.

**Why simpler**

The number of places that know the stamp's shape drops from five to one, and the one that a comment currently asks a human to keep in step disappears rather than being documented. A fourth coordinate could then be added in `Stamp` alone. It also removes a whole class of silent defect by construction: you cannot compare one axis by accident (the job's array), and you cannot compare a stale definition (the sweep's tuple), which are the two recorded bug shapes here — the 172-of-174 LightBurn thumbnails (thumbnail_map.rb:79-88) and the sweep's "Enqueued 0" (missing_backfill.rb:16-22). It removes code rather than adding a layer: MissingBackfill loses the pluck, the Set, and its own `revision = Enqueue.revision_for(renderer, KIND)` line.

**Smallest credible implementation scope**

Smallest credible slice is MissingBackfill alone: replace the pluck/Set with an index of rows and call `Enqueue.current_preview?` — ~6 lines changed in one file, no new type, and it is the copy that has already drifted. The `Stamp` Data object and the job's `target` are a second, optional step; do them only if the first lands cleanly.

**Affected files**

- `app/services/maker/previews/missing_backfill.rb`
- `app/services/maker/previews/enqueue.rb`
- `app/jobs/maker/generate_preview_job.rb`
- `app/models/maker/preview.rb`

**Regression risks and migration concerns**

Do NOT collapse `content_moved` and `rebuilt` in `Enqueue.call` (enqueue.rb:91-92) into a single stamp comparison — they must stay separate booleans because they drive DIFFERENT writes: enqueue.rb:115 blanks `status` to "pending" on a content move only, and enqueue.rb:102-114 explains why a renderer bump deliberately keeps serving the old artifact. A stamp equality test there would fuse two answers into one and re-ship the "generating preview is broken" regression named in that comment. `commit_if_current` must keep comparing BOTH members (job:159-176 argues every terminal write goes through it). Memory: MissingBackfill would instantiate up to BATCH=500 Preview rows per batch instead of 3-column tuples — small rows, no query-count change, but worth confirming on a large library. Minor: `current_preview?` re-resolves the Registry via `revision_for_name`, so a renderable node costs one extra frozen-hash lookup per node in the sweep.

**Validation required**

Existing: test/services/maker/previews/missing_backfill_test.rb — especially "what the sweep considers covered is exactly what Enqueue would not re-enqueue" (line 122), "a second run after a revision bump enqueues nothing", "a non-renderable file is never counted, however many times the sweep runs", and the dry-run/real-run agreement test; test/services/maker/previews/enqueue_test.rb (the four-axis tests, incl. lines 118-133 two_kinds and 150-151 BASE_REVISION fallback); test/services/maker/previews/thumbnail_map_test.rb (lines 194-253, both staleness axes); test/jobs/maker/generate_preview_job_test.rb:76 (mid-flight supersede). Additional required: mutation-check per CLAUDE.md §15 — drop the revision member from `Stamp` (or from the sweep's currency test) and confirm missing_backfill_test's revision tests AND generate_preview_job_test both go red; the missing_backfill_test comment at line 105-112 states the seen-key collapse currently reddens, so that mutation must keep reddening. Also add the test that does not exist today: generate_preview_job_test.rb:82 moves only `version_id` mid-flight, so the SECOND axis of `commit_if_current` is unasserted — add a mid-flight `renderer_revision` move before changing that comparison.

### S10-2 — Declare the renderer contract once instead of discovering it by runtime reflection at every call site

> **COORDINATOR VERDICT — NARROWED.** Undoes three in-file arguments (generate_preview_job.rb:186-209, mage.rb:60, lbrn2.rb:140). Keep ONLY the real hazard: render_with's `%i[key keyreq]` filter silently drops `**opts` renderers. Drop the defaults module.

> **Schema gap in this entry:** `category` field absent.

- **Category:** _(not recorded)_  
- **Lane confidence:** medium

**Evidence**

- app/jobs/maker/generate_preview_job.rb:203-209 — `render_with` inspects the callee on every job run: `accepted = renderer.method(:render).parameters.select { |t, _| %i[key keyreq].include?(t) }.map(&:last)`, then adds `:ext`/`:kind` only if the signature declares them.
- test/services/maker/previews/renderer_contract_test.rb:79-84 — the identical reflection, copied verbatim into the test that exists to pin the contract; and it passes only `size:`/`ext:`, never `kind:`, so the kind arm of `render` is never exercised by the contract backstop.
- app/jobs/maker/generate_preview_job.rb:191-195 — a second optional protocol resolved by `respond_to?`: `return renderer.available_for?(kind) if renderer.respond_to?(:available_for?)` else `renderer.available?`.
- app/services/maker/previews/enqueue.rb:137-141 — a third: `return BASE_REVISION unless renderer.respond_to?(:payload_revision)`, then `renderer.payload_revision(kind) || BASE_REVISION`.
- app/services/maker/previews/stl.rb:54 — `def render(stl_bytes, size: 512, kind: "thumbnail", ext: nil) # rubocop:disable Lint/UnusedMethodArgument` — a renderer already carrying the union signature with args it ignores, i.e. the uniform signature is partly adopted and tolerated already. Four distinct `render` signatures exist across the eleven registered renderers: svg.rb:42 `(size:, kind:)`, three_mf.rb:47 `(size:)`, mesh.rb:64 `(size:, kind:, ext:)`, pdf.rb:32 `(size:)`.

**Current complexity / invalid states**

The registry's published contract is `available?`/`render`/`EXTENSIONS` (registry.rb:3-10), but the orchestrator actually depends on three MORE optional protocols and on the arity of `render` itself, each discovered at call time. A renderer whose `render` took `**opts` would satisfy every existing test and silently receive neither `ext:` nor `kind:` — `keyrest` is not in the `%i[key keyreq]` filter — which for Mesh means the `.step`/`.iges` loader selection is lost, and for Lbrn2/Svg/Dxf means every geometry request quietly renders a thumbnail instead. The reflection is also duplicated into the contract test, so the test adapts to whatever the renderer declares rather than asserting what the job will actually send, and it never sends `kind:` at all.

**Proposed representation**

A `Maker::Previews::Renderer` module the eleven renderers `extend`, supplying the defaults the job currently reconstructs: `payload_revision(_kind) = BASE_REVISION` and `available_for?(kind) = available?`, and declaring one signature `render(bytes, size:, kind: "thumbnail", ext: nil)`. `GeneratePreviewJob#render_with` then becomes a direct `renderer.render(bytes, size: 512, kind:, ext:)`, `#available_for?` becomes a direct call, and `Enqueue.revision_for` becomes `renderer.payload_revision(kind) || BASE_REVISION`. The contract test asserts the signature instead of adapting to it, and can drive `kind:` for the renderers that claim more than a thumbnail.

**Why simpler**

One declared interface replaces three optional protocols plus signature introspection, and the same interface stops being spelled twice (job and contract test). The silent-drop hazard is removed structurally rather than by everyone remembering the filter, which is the shape CLAUDE.md §15 calls the dominant failure mode here. It also makes `available_for?`'s absence in Lbrn2/Mage explicit as an inherited default rather than an implicit fallthrough.

**Smallest credible implementation scope**

Smallest credible slice: add the module with the two defaults and have the renderers that currently omit `payload_revision`/`available_for?` extend it, then delete both `respond_to?` fallbacks. Normalising the `render` signature (and deleting the two reflection copies) is a second slice; it can be done renderer-by-renderer since the reflection tolerates both shapes during the transition.

**Affected files**

- `app/jobs/maker/generate_preview_job.rb`
- `app/services/maker/previews/enqueue.rb`
- `app/services/maker/previews/registry.rb`
- `test/services/maker/previews/renderer_contract_test.rb`

**Regression risks and migration concerns**

Honest blast radius: the second slice touches all eleven renderer modules, which are S11/S12 and which this audit was told not to make the subject. Two renderers argue in comments for the CURRENT shape — mage.rb:60-63 ("NO `available_for?` HERE ... the absence is the point") and lbrn2.rb:140-143 ("a method that cannot answer differently from the one it wraps is a second place to keep in step for no gain") — a defaults module preserves exactly that behaviour and keeps both comments true, but each file must be re-read rather than bulk-edited. The line-count win is modest (~15 lines); the real win is the removed failure mode and the removed second copy in the test. Also: making every renderer accept `kind:` means one could silently ignore a kind it cannot produce — keep Mesh's explicit refusal (mesh.rb:64-68 raises `GeneratePreviewJob::Unsupported` for `model_glb`) as the pattern, do not let a default swallow it. Do not derive per-kind capability from `payload_revision`: FilesController's own comment (files_controller.rb:1168-1173) already records that every renderer answers it via the fallback, so it does not answer "which kinds does this produce?".

**Validation required**

Existing: test/services/maker/previews/renderer_contract_test.rb (the structural interface test and the fixture render test), test/jobs/maker/generate_preview_job_test.rb:409 ("a renderer that refuses a kind lands in unsupported, not failed"), test/services/maker/previews/enqueue_test.rb:118-133 and :150-151 (per-kind revisions and the BASE_REVISION fallback), test/integration/web/lbrn_geometry_test.rb and test/system/measure_formats_test.rb (the `available_for?` geometry-without-rasterizer path). Additional required: extend the contract test to drive `render(..., kind:)` for every renderer that declares more than a thumbnail — that arm is uncovered today; and mutation-check each default by removing a renderer's own `payload_revision`/`available_for?` and confirming the inherited default gives the identical answer before deleting anything.

### Cross-subsystem concerns raised by this lane

_Named, not solved — the lane was told to stay inside its boundary._

- FilesController::MEASURABLE_EXTS (app/controllers/files_controller.rb:1173) is a fourth hand-written table of per-format capability living beside Registry::RENDERERS; its own comment (lines 1166-1172) explains why it cannot be derived from either Registry or payload_revision — because no renderer declares which KINDS it produces. Naming it only; it belongs to the Files/preview-surface subsystem.
- test/services/maker/previews/renderer_contract_test.rb:79-84 duplicates GeneratePreviewJob's kwarg reflection and never passes `kind:`, so the kind-dispatch arm of every multi-kind renderer is unexercised by the contract backstop that exists to make adding a format safe.
- Maker::Previews::DeadNodeReaper#reap! (dead_node_reaper.rb:42) loads a user's ENTIRE maker_previews table into memory and then builds an IN-clause over every node_id, and Maker::AttachmentReaper#reap! (app/services/maker/attachment_reaper.rb:45,59-63) does the same for attachments and covers. Unbatched, unlike MissingBackfill's find_in_batches. Not raised as a finding because the shared rule lives in Maker::DeadNodes and any SQL-level anti-join would split that one definition in two — the thing those files exist to prevent.
- Maker::Preview#version_id is nullable and holds a backend-polymorphic content_token (CLAUDE.md §5), which is what forces the `version_id.blank?` guard at enqueue.rb:205-211. That nullability originates in the FileLayer port, not here.

---

## S11 — Preview rasterizers (thumbnail producers)

**Lane verdict:** `recommend`

### S11-1 — Six independent definitions of "which binary, is it there, how do I run it" — one tool descriptor instead

> **COORDINATOR VERDICT — NARROWED.** Covers 4 of 6 tools and invalidates two config/brakeman.ignore fingerprints AND their justification notes, turning `bin/ci scan` red until re-argued. Keep the material core: give pdfium ONE `available?` (pdf.rb:22-29 rescues Errno::ENOENT/EACCES, pdf_text.rb:11-18 rescues StandardError). Defer BinaryTool.

- **Category:** ownership  
- **Lane confidence:** high

**Evidence**

- app/services/maker/previews/image_thumb.rb:25-32 — `BIN = ENV.fetch("VIPSTHUMBNAIL_BIN", "vipsthumbnail").freeze` then `available?` = `Open3.capture2e(BIN, "--vips-version"); true rescue Errno::ENOENT, Errno::EACCES then false`
- app/services/maker/previews/pdf.rb:22-29 — byte-for-byte the same shape with `PDFIUM_BIN`/`--version`
- app/services/maker/pdf_text.rb:11-18 — a SECOND definition of the SAME binary: `BIN = ENV.fetch("PDFIUM_BIN", "pdfium").freeze` with `available?` rescuing `StandardError` rather than `Errno::ENOENT, Errno::EACCES`. Two modules answer "is pdfium present?" by different rules; `ExtractPdfMetadataJob` asks one (app/jobs/maker/extract_pdf_metadata_job.rb:32 `return nil unless Maker::PdfText.available?`) and `GeneratePreviewJob` asks the other.
- app/services/maker/previews/stl.rb:21,43-50,55-74 — same constant+probe shape, then the tempfile-in / `"#{fin.path}.png"` out / `Open3.capture3` / `status.success? && File.exist?(out_path) && File.size?(out_path)` / `File.binread` / `ensure File.delete` block, with a trailing `rescue Errno::ENOENT => e; raise RenderError, "… not runnable"`
- app/services/maker/previews/svg_rasterizer.rb:20-31,47-77 — the same run-a-binary-to-a-tempfile block, but binary resolution is a memoized method (`def bin = @bin ||= ENV.fetch("RESVG_BIN", "resvg")`) with `reset_bin!`, and the run rescues `Errno::ENOENT, Errno::EACCES` (line 75) where stl.rb:72, pdf.rb:54, image_thumb.rb:55 and mesh.rb:97 rescue `Errno::ENOENT` only — so a present-but-unexecutable binary escapes four of the five renderers as a raw `Errno::EACCES`
- app/services/maker/previews/mesh.rb:26-38,76-99 — fifth copy; `to_output(mesh_bytes, ext:, out_ext:, size:)` carries an `out_ext` parameter and an `args += ["--resolution", …] if out_ext == ".png"` branch, while its only caller (mesh.rb:70) passes a literal `".png"` — vestigial since the `model_glb` path was closed at mesh.rb:65-68
- test/services/maker/previews/svg_rasterizer_test.rb:29-38 and test/services/maker/previews/mage_test.rb:30-38 — both drive the ENV knob + `SvgRasterizer.reset_bin!`; that door exists for exactly one of the six tools, because the other five froze their path into a constant at class-load

**Current complexity / invalid states**

Five renderers plus PdfText each carry their own copy of the same three things: (1) a frozen `BIN`/`F3D` constant read from ENV at class-load, (2) an `available?` that shells the binary and rescues to false, (3) for the five that render, a write-input-tempfile / build argv / `Open3.capture3` / check `status.success? && File.exist? && File.size?` / `File.binread` / `ensure File.delete` block wrapped in a `rescue Errno::* => raise <MyError>, "<name> not runnable"`. The copies have already drifted three observable ways: two different `available?` rescue contracts for the SAME pdfium binary (pdf.rb:27 vs pdf_text.rb:16), two different run-time rescue sets (svg_rasterizer.rb:75 vs the other four), and two different representations of "which binary" (five frozen constants vs one memoized-with-reset). Each copy also has to independently remember the `File.size?` limb of the success check — omitting it silently promotes a zero-byte output to a `ready` preview.

**Proposed representation**

One small value object in this namespace — e.g. `Maker::Previews::BinaryTool.new(env: "PDFIUM_BIN", default: "pdfium", probe: %w[--version], expect: nil)` — owning three methods: `path` (lazily memoized from ENV, with a `reset!` so every tool gets the door only SvgRasterizer has today), `available?` (runs `probe`, rescues ENOENT/EACCES, and applies the optional `expect` matcher that Mesh's f3d banner check needs), and `run_to_file(bytes, in_suffix:, out_suffix:, args:, error:)` returning the output bytes and raising the caller's own error class on a non-zero exit, a missing output, or a zero-byte output. Each renderer keeps its own `available?`/`render`/`EXTENSIONS` (the S10 contract, and the shape `forcing_available` and `without_svg_rasterizer` stub) and keeps its own error class and message; what it stops owning is the plumbing. `Maker::PdfText` uses the SAME tool instance as `Maker::Previews::Pdf`, so `PDFIUM_BIN` has one reading and one availability answer. Mesh's `to_output` loses `out_ext` and its dead `.png` branch.

**Why simpler**

It collapses six independent answers to one question into one answer. The concrete wins are not line count: the two modules that disagree about whether pdfium exists stop being able to disagree; the run-time rescue set becomes one decision instead of five that have already split; the `File.size?` success limb and the `ensure File.delete` cleanup become impossible to forget in a new renderer; and the ENV-driven "point this at a nonexistent path" test door that today exists only for resvg exists for all six, which matters in a repo whose §15 requires mutation-checking a guard by breaking the thing it guards. It follows the precedent §14b already sets for this exact situation — "the Reconciler is the reusable half; the Scanner is not", because "every one of phase 2a's bugs lived in the logic a second copy would have duplicated" — and registry.rb:42-48 records the same failure mode ("Two tables, one question, and the drift was invisible because each table looked right on its own").

**Smallest credible implementation scope**

One new ~50-line module plus edits to six files. Each renderer drops ~20 lines and gains a `TOOL = BinaryTool.new(...)` line and an argv-building `render`. The per-file rationale comments (why a subprocess and not ruby-vips — image_thumb.rb:11-14, §14e; why the f3d banner match is case-insensitive — mesh.rb:31-35; why running with no args is the probe — stl.rb:44-45, svg_rasterizer.rb:25-26; the resvg stylesheet argument — svg_rasterizer.rb:33-44) must MOVE with the code they explain, not be dropped: they each record a shipped bug.

**Affected files**

- `app/services/maker/previews/image_thumb.rb`
- `app/services/maker/previews/pdf.rb`
- `app/services/maker/previews/stl.rb`
- `app/services/maker/previews/mesh.rb`
- `app/services/maker/previews/svg_rasterizer.rb`
- `app/services/maker/pdf_text.rb`
- `config/brakeman.ignore`
- `test/services/maker/previews/svg_rasterizer_test.rb`
- `test/services/maker/previews/mage_test.rb`

**Regression risks and migration concerns**

1) `config/brakeman.ignore` pins Command Injection warnings by fingerprint to app/services/maker/previews/mesh.rb:88 and app/services/maker/previews/image_thumb.rb:45; moving both `capture3` calls into one shared method invalidates those fingerprints and their carefully written justification notes, so `bin/ci scan` will go red until they are regenerated and re-argued. 2) The five tools are not uniform: Mesh asserts a banner substring, ImageThumb needs a caller-chosen input suffix (image_thumb.rb:37), SvgRasterizer needs a SECOND tempfile for its stylesheet (svg_rasterizer.rb:53-56). If the shared runner cannot express all three cleanly, forcing them through it is worse than the duplication — SvgRasterizer in particular may be the member that keeps its own body. 3) `SvgRasterizer.reset_bin!` is called by two live tests; the replacement must keep an equivalent reset or those tests silently stop pointing at a bogus path. 4) Unifying the run-time rescue set to ENOENT+EACCES is a behaviour change (an EACCES from stl-thumbnailer becomes `RenderError` → `failed` instead of a raw Errno; note `available?` already gates this, so it is a narrow path).

**Validation required**

test/services/maker/previews/renderer_contract_test.rb already exercises every registered renderer structurally and end-to-end where its toolchain exists, and stl_test/mesh_test/svg_rasterizer_test cover the individual binaries; those must stay green with no edits. Then mutation-check per §15: point each tool's ENV knob at a nonexistent path and assert `available?` goes false and the job writes `unsupported` (today possible only for RESVG_BIN) — and confirm each assertion carries weight by reverting the rescue clause and seeing it go red. Also assert the zero-byte-output limb: make the runner's `File.size?` check the mutation target, since that is the one whose absence yields a `ready` preview over empty bytes. Run all three backend legs (`bin/ci test`, `test-s3`, `test-chunk-remote`) since renderer availability is backend-independent and the counts must match.

### S11-2 — `width`/`height` in the renderer result means two different things, and two producers fabricate it

> **COORDINATOR VERDICT — BLOCKED.** Cross-repo, and I originally recorded it as a bare ACCEPT. V1::Maker::PreviewsController#preview_json emits width/height (:112-113); this finding replaces fabricated square values with real ones.

- **Category:** state-representation  
- **Lane confidence:** medium

**Evidence**

- app/services/maker/previews/image_thumb.rb:34-35 — the doc comment says "A size×size-bounded PNG (aspect preserved)" — and image_thumb.rb:50 then returns `{ bytes: …, content_type: "image/png", width: size, height: size }`. vipsthumbnail is invoked as `--size #{size}x#{size}` (image_thumb.rb:45), which preserves aspect, so a 4:3 photo is recorded as 512×512.
- app/services/maker/previews/pdf.rb:31 — "Page 1 → a size×size-bounded PNG (aspect preserved)" — and pdf.rb:49 returns `width: size, height: size` after invoking pdfium with `--max-width`/`--max-height` (pdf.rb:43), which also preserves aspect. Every A4 page in the library is stored as square.
- app/services/maker/previews/three_mf.rb:174-183 — `png_dimensions` parses the real IHDR (`head[16, 8].unpack("N2")`) after comparing against a literal `"\x89PNG\r\n\x1A\n".b`, and three_mf.rb:51-52 uses it, so this renderer reports actual pixels (or nil for a JPEG entry)
- app/services/maker/previews/embedded_thumbnail.rb:19,27-30 — a SECOND copy of the same IHDR parse (`png[16, 8].unpack("N2")`) against its own `PNG_MAGIC` constant; app/services/maker/previews/lbrn2.rb:484 already reaches for `EmbeddedThumbnail::PNG_MAGIC`, so three_mf.rb:176's literal is the outlier
- app/services/maker/previews/stl.rb:67, app/services/maker/previews/mesh.rb:71, app/services/maker/previews/svg.rb:46 — these three are genuinely square (the binaries are given explicit `size size` / `--resolution size,size` / `--width --height`), so the same two keys are truthful here and fabricated in the two above, with nothing in the shape to tell them apart
- app/controllers/v1/maker/previews_controller.rb:113 — `width: p.width, height: p.height` is served to API clients from the `maker_previews.width`/`height` columns (db/schema.rb:264,273); this is the one consumer, and it cannot tell a measured pair from a declared bound

**Current complexity / invalid states**

The renderer result Hash `{ bytes:, content_type:, width:, height: }` is the contract every producer here fills, but `width`/`height` carry two incompatible meanings: "the pixels of the image I am returning" (ThreeMf, EmbeddedThumbnail — measured from the PNG header) and "the bound I asked the binary for" (ImageThumb, Pdf — where the binary preserves aspect, so the recorded pair is wrong). Stl/Mesh/Svg/TextThumb happen to be square, which is why the divergence is invisible. Separately, the IHDR sniff that would settle the question exists twice, in three_mf.rb:174-183 and embedded_thumbnail.rb:27-30, with the PNG magic bytes written as a shared constant in one and a literal in the other.

**Proposed representation**

Make the two keys mean exactly one thing — the returned image's actual dimensions, or nil when they cannot be cheaply read — and give the namespace one place that answers it: promote the IHDR sniff to a single helper (extending `EmbeddedThumbnail`'s existing `PNG_MAGIC` or a tiny `Maker::Previews::RasterHeader`), have ThreeMf and EmbeddedThumbnail call it instead of their two copies, and have ImageThumb and Pdf call it on the bytes they just read back rather than echoing the `size` argument they were passed. The renderers whose output is genuinely square can call it too, or keep their literal pair — but the contract comment (registry.rb:6-7) then says what the pair means, and a new renderer has one obvious thing to do.

**Why simpler**

One field, one meaning, one implementation. Today a consumer holding a `maker_previews` row has no way to know whether the numbers describe the image or describe a request, and for PDFs and photos — two of the most common file types in this library — they describe a request and are simply wrong. The change removes a duplicated header parser rather than adding an abstraction, and it removes the invalid state (a stored 512×512 for a 512×384 image) rather than documenting it.

**Smallest credible implementation scope**

One small helper (~10 lines, or a method added to EmbeddedThumbnail), plus four call sites: image_thumb.rb:50, pdf.rb:49, three_mf.rb:51-52 (swap its private copy for the shared one), embedded_thumbnail.rb:27-30. No schema change, no job change, no registry change. Note the sniff must stay total and non-raising — three_mf.rb:181-182's `rescue StandardError → [nil, nil]` is the right posture and should carry over, since a preview must never fail because its dimensions were unreadable.

**Affected files**

- `app/services/maker/previews/image_thumb.rb`
- `app/services/maker/previews/pdf.rb`
- `app/services/maker/previews/three_mf.rb`
- `app/services/maker/previews/embedded_thumbnail.rb`

**Regression risks and migration concerns**

1) Existing `maker_previews` rows keep their wrong values — this is not a staleness axis the revision mechanism covers, and bumping `THUMBNAIL_REVISION` to force a re-render would re-rasterize the whole library for a metadata field, which is almost certainly not worth it; the honest scope is "correct from here", stated plainly. 2) API clients reading the current square values would start seeing non-square ones; nothing in this repo consumes them beyond previews_controller.rb:113, but a desktop/web client outside this repo might. 3) three_mf.rb sets `content_type: "image/jpeg"` for a `.jpg` zip entry (three_mf.rb:50) while the sniff is PNG-only, so those keep answering nil — acceptable, but do not let the shared helper's name promise JPEG support it does not have (three_mf.rb:173's comment already over-promises: it says "PNG/JPEG header sniff" and handles only PNG).

**Validation required**

Extend test/services/maker/previews/renderer_contract_test.rb, which already renders each available renderer against a fixture (renderer_contract_test.rb:61-75), to assert that when `width`/`height` are non-nil they match the actual raster dimensions of `result[:bytes]` — that single assertion is what makes the field mean one thing across all nine producers, and it goes red today for the Pdf and ImageThumb entries (sample.pdf, sample.png) if either fixture is non-square. Mutation-check it by restoring `width: size, height: size` in pdf.rb and confirming red. Existing three_mf_test and embedded_thumbnail_test cover the parser move.

### Cross-subsystem concerns raised by this lane

_Named, not solved — the lane was told to stay inside its boundary._

- Maker::Previews::Mage (in boundary) and Maker::Previews::Lbrn2 (NOT in boundary) are near-identical shells: `available? = true`, `payload_revision(kind)` branching to LbrnGeometry::PAYLOAD_REVISION, and `render` = geometry arm | EmbeddedThumbnail.extract || outline_thumbnail-via-Lbrn2.to_svg (mage.rb:34-84 vs lbrn2.rb:151,171-172,184-203). Naming it only; any shared shape would have to be decided from the Lbrn2 side.
- The renderer call convention is discovered by reflection in two places that must agree: app/jobs/maker/generate_preview_job.rb:204 and test/services/maker/previews/renderer_contract_test.rb:81 both inspect `renderer.method(:render).parameters` to decide whether to pass `ext:`/`kind:`. That is S10's contract; the comments at generate_preview_job.rb:188-195 argue for the respond_to?/reflection shape, so I am not proposing a change — only noting the duplicated reflection.
- ThreeMf::THUMBNAIL_REVISION must be bumped by hand whenever Stl::THUMBNAIL_REVISION moves, because its mesh fallback renders through Stl (three_mf.rb:28-37 documents this and says it was verified). Nothing enforces the lockstep; the revision mechanism is S10's.
- Maker::PdfText takes a filesystem path (pdf_text.rb:20) while every preview renderer takes bytes, so app/jobs/maker/extract_pdf_metadata_job.rb:35-40 owns a tempfile the renderers own themselves. Folding PdfText into the shared tool object in finding 1 would make this asymmetry easy to remove, but the job is arguably S-other and I did not scope it.

---

## S12 — Preview geometry extraction (Measure payloads)

**Lane verdict:** `recommend`

### S12-1 — Dxf.each_geometry takes raw bytes, so every DXF render lexes the file twice and rebuilds the layer table twice

> **COORDINATOR VERDICT — ACCEPT.** Verified against the tree; no narrowing applied.

- **Category:** data-structure  
- **Lane confidence:** high

**Evidence**

- app/services/maker/previews/dxf_geometry.rb:31-36 — `pairs = Dxf.tokenize(dxf_bytes)` at :31, `Dxf.mm_per_unit(pairs)` at :32, `Dxf.layer_colors(pairs)` at :33, and then `Dxf.each_geometry(dxf_bytes)` at :36 — the traversal is handed the raw bytes, not the `pairs` the caller just built three lines above.
- app/services/maker/previews/dxf.rb:84-86 — `def each_geometry(dxf_bytes)` / `pairs = tokenize(dxf_bytes)` / `off = layers_off(pairs)`: a second full lex of the identical bytes, plus its own layer-table walk.
- app/services/maker/previews/dxf.rb:315-320 — the thumbnail leg does the same: `colors = layer_colors(tokenize(dxf_bytes))` at :316, then `each_geometry(dxf_bytes)` at :320, which tokenizes again.
- app/services/maker/previews/dxf.rb:261 and :269 — `layer_colors` and `layers_off` each independently call `layer_records(pairs)`; `layer_records` at :277-291 walks EVERY pair in the file. `DxfGeometry.build` calls one and `each_geometry` calls the other, so the layer table is reconstructed twice per payload.
- app/services/maker/previews/dxf.rb:381-392 — `tokenize` does `bytes.to_s.b.force_encoding("UTF-8").scrub.split(/\r\n|\r|\n/)` and then a two-line-at-a-time loop, i.e. a full string copy + a line array + a pair array. DXF is verbose ASCII (real laser/CNC sources run to megabytes), so this is the dominant allocation in the leg and it is paid twice.
- app/services/maker/previews/lbrn2.rb:224-231 — the same-subsystem precedent for the right shape: `to_svg` calls `parse_document` ONCE at :224 and hands the parsed `doc` to both `cut_colors(doc)` (:227) and `each_geometry(doc)` (:231). `Lbrn2.each_geometry(doc)` at :275 takes a document, not bytes.
- app/services/maker/previews/lbrn_geometry.rb:51 — `Geometry.encode(build(Lbrn2.parse_document(bytes)))`: LightBurn's measure leg parses once and passes the document down; DXF's does not.

**Current complexity / invalid states**

`Dxf.each_geometry`'s parameter type is `dxf_bytes`, but everything it needs is derived from `tokenize(dxf_bytes)`, and both of its two callers have already computed exactly that. The result is that one DXF render performs six full passes over the file where three would do: two `tokenize` calls (each a scrub + split + pair build over the whole byte string), two `layer_records` walks over the whole pair list, one header scan for `$INSUNITS`, and one `parse_entities` walk. Neither caller can avoid it, because the traversal re-derives its inputs from scratch rather than accepting them. The state that should be one parsed value — the pair list, the layer colour map, the off-layer set, the unit scale — is instead reconstructed piecemeal in two places (`DxfGeometry.build` builds three of the four; `each_geometry` rebuilds two of them privately), and nothing ties the two reconstructions together.

**Proposed representation**

Give the DXF leg the same shape the LightBurn leg already has: parse once, pass the parsed thing down. Smallest form: change `Dxf.each_geometry` to take the `pairs` list (as `Lbrn2.each_geometry` takes a `doc`), and have `DxfGeometry.build` and `Dxf.to_svg` each call `tokenize` once and pass it in. Fuller form, if it earns its keep: a small `Dxf::Document` value holding `pairs`, `layer_colors`, `layers_off` and `mm_per_unit`, built once by `tokenize`, with `layer_records` walked ONCE and both the colour map and the off-set derived from that single pass. `Dxf.render`/`Dxf.to_svg` keep their byte-taking public signatures — only the internal traversal's input type moves.

**Why simpler**

It removes a whole class of question from the file rather than trimming lines: today a reader has to notice that `DxfGeometry.build` and `each_geometry` are separately re-deriving the same four facts from the same bytes, and that the layer table is walked twice for two mutually exclusive slices of the same records. After the change there is one place where a DXF becomes structured data and one place each fact is computed, matching the pattern `Lbrn2`/`LbrnGeometry` already use and which the subsystem's own documentation treats as the norm. It also strictly halves the parse cost of the leg the invariants doc identifies as ~98% of the time to build a Measure view for the LightBurn equivalent.

**Smallest credible implementation scope**

Change `Dxf.each_geometry(dxf_bytes)` at dxf.rb:84 to accept the tokenized pairs; update its two callers (dxf_geometry.rb:36 and dxf.rb:320) to pass the pairs they already hold. Optionally fold `layer_colors`/`layers_off` into one `layer_records` pass returning both. No change to `render`, `to_svg`, `payload_revision`, the yield contract, or any output bytes — this is a parameter-type change, so no `FORMAT_REVISION` bump is warranted (and must not be made, per the invariants doc: a bump re-renders the library for nothing).

**Affected files**

- `app/services/maker/previews/dxf.rb`
- `app/services/maker/previews/dxf_geometry.rb`

**Regression risks and migration concerns**

`each_geometry` is a module_function other code could call; only dxf_geometry.rb:36 and dxf.rb:320 do today, but the signature change is a public-surface change and any out-of-tree caller passing bytes would break loudly (acceptable — it fails at the call, not silently). The real risk is accidentally weakening the one-traversal guarantee: dxf.rb:16-21 records that both artifacts MUST share `each_geometry` (§14b's LbrnMetadata second-copy bug), so the two callers must keep calling the same traversal — moving the tokenize out must not tempt anyone into giving the thumbnail its own walk. If a `Dxf::Document` struct is introduced, it must stay a value computed once per render and never be memoized on the module (the renderers are module_functions shared across Puma threads).

**Validation required**

Existing: test/services/maker/previews/dxf_test.rb (which calls `Dxf.tokenize` at :29 and `Dxf.parse_entities(Dxf.tokenize(...))` at :35 directly, so it exercises the pieces), and test/services/maker/previews/dxf_geometry_test.rb — in particular "the payload and the thumbnail measure the same geometry" at :120-131, which is the guard tying the two artifacts to one traversal and will go red if the walk is split. Additional required: (a) assert `Dxf.to_svg(fixture)` is byte-identical before and after on sample.dxf and plate.dxf — the same evidence dxf.rb:359-363 records for the original refactor onto `each_geometry`; (b) a guard counting `tokenize` invocations per `DxfGeometry.render` and asserting 1, mutation-checked by restoring the bytes-taking signature and confirming it goes red (§15: a guard that has never failed has not been shown to work).

### S12-2 — "A LightBurn CutSetting value lives in an attribute, a child's Value, or a child's text" is written six ways, and three of them disagree about the layer index that keys three separate maps

> **COORDINATOR VERDICT — ACCEPT.** Verified against the tree; no narrowing applied.

- **Category:** data-structure  
- **Lane confidence:** medium

**Evidence**

- app/services/maker/previews/lbrn2.rb:326 — `idx = cs["index"] || cs.at_xpath("index")&.[]("Value") || cs.at_xpath("index")&.text` inside `hidden_cuts`: attribute first, no blank handling.
- app/services/maker/previews/lbrn2.rb:506 — byte-identical to :326, inside `cut_colors`. Two literal copies of the same expression 180 lines apart.
- app/services/maker/previews/lbrn2.rb:338-340 — `def setting(cs, key)` = `cs.at_xpath(key)&.[]("Value") || cs.at_xpath(key)&.text || cs[key]`: the SAME three sources in the OPPOSITE order. `hidden_cuts` at :327 calls this for "hide" while reading "index" with the other order, so one method uses both conventions on one element.
- app/services/maker/previews/lbrn2.rb:509 — `raw = cs.at_xpath("color")&.[]("Value") || cs.at_xpath("color")&.text || cs["color"]`: a fourth hand-inlined copy, child-first, written out rather than calling `setting` two screens above it.
- app/services/maker/previews/lbrn_metadata.rb:95-97 — `def val(node, key)` = `node[key].presence || node.at_xpath(key)&.[]("Value").presence || node.at_xpath(key)&.text.presence`: attribute-first AND `.presence` on every arm. Its own comment at :93-94 says "Mirrors Lbrn2#cut_colors so both real-export forms parse" — it does not mirror it; the order is inverted and the blank handling differs.
- app/services/maker/previews/lbrn_metadata.rb:39 and :48 — `idx = val(cs, "index")` and the colour read: the panel derives the SAME layer index from the SAME element through the fifth variant, while lbrn2.rb:326 and :506 derive it through the first.
- app/services/maker/previews/lbrn2.rb:357 — `next if hidden.include?(cut_key(shape["Type"], layer_index(shape)))`: the hidden-set built from :326's reader is matched against the shape's own attribute string, so a mismatch in how the index is read silently stops hiding working — the exact failure lbrn2.rb:318-323 already records ("Merged by index, the first file renders as a blank page with no job size at all").
- Every fixture writes the child form only: `grep -rn 'CutSetting[^>]*index=' test/` returns ZERO matches, while `<index Value="N"/>` appears in bezier-circle.lbrn2:14, nested-plate.lbrn2:19,29, laser-settings.lbrn2:4,13,22, sample.lbrn2:4,9, real-export.lbrn2:21,28, embedded-thumb.lbrn2:10, text-backup-path.lbrn2:24. The attribute arm — the first term of three of these readers — is exercised nowhere, so the divergence cannot surface in the suite.

**Current complexity / invalid states**

Six expressions encode one fact about the LightBurn dialect (a value may be an attribute, a child's `Value` attribute, or a child's text). Two are byte-identical duplicates; three disagree on precedence (attribute-first at lbrn2.rb:326/:506 and lbrn_metadata.rb:96, child-first at lbrn2.rb:339 and :509); one applies `.presence` and the others rely on truthiness. Because Ruby's `||` treats `""` and `" "` as truthy while Rails' `.presence` does not, a CutSetting written as `<CutSetting index=" "><index Value="3"/></CutSetting>` yields `" "` from lbrn2.rb:326 and :506 but `"3"` from lbrn_metadata.rb:39 — three maps keyed on the same conceptual layer (`hidden_cuts`' visibility set, `cut_colors`' stroke map, `LbrnMetadata`'s panel rows) then disagree about which layer that is. The failure is silent in every direction: the hide check at lbrn2.rb:357 simply stops matching, `cut_colors` writes an entry no shape ever looks up, and the panel shows a layer the drawing treats as a different one. Nothing is positioned to notice, and no fixture reaches the attribute arm at all.

**Proposed representation**

One reader for the dialect and one derivation of a CutSetting's identity, both owned by `Lbrn2` (which already owns `cut_settings`, `cut_key`, `layer_color` and `layer_name`): a single `Lbrn2.setting(node, key)` with ONE deliberate precedence and ONE blank policy, plus `Lbrn2.cut_index(cs)` built on it. `hidden_cuts`, `cut_colors` and `LbrnMetadata.layers` all call those instead of re-spelling them. If it reads better as a value, a tiny `Lbrn2::CutSetting` wrapper exposing `index`, `color`, `hidden?` and `setting(key)` collapses the same six expressions into one place and gives the three consumers a shape to agree on rather than a Nokogiri node each re-interprets.

**Why simpler**

It makes "which layer is this?" have one answer instead of three, which is the property the code already depends on and currently only gets by coincidence — the same one-condition-two-answers shape this repo records as its own failure mode, here inside a single format's parser. It also removes the standing question a reader of lbrn2.rb:326-340 has to resolve today (why does one method read the index attribute-first and the sibling field child-first?), which cannot be answered from the code because there is no reason — the orders were written independently.

**Smallest credible implementation scope**

Pick the precedence deliberately (attribute-first matches three of the four index readers and lbrn_metadata's `val`) and the blank policy (`.presence` on all arms is the only one that cannot produce a blank key), then route lbrn2.rb:326, :506, :509 and lbrn_metadata.rb:39/44/48/61-63/78 through it. Do NOT fold in `LbrnMetadata.device_name` (lbrn_metadata.rb:99-103): it deliberately uses the DESCENDANT axis `.//DeviceName`, not the child axis, and mage_metadata.rb:71-72 records why that distinction matters — collapsing them would let a lookup reach into a nested element. `text_strings` at :105-108 is likewise a different query (an xpath filter over Shape[@Type='Text']) and should stay.

**Affected files**

- `app/services/maker/previews/lbrn2.rb`
- `app/services/maker/previews/lbrn_metadata.rb`

**Regression risks and migration concerns**

Unifying CHANGES behaviour on files using the attribute form — no fixture uses it, so the suite cannot tell you which way it moved, and the 58-export corpus that sized this parser is not in the repo. Mitigate by adding a fixture with an attribute-form `<CutSetting index="1" hide="1">` and one with both forms present, and by documenting `Lbrn2.setting`'s precedence at its definition. The change touches the layer-index derivation `hidden_cuts` feeds, and lbrn2.rb:307-331 records a real shipped bug in that area (visibility keyed on (kind, index), never index alone) — `cut_key`'s two-part key must not be disturbed. `LbrnMetadata.parse` has a blanket `rescue StandardError` at :33-34 returning nil, so a mistake here degrades to an empty Laser Settings panel rather than an error: assert on the parsed output, not on the absence of an exception.

**Validation required**

Existing: test/services/maker/previews/lbrn2_test.rb — the hidden-layer group at :264-305 (including the CutSetting/CutSetting_Img same-index pair at :284-302), the colour tests at :78 and :317-335; test/services/maker/previews/lbrn_metadata_test.rb :20, :43-60, :78-79, :98, :107-108; test/services/maker/previews/lbrn_geometry_test.rb and test/integration/web/lbrn_geometry_test.rb for the payload's `colors` map. Additional required: a fixture exercising the ATTRIBUTE form of `index`/`hide`/`color` (currently zero coverage), and one asserting that `hidden_cuts`, `cut_colors` and `LbrnMetadata.layers` agree on the index string for a CutSetting carrying both a blank attribute and a real child value — mutation-checked by restoring one of the old inline readers and confirming that test goes red.

### Cross-subsystem concerns raised by this lane

_Named, not solved — the lane was told to stay inside its boundary._

- app/services/maker/previews/mage_metadata.rb:73-74 holds a FOURTH copy of the same three-way `val(node, key)` reader (attribute-first + .presence, identical to lbrn_metadata.rb:96). It is outside this boundary; if the LightBurn reader is unified, that file is the obvious next caller, but MillMage's `<Operation>`/`<Tool>` lookup has its own child-axis argument recorded at mage_metadata.rb:71-72 and should be decided there, not here.
- The `kind == "geometry"` artifact dispatch is spelled out four times across the renderers: dxf.rb:38/46-48/57 and lbrn2.rb:171-173/185 inside this boundary, plus svg.rb:22/30-31/43 and mage.rb:51-52/65 outside it. A shared mixin taking one `geometry_module` declaration would collapse all four, but two sites belong to renderers I do not own and the invariants doc argues for each format declaring its own `PAYLOAD_REVISION`/`available_for?` — worth deciding at the renderer-registry level, not from inside the geometry files. Note enqueue.rb:171-172 already records that a mutation in this area "reddened NOTHING" because Lbrn2's two revisions happen to be equal.
- docs/invariants/measure-view.md states "CURVE FLATTENING IS BOUNDED BY GEOMETRIC ERROR, NEVER BY A FIXED SAMPLE COUNT", but svg_geometry.rb:69 (`ELLIPSE_SAMPLES = 64`) and lbrn2.rb:126 (`ELLIPSE_SAMPLES = 32`) flatten `<circle>`/`<ellipse>` and LightBurn Ellipses at a fixed count. For an unrotated ellipse the multiple-of-4 rule keeps the bbox and `d` exact (which is what those comments argue), but under a rotating transform the axis extents are no longer sampled and the reported extent can read small — the same silent under-report the doc describes. This is a correctness question, not a simplification, so I am naming it rather than proposing a change.

---

## S13 — Identity models

**Lane verdict:** `recommend`

### S13-1 — Device conflates two populations: enrolled client devices and server-owned singleton devices, with no way to express the constraint

> **COORDINATOR VERDICT — NARROWED.** Diagnosis sound, remedy not. Drop the `kind` column, the partial index and the backfill the lane itself says "deletes live credentials" on the table holding the only credential the v1 API accepts. Keep: one `Device.service(user:, key:)` + a SERVICE_NAMES constant. No migration.

- **Category:** state-representation  
- **Lane confidence:** medium

**Evidence**

- app/models/device.rb:11-16 — `Device.register!(user:, name:)` unconditionally mints a fresh `SecureRandom.urlsafe_base64(32)` token and `create!`s a new row every call; the plaintext is stashed by `instance_variable_set(:@plaintext_token, token)`.
- app/models/device.rb:9 — `attr_reader :plaintext_token`; only populated on the object returned by `register!`, so any Device loaded via `find_by` has nil there. The two service call sites below therefore hold a Device whose token they can never see — fine for them, and exactly the asymmetry showing they are a different kind of thing.
- app/controllers/application_controller.rb:57-62 — `WEB_DEVICE_NAME = "web-session"` then `@web_device ||= current_user.devices.find_by(name: WEB_DEVICE_NAME) || Device.register!(user: current_user, name: WEB_DEVICE_NAME)`. A get-or-create written by hand, not `find_or_create_by`.
- app/services/maker/addons/library_output.rb:181-182 — `def addon_device(user); user.devices.find_by(name: "addons") || Device.register!(user:, name: "addons"); end`. The identical shape with a bare string literal instead of a constant; the concept has no single owner.
- db/schema.rb:52-61 — the devices table has exactly two indexes: `["token_digest"] unique` and `["user_id"]`. There is NO uniqueness on `(user_id, name)`, so nothing prevents N rows sharing a well-known name.
- db/schema.rb:55 — `t.string "name", default: "device", null: false`, and app/controllers/v1/devices_controller.rb:36 and :45 both do `params[:device_name].presence || "device"`. Several enrolled devices per user legitimately share the name "device", which is why a plain unique index on (user_id, name) is NOT available as a fix — the constraint cannot be stated without first distinguishing the two populations.

**Current complexity / invalid states**

`Device` models one thing, but two populations with different lifecycles live in the table. (1) Enrolled devices: created by V1::DevicesController#login/#create, plaintext token handed to a remote client exactly once, later matched by Device.authenticate, last_seen_at touched per request, names user-supplied and freely duplicated (default "device"). (2) Server-owned singletons: `web-session` and `addons`, created lazily by this app for itself, whose token is never returned to anyone and never authenticates anything — they exist only to supply a `device:` attribution to FileLayer write calls (files_controller.rb:536 passes `device: web_device`; library_output.rb:159 passes `device: addon_device(user)`). Because the model has no notion of population (2), "there is exactly one web-session device per user" is asserted nowhere: it is a hand-rolled `find_by || register!` at two call sites, in two different layers, with the key spelled as a controller constant in one and a string literal in the other. Two consequences follow from the representation. First, the get-or-create is racy with no constraint behind it: two concurrent first-time requests (two browser tabs after sign-in; two addon saves) each fall through the `find_by` and each call `register!`, producing two live credentials named `web-session`, after which `find_by` returns an arbitrary one and the extra token persists forever with nothing to clean it up. Second, the two populations are indistinguishable: `POST /v1/devices { name: "web-session" }` is a documented endpoint (devices_controller.rb:43-47) that mints an ordinary enrolled device the server-side lookup will then happily adopt as its own attribution device.

**Proposed representation**

Give Device the discriminator the schema needs and let the model own the singleton concept. Add a `kind` column (`enrolled` default / `service`) plus a partial unique index on `(user_id, name) WHERE kind = 'service'` — partial because enrolled devices must keep sharing the default name "device". Add `Device::SERVICE_NAMES = { web: "web-session", addons: "addons" }` and one class method, `Device.service(user:, key:)`, doing `find_or_create_by` on `(user, name, kind: :service)` with a rescue of RecordNotUnique that re-finds — the standard shape, now correct because the index exists to make it correct. ApplicationController#web_device becomes `@web_device ||= Device.service(user: current_user, key: :web)` and LibraryOutput#addon_device becomes `Device.service(user:, key: :addons)`; WEB_DEVICE_NAME and the "addons" literal both go. Optionally (worth doing, but separable) scope `Device.authenticate` to `kind: :enrolled`, which makes "a service device's token is never handed out, so a token matching one is by construction not a real login" a property of the type rather than something a reader reconstructs from two call sites.

**Why simpler**

One question — "which device does the server use to attribute its own writes for this user?" — currently has two answers written in two layers and enforced by neither the schema nor the model. After the change it has one answer, in the model that owns device lifecycle, and the invariant it depends on (at most one per user per service name) is a database constraint instead of a comment. It also removes an invalid state the current shape permits (N rows sharing a well-known name, and an enrolled device masquerading as a service one) rather than merely relocating a branch. This is NOT a case where CLAUDE.md or a code comment argues for the present shape: §8 and §14j say only that Device is host-owned and that its token is the sole v1 credential — both preserved by the proposal — and neither the ApplicationController comment ("A stable, reusable Device for the signed-in web user") nor the LibraryOutput comment ("A dedicated device so addon writes are attributable") defends the hand-rolled get-or-create; they state the intent the proposal would actually enforce.

**Smallest credible implementation scope**

One migration (add `kind` with a default, backfill the two known names to 'service', add the partial unique index — SQLite and Postgres both support partial indexes, which matters because §7 requires adapter-agnostic code). ~15 lines added to app/models/device.rb; two call sites edited to one line each. Test work is the real cost and it is additive: there is currently NO test/models/device_test.rb at all, so the concurrency behaviour has no coverage to update — a new model test asserting the second call returns the same row and does not increase Device.count, plus (per §15) a mutation check that reverting to `find_by || register!` under concurrent calls goes red.

**Affected files**

- `app/models/device.rb`
- `app/controllers/application_controller.rb`
- `app/services/maker/addons/library_output.rb`
- `db/schema.rb`
- `db/migrate/ (one new migration)`

**Regression risks and migration concerns**

The backfill must handle duplicate-name rows the current race may already have created on live deployments — the partial unique index will refuse to build otherwise, so the migration needs a de-dup step (keep the oldest, delete the rest), and that step deletes live credentials, exactly the sort of thing to verify row-counts on before running (precedent: DropRetiredSyncEngineTables was run only after confirming 0 rows on every live deployment). Scoping Device.authenticate to enrolled is a behaviour change for any deployment where a service device's token did get used, so it should land as a separate step behind its own test rather than in the same commit. Adding a column to `devices` touches the model whose token is the only credential the v1 API accepts, so the change wants the full three-backend run.

**Validation required**

bin/ci's three backend legs (test / test-s3 / test-chunk-remote) with identical run counts per §15; the existing test/integration/v1/device_login_test.rb (lines 25, 47, 62, 76 already assert Device.count deltas across the login paths) covers the enrolled population unchanged. New: a device model test that calls the service accessor twice and asserts one row, and the same from two threads; and an assertion that `POST /v1/devices { name: "web-session" }` produces a device the web lookup does not adopt.

### S13-2 — Three overlapping predicates and a transient flag all answer "does this account have no local password"; one is subsumed and the flag is inert

> **COORDINATOR VERDICT — ACCEPT.** Verified against the tree; no narrowing applied.

> **Schema gap in this entry:** affected_files names 5 files; its own scope requires a same-commit sweep of 24 (`grep -rl omniauth_signup test/`). 21 required edits unlisted.

- **Category:** state-representation  
- **Lane confidence:** medium

**Evidence**

- app/models/user.rb:173-177 — `def password_required?; return false if omniauth_signup || omniauth_identity?; return false if encrypted_password.blank? && password.blank?; super; end`. Two guard clauses for one question.
- app/models/user.rb:92-94 — `# Set transiently by from_omniauth (and the v1 bootstrap) so a passwordless account validates on first save before its UserIdentity row is persisted. Not a DB column.` followed by `attr_accessor :omniauth_signup`. This comment is the argument for the flag's existence — and the second guard clause (line 175) already makes every case it names validate, because such an account has both `encrypted_password` blank (schema default "") and `password` nil.
- app/models/user.rb:181-183 — `def omniauth_identity?; identities.any? { |i| i.persisted? || i.new_record? }; end`. Its only caller in app/, lib/ or config/ is line 174 (verified by grep across app/ lib/ test/ config/); the pre-save case it exists for — test/models/user_devise_model_test.rb:27-30, `User.new(email:)` + `identities.build(...)` with no password — is likewise already covered by line 175.
- app/models/user.rb:104-107 — `skip_confirmation_notification! if respond_to?(...) && encrypted_password.blank? && password.blank?` repeats line 175's condition verbatim as a third spelling of the same test.
- app/controllers/users/registrations_controller.rb:14-19 — the comment states the rule as `password_required?` "returns false whenever no password is set (so the OmniAuth seam + the device-token bootstrap can create passwordless accounts)". That is line 175 alone; the controller's account of the model's contract does not include line 174's broader rule.
- devise-5.0.4/lib/devise/models/validatable.rb:37-39 — `validates_presence_of :password, if: :password_required?` and `validates_confirmation_of :password, if: :password_required?` are gated on it, while `validates_length_of :password ... allow_blank: true` at line 39 is NOT. So the practical effect of line 174 is that an identity-linked account skips the password-confirmation match on any later password set (e.g. a :recoverable reset), silently accepting a mistyped pair.
- test/ — `omniauth_signup: true` appears in ~30 test files (test_helper.rb:282, test/services/maker/project_intake_test.rb:26, test/models/maker/shelf_test.rb:7, and so on), always as `User.create!(email:, confirmed_at: Time.current, omniauth_signup: true)` with no password. Every one of those users validates identically without the flag, via line 175.

**Current complexity / invalid states**

"This account has no local password" is represented four ways on one model: a transient attr_accessor (`omniauth_signup`, user.rb:94), an association scan (`omniauth_identity?`, user.rb:181), a column check exposed as a public predicate (`password_set?`, user.rb:162), and an inline `encrypted_password.blank? && password.blank?` written out twice (user.rb:105-106 and user.rb:175). `password_required?` consults three of the four in sequence. The first guard (line 174) is broader than the rule the model's own comment at 166-172 states ("a password is REQUIRED only when one is actually being set") and broader than the rule registrations_controller.rb:14-19 relies on, and it is not load-bearing: no current path sets `omniauth_signup` or builds an identity on a User that also carries a password (from_omniauth at user.rb:144 does `new(email:)` with no password, then sets the flag at line 150), so line 175 already returns false for every case line 174 catches. The flag's cost is not local: ~30 test files thread `omniauth_signup: true` through User.create! believing it is what makes those users valid, when line 175 is. The one place line 174 does change behaviour is the case it was not written for — an already-identity-linked account setting a password later, where it suppresses validates_confirmation_of.

**Proposed representation**

Collapse to the single rule both comments already state. `password_required?` becomes `return false if encrypted_password.blank? && password.blank?; super`. Delete `omniauth_signup` (user.rb:94, and the assignment at user.rb:150) and `omniauth_identity?` (user.rb:181-183). Extract the twice-written condition as one private predicate — `def passwordless? = encrypted_password.blank? && password.blank?` — used by both `password_required?` and `skip_passwordless_confirmation_notification` (user.rb:105-106), so the credential state of an account is computed in exactly one place. Keep `password_set?` (user.rb:162): it is the persisted-state question from_omniauth's anti-takeover gate asks at user.rb:134, a genuinely different question from "is a password being set on this save", and CLAUDE.md §8's registration/takeover rules depend on it.

**Why simpler**

One rule replaces three, and the rule that survives is the one two separate comments already claim is the contract — so the code stops disagreeing with its own documentation. It removes a transient attribute that ~30 test call sites treat as load-bearing when it is not, a live source of wrong mental models for anyone reading a test setup. And it closes the one asymmetry the current shape actually produces (confirmation-match silently skipped for identity-linked accounts) by deletion rather than by adding a fourth condition. I want to be explicit that a comment DOES argue for the current shape — user.rb:92-93 justifies `omniauth_signup` — and I recommend against it only because I checked the justification rather than accepting it: the flag's stated purpose is served by line 175, verified by tracing from_omniauth (user.rb:122-154), the bootstrap in test_helper.rb:282, and the pre-save identity case in user_devise_model_test.rb:26-33. If that trace is wrong, this finding is wrong.

**Smallest credible implementation scope**

~12 lines removed from app/models/user.rb plus one small private predicate. The blast radius is the test suite and it is mechanical but must land in one sweep: deleting the attr_accessor makes every `User.create!(..., omniauth_signup: true)` raise UnknownAttributeError, so all ~30 files drop the kwarg in the same commit (`grep -rl 'omniauth_signup' test/` plus one-line-per-site edits). No migration, no controller changes.

**Affected files**

- `app/models/user.rb`
- `test/test_helper.rb`
- `test/models/user_omniauth_test.rb`
- `test/models/user_devise_model_test.rb`
- `test/integration/web/devise_auth_flow_test.rb`

**Regression risks and migration concerns**

The whole finding rests on the claim that line 174 is subsumed by line 175 on every reachable path. That is a claim about Devise's validation wiring as well as this app's, and I verified it by reading devise-5.0.4/lib/devise/models/validatable.rb rather than by running anything — as a read-only auditor I could not execute the suite, so it must be mutation-checked before landing (§15): delete line 174 alone first and confirm the suite is still green, and separately confirm that reverting line 175 alone goes red, which proves line 175 is the guard actually carrying the passwordless accounts. Second risk: dropping the flag changes what ~30 test setups say they are doing; if any relies on omniauth_signup for something other than password validation, that surfaces in the sweep. Third: :registerable web sign-up must keep requiring a password — that is enforced at the controller boundary (registrations_controller.rb:20-28), not by password_required?, so it is unaffected, but the devise_auth_flow_test.rb signup case should be confirmed green explicitly rather than assumed.

**Validation required**

bin/ci's three backend legs with identical run counts. Specifically: test/models/user_devise_model_test.rb:20-24 (short password still rejected — the case that proves `super` still runs), :26-33 (identity-built account still valid with no password), test/models/user_omniauth_test.rb in full (the takeover gate depends on password_set?, unchanged), and test/integration/web/devise_auth_flow_test.rb:34 and :71. Add one new test the current shape cannot pass: an identity-linked user setting a password with a mismatched confirmation must be rejected.

### Cross-subsystem concerns raised by this lane

_Named, not solved — the lane was told to stay inside its boundary._

- app/controllers/concerns/v1/authentication.rb:1-17 documents itself as a deliberate second copy of Sync::V1::Authentication and says test/v1_auth_parity_test.rb compares the two — but CLAUDE.md §14j states that guard went with the extraction and 'nothing checks that agreement now'. Device-token verification is duplicated across two repos with no guard behind it. Named, not solved.
- app/controllers/application_controller.rb:59-62 and app/services/maker/addons/library_output.rb:181-182 are the two call sites finding 1 would edit; where the service-device accessor is called from belongs to the web-layer and addons subsystems.
- user.rb:196-222's comment block still describes lib/postgres_pooler_check.rb and Sync.engine_present?, both of which CLAUDE.md §14e says are gone — a third stale block in the same file beyond the two the brief pre-identified. Docs hygiene, not structural; not counted as a finding.
- V1::DevicesController#create (app/controllers/v1/devices_controller.rb:43-47) accepts an arbitrary caller-supplied device name with no reserved-name check, which is what lets an enrolled device collide with a well-known service name. Whether that door should refuse the service names belongs to the v1 controller subsystem.

---

## S14 — Inventory / BOM / taxonomy domain models

**Lane verdict:** `recommend`

### S14-1 — The owned-reference pattern (guarded validation + inverse destroy handler) is written out six times, and the pairing exists only in prose

> **COORDINATOR VERDICT — NARROWED.** The DSL does not close the bug class — a seventh reference written the old way stays as invisible as today. Keep the shared private predicate + a guard test enumerating the pairs. No macro, no registry.

- **Category:** ownership  
- **Lane confidence:** medium

**Evidence**

- app/models/maker/inventory_item.rb:24-25 — `validate :location_belongs_to_user, if: -> { location_id.present? }` and `validate :supplier_belongs_to_user, if: -> { supplier_id.present? }`
- app/models/maker/inventory_item.rb:109-119 — two private methods with identical bodies: `unless Maker::Location.exists?(id: location_id, user_id: user_id) errors.add(:location_id, "must reference your own location")` and the same for Supplier
- app/models/maker/bom_line.rb:15-16 and :57-67 — the same two-line declaration plus the same two method bodies again, for `inventory_item_id` and `supplier_id`
- app/models/maker/location.rb:17 and :21-25 — a fifth copy (`parent_belongs_to_user`); app/models/maker/bom.rb:12 and :16-20 — a sixth (`project_belongs_to_user`, deliberately unguarded because `project_id` is NOT NULL)
- app/models/maker/supplier.rb:7-19 — a 9-line comment recording that WITHOUT the two `dependent: :nullify` lines beneath it, destroying a supplier locks every referencing row against editing ANYTHING, because the referrer's `if: supplier_id.present?` guard still fires on a dangling id
- app/models/maker/location.rb:9-14 — the same bug recorded a second time: the `children` nullify "covered only the self-reference; inventory items pointing here were stranded AND locked"
- app/models/maker/item.rb:15-20 — the same bug a third time, for `Task#taskable_belongs_to_owner`, fixed with `has_many :tasks, as: :taskable, dependent: :nullify`
- app/models/maker/inventory_item.rb:13-17 — the same bug a fourth time, on `bom_lines`, where the handler had to be a custom `before_destroy` instead of a `dependent:`
- lib/schema_map.rb:153-166 — an authored EDGES table already enumerates these same app-level references, and lib/schema_map.rb:25-31 states plainly that nothing catches a NEW app-level reference nobody adds to it
- test/integration/v1/maker/referential_integrity_test.rb:5-15 — the whole suite exists for this one bug class ("audit A-M4"), asserting per-pair by hand rather than over an enumeration

**Current complexity / invalid states**

Six near-identical `<fk>_belongs_to_user` private methods plus their guarded `validate` lines are spread across five models in this subsystem (two more, Sheet and Task, sit just outside it). Each one silently obliges the REFERENCED model to declare an inverse destroy handler, because a dangling id is still `present?` and so keeps failing the guard on every later save — the permanent-row-lock described at CLAUDE.md §14d. That obligation is recorded only as prose comments on the other model (supplier.rb:7-19, location.rb:9-14, item.rb:15-20, inventory_item.rb:13-17), one comment per time it was missed. There is no place where the pairs are enumerable, so nothing can check that a reference has its inverse: the four comments are four separate shipped instances of the same bug, each found by a user-visible symptom rather than by a gate.

**Proposed representation**

A small `Maker::OwnedReference` concern that declares one reference in one statement — e.g. `owned_reference :supplier, class_name: "Maker::Supplier", on_owner_destroy: :nullify` — doing three things: declaring the `belongs_to ... optional: true`, declaring the existing guarded validation with the existing message, and appending `[model, foreign_key, owner_class, handler]` to a class-level registry. `BomLine`'s inventory-item reference declares `on_owner_destroy: :release_bom_lines` — it RECORDS the custom handler, it does not replace it. One new guard test then walks the registry and asserts, for every entry, that the owner class actually carries the named handler: a `has_many` reflection on the matching foreign key with a non-nil `dependent:`, or a `before_destroy` callback of that name. Keep every existing comment at its declaration site; they carry the bug histories §14d cites.

**Why simpler**

The subsystem's most-repeated defect stops depending on someone reading a comment on a different model. Today the correctness of `InventoryItem#supplier_belongs_to_user` lives in `supplier.rb`, and the only thing connecting them is prose; after the change the pair is one line of data that a test walks, so adding a seventh owned reference without its inverse handler goes red instead of shipping and locking rows. It also collapses six copies of a five-line method into one implementation, which matters less than the registry but is why the copies drifted in guard style (four are `if: <fk>.present?`-guarded, two are not) with no way to see that at a glance.

**Smallest credible implementation scope**

One new file (app/models/concerns/maker/owned_reference.rb, roughly 30 lines), six declaration sites rewritten across inventory_item.rb, bom_line.rb, location.rb and bom.rb with their private methods deleted, and one new guard test. No schema change, no controller change, no behaviour change: the validations must keep the same names, messages, and `present?` guards so the existing suites pass untouched.

**Affected files**

- `app/models/maker/inventory_item.rb`
- `app/models/maker/bom_line.rb`
- `app/models/maker/location.rb`
- `app/models/maker/bom.rb`
- `app/models/maker/supplier.rb`
- `app/models/concerns/maker/owned_reference.rb (new)`

**Regression risks and migration concerns**

Three real ones. (1) This introduces a DSL where explicit code stood, which this repo generally distrusts — the justification is the registry, not the line saving, and if the registry guard is not written the change is not worth making. (2) CLAUDE.md §14d forbids collapsing `InventoryItem#release_bom_lines` into a `dependent:`; the macro must therefore support a named custom handler and must not be allowed to "normalise" that entry into a nullify. Same for `Bom#project_belongs_to_user`, which is deliberately unguarded because `project_id` is NOT NULL. (3) `Task#taskable_belongs_to_owner` (app/models/maker/task.rb:40, :61-71) is polymorphic and resolves its owner class through a `TASKABLE_OWNERS` map with a deliberate blank-type exemption; it does not fit the macro and should stay hand-written, with at most a manual registry entry.

**Validation required**

test/integration/v1/maker/referential_integrity_test.rb and test/integration/v1/maker/cross_tenant_fk_test.rb must stay green with no edits — they drive the real API and are the behavioural definition of both halves. Then mutation-check the new guard the way §15 requires: delete `dependent: :nullify` from supplier.rb:16-19 and confirm the guard goes RED, restore; delete it from location.rb:13-14, confirm RED, restore; rename `release_bom_lines` and confirm RED. A guard over an enumeration must also assert the enumeration is non-empty, per the recorded failure at §14e where two architecture guards passed over an empty glob.

### S14-2 — The ledger's destroy guard infers "am I being cascaded?" from parent object state that the real cascade never sets, leaving account deletion dependent on the order of two lines in User

> **COORDINATOR VERDICT — PROMOTED.** Latent, order-dependent, unguarded: the permitted branch is unreachable via the sanctioned cascade (dependent: :delete_all bypasses callbacks), and User#destroy survives only because user.rb:67 precedes :68.

- **Category:** state-representation  
- **Lane confidence:** medium

**Evidence**

- app/models/maker/inventory_transaction.rb:43-49 — `allow_destroy_only_with_parent` permits the destroy `unless inventory_item.nil? || inventory_item.destroyed? || inventory_item.marked_for_destruction?`, with a comment saying it exists to permit removal "when the parent item is being destroyed (dependent: :destroy)"
- app/models/maker/inventory_item.rb:10-12 — the association is `has_many :transactions, ... dependent: :delete_all`, NOT `:destroy`; `delete_all` issues one DELETE without instantiating rows, so `before_destroy` never fires on that path and none of the guard's three escape clauses is ever evaluated there
- app/models/maker/inventory_transaction.rb:17-18 — the sibling rule immediately above is unconditional (`before_update { raise ActiveRecord::ReadOnlyRecord, "inventory transactions are immutable" }`), so the same fact is stated once flatly and once through a three-clause predicate
- app/models/user.rb:67-68 — `has_many :maker_inventory_items, dependent: :destroy` is declared on line 67 and `has_many :maker_inventory_transactions, dependent: :destroy` on line 68; Rails runs dependent cascades in declaration order, so today the items go first and delete_all their ledger rows, leaving line 68 with nothing to instantiate. Swap the two lines and every account deletion raises ReadOnlyRecord mid-cascade
- app/controllers/users/registrations_controller.rb:44-46 — account deletion is a live, reachable request path (`if resource.valid_password?(supplied) then super`), and its own comment records that this cascade covers 31 `dependent: :destroy` associations
- test/models/maker/inventory_transaction_test.rb:60-71 — the two pinned tests are "cannot be destroyed while its item exists" (raises) and "destroying the item cascades" (goes through delete_all); neither one reaches the `destroyed?`/`marked_for_destruction?` branches

**Current complexity / invalid states**

"A posted ledger row may only disappear as part of its parent's destruction" is encoded as a runtime inspection of the parent's transient in-memory flags — `nil?`, `destroyed?`, `marked_for_destruction?`. But the sanctioned cascade is `dependent: :delete_all`, which bypasses callbacks entirely, so the branch that predicate exists to permit is unreachable from every path in the app; the code comment naming `dependent: :destroy` describes an association shape that is not what inventory_item.rb:12 declares. The one path that DOES instantiate ledger rows — `User#destroy` via `maker_inventory_transactions` — would hit the guard with a live, undestroyed parent and raise, and only escapes because `maker_inventory_items` happens to be declared one line earlier.

**Proposed representation**

State the rule once, flat, matching the `before_update` immediately above it: `before_destroy { raise ActiveRecord::ReadOnlyRecord, "inventory transactions are immutable" }`, with the three-clause predicate and its method deleted. Make both cascades explicitly row-level rather than callback-level: keep `dependent: :delete_all` on `InventoryItem#transactions` (with a comment naming the new dependency — the record-level rule is unconditional now, so this association must never be switched to `:destroy`), and change app/models/user.rb:68 to `dependent: :delete_all` so account deletion stops depending on declaration order.

**Why simpler**

One sentence — "a posted ledger row is never destroyed through a record callback; the two cascades are row-level DELETEs" — replaces a predicate over three transient object flags whose true branches nothing can currently reach, plus a comment that names the wrong association mode. It also removes an invisible ordering coupling between two adjacent lines in a 20-line association block, where a reasonable tidy-up (alphabetising, grouping) silently breaks a live account-deletion request. This is the append-only invariant the model already claims at inventory_transaction.rb:5 ("Immutable append-only ledger") expressed without an escape hatch that only looks like one.

**Smallest credible implementation scope**

Delete `allow_destroy_only_with_parent` and replace the `before_destroy` symbol with the inline raise (app/models/maker/inventory_transaction.rb:18, 43-49); add one comment line at app/models/maker/inventory_item.rb:10-12; change `:destroy` to `:delete_all` at app/models/user.rb:68. About six lines net removed, one line changed outside the subsystem boundary.

**Affected files**

- `app/models/maker/inventory_transaction.rb`
- `app/models/maker/inventory_item.rb`
- `app/models/user.rb`

**Regression risks and migration concerns**

Two. (1) The unconditional raise makes `dependent: :destroy` on any future `has_many :transactions` a hard failure rather than a permitted cascade — that is the intent, but it must be commented at the association or the next editor "fixes" `:delete_all` into `:destroy` and breaks item deletion. (2) `user.rb:68` is outside this subsystem's boundary; the change is one word but belongs to whoever owns User. A related, deliberately untouched item: `maker_inventory_transactions.project_id` (lib/schema_map.rb:164) has no inverse handler on Project, which is harmless only because the ledger runs no validation on that column — do not "fix" it by adding one without also adding the handler.

**Validation required**

test/models/maker/inventory_transaction_test.rb:60-71 must stay green unchanged (the "cannot be destroyed while its item exists" test now passes via the flat rule, and the item-cascade test still goes through delete_all). Add one test that `User#destroy!` succeeds for a user holding ledger rows — it passes both before and after, so mutation-check it by first reordering user.rb:67/68 and confirming it goes RED on today's code and stays GREEN after the change; that is the whole claim. Add a second test pinning the new unconditional rule: `txn.destroy` raises even when `txn.inventory_item.mark_for_destruction` has been called.

### Cross-subsystem concerns raised by this lane

_Named, not solved — the lane was told to stay inside its boundary._

- app/models/maker/sheet.rb:29 and :71-75 carry a seventh verbatim copy of the `project_belongs_to_user` shape, and app/models/maker/task.rb:40 and :61-71 an eighth (polymorphic, with a deliberate blank-type exemption). Any owned-reference registry should eventually cover them; Sheet and Task are not mine to change.
- app/controllers/v1/maker/boms_controller.rb:32-37 and :82-85 — `rollup` maps every line through `BomLine#resolved_target`, which lazily loads `inventory_item` (bom_line.rb:32) and `supplier` (bom_line.rb:41) per line with no eager load, so the endpoint costs O(lines) queries. `bom.lines.includes(:inventory_item, :supplier)` would fix it, but the fix belongs to the controller and CLAUDE.md §14e says query cost must be asserted as constancy in N, never a literal.
- app/models/user.rb:67-68 — the account-deletion cascade's correctness currently depends on the declaration ORDER of two adjacent `has_many` lines. My second finding needs a one-word change there; the file itself is owned elsewhere.
- lib/schema_map.rb:164 records `maker_inventory_transactions.project_id -> maker_projects.id` as an app-level edge, but app/models/maker/project.rb declares no inverse association for it. Harmless today only because the ledger runs no `project_belongs_to_user` validation, so a dangling project_id cannot lock a row — worth knowing before anyone adds one.

---

## S15 — Project domain models

**Lane verdict:** `recommend`

### S15-1 — The two status/timestamp pairs are derived data written by four hand-rolled derivations with two different rules — make the stamp a model-owned projection of `status`

> **COORDINATOR VERDICT — SPLIT.** Task half is LANDABLE NOW — v1/maker/tasks_controller.rb:41 does not permit completed_at. Project half is BLOCKED — v1/maker/projects_controller.rb:34 permits :archived_at and :40 emits it.

- **Category:** state-representation  
- **Lane confidence:** high

**Evidence**

- app/models/maker/project.rb:61-63 — `def archive!` / `update!(status: "archived", archived_at: Time.current)`: the only writer that sets the project pair together.
- app/models/maker/project.rb:69-71 — `def unarchive!` / `update!(status: "active", archived_at: nil)`: the inverse, again the only consistent door.
- app/controllers/v1/maker/projects_controller.rb:34 — `params.require(:project).permit(:name, :slug, :description, :status, :archived_at)`. The controller has NO derivation anywhere (I read all 61 lines): `#create` (line 15-17) and `#update` (line 21-23) pass the params straight to `new`/`update!`. So `PATCH /v1/maker/projects/:id {project:{status:"archived"}}` persists `status="archived", archived_at=NULL`, and `{status:"active", archived_at:"2020-01-01"}` persists a live project carrying an archive stamp. Both are live doors — the sibling test at test/integration/v1/maker/projects_test.rb:57 already PATCHes `status: "paused"` this way.
- app/controllers/projects_controller.rb:181 — the web edit door permits `:status` too (`permit(:name, :description, :status, :cover_node_id)`) and #update at line 130 calls `@project.update(project_params)`, bypassing `archive!` entirely. (No view renders a status field — `grep -rn ':status' app/views/projects/` is empty — so this door is curl-only, unlike the v1 one.)
- app/models/maker/task.rb:44-46 — `def complete!` / `update!(status: "done", completed_at: Time.current)`: derivation site 1 for the task pair.
- app/controllers/v1/maker/tasks_controller.rb:16 — `task.completed_at ||= Time.current if task.status == "done"`: derivation site 2.
- app/controllers/v1/maker/tasks_controller.rb:24-28 — `if attrs["status"] == "done"` → `attrs["completed_at"] = Time.current if task.completed_at.nil?`; `elsif attrs["status"].present?` → `attrs["completed_at"] = nil`: derivation site 3, and it PRESERVES an existing stamp on a redundant done→done PATCH.
- app/controllers/projects/tasks_controller.rb:47-51 — `case attrs["status"] … when "done" then attrs["completed_at"] = Time.current`: derivation site 4, and it OVERWRITES the stamp unconditionally, so re-pressing Done on an already-done task moves its completion time forward. The two doors disagree about the same fact.
- app/controllers/projects/tasks_controller.rb:42 — the file's own comment names the divergence out loud: "`Time.current`, not v1's `completed_at ||=`, reproduces `Maker::Task#complete!` exactly — this is not a fourth spelling of the derivation rule." It is four sites; the comment argues only that this one matches the model's bang method.
- db/schema.rb:295 — `t.datetime "archived_at"` (nullable, no default) beside line 301 `t.string "status", default: "planning", null: false`; db/schema.rb:359 — `t.datetime "completed_at"` beside line 361 `t.string "status", default: "todo", null: false`. Nothing at the DB level ties either pair.
- test/models/maker/project_test.rb:50-55 and :64-73 — the only pair coverage is `archive!` then `unarchive!` round-tripping. Nothing asserts what the pair does when `status` is written directly, which is exactly the reachable path.

**Current complexity / invalid states**

`archived_at` and `completed_at` are pure projections of `status` (nothing computes from them — `grep -rn archived_at app/` returns only the two model writers and the v1 serializer at projects_controller.rb:40; `completed_at` likewise only the writers and the serializer at tasks_controller.rb:46). Yet each pair is written by hand at every door. The task pair has four derivation sites with two semantics; the project pair has zero derivation outside the model plus a permitted `:archived_at` param, so a contradictory pair is reachable through the v1 API today. The state space is `5 statuses × (stamped | unstamped)` where only `archived ⇒ stamped` and `¬archived ⇒ unstamped` are meaningful, and nothing enforces that.

**Proposed representation**

Make `status` the single authority and the timestamp a derived column the model owns. In `Maker::Project`: `before_save :sync_archived_at`, setting `self.archived_at = (status == "archived" ? Time.current : nil) if status_changed?`. In `Maker::Task`: the same shape keyed on `status == "done"` → `completed_at`. Then `archive!` becomes `update!(status: "archived")`, `unarchive!` becomes `update!(status: "active")`, `complete!` becomes `update!(status: "done")`; delete the derivation blocks at v1/maker/tasks_controller.rb:16 and :24-28 and projects/tasks_controller.rb:47-51; drop `:archived_at` from the permit list at v1/maker/projects_controller.rb:34. Guarding on `status_changed?` (rather than on the value) gives the idempotent answer both existing rules were reaching for: a redundant done→done or archived→archived write keeps the original stamp (v1's `||=` behaviour), while a real transition in or out re-derives it (the web's behaviour).

**Why simpler**

One rule in one place instead of four spellings with two semantics, and the invalid combination stops being representable through any door rather than being avoided door-by-door. It also removes the standing asymmetry that `task_params` (v1/maker/tasks_controller.rb:41) already refuses a client-supplied `completed_at` while `project_params` accepts a client-supplied `archived_at`. Explicitly noting the counter-evidence, per the brief: projects/tasks_controller.rb:29-43 argues at length for its current shape — ONE VALIDATED WRITE with the stamp derived in memory from the same params, so a refused write cannot persist a half-pair (the `update_column` bug it records). A `before_save` callback preserves exactly that property: it runs after validation and inside the same save, so a refused write persists nothing. The proposal keeps what that comment protects and removes the thing it could not fix from inside one controller — the other three doors.

**Smallest credible implementation scope**

Two ~4-line private callbacks (one per model), three controller derivation blocks deleted, one permit-list entry dropped, three bang methods shortened. No migration. No data backfill required for correctness, though a one-off backfill of rows already carrying `status="archived", archived_at=NULL` would make the column trustworthy for the desktop client that reads it.

**Affected files**

- `app/models/maker/project.rb`
- `app/models/maker/task.rb`
- `app/controllers/v1/maker/projects_controller.rb`
- `app/controllers/v1/maker/tasks_controller.rb`
- `app/controllers/projects/tasks_controller.rb`

**Regression risks and migration concerns**

Dropping `:archived_at` from v1's permit list is a WIRE change: a desktop client backfilling an imported project's archive date would silently lose it (unpermitted params are ignored, not raised — I found no `action_on_unpermitted_parameters` setting in config/). Check `tinkerex-client` before removing it; if a client does send it, keep the permit and have the callback defer to an explicitly-supplied value on create only. Second risk: `status_changed?` is true on create when the supplied status differs from the column default, so a project created directly as `status: "archived"` starts stamped — a behaviour change from today's NULL, and the intended one, but it will move an existing assertion if any test creates such a row (test/integration/web/projects_flow_test.rb:284 and :379 already pass `archived_at:` explicitly, so a callback keyed on `status_changed?` would overwrite the fixture's value — those two setups need updating or the callback needs a create-time deference).

**Validation required**

Mutation-check both callbacks per §15: after the guards go green, delete the callback body and confirm the new door-level tests go RED. The tests that matter are ones that drive the REAL requests §14e warns about — `PATCH /v1/maker/projects/:id {status:"archived"}` then assert `archived_at` is present (this fails today), and `PATCH /v1/maker/projects/:id {status:"active"}` on an archived project then assert it is nil. For tasks, assert the two doors now agree: PATCH a done task to done twice through v1 and through /projects/:id/tasks/:id and assert the stamp is unchanged in both. Avoid comparing timestamps at `.to_i` (§15's recorded near-miss) — use `travel_to` to separate the setup from the write, or assert nil-vs-present rather than an ordering.

### Cross-subsystem concerns raised by this lane

_Named, not solved — the lane was told to stay inside its boundary._

- V1::Maker::TasksController#task_params (app/controllers/v1/maker/tasks_controller.rb:41) permits :taskable_type and :taskable_id independently, which is what makes the half-orphan row (taskable_id present, taskable_type NULL) reachable — the state app/models/maker/task.rb:50-60 spends twelve lines explaining it must tolerate rather than lock. The model's exemption is right; the shape belongs to the controller's param model, outside this boundary. Naming it, not solving it.
- Maker::Model#print_status is a third derived pair, written by Maker::PrintRun#sync_model_status (app/models/maker/print_run.rb:24-28) via update_column from an after_save/after_destroy, and also directly editable by the user. It is deliberately a convenience default rather than a derived invariant, so it does not have the contradiction the two pairs above do — but it is the same family and lives in the model subsystem, not here.
- app/controllers/projects_controller.rb:181 permits :status on the web edit door while no view renders a status field. Whether that permit should exist at all is a web-layer question.

---

## S16 — File-attachment vocabulary & model catalog

**Lane verdict:** `recommend`

### S16-1 — Name the Project/Model "library-backed catalog record" duck type as one concern, instead of two copies plus two hand-written class lists

> **COORDINATOR VERDICT — REJECTED.** ~50-line concern + DSL + registry to remove ~19 lines shared by exactly two models. Net increase in code and indirection. The duplication is real; this cure is worse. Revisit only if a third implementor appears.

- **Category:** data-structure  
- **Lane confidence:** medium

**Evidence**

- app/models/maker/model.rb:49-51 — `def cover_node_id; self[:cover_node_id].presence || derived_cover_node_id; end`
- app/models/maker/project.rb:46-48 — byte-identical body for the same method on the sibling class
- app/models/maker/model.rb:96-102 — `derived_cover_node_id` sorts `file_attachments` by `[position, id]` then picks image -> model -> first; declared PRIVATE (it sits under `private` at model.rb:79)
- app/models/maker/project.rb:53-59 — the same three-line preference ladder, declared PUBLIC; grep shows no caller outside the two `cover_node_id` overrides, so the visibility split is drift that already happened inside the "identical" pair
- app/models/maker/model.rb:69-77 and app/models/maker/project.rb:77-85 — `ensure_library_folder!(acting_user)` differs only in the root segment (`"Models"` literal vs `Maker::ProjectFolders::ROOT`); the surrounding find-live-node / ensure_path! / update_column(:folder_node_id) body and even the doc comment are identical text
- app/services/maker/attachment_reaper.rb:49-58 — the comment states "`maker_models` carries the identical column with the identical override" and "`covered` is therefore HETEROGENEOUS. Every line below is duck-typed on `[:cover_node_id]` and `update_column` … a future line branching on the class, or reaching for something only `Project` has, breaks the model half SILENTLY"
- app/services/maker/attachment_reaper.rb:59-60 — the pair enumerated by hand: `user.maker_projects.where.not(cover_node_id: [nil, ""]).to_a + user.maker_models.where.not(cover_node_id: [nil, ""]).to_a`
- app/services/library/repo_metadata_purge.rb:198-202 — a SECOND hand-written enumeration of the same pair: `Maker::Project.where.not(cover_node_id: nil)… + Maker::Model.where.not(cover_node_id: nil)…`
- app/models/maker/model.rb:83-94 — `ensure_slug` inlines `.strip.downcase.gsub(/[^a-z0-9]+/, "-").gsub(/\A-+|-+\z/, "")` plus a `-2, -3, …` collision loop
- app/models/maker/project.rb:89-91 — `self.slugify` carries the comment "THE ONE NORMALIZATION. Extracted from #ensure_slug so Maker::ProjectDiscovery can reuse it without a second copy of the regex" — while model.rb:84-85 is that second copy
- app/models/concerns/maker/text_only_rich_text.rb:1-20 — the repo already has the idiom (one concern under app/models/concerns/maker/, included by two models)

**Current complexity / invalid states**

"A maker record that owns a folder in the library and shows one node as its cover" is a real contract with exactly two implementors, but it is not named anywhere. It exists as (1) three method bodies copied between model.rb and project.rb, and (2) two independent literal lists of `[Maker::Project, Maker::Model]` in two sweeps that must both be edited if the contract ever gains a third implementor. The reaper's own comment is the give-away: it documents the duck type in prose and names the failure mode ("breaks the model half SILENTLY") because there is no type to lean on. Drift inside the pair is not hypothetical — `derived_cover_node_id` is already public on one and private on the other, and Project's slug normalization has been extracted to a named single definition while Model still carries the pre-extraction regex inline.

**Proposed representation**

One concern, app/models/concerns/maker/library_backed_record.rb (`Maker::LibraryBackedRecord`), included by Maker::Model and Maker::Project. It carries: the `cover_node_id` override and `derived_cover_node_id` (one visibility, chosen deliberately — private, since nothing calls it externally); `ensure_library_folder!`, parameterised by a class-level `library_root` set in each including class (`library_root "Models"` / `library_root Maker::ProjectFolders::ROOT`); and one slug helper pair so Model stops carrying a second copy of Project.slugify's regex (Model keeps its own `ensure_slug` semantics — disambiguate rather than fail, per its comment at model.rb:81-82 — but composes the shared normalization). The concern also registers its includers, so `Maker::LibraryBackedRecord.includers` replaces both hand-written pairs: `AttachmentReaper#reap!` builds `covered` by mapping over the registry, and `RepoMetadataPurge.referenced` does the same for its pluck. Nothing about the two records' domain difference is unified — status vocabularies, associations, print runs, origin/dismissal all stay where they are.

**Why simpler**

It converts a contract that today lives in a comment into something the code can name, and collapses two hand-maintained class enumerations into one. The reaper's stated hazard ("a future line branching on the class … breaks the model half SILENTLY") becomes structurally hard to hit, because the sweep no longer has a literal list to fall out of sync with the set of classes that actually have covers. It also removes the two live drifts inside the pair (public-vs-private derived reader; a second copy of a regex whose sibling is documented as "THE ONE NORMALIZATION"), and gives the cover preference ladder a single test surface instead of the near-duplicate ladders pinned separately in test/models/maker/model_test.rb:77-100 and test/integration/web/project_cover_test.rb.

**Smallest credible implementation scope**

One new file (~50 lines) under app/models/concerns/maker/; ~35 lines removed from model.rb and ~30 from project.rb; two call sites re-pointed at the registry (attachment_reaper.rb:59-60, repo_metadata_purge.rb:198-202). No migration, no schema change, no controller or view change — every public method keeps its current name and signature.

**Affected files**

- `app/models/maker/model.rb`
- `app/models/concerns/maker/library_backed_record.rb`
- `app/services/maker/attachment_reaper.rb`
- `app/models/maker/project.rb`
- `app/services/library/repo_metadata_purge.rb`

**Regression risks and migration concerns**

Owned from THIS side, and it does reach into Maker::Project, which is S15's file — S15 should be consulted before landing. The repo's strongest counter-argument is its own recurring warning that agreement across implementors is samples, not identity (§14a says this three times about `scannable`/`port_writable`/`dir_deletable`). That warning is about predicates that ASK DIFFERENT QUESTIONS while happening to agree; here the two bodies answer the literally same question about the same column, and attachment_reaper.rb:49 already asserts they are one rule ("the identical column with the identical override"). Still, an implementor should preserve the one place they genuinely differ — the library root segment — as an explicit per-class declaration rather than deriving it from the class name, or a rename of either model silently changes where files land on a user's NAS. Second risk: `ensure_library_folder!` calls the port and is exercised on a real share library (test/models/maker/model_test.rb:6-10 spells out why that suite pins a fresh share), so the extraction must not change when `update_column(:folder_node_id, …)` fires. Third: the slug half is the weakest limb — if it complicates the concern, drop it and keep the cover + folder halves.

**Validation required**

Existing tests already cover both halves independently and should stay green unchanged: test/models/maker/model_test.rb:77-117 (cover ladder + ensure_library_folder! creating Models/<slug>), test/integration/web/project_cover_test.rb (chosen-vs-derived, cover_clear), test/services/maker/attachment_reaper_test.rb:94-173 (both the project and model cover arms, including the tombstone-grace arm at :163-170), test/services/library/repo_metadata_purge_test.rb:248-249 (both cover columns pinned as references). Mutation-check the registry specifically, per §15: remove Maker::Model from the concern's includers and confirm attachment_reaper_test.rb's model-cover tests go RED — if they stay green the registry is not carrying the weight the two literal lists carried. Also assert the includers set is NON-EMPTY where it is consumed (§14e: "a guard that scans a directory dies silently when the directory leaves" — a registry that resolves to [] satisfies every existing assertion perfectly).

### S16-2 — `maker_file_attachments.version_id` is an inert content pin — nothing in this app writes it, nothing reads it, and nothing refreshes it

> **COORDINATOR VERDICT — BLOCKED.** Cross-repo. version_id is a v1 create param and a key in three response bodies; tinkerex-client cannot be grepped from here (14j). Prefer the derived-value variant, or defer.

- **Category:** state-representation  
- **Lane confidence:** medium

**Evidence**

- db/schema.rb:164 — `t.string "version_id"` on `maker_file_attachments`, nullable, no default, no index
- app/models/maker/file_attachment.rb:240-241 — the model's ONLY validations are `node_id` presence and `role` inclusion; `version_id` has no validation, no writer, no reader and no mention anywhere in the 243-line file
- lib/schema_map.rb:116-120 — describes the column as "`FileLayer::FileInfo#content_token` under a backend-neutral name", i.e. a real version UUID on chunk_remote and a CONTENT HASH on share/s3 — a value that changes every time the file's bytes change
- app/services/file_layer/file_info.rb:4-8 — "It is the value stored in the `version_id` column on maker_previews / maker_file_attachments"
- app/services/maker/project_intake.rb:564-566 — the row hash inserted by the project sweep is `{user_id, attachable_type, attachable_id, node_id, role}`; no version_id
- app/services/maker/attach_to_project.rb:337-339 — same five keys, no version_id
- app/services/maker/model_intake.rb:111-113 — same, plus position/timestamps; no version_id
- app/controllers/models/attachments_controller.rb:22-24 — `create_or_find_by!(user:, node_id:) { |a| a.role = … }`; sets role only
- app/controllers/projects/uploads_controller.rb:37 — `role: role_for(file.original_filename, target)`; no version_id
- app/controllers/v1/maker/file_attachments_controller.rb:33 and :37 — the ONLY writer is an optional strong-param a v1 client may send, and the only reader echoes it straight back in JSON
- app/controllers/v1/maker/items_controller.rb:73 — a second echo-only serializer
- grep over test/ finds exactly one hit for an attachment version_id — test/schema_map_test.rb:84, which asserts the column is NOT drawn as an edge; no test anywhere creates or asserts a value in it

**Current complexity / invalid states**

The column reads as a version pin: its name, CLAUDE.md §5 and lib/schema_map.rb all describe it as the backend-polymorphic content token identifying which bytes this attachment refers to. In practice it is NULL for every row this app creates (six independent server-side writers all omit it), it is set only if a v1 API client volunteers it, and once set nothing ever updates it when the file's content changes — an attachment written against v1 of a file keeps that token forever while every surface renders the file's current bytes. The contrast with the sibling column is the tell: `maker_previews.version_id` is load-bearing and actively maintained (GeneratePreviewJob does compare-and-set on it at generate_preview_job.rb:87 and :171, and reads bytes through it at :110). This one has no such consumer, so it is a nullable field whose only reachable states are "NULL" and "a stale token nothing will refresh".

**Proposed representation**

Pick one honest representation and drop the third state. Preferred: remove the column (a drop migration, following the DropRetiredSyncEngineTables precedent in §10 — forward-only, never a rewrite) and remove `:version_id` from the strong params at v1/maker/file_attachments_controller.rb:33 and from the three JSON serializers. If the tinkerex-client wire turns out to depend on the field being present in responses, the alternative — strictly better than the status quo — is to keep the KEY and serialize it as a live read of the node's current `content_token` via the port, so the value means "the content this attachment currently points at" rather than "whatever a client once posted". Either way `maker_file_attachments` stops carrying a column that can hold a lie.

**Why simpler**

It removes a nullable field whose documented meaning and actual behaviour disagree, on the model that S16 owns. A future reader of file_attachment.rb (or of schema_map's content_token note) can reasonably conclude that attachments are version-pinned and build on that; the column silently will not support it, because no writer maintains it. That is the same shape as this repo's recorded failure mode — a plausible-looking representation with no mechanism behind it — and deleting it is cheaper than the feature that discovers it the hard way.

**Smallest credible implementation scope**

One drop migration; delete `:version_id` from one permit list and three serializer hashes; update the two prose references (lib/schema_map.rb:116-120 and app/services/file_layer/file_info.rb:7) so they name only `maker_previews`. No behaviour changes in any web path — every one of them already writes NULL. Roughly 10 edited lines plus the migration.

**Affected files**

- `app/models/maker/file_attachment.rb`
- `db/migrate/`
- `app/controllers/v1/maker/file_attachments_controller.rb`
- `app/controllers/v1/maker/items_controller.rb`
- `app/controllers/v1/maker/projects_controller.rb`
- `lib/schema_map.rb`
- `app/services/file_layer/file_info.rb`

**Regression risks and migration concerns**

The real risk is the WIRE, not this repo: `version_id` sits in the v1 maker API's create params and in three response bodies, and §14j/§3 put the desktop client in chaim354/tinkerex-client, which this repo cannot grep. CONFIRM there before dropping — this is exactly the "device auth is duplicated across the two repos and nothing checks that agreement" situation §14j warns about, and a removed response key is a silent client-side nil rather than an error. If confirmation is not available, do the derived-value variant instead of the drop, or do nothing: the status quo is misleading but not currently broken. Second, smaller risk: test/schema_map_test.rb:84 names the column explicitly and must be updated in the same change, or a passing assertion quietly becomes vacuous (§14e: a guard whose subject leaves goes on passing over nothing).

**Validation required**

Before changing anything, re-run the reachability check that produced this finding — `grep -rn 'version_id' app lib test | grep -i attach` — and confirm the only hits are the permit list, the three serializers and schema_map_test.rb:84. Then confirm the field is genuinely never populated on the web path by driving a real request (§14e: "the suite being green is not evidence a guard works … drive the real request") — upload through Projects::UploadsController and through Models::AttachmentsController and assert `version_id` is nil on the created row BEFORE the removal, so the removal is provably a no-op rather than argued to be one. After the migration, `bin/ci` with all three backend legs reporting identical run counts, since maker_file_attachments is exercised on share, s3 and chunk_remote alike.

### Cross-subsystem concerns raised by this lane

_Named, not solved — the lane was told to stay inside its boundary._

- Maker::Project (S15) owns half of finding 1 — the duplicated cover_node_id / derived_cover_node_id / ensure_library_folder! bodies and the `self.slugify` single-normalization comment live in app/models/maker/project.rb. I own the recommendation from the Model side, but the concern cannot land without S15's agreement on which visibility and which slug seam survive.
- Library::RepoMetadataPurge.referenced (app/services/library/repo_metadata_purge.rb:198-202) is the second hand-written enumeration of the Project+Model cover pair. Naming it here as the other consumer of finding 1's registry; not proposing changes to that service's own logic.
- The v1 maker API serializers (app/controllers/v1/maker/file_attachments_controller.rb, items_controller.rb, projects_controller.rb) are the only surface that touches maker_file_attachments.version_id, and the consumer is the desktop client in chaim354/tinkerex-client. Finding 2 cannot be executed without a check in that repo; that check is outside this audit.
- Maker::DeadNodes (app/services/maker/dead_nodes.rb, S10) — read as context for AttachmentReaper. Its reapable?/index split is sound and its single-definition rule is explicit; I deliberately declined to propose pushing the sweep into SQL because that would create the second copy of reapable? the module exists to prevent.
- Maker::Preview also carries a version_id column, but that one is live (GeneratePreviewJob compare-and-set) and is S-other's file; finding 2 is scoped to the attachment column only.

---

## S17 — Project-folder intake & discovery

**Lane verdict:** `recommend`

### S17-1 — Collapse ProjectIntake's `dry_run` + `move` boolean pair into one run mode, and let `Result#status` report it

> **COORDINATOR VERDICT — ACCEPT.** Verified against the tree; no narrowing applied.

- **Category:** state-representation  
- **Lane confidence:** medium

**Evidence**

- app/services/maker/project_intake.rb:178 — `def self.for_project(user:, project:, dry_run: false, move: true)`: two independent booleans, so four combinations are constructible while only three are meaningful. `(dry_run: true, move: false)` is representable and has no caller and no test — it would mean "count would-be attachments, plan no moves", a mode nobody designed.
- app/services/maker/project_intake.rb:238 and :245 — `refused = !dry_run && inbox_total > cap` then `for_project(user:, project:, dry_run:, move: !refused)`. The fact being expressed ("a dry run always plans its moves") reaches the callee as a double negative threaded through a second, independent flag.
- app/services/maker/project_intake.rb:290-298 — `for_node` computes `inbox > cap`, emits `Rails.logger.warn("...attaching but NOT filing #{project.slug}...")`, then calls `for_project(user:, project:, move: inbox <= cap)`. The decision exists only in the log line; nothing about it survives into the value returned to the caller.
- app/services/maker/project_intake.rb:400, :408, :424 — three `Result.new` sites. Line 408 (`unless @move`) and line 424 (filed everything) both carry `status: :ok`. So `:ok` covers both "this project's inbox is filed" and "filing was deliberately skipped"; only `:no_folder` is distinguishable.
- app/controllers/concerns/project_folder_intake.rb:75-81 — `intake_project_folder` hands that same Result to the three browser-facing doors; :146-151 `project_intake_sentence` inspects only `skips`, so an attach-only result falls to the plain `"#{lead}."` branch.
- app/controllers/projects/uploads_controller.rb:54-55 — `intake_result = intake_project_folder(info.node_id)` then `notice: project_intake_notice(intake_result, file.original_filename)`. An upload into a project sitting over `eager_max_moves` therefore flashes "Uploaded x." — byte-identical to a fully filed upload, which is the same missing-feedback shape the concern's own header (project_folder_intake.rb:36-51) calls "A REAL REGRESSION, NOT A HARMLESS ONE" for the conflict case.
- test/services/maker/project_intake_test.rb:1170 — "for_node respects the eager cap, so a large backlog stays attach-only" asserts `result.moved == 0` and `result.attached == 4`; there is no status to assert, so the test infers the mode from a zero count, which is also what a project with an empty inbox produces.

**Current complexity / invalid states**

The run mode is spread across two orthogonal booleans (`@dry_run`, `@move`) set by three entry points using three different expressions (`move: true` default, `move: !refused`, `move: inbox <= cap`), then erased from the result. Consequences visible today: (1) an unreachable-but-representable fourth combination; (2) `!dry_run && …` / `move: !refused` double negation at project_intake.rb:238-245; (3) `Result#status == :ok` conflates "filed" with "deliberately did not file", so the only record of an eager-cap refusal is a `Rails.logger.warn` (project_intake.rb:292-296) its sole caller cannot see, and three browser doors report a capped upload exactly as they report a filed one.

**Proposed representation**

One kwarg on `for_project`/`#initialize`: `mode:` in `{ :file, :attach_only, :plan }` (`:file` default). `for_user` passes `dry_run ? :plan : (refused ? :attach_only : :file)`; `for_node` passes `inbox > cap ? :attach_only : :file`. `#attach` checks `mode == :plan` where it reads `@dry_run` (project_intake.rb:568), `#place` the same at :719, `#call` checks for `:file` at :408 — the same three branch points, keyed on one value. Then widen `Result#status` to `:ok | :no_folder | :filing_capped` (or add a `mode:` member) so line 408's construction records why nothing was filed, and `ProjectFolderIntake#project_intake_sentence` can say so through the channel it already has for `:conflict`.

**Why simpler**

One value replaces a two-flag product whose invalid corner is prevented only by nobody happening to construct it. The `!dry_run` / `!refused` inversion disappears — each entry point names the mode it wants rather than computing a negation of a negation. And what `for_node` already computes and logs ("attaching but NOT filing") stops being a log-only side channel: it becomes part of the value its one caller already reads, removing the need for a future reader to rediscover, as the concern's header did for the conflict case, that a door reports success for something that silently did not happen.

**Smallest credible implementation scope**

Smallest credible slice is the representation change alone, no behaviour change: replace the two kwargs with `mode:` at project_intake.rb:178, :218-249, :286-298, :391-395, and the three reads at :408, :568, :719. Leave `Result` untouched in that slice; ship the `status` widening (and the flash sentence that consumes it) as a second, separately reviewable step, since only that half changes what a user sees.

**Affected files**

- `app/services/maker/project_intake.rb`
- `lib/tasks/projects.rake`
- `app/controllers/concerns/project_folder_intake.rb`
- `test/services/maker/project_intake_test.rb`

**Regression risks and migration concerns**

`for_project`'s kwargs are public API used by the rake task (lib/tasks/projects.rake:37 passes `dry_run:`) and by tests at project_intake_test.rb:363, :665, :675 — a mechanical but non-local rename. The second slice changes a user-visible flash on three doors, so it needs the care the conflict sentence got. Nothing in docs/invariants/project-intake.md argues for the two-boolean shape: its "TWO CAPS, DELIBERATELY NOT ONE" rule is about `MAX_MOVES` and `EAGER_MAX_MOVES` staying separate numbers, which this leaves entirely alone — the mode is the outcome of comparing an inbox to whichever cap applies, not a merge of the caps. Guard the distinction by mutation: collapse the two caps and the independence tests at project_intake_test.rb:1123 and :1138 must still go red.

**Validation required**

Existing coverage is good and mostly sufficient: test/services/maker/project_intake_test.rb:361 (`dry_run` writes nothing), :663 (`move: false` attaches without filing), :673 (a dry run creates no category folder), :1170 and :1183 (for_node over and under the eager cap), :1200 (the over-cap query-count budget), :1123 and :1138 (the two caps are independent), plus test/integration/web/project_folder_intake_test.rb and project_upload_attach_test.rb for door behaviour. Additional validation needed: a test asserting `mode: :plan` still plans moves (the case `!dry_run &&` encodes today), and — for the second slice — a door-level test that an over-eager-cap upload's flash differs from a filed upload's, mutation-checked by forcing `mode: :file` and confirming it goes red.

### S17-2 — Key `Result#skips` entries by `node_id` (and carry the destination folder) instead of by filename

> **COORDINATOR VERDICT — ACCEPT.** Verified against the tree; no narrowing applied.

- **Category:** index-or-collection  
- **Lane confidence:** medium

**Evidence**

- app/services/maker/project_intake.rb:32 — `Result = Data.define(:attached, :moved, :skipped, :skips, :plan, :status)`, with the header at :29-31 defining `skips` as "[name, reason] pairs, one per file #file_all did not move".
- app/services/maker/project_intake.rb:621-628 — inside `#file_all`'s loop the whole `node` is in hand, and it records `skips << [ node.name, outcome ]` / `plan << [ node.name, outcome ]`, discarding `node.node_id`. Same at :637 for the FetchError arm (`unreached.each { |node| skips << [ node.name, :unavailable ] }`).
- app/controllers/concerns/project_folder_intake.rb:103-107 — `left_unfiled_by_conflict?` answers the caller's question by string comparison: `intake_result.skips.any? { |skipped_name, reason| reason == :conflict && skipped_name == name }`.
- app/controllers/concerns/project_folder_intake.rb:93-102 — the comment names the resulting hole in as many words: "two DIFFERENT loose files that happen to share this node's exact name, both skipped with :conflict in the SAME sweep, cannot be told apart by name alone". It defends the helper given the data ("NAME IS ALL Result#skips HAS"), not the choice of what the Result carries.
- app/controllers/concerns/project_folder_intake.rb:146-151 — `project_intake_sentence` recomputes the destination with `Maker::ProjectFolders.folder_for(filename)`, re-deriving a value `#place` already computed at project_intake.rb:711 (`dest = Maker::ProjectFolders.folder_for(node.name)`) immediately before the collision it is reporting.
- app/controllers/concerns/project_folder_intake.rb:160-162 — `unfiled_by_conflict` scans `names` × `skips` and returns a name, which line 147 then re-scans `skips` for via `left_unfiled_by_conflict?`; the addon door at app/controllers/tools/addons_controller.rb:558-559 drives exactly that round trip (`project_intake_sentence(..., unfiled_by_conflict(intake_result, files.map(&:name)))`).
- app/controllers/tools/addons_controller.rb:552 — the same door already holds node_ids (`intake_project_folder(addon_files.first&.node_id)`; `addon_files` are the `maker_addon_files` rows returned by `Maker::Addons::LibraryOutput.write`, app/services/maker/addons/library_output.rb:49-57, each carrying `node_id`). app/controllers/files_controller.rb:463 and app/controllers/projects/uploads_controller.rb:54 likewise hold `info.node_id`.

**Current complexity / invalid states**

The sweep records outcomes under a key (`name`) that is not unique within the collection it indexes, while holding the unique key (`node_id`) at the moment of recording. Three helper methods in ProjectFolderIntake exist to work around that: an existence test by name, a plural variant of it, and a sentence builder that re-derives the destination folder from the name because the Result does not carry it. The addon door pays three passes over `skips` for one question, and the concern carries ~15 lines of comment (project_folder_intake.rb:88-102) explaining an ambiguity the sweep created by dropping the id.

**Proposed representation**

`Skip = Data.define(:node_id, :name, :reason, :folder)` (`folder` nil for reasons with no destination), with a matching `Filed = Data.define(:node_id, :name, :folder)` for `plan`. `#file_all` builds these from the `node` it already holds and the `dest` `#place` already computed. `ProjectFolderIntake` then collapses to `conflict_for(intake_result, node_id)` returning the `Skip` or nil, and `project_intake_sentence(lead, skip)` reading `skip.folder`; the plural door becomes `conflict_for(result, node_ids)` with `node_ids.include?`.

**Why simpler**

The question the three doors actually ask — "was the file I just wrote left at the root?" — becomes answerable exactly, instead of approximately with a paragraph explaining when the approximation is wrong. Two of the three concern helpers merge into one, the name-then-re-scan round trip at addons_controller.rb:559 becomes a single lookup, and `folder_for` stops being computed twice (once in `#place`, once in the flash) for one fact — the same "prediction and behaviour cannot disagree" argument docs/invariants/project-intake.md already makes for `destination_for` taking its folder name from `ProjectFolders.folder_for`, applied to the reporting path.

**Smallest credible implementation scope**

Smallest slice: change only `skips` (leave `plan` as pairs), add `node_id` and `folder`, and switch `left_unfiled_by_conflict?` / `unfiled_by_conflict` to node_id keying at the three doors. `plan`'s conversion and the rake task's printing can follow separately.

**Affected files**

- `app/services/maker/project_intake.rb`
- `app/controllers/concerns/project_folder_intake.rb`
- `app/controllers/tools/addons_controller.rb`
- `app/controllers/files_controller.rb`
- `app/controllers/projects/uploads_controller.rb`
- `lib/tasks/projects.rake`
- `test/services/maker/project_intake_test.rb`

**Regression risks and migration concerns**

`skips`/`plan` are destructured as arrays in places that would break on a Data: lib/tasks/projects.rake:49-50 (`result.plan.each { |name, folder| … }`, `result.skips.each { |name, reason| … }`) and ~8 assertions in test/services/maker/project_intake_test.rb (:530, :592, :606, :657, :752-753, :828-829). Data does not destructure into block params the way a two-element Array does, so each must be updated — mechanical, but the rake-task failure would be a NoMethodError at print time in a path no gate runs. Also leave `Maker::ProjectIntake#place`'s String-or-Symbol return union exactly as it is (defended at project_intake.rb:608-612); only what `#file_all` records changes.

**Validation required**

Existing: test/services/maker/project_intake_test.rb's skip assertions (:530 `:model_bundle`, :592 and :606 `:conflict`, :657 `:bad_name`, :752-753 and :828-829 the FetchError-abort arm), test/integration/web/project_upload_attach_test.rb:82 ("a duplicate filename is no longer refused, and the flash now says where the second copy landed" — asserts the full flash string, so it pins that the folder read off the Skip matches what was recomputed before), test/integration/web/project_folder_intake_test.rb, and test/controllers/tools/addons_controller_test.rb:1100 (the addon door's conflict path). Additional validation required: the case the current shape cannot answer — two distinct loose files sharing one name, both skipped `:conflict` in one sweep, asserting the flash reports only the uploader's own node; mutation-check by keying `conflict_for` back on `name` and confirming it goes red.

### Cross-subsystem concerns raised by this lane

_Named, not solved — the lane was told to stay inside its boundary._

- Tools::AddonsController#resolve_placements (app/controllers/tools/addons_controller.rb:917-930) calls Maker::ProjectIntake.destination_for once per file in a save, and every file in a save shares one parent_node_id — so the maker_projects lookup (project_intake.rb:168) and, for same-category outputs, the category-folder lookup (:172) repeat per file: up to 3N queries where 1 + one-per-distinct-category + 1 would do. A batch `destinations_for(user:, parent_node_id:, names:)` would belong on the intake side but the call site is the addon door; N is small today, so this is a note, not a recommendation.
- Maker::ProjectIntakeJob.sweep_all! (project_intake_job.rb:49-53), Maker::ProjectDiscoveryJob.sweep_all! (project_discovery_job.rb:48-52) and Maker::ModelIntakeJob share a byte-identical `return if FileLayer.current.capabilities.scannable?; User.find_each { perform_later(user_id: user.id) }` plus identical `discard_on` and `limits_concurrency` declarations. ModelIntakeJob is outside this boundary and each file argues its own copy, so I am naming rather than proposing an extraction.
- Maker::ProjectIntake.owning_project (project_intake.rb:337-352, MAX_DEPTH 32, one query per level) and Maker::AttachToProject#walk_for_marker (attach_to_project.rb:246-257, MAX_ANCESTOR_WALK 64, two queries per level) walk the same parent chain of the same node during one eager nudge, with different bounds and no shared ancestor resolver; Library::RepoMetadataPurge:67 carries a third copy of the bound. Real project-folder depths are 2-3 so there is no material cost today, but the divergent constants are worth knowing about.

---

## S18 — Model intake & shelves

**Lane verdict:** `recommend`

### S18-1 — LibraryTree holds every dir in memory but exposes no path index, so both callers re-query the same rows and rebuild every path themselves

> **COORDINATOR VERDICT — ACCEPT.** Verified against the tree; no narrowing applied.

- **Category:** index-or-collection  
- **Lane confidence:** high

**Evidence**

- app/services/maker/library_tree.rb:13-17 — the constructor plucks `(node_id, parent_node_id, name)` for EVERY live dir into `@dirs`, i.e. the complete dir id set and every name are already in memory after one query.
- app/services/maker/model_intake.rb:162 — `shelf_dir_ids` issues a SECOND query for data the tree already holds: `user.nodes.present.where(kind: "dir").pluck(:node_id)`, then line 163 calls `tree.path_for(dir_id)` for each and line 164 skips nil.
- app/controllers/shelves_controller.rb:62-65 — `decorate` issues the SAME pluck a third time (`ids = current_user.nodes.present.where(kind: "dir").pluck(:node_id)`) and does the identical `ids.filter_map { |id| @tree.path_for(id) }` derivation, behind a `@tree_paths ||=` memo whose comment (lines 58-61) says the memo is load-bearing because otherwise the page costs one pluck per shelf.
- app/services/maker/library_tree.rb:22-34 — `path_for` walks the parent chain from scratch on every call and memoizes nothing, so building all dir paths is O(dirs × depth) with shared prefixes re-walked, and that whole sweep is performed independently by each of the two callers above.
- app/services/maker/model_intake.rb:187 — `owner_key` rebuilds a full path only to throw it away: `tree.path_for(dir_id).to_s.split("/").last`, recovering a name that `LibraryTree::Entry` already stores (library_tree.rb:11 `Entry = Data.define(:node_id, :parent_node_id, :name)`).
- test/integration/web/page_query_budget_test.rb:147-161 — `shelves#index does not grow with shelves or directories` asserts CONSTANCY via `assert_constant_queries`, not a literal count; test/services/maker/model_intake_test.rb:128-140 likewise asserts `assert_equal small, big`. Removing a query at either site cannot break either guard.

**Current complexity / invalid states**

"the set of live dir paths" is a derived index that nothing owns. It is rebuilt from raw rows at two call sites in two different spellings (a Set of matching ids in the sweep, an Array of path strings plus `""` in the controller), each preceded by its own redundant pluck of rows `LibraryTree` already loaded. The controller has to defend the cost with a hand-rolled `@tree_paths ||=` memo inside a `map`, and a comment explaining that the memo is not a micro-optimisation. A third spelling of "walk up to get a name" exists inside `owner_key`, which builds a whole path string to take its last segment.

**Proposed representation**

One lazily-built, memoized index on `Maker::LibraryTree`: `#paths -> { node_id => path }` covering exactly the dirs whose chain resolves (an unresolvable chain is simply ABSENT — the same answer both callers already produce with `next if path.nil?` / `filter_map`), built by walking `@dirs` once with each entry's parent path memoized, plus `#name_of(node_id)` returning `@dirs[id]&.name`. Then: `shelf_dir_ids` becomes a select over `tree.paths` with no query of its own; `ShelvesController#decorate` becomes `matches = @tree.paths.values + [""]` hoisted into `#index`, and the `@tree_paths` memo and its justification comment disappear; `owner_key`'s title becomes `tree.name_of(dir_id)`.

**Why simpler**

The index moves to the object whose stated job is to BE the index (library_tree.rb:2-9 calls itself "an in-memory index of one user's live DIRECTORY nodes, built with ONE pluck"), so the two callers stop re-deriving it and stop re-querying rows that are already loaded. Two queries disappear, the controller's load-bearing memo becomes structural rather than a convention a future edit can drop, path building goes from O(dirs × depth) repeated per caller to O(dirs) once per tree, and the path-rebuild-to-get-a-name in `owner_key` becomes a hash lookup. No invariant in docs/invariants/model-intake.md is touched: the cycle guard and the `:broken` sentinel stay exactly where they are, and the nil-is-an-answer rule is preserved by omission from the index.

**Smallest credible implementation scope**

~30-40 lines across three files: add `#paths` and `#name_of` to app/services/maker/library_tree.rb (path memoization inside the existing `each_ancestor`-based walk); rewrite `ModelIntake.shelf_dir_ids` (app/services/maker/model_intake.rb:159-170) to take only `(tree, patterns)`; hoist the match list in app/controllers/shelves_controller.rb:57-68 into `#index`; change the title expression at model_intake.rb:187.

**Affected files**

- `app/services/maker/library_tree.rb`
- `app/services/maker/model_intake.rb`
- `app/controllers/shelves_controller.rb`

**Regression risks and migration concerns**

The nil/`:broken` semantics are the whole risk: a dir whose chain is broken must be ABSENT from `#paths`, never present with a partial or sentinel-derived path — the exact failure library_tree.rb:25-29 warns about, where `:broken` answers `.name` and becomes an ordinary-looking segment. A memoizing walk must therefore mark a broken chain's whole visited prefix unresolvable, not cache a half-built path. Second risk: `#paths` must stay lazy so `LibraryTree.new` remains the single pluck that test/services/maker/library_tree_test.rb:62-66 measures. Third: `shelf_dir_ids` currently takes `user` only for that pluck; dropping the parameter is a signature change to a `private_class_method`, no external callers (verified by grep — the only references to `shelf_dir_ids` are its definition and its one call at model_intake.rb:128).

**Validation required**

Existing guards cover the behaviour: test/services/maker/model_intake_classify_test.rb (the whole nearest-shelf table, including the wildcard case at line 80 and the broken-chain skips), test/services/maker/library_tree_test.rb:36-59 (both sentinel tests, already mutation-checked), test/services/maker/model_intake_test.rb:128-140 and page_query_budget_test.rb:147-161 (constancy). Add one test asserting `tree.paths` omits an unresolvable dir (the existing `d-dead` / `d-dead2` fixtures in library_tree_test.rb give it for free), and mutation-check it by making the memo cache a partial path for a broken chain — it must go red. Also assert the two sweeps' query counts DROP by one each, so the removed pluck is proven removed rather than merely believed.

### S18-2 — ModelIntake::Plan is six parallel collections over two different key spaces, three of which are deliberately allowed to disagree

> **COORDINATOR VERDICT — ACCEPT.** Verified against the tree; no narrowing applied.

- **Category:** data-structure  
- **Lane confidence:** medium

**Evidence**

- app/services/maker/model_intake.rb:23-25 — `Plan = Data.define(:owners, :model_keys, :dir_keys, :titles, :names, :skips)`; `owners` and `names` are keyed by FILE node_id, `titles`/`dir_keys`/`model_keys` by MODEL key, and `files_for(key) = owners.select { |_file, owner| owner == key }.keys` is a full scan of every owned file per call.
- app/services/maker/model_intake.rb:145-149 — `classify` writes five of them side by side per file (`owners[node_id] = key`, `titles[key] = title`, `names[node_id] = name`, `dir_keys << key if tree.dir?(key)`, `model_keys << key if role == MODEL_ROLE`), so the invariant "every key in `owners` has a title and every file has a name" is maintained only by those five lines staying in step.
- app/services/maker/model_intake.rb:154 — `owners.select! { |_file, key| model_keys.include?(key) }` prunes `owners` AFTER the fact and prunes nothing else, so the shipped Plan carries `names` entries for files nothing owns and `titles`/`dir_keys` entries for keys that are not models. Harmless today only because every consumer enters through `owners`.
- app/services/maker/model_intake.rb:106-113 — `attach_all` reconstructs the join by hand: iterate `plan.owners`, look the model up in a third hash, then cross-reference `plan.names[file_id]` to derive the role.
- app/services/maker/model_intake.rb:84 and 90 — model creation does the same cross-map dance for one row: `plan.titles.fetch(key)` and `plan.dir_keys.include?(key) ? key : nil`.
- test/services/maker/model_intake_classify_test.rb:47,63,67,78,102 — `files_for` is exercised only by tests (grep finds no app/lib caller), and line 59-63's comment records that the `owners.select!` filter at line 154 was mutation-checked green until an assertion about `files_for("f-notes")` was added.

**Current complexity / invalid states**

One conceptual record — "a candidate model: its key, its title, whether it is a folder, and the files it claims" — is spread across four collections plus a Set of which keys survived, assembled per file and then partially pruned. Nothing structurally prevents the states that pruning leaves behind (a title for a non-model key, a name for an unowned file), and answering "which files does this model claim" costs a scan of the whole library's owned files.

**Proposed representation**

Build the plan grouped by model key: a mutable `groups[key] = { title:, dir:, files: { file_id => name }, model: false }` accumulated in the same single pass, `groups.select! { |_, g| g[:model] }` in place of the `owners.select!` at line 154, and a `Plan = Data.define(:models, :skips)` whose `models` is that hash frozen into per-model `Data` values. `model_keys` becomes `models.keys`, `files_for(key)` becomes an O(1) `models[key].files.keys`, and `attach_all` iterates `models` → `files` directly, taking each file's name from the group it is already inside.

**Why simpler**

The two key spaces stop being interleaved: files live inside the model that owns them instead of in a sibling map joined by hand at three call sites. The post-hoc filter becomes a single reject over models, which drops each unclaimed key's files WITH it rather than leaving stale entries in `names`, so the class of state the current shape tolerates stops existing. `files_for` stops being a linear scan. `attach_all` and the create loop lose their cross-map lookups.

**Smallest credible implementation scope**

Contained to app/services/maker/model_intake.rb — the `Plan` definition (lines 23-25), `classify` (lines 125-156), `attach_all` (lines 104-121) and the create loop's two field expressions (lines 84, 90). Roughly 40 lines rewritten, no other file touches `Plan` (grep: `files_for`/`model_keys`/`plan.` appear only in this file and its tests).

**Affected files**

- `app/services/maker/model_intake.rb`

**Regression risks and migration concerns**

docs/invariants/model-intake.md names `plan.titles.fetch(key)` explicitly ("HAS NO DEFAULT ON PURPOSE" — `fetch(key, key)` would ship a model titled `d-enc`). Attaching the title to the model record satisfies that concern by construction rather than by discipline, but the doc bullet must be rewritten in the same change or it becomes a citation pointing at a map that no longer exists — a doc-honesty failure this repo treats as a real cost. Second risk: the grouped build changes the ORDER of rows handed to `insert_all` (from file-discovery order to model order); nothing asserts row order, and creation order is separately determinised by the `.sort` at line 73, but that should be stated rather than assumed. Third: `Data` is immutable, so grouping must accumulate in plain hashes and freeze at the end — a half-conversion that tries to mutate a `Data` will simply not work, which is a loud failure rather than a quiet one.

**Validation required**

test/services/maker/model_intake_classify_test.rb is a table over exactly this structure and should pass unchanged, including the load-bearing `assert_empty plan.files_for("f-notes")` at line 63 whose comment records that it is the only assertion that catches deletion of the owners filter — mutation-check it again after the change by removing the `groups.select!`, which must go red. test/services/maker/model_intake_test.rb's steady-state query-constancy test (lines 128-140) and the import-origin tests (lines 168-178) cover the write path. Additionally assert that a plan contains no entry for a key with no model-role file, which is now a structural property and cheap to state.

### Cross-subsystem concerns raised by this lane

_Named, not solved — the lane was told to stay inside its boundary._

- Library::RepoMetadataPurge carries its own ancestor-to-path builder with its own cache (app/services/library/repo_metadata_purge.rb:208-219, `path_for(node, cache)`), a third implementation of the walk LibraryTree already owns. Naming only — it is outside S18 and has different tombstone semantics.
- Maker::ProjectDiscovery comments (app/services/maker/project_discovery.rb:86) that `parent_node_id: nil` is "the representation Library::Reconciler and Maker::LibraryTree both use", i.e. the root-is-nil convention is asserted in prose across at least three subsystems with no shared constant. Not proposing a change here.
- Both S18 callers evaluate `Maker::Shelf.matches?` (app/models/maker/shelf.rb:35-41, S16) in a nested loop over patterns x dirs — model_intake.rb:161/166 and shelves_controller.rb:66. A pattern-side index (e.g. bucketing patterns by segment count) would cut that, but Shelf is S16 and the current cost is bounded by dir count, so I did not pursue it.

---

## S19 — Addon registry, source, host & library output

**Lane verdict:** `recommend`

### S19-1 — Registry.all carries two representations of the index at once — built Addons and the raw manifest array — so the states_key consent decision re-derives shares_states_with from the raw hash while the typed member it duplicates has no reader

> **COORDINATOR VERDICT — ACCEPT.** Verified against the tree; no narrowing applied.

> **Schema gap in this entry:** `category` field absent.

- **Category:** _(not recorded)_  
- **Lane confidence:** high

**Evidence**

- app/services/maker/addons/registry.rb:88-93 — `all` builds `index = manifests` (raw Array of Hashes), maps it through `build`, then filters with `states_key_permitted?(addon, index)`, passing the RAW array alongside the built Addon. Both representations are live in one three-line method.
- app/services/maker/addons/registry.rb:158 — `build` already normalizes the field: `shares_states_with: Array(manifest["shares_states_with"]).map(&:to_s)`, with a comment flagging `Array()` as "leniency rather than validation".
- app/services/maker/addons/registry.rb:239-241 — the consent check ignores that member and redoes the work against the raw hash: `target = index.find { |m| m.is_a?(Hash) && m["key"].to_s == addon.states_key }` then `build(target) && Array(target["shares_states_with"]).map(&:to_s).include?(addon.key)`. `build` is therefore invoked a SECOND time on a manifest already built at :90, and the coercion rule exists in two places.
- Verified by grep across app/ lib/ config/ (--include='*.rb','*.erb'): `addon.shares_states_with` is read NOWHERE outside registry.rb itself; the only readers are test/services/maker/addons/registry_test.rb:201 and :208. A typed member with no production reader sits beside an untyped derivation that is authoritative.
- app/services/maker/addons/registry.rb:95 — `def find(key) = all.find { |a| a.key == key.to_s }`, so every `load_addon` re-runs the whole build+filter pass; `states_key_permitted?` additionally does a linear `index.find` per claiming addon.
- app/services/maker/addons/registry.rb:187-192 and docs/invariants/addons.md:433-443 — the recorded invariant is "the target must itself BUILD, not merely appear in the raw index" and "it is NOT recursive": a target skipped by this same check still confers a grant (probed: A admitted, B absent from Registry.all).

**Current complexity / invalid states**

One logical index is held in two shapes simultaneously. `build` is the declared normalizer of a manifest, but the single security-relevant decision in this module — may addon A read AND write addon B's saved states, for every user — bypasses the normalized value and re-parses the raw hash with a hand-copied duplicate of the same expression. That permits a state the type system suggests is impossible: `Addon#shares_states_with == []` while the addon nonetheless confers the grant. It is reachable the moment anyone tightens `build` toward what docs/addon-api-v1.md:107 actually specifies ("array of strings"), e.g. replacing `Array(...)` with the `is_a?(Array)` type-check that `services` at registry.rb:116 already uses — the gallery would then show no consent while the consent still stands. Separately, "the target must itself build" is encoded as a remembered second call to `build` rather than as a structural property, and `build` runs twice per sharing claimant.

**Proposed representation**

Build the index ONCE into a keyed map of built Addons and decide from the typed value. Concretely, inside `all`: `built = manifests.filter_map { |m| build(m) }.index_by(&:key)`, then `built.values.select { |a| states_key_permitted?(a, built) }.sort_by { |a| [a.title, a.key] }`, with `states_key_permitted?(addon, built)` reading `built[addon.states_key]&.shares_states_with&.include?(addon.key)`. "The target must itself build" becomes absence from the map rather than a remembered re-invocation; the linear `index.find` becomes a hash lookup; `shares_states_with` acquires its first production reader and stops having a second definition.

**Why simpler**

One representation of the index instead of two, and one definition of the consent coercion instead of two. The rule a future editor must not break (`build` must succeed on the target) stops being a call they could delete and becomes the shape of the data. It also removes the only place in this module where a raw manifest hash escapes `build`, which is the boundary the whole class exists to draw — everything else downstream (Addon, the gallery, the controller) already speaks only in built Addons.

**Smallest credible implementation scope**

registry.rb only: `all` (:88-93) and `states_key_permitted?` (:236-247) — roughly ten lines, no schema, no caller changes. `find`, `build`, `manifests` and the Addon shape are untouched. Optionally `find(key)` becomes a map lookup, but that is not required and can be left alone.

**Affected files**

- `app/services/maker/addons/registry.rb`
- `test/services/maker/addons/registry_test.rb`

**Regression risks and migration concerns**

ONE LINE MUST NOT BE GOT WRONG, and it is the reason to do this deliberately rather than opportunistically: the map must be built from the PRE-`select` list. Indexing the FILTERED result makes the check recursive, which registry.rb:194-203 and docs/invariants/addons.md:440-443 say it deliberately is not — the recorded probe is that A is admitted with states_key "b" while B is itself absent from Registry.all, and the invariant is that consent, not gallery visibility, is what is enforced. A behaviour delta worth naming rather than discovering: on DUPLICATE keys within one index, today `index.find` picks the first raw entry and refuses if that copy fails `build`, whereas a map built by `index_by` picks the last building entry (or first, with `.reverse` / an explicit reduce). Degenerate either way, but choose it consciously. Finally, the log line at :243-244 must keep firing for a refused claim — it is the operator's only clue, per the comment at :217-226.

**Validation required**

Existing coverage that must stay green, all in test/services/maker/addons/registry_test.rb and traced individually: :215-222 (unreciprocated claim skipped, target unaffected), :224-230 (mutual declaration honoured), :237-241 (claim on an absent addon refused), :243-246 (states_key == key untouched), :253-260 (target present in the index but rejected by `build` — the api_version "99" case — refused), plus :200-208 which are the only current readers of `Addon#shares_states_with`. ADDITIONAL WORK REQUIRED: the non-recursion property at registry.rb:194-203 has NO test — only a comment claiming it was probed — and this change alters HOW that property arises, so it must gain one (index: A claims B and B reciprocates; B claims C unreciprocated; assert A is admitted with states_key "b" while B is absent). Mutation-check it by building the map from the filtered list and confirming red, per §15.

### S19-2 — Registry.manifests caches the index unconditionally, ignoring the `cacheable?` predicate the Source itself answers — so a dev author gets fresh addon bytes against a manifest up to 5 minutes stale

> **COORDINATOR VERDICT — ACCEPT.** Verified against the tree; no narrowing applied.

> **Schema gap in this entry:** `category` field absent.

- **Category:** _(not recorded)_  
- **Lane confidence:** medium

**Evidence**

- app/services/maker/addons/registry.rb:100-105 — `Rails.cache.fetch(CACHE_KEY, expires_in: TTL) { Source.current.manifests }`; the source is constructed and asked for manifests, but never asked whether its output may be cached.
- app/services/maker/addons/source.rb:69-79 — `cacheable?` is documented as "a predicate the source ANSWERS, rather than a class check at the call site", TRUE for the HTTP source; app/services/maker/addons/source.rb:157-160 — `Source::Local#cacheable? = false`, because "a cached copy would make an addon author's edit invisible for the TTL — the 'my fix didn't deploy' confusion the whole caching design is supposed to avoid, delivered to the one person editing the file."
- Verified by grep across app/: `cacheable?` has exactly two consumers, both asset paths in S20 — app/controllers/tools/addons_controller.rb:219 (`expires_in ASSET_TTL, public: false if source.cacheable?`) and :1171 (`return source.asset(key, path) unless source.cacheable?`). The manifest cache one file over does not ask.
- config/environments/development.rb:104 — `ENV["ADDON_SOURCE_PATH"] ||= …/tinkerex-addons/addons if ENV["ADDON_SOURCE_URL"].blank?`, so dev resolves `Source::Local` (source.rb:31-33 gives PATH precedence); config/environments/development.rb:29 — `config.cache_store = :memory_store`, unconditional. `Rails.cache.fetch` is live in dev regardless of the `caching-dev.txt` toggle, which gates `perform_caching`, not `Rails.cache`.
- app/controllers/tools/addons_controller.rb:1166-1171 — the exact shape being proposed already exists one layer along, and its own comment says so: "THE RESCUE SITS OUTSIDE THE CACHE WRITE, and that placement is the same one Registry#all documents." The asset path honours `cacheable?`; the manifest path does not.

**Current complexity / invalid states**

Freshness is decided in two different places by two different rules for one source object. `Source::Local` declares itself uncacheable and that declaration is honoured for asset bytes and silently dropped for the index, producing a contradictory combination no reader can reason about: an addon author editing a bundle sees module bytes update instantly while `entry`, `pins`, `services`, `min_host` and `states_key` stay up to 5 minutes stale. That is worse than uniform staleness — the half that updates is the half that convinces you the other half did — and it is invisible, because a stale manifest fails as a 404 on a renamed entry module or a bare specifier that no longer resolves, not as anything naming the cache.

**Proposed representation**

Let the source own the answer, as it was designed to: `def manifests; source = Source.current; return source.manifests unless source.cacheable?; Rails.cache.fetch(CACHE_KEY, expires_in: TTL) { source.manifests }; rescue StandardError => e; …; []; end`. One predicate, asked by every consumer of the source's output, instead of a cacheability declaration that two call sites honour and a third overrides.

**Why simpler**

It removes a rule that exists only implicitly ("the index is always cacheable, whatever the source says") and replaces it with the one the source already publishes. Production is byte-identical — `Source#cacheable?` is `true` at source.rb:79 — so the change is confined to the dev/test backend where the predicate is `false` and was written to mean exactly this.

**Smallest credible implementation scope**

`Registry.manifests` (registry.rb:100-105) — three lines — plus the test-double updates named below, which are the larger half of the diff. No production behaviour change, no schema, no caller changes.

**Affected files**

- `app/services/maker/addons/registry.rb`
- `test/support/fake_addon_source.rb`
- `test/services/maker/addons/registry_test.rb`

**Regression risks and migration concerns**

§14c's rescue-outside-`Rails.cache.fetch` rule must survive intact (the rescue stays at method level, so a two-second blip still greys addons out for one request only, never for the TTL). THE MIGRATION RISK IS A FALSE-GREEN TRAP AND MUST LAND IN THE SAME COMMIT: test/services/maker/addons/registry_test.rb:131-132 and :139-140 install `failing = Object.new` doubles defining ONLY `manifests`, so a new `source.cacheable?` call raises `NoMethodError`, which the method's own `rescue StandardError` swallows into `[]` — both tests stay green while becoming vacuous about the thing they assert. And test/support/fake_addon_source.rb:6,17 defaults `cacheable: false`, which after this change disables the manifest cache across registry_test.rb and makes "a failed fetch is NOT cached" (:138-146) pass whether or not caching works at all. Both doubles and the fake's default must be handled deliberately — this is precisely the §14e "suite green over a guard whose precondition is never established" shape.

**Validation required**

test/services/maker/addons/registry_test.rb:138-146 ("a failed fetch is NOT cached, so recovery does not wait out the TTL") and :122-126/:128-136 (degrade-to-empty) are the existing guards and must be re-armed, not merely kept green — the invariant file notes the caching assertions are only meaningful against a real MemoryStore, since test.rb:47 sets `:null_store`. ADDITIONAL VALIDATION REQUIRED: a test that an uncacheable source is asked twice for two `Registry.all` calls, and a complementary one that a cacheable source is asked once — mutation-check the first by removing the new `unless source.cacheable?` guard and confirming red. test/services/maker/addon_origin_test.rb:13 already defines a `cacheable? = false` double and shows the shape.

### Cross-subsystem concerns raised by this lane

_Named, not solved — the lane was told to stay inside its boundary._

- S20 (Tools::AddonsController) owns both existing consumers of Source#cacheable? — addons_controller.rb:219 and the cached_asset helper at :1168-1171. Finding 2 does not change them, but any future move of the cacheability decision would have to account for all three call sites together.
- maker_addon_files.position is only unique within one save and nothing on the row records which save that was: library_output.rb:72-77 states the cost outright ("two rows, both zero ... arbitrary and unrecoverable") and Maker::AddonState's order(:position, :id) is a tiebreak, not a repair. I deliberately did NOT recommend adding a revision column to that table: no current reader distinguishes a state's current output from a superseded one, and §14c's own rule about maker_addon_states.revision ("add [the count column] with the deletion, not before — today it would be a second value to keep in step for no present reader") argues against it here for the same reason. Flagging it as a known, documented ambiguity that becomes worth fixing the day a reader needs it.
- Source#manifests (source.rb:55-62) and Source::Local#manifests (source.rb:146-153) each carry their own copy of the "the index must be an Array" assertion and JSON::ParserError rescue, while validate_asset_path! (source.rb:42-49) was extracted as a class method precisely so the two backends cannot drift. Coverage is asymmetric — source_test.rb:118-123 tests Local's non-array branch, and there is no equivalent for the HTTP Source, which is the production path. I judged this below the threshold (about eight lines, mirrored tests) rather than manufacturing it into a finding, but it is the same drift shape the file's own comment argues against.
- docs/AUDIT-2026-08-19.md is a dated snapshot listing F-20 and F-21 as ACCEPTED with no landing record; per CLAUDE.md §14e ("a stale open-list ... hides unfinished work behind a row that says done") somebody should reconcile that ledger against the tree, since both conditions it accepted are still present.

---

## S20 — Addon web layer & state persistence

**Lane verdict:** `recommend`

### S20-1 — The save door's per-file "placement" is an untyped hash with three different key sets, paired to `files` by array index in three separate places

> **COORDINATOR VERDICT — ACCEPT.** Verified against the tree; no narrowing applied.

- **Category:** state-representation  
- **Lane confidence:** medium

**Evidence**

- app/controllers/tools/addons_controller.rb:916-928 — `resolve_placements` returns, per file, one of three *different* hash shapes: `{folder:, parent_node_id:, replace: true, owned: <bool>}` (arm 1, line 922-923), `{parent_node_id:, replace: true, owned: true}` (arm 2, line 925), or `{}` (line 927).
- app/controllers/tools/addons_controller.rb:952 — `colliding = files.zip(placements).select { |_f, p| p[:replace] && !p[:owned] }`; line 956 then reads `p[:folder]` off the same untyped hash to build the 409 body. The `replace`/`owned`/`folder` keys are only meaningful in combination, and nothing but convention keeps them consistent.
- app/controllers/tools/addons_controller.rb:520-532 — the write call re-establishes the same pairing by *index* instead of by zip: `files.each_with_index.map do |f, i| { name: …, role: "output" }.merge(placements[i].slice(:parent_node_id, :replace)) end`. The `.slice` is an allowlist whose whole rationale (which two keys LibraryOutput reads, why `:folder` and `:owned` are dropped, why `{}.slice` must stay `{}`) lives in an 11-line comment at 521-530 rather than in code.
- app/services/maker/addons/library_output.rb:52-53 — the consumer: `dest = f.fetch(:parent_node_id, parent_node_id)` and `replace = f[:replace].present?`. `fetch` means an ABSENT `:parent_node_id` key and a PRESENT-but-nil one mean different things ("use the save's picked folder" vs "the library root"), so the empty-hash sentinel is a real contract, not just a default.
- app/controllers/tools/addons_controller.rb:867-877 — `refuse_taken_names!(files, parent_node_id, owned)` consumes the same `owned` index a third way (`except_node_id: owned[[parent_node_id, name]]`), and its comment at 861-866 says `owned` is required-not-defaulted precisely because "the two halves fail in opposite directions" — a rule that today exists only as prose plus a required kwarg.
- app/controllers/tools/addons_controller.rb:964 and 1041-1043 — this same file already uses `Data.define` for exactly this job twice (`SaveFile = Data.define(:name, :content_type, :bytes)`, `FileSource = Data.define(:content_type, :size, :reader)`), and `Maker::ProjectIntake::Destination` at app/services/maker/project_intake.rb:143 is a third. The placement is the one value in this flow still passed as a bare Hash.

**Current complexity / invalid states**

A save's per-file destination decision is carried as an untyped Hash whose key set varies by branch, kept in a second array parallel to `files`. That representation permits combinations the code must never produce — most importantly `owned: true` with `replace` absent, which is exactly the defect the arm-2 comment records as measured on chunk ("lands as a CREATE: probed on chunk, that is a SECOND live node with the same name in the same directory", lines 894-903). Nothing structural forbids it: the two keys are only guaranteed to travel together because they appear in the same hash literal. Meanwhile the files↔placements correspondence is re-derived three ways (`zip` at 952, `placements[i]` at 532, positional order implied by `resolve_placements`' `files.map`), and the rule about which keys may cross into `LibraryOutput` is a comment attached to a `.slice`.

**Proposed representation**

Introduce a `Placement` value beside the existing `SaveFile`/`FileSource` in the same file, with named constructors matching the three branches — e.g. `Placement.create` (the `{}` case), `Placement.replace_owned(parent_node_id:)`, `Placement.replace_other(parent_node_id:, folder:)` — and exactly two readers: `#asks_user?` (today's `p[:replace] && !p[:owned]`) and `#write_overrides` (today's `.slice(:parent_node_id, :replace)`, returning a literal `{}` for the create case so `LibraryOutput`'s `fetch` default is untouched). `owned` then cannot exist without `replace`, and `folder` cannot exist without a 409-eligible replace, because no constructor produces those. Then have `resolve_placements` return the *pairs* — `files.map { |f| [f, placement_for(f, …)] }` — so `render_would_replace` and the `LibraryOutput.write` mapping both consume one collection and the `zip`/`placements[i]` index correspondence disappears. Optionally (and separably) the same value can carry the picked-folder verdict, folding `refuse_taken_names!` and `resolve_placements` into one "plan this save" pass; I would not do that in the same change, because the ordering between those two checks is load-bearing (lines 852-855).

**Why simpler**

It removes one whole class of representable-but-illegal state (`owned` without `replace`) that this door has already shipped as a live bug once, and it moves two rules that currently live only in comments — "only these two keys reach LibraryOutput" and "a non-colliding placement must be an empty hash, not a hash of nils" — into single methods that a future edit cannot bypass by writing a hash literal. It also deletes the parallel-array invariant: three call sites that must agree about index ordering become one collection of pairs. Net line count is roughly flat; the win is that the constraints stop being prose.

**Smallest credible implementation scope**

One file. Add ~12 lines of `Placement` definition, rewrite `resolve_placements` (15 lines), `render_would_replace`'s `select`/`map` (3 lines), and the `LibraryOutput.write` files mapping (4 lines) in `#create`. No migration, no wire-format change, no change to `LibraryOutput`. Several paragraphs of comment at 521-530 and 905-915 shorten to point at the constructors instead of restating the key rules.

**Affected files**

- `app/controllers/tools/addons_controller.rb`

**Regression risks and migration concerns**

The real risk is the absent-vs-nil `:parent_node_id` contract with `Maker::Addons::LibraryOutput.write` (library_output.rb:52). A naive `Data` whose `to_h` always emits `parent_node_id:` would turn every ordinary save's placement from "no override" into "override to nil", which for a save into a picked folder is a silent redirect to the library ROOT. `#write_overrides` must return a literal `{}` for the create case — that is the one thing to mutation-check. Second risk: arm 1 must keep winning over arm 2 when both apply (lines 905-910); named constructors do not change `if`/`elsif` order, but a reviewer should confirm the branch order survives. Third: this is a heavily-argued door and the comments are the record — they should be edited to point at the new constructors, not deleted, per CLAUDE.md §15.

**Validation required**

test/controllers/tools/addons_controller_test.rb already pins every branch and their interaction: "revising replaces its own file in the picked folder" (772-792, asserts the node_id survives — i.e. arm 2 really set `replace`), "revising still asks before replacing a filed file another box produced" (816-832, arm 1 + `owned: false` → 409), "the exemption is scoped to the folder it owns, not to the name" (847-866), "revising refuses a name it owns when a node it does NOT own also holds it" (888-916), and "when both placement arms apply the category folder wins and the save asks" (925-944, which asserts the 409 body's `folder` key). Mutation checks that must go red: (a) make `Placement#write_overrides` always include `parent_node_id:` and confirm a save into a picked folder no longer lands there; (b) make `#asks_user?` ignore `owned` and confirm 772-792 goes red; (c) reorder the two constructors' branches and confirm 925-944 goes red. Run on all three backend legs (`test`, `test-s3`, `test-chunk-remote`) — the chunk leg is the one where a missed `replace` mints a duplicate sibling rather than being refused by the port.

### Cross-subsystem concerns raised by this lane

_Named, not solved — the lane was told to stay inside its boundary._

- S19 (Maker::Addons::LibraryOutput): the placement contract's sharpest edge lives across this boundary — `f.fetch(:parent_node_id, parent_node_id)` at app/services/maker/addons/library_output.rb:52 makes an ABSENT key and a nil-valued key mean different things (picked folder vs library root). Any typed placement in the controller must preserve that; a shared value object spanning both would be the cleaner answer but is not mine to design.
- S19 (LibraryOutput#upsert_file!): `maker_addon_files` accumulates rows from revisions that no longer emit that name (addons_controller.rb:787-790 states this as the rule), so `state.files` mixes current and stale outputs and two rows can share `position` — which app/models/maker/addon_state.rb:9-22 acknowledges by adding an `:id` tiebreak and saying the number "does NOT make the number meaningful across saves". `GET /tools/:key/states` serialises that mixture with no way for a bundle to tell a current output from a stale one. A `revision` (or `last_written_revision`) column on maker_addon_files would resolve it, but the writer is S19's and the wire shape is api_version-1 frozen, so I am naming it only.
- Tools::LibraryFolders (not in my boundary): `#show` calls BOTH `folder_options` (app/controllers/tools/library_folders.rb:45-58, which plucks every dir the user owns and builds a label for each) and `folder_path_label` (:17-29), whose own comment says it avoids `folder_options.rassoc(id)` precisely because that "plucks EVERY dir the user owns". On this one page the full pluck is paid anyway, so the O(depth) per-ancestor `find_by` queries buy nothing. Small, and it resolves itself when the legacy flat `@folders` list is finally dropped.

---

## S21 — Addon SDK (browser)

**Lane verdict:** `recommend`

### S21-1 — importer_controller.js keeps the last un-migrated copy of the ROLE_BY_EXT vocabulary, and it has already drifted

> **COORDINATOR VERDICT — DEMOTED.** MY PROMOTION WAS WRONG. importer_controller.js:122 posts only {node_id, cover}; the server derives role authoritatively at models/attachments_controller.rb:23. Files are NOT stored as role `other`. Residual: the JS vocabulary feeds only the importer's own cover heuristic and "N models" summary count. Cosmetic-to-minor.

> **Schema gap in this entry:** Records ABSOLUTE worktree paths that stop resolving once this branch lands.

- **Category:** data-structure  
- **Lane confidence:** high

**Evidence**

- app/javascript/controllers/importer_controller.js:8-18 — module-private `IMAGE_EXT = ["png","jpg","jpeg","gif","webp","bmp"]`, `MODEL_EXT = ["stl","3mf","obj","step","stp"]`, and `roleFor(name)` mapping pdf->instructions, gcode|gco->gcode, zip->source_archive, else "other".
- app/models/maker/file_attachment.rb:33-41 — `ROLE_BY_EXT` opens at :33 and carries the same role names: :34 `"stl" => "model" … "stp" => "model"`, :35 `"png" => "image" … "bmp" => "image"`, :41 `"gcode" => "gcode", "gco" => "gcode", "nc" => "gcode", "tap" => "gcode", "ngc" => "gcode"`. The JS copy lacks nc/tap/ngc — the two tables already disagree today about what a `.nc` file is.
- app/models/maker/file_attachment.rb:212 — `def self.role_for(name)`, the single server-side accessor the JS copy shadows (`ROLE_BY_EXT.fetch(ext, "other")`).
- app/helpers/files_helper.rb:101-104 — `EXT_FAMILIES = Maker::FileAttachment::ROLE_LABELS.filter_map { … ROLE_BY_EXT.select { |_ext, r| r == role }.keys … }`: the repo already owns the exact roles->extension-sets derivation this finding needs, and the comment at :94-97 records the drift that motivated it (`.svg`/`.dxf`/`.lbrn2` reading "2D / laser" in one table and "Vector" in the other; five cad_source extensions with no chip at all).
- app/controllers/files_controller.rb:1191-1195 — a third such migration with the cost written down: "This was an inline set of 26 extensions sitting next to Maker::FileAttachment::ROLE_BY_EXT, and it had already drifted: five of its entries (xml log ini cfg conf) were in no ROLE_BY_EXT entry at all".
- app/javascript/controllers/importer_controller.js:85-89 — `renderSummary` counts `f.role === r` for model/image/instructions and derives `other` by subtraction; :95-96 `coverIndex()` picks the first `role === "image"` else the first `role === "model"`; :78 `deriveTitle` picks the first `role === "model"`. Three user-visible consumers, all reading the shadow table.
- app/views/models/new.html.erb:5-10 — the element already carries five server-rendered `data-importer-*-value` attributes, so plumbing a sixth derived from `ROLE_BY_EXT` needs no new mechanism.

**Current complexity / invalid states**

Two definitions of "what kind of file is this" exist for one import flow. The server assigns the real role on attach via `Maker::FileAttachment.role_for` (ROLE_BY_EXT); the browser independently re-derives a coarse role from a hand-written 15-extension table before the file is ever uploaded, and uses it for three decisions the user sees — the summary line, the auto-filled title, and which file becomes the model's cover. CLAUDE.md §14d states the rule in as many words ("Add an extension in ROLE_BY_EXT only"), and three other second copies in this repo — FilesHelper::EXT_FAMILIES, FilesController#preview_kind's 26-extension set, Maker::ProjectIntake — were each migrated to derive from the one table after drifting. This JS copy is the remaining one, it sits on the far side of a language boundary where no Ruby test can observe the disagreement, and it has already drifted (nc/tap/ngc).

**Proposed representation**

Delete `IMAGE_EXT`/`MODEL_EXT`/`roleFor` from the controller and have the server hand down the vocabulary it already owns. Add one `data-importer-roles-value` (Object) to app/views/models/new.html.erb rendered from `Maker::FileAttachment::ROLE_BY_EXT` — or, if the full ~50-entry map is more payload than wanted, just the two extension sets the importer consumes, derived the way FilesHelper::EXT_FAMILIES already derives its families (`ROLE_BY_EXT.select { |_ext, r| r == role }.keys`). `roleFor` becomes a lookup in that value with the same `"other"` fallback the server uses, so the client's role and the role the server records after attach are the same function of the same table.

**Why simpler**

One table instead of two, and the client stops asserting facts about file types it has no authority over. It removes an invisible failure mode rather than shortening code. Concretely: someone adds `"avif" => "image"` to file_attachment.rb:35 as the one-line edit every §14d comment in this repo says is the complete edit; a user then imports a zip whose only preview image is `render.avif`. importer_controller.js:10-13 classifies it "other", so `coverIndex()` (:95-96) skips it and picks the first `.stl` instead, and `renderSummary` (:87-89) reports "0 images" — while the model page groups that same file under Images, because the server used ROLE_BY_EXT. Nothing errors and no test goes red. It also makes the importer's summary and the model page's attachment grouping provably the same partition, which today they are not.

**Smallest credible implementation scope**

One data attribute in app/views/models/new.html.erb, a Stimulus `static values` entry, and replacing ~10 lines at the top of importer_controller.js with a lookup. No wire format changes, no change to what the server records, no addon-facing surface touched.

**Affected files**

- `app/javascript/controllers/importer_controller.js`
- `app/views/models/new.html.erb`

**Regression risks and migration concerns**

Low. The client `role` is display-only — the server recomputes the authoritative role on attach — so a mistake here cannot mis-file anything, only mis-count a summary line or pick a different cover. One thing to preserve: `roleFor`'s `"other"` fallback must stay a fallback, not become `undefined`, or `renderSummary`'s subtraction at :86 goes wrong.

**Validation required**

The structural claim is checkable without a browser: assert the value rendered into `data-importer-roles-value` equals what `Maker::FileAttachment::ROLE_BY_EXT` (or the derived image/model sets) contains, the way test/helpers/files_helper_test.rb already pins EXT_FAMILIES against the same source. Mutation-check per §15 by adding a fake extension to ROLE_BY_EXT and confirming the rendered value carries it — a test that still passes with the JS table restored is vacuous. The user-visible half (summary counts, cover selection) has no system-test coverage I could find for /models/new, so that half would need a browser assertion or an explicit note that it stays unpinned.

### S21-2 — Mount liveness is encoded twice — a controller boolean and a module-global binding — and neither says WHICH mount

> **COORDINATOR VERDICT — ACCEPT.** Verified against the tree; no narrowing applied.

> **Schema gap in this entry:** Records ABSOLUTE worktree paths that stop resolving once this branch lands.

- **Category:** ownership  
- **Lane confidence:** medium

**Evidence**

- app/javascript/maker/addon_sdk.js:65 — `export let host = UNINITIALIZED_HOST`: one module-global binding with no identity attached to it.
- app/javascript/maker/addon_sdk.js:790-798 — `initHost(ctx)` calls `teardownHost()` unconditionally at :794, then `host = new Host(ctx)`; it returns the instance, but nothing today keeps the returned value.
- app/javascript/maker/addon_sdk.js:800-805 — `teardownHost()` takes no argument: `if (host !== UNINITIALIZED_HOST) host._fireTeardown(); host = UNINITIALIZED_HOST`. Any caller tears down whatever host is currently live, whether or not that caller created it.
- app/javascript/controllers/addon_controller.js:17 — `this.disposed = false` at the top of `connect()`; :106-107 — `disconnect()` sets `this.disposed = true` and then calls the argument-less `teardownHost()`.
- app/javascript/controllers/addon_controller.js:54-63 — `const module = await import(this.entryValue)`, then `if (this.disposed) return` at :62, then `await module.default.mount(this.mountTarget, {…})` at :63. The boolean is consulted exactly once, between two awaits; nothing re-checks after it.
- app/javascript/maker/addon_sdk.js:26-36 — the header names the hazard the sentinel does NOT cover: the Proxy answers "no host is live", and the file's own advice is to read through `host` at call time. A read landing while a SUCCESSOR host is live is neither case — it resolves silently to the successor.
- test/system/addon_sdk_test.rb:467-475 — the Turbo soft-navigation test's own comment: "the `this.disposed` guard added in commit b3f4b78 exists precisely for that in-flight race". The race is acknowledged; what is pinned is the clean sequential handoff, not an interleaving.

**Current complexity / invalid states**

Two independent representations answer "is this mount still the live one". The SDK's is the module-global `host` binding, which knows only live-vs-sentinel; the controller's is a per-instance `disposed` boolean, which knows only "my element was removed". Neither carries the identity of the mount it belongs to, so two questions the code needs to tell apart collapse into one: "my mount ended" and "my mount ended and someone else's is now live". Consequences: `disconnect()` on a stale controller tears down whatever host happens to be current, including a successor's; and the single `if (this.disposed)` gate at :62 is the only check between the dynamic import and `mount()`, with no way to express "the host I was created for is no longer the host the binding resolves to".

**Proposed representation**

Give the binding an owner instead of a second boolean. `connect()` keeps what `initHost` already returns (`this.host = initHost({…})`); the post-import gate becomes an identity test against the live binding rather than a private flag; and `teardownHost` takes the instance the caller created (`teardownHost(this.host)`), no-opping unless `host === that instance`. `initHost`'s own internal call at :794 keeps today's unconditional behaviour by passing the current `host`. `this.disposed` disappears — one predicate, "am I still the live host", replaces it and answers correctly in the case the boolean cannot see.

**Why simpler**

It removes a class of contradictory state rather than renaming it. With an unowned global, "tear down the host" is not an operation a caller can perform safely: it silently means "tear down whoever is current". Making teardown identity-checked turns a late or out-of-order disconnect from a live-host kill into a no-op, and it does so without adding a state machine — one comparison replaces one boolean. The concrete case: a user on /tools/boxes navigates to /tools/openscad via Turbo Drive; Stimulus processes the body swap in one mutation batch while the boxes controller is still awaiting `mount()` at :63. If additions are processed before removals, or a later change reorders them, the boxes `disconnect()` (:106-107) destroys the openscad host `connect()` just installed, and the openscad bundle's next `host.files.save(...)` throws the SDK's "read after this addon's host was torn down" error — a message that sends the developer hunting a closure that outlived its mount, which is not what happened. It also keeps the published surface intact: `initHost`/`teardownHost` are host-side exports, the new argument is optional, and nothing a bundle imports (`host`, the error classes, `files`/`state`/`service`) changes shape — which matters because bundles deploy independently of this repo.

**Smallest credible implementation scope**

About six lines: an optional parameter on `teardownHost` at addon_sdk.js:800, its one internal caller at :794, and three lines in addon_controller.js (`this.host = initHost(...)` at :48, the gate at :62, the call at :107). No change to `Host`, to the ctx contract, or to the bundle-facing surface.

**Affected files**

- `app/javascript/controllers/addon_controller.js`
- `app/javascript/maker/addon_sdk.js`

**Regression risks and migration concerns**

The residual case this does NOT close, and the change should say so rather than imply otherwise: a bundle's `mount()` still awaiting when a successor connects will, on resuming, read the global `host` at call time and get the SUCCESSOR — that is the documented contract (addon_sdk.js:14-20) and identity in the controller cannot reach inside a bundle's own call. What identity buys is the two halves this subsystem owns: a stale disconnect can no longer tear down a live host, and the controller can decline to mount against a host it did not create. Do not extend this into making `Host` methods refuse when `this !== host` without first checking bundle behaviour — a bundle that legitimately holds a callback across a re-mount would start throwing where it currently degrades.

**Validation required**

test/system/addon_sdk_test.rb:475 already drives connect -> disconnect -> connect through a real Turbo soft navigation and must stay green unchanged — that is the regression guard for the sequential path. For the identity claim itself, mutation-check per §15: make `teardownHost` ignore its argument again and confirm a test that installs a second host and then fires the first controller's `disconnect()` goes red (today it passes, because the sentinel and a successor are indistinguishable to every existing assertion). Honest limit: I executed nothing, and I did not confirm empirically that Stimulus/Turbo can interleave connect-before-disconnect on this app — no morphing and no turbo-frames are configured for /tools (grep over app/views, app/javascript, config found none), so the interleaving argument rests on Stimulus processing one MutationObserver batch while an `await` is pending. Probe that before landing; if it cannot interleave here, the finding shrinks to the ownership cleanup alone and should be judged on that.

### Cross-subsystem concerns raised by this lane

_Named, not solved — the lane was told to stay inside its boundary._

- app/javascript/controllers/importer_controller.js:140-150 defines a `postJSON` that is a near-verbatim copy of the module-private `postJSON` in app/javascript/lib/chunk_upload.js:13-22 — same headers, same `res.json().catch(() => ({}))`, same `data.error || 'request failed (status)'` message — and importer_controller already imports from that module at :3. Exporting the one implementation would remove the copy. Too small for a finding slot, and lib/chunk_upload.js is outside my boundary.
- app/javascript/controllers/uploader_controller.js:15 calls `uploadChunkFile` unconditionally with no `port_writable` branch, while importer_controller.js:119-121 branches between `uploadPortFile` and `uploadChunkFile` on `portWritableValue`. Whether the single-file uploader is correct on share/s3 deployments is an uploads-subsystem question — naming it only.
- The addon ctx blob's shape is asserted piecemeal across addon_sdk.js (`_ctx.urls.save` :535, `_ctx.urls.file` :611, `_ctx.urls.states` :631 and :662, `_ctx.urls.service` :702, `_ctx.csrfToken` :404, `_ctx.chooseFolder` :557, `_ctx.chooseFile` :585, `_ctx.launch` :692) with no single declaration of the expected shape on either side of the wire. docs/invariants/addons.md pins the server half deliberately (the nine legacy attributes stay for the life of api_version 1; `defaultFolder` names two shapes on purpose), so this belongs to whoever owns Maker::Addons::Host and the ctx renderer, not here.
- app/javascript/lib/formula_adapter.js is a classic script that must set `window.formula` before jspreadsheet loads, with load order enforced by projects/sheets/show.html.erb, and its correctness depends on vendored bundle internals documented at :11-28. Nothing to simplify inside it; any change is a sheets-subsystem question.

---

## S22 — Files web controller & views

**Lane verdict:** `recommend`

### S22-1 — The sort vocabulary is spread across six sites, and `paged_folder?` infers "this sort has a SQL folder ordering" from DEFAULT_SORT instead of storing it

> **COORDINATOR VERDICT — NARROWED.** Its central sentence is FALSE — files_controller.rb:886 states the rule with a per-sort argument. Residual defect is one token: paged_folder? spells the condition as `@sort == DEFAULT_SORT` where `"name"` is meant. Drop the six-site vocabulary refactor.

- **Category:** data-structure  
- **Lane confidence:** medium

**Evidence**

- app/controllers/files_controller.rb:901 — `def paged_folder? = @sort == DEFAULT_SORT`: the ONLY gate on the paged branch.
- app/controllers/files_controller.rb:916 — `def folder_page_order(dir)`: takes `dir` only, never the sort key; its body (917-924) orders by `kind='dir'`, `LOWER(name)`, `name` unconditionally, so it can express exactly one of the three sorts.
- app/controllers/files_controller.rb:788-789 — `SORTS = %w[name type modified]` and `DEFAULT_SORT = "name"`, two constants with nothing linking `DEFAULT_SORT`'s value to the fact that folder_page_order happens to implement that same key.
- app/controllers/files_controller.rb:934-940 — `sort_key`'s three-branch case (type/modified/else name), the Ruby authority for folder mode.
- app/controllers/files_controller.rb:1090-1108 — `flat_order`'s parallel three-branch case over the same keys ('modified' COALESCE, 'type' CASE, else LOWER(name)), the SQL authority for flat mode.
- app/views/files/index.html.erb:182 — `{ "name" => "Name", "type" => "Type", "modified" => "Modified" }` hard-coded in the grid's sort form, a fourth copy of the key list; app/views/files/_list.html.erb:9,10,18 spell the same three keys into `sort_header` calls.
- app/controllers/files_controller.rb:192-196 — the comment recording that this exact class of bug already shipped: an ORDER BY that did not match the heading the user clicked, so the LIMIT selected the wrong rows under the right label.

**Current complexity / invalid states**

Three sorts × three listing modes (flat/paged-folder/unpaged-folder) are encoded as five independent case statements and constants that must agree by hand. The specific invalid state that is representable today: `folder_page_order` implements the NAME order and nothing else, but the branch that uses it is guarded by `@sort == DEFAULT_SORT`. Change line 789 to `"modified"` — a one-token edit that reads as a harmless default change and breaks no whitelist — and every folder page is now selected and ordered by name while the Modified header is marked active, i.e. rows silently drop and duplicate across page boundaries. That is the same defect the comment at 192-196 records as already shipped once in flat mode. Nothing anywhere states "only `name` has a SQL folder ordering"; it is inferred from a default's value.

**Proposed representation**

One ordering registry keyed by sort key, holding the facts that are currently scattered: `SORT_ORDERS = { "name" => Ordering.new(label: "Name", folder_sql: ->(dir) { … }), "type" => Ordering.new(label: "Type", folder_sql: nil), "modified" => Ordering.new(label: "Modified", folder_sql: nil) }`. Then `SORTS = SORT_ORDERS.keys`, `paged_folder? = SORT_ORDERS.fetch(@sort).folder_sql.present?`, `folder_page_order` becomes `SORT_ORDERS.fetch(@sort).folder_sql.call(@dir)`, and the grid form's option list is `SORT_ORDERS.map { |k, o| [k, o.label] }` (helper_method) instead of a literal hash in the ERB. `sort_key`'s and `flat_order`'s case bodies can move into the same records later, or not at all — they are not what this finding turns on.

**Why simpler**

"Can this sort be paged?" stops being a coincidence between two constants and becomes a stored property read off the ordering that would do the paging. The lambda that produces the SQL and the assertion that the SQL exists become the same fact, so they cannot disagree; adding a fourth sort, or making `type` pageable, is one entry rather than an edit in six places three of which are silent when missed. It also removes the fourth and fifth copies of the key list (the ERB literal and the SORTS whitelist), which today can drift into offering an option the whitelist drops — the exact dead-control failure `ext_slots_left?` exists to prevent one filter over (files_helper.rb:145-153).

**Smallest credible implementation scope**

Smallest credible slice: add the registry with `label` and `folder_sql` only; derive `SORTS`, `paged_folder?` and the grid form's options from it; keep `sort_key`, `flat_order`, `resolve_sort`'s whitelist logic, `DIRS` and the Arel body of the name ordering byte-for-byte as they are. No change to flat mode, no change to the sanitize_sql_array/Arel path Brakeman watches.

**Affected files**

- `app/controllers/files_controller.rb`
- `app/views/files/index.html.erb`

**Regression risks and migration concerns**

The name ordering's Arel must move verbatim — its LOWER() is what keeps rows from scattering across page boundaries (files_pagination_test.rb:79 goes red if dropped, per the comment at 903-910). Deriving the grid's option labels through a helper_method adds a controller→view coupling where a literal sits today; if that is unwelcome, leave index.html.erb:182 alone and take only the `paged_folder?`/`SORTS` half — most of the value is there. Do not use this as cover for collapsing the Ruby and SQL comparators into one: §5.2 and the comments at 818-829 and 886-900 argue that split is deliberate and portability-driven, and I am not recommending it.

**Validation required**

Existing: test/integration/web/files_pagination_test.rb (all seven tests, especially "the type and modified sorts are NOT paged" at :156 and "every child appears exactly once across all pages" at :79) and test/integration/web/files_sort_test.rb (whitelist fallback at :180-186, header/select state at :186-251). Additional: a test that flips DEFAULT_SORT to "modified" (or, better, asserts `paged_folder?` is false for every key whose `folder_sql` is nil) and shows paging does not engage — that is the mutation-check the current shape has no way to express, since today the mutation is green.

### S22-2 — A preview's display state is re-derived from (row?, status, asset attached?) at five sites in this subsystem, and they give four different answers for one representable row

> **COORDINATOR VERDICT — NARROWED.** The 5-sites/4-answers divergence is verified exactly. But reachability is narrow: GeneratePreviewJob attaches BEFORE update!(status:"ready"), and V1::Maker::PreviewsController does not permit :status. The only production path is a failure between purge and destroy! in DeadNodeReaper. It IS created abundantly in the suite. Do not report as "users see this".

- **Category:** state-representation  
- **Lane confidence:** high

**Evidence**

- app/controllers/files_controller.rb:313-315 — `#thumbnails` emits `{ status: preview.status, url: (… "ready" && attached? ? url_for : nil) }`, so a ready row with no attached asset serializes as `{status: "ready", url: nil}`.
- app/controllers/files_controller.rb:389-391 — `#geometry`'s `when "ready"` emits `{ status: "ready", url: (url_for(preview.asset) if preview.asset.attached?) }` — the same status/url contradiction, spelled differently.
- app/views/files/_thumb.html.erb:9-20 — `thumb&.status == "ready" && thumb.asset.attached?` → img; `thumb.nil? || pending/processing` → spinner; ELSE → the terminal "Preview not supported" badge. Ready-without-asset lands on the badge.
- app/views/files/show.html.erb:166-176 — `@kind == :thumbnail && @thumbnail&.status == "ready" && @thumbnail.asset.attached?` → img, `pending/processing` → "Generating preview…", else → "No inline preview for this file type." Ready-without-asset lands on the last one. Line 155 spells the same pair a fifth time inside the model3d fallback.
- app/javascript/controllers/thumbs_controller.js:46-50 — `if (entry.status === "ready" && entry.url) … else if (status === "unsupported" || "failed") …`: the `{ready, url: null}` payload matches NO branch, so the cell keeps its spinner AND stays in the poll set until `resolveStragglers()` fires at try 41 (~80 s).
- app/javascript/controllers/measure_controller.js:111-121 — the same shape for #geometry: `body.status === "ready" && body.url` or a terminal status; `{ready, url: null}` falls through to "Still generating — reload to check.", forever.
- test/integration/web/lbrn_geometry_test.rb:56-62 — `thumbnail_at(revision, status: "ready")` creates precisely this row (status "ready", no asset attached) and the test at :256 GETs the file page with it, so the state is live in the suite today.

**Current complexity / invalid states**

`Maker::Preview` carries status and the attachment as two independent axes (app/models/maker/preview.rb:8,20 — `has_one_attached :asset` beside a `STATUSES` inclusion validation), and GeneratePreviewJob attaches and then `update!(status: "ready")` as two statements (generate_preview_job.rb:113-120). The tuple (ready, not attached) is therefore representable, and each of the five consumer sites in this boundary re-derives "which of image / spinner / badge" from it independently. They do not agree: the two HTML surfaces call it terminal, the two JSON doors call it ready-with-no-url, and both JS clients treat ready-with-no-url as "keep waiting". So the same row shows a static badge on first paint and an unresolvable spinner on the poll. This is the shape docs/invariants/files-preview.md already records drifting once — the no-row case worked around three times at the callers and still live in a fourth.

**Proposed representation**

One resolver returning a small discriminated result — `Ready(url)` / `Pending` / `Terminal(status, error)` — with `Ready` requiring BOTH `status == "ready"` and `asset.attached?`, and ready-without-asset resolving to `Terminal` (which is what both HTML surfaces already do, so the change lands only on the two JSON doors that currently emit an unhandleable payload). `#thumbnails` and `#geometry` serialize it; `_thumb.html.erb` and show.html.erb's two checks branch on it. The `url_for(preview.asset)` call, currently written five times, exists once inside `Ready`.

**Why simpler**

The contradiction stops being representable in what the views and the JSON contract see: there is no "ready" without a url, so neither JS client can reach a branch it has no handler for, and the four surfaces cannot answer one row differently. It also collapses five copies of the `status == "ready" && asset.attached?` pairing — the pairing is the actual invariant and it is currently prose held in five places. This does NOT touch the endpoint's two no-row cases (unsupported vs omit): that rule is about a node with no row at all (files_controller.rb:309-318, docs/invariants/files-preview.md), it is a different question from status→display, and it must stay exactly as it is.

**Smallest credible implementation scope**

Smallest credible slice: a private controller method plus a `helper_method` (or a small PORO under app/services/maker/previews/ if the four out-of-boundary adopters are wanted later), consumed by #thumbnails, #geometry, _thumb.html.erb and show.html.erb:155/166/169. Do not change ThumbnailMap, Enqueue, the job, or the backfill flag.

**Affected files**

- `app/controllers/files_controller.rb`
- `app/views/files/_thumb.html.erb`
- `app/views/files/show.html.erb`
- `app/helpers/files_helper.rb`

**Regression risks and migration concerns**

The wire shape of both JSON doors is pinned by tests and consumed by two JS controllers — the keys (`status`, `url`, `error`) must stay identical; only the ready-without-asset case changes value. The `#geometry` action's deliberate asymmetry with `#current_thumbnail` (it never reads `status` before deciding to enqueue — files_controller.rb:365-387, §14h forbids unifying that) is about the ENQUEUE decision, not the render decision; the resolver must sit strictly after `preview` is resolved and must not absorb that logic. `_thumb.html.erb`'s terminal branch must keep its exact `title`/em-dash text, which thumbs_controller.js:83-88 mirrors by hand.

**Validation required**

Existing: test/integration/web/files_flow_test.rb:69 and :98 (the two thumbnails-endpoint contract tests, including the omit-vs-unsupported split), test/integration/web/lbrn_geometry_test.rb:74-171 (pending/ready/failed/unsupported/staleness for #geometry), test/integration/web/maker_page_thumbnails_test.rb (the cross-surface poll cells). Additional and required: one test that builds a status="ready" row with no attached asset — lbrn_geometry_test.rb:56 already has the helper — and asserts the SAME verdict from #thumbnails, #geometry, the file list cell and the detail page. Mutation-check it by restoring any one of the five inline expressions and confirming that test goes red.

### Cross-subsystem concerns raised by this lane

_Named, not solved — the lane was told to stay inside its boundary._

- app/javascript/controllers/thumbs_controller.js and measure_controller.js are the only consumers of this controller's two JSON doors, and both hand-mirror server-side rendering rules (thumbs_controller.js:83-88 replicates _thumb.html.erb's terminal badge text by comment-enforced agreement). Any change to the preview payload shape has to land in both repos-of-truth at once; out of scope here.
- The natural long-term owner of a preview display-state resolver is Maker::Preview / Maker::Previews (S16-adjacent), because four surfaces outside this boundary read the same tuple — projects/_attachment_group, projects/_card, models/_card, models/_hero_poster — and files_helper.rb:53-57 names them explicitly as un-swept adopters. I scoped finding 2 to this subsystem deliberately rather than proposing a shared model.
- Maker::Preview allows (status: "ready", asset not attached) at the model level — status inclusion validation and has_one_attached are independent, and GeneratePreviewJob attaches and marks ready as two separate statements (generate_preview_job.rb:113-120). Making that unrepresentable at the model or job level would remove finding 2's root cause rather than its symptom, but that is S16/preview-pipeline work, not S22's.
- FilesHelper#file_type_label and FilesController#sort_key must agree about the 'type' vocabulary (asserted only in prose at files_helper.rb:66-68 and files_controller.rb:858-861). Finding 1's registry would be the natural place to hold that agreement, but the helper's rendering side reaches into the views' concerns; I did not expand into it.

---

## S23 — Library mutation services & trash/browse web

**Lane verdict:** `recommend`

### S23-1 — Tools::LibraryFolders hand-rolls the dir-ancestry index twice, duplicating Maker::LibraryTree (and losing its cycle guard)

> **COORDINATOR VERDICT — ACCEPT.** Verified against the tree; no narrowing applied.

- **Category:** index-or-collection  
- **Lane confidence:** medium

**Evidence**

- app/controllers/tools/library_folders.rb:46 — `rows = current_user.nodes.present.where(kind: "dir").pluck(:node_id, :parent_node_id, :name)`, then `by_id = rows.index_by(&:first)` at :47. This is byte-for-byte the same query and the same id->row index that app/services/maker/library_tree.rb:14-16 builds in its constructor (`user.nodes.present.where(kind: "dir").pluck(:node_id, :parent_node_id, :name)` -> `@dirs` keyed by node_id, wrapped in an `Entry` Data type).
- app/controllers/tools/library_folders.rb:49-55 — the `label` lambda is a hand-rolled memoized recursive path builder: `prefix = parent && by_id[parent] ? label.call(parent) : ""` then `labels[nid] = "#{prefix}/#{name}"`. Because `labels[nid]` is only assigned AFTER the recursive call returns, there is no visited set and a parent cycle recurses until SystemStackError. Its own sibling nine lines above carries an explicit guard (library_folders.rb:21: `seen = Set.new # a parent cycle is not reachable through the app's own doors; do not hang if one is`), and app/services/maker/library_tree.rb:53-56 documents exactly this hazard ("a cycle is unrepresentable on a mount but perfectly representable in a row set, and an unguarded walk HANGS the sweep"). Three walks over the same rows, two guarded, one not.
- app/controllers/tools/library_folders.rb:17-29 — `folder_path_label` climbs parents with one `find_by` per hop (`node = node.parent_node_id && current_user.nodes.present.find_by(node_id: node.parent_node_id, kind: "dir")`), i.e. O(depth) queries, producing `"/#{names.join('/')}"`. app/services/maker/library_tree.rb:22-34 (`path_for`) and :57-70 (`each_ancestor`) are the same climb over an already-loaded index, with the `:broken` sentinel handled explicitly.
- app/controllers/tools/addons_controller.rb:200-201 — `@folders = folder_options` immediately followed by `@default_folder_label = folder_path_label(@default_parent_node_id)`. This is the ONLY call site of `folder_path_label` in the tree (grep over app/ and test/), so the whole-tree pluck the label method exists to avoid has already been paid one line earlier, and the label it computes is already an element of `@folders`.
- app/controllers/tools/library_folders.rb:12-16 — the comment justifying the second implementation: "NOT `folder_options.rassoc(id)`, which is the obvious version and the wrong shape: that plucks EVERY dir the user owns and builds a label for each, to use one of them... the chooser asks the server for a level at a time, so the whole tree is precisely what it no longer needs." Its premise is stale: app/controllers/tools/addons_controller.rb:195-200 says the flat list is deliberately still built ("BOTH shapes of 'where does this save go?' ... `folders` is the flat [label, node_id] list the shipped bundles build a <select> from"), and app/views/tools/addons/show.html.erb:47 still emits `data-addon-folders-value="<%= @folders.to_json %>"`. The page never dropped the flat picker.
- test/controllers/tools/library_folders_test.rb:20-25 — the only path-label test covers `folder_options` (`assert opts.any? { |label, _| label == "/Projects" }`). Nothing anywhere tests `folder_path_label`, so the two implementations are required to agree on label format with only one of them pinned.

**Current complexity / invalid states**

Three separate derivations of "the path from the library root to this dir" exist over one row set. Two live in this module (`folder_options`'s recursive lambda over a locally-built `by_id` index, and `folder_path_label`'s per-hop query walk), and a third — already typed, already cycle-guarded, already query-bounded — exists as `Maker::LibraryTree`. The two in-module copies must produce identical strings (they do today: both emit "/Projects/harbor", both fall back to the bare leaf when an ancestor is missing), but only one is under test and only one is cycle-safe. At the single call site both run back-to-back, so the O(depth) query walk recomputes a label the pluck one line above already has in hand.

**Proposed representation**

Build one `Maker::LibraryTree` per request and derive both shapes from it: `folder_options` maps its rows through the tree's `path_for`, and `folder_path_label` becomes a lookup into that same index (or a `path_for` call) rather than a second walk with its own queries. `LibraryTree` already exposes the exact primitives needed — `path_for(node_id)`, `ancestors_of`, `dir?` — over a typed `Entry` Data object and a single pluck, and it already answers the cycle/broken-chain case explicitly instead of by accident.

**Why simpler**

It removes a duplicated index construction and a duplicated path derivation without introducing anything new: the shared model already exists and is already tested (test/services/maker/library_tree_test.rb). It also removes the last unguarded parent walk in the module, so all ancestry climbing in this repo goes through one guarded implementation rather than three that happen to agree. And at the only call site it strictly reduces queries — the whole-tree pluck already happens, so the per-hop walk on top of it is pure duplicate work.

**Smallest credible implementation scope**

Confined to app/controllers/tools/library_folders.rb (both methods), plus memoizing one `Maker::LibraryTree` per request. `app/controllers/tools/addons_controller.rb:200-201` keeps calling the same two method names with the same signatures, and the JSON shapes on the wire (`@folders` as [label, node_id] with ROOT_LABEL/"" first, `@default_folder_label` as "/a/b") stay identical, so nothing in app/views/tools/addons/show.html.erb, the addon ctx at addons_controller.rb:718, or any external bundle changes.

**Affected files**

- `app/controllers/tools/library_folders.rb`
- `app/controllers/tools/addons_controller.rb`

**Regression risks and migration concerns**

Two behavioural details must be preserved deliberately, not inherited. (1) `LibraryTree#path_for` returns nil for a broken chain (a tombstoned or missing ancestor) whereas today's `folder_options` label and `folder_path_label` both degrade to the bare leaf ("/harbor") — dropping such folders from the picker would be a silent behaviour change, so the caller must map nil back to the lenient form or the tree must be asked for ancestors and joined locally. (2) `LibraryTree#path_for` returns "" for the root and no leading slash for a path, while both current methods emit a leading "/" and ROOT_LABEL for the root; the mapping is trivial but is where a regression would hide. Separately, this makes S23 depend on a service documented under the model-catalog area (§14k) — the class itself is generic ("reads `nodes`, the catalog all three backends populate", library_tree.rb:9) but the cross-area reuse is worth stating in review.

**Validation required**

test/controllers/tools/library_folders_test.rb already pins `folder_options`' output shape (root first, "/Projects" present) and `chosen_parent_node_id`; extend it with the missing `folder_path_label` cases before touching either method — root/blank, nested, foreign id, and a dir whose parent is tombstoned — so the equivalence claim above is pinned rather than argued. Mutation-check per §15: make the two derivations disagree (e.g. drop the leading slash in one) and confirm the new tests go red. test/system/box_save_folder_test.rb and test/system/addon_bundle_test.rb drive the real picker and cover the rendered end of it.

### Cross-subsystem concerns raised by this lane

_Named, not solved — the lane was told to stay inside its boundary._

- app/controllers/files_controller.rb:1153-1162 (`folder_crumbs`) is a fourth copy of the parent_node_id climb, with its own `visited` Set — outside this boundary, but any consolidation of the ancestry walk should count it. It is the copy library_browse_controller.rb:85-86 says it deliberately does not share with.
- `LibraryBrowseController#children` emits a `crumbs:` array (library_browse_controller.rb:17, built by the walk at :87-97) that no first-party client reads — app/javascript/lib/file_chooser.js builds its breadcrumb from its own `this.trail` (file_chooser.js:147). It cannot simply be dropped: the endpoint is handed to every addon bundle as `urls.children` (app/controllers/tools/addons_controller.rb:715), so its response shape is an out-of-repo contract. Naming it, not solving it.
- `Maker::LibraryFolder#create_child!` (library_folder.rb:37-39) serves two contracts: find-or-create for Maker::ProjectIntake#place (project_intake.rb:725-731 depends on the idempotence) and create-or-conflict for LibraryBrowseController#create_folder, which reconstructs the distinction with its own narrower `kind: "dir"`-scoped `exists?` at library_browse_controller.rb:44-46 — the same lookup ensure_segment then repeats at library_folder.rb:62. I considered and rejected this as a second finding: it costs one duplicate query and one predicate, and splitting the contract would add an entry point or kwarg for a gain too small to justify the churn across create_child!'s other callers.
- `Maker::LibraryTree` is documented under the model-catalog area (§14k / docs/invariants/model-intake.md); the finding above reuses it from the addons-facing tools layer. The class is generic by construction, but the ownership question belongs to whoever owns that file.

---

## S24 — Projects & models web layer

**Lane verdict:** `recommend`

### S24-1 — The "live attachments + how many went missing" step is authored per surface; PageNodes extracted the query but not the rule that consumes it

> **COORDINATOR VERDICT — PROMOTED.** More than duplication: the two controller spellings both report the count with a "NOT SILENT" comment; the third (_log_entry.html.erb:10) drops missing photos with no count and no message — doing exactly what the other two exist to prevent.

- **Category:** state-representation  
- **Lane confidence:** high

**Evidence**

- app/controllers/projects_controller.rb:81-86 — `@page_nodes = live_nodes_for(...)`, then `@attachments, missing = all_attachments.partition { |a| @page_nodes.key?(a.node_id) }`, then `@missing_attachment_count = missing.size`, with a 3-line "NOT SILENT" comment between the last two.
- app/controllers/models_controller.rb:53-58 — the identical three statements (`order(:position).to_a`, `live_nodes_for(... + [@model.cover_node_id])`, the same `partition`, the same `@missing_attachment_count = missing.size`), whose comment literally says "NOT SILENT, same sentence and same reason as the project panel's".
- app/views/projects/_log_entry.html.erb:10 — the THIRD surface spells the same rule a third way, in a view: `photos = entry.file_attachments.select { |a| @page_nodes.key?(a.node_id) }` — and implements only half of it: it filters, but nothing counts what it dropped, so a tombstoned build-log photo disappears with no notice while a tombstoned project file gets one.
- app/views/projects/_attachments.html.erb:69-74 and app/views/models/show.html.erb:159-164 — byte-for-byte the same six lines of markup (`p.muted.attachments-missing`, `pluralize(@missing_attachment_count, "attached file") + " no longer in your library."`, `link_to "Check the trash", trash_index_path`), the second carrying a comment saying it is "the same sentence, class and Trash link the project panel uses, because it is the same event".
- app/controllers/concerns/page_nodes.rb:20-35 — the concern stops at `live_nodes_for(node_ids) -> {node_id => Node}`; its own header records why it exists: "Written per-surface it diverged exactly the way this repo's other guards have" — models#show built an index and then handed `@by_role`/`@cover_att` the unfiltered list (broken <img>, an <iframe> 302ing to the whole Files listing, a forever-spinner hero).
- test/integration/web/page_nodes_test.rb:107-116 ("the models page says how many attachments are gone rather than hiding them silently") and test/integration/web/project_attachments_test.rb:64-75 assert the same `.attachments-missing` text/`trash_index_path` link against the two duplicated view fragments — the duplication is pinned twice, not once.
- test/integration/web/page_nodes_test.rb:140-153 ("a tombstoned build-log photo stays hidden") asserts only that the dead photo's cell is absent; there is no assertion of a count for that surface, which is why the half-implementation at _log_entry.html.erb:10 has never gone red.

**Current complexity / invalid states**

One rule — "an attachment whose node is not live must not render, and the user must be told how many were dropped" — is written out three times in three shapes (controller partition, controller partition, view select) plus two identical copies of the sentence that reports it. The repo's own record says this exact rule diverging per surface is what shipped the models#show defects that PageNodes was created to prevent; the concern consolidated the *lookup* but left the *decision* at each call site, so the divergence surface is smaller but still open — and one of the three sites already implements only half.

**Proposed representation**

Give PageNodes one more verb beside `live_nodes_for`, returning a tiny value object instead of a bare Hash — e.g. `live_partition(attachments, extra_ids: [])` -> `Data.define(:nodes, :live, :missing_count)`. Both `ProjectsController#show` and `ModelsController#show` become one call each (`@page_nodes`, `@attachments`, `@missing_attachment_count` assigned from its members, keeping the ivar names the views already use). Extract the six duplicated lines into one partial (house style puts a shared partial under its owning concept and lets the other side name the prefix — see app/views/projects/_move_conflict.html.erb:6-10, and files/_thumb already rendered from projects/) and render it from both views. `_log_entry.html.erb:10`'s filter calls the same predicate (`@page_nodes.key?`) via the object rather than reaching into a raw Hash, so the third surface is visibly the same rule with the count deliberately not shown.

**Why simpler**

The rule that has already caused shipped defects gets exactly one definition, and its half-implemented third instance becomes visible as such instead of reading as ordinary view code. Two identical view fragments and two identical 3-statement controller preambles collapse to one each, and a new attachment-rendering surface (there are already three) inherits the rule by calling one method rather than by remembering a comment. It is the same move the repo already made for the lookup, applied one step further out — not a new abstraction, an extension of an existing one whose header argues for precisely this.

**Smallest credible implementation scope**

Small: ~20 lines added to app/controllers/concerns/page_nodes.rb, ~10 lines deleted across the two controllers, one new partial replacing two 6-line fragments, one view line changed. No schema, no job, no port call.

**Affected files**

- `app/controllers/projects_controller.rb`
- `app/controllers/models_controller.rb`
- `app/views/projects/_attachments.html.erb`
- `app/views/models/show.html.erb`
- `app/views/projects/_log_entry.html.erb`
- `app/controllers/concerns/page_nodes.rb`

**Regression risks and migration concerns**

THREE THINGS THE CURRENT CODE ARGUES FOR AND THIS MUST NOT UNDO. (1) Liveness stays `user.nodes.present`, never `stat_all` — page_nodes_test.rb:177-201 exists solely to pin that an unmounted NAS must not read as "your files were deleted"; a value object holding both nodes and thumbs would invite exactly that collapse, so the helper must not touch the port. (2) ThumbnailMap stays OUT of the shared helper: models#show is cover-only on purpose (models_controller.rb:61-65) and page_nodes_test.rb:117-136 pins it at one enqueued job, while projects#show deliberately merges its union — merging the two would spend BACKFILL_LIMIT on 100 rows the models page never paints. (3) Keep the partition (not `&.`) so views keep dereferencing `@page_nodes[...]` plainly — page_nodes.rb:26-29 says why. Also: `.attachments-missing` is load-bearing (CSS at app/assets/stylesheets/projects.css:65 and four assertions), and the two views place the paragraph in different containers, so the partial must carry the <p> and no layout. Finally, adopting the helper for the build-log photos must NOT start folding photo losses into `@missing_attachment_count` as a side effect — that would change what project_attachments_test.rb:64-75 measures; whether photos should get their own notice is a product call, out of scope here. PageNodes itself sits just outside this subsystem's file list — flagged as a one-method addition, not a rewrite.

**Validation required**

Existing suites cover it without new tests: test/integration/web/page_nodes_test.rb (all six tests, including the FetchError and enqueue-budget ones), test/integration/web/project_attachments_test.rb:64-89, test/integration/web/projects_flow_test.rb, models_flow_test.rb, and page_query_budget_test.rb (constancy in N, per §14d — do not add a literal count). Mutation-check per §15: revert one surface to handing the view `all_attachments` and confirm the tombstone tests go RED for that surface, then restore. Run all three backend legs (`test`, `test-s3`, `test-chunk-remote`) since the query shapes differ per backend.

### Cross-subsystem concerns raised by this lane

_Named, not solved — the lane was told to stay inside its boundary._

- `Maker::Project` encodes "archived" twice — as a member of the 5-value `status` enum (app/models/maker/project.rb:7,61-71) and as the `archived_at` timestamp — and the two can disagree: `app/controllers/v1/maker/projects_controller.rb:34` permits `:status` and `:archived_at` independently, while nothing in the web layer reads `archived_at` at all. Model/v1 territory; naming it only.
- The web layer re-derives "is this archived" as a raw string comparison at eight in-boundary sites (projects_controller.rb:37; concerns/current_project.rb:26 and :42; current_project_controller.rb:10; views/projects/show.html.erb:12,20,28; views/projects/_card.html.erb:18) and two more in FilesController (files_controller.rb:425,427). A `#archived?` predicate plus a `not_archived` scope would centralise it, but the change lands in the model, so I have not made it a finding.
- `scope :active` on Maker::Project (app/models/maker/project.rb:25) means `status == "active"`, which is NOT "not archived" — it currently has no callers in app/, so it is a latent name trap sitting next to four `where.not(status: "archived")` call sites that a future reader could "tidy" into it, silently dropping planning/paused/done projects.
- `ProjectsController#index` (projects_controller.rb:36-39) materialises every project INCLUDING archived ones, with `includes(:file_attachments)`, purely so it can partition in Ruby and size the "N archived project(s)" link. Two scoped queries would render the same page; the payoff is small at realistic project counts, which is why it is a note and not a finding.
- Build-log photos whose node is tombstoned are dropped with no "no longer in your library" notice, unlike project and model attachments (see finding 1's evidence). That asymmetry may be intentional — it is a product decision about the build-log surface, not something the simplification requires changing.

---

## S25 — Auth, application shell & security headers

**Lane verdict:** `recommend`

### S25-1 — The email-unlock surface is unreachable and contradicts the settled `:time` unlock strategy

> **COORDINATOR VERDICT — ACCEPT.** Verified against the tree; no narrowing applied.

> **Schema gap in this entry:** affected_files records ABSOLUTE worktree paths (evidence is relative).

- **Category:** state-representation  
- **Lane confidence:** high

**Evidence**

- config/initializers/devise.rb:235 sets `config.unlock_strategy = :time`, and lines 229-234 argue for it explicitly (an emailed unlock link is meaningless for POST /v1/devices/login, and the Devise mailer's scope lookup is fragile outside a routed web request). That decision is documented and should stand.
- devise-5.0.4 lib/devise/rails/routes.rb:394-399 — `devise_unlock` draws `resource :unlock` ONLY `if mapping.to.unlock_strategy_enabled?(:email)`. Devise's `unlock_strategy_enabled?` (lib/devise/models/lockable.rb:200-203) is `self.unlock_strategy == strategy || (== :both && ...)`, so with `:time` it is false and NO unlock route exists. config/routes.rb:49-56 confirms no unlocks controller is registered either.
- app/views/users/unlocks/new.html.erb:1-14 is a complete 'Resend unlock instructions' form posting to `unlock_path(resource_name)` — a route helper that is never drawn. The file can never render; there is no Users::UnlocksController (app/controllers/users/ holds only confirmations, omniauth_callbacks, passwords, registrations, sessions).
- app/views/users/mailer/unlock_instructions.html.erb:7 links to `unlock_url(@resource, unlock_token: @token)`. devise-5.0.4 lib/devise/models/lockable.rb:45 guards the send with `if unlock_strategy_enabled?(:email) && opts.fetch(:send_instructions, true)`, so this mail is never sent under `:time`.
- app/views/users/shared/_links.html.erb:17-19 gates the 'Didn't receive unlock instructions?' link on `resource_class.unlock_strategy_enabled?(:email)` — a branch that is statically false for this configuration, wrapping a call to the undefined `new_unlock_path`.
- db/schema.rb:442 and :447 still carry `users.unlock_token` and `index_users_on_unlock_token` (unique). devise-5.0.4 lib/devise/models/lockable.rb:33 only requires that column when `:email` unlock is enabled, so nothing in this app can ever write it.

**Current complexity / invalid states**

The app's account-lockout recovery model is stated twice, contradictorily. The initializer says recovery is purely time-based (10 attempts -> locked -> auto-unlock after 1 hour, no mail, config/initializers/devise.rb:239,242, with `last_attempt_warning = false` at :247). The view tree says recovery is email-based: a full unlock request page, an unlock-instructions mail template, and a nav link for both. A reader cannot tell from the code which model is real without going into the Devise gem's route drawer, and a reader who trusts the views will misdescribe what a locked-out user experiences — which, with `config.paranoid = true` (devise.rb:102), is an hour of 'Invalid Email or password' with no mail and no self-serve page.

**Proposed representation**

Keep `unlock_strategy = :time` (the comment at devise.rb:229-234 settles it) and make the file tree agree with it: delete app/views/users/unlocks/ and app/views/users/mailer/unlock_instructions.html.erb, and delete the dead branch at app/views/users/shared/_links.html.erb:17-19. One representation of the lockout-recovery model, in the config, where the argument for it already lives. If the branch is worth keeping as future-proofing, it should carry a one-line comment saying it is inert under `:time`, so the next reader does not have to re-derive it from the gem.

**Why simpler**

It removes an entire user-facing flow that does not exist, so the set of auth surfaces a reader must reason about drops from six to five and every remaining view under app/views/users/ is reachable. It also collapses the lockout-recovery model from two contradictory statements to one, so `unlock_strategy` becomes the single place that answers 'what happens after a lockout' — currently the honest answer requires reading Devise's routes.rb.

**Smallest credible implementation scope**

Delete two view files and three lines of ERB. No controller, model, route or test change. The follow-on `users.unlock_token` column + unique index drop is a separate S13/migration decision and is listed as a cross-subsystem concern rather than included here.

**Affected files**

- `app/views/users/unlocks/new.html.erb`
- `app/views/users/mailer/unlock_instructions.html.erb`
- `app/views/users/shared/_links.html.erb`
- `config/initializers/devise.rb`

**Regression risks and migration concerns**

The only real risk is a later decision to flip `unlock_strategy` to `:email` or `:both`, which would then need the two views regenerated (`rails g devise:views` reproduces them verbatim). That is cheap, and the initializer comment argues the flip should not happen. Deleting the `_links` branch is the one edit with any subtlety: if the strategy were flipped later, the link would silently not appear — so if that is a concern, keep the branch and comment it rather than deleting it. Do NOT let this finding be read as a recommendation to change `unlock_strategy` itself; the comment at devise.rb:229-234 is a documented decision and this finding endorses it.

**Validation required**

Before: confirm no unlock route is drawn (`bin/rails routes | grep unlock` returns nothing) and that `User.unlock_strategy_enabled?(:email)` is false. After: run the web leg (`bin/rails test test/integration/web/`) — auth_pages_test.rb, devise_auth_flow_test.rb and account_enumeration_test.rb render the sign-in/sign-up/reset pages that include `users/shared/_links`, so a broken partial fails there. Mutation check: temporarily set `unlock_strategy = :both`, confirm the unlock route appears and the deleted views are then genuinely required — that is the evidence the deletion is contingent on the config and not on nothing.

### S25-2 — Mail has no owner: ApplicationMailer and both mailer layouts are inert, and the from-address is stated twice

> **COORDINATOR VERDICT — ACCEPT.** Verified against the tree; no narrowing applied.

> **Schema gap in this entry:** affected_files records ABSOLUTE worktree paths (evidence is relative).

- **Category:** ownership  
- **Lane confidence:** high

**Evidence**

- app/mailers/application_mailer.rb:1-4 declares `class ApplicationMailer < ActionMailer::Base`, `default from: "from@example.com"`, `layout "mailer"`. Grepping `ApplicationMailer` across app/, lib/, config/ and test/ returns exactly that one line — it has zero subclasses and zero senders.
- config/initializers/devise.rb:33 leaves `# config.parent_mailer = 'ActionMailer::Base'` commented, so Devise::Mailer inherits ActionMailer::Base directly, not ApplicationMailer. Every mail this app actually sends (confirmation, reset, password_change, email_changed) is a Devise::Mailer mail.
- config/initializers/devise.rb:27 sets `config.mailer_sender = "no-reply@tinkerex.app"` — the real from-address — while app/mailers/application_mailer.rb:2 asserts a different one. Neither file references the other; nothing in test/ or app/ mentions either string.
- actionmailer-8.1.3.1 lib/action_mailer/base.rb contains no `layout "mailer"` declaration (line 31 is a doc comment showing users how to write one). Layout resolution for Devise::Mailer therefore falls to the implied layout name `devise/mailer`, which does not exist, so app/views/layouts/mailer.html.erb:1-13 and app/views/layouts/mailer.text.erb:1 are rendered by nothing.
- app/views/users/mailer/ holds five .html.erb templates and no .text.erb — they are HTML fragments (`<p>Hello ...</p>`, e.g. app/views/users/mailer/confirmation_instructions.html.erb) written on the assumption that something wraps them in the `<!DOCTYPE html>` shell that app/views/layouts/mailer.html.erb:1-2 provides. Nothing does.

**Current complexity / invalid states**

'How does this app send mail, and who it is from' is answered by four files, three of which are decorative. ApplicationMailer looks like the base class and is not; layouts/mailer.html.erb and layouts/mailer.text.erb look like the mail shell and are not applied; the from-address that is actually used is a Devise config line that the mailer class contradicts. The failure mode is quiet and forward-looking: the day anyone adds a real mailer (a build-log digest, a share-link notice), it inherits ApplicationMailer, picks up `from@example.com`, and ships from a placeholder domain with nothing red — the same 'green over something that never worked' shape CLAUDE.md 15 names as this repo's dominant failure.

**Proposed representation**

Give mail one owner. Set `config.parent_mailer = 'ApplicationMailer'` (config/initializers/devise.rb:33) so Devise::Mailer inherits the app's base class, then put the sender in one place: either keep `config.mailer_sender` and delete the `default from:` line, or move the address into ApplicationMailer and drop `mailer_sender`. Either way the two mailer layouts start being applied to the five Devise templates they were written for, and one line answers 'who is this from'. The strictly smaller alternative, if wiring Devise through ApplicationMailer is unwanted, is to delete app/mailers/application_mailer.rb and both mailer layouts and let devise.rb:27 be the whole story — also one owner, one fewer file to misread.

**Why simpler**

It removes a class of file that reads as load-bearing and is not. After the change, `grep -rn 'from ' app/mailers config/initializers/devise.rb` has one answer instead of two contradictory ones, and the mailer layout either applies or does not exist — no third state where it sits in the tree looking applied. This is ownership, not style: today no file can be pointed at as 'the mail configuration'.

**Smallest credible implementation scope**

One uncommented line in config/initializers/devise.rb, one deleted or edited line in app/mailers/application_mailer.rb. No model, controller or view changes. (Or: delete three files, if the delete-instead variant is chosen.)

**Affected files**

- `app/mailers/application_mailer.rb`
- `config/initializers/devise.rb`
- `app/views/layouts/mailer.html.erb`
- `app/views/layouts/mailer.text.erb`

**Regression risks and migration concerns**

Pointing `parent_mailer` at ApplicationMailer changes the rendered mail body: the five Devise templates gain the `<!DOCTYPE html>` wrapper from app/views/layouts/mailer.html.erb. That is the intended outcome but it is a visible change, so check the two token-extraction assertions in test/integration/web/devise_auth_flow_test.rb:115 and :160, which scrape `confirmation_token=` / `reset_password_token=` out of `mail.body.encoded` — both are regex-over-body and survive a layout, but confirm rather than assume. Second risk: ApplicationMailer's `default from:` would override `Devise.mailer_sender` for Devise mail once the inheritance is wired, which is exactly why the two addresses must be reconciled in the same edit rather than left to interact. Order matters — do not uncomment parent_mailer while `from@example.com` is still in place, or every confirmation mail ships from the placeholder.

**Validation required**

Drive a real send rather than reading the files, per CLAUDE.md 14e: run test/integration/web/devise_auth_flow_test.rb and assert on `ActionMailer::Base.deliveries.last` — that `mail.from` is the single intended address, and that `mail.body.encoded` now contains `<!DOCTYPE html>` (proving the layout is applied, which nothing currently checks). Mutation check: revert `parent_mailer` to the comment and confirm the layout assertion goes RED; a test that passes either way is asserting nothing, which is the state the mailer layouts are in today.

### Cross-subsystem concerns raised by this lane

_Named, not solved — the lane was told to stay inside its boundary._

- S13 (User model) — `User#password_required?` at app/models/user.rb:173-177 returns false whenever `encrypted_password.blank? && password.blank?`, a self-fulfilling rule: an absent password proves a password is not required. Lines 174 already cover the two legitimate passwordless cases (`omniauth_signup` transient flag, `omniauth_identity?`), so line 175 is the over-broad catch-all. Its cost lands in MY subsystem: app/controllers/users/registrations_controller.rb:20-31 re-implements Devise's whole error path (build_resource / errors.add(:password, :blank) / clean_up_passwords / set_minimum_password_length / respond_with_navigational) purely to reject a blank web password the model would otherwise accept. The controller comment at :14-19 argues for the placement, and it is right given the model as written — but the underlying shape is 'which door you came through' standing in for a field. Fixing it means editing User, which is S13's call, not mine.
- S13 / migrations — db/schema.rb:442 and :447 carry `users.unlock_token` plus a unique index that can never be written while `config.unlock_strategy = :time` (devise-5.0.4 lib/devise/models/lockable.rb:33,45). Dropping the column and index is the data-structure half of my first finding and belongs with the User schema, not with the views I own.
- CSP flip checklist (spans S25 + the files/models view subsystems) — config/initializers/content_security_policy.rb:92-95 nonces `script-src`, and the plan at :97-100 is to flip `report_only` to false once violations are clean. A nonce does not authorize inline EVENT HANDLERS: `script-src 'self' 'nonce-...'` blocks `onchange=` unless `'unsafe-hashes'`/`'unsafe-inline'` is present. app/views/layouts/application.html.erb:48 (the current-project selector, in my boundary) uses `onchange: "this.form.requestSubmit()"`, and four more sit outside it — app/views/models/index.html.erb:16,21, app/views/files/index.html.erb:181,186, app/views/files/_ext_filter.html.erb:47. So the topbar project switcher and every sort/filter select stop submitting the moment the policy is enforced, on a 200 response with nothing red. This is a blocker for the documented flip, not a simplification, and I am flagging rather than solving it because four of the five sites are другой subsystem's views. The fix is one small Stimulus controller replacing all five (test/stimulus_hygiene_test.rb already guards that identifiers resolve).
- Trivial, noted only so the next auditor does not re-derive it: app/views/pwa/manifest.json.erb and app/views/pwa/service-worker.js are unrouted Rails scaffold — config/routes.rb draws no pwa routes and the manifest <link> is commented out at app/views/layouts/application.html.erb:15. The service worker is 26 lines of commented-out example. Below the threshold for a finding on its own; fold it into any future cleanup of the shell.

---

## S26 — v1 device-token API

**Lane verdict:** `recommend`

### S26-1 — The v1 wire shape of a resource has no single definition: attachment is spelled 3× byte-identically, build-log entry and BOM line each 2× with silently different key sets

> **COORDINATOR VERDICT — BLOCKED.** Cross-repo: reshapes seven serializer key sets. Also a PREREQUISITE of S16-2 — the three byte-identical attachment_json copies S16-2 must edit are exactly what S26-1 collapses.

> **Schema gap in this entry:** `category` field absent.

- **Category:** _(not recorded)_  
- **Lane confidence:** high

**Evidence**

- app/controllers/v1/maker/file_attachments_controller.rb:36-39 — `def attachment_json(att) { id:, node_id:, version_id:, role:, label:, position: } end`
- app/controllers/v1/maker/items_controller.rb:72-75 — the same method body, byte-identical (verified: the extracted method text of all three md5s to 961da586cddc4810afcc979d82515fb7), used at items_controller.rb:66 for the nested `file_attachments` array of `#show`
- app/controllers/v1/maker/projects_controller.rb:55-58 — the third byte-identical copy, used at projects_controller.rb:46
- app/controllers/v1/maker/build_log_entries_controller.rb:31-35 — `entry_json` emits id, project_id, body(to_plain_text), entry_type, logged_at, created_at, updated_at
- app/controllers/v1/maker/projects_controller.rb:50-53 — a SECOND build-log-entry shape emitting only id, body(to_plain_text), entry_type, logged_at; the two are coupled by nothing but the English comment on line 50 ("See V1::Maker::BuildLogEntriesController#entry_json")
- app/controllers/v1/maker/bom_lines_controller.rb:36-42 — `line_json` (13 keys incl. bom_id, inventory_item_id, node_id, part_name, supplier_id, created_at, updated_at) vs app/controllers/v1/maker/boms_controller.rb:81-85 — `rollup_line_json`, an independently written 8-key subset that adds `target`
- app/controllers/v1/maker/collections_controller.rb:27 — a third, inline spelling of an item (`{ id:, title:, item_type: }`) beside items_controller.rb:55-70's `item_json`
- test/integration/v1/maker/items_test.rb:44 and test/integration/v1/maker/projects_test.rb:50-51 assert only `assert_equal [], body["file_attachments"]` / `[]` for build_log_entries; test/integration/v1/maker/file_attachments_test.rb:24-26 asserts only node_id and role — so no test observes the nested attachment or build-log key sets at all, and drift between the copies is invisible to a green suite

**Current complexity / invalid states**

Each of the fourteen controllers writes its own hash literal per resource, and four of them (boms, inventory_items, items, projects) already carry an internal `full:` projection idiom (e.g. projects_controller.rb:37-48, items_controller.rb:55-70) for the summary-vs-full split. The idiom breaks the moment a resource is rendered from a DIFFERENT controller: the nesting controller writes an independent literal instead of asking the owning controller for a projection. The result is one resource with N definitions — three identical for file attachments, two divergent for build-log entries, two divergent for BOM lines, three for item — and no mechanism, test or otherwise, that notices when they stop agreeing. Adding a column to the attachment wire today is three edits in three files that nothing forces you to make together.

**Proposed representation**

One plain module per resource family in the v1 namespace — e.g. `V1::Maker::Wire` with `Wire.file_attachment(att)`, `Wire.build_log_entry(entry, full: true|false)`, `Wire.bom_line(line, rollup: true|false)` — each returning the full hash and expressing the narrower nested variants as a NAMED projection (`FULL.slice(*SUMMARY_KEYS)` or an explicit key list) rather than as a second literal. Controllers call the function; the three identical attachment copies collapse to one call site each, and the two divergent pairs become one definition plus one named subset, so 'this nesting deliberately omits project_id/created_at/updated_at' becomes a data value you can read in one place instead of a difference you have to diff two files to see.

**Why simpler**

It removes an entire class of state the code currently permits: today the same resource can have two disagreeing wire shapes and nothing — not a type, not a test, not a comment that the compiler reads — prevents it. After the change the disagreement is unexpressible; a nested variant can only be a subset of the one definition, and the subset is named. This is not moving branching behind a new type: there is no branching to move, only literals to deduplicate, and the projection keys become the single fact a reviewer checks. It also matches the idiom the subsystem already chose for the in-file case (`full:`), so it makes one rule out of two.

**Smallest credible implementation scope**

Small and mechanical: add one file (~60 lines) under app/controllers/v1/maker/ or app/serializers/, replace 3 attachment methods, 2 build-log methods, 2 BOM-line methods and (optionally) the inline collection-item literal with calls. No route, model or auth change; no change to `V1::BaseController` or the Authentication concern.

**Affected files**

- `app/controllers/v1/maker/file_attachments_controller.rb`
- `app/controllers/v1/maker/items_controller.rb`
- `app/controllers/v1/maker/projects_controller.rb`
- `app/controllers/v1/maker/build_log_entries_controller.rb`
- `app/controllers/v1/maker/bom_lines_controller.rb`
- `app/controllers/v1/maker/boms_controller.rb`
- `app/controllers/v1/maker/collections_controller.rb`

**Regression risks and migration concerns**

The real risk is ACCIDENTAL WIDENING, and it is the same risk build_log_entries_controller.rb:27-30 already records in prose: the shipped Rust client declares `pub body: String` with no `serde(default)`, so the wire is a strict contract and a projection that quietly hands the nested renderer the full key set is an observable API change, not a refactor. `body` must stay `to_plain_text` in BOTH build-log spellings. Do not 'harmonise' the divergent pairs while consolidating them — reproduce today's exact key sets first, and treat any widening as a separate, argued change. Second, minor: `rollup_line_json` calls `line.resolved_target`, so the rollup projection adds a key rather than only removing them; keep that explicit rather than making `target` conditional on a flag whose default is easy to get wrong.

**Validation required**

Before touching anything, add exact key-SET assertions at all seven sites (`assert_equal %w[id label node_id position role version_id], body["file_attachments"].first.keys.sort` etc.) for: POST /v1/maker/items/:id/file_attachments, GET /v1/maker/items/:id, GET /v1/maker/projects/:id (both nested arrays), GET /v1/maker/projects/:id/build_log_entries, GET /v1/maker/boms/:id/rollup, and GET /v1/maker/boms/:bom_id/bom_lines. They pass on today's tree — that is the point; they are the before/after equality check. Mutation-check them per CLAUDE.md §15 by adding one key to the shared function and confirming each goes RED (today the nested ones cannot go red, because items_test.rb:44 and projects_test.rb:50-51 only assert `[]`). Then bin/ci's three backend legs (test, test-s3, test-chunk-remote) must report identical run counts.

### S26-2 — `Maker::Task`'s status/completed_at pair is a derived invariant maintained by each caller, spelled four ways across three files — and one sanctioned door produces the invalid pair

> **COORDINATOR VERDICT — MERGED.** Strict subset of S15-1 (same rule, same files). S15-1 is authoritative.

> **Schema gap in this entry:** `category` field absent.

- **Category:** _(not recorded)_  
- **Lane confidence:** medium

**Evidence**

- app/controllers/v1/maker/tasks_controller.rb:14-19 — create: `task.completed_at ||= Time.current if task.status == "done"`. The `||=` is vacuous here: task_params (tasks_controller.rb:40-42) does not permit :completed_at, so it is always nil at that point.
- app/controllers/v1/maker/tasks_controller.rb:21-31 — update: stamps `Time.current` only `if task.completed_at.nil?`, and nulls the stamp for any other present status. A third rule (leave alone) applies when status is absent.
- app/models/maker/task.rb:44-46 — `complete!` does `update!(status: "done", completed_at: Time.current)`; the model itself carries NO validation or callback tying the two columns, only `scope :open, -> { where.not(status: "done") }` (task.rb:42), which reads status alone.
- app/controllers/projects/tasks_controller.rb:44-51 — the web door's `case attrs["status"]`: done → `Time.current` UNCONDITIONALLY (its own comment, lines 42-43, notes this deliberately differs from "v1's `completed_at ||=`"), else-present → nil, nil/"" → leave alone. So re-PATCHing status="done" on an already-done task refreshes the stamp on the web and preserves it on v1 — one operation, two answers.
- app/controllers/projects/tasks_controller.rb:18-27 with :status permitted at line 102 — create applies NO derivation at all, so `POST /projects/:slug/tasks {task:{title:"x", status:"done"}}` persists status="done" with completed_at NULL. That is precisely the pair the same file's update comment (lines 34-36) calls one "which no sanctioned path can produce".
- test/integration/web/project_tasks_test.rb:64 creates `status: "done"` with no stamp, while lines 98, 131 and 113 must remember to pass `completed_at: Time.current` alongside `status: "done"` — the fixtures are re-deriving the invariant by hand, the usual symptom of a rule that lives outside the model.

**Current complexity / invalid states**

Two columns encode one fact ('is this task finished, and when'), and every writer is responsible for keeping them consistent. There are four spellings of the derivation and they do not agree: v1 create (stamp if done), v1 update (stamp only if currently unstamped), web update (always re-stamp), web create (never stamp). The web controller's own comment already argues about not becoming a 'fourth spelling', which is evidence the multiplication is felt rather than hypothetical. Nothing rejects the contradictory rows, so `status="done", completed_at=NULL` and `status="todo", completed_at=<time>` are both representable and both reachable.

**Proposed representation**

Make the derivation total in `Maker::Task`: a `before_validation` that, when `status_changed?`, sets `completed_at = Time.current` on entry to "done" and `nil` on exit from it (leaving an existing stamp alone when status is unchanged). `complete!` then becomes `update!(status: "done")`. The two v1 controller actions drop their pre-computation entirely (tasks_controller.rb:16 and 23-28 delete), and the web door's `case` collapses to the plain `task.update(task_params)` it already wants. The stamp stays derived IN MEMORY before validation, so `Projects::TasksController`'s hard-won 'one validated write, refusal is total' property (its comment at lines 29-43, pinned by project_tasks_test.rb:110-123 and :142-152) is preserved, not weakened — a refused save writes neither column.

**Why simpler**

One rule in one place instead of four rules in three files that a reader must diff to compare. The invalid combinations stop being something callers are trusted to avoid and become unrepresentable through any door — including the two doors that get it wrong today. It also deletes the vacuous `||=` at tasks_controller.rb:16 rather than leaving a line that reads as a guard but cannot guard anything.

**Smallest credible implementation scope**

Small: ~8 lines added to app/models/maker/task.rb, ~10 lines deleted from app/controllers/v1/maker/tasks_controller.rb, ~5 from app/controllers/projects/tasks_controller.rb. No migration (existing contradictory rows are left alone unless a backfill is separately wanted).

**Affected files**

- `app/controllers/v1/maker/tasks_controller.rb`
- `app/models/maker/task.rb`
- `app/controllers/projects/tasks_controller.rb`

**Regression risks and migration concerns**

(1) One deliberate behaviour change must be chosen and stated: today the web door re-stamps a task already in "done" and v1 does not. A `status_changed?`-guarded callback adopts v1's answer (no re-stamp) for both. That is the more defensible rule, but it IS a change to the web door and to nothing that currently tests it — say so rather than letting it ride. (2) `app/controllers/projects/tasks_controller.rb` is outside this subsystem's ownership boundary; the model callback is what makes its `case` redundant, but removing it there is a separate, coordinated edit. (3) A callback firing on any save is the classic over-reach — it must be guarded on `status_changed?` so an unrelated title edit never touches the stamp; project_tasks_test.rb:110-123 is the existing test that would catch the unguarded version.

**Validation required**

Per CLAUDE.md §15, mutation-check the new callback: remove the `status_changed?` guard and confirm a title-only PATCH on a done task goes RED; remove the exit-from-done arm and confirm project_tasks_test.rb:95-100 goes RED. Add the two cases nothing covers today — `POST /projects/:slug/tasks {status: "done"}` asserting `completed_at` present, and `POST /v1/maker/tasks {status: "done"}` — and confirm the web one FAILS before the change and passes after (that is the finding's proof, not a formality). Note §15's timestamp warning: assert `completed_at` presence/nil, or `travel_to` a separated time, never a `.to_i` comparison. Then bin/ci's three backend legs.

### Cross-subsystem concerns raised by this lane

_Named, not solved — the lane was told to stay inside its boundary._

- app/controllers/projects/tasks_controller.rb (web layer, S-other) holds the third and fourth spellings of the task status/completed_at derivation, and its #create is the door that actually produces the invalid pair. Finding 2's model-level fix makes its #update `case` redundant, but that deletion belongs to whoever owns the web tasks controller.
- The v1 wire shapes in finding 1 are consumed by the sibling Rust client (chaim354/tinkerex-client), which deserializes strict structs — build_log_entries_controller.rb:27-30 records `pub body: String` with no serde(default). Any key-set change is a cross-repo wire change, not a local refactor; the consolidation must reproduce today's key sets exactly.
- app/controllers/models/attachments_controller.rb:36 and app/controllers/projects/attachments_controller.rb:211 render further, narrower attachment shapes for the web layer. They are a different contract (Turbo/JSON for the browser) and were deliberately NOT folded into finding 1's scope.

---

## S27 — Measure view & print sheet (browser)

**Lane verdict:** `recommend`

### S27-1 — Drawing-scoped state has three partial definitions (connect / draw / showPoster) and no single reset

> **COORDINATOR VERDICT — ACCEPT.** Verified against the tree; no narrowing applied.

- **Category:** state-representation  
- **Lane confidence:** medium

**Evidence**

- measure_controller.js:60-68 — connect() initialises five fields (aborted, selected, hovered, marked, nodeByShape, selecting).
- measure_controller.js:88-100 — showPoster() clears six: `this.selected = this.hovered = this.svg = null`, `this.marked.clear()`, `this.nodeByShape.clear()`, `this.selecting = false`. It does NOT clear allShapes, byObject, colors or home.
- measure_controller.js:136-137,150,168,171 — draw() re-initialises only four of the same family: `this.colors = payload.colors || {}`, `this.byObject = new Map()`, `this.home = [...]`, `this.allShapes = payload.shapes`, `this.svg = svg`. It leaves selected/hovered/marked/selecting untouched.
- measure_controller.js:166 — `this.nodeByShape.set(s, top.__visible || top)` writes INTO the existing map rather than a fresh one, so a second draw() accumulates entries for the previous SVG's nodes alongside the new ones.
- measure_controller.js:136-144 — the empty-payload early return (`if (!payload.shapes.length) { this.setStatus(...); return }`) sits AFTER colors/byObject are replaced but BEFORE allShapes/svg, so an empty payload leaves allShapes and svg describing the previous draw.
- test/system/measure_print_test.rb:2728-2731 — the suite already treats an un-emptied nodeByShape as a defect in its own right: `assert_equal [0,0,false], in_measure_controller("[c.marked.size, c.nodeByShape.size, c.selecting]")` with the comment "a Map never emptied is a live reference to every node of every file measured in this tab".
- app/assets/stylesheets/application.css:131,138 — `.measure-actions { display: none }` until `--ready`, which is what makes the ✕ Image path unreachable mid-load but leaves `.measure-launch` (line 130/137) clickable for the whole of the first load, so load() is re-entrant.

**Current complexity / invalid states**

Ten fields belong to "the payload currently on the stage" (colors, byObject, home, view, allShapes, svg, nodeByShape, marked, selected, hovered) but there is no place that says so. Three code paths each hold a partial, hand-maintained list of them: connect() names five, showPoster() clears six, draw() replaces four and mutates a fifth in place. Keeping the three lists in agreement is exactly the "N copies that must agree" shape CLAUDE.md §14b/§14d record; showPoster()'s own comment (lines 93-96) argues at length for why leaving one of them populated is silently wrong, but draw() — the other entry point into the same state — was never given the same treatment.

**Proposed representation**

One `resetDrawing()` private that clears every drawing-scoped field, called at the TOP of draw() and from showPoster() (which then keeps only its DOM/status work). The stronger form, if the test-touch cost is acceptable, is to hold that state in one replaced-wholesale object — `this.drawing = { shapes, byObject, colors, nodeByShape, svg, home }` with selection/marks alongside — so `showPoster()` is `this.drawing = null` and `draw()` is one assignment, making "these fields all belong to one payload" structural rather than remembered.

**Why simpler**

It converts an agreement maintained across three methods into one definition. `draw()` becomes correct-by-construction for the cases it silently is not today: a second load() (reachable by clicking Measure twice, since the launch button stays visible until --ready is applied at the END of draw()) currently leaves nodeByShape holding both SVGs' nodes, and any mark or selection made between the two draws survives pointing at shape objects and detached DOM nodes from the payload that was replaced — the precise failure showPoster()'s comment already names, on the one path that lacks the clear.

**Smallest credible implementation scope**

One new ~10-line private method plus two call sites; net line count roughly flat. If the field names are preserved (marked, nodeByShape, allShapes, svg, home) no test changes are needed — the three `in_measure_controller` probes at measure_print_test.rb:2604-2610, 2731 and 2754 read exactly those names. Optionally add a re-entrancy guard or load epoch to load() so a superseded payload is dropped rather than drawn.

**Affected files**

- `app/javascript/controllers/measure_controller.js`

**Regression risks and migration concerns**

Clearing `this.selecting` inside draw() would be a behaviour change (today select mode survives a re-draw), so mode state should be left out of the drawing object or explicitly preserved. The empty-payload early return must run AFTER the reset, or an empty payload would go on showing the previous drawing. The object form would require updating the three `in_measure_controller` probes, which are load-bearing tests — prefer the flat form unless that churn is wanted.

**Validation required**

Existing system tests cover the reset paths ("✕ Image drops the print set and leaves select mode" 2719+, "Reset returns the view home and empties the print set" 2595+). Add one driving a double Measure click and asserting `c.nodeByShape.size` equals the shape count, not twice it — mutation-check by restoring the accumulating `set` into a non-cleared map and confirming red.

### S27-2 — Selection and hover are keyed by DOM node while marks are keyed by shape, requiring three ad-hoc links and two spellings of "the node to style"

> **COORDINATOR VERDICT — ACCEPT.** Verified against the tree; no narrowing applied.

- **Category:** state-representation  
- **Lane confidence:** medium

**Evidence**

- measure_controller.js:62-63 vs 66 — `this.selected = null` / `this.hovered = null` hold DOM nodes, while `this.marked = new Set()` holds payload shape objects (line 457 `this.marked.add(shape)`).
- measure_controller.js:308,317-318,322 — three separate links are maintained on the DOM: `node.__shape = shape`, `hit.__shape = shape`, `hit.__visible = node`, `group.__visible = node`.
- measure_controller.js:321 — the code comment concedes the duplication itself: "So draw() can resolve a group to the line it should style, the same way styleNode() does."
- measure_controller.js:166 (`this.nodeByShape.set(s, top.__visible || top)`) and measure_controller.js:365-366 (`styleNode(node) { return node.__visible || node }`) — two spellings of one rule ("which node carries the highlight class"), which must agree or the marked class and the hover/selected classes land on different elements.
- measure_controller.js:242 and 396 — every consumer of `selected` immediately dereferences back to the shape: `[this.selected.__shape]` in print(), `const shape = node.__shape` in pick().
- measure_controller.js:372 — `if (node === this.hovered) return` compares NODES, but one open contour is two hit targets (the fat twin at 316-318 and the drawn line, both hit-testable per application.css:144,146), so moving the pointer between them within one contour reads as a hover change and re-toggles the class on the same visible element.
- docs/invariants/measure-view.md:304-309 and test/system/measure_print_test.rb:2554-2560 — the rule that the class must land on the DRAWN line (not the group, not the twin) is mutation-checked, and is currently enforced at two places rather than one.

**Current complexity / invalid states**

Three different identities are in play for one contour — the payload shape, the element the pointer hit, and the element that carries the highlight class — and the controller maintains all three cross-links by hand (`__shape`, `__visible`, `nodeByShape`) while storing selection/hover in the second currency and marks in the first. `styleNode()` is called at eight sites purely to translate between them.

**Proposed representation**

Make the payload shape the single currency for all three selection states: `selected`, `hovered` and `marked` all hold shapes, and `nodeByShape` — which already stores exactly the drawn line (line 166) — is the one index from shape to the element that carries a class. `shapeAt(event)` returns the shape rather than the node. `styleNode()` and both `__visible` assignments disappear; `__shape` survives with one job, the hit-test back-pointer from any hit-testable element.

**Why simpler**

One key type instead of two, one index instead of three ad-hoc links, and the invariant "the class lands on the drawn line" gets exactly one enforcement point (the `nodeByShape.set` call) instead of two that must agree. The hover early-return also becomes correct per contour rather than per hit target: today the same contour can be entered twice through its twin and its line.

**Smallest credible implementation scope**

Confined to one file: draw() (166), contourNode() (308-322), shapeAt() (353-359), styleNode() (deleted), hover/clearHover (370-380), pick() (388-396), clearSelection() (424-427) and print() (241-243). Roughly 30 lines touched, net smaller. No test changes expected — the suite asserts DOM classes and `c.marked.size` / `c.nodeByShape.size`, both of which keep their names and meanings.

**Affected files**

- `app/javascript/controllers/measure_controller.js`

**Regression risks and migration concerns**

`shapeAt` must keep asking `document.elementFromPoint` rather than trusting `event.target` (the pointer-capture retargeting documented at 340-352 is a measured bug, not a style choice) and `__shape` must stay on BOTH the twin and the drawn line or open contours stop being clickable. Paint-order hit dispatch (measure-view.md:274-281) is untouched. Bitmap shapes must remain in nodeByShape — they are, since line 308 runs before the early return at 309.

**Validation required**

The existing tests carry this: "marking an open contour marks the line you can see" (measure_print_test.rb:2562+, asserts the COMPUTED stroke on the polyline), the hover/selected class assertions, and the nested-plate paint-order tests. Mutation-check by pointing `nodeByShape` at the group instead of the drawn line and confirming the computed-stroke assertion goes red — the guard that made the two-spelling rule safe is already in place.

### Cross-subsystem concerns raised by this lane

_Named, not solved — the lane was told to stay inside its boundary._

- measure_controller.js:532-537 `unionOf(shapes)` is a line-for-line duplicate of the already-exported `unionBox(shapes)` at print_sheet.js:58-65, and the controller already imports from that module (measure_controller.js:2). Deliberately NOT raised as a finding: it is a six-line pure function with no invariant attached, so folding it is line-count reduction rather than a structural simplification. Worth doing opportunistically alongside other work in this file, not on its own.
- print_sheet.js:212 `contourNode(doc, shape)` and measure_controller.js:292 `contourNode(shape)` share only the tag choice and the points join; a shared helper would have to be threaded a `doc` (the print document is a different realm, print_sheet.js:604-607) for a two-line gain. Recommending AGAINST — see coverage notes.
- The payload wire shape (`b`, `p`, `k`, `i`, `c`, `d`, `o`) is read structurally in both files with no shared declaration; a typed model is not available in this stack (no build step beyond importmap, no JS test runner per print_sheet.js:274-278), so this is noted only, not proposed.

---

## S28 — Remaining browser UI (Stimulus controllers, JS libs, CSS)

**Lane verdict:** `recommend`

### S28-1 — FileChooser stores a snapshot of derived state (`this.selection`) that four write sites must each recompute consistently — derive it from `trail` + a picked file instead

> **COORDINATOR VERDICT — ACCEPT.** Verified against the tree; no narrowing applied.

- **Category:** state-representation  
- **Lane confidence:** high

**Evidence**

- app/javascript/lib/file_chooser.js:41-42 — the two fields that carry navigation state side by side: `this.trail = []` (the folders descended into) and `this.selection = null // { nodeId, kind, path } or null`. In folder mode the second is a function of the first plus the constructor seed; it is stored as an independent snapshot anyway.
- app/javascript/lib/file_chooser.js:56-58 — write site 1, the seed: `this.selection = this.mode === "folder" ? { nodeId: this.value, kind: "dir", path: this.label || this.rootLabel } : null`. The 6-line comment above it (lines 50-55) records a shipped defect where this site seeded `path` with `rootLabel` while `nodeId` held a real folder, so the two halves of the snapshot disagreed from the first frame.
- app/javascript/lib/file_chooser.js:191-197 — write site 2, `descend`: mutates `trail`, then rebuilds the snapshot as `{ nodeId: folder.node_id, kind: "dir", path: this.pathPrefix(this.trail.length) }` for folder mode and `null` for file mode.
- app/javascript/lib/file_chooser.js:199-203 — write site 3, `pickFile`: collapses `trail` to `depth`, then composes `path: this.pathPrefix(depth) + "/" + file.name` — the composition whose depth-0 case shipped as "Choose automatically/hero.png" (documented at lines 231-243 and pinned by test/system/file_chooser_test.rb's root-column test).
- app/javascript/lib/file_chooser.js:205-229 — write site 4, `back`: pops `trail`, then a mode branch recomputes the snapshot twice more (a `last`/root ternary for folder mode, `null` for file mode). Lines 213-226 record the third defect of the same shape: this branch did not exist, so a Back left `Selected: /a/b/x.svg` on screen with Open live after the column holding that file was gone.
- app/javascript/lib/file_chooser.js:146-155 and 296-301 — the only two readers: `render` prints `this.selection.path` and enables/disables Choose, and `choose` destructures `{ nodeId, kind, path }` and re-normalizes with `nodeId || ""` (a defensive fix-up that exists because different write sites can leave `nodeId` as `""`, undefined, or a real id).

**Current complexity / invalid states**

"What is currently selected" is stored as a mutable snapshot written at four sites and read at two. In folder mode the snapshot is fully determined by `trail` (plus the constructor's `value`/`label` seed until the first navigation), and in file mode it is determined by the picked entry plus its depth — but nothing in the code says so, so each write site re-derives `nodeId`, `kind` and `path` by hand and must independently remember three rules: the root is named with the caller's `rootLabel` and never with `pathPrefix(0)`; a file's path is `pathPrefix(depth) + "/" + name`; and any trail change invalidates a file pick. All three recorded defects in this file are one write site disagreeing with the others about one of those rules — the comments at lines 50-55, 213-226 and 231-243 each describe a snapshot that had drifted from the trail it was supposed to describe. The `nodeId || ""` at line 300 is a fourth symptom: the reader normalizes because the writers do not agree.

**Proposed representation**

Store only the inputs and compute the selection on read. Fields become `trail` (unchanged), `pickedFile = null | { node_id, name, depth }` (file mode only), and `seed = { nodeId, path } | null` (folder mode, set in the constructor from `value`/`label`, cleared on the first navigation). Add one `currentSelection()` that returns, in order: in file mode, `pickedFile && { nodeId: pickedFile.node_id, kind: "file", path: this.pathPrefix(pickedFile.depth) + "/" + pickedFile.name }`; in folder mode, `seed` if it is still set, else `{ nodeId: last.id, kind: "dir", path: this.pathPrefix(this.trail.length) }` for a non-empty trail, else `{ nodeId: "", kind: "dir", path: this.rootLabel }`. `descend`/`back` then do nothing but mutate `trail`, clear `pickedFile`, clear `seed`, and re-render; `pickFile` sets `pickedFile` and collapses the trail; `render` and `choose` call the one function. The three rules above are then written once each instead of once per write site, and `nodeId` is uniformly `""`-or-an-id so line 300's `|| ""` disappears.

**Why simpler**

It removes a stored copy of state that is already fully determined by other fields, which is what made every past defect here possible: a snapshot can disagree with the trail, a derivation cannot. Concretely, all three documented bugs become unrepresentable rather than fixed-and-guarded — the seed can no longer name a folder while displaying the root label (one expression owns both halves), Back can no longer leave a file selected in a column that has been popped (there is no independent field left to go stale), and `pathPrefix` can no longer be asked for a display label by one caller and a path by another. It also collapses the mode branching from four sites (open, descend, back, and the placeholder in render) to one place, and turns two of the four navigation methods into pure trail edits.

**Smallest credible implementation scope**

One file, roughly 60 lines touched: replace the `selection` field with `pickedFile`/`seed` in the constructor (lines 41-42), rewrite `open`'s seed (56-58), `descend` (191-197), `pickFile` (199-203) and `back` (205-229) as trail/pick edits, add `currentSelection()` beside `pathPrefix`, and point `render` (148-154) and `choose` (297-301) at it. No call-site changes: `FileChooser#open`'s resolved shape `{nodeId, kind, path} | null` is unchanged, so filechooser_controller.js, `chooseFolder`/`chooseFile` and the addon `ctx` contract are untouched.

**Affected files**

- `app/javascript/lib/file_chooser.js`

**Regression risks and migration concerns**

The comments in this file argue for specific VALUES, and the derivation must reproduce each of them exactly or it re-opens a recorded bug: the root in folder mode is named with the caller's `rootLabel` and not with `pathPrefix(0)` (lines 210-212 and 231-243); the seed must survive until the first navigation and must not be recomputed from an empty trail (lines 50-58, the case addon_bundle_test.rb drives without navigating); and file mode's null must stay a modal-INTERNAL null that `choose` returns early on, so the promise's null keeps meaning cancel and only cancel (lines 216-226, 297-298). A second risk is scope creep into the mode branching generally — the `mode`-dependent fetch param, footer verb and button label (lines 81, 114, 123) are unrelated to this and should be left exactly as they are.

**Validation required**

test/system/file_chooser_test.rb already covers five of the six behaviours this touches in a real browser: descend-then-pick composes the path, a file picked in the ROOT column gets "/hero.png" and not the root label, Back clears a file-mode pick and disables Open, Escape commits nothing, and reopening then backing out leaves the field untouched. test/system/addon_bundle_test.rb:213 ("the chooser resumes from the folder it was seeded with, in both halves") covers the folder-mode seed without navigating — the one path the file-mode host page cannot reach — and test/system/addon_sdk_test.rb:287 covers pickFile including the cancel answer. Per CLAUDE.md §15, mutation-check the derivation: make `currentSelection()` name the root with `pathPrefix(0)` instead of `rootLabel` and confirm the root-column test goes red, and make `descend` leave `pickedFile` set and confirm the Back test goes red.

### S28-2 — The JSON-request contract (CSRF header, `Accept: application/json`, `{error}` failure envelope) is restated in prose at five call sites while a correct implementation already exists, unexported, in lib/chunk_upload.js

> **COORDINATOR VERDICT — ACCEPT.** Verified against the tree; no narrowing applied.

- **Category:** data-structure  
- **Lane confidence:** medium

**Evidence**

- app/javascript/lib/chunk_upload.js:9-22 — the canonical pair, both module-private: `csrfToken()` reads `meta[name="csrf-token"]?.content || ""`, and `postJSON(url, body)` sends Content-Type + Accept + X-CSRF-Token, then does `const data = await res.json().catch(() => ({}))` and throws `data.error || \`request failed (${res.status})\``. Neither is in the module's export list (only `sha256Hex`, `uploadChunkFile`, `uploadPortFile` are).
- app/javascript/controllers/uploader_controller.js:2 and 32-51 — this controller already imports `uploadChunkFile` from that very file, then reimplements `postJSON` inline as `postAttach`, with an 8-line comment (lines 33-40) explaining why `Accept: application/json` is load-bearing (without it Rails' `respond_to` block answers a 302 HTML redirect that fetch follows, silently consuming the flash) and why `res.ok` must throw. `postJSON` two files away already does both, with a better error message.
- app/javascript/controllers/filemenu_controller.js:107-127 — `save` builds the same three headers by hand (line 117 re-reads the csrf meta tag) and re-parses the same envelope: `const data = await res.json().catch(() => ({}))` then `throw new Error(data.error || \`failed (${res.status})\`)` — a line-for-line copy of chunk_upload.js:19-20.
- app/javascript/lib/file_chooser.js:266-274 and 286-287 — a fourth copy: `const token = document.querySelector('meta[name="csrf-token"]')?.content` and a ternary that OMITS the X-CSRF-Token header entirely when the token is missing (the other four sites send `""`), plus the same `err.error || fallback` envelope read at 286-287.
- app/javascript/controllers/sheet_controller.js:106 — a fifth csrf read, and at 149-156 the comment that constrains any shared helper: an earlier draft told a server refusal from a transport failure by sniffing `error.message` for an "HTTP " prefix and ended up showing users their browser's jargon for an outage, so this controller deliberately handles `!response.ok` inline (139-147) and returns before the catch.
- app/javascript/controllers/importer_controller.js:144 — a sixth copy of the identical meta-tag expression, outside this lane, showing the shape is still spreading to new controllers rather than converging.

**Current complexity / invalid states**

Every browser-side write in this app assumes the same three things about the server — that a CSRF token lives in a specific meta tag, that Rails will answer HTML unless asked for JSON, and that a refusal carries `{ error: "..." }` — and each of the five in-boundary call sites encodes those assumptions independently. The assumptions are documented as COMMENTS at the call sites (uploader_controller.js:33-40 is eight lines of prose about a header the shared helper already sets) rather than as a function, so the trap is re-learnable but not re-usable: the sixth caller has to read someone else's comment to avoid it. The copies have already drifted — file_chooser.js sends no CSRF header at all when the meta tag is absent while the others send an empty string — and the `res.json().catch(() => ({}))` + `data.error || fallback` envelope reader is written out four separate times.

**Proposed representation**

Export the two functions that already exist. Either add `export` to `csrfToken` and `postJSON` in lib/chunk_upload.js, or (cleaner, since the module's name is about uploads) move both into a small `app/javascript/lib/http.js` that chunk_upload.js imports. Then `uploader_controller#postAttach` becomes one `await postJSON(this.attachUrlValue, { node_id: nodeId })` call, `filemenu_controller#save` becomes `await postJSON(noteUrl, { note: { body } })` inside its existing try/catch (its `status.textContent = e.message` already displays exactly what postJSON throws), and file_chooser's `submitNewFolder` uses the shared `csrfToken()` while keeping its FormData body and its inline error rendering.

**Why simpler**

One definition of how this app talks JSON to itself, instead of five hand-copied ones plus prose explaining each. It deletes the ~20-line `postAttach` method and its comment outright, removes two of the four duplicated envelope readers, and makes the `Accept` trap structurally unhittable by the next controller rather than something it must read a comment to avoid. It also closes the one live divergence — file_chooser's missing-token branch becomes the same branch as everyone else's.

**Smallest credible implementation scope**

Small and mechanical: add exports (or a ~15-line lib/http.js plus one import in chunk_upload.js), then three call-site edits — uploader_controller.js (delete `postAttach`, call `postJSON`), filemenu_controller.js (replace the fetch block in `save`), file_chooser.js (use the shared `csrfToken()`). No server changes, no contract changes.

**Affected files**

- `app/javascript/lib/chunk_upload.js`
- `app/javascript/controllers/uploader_controller.js`
- `app/javascript/controllers/filemenu_controller.js`
- `app/javascript/lib/file_chooser.js`

**Regression risks and migration concerns**

sheet_controller.js MUST NOT be folded in, and that is a recorded decision, not an oversight: its comment at lines 149-156 documents that distinguishing a server refusal from a transport failure by inspecting a thrown error regressed the outage message it exists for, so it keeps its inline `!response.ok` branch and its own status wording. A throw-based shared helper would push it back toward exactly that shape. Secondary risk: `postJSON`'s error message is `data.error || \`request failed (${status})\``, which is not byte-identical to the strings `postAttach` ("attach failed (404)") and `filemenu#save` ("failed (404)") produce today — check whether any system test asserts on those literals before switching. This is a modest, low-drama cleanup; if a reviewer judges it as consistency-only, the honest counter is the `Accept`-header trap being encoded in prose at each site rather than in a function.

**Validation required**

Drive the three real requests rather than reasoning about the headers, per CLAUDE.md §14e: the upload+attach path is covered by the projects upload-control system tests, the note popover by the filemenu system coverage, and folder creation by test/system/file_chooser_test.rb's "New Folder creates a real dir through the port" and "a rejected folder name reports inline" (the latter asserts the server's `{error}` string reaches the user, which is the envelope reader under test). Mutation-check the shared helper by dropping `Accept: application/json` from it and confirming the attach path regresses to the flash-eating redirect the uploader comment describes.

### Cross-subsystem concerns raised by this lane

_Named, not solved — the lane was told to stay inside its boundary._

- The CSRF/Accept/`{error}` request shape duplicated in finding 2 also appears in app/javascript/controllers/importer_controller.js:144 and app/javascript/controllers/addon_controller.js:35 (the latter with an unquoted `meta[name=csrf-token]` selector), both other lanes. If a shared lib/http.js is created, those two are the natural follow-on adopters — but addon_controller.js's copy sits inside the addon ctx contract (§14c / docs/invariants/addons.md), so it should be changed by that lane, not this one.
- lib/file_chooser.js is consumed by addon_controller.js as `ctx.chooseFolder`/`ctx.chooseFile` (S21). Finding 1 keeps the resolved `{nodeId, kind, path} | null` shape exactly, so no addon contract or bundle republish is implicated — but the S21 owner should be told, since test/system/addon_bundle_test.rb and addon_sdk_test.rb are part of that change's validation set.

---

## S29 — CI gate definition & hygiene guards

**Lane verdict:** `recommend`

### S29-1 — A sweep's scanned set is discarded by its own helper, so §14e's non-vacuity assertion is unrepresentable at the call site — and the file that narrates that exact bug omits it three times

> **COORDINATOR VERDICT — NARROWED.** The Sweep struct threaded through 17 sites does not make the guard structural — the lane concedes "a helper cannot force use". Add the non-vacuity assertion at the sweep sites. NOTE: three sweeps, not two — the third is maker_layer_files (:677-701), the 14d seam guard 14e records as already having gone vacuous once.

- **Category:** data-structure  
- **Lane confidence:** high

**Evidence**

- test/architecture_invariants_test.rb:29-37 — `def offending(globs, pattern)` globs `Dir.glob(ROOT.join(rel, "**", "*.rb"))` and flat_maps straight to "path:lineno" strings. The file list it built is never returned, so a caller physically cannot assert what was scanned without re-globbing.
- test/architecture_invariants_test.rb:181-183 — `hits = offending(%w[app/**/maker], /manifest_chunks|ChunkStore/)` then `assert_empty hits`. No assertion that any file was scanned. If `app/**/maker` ever moves, the glob is `[]` and this passes forever.
- test/architecture_invariants_test.rb:825-828 — `hits = offending(%w[app lib], /rescue.*NotImplementedError/)` then `assert_empty hits`. Same shape, same gap.
- test/architecture_invariants_test.rb:677-701 — `maker_layer_files = Dir.glob(...app...) + Dir.glob(...lib...) + Dir.glob(...lib/tasks/*.rake)`, then `hits = maker_layer_files.flat_map { sync_references(file) }`, then `assert_empty offending_files`. No non-empty check on `maker_layer_files`. `grep -n 'refute_empty|assert_not_empty|assert_operator' test/architecture_invariants_test.rb` returns zero scan-set assertions in the whole 987-line file.
- test/architecture_invariants_test.rb:606-612 — this same file's comment narrates the precise failure: two guards "both scanned engines/tinkerex-sync/**", the extraction "made that glob [] -- and both tests are `assert_empty offenders`, which an empty file list satisfies perfectly... Only ONE of the pair said so." The lesson is recorded here and applied here zero times.
- test/ci_hygiene_test.rb:92-101 and :108-116 — both drive `each_job` and go straight to `assert_empty offenders` with no `scanned` tally, while test/ci_hygiene_test.rb:238-242 (the preflight-gating test) builds `scanned` and asserts `assert_operator scanned.size, :>=, 2` for exactly this reason. Three callers of one helper, one of which remembered.
- test/ci_hygiene_test.rb:332-339 — `surface = [ "config/ci.rb", *Dir.glob("bin/*"), *Dir.glob(".github/workflows/*.{yml,yaml}") ]` then `assert_empty offenders`; `code_lines` (test/ci_hygiene_test.rb:376-380) returns `[]` for a missing path, so every entry that disappears silently reduces what is checked.
- test/docs_hygiene_test.rb:79-81, :102-103, :122-123 — three hand-spelled variants of the same guard (`refute_empty files` + `assert_operator files.size, :>, 100`; `refute_empty files`; `refute_empty cited`), each with its own bespoke message. test/deploy_hygiene_test.rb:120 (`assert sidecars.any?`), :165 (`assert scripts.any?`), :238, :242 add four more spellings.
- test/stimulus_hygiene_test.rb:92-101 — the main sweep asserts `assert_empty offenders` over `view_declarations`; `refute_empty registered_identifiers` exists only in a different test (test/stimulus_hygiene_test.rb:136), so a moved `app/views` leaves the sweep green over nothing while that test stays green too.

**Current complexity / invalid states**

Nine sweep sites in this subsystem spell the non-vacuity guard by hand in seven different ways (`refute_empty`, `assert_operator size > 100`, `> 5`, `>= 2`, `.any?`), and eight comparable sites omit it entirely. The rule is stated three times in prose (test/docs_hygiene_test.rb:24-27, test/ci_hygiene_test.rb:233-237, test/architecture_invariants_test.rb:606-612) and enforced by nothing. The root cause is a representation choice, not discipline: `offending` and `code_lines` return only the offender list, so the scanned corpus — the thing the assertion is meaningful relative to — is thrown away before the caller sees it. Writing the guard at those call sites requires duplicating the glob, which is why nobody did.

**Proposed representation**

Make a sweep one value instead of two unrelated locals. Have `offending` (and `code_lines`, and `each_job`) return a small `Sweep` struct carrying both halves — `Sweep = Struct.new(:label, :scanned, :offenders)` — and add one shared assertion in a test-support module: `assert_clean_sweep(sweep, minimum: 1, message:)`, which asserts `sweep.scanned.size >= minimum` first (with a message naming the subject, e.g. "this guard scanned N of the set it exists to check") and then `assert_empty sweep.offenders, message`. Convert the nine sites that already do this by hand and the eight that do not. Keep every existing per-site `minimum:` value and per-site offender message as arguments — those are argued and must not be flattened into one generic threshold.

**Why simpler**

Today the assertion "offenders is empty" is only meaningful in relation to a set the code has already discarded, so the relationship exists in prose and in nothing else. Pairing them makes the invariant expressible: you cannot write the offender assertion without having named what was swept. It also collapses seven ad-hoc spellings of one idea into one call whose argument names (`scanned`, `minimum`) say what the number is for — today `assert_operator files.size, :>, 100` at test/docs_hygiene_test.rb:81 and `assert_operator pins.size, :>, 5` at test/ci_hygiene_test.rb:351 read as arbitrary magic numbers unless you read the paragraph above each.

**Smallest credible implementation scope**

One new test-support file (~20 lines) with `Sweep` and `assert_clean_sweep`, required from test_helper. Change `offending`'s return type in test/architecture_invariants_test.rb:29-37 and its three callers (:181, :677, :825). Change `each_job` in test/ci_hygiene_test.rb:445-453 to accumulate what it yielded, and convert its four sweep tests. Convert test/docs_hygiene_test.rb's three, test/stimulus_hygiene_test.rb's one, and test/deploy_hygiene_test.rb's four. No production code touched; no gate definition touched.

**Affected files**

- `test/architecture_invariants_test.rb`
- `test/ci_hygiene_test.rb`
- `test/docs_hygiene_test.rb`
- `test/stimulus_hygiene_test.rb`
- `test/deploy_hygiene_test.rb`

**Regression risks and migration concerns**

Three, all real. (1) A helper cannot force use — a new guard can still write bare `assert_empty`. This makes the right thing the shortest thing; it does not make it un-forgettable, and claiming otherwise would be the false comfort this repo warns about. If un-forgettable is the goal, the only mechanism is a meta-guard over these test files, which is a bigger and more fragile thing to argue for separately. (2) Rewriting nine currently-green guards risks weakening one by accident; §15 requires each converted site to be mutation-checked (point its glob at an empty dir, confirm RED, restore) rather than trusted because the suite stayed green. (3) The per-site thresholds and messages are argued content (test/docs_hygiene_test.rb:58-72, test/ci_hygiene_test.rb:233-237); a helper that swallowed them into one generic message would be a net loss. Nothing in CLAUDE.md or in any code comment argues for the current duplicated spelling — §14e argues for the rule these sites are failing to apply, which is evidence for the change, not against it.

**Validation required**

For each converted site, mutate the scanned set to empty (rename the directory, or inject an empty WORKFLOW_DIR / glob root) and confirm the test goes RED. Today that mutation leaves test/architecture_invariants_test.rb:183, :701 and :828, plus test/ci_hygiene_test.rb:101 and :116, GREEN — run that mutation first, before any change, so the gap is measured rather than argued. After conversion, re-run the same mutation and confirm each is red, then restore.

### S29-2 — `each_job` yields a raw YAML hash, so "what runner family does this job target" is re-derived three times — and the documented fail-safe direction holds at only one of them

> **COORDINATOR VERDICT — ACCEPT.** Verified against the tree; no narrowing applied.

- **Category:** data-structure  
- **Lane confidence:** medium

**Evidence**

- test/ci_hygiene_test.rb:445-453 — `each_job` yields `[basename, job_name, job_hash]`, the raw parsed YAML. No accessor for labels, steps, needs, or the `if:` condition.
- test/ci_hygiene_test.rb:94-95 — `raw = Array(job["runs-on"])` then `next if raw.map { |l| l.to_s.downcase }.include?("self-hosted")`.
- test/ci_hygiene_test.rb:110 — `next unless Array(job["runs-on"]).map { |l| l.to_s.downcase }.include?("macos")` — the identical expression, third-hand.
- test/ci_hygiene_test.rb:246 — `families = Array(job["runs-on"]).map { |l| l.to_s.downcase } & FAMILIES` — the same expression again, and the check it feeds is labelled "THE CORE INVARIANT" at test/ci_hygiene_test.rb:226.
- test/ci_hygiene_test.rb:82-91 — the KNOWN LIMIT is documented at exactly one of the three: `runs-on` also has a map form `{ group:, labels: }`, `Array(hash)` yields `[key, value]` PAIRS, "so a map-form job can never match `\"self-hosted\"` and therefore always FAILS this check. Left alone... It fails in the SAFE direction (loudly over-flagging, never silently passing a billed runner)".
- The safe-direction claim is a property of that one check only, and does not transfer. At test/ci_hygiene_test.rb:110 a map-form macos job yields labels that do not `include?("macos")`, so the guard `next`s past it — a map-form macos job using ruby/setup-ruby passes. At test/ci_hygiene_test.rb:246-248 a map-form linux job produces `families = []`, so `gated_families.empty?` is true and the guard `next`s — an ungated map-form linux job passes, which is exactly the "queues for 24h, mergeStateStatus UNSTABLE, five weeks of dark CI" failure test/ci_hygiene_test.rb:226-228 exists to prevent. Two of the three fail OPEN; nothing at either site says so.
- test/ci_hygiene_test.rb:89-90 — the same comment's supporting measurement is already stale: "verified: all 15 `runs-on` values are Array-shaped — down from 38 before the client/ extraction". `grep -c 'runs-on:' .github/workflows/ci.yml` is 7 today, and ci.yml is the only workflow left (.github/workflows/ contains one file). Shape knowledge held in prose beside one of three copies drifts; shape knowledge held in one accessor cannot.
- ci/preflight.sh:69-71 — `targeted()` is a fourth, independent notion of the same question, in shell: `grep -rhE '^[[:space:]]*runs-on:' "$WORKFLOW_DIR" | grep -q "$1"`. Its own comment at ci/preflight.sh:52-55 argues it is "deliberately crude" and over-reports, which is a different and defensible trade — noted so the Ruby consolidation is not mistakenly extended into the shell.

**Current complexity / invalid states**

Four call sites answer "which runner families does this job target" and three of them are the same 60-character expression pasted three times. Because each site re-derives it, each site independently decides what to do with an unrecognised `runs-on` shape — and they disagree: one flags, two skip. The one that flags is the one whose comment explains the trade-off, so a reader who checks the documented behaviour finds it correct and generalises it to the other two, where it is inverted.

**Proposed representation**

Have `each_job` yield one small value object instead of the raw hash — `Job = Struct.new(:file, :name, :labels, :steps, :needs, :condition)` — built by a single constructor that normalises `runs-on` once. That constructor makes the map-form decision in one place: either flatten `{group:, labels:}` into its `labels` array, or (preferable, and consistent with test/ci_hygiene_test.rb:82-91's argument that a correct reading is genuinely ambiguous) record it as an explicit `unresolvable` marker that every guard treats as an offender rather than as "no families matched". Then the three checks read `job.labels.include?("self-hosted")`, `job.labels.include?("macos")`, `job.labels & FAMILIES` with no per-site parsing.

**Why simpler**

It turns three independent readings of one YAML shape into one, so the map-form limit is decided once and inherited by every guard instead of being documented at whichever site happened to think about it. It also removes an invalid state the current code permits: "labels could not be read" and "labels contain none of the families I care about" are presently the same value (an array that matches nothing), which is why two guards silently treat the first as the second. Making `labels` a field with one owner is what lets those two be distinguished at all.

**Smallest credible implementation scope**

Rewrite `each_job` (test/ci_hygiene_test.rb:445-453) to build and yield the struct, and update the four consuming sites (:93-98, :109-113, :142-151, :245-258). Delete the three duplicated `Array(job[...]).map { |l| l.to_s.downcase }` expressions. Refresh the stale count in the comment at test/ci_hygiene_test.rb:89-90 while you are there. Roughly 25 lines net. `ci/preflight.sh` is deliberately untouched — its crudeness is argued in-file and over-reports, which is the safe direction there.

**Affected files**

- `test/ci_hygiene_test.rb`
- `ci/preflight.sh`

**Regression risks and migration concerns**

Low but not zero. The map-form decision is a judgment call the current comment explicitly declines to make ("an org-level HOSTED larger-runner group and a self-hosted runner group use the identical YAML shape, so static inspection cannot tell them apart") — the change should preserve that refusal by making the shape an explicit offender everywhere, not by inventing a resolution. Doing the opposite (flattening `labels` so a map-form job silently satisfies the self-hosted check) would convert the one guard that currently fails safe into one that fails open, which is strictly worse than today. This is also a latent defect, not a live one: no workflow here uses the map form, so nothing is currently broken and the case for acting is that the asymmetry is invisible and the fix is small.

**Validation required**

Make `each_job`'s source injectable (it currently hard-codes WORKFLOW_DIR at test/ci_hygiene_test.rb:42 and :449), then reuse test/ci_preflight_test.rb:131-141's `with_workflows` pattern to plant a throwaway workflow containing a map-form job: `runs-on: { group: g, labels: [self-hosted, linux] }` with no `needs: preflight`. Assert today that the setup-ruby guard and the preflight-gating guard both pass over it — that is the measurement — then assert after the change that both flag it. Mutation-check the self-hosted guard separately to confirm it still fails on the map form rather than newly accepting it.

### Cross-subsystem concerns raised by this lane

_Named, not solved — the lane was told to stay inside its boundary._

- test/architecture_invariants_test.rb also guards production-code invariants outside this subsystem (§14a chunk-internals, §14d controller auth, index prefixes). Finding 1 changes only that file's `offending` helper and its assertion shape, not the rules themselves, but the mutation-check for each converted site touches app/ and lib/ paths owned by other subsystems — do the mutations by renaming a directory in a scratch checkout rather than editing production code.
- ci/preflight.sh:69-71 holds a fourth, shell-side notion of "which families a job targets", independent of the three Ruby ones in finding 2. Its over-reporting bias is argued in-file at ci/preflight.sh:52-55 and is the safe direction there, so it should NOT be unified with the Ruby accessor. Flagged only so a future consolidation does not reach into it by analogy.
- test/deploy_hygiene_test.rb participates in finding 1's sweep shape (four hand-spelled non-empty assertions at :120, :165, :238, :242) but its subject matter — GPL sidecar licensing, kamal secrets, .dockerignore — belongs to the deploy subsystem. Converting its four sites is optional and can be deferred without weakening the fix.

---

## S30 — Forgejo record CLI

**Lane verdict:** `recommend`

### S30-1 — Each write verb hand-rolls its own argv grammar, so "refuse, never guess" holds in deploy only

> **COORDINATOR VERDICT — ACCEPT.** Verified against the tree; no narrowing applied.

- **Category:** control-flow  
- **Lane confidence:** high

**Evidence**

- bin/log:344-353 — `deploy` parses with a strict `until argv.empty?` loop whose `else` arm raises `UsageError, "deploy: unrecognised argument #{flag.inspect}"`. The inline comment names the shipped bug this fixed: a typo'd flag "used to fall through to the three defaults silently, filing a deploy record naming destinations nobody deployed".
- bin/log:280-297 — `arc` uses a completely different grammar: `flag = argv.shift`, a `case` on that one token, then `closed: argv.include?("--closed")`, which is a scan of whatever is left in argv. Nothing inspects the remaining tokens, so any trailing argument is silently dropped. `bin/log arc --from-file entry.md --clsoed` (one transposed letter) creates the historical import as LIVE OPEN WORK and exits 0 — the exact silent-false-record shape deploy's `else` arm exists to prevent, in the verb CLAUDE.md §15 makes mandatory at PR time.
- bin/log:257-259 — `open_item` reads a second, undocumented positional as the issue body (`create_issue(title, body: argv.shift.to_s, ...)`), and drops anything after it. `show` (183-184) and `note` (365-368) shift positionally and ignore extras too.
- bin/log:60-62 — the SUBCOMMANDS rows that generate `--help` describe none of this: `deploy` is `"--image SHA"` with no mention of `--dest`; `open` is `'"<title>"'` with no mention of the body positional. (`arc`'s `--closed` survives only because it is prose in the description column.) The usage table and the parsers are independent artifacts that already disagree.
- test/log_cli_test.rb:570-583 — two tests pin deploy's strictness (`"an unrecognised deploy flag is refused, never silently defaulted"`, `"deploy --dest with no value is a usage error, not a crash"`). Grepping every `test "` line in the file, there is no equivalent for `arc`, `open`, `note` or `show`; the arc tests at 282, 696, 724 and 762 all pass well-formed argv.

**Current complexity / invalid states**

Four different argument-parsing policies in one 524-line file: a strict flag loop (deploy), a single-token case plus a whole-argv `include?` scan (arc), and bare positional shifts that ignore trailing tokens (open, note, show). Which policy a verb gets depends on whether someone remembered to apply it there, and the usage table that claims to be the single definition of the CLI's surface describes a different set of arguments than the parsers accept.

**Proposed representation**

Declare each verb's argument grammar once, in the SUBCOMMANDS row that already exists, and parse it in one place. Concretely: give each row a positional list and a set of accepted flag names (value-taking or boolean) — e.g. arc: flags `--from-pr VALUE`, `--from-file VALUE`, `--closed` (bool), 0 positionals; deploy: `--image VALUE`, `--dest VALUE`, 0 positionals; open: 1 required + 1 optional positional, no flags; note: 2 required positionals. One ~20-line `parse_args(spec, argv)` returns positionals plus a flags hash and raises UsageError for an unrecognised token, a flag missing its value, or a positional count outside the declared range. Verbs then read `flags["--dest"]` / `positionals[0]` instead of shifting. Critically, the parser must recognise only the DECLARED flag names, never a leading `-`, so `bin/log note 128 "-- corrected figure"` keeps working.

**Why simpler**

"Refuse, never guess" stops being a property each verb re-implements (or forgets) and becomes a property of the one parser — which is what the deploy comment's own reasoning demands but only deploy got. It deletes three ad-hoc parsers, removes `argv.include?("--closed")` (a whole-argv scan is order-insensitive and cannot distinguish a flag from a stray token), and makes `usage_text` derivable from the same declaration instead of a hand-written args string, closing the existing `--dest`/body-positional documentation gaps by construction rather than by remembering.

**Smallest credible implementation scope**

bin/log only. Add the flag/positional spec to the eight SUBCOMMANDS rows and a `parse_args` helper (~20 lines); rewrite the argv handling in `arc`, `deploy`, `open_item`, `note` and `show` to read the parsed result (each shrinks). Optionally derive the usage args column from the spec, retiring the hand-written strings at bin/log:59-66. Add refusal tests for arc/open mirroring test/log_cli_test.rb:570-583.

**Affected files**

- `bin/log`
- `test/log_cli_test.rb`

**Regression risks and migration concerns**

Behaviour change: tokens that are currently ignored become exit-2 usage errors. That is the intent, but it is a real change for any caller relying on the sloppiness — I grepped .claude/commands/*.md and CLAUDE.md §13/§15 and found only well-formed invocations, so I believe there are none. Two traps: (1) title/body/note text can legitimately begin with `-` or `--`, so the parser must key off declared names only, never a dash prefix — a naive `arg.start_with?("-")` check would break `bin/log note 128 "-- corrected"`; (2) `arc`'s two mode flags are mutually exclusive and one is required, which the current `case/else` enforces with a good message ("arc needs --from-pr N or --from-file PATH", pinned nowhere but reachable) — that check must survive as an explicit line in `arc`, not be assumed to fall out of the spec. Also keep `main`'s unknown-COMMAND path untouched; test:97-103 pins it.

**Validation required**

Mutation-check each new refusal the way test:570 does for deploy: `bin/log arc --from-file x.md --clsoed` must exit 2 and name the argument (today it exits 0 and files an OPEN issue — verify the current behaviour first so the test is known to have been red); same for a trailing token on `open`, `note`, `show`. Assert `bin/log note 128 "-- corrected figure"` still POSTs that exact body (extends test:589). Assert `--help` names `--dest` if the usage column is derived. Then run the existing 38 tests in test/log_cli_test.rb unchanged.

### S30-2 — SUBCOMMANDS is a usage table shadowed by a second list of the same eight names in `dispatch`

> **COORDINATOR VERDICT — ACCEPT.** Verified against the tree; no narrowing applied.

- **Category:** data-structure  
- **Lane confidence:** medium

**Evidence**

- bin/log:53-57 — the table's own comment claims the property it does not have: "ONE TABLE, NOT FOUR LISTS. USAGE is DERIVED from this and `main` dispatches on it, so a subcommand cannot exist in one place and be missing from another." It then cites §14d's EXT_FAMILIES-derived-from-ROLE_BY_EXT rule and notes this file's own first draft already drifted "before it was 62 lines old".
- bin/log:435-441 — what `main` actually does is `unless SUBCOMMANDS.key?(command)` … then `dispatch(command, argv)`. The table is used as a membership set; it does not carry the handler.
- bin/log:496-512 — `dispatch` is a `case` with eight `when` arms repeating the same eight literal strings, plus an `else` that raises `"unreachable: #{command}"`. Its comment (487-495) concedes the coupling is by convention — "EVERY SUBCOMMAND DECLARED IN SUBCOMMANDS NOW HAS AN ARM HERE" — and the `else` only fires when someone actually RUNS the drifted command, at which point it lands in main's catch-all as EXIT_BUG.
- bin/log:408-418 — `usage_text` genuinely is derived from SUBCOMMANDS, so a row added without a dispatch arm is advertised by `--help` as a working subcommand and then exits 5.
- test/log_cli_test.rb:62-75 — the usage test iterates `%w[setup arc open deploy note show search status]` and asserts each has a `^\s*bin/log <name>\b` line, i.e. it checks the table half only. No test in the file (see the full `test "` listing: 38 tests) invokes each SUBCOMMANDS key to prove it dispatches, so the table→dispatch direction is unguarded.

**Current complexity / invalid states**

Eight subcommand names written twice — once as SUBCOMMANDS keys (bin/log:58-67) and once as `when` literals in `dispatch` (496-505) — with the file's own header comment asserting they are written once. Drift is caught only at runtime, only for the drifted command, and only after `--help` has already advertised it.

**Proposed representation**

Put the handler in the row: `"setup" => ["", "Create the labels, idempotently", :setup]`, `"open" => ['"<title>"', "File an open item", :open_item]`, etc. `main` then does `send(SUBCOMMANDS.fetch(command)[2], argv)` and `dispatch`'s `case` is deleted. `setup` and `status` either take an ignored `argv` parameter or keep their arity in the row.

**Why simpler**

The table becomes the single definition its comment already claims, in the same shape §14d requires of EXT_FAMILIES/ROLE_BY_EXT. It removes the second list, removes the `else raise "unreachable"` arm that exists only to catch drift between two structures that would no longer exist, and makes the drift class checkable by a test that iterates the table — which is currently impossible because there is nothing to iterate against.

**Smallest credible implementation scope**

bin/log only: add a third element to the eight SUBCOMMANDS rows, replace `dispatch` (bin/log:496-512) with a `send` in `main`, adjust `setup`/`status` arity. One new test iterating SUBCOMMANDS keys.

**Affected files**

- `bin/log`
- `test/log_cli_test.rb`

**Regression risks and migration concerns**

Low, but three details are load-bearing. (1) `open` must map to `:open_item`, not `:open` — the comment at bin/log:255-256 records that `open` inside this module would shadow `Kernel#open` for every other method, so the row must name the real method rather than deriving it from the key. (2) A row naming a nonexistent method currently fails at `dispatch`'s `else` with a clear "unreachable: x"; with `send` it becomes NoMethodError, which still reaches main's `rescue StandardError` and still exits 5 (bin/log:471-484) — the same outcome, but the message is worse, so `SUBCOMMANDS.fetch(...)` plus an explicit `respond_to?` check is worth keeping. (3) `main`'s unknown-command branch (435-439) must stay exactly as it is — stderr + usage + exit 2 — because test:97-103 pins it and `send` on an absent key would otherwise become an exception path. The value here is real but bounded: the existing `else raise` already makes drift loud rather than silent, so this is a smaller win than finding #1 and only clearly worth doing if that lands (both edit the same rows).

**Validation required**

Add the guard that does not exist today: a test that shells `bin/log <key>` for every SUBCOMMANDS key against a stub and asserts none exits 5 and none prints "unreachable"/"unexpected failure" (usage errors from missing arguments are fine — assert `!= 5`). Mutation-check it by adding a ninth row with a bogus handler symbol and confirming it goes RED, then removing it. Then run the existing 38 tests; the `--help`, no-args and unknown-command tests (62, 77, 97) cover the surface that must not move.

### Cross-subsystem concerns raised by this lane

_Named, not solved — the lane was told to stay inside its boundary._

- `--dest` is documented in .claude/commands/deploy.md:147 and the deploy flow depends on it, but bin/log's own SUBCOMMANDS row (bin/log:62) and therefore `bin/log --help` never mention it. CLAUDE.md:377's cheatsheet line also omits it. If finding #1 lands and usage text is derived from the declared flags, that divergence closes on its own; otherwise it is a docs fix owned partly outside this subsystem.
- test/log_cli_test.rb runs under ActiveSupport::TestCase and `Rails.root` (test:23), so this subsystem's guard is carried by the Rails suite and therefore runs three times, once per LIBRARY_BACKEND leg, despite bin/log being stdlib-only and backend-independent. Not a defect, but it means every added bin/log test costs 3x in bin/ci. Out of scope here.

---

## S31 — Deploy, secrets, backup & build tooling

**Lane verdict:** `recommend`

### S31-1 — A backup/restore "destination" is an implicit record re-spelled in ~10 case statements across 4 files; make it one table

> **COORDINATOR VERDICT — SPLIT+PROMOTED.** S31-1a is a LIVE monitoring gap, not duplication: ops/backup-db.sh:40 accepts `sync` and :5 backs it up nightly, but the ping whitelist at :99-103 has no PING_SYNC arm, so ping_kuma resolves an unset variable and returns 0 silently. One line. S31-1b is the destination-table refactor.

- **Category:** data-structure  
- **Lane confidence:** high

**Evidence**

- ops/backup-db.sh:40 accepts `chunk|share|s3|sync` as destinations, and ops/backup-db.sh:112 builds the ping variable name generically (`local var="PING_$(echo "$1" | tr '[:lower:]' '[:upper:]')"`) — but the ping.env whitelist reader at ops/backup-db.sh:99-103 has arms for only `PING_CHUNK`, `PING_SHARE`, `PING_S3`. There is no `PING_SYNC` arm, so `ping_kuma sync ...` reads an unset variable and `[ -n "$url" ] || return 0` (line 114) silently skips it.
- bin/backup-cron-install:194-205 derives the key list from $DESTS (`k="PING_$(printf '%s' "$d" | tr ...)"`) and writes PING_SYNC into ping.env, and bin/backup-cron-install:238-247 then greps ping.env per destination and prints `!! NO HEARTBEAT for:` only for the ones absent. So an operator who follows the installer's own instruction and supplies PING_SYNC gets told sync is monitored, while the nightly never pings for it. That comment block (lines 194-199) explicitly records this exact divergence happening once before: "which is exactly how `sync` arrived monitored by nothing while the other three were watched".
- The container-name pattern and storage volume are spelled out per destination in ops/backup-db.sh:181-197 (`container_for`) and ops/backup-db.sh:198-206 (`volume_for`), then spelled out AGAIN in bin/restore-db:51-61 (`FILTER`/`VOLUME`, same four arms, same `^tinkerex-web-[0-9a-f]` and anchored `^tinkerex-sync$` regexes with the anchoring argument duplicated in both files' comments).
- The "which second table proves this DB is real" attribute is a third per-destination axis, spelled in bin/restore-db:71-74 (`COUNT_TABLE=versions` vs `maker_projects`), again in bin/restore-db:255-276 (the sync arm counts `Sync::Version`, the other counts `Maker::Project`, and each arm carries its own health-probe style), and again in bin/backup-db:83-112 (two hand-written inventory SQL heredocs, one per family).
- bin/backup-status re-derives the destination set from the crontab line with its own token scanner (bin/backup-status:70 `chunk|share|s3|sync)`) and its own fallback list (bin/backup-status:77 `dests=${line_dests:-chunk share s3 sync}`) — a fifth copy of the closed set.
- Four sites hard-code share's container pattern purely to obtain "some app image" to run helpers in: bin/backup-status:113, bin/restore-db:93, bin/restore-db:109, bin/backup-cron-install:127 (`docker ps -a -qf name='^tinkerex-web-share-' | head -1`). This dependency is written down nowhere; at bin/backup-status:115-117 an empty image is reported to the operator as `volume $volume does not exist — run bin/backup-cron-install`, which is the wrong diagnosis.

**Current complexity / invalid states**

A destination has at least five attributes — container name-filter, storage volume, ping variable, evidence table/label, health-probe style — plus a "helper image source" that is silently always share's container. None of that is written as a record anywhere. It is re-derived by hand in ten `case` statements spread over ops/backup-db.sh, bin/backup-db, bin/restore-db and bin/backup-cron-install, several of which duplicate a load-bearing regex (the anchored `^tinkerex-sync$`, the `[0-9a-f]` disambiguator) along with the paragraph explaining why it must stay that way. Adding a destination means finding all ten; missing one is silent, and §14i is explicit that no gate in bin/ci can go red for any of it.

**Proposed representation**

One destination table, with the arms derived from it rather than re-enumerated. Because the ssh boundary is real, the table has one home and one accessor: keep it inside ops/backup-db.sh (which must stay a single self-contained file — bin/backup-cron-install:181 scp's exactly that one file, and §14i makes it the only implementation), expressed as a small newline-delimited table plus a `dest_field <dest> <field>` reader that `container_for`, `volume_for`, the argument validation and the ping.env whitelist all consult. Add a `--describe <dest>` subcommand that prints `FILTER=… VOLUME=… COUNT_TABLE=… COUNT_LABEL=… PROBE=host|exec HELPER_FROM=…`, and have the three Mac-side scripts read it from the checked-out copy (no ssh, no second file, no new dependency) instead of restating the arms. Make the helper-image source an explicit field rather than an unwritten assumption that a share container exists.

**Why simpler**

It converts five independent per-destination facts, currently held as parallel branch sets, into one row per destination with one reader. The specific failure this shape produces is already in the tree twice: the missing PING_SYNC arm means the sync database backs itself up nightly and reports failures to nobody, which is the precise defect bin/backup-cron-install:194-199 claims to have closed by deriving its half from $DESTS — it closed the writing half and left the reading half enumerated. Deriving the whitelist from the table closes it structurally. It also removes the duplicated regex-plus-rationale pairs (ops/backup-db.sh:186-195 and bin/restore-db:55-59 argue the same anchoring point about the same string), which is exactly the 'one rule living in two places, and eventually disagreeing' shape ops/backup-db.sh:287-289 names as its own opening argument.

**Smallest credible implementation scope**

Moderate, mechanical, single subsystem. One table + one accessor in ops/backup-db.sh; replace four case bodies there; replace bin/restore-db:51-74's two cases and bin/backup-db:30-33's validation with `--describe` reads; give bin/backup-status an explicit helper-image field. The per-destination PROSE arguments (why `^tinkerex-sync$` is anchored, why sync's inventory query differs) move to the table as row comments — they must not be dropped, they are the reason the values differ. No behaviour change intended anywhere except that PING_SYNC starts working.

**Affected files**

- `ops/backup-db.sh`
- `bin/backup-db`
- `bin/restore-db`
- `bin/backup-status`
- `bin/backup-cron-install`

**Regression risks and migration concerns**

Nothing in bin/ci covers any of these five scripts (§14i states this outright), so the change has no gate behind it and the bar is correspondingly higher. The concrete hazards: (1) a table reader that word-splits would corrupt the anchored regexes — the values must be read whole; (2) ops/backup-db.sh must remain a single file runnable standalone from cron, so the table cannot become a sourced sibling; (3) the inner workers run under the app image's `sh` (dash), not bash, so the reader must live in the outer bash script only; (4) `--describe` becomes a public-ish interface between the repo's scripts, which is a new coupling, albeit a narrower one than four scripts each re-deriving the same regex.

**Validation required**

Prove against stubs, never the live NAS or a real volume (backup-restore.md is explicit). Specifically: (a) mutation-check the ping gap — configure a stub push URL as PING_SYNC, run the nightly arm against stub containers, and confirm a ping is now attempted for sync and was NOT before; (b) drop a row from the table and confirm that destination is refused by the argument check rather than falling through; (c) `bin/backup-status` against a crontab line installed with a BACKUP_DESTS subset, confirming the reported set still comes from the line and not from repo defaults (bin/backup-status:38-44 records why); (d) `bin/restore-db sync <archive> --into rehearsal` and one maker destination the same way, confirming the probe style and the second row count still differ per destination (bin/restore-db:238-254).

### S31-2 — The `ovh` destination still models a per-destination chunk-store axis this repo deleted, and the merged result is a configuration that cannot boot

> **COORDINATOR VERDICT — PROMOTED.** "Cannot boot" is STATICALLY VERIFIABLE and verifies — I was over-cautious calling it unverified. deploy.ovh.yml declares NO LIBRARY_BACKEND, so deploy.yml:168 chunk_remote stays in force while :75 sets CHUNK_REMOTE_URL: "", which library_backend_check.rb:78 requires present and raises on.

- **Category:** state-representation  
- **Lane confidence:** medium

**Evidence**

- config/deploy.ovh.yml:34-42 declares `CHUNK_SECRET_ACCESS_KEY` and `CHUNK_ACCESS_KEY_ID` in env.secret and `STORAGE_BACKEND: s3`, `CHUNK_ENDPOINT`, `CHUNK_BUCKET`, `CHUNK_REGION` in env.clear. .kamal/secrets.ovh:13 and .kamal/secrets.ovh:21 resolve the two credentials from 1Password (`op://tinkerex/R2/...`).
- config/deploy.yml:120-125 records that these names configured `Sync::Storage::ChunkStore` inside the retired engine gem and that "NO CODE HERE READS ANY OF THOSE NAMES -- checked by grep across app/, lib/, config/ and bin/, not assumed". CLAUDE.md §7 states the same. So every `-d ovh` deploy, and every `bin/secrets-preflight --all`, resolves two vault refs that nothing consumes.
- The same cleanup was already applied to the other two overlays and only ovh was missed: config/deploy.share.yml:43-45 and config/deploy.s3.yml:36-39 both carry a `STORAGE_BACKEND: memory WAS HERE ... there is nothing to neutralise` tombstone where the line used to be. Their file headers were not updated to match — config/deploy.share.yml:16-17 and config/deploy.s3.yml:13-16 still describe `STORAGE_BACKEND=memory` neutralising an inherited chunk store — so the axis is currently half-removed in three different states across three overlays.
- The merged ovh config is contradictory, not merely stale. deploy.ovh.yml sets no LIBRARY_BACKEND, so it inherits `LIBRARY_BACKEND: chunk_remote` from config/deploy.yml:168, while config/deploy.ovh.yml:75 blanks `CHUNK_REMOTE_URL: ""`. lib/library_backend_check.rb:78 (`CHUNK_REMOTE_REQUIRED = %w[CHUNK_REMOTE_URL SYNC_ADMIN_TOKEN]`) and lib/library_backend_check.rb:118-121 refuse to boot when either is blank.
- .kamal/secrets.ovh:23-24 asserts the opposite of the merged config in prose — "this box never runs LIBRARY_BACKEND=chunk_remote and CHUNK_REMOTE_URL is blanked" — which was true when the fourth `remote` destination carried chunk_remote and stopped being true when Arc D Part 2 folded it into the base. The same file's line 31 (and config/deploy.yml:283) still point readers at `.kamal/secrets.remote`, which no longer exists in the tree.

**Current complexity / invalid states**

A destination in this config is described by two overlapping storage models: the LIBRARY_BACKEND axis (share / s3 / chunk_remote plus its knobs), which the app actually reads, and a residual STORAGE_BACKEND + CHUNK_* chunk-store axis that no code in this repo reads any more. Only ovh still carries the second one, and because kamal deep-merges env.clear and never overlays `accessories:`, working out what a destination really declares now means reasoning across the base file, the overlay, the tombstone comments, and two secrets files whose prose disagrees with the merged result.

**Proposed representation**

Collapse to the one axis the code reads. Delete `STORAGE_BACKEND`/`CHUNK_ENDPOINT`/`CHUNK_BUCKET`/`CHUNK_REGION` from config/deploy.ovh.yml's env.clear and the two `CHUNK_*` entries from its env.secret, and drop the corresponding lines from .kamal/secrets.ovh (leaving SYNC_ADMIN_TOKEN, which is genuinely required because `accessories:` is never overlaid — deploy-secrets.md is explicit about that). Then make ovh state its LIBRARY_BACKEND explicitly instead of inheriting one it cannot satisfy, so a destination's storage story is one declared value plus that value's own knobs. Fix the two stale overlay headers to match their own tombstones, and repoint the `.kamal/secrets.remote` citations. config/deploy.r2.example.yml and scripts/r2-cutover/ document and migrate that same retired chunk-store keyspace (scripts/r2-cutover/migrate-chunks.sh:27-31 hard-codes the prefix on the basis of `Storage::ChunkStore#key_for`, a class no longer in this process); they belong with the sync server now rather than here.

**Why simpler**

It removes an entire configuration axis from the deploy model rather than moving branching around: after it, "what storage does this destination use" has exactly one answer per destination instead of two that must be reconciled by a reader. It also removes two vault reads from every ovh deploy and from `bin/secrets-preflight --all` — and deploy-secrets.md's own rule about eager `$(…)` expansion is that a credential a destination never holds should not be resolved for it. Finally it forces the ovh/chunk_remote contradiction into the open instead of leaving it latent behind a destination that bare "deploy" deliberately excludes (§7 — and §7 also records what an excluded destination costs: it drifts).

**Smallest credible implementation scope**

Small for the config edits (two files, ~8 lines removed plus comment updates), but it surfaces one real decision that must be made deliberately rather than mechanically: what LIBRARY_BACKEND ovh should declare. `share` needs a mount it does not have, `s3` needs LIBRARY_S3_* it does not have, and `chunk_remote` needs a reachable sync server, which is the very thing config/deploy.ovh.yml:69-75 says does not resolve there. Retiring the r2-cutover tooling is a separate, larger call and should be handed to the sibling repo rather than deleted in this change.

**Affected files**

- `config/deploy.ovh.yml`
- `.kamal/secrets.ovh`
- `config/deploy.share.yml`
- `config/deploy.s3.yml`
- `config/deploy.r2.example.yml`
- `scripts/r2-cutover/migrate-chunks.sh`
- `scripts/r2-cutover/smoke.sh`

**Regression risks and migration concerns**

OVH is a real internet-facing box, so a config edit here is not free even though the removed names have no reader. Concretely: (1) deciding ovh's LIBRARY_BACKEND is a product decision, not a cleanup — do not pick one to make the file tidy; (2) removing the CHUNK_* secrets is only safe because nothing reads them, which should be re-grepped at the time rather than trusted from config/deploy.yml:120-125's dated claim; (3) test/deploy_hygiene_test.rb:89-96 asserts only that the four *_URL keys are blanked in ovh and derives required secret keys from the merged config (test/deploy_hygiene_test.rb:341-351), so removing a key from both the overlay and the secrets file keeps that guard consistent — but it is derived, so it will not catch a one-sided removal until the preflight runs; (4) the r2-cutover runbook is the only written record of that migration, so move it, do not delete it.

**Validation required**

`bin/secrets-preflight ovh` and `bin/secrets-preflight --all` before and after, comparing the printed key lists (that command is the instrument deploy-secrets.md names, and it prints names and byte lengths only). Then `bin/rails test test/deploy_hygiene_test.rb` for the merged-config guards. Independently confirm the boot contradiction first, since it is the load-bearing claim: build the merged ovh config via `Kamal::Configuration.create_from(config_file: 'config/deploy.yml', destination: 'ovh').raw_config` and read back LIBRARY_BACKEND and CHUNK_REMOTE_URL, then check that pair against lib/library_backend_check.rb:118-121 — read the merged config, do not infer it from the overlay text.

### Cross-subsystem concerns raised by this lane

_Named, not solved — the lane was told to stay inside its boundary._

- bin/backup-status:113-117 reports `volume $volume does not exist — run bin/backup-cron-install` when the real cause is that no `^tinkerex-web-share-` container exists to source a helper image from. It is a wrong diagnosis in the one command that exists to answer "is the nightly actually working". Named here as a bug, not folded into a finding.
- The merged `ovh` destination inherits LIBRARY_BACKEND=chunk_remote (config/deploy.yml:168) while blanking CHUNK_REMOTE_URL (config/deploy.ovh.yml:75), which lib/library_backend_check.rb:118-121 refuses to boot on. That is a defect in a destination bare "deploy" deliberately excludes (§7), so nothing exercises it; it needs a decision from whoever owns that box.
- scripts/r2-cutover/ and docs/r2-migration.md describe migrating the content-addressed chunk keyspace and are written against `Storage::ChunkStore#key_for` and the server's STORAGE_BACKEND/CHUNK_* env — none of which exist in this process any more. scripts/r2-cutover/smoke.sh additionally drives the Rust client's presigned_roundtrip example, and §13 records that no CI leg here reaches into tinkerex-client. Ownership of this tooling now sits with chaim354/tinkerex-sync.
- .kamal/secrets.ovh:31 and config/deploy.yml:283 both cite `.kamal/secrets.remote` as the fullest copy of the SYNC_ADMIN_TOKEN argument, but that file was deleted with the `remote` destination. Two pointers into nothing, in the file a reader consults when one secret fails.

---

## S32 — Test infrastructure & shared adapter contracts

**Lane verdict:** `recommend`

### S32-1 — `use_fresh_share_library!` overrides global FileLayer state but owns none of its teardown — 35 suites hand-roll the same two-line restore, and `create_node!` couples to an `@root` ivar the helper never sets

> **COORDINATOR VERDICT — ACCEPT.** Verified against the tree; no narrowing applied.

- **Category:** state-representation  
- **Lane confidence:** high

**Evidence**

- test/test_helper.rb:171-175 — `use_fresh_share_library!` mktmpdirs a root, assigns `FileLayer.current = FileLayer::Share.new(...)`, and returns the Pathname. It records nothing: no ivar, no flag, no cleanup registration.
- test/test_helper.rb:166-170 — the helper's own comment states the contract it cannot enforce: "A direct assignment sets no @file_layer_backend_pinned either, so the caller MUST pair this with `FileLayer.reset!` in teardown or the adapter leaks into the next test in this forked worker."
- test/test_helper.rb:187-192 — a shared `teardown` block ALREADY exists in this same class and already performs exactly this kind of restore for the sibling helper (`if @file_layer_backend_pinned` → restore ENV + `FileLayer.reset!`). The mechanism is present; `use_fresh_share_library!` simply opted out of it.
- test/test_helper.rb:177-181 — `pin_file_layer_backend`'s comment records the recurring bug in this area verbatim: "Capture the prior value ONCE. A second call in the same test would otherwise overwrite it with the first pin's value, and teardown would 'restore' that into the next test in this worker — a leak that no test would report."
- test/test_helper.rb:138-141 — `create_node!` materialises files only when `defined?(@root)` is true, reading an ivar by convention that `use_fresh_share_library!` never assigns; the coupling exists only because every caller happens to write `@root = use_fresh_share_library!`.
- test/test_helper.rb:135-137 — the comment makes the convention explicit rather than structural: "NO-OPS WHEN THERE IS NO @root... Pair it with `use_fresh_share_library!` in setup (and its FileLayer.reset! in teardown)."
- test/integration/web/files_flow_test.rb:26-33 — the duplicated contract in full: `setup { @root = use_fresh_share_library! }` / `teardown { FileLayer.reset!; FileUtils.remove_entry(@root) if @root&.exist? }`. This exact pair is repeated at 35 call sites in 35 files (verified: `grep -rn '= use_fresh_share_library!' test/ | grep -v test_helper.rb` → 35).
- test/integration/web/files_flow_test.rb:14-21, test/services/library/repo_metadata_purge_test.rb:21-25, test/integration/v1/maker/previews_test.rb:6-10 — three independent copies of the same paragraph re-deriving why the teardown reset is "load-bearing rather than decoration". A rule that has to be re-explained in three suites is one the harness is not carrying.

**Current complexity / invalid states**

One global (`FileLayer.current`) is mutated by two helpers with two different restore disciplines. `pin_file_layer_backend` is self-restoring via `@file_layer_backend_pinned`/`@file_layer_backend_prior` and the shared teardown at test_helper.rb:187-192. `use_fresh_share_library!` is not: it leaves both the adapter override and a fresh tmpdir dangling, and pushes the entire lifecycle onto 35 caller-written teardown blocks plus an ivar-naming convention (`@root`) that a third helper (`create_node!`) silently reads. The invalid state is representable and silent in both directions: forget `FileLayer.reset!` and the next test in the forked worker inherits a Share adapter pointed at a deleted tmpdir (previews_test.rb:8-10 records this surfacing as an unrelated `KeyError`); forget `FileUtils.remove_entry` and the tmpdir accumulates on the CI runner (CLAUDE.md §15 records 334 accumulated `tmp.*` dirs on this same mac runner from exactly this shape). Three files already call the helper more times than they clean up (previews_test.rb, generate_preview_job_test.rb, repo_metadata_purge_test.rb).

**Proposed representation**

Make the override a registered lifecycle owned by test_helper, not a caller convention. `use_fresh_share_library!` records what it did — the tmpdir it created and the fact that `FileLayer.current` was overridden — into ivars it owns (e.g. `@fresh_share_roots << root`, `@file_layer_overridden = true`), assigns `@root` itself for the first call, and returns the root exactly as today so `@root = use_fresh_share_library!` keeps working unchanged. Extend the existing teardown at test_helper.rb:187-192 with a second arm: `FileLayer.reset!` when overridden, and `FileUtils.remove_entry` each recorded root that still exists. Caller `setup` lines stay; caller `teardown` blocks lose their two boilerplate lines. Deliberately keep the direct `FileLayer.current =` assignment — the comment at test_helper.rb:166-168 argues correctly that `pin_file_layer_backend` cannot be used here because it rebuilds from ENV and would need `LIBRARY_PATH`; nothing in that argument requires the *restore* to be manual.

**Why simpler**

The leak stops being representable. Today correctness of a global override is distributed across 35 files, and the failure is silent and lands in a different test than the one that caused it. After, one helper and one teardown own the whole lifecycle — the same shape `pin_file_layer_backend` already has three lines below it, so the class ends up with one discipline for backend overrides instead of two. It also makes `create_node!`'s `defined?(@root)` branch a real dependency (the helper sets it) rather than a naming coincidence between two helpers that never mention each other in code.

**Smallest credible implementation scope**

~15 lines in test/test_helper.rb (record roots + assign @root + one teardown arm). Then a mechanical two-line deletion from the teardown of 35 suites; those deletions are optional and can land incrementally, because a caller that still calls `FileLayer.reset!` and `remove_entry` after the shared teardown has already done so is a harmless no-op (`reset!` nils an already-nil memo, `remove_entry` is guarded by `if @root&.exist?`). That property is what makes this a safe, non-atomic change.

**Affected files**

- `test/test_helper.rb`

**Regression risks and migration concerns**

(1) Teardown ordering — the shared teardown must run AFTER each suite's own, because some suites read `@root` in their teardown; `ActiveSupport::Callbacks` runs `teardown` blocks in reverse declaration order and the base class declares first, so this holds, but it must be verified rather than assumed. (2) Suites that call the helper more than once per test (test/integration/v1/maker/previews_test.rb:68, test/services/library/repo_metadata_purge_test.rb, test/jobs/maker/generate_preview_job_test.rb) need the recorded-roots list, not a single ivar — a single ivar would silently keep leaking the earlier tmpdirs it does today. (3) Tests that deliberately destroy the root mid-test to simulate an unmounted NAS (test/integration/web/share_trash_test.rb:148) require the cleanup to stay `if exist?`-guarded. (4) test/services/library/repo_metadata_purge_test.rb:301-313 resets FileLayer mid-test on purpose so the factory is exercised; that path must stay untouched. (5) Suites that set `@root` for a purpose other than a share library (e.g. test/services/file_layer/share_test.rb:27) must not be handed a second meaning for the ivar — scope the auto-assignment to the helper's own first call only.

**Validation required**

Mutation-check per CLAUDE.md §15, which this change is specifically buying: delete the new teardown arm and confirm a targeted two-test run goes RED (test A calls the helper, test B in the same worker asserts `FileLayer.current` is not a Share pointed at a removed directory) — the point is that today no test goes red for this at all. Then run `bin/ci test`, `test-s3` and `test-chunk-remote` and confirm identical run counts across the three legs (the helper is used by suites on all three). Finally count `tmp/test-library*` directories before and after a full `bin/rails test` run to confirm the tmpdir accumulation actually stops.

### S32-2 — Two incompatible hand-rolled method-stub idioms, five copies inside the boundary, with the same rationale comment written out four times

> **COORDINATOR VERDICT — ACCEPT.** Verified against the tree; no narrowing applied.

- **Category:** ownership  
- **Lane confidence:** medium

**Evidence**

- test/test_helper.rb:77-84 — `without_svg_rasterizer` uses the UnboundMethod idiom: capture `mod.instance_method(:available?)` into a local, `define_method` a replacement, restore the UnboundMethod in `ensure`.
- test/test_helper.rb:253-266 — `with_concurrent_file_attachment` repeats the identical idiom on `ActiveRecord::Relation#create_or_find_by!`, with lines 237-249 recording that the *other* obvious restore (`remove_method`) produced a `SystemStackError` that surfaced in the NEXT test rather than this one.
- test/worker_budget_test.rb:141-147 — `with_concurrent_suite` uses a DIFFERENT idiom for the same job: `singleton_class.alias_method :__real_concurrent, :concurrent_browser_suite?`, `define_singleton_method`, then alias back in `ensure`.
- test/worker_budget_test.rb:199-213 — `stub_total` repeats that alias idiom three times in one method (`__real_total`, `__real_avail`, `__real_cores`), i.e. six alias statements for three swaps.
- test/worker_budget_test.rb:121-135 — a fifth copy, inline in a test body with its own hand-written `begin`/`ensure`, aliasing `__real_alive` around `process_alive?`.
- test/test_helper.rb:72-76 and test/test_helper.rb:251-252 and test/worker_budget_test.rb:138-140 and test/support/fake_service_proxy.rb:3-4 — four separate copies of the same explanatory note ("minitest 6 dropped minitest/mock, so `stub` does not exist in this suite"). The fake_service_proxy copy cites `test/test_helper.rb:147`, a line that no longer holds that note — evidence the copies have already begun to drift.

**Current complexity / invalid states**

"Swap a method for the duration of a block, then put it back" is implemented five times inside the boundary in two mutually incompatible ways. The alias variant stores the original under a fixed global name on the singleton, so it is only correct while no two overlapping uses ever target the same method: a nested or repeated `with_concurrent_suite`/`stub_total` would alias `__real_*` to the *stub*, and the outer `ensure` would then "restore" the stub permanently into the forked worker — the precise failure mode `pin_file_layer_backend` documents at test_helper.rb:178-181 for ENV pinning, unguarded here. The UnboundMethod variant is nesting-safe by construction because the original lives in a block-local. Nothing today tells a reader which of the two to reach for, and the reason both exist (no `minitest/mock`) is re-explained in four places instead of once.

**Proposed representation**

One shared block helper in test/test_helper.rb built on the UnboundMethod idiom — the nesting-safe one this file already prefers and already documents — e.g. `with_stubbed_method(owner, name) { |*args| ... }` capturing `owner.instance_method(name)` and restoring it in `ensure`, plus a plural form for the three-at-once case `stub_total` needs. Convert the five sites; delete the three duplicated rationale comments in favour of one on the helper. The alias-based variant and the `__real_*` names disappear entirely.

**Why simpler**

One idiom instead of two, with the unsafe one removed rather than merely discouraged, and the reason for the idiom stated once where a reader looking for a stub will actually find it. This is the argument test_helper.rb:69-71 already makes for `without_svg_rasterizer` — "Shared rather than copied. Three suites need it, and a per-file copy is how one of them silently stops stubbing the thing it means to" — applied to the mechanism instead of to one instance of it. The stale `test_helper.rb:147` citation in fake_service_proxy.rb is the drift that argument predicts.

**Smallest credible implementation scope**

~12 lines added to test/test_helper.rb; five call sites rewritten (two in test_helper.rb, three in test/worker_budget_test.rb). No production code, no new dependency — the whole point of the current shape is that adding a mocking gem was rejected (§9 licence check, test/worker_budget_test.rb:138-140), and this keeps that.

**Affected files**

- `test/test_helper.rb`
- `test/worker_budget_test.rb`
- `test/support/fake_service_proxy.rb`

**Regression risks and migration concerns**

Low, but real and worth stating: the value here is consolidation plus removal of a LATENT hazard, not a bug that fires today — no current site nests, so nothing is presently broken, and this must not be sold as a correctness fix. The helper must restore with `define_method(name, unbound)` and never `remove_method`, for the reason test_helper.rb:237-249 records at length. It must also work for singleton methods on a module (`WorkerBudget`) and for instance methods on a class (`ActiveRecord::Relation`), which is `owner` being `X.singleton_class` in one case and `X` in the other — getting that wrong silently stubs nothing. There are ~66 further occurrences of these idioms across 16 other test files outside this boundary; converting those is out of scope here.

**Validation required**

Mutation-check the helper itself, since it exists to guarantee restoration: break the `ensure` and confirm the following test in the same file goes RED (today, with `with_concurrent_suite`, it would). Assert restoration explicitly in one case — capture `WorkerBudget.method(:process_alive?)` before and after and compare — because a helper that never restores passes every existing assertion in test/worker_budget_test.rb. Then run `bin/ci test` and confirm the run count is unchanged.

### Cross-subsystem concerns raised by this lane

_Named, not solved — the lane was told to stay inside its boundary._

- The `use_fresh_share_library!` lifecycle change touches 35 suites outside this subsystem (test/integration/web/*, test/system/*, test/jobs/maker/*, test/services/*). The proposal is deliberately backward-compatible so those deletions can land incrementally, but whoever owns those suites should confirm no teardown reads `@root` after the shared teardown would have removed it.
- The method-stub idiom appears ~66 more times across 16 test files outside this boundary (test/services/library/repo_metadata_purge_test.rb:319-325, test/services/maker/previews/lbrn2_test.rb, test/services/maker/project_intake_test.rb, and others). Converting them is out of scope here; the shared helper should be introduced in test/test_helper.rb so those subsystems can adopt it without a second definition.
- test/support/fake_service_proxy.rb:3-4 cites `test/test_helper.rb:147` for the minitest/mock note; that line reference is stale. Any file citing another file by line number in this suite is a claim nothing checks — CLAUDE.md §15's `bin/verify-fix-log` rule about commit references applies to this shape too.

---

## S33 — Schema map generator

**Lane verdict:** `recommend`

### S33-1 — `lib/tasks/engine_schema.rake` is a rake namespace whose only subject was deleted — every task body raises NameError

> **COORDINATOR VERDICT — ACCEPT.** Verified against the tree; no narrowing applied.

- **Category:** ownership  
- **Lane confidence:** high

**Evidence**

- lib/tasks/engine_schema.rake:6-7 — `was = EngineSchema.output_path.exist? ? EngineSchema.output_path.read : nil` / `path = EngineSchema.write!`; lines 10-11 read `EngineSchema::OUTPUT` and `EngineSchema.tables`; line 16 reads `EngineSchema.current?`. Every statement in both task bodies names the constant `EngineSchema`.
- `grep -rn "EngineSchema" --include="*.rb" --include="*.rake" .` (excluding docs/) returns ONLY those six lines in lib/tasks/engine_schema.rake. There is no other definition or reference anywhere in the tree.
- `ls lib/engine_schema.rb db/engine_schema.rb test/engine_schema_test.rb` → all three "No such file or directory". `git log --oneline --diff-filter=D -- lib/engine_schema.rb db/engine_schema.rb test/engine_schema_test.rb` → f4e5172 "Arc D Part 2 Task 4: the sync engine is no longer a dependency of this app"; `git show --stat f4e5172` shows `db/engine_schema.rb | 118 ---` and `lib/engine_schema.rb | 158 ---` and no mention of the rake file.
- docs/superpowers/plans/2026-08-25-arc-d-part-2-retire-embedded-chunk.md:120 — the plan step reads "Delete `db/engine_schema.rb`, `lib/engine_schema.rb`, `test/engine_schema_test.rb`". The rake file is not in that list, which is why it survived; `git log --oneline -1 -- lib/tasks/engine_schema.rake` is still a8ae7bb, the commit that created it.
- Rakefile (6 lines) is the stock `Rails.application.load_tasks`, so `lib/tasks/*.rake` is loaded unconditionally and both tasks are listed by `bin/rails -T`. Rake task bodies are blocks, so load succeeds and the failure is deferred to invocation — which is exactly why nothing has gone red.
- `grep -n "engine_schema\|schema:map" config/ci.rb .github/workflows/*.yml` → no matches. No gate invokes either namespace, so no CI leg can notice.

**Current complexity / invalid states**

Two rake tasks — `engine_schema:generate` and `engine_schema:check` — advertise a capability ("Regenerate db/engine_schema.rb -- the sync engine's draft consolidated migration") that this repo no longer has any subject for. `db/engine_schema.rb`, `lib/engine_schema.rb` and `test/engine_schema_test.rb` were all deleted in Arc D Part 2 when the sync engine stopped being a dependency (CLAUDE.md §12.12, §14j). The file is not merely unused: it is non-functional. Invoking either task NameErrors on `EngineSchema` on its first statement. Meanwhile it sits in `bin/rails -T` output as a live-looking maintenance command, and the description string still asserts the pre-split architecture ("the sync engine's draft consolidated migration") that CLAUDE.md §3 and §10 now explicitly say lives in `chaim354/tinkerex-sync`.

**Proposed representation**

Delete lib/tasks/engine_schema.rake. Nothing replaces it — the cross-repo consolidated-migration obligation ended with the gem dependency, which is precisely what f4e5172 recorded when it removed the other three files. If any residual value is wanted, it belongs in tinkerex-sync's own repo, per CLAUDE.md §15's "Do not add sync-engine knowledge to this file" rule applied to code.

**Why simpler**

It removes a whole rake namespace, its two task definitions, and the last code-level reference to the retired `EngineSchema` module from a repo whose architecture docs state in three places that the sync engine is not a dependency. This is not a stylistic tidy: the current state is a discoverable command that cannot run, plus a description that contradicts §2/§3/§12.12. It also completes a deletion that was demonstrably intended and simply missed — the plan step at line 120 enumerates three files and the fourth was overlooked. There is no comment anywhere in the tree, and nothing in CLAUDE.md, arguing for keeping it; the only prose that mentions it is the plan that meant to remove its siblings.

**Smallest credible implementation scope**

Delete one 19-line file. Separately (cross-subsystem, do not bundle): app/controllers/concerns/v1/authentication.rb:17 cites `test/engine_schema_test.rb` as a live example of the duplicate-then-guard pattern, and that file no longer exists — the comment should point at something real or drop the analogy.

**Affected files**

- `lib/tasks/engine_schema.rake`
- `app/controllers/concerns/v1/authentication.rb`

**Regression risks and migration concerns**

Essentially none. No gate, workflow, script or doc invokes `engine_schema:generate` or `engine_schema:check` (verified by grep across config/ci.rb, .github/workflows/, and the repo's *.rb/*.rake/*.sh/*.yml). The only mentions outside the file are historical plan/spec documents under docs/superpowers/, which describe finished work and should not be edited (CLAUDE.md §15: a dated snapshot of finished work). The one thing to preserve is the reasoning, and it already lives in the Forgejo arc record and in f4e5172's commit message.

**Validation required**

After deletion: `bin/rails -T | grep engine_schema` returns nothing; `grep -rn EngineSchema app/ lib/ test/ config/ bin/` returns nothing. `bin/ci` should be unaffected — confirm the `test` leg's run count is unchanged, since no test file references the namespace. Before deleting, mutation-check the claim the other way: `bin/rails engine_schema:check` today should fail with `NameError: uninitialized constant EngineSchema`, which demonstrates the task has no subject rather than merely no caller.

### S33-2 — `annotate` mutates the memoized parse results in place, so `SchemaMap.tables` silently changes meaning once `data`/`render` has run

> **COORDINATOR VERDICT — ACCEPT.** Verified against the tree; no narrowing applied.

- **Category:** state-representation  
- **Lane confidence:** high

**Evidence**

- lib/schema_map.rb:210-212 — `def tables; @tables ||= SOURCES.flat_map { |db, path| parse(db, root.join(path).read) }; end`. The parsed column hashes are memoized on the module and handed out by reference to every caller.
- lib/schema_map.rb:294-295 — `columns = [ { "n" => "id", ... } ] + t["columns"]` then `columns.each { |c| annotate(c, t, name, sources, targets) }`. The `+` builds a new ARRAY but the elements after the first are the same hash objects that live in `@tables`.
- lib/schema_map.rb:335-346 — `annotate` writes badges straight onto its argument: `col["u"] = true`, `col["ix"] = true`, `col["ref"] = true`, `col["fkc"] = true`, `col["key"] = true`, `col["cu"] = composite["cols"].join(", ")`, then returns `col`. No copy is taken anywhere on the path.
- Verified by running the module read-only (`ruby -rjson -rset -rpathname -e 'require "./lib/schema_map"; ...'`): before `SchemaMap.data`, `nodes.node_id` is `{"n"=>"node_id","t"=>"string","req"=>true}`; after `SchemaMap.data`, the SAME object read back through `SchemaMap.tables` is `{"n"=>"node_id","t"=>"string","req"=>true,"key"=>true,"cu"=>"user_id, node_id"}`. Likewise `users.email` gains `"u"=>true,"ix"=>true`. An `equal?` check on the before/after objects printed `true`.
- test/schema_map_test.rb:39-49 — the parse-fidelity test asserts EXACT hash equality, e.g. `assert_equal({ "n" => "content_hash", "t" => "string" }, column("nodes", "content_hash"))`, via the helper at test/schema_map_test.rb:91-93 which reads `SchemaMap.tables`.
- test/schema_map_test.rb:27 and :32 — the staleness test calls `SchemaMap.render` and `SchemaMap.payload`, both of which reach `data` (lib/schema_map.rb:308 and :314) and therefore run `annotate` over the shared hashes. Minitest randomizes order within a class, so the two tests can run in either order in the same process.
- test/schema_map_test.rb:96-98 — `rendered_column` exists specifically to read "the same column as the page draws it: annotated with the badges `data` computes", i.e. the suite is built around a parsed-vs-rendered distinction that the aliasing collapses whenever `data` has already run.

**Current complexity / invalid states**

The module has two intended shapes for a column — the parse result (`n`, `t`, `req`, `d`) and the rendered result (parse plus the `u`/`ix`/`ref`/`fkc`/`key`/`cu` badges) — but only one set of objects. `data` annotates the memoized hashes in place, so `SchemaMap.tables` returns parse-shaped columns before any render and render-shaped columns after one, within the same process, with nothing in the API signalling which you have. The suite is written as if the two shapes were distinct (two helpers, `column` and `rendered_column`, at test/schema_map_test.rb:91-98) and its exact-equality assertions at lines 39-49 are order-dependent as a result. They pass today only by accident of which five columns were chosen: none of `nodes.content_hash`, `nodes.deleted`, `maker_bom_lines.quantity`, `solid_cache_entries.key` or `maker_addon_states.data` carries a badge (checked against db/schema.rb and db/cache_schema.rb — e.g. solid_cache_entries indexes `key_hash`, not `key`, and the nodes index on content_hash is composite and non-unique). Nothing in lib/schema_map.rb, test/schema_map_test.rb, or CLAUDE.md argues for the in-place mutation; it reads as incidental.

**Proposed representation**

Make `annotate` non-mutating and let `data` own the rendered shape: build the badges into a fresh hash (`col.merge(badges)`) and have lib/schema_map.rb:295 `map` rather than `each`. `SchemaMap.tables` then always means "what the dumps say" and `SchemaMap.data` always means "what the page draws", for the whole life of the process and in any call order.

**Why simpler**

One shape, one owner. Today the same object is both the parse output and the render output depending on execution history, which is the shape that makes an order-randomized test order-dependent and makes `SchemaMap.tables` unsafe to reason about from outside. The fix removes the aliasing rather than documenting it, and it makes the suite's existing parse-vs-render distinction real instead of accidental — which matters here because test/schema_map_test.rb:36-38 says in as many words that those assertions exist to stop a PARSER bug being baked into the map and called current. An assertion that can be silenced by test ordering is the vacuous-guard failure mode CLAUDE.md §15 and §14e already name twice ("a guard that skips on the thing it asserts is vacuous").

**Smallest credible implementation scope**

About four lines in lib/schema_map.rb: change `columns.each { |c| annotate(...) }` (line 295) to a `map`, and change `annotate` (lines 335-346) to accumulate into a new hash and return it instead of writing into `col`. No call-site outside `data` uses `annotate` (it is private). Optionally add one assertion in test/schema_map_test.rb on a badged column (e.g. `users.email` or `nodes.node_id`) so the guard actually covers the case it is now immune to.

**Affected files**

- `lib/schema_map.rb`
- `test/schema_map_test.rb`

**Regression risks and migration concerns**

Low, and mechanically checkable. The only real requirement is that `data`'s output be byte-identical, so `docs/schema-map.html` does not move — the existing staleness test (test/schema_map_test.rb:24-34) and `bin/rails schema:map:check` both assert exactly that. Watch two details: `annotate` sets keys conditionally (`if single && single["unique"]`, etc.), so the merged hash must omit absent keys rather than setting them to nil — a nil would change the JSON payload and rewrite the page; and the synthetic `id` column at line 294 is constructed fresh each call, so it is unaffected either way. Key insertion order must also be preserved, since JSON.generate emits in insertion order and the page is compared byte-for-byte.

**Validation required**

`bin/rails schema:map:check` must still print "docs/schema-map.html is current" with no rewrite — that is the byte-identity proof. Then mutation-check the new guard the way CLAUDE.md §15 requires: add `assert_equal({ "n" => "email", "t" => "string", "req" => true }, column("users", "email"))` to the parse test and confirm it is stable across several `bin/rails test test/schema_map_test.rb --seed N` values; on the unfixed code that same assertion should go RED for at least some seeds (whenever the staleness test runs first) and green for others, which is the demonstration that the current representation is order-dependent.

### Cross-subsystem concerns raised by this lane

_Named, not solved — the lane was told to stay inside its boundary._

- app/controllers/concerns/v1/authentication.rb:17 cites `test/engine_schema_test.rb`'s cross-repo byte-identity check as the model for `test/v1_auth_parity_test.rb`'s duplicate-then-guard shape. That test file was deleted in f4e5172 and no longer exists, so the comment points a reader at nothing. Out of scope for S33 (it is the v1 auth concern's comment, not the schema-map tool), flagged rather than fixed.
- docs/schema-map.html is a generated artifact in a hand-written directory. It is guarded by test/schema_map_test.rb and by `bin/rails schema:map:check`, but nothing in config/ci.rb or .github/workflows/*.yml invokes the rake task — the coverage comes solely from the suite. That is adequate today; noting it because the same absence is what let lib/tasks/engine_schema.rake rot unnoticed.

---

## S34 — GPL sidecars (Python)

**Lane verdict:** `skip`

**This subsystem was reviewed and deliberately returned no findings.** The lane's argument:

> Read in full: sidecar/openscad/{app.py(190), coerce.py(198), schema.py(104), render.py(200)}, sidecar/boxes/app.py(396), and the pytest suites (openscad tests/test_{coerce,schema,api,catalog,render}.py; boxes tests/test_api.py). Also read docs/invariants/addons.md and the S37/S38 sections of docs/AUDIT-2026-08-19.md, which audited these same two files on 2026-08-19.
>
> Why skip: this subsystem was deep-audited seven days ago and three of the four findings have LANDED, visibly, in the current tree — F-59 (double schema derivation under opposite failure policies) is gone, replaced by the single `_coerced` path with its "do not reintroduce a second, softer reader" argument at sidecar/openscad/app.py:166-190; F-60 is the hand-rolled success-only memo at sidecar/openscad/render.py:41-77; F-61 is the two memoized catalogues at sidecar/boxes/app.py:55-111. F-62 (the flat `params` key at sidecar/boxes/app.py:388-391) is DELIBERATELY NOT DELETED and is pinned by sidecar/boxes/tests/test_api.py:316-360, whose docstring states the out-of-repo gate ("grep chaim354/tinkerex-addons ... AND any pinned older build"); re-recommending it would be re-raising a decision already made with a written reason. What is left is ~1100 lines of single-purpose code in which nearly every branch carries the measured bug that produced it.
>
> Candidates I examined and rejected as below the bar:
> 1. Parallel-array `choices`/`choice_labels` in sidecar/openscad/schema.py:38-39,44-49 vs the `{choice: label}` MAP in sidecar/boxes/app.py:192-196. Real divergence (verified: sidecar/openscad/tests/test_schema.py:66-67 asserts `choices == [1, 2]` with `choice_labels == ["solid", "hollow"]`; sidecar/boxes/tests/test_api.py:387-396 asserts a dict), but it is not a SIMPLIFICATION — both lists are built in one expression from one source list and can never drift, so no invalid combination is representable, and a dict comprehension is not smaller than a list comprehension. The actual risk is a consumer contract mismatch, so it is recorded below as a cross-subsystem concern instead.
> 2. Consolidating the four separate walks of argparse's private `_action_groups`/`_group_actions` in sidecar/boxes/app.py:130-133, :238, :282-283 (plus the double derivation at :313-314, where `_exposed(box)` already calls `_actions(box)`). One place owning the private-API shape is attractive and matches the file's own doctrine (:128, :137-139: separately-derived views are the bug class here), and :238 has already drifted (it includes the `_HelpAction` that `_actions` excludes — harmless today, it only reads sx/sy). But a view threaded through `_param(a, box)` → `_seeded_default(box, a)` widens three signatures to delete three one-line comprehensions, and it is cost-neutral unless the view is also memoized per box. Churn > gain.
> 3. Memoizing the whole `/generators` payload in boxes (the explicitly un-taken second half of F-61; sidecar/boxes/app.py:377-396 re-instantiates ~181 generators per request, and sidecar/boxes/tests/test_api.py:303-313 already pins that two calls are byte-identical). Rejected because `_seeded_default`'s `except Exception` fallback at :246-248 returns the unusable "\n" default, so a transient seeding failure on the FIRST request would be frozen for that worker's whole life — precisely the sticky-degraded-state failure render.py:53-58 hand-rolled its memo to avoid. A correct version needs success-only semantics, which is a bug-shaped change, not a simplification.
> 4. Passing coerce() the flat `params` list instead of `param_groups` (sidecar/openscad/coerce.py:69 re-flattens a presentation-shaped nesting to build its name index; schema.py:26 already emits the flat list). Decouples validation from the form's grouping, but deletes one nested comprehension at the cost of ~10 test call sites, and the flat key it would depend on has no verified live consumer.
> 5. A dataclass for the param spec shared by schema.py/coerce.py. Rejected: the dict IS the wire shape (app.py:88,126 jsonify it directly), so a typed model adds a serialization hop; the brief also excludes moving existing branching behind a new type.
> 6. render.py's `vector_names` branch (:103-113) and `param_set_json`'s string coercion: explicitly argued as not-dead-code for direct callers, with the silent-default failure it defends named. CLAUDE.md §15 / the file's own comment argue for the current shape; left alone.
> Not findings by rule: GPL LICENSE files, the Dockerfiles, catalog/*.scad.

---

## S35 — stl-thumbnailer (Rust)

**Lane verdict:** `skip`

**This subsystem was reviewed and deliberately returned no findings.** The lane's argument:

> Read in full and verified line-by-line: tools/stl-thumbnailer/src/lib.rs (237 lines), src/main.rs (32), tests/render.rs (198), Cargo.toml (34), plus README.md and the Rails call site app/services/maker/previews/stl.rb for context (exec'd via Open3.capture3 with in/out paths + w/h; the only consumer, alongside Maker::Previews::ThreeMf#mesh_to_stl at app/services/maker/previews/three_mf.rb:59,124 which feeds STL bytes into the same binary).
>
> WHY SKIP — measured against the brief's own categories, none is present:
>
> 1. Scattered booleans / nullable fields permitting invalid combinations: none. The crate holds exactly two data structures, both total. `Vert { pos: Vec3<f32>, normal: Vec3<f32> }` (lib.rs:36-41) has no optional field — `build_vertices` (lib.rs:127-152) guarantees a usable normal on every vertex by construction: the STL face normal when `magnitude_squared() > 1e-12` (lib.rs:137), else a cross-product recompute, else `Vec3::unit_z()` as the total fallback (lib.rs:141-145). `ThumbPipeline { mvp, light_dir }` (lib.rs:44-48) is two immutable fields built once at lib.rs:113. There is no Option, no bool, and no enum anywhere in the crate.
>
> 2. Lifecycle / concurrency / async state permitting staleness: none. `render_stl` (lib.rs:89-122) is a pure function of `(&[u8], u32, u32) -> Result<Vec<u8>>`. No globals, no interior mutability, no I/O except in main.rs's thin CLI wrapper (main.rs:27-29). The only mutable state is the two `Buffer2d`s created and consumed within one call (lib.rs:103-104).
>
> 3. Duplicated branching a map/registry/reducer would remove: there are only TWO branches in the whole library — `if !verts.is_empty()` (lib.rs:106) and the normal-validity check (lib.rs:137). Two branches cannot be de-duplicated into a dispatch table.
>
> 4. Repeated scans / wrong collection: one pass in `build_vertices` (lib.rs:129), one AABB pass in `auto_frame` (lib.rs:171-174), one downsample pass (lib.rs:208-224). Each is single-purpose and reads once. `auto_frame` scans 3N flattened vertices where the indexed mesh holds N unique ones, but that is a constant-factor perf nuance on a thumbnail-sized mesh (README measures ~8 ms / 5000 tris), not a representation problem, and threading `stl_io::IndexedMesh` down into `auto_frame` would ADD coupling to buy nothing.
>
> 5. Unclear ownership needing a module boundary: the four functions have crisp, non-overlapping jobs — parse+orchestrate, flatten, frame, downsample, encode. The lib/bin split is load-bearing: tests/render.rs:6 imports `stl_thumbnailer::render_stl`, so the `[lib]` target at Cargo.toml:8-10 is not vestigial even now that the desktop consumer is gone.
>
> CANDIDATES I CONSIDERED AND REJECTED, with the reason:
>
> (a) The packed `0x00RRGGBB` u32 pixel is packed at lib.rs:76-80 (`(r << 16) | (g << 8) | b` in `frag`), packed again at lib.rs:102 (the background constant), and unpacked at lib.rs:214-217 (`(px >> 16) & 0xff` etc. in `downsample`) — three sites of hand-rolled shift arithmetic. A small `Rgb` newtype with `pack`/`unpack` would centralize it. REJECTED: `u32` is forced by euc's `Pipeline::Pixel` associated type (lib.rs:56), so a newtype would be unwrapped at the rasterizer boundary anyway; the total arithmetic is ~10 lines; and this is precisely the "moving existing branching behind a new type" and "minor line-count reduction" the brief excludes.
>
> (b) tests/render.rs duplicates one "is this pixel ink?" predicate twice — the manhattan-delta-vs-background test with the literal threshold 24 appears at render.rs:29-33 (`non_background_ratio`) and again at render.rs:114-118 (`ink_bbox`), with two different background-determination strategies (most-common color at render.rs:25 vs corner pixel at render.rs:110). A shared ink-mask helper would remove the drift risk. REJECTED as sub-threshold: ~15 lines in a 198-line test file, and the two bg strategies may be deliberately different for their respective framings. Not worth spending a finding slot on.
>
> (c) main.rs repeats the usage string verbatim at main.rs:20 and main.rs:23. Two lines. Trivial.
>
> (d) `ink_bbox` accepts `h` and discards it (`let _ = h;` at render.rs:127). A dead parameter, not a data-structure problem.
>
> STRONG EVIDENCE AGAINST CHANGE, per the repo's own rules: three of the crate's apparent oddities are explicitly argued for in comments, and I am NOT recommending any of them be undone. The `UP` constant (lib.rs:32-34) is named rather than inlined precisely because "the camera direction and the look-at both have to agree about it, and they did not." The `auto_frame` doc block (lib.rs:157-167) records the shipped Y-up-camera bug that tipped every library thumbnail sideways past a fully green suite, and tests/render.rs:149-167 + 169-181 are the two positional guards that catch it in both directions — mutation-checked, per the comment at render.rs:154-156, exactly as CLAUDE.md §15 demands. The SSAA-instead-of-MSAA choice (lib.rs:9-11, Cargo.toml:18-21) and the euc 0.5.3 / vek 0.14 pinning are both justified with measurements. Licensing is compliant with §9: Cargo.toml:6 declares Apache-2.0 and every dependency comment (Cargo.toml:17-31) names a permissive license.
>
> This is a small, clear, stateless renderer whose complexity is inherent to CPU rasterization. It meets the brief's "prefer boring local code when it is already clear" bar. Recommending a change here would be manufacturing a finding.

---

## S36 — Boot config, routes & database schema

**Lane verdict:** `recommend`

### S36-1 — `nodes` still carries three sync-engine state columns with no reader in this repo — one of them (`updated_seq`) with an index paid on every node write

> **COORDINATOR VERDICT — ACCEPT (count corrected).** The grep count in the evidence is WRONG — `rg updated_seq` returns SEVEN hits, not five (the lane dropped drop_redundant_prefix_indexes.rb:26, which it cites two bullets later). The CONCLUSION survives: no read, no write in app code. NOTE: dropping the index does NOT make PREFIX_INDEX_EXEMPTIONS vacuous — index_nodes_on_user_id prefixes FIVE composites, not one.

- **Category:** state-representation  
- **Lane confidence:** high

**Evidence**

- db/schema.rb:388 — `t.bigint "updated_seq", default: 0, null: false` on the `nodes` table, and db/schema.rb:394 — `t.index ["user_id", "updated_seq"], name: "index_nodes_on_user_id_and_updated_seq"`. Both are live in the current schema.
- `rg -n "updated_seq" app/ lib/ config/ test/ db/` returns exactly five hits and NONE is a read or a write: app/services/library/reconciler.rb:40 and app/services/maker/project_intake.rb:461 are prose comments; db/migrate/20260611010000_create_sync_engine.rb:32 (`t.bigint :updated_seq, null: false, default: 0  # changelog seq of last change`) and :37 (`add_index :nodes, %i[user_id updated_seq]`) are the original DDL; db/schema.rb is the dump. There is no `updated_seq =`, no `.updated_seq`, no pluck/select/order naming it anywhere in app/ or lib/. The column is 0 on every row in every deployment and always will be — the thing that incremented it was `Sync::Journal`-style commit code that left with the engine (Arc D Part 2).
- `rg -n '\.mode\b' app/ lib/ -g '*.rb'` returns exactly ONE line — app/services/file_layer/chunk_remote/changelog_sync.rb:182 `row.mode = payload["mode"]` — a write with no reader. `rg -n 'symlink_target' app/ lib/ config/` returns exactly one line, changelog_sync.rb:196 `row.symlink_target = Base64.decode64(payload["symlink_target"]) if payload["symlink_target"]` — also write-only. Contrast `mtime`, set on the same lines (:183) and genuinely read (app/services/file_layer/chunk_remote.rb:445 `mtime: node.mtime`), and `size`/`content_hash`/`storage_path`, which db/migrate/20260716025826_add_share_columns_to_nodes.rb:1-13 documents as live share/s3 state.
- The precedent and the safety procedure are already established here: db/migrate/20260825140000_drop_retired_sync_engine_tables.rb:12-14 states the rule explicitly — "THAT RULE IS ABOUT REWRITING HISTORY, NOT ABOUT ADDING TO IT. A new migration that DROPS the tables is the ordinary, safe operation" — and :21-27 enumerates what was deliberately NOT dropped and why (`remote_manifest_chunks`, `users.head_seq`, `nodes`). That migration cleaned the engine's TABLES; the engine's COLUMNS on this app's own `nodes` table were not part of it.
- db/migrate/20260819120000_drop_redundant_prefix_indexes.rb:1-4 states the cost model this repo already accepted for exactly this shape: a redundant btree "only costs: another btree to maintain on every insert/update/delete of the row, and another copy of the leading column on disk", and :22-32 records the measured plan work behind keeping `index_nodes_on_user_id`. `index_nodes_on_user_id_and_updated_seq` is named there only as the *worse* fallback plan the planner drops to — never as an index any query wants.

**Current complexity / invalid states**

The `nodes` table is this app's own catalog on all three backends (and chunk_remote's mirror), and it is the hottest bulk-write table in the app — `Library::Reconciler` writes node rows for an entire NAS/S3 library on every scan. Its column list currently mixes three kinds of state with nothing distinguishing them: live maker-catalog state (`storage_path`, `content_hash`, `size`, `mtime`, `deleted`, `current_version_id`), engine state that is mirrored but never consulted (`mode`, `symlink_target`), and engine state that is neither written nor read (`updated_seq`, NOT NULL default 0, plus a dedicated index). A reader auditing the catalog cannot tell which is which without grepping each column, and `updated_seq`'s index is descended and split on every node insert and update for a column whose value is constant.

**Proposed representation**

One forward-only migration in the shape db/migrate/20260825140000 already established: `remove_index :nodes, %i[user_id updated_seq]` then `remove_column :nodes, :updated_seq`, with the migration comment carrying the grep result that justifies it (zero readers, zero writers) the way the table-drop migration carries its 0-rows verification. Scope the recommendation to `updated_seq` alone as the confident case. Treat `mode` and `symlink_target` as a separate, weaker question and leave them for now: they are write-only in this repo, but they are the chunk_remote mirror's fidelity to the sync server's tree, and the argument for dropping them is a cross-repo one (whether the mirror is allowed to be lossy) rather than a local one. If they stay, one line beside them in the migration recording "mirrored for fidelity, deliberately unread here" makes the three-way distinction legible without changing behavior.

**Why simpler**

It removes state that cannot be correct or incorrect because nothing consults it, and removes a write-path cost paid on the app's highest-volume table for nothing. More importantly for a reader: after the change, every column on `nodes` is either read by this app or explicitly annotated as mirror fidelity, so the question "is this live?" has an answer at the schema instead of requiring a grep per column. That is exactly the failure mode CLAUDE.md §14e names — "a stale open-list is worse than none, because it spends the next reader's attention on finished work" — applied to schema rather than to a ledger.

**Smallest credible implementation scope**

One new migration file under db/migrate/ plus the regenerated db/schema.rb. No app/ or lib/ change is required, because there is no call site. The two prose comments that mention `updated_seq` (app/services/library/reconciler.rb:40, app/services/maker/project_intake.rb:461) would want a one-word touch-up but neither is load-bearing.

**Affected files**

- `db/schema.rb`
- `db/migrate/20260611010000_create_sync_engine.rb`
- `app/services/file_layer/chunk_remote/changelog_sync.rb`

**Regression risks and migration concerns**

Dropping a column from a populated table is irreversible in the direction that matters, so the migration should be preceded by the same discipline db/migrate/20260825140000 used: confirm on each live deployment that the column holds only its default (here, `SELECT COUNT(*) FROM nodes WHERE updated_seq <> 0` on chunk_remote, share and s3) rather than reasoning from "nothing reads it". SQLite's `remove_column` rebuilds the table, so on a large self-host library it is a one-time O(N) rewrite under the write lock — schedule it, do not run it under load. A `down` is trivially writable here (unlike the table drop), so make it reversible. Finally: `index_nodes_on_user_id` is exempted from test/architecture_invariants_test.rb's strict-prefix guard (PREFIX_INDEX_EXEMPTIONS at :938-941); that exemption is unaffected, because `(user_id)` remains a strict prefix of `(user_id, node_id)` and `(user_id, content_hash)` regardless.

**Validation required**

Before: `rg -n 'updated_seq' app/ lib/ config/` must return only the two prose lines — that is the whole correctness argument and it is mechanically checkable. After: run all three backend legs (`bin/ci test`, `test-s3`, `test-chunk-remote`) and confirm identical run counts per §15; a chunk_remote leg that goes red would mean the changelog mirror does write it after all, which is the one thing that would falsify the finding. The strict-prefix guard in test/architecture_invariants_test.rb must still pass with its existing exemption unchanged. Mutation-check the migration itself by asserting a query against `nodes` still plans through `index_nodes_on_user_id` (the exemption's measured claim at test/architecture_invariants_test.rb:930-937) after the drop.

### S36-2 — The removed v1 sync API's configuration state and route-file narration outlived the code — a `config.x` knob with zero readers, and a `namespace :v1` block whose present-tense comments describe routes that no longer exist

> **COORDINATOR VERDICT — ACCEPT.** Verified against the tree; no narrowing applied.

- **Category:** ownership  
- **Lane confidence:** high

**Evidence**

- config/initializers/finalize_verification.rb:22 — `Rails.application.config.x.verify_finalize = ENV.fetch("SYNC_VERIFY_FINALIZE", "1") == "1"`. `rg -n "verify_finalize|SYNC_VERIFY_FINALIZE" .` finds NO reader in app/, lib/, config/ or test/ — only this assignment and four docs hits (docs/sync-protocol.md:466, docs/AUDIT-2026-08-19.md:249, and two cross-repo CI spec/plan files). The audit hit names the two vanished readers by path: `app/controllers/v1/commits_controller.rb:30` and `app/controllers/files_controller.rb:498` hard-coding `verify: true`; neither exists in this tree. The file's own first line describes "v1 `POST /v1/commit/:id/finalize`", an endpoint CLAUDE.md §6 says is explicitly not routed here.
- config/routes.rb:277-281 asserts as present-tense fact: "the sync routes below now dispatch to Sync::V1::* -- the engine's controllers, in the tinkerex-sync gem's app/controllers/sync/v1/ -- but every URL, route name and HTTP verb here is BYTE-IDENTICAL to before this task... real desktop clients are deployed against these URLs." config/routes.rb:283 continues "EVERY SYNC `to:`/`controller:` BELOW NOW CARRIES A LEADING `/`, AND THE SLASH IS NOT DECORATION". There are zero such routes below. The `namespace :v1 do` at config/routes.rb:295 contains only `devices/login`, `resources :devices` and the `namespace :maker` block.
- config/routes.rb:313-320 is the retraction of the block immediately above it — "THE SYNC ENGINE'S v1 ROUTES ARE GONE... `Sync.draw_v1_routes(self)` used to add /v1/changes, /v1/tree, /v1/commit..." — so the file states a claim and its own contradiction 20 lines apart, and a reader hits the false one first.
- config/routes.rb:360, 362-364 and 366-369 are three orphaned section headers with no routes under them, sitting between the end of `namespace :maker` (:358) and the closing `end` of `namespace :v1` (:370): a bare `# hydration`; a share-links paragraph describing mint/revoke/redeem endpoints; and a paragraph describing "The `local` (filesystem) chunk backend's storage tier — presigned, HMAC-authorized blob PUT/GET... Only active under STORAGE_BACKEND=local". CLAUDE.md §7 states that since Arc D Part 2 "no code in this repo reads `STORAGE_BACKEND` or any `CHUNK_*` storage knob at all", which I confirmed for `verify_finalize`'s sibling knob by the same grep.
- For contrast, the same file shows what a live, well-argued config comment looks like and that it is NOT what these are: config/routes.rb:11-41's Active Storage direct-uploads shadow carries its argument AND its route (:39-41), and is pinned by a real driven-request guard (test/integration/web/direct_uploads_gate_test.rb:18 derives PATH from `ActiveStorage.routes_prefix` rather than hard-coding it). No equivalent guard exists for the sync surface: `rg -n "v1/changes|v1/commit|v1/tree|v1/conflicts|v1/locks" test/` finds only ChunkRemote client-side fakes, never an assertion that these paths 404 here.

**Current complexity / invalid states**

Two artifacts of the engine removal survive as live config rather than as history. First, `config.x.verify_finalize` is real application state, set on every boot from an env var, that nothing consults — an operator who sets `SYNC_VERIFY_FINALIZE=0` on this app (as docs/superpowers/plans/2026-08-25-cross-repo-ci.md:143 still instructs for a CI job) changes nothing, silently, which is precisely the class of failure §14g and §14e keep warning about. Second, routes.rb's v1 section opens with 20 lines of present-tense description of a routed sync API, retracts itself 20 lines later, and closes with three section headers for routes that were deleted — so the one place a reader goes to answer "what does this app actually serve under /v1?" (a security-relevant question, since §6 and §8 turn on a device token being the only credential the whole v1 API accepts) answers it wrongly on first read.

**Proposed representation**

Delete config/initializers/finalize_verification.rb outright — the knob belongs to `chaim354/tinkerex-sync`, which is where `POST /v1/commit/:id/finalize` is served, and where CLAUDE.md §14j says engine-side rules live. In config/routes.rb, replace lines 275-294 with the durable statement that already exists in the retraction at :313-320: this app serves the CLIENT half only (§6), the sync engine's v1 routes are not drawn here, and a device syncs against the standalone sync server. Delete the three orphaned headers at :360-369. Keep the `namespace :v1` block itself and its two device routes exactly as they are. Optionally cite the sync repo once, rather than restating what it serves.

**Why simpler**

It makes the route file's contents and its documentation agree, and removes a boot-time config assignment that reads as a live tuning knob and is not one. This is not comment tidying for line count: the removed text makes two false claims a reader would act on (that sync routes are drawn here, and that a `SYNC_VERIFY_FINALIZE` set on this app has an effect), and CLAUDE.md's own standard for this file — "THE FORGEJO RECORD (§11) is where an arc gets narrated... What belongs HERE is an invariant" — applies to a route file's comments for the same reason it applies to CLAUDE.md itself.

**Smallest credible implementation scope**

One file deleted (config/initializers/finalize_verification.rb, 22 lines) and roughly 30 comment lines in config/routes.rb replaced by about 6. No route, controller or behavior changes. Worth pairing with the cross-subsystem gap below: a small request test asserting that `/v1/commit`, `/v1/changes`, `/v1/tree` and `/v1/nodes` 404 here would turn §6's "serves none of it" from prose into a guard, and would make this deletion self-protecting.

**Affected files**

- `config/initializers/finalize_verification.rb`
- `config/routes.rb`

**Regression risks and migration concerns**

Low, and the risk is asymmetric in the safe direction — deleting a config assignment nothing reads cannot change behavior, and the grep that proves it is mechanical. The one thing to check before deleting: that no Kamal destination or accessory env sets `SYNC_VERIFY_FINALIZE` expecting this app to honor it (config/deploy*.yml is S31; I did not find it in the repo-wide grep, which returned only docs). The cross-repo docs that reference the flag (docs/sync-protocol.md:466, the two cross-repo CI plan files) describe the SYNC SERVER's behavior and are correct about it — they should not be edited as part of this, only the copy of the knob that lives in the wrong repo. On the routes side, deleting comments cannot break routing, but resist the temptation to also delete `namespace :v1`'s device routes: §14j is explicit that `Device` is host-owned and its token is the only credential the whole API accepts.

**Validation required**

`rg -n "verify_finalize|SYNC_VERIFY_FINALIZE" app/ lib/ config/ test/` must return nothing after the change. `bin/rails routes | grep '^\s*v1'` before and after must produce an identical list — that is the mutation check that the comment edit touched no route. Then run bare `bin/ci` (all three backend legs, identical run counts per §15). If the suggested 404 guard is added, mutation-check it by temporarily drawing a `post "commit"` inside `namespace :v1` and confirming it goes red.

### Cross-subsystem concerns raised by this lane

_Named, not solved — the lane was told to stay inside its boundary._

- CLAUDE.md §6 states this app "implements the CLIENT half and serves none of" the sync wire — /v1/changes, /v1/tree, /v1/commit, /v1/chunks/*, /v1/conflicts, /v1/locks, /v1/trash, /v1/nodes, /v1/share_links are "not routed here". Nothing asserts it. `rg -n "v1/changes|v1/commit|v1/tree|v1/conflicts|v1/locks" test/` returns only ChunkRemote client-side transport fakes (test/services/file_layer/chunk_remote/*, test/jobs/file_layer/remote_changelog_pull_job_test.rb). Compare the direct-uploads shadow, which IS pinned by a driven request (test/integration/web/direct_uploads_gate_test.rb). A four-line request test asserting 404 on those paths would make the invariant self-defending; it belongs to whichever subsystem owns test/integration/web/, not to config/.
- test/architecture_invariants_test.rb:930-937 justifies the `nodes => index_nodes_on_user_id` prefix-index exemption primarily by citing `Sync::Tree.call (app/services/sync/tree.rb:12)` — a file that no longer exists in this tree (the engine left in Arc D Part 2). The exemption is still correct, but on its SECOND stated reason only: `Maker::Previews::MissingBackfill`'s `find_each` paging by id (missing_backfill.rb:74). This is the exact shape §14e warns about ("a guard whose subject is a path can be silently retired by a move") — the measured 183x claim now rests on a caller nobody in this repo can re-measure. The comment wants re-grounding on the backfill caller. Owner: whoever owns test/architecture_invariants_test.rb, not S36.
- docs/sync-protocol.md:466 documents `Rails.configuration.x.verify_finalize` / `SYNC_VERIFY_FINALIZE` as part of the normative wire spec, and docs/superpowers/plans/2026-08-25-cross-repo-ci.md:143 instructs setting `SYNC_VERIFY_FINALIZE: "0"` in a CI job. Both are correct about the SYNC SERVER, where finalize is actually served. Only the copy of the knob living in this repo's config/initializers/ (my finding 2) is misplaced; the docs should be left pointing at chaim354/tinkerex-sync rather than edited alongside it.

---

## S37 — Production container image

**Lane verdict:** `skip`

**This subsystem was reviewed and deliberately returned no findings.** The lane's argument:

> Read at HEAD in full: Dockerfile (181 lines), .dockerignore (85 lines — the brief said 75; it is 85), bin/docker-entrypoint (8 lines), bin/thrust (5 lines). Also opened the three sibling definitions of the renderer-binary contract to judge the row's stated premise: app/services/maker/previews/{image_thumb,pdf,stl,svg_rasterizer,mesh}.rb, app/services/maker/pdf_text.rb, app/services/maker/previews/registry.rb, test/services/maker/previews/renderer_contract_test.rb, ci/ensure-resvg.sh, test/deploy_hygiene_test.rb, docs/adding-a-preview-format.md.
>
> VERIFIED FACTS (each opened, not inferred):
> - Dockerfile instruction skeleton: base (12), build (31), stl-thumbnailer (75), resvg (85), pdfium (93), f3d (110), final (123). `COPY . .` is at Dockerfile:57. USER switches at :147; the four renderer COPYs land at :155/:159/:163/:173; `ENV F3D_BIN="/opt/f3d/bin/f3d"` at :174.
> - The six ENV.fetch sites: image_thumb.rb:25 (VIPSTHUMBNAIL_BIN/"vipsthumbnail"), pdf.rb:22 and pdf_text.rb:11 (PDFIUM_BIN/"pdfium"), stl.rb:21 (STL_THUMBNAILER_BIN/"stl-thumbnailer"), svg_rasterizer.rb:20 (RESVG_BIN/"resvg", memoized rather than a frozen const, with reset_bin! at :22), mesh.rb:26 (F3D_BIN/"f3d").
> - The image satisfies those defaults by THREE different mechanisms: apt onto PATH (vipsthumbnail, via `libvips-tools` at Dockerfile:19), COPY onto /usr/local/bin (stl-thumbnailer, resvg, pdfium), and an ENV override (F3D alone).
>
> CANDIDATES CONSIDERED AND REJECTED, with why:
>
> 1. "Collapse the renderer→binary contract into one table (module → env var → default name) that both the renderers and a Dockerfile-provisioning guard read." REJECTED. Each of the six sites uses its default exactly once, at its own renderer, so no branching is removed — this is the "move existing code behind a new type" the brief forbids. Worse, the per-renderer `available?` bodies are NOT interchangeable and each difference is argued in a comment: mesh.rb:29-38 must run `--version` and match the banner case-insensitively (a literal `include?("f3d")` reported a good binary as unavailable and silently sent every .obj/.step/.iges to `unsupported`); pdf.rb:24-29 and image_thumb.rb:27-32 use tool-specific version flags; stl.rb:43-50 runs the bare binary because it has no version flag. A shared reducer would have to discard that. And the Dockerfile half cannot participate in a Ruby structure at all — a guard would be string-matching `COPY … /usr/local/bin/resvg`, which is brittle and proves nothing about the binary running.
>
> 2. "Make F3D consistent with the other three (symlink onto PATH so the ENV default resolves)." REJECTED — the Dockerfile already beats this at :168-172, on two independent grounds I confirmed against the file: the final stage is at USER 1000:1000 by :147, so `RUN ln -s` would need root restored; and F3D resolves its bundled VTK/OCCT libraries and plugins relative to its own bin/../lib, so it must not be lifted out of /opt/f3d the way the three static binaries are. The row framed this asymmetry as the point, but it is documented, argued, and correct. Recommending it would be stylistic consistency only.
>
> 3. "Replace `.dockerignore`'s denylist with an allowlist of COPY sources, so §9 (no copyleft in the permissive image) holds structurally rather than resting on .dockerignore:76 (`/sidecar/`) plus one string-equality assertion at test/deploy_hygiene_test.rb:12." REJECTED as a *simplification*. It is safer but strictly larger: ~16 explicit COPY sources replacing one line, each a layer, with a real risk of breaking assets:precompile, and .dockerignore is still needed anyway for build-context size (the `/client/` line at :64 is what cuts the context from ~8 GB). This is a security-posture proposal, not a data-structure one, so it does not belong in this row's output.
>
> SUB-THRESHOLD OBSERVATIONS (reported for the record; I would not fund either as a standalone task):
> - The stale anchor the row flagged is confirmed: test/deploy_hygiene_test.rb:9 says "Dockerfile:47 is `COPY . .`" while `COPY . .` is at Dockerfile:57. The assertion itself (:11-13) reads .dockerignore and is unaffected — only the comment is wrong. A one-word comment fix.
> - Dockerfile:39 is `COPY Gemfile Gemfile.lock vendor ./`. Docker copies a directory's CONTENTS, not the directory, so this drops vendor/'s 3.8 MB of JS (3MFLoader.js, codemirror.js, …) flat into /rails/ rather than /rails/vendor/. `COPY . .` at :57 then adds the correct /rails/vendor/javascript without removing the strays, and :151 carries both into the final image. Nothing depends on it: `vendor/` holds only `.keep` and `javascript/` (no vendored gems), and the Gemfile has no `path:`/vendor reference, so `bundle install` at :51 does not need it. Scaffold-inherited since ff07b26. Effect is a few MB and a confusing /rails/*.js — cosmetic, and a one-line deletion, which is the minor-line-count change the brief excludes.
> - The comment at Dockerfile:125-127 states its own rule as "these are the only packages in this image that exist for ONE renderer; every other one is a static binary". That is not quite true: `libvips libvips-tools` at :19 sit in `base` and exist solely for ImageThumb (config/application.rb:35-41 records why it must be the CLI and never the ruby-vips FFI binding, per CLAUDE.md §14e). The rule and the file disagree, but the placement is harmless and correcting the prose is not a subsystem change.
>
> CONFIDENCE IN THE SKIP: high. Every structural oddity in these four files is either documented with the bug it prevents (F3D's ENV wiring, the pdfium WASM choice at :89-92, xz-utils at :106-108, the derived Mesa list at :129-138, /client/ and /sidecar/ in .dockerignore) or is scaffold boilerplate that is already clear (bin/thrust, bin/docker-entrypoint's last-two-argv match against the CMD at :181). There is no scattered-boolean, no invalid-state combination, and no repeated lookup here that a better collection would materially simplify.

---

## S38 — Node ancestry traversal (cross-cutting seam)

**Lane verdict:** `recommend`

### S38-1 — Three byte-identical whole-dir plucks build three different in-memory ancestry indexes with three different answers on a cycle; Maker::LibraryTree already owns that definition

> **COORDINATOR VERDICT — ACCEPT.** Verified against the tree; no narrowing applied.

- **Category:** data-structure  
- **Lane confidence:** high

**Evidence**

- app/services/maker/library_tree.rb:14-17 — `rows = user.nodes.present.where(kind: "dir").pluck(:node_id, :parent_node_id, :name)`, stored as `@dirs` keyed by node_id holding a `Data.define(:node_id, :parent_node_id, :name)` Entry. This is the declared owner: the class comment at lines 2-9 says it exists so callers stop "Walking parent_node_id per file".
- app/controllers/files_controller.rb:1122-1123 — `dirs = current_user.nodes.present.where(kind: "dir").pluck(:node_id, :parent_node_id, :name)` then `by_id = dirs.to_h { |id, parent, name| [ id, [ parent, name ] ] }`. Byte-identical query, second index shape (bare 2-element array instead of the Entry), second path builder.
- app/controllers/tools/library_folders.rb:46-47 — `rows = current_user.nodes.present.where(kind: "dir").pluck(:node_id, :parent_node_id, :name)` then `by_id = rows.index_by(&:first)`. Same query a third time, third index shape (3-element row keyed by first element), third path builder.
- app/services/maker/library_tree.rb:57-70 (`#each_ancestor`) — `seen = Set.new` … `return yield(:broken) if seen.include?(current)` … `return yield(:broken) unless entry`. Cycle AND missing ancestor both collapse to one sentinel; `path_for`/`ancestors_of` (lines 23-46) turn it into nil, documented at lines 20-22 as "NIL IS AN ANSWER, NOT AN ERROR".
- app/controllers/files_controller.rb:1129-1131 — `cache[id] = "…" # cycle marker` written BEFORE recursing, so a cycle yields a path string containing a literal `…` segment; and line 1126 `return "" if id.nil? || !by_id.key?(id)` makes a node under a tombstoned/missing parent render as if it sat at the library root. Two answers that differ from LibraryTree's nil.
- app/controllers/tools/library_folders.rb:49-55 — the `label` lambda memoizes AFTER the recursive call (`prefix = parent && by_id[parent] ? label.call(parent) : ""` on line 53, `labels[nid] = ...` only on line 54), so there is NO cycle guard at all: a `parent_node_id` loop recurses until SystemStackError. Line 53 also silently relabels a dir whose parent row is absent as a root-level folder.
- app/controllers/tools/library_folders.rb:21 — thirty lines above, `folder_path_label` DOES guard: `seen = Set.new # a parent cycle is not reachable through the app's own doors; do not hang if one is`. One file, two methods, opposite answers to the same question.
- app/services/library/repo_metadata_purge.rb:67-80 and app/services/maker/attach_to_project.rb:216-219 — both state the repo's settled position: "`parent_node_id` is a plain string column with no foreign key, so a cycle is representable, and an uncapped walk is an infinite loop", `MAX_ANCESTOR_WALK = 64`. `folder_options` is the one in-memory copy out of step with that decision.
- app/controllers/tools/addons_controller.rb:200-201 — `@folders = folder_options` immediately followed by `@default_folder_label = folder_path_label(@default_parent_node_id)`, and grep shows those are the ONLY callers of either method. So on the single request where both run, the whole-dir pluck `folder_path_label`'s comment (library_folders.rb:12-16) says it is avoiding has already happened one line earlier.

**Current complexity / invalid states**

One question — "what is the path of this dir node, given the user's live dir rows" — is answered by three separately written in-memory indexes over the same `pluck(:node_id, :parent_node_id, :name)`. They disagree on both degenerate inputs. On a parent cycle: `Maker::LibraryTree` returns nil (library_tree.rb:26-33), `FilesController#folder_paths_for` returns a path with a literal `…` segment spliced in (files_controller.rb:1129), `Tools::LibraryFolders#folder_options` overflows the stack (library_folders.rb:49-55). On a broken chain (a live dir whose parent row is tombstoned or absent): LibraryTree returns nil, the other two silently render the node as if it were at the library root. None of that divergence is argued anywhere; each copy was written inside a different feature and no lane owned the seam. `folder_options` additionally contradicts a guard sitting thirty lines above it in its own file, and contradicts the explicit "a cycle is representable, do not run uncapped" position stated verbatim in two other services.

**Proposed representation**

Make `Maker::LibraryTree` the one dir-ancestry index and delete the two ad-hoc ones. It needs two small additions to cover both call sites, both of which also help its existing callers: (1) memoize `path_for` in a `@paths` hash — `FilesController#folder_paths_for` caches per id today and `ShelvesController#index` (shelves_controller.rb:7, 51) and `Maker::ModelIntake.classify` (model_intake.rb:126) both call `path_for` in a loop with no cache, so the memo is a net win rather than a concession; (2) expose the dir ids (an `each_dir`/`dir_ids` reader over `@dirs`) so `folder_options` can build `[label, node_id]` pairs from it. Then `folder_paths_for(nodes)` becomes `tree = Maker::LibraryTree.new(current_user); nodes.to_h { |n| [n.node_id, tree.path_for(n.parent_node_id)] }`, and `folder_options` becomes a map over `tree.dir_ids` calling `path_for`. Both callers must decide once, explicitly, what a nil (broken/cyclic) path renders as — the current implicit answers are "root-level" and "…", neither chosen deliberately.

**Why simpler**

It removes two of the three representations of one index and, with them, the two undocumented degenerate-case behaviours. The remaining type already states its contract in prose and is pinned by tests, including a query-count test (test/services/maker/library_tree_test.rb:62-67, "the index costs one query regardless of how many dirs there are") and a broken-chain test (lines 55-60, "ancestors of an unresolvable chain are nil, not a raise") — coverage neither controller copy has. It also fixes a real defect as a side effect rather than as a separate patch: `folder_options` is the only ancestry walk in the app with no bound of any kind, on a page (`/tools/:addon`) that renders it on every load. And it makes the *remaining* per-hop walks legible as a deliberate second strategy rather than as more of the same accident.

**Smallest credible implementation scope**

Small. Add a `@paths` memo inside `Maker::LibraryTree#path_for` and a `dir_ids` (or `each_dir`) reader over `@dirs`; rewrite `FilesController#folder_paths_for` (files_controller.rb:1121-1134, ~13 lines) and `Tools::LibraryFolders#folder_options` (library_folders.rb:45-58, ~13 lines) as thin callers; pick and state the nil-path rendering at each. Roughly one file added to, two methods replaced. Existing tests: test/services/maker/library_tree_test.rb, test/controllers/tools/library_folders_test.rb, test/integration/web/files_type_filter_test.rb (which references the cycle guard at line 261) and test/integration/web/page_query_budget_test.rb all bear on it.

**Affected files**

- `app/services/maker/library_tree.rb`
- `app/controllers/files_controller.rb`
- `app/controllers/tools/library_folders.rb`
- `app/controllers/shelves_controller.rb`

**Regression risks and migration concerns**

Three, and the first is the one that must be handled rather than discovered. (1) Behaviour change on a broken chain: today a dir whose parent row is missing shows as root-level in both the Files Folder column and the addon picker; `path_for` answers nil there. That is arguably the more honest answer but it IS a change, and CLAUDE.md §14b's tombstone rules mean tombstoned ancestors are a real, reachable population, not a hypothetical — decide the rendering explicitly and pin it. (2) `Tools::LibraryFolders` is a controller concern with no `Maker::` dependency today; taking one couples the addon controllers to a maker service. That is consistent with §14d ("a verb more than one controller performs gets a named service") but is a new edge. (3) `library_folders.rb:12-16` argues `folder_path_label` must NOT pay for the whole tree because the chooser fetches a level at a time. That argument is untouched by this finding and I am deliberately not folding `folder_path_label` in: it is O(depth) find_by hops on purpose, and addons_controller.rb:195-199 says the flat `folder_options` list exists only "until the addons repo says otherwise" — so `folder_path_label` must survive `folder_options`' eventual removal without inheriting a whole-tree pluck. (Worth knowing while the two coexist: on the only request that runs either, addons_controller.rb:200-201, the pluck happens anyway, so the O(depth) walk is currently buying nothing.)

**Validation required**

Unit: extend test/services/maker/library_tree_test.rb with a two-node cycle and assert the memo does not change any answer (mutation-check by removing the `seen` Set and confirming the cycle test hangs/reds — the file already mutation-checks the `:broken` sentinel, see its comment at library_tree.rb:25-29). Behavioural: drive `GET /files` with a dir whose parent is tombstoned and assert the rendered Folder column, and drive `GET /tools/:addon` with the same fixture and assert the rendered `<select>` labels — both currently pass only by accident. Regression on the defect being closed: build a two-node `parent_node_id` cycle and assert `/tools/:addon` renders instead of 500-ing; that test must be red at HEAD. Query budget: test/integration/web/page_query_budget_test.rb should still show files#index constant in N (it goes from two whole-dir plucks per request to one, so the count drops rather than grows — assert constancy, never a literal, per §14e).

### Cross-subsystem concerns raised by this lane

_Named, not solved — the lane was told to stay inside its boundary._

- Tools::LibraryFolders#folder_options (app/controllers/tools/library_folders.rb:49-55) is the only parent_node_id walk in the app with no cycle guard and no numeric cap, while three other services state in comments that a cycle IS representable because parent_node_id is an unconstrained string column. Its only caller is Tools::AddonsController#show (addons_controller.rb:200), so a corrupt mirror row would 500 the whole /tools/:addon page via SystemStackError. This is a defect independent of whether the simplification above is funded, and is worth a note against §14c's addon-surface rules.
- The brief's list of seven copies is incomplete: FilesController#folder_paths_for (files_controller.rb:1121-1134) is an eighth, and is one of the three that duplicate Maker::LibraryTree's index rather than doing a per-hop walk. Whatever lane owns files_controller.rb should know it holds an ancestry index, not just a crumb walk.
- Three separate copies decide independently what a live dir under a tombstoned parent should look like (nil / root-level / root-level). Given §14b's two-tombstone-kinds rule, that population is reachable in normal operation on share and s3, so the answer deserves to be stated once rather than defaulted three times.

---

## S39 — Test suite bodies

**Lane verdict:** `recommend`

### S39-1 — Web sign-in is an unowned, 60-file idiom: 15 byte-identical copies that assert nothing, while the two copies that DO assert carry the written-down reason why they must

> **COORDINATOR VERDICT — ACCEPT.** Verified against the tree; no narrowing applied.

- **Category:** ownership  
- **Lane confidence:** high

**Evidence**

- test/support/chunk_remote_journey.rb:51-61 — the one `sign_in` in the repo that states the hazard and closes it: after `post user_session_path` it does `assert_redirected_to files_path`, with the comment "a FAILED sign-in redirects too (Devise's own FailureApp#redirect, and this app's per-IP rate-limit hook in Users::SessionsController, both `redirect_to`), so a bare 3xx cannot tell success from failure and every request this helper's caller makes afterward would silently run unauthenticated while this reported fine."
- test/integration/v1/capability_gating_test.rb:43-46 — `sign_in_web(user)` independently reached the same conclusion: `post user_session_path, …` followed by `assert_redirected_to files_path`. Two places in the repo know; the boundary's copies do not.
- test/integration/web/attach_from_files_test.rb:10-15 — the un-asserting copy, verbatim: `def sign_in(email = "maker@example.com"); user = User.find_by(email:) || User.create!(email:, password: PASSWORD, confirmed_at: Time.current); post user_session_path, params: { user: { email:, password: PASSWORD } }; user; end`. No assertion of any kind on the response.
- test/integration/web/attach_from_files_test.rb:88-97 — a test that goes VACUOUSLY GREEN under that failure mode. `user = sign_in`, then `post attachments_path …`, then `assert_difference "project.file_attachments.count", 0 do post attachments_path … end`. If the sign-in silently failed, both POSTs redirect to /users/sign_in, zero rows are created either time, the difference is 0, and the test passes while asserting nothing about the find-or-create it exists to pin. This is CLAUDE.md §15's "a green suite over something that never worked" shape.
- `grep -rn -A4 'def sign_in(email' test/ | grep -c 'post user_session_path'` → 15 byte-identical bodies, at test/integration/web/notes_test.rb:20-25, projects_flow_test.rb:23-28, models_flow_test.rb:22-27, files_flow_test.rb:39-44, trash_flow_test.rb:29-34, lbrn_geometry_test.rb:26-31, settings_panel_test.rb:24-29, project_attachments_test.rb:20-25, project_tasks_test.rb:12-17, project_build_log_test.rb:12-17, project_sheets_test.rb:12-17, attach_from_files_test.rb:10-15, print_runs_test.rb:10-14, models_import_test.rb:25-29, and test/support/chunk_remote_journey.rb:51-61 (the only one with the assertion).
- `grep -rn 'post user_session_path' test/ | wc -l` → 75 sites across 60 files (the other ~45 are inline in `setup`, e.g. test/integration/web/folder_nav_test.rb:20, files_type_filter_test.rb:12, page_query_budget_test.rb:32, test/controllers/tools/addons_controller_test.rb:60). Of all 75, exactly 3 assert the sign-in succeeded.
- `grep -rn 'PASSWORD = ' test/ | sed 's/.*PASSWORD = //' | sort | uniq -c` → 63 files declare `PASSWORD = "correct horse battery staple".freeze` plus one unfrozen copy of the same literal; 65 in-boundary files each hold their own definition of the one credential the whole web suite authenticates with.
- CLAUDE.md §14e records that this failure mode is not hypothetical in this repo: the auth throttles are LIVE in the test env, and "the test simply is not signed in, so it fails as `302 redirect to /users/sign_in`, or as a missing `<h1>`, in a test that has nothing to do with auth. Measured, adding the throttles without this: 306 failures / 20 errors". test_helper.rb:57 clears the counter per test to mitigate one cause; nothing mitigates the others.

**Current complexity / invalid states**

"Sign a web user in" has no owner. It is respelled 75 times across 60 test files — 15 as a byte-identical private `sign_in`, ~45 inline in `setup` — and the credential it uses is redeclared as a per-file `PASSWORD` constant in 65 files. The success check that makes the idiom safe exists in exactly 2 of the 75 sites, and both of those sites carry a comment explaining that without it a failed sign-in is indistinguishable from a successful one and every later request in the test runs anonymously. The copies inside this subsystem never got that lesson, and at least one of them (attach_from_files_test.rb:88-97) is a guard that passes vacuously if it ever bites.

**Proposed representation**

One owner for the web session, beside the two integration helpers test_helper.rb already owns for exactly this reason (`bootstrap_account` at :212 for device auth, `port_upload` at :100 for library writes — whose own comment says "ONE DEFINITION, deliberately", recording that it was previously a helper copied between two suites). Add to the same `ActionDispatch::IntegrationTest` module:

  WEB_PASSWORD = "correct horse battery staple"

  def sign_in_web(email = "maker@example.com")
    user = User.find_by(email:) || User.create!(email:, password: WEB_PASSWORD, confirmed_at: Time.current)
    post user_session_path, params: { user: { email:, password: WEB_PASSWORD } }
    assert_redirected_to files_path,
      "sign-in as #{email} did not succeed — every later request in this test would run anonymously"
    user
  end

Delete the 15 private copies and the 65 per-file `PASSWORD` constants in the same change, and rewrite the ~45 inline `post user_session_path` setups as calls to it. The credential and the success check then have one definition each.

**Why simpler**

It removes a real hazard, not just duplication: today a sign-in that stops working is observable only as a downstream assertion failure in an unrelated test, and in the assert_no_difference / assert_not_exists shape it is not observable at all. Making the helper assert converts a silent, misattributed failure into an immediate, correctly-named one at the frame that caused it — which is the argument two other files in this repo already wrote out in full. It also collapses a genuine maintenance coupling: any change to the web auth flow (a Devise module, the session param shape, a password policy, an added confirmation step) currently has 75 edit sites in this subsystem, and the copies that are missed fail in the misattributed way rather than the loud way.

**Smallest credible implementation scope**

~60 files touched but each edit is mechanical: delete a 5-line method or rewrite a 1-line inline POST, delete a constant. One new ~8-line helper in test_helper.rb (outside this row's boundary — the enabling change is one method there; all 60 deletions are inside it). No app/ code changes. Roughly a day including the mutation check.

**Affected files**

- `test/test_helper.rb`
- `test/integration/web/attach_from_files_test.rb`
- `test/integration/web/notes_test.rb`
- `test/integration/web/projects_flow_test.rb`
- `test/integration/web/models_flow_test.rb`
- `test/integration/web/files_flow_test.rb`
- `test/integration/web/trash_flow_test.rb`
- `test/integration/web/lbrn_geometry_test.rb`
- `test/integration/web/settings_panel_test.rb`
- `test/integration/web/project_attachments_test.rb`
- `test/integration/web/project_tasks_test.rb`
- `test/integration/web/project_build_log_test.rb`
- `test/integration/web/project_sheets_test.rb`
- `test/integration/web/print_runs_test.rb`
- `test/integration/web/models_import_test.rb`
- `test/integration/web/folder_nav_test.rb`
- `test/integration/web/files_type_filter_test.rb`
- `test/integration/web/page_query_budget_test.rb`
- `test/controllers/tools/addons_controller_test.rb`
- `test/integration/v1/capability_gating_test.rb`

**Regression risks and migration concerns**

1. NAME COLLISION MUST BE RESOLVED IN THE SAME COMMIT. A method named `sign_in` defined in a test class overrides one defined in `ActionDispatch::IntegrationTest`, so adding the helper without deleting the 15 copies leaves those suites on the old, un-asserting behaviour while everything looks converted. Use a distinct name (`sign_in_web`) or delete the copies atomically. 2. Some callers legitimately expect a sign-in NOT to succeed — test/integration/web/auth_throttle_test.rb and auth_pages_test.rb drive failed logins on purpose and must keep raw `post user_session_path`, not the asserting helper. 3. test/system/support/web_helpers.rb:21 `sign_in_as` is the Capybara browser-driven sign-in (fill_in / click_on) and already asserts `assert_current_path "/files"`; it is a different mechanism and must stay separate. 4. Two files use a deliberately different password (`"password123"`, `"a different correct horse"`) — those are testing password handling itself and keep their own literal.

**Validation required**

Mutation-check the new assertion per CLAUDE.md §15: temporarily make the helper post a wrong password and confirm the affected suites go RED **at the helper's own assertion line**, naming the email, rather than deep in an unrelated `assert_response :success`. Specifically confirm attach_from_files_test.rb's "attaching the same file to the same project twice creates ONE row" goes RED under that mutation — today it goes green, which is the whole finding. Then restore, and run all three backend legs (`bin/ci test`, `test-s3`, `test-chunk-remote`) confirming identical run counts within the known ±2 flap (tinkerex#131).

### S39-2 — `use_fresh_share_library!` mints a process-global and a tmpdir but delegates cleanup to 47 caller files, while its sibling helper one method below it already demonstrates the owning shape

> **COORDINATOR VERDICT — SUPERSEDES S32-1.** Same subject, better count: 47 caller files, not 35.

- **Category:** ownership  
- **Lane confidence:** medium

**Evidence**

- test/test_helper.rb:163-175 — `use_fresh_share_library!` does `root = Pathname.new(Dir.mktmpdir("test-library")); FileLayer.current = FileLayer::Share.new(root: root.to_s); root`, and its own comment states the obligation it declines to meet: "A direct assignment sets no @file_layer_backend_pinned either, so the caller MUST pair this with `FileLayer.reset!` in teardown or the adapter leaks into the next test in this forked worker."
- test/test_helper.rb:177-192 — the sibling helper `pin_file_layer_backend(name)` in the very same file DOES own its lifecycle: it records `@file_layer_backend_pinned` / `@file_layer_backend_prior`, and the shared `teardown do … end` at :187-192 restores ENV and calls `FileLayer.reset!` for every caller. The correct shape is already written, twelve lines below the helper that lacks it.
- `grep -rl "FileUtils.remove_entry(@root) if @root&.exist?" test/ | wc -l` → 47 files, 49 occurrences, each hand-rolling the identical two-line teardown, e.g. test/integration/web/notes_test.rb:15-18, back_link_test.rb:27-30, files_flow_test.rb:30-33, page_nodes_test.rb:40-43, library_browse_test.rb:29-32, test/system/box_revisions_test.rb:42-45, test/jobs/maker/generate_preview_job_test.rb, test/services/maker/attach_to_project_test.rb.
- test/jobs/maker/model_intake_job_test.rb:14 and :43 — `FileLayer.current = FileLayer::Share.new(root: Dir.mktmpdir("mij"))` with `teardown { FileLayer.reset! }` at :58 and NO `remove_entry` anywhere in the file: two tmpdirs leaked per run. Same at test/jobs/maker/project_discovery_job_test.rb:18, :38, :77 with `teardown { FileLayer.reset! }` at :93 — three more. Verified by `for f in $(grep -rl mktmpdir test/); do grep -q 'remove_entry\|rm_rf' $f || echo $f; done`, which names exactly these two test files.
- CLAUDE.md §15 ("CI") records the cost of exactly this: "config/ci.rb's own review found 334 accumulated `tmp.*` directories on the mac runner — a gate that makes a tmpdir must clean it up." The runner is persistent and self-hosted, so these accumulate run over run.
- test/integration/v1/maker/previews_test.rb:6-14 — the comment on one caller's hand-rolled teardown states what a forgotten line costs: "this teardown is what stops the adapter leaking into the next test in this forked worker. It matters more than it used to: FileLayer.build's default arm is `share` since Arc D Part 2, and share raises KeyError on a missing LIBRARY_PATH … so a leaked reset surfaces as a KeyError in an unrelated test."
- The idiom has fragmented into four spellings of "point FileLayer at a library for the duration of this test": `use_fresh_share_library!` (36 files), a direct `FileLayer.current = FileLayer::Share.new(root: …)` (30 sites across ~24 files, e.g. test/jobs/library/scan_job_test.rb:286/486/565, test/system/measure_print_test.rb:57), `pin_file_layer_backend` (16 sites), and a per-file save/restore of the ivar (test/services/library_broadcast_test.rb:34-44 `with_file_layer_env`, which reaches into `FileLayer.instance_variable_get(:@current)` directly).

**Current complexity / invalid states**

`FileLayer.@current` is a process-global that survives the per-test database rollback, and its lifetime is currently owned by 47 separate test files rather than by the helper that sets it. `use_fresh_share_library!` returns a tmpdir and leaves both cleanups — reset the global, remove the directory — to a two-line `teardown` block the caller must remember to write. All 36 current callers do; two other files that build the same state a different way (model_intake_job_test.rb, project_discovery_job_test.rb) already leak five tmpdirs per run onto a persistent self-hosted runner. The failure mode for the other half of the pair is worse than a leaked directory: a missed `FileLayer.reset!` surfaces as a KeyError in a later, unrelated test in the same forked worker.

**Proposed representation**

Give the helper the same ownership `pin_file_layer_backend` already has, using the existing shared teardown:

  def use_fresh_share_library!
    @fresh_share_library_root = Pathname.new(Dir.mktmpdir("test-library"))
    FileLayer.current = FileLayer::Share.new(root: @fresh_share_library_root.to_s)
    @fresh_share_library_root
  end

and extend the existing `teardown do … end` at test_helper.rb:187 with:

    if @fresh_share_library_root
      FileLayer.reset!
      FileUtils.remove_entry(@fresh_share_library_root) if @fresh_share_library_root.exist?
    end

Then delete the 47 hand-rolled teardown blocks. For the mid-test assignments that do not go through the helper, add a block form `with_file_layer(adapter) { … }` that restores the prior `@current` on any exit (the shape test/services/library_broadcast_test.rb:34-44 already hand-rolls), and route model_intake_job_test.rb:14/:43 and project_discovery_job_test.rb:18/:38/:77 through `use_fresh_share_library!` so their tmpdirs are cleaned.

**Why simpler**

The lifetime of one process-global is stated once, at the place that mints it, instead of at 47 call sites that must each remember two lines whose omission is silent and whose failure lands in a different test. It is not a style change: it fixes five live tmpdir leaks on a persistent runner that CLAUDE.md already records as having accumulated 334 stale directories, and it removes the standing hazard the helper's own comment describes rather than documenting it for the 48th caller. It also collapses the four competing spellings of the same operation into two (a fresh share library; an arbitrary adapter for a block), so a future reader has one obvious door.

**Smallest credible implementation scope**

One method plus five lines in test_helper.rb (outside this row's boundary), then 47 mechanical deletions and 5 call-site rewrites inside it. Half a day.

**Affected files**

- `test/test_helper.rb`
- `test/jobs/maker/model_intake_job_test.rb`
- `test/jobs/maker/project_discovery_job_test.rb`
- `test/integration/web/notes_test.rb`
- `test/integration/web/back_link_test.rb`
- `test/integration/web/files_flow_test.rb`
- `test/integration/web/page_nodes_test.rb`
- `test/integration/web/library_browse_test.rb`
- `test/integration/v1/maker/previews_test.rb`
- `test/system/box_revisions_test.rb`
- `test/system/addon_bundle_test.rb`
- `test/jobs/maker/generate_preview_job_test.rb`
- `test/services/maker/attach_to_project_test.rb`
- `test/services/maker/project_intake_test.rb`
- `test/services/library/repo_metadata_purge_test.rb`
- `test/services/library_broadcast_test.rb`

**Regression risks and migration concerns**

1. TEARDOWN ORDERING. ActiveSupport registers `teardown` blocks as :after callbacks, which run in reverse declaration order, so test_helper's block runs LAST — after per-file teardowns such as test/system/box_revisions_test.rb:47's `FakeBoxesSidecar.uninstall!` and addon_bundle_test.rb:47's ENV restore. Verify no per-file teardown reads `FileLayer.current` expecting it to still be the fresh adapter; grep showed none, but this must be checked before deleting the blocks, and it is the one thing that could break silently. 2. Files that build `@root` WITHOUT the helper (test/integration/web/share_delivery_test.rb, share_delete_test.rb, share_trash_test.rb, rescan_test.rb, capability_gating_test.rb) also carry the identical `remove_entry(@root)` line; those must either be converted or keep their own teardown — deleting theirs on a pattern match would leak. 3. test/services/library_broadcast_test.rb:22-33 argues explicitly why it does NOT reuse `pin_file_layer_backend` (that helper calls `FileLayer.build`, which for chunk_remote demands a real CHUNK_REMOTE_URL/TOKEN it has no use for). A block-form `with_file_layer(adapter)` does not call `build` and so does not re-open that argument, but it must not be folded into `pin_file_layer_backend`.

**Validation required**

Mutation-check the new ownership per CLAUDE.md §15: delete the `FileLayer.reset!` line from the shared teardown and confirm a suite that previously reset by hand now fails — pair a `use_fresh_share_library!` test immediately before a test that reads the ambient backend, and confirm the leaked adapter is observable. Separately assert the tmpdir claim directly: count `Dir.glob(Dir.tmpdir + '/test-library*')` and `/mij*` `/pdj*` before and after a full `bin/rails test` run, confirming zero growth after the change and non-zero growth before it. Then run all three backend legs and compare run counts within the ±2 known flap.

### Cross-subsystem concerns raised by this lane

_Named, not solved — the lane was told to stay inside its boundary._

- Both findings' enabling change lands in test/test_helper.rb, which is explicitly OUTSIDE this row's ownership boundary (as are test/support/chunk_remote_journey.rb and test/system/support/web_helpers.rb, which supply the counter-examples). The deletions are all inside the boundary; whoever owns test_helper.rb must add ~15 lines to it.
- S32 flagged that changing `use_fresh_share_library!` "touches 35 suites outside this subsystem" — finding 2 is the other half of that observation, and the two should be sequenced together rather than landed independently.
- Finding 1's helper must not be applied to test/integration/web/auth_throttle_test.rb or auth_pages_test.rb, which drive FAILED sign-ins deliberately, nor to test/system/support/web_helpers.rb's Capybara `sign_in_as` (a different mechanism that already asserts).
- Both changes alter test-only code, so all three backend legs (`bin/ci test`, `test-s3`, `test-chunk-remote`) must be re-run and their run counts compared per CLAUDE.md §15; `test-chunk-remote` needs ../tinkerex-sync checked out.

---

## S40 — Addon bundle fixtures & the out-of-repo snapshot

**Lane verdict:** `recommend`

### S40-1 — `fixture/save.js` is a second, now-diverged implementation of the 409 overwrite protocol that mirrors nothing shipped — and it owns the only assertion of the decline branch

> **COORDINATOR VERDICT — ACCEPT.** Verified against the tree; no narrowing applied.

- **Category:** ownership  
- **Lane confidence:** high

**Evidence**

- test/fixtures/addons/fixture/fixture.js:12-17 — the fixture's own justification: "IT ALSO EXERCISES save.js, which is a VERBATIM COPY of the helper all three real bundles import (chaim354/tinkerex-addons addons/<key>/save.js) … what this proves is that the helper and the host's 409 contract actually agree, in a browser, against the real endpoint."
- test/fixtures/addons/boxes/boxes.js:6 — the in-repo snapshot of one of those three real bundles contradicts that claim in the same fixtures directory: `@maker/addon-sdk` "is what absorbed this bundle's old save.js". boxes/ contains no save.js (ls of test/fixtures/addons/boxes: 18 modules, none named save.js), and boxes/editor.js:340-364 does the 409 dance through `host.files.save({ onReplace })`, not through any helper.
- app/javascript/maker/addon_sdk.js:409-412 — the host-shipped SDK (pinned as `@maker/addon-sdk` in config/importmap.rb:61) states it "Absorbs what every bundle copies today (save.js): POST, and if the host answers 409 would_replace, ask `onReplace` and re-send with overwrite=1." Its implementation is at addon_sdk.js:533-541 (`build(overwrite)` appends `overwrite=1`, `if (!onReplace) throw error`, `if (!proceed) return { cancelled: true }`).
- THE TWO COPIES HAVE ALREADY DIVERGED ON THE WIRE SHAPE. test/fixtures/addons/fixture/save.js:40 recognises only the flat body: `if (payload?.error !== "would_replace" || !payload.files?.length) return { res, cancelled: false }`. app/javascript/maker/addon_sdk.js:92-97 deliberately reads both shapes — "errorFrom accepts today's flat {error: \"would_replace\", files: [...]} AND PR 3's nested {error: {code: …}}" — because a getter reading one shape "would silently hand `onReplace` an empty list". So the fixture asserts an agreement with the host that the shipped code does not have.
- test/system/addon_bundle_test.rb:58-61 repeats the stale claim as the reason the test is trustworthy: "The fixture imports a VERBATIM COPY of the helper all three real bundles import, so what passes here is the same code that ships." It is not the code that ships.
- THE DECLINE BRANCH IS ASSERTED ONLY AGAINST THE DEAD COPY. test/system/addon_bundle_test.rb:113-114 (`dismiss_confirm(/Replace with this version\?/)` → "Not saved.") runs through save.js. The SDK fixture cannot reach the same branch: test/fixtures/addons/sdk-fixture/sdk.js:92-95 hardcodes `onReplace: (files) => { …; return true }`, so `result.cancelled` at sdk.js:97 is unreachable, and test/system/addon_sdk_test.rb:74-92 asserts only the accept path. The two other `host.files.save` call sites in that fixture (sdk.js:213, sdk.js:270) pass no `onReplace` at all, so a 409 there throws rather than cancelling. Grepping test/system for `dismiss_confirm` returns exactly two hits: addon_bundle_test.rb:113 and tray_layout_test.rb:92 (an unrelated dialog).
- CROSS-CHECKED AGAINST THE SIBLING REPO (~/Desktop/repos/tinkerex-addons, read-only): `ls addons/*/save.js` → no matches; all three published bundles (`generators`, `boxes`, `openscad` in addons/manifests.json) import `@maker/addon-sdk`. The publish-side guard `bin/check-fixture-drift` loops `for dir in addons/*/` and skips any key the host does not mirror, so a fixture module with no counterpart in the addons repo — which is exactly what fixture/save.js is — can never be reported by it, in either direction.

**Current complexity / invalid states**

One client-side protocol (POST → 409 `would_replace` → ask the user → re-POST with `overwrite=1` → distinguish declined from failed) has two implementations inside this repo: the shipped `app/javascript/maker/addon_sdk.js` (`files.save`, returning the tagged `{cancelled}` object and typed `WouldReplaceError`) and `test/fixtures/addons/fixture/save.js` (`saveWithOverwrite`, returning `{res, cancelled}` and reading only the flat error body). The fixture copy exists on the stated grounds that it is byte-identical to what ships; that ceased to be true when the bundles moved onto the SDK, and the two have already diverged on which 409 body shapes they understand. The browser-level assertions for the flow are split across the two: the accept path is proved against the SDK (addon_sdk_test.rb:74-92), the decline path only against the copy (addon_bundle_test.rb:105-124).

**Proposed representation**

One owner for the flow: `host.files.save`. Delete `test/fixtures/addons/fixture/save.js` and let the raw-ctx `fixture` addon do a plain `fetch` POST to `ctx.saveUrl` with `ctx.csrfToken` — which is all its stated job requires (manifests.json:27 keeps `fixture` on the raw-ctx path so "both halves of the compatibility rule are covered by something that runs"; the compatibility half is the ctx door, not the 409 helper). Move the two browser tests onto shipped code: make sdk-fixture's `onReplace` answer come from the query string, the way `q.get("parent")`/`q.get("fname")` already do (sdk.js:88-89), so `addon_sdk_test.rb` can assert both `Saved.` and `Not saved.` plus "declining leaves the original bytes untouched"; and keep the real `window.confirm` exercised where it actually ships, in `test/fixtures/addons/boxes/editor.js:342`, by adding a `dismiss_confirm` case beside `box_revisions_test.rb:180`. Then correct the two comments that assert the copy is what ships (fixture.js:12-17, addon_bundle_test.rb:58-61).

**Why simpler**

It removes an entire second definition of a wire protocol from the repo, and with it the class of failure this codebase repeatedly records: a green test over code nobody runs. Today a change to the host's 409 body shape (the nested form addon_sdk.js:92-97 already anticipates) breaks the fixture and nothing that ships, while a change to the SDK's decline semantics breaks nothing at all, because the only assertion of that outcome is against the copy. After the change, each browser assertion in this area is about the module that production loads, and the fixture tree's one remaining bundle-side helper is gone rather than being kept in sync by a comment. It also removes the only file in test/fixtures/addons/ that the sibling repo's `bin/check-fixture-drift` structurally cannot see — the snapshot's drift is otherwise bounded by that guard, which is what makes this the one genuinely unguarded piece.

**Smallest credible implementation scope**

Delete test/fixtures/addons/fixture/save.js (51 lines); inline a ~6-line `fetch` POST into fixture.js's save handler and drop the import at fixture.js:2 and the call at fixture.js:64; parameterize `onReplace`'s answer in sdk-fixture/sdk.js:92-95 from the query string; move the two tests at addon_bundle_test.rb:78-124 into addon_sdk_test.rb (or retarget them in place) and add one dismiss_confirm case to box_revisions_test.rb; rewrite the stale comment blocks at fixture.js:12-17 and addon_bundle_test.rb:56-61. No app/ or lib/ change. Roughly one small PR.

**Affected files**

- `test/fixtures/addons/fixture/save.js`
- `test/fixtures/addons/fixture/fixture.js`
- `test/fixtures/addons/sdk-fixture/sdk.js`
- `test/system/addon_bundle_test.rb`
- `app/javascript/maker/addon_sdk.js`

**Regression risks and migration concerns**

Two things must not be lost. (1) The raw-ctx compatibility coverage that manifests.json:27 explicitly buys — the rewritten fixture must still POST to `ctx.saveUrl` with `ctx.csrfToken` and never import the SDK, or the `fixture`/`sdk-fixture` pairing collapses into one path. (2) The browser-only proof that a real `window.confirm` gates a real re-POST: today only save.js's dialog is dismissed in a test, so the boxes dismiss_confirm case is the replacement, not an optional extra. There is also an out-of-repo unknown this audit could not fully close: if any unpublished bundle still copies save.js by hand, deleting the fixture removes its differential check — but the three manifests in the sibling repo's addons/manifests.json are the complete published set and none of them does.

**Validation required**

Before: confirm the copy is dead by grepping the sibling checkout — `ls ~/Desktop/repos/tinkerex-addons/addons/*/save.js` (no matches) and `grep -rn saveWithOverwrite ~/Desktop/repos/tinkerex-addons/addons/` (no hits). After: `bin/ci system` must keep the same run count, with the decline assertion now failing if the SDK's `if (!proceed) return { cancelled: true }` (addon_sdk.js:541) is mutated to return `{cancelled: false}` — mutation-check exactly that line, since under today's arrangement that mutation leaves the whole suite green. Also mutate `addon_sdk.js`'s `WouldReplaceError#files` getter (addon_sdk.js:96) to read only `this.body?.files` and confirm the new accept-path assertion on `data-replaced` still catches it.

### Cross-subsystem concerns raised by this lane

_Named, not solved — the lane was told to stay inside its boundary._

- The single finding straddles a boundary: the fix deletes a file in test/fixtures/addons/ but the replacement coverage lands on app/javascript/maker/addon_sdk.js's behaviour, asserted through test/system/addon_sdk_test.rb and test/system/box_revisions_test.rb. Whoever owns the addon SDK subsystem should review the mutation-check on addon_sdk.js:541 (`if (!proceed) return { cancelled: true }`), which is unguarded today.
- The claim 'all three real bundles import save.js' was true when written and is now false; the same class of stale cross-repo claim may exist elsewhere in comments that describe chaim354/tinkerex-addons from inside this repo. Nothing in bin/ci can check a sentence about another repository — the sibling's bin/check-fixture-drift covers directory contents only, never prose or the manifest index.

---

## S41 — Browser module graph (vendored JS + importmap)

**Lane verdict:** `recommend`

### S41-1 — Vendored-file provenance is three unrelated records; one already exists for a third of the directory — extend it and derive the pin-graph check from it

> **COORDINATOR VERDICT — ACCEPT.** Verified against the tree; no narrowing applied.

- **Category:** data-structure  
- **Lane confidence:** high

**Evidence**

- vendor/javascript/JSPREADSHEET-LICENSES.md:9-15 — a per-file provenance TABLE already exists in this directory (File | Package | Resolved version | Licence | Source), covering exactly 5 artifacts (jspreadsheet.js, jsuites.js, formula-parser.js and two .css). Lines 16-21 go further and record that `@5` was a floating range plus what it resolved to on a named date, and lines 22-27 record that each bundle's internal version string disagrees with the resolved one. This is the right shape; it stops at one of the three vendored families.
- vendor/javascript/JSPREADSHEET-LICENSES.md:4-6 — that same record already REFERS to a patch in a family it does not cover: "the hand-patched `buffer.js` that jszip and Maker.js share". The record knows the fact exists and has nowhere to put it.
- bin/build-codemirror:16-18 — "This differs from every other file in vendor/javascript/, which are unmodified upstream bytes fetched from a CDN." That claim is FALSE at HEAD for at least three files (next three refs), and it is load-bearing prose: it is the sentence that tells a reader re-downloading a vendored file is safe.
- config/importmap.rb:26-33 — records that buffer.js shipped a relative import `../../_/C7GZrc4O.js` to a jspm shared chunk, that the chunk was fetched separately, and that "buffer.js's one import line" was repointed BY HAND at a fabricated bare specifier `jszip-buffer-chunk`. Ends: "Without this, `import JSZip from \"jszip\"` 404s in the browser via buffer.js's dead import."
- config/importmap.rb:63-70 — records two more hand-patches: `three.module.js` re-exports `./three.core.js` "(repointed to the bare \"three-core\" specifier)" and `3MFLoader.js` imports fflate via a relative path "(repointed to the bare \"fflate\")". Line 70 closes with "Verified: no dangling relative/URL import remains in any file" — a one-time manual verification with nothing behind it.
- vendor/javascript/three.module.js:1-6 — lines 1-5 are the upstream Three.js MIT banner; line 6 is the patched `import { Matrix3, Vector2, Color, … } from 'three-core'`. Nothing in this 19,610-line file marks it as modified; the only two occurrences of `three-core` in the whole file are lines 6 and 7 (grep -n).
- vendor/javascript/3MFLoader.js:22 — `import { unzipSync } from 'fflate';` (upstream ships `../libs/fflate.module.js`, per config/importmap.rb:68-69). Line 1 of this file is `import {` — it carries no provenance header at all, so the patch is unmarked in a file whose origin is also unrecorded.
- vendor/javascript/buffer.js:1,3 — line 1 IS a provenance banner (`// buffer@2.1.0 downloaded from https://ga.jspm.io/npm:@jspm/core@2.1.0/nodelibs/browser/buffer.js`), line 3 is the patched `import{d as r}from"jszip-buffer-chunk"`. The banner records where the bytes came from and says nothing about their having been edited — the same for vendor/javascript/jszip.js:1, whose banner names `jszip/dist/jszip.min.js@3.10.1` while the file was renamed post-download (config/importmap.rb:15-16).
- test/ci_hygiene_test.rb:346-369 — the complete set of machine checks on this pin graph: pins are parsed out of config/importmap.rb (346-347), a non-vacuity assertion (351), `codemirror` is pinned (355), no `@codemirror/*` per-package pin (357-361), and `vendor/javascript/codemirror.js` exists (366-369). The other 23 pins' targets are unchecked and no vendored file's import specifiers are checked at all.
- app/javascript/controllers/modelviewer_controller.js:118-120 — `boot()` does `await import("three")` then `await import("three/addons/controls/OrbitControls.js")`; a rejection is caught at lines 45-47 and 89-93 and logged as `console.warn("[modelviewer] keeping thumbnail fallback:", e)`, leaving the poster image in place. test/system/README.md:60-64 states there is deliberately no system test asserting the render ("renders into a `<canvas>`, which is opaque to Capybara"); the integration tests (test/integration/web/files_flow_test.rb:270-288) assert only data attributes.
- docs/AUDIT-2026-08-19.md:214 — a prior audit row recorded this whole directory as "Third-party JS shipped verbatim … skip (verified)", and line 288 enumerates the files under that heading. That is the second document in the repo asserting the unmodified-bytes belief that lines 4-8 above disprove.

**Current complexity / invalid states**

Four different facts about a vendored file — where it came from, what version, what licence, and whether its bytes were edited — are recorded in four unrelated places with no common shape. A table covers five files (JSPREADSHEET-LICENSES.md:9-15). A one-line banner covers the four jspm downloads (buffer.js:1, jszip.js:1, process.js:1, jszip-buffer-chunk.js:1) and records origin but never edits. Five prose blocks in config/importmap.rb (lines 9-33, 63-77) carry the three-file patch record, in a file whose job is the pin table. And the six three.js files carry nothing at all. Because there is no single record, two documents in the repo now state the opposite of the truth — bin/build-codemirror:16-18 and docs/AUDIT-2026-08-19.md:214 both assert the directory is unmodified upstream bytes, while three files are hand-repointed and one is renamed. Nothing checks any of it: the closure property config/importmap.rb:70 claims to have verified by hand — every import in vendor/javascript resolves to an importmap pin, no relative or URL import remains — is asserted in prose and by no test.

**Proposed representation**

One per-file provenance record for the whole directory, in the shape the repo already chose: promote JSPREADSHEET-LICENSES.md to VENDOR-PROVENANCE.md (or add a second table beside it) with one row per vendored artifact carrying Source URL, Resolved version, Licence, and a Patched column naming the exact edit (`three.module.js:6  './three.core.js' -> 'three-core'`), blank for the untouched ones. Then derive the check the record makes possible, in test/ci_hygiene_test.rb which already parses the pins at line 346: walk the pin graph from the importmap's `to:` targets under vendor/javascript, collect the bare specifiers each target imports, and assert (a) every one of them is an importmap pin, (b) no relative or URL specifier survives in a reachable file, (c) every pin's target file exists — today only codemirror.js is checked (366-369). Correct bin/build-codemirror:16-18 to say what is actually true: it is the only GENERATED file, and three of the fetched ones are patched.

**Why simpler**

It replaces four incompatible records with one, using a table this directory already contains rather than inventing a format, and it makes the directory's central claim checkable instead of re-argued. config/importmap.rb goes back to being a pin table: the argument for each fabricated specifier stays (it is genuine §14-grade rationale), but the mechanical facts — source URL, version, which line was edited from what to what — stop being prose a reader has to reassemble into a graph. Most concretely, it gives the next person bumping three.js the one thing they cannot get today: `pin "three" # @0.185.1` at config/importmap.rb:71 will age, config/importmap.rb:65-67 instructs re-vendoring from unpkg, and the two lines that must be re-patched afterwards are line 6 of a 19,610-line file and line 22 of a 1,621-line file, neither marked. This is not a new abstraction over working code; it is the completion of one already present, plus the guard that turns a hand-verified sentence into a fact.

**Smallest credible implementation scope**

Small and self-contained. One documentation file extended from 5 rows to ~19 (the facts are all recoverable from the existing banners and comments — no re-downloading needed). Roughly 10-15 lines trimmed from config/importmap.rb where prose duplicates the table, leaving the arguments intact. One ~30-line test added to the existing importmap section of test/ci_hygiene_test.rb. Three lines corrected in bin/build-codemirror. No shipped bytes change and no runtime behaviour changes.

**Affected files**

- `vendor/javascript/JSPREADSHEET-LICENSES.md`
- `config/importmap.rb`
- `bin/build-codemirror`
- `test/ci_hygiene_test.rb`
- `vendor/javascript/three.module.js`
- `vendor/javascript/3MFLoader.js`
- `vendor/javascript/buffer.js`

**Regression risks and migration concerns**

The specifier scan must not regex over minified UMD bundles: formula-parser.js is 180KB on a single line and jspreadsheet.js/jsuites.js are minified with no ESM imports at all, so a loose `from"…"` pattern would false-positive on string literals. Scoping the walk to files REACHABLE from a pin target avoids this by construction — those three are loaded as classic scripts by app/views/projects/sheets/show.html.erb:38-39 and are in no pin — but it must be scoped that way deliberately, not by naming files. Second, §14e's rule applies directly here ("a guard that scans a directory dies silently when the directory leaves"): the test must assert it walked a non-empty file set and collected more than a handful of specifiers before asserting anything is empty, or a path change retires it silently. Third, trimming config/importmap.rb must not remove the ARGUMENTS — why `three-core` and `jszip-buffer-chunk` are fabricated specifiers rather than a jspm pin is §14-grade reasoning that cost real debugging; only the mechanical duplication should move.

**Validation required**

Mutation-check the guard three ways, per §15: (1) revert vendor/javascript/three.module.js:6 to `from './three.core.js'` and confirm the test goes RED — this is the exact regression a three.js bump reproduces; (2) delete the `three-core` pin at config/importmap.rb:72 and confirm RED; (3) point a pin's `to:` at a filename that does not exist and confirm RED. Then confirm non-vacuity by printing the number of files walked and specifiers collected and asserting a floor, the way test/ci_hygiene_test.rb:351 already does for the pin parse. Independently confirm the failure is otherwise invisible: with mutation (1) in place, `bin/ci` should stay fully green — that is the whole argument for the guard.

---

## S42 — Lint & scan gate binstubs and their configs

**Lane verdict:** `skip`

**This subsystem was reviewed and deliberately returned no findings.** The lane's argument:

> Read at HEAD, in full: bin/rubocop (8 lines), bin/brakeman (33), bin/bundler-audit (6), bin/importmap (4), bin/setup (35), .rubocop.yml (15), config/brakeman.ignore (97), .github/dependabot.yml (11). Also read for context: config/ci.rb:30-48 and :251-261, test/ci_hygiene_test.rb:170-200 and :260-345, config/bundler-audit.yml, and the six Open3 call sites the ignore file arbitrates over.
>
> WHY SKIP. This subsystem is ~210 lines, of which the majority is comment prose carrying documented invariants, and it has essentially no state to represent: four one-purpose binstubs, one `inherit_gem` line, an externally-owned JSON suppression file, and an 11-line dependabot config. Nothing here holds a lifecycle, a nullable-field combination, or a branch table. Every candidate I formed died on inspection:
>
> (1) THE FINGERPRINT-PLUS-PROSE REPRESENTATION IS THE RIGHT ONE, and I judged it explicitly as the row asked. The record's identity key is content-derived (config/brakeman.ignore:6, :29, :52, :75) and is what brakeman actually matches on; the `file`/`line`/`code` fields are informational and brakeman rewrites the whole record on regeneration, so we do not own the format and cannot restructure it. The one thing we DO own — the `note` field — is the load-bearing part and is unusually well-argued (e.g. :70 rebuts the SQL warning using brakeman's own `user_input: "exts.size"` field, an integer count, and names the two independent layers behind it). Replacing that prose with anything more structured would trade a reviewable argument for a token.
>
> (2) Binstub argument injection is already governed by a mutation-checked three-assertion guard (test/ci_hygiene_test.rb:293, :312, :327) and bin/brakeman:5-31 carries the incident. bin/rubocop:6 and bin/bundler-audit:5 DO inject arguments, but ci_hygiene_test.rb:300-305 argues the carve-out on the merits (config-file selection, no network, cannot change what is reported) and explicitly rejects broadening the rule. That is a strong argument I cannot beat.
>
> (3) The three different bootstrap idioms across the four binstubs (bin/rubocop:2-3 `rubygems`+`bundler/setup`+`Gem.bin_path`; bin/bundler-audit:2 `config/boot`; bin/importmap:3 `config/application`) are each correct for their tool — importmap needs the loaded app to read config/importmap.rb. Unifying them is pure stylistic consistency, which the brief excludes, and would put bin/brakeman:33's pinned-version guard at risk for no gain.
>
> (4) config/bundler-audit.yml contains only a placeholder (`CVE-THAT-DOES-NOT-APPLY`), so bin/bundler-audit:5 injects a `--config` for a no-op file. Deleting it would let the "binstub is a plain loader" rule extend uniformly — but that is line-count plus consistency, and the file is a genuine future extension point for a real CVE waiver. Not fundable.
>
> VERIFIED DRIFT I AM DELIBERATELY NOT PROMOTING TO A FINDING, because the fix is a chore or a new guard rather than a simplification of representation, and none of it currently misbehaves: config/brakeman.ignore has not been touched since 2026-07-29 (b328912), and its informational metadata has since drifted — :55-56 point at app/controllers/files_controller.rb:729, but `flat_ext_scope` is now at :1039-1042 (line 729 is inside `require_scannable!`); :9-10 point at v1/maker/file_attachments_controller.rb:33, but `attachment_params` is at :32; :96 records `"brakeman_version": "8.0.5"` while Gemfile.lock:110 pins 8.0.6. All four fingerprints evidently still match (the scan gate is green with `--exit-on-warn`), so this is cosmetic — but a reviewer auditing a suppression from the ignore file is sent to the wrong line, which is worth knowing when the cross-subsystem concern below fires.

---

## S43 — Sheets (spreadsheet) feature

**Lane verdict:** `recommend`

### S43-1 — The workbook blob's element shape is guarded in the browser but not on the server, so `Sheet#cells`/`#columns` are half a guard and `to_csv` is the unguarded consumer

> **COORDINATOR VERDICT — ACCEPT.** Verified against the tree; no narrowing applied.

- **Category:** data-structure  
- **Lane confidence:** high

**Evidence**

- app/models/maker/sheet.rb:57-58 — `def cells = data.is_a?(Hash) && data["cells"].is_a?(Array) ? data["cells"] : []` and the identical line for `columns`. Both check only that the value IS an Array; the elements are returned untouched.
- app/models/maker/sheet.rb:64-65 — `to_csv` then assumes the elements: `csv << columns.map { |c| c["title"].to_s }` and `cells.each { |row| csv << Array(row).map(&:to_s) }`. Verified with `ruby -e`: `nil["title"]` raises NoMethodError, and `Array({"a"=>1})` is `[["a", 1]]` — so a nil column entry 500s the CSV export and a Hash row exports as garbage pairs.
- app/javascript/controllers/sheet_controller.js:60-66 — the comment states "The model's `columns` reader guards the OUTER shape only … it does not, and cannot, validate every element inside an otherwise-valid array … Filter here too", followed by `columns.filter((c) => c && typeof c === "object").map((c) => ({ title: c.title, width: c.width || 120 }))`. This is the only element-level guard in the whole feature, and it exists only in the browser.
- app/views/projects/sheets/show.html.erb:63 — the page feeds the grid from the readers: `data-sheet-data-value="<%= { "columns" => @sheet.columns, "cells" => @sheet.cells }.to_json %>"`, so whatever the readers return is exactly what the JS filter then has to clean up.
- app/controllers/projects/sheets_controller.rb:71 — `params.require(:sheet).permit(:name, :position, data: {})` permits the blob whole (and sheet.rb:77-79 deliberately validates nothing about shape), so a crafted PATCH from the sheet's own owner is the reachable path; sheets_controller.rb:26-30's `format.csv` branch has no rescue.
- test/integration/web/project_sheets_test.rb:232 and :237-246 — the suite stores exactly `{"columns" => [nil, {"title" => "Z"}], "cells" => "nope"}` and its comment records the measured result: "`columns` passes the SAME outer check … so its malformed inner `nil` entry rides through unchanged" and "The inner-element case is what sheet_controller.js's own `.filter(...)` guards". That same stored sheet, fetched as `.csv`, hits sheet.rb:64.

**Current complexity / invalid states**

One invariant — "a workbook is `{columns: [Hash], cells: [[scalar]]}`" — is asserted at three sites with three different strengths, in two languages: the model readers check the outer container only, the Stimulus controller re-checks each element, and `to_csv` checks nothing at all. Nothing owns the shape, so each new consumer must independently rediscover how much of it is already true. The gap is not a considered division of labour: the JS comment justifies the second guard by saying the model "does not, and cannot" do element-wise validation — but it plainly can (`grep(Hash)`), and the reason the split looks defensible is that the one server-side consumer that would expose it (`to_csv`) was never checked against the malformed blob the integration test itself constructs.

**Proposed representation**

Make the two readers TOTAL over the shape their consumers already assume, so the model is the single definition of "workbook" and every reader downstream — Ruby or JS — gets the same guarantee: `columns` returns only Hash entries (`… ? data["columns"].grep(Hash) : []`), `cells` returns rows normalised to Arrays (non-Array rows mapped to `[]`, preserving row count so `_sheets.html.erb:22`'s "N rows" does not shift). `to_csv` then drops its `Array(row)` coercion and is safe by construction, and `sheet_controller.js`'s `.filter((c) => c && typeof c === "object")` becomes dead — the view at show.html.erb:63 feeds it exclusively from the readers, so after this change nothing malformed can reach it. Keep the two properties the existing comments are actually defending: the readers still never raise, and `data_within_size_limit` (sheet.rb:86-92) still says nothing about shape, so a half-written blob is still a save the user can complete.

**Why simpler**

One place decides what a workbook is, instead of three places each deciding a different amount of it. It removes the cross-language duplication the JS comment explicitly documents as necessary, and it removes the class of bug that duplication already let through — a consumer written on the server against readers advertised as "defensive" that turns out not to be defended. It is a tightening of an existing reader, not a new type or a new layer: net effect is two lines in the model, one coercion deleted, seven lines of JS deleted.

**Smallest credible implementation scope**

Two one-line changes in app/models/maker/sheet.rb:57-58; drop `Array(...)` at sheet.rb:65; update the reader comment at sheet.rb:53-56 (it currently describes outer-only semantics) and delete the now-redundant filter and its comment at sheet_controller.js:60-66. Tests: extend test/models/maker/sheet_test.rb's "cells and columns read defensively from a malformed blob" (line 50) with element-wise cases, and add a request test that GETs `.csv` on the exact blob project_sheets_test.rb:232 stores. Roughly 30 lines net across five files, no migration, no route or API change.

**Affected files**

- `app/models/maker/sheet.rb`
- `app/javascript/controllers/sheet_controller.js`
- `app/views/projects/sheets/show.html.erb`
- `app/controllers/projects/sheets_controller.rb`
- `test/integration/web/project_sheets_test.rb`

**Regression risks and migration concerns**

The integration test at project_sheets_test.rb:246-247 asserts the rendered `data-sheet-data-value` equals `{"columns" => [nil, {"title" => "Z"}], "cells" => []}.to_json`, and its surrounding comment (237-246) records that expectation as a measured correction to an earlier wrong draft. That expectation legitimately changes — it must be edited deliberately, with the comment rewritten, not deleted. Second risk: dropping a malformed column entry shifts the columns to its right, so column i no longer lines up with cell index i in that row. This is not a regression — sheet_controller.js:64-66 performs exactly that drop today, so the render path's behaviour is unchanged — but it is the reason to normalise cells rows to `[]` rather than drop them. Third: this must not be mistaken for a licence to shape-validate on save; the model comment at sheet.rb:77-79 argues correctly that rejecting a malformed blob turns a recoverable empty grid into an unsaveable sheet, and that stays true.

**Validation required**

Mutation-check per CLAUDE.md §15: with the new CSV request test green, revert `columns` to the outer-only form and confirm the test goes RED with NoMethodError from sheet.rb:64 — a reader change that leaves it green means the test built its blob through a path that sanitises. Separately confirm the JS deletion is safe by asserting the rendered `data-sheet-data-value` for the malformed blob now contains no null entry, which is what makes the browser-side filter unreachable. Run the three backend legs (`test`, `test-s3`, `test-chunk-remote`) for identical counts — sheets are app-DB rows and backend-neutral (sheets_controller.rb:2-4), so any divergence here would itself be the signal something else is wrong.

---

## S44 — Rails scaffold surface

**Lane verdict:** `recommend`

### S44-1 — Two Gemfile entries are auto-required at boot and used nowhere: `jbuilder` and `image_processing` — the latter contradicts the invariant one file away that structurally disables the only pipeline that would load it

> **COORDINATOR VERDICT — ACCEPT.** Verified against the tree; no narrowing applied.

- **Category:** ownership  
- **Lane confidence:** high

**Evidence**

- Gemfile:31-32 — `# Build JSON APIs with ease [https://github.com/rails/jbuilder]` / `gem "jbuilder"`. Neither entry carries `require: false`.
- Gemfile:63-64 — `# Use Active Storage variants [...]` / `gem "image_processing", "~> 2.0"`.
- config/application.rb:7 — `Bundler.require(*Rails.groups)`. Because neither gem is `require: false`, both are `require`d into every process (production, dev, test, `bin/jobs`) at boot, unlike `aws-sdk-s3`/`kamal`/`thruster`/`omniauth_openid_connect`, which are all explicitly `require: false` in the same Gemfile.
- config/application.rb:51 — `config.active_storage.variant_processor = :disabled`, under a 19-line comment (:30-50) stating the variant pipeline "was never usable here" because the app deliberately ships no ruby-vips, and that `:disabled` "removes CVE-2026-66066's code path STRUCTURALLY".
- activestorage-8.1.3.1 lib/active_storage/engine.rb:97-99 — the `case ActiveStorage.variant_processor` selects `ActiveStorage::Transformers::NullTransformer` for `:disabled`, so `ActiveStorage::Transformers::ImageProcessingTransformer` (whose file-level `begin require "image_processing"` at transformers/image_processing_transformer.rb:3-9 is the only in-tree consumer) is never autoloaded. The gem is loaded by `Bundler.require` and then referenced by nothing.
- `grep -rn "ImageProcessing" app lib test config bin` returns exactly two hits, both PROSE inside the disabling comment: config/application.rb:34 and config/application.rb:40. Zero call sites.
- `grep -rni "jbuilder" . --exclude-dir=.git --exclude=Gemfile.lock` returns only Gemfile:31 and Gemfile:32. `find app -name "*.jbuilder"` is empty; the only `*.json*` file under app/ is app/views/pwa/manifest.json.erb. The v1 API renders plain hashes instead — e.g. app/controllers/v1/maker/locations_controller.rb:5 `render json: { locations: ... }`.
- app/services/maker/previews/image_thumb.rb:25 — `BIN = ENV.fetch("VIPSTHUMBNAIL_BIN", "vipsthumbnail")`; the raster resize path shells out to the binary (:47, :56 handle its exit status), which is the design reason no in-process image library is wanted (CLAUDE.md §14e).
- Gemfile.lock:163 (`image_processing (2.0.2)`, listed with no dependency lines beneath it) and Gemfile.lock:174 (`jbuilder (2.15.1)`, a top-level spec entry following `irb`), with both named under DEPENDENCIES at :500 and :502 — neither is pulled in transitively by another gem, so removing the Gemfile line removes the gem entirely.

**Current complexity / invalid states**

The Gemfile is a claim about what the app depends on, and for these two entries the claim is false in a way that is actively misleading rather than merely idle. `image_processing` exists solely to satisfy Active Storage's variant transformer; config/application.rb:51 turns that transformer off, and the surrounding comment argues at length that the whole variant path is unusable here by design. A reader who consults the Gemfile — the conventional place to answer "can this app resize images?" — gets "yes, image_processing ~> 2.0", and several checked-in planning documents still assert it (docs/research-format-processing.md:105 "already in the Gemfile", docs/superpowers/plans/2026-06-15-preview-pipeline.md:12). The actual answer is "only by shelling out to vipsthumbnail". `jbuilder` is the plainer case: a gem that installs a template handler and a railtie into every boot for a rendering style the app has never used. Both also sit in the weekly Dependabot / `bundler-audit` surface (Gemfile:88), so each future advisory or version bump on them costs a real review of something that cannot affect this app.

**Proposed representation**

Delete Gemfile:31-32 and Gemfile:63-64 and re-resolve the lockfile, so the declared dependency set matches the set the app can actually reach. The variant decision then lives in exactly one place — config/application.rb:51 plus its comment — instead of being asserted one way in config/ and the opposite way in the Gemfile.

**Why simpler**

It removes a contradiction rather than adding an abstraction: after the change there is one statement about image variants in the repo instead of two that disagree, and the Gemfile stops advertising a capability whose comment two files away exists to forbid. It also shrinks what `Bundler.require` pulls into every process to things that are reachable, which is the same principle the Gemfile already applies deliberately to `aws-sdk-s3`, `kamal`, `thruster` and `omniauth_openid_connect` via `require: false`.

**Smallest credible implementation scope**

Two Gemfile line-pairs deleted, `bundle install` to update Gemfile.lock (removing the specs at :163/:174, the DEPENDENCIES entries at :500/:502, and the checksum lines at :581/:585). No app, config, test or Dockerfile change. `rails app:update` will offer both lines back, which is the §14e regression source this row exists to watch — if that matters, the durable form is a line in test/ci_hygiene_test.rb, which already refuses re-injected scaffold content.

**Affected files**

- `Gemfile`
- `Gemfile.lock`
- `config/application.rb`

**Regression risks and migration concerns**

One real counter-argument, which I checked rather than assumed and which applies only to `image_processing`. TODAY, if someone edits application.rb:51 back to `:vips`, boot dies LOUDLY: transformers/vips.rb:10 does `require "image_processing/vips"`, whose LoadError message ("ImageProcessing::Vips requires the ruby-vips gem") matches neither arm of engine.rb:109-116's rescue (`/libvips/`, `/image_processing/`), so it re-raises — exactly the incident CLAUDE.md §14e records. WITHOUT the gem, the outer `require "image_processing"` at image_processing_transformer.rb:3 raises a LoadError whose message DOES match `/image_processing/`, so activestorage downgrades it to a logged warning and leaves `variant_transformer` nil — silent inert. So removal converts an accidental tripwire into a silent no-op for that one forbidden edit. I judge this not worth keeping a boot-loaded gem for: the tripwire only fires on an edit whose own comment forbids it, and the silent outcome it degrades to is harmless here (the only `representation` call in the tree, app/views/active_storage/blobs/_blob.html.erb:3, is unreachable because both rich-text models include `Maker::TextOnlyRichText`), while the deadlock the design actually guards against comes from ruby-vips, which this change does not touch either way. It also makes re-enabling variants require TWO deliberate Gemfile edits instead of one. If the reviewer disagrees, the honest split is: drop `jbuilder` (no counter-argument exists) and keep `image_processing` with a one-line comment recording that it is retained as a loud-failure tripwire, not as a dependency — the current state, where it reads as a live dependency, is the only outcome I would not choose.

**Validation required**

Static, already done: the three greps above (`ImageProcessing`, `jbuilder`, `*.jbuilder`) return zero call sites, and Gemfile.lock shows both as direct-only. Dynamic, which I could NOT run under this read-only audit: boot each env and confirm `ActiveStorage.variant_transformer` is `ActiveStorage::Transformers::NullTransformer` before and after, and that `ActionView::Template.handler_for_extension(:jbuilder)` was never exercised; then run bare `bin/ci` — all three backend legs (`test`, `test-s3`, `test-chunk-remote`) must report identical run counts per §15, since `Bundler.require` runs in every leg and a hidden transitive use would surface as a NameError at boot rather than in one leg only.

### Cross-subsystem concerns raised by this lane

_Named, not solved — the lane was told to stay inside its boundary._

- The cache_store guard gap crosses into config/environments/production.rb and test/ci_hygiene_test.rb, both outside this row's boundary — whichever row owns the environment configs or the hygiene guards should decide whether to add a boot-level assertion that all three Solid stores resolve as configured, since the invariant's own instruction ("resolve it by RUNNING Rails.application.config.cache_store") is something no reader of the files can satisfy.
- The recommended Gemfile change is inert with respect to every other subsystem — `image_processing` and `jbuilder` have zero call sites and no transitive dependents — but because `Bundler.require(*Rails.groups)` at config/application.rb:7 loads them in every process, verification must be bare `bin/ci` across all three backend legs rather than a single leg.
- Several checked-in planning/research documents (docs/research-format-processing.md:105, :224; docs/superpowers/plans/2026-06-15-preview-pipeline.md:12, :278; docs/HANDOFF.md:173) still assert that `image_processing` is the resize step. The implementation went to a `vipsthumbnail` subprocess instead (app/services/maker/previews/image_thumb.rb:25). Those are historical plan documents rather than invariant files, so no doc change is required by the gem removal, but a reader consulting them will be misled either way.

---

## S45 — Database migrations

**Lane verdict:** `skip`

**This subsystem was reviewed and deliberately returned no findings.** The lane's argument:

> Read all 72 files in db/migrate/ (1,959 lines). Opened in full: all five rederive_* migrations, both Action Text conversions, drop_redundant_prefix_indexes, drop_retired_sync_engine_tables, purge_repo_metadata_nodes, one_preview_per_node_and_kind, delete_addon_parameters_file_rows, backfill_devise_user_columns, add_unique_index_to_maker_file_attachments, add_user_foreign_key_to_conflicts_and_file_locks, create_sync_engine, create_maker_previews + its two add_column follow-ups, create_maker_shelves, add_auto_catalog_to_maker_models, create_maker_models, create_maker_file_attachments, create_maker_addon_state_revisions, create_remote_manifest_chunks. Skimmed the remaining ~45 plain create_table/add_column migrations (20260612*-20260730*) with comments stripped; all are ordinary frozen DDL with nothing to represent differently.
>
> THE BRIEF'S PRIMARY LEAD DOES NOT PAN OUT — the five rederive_* migrations agree with Maker::FileAttachment::ROLE_BY_EXT at HEAD, with exactly one divergence that is deliberate, named, and doubly guarded. Checked entry by entry:
> - 20260728124303_rederive_vector_and_cad_source_roles.rb:20-22 maps svg/dxf->vector and scad/f3d/fcstd/sldprt/sldasm->cad_source; app/models/maker/file_attachment.rb:47,52-53 agrees on all seven.
> - The ONE divergence is `lbrn2`: db/migrate/20260728124303...rb:20 says `"lbrn2" => "vector"`, app/models/maker/file_attachment.rb:47 says `"lbrn2" => "laser"`. That is not drift — 20260730153103_rederive_laser_roles.rb:24,28-29 carries those rows forward (LASER_EXTS = %w[lbrn2], PRIOR_ROLE "vector" -> NEW_ROLE "laser"), and test/models/maker/rederive_roles_migration_test.rb:95 declares `SUPERSEDED = { "lbrn2" => "laser" }` with TWO assertions (:99-108 skips superseded entries; :111-114 asserts SUPERSEDED still matches the model AND still disagrees with the frozen migration, so the allowlist cannot outlive its cause).
> - 20260729035422_rederive_document_roles.rb:14-17 (txt md markdown json csv -> document) all match file_attachment.rb:61-62.
> - 20260826130000_rederive_code_roles.rb:28-29 lists 26 extensions; file_attachment.rb:74-78 lists the same 26 in the same order (`... "yml" => "code", "yaml" => "code", "cmake" => "code"`).
> - 20260826180000_rederive_widened_text_roles.rb:34-42 lists 25 (22 code + rst/tex/tsv document); file_attachment.rb:62-63 and :101-105 carry the identical set.
> Each copy has its own agreement test (test/models/maker/rederive_{roles,document_roles,laser_roles,code_roles,widened_text_roles}_migration_test.rb), and rederive_code_roles_migration_test.rb:100 additionally asserts the list SIZE is 26 so the guard cannot go vacuous — the pattern §15 demands. Recommending the copies be replaced by a reference to ROLE_BY_EXT would have to beat the self-containment argument stated at 20260728124303...rb:4-18 and repeated in each successor, and it cannot: the copies are provably not drifting, and a shared reference is exactly the coupling those headers reject.
>
> OTHER MIGRATIONS CARRYING APP LOGIC — checked for drift, none found:
> - 20260728152247_move_note_body_to_action_text.rb:22 calls `ApplicationController.helpers.render_note`, justified at :7-9 by the claim that render_note keeps a second caller. Verified still true at HEAD: app/helpers/notes_helper.rb:6 defines it and app/views/models/show.html.erb:110 calls it.
> - 20260826120000_purge_repo_metadata_nodes.rb:24 resolves `Library::RepoMetadataPurge` via safe_constantize with the NameError scoped to the lookup (:17-22) and reports `result.reason` rather than composing one (:38-47). Both hazards it names are real and correctly handled; nothing has moved out from under it.
> - 20260813000100_create_maker_addon_state_revisions.rb:32-37 backfills with raw SQL through the connection specifically so a later Maker::AddonState change cannot alter what it did.
>
> NEAR-MISSES I CONSIDERED AND REJECTED AS BELOW THRESHOLD, recorded so the next reader does not re-derive them:
> 1. `maker_file_attachments.version_id` (db/migrate/20260615000004_create_maker_file_attachments.rb:8) is close to vestigial — the only readers/writers at HEAD are the v1 API (app/controllers/v1/maker/file_attachments_controller.rb:33,37 and the echoes at projects_controller.rb:56, items_controller.rb:73); no web door sets it (projects/uploads_controller.rb:36-38 omits it, as do maker/project_intake.rb:566 and maker/model_intake.rb:112). Real, but it is an app/API finding whose migration is frozen history, and the payoff is one nullable column.
> 2. `maker_file_attachments.role` looks like a denormalized cache of the pure function `Maker::FileAttachment.role_for` (file_attachment.rb:212-214) — which is exactly why the five rederive migrations exist, and app/services/maker/project_folders.rb:10-12 explicitly refuses to read the stored column for that reason. But it is NOT redundant: app/controllers/projects/uploads_controller.rb:94-96 forces `"image"` for any Maker::BuildLogEntry target regardless of extension, so at least one writer is not derivable from the filename. Deriving it would need a new "forced" concept, i.e. forcing an abstraction, and touches four subsystems outside this boundary.
> 3. The five rederive migrations each redeclare `MigrationAttachment`/`MigrationNode` and repeat the same find_each + per-row `MigrationNode.find_by` loop (an N+1 by construction). Extracting a shared helper is precisely the coupling the self-containment headers forbid — a later edit to the shared helper would silently change what all five frozen migrations do.
> 4. `maker_models` now carries origin/auto_node_id/dismissed_at (20260825150100_add_auto_catalog_to_maker_models.rb:18-23) with no validation coupling origin=="auto" to auto_node_id presence (app/models/maker/model.rb:34 validates origin inclusion only). That is a hardening opportunity (a check constraint), not a simplification, and the state is owned by docs/invariants/model-intake.md.
>
> CONCLUSION: db/migrate is append-only history governed by CLAUDE.md §10's no-rewrite rule. Its only live surface — the hand-copied role vocabularies — is verified in agreement with the model and guarded on both sides. I would not fund a change here, and reporting one to fill a quota would be exactly the failure mode the brief warns against.

---

