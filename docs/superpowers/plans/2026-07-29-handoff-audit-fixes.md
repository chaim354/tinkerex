# Handoff audit fixes — implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended)
> or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`)
> syntax for tracking.

**Goal:** Close the six still-open items from `docs/HANDOFF-AUDIT-FIXES.md` — unblock the CI security
gates, bump five gems behind advisories, ship the GPL sidecar's licence text, install F3D so STEP/IGES/OBJ
previews actually work on the deployed image, and correct three stale/undocumented facts in the docs.

**Architecture:** Nine independent tasks against the Rails server + Dockerfile + docs. No task touches
the sync engine, the changelog, conflicts, locks or the mounts — CLAUDE.md §12 step 10's tripwire stays
un-tripped. Two tasks are test-first (the sidecar licence guard, the OBJ render); the rest are verified
by **exit code**, which is the whole point of the arc being fixed.

**Tech stack:** Rails 8.1.3, Ruby, brakeman 8.0.5, bundler-audit, Docker (multi-stage, amd64
cross-built), F3D 3.5.0 (BSD-3), minitest.

---

## Read this first

### Source

`docs/HANDOFF-AUDIT-FIXES.md` (written 2026-07-29 against commit `6ca3dd7`, lives on the
`opus-5-model-8b8462` worktree — it is **not** in this worktree's `docs/`). This plan works from HEAD
`4ed32fe`, which is one merge ahead of the handoff's baseline.

### Four handoff items are ALREADY CLOSED by PR #94 — do not redo them

Verified at HEAD `4ed32fe`, not assumed:

| Handoff item | Evidence it is closed |
|---|---|
| **4** Active Storage direct-upload | `config/routes.rb:32` draws `post "#{ActiveStorage.routes_prefix}/direct_uploads"` → a 404 proc. Option (c) was taken: server-side strip **and** route removal. |
| **5** Bound `maker_sheets.data` | `app/models/maker/sheet.rb` has `MAX_DATA_BYTES = 1_048_576` + `validate :data_within_size_limit`. |
| **7** One system test that executes JS | `test/system/sheet_grid_test.rb` — "a formula computes in the grid and persists as its raw text", plus `test/system/tray_layout_test.rb`. |
| **9** Two file-type vocabularies | `FilesHelper::EXT_FAMILIES` is now **derived** from `Maker::FileAttachment::ROLE_BY_EXT`/`ROLE_LABELS`. |

If a task below appears to duplicate one of these, stop and re-read — you are on the wrong baseline.

### The three decisions this plan encodes (already made — do not relitigate)

1. **F3D → install it** (handoff item 8, option a). Not "annotate".
2. **CI Linux runner → document only.** All 7 `ci.yml` jobs target `[self-hosted, linux]`; the GitHub
   API reports exactly one runner (`charless-MacBook-Pro-maker-mac`, macOS). **Do not retarget the jobs
   and do not add `ubuntu-latest`** (CLAUDE.md §15 forbids hosted runners). A separate agent will fix CI.
   This plan corrects the stale CLAUDE.md claim and writes down the local-verification recipe.
3. **`ENABLE_TEST_SIGNUP` → document only, change nothing.** Task 9 records the finding; it makes no
   behavioural change.

### The one rule that matters for Tasks 2–4

**Verify security gates by EXIT CODE, never by reading output.** The failure being fixed is a gate that
*looked* like it passed.

---

## File structure

| File | Change | Task |
|---|---|---|
| `config/brakeman.ignore` | Add a 4th ignored warning (`image_thumb.rb:45`) | 2 |
| `Gemfile.lock` | Bump 5 gems (+ 7 nokogiri platform lines) | 3 |
| `test/deploy_hygiene_test.rb` | Add a 3rd assertion: every GPL sidecar image carries its own LICENSE | 5 |
| `sidecar/boxes/Dockerfile` | `COPY LICENSE README.md ./` | 5 |
| `Dockerfile` | New `f3d` stage + runtime libs + `COPY --from=f3d` + `ENV F3D_BIN` | 6 |
| `test/fixtures/files/tetra.obj` | New fixture (OBJ is in `Mesh::EXTENSIONS` and had no test) | 6 |
| `test/services/maker/previews/mesh_test.rb` | Add an OBJ render test | 6 |
| `CLAUDE.md` | Delete the stale `53 tests`; correct §15's runner claim | 7, 8 |
| `docs/STATUS.md` | Record the arc + the two documented-only findings | 8, 9, 10 |
| `config/deploy.ovh.yml` | Comment only — record the `ENABLE_TEST_SIGNUP` inheritance | 9 |

---

## Task 1: Establish the baseline

No code changes. This is the gate that lets you tell "I broke it" from "I found it".

**Files:** none.

- [ ] **Step 1: Run the default suite**

```bash
bin/rails test
```

Expected: `1625 runs, 5655 assertions, 0 failures, 0 errors, 14 skips`.
(The handoff quotes 1587/5482 — that is the `6ca3dd7` baseline, one merge behind. 1625 is current;
`docs/STATUS.md` line 7 is the authority.)

- [ ] **Step 2: Run the share leg**

```bash
LIBRARY_PATH=$(mktemp -d) LIBRARY_BACKEND=share bin/rails test
```

Expected: identical counts.

- [ ] **Step 3: Run the s3 leg**

```bash
LIBRARY_BACKEND=s3 LIBRARY_S3_BUCKET=ci-not-a-real-bucket LIBRARY_S3_REGION=us-east-1 \
  LIBRARY_S3_ACCESS_KEY_ID=ci LIBRARY_S3_SECRET_ACCESS_KEY=ci LIBRARY_S3_PREFIX=library \
  bin/rails test
```

Expected: identical counts. **No network call happens** — the s3 leg uses a stubbed client on purpose.

- [ ] **Step 4: Run the system tests and rubocop**

```bash
bin/rails db:test:prepare test:system
```

Expected: `6 runs, 28 assertions, 0 failures, 0 errors`.

```bash
bin/rubocop
```

Expected: `435 files inspected, no offenses detected`.

- [ ] **Step 5: Record the three gate exit codes as they are TODAY**

```bash
bin/brakeman --no-pager >/dev/null 2>&1; echo "brakeman=$?"
bin/bundler-audit        >/dev/null 2>&1; echo "audit=$?"
bin/importmap audit      >/dev/null 2>&1; echo "js=$?"
```

Expected **right now**: `brakeman=3`, `audit=1`, `js=0`. Those first two are what Tasks 2 and 3 fix.
If `js` is anything but 0, stop — that is new, and out of this plan's scope.

---

## Task 2: Unblock `bin/brakeman` (handoff item 1)

`.github/workflows/ci.yml`'s `scan_ruby` job runs brakeman as step 1 and bundler-audit as step 2.
Brakeman exits 3, so **step 2 has never run**. The job looks like two gates and is currently zero.

The warning is a false positive: `Open3.capture3` with an **argv array** execs the binary directly —
no shell, so no shell-injection vector. `config/brakeman.ignore` already carries this exact argument at
length for `app/services/maker/previews/mesh.rb:59`, the sibling renderer using the same pattern.
`image_thumb.rb` was added later and the ignore was never extended.

**Files:**
- Modify: `config/brakeman.ignore`

- [ ] **Step 1: Confirm the warning and read its real fingerprint out of brakeman itself**

Do **not** trust the fingerprint written in the handoff without checking it — a fingerprint is derived
from the code and the location, both of which can move.

```bash
bundle exec brakeman -f json --no-pager 2>/dev/null | python3 -c "
import json,sys
d = json.load(sys.stdin)
for w in d['warnings']:
    print(json.dumps({k: w.get(k) for k in
        ['warning_type','warning_code','fingerprint','check_name','message','file','line',
         'link','code','render_path','location','user_input','confidence','cwe_id']}, indent=2))
