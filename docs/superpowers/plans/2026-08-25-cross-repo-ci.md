# Cross-Repo CI Cleanup Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this
> plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make this repo keep only CI it can go red on — hand the sync↔client suites over
corrected, delete them here, and repair everything that silently changes meaning when they go.

**Architecture:** Six sequenced changes. The handoff doc is written FIRST so no recipe survives
only in git history. The guard that goes vacuous on deletion is strengthened BEFORE the deletion,
so its mutation-check is meaningful. Deletion and the guard-list retarget land in ONE commit,
because splitting them makes `bin/ci` red mid-branch.

**Tech Stack:** GitHub Actions YAML, bash (`ci/preflight.sh`), Ruby/Minitest
(`test/ci_hygiene_test.rb`), Markdown.

**Spec:** `docs/superpowers/specs/2026-08-25-cross-repo-ci-design.md`

---

## File Structure

| File | Change | Responsibility after |
|---|---|---|
| `docs/superpowers/specs/2026-08-25-cross-repo-ci-handoff.md` | **create** | The corrected recipes the siblings execute. The deliverable that makes deletion safe. |
| `.github/workflows/nightly.yml` | **delete** | — |
| `.github/workflows/client-contract.yml` | **delete** | — |
| `test/ci_hygiene_test.rb` | modify | Gains a non-empty-scan assertion; `PATHS_THAT_MUST_RUN_CI` retargeted; two comments stop citing a deleted file. |
| `.github/workflows/ci.yml` | modify | `push: main` gains the same `paths` filter as `pull_request`. |
| `ci/preflight.sh` | modify | `--summary` DERIVES which families this repo's workflows target; three states, not two. |
| `CLAUDE.md` | modify | §13, §12.6, §15 CI bullet. |
| `ci/runners/README.md` | modify | Five `nightly` references. |
| `config/ci.rb` | modify | Header's "client-contract.yml precedent" citation. |
| `docs/STATUS.md` | modify | One arc entry. |

**Not touched, deliberately:** `config/ci.rb`'s `GATES` hash (no gate is added or removed),
`.kamal/*`, anything under `app/` or `lib/`.

---

### Task 1: The handoff document

**Files:**
- Create: `docs/superpowers/specs/2026-08-25-cross-repo-ci-handoff.md`

This is written first and in full. Deleting a workflow whose corrected form exists only in a
future intention is how a recipe becomes git archaeology.

- [ ] **Step 1: Write the handoff document**

Create `docs/superpowers/specs/2026-08-25-cross-repo-ci-handoff.md` with exactly this content:

````markdown
# Cross-repo CI handoff: sync↔client suites leave `tinkerex`

**From:** `chaim354/tinkerex` (the maker app)
**Date:** 2026-08-25
**Why:** After Arc D Part 2 these suites test `tinkerex-sync` against `tinkerex-client` with **no
`tinkerex` code involved**. They were deleted from `tinkerex` on this date. This document carries
the CORRECTED recipes — the versions here were broken, and copying them verbatim reproduces the
bug.

## The bug you must not copy

`tinkerex` no longer routes the sync API. Probed on `main` at deletion time:

```
recognize_path("/v1/commit", :post) -> ActionController::RoutingError
```

Its only non-maker `/v1` routes are `POST /v1/test/users`, `POST /v1/devices/login`,
`POST /v1/devices`. Every job below used to boot `bin/rails server` from `tinkerex` and point
`SYNC_IT_SERVER_URL` at it. Those jobs now get through signup and device login, then **404 on the
first commit**. The server to boot is **`tinkerex-sync`**.

Also drop, everywhere: `STORAGE_BACKEND`, `CHUNK_PUBLIC_URL`, `CHUNK_LOCAL_DIR`. No code in
`tinkerex` reads them any more; they are inert, not load-bearing.

---

## Part A → `chaim354/tinkerex-sync`

**Lands beside** the existing `ci.yml` `test` and `conformance` jobs, both already
`[self-hosted, macos]`.

**Source:** `tinkerex`'s deleted `.github/workflows/client-contract.yml`, job
`engine-integration`.

**Four changes from the original:**

1. **`runs-on: [self-hosted, linux]` → `[self-hosted, macos]`.** The original never ran once:
   linux is not a registered runner in any of the three repos, so the job was `if:`-gated off and
   the workflow reported success in ~8s having run only `preflight`. macos is registered in all
   three.
2. **Delete the `ruby/setup-ruby@v1` step.** It assumes the GitHub-hosted `/Users/runner` layout
   the self-hosted Mac lacks; the runner's PATH already carries mise ruby matching
   `.ruby-version`. `bundle install --quiet` is all the job needs.
3. **Delete the `apt-get install libfuse-dev` step.** Linux-only, and unnecessary: `fuser` is
   `cfg(linux)`, so `sync-engine` builds on mac without FUSE. `tinkerex`'s `nightly.yml`
   `e2e-macos` job proved this on real hardware.
4. **Boot your own app directly** instead of through `tinkerex`'s `bin/sync-server`. That script
   exists to boot a *sibling* checkout from `tinkerex`; inside your own repo it is a detour.

