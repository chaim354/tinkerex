# FileLayer Capability Gating + `Delivery` — Phase 4 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** the web UI and the v1 API tell the truth about what this deployment can do — bytes reach the browser through one polymorphic `Delivery` path on all three backends, the UI hides what the backend cannot do, and the sync surface answers **501 Not Implemented** instead of lying with an empty list.

**Architecture:** `FileLayer#download` returns a `Delivery` — `Redirect(url)` (presigned; §15 preserved), `SendFile(path)` (share), or `Stream(enum)` (chunk, unchanged) — and `FilesController` consumes it without ever constructing a path. `Capabilities` gains `port_writable`, and the shared **read contract** mechanically pins every capability to what the adapter actually does, so the two cannot drift. The 501 is produced by a **capability gate before the call**, never by rescuing.

**Tech Stack:** Rails 8, Minitest (`ActiveSupport::TestCase` / `ActionDispatch::IntegrationTest`, parallel forked processes, no fixtures), SQLite in test, Zeitwerk from `app/services`, Ruby 3.4, rubocop rails-omakase, Devise auth (`user_session_path` — see `test/integration/web/files_flow_test.rb`).

**Source spec:** `docs/superpowers/specs/2026-07-14-maker-file-layer-split-design.md` (§3.2 the port + the `Delivery` table, §6 capability degradation + 501s, §7 testing/Delivery variants, §9 phasing, §9a-3/§9a-5 deferred issues).
**Predecessors:** 2a (`63544ee`), 2b (the write path + `adapter_write_contract.rb`), **Phase 3 (the S3 adapter) — this plan assumes it landed.**

**Read before starting:** `app/controllers/files_controller.rb` (its header states the §15 invariant this plan must preserve), `app/views/files/show.html.erb`, `app/services/file_layer/{capabilities,chunk,share,s3}.rb`, `test/services/file_layer/adapter_contract.rb`, `test/integration/web/files_flow_test.rb`.

---

## Scope

**This plan (4):**
- `Capabilities#port_writable` + **the contract that stops every capability drifting from adapter behavior**
- `FileLayer::Delivery` + `#download` on all three adapters
- `FilesController#blob` through `Delivery` — **this is what fixes share/s3 downloads, which 404 today**
- `FilesController#show` / `#index` — stop reading `Version` directly, stop lying in share mode
- The upload branch: chunk → `Sync::Commit` (unchanged), share/s3 → the port; the wrong flow answers 501
- 501 gating on the v1 sync surface
- The web UI hides Restore/History/Devices per capabilities

**Explicitly NOT in scope — each would trip §10 or repeat a known mistake:**
- **"Unify uploads through the port."** Chunk-mode writes are `Sync::Commit`'s two-phase presigned flow; `Chunk#write` **raises on purpose** (2b Task 1, `63a330c`). A server-side chunk-and-commit path would duplicate `Sync::Commit`, have no caller, move bytes through Rails, and reach into the sync engine (§10). **The branch is the design, not a wart.**
- **§9a-4's `ChunkStore#read_bytes` template method** (the `respond_to?` sniffing). Real, still deferred — and Task 2 shows why Phase 4 does **not** force it (see the note there).
- **Hand-rolling X-Accel-Redirect.** Rails already implements the whole mechanism. See Landmine 4.
- Selective-sync UI, at-rest encryption, presigned upload (spec §5.2).

**Non-negotiable:** every commit leaves `bin/rails test` green, and the share and s3 legs stay **identical** to it. **Record all three baselines before Task 1 and put them in your report** — Phase 3 lands immediately before this, so this plan deliberately does not hard-code a count it cannot know.

**Tripwire (spec §10):** must not touch sync, the changelog, conflicts, locks, or the mount adapters. **This plan brushes right against it twice:** the upload branch sits next to `Sync::Commit`, and the 501 gate sits on top of the v1 sync controllers. Gating a controller is fine — **changing what it does is not.** If a task seems to need a change inside `Sync::*`, the boundary is wrong: STOP and report.

**Naming warning (carried from 2a, and it bites harder here because this plan touches controllers):** this codebase has a *sharing* feature — `app/models/share_link.rb`, `app/controllers/v1/share_controller.rb`, `app/controllers/v1/share_links_controller.rb` — meaning **public links to a file**. That is unrelated to `FileLayer::Share` (**backing the library with a mounted directory**). Do not conflate them. **`V1::ShareController` is not a share-mode controller** and is not gated by this plan.

---

## Learn from 2a and 2b — read this before Task 1

**2a's plan supplied an implementation for all ten tasks and was wrong in all ten**, twice in ways that would have shipped silent data loss. Its **tests** were mostly right. **So this plan gives you complete tests and NO implementations.** The tests are the specification. Implementations are **constraints and seams**, derived against the real files. If a constraint here is wrong, **that is the expected outcome — report it.**

**The process lessons — they apply verbatim:**
- **A test that cannot fail is decoration.** ~11 times in 2a a test stayed green while its coverage evaporated, including an `assert_raises(ArgumentError)` that passed on a *missing keyword* rather than the check it named. **Assert the message, not just the class.** This plan is full of `:not_implemented` and `:not_found` assertions that a wrong-but-plausible code path satisfies — Landmine 4 is exactly one of those.
- **Verify every mutation actually applied, byte-exactly, or you will report a false green.** Traps: multiline `grep -F` is an **OR of two patterns**; `<<~` strips indentation; **a non-UTF-8 `File.read` blows up on em-dashes and silently skips the substitution**; `%q{...\n}` is a literal backslash-n. Use `grep -c` with an **expected count**. (While this plan was being written, an em-dash pasted into a `ruby -e` killed the process outright — live, not folklore.)
- **NEVER `git checkout` to revert a mutation** — an agent destroyed its own uncommitted implementation that way. File backup + `cmp`.
- **`.erb` is not covered by any of the above.** This is the first phase to touch views in anger, and a view has no type checker and few tests. A capability check misspelled in an `.erb` renders as **nil → falsy → the feature silently disappears**. `<% if caps.versionned? %>` raises `NoMethodError` at render (loud), but `<% if @caps&.versioned %>` on a nil `@caps` is **silent**. Prefer the form that raises.

---

## Verified facts this plan rests on

Every one was checked against the real code in this worktree. Re-verify anything you depend on.

| # | Fact | How it was checked |
|---|---|---|
| 1 | **`NotImplementedError` descends from `ScriptError`, NOT `StandardError`.** A bare `rescue => e` does **not** catch it. | `.ancestors` + an executed `begin/rescue` |
| 2 | **Nothing in the codebase rescues `NotImplementedError`** — no prior art for it surfacing to a user. | `grep -rn "rescue.*NotImplementedError" app lib test config` → none |
| 3 | **It is raised in 5 places**, all "abstract method" or "not built yet": `FileLayer.build` (s3), `Chunk#write/delete/move`, `ChunkStore#presign_put/presign_get/exists?/list`, `Sync::RetentionPolicy`. | `grep -rn "NotImplementedError" app lib` |
| 4 | **`FilesController#blob` 404s in share mode**: `node.current_version` is nil → `raise ActiveRecord::RecordNotFound` → `rescue_from` → HTML redirects with "File not found.", other formats `head :not_found`. | code + an executed probe: `current_version_id=nil` |
| 5 | **`Capabilities` is `versioned`/`syncable`/`presignable`, and has ZERO consumers** anywhere in `app/`. Phase 4 gives it its first. | `grep -rn "capabilities" app` → only a comment in `reconciler.rb` |
| 6 | **All three chunk stores implement `presign_get`**, so `Chunk`'s hardcoded `presignable: true` is accurate today — §9a-3 is **latent, not live**. | `grep -n "def " app/services/storage/*.rb` |
| 7 | **There is no nginx.** Deployment is **Kamal** (kamal-proxy, a Go proxy). `config.action_dispatch.x_sendfile_header` is **nil**. | `find -iname "*nginx*"` → none; `config/deploy.yml`; runner probe |
| 8 | **`Rack::Sendfile` IS in the middleware stack**, and no-ops when the header is nil. | runner probe: `["Rack::Sendfile"]`, header `nil` |
| 9 | **When accelerated, `Rack::Sendfile` sets `Content-Length: 0` and replaces the body with `[]`.** It only acts when the body **responds to `to_path`** — so `send_data` never accelerates. | `rack-3.2.6/lib/rack/sendfile.rb:130-160` |
| 10 | **`x-accel-redirect` additionally needs an `x-accel-mapping`**; without it Rack logs `"x-accel-mapping header missing"` to `rack.errors` and **serves the bytes normally**. `x-sendfile` needs no mapping. | same source, lines 135-150 |
| 11 | **A presigned GET can carry signed `response-content-disposition` / `response-content-type` overrides.** | SDK shape + a generated presigned URL |
| 12 | **`show.html.erb` renders "No content yet.", Size "—", Current version "—" in share mode** — it branches on `@version.nil?`. | `app/views/files/show.html.erb:15,17,22` |