"
```

Expected: exactly one warning, `file: app/services/maker/previews/image_thumb.rb`, `line: 45`,
`warning_type: Command Injection`. The handoff predicts
`fingerprint: 8c103396fda65cd51507f38aaa29004f32f6ff5823fd2695ac5515c334d51d19` — **use whatever this
command prints**, and note it in your commit message if it differs.

- [ ] **Step 2: Add the ignore entry**

Do not run `bundle exec brakeman -I` — it is an interactive TUI and cannot be driven headlessly.
Hand-write the entry instead, using the JSON from Step 1 verbatim for the first 14 keys and adding a
`note`. Insert it into `config/brakeman.ignore` as the **last element** of `ignored_warnings` (after the
`files_controller.rb` entry), keeping the file's existing 2-space indentation and the trailing
`"brakeman_version": "8.0.5"` key untouched:

```json
    {
      "warning_type": "Command Injection",
      "warning_code": 14,
      "fingerprint": "<paste from Step 1>",
      "check_name": "Execute",
      "message": "Possible command injection",
      "file": "app/services/maker/previews/image_thumb.rb",
      "line": 45,
      "link": "https://brakemanscanner.org/docs/warning_types/command_injection/",
      "code": "Open3.capture3(BIN, Tempfile.new.path, \"--size\", \"#{size}x#{size}\", \"-o\", \"#{Tempfile.new.path}.thumb.png\")",
      "render_path": null,
      "location": {
        "type": "method",
        "class": "Maker::Previews::ImageThumb",
        "method": "render"
      },
      "user_input": "<paste from Step 1 — null if brakeman reports null>",
      "confidence": "Medium",
      "cwe_id": [
        77
      ],
      "note": "False positive, same argument as the mesh.rb entry above. `Open3.capture3(*args)` is invoked with an ARGV ARRAY, so Ruby execs the binary directly with NO shell — there is no shell-injection vector. `BIN` is an operator-controlled constant (ENV['VIPSTHUMBNAIL_BIN'] default 'vipsthumbnail'); both the input and output paths are Tempfile-generated, not user-supplied (`out_path` is the tempfile's own path plus a fixed '.thumb.png' suffix); and `size` is an integer preview dimension passed as its own argv element (a malformed value would just make vipsthumbnail error out, which is handled and raised as RenderError). No user input reaches a shell. An argv-array capture3 is the deliberate pattern every renderer in Maker::Previews::* uses."
    }
```

**Every key from Step 1 must match byte-for-byte** — brakeman matches on the fingerprint, but a
mismatched `file`/`line` makes the file lie to the next reader.

- [ ] **Step 3: Verify the file is still valid JSON**

```bash
python3 -c "import json; d=json.load(open('config/brakeman.ignore')); print(len(d['ignored_warnings']), 'ignored;', d['brakeman_version'])"
```

Expected: `4 ignored; 8.0.5`

- [ ] **Step 4: Verify by exit code**

```bash
bin/brakeman --no-pager >/dev/null 2>&1; echo "brakeman=$?"
```

Expected: `brakeman=0`

- [ ] **Step 5: Commit**

```bash
git add config/brakeman.ignore
git commit -m "fix(ci): brakeman exits 3 on a false positive, so bundler-audit has never run

The scan_ruby job runs brakeman first and bundler-audit second. Brakeman
exits 3 on Maker::Previews::ImageThumb's argv-array Open3.capture3 — the
same shell-free pattern already accepted at length for the sibling
mesh.rb renderer — so step 2 has never executed. Two gates, zero running.

Per-warning fingerprint, matching the mesh.rb precedent; no blanket
suppression, and the code is not touched because there is nothing wrong
with it."
```

### Do not

- **Do not "fix" the code to satisfy brakeman.** An argv-array `capture3` is the correct, shell-free way
  to call a binary, and it is what every `Maker::Previews::*` renderer does deliberately.
- **Do not add a blanket suppression** for the Command Injection check. The `mesh.rb` precedent is a
  per-warning fingerprint for a reason.

---

## Task 3: Bump the five gems behind advisories (handoff item 2)

Seven advisories across five gems, one rated **High**.

| Gem | Installed | Severity | Fix | Why it matters here |
|---|---|---|---|---|
| **websocket-driver** | 0.8.1 | **High** — CVE-2026-61666 | `>= 0.8.2` | `actioncable`'s own dependency. `/cable` is mounted and held open **continuously by every device** — it carries the `{head_seq}` nudge. A DoS via malformed `Host` header lands on the always-on socket. |
| loofah | 2.25.1 | Medium + 2 | `>= 2.25.2` | Action Text sanitization — the path rendering user-authored project notes and build-log entries. `javascript:` URI bypasses. |
| rails-html-sanitizer | 1.7.0 | XSS | `>= 1.7.1` | Same Action Text path. |
| nokogiri | 1.19.3 | Low + 8 | `>= 1.19.4` | Parses **untrusted user file content** — `Maker::Previews::Lbrn2` reads uploaded `.lbrn2`/`.lbrn` XML. Several advisories are use-after-free in exactly that surface. |
| crass | 1.0.6 | DoS ×4 | `>= 1.0.7` | Transitive via loofah; CSS parser. |

All five are transitive or loosely pinned, so this is a **lockfile bump, not a constraint change**.
`Gemfile:505` already permits `nokogiri 1.19.4` under `~> 1.18`; the other four are not named in the
`Gemfile` at all.

**Files:**
- Modify: `Gemfile.lock`

- [ ] **Step 1: Record the pre-bump state of the pin you must not disturb**

```bash
grep -n 'lexxy' Gemfile Gemfile.lock
```

Keep this output. `lexxy` is pinned to an exact version on purpose (it shed its beta suffix in June 2026
and shipped six releases in 24 days); the Gemfile comment says to bump it deliberately with a manual
editor re-check.

- [ ] **Step 2: Bump exactly the five gems**

```bash
bundle update nokogiri loofah rails-html-sanitizer crass websocket-driver
```

- [ ] **Step 3: Verify by exit code**

```bash
bin/bundler-audit >/dev/null 2>&1; echo "audit=$?"
```

Expected: `audit=0`

- [ ] **Step 4: Verify all seven nokogiri platform lines moved, not just your Mac's**

Nokogiri ships platform-specific gems. If only `arm64-darwin` bumped, CI's linux runner resolves
differently from your machine.

```bash
grep -nE '^    nokogiri \(1\.' Gemfile.lock
```

Expected: **7 lines**, every one at `1.19.4` (or later) — `aarch64-linux-gnu`, `aarch64-linux-musl`,
`arm-linux-gnu`, `arm-linux-musl`, `arm64-darwin`, `x86_64-linux-gnu`, `x86_64-linux-musl`.

- [ ] **Step 5: Verify nothing else rode along**

```bash
git diff --stat
git diff Gemfile.lock | grep -E '^[+-]    [a-z]' | sort
```

Expected: `Gemfile.lock` is the **only** changed file, and the only gems appearing are the five named
plus their checksum lines. **If `lexxy` appears in that diff, `git checkout Gemfile.lock` and redo Step 2
naming only the five gems** — a blanket `bundle update` rides it in silently.

- [ ] **Step 6: Run all three backend legs**

```bash
bin/rails test
```

```bash
LIBRARY_PATH=$(mktemp -d) LIBRARY_BACKEND=share bin/rails test
```

```bash
LIBRARY_BACKEND=s3 LIBRARY_S3_BUCKET=ci-not-a-real-bucket LIBRARY_S3_REGION=us-east-1 \
  LIBRARY_S3_ACCESS_KEY_ID=ci LIBRARY_S3_SECRET_ACCESS_KEY=ci LIBRARY_S3_PREFIX=library \
  bin/rails test