**Keep, with its argument intact:** `SYNC_VERIFY_FINALIZE=0`. Finalize's verify-the-bytes-landed
check is on by default, but `integration.rs` deliberately moves chunk bytes through `SharedDirIO`
— a shared-dir stand-in for the cloud — so the server legitimately cannot see them. The genuine
verify-ON proof is `two_device_e2e`, in Part B.

**Keep** `STORAGE_BACKEND=local` **only if your own app still reads it** — `two_device_e2e` moves
bytes via `PresignedIO`, and a memory store presigns relative `/dev/blobs/...` paths a Rust HTTP
client cannot follow. Verify against your own code rather than trusting this line.

```yaml
  engine-integration:
    runs-on: [self-hosted, macos]
    steps:
      - uses: actions/checkout@v7
        with: { clean: false }
      - name: Check out tinkerex-client
        uses: actions/checkout@v7
        with:
          repository: chaim354/tinkerex-client
          ssh-key: ${{ secrets.TINKEREX_CLIENT_DEPLOY_KEY }}
          path: tinkerex-client
          clean: false
      # tinkerex-client keeps the `client/` prefix in its OWN layout, so `tinkerex-client/client/...`
      # is the real path. Symlinking it to `client` means `--manifest-path client/...` and every
      # conformance script's own `cd "$(dirname "$0")/../.."` resolve with zero edits on either
      # side: bash's logical `cd` strips `..` TEXTUALLY against the invoking path, so it lands at
      # this checkout's root rather than the symlink's physical target.
      # `rm -rf` first because self-hosted runners are PERSISTENT (`clean: false`) and a real
      # client/ directory on disk would make `ln -s` refuse.
      - name: Symlink client/ to the second checkout
        run: |
          rm -rf client
          ln -s tinkerex-client/client client
      - uses: dtolnay/rust-toolchain@stable
      - name: Install gems (the runner's own Ruby — NOT ruby/setup-ruby)
        run: bundle install --quiet
      - name: Boot this app + run the integration suite (one step keeps the server alive)
        env:
          SYNC_IT_SERVER_URL: http://localhost:3002
          SYNC_VERIFY_FINALIZE: "0"
        run: |
          (lsof -ti tcp:3002 | xargs kill -9 2>/dev/null) || true
          sleep 1
          bin/rails db:prepare
          bin/rails server -p 3002 &
          SRV=$!
          trap 'kill "$SRV" 2>/dev/null || true' EXIT
          for i in $(seq 1 60); do
            curl -sf http://localhost:3002/up >/dev/null && { echo "server up"; break; }
            sleep 1
          done
          curl -sf http://localhost:3002/up >/dev/null || { echo "server failed to start"; exit 1; }
          cargo test --manifest-path client/sync-engine/Cargo.toml --test integration
          cargo test --manifest-path client/sync-engine/Cargo.toml --test two_device_e2e
```

**You will need** a `TINKEREX_CLIENT_DEPLOY_KEY` secret in `tinkerex-sync`. `GITHUB_TOKEN` is
scoped to one repo and cannot check out another, even same-owner private. Use a read-only deploy
key, not a PAT: `gh repo deploy-key add` gives one repo, read-only, no expiry, and needs no
browser (GitHub sunset `POST /authorizations` in 2020, so a fine-grained PAT is an irreducibly
manual step that also expires).

---

## Part B → `chaim354/tinkerex-client`

**Read this first: `two-device-fuse-linux` already exists in your `rust-client.yml` and is
broken.** It runs `bin/rails db:prepare` and then `client/test-conformance/two-device-fuse.sh`,
whose line 71 is `… bin/rails server -p "$PORT"`. **`tinkerex-client` has no `bin/rails`.** That
job could only ever have worked when run from `tinkerex`'s root — which is exactly why `tinkerex`
kept a duplicate of it in `nightly.yml` with a symlink. Both copies are linux-gated, so neither
has ever run. **Replace the existing job; do not add a second.**

**B1 — the two conformance scripts each need one line changed.**

`client/test-conformance/two-device-fuse.sh:71` and
`client/test-conformance/two-device-webdav-macos.sh:66` both read:

```bash
STORAGE_BACKEND=local ENABLE_TEST_SIGNUP=true CHUNK_LOCAL_DIR="$WORK/chunk-store" bin/rails server -p "$PORT" >"$WORK/server.log" 2>&1 &
```

The `bin/rails` they resolve comes from `cd "$(dirname "$0")/../.."`, i.e. the *invoking* repo's
root. Post-separation that must be a `tinkerex-sync` checkout. Give each script an explicit
server-root variable rather than relying on the enclosing repo:

```bash
SYNC_ROOT="${SYNC_ROOT:?set SYNC_ROOT to a tinkerex-sync checkout}"
( cd "$SYNC_ROOT" && ENABLE_TEST_SIGNUP=true bin/rails server -p "$PORT" ) >"$WORK/server.log" 2>&1 &
```

Drop `STORAGE_BACKEND` and `CHUNK_LOCAL_DIR` unless `tinkerex-sync`'s own code reads them — check,
do not assume. Keep `ENABLE_TEST_SIGNUP=true`: the scripts create users through
`POST /v1/test/users`, which is gated solely on that flag.

