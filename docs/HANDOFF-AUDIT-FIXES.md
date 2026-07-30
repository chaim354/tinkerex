# Handoff — audit fix queue

**Source:** `docs/SYSTEM-AUDIT-2026-07-28.md` (full-system audit, commit `6ca3dd7`), plus the four
open items `docs/STATUS.md` records from the project-page overhaul.
**Written:** 2026-07-29. **For:** the next agent picking this up.

Everything below was **observed by running the command shown**, not inferred. Each item carries the
evidence, the fix, the verification, and — where one exists — the trap that will waste your time if
you do not know about it.

---

## Before you start

Baseline at commit `6ca3dd7`, so you can tell whether you broke something rather than found something:

```bash
bin/rails test          # 1587 runs, 5482 assertions, 0 failures, 0 errors, 14 skips
```

The suite must also stay green on **all three backends** — that is a standing invariant in this repo,
not a nicety, and several past bugs were only visible on one leg:

```bash
bin/rails test
LIBRARY_BACKEND=share bin/rails test
LIBRARY_BACKEND=s3 bin/rails test
```

**The single rule that matters for items 1–3: verify security gates by EXIT CODE, never by reading
output.** The whole failure mode being fixed here is a gate that *looked* like it passed.

---

## 1 · 🔴 Unblock `bin/brakeman` so `bin/bundler-audit` can run at all

**Effort:** minutes. **Do this first** — it is what makes item 2 verifiable.

### Evidence

```bash
bin/brakeman --no-pager; echo "exit=$?"    # exit=3  (warnings found)
```

`.github/workflows/ci.yml` runs brakeman as step 1 of the `scan_ruby` job and bundler-audit as
step 2. Step 1 exits non-zero, so **step 2 has never run**. The job looks like two gates and is
currently zero.

### The warning, and why it is a false positive

```
Command Injection — app/services/maker/previews/image_thumb.rb:45
Open3.capture3(BIN, Tempfile.new.path, "--size", "#{size}x#{size}", "-o", "#{Tempfile.new.path}.thumb.png")
```

`Open3.capture3` with an **argv array** execs the binary directly — **no shell is involved**, so
there is no shell-injection vector. `BIN` is operator-controlled (`ENV["VIPSTHUMBNAIL_BIN"]`, default
`vipsthumbnail`), both paths are `Tempfile`-generated rather than user-supplied, and `size` is an
integer preview dimension passed as its own argv element (a malformed value just makes vipsthumbnail
error out, which is handled).

**`config/brakeman.ignore` already contains this exact argument**, written out at length, for
`app/services/maker/previews/mesh.rb:59` — the same `Open3.capture3(*args)` pattern in a sibling
renderer. `image_thumb.rb` was added later and the ignore was never extended to match. This is an
inconsistency, not a risk.

### Fix

Use brakeman's own interactive flow — it writes a correctly-shaped entry with all 15 keys:

```bash
bundle exec brakeman -I
```

The entry you are adding should end up with:

```
fingerprint: 8c103396fda65cd51507f38aaa29004f32f6ff5823fd2695ac5515c334d51d19
file:        app/services/maker/previews/image_thumb.rb
line:        45
```

Give it a `note` modelled on the existing `mesh.rb` one — same reasoning, same shape. Do not write a
thinner note: the value of that file is that a future reader can tell a considered accept from a
rubber stamp.

### Verify

```bash
bin/brakeman --no-pager; echo "exit=$?"    # must be exit=0
```

### Do not

- **Do not "fix" the code to satisfy brakeman.** There is nothing wrong with it; an argv-array
  `capture3` is the correct, shell-free way to call a binary, and it is the pattern every renderer in
  `Maker::Previews::*` uses deliberately.
- **Do not add a blanket suppression** for the Command Injection check. The `mesh.rb` precedent is a
  per-warning fingerprint for a reason.

---

## 2 · 🔴 Five gems behind published advisories, one rated High

**Effort:** ~1 hour, mostly waiting on the suite.

### Evidence

```bash
bundle exec bundler-audit check --update   # 7 advisories across 5 gems
bin/bundler-audit; echo "exit=$?"          # exit=1
```