```

Expected on each: `1625 runs, 5655 assertions, 0 failures, 0 errors, 14 skips`.

The loofah / rails-html-sanitizer bump is the one with real regression surface — it is the Action Text
sanitizer, which `Maker::TextOnlyRichText` sits on top of. If anything goes red, it will be in the
notes / build-log-entry tests.

- [ ] **Step 7: Run the system tests too**

```bash
bin/rails db:test:prepare test:system
```

Expected: `6 runs, 28 assertions, 0 failures, 0 errors`.

- [ ] **Step 8: Commit**

```bash
git add Gemfile.lock
git commit -m "chore(deps): five gems behind advisories, one High on the always-on /cable path

websocket-driver 0.8.1 is actioncable's own dependency and CVE-2026-61666
is a DoS via malformed Host header — /cable is held open continuously by
every device to carry the {head_seq} nudge, so it is the most exposed
socket we have. loofah + rails-html-sanitizer + crass are the Action Text
sanitizer path that renders user-authored notes and build-log entries;
nokogiri parses untrusted uploaded .lbrn2 XML in Maker::Previews::Lbrn2,
and several of its advisories are use-after-free in exactly that surface.

Lockfile-only: all five are transitive or loosely pinned. Named
explicitly rather than a bare bundle update, which would have ridden in
the deliberate exact lexxy pin. All 7 nokogiri platform lines moved, so
the linux runner resolves what this Mac does.

bin/bundler-audit now exits 0. Suite green on chunk, share and s3."
```

### Do not

- **Do not `bundle update` bare.** See Step 5.
- **Do not add anything to `config/bundler-audit.yml`'s ignore list** to make this go green. Every one of
  these is a real advisory on a reachable path.

---

## Task 4: Confirm all three security gates go green by exit code (handoff item 3)

Tasks 2 and 3 are only done when this passes. This is a verification task; it produces no commit.

**Files:** none.

- [ ] **Step 1: Run all three gates, reading only exit codes**

```bash
bin/brakeman --no-pager >/dev/null 2>&1; echo "brakeman=$?"
bin/bundler-audit        >/dev/null 2>&1; echo "audit=$?"
bin/importmap audit      >/dev/null 2>&1; echo "js=$?"
```

Expected: `brakeman=0`, `audit=0`, `js=0`. `importmap audit` was already green — leave it alone.

- [ ] **Step 2: Confirm these are the commands CI actually runs**

```bash
sed -n '26,58p' .github/workflows/ci.yml
```

Expected: the `scan_ruby` job runs `bin/brakeman --no-pager` then `bin/bundler-audit`, and `scan_js` runs
`bin/importmap audit`. If the workflow has drifted from these three commands, the local check above is not
the gate and you must reconcile before claiming this task.

- [ ] **Step 3: Note what you cannot verify, and say so**

`ci.yml` **cannot run today** — all 7 jobs declare `runs-on: [self-hosted, linux]` and no Linux runner is
registered (Task 8 documents this). Do **not** claim "CI is green"; claim "the three gate commands exit 0
locally, which is exactly what `scan_ruby`/`scan_js` execute". Pushing will queue the jobs forever, not
fail them — `mergeStateStatus` stays UNSTABLE with 0 elapsed.

---

## Task 5: Ship the boxes sidecar's GPL-3.0 licence inside its image (handoff item 6)

We build `sidecar/boxes` and push it to a registry — that is redistribution, and the GPL-3.0 licence text
belongs inside the image. `sidecar/openscad` (GPL-2.0) already does this (`Dockerfile:104`); `sidecar/boxes`
has a `LICENSE` in the repo and never copies it in.

This is the **one §9 rule with no test behind it**. `test/deploy_hygiene_test.rb` exists precisely because
it can see files the Rails process never loads, and both its existing assertions guard real shipped bugs.
Close the class, not the instance — so the test comes first.

**Files:**
- Modify: `test/deploy_hygiene_test.rb`
- Modify: `sidecar/boxes/Dockerfile:26`

- [ ] **Step 1: Write the failing test**

Append inside `class DeployHygieneTest` in `test/deploy_hygiene_test.rb`, after the existing
`"the OVH overlay clears every sidecar URL it cannot reach"` test:

```ruby
  test "every GPL sidecar image carries its own licence text" do
    # CLAUDE.md §9: we build these images and push them to a registry, which is REDISTRIBUTION —
    # so the licence has to be INSIDE the image, not merely beside the Dockerfile in this repo.
    # A DIRECTORY-DRIVEN sweep, not a hard-coded pair: the point is to close the class, so a third
    # sidecar added later is covered on the day it appears rather than the day someone remembers.
    # Discovery is "has a LICENSE next to a Dockerfile" — every sidecar here is GPL by construction
    # (that is why they are sidecars invoked over HTTP instead of libraries we link).
    sidecars = ROOT.glob("sidecar/*/Dockerfile").select { |df| df.dirname.join("LICENSE").exist? }
    assert sidecars.any?, "expected at least one sidecar/<name>/Dockerfile with a LICENSE beside it"

    sidecars.each do |dockerfile|
      name = dockerfile.dirname.basename.to_s
      copies_licence = dockerfile.read.lines.any? { |l| l.start_with?("COPY") && l.include?("LICENSE") }
      assert copies_licence,
             "sidecar/#{name}/Dockerfile must COPY its LICENSE into the image — we push this image, " \
             "which is redistribution (CLAUDE.md §9). sidecar/openscad is the pattern to copy."
    end
  end
```

- [ ] **Step 2: Run it and watch it fail for the right reason**

```bash
bin/rails test test/deploy_hygiene_test.rb
```

Expected: **1 failure**, message `sidecar/boxes/Dockerfile must COPY its LICENSE into the image…`.
If it fails naming `openscad` instead, or passes, stop — the glob or the discovery rule is wrong, and a
guard that passes for the wrong reason is worse than none.

- [ ] **Step 3: Fix the Dockerfile**

In `sidecar/boxes/Dockerfile`, replace line 26:

```dockerfile
COPY app.py ./
```

with:

```dockerfile
COPY app.py ./