**B2 — the five jobs.** Each needs a `tinkerex-sync` checkout and boot in place of the `tinkerex`
Rails server. `SYNC_IT_SERVER_URL` must point at it.

| job | family | cargo invocation |
|---|---|---|
| `e2e-linux` | linux | `--test two_device_e2e -- --nocapture` |
| `e2e-macos` | macos | `--test two_device_e2e -- --nocapture` |
| `stress-load-and-multifiletype-linux` | linux | `--test concurrency_load` then `--test multifiletype_conformance`, both `-- --nocapture` |
| `two-device-fuse-linux` | linux | script: `client/test-conformance/two-device-fuse.sh` |
| `two-device-webdav-macos` | macos | script: `client/test-conformance/two-device-webdav-macos.sh` |

All manifests are `client/sync-engine/Cargo.toml`.

**Keep** `continue-on-error: true` on `two-device-webdav-macos` and its reason: macOS
`/sbin/mount_webdav` needs an INTERACTIVE desktop login session and will not hold a mount from a
headless launchd/ssh context. The script self-detects and exits 0 with a `BLOCKED` notice rather
than a false failure.

**Keep** the `needs: preflight` + `if: ${{ needs.preflight.outputs.<family> == 'true' }}` gating on
every linux and windows job. A job matching no online runner does **not** fail — it queues 24h at
0 elapsed and is auto-cancelled, leaving the PR UNSTABLE and merging needing `--admin`. That is
how CI went dark for five weeks on 2026-06-24.

**B3 — the signal gap.** In `tinkerex`, four consecutive nightly failures (2026-08-21 → 08-24,
all `Input required and not supplied: token` from a secret referenced on extraction day and never
created) notified nobody, because a scheduled workflow has no PR to turn red. If these land on a
schedule in `tinkerex-client`, give them a notification path.

---

## What `tinkerex` keeps

`ci.yml` only, six jobs, all `[self-hosted, macos]`, each invoking `bin/ci <gate>`. Its
`test-chunk-remote` gate still boots a real `tinkerex-sync` via `bin/sync-server` and runs the
full suite against it — that is `tinkerex`'s half of the wire contract and it is not moving.
`TINKEREX_SYNC_DEPLOY_KEY` stays for it. `TINKEREX_CLIENT_DEPLOY_KEY` was deleted; recreate it in
whichever repo now needs it.
````

- [ ] **Step 2: Verify the handoff names only files that exist where it says they do**

```bash
ls ../tinkerex-client/client/test-conformance/two-device-fuse.sh \
   ../tinkerex-client/client/test-conformance/two-device-webdav-macos.sh \
   ../tinkerex-client/client/sync-engine/Cargo.toml
sed -n '71p' ../tinkerex-client/client/test-conformance/two-device-fuse.sh
sed -n '66p' ../tinkerex-client/client/test-conformance/two-device-webdav-macos.sh
```

Expected: all three paths listed, and both `sed` lines print a `bin/rails server -p "$PORT"`
command. If a line number is off, correct the handoff — a cited line that does not say what the
doc claims is the §15 failure this repo has been bitten by three times.

- [ ] **Step 3: Commit**

```bash
git add docs/superpowers/specs/2026-08-25-cross-repo-ci-handoff.md
git commit -m "Hand the sync<->client CI over, corrected

The recipes here are the FIXED versions: every job that booted this
app's Rails now boots tinkerex-sync, because /v1/commit does not route
here any more. Copying the deleted workflows verbatim reproduces a 404
on first commit.

Also records that tinkerex-client's own two-device-fuse-linux is already
broken (it calls bin/rails, which that repo does not have) -- so Part B
replaces a job slot rather than adding one.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 2: Stop the preflight-gating guard going vacuous

**Files:**
- Modify: `test/ci_hygiene_test.rb` — the test `"every linux or windows job is preflight-gated so it can never queue against a missing runner"`

After Task 3 this repo has zero linux/windows jobs, so that test's `ungated` array is empty and
`assert_empty` passes **over nothing** — CLAUDE.md §14e verbatim: *"a guard that scans a directory
dies silently when the directory leaves."* The subject set is legitimately empty; what must not be
silently empty is the SCAN.

Do this BEFORE the deletion, so the mutation-check is meaningful.

- [ ] **Step 1: Add the failing assertion**

In `test/ci_hygiene_test.rb`, inside that test, insert this immediately before the existing
`ungated = []` line:

```ruby
    # THE SCAN MUST BE NON-EMPTY, EVEN THOUGH THE SUBJECT SET MAY LEGITIMATELY BE EMPTY.
    # This repo has no linux/windows jobs since the sync<->client suites moved out
    # (docs/superpowers/specs/2026-08-25-cross-repo-ci-handoff.md), so `ungated` below is
    # expected to be empty and assert_empty alone would pass over NOTHING. §14e: a guard whose
    # subject is a path is silently retired by a move. Assert what was actually looked at.
    scanned = []
    each_job { |file, name, _job| scanned << "#{file}:#{name}" }
    assert_operator scanned.size, :>=, 2,
                    "this guard scanned #{scanned.size} job(s) — it can no longer fail for the " \
                    "reason it exists. Point WORKFLOW_DIR at the real workflows."
