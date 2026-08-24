# Arc A Part 2 — the portable conformance corpus

> **For agentic workers:** REQUIRED SUB-SKILL: superpowers:subagent-driven-development or
> superpowers:executing-plans. Steps use `- [ ]` checkboxes.

**Goal:** a language-neutral corpus that any sync-server implementation must satisfy, so a Rust
rewrite has something to be graded against other than "port the Ruby tests."

**Architecture:** authored REQUESTS, recorded RESPONSES. Scenario files declare an ordered
sequence of HTTP calls against a live server; a recorder runs them and writes down what the server
actually answered; a verifier replays them and diffs. The corpus lives in `chaim354/tinkerex-sync`
because the server owns the server contract. A tiny matcher vocabulary keeps the runner
reimplementable in any language in an afternoon.

**Tech Stack:** Ruby (recorder + verifier), YAML (scenarios), JSON Schema (format spec), the
standalone `host/` app as the server under test.

**Design:** `docs/superpowers/specs/2026-08-23-stage-5-engine-leaves-the-process-design.md`, Arc A
section A2. **That file is not on this branch** — it lands with PR #226 (`claude/stage-5-arc-a`),
which is unmerged. Read it there, or take the preamble below as self-contained, which it is
deliberately meant to be: a task that cannot be executed without chasing an unmerged branch is a
task that will be executed wrong.

---

## Where the work happens

**Every task below runs in `../tinkerex-sync`, not this repo**, except Task 6 which writes
`docs/sync-protocol.md` here. Commits go to that repo and it gets its own PR.

## Why recorded, not hand-authored — the one rule that must not bend

The design doc is explicit and it is worth restating because hand-authoring is the tempting
shortcut: **expectations written by the same mind that wrote the implementation will agree with
the implementation, including where the implementation is wrong.** This repo has already paid for
that once — `FakeS3` decoded `copy_source` with `CGI.unescape` while the adapter encoded with
`CGI.escape`, exact inverses, and 79 of 80 tests were green over silent permanent data loss on any
filename containing a space (CLAUDE.md §14e).

So: a human authors the REQUEST sequence and the assertions about *shape*; the recorder fills in
the *values* from a real server. Reviewing a recorded corpus is then a genuine act — you read what
the server said and decide whether it is right — rather than confirming your own guess.

---

## The matcher vocabulary — deliberately tiny

Five forms, and no more without a strong argument. A Rust implementer must be able to read this
section and write a runner without reading the Ruby.

| Form | Meaning |
|---|---|
| a literal scalar/array/object | exact equality |
| `{ $capture: NAME }` | matches anything; binds the value to `NAME` for later steps |
| `{ $ref: NAME }` | must equal the value previously bound to `NAME` |
| `{ $type: string\|integer\|boolean\|array\|object\|null }` | type only — for values that vary per run |
| `{ $absent: true }` | the key must NOT be present |

`$type` exists for genuinely volatile values (timestamps, server-assigned ids on their first
appearance). **`$type` is the escape hatch and every use is a small admission**: it says "the
contract does not pin this." A reviewer should push back on any `$type` that could have been a
`$capture` + `$ref` pair instead, because a captured-and-referenced value proves internal
consistency where a type check proves almost nothing.

Requests may interpolate `{{NAME}}` into paths, query values and body values.

---

## File Structure

| File (in `../tinkerex-sync`) | Responsibility |
|---|---|
| `conformance/README.md` | The normative format spec — matchers, execution model, how to add a scenario, how to run a non-Ruby runner against it. The document a Rust implementer reads. |
| `conformance/schema.json` | JSON Schema for a scenario file, so a runner can validate before executing. |
| `conformance/scenarios/*.yml` | The corpus. One file per endpoint group. |
| `conformance/runner.rb` | Shared execution engine: interpolation, matching, capture bindings. Used by both the recorder and the verifier so they cannot disagree. |
| `bin/conformance-record` | Runs scenarios against a live server and writes recorded expectations back into the YAML. |
| `test/conformance_test.rb` | The verifier, as an ordinary Minitest file so `rake` runs it. Skips cleanly with no server. |