| Gem | Installed | Severity | Fix | Why it matters *here* |
|---|---|---|---|---|
| **websocket-driver** | 0.8.1 | **High** — CVE-2026-61666 | `>= 0.8.2` | It is **`actioncable`'s own dependency** (`Gemfile.lock:10`). `/cable` is mounted and held open **continuously by every device** — it carries the `{head_seq}` sync nudge. A DoS via malformed `Host` header lands on the always-on socket. |
| loofah | 2.25.1 | Medium + 2 | `>= 2.25.2` | Action Text sanitization — the path that renders user-authored project notes and build-log entries. `javascript:` URI bypasses. |
| rails-html-sanitizer | 1.7.0 | XSS | `>= 1.7.1` | Same Action Text path. |
| nokogiri | 1.19.3 | Low + 8 | `>= 1.19.4` | Parses **untrusted user file content** — `Maker::Previews::Lbrn2` reads uploaded `.lbrn2`/`.lbrn` XML. Several advisories are use-after-free in exactly that surface. |
| crass | 1.0.6 | DoS ×4 | `>= 1.0.7` | Transitive via loofah; CSS parser. |

### Fix

All five are transitive or loosely-pinned, so this is a **lockfile bump, not a constraint change**.
`Gemfile` already permits `nokogiri 1.19.4` under `~> 1.18`; the other four are not named in the
`Gemfile` at all.

```bash
bundle update nokogiri loofah rails-html-sanitizer crass websocket-driver
```

### Verify

```bash
bin/bundler-audit; echo "exit=$?"                 # must be exit=0
bin/rails test                                     # still 0 failures / 0 errors
LIBRARY_BACKEND=share bin/rails test
LIBRARY_BACKEND=s3 bin/rails test
```

Nokogiri ships **platform-specific gems** (the lockfile carries 7 `nokogiri (1.19.3-*)` lines).
Confirm the bump wrote all of them, not just `arm64-darwin`, or CI's linux runner will resolve
differently from your Mac.

### Do not

- **Do not `bundle update` bare.** This repo pins `lexxy` to an exact version on purpose — it shed
  its beta suffix in June 2026 and shipped six releases in 24 days, and the Gemfile comment says to
  bump it deliberately with a manual editor re-check. A blanket update rides it in silently.
- **Do not add anything to `config/bundler-audit.yml`'s ignore list** to make this go green. Every one
  of these is a real advisory on a reachable path.

---

## 3 · 🔴 Confirm CI actually goes green

**Effort:** minutes. Not optional — items 1 and 2 are only done when this passes.

```bash
bin/brakeman --no-pager; echo "brakeman=$?"   # 0
bin/bundler-audit;        echo "audit=$?"     # 0
bin/importmap audit;      echo "js=$?"        # 0  (already green — leave it alone)
```

Then push and watch the **`scan_ruby`** job specifically. It runs on a self-hosted linux runner. Note
that `ci.yml` only triggers on paths including `Gemfile`/`Gemfile.lock`, so a `config/`-only commit
will not exercise it — item 2 touches the lockfile, so the combined change does.

---

## 4 · 🟠 Decide the Active Storage direct-upload question

**Effort:** ~half a day, most of it the decision rather than the code.
**This one needs a judgement call, not just an implementation.** It is `STATUS.md` open item #1.

### Evidence

```bash
bin/rails routes | grep direct_upload
# rails_direct_uploads POST /rails/active_storage/direct_uploads  active_storage/direct_uploads#create
```

`ActiveStorage::DirectUploadsController` descends from `ActiveStorage::BaseController`, **not** this
app's `ApplicationController`, so it inherits none of the app's auth. `ApplicationController` declares
no global `authenticate_user!` — auth is per-controller here, which is fine for the app's own
controllers but means an engine-mounted one silently opts out.

Result: an **unauthenticated storage-write primitive**. Anyone who can reach the host can mint an
`ActiveStorage::Blob` and get a signed upload URL back. No read-back without a signed id, so this is
resource consumption and storage cost rather than disclosure — but it is uncapped, and in the managed
mode the cost lands on the operator.

Both halves were demonstrated, not reasoned — see
`docs/superpowers/specs/2026-07-27-project-page-overhaul-design.md` §9a, which also costs the options.

### The four options, from that spec

- **(a) Strip server-side** — remove `<action-text-attachment>` from `body` before save in
  `NotesController#create` and `Projects::BuildLogEntriesController#create`.
- **(b) Gate the route** — constrain or remove `rails/active_storage/direct_uploads`. Closes the
  anonymous write.
- **(c) Both** — the only combination that makes the "attachments are off" claim actually true.
- **(d) Accept and document** — defensible for a single-user self-hosted box, much less so for the
  managed/SaaS mode.