```

- [ ] **Step 2: Run it and confirm it passes on the current tree**

```bash
bin/rails test test/ci_hygiene_test.rb -n "/preflight-gated/"
```

Expected: `1 runs, ... 0 failures, 0 errors`. (There are 15 jobs across three workflows today.)

- [ ] **Step 3: Mutation-check it — this is the whole point of the task**

Temporarily point the constant at an empty directory:

```bash
mkdir -p tmp/empty-workflows
sed -i '' 's|WORKFLOW_DIR = Rails.root.join(".github/workflows")|WORKFLOW_DIR = Rails.root.join("tmp/empty-workflows")|' test/ci_hygiene_test.rb
bin/rails test test/ci_hygiene_test.rb -n "/preflight-gated/"
```

Expected: **FAIL** with `this guard scanned 0 job(s)`.

If it PASSES, the assertion is not wired up — fix it before continuing. A guard that has never
failed has not been shown to work (§15).

- [ ] **Step 4: Restore**

```bash
sed -i '' 's|WORKFLOW_DIR = Rails.root.join("tmp/empty-workflows")|WORKFLOW_DIR = Rails.root.join(".github/workflows")|' test/ci_hygiene_test.rb
rmdir tmp/empty-workflows
bin/rails test test/ci_hygiene_test.rb -n "/preflight-gated/"
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add test/ci_hygiene_test.rb
git commit -m "The preflight-gating guard asserts it actually scanned something

Once the cross-repo workflows leave, this repo has zero linux/windows
jobs, so \`ungated\` is empty and assert_empty passes over nothing --
§14e's 'a guard that scans a directory dies silently when the directory
leaves', arriving on schedule.

Mutation-checked: WORKFLOW_DIR pointed at an empty dir goes RED with
'scanned 0 job(s)'.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 3: Delete the two workflows, in one commit with their fallout

**Files:**
- Delete: `.github/workflows/nightly.yml`
- Delete: `.github/workflows/client-contract.yml`
- Modify: `test/ci_hygiene_test.rb` — `PATHS_THAT_MUST_RUN_CI`, and the comments at the file
  header and above the `ruby/setup-ruby` test

One commit: `PATHS_THAT_MUST_RUN_CI` asserts `nightly.yml` **exists**, so deleting the file
without retargeting the entry leaves `bin/ci test` red.

- [ ] **Step 1: Confirm the guard fails first, so you know it is load-bearing**

```bash
git rm -q .github/workflows/nightly.yml .github/workflows/client-contract.yml
bin/rails test test/ci_hygiene_test.rb
```

Expected: **FAIL** — `.github/workflows/nightly.yml no longer exists — fix the list, not the
filter`. That message is the guard working exactly as designed.

- [ ] **Step 2: Retarget the path entry**

In `test/ci_hygiene_test.rb`, in `PATHS_THAT_MUST_RUN_CI`, replace:

```ruby
    ".github/workflows/nightly.yml",        # ci_hygiene_test globs EVERY workflow, not just ci.yml
```

with:

```ruby
    ".github/workflows/ci.yml",             # ci_hygiene_test parses this file; a PR editing it must run it
```

- [ ] **Step 3: Fix the two comments that cite the deleted file**

The `ruby/setup-ruby` RULE stays — it is about macos jobs, and this repo is all macos. Only its
CITATION must stop naming a file that no longer exists.

In the class-level comment block, replace:

```ruby
#   * `ruby/setup-ruby@v1` does not work on the self-hosted Mac. nightly.yml's e2e-macos job says so
#     in a comment and uses the runner's own Ruby instead. Retargeting a Rails job at macos while
```

with:

```ruby
#   * `ruby/setup-ruby@v1` does not work on the self-hosted Mac — it assumes the hosted
#     /Users/runner layout. Every job here uses the runner's own Ruby instead. (The job that
#     documented this in a comment, nightly.yml's e2e-macos, left with the cross-repo suites on
#     2026-08-25 — docs/superpowers/specs/2026-08-25-cross-repo-ci-handoff.md.) Retargeting a
#     Rails job at macos while
```

And above the test itself, replace:

```ruby
    # The action assumes the GitHub-hosted /Users/runner layout the self-hosted Mac does not have
    # (see nightly.yml's e2e-macos, which works around it). The runner's own PATH already carries
```

with:

```ruby
    # The action assumes the GitHub-hosted /Users/runner layout the self-hosted Mac does not have.
    # The runner's own PATH already carries
```

- [ ] **Step 4: Run the full hygiene suite**

```bash
bin/rails test test/ci_hygiene_test.rb
```

Expected: all green. In particular the set-equality test between `bin/ci --list-ci` and `ci.yml`'s
gate jobs must still pass — no gate was added or removed, so this confirms rather than changes.

- [ ] **Step 5: Commit**

```bash
git add -A .github/workflows test/ci_hygiene_test.rb
git commit -m "Delete the cross-repo CI: it tests neither this repo's code nor anything

client-contract.yml never ran once. Its only real job is linux-gated and
CI_RUNNERS=macos, so every run was preflight-success + engine-integration
-skipped -> workflow SUCCESS, on every PR since it landed.