---

## Task 1: the runner and its format

**Files (in `../tinkerex-sync`):**
- Create: `conformance/runner.rb`
- Create: `conformance/schema.json`
- Test: `test/conformance_runner_test.rb`

- [ ] **Step 1: Write the failing test**

`test/conformance_runner_test.rb` — unit tests for the MATCHER, with no HTTP involved. This is the
piece that must be right before anything is recorded, because a permissive matcher records a
corpus that cannot fail.

```ruby
# frozen_string_literal: true

require "test_helper"
require_relative "../conformance/runner"

# THE MATCHER IS THE WHOLE CORPUS'S TEETH. A recorded expectation is only worth what the matcher
# refuses, so these tests are mostly about what must NOT match -- an over-permissive matcher would
# record a corpus that passes against a server doing the wrong thing, which is the FakeS3 shape
# (CLAUDE.md §14e) one level up.
class ConformanceRunnerTest < ActiveSupport::TestCase
  M = Conformance::Matcher

  test "a literal must match exactly" do
    assert M.new.match!({ "a" => 1 }, { "a" => 1 })
    assert_raises(Conformance::Mismatch) { M.new.match!({ "a" => 1 }, { "a" => 2 }) }
  end

  test "an extra key in the actual body is a mismatch, not a pass" do
    # THE DIRECTION THAT MATTERS. A subset match would let a server add a field nobody vetted --
    # and for a wire contract, a new field IS a contract change.
    assert_raises(Conformance::Mismatch) { M.new.match!({ "a" => 1 }, { "a" => 1, "b" => 2 }) }
  end

  test "a missing key is a mismatch" do
    assert_raises(Conformance::Mismatch) { M.new.match!({ "a" => 1, "b" => 2 }, { "a" => 1 }) }
  end

  test "$capture binds a value and matches anything" do
    m = M.new
    m.match!({ "id" => { "$capture" => "node" } }, { "id" => "abc" })
    assert_equal "abc", m.bindings["node"]
  end

  test "$ref must equal what was captured" do
    m = M.new
    m.match!({ "id" => { "$capture" => "node" } }, { "id" => "abc" })
    assert m.match!({ "id" => { "$ref" => "node" } }, { "id" => "abc" })
    assert_raises(Conformance::Mismatch) { m.match!({ "id" => { "$ref" => "node" } }, { "id" => "xyz" }) }
  end

  test "$ref to an unbound name is an error, not a silent pass" do
    assert_raises(Conformance::Mismatch) { M.new.match!({ "id" => { "$ref" => "never" } }, { "id" => "abc" }) }
  end

  test "$type checks the type and nothing else" do
    assert M.new.match!({ "seq" => { "$type" => "integer" } }, { "seq" => 7 })
    assert_raises(Conformance::Mismatch) { M.new.match!({ "seq" => { "$type" => "integer" } }, { "seq" => "7" }) }
  end

  test "$absent requires the key to be missing" do
    assert M.new.match!({ "gone" => { "$absent" => true } }, {})
    assert_raises(Conformance::Mismatch) { M.new.match!({ "gone" => { "$absent" => true } }, { "gone" => nil }) }
  end

  test "a null value is not the same as an absent key" do
    # These are different answers on the wire and the corpus must be able to tell them apart --
    # chunk_remote's own restore-to-root case turns on parent_node_id being NULL rather than gone.
    assert M.new.match!({ "parent_node_id" => nil }, { "parent_node_id" => nil })
    assert_raises(Conformance::Mismatch) { M.new.match!({ "parent_node_id" => nil }, {}) }
  end

  test "interpolation substitutes bound values into strings" do
    m = M.new
    m.match!({ "id" => { "$capture" => "node" } }, { "id" => "abc" })
    assert_equal "/v1/nodes/abc/move", m.interpolate("/v1/nodes/{{node}}/move")
  end

  test "interpolating an unbound name raises rather than emitting the literal braces" do
    assert_raises(Conformance::Mismatch) { M.new.interpolate("/v1/nodes/{{nope}}") }
  end
end
```