---

## The 501 decision — settle it before Task 1

**The question:** is the 501 produced by (a) a capability check **before** the call, (b) an explicit `rescue NotImplementedError`, or (c) both?

**The answer is (a), and (b) is rejected on its merits — not merely unchosen.** Three reasons, in increasing order of force:

**1. `NotImplementedError` is not a `StandardError` (verified).** A controller's `rescue => e` will not catch it; ActiveJob's `retry_on`/`discard_on` default to `StandardError` and will not either. So a rescue-based design does not merely have a gap — **it silently does not work**, and the failure mode is precisely the 500 that §6 says not to produce. Anyone reaching for (b) must write `rescue NotImplementedError` explicitly, and the fact that they must is the first hint that they are catching the wrong kind of thing.

**2. A 501 there would be factually wrong.** 501 means *"this deployment can't do that."* But `Chunk#write` raising does **not** mean the deployment cannot accept uploads — **chunk mode accepts uploads all day**, through `Sync::Commit`'s two-phase presigned flow. It means *the caller used the wrong write path*. Answering 501 would tell the client a true-sounding lie and send them away instead of fixing the bug.

**3. A `rescue NotImplementedError` in a controller catches it from anywhere in the stack.** Verified: it is raised in five places, including `FileLayer.build` (an s3 misconfiguration), `ChunkStore`'s four abstract methods, and `Sync::RetentionPolicy`. Dressing **any** of those as "this deployment can't do that" would be actively misleading — and would swallow a boot-level misconfiguration into a routine-looking response.

**So: gate on capabilities before calling. `NotImplementedError` stays un-rescued, and that is a feature** — it is a programming error, it should be loud, and it should reach the error tracker rather than being laundered into a plausible HTTP status. This is also what `Capabilities` is *for*, and Phase 4 is where it acquires its first consumer (verified: it has none today).

**Where the honest 501s actually are — and they are not where the question implied:**

| Surface | Why 501 | Mechanism |
|---|---|---|
| `GET /v1/nodes/:id/versions` in share mode | today it returns `{versions: []}` — *"this file has no history"*, a lie. It has no history **because this deployment has none**. | `versioned?` gate |
| `POST /v1/nodes/:id/restore`, conflicts, locks, devices/pairing, changes, commits, tree | the sync surface; spec §3.3 says it is mounted **only in chunk mode** | `syncable?` / `versioned?` gate |
| `POST /files/begin_upload` in share mode | there is no chunk store to presign into | `port_writable?` gate |
| `POST /files` (direct) in chunk mode | §15: chunk mode genuinely **cannot** take bytes through Rails. An architectural constraint, not a bug. | `port_writable?` gate |

Note what these have in common and what the `Chunk#write` case does not: **every one of them is a request for a capability the deployment truly lacks, and none of them involves `NotImplementedError` at all.** The v1 sync controllers never touch `FileLayer`. The two 501s are *honest*; a 501 from a rescued `Chunk#write` would not be.

---

## The `port_writable` capability

**It answers exactly one question, for exactly one caller: which upload flow does the UI drive?**

- `true` → POST the bytes to the port (`FileLayer#write`). Share, S3.
- `false` → drive `Sync::Commit`'s two-phase flow. Chunk.

**It is NOT "can this deployment accept uploads."** Chunk mode can, and naming it that way would hide the upload button in **the product's main deployment** — a straightforward bug, and an easy one to ship, since "writable" reads like it means "accepts uploads."

**Why not derive it from `syncable?`** (chunk is syncable; share/s3 are not, so the correlation is exact today, and the correlation is even *causal* — the two-phase flow exists **because** of sync): because it is an inference chain — *syncable → the sync engine owns writes → the port refuses* — and inference chains break silently. §9a-3 already lodges this complaint against `presignable` ("two mechanisms, two places"). One explicit answer beats a correct guess.

**And the drift is real, which is the point of Task 1.** `Capabilities` is a hand-written `Data` literal per adapter. Nothing mechanically ties `port_writable: false` to `write` actually raising, or `presignable: true` to the store actually presigning. So Task 1 does not just add a field — **it makes the read contract assert every capability against what the adapter really does**, on every adapter, forever. That is the only reason to trust a hardcoded boolean.

---

## Cross-task landmines

2a's two worst defects were **cross-task** — each commit fine alone, broken in combination, invisible to per-task review. These are Phase 4's.

### Landmine 1 — a capability that drifts from the adapter is worse than no capability

`Capabilities` is three (soon four) hardcoded booleans per adapter, **with zero consumers today** (verified). The moment Phase 4 gates the UI on them, a wrong boolean stops being inert documentation and becomes **a feature that silently disappears** — or, worse, one that is offered and then fails.

The drift is already latent and the spec already saw it (§9a-3): `Chunk` hardcodes `presignable: true` while `Chunk.fetch` **separately** duck-types the same question with `respond_to?`. Two mechanisms, two places, and §9a-4 notes the sniffing *fails open* — "if `S3ChunkStore` ever gains a `read`, the presign path is silently bypassed with no test failing."

(Verified, and worth stating so nobody over-corrects: `presignable: true` is **accurate today** — all three chunk stores implement `presign_get`. It is a latent bug, not a live one. Do not "fix" it into a live one.)

**Therefore Task 1 pins every capability to observed behavior in the shared READ contract** — which every adapter runs, which is the whole anti-divergence mechanism. Not a Chunk test, not a Share test: the contract. **Pinned in Task 1.** Cross-task shape: the capability task and the view task are each fine alone; the drift only shows when a *fourth* adapter, or a changed store, makes a boolean false without anyone touching the view that reads it.

### Landmine 2 — the escape guard, relocated to the controller layer

`Delivery::SendFile(path)` hands an **absolute filesystem path** to a controller that then hands it to `send_file`. The guard against `../../etc/passwd` lives in **`Share#absolute_path`** — and `Delivery::SendFile` is a `Data` object **anyone can construct with anything**. The type carries no guarantee.

Two ways the guard is lost, and they pull in opposite directions:
1. **The controller builds a path itself** (from `params`, from `node.storage_path`) — traversal is back, and the guard in the adapter is bypassed entirely.
2. **The controller re-validates** — now there are two guards in two places, which is §9a-3's complaint again, and the second one will drift.

**The rule: the controller must never construct or validate a path. `download` is the only producer of `SendFile`, and it resolves through `absolute_path` — the same single choke point `read` uses.** The controller only consumes.

**Is `storage_path` ever attacker-controlled?** Today, no: it is written by our own observer (a walk under the root) or by `Share#write` (already guarded). **But it is a plain DB column**, and 2b's `write` takes a `name` from the UI. The guard in `absolute_path` is the only thing standing there, and "no caller passes anything bad today" is precisely the assumption that ages badly. **Pinned in Task 4** by poisoning the row directly (`update_column`, which bypasses validation — a row a future bug could produce) and asserting `download` raises rather than returning a `Delivery`.

### Landmine 3 — the S3 redirect silently drops the disposition policy

`blob` today carefully forces every non-allowlisted type to `disposition: attachment` and sets `X-Content-Type-Options: nosniff` — notably for **SVG and HTML**, which the browser would otherwise execute.

**A `Redirect(url)` bypasses every one of those headers.** The browser leaves for the bucket and gets whatever `Content-Type` the object carries, and `?download=1` — the UI's own control — is silently ignored. **The same UI button behaves differently depending on the deployment's backend**, which is exactly the divergence the contracts exist to prevent.

**Be honest about the severity, because overselling it is how a plan gets ignored:** this is **not** stored XSS against the app session. The redirect goes to the bucket's origin (`s3.amazonaws.com`, R2, the user's SeaweedFS), so an SVG executes *there*, not in our origin. The real defect is **behavioral parity** — and, in a self-host that fronts the bucket on a sibling domain, a defense-in-depth gap.

**The fix is nearly free and verified:** a presigned GET can carry **signed** `response-content-disposition` / `response-content-type` overrides. So the **controller owns the policy** (which disposition, per `SAFE_INLINE_TYPES`) and the **adapter owns the mechanism** (a signed URL param, a response header, or a stream header). **Pinned in Task 3.**

### Landmine 4 — `send_file`, and a test that proves nothing

Verified from `rack-3.2.6/lib/rack/sendfile.rb`:
- Acceleration only engages when the body **responds to `to_path`**. `send_file` produces such a body; **`send_data` does not**. So a `send_data` implementation would **never accelerate, forever, silently** — and a test asserting `response.body == contents` would pass the whole time. A textbook test-that-cannot-fail.
- When it does engage, **`Content-Length: 0` and the body is replaced with `[]`**. So "sent the header" and "served the bytes" are **mutually exclusive**: a test asserting only the header passes while serving nothing; a test asserting only the bytes passes while never accelerating. **You need both, in two tests, with the header toggled.**
- `x-accel-redirect` additionally requires an **`x-accel-mapping`** header from nginx. Without it, Rack logs `"x-accel-mapping header missing"` to `rack.errors` and **serves the bytes normally** — it fails *safe*, and *silently*.

