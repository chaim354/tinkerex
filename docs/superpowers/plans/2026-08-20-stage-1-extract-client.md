# Stage 1 — Extract `client/` into `tinkerex-client`

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Move the Rust crates and the Tauri desktop app out of the Rails monorepo, so maker-layer work stops carrying ~37k lines of Rust and six CI workflows it never touches.

**Design:** `docs/superpowers/specs/2026-08-20-chunk-repo-separation-design.md` §3.

---

## READ THIS FIRST — the design doc's Stage 1 section is wrong in three ways

It says Stage 1 is *"Nearly free: no Ruby depends on it, and the only tie is `bin/ci test-app` … plus `ci_hygiene_test.rb`'s workflow guards."* A measurement of the real tree falsifies that. **Do not plan from §3; plan from here.**

1. **`client/stl-thumbnailer` IS a Ruby dependency, at Docker build time.** `Dockerfile:57-64` compiles it from source in its own stage and `:141` copies the binary into the production image; `.dockerignore:54-63` excludes `/client/` and then re-includes exactly this one crate. `Maker::Previews::Stl` execs it by bare name off `PATH`. Extract `client/` naively and **every STL and 3MF thumbnail in production stops rendering.** Task 1 resolves this and it is the reason Task 1 comes first.

2. **Two of the six workflows cannot move wholesale, because four jobs boot a real Rails server** to give the Rust integration suites something to talk to: `rust-client.yml`'s `engine-integration`, and `nightly.yml`'s `e2e-linux`, `e2e-macos`, `stress-load-and-multifiletype-linux`. Each does `bin/rails server -p 3001 &` and then `cargo test --manifest-path client/sync-engine/…`. They need **both** trees in one job.

3. **Self-hosted runners are registered PER REPOSITORY, not per org.** `ci/runners/setup-{macos,linux,windows}.{sh,ps1}` all hardcode `REPO_URL="https://github.com/chaim354/tinkerex"` and register against `repos/chaim354/tinkerex/actions/runners`. A new repo needs a **second runner service** on each physical box. And per `ci/runners/README.md:56`, **only `charless-MacBook-Pro-maker-mac` is registered today** — the Linux and Windows runners the client workflows target are not live at all. This is an operator step with no code fix, and it gates whether the moved CI runs at all.

**One thing the design doc got right and is worth banking:** history is cleanly separable. 166 of 1090 commits touch `client/`, and — verified two independent ways — **zero commits touch both `client/` and a non-`client/` path.** `git filter-repo --path client/` yields an unfragmented history with no commit needing to be split. Largest blob ever committed under `client/` is ~152 KB; no LFS needed, no submodules, no symlinks.

---

## Task 1: Get `stl-thumbnailer` out of `client/` FIRST — before anything moves

**This is a prerequisite, not a step of the move.** Until it is done, extracting `client/` breaks production thumbnails.

**The recommendation, with its argument: `stl-thumbnailer` is not a client crate and never was.** It is a **server-side** renderer invoked by the preview pipeline (`app/services/maker/previews/stl.rb`), compiled into the **Rails** image, and executed by the **Rails** process. Nothing in `client/` depends on it — verified: no `Cargo.toml` under `client/` has a `path` dependency on it. It sits in `client/` by historical accident. Moving it to `tools/stl-thumbnailer/` **in this repo** is not a workaround for the extraction; it is filing it where it belonged all along, and it makes the extraction genuinely free of Ruby coupling.

Rejected alternatives, and why:
- **Publish prebuilt binaries the Dockerfile downloads.** Adds a release pipeline, a version-pinning problem and a network dependency to `docker build`, to solve a problem that only exists because the crate is in the wrong directory.
- **Submodule or vendored copy.** Two sources of truth for a binary whose Ruby caller is in this repo. CLAUDE.md §14e's `FakeS3` lesson is what two copies of one thing costs.
- **Leave `client/stl-thumbnailer` behind while the rest moves.** Leaves a one-crate `client/` directory whose name now means nothing, and every reader has to learn why.

**Files:**
- Move: `client/stl-thumbnailer/` → `tools/stl-thumbnailer/`
- Modify: `Dockerfile:57-64,141`
- Modify: `.dockerignore:54-63`
- Modify: `app/services/maker/previews/stl.rb` (comment only — the code execs off `PATH`)
- Modify: `app/javascript/controllers/modelviewer_controller.js:7` (comment)
- Modify: `test/ci_hygiene_test.rb` if it names the old path
- Modify: `CLAUDE.md` §3 component table, §10 repo layout