### Context for the decision

The **client half is already solid**: Lexxy `JSON.parse`s `attachments="false"`, so the string really
is the boolean, and with attachments off the drag/drop listeners are never registered. What is missing
is only the server half. The route is also **pre-existing** — Active Storage has been installed since
the preview pipeline. What the project-page overhaul added was a user-writable field where an
attachment *renders*, turning a dormant route into a reachable one.

### Do not

- **Do not read decision #2 of the overhaul spec as closing this.** The spec says so explicitly. That
  decision is correct about what the *editor* does and says nothing about the route.

---

## 5 · 🟠 Bound `maker_sheets.data`

**Effort:** ~1 hour.  `STATUS.md` open item #2.

### Evidence

- `app/models/maker/sheet.rb:17` — the only validation on the model is
  `validates :name, presence: true`.
- `app/controllers/projects/sheets_controller.rb:61` —
  `params.require(:sheet).permit(:name, :position, data: {})`, permitted whole and unbounded.

The blob is then embedded into the page HTML on every view with no truncation, so growth is paid for
twice: once in the row, once in every render. A buggy autosave loop or a genuinely large sheet grows
this without a ceiling.

### Fix

A byte-length validation on `data` plus a render-time guard. Pick a limit that is generous for a real
spreadsheet and still bounded.

### Do not

- **Do not shape-check `data` in the controller.** The existing comment there explains the design:
  `data` is an arbitrary nested structure the grid round-trips, and `Maker::Sheet`'s defensive readers
  (`#cells`, `#columns` at `sheet.rb:45-46`) are what defend the render against a malformed blob. A
  size limit is orthogonal to that and does not conflict with it; a shape check would.

---

## 6 · 🟡 Ship the boxes sidecar's GPL-3.0 licence text inside its image

**Effort:** minutes. One line.

### Evidence

```bash
grep -n 'COPY' sidecar/boxes/Dockerfile      # only requirements.txt and app.py
grep -n 'COPY' sidecar/openscad/Dockerfile   # COPY LICENSE README.md ./  + catalog/NOTICE
```

The two sidecars disagree. `sidecar/boxes` is **GPL-3.0** and has a `LICENSE` in the repo, but the
Dockerfile never copies it in. We build that image and push it to a registry — that is redistribution,
and the licence text belongs inside it. `sidecar/openscad` (GPL-2.0) already does this correctly.

### Fix

In `sidecar/boxes/Dockerfile`, alongside the existing `COPY app.py ./` (line 26):

```dockerfile
COPY LICENSE README.md ./
```

Match the openscad Dockerfile's placement and comment style.

### Context

The rest of the §9 licensing posture is **enforced by a test**, not just documented —
`test/deploy_hygiene_test.rb` asserts `/sidecar/` is in `.dockerignore` (so the Rails image's
`COPY . .` cannot bake the copyleft trees into the permissive app image) and asserts the OVH overlay
explicitly blanks every `*_SIDECAR_URL`. Both were real shipped bugs.

**Worth considering while you are here:** this obligation is the one §9 rule with *no* test behind it.
A third assertion in `deploy_hygiene_test.rb` — each GPL sidecar Dockerfile copies its own LICENSE —
would close the class rather than the instance, and that file exists precisely because it can see
files the Rails process never loads.

---

## 7 · 🟡 One system test that executes JavaScript

**Effort:** ~half a day.  `STATUS.md` open item #3. **This is the highest-value item after the CI unblock.**

### Why

**Nothing in the test suite executes JavaScript.** `test/system/` and `ApplicationSystemTestCase`
(Capybara + headless Chrome) already exist and are used elsewhere, but every test added by the most
recent arc is a server-side integration or model test.

That is *why* 1587 green tests across three backends caught neither spreadsheet-grid bug:

- `jspreadsheet-ce` v5's factory is an **async workbook** API — calling it with a flat
  `{data, columns}` throws *inside an uncatchable promise*, so the grid renders permanently empty with
  no error anywhere. Looks like a blank sheet, not a broken one.
- Classic `<script>` tags needed `data-turbo-track="reload"`: every real path to the sheet page is a
  Turbo **visit**, which merges `<head>` rather than reparsing, so untracked tags loaded async and
  Stimulus connected before `window.jspreadsheet` existed.

Both were client-side only and structurally invisible to the suite.

### The test

Type a formula, assert the computed value, reload, assert the **raw formula** persists. That single
test would have caught both bugs above.