**And the answer to "what happens when it isn't configured": on this deployment it is never configured, and never will be.** There is **no nginx** — deployment is Kamal + kamal-proxy (a Go proxy), and `x_sendfile_header` is nil (both verified). `Rack::Sendfile` is in the stack and no-ops. **The `else Rack::Files` branch of spec §3.2's table is the only branch that runs.**

**Therefore: do not hand-roll X-Accel. Call `send_file` and let Rails' existing `config.action_dispatch.x_sendfile_header` do it.** That satisfies §3.2's "when configured, else `Rack::Files`" **exactly**, via the mechanism Rails already ships, and adds no speculative code for a proxy this deployment does not have. Writing our own header emitter for an untestable path is precisely what 2a's post-mortem punishes. **Pinned in Task 5**, which tests both modes and documents the operator knob.

### Landmine 5 — fixing `blob` while `show` keeps lying

`blob` is not the only chunk-mode assumption in the UI. Verified in `show.html.erb`: `@version = @node.current_version` is **nil in share mode**, so the page renders **Size "—"**, **Current version "—"**, and — the worst one — **"No content yet."** for a file that is sitting on the user's NAS with bytes in it. `index` builds `@versions_by_node` from `current_user.versions`, which is empty.

So a Phase 4 that fixes only `blob` ships a page that says the file is empty next to a Download button that works. Each task is fine alone; the combination is incoherent. **Pinned in Task 6**, which routes the views through `FileLayer#stat` (backend-neutral by construction) rather than `Version`.

---

## File structure

| File | Responsibility |
|---|---|
| `app/services/file_layer/capabilities.rb` (modify) | `port_writable` |
| `app/services/file_layer/delivery.rb` (create) | `Redirect` / `SendFile` / `Stream` |
| `app/services/file_layer/chunk.rb` (modify) | `download` → `Stream`, or `Redirect` for the case `blob` already redirects |
| `app/services/file_layer/share.rb` (modify) | `download` → `SendFile`, through `absolute_path` |
| `app/services/file_layer/s3.rb` (modify) | `download` → `Redirect`, with signed disposition overrides |
| `app/controllers/files_controller.rb` (modify) | consume `Delivery`; branch the upload; read the port |
| `app/controllers/concerns/library_capabilities.rb` (create) | the gate + the 501 |
| `app/controllers/v1/*_controller.rb` (modify) | the gate, per the Task 7 audit |
| `app/views/files/{index,show}.html.erb` (modify) | read capabilities; stop reading `Version` |
| `test/services/file_layer/adapter_contract.rb` (modify) | **capabilities pinned to behavior** |
| `test/services/file_layer/{chunk,share,s3}_test.rb` (modify) | `download` per backend |
| `test/integration/web/files_flow_test.rb` (modify) | chunk-mode delivery unchanged |
| `test/integration/web/share_delivery_test.rb` (create) | share delivery + acceleration + the escape guard |
| `test/integration/v1/capability_gating_test.rb` (create) | the 501s |

---

### Task 1: `port_writable`, and capabilities pinned to behavior

**Why first:** it is the seam decision, and Landmine 1. A capability nothing verifies is a comment with a `?` on the end.

**Files:**
- Modify: `app/services/file_layer/capabilities.rb`, `{chunk,share,s3}.rb`
- Modify: `test/services/file_layer/adapter_contract.rb`

- [ ] **Step 1: Read `test/services/file_layer/adapter_contract.rb` in full, and enumerate.**

You are **replacing** `test_contract_capabilities_answers_all_three_questions`, not appending beside it. **Read it first and account for it** — 2a's worst rework came from a test-move list that undercounted its source by two cases, one a tenant-isolation test that would have been silently deleted.

- [ ] **Step 2: Write the failing contract tests**

In `adapter_contract.rb`, replace the three-questions test with:

```ruby
  def test_contract_capabilities_answers_every_question
    caps = adapter.capabilities
    assert_includes [ true, false ], caps.versioned?
    assert_includes [ true, false ], caps.syncable?
    assert_includes [ true, false ], caps.presignable?
    assert_includes [ true, false ], caps.port_writable?
  end

  # LANDMINE 1. Capabilities are four hand-written booleans per adapter, and until Phase 4
  # nothing read them -- so nothing noticed if they were wrong. Now the UI hides features on
  # them and the API returns 501 on them, so a wrong boolean is a feature that silently
  # vanishes, or one that is offered and then fails.
  #
  # Nothing mechanically ties `port_writable: false` to `write` actually raising. This does.
  # It lives in the READ contract -- which EVERY adapter runs -- rather than in any one
  # adapter's test, because "the adapters cannot diverge" is the contract's whole job.
  #
  # The spec predicted this drift for `presignable` (9a-3: "answered statically but is a
  # property of the store", with Chunk.fetch duck-typing the same question elsewhere). This
  # is the mechanism that would have caught it.
  def test_contract_port_writable_agrees_with_what_write_actually_does
    if adapter.capabilities.port_writable?
      info = adapter.write(@user, parent_node_id: nil, name: "caps.stl", io: StringIO.new("w"))
      assert_equal "w", adapter.read(@user, node_id: info.node_id),
                   "port_writable? is true, so the port's write path must actually work"
    else
      err = assert_raises(NotImplementedError) do
        adapter.write(@user, parent_node_id: nil, name: "caps.stl", io: StringIO.new("w"))
      end
      # Assert the MESSAGE, not just the class: NotImplementedError is reachable from five
      # places in this codebase (FileLayer.build, ChunkStore's abstract methods,
      # Sync::RetentionPolicy), so the class alone would let an unrelated raise satisfy this.
      assert_match(/Sync::Commit/, err.message,
                   "a refusal must name the path the caller SHOULD use")
    end
  end

  # The same pin for delete/move, so an adapter cannot answer port_writable? true and then
  # refuse half the path -- which would be a Delivery-shaped 500 in Phase 4's UI.
  def test_contract_port_writable_agrees_with_what_delete_and_move_actually_do
    return if adapter.capabilities.port_writable?

    [ -> { adapter.delete(@user, node_id: "n1") },
      -> { adapter.move(@user, node_id: "n1", new_parent_node_id: nil, new_name: "y.stl") } ].each do |op|
      err = assert_raises(NotImplementedError) { op.call }
      assert_match(/Sync::Commit/, err.message)
    end
  end

  # presignable? is the store's property, not the adapter's opinion (spec 9a-3). This does not
  # fix that -- it pins the claim to something observable, so a future divergence fails a test
  # instead of silently disabling a UI affordance.
  #
  # NOTE what this does NOT assert: that a presignable adapter DELIVERS by redirect. Those are
  # different questions -- see Task 2. Chunk is presignable on all three stores, but two of
  # them presign to URLs Rails itself serves.
  def test_contract_presignable_is_not_merely_asserted
    caps = adapter.capabilities
    return unless caps.presignable?
    id = create_file!(name: "presign.stl", bytes: "p")
    assert adapter.download(@user, node_id: id, disposition: "attachment"),
           "a presignable adapter must be able to produce a Delivery"
  end
```

- [ ] **Step 3: Run and watch it fail**

Run: `bin/rails test test/services/file_layer/`
Expected: `NoMethodError: undefined method 'port_writable?'` on all three adapters.

- [ ] **Step 4: Implement**

**Constraints:**
- `Capabilities = Data.define(:versioned, :syncable, :presignable, :port_writable)` + a `port_writable?` reader. **Every construction site must be updated** — `Data.define` has no defaults, so a missed one is an `ArgumentError` at construction. That is the good failure; do not paper over it with a default.
- `Chunk`: `port_writable: false`. `Share`: `true`. `S3`: `true`.
- The comment on the field must say what it is **not**: not "this deployment accepts uploads" — chunk mode does, via `Sync::Commit`. It is *which upload flow the UI drives*. Getting that wrong hides upload in the product's main deployment.
- **Do not** derive it from `syncable?`. Argued above.
- `download` does not exist until Task 2, so `test_contract_presignable_is_not_merely_asserted` stays red. **Correct for this task; do not stub `download` to go green.**

- [ ] **Step 5: Prove the pin is real (mutation)**

Flip `Chunk`'s `port_writable` to `true`. `test_contract_port_writable_agrees_with_what_write_actually_does` must fail — proving the contract catches a capability that lies about its adapter. Byte-exact abort-if-unchanged guard; `grep -c` with an expected count; **revert by file backup + `cmp`, never `git checkout`.** **Report.**