# The GPL-3.0 licence text travels INSIDE the image: we build this and push it to a registry, which
# is redistribution. sidecar/openscad does the same for its GPL-2.0 text. Guarded by
# test/deploy_hygiene_test.rb, which can see this file — the Rails process never loads it.
COPY LICENSE README.md ./
```

- [ ] **Step 4: Confirm `LICENSE` and `README.md` are actually copyable from the build context**

```bash
ls -la sidecar/boxes/LICENSE sidecar/boxes/README.md
head -3 sidecar/boxes/LICENSE
```

Expected (verified 2026-07-29): `LICENSE` is 35147 bytes beginning `GNU GENERAL PUBLIC LICENSE /
Version 3, 29 June 2007`, and `README.md` is 1375 bytes. Both must exist — a `COPY` of a missing path
fails the build, and the repo-root `.dockerignore` does not apply here (each sidecar builds from its own
directory as context). If either has since moved, drop it from the COPY line rather than guessing.

- [ ] **Step 5: Run the test to verify it passes**

```bash
bin/rails test test/deploy_hygiene_test.rb
```

Expected: `3 runs, … 0 failures, 0 errors`.

- [ ] **Step 6: Verify the sidecar image still builds and the licence landed in it**

```bash
docker build -t tinkerex-boxes-licencecheck sidecar/boxes
```

```bash
docker run --rm --entrypoint sh tinkerex-boxes-licencecheck -c 'ls -la LICENSE && head -3 LICENSE'
```

Expected: the file is present in the image's working directory and its first lines are the GPL-3.0 header.
If Docker is unavailable on this box, say so explicitly rather than skipping silently — the test in Step 5
checks the *Dockerfile*, not the *image*, and only this step closes that gap.

- [ ] **Step 7: Commit**

```bash
git add test/deploy_hygiene_test.rb sidecar/boxes/Dockerfile
git commit -m "fix(sidecar): the GPL-3.0 licence text must ship inside the boxes image

We build sidecar/boxes and push it to a registry — redistribution — so
the licence belongs in the image, not merely beside the Dockerfile in
this repo. sidecar/openscad already does this for its GPL-2.0 text; the
two disagreed.

The guard is directory-driven rather than a hard-coded pair, so it closes
the class: a third GPL sidecar is covered the day it appears. It lives in
deploy_hygiene_test.rb because that file exists precisely to see files
the Rails process never loads — the same reason its other two assertions
(the /sidecar/ dockerignore line, the OVH URL blanks) live there, both of
which guard real shipped bugs. This was the one §9 rule with no test."
```

---

## Task 6: Install F3D so STEP / IGES / OBJ previews work on the shipped image (handoff item 8)

`Maker::Previews::Registry` maps `obj`, `step`, `stp`, `iges`, `igs` → `Maker::Previews::Mesh`, which
shells out to the **F3D** CLI. The `Dockerfile` builds dedicated stages for `stl-thumbnailer`, `resvg`
and `pdfium` but installs **no f3d binary** (`grep -n 'f3d' Dockerfile` finds only a comment). It
degrades correctly — `Mesh.available?` gates on the binary and those extensions fall through to
`unsupported` — but the CAD formats closest to this product's audience silently have no preview while
the code reads as though they do.

**Decision taken: install it.** F3D is **BSD-3**; its OCCT dependency is **LGPL** and stays
process-isolated in the subprocess, the same §9 posture as the GPL sidecars.

**The build target is `linux/amd64`** (`config/deploy.yml` sets `builder: arch: amd64`; the image is
cross-built once on the Mac via QEMU and both boxes pull it), so `F3D-3.5.0-Linux-x86_64.tar.xz`
(58.4 MB compressed) is the right asset.

**Files:**
- Create: `test/fixtures/files/tetra.obj`
- Modify: `test/services/maker/previews/mesh_test.rb`
- Modify: `Dockerfile`

### ⚠ The trap in this task

`Maker::Previews::Mesh#to_output` builds its argv at **`mesh.rb:59-60`** and splats it into
`Open3.capture3` at **`mesh.rb:62`**. `config/brakeman.ignore`'s entry for this records **line 59** —
brakeman reports where the flagged expression is *built*, not where it is called, which is why the
recorded line is 59 and not 62. That is not drift; do not "correct" it.

**If you add a flag (e.g. `--rendering-backend=egl`) to make headless rendering work, brakeman goes
back to exit 3 and Task 2's work silently unravels.** The fingerprint hashes `warning_code + code +
location + file + confidence` — `code` is the rendered argv, so changing the argv changes the
fingerprint and the existing entry stops matching. (The line number is *not* in the hash, so merely
moving the call is harmless.) If that happens you must regenerate the `mesh.rb` ignore entry using
Task 2's procedure and re-run Task 4. Check before you commit, not after.

- [ ] **Step 1: Write the OBJ fixture**

`obj` is in `Mesh::EXTENSIONS` but every existing render test feeds `tetra.stl`. Create
`test/fixtures/files/tetra.obj` — a unit tetrahedron, four vertices and four faces:

```
# Minimal tetrahedron for Maker::Previews::Mesh's OBJ path.
# OBJ face indices are 1-based. Four vertices, four triangular faces, no normals or materials —
# the renderer only needs geometry, and a materials reference would need a second file.
v 0.0 0.0 0.0
v 1.0 0.0 0.0
v 0.0 1.0 0.0
v 0.0 0.0 1.0
f 1 3 2
f 1 2 4
f 1 4 3
f 2 3 4
```

- [ ] **Step 2: Write the failing test**

In `test/services/maker/previews/mesh_test.rb`, add to the `setup` block and append a test. Replace:

```ruby
      setup { @stl = File.binread(Rails.root.join("test/fixtures/files/tetra.stl")) }
```

with:

```ruby
      setup do
        @stl = File.binread(Rails.root.join("test/fixtures/files/tetra.stl"))
        @obj = File.binread(Rails.root.join("test/fixtures/files/tetra.obj"))
      end
```

and add, after the `"renders an STL to a PNG thumbnail via f3d"` test:

```ruby
      # OBJ is the one extension Mesh::EXTENSIONS actually OWNS that had no render coverage — the
      # other three tests all feed STL, which routes to the euc Stl renderer in production and only
      # reaches F3D here because the test calls Mesh directly. So an F3D build that could not load an
      # OBJ would have passed the whole suite.
      test "renders an OBJ to a PNG thumbnail via f3d" do
        skip "f3d not installed" unless Maker::Previews::Mesh.available?
        result = Maker::Previews::Mesh.render(@obj, size: 128, ext: "obj")
        assert_equal "image/png", result[:content_type]
        assert_equal 128, result[:width]
        assert_equal "\x89PNG".b, result[:bytes][0, 4].b
      end
```

- [ ] **Step 3: Run it — it must SKIP, not fail, on this Mac**

```bash
bin/rails test test/services/maker/previews/mesh_test.rb
```

Expected: `5 runs, … 0 failures, 0 errors, 4 skips` (f3d is not installed on the build box; the
`available?` test still runs). A **failure** here means the fixture or the `ext:` argument is wrong.

If you want the test to actually execute before touching Docker, install F3D locally and re-run:

```bash
brew install --cask f3d && bin/rails test test/services/maker/previews/mesh_test.rb
```

Expected then: `5 runs, … 0 failures, 0 skips`. This is optional but it is the cheapest way to prove the
fixture is good before spending a Docker build on it.

- [ ] **Step 4: Commit the test half**

```bash
git add test/fixtures/files/tetra.obj test/services/maker/previews/mesh_test.rb
git commit -m "test(previews): OBJ is the extension Mesh actually owns and had no render test