- [ ] **Step 2: Run it and watch it fail**

```bash
cd ../tinkerex-sync && bundle exec rake test TEST=test/conformance_runner_test.rb
```

Expected: errors — `conformance/runner.rb` does not exist.

- [ ] **Step 3: Implement `conformance/runner.rb`**

Write `Conformance::Matcher` (bindings, `match!`, `interpolate`) and `Conformance::Mismatch`.
Requirements, each of which a test above pins:

- Exact matching by default, in BOTH directions — extra keys and missing keys are both mismatches.
- `$capture` / `$ref` / `$type` / `$absent` as the only special forms; a hash is a special form
  only when it has exactly one key and that key starts with `$`.
- `nil` and absent are distinct.
- `interpolate` raises on an unbound name rather than emitting `{{name}}` literally — a silent
  literal would produce a request to a nonsense path and a confusing 404.
- A `Mismatch` message must name the JSON path that failed (`body.changes[0].node_id`), not just
  "did not match". A corpus that cannot tell you WHERE is a corpus nobody will maintain.

- [ ] **Step 4: Green**

```bash
cd ../tinkerex-sync && bundle exec rake test TEST=test/conformance_runner_test.rb
```

Expected: all pass.

- [ ] **Step 5: Write `conformance/schema.json`**

A JSON Schema for one scenario file: `name`, `description`, `steps[]`, each step
`{ name, request: { method, path, query?, body?, headers? }, expect: { status, body? } }`.
Validate every existing scenario against it in Task 3's verifier.

- [ ] **Step 6: Mutation-check the matcher**

Break exact-matching to allow extra keys (make the actual-side check a subset test) and confirm
`test_an_extra_key_in_the_actual_body_is_a_mismatch,_not_a_pass` goes RED. Restore, confirm green.
Report both. §15: a guard that has never failed has not been shown to work — and this guard is the
one every recorded expectation depends on.

- [ ] **Step 7: Commit**

```bash
cd ../tinkerex-sync
git add conformance/runner.rb conformance/schema.json test/conformance_runner_test.rb
git commit -m "Conformance: the matcher, and what it refuses"
```

---

## Task 2: the recorder