- [ ] **Step 6: Full suite + commit** — report ACTUAL counts for all three legs.

```bash
git add app/services/file_layer/capabilities.rb app/services/file_layer/chunk.rb \
        app/services/file_layer/share.rb app/services/file_layer/s3.rb \
        test/services/file_layer/adapter_contract.rb
git commit -m "$(cat <<'EOF'
feat(file-layer): capabilities gain port_writable, and are pinned to what adapters do

port_writable answers exactly one question for exactly one caller: which upload flow does the
UI drive? It is NOT "can this deployment accept uploads" -- chunk mode accepts uploads all day
through Sync::Commit's two-phase presigned flow, and naming it that way would hide the upload
button in the product's main deployment. It is not derived from syncable? either: the
correlation is exact and even causal today, but an inference chain breaks silently, and one
explicit answer beats a correct guess.

The bigger half is the contract. Capabilities were four hand-written booleans per adapter with
ZERO consumers, so nothing noticed if one was wrong. Phase 4 makes the UI hide features on them
and the API return 501 on them, and a static boolean is only trustworthy if something checks
it. The read contract -- which every adapter runs -- now asserts each capability against
observed behavior. The spec predicted exactly this drift for presignable (9a-3); this is the
mechanism that would have caught it.

The refusal assertions match the MESSAGE, not just the class: NotImplementedError is reachable
from five places in this codebase, so the class alone would let an unrelated raise pass.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
)"
```

---

### Task 2: `Delivery` + `download` on all three adapters

**Files:**
- Create: `app/services/file_layer/delivery.rb`
- Modify: `app/services/file_layer/{chunk,share,s3}.rb`
- Modify: `test/services/file_layer/{chunk,share,s3}_test.rb`

- [ ] **Step 1: Read `FilesController#blob` in full first.** Its behavior is the specification for `Chunk#download`: this task must **preserve it exactly**, including the single-chunk S3 redirect. Anything else is a regression wearing a refactor.

- [ ] **Step 2: Write the failing tests**

In `chunk_test.rb`:

```ruby
    # Chunk's delivery is today's stitched-chunk enumerator, unchanged. The bytes come from
    # presigned GETs per chunk -- Rails stitches, but never holds the whole file.
    test "download streams the stitched chunks" do
      id = create_file!(name: "s.stl", bytes: "streamed")
      d = adapter.download(@user, node_id: id, disposition: "attachment")
      assert_kind_of FileLayer::Delivery::Stream, d
      assert_equal "streamed", d.enum.to_a.join
    end

    # PRESERVED FROM #blob, exactly: a single-chunk file on real object storage redirects the
    # browser straight to storage. This is not the `presignable?` question -- the memory and
    # local stores presign too, but to URLs Rails itself serves, so redirecting to them would
    # move the bytes through Rails via an extra hop. The condition is "does the presigned URL
    # point OFF-BOX", which is a third question, and today only S3ChunkStore answers it yes.
    test "a single-chunk file on real object storage redirects, as blob already did" do
      with_s3_chunk_store do
        id = create_file!(name: "one.stl", bytes: "single")
        d = adapter.download(@user, node_id: id, disposition: "attachment")
        assert_kind_of FileLayer::Delivery::Redirect, d
      end
    end

    test "download raises NotFound for a deleted node, exactly as read does" do
      id = create_file!(name: "gone.stl", bytes: "b")
      delete_file!(id)
      assert_raises(FileLayer::NotFound) { adapter.download(@user, node_id: id, disposition: "attachment") }
    end
```

`with_s3_chunk_store` does not exist. **Read `chunk_test.rb`'s existing `PresignOnlyStore` / `with_http_get_raising` helpers and match their idiom** rather than inventing a second one. If a single-chunk S3 redirect cannot be staged cheaply, **say so and drop the test rather than ship a permanent skip that reads as coverage** (2b's rule).

In `share_test.rb`:

```ruby
    test "download hands back the absolute path, resolved through the escape guard" do
      id = create_file!(name: "d.stl", bytes: "bytes")
      d = adapter.download(@user, node_id: id, disposition: "attachment")
      assert_kind_of FileLayer::Delivery::SendFile, d
      assert_equal @root.join("d.stl").to_s, d.path
      assert File.exist?(d.path)
    end

    # LANDMINE 2. Delivery::SendFile is a Data object anyone can construct with any path, so
    # the TYPE carries no guarantee -- the guard has to live at the only place that PRODUCES
    # one. update_column bypasses validation: a poisoned row, of the shape a future bug could
    # produce. download must refuse rather than hand a controller a path outside the root.
    test "download refuses a storage_path that escapes the root" do
      id = create_file!(name: "d.stl", bytes: "bytes")
      @user.nodes.find_by!(node_id: id).update_column(:storage_path, "../../../etc/passwd")
      assert_raises(FileLayer::NotFound) { adapter.download(@user, node_id: id, disposition: "attachment") }
    end

    test "download raises NotFound for a deleted node" do
      id = create_file!(name: "gone.stl", bytes: "b")
      delete_file!(id)
      assert_raises(FileLayer::NotFound) { adapter.download(@user, node_id: id, disposition: "attachment") }
    end
```

In `s3_test.rb`:

```ruby
    test "download presigns a GET - the bytes never touch Rails" do
      id = create_file!(name: "p.stl", bytes: "presigned")
      d = adapter.download(@user, node_id: id, disposition: "attachment")
      assert_kind_of FileLayer::Delivery::Redirect, d
      assert_includes d.url, "X-Amz-Signature", "it must be a signed URL, not a bare object URL"
      assert_includes d.url, "#{PREFIX}/p.stl"
    end

    # LANDMINE 3. A redirect bypasses every header the controller sets -- including the
    # attachment disposition that blob forces for SVG and HTML, and the ?download=1 control.
    # Without this, the SAME UI button behaves differently depending on the deployment's
    # backend, which is the divergence the contracts exist to prevent. The override is signed
    # into the URL, so it is tamper-proof.
    test "the disposition policy is SIGNED INTO the presigned URL, not silently dropped" do
      id = create_file!(name: "evil.svg", bytes: "<svg onload=alert(1)>")
      d = adapter.download(@user, node_id: id, disposition: "attachment", content_type: "application/octet-stream")
      assert_includes d.url, "response-content-disposition"
      assert_includes d.url, "response-content-type"
    end

    test "an inline disposition is honored too - the policy is the caller's, not the adapter's" do
      id = create_file!(name: "ok.png", bytes: "\x89PNG".b)
      d = adapter.download(@user, node_id: id, disposition: "inline", content_type: "image/png")
      assert_includes CGI.unescape(d.url), "inline"
    end

    test "download refuses a storage_path that escapes the prefix" do
      id = create_file!(name: "a.stl", bytes: "b")
      @user.nodes.find_by!(node_id: id).update_column(:storage_path, "../../etc/passwd")
      assert_raises(FileLayer::NotFound) { adapter.download(@user, node_id: id, disposition: "attachment") }
    end
```

- [ ] **Step 3: Run to see them fail.**

- [ ] **Step 4: Implement**

**Constraints:**
- `app/services/file_layer/delivery.rb`: `module Delivery` holding `Redirect = Data.define(:url)`, `SendFile = Data.define(:path)`, `Stream = Data.define(:enum)`. Nothing else — the disposition/content-type are **applied**, not carried, because each transport applies them differently.
- **The signature is `download(user, node_id:, disposition:, content_type: nil) -> Delivery`.** This is a **deliberate deviation from spec §3.2**, which lists `download(user, node_id:)`. Flagged so it is a decision, not a smuggled API — the same way 2b flagged `undelete`. The reason is Landmine 3: a `Redirect` must sign the disposition into the URL, so it must know it at mint time, and only the controller knows the policy (`SAFE_INLINE_TYPES` is a web concern, not a storage one). **The controller owns the policy; the adapter owns the mechanism.** If you disagree, argue it before implementing.
- `Chunk#download`: **preserve `blob`'s behavior exactly** — `Redirect` when `chunks.size == 1 && store.is_a?(Storage::S3ChunkStore)`, else `Stream` wrapping the same enumerator `blob` builds today. **Move the logic; do not improve it.**
  - **Do not** rewrite that `is_a?` into `capabilities.presignable?`. Verified: all three chunk stores presign, but memory/local presign to URLs **Rails itself serves** — so `presignable?` is a *different question* and substituting it would redirect the browser on a pointless round-trip through us. §9a-3/§9a-4's cleanup is real and stays deferred; **Phase 4 does not force it**, and this is why. Say so in the comment or the next reader will "simplify" it.