- [ ] **Step 1: Prove the current binary works, so you can prove it still does**

```bash
grep -rn "stl-thumbnailer\|stl_thumbnailer" Dockerfile .dockerignore app/ test/ config/ bin/ scripts/ | grep -v "^app/.*:.*#"
```

Record every hit. Then confirm the renderer's own tests currently pass and note which of the 3 pre-existing skips is the "stl-thumbnailer not installed" one:

```bash
bin/rails test test/services/maker/previews/ 2>&1 | tail -5
```

- [ ] **Step 2: Move the crate with its history**

```bash
git mv client/stl-thumbnailer tools/stl-thumbnailer
```

- [ ] **Step 3: Repoint the Dockerfile**

In `Dockerfile`, the build stage becomes:

```dockerfile
FROM docker.io/library/rust:1-slim AS stl-thumbnailer
WORKDIR /build
COPY tools/stl-thumbnailer ./
RUN cargo build --release && strip target/release/stl-thumbnailer
```

The `COPY --from=stl-thumbnailer …` line at `:141` is unchanged — it copies from the stage, not from the source tree.

- [ ] **Step 4: Repoint `.dockerignore`**

Replace the three-line `/client/` block with:

```
# The whole client tree is the desktop app's, and the Rails image needs none of it.
# tools/stl-thumbnailer is NOT in here on purpose: the image compiles it (see Dockerfile),
# because Maker::Previews::Stl execs the resulting binary. It used to live under client/,
# which is why this file once carried a re-include exception for it.
/client/
```

- [ ] **Step 5: Prove the image still builds and still contains the binary**

This is the step that actually verifies Task 1. A green `bin/ci` proves nothing here — the Dockerfile is not a gate.

```bash
docker build --target stl-thumbnailer -t stl-probe . && docker run --rm stl-probe /build/target/release/stl-thumbnailer 2>&1 | head -3
```

Expected: the binary's own usage/version output, not a "not found". **If Docker is unavailable on this box, say so explicitly and do not claim this step passed** — name it in the PR as unverified.

- [ ] **Step 6: Full gate + commit**

```bash
bin/ci
```

```bash
git add -A && git commit -F - <<'MSG'
refactor: move stl-thumbnailer out of client/ -- it is a SERVER-side tool

It is compiled into the Rails image (Dockerfile), executed by the Rails process
(Maker::Previews::Stl execs it off PATH), and depended on by no crate in client/
-- verified: no Cargo.toml under client/ has a path dependency on it. It sat in
client/ by historical accident.

This is a prerequisite for extracting client/ into its own repo, and it is the
reason that extraction was NOT "nearly free" as the design doc claimed: a naive
move would have taken every STL and 3MF thumbnail in production down, because
.dockerignore excluded /client/ and then re-included exactly this one crate.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
MSG
```

---

## Task 2: Decide the fate of the two dead crates

`client/juicefs-backend` (1,922 lines) and `client/maker-app-core` (646 lines) have **zero consumers anywhere** — no `Cargo.toml` path-depends on them, no workflow names them. CLAUDE.md §3 already calls them *"Leftovers from the abandoned mount path; reference only."*

- [ ] **Step 1: Re-verify the "zero consumers" claim before acting on it**

```bash
grep -rn "juicefs-backend\|juicefs_backend\|maker-app-core\|maker_app_core" --include=Cargo.toml --include='*.rs' --include='*.yml' --include='*.sh' . | grep -v "^./client/juicefs-backend\|^./client/maker-app-core"
```

Expected: no hits outside the crates' own trees and docs.

- [ ] **Step 2: Move them, do not delete them**

They travel with `client/` in Task 4. **Recommendation: keep them.** They are the recorded evidence behind CLAUDE.md §14e's "JuiceFS was abandoned" invariant and `docs/roads-not-taken.md`; deleting them costs nothing today and removes the artifact a future reader would want when they propose reviving a mount-based design. If they are ever deleted, that is its own decision with its own commit message, not a side effect of a move.

Record the decision in the new repo's README. No code change in this task.

---

## Task 3: Create the repo and choose its layout

**BLOCKED ON THE USER — this task creates a public artifact and needs their explicit go-ahead.** Do not run it unprompted.

- [ ] **Step 1: Confirm the name and visibility with the user, then create it**

```bash
gh repo create chaim354/tinkerex-client --private --description "Rust crates and Tauri desktop app for tinkerex: local-first sync engine, per-OS mounts"
```

- [ ] **Step 2: KEEP THE `client/` PREFIX in the new repo**