nightly.yml still booted THIS app's Rails and pointed the Rust client at
it, but /v1/commit stopped routing here in Arc D Part 2. Its last green
ran 3h24m BEFORE that merged, so the green is pre-separation and the next
run would have 404'd. The identical fix HAD been applied to
client-contract.yml -- the workflow that never runs -- and withheld from
the one that does.

Both test sync<->client with zero tinkerex code involved. Corrected
recipes: docs/superpowers/specs/2026-08-25-cross-repo-ci-handoff.md

PATHS_THAT_MUST_RUN_CI named nightly.yml and went red on the delete,
exactly as its own message says it should.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 4: Filter the `push: main` leg

**Files:**
- Modify: `.github/workflows/ci.yml:53-55`

With `client-contract.yml` gone, docs-only PRs no longer run anything. Docs-only *merges* still
run all six jobs, because the push leg has no filter.

- [ ] **Step 1: Add the filter**

In `.github/workflows/ci.yml`, replace:

```yaml
  push:
    branches: [ main ]
```

with:

```yaml
  # THE PUSH LEG CARRIES THE SAME FILTER AS THE PR LEG, AND THAT IS A DELIBERATE REVERSAL.
  # It was unfiltered on purpose: the paths list was an allowlist that drifted silently, a new
  # top-level path defaulted to NOT running CI, and this leg was the net that surfaced the gap as
  # red on main AFTER the merge. Two things changed. The filter is now a closed set (see `paths:`
  # above), and test/ci_hygiene_test.rb pins it in BOTH directions against real files
  # (PATHS_THAT_MUST_RUN_CI / PATHS_THAT_MUST_SKIP_CI) — a stronger net than re-running six jobs
  # on main, because it fails at PR time instead of after the merge.
  # Consequence, intended: a docs-only merge runs zero jobs. If you ever loosen the hygiene test's
  # two path lists, restore this leg to unfiltered in the same commit.
  push:
    branches: [ main ]
    paths:
      - '**'
      - '.*'
      - '.*/**'
      - '!docs/**'
      - '!client/**'
      - '!**.md'
```

- [ ] **Step 2: Verify both legs parse to the identical filter**

```bash
python3 -c "
import yaml
d = yaml.safe_load(open('.github/workflows/ci.yml'))
on = d.get(True) or d.get('on')
pr, push = on['pull_request']['paths'], on['push']['paths']
print('pull_request:', pr)
print('push        :', push)
assert pr == push, 'the two legs disagree'
print('OK - identical')
"
```

Expected: `OK - identical`.

- [ ] **Step 3: Verify a docs-only path now skips both legs**

```bash
bin/rails test test/ci_hygiene_test.rb -n "/paths filter/"
```

Expected: PASS. Both filter tests read the `pull_request` leg; they are unaffected, which is why
Step 2 exists — it is what actually checks the new leg.

- [ ] **Step 4: Commit**

```bash
git add .github/workflows/ci.yml
git commit -m "A docs-only merge runs zero jobs, like a docs-only PR already did

The push:main leg was unfiltered as a net for paths-filter drift. That
net is now ci_hygiene_test's two path lists, which fail at PR time
instead of after the merge -- strictly earlier, so the swap is not a
loosening. Recorded in the comment so it is not silently reversed.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 5: `preflight --summary` reports three states, derived

**Files:**
- Modify: `ci/preflight.sh` — the `--summary` branch only

With no linux/windows jobs left here, the summary says *"absent — its jobs were SKIPPED"* about
jobs that do not exist. A hard-coded "this repo has no linux jobs" would be the fourth
hand-maintained list the script's own header warns against, so **derive it from the workflows**.

The non-summary branch (`family=true|false` for `$GITHUB_OUTPUT`) must not change — that is the
gating contract other repos' jobs rely on.

- [ ] **Step 1: Add the derivation helper**

In `ci/preflight.sh`, immediately after the `available()` function, add:

```bash
# DOES ANY WORKFLOW IN THIS REPO ACTUALLY SCHEDULE A JOB ON THIS FAMILY?
#
# DERIVED, NOT DECLARED. The header above refuses to hand-maintain a job list because it would be
# a fourth thing to drift; the same objection applies to hand-maintaining "which families this
# repo uses". A grep over the workflow dir cannot go stale.
#
# Deliberately crude: it matches the family name anywhere in a `runs-on` line, which over-reports
# rather than under-reports. Over-reporting restores the OLD wording (a warning about skipped
# coverage) and is safe; under-reporting would hide a real gap, which is the failure this whole
# script exists to prevent.
#
# `[[:space:]]`, not `\s`: the runner is macOS and BSD grep -E does not honour `\s`.
targeted() {
  grep -rhE '^[[:space:]]*runs-on:' .github/workflows/ 2>/dev/null | grep -q "$1"
}
```

- [ ] **Step 2: Replace the summary's table and closing note**

In the `--summary` branch, replace the whole block from `absent=""` down to **and including**
the `exit 0` that ends the branch. The replacement below carries its own `exit 0`; leaving the
original in place would give the branch two.

```bash
  absent=""
  for family in $FAMILIES; do
    targeted "$family" && ! available "$family" && absent="$absent \`$family\`"
  done

  echo "## CI runner preflight"
  echo
  echo "Declared fleet (repo variable \`CI_RUNNERS\`): \`$declared\`"
  echo
  echo "| Runner family | Status |"
  echo "|---|---|"
  for family in $FAMILIES; do
    if ! targeted "$family"; then
      echo "| \`$family\` | — no job in this repo targets it |"
    elif available "$family"; then
      echo "| \`$family\` | ✅ available |"
    else
      echo "| \`$family\` | ⛔ **absent — its jobs were SKIPPED** |"
    fi
  done
  echo

  if [ -n "$absent" ]; then
    echo "> **This coverage was skipped, not passed.** Jobs requiring$absent were never scheduled,"
    echo "> so a green run here is green about less than a full run would be. The skipped jobs are"
    echo "> listed by name in this run's job list."
    echo ">"
    echo "> Register the runner (\`ci/runners/README.md\`) and add the family to the \`CI_RUNNERS\`"
    echo "> repo variable, or accept the gap knowingly."
  else
    echo "> No coverage skipped: every family this repo schedules jobs on is declared available."
    echo ">"
    echo "> A \`—\` row is NOT a passing row. It means this repo has no job for that family at all"
    echo "> — the sync↔client suites that did left on 2026-08-25"
    echo "> (\`docs/superpowers/specs/2026-08-25-cross-repo-ci-handoff.md\`). That coverage now lives"
    echo "> in \`tinkerex-sync\` and \`tinkerex-client\`, and this run says nothing about it."
  fi
  exit 0