- `Share#download`: `SendFile(absolute_path(node).to_s)` — through **the same `absolute_path`** `read` uses. Not a copy. Landmine 2.
- `S3#download`: `Redirect` from a presigned GET carrying `response_content_disposition` (with the filename) and `response_content_type`. Presigning is **local HMAC** — no network (verified).
- **Every `download` applies the same liveness guard `read` does** (`live_node!`). A tombstoned node is gone on every backend; `download` must not be the hole in that.
- `download` does **not** read bytes. `Stream`'s enumerator is lazy — that is what keeps a 2GB file off the Rails heap, and it is why `MAX_BYTES` (a `read` concern) does not apply here.

- [ ] **Step 5: Full suite + commit** — report ACTUAL counts for all three legs.

---

### Task 3: `FilesController#blob` through `Delivery`

**This is the task that fixes share/s3 downloads.** Verified: `blob` 404s in share mode today (`node.current_version` is nil → `RecordNotFound`). That is correct-by-scope in 2a/2b; this is where it is paid off.

**Files:**
- Modify: `app/controllers/files_controller.rb`
- Modify: `test/integration/web/files_flow_test.rb`
- Create: `test/integration/web/share_delivery_test.rb`

- [ ] **Step 1: Read `test/integration/web/files_flow_test.rb` in full.** It is the chunk-mode delivery regression suite (SVG/HTML served as attachments — the stored-XSS guards). **Those tests must still pass, unmodified.** If one needs changing, that is a regression, not a test problem.

- [ ] **Step 2: Write the failing test**

Create `test/integration/web/share_delivery_test.rb`:

```ruby
require "test_helper"

module Web
  # Share-mode byte delivery through the real controller. Verified before this task: blob 404s
  # in share mode -- node.current_version is nil, so it raises RecordNotFound. That was correct
  # by scope in 2a/2b; this is where it is paid off.
  class ShareDeliveryTest < ActionDispatch::IntegrationTest
    PASSWORD = "correct horse battery staple".freeze

    setup do
      @root = Pathname.new(Dir.mktmpdir("share-delivery"))
      @user = User.create!(email: "sd-#{SecureRandom.hex(4)}@example.com",
                           password: PASSWORD, confirmed_at: Time.current)
      FileLayer.current = FileLayer::Share.new(root: @root.to_s)
      post user_session_path, params: { user: { email: @user.email, password: PASSWORD } }
    end
    teardown do
      FileLayer.reset!
      FileUtils.remove_entry(@root) if @root&.exist?
    end

    def index!(rel, bytes)
      path = @root.join(rel)
      FileUtils.mkdir_p(path.dirname)
      File.binwrite(path, bytes)
      Library::Scanner.call(@user, root: @root.to_s, max_delete_pct: 100)
      @user.nodes.find_by!(storage_path: rel).node_id
    end

    test "a share-backed file downloads -- it used to 404" do
      id = index!("bracket.stl", "solid bracket")
      get blob_file_path(id)
      assert_response :success
      assert_equal "solid bracket", response.body
    end

    test "the filename reaches the browser" do
      id = index!("bracket.stl", "solid")
      get blob_file_path(id, download: 1)
      assert_match(/attachment/, response.headers["Content-Disposition"])
      assert_match(/bracket\.stl/, response.headers["Content-Disposition"])
    end

    # The stored-XSS policy is the CONTROLLER's and must not vary by backend. These mirror
    # files_flow_test.rb's chunk-mode cases exactly -- the same button, the same answer.
    test "an SVG is served as an attachment on the share backend too" do
      id = index!("evil.svg", "<svg onload=alert(1)></svg>")
      get blob_file_path(id)
      assert_match(/attachment/, response.headers["Content-Disposition"])
      assert_equal "nosniff", response.headers["X-Content-Type-Options"]
    end

    test "an HTML file is served as an attachment on the share backend too" do
      id = index!("evil.html", "<script>alert(1)</script>")
      get blob_file_path(id)
      assert_match(/attachment/, response.headers["Content-Disposition"])
    end

    test "a PNG is served inline, as it is in chunk mode" do
      id = index!("ok.png", "\x89PNG\r\n\x1a\n".b)
      get blob_file_path(id)
      assert_match(/inline/, response.headers["Content-Disposition"])
    end

    test "another user's node is 404, never their bytes" do
      id = index!("mine.stl", "secret")
      other = User.create!(email: "o-#{SecureRandom.hex(4)}@example.com",
                           password: PASSWORD, confirmed_at: Time.current)
      delete destroy_user_session_path
      post user_session_path, params: { user: { email: other.email, password: PASSWORD } }

      get blob_file_path(id)
      assert_not_equal "secret", response.body, "a node lookup must be scoped to current_user"
    end

    # A node whose bytes vanished from the NAS: the row is there, the file is not. It must be
    # a clean 404, not a 500 -- and it must not leak the absolute path of the library root.
    test "a node whose file vanished is a clean 404, and leaks no path" do
      id = index!("vanishing.stl", "b")
      File.unlink(@root.join("vanishing.stl"))
      File.binwrite(@root.join("other.stl"), "so the library does not look unmounted")

      get blob_file_path(id)
      assert_response :redirect # rescue_from RecordNotFound redirects for HTML -- verify
      assert_not_includes response.body.to_s, @root.to_s, "never leak the library root"
    end
  end
end
```

**On `FileLayer.current = …` — there are already TWO idioms for this and you must pick deliberately rather than invent a third.** Verified:

| Idiom | Where | Mechanism |
|---|---|---|
| `pin_file_layer_backend(name)` | `test_helper.rb:52`, on `ActiveSupport::TestCase` (so integration tests inherit it). Used by `previews_test.rb`, `generate_preview_job_test.rb`, `file_bytes_test.rb`. | sets `ENV["LIBRARY_BACKEND"]` + `FileLayer.reset!`; **a teardown restores it** |
| `FileLayer.current = <adapter>` | `file_bytes_test.rb:30` — injects a fake | the factory's `attr_writer :current` |
| `with_backend(value)` | `factory_test.rb:68`, block-scoped, local to that file | same ENV mechanism |

The tests above use the **second** because they need a **tmpdir root**, and `pin_file_layer_backend("share")` rebuilds from ENV — so it would also need `ENV["LIBRARY_PATH"] = @root.to_s`, which its teardown does **not** restore. Both are defensible. **Whichever you choose, say why in your report**, and note the trap in the one you did not: a direct `FileLayer.current =` does **not** set `@file_layer_backend_pinned`, so `test_helper.rb`'s teardown will **not** clean up after it — the explicit `FileLayer.reset!` in the `teardown` above is load-bearing, not decoration. Delete it and the adapter leaks into the next test in that forked worker, where it will fail as something unrelated.

The last test asserts `:redirect` because `rescue_from ActiveRecord::RecordNotFound` redirects for HTML (verified). **Confirm the actual status before trusting this line** — if `download` raises `FileLayer::NotFound` rather than `RecordNotFound`, nothing rescues it and you get a 500. **That is a real finding if it happens: report it and decide where the mapping belongs.**

- [ ] **Step 3: Run to see them fail.**

- [ ] **Step 4: Implement**

**Constraints:**
- `blob` computes its policy exactly as today (`SAFE_INLINE_TYPES`, `?download=1`, `nosniff`, the `Content-Disposition` format), then calls `FileLayer.current.download(current_user, node_id: params[:id], disposition:, content_type:)` and dispatches on the variant:
  - `Redirect` → `redirect_to url, allow_other_host: true`. **Do not set Content-Disposition on this branch** — it is a header on a 302 and the browser ignores it; the policy is signed into the URL instead (Task 2). The asymmetry is real; comment it.
  - `SendFile` → `send_file path, ...` (Task 5 owns the details).
  - `Stream` → `self.response_body = enum`, headers as today.
- **The controller must never construct or validate a path.** Landmine 2. It receives `SendFile.path` and passes it on. If you find yourself writing `File.join`, `Pathname`, or a `..` check in this controller, **stop** — the guard belongs in `Share#absolute_path`, and a second copy is §9a-3's complaint reborn.
- `FileLayer::NotFound` → 404, in the same shape `RecordNotFound` already produces. **Decide where**: a `rescue_from FileLayer::NotFound` on `FilesController`, or mapping at the call site. Say which and why. Note `FileLayer::NotFound` **is** a `StandardError` (unlike `NotImplementedError`), so `rescue_from` works on it.
- Keep the header's §15 comment **true**. It currently describes the chunk-mode presign path; share now streams through Rails, which is spec §2 decision 6, deliberate and scoped to storage we do not own. **Update the comment to say so** — an invariant note that has quietly become false is worse than none.

- [ ] **Step 5: Prove chunk mode did not regress**

Run `bin/rails test test/integration/web/files_flow_test.rb` — unmodified, green. This is the regression gate for a refactor of the byte path. Report ACTUAL.

- [ ] **Step 6: Full suite + commit** — all three legs.

---

### Task 4: The escape guard, pinned at the controller layer

**Files:**
- Modify: `test/integration/web/share_delivery_test.rb`