The new repo's layout must be `tinkerex-client/client/fs-provider/…`, **not** a flattened `tinkerex-client/fs-provider/…`.

The reason is measured, not aesthetic: **82 self-referential `client/…` path strings live inside `client/` itself, across 33 files.** The `.rs` hits are doc-comment prose and harmless, but `client/test-conformance/*` and `client/maker-app/src-tauri/scripts/set-app-version.sh` pass them as real arguments — `cargo build --manifest-path client/fs-webdav/Cargo.toml`, `cd "$(dirname "$0")/../.."`. Every CI workflow does the same. Flattening means editing all of them and every `--manifest-path` in six workflow files; keeping the prefix makes that machinery work unchanged.

A one-line note in the new repo's README explaining why the top level has a single `client/` directory costs less than 82 edits and the regressions they would carry.

---

## Task 4: Move the tree with history

- [ ] **Step 1: Produce the new repo's history with `git filter-repo`**

Work on a CLONE, never on the working repo:

```bash
git clone https://github.com/chaim354/tinkerex.git /tmp/tinkerex-client-src
cd /tmp/tinkerex-client-src
git filter-repo --path client/
git log --oneline | wc -l   # expect 166
```

**Expect 166 commits.** If the number differs, stop — `git filter-repo`'s path matching is not doing what this plan assumes, and proceeding would silently drop or duplicate history.

Note the ordering: this runs **after** Task 1, so `stl-thumbnailer`'s move is already in history and the filtered result correctly excludes it from the new repo's tip while keeping its pre-move commits (they were `client/` paths at the time). That is correct and worth stating in the new repo's README so nobody is surprised to find `stl-thumbnailer` in `git log` but not on disk.

- [ ] **Step 2: Push it**

```bash
git remote add origin https://github.com/chaim354/tinkerex-client.git
git push -u origin main
```

- [ ] **Step 3: Remove `client/` from THIS repo, in its own commit**

```bash
git rm -r client/
```

Do not squash this with the CI changes — a reviewer should be able to see the deletion alone.

---

## Task 5: Split the CI workflows

Four move wholesale; two split.

| Workflow | Disposition |
|---|---|
| `build-app.yml` | **Moves wholesale** |
| `install-app-on-runners.yml` | **Moves wholesale, paired with `build-app.yml`** — its `workflow_run: workflows: ["Build app"]` trigger only fires for a workflow in the SAME repo, so separating them silently breaks it |
| `cross-os-e2e.yml` | **Moves wholesale** — every job targets the deployed server via `SERVER_URL`, no local Rails |
| `rust-client.yml` | **Splits** — 7 of 8 jobs are pure cargo; `engine-integration` boots Rails |
| `nightly.yml` | **Splits** — 9 of 12 jobs are pure cargo or hit the deployed server; `e2e-linux`, `e2e-macos`, `stress-load-and-multifiletype-linux` boot Rails |
| `ci.yml` | **Stays.** Delete the `test-app-js` job and the `client/maker-app/**` re-include from its `paths:` |

- [ ] **Step 1: Decide where the four Rails-coupled jobs live, and record the decision**

They need both trees in one job. Three options — **pick one and write the argument into the workflow file itself**, because the next person will wonder:

- **(a) Keep them in `tinkerex`, checking out `tinkerex-client` as a second path.** `actions/checkout@v7` supports `repository:` + `path:`. The Rails repo already has the runner registration and the server boot recipe. **Recommended** — the job is fundamentally "does the client still work against THIS server", which is a question about the server's contract.
- **(b) Move them to `tinkerex-client`, checking out `tinkerex`.** Inverts the same coupling; needs the new repo to carry a Ruby toolchain and `db:prepare`.
- **(c) Drop them to a nightly cross-repo workflow only.** Cheapest, loses PR-time signal on the wire contract — which is exactly what Stages 3 and 4 will lean on.

- [ ] **Step 2: Edit `ci.yml`**

Remove the `test-app-js` job (lines ~214-221) and the `- 'client/maker-app/**'` line from `paths:`. **Leave `- '!client/**'`** — it still correctly excludes a directory that no longer exists, and removing it changes nothing while making the diff larger.

- [ ] **Step 3: Drop the `test-app` gate from `config/ci.rb`**

Delete the `"test-app" => ->(ci) do … end` block. `bin/ci` goes from **8 gates to 7**. Note what the gate did: it globbed `client/maker-app/test/**/*.test.js` and `abort`ed if empty — so leaving it in place after the move does not degrade gracefully, it **aborts the whole `bin/ci` run**, since Ruby's `Dir.glob` with a missing `base:` returns `[]` rather than raising.