```

- [ ] **Step 3: Run it and read the output**

```bash
CI_RUNNERS=macos ci/preflight.sh --summary
```

Expected: `macos` ✅ available; `linux` and `windows` each `— no job in this repo targets it`; and
the closing note is the "No coverage skipped" branch including the `—` disclaimer.

- [ ] **Step 4: Mutation-check the derivation both ways**

```bash
# Over-report path: a linux job appears -> the row must become a warning.
printf 'jobs:\n  x:\n    runs-on: [self-hosted, linux]\n' > .github/workflows/zz-probe.yml
CI_RUNNERS=macos ci/preflight.sh --summary | grep -E '^\| `linux`'
rm .github/workflows/zz-probe.yml
```

Expected: the probe run prints `⛔ **absent — its jobs were SKIPPED**` for `linux`. If it still
prints the `—` row, `targeted()` is not reading the directory — fix it.

- [ ] **Step 5: Confirm the gating output is byte-for-byte unchanged**

```bash
CI_RUNNERS=macos ci/preflight.sh
```

Expected exactly:

```
macos=true
linux=false
windows=false
```

This is the contract `if: needs.preflight.outputs.<family>` reads. If it changed, revert Step 2 —
the summary is cosmetic, the outputs are not.

- [ ] **Step 6: Commit**

```bash
git add ci/preflight.sh
git commit -m "preflight tells 'runner absent' apart from 'no job needs it'

With the cross-repo suites gone this repo has no linux/windows jobs, so
the old summary warned about SKIPPED jobs that do not exist. Derived from
a grep over the workflow dir rather than a hand-maintained list -- the
same objection the file header already makes to listing jobs -- and
biased to over-report, so a wrong answer restores the warning rather than
hiding a gap.

The family=true|false output is untouched: that is the gating contract.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 6: Correct every doc that now says something false