Task 2 pinned the guard at the adapter. **This pins that the controller did not re-introduce it** — the two are different claims, and Landmine 2 is that only the first is obvious.

- [ ] **Step 1: Write the test**

```ruby
    # LANDMINE 2, at the layer it actually moved to. Task 2 pins that Share#download refuses a
    # poisoned path. This pins the OTHER half: that the controller does not resolve one itself.
    # The guard lives in exactly one place -- Share#absolute_path -- and a controller that
    # builds or re-validates a path either bypasses it or becomes a second copy that drifts.
    test "a poisoned storage_path cannot be downloaded through the controller" do
      id = index!("innocent.stl", "b")
      File.binwrite(@root.join("decoy.stl"), "so the library does not look unmounted")
      @user.nodes.find_by!(node_id: id).update_column(:storage_path, "../../../etc/passwd")

      get blob_file_path(id)

      assert_not_equal File.read("/etc/passwd"), response.body, "traversal must not serve"
      assert_not_includes response.body.to_s, "root:", "and must not leak /etc/passwd's contents"
    end

    # An absolute storage_path is the same attack with a different spelling: root.join("/etc/x")
    # in Pathname yields "/etc/x", NOT root + "/etc/x". A guard testing only for ".." misses it.
    test "an ABSOLUTE storage_path cannot be downloaded either" do
      id = index!("innocent2.stl", "b")
      File.binwrite(@root.join("decoy2.stl"), "so the library does not look unmounted")
      @user.nodes.find_by!(node_id: id).update_column(:storage_path, "/etc/passwd")

      get blob_file_path(id)
      assert_not_includes response.body.to_s, "root:"
    end
```

The `decoy` writes are not decoration: `Share#read`'s `library_present?` turns an ENOENT in an **empty** root into a `FetchError` rather than a `NotFound` (spec §6 — an unmounted NAS must never read as a deletion). Without a decoy these tests could pass for the wrong reason. **A test that passes for the wrong reason is 2a's most repeated defect.**

- [ ] **Step 2: Run.** If either fails, **that is a real vulnerability — report it immediately** rather than adjusting the test.

- [ ] **Step 3: Prove the guard is real (mutation)**

Remove the escape check from `Share#absolute_path`. **Both** tests must fail. Byte-exact guard; revert by backup + `cmp`. **Report.** A guard nobody has watched fail is a guard nobody knows is wired up.

- [ ] **Step 4: Commit.**

---

### Task 5: `send_file` and acceleration — two tests, because one proves nothing

**Files:**
- Modify: `app/controllers/files_controller.rb`, `test/integration/web/share_delivery_test.rb`
- Modify: `config/environments/production.rb` (a **commented** knob + the operator note)

- [ ] **Step 1: Read the facts before writing code.** Verified from `rack-3.2.6/lib/rack/sendfile.rb:130-160` and from this deployment:
  - There is **no nginx**. Deployment is **Kamal** (kamal-proxy). `x_sendfile_header` is **nil**. `Rack::Sendfile` is in the stack and **no-ops**. **The un-accelerated branch is the only one that runs here.**
  - Acceleration engages only when the body **responds to `to_path`** — `send_file` yes, **`send_data` never**.
  - When it engages: **`Content-Length: 0`, body replaced with `[]`**.
  - `x-accel-redirect` **also** needs an `x-accel-mapping` header from nginx; without it Rack logs to `rack.errors` and **serves normally** — fails safe, silently.

  **So: do not hand-roll X-Accel.** `send_file` + Rails' existing `config.action_dispatch.x_sendfile_header` **is** spec §3.2's "X-Accel-Redirect / X-Sendfile when configured, else `Rack::Files`", implemented by the mechanism Rails already ships. Writing a header emitter for a proxy we do not have is the speculative code 2a's post-mortem punishes.

- [ ] **Step 2: Write both tests**

```ruby
    # Two tests, because either alone proves nothing. When Rack::Sendfile accelerates it sets
    # Content-Length: 0 and REPLACES THE BODY WITH [] -- so "sent the header" and "served the
    # bytes" are mutually exclusive. A test asserting only the header passes while serving
    # nothing; a test asserting only the bytes passes while never accelerating.
    #
    # The nastiest version: send_data never accelerates at all (no to_path), so a send_data
    # implementation would pass the bytes test forever while the header silently never fired.
    test "with no x_sendfile_header configured -- this deployment -- Rails serves the bytes" do
      id = index!("plain.stl", "real bytes")
      get blob_file_path(id)
      assert_response :success
      assert_equal "real bytes", response.body,
                   "no proxy here (Kamal, not nginx): Rack::Files must actually serve"
    end

    # The accelerated path. x-sendfile is used rather than x-accel-redirect because Rack's
    # x-accel-redirect branch ALSO needs an x-accel-mapping header from nginx to translate the
    # filesystem path into an internal URI -- without it it logs and serves normally. That
    # asymmetry is the real X-Accel footgun, and it is why this is documented for the operator
    # rather than shipped as our own code.
    test "with x_sendfile_header configured, the proxy gets the path and the body is empty" do
      id = index!("accel.stl", "real bytes")
      prior = Rails.application.config.action_dispatch.x_sendfile_header
      begin
        # Rack::Sendfile reads env["sendfile.type"], which ActionDispatch sets from this config.
        # VERIFY this actually reaches the middleware in an integration test before trusting a
        # green: if it does not, this test passes for the wrong reason and pins nothing.
        Rails.application.config.action_dispatch.x_sendfile_header = "x-sendfile"
        get blob_file_path(id), headers: { "HTTP_X_SENDFILE_TYPE" => nil }

        assert_equal @root.join("accel.stl").to_s, response.headers["x-sendfile"],
                     "the proxy must be handed the real filesystem path"
        assert_empty response.body, "when accelerated, Rack replaces the body -- WE must not serve"
      ensure
        Rails.application.config.action_dispatch.x_sendfile_header = prior
      end
    end

    # to_path is the whole mechanism: no to_path, no acceleration, ever, silently. send_data
    # would pass every bytes test above while making acceleration permanently dead code.
    test "the body responds to to_path, which is what makes acceleration possible at all" do
      id = index!("topath.stl", "b")
      get blob_file_path(id)
      assert_response :success
    end
```

**The second test is the risky one and you must verify it rather than trust it.** `x_sendfile_header` is read at **request** time via `env["sendfile.type"]`, but whether mutating `Rails.application.config` mid-suite reaches `Rack::Sendfile` (which was constructed at boot with a `variation`) is **not obvious** — Rack's `variation(env)` returns `@variation || env['sendfile.type']`, so it depends on how ActionDispatch wires it. **If the mutation does not take effect, this test passes vacuously and pins nothing** — the exact defect 2a shipped eleven times.

**Verify it by mutation** (Step 4). If it cannot be made to fire, **delete the test and say so in your report** rather than ship a green that means nothing. Rack's own `variation` comment notes `HTTP_X_SENDFILE_TYPE` is *deliberately* not read (an attacker could enable x-accel-redirect and bypass proxy restrictions) — so do **not** reach for that as a workaround.

- [ ] **Step 3: Implement**

**Constraints:**
- `send_file path, type:, disposition:, filename:` — **`send_file`, never `send_data`**. `send_data` cannot accelerate (no `to_path`), and would make the whole mechanism silently dead.
- Keep `X-Content-Type-Options: nosniff` and the `SAFE_INLINE_TYPES` policy identical to the `Stream` branch. Same button, same answer, whatever the backend.
- In `config/environments/production.rb`, add the knob **commented out**, with a note: nginx front → `config.action_dispatch.x_sendfile_header = "x-accel-redirect"` **plus** an `internal` location and `proxy_set_header x-accel-mapping /mnt/nas/=/files/;`; Apache → `"x-sendfile"`. **Commented, because this deployment is kamal-proxy and enabling it here would silently serve empty bodies.** That last clause is the whole reason it stays commented — say it.

- [ ] **Step 4: Prove the accelerated test can fail (mutation)**

Change `send_file` to `send_data File.binread(path), ...`. The **accelerated** test must fail (no `to_path` → no header, and the body is non-empty), while the **un-accelerated** test still passes — **which is exactly the point**: it demonstrates that the bytes test alone would have let a never-accelerating implementation through. Byte-exact guard; revert by backup + `cmp`. **Report both outcomes.**

- [ ] **Step 5: Full suite + commit.**

---

### Task 6: The UI stops lying — capabilities + the port, not `Version`

**Files:**
- Modify: `app/controllers/files_controller.rb`, `app/views/files/{index,show}.html.erb`
- Modify/Create: the corresponding tests

- [ ] **Step 1: Read `app/views/files/show.html.erb` and `index.html.erb` in full and enumerate every chunk-mode assumption.** Verified starting points (there may be more — **find them, do not trust this list**):
  - `show`: `@version = @node.current_version` → **nil in share mode** → Size **"—"**, Current version **"—"**, and the preview block renders **"No content yet."** for a file with bytes on the user's NAS.
  - `index`: `@versions_by_node` from `current_user.versions` → **empty** in share/s3.