The browser surface is now substantial and entirely untested: the Three.js viewer, the JSZip importer,
the Maker.js generators, and the jspreadsheet grid. Worth doing before the next JS-heavy feature, not
after.

---

## 8 · 🟡 STEP / IGES / OBJ previews are wired but cannot run on the shipped image

**Effort:** ~1 hour either way.

### Evidence

```bash
grep -n 'f3d' Dockerfile     # nothing
```

`Maker::Previews::Registry` maps `step`, `stp`, `iges`, `igs` and `obj` to `Maker::Previews::Mesh`,
which shells out to the **F3D** CLI (`F3D = ENV.fetch("F3D_BIN", "f3d")`). The Dockerfile installs
`libvips-tools` and builds dedicated stages for `stl-thumbnailer`, `resvg` and `pdfium` — but installs
no `f3d` binary anywhere.

It **degrades correctly**: `Mesh.available?` gates on the binary, so those extensions fall through to
`unsupported`, the same graceful path the design intends. The problem is that the CAD formats closest
to this product's audience silently have no preview on the deployed server, while the code reads as
though they do.

### Two acceptable resolutions — pick one, do not leave it ambiguous

- **(a) Install it.** Add an F3D stage to the `Dockerfile` beside the `resvg`/`pdfium` ones (they start
  at lines 71 and 79; the final stage's `COPY --from=` lines are at 99–107) and copy the binary to
  `/usr/local/bin/f3d`. Check image size before and after — F3D pulls a real rendering stack, and the
  reason every other renderer here is a small static binary is that the image stays lean.
  F3D is **BSD-3**; its OCCT dependency is **LGPL** and stays process-isolated in the subprocess, which
  is the same §9 posture as the GPL sidecars.
- **(b) Annotate.** Leave it out and say so at the registry entries, so the next reader is not misled.

---

## 9 · 🟢 Two file-type vocabularies disagree

**Effort:** ~1 hour.  `STATUS.md` open item #4. Cosmetic, but user-visible.

`FilesHelper::EXT_FAMILIES` (the Files-page filter chips) and `Maker::FileAttachment::ROLE_LABELS`
(the project panel headings) name overlapping files differently — `.svg`/`.dxf`/`.lbrn2` are
"2D / laser" in one and something else in the other. Same file, two names, depending on which page
you are on.

---

## 10 · 🟢 Delete the stale test count from `CLAUDE.md`

**Effort:** minutes.

`CLAUDE.md:276` states `fs-provider` has **"53 tests"**. Measured:

```bash
(cd client/fs-provider && cargo test --quiet)   # 192 passed, 0 failed, across 20 binaries
```

`CLAUDE.md` defers per-suite counts to `docs/STATUS.md` everywhere else, so **delete the number rather
than updating it** — a count in two places is a count that will be wrong in one of them.

---
## 1. CI cannot go green — no Linux runner is registered

**Status:** open. Blocks every PR check; PR #94 was merged with `--admin` because of it.

All seven jobs in `.github/workflows/ci.yml` declare `runs-on: [self-hosted, linux]`. The GitHub
API reports exactly **one** registered runner:

    charless-MacBook-Pro-maker-mac   os=macOS   status=online
    labels=self-hosted,macOS,ARM64,maker-mac

No Linux runner exists, so all seven jobs queue forever. On PR #94 they sat `pending` with **0
elapsed** — never started, never failed. `mergeStateStatus` stays UNSTABLE indefinitely.

**CLAUDE.md §15 is stale on this point** and should be corrected alongside the fix: it names
`flasher-maker-linux`, `charless-MacBook-Pro-maker-mac` and `CHAIMDESK-maker-windows` as "the repo
has all three registered". Only the Mac is registered today.

**The fix is NOT `ubuntu-latest`.** CLAUDE.md §15 forbids GitHub-hosted runners (they are the only
billed ones; self-hosted are free). Re-register a Linux runner, or retarget the jobs at the macOS
runner if they can run there — but note the `system-test` job needs headless Chrome and
`db:test:prepare`.

**Until then, verify locally** — it is exactly what those jobs run:

    bin/rails test
    LIBRARY_PATH=$(mktemp -d) LIBRARY_BACKEND=share bin/rails test
    LIBRARY_BACKEND=s3 LIBRARY_S3_BUCKET=ci-not-a-real-bucket LIBRARY_S3_REGION=us-east-1 \
      LIBRARY_S3_ACCESS_KEY_ID=ci LIBRARY_S3_SECRET_ACCESS_KEY=ci LIBRARY_S3_PREFIX=library \
      bin/rails test
    bin/rails db:test:prepare test:system
    bin/rubocop

## 2. `ENABLE_TEST_SIGNUP` is ON in production — on ALL THREE backends

**Status:** open. Security-adjacent. Pre-existing, not from the audit-fix branch.

`config/deploy.yml:64` sets `ENABLE_TEST_SIGNUP: true`. **That is the BASE config**, and Kamal
`deep_merge`s env hashes, so `-d s3` and `-d share` inherit it — this is not share-only. Surfaced
by `config/initializers/test_signup_warning.rb` on every boot:

    ⚠️  ENABLE_TEST_SIGNUP is ON — the unverified POST /v1/test/users signup seam is OPEN.
        Non-production test/dev instances ONLY. Never set this on the managed SaaS.

The seam itself:

- `config/routes.rb:191` draws the route when the env var is present **or** the environment is not
  production — so in production the env var is the only thing keeping it open.
- `app/controllers/v1/test_users_controller.rb:15` gates the action on the same var.

**Why it matters now:** this branch just closed an unauthenticated *write* surface
(`POST /rails/active_storage/direct_uploads`). An unverified *signup* endpoint is the same class of
exposure and is currently reachable on all three deployed instances.

**Decide, don't drift:** either drop the var from `config/deploy.yml` (and confirm nothing in the
E2E/conformance harnesses depends on it — the Rust integration suites are the likely consumer), or
record explicitly why a LAN-only self-hosted box is an acceptable place to leave it open. The
warning initializer already exists; what is missing is the decision.