Every existing Mesh test feeds tetra.stl, which in production routes to
the euc Stl renderer and only reaches F3D because the test calls Mesh
directly. So an F3D build unable to load an OBJ would pass the suite.
Skips without the binary, matching the file's existing posture."
```

- [ ] **Step 5: Measure the image size BEFORE**

```bash
docker build --platform linux/amd64 -t tinkerex:before .
docker image inspect tinkerex:before --format '{{.Size}}' | awk '{printf "before: %.1f MB\n", $1/1e6}'
```

Write the number down. F3D pulls a real rendering stack, and the reason every other renderer here is a
small static binary is that the image stays lean — you cannot judge the trade without both numbers.

- [ ] **Step 6: Add the F3D builder stage**

In `Dockerfile`, after the `pdfium` stage (which ends at line 84 with the `curl … chmod +x /tmp/pdfium`
RUN) and before `# Final stage for app image`, insert:

```dockerfile
# ---- F3D: mesh + CAD → PNG/GLB (BSD-3 — CLAUDE.md §9). The one renderer here that is NOT a small
# static binary: it carries VTK, and through its OCCT plugin it is what gives STEP/IGES a preview at
# all. OCCT is LGPL and stays process-isolated in the f3d subprocess — the same posture §9 takes for
# the GPL sidecars and the FUSE drivers, and the reason Maker::Previews::Mesh shells out rather than
# linking. Official prebuilt tarball; the deploy builds linux/amd64, so x86_64 is the right asset.
FROM base AS f3d
ARG F3D_VERSION=3.5.0
RUN curl -fsSL "https://github.com/f3d-app/f3d/releases/download/v${F3D_VERSION}/F3D-${F3D_VERSION}-Linux-x86_64.tar.xz" \
      -o /tmp/f3d.tar.xz && \
    mkdir -p /opt/f3d && \
    tar -xJf /tmp/f3d.tar.xz -C /opt/f3d --strip-components=1 && \
    rm /tmp/f3d.tar.xz
```

- [ ] **Step 7: Add F3D's runtime libraries to the final stage**

In the final stage, insert **before** the existing `RUN groupadd --system --gid 1000 rails` (currently
line 89) — it must be before `USER 1000:1000`, since apt needs root:

```dockerfile
# F3D's runtime libraries. It renders OFFSCREEN (Maker::Previews::Mesh always passes --output), so
# there is no X server and no GPU — Mesa's software EGL is what actually draws. These are the only
# packages in this image that exist for one renderer; every other one is a static binary, which is
# why they are listed here rather than folded into `base`.
RUN apt-get update -qq && \
    apt-get install --no-install-recommends -y \
      libegl1 libgl1 libglx-mesa0 libgl1-mesa-dri libgomp1 \
      libx11-6 libxext6 libxrender1 libxcursor1 libxi6 libxrandr2 && \
    rm -rf /var/lib/apt/lists /var/cache/apt/archives
```

**This list is a starting point, not a verified fact** — Step 9 discovers the real set with `ldd` and you
adjust it there.

- [ ] **Step 8: Copy the tree in and point the app at it**

In the final stage, after the existing `COPY --from=pdfium /tmp/pdfium /usr/local/bin/pdfium` (line 107),
append:

```dockerfile
# F3D → Maker::Previews::Mesh#available? is true, so .obj/.step/.stp/.iges/.igs get a thumbnail (and
# the model_glb kind gets a GLB) instead of falling through to `unsupported`.
#
# F3D_BIN RATHER THAN A PATH SYMLINK: the renderer already reads ENV["F3D_BIN"], and the final stage
# has switched to USER 1000:1000 by the time these COPYs run, so a `RUN ln -s` into /usr/local/bin
# would need root back. Pointing the existing knob at the tree is the smaller change and keeps F3D's
# own bin/../lib layout intact (the binary resolves its libraries and plugins relative to itself).
COPY --from=f3d /opt/f3d /opt/f3d
ENV F3D_BIN="/opt/f3d/bin/f3d"
```

- [ ] **Step 9: Build, then discover the real library set from inside the image**

```bash
docker build --platform linux/amd64 -t tinkerex:f3d .
```

```bash
docker run --rm --platform linux/amd64 --entrypoint sh tinkerex:f3d -c \
  'ldd /opt/f3d/bin/f3d | grep -i "not found" || echo "ALL LIBS RESOLVED"'
```

Expected: `ALL LIBS RESOLVED`. If any library is reported "not found", add the Debian package providing
it to Step 7's list and rebuild. Conversely, once it resolves, try trimming packages you did not need —
but only one at a time, rebuilding between, and stop the moment Step 10 goes red.

- [ ] **Step 10: Prove F3D actually runs and can read the CAD formats**

```bash
docker run --rm --platform linux/amd64 --entrypoint sh tinkerex:f3d -c '/opt/f3d/bin/f3d --version'
```

Expected: a version banner containing `f3d` (this is exactly what `Mesh.available?` greps for).

```bash
docker run --rm --platform linux/amd64 --entrypoint sh tinkerex:f3d -c \
  '/opt/f3d/bin/f3d --list-readers'
```

Expected: the listing includes **STEP** and **IGES** readers (the OCCT plugin) and **OBJ**. If STEP/IGES
are absent, the plain tarball does not carry the OCCT plugin on this release — stop and report that
before going further, because it means item 8's headline (STEP/IGES previews) is not achieved by this
asset and the raytracing build or a different packaging has to be evaluated.

- [ ] **Step 11: Prove a real headless render inside the image, through the app's own code path**

This is the step that matters — `--version` succeeding proves nothing about offscreen rendering.

```bash
docker run --rm --platform linux/amd64 --entrypoint sh tinkerex:f3d -c '
  cd /rails && RAILS_ENV=production ./bin/rails runner "
    puts %(available?=#{Maker::Previews::Mesh.available?})
    bytes  = File.binread(Rails.root.join(%(test/fixtures/files/tetra.obj)))
    result = Maker::Previews::Mesh.render(bytes, size: 128, ext: %(obj))
    puts %(png=#{result[:bytes][0,4].b.inspect} size=#{result[:bytes].bytesize})
  "'
```

Expected: `available?=true` and `png="\\x89PNG" size=<some positive number>`.

If the fixture is not in the image (the Dockerfile's `COPY . .` may exclude `test/` — check
`.dockerignore`), write the OBJ inline in the runner script with a heredoc instead of reading the fixture.

If rendering fails with an EGL/display error, F3D needs an explicit backend. **Read the trap at the top of
this task first**, then add `--rendering-backend=egl` (or `osmesa`, adding `libosmesa6`) to the argv in
`app/services/maker/previews/mesh.rb:57`, and regenerate the `mesh.rb` brakeman fingerprint.

- [ ] **Step 12: Measure the image size AFTER, and record the delta**

```bash
docker image inspect tinkerex:f3d --format '{{.Size}}' | awk '{printf "after: %.1f MB\n", $1/1e6}'
```

Write both numbers into the commit message. The F3D tarball is 58.4 MB compressed, so expect a
substantial uncompressed delta plus the Mesa/X libraries.

- [ ] **Step 13: Run the full suite (the local one still skips — that is correct)**

```bash
bin/rails test
```

Expected: `1626 runs, … 0 failures, 0 errors, 15 skips` — one more run and one more skip than the
baseline, from the new OBJ test skipping on this f3d-less Mac.

- [ ] **Step 14: Commit**