- [ ] **Step 2: Write the failing tests**

```ruby
    # LANDMINE 5. Fixing blob while show still says "No content yet." ships a page that calls
    # the file empty next to a Download button that works. The view reads Version -- a
    # chunk-mode concept -- so in share mode it renders the truth about the wrong thing.
    test "the show page reports the real size and does NOT say 'No content yet'" do
      id = index!("bracket.stl", "solid bracket")
      get file_path(id)
      assert_response :success
      assert_no_match(/No content yet/, response.body,
                      "the file has 13 bytes on the user's NAS")
      assert_match(/13 Bytes/i, response.body)
    end

    test "the show page offers no Restore or History on an unversioned backend" do
      id = index!("bracket.stl", "solid")
      get file_path(id)
      assert_no_match(/Restore/i, response.body, "share keeps no history -- do not offer it")
      assert_no_match(/Version history/i, response.body)
    end

    test "the index lists share-backed files" do
      index!("a.stl", "aaa")
      index!("cad/b.stl", "bbb")
      get files_path
      assert_response :success
      assert_match(/a\.stl/, response.body)
      assert_match(/b\.stl/, response.body)
    end
```

And in `files_flow_test.rb` (chunk mode) — the **counterpart**, which is what stops the gate over-firing:

```ruby
    # The other half of capability gating, and the one a plan forgets: chunk mode must KEEP
    # everything. A gate that hides a feature in share mode is half-right; a gate that hides
    # it in the product's main deployment is a straightforward bug -- and "port_writable"
    # reads like "accepts uploads", which chunk mode very much does.
    test "chunk mode still offers upload and version history" do
      sign_in
      node_id = upload("v.stl", "bytes")
      get file_path(node_id)
      assert_response :success
      assert_match(/Current version/i, response.body)

      get files_path
      assert_match(/upload/i, response.body, "chunk mode uploads via the two-phase flow -- do not hide it")
    end
```

- [ ] **Step 3: Run to see them fail.**

- [ ] **Step 4: Implement**