- [ ] **Step 4: Fix `test/ci_hygiene_test.rb`**

Remove the four `client/` literals from its path lists:
- `PATHS_THAT_MUST_RUN_CI`: `client/maker-app/package.json`, `client/maker-app/test/session.test.js`
- `PATHS_THAT_MUST_SKIP_CI`: `client/sync-engine/src/lib.rs`, `client/maker-app/README.md`

These are asserted with `Rails.root.join(path).exist?` **before** the paths-filter logic runs, so a stale entry turns `test`, `test-share` AND `test-s3` red — not just the client gate.

Also check `DYNAMIC_MATRIX_WORKFLOWS = %w[build-app.yml install-app-on-runners.yml]`: both files are leaving, so that exemption list should empty or the constant should go.

- [ ] **Step 5: Give the new repo its own hygiene guard**

Three of `ci_hygiene_test.rb`'s assertions are generic workflow hygiene and apply to whatever CI the new repo has:
1. no job targets a GitHub-hosted runner (`runs-on` must include `self-hosted` — CLAUDE.md §15: hosted runners are billed)
2. no macOS job uses `ruby/setup-ruby`
3. every linux/windows job is preflight-gated

**Without a copy in `tinkerex-client`, these three stop being checked for six workflow files.** That is the design doc's own Risk #4. The new repo has no Rails, so this needs a different shape — a small Rust test, or a shell script in its CI. Decide and implement; do not leave it as "someone should".

- [ ] **Step 6: `bin/ci` must be green at 7 gates, three legs identical**

---

## Task 6: The two stragglers the design doc missed

- [ ] **Step 1: `scripts/r2-cutover/smoke.sh`**

It does `ENGINE_DIR="$REPO_ROOT/client/sync-engine"` and hard-fails `sync-engine crate not found` when absent, then `cargo run --example presigned_roundtrip`. It is an **operator** script run by hand during R2 cutovers, not CI — so nothing goes red when it breaks; someone finds out mid-migration.

Options: point it at a sibling checkout via an env var (`TINKEREX_CLIENT_DIR`, defaulting to `../tinkerex-client`), or move the script to the client repo. Either is fine; **failing loudly with a message naming the new repo is the requirement**, not silently skipping.

- [ ] **Step 2: `ci/runners/` stays, but needs a sibling**

`ci/runners/setup-{macos,linux,windows}` hardcode `chaim354/tinkerex`. The physical boxes need a second runner service registered against `chaim354/tinkerex-client`. Copy the scripts into the new repo with the URL changed, and add a line to `ci/runners/README.md` here saying a second service exists and why.

**Flag to the user:** only the macOS runner is registered today. Until Linux and Windows runners are registered against the new repo, the moved workflows are **skipped, not passing** — the same trap CLAUDE.md §15 records for this repo's own Linux/Windows coverage.

---

## Task 7: Documentation

- [ ] **Step 1: `CLAUDE.md`**
- §3's component table: the `client/` rows leave; add a pointer to `tinkerex-client`. `stl-thumbnailer` gets a row under its new `tools/` home.
- §4's Mount row and §10's repo layout: repoint.
- §13's cheatsheet: every `cd client/…` and `--manifest-path client/…` line now names another repo. **This section is what a fresh agent reads to run things** — leaving it wrong is worse than leaving it sparse.
- §15's CI section: the gate count is 7.

- [ ] **Step 2: `docs/STATUS.md`** — one entry for the arc, per §15. Record what moved, the 166-commit filter-repo result, the `stl-thumbnailer` re-filing and why it was a prerequisite, the four Rails-coupled jobs and where they landed, and the runner-registration state.

- [ ] **Step 3: Amend the design doc.** §3 currently claims Stage 1 is "nearly free … no Ruby depends on it". Correct it, citing this plan's opening section.

---

## Done when

- [ ] `bin/ci` green at **7** gates, three legs identical
- [ ] `docker build --target stl-thumbnailer` produces a working binary
- [ ] `tinkerex-client` has 166 commits and its own CI green
- [ ] No `client/` reference remains in this repo outside prose — `grep -rn "client/" --include='*.rb' --include='*.yml' --include='Dockerfile' . | grep -v '^./docs'`
- [ ] The three generic workflow-hygiene assertions exist in BOTH repos
- [ ] The user knows which runners are registered and which coverage is therefore skipped rather than passing