```bash
git add Dockerfile
git commit -m "feat(previews): install F3D, so STEP/IGES/OBJ actually preview on the deployed image

Registry has mapped obj/step/stp/iges/igs to Maker::Previews::Mesh since
the preview pipeline shipped, and Mesh shells out to f3d — which the
Dockerfile never installed. It degraded correctly (available? gates on
the binary, so those extensions fell through to unsupported) but the CAD
formats closest to this product's audience silently had no preview while
the code read as though they did.

BSD-3; the LGPL OCCT dependency stays process-isolated in the subprocess,
the same §9 posture as the GPL sidecars. Wired via the renderer's
existing F3D_BIN knob rather than a PATH symlink: the final stage is
already USER 1000:1000 when the COPYs run, and F3D resolves its own libs
and plugins relative to the binary.

Image size: <before> MB -> <after> MB. Verified in the built image:
libraries resolve, --list-readers carries STEP/IGES/OBJ, and a real
headless render of tetra.obj through Maker::Previews::Mesh returns a PNG."
```

Replace `<before>`/`<after>` with the Step 5 and Step 12 numbers.

---

## Task 7: Delete the stale test count from `CLAUDE.md` (handoff item 10)

`CLAUDE.md:276` states `fs-provider` has **"53 tests"**. Measured: `192 passed` across 20 binaries.
`CLAUDE.md` defers per-suite counts to `docs/STATUS.md` everywhere else, so **delete the number rather
than updating it** — a count in two places is a count that will be wrong in one of them.

**Files:**
- Modify: `CLAUDE.md:276`

- [ ] **Step 1: Confirm the real number, so the commit message is not itself a guess**

```bash
(cd client/fs-provider && cargo test --quiet 2>&1 | tail -30)
```

Expected: 20 test binaries, `192 passed; 0 failed` in total. (This is a Rust build — it may take several
minutes cold and does not need the Rails app.)

- [ ] **Step 2: Make the edit**

In `CLAUDE.md:276`, change:

```
- `fs-provider`: local SQLite tree + FastCDC chunks + `export_tree`/`apply_remote`/`apply_remote_delete`/`truncate`. **53 tests** across hermetic suites (`tests/`): **caching** (mtime-freshness + random-write-on-hydrated), **chunking**
```

to:

```
- `fs-provider`: local SQLite tree + FastCDC chunks + `export_tree`/`apply_remote`/`apply_remote_delete`/`truncate`. Hermetic suites (`tests/`; count in `docs/STATUS.md`): **caching** (mtime-freshness + random-write-on-hydrated), **chunking**
```

- [ ] **Step 3: Verify no other stale count survives in this file**

```bash
grep -nE '\*\*[0-9]+ tests?\*\*|\b[0-9]{2,4} (tests|runs)\b' CLAUDE.md
```

Read each hit. Any *count* of a suite that `docs/STATUS.md` also carries should be deleted the same way;
counts that appear inside a **historical narrative** ("Server suite 75 tests" in a dated §11 entry,
"523 → 635") are records of what a past arc moved and stay — they describe a moment, not the present.

- [ ] **Step 4: Commit**

```bash
git add CLAUDE.md
git commit -m "docs(claude): delete the stale fs-provider count rather than updating it

CLAUDE.md said 53 tests; cargo test says 192 across 20 binaries. This
file defers per-suite counts to docs/STATUS.md everywhere else — a count
in two places is a count that will be wrong in one of them, and this one
already was."
```

---

## Task 8: Correct CLAUDE.md §15's runner claim and document the CI gap

**Documentation only. Do not retarget any job. Do not add `ubuntu-latest`.** A separate agent will fix
CI and testing.

All 7 jobs in `.github/workflows/ci.yml` declare `runs-on: [self-hosted, linux]`. The GitHub API reports
exactly one registered runner. CLAUDE.md §15 says the repo "has all three registered" — that is stale,
and it is the sentence that would stop the next reader diagnosing this in ten seconds.

**Files:**
- Modify: `CLAUDE.md` (§15, the CI bullet)
- Modify: `docs/STATUS.md`

- [ ] **Step 1: Re-measure, so the doc records today rather than the handoff's yesterday**

```bash
gh api repos/:owner/:repo/actions/runners \
  --jq '.runners[] | "\(.name)  status=\(.status)  labels=\([.labels[].name]|join(","))"'
```

Expected at time of writing: one line, `charless-MacBook-Pro-maker-mac  status=online
labels=self-hosted,macOS,ARM64,maker-mac`. **Use what this prints** — if a Linux runner has come back,
this whole task collapses to deleting the STATUS.md note, and you should say so instead of writing a
finding that is no longer true.

- [ ] **Step 2: Correct §15's runner list in `CLAUDE.md`**

Find the bullet beginning `- **CI runs on SELF-HOSTED runners only — never GitHub-hosted.**` and replace
the parenthetical claim:

```
  `runs-on: [self-hosted, linux|macos|windows]` (the repo has all three registered:
  `flasher-maker-linux`, `charless-MacBook-Pro-maker-mac`, `CHAIMDESK-maker-windows`).
```

with:

```
  `runs-on: [self-hosted, linux|macos|windows]`. **Only ONE runner is registered today (2026-07-29):
  `charless-MacBook-Pro-maker-mac` (macOS). `flasher-maker-linux` and `CHAIMDESK-maker-windows` are
  NOT registered** — verify with `gh api repos/:owner/:repo/actions/runners` rather than trusting this
  line. Consequence: all 7 `ci.yml` jobs target linux and **queue forever** rather than failing, so a
  PR sits UNSTABLE at 0 elapsed and merging needs `--admin` (PR #94 did). Verify locally instead —
  see `docs/STATUS.md`, "CI cannot run".
```

- [ ] **Step 3: Add the finding to `docs/STATUS.md`**

Insert a new section immediately before the existing `## Still open after this arc (small, deliberate)`
heading (line 134):

```markdown
## CI cannot run — no Linux runner is registered (2026-07-29)

**Open, and assigned elsewhere: a separate agent owns fixing CI + testing infrastructure.** Recorded
here so nobody re-diagnoses it.

All 7 jobs in `.github/workflows/ci.yml` declare `runs-on: [self-hosted, linux]`.
`gh api repos/:owner/:repo/actions/runners` reports exactly one runner —
`charless-MacBook-Pro-maker-mac`, macOS. So every job **queues forever** rather than failing: on PR #94
they sat `pending` with **0 elapsed**, `mergeStateStatus` stayed UNSTABLE, and the merge needed
`--admin`. CLAUDE.md §15 claimed all three runners were registered; corrected in the same commit.

**The fix is NOT `ubuntu-latest`** — §15 forbids GitHub-hosted runners because they are the only billed
ones. Either re-register a Linux runner, or retarget at the Mac, noting that `system-test` needs headless
Chrome and `db:test:prepare` there and that the Mac then serialises every PR check.

**Until then, verify locally — this is exactly what those jobs run:**

    bin/rails test
    LIBRARY_PATH=$(mktemp -d) LIBRARY_BACKEND=share bin/rails test
    LIBRARY_BACKEND=s3 LIBRARY_S3_BUCKET=ci-not-a-real-bucket LIBRARY_S3_REGION=us-east-1 \
      LIBRARY_S3_ACCESS_KEY_ID=ci LIBRARY_S3_SECRET_ACCESS_KEY=ci LIBRARY_S3_PREFIX=library \
      bin/rails test
    bin/rails db:test:prepare test:system
    bin/rubocop
    bin/brakeman --no-pager >/dev/null 2>&1; echo "brakeman=$?"   # must be 0
    bin/bundler-audit        >/dev/null 2>&1; echo "audit=$?"     # must be 0
    bin/importmap audit      >/dev/null 2>&1; echo "js=$?"        # must be 0

**Read the last three by EXIT CODE, not by output.** Until 2026-07-29 `bin/brakeman` exited 3, and
because `scan_ruby` runs it as step 1 and `bin/bundler-audit` as step 2, the audit gate had **never
executed** — the job looked like two gates and was zero. That is how five gems drifted behind published
advisories, one of them High on the always-on `/cable` path.
```