**Constraints:**
- `show`/`index` read `FileLayer.current.stat(...)` → `FileInfo` (`size`, `mtime`, `content_token`) instead of `Version`. **Backend-neutral by construction** — that is the port's whole job, and it is why this is not scope creep but the same fix as `blob`.
- Expose `FileLayer.current.capabilities` to the views by **one** named mechanism (a `helper_method`, or an `@capabilities` set in a `before_action`). **One**, not two — a view reaching for `FileLayer.current.capabilities` inline while a controller sets `@caps` is exactly how the two answers drift.
- **Prefer the form that raises.** `<% if @caps&.versioned %>` on a nil `@caps` is **silently falsy** — the feature disappears and no test necessarily notices. `<% if capabilities.versioned? %>` raises `NoMethodError` at render. `.erb` has no type checker; loud beats convenient. (Landmine 1's cousin, and the reason the "Learn from" section calls out views.)
- Gate on `versioned?` for Restore/History. **Do not gate the upload control on `versioned?` or `syncable?`** — it is `port_writable?`-or-the-two-phase-flow, and both are available; see Task 7.
- The `mtime` render already exists in `show` and is nanos-aware (`@node.mtime / 1_000_000_000`) — **verify it still is** after your change. Nanos-as-seconds has shipped for real twice in this codebase.

- [ ] **Step 5: Full suite + commit** — all three legs.

---

### Task 7: The upload branch + the 501s

**Files:**
- Create: `app/controllers/concerns/library_capabilities.rb`
- Modify: `app/controllers/files_controller.rb`, `app/controllers/v1/*`
- Create: `test/integration/v1/capability_gating_test.rb`

- [ ] **Step 1: Audit the v1 surface — do not trust this plan's list**

Spec §3.3: the sync surface is mounted **only in chunk mode**. The controllers are: `changes`, `chunks`, `commits`, `conflicts`, `devices`, `locks`, `nodes`, `search`, `share`, `share_links`, `trash`, `tree`, `test_users`, `maker/*`.

**Open each one and decide, per controller, what it actually does in share mode. Then write down your answer and your reason.** Starting hypotheses — **each is a hypothesis, not an instruction**:

| Controller | Hypothesis | Watch out |
|---|---|---|
| `changes`, `chunks`, `commits`, `tree`, `devices`, `locks`, `conflicts` | `syncable?` → 501 | pairing lives in `devices` — a share deployment has no devices at all |
| `nodes#versions`, `nodes#restore` | `versioned?` → 501 | today `versions` returns `{versions: []}` — **the lie §6 names** |
| `nodes` (create/update/delete/move) | `syncable?` → 501 | these are the sync engine's mutations, not the port's |
| `trash` | **undecided** | share HAS a trash (2b) but **this controller is the chunk trash** (tombstones + retained versions). Two different features, one name. **Decide deliberately.** |
| `search`, `maker/*` | **no gate** | the maker layer is the whole product in share mode — **gating these would break the phase's reason to exist** |
| `share`, `share_links` | **no gate** | **public links to a file** — unrelated to `FileLayer::Share`. See the naming warning. |
| `test_users` | no gate | test-only |

**If a controller's share-mode behavior surprises you, report it.** A wrong gate here either breaks the maker layer or ships the lie §6 exists to kill.

- [ ] **Step 2: Write the failing tests**

Create `test/integration/v1/capability_gating_test.rb`:

```ruby
require "test_helper"

module V1
  # Spec 6: "The API returns 501 Not Implemented (not 500) -- an honest 'this deployment can't
  # do that'." The gate is a capability check BEFORE the call, never a rescue: NotImplementedError
  # is not a StandardError (a bare rescue does not catch it), and a 501 for a chunk-mode
  # Chunk#write would be a lie anyway, since chunk mode accepts uploads via Sync::Commit.
  class CapabilityGatingTest < ActionDispatch::IntegrationTest
    setup do
      @root = Pathname.new(Dir.mktmpdir("gate"))
      # bootstrap_account is test_helper.rb's real device-auth idiom (it calls Device.register!
      # and hands back the plaintext token). Matched rather than reinvented: the v1 suites all
      # use it, and a second auth idiom in the same API is a divergence.
      @account = bootstrap_account(email: "gate-#{SecureRandom.hex(4)}@example.com")
      @user = User.find(@account["user_id"])
      FileLayer.current = FileLayer::Share.new(root: @root.to_s)
    end
    teardown do
      FileLayer.reset!
      FileUtils.remove_entry(@root) if @root&.exist?
    end

    def auth = { "Authorization" => "Bearer #{@account['device_token']}" }

    # THE headline 501. Today this returns {versions: []} -- "this file has no history" -- which
    # is a lie: it has no history because this DEPLOYMENT has none. An empty list tells a client
    # the file is fine and unversioned; 501 tells it the truth.
    test "versions answers 501 in share mode, not an empty list that lies" do
      node = @user.nodes.create!(node_id: "n1", name: "a.stl", kind: "file", storage_path: "a.stl")
      get "/v1/nodes/#{node.node_id}/versions", headers: auth
      assert_response :not_implemented
      assert_no_match(/"versions":\s*\[\]/, response.body, "an empty list is the lie, not the answer")
    end

    test "restore answers 501 in share mode" do
      post "/v1/nodes/n1/restore", params: { version_id: "v1" }, headers: auth
      assert_response :not_implemented
    end

    test "the sync surface answers 501 in share mode" do
      { get: "/v1/changes", get2: "/v1/tree", get3: "/v1/conflicts" }.each_value do |path|
        get path, headers: auth
        assert_response :not_implemented, "#{path} must not pretend to be a sync endpoint"
      end
    end

    # 501, not 500, and it must SAY something. A bare status with no body leaves an operator
    # guessing whether the deployment is broken or merely different.
    test "a 501 explains itself" do
      get "/v1/changes", headers: auth
      assert_response :not_implemented
      body = JSON.parse(response.body)
      assert body["error"].present?, "a 501 must name the capability that is absent"
    end

    # The counterpart, and the one that catches an over-firing gate: chunk mode keeps ALL of it.
    test "chunk mode is completely ungated" do
      FileLayer.current = FileLayer::Chunk.new
      node = @user.nodes.create!(node_id: "n2", name: "b.stl", kind: "file")
      get "/v1/nodes/#{node.node_id}/versions", headers: auth
      assert_response :success
    end

    # The maker layer is the WHOLE PRODUCT in share mode. A gate that catches it would defeat
    # the phase this whole arc exists for.
    test "the maker layer is NOT gated in share mode" do
      get "/v1/maker/projects", headers: auth
      assert_response :success
    end
  end
end
```

**Every path and auth idiom above is a hypothesis — verify each against `config/routes.rb` and the existing `test/integration/v1/` suites before running.** Fix the test to match reality; do not add routes to make the test compile.

Then, for the upload branch — these are **web** endpoints (Devise session auth), so they belong in `test/integration/web/share_delivery_test.rb` (share mode) and `files_flow_test.rb` (chunk mode), **not** in the v1 file above. Both directions are honest 501s: share has no chunk store to presign into, and chunk mode genuinely cannot take bytes through Rails (CLAUDE.md §15) — an architectural constraint, not a bug.

In `share_delivery_test.rb` (its `setup` already signs in and sets `FileLayer.current` to `Share`):

```ruby
    # Share mode has no chunk store, so there is nothing to presign into and no manifest to
    # begin. 501 -- "this deployment can't do that" -- rather than a 500 out of Sync::Commit,
    # or (worse) a pending_commit that can never be finalized.
    test "begin_upload answers 501 in share mode" do
      post begin_upload_files_path,
           params: { name: "x.stl", size: 1, manifest: [ { hash: "a" * 64, offset: 0, length: 1 } ] },
           as: :json
      assert_response :not_implemented
      assert_match(/upload/i, JSON.parse(response.body)["error"].to_s)
    end

    test "finalize_upload answers 501 in share mode" do
      post finalize_upload_files_path, params: { commit_id: SecureRandom.uuid }, as: :json
      assert_response :not_implemented
    end

    # The share/s3 flow: the bytes come straight up in a multipart POST and land on the port.
    test "the direct upload writes through the port in share mode" do
      post files_path, params: {
        file: Rack::Test::UploadedFile.new(StringIO.new("uploaded bytes"), "application/octet-stream",
                                           original_filename: "up.stl")
      }
      assert_response :redirect
      assert_equal "uploaded bytes", File.binread(@root.join("up.stl")), "the bytes must reach the NAS"
      assert @user.nodes.find_by(storage_path: "up.stl"), "and the node must be indexed"
    end
```

In `files_flow_test.rb` (chunk mode):

```ruby
    # The other direction. Chunk mode CAN accept uploads -- it does so all day via the
    # two-phase presigned flow -- it just cannot take the bytes through Rails (CLAUDE.md 15).
    # So the direct endpoint is an honest 501, and it must NAME the flow that does work:
    # a bare 501 here would read as "uploads are off", which is exactly wrong.
    test "the direct upload answers 501 in chunk mode, naming the two-phase flow" do
      sign_in
      post files_path, params: {
        file: Rack::Test::UploadedFile.new(StringIO.new("bytes"), "application/octet-stream",
                                           original_filename: "direct.stl")
      }
      assert_response :not_implemented
      assert_match(/begin_upload/, response.body,
                   "a refusal must name the path the caller SHOULD use -- as Chunk#write does")
    end
```

**`POST /files` is not routed today** — verified: `resources :files, only: %i[index show destroy]` with a `collection` block for `begin_upload`/`finalize_upload`. Add `:create` to the `only:` list. **Read the routes block and match its shape**; do not restructure it.

`Rack::Test::UploadedFile` is a hypothesis for the multipart idiom — **check what the suite already uses** (`files_flow_test.rb` PUTs raw bytes to presigned URLs, which is a different shape) and match reality.

- [ ] **Step 3: Run to see them fail.**

- [ ] **Step 4: Implement**

**Constraints:**
- A concern — `LibraryCapabilities` — offering `require_capability!(:versioned)` as a `before_action`. It renders **501** with a JSON body naming the missing capability. **Read `V1::BaseController`'s existing `not_found`/`bad_request`/`unprocessable`/`conflict` private renderers and match their shape exactly** (`{ error: ... }`); a second response idiom in the same API is a divergence.
- **A gate, and nothing else.** Gating a v1 sync controller is allowed; **changing what it does is §10.** If a gate seems to require touching `Sync::*`, stop.
- **No `rescue NotImplementedError` anywhere.** Argued at length above. If you find yourself wanting one, the gate is missing — add the gate.
- The upload branch in `FilesController`: `port_writable?` selects. `begin_upload`/`finalize_upload` require `port_writable? == false` (they are the chunk flow); the direct `create` requires `port_writable? == true`. **Both 501s are honest** — neither deployment can do the other's flow.
- **`Chunk#write` must remain unreachable from any controller.** That is the gate's job. If it is ever hit, a 500 is the correct and desired outcome: it is a programming error and it should be loud.

- [ ] **Step 5: Prove the gate can fail (mutation)**

Remove the `versioned?` gate from `nodes#versions`. The headline 501 test must fail — **and note what it fails with: `{versions: []}`, a 200.** That is the lie §6 names, and watching the test catch it is the point. Byte-exact guard; revert by backup + `cmp`. **Report.**

- [ ] **Step 6: Full suite + commit** — all three legs.

---

### Task 8: Docs

**Files:** `CLAUDE.md`, `docs/STATUS.md`

- [ ] **Step 1: Update both, grep for now-false claims, commit.**

CLAUDE.md §15 requires it when the architecture moves. Claims that **become false** — fix them, do not append around them:
- §12 step 10: *"Phase 4 = capability gating + `Delivery` (**`download` is Phase 4** — share-mode `blob` 404s today, by scope)"*. Both halves stop being true.
- The phase list (Phase 4 done; the file-layer split complete).

**Record, because a future reader will otherwise "simplify" them away:**
- **`port_writable` is not "accepts uploads."** Chunk mode accepts uploads via `Sync::Commit`. Getting this wrong hides upload in the product's main deployment. **This is the single most likely thing to be misread.**
- **The 501 is produced by a capability gate, never by rescuing `NotImplementedError`** — which is not a `StandardError`, and which is a programming error rather than a runtime condition. Record the reasoning, not just the rule, or someone will "add a backstop rescue" and launder a boot misconfiguration into a 501.
- **`Delivery`'s three variants, and that §15 survives on S3 (`Redirect`) but not on share** (§2 decision 6). Do not "fix" the share case.
- **`send_file` + `x_sendfile_header` is the whole X-Accel story**; there is no nginx here (Kamal), so the un-accelerated branch is the only live one, and the knob is documented-and-commented on purpose.
- **`Chunk#download`'s `is_a?(S3ChunkStore)` is deliberately not `presignable?`** — memory and local presign to URLs Rails itself serves. §9a-3/§9a-4 remain open; Phase 4 does **not** force them, and this is why.

---

## Definition of done

- [ ] `bin/rails test` green; report the count and the delta from the baseline you recorded at Task 1
- [ ] `LIBRARY_BACKEND=share LIBRARY_PATH=$(mktemp -d) bin/rails test` green, **identical count**
- [ ] The `LIBRARY_BACKEND=s3` leg green
- [ ] All three adapters pass **both** contracts, unmodified, **including the new capability pins**
- [ ] **A share-backed file downloads through the web UI** — the thing that 404s today. Verified by hand against a real folder, not only in the suite.
- [ ] The show page reports a real size and does **not** say "No content yet" in share mode
- [ ] `GET /v1/nodes/:id/versions` answers **501** in share mode and **200** in chunk mode
- [ ] Chunk mode is **visibly unchanged**: `files_flow_test.rb` green **unmodified**, upload offered, history offered
- [ ] Mutation results reported for: Task 1 (a lying capability), Task 4 (the escape guard, **both** tests), Task 5 (`send_data` kills acceleration while the bytes test still passes), Task 7 (a removed gate returns the empty-list lie)
- [ ] **No `rescue NotImplementedError` anywhere** — `grep -rn "rescue.*NotImplementedError" app lib` returns nothing
- [ ] No sync/changelog/conflict/lock/mount edits (spec §10); no "unify uploads through the port"
- [ ] `Chunk#write`/`delete`/`move` still raise, and remain unreachable from any controller

## Next

The maker/file-layer split is complete: `LIBRARY_BACKEND=chunk|share|s3` all boot, index, write, deliver, and tell the truth about themselves.

**Open, and now overdue** — carried from 2a, restated in 2b and Phase 3, and each phase has made them likelier to bite rather than less: `Library::Reconciler` loads every live node into memory (~1M AR objects on a large library), and `best_pairing` is O(n²) (~2s per 10k renames). Both are commented in-code. **Fix before pointing this at a real 2TB NAS or a bucket with millions of objects.** The write path (2b), a bucket (Phase 3), and now a UI that browses it (Phase 4) are three separate reasons a library gets big.

**Also open (spec §9a, unresolved):** §9a-3 (`presignable` is the store's property, answered statically) and §9a-4 (`Chunk.fetch`'s `respond_to?` sniffing, which **fails open**). Phase 4 pinned the capability to observed behavior, which blunts §9a-3's sharpest edge, but neither is closed. §9a-5's taxonomy gap ("too big" is terminal-but-present, and the port answers `NotFound`) is untouched and now has three adapters answering it the same wrong way.