**Files:**
- Modify: `CLAUDE.md` (§13 paragraph, §12 item 6, §15 CI bullet)
- Modify: `ci/runners/README.md` (five `nightly` references: lines 26, 167, 190, 208, 214)
- Modify: `config/ci.rb` (header's client-contract.yml citation)

- [ ] **Step 1: CLAUDE.md §13 — replace the paragraph that is now false in full**

Replace this paragraph:

```
**Two CI legs here still reach into `tinkerex-client`, deliberately.** `nightly.yml` runs the
Rails-coupled two-device real-mount legs (`two-device-fuse.sh`, `two-device-webdav-macos.sh`)
because those scripts boot their **own local Rails server** — they `cd` upward to find `bin/rails`
— so they must run from THIS repo's root even though the scripts live in the sibling. Both
`nightly.yml` and `client-contract.yml` check the sibling out into a subdirectory and symlink
`client` to it, so from a job's-eye view the paths are unchanged. `client-contract.yml` boots
`tinkerex-sync` for the same kind of reason.
```

with:

```
**NO CI LEG HERE REACHES INTO `tinkerex-client` ANY MORE (2026-08-25).** `nightly.yml` and
`client-contract.yml` are deleted: both tested sync↔client with **no code from this repo
involved**, and both were broken in ways only measurement showed. `client-contract.yml` had never
run once — its only real job is linux-gated and `CI_RUNNERS` is `macos`, so every run reported
SUCCESS having run only `preflight`. `nightly.yml` still booted THIS app's Rails and pointed the
Rust client at it, three hours after Arc D Part 2 stopped routing `/v1/commit` here. Corrected
recipes went to the siblings in
`docs/superpowers/specs/2026-08-25-cross-repo-ci-handoff.md`. **`ci.yml` is the only workflow
left**, six jobs, all macos, each invoking `bin/ci <gate>`. This repo's half of the wire contract
is `bin/ci test-chunk-remote`, which is not moving.
```

- [ ] **Step 2: CLAUDE.md §12 item 6 — keep the item number, correct its claim**

Replace:

```
6. **Linux and Windows CI coverage is skipped, not passing** — no linux or windows runner is
   registered in ANY of the three repos (macOS is, in all three). §15 has the measured table and
   its date.
```

with:

```
6. **Linux and Windows CI coverage is skipped, not passing** — no linux or windows runner is
   registered in ANY of the three repos (macOS is, in all three). §15 has the measured table and
   its date. **Since 2026-08-25 this repo schedules no linux or windows jobs at all**, so the gap
   is entirely the siblings' — `ci/preflight.sh --summary` now says `— no job in this repo targets
   it` rather than warning about skipped jobs that do not exist.
```

- [ ] **Step 3: CLAUDE.md §15 CI bullet — the `if:`-gated sentence no longer describes this repo**

Replace:

```
- **`ci.yml`'s jobs therefore target `macos`**, and linux/windows jobs elsewhere are
  `if:`-gated on the repo variable **`CI_RUNNERS`** via `ci/preflight.sh`, so a job whose
  runner is absent is never *scheduled*. That gate fixed a five-week outage: a job matching no
  online runner does **not** fail — it queues 24 h at 0 elapsed and is auto-cancelled, which
  is why a PR sat UNSTABLE and merging needed `--admin`. **Linux and Windows coverage is
  skipped, not passing.**
```

with:

```
- **`ci.yml`'s jobs target `macos`, and it is the ONLY workflow here** since the cross-repo
  suites left (2026-08-25). The `if:`-gate on the repo variable **`CI_RUNNERS`** via
  `ci/preflight.sh` therefore has nothing left to gate *in this repo* — **keep the mechanism
  anyway**: it fixed a five-week outage, and the failure it prevents is silent. A job matching no
  online runner does **not** fail — it queues 24 h at 0 elapsed and is auto-cancelled, which is
  why a PR sat UNSTABLE and merging needed `--admin`. Any future linux/windows job here MUST be
  `needs: preflight` + `if:`-gated; `test/ci_hygiene_test.rb` enforces it, and asserts it actually
  scanned some jobs so the guard cannot go vacuous the way it nearly did. The siblings still gate
  real jobs this way. **Linux and Windows coverage is skipped, not passing.**
```

- [ ] **Step 4: `ci/runners/README.md` — update the five `nightly` references**

Locate each with `grep -n nightly ci/runners/README.md`. The two-device *capability* sections stay
— the runner setup they describe is still what those suites need, they just run elsewhere now. Add
this note directly under the `## Enabling the two-device REAL-MOUNT e2e` heading:

```
> **These suites no longer run from this repo.** `nightly.yml` was deleted on 2026-08-25 and the
> jobs moved to `chaim354/tinkerex-client`
> (`docs/superpowers/specs/2026-08-25-cross-repo-ci-handoff.md`). The runner *setup* below is
> unchanged and still required — read `nightly.yml` below as "the workflow in tinkerex-client".
```

Then fix the one instruction that names a workflow this repo no longer has. Replace:

```
Verify: `gh workflow run nightly.yml` (or `gh workflow run rust-client.yml -f target=two-device`),
```

with:

```
Verify (from a `tinkerex-client` checkout): `gh workflow run rust-client.yml -f target=two-device`,
```

- [ ] **Step 5: `config/ci.rb` — the header cites a deleted file as precedent**

In the `test-chunk-remote` gate's comment block, replace:

```
  # lived beside bin/ci on the client-contract.yml precedent: a cross-repo wire-contract workflow
  # that boots a real server and never calls bin/ci. Arc B closed all four gaps -- the suite is
```

with:

```
  # lived beside bin/ci on the client-contract.yml precedent: a cross-repo wire-contract workflow
  # that boots a real server and never calls bin/ci. (That workflow was deleted on 2026-08-25 --
  # it had never run once -- so the precedent is history, not a live example; the argument for
  # folding this gate INTO bin/ci is what survives.) Arc B closed all four gaps -- the suite is
```

- [ ] **Step 6: Verify no doc still points at a deleted workflow**

```bash
grep -rn "client-contract\|nightly\.yml" CLAUDE.md config/ci.rb ci/ test/ .github/ 2>/dev/null
```

Expected: every remaining hit is either past-tense prose about the deletion, or the
`ci/runners/README.md` note that explicitly redirects to `tinkerex-client`. **No hit may read as a
live instruction.**

- [ ] **Step 7: Run the docs guard and commit**

```bash
bin/rails test test/docs_hygiene_test.rb test/ci_hygiene_test.rb
```

Expected: green. CLAUDE.md's line ceiling is a ratchet — §13 gets shorter here, §12.6 and §15 grow
slightly; if the ceiling now allows a lower number, lower it.

```bash
git add CLAUDE.md ci/runners/README.md config/ci.rb
git commit -m "Correct every doc that outlived the cross-repo workflows

§13's 'Two CI legs here still reach into tinkerex-client, deliberately'
was the load-bearing false one -- it described a mechanism that no longer
exists in a file loaded into every session. §12.6 and §15's CI bullet
narrowed to what is still true. ci/runners/README.md keeps the runner
SETUP (still required) and redirects the workflow references.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 7: The STATUS.md entry

**Files:**
- Modify: `docs/STATUS.md`

§15: the entry is part of the work, in the same branch and PR, written while the numbers are still
in front of you. One arc, one entry.

- [ ] **Step 1: Add the entry**

Insert a new `## 2026-08-25: The cross-repo CI leaves, and two green signals turn out to be
vacuous` section in the correct reverse-chronological position, covering:

- The measurement that started it: bare `bin/ci` green in 2m13s, three legs at identical run
  counts (2357), 0 failures — the local gate story was never what broke.
- **F1** `nightly.yml` pointed the Rust client at this app's Rails; `recognize_path("/v1/commit",
  :post)` raises `RoutingError`; last green ran `2026-08-25T08:30Z` vs Arc D Part 2 merging
  `2026-08-25T11:54:51Z` — 3h24m earlier, so that green is pre-separation. The identical fix HAD
  been applied to `client-contract.yml` and withheld from the workflow that runs.
- **F2** `client-contract.yml` never ran once: linux-gated, `CI_RUNNERS=macos`, so every run was
  `preflight: success` + `engine-integration: skipped` → SUCCESS. Verified against run
  `32879690329`.
- **F3** Four consecutive red nights 08-21→08-24, `Input required and not supplied: token`,
  notifying nobody.
- **F4** `client-contract.yml` had no paths filter and ran on `e4dfe51` (a `docs/STATUS.md`-only
  commit); `push: main` was unfiltered.
- The bonus finding: `two-device-fuse.sh` is referenced by two workflows in two repos, both
  linux-gated, never run in either — and `tinkerex-client`, which owns one of them, has no
  `bin/rails` for the script to find.
- What was done, and the two guards repaired (`PATHS_THAT_MUST_RUN_CI` going red on the delete
  exactly as designed; the preflight-gating test gaining a non-empty-scan assertion), both
  mutation-checked.
- What is explicitly NOT closed: §12.6 unchanged; `bin/ci` still prints the three leg counts
  without comparing them.

- [ ] **Step 2: Commit**

```bash
git add docs/STATUS.md
git commit -m "Record the cross-repo CI arc

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 8: Final verification

- [ ] **Step 1: Bare `bin/ci`**

Run it ONCE, capturing the output, so the leg counts can be read without paying for a second run:

```bash
bin/ci 2>&1 | tee tmp/ci-final.txt | tail -20
grep -E '^[0-9]+ runs, ' tmp/ci-final.txt
```

Expected: every gate green, and four `N runs,` lines — share, s3, the chunk_remote journey (10
runs), and the chunk_remote full suite. **The three FULL-suite counts must match** (2357 at the
time of writing; the 10-run line is the journey file and is not one of them).

`bin/ci` prints these and never compares them, so this is the human half of the §15 rule. A ±2
assertion / ±1 skip difference is the known flap; a difference in `runs` is a real bug — a test
depending on the ambient `LIBRARY_BACKEND`.

- [ ] **Step 2: Confirm exactly one workflow remains, all jobs macos, all invoking bin/ci**

```bash
ls .github/workflows/
python3 -c "
import yaml, glob
for f in sorted(glob.glob('.github/workflows/*.yml')):
    d = yaml.safe_load(open(f))
    for n, j in d['jobs'].items():
        runs = j.get('runs-on')
        cmds = [s.get('run','') for s in j.get('steps',[])]
        gate = [c for c in cmds if 'bin/ci' in c]
        print(f'{f} {n}: {runs} gate={bool(gate)}')
"
```

Expected: `ci.yml` only; six jobs; every `runs-on` is `['self-hosted', 'macos']`; every job except
`preflight` has `gate=True`.

- [ ] **Step 3: Delete the now-unused deploy key — YOU run this, not the agent**

`TINKEREX_CLIENT_DEPLOY_KEY`'s only two consumers were the deleted workflows. Deleting a repo
secret is a settings change; it is listed here for a human to run deliberately.

```bash
gh secret delete TINKEREX_CLIENT_DEPLOY_KEY --repo chaim354/tinkerex
```

Confirm `TINKEREX_SYNC_DEPLOY_KEY` **remains** — `ci.yml`'s `test-chunk-remote` job uses it:

```bash
gh secret list --repo chaim354/tinkerex
```

Expected: `TINKEREX_SYNC_DEPLOY_KEY` present, `TINKEREX_CLIENT_DEPLOY_KEY` absent.

- [ ] **Step 4: Push and open the PR**

Per CLAUDE.md §15's close-out rule, on a `claude/*` branch with green gates this is standing
authorization. State plainly in the PR what was verified (bare `bin/ci`, three legs, both
mutation-checks, the derived preflight summary) and what was not (the siblings' side of the
handoff is unexecuted; §12.6 unchanged).