- [ ] **Step 4: Verify the docs are internally consistent**

```bash
grep -n 'flasher-maker-linux\|CHAIMDESK-maker-windows' CLAUDE.md docs/STATUS.md
```

Every surviving hit must be inside text that says those runners are **not** registered, or inside a dated
historical entry. A bare present-tense claim that they exist is the thing being fixed.

- [ ] **Step 5: Commit**

```bash
git add CLAUDE.md docs/STATUS.md
git commit -m "docs(ci): only the Mac runner is registered, so all 7 ci.yml jobs queue forever

CLAUDE.md §15 said the repo has linux, macOS and windows runners
registered. The API reports one: charless-MacBook-Pro-maker-mac. Every
ci.yml job targets [self-hosted, linux], so they never start and never
fail — PR #94 sat UNSTABLE at 0 elapsed and merged with --admin.

Documentation only; a separate agent owns the CI fix. Records the local
verification recipe, and why the last three commands must be read by exit
code: brakeman exiting 3 meant bundler-audit had never run at all."
```

---

## Task 9: Document the `ENABLE_TEST_SIGNUP` deep-merge inheritance

**Documentation only — no behavioural change.** The decision was made deliberately.

`config/deploy.yml:64` sets `ENABLE_TEST_SIGNUP: true` in the **base** config, with a comment justifying
it for the LAN-only Unraid box. Kamal **deep-merges** `env.clear`, so `-d ovh` inherits it —
and `config/deploy.ovh.yml` blanks `BOXES_SIDECAR_URL` / `OPENSCAD_SIDECAR_URL` for exactly that
deep-merge reason while leaving this one alone. The base config's stated justification ("this Unraid
instance is a NON-production test/dev deploy") does not cover the OVH box.

The seam itself: `config/routes.rb:191` draws `POST /v1/test/users` when the env var is present **or** the
environment is non-production, and `app/controllers/v1/test_users_controller.rb:15` gates the action on
the same var. It creates **confirmed accounts with no email verification**.

It is genuinely load-bearing on Unraid: `client/test-conformance/two-device-cfapi.ps1` defaults its
server to `http://192.168.1.95` and enrolls through that seam, as do
`two-device-fuse.sh`, `two-device-webdav-macos.sh` and three `.github/workflows` jobs (those last four
set the var on a server they boot themselves, so only the cfapi one depends on the *deployed* box).

**Files:**
- Modify: `config/deploy.ovh.yml` (comment only)
- Modify: `docs/STATUS.md`

- [ ] **Step 1: Re-verify the inheritance before documenting it**

```bash
grep -n 'ENABLE_TEST_SIGNUP' config/deploy.yml config/deploy.ovh.yml config/deploy.s3.yml config/deploy.share.yml
```

Expected: one hit, `config/deploy.yml:64`. No overlay mentions it, which is the finding.

- [ ] **Step 2: Add the comment to `config/deploy.ovh.yml`**

In the `env.clear` block, after the `OPENSCAD_SIDECAR_URL: ""` line, append:

```yaml

    # ENABLE_TEST_SIGNUP IS INHERITED HERE, DELIBERATELY AND WITH EYES OPEN (2026-07-29).
    #
    # deploy.yml's env.clear sets ENABLE_TEST_SIGNUP: true, and Kamal DEEP-MERGES env.clear — the same
    # mechanism the two blank lines above exist to defeat. So this box, unlike the LAN-only Unraid one
    # the base comment justifies, serves POST /v1/test/users: an unverified signup that mints CONFIRMED
    # accounts, reachable by anyone who can reach the host.
    #
    # Accepted for now because this is a prod-LIKE TEST box, not the managed SaaS. Blanking it is one
    # line (`ENABLE_TEST_SIGNUP: ""`) beside the sidecar blanks above, and that is the fix the day this
    # box holds anything real. The boot warning fires either way
    # (config/initializers/test_signup_warning.rb).
    #
    # NOT blanked at the base instead, because the Unraid box needs it:
    # client/test-conformance/two-device-cfapi.ps1 enrolls against http://192.168.1.95 through this
    # seam. The other harnesses boot their own server and set the var themselves.
```

- [ ] **Step 3: Add the finding to `docs/STATUS.md`**

Append to the `## Still open after this arc (small, deliberate)` list (the section at line 134):

```markdown
- **`ENABLE_TEST_SIGNUP` is inherited by the OVH deployment, knowingly.** `config/deploy.yml:64` sets it
  in the **base** env.clear, which Kamal deep-merges, so `-d ovh` gets it too — the base comment's
  justification ("this Unraid instance is a NON-production test/dev deploy") covers the LAN box only.
  `POST /v1/test/users` mints **confirmed accounts with no email verification**. Left ON deliberately:
  OVH is a prod-*like* test box, and blanking it at the base would break
  `client/test-conformance/two-device-cfapi.ps1`, which enrolls against the deployed Unraid server
  through this seam. The fix, when this stops being acceptable, is one line —
  `ENABLE_TEST_SIGNUP: ""` in `config/deploy.ovh.yml` beside the two sidecar-URL blanks, which exist to
  defeat exactly this deep-merge. Recorded at the edit site too.
```

- [ ] **Step 4: Verify the YAML still parses and the overlay is unchanged in behaviour**

```bash
ruby -ryaml -e 'o = YAML.load_file("config/deploy.ovh.yml", aliases: true); puts o.dig("env","clear").inspect'
```

Expected: the same seven keys as before your edit — `STORAGE_BACKEND`, `CHUNK_ENDPOINT`, `CHUNK_BUCKET`,
`CHUNK_REGION`, `CHUNK_ACCESS_KEY_ID`, `BOXES_SIDECAR_URL`, `OPENSCAD_SIDECAR_URL` — and **no
`ENABLE_TEST_SIGNUP` key**, because this task adds a comment, not a value.

- [ ] **Step 5: Confirm the existing hygiene test still passes**

```bash
bin/rails test test/deploy_hygiene_test.rb
```

Expected: `3 runs, … 0 failures, 0 errors` (3 after Task 5).

- [ ] **Step 6: Commit**

```bash
git add config/deploy.ovh.yml docs/STATUS.md
git commit -m "docs(deploy): record that the OVH box inherits ENABLE_TEST_SIGNUP, deliberately

deploy.yml sets it in the BASE env.clear and Kamal deep-merges — the same
mechanism the two sidecar-URL blanks in the OVH overlay exist to defeat.
So POST /v1/test/users, which mints confirmed accounts with no email
verification, is served there too; the base comment only ever justified
the LAN-only Unraid box.

Left ON deliberately (prod-LIKE test box), and NOT blanked at the base
because two-device-cfapi.ps1 enrolls against the deployed Unraid server
through this seam. Documented at the edit site and in STATUS.md so the
one-line fix is obvious the day it is wanted. No behaviour change."
```

---