## 3. Carried forward from the audit-fix branch (PR #94) — both deliberate

Recorded in `docs/STATUS.md` under "Still open after this arc". Neither is a defect.

**3a. `importer_controller.js` holds a THIRD extension→role table.** `roleFor` (lines 10–18) is
hand-duplicated in JS and never gained `vector`, `cad_source`, or now `document`. **Nothing is
broken:** the value never leaves the browser — only `node_id`/`cover` are POSTed, and the server
re-derives authoritatively via `Maker::FileAttachment.role_for` — so the persisted role is correct.
Its only effect is the pre-upload summary, which has always lumped everything but model/image/PDF
into "other", so `.txt` behaves there exactly as `.svg` already did.

Worth closing because "one vocabulary" is the whole point of that arc and this copy has now drifted
twice. Fixing it means plumbing the Ruby vocabulary into JS (an endpoint, or a generated constant) —
a real change, which is why it was out of scope.

**3b. `MAX_DATA_BYTES` coverage is asymmetric by construction.** A limit set too *low* fails a test;
one set too *high* fails nothing, because every other test derives its filler from the constant.
Closed as far as it can be by one test pinning the literal (`test "the limit is one mebibyte"`).
Noted so the gap is not rediscovered as a bug.

## Reference — the current measured state

Recorded so you can tell drift from breakage. All green at `6ca3dd7`:

| Suite | Result |
|---|---|
| Rails server | 1587 runs, 5482 assertions, 0 failures, 0 errors, 14 skips |
| `fs-provider` (20 binaries) | 192 passed |
| `fs-cfapi` | 42 passed |
| `sync-client` | 35 passed |
| `sync-engine` (lib) | 13 passed |
| `fs-fskit` | 13 passed |
| `stl-thumbnailer` | 7 passed |
| `fs-webdav` | 4 passed |
| `fs-fuse` | does not build on macOS — `fuser` needs a `fuse.pc` pkg-config alias. Expected; Linux-only. |
| `fs-winfsp` | 0 tests (Windows-only FFI shim) |

**Three architectural tripwires, all holding** — re-run them after any change that touches the
maker/file-layer seam:

```bash
grep -rn "manifest_chunks\|ChunkStore" app/services/maker/ app/models/maker/ app/jobs/maker/ \
  | grep -v ':[0-9]*: *#'                                                  # exactly 1: library_output.rb:47
grep -rn "rescue.*NotImplementedError" app lib | grep -v ':[0-9]*: *#'     # nothing
grep -rn "port_writable?" app/ | grep -v capabilities.rb                   # 5 doors + UI selects
```

Full architecture, C4 diagrams and the library-choice rationale:
**`docs/SYSTEM-AUDIT-2026-07-28.md`**.