**Files (in `../tinkerex-sync`):**
- Create: `bin/conformance-record`
- Create: `conformance/scenarios/01-enrolment.yml` (the first scenario, as the recorder's proof)

- [ ] **Step 1: Author the first scenario's REQUESTS only**

`conformance/scenarios/01-enrolment.yml` — device enrolment and `whoami`, because every other
scenario needs a token and this is the one that mints it. Author `request` blocks and leave each
`expect` as `{}` for the recorder to fill.

- [ ] **Step 2: Write `bin/conformance-record`**

Reads a scenario, executes each step against `$SYNC_SERVER_URL` with `$SYNC_DEVICE_TOKEN`, and
writes the observed status and body back into the file as `expect`. Rules:

- **It must NOT overwrite an expectation a human has edited** unless `--force` is passed. The
  corpus is reviewed; silently re-recording erases the review.
- Volatile values are recorded as `$type`, not as literals — timestamps, and any server-assigned
  id on first appearance. It should then be a HUMAN decision to tighten a `$type` into a
  `$capture`/`$ref` pair. The recorder must print a summary of every `$type` it wrote, so the
  reviewer sees exactly what was left unpinned.
- Writes YAML deterministically (sorted keys, stable formatting) so a re-record produces a clean
  diff rather than noise.

- [ ] **Step 3: Record against a real server, and READ what it wrote**

```bash
cd ../tinkerex-sync/host && bin/rails db:prepare && EMAIL=conformance@example.com bin/rails sync:device:issue
STORAGE_BACKEND=local bin/rails server -p 3003 &
cd .. && SYNC_SERVER_URL=http://127.0.0.1:3003 SYNC_DEVICE_TOKEN=<token> bin/conformance-record conformance/scenarios/01-enrolment.yml
```

Then open the file and read every recorded expectation. Report anything that surprised you — that
reading IS the deliverable of this step, not a formality.

- [ ] **Step 4: Commit**

---

## Task 3: the verifier, and CI

**Files (in `../tinkerex-sync`):**
- Create: `test/conformance_test.rb`
- Modify: `.github/workflows/ci.yml`

- [ ] **Step 1: Write the verifier**

An ordinary Minitest file so `rake test` runs it. For each scenario: validate against
`schema.json`, execute every step, match every expectation. **Skips cleanly when
`SYNC_SERVER_URL` is unset**, so the default suite is unaffected.

- [ ] **Step 2: Prove it fails when the server is wrong**

Mutate the server — change one response field (e.g. have `whoami` return `user` instead of
`user_id`) — and confirm the verifier goes RED naming that JSON path. Restore. **Report the exact
failure message**: if it does not name the path, fix the matcher, because that message is what a
Rust implementer will be debugging against.

- [ ] **Step 3: Add a CI job**

A `conformance` job in `.github/workflows/ci.yml`: boot `host/`, run the verifier. Same
self-hosted-macos constraints as that file's existing `test` job. Do not add
`ruby/setup-ruby` to a macos job.

- [ ] **Step 4: Commit**

---

## Task 4: the corpus — the sync verbs

**Files:** `conformance/scenarios/02-commit.yml`, `03-changes.yml`, `04-nodes.yml`,
`05-trash.yml`

Author requests, record responses, read what was recorded. Cover: the two-phase commit and its
`put_urls`/`missing`; `GET /changes` including paging and `oldest_seq`; mkdir, symlink, move,
delete, versions, restore, resolve_conflict; trash index and restore.

- [ ] **`05-trash.yml` MUST cover both `to_root` arms, and this is the highest-value scenario in
  the corpus.** Restoring an orphan WITHOUT `to_root` is a 409 `parent_deleted`; WITH
  `to_root: true` it succeeds and the node comes back with `parent_node_id` null. That divergence
  is exactly what Arc A Part 1 found as gap (d) — the maker client posts an empty body and gets the
  409 — so pinning both arms here is what stops a future implementation quietly picking one.

---

## Task 5: the corpus — the rest

**Files:** `conformance/scenarios/06-tree-search.yml`, `07-conflicts.yml`, `08-locks.yml`,
`09-chunks.yml`, `10-share-links.yml`

- [ ] **Coverage must be checked, not assumed.** Add an assertion to `test/conformance_test.rb`
  that every route `Sync.draw_v1_routes` defines appears in at least one scenario, DERIVED from
  the drawer rather than from a hand-written list. A hand-written list is the third copy of a thing
  the drawer exists to be the single definition of, and it will drift the day someone adds an
  endpoint. Endpoints deliberately not covered must be named in the assertion's own exception list
  with a reason, so "not covered" is a decision rather than an oversight.

---

## Task 6: `docs/sync-protocol.md` becomes normative

**Files (in THIS repo, `tinkerex`):** `docs/sync-protocol.md`

- [ ] Grow it from its current 215 lines to cover all 25 endpoints `Sync.draw_v1_routes` defines:
  method, path, request shape, response shape, and every error status with its meaning.
- [ ] **Cross-reference the corpus rather than duplicating it.** Each endpoint names the scenario
  file that pins it. Prose and fixtures that restate each other drift; prose that POINTS at
  fixtures cannot.
- [ ] Record the `to_root` divergence explicitly, since it is the one place the protocol's
  behaviour and the maker client's use of it disagree today.
- [ ] A Rust implementer reads this document and is graded by the corpus. Write it for that reader.