## Task 10: Record the arc and run final verification

**Files:**
- Modify: `docs/STATUS.md`

- [ ] **Step 1: Re-run every gate and every suite, from a clean state**

```bash
bin/brakeman --no-pager >/dev/null 2>&1; echo "brakeman=$?"
bin/bundler-audit        >/dev/null 2>&1; echo "audit=$?"
bin/importmap audit      >/dev/null 2>&1; echo "js=$?"
bin/rubocop
```

Expected: `0`, `0`, `0`, and `no offenses detected`.

```bash
bin/rails test
```

```bash
LIBRARY_PATH=$(mktemp -d) LIBRARY_BACKEND=share bin/rails test
```

```bash
LIBRARY_BACKEND=s3 LIBRARY_S3_BUCKET=ci-not-a-real-bucket LIBRARY_S3_REGION=us-east-1 \
  LIBRARY_S3_ACCESS_KEY_ID=ci LIBRARY_S3_SECRET_ACCESS_KEY=ci LIBRARY_S3_PREFIX=library \
  bin/rails test
```

```bash
bin/rails db:test:prepare test:system
```

Expected: `1627 runs, … 0 failures, 0 errors, 15 skips` on each of the three legs (baseline 1625, +1 OBJ
test in Task 6, +1 hygiene test in Task 5; the OBJ test skips without f3d, so skips go 14 → 15), and
`6 runs, 28 assertions, 0 failures` on system. **If the three legs disagree with each other, stop** —
that is the standing invariant this repo has caught several one-leg bugs with.

- [ ] **Step 2: Re-run the three architectural tripwires**

```bash
grep -rn "manifest_chunks\|ChunkStore" app/services/maker/ app/models/maker/ app/jobs/maker/ | grep -v ':[0-9]*: *#'
```

Expected: **exactly one** line, `app/services/maker/addons/library_output.rb:47`.

```bash
grep -rn "rescue.*NotImplementedError" app lib | grep -v ':[0-9]*: *#'
```

Expected: nothing.

```bash
grep -rn "port_writable?" app/ | grep -v capabilities.rb
```

Expected: the 5 doors + the UI selects, unchanged from before this arc.

- [ ] **Step 3: Write the arc entry in `docs/STATUS.md`**

Update the `**Updated:**` line at the top and insert a new `## Latest (2026-07-29): …` section above the
existing `## Latest (2026-07-29): the four open items are CLOSED …` section, demoting that one to
`## Earlier (2026-07-29): …`. Cover, with the numbers you actually measured:

- **`scan_ruby` was two gates running zero.** brakeman exited 3 on a false positive, so bundler-audit
  never executed. Both now exit 0. The rule this arc is about: **read a security gate by exit code**.
- **Five gems bumped**, one High (`websocket-driver` / CVE-2026-61666) on the `/cable` socket every device
  holds open. All 7 nokogiri platform lines moved.
- **F3D installed** — STEP/IGES/OBJ previews work on the shipped image for the first time; image size
  `<before>` → `<after>` MB; verified by a real headless render inside the built image, not by
  `--version`. New `tetra.obj` fixture, because every prior Mesh test fed an STL that production routes
  elsewhere.
- **The boxes sidecar ships its GPL-3.0 text**, and `deploy_hygiene_test.rb`'s new third assertion is
  **directory-driven**, so it closes the class rather than the instance.
- **Two documented-only findings**: no Linux runner (CI queues forever; a separate agent owns it) and the
  OVH `ENABLE_TEST_SIGNUP` inheritance.
- **The stale `53 tests` in CLAUDE.md is deleted, not updated** — the real number is 192, and a count in
  two places will be wrong in one of them.

- [ ] **Step 4: Commit**

```bash
git add docs/STATUS.md
git commit -m "docs(status): record the audit-fix arc

Two security gates that were structurally incapable of running now run;
five gems off published advisories; STEP/IGES/OBJ previews exist on the
deployed image for the first time; the GPL-3.0 boxes sidecar ships its
own licence text behind a class-closing test. Two findings documented
rather than fixed, both deliberately."
```

- [ ] **Step 5: Hand off**

Use `superpowers:finishing-a-development-branch` to decide between merge, PR, or further work. Note in
the PR body that **CI will not run** (Task 8) and that the local verification recipe in
`docs/STATUS.md` under "CI cannot run" is what stands in for it.

---

## Deferred, with reasons

Not tasks in this plan. Recorded so they are not rediscovered as omissions.

- **`importer_controller.js` holds a THIRD extension→role table** (handoff §3a; `docs/STATUS.md` "Still
  open"). `roleFor` at lines 10–18 never gained `vector`, `cad_source` or `document`. **Nothing is
  broken** — the value never leaves the browser (only `node_id`/`cover` are POSTed and the server
  re-derives via `Maker::FileAttachment.role_for`), so its only effect is the pre-upload summary, where
  `.txt` behaves exactly as `.svg` already did. Closing it means plumbing the Ruby vocabulary into JS —
  an endpoint or a generated constant — which is a real change with its own design question, not a
  cleanup to fold into an audit-fix branch.
- **`MAX_DATA_BYTES` coverage is asymmetric by construction** (handoff §3b). A limit set too *low* fails a
  test; one set too *high* fails nothing, because every other test derives its filler from the constant.
  Already closed as far as it can be by the test pinning the literal. Nothing to do.
- **The unexplained intermittent** (`SQLite3::BusyException` in `Tools::GeneratorsControllerTest#setup`,
  captured 2026-07-27, never reproduced). If a run in this arc goes red with one error and no pattern,
  re-run before investigating — and if it reproduces, that is news worth its own session.

---

## Self-review

**Spec coverage** — every open item in `docs/HANDOFF-AUDIT-FIXES.md` maps to a task or a documented
deferral:

| Handoff item | Where |
|---|---|
| 1 · brakeman blocked | Task 2 |
| 2 · five gems | Task 3 |
| 3 · confirm CI green | Task 4 (+ Task 8 for why CI itself cannot run) |
| 4 · Active Storage | **already closed** — "Read this first" |
| 5 · bound sheet data | **already closed** — "Read this first" |
| 6 · boxes GPL licence | Task 5 |
| 7 · JS system test | **already closed** — "Read this first" |
| 8 · F3D | Task 6 |
| 9 · file-type vocabularies | **already closed** — "Read this first" |
| 10 · stale test count | Task 7 |
| addendum 1 · no Linux runner | Task 8 (document only, by decision) |
| addendum 2 · `ENABLE_TEST_SIGNUP` | Task 9 (document only, by decision) |
| addendum 3a · JS role table | Deferred, with reason |
| addendum 3b · `MAX_DATA_BYTES` | Deferred, with reason |

**Counts used consistently:** baseline 1625/5655/14 skips → 1626 after Task 6's OBJ test (+1 run, +1
skip) → 1627 after Task 5's hygiene test (+1 run). Task 6 Step 13 says 1626/15, Task 10 Step 1 says
1627/15. Task 5 Step 5 and Task 9 Step 5 both expect `deploy_hygiene_test.rb` at 3 runs.

**Names used consistently:** `Maker::Previews::Mesh` (`available?`, `render`, `to_output`,
`EXTENSIONS`, `F3D`), `Maker::Previews::ImageThumb#render`, `Maker::FileAttachment.role_for`,
`ENV["F3D_BIN"]`, `MAX_DATA_BYTES`.
