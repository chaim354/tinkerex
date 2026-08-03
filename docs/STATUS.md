# Build status — sync engine

**Updated:** 2026-08-03 (**Secrets resolve from 1Password per destination, with a preflight — PR #122 + the `tinkerex` vault split**)

## What this file is

The **canonical record**: every arc, newest first, with the numbers that were actually measured.
Architecture and the invariants a future editor must not undo live in **CLAUDE.md** (§14) — not here.
Narrate arcs here; put rules there.

- **Still open (deliberate, carried forward)** — immediately below.
- **Latest** — the most recent arc. Exactly one section is ever called that.
- **Everything older** — `## <date>: <title>`, reverse-chronological.
- **Origin (2026-06-11)** — the first session's plan, at the very bottom, **historical and superseded**.

**The per-entry suite counts here do NOT form a chain and cannot be used as a baseline.** The
2026-07-29 entry documents the arithmetic. Take a baseline by *running the merge-base*, not by
reading the last entry.

---

## Still open (deliberate, carried forward)

> **The remaining-work list is `docs/OPEN-WORK.md`** (added 2026-07-30) — every item verified
> against the code rather than copied forward. The bullets below are this file's own carried
> caveats; that document is the one to read for what to do next.

- **`importer_controller.js` has a THIRD extension→role table.** `roleFor` (lines 10–18) is
  hand-duplicated in JS and never gained `vector`, `cad_source`, or now `document`. **Nothing is
  broken:** the value never leaves the browser — only `node_id`/`cover` are POSTed and the server
  re-derives authoritatively via `Maker::FileAttachment.role_for` — so the persisted role is
  correct. Its only effect is the pre-upload summary, which has always lumped everything but
  model/image/PDF into "other", so `.txt` behaves there exactly as `.svg` already did. Recorded
  because "one vocabulary" is this arc's whole point and a third copy has now drifted twice; fixing
  it means plumbing the Ruby vocabulary into JS, which is a real change and was out of scope here.
- **`MAX_DATA_BYTES` coverage is asymmetric by nature.** A limit set too *low* fails a test; one set
  too *high* fails nothing, because every other test derives its filler from the constant. Closed as
  far as it can be by one test pinning the literal.
- **`ENABLE_TEST_SIGNUP` is inherited by the OVH deployment, knowingly.** `config/deploy.yml:64` sets it
  in the **base** env.clear, which Kamal deep-merges, so `-d ovh` gets it too — the base comment's
  justification ("this Unraid instance is a NON-production test/dev deploy") covers the LAN box only.
  `POST /v1/test/users` mints **confirmed accounts with no email verification**. Left ON deliberately:
  OVH is a prod-*like* test box, and blanking it at the base would break
  `client/test-conformance/two-device-cfapi.ps1`, which enrolls against the deployed Unraid server
  through this seam. The fix, when this stops being acceptable, is one line —
  `ENABLE_TEST_SIGNUP: ""` in `config/deploy.ovh.yml` beside the two sidecar-URL blanks, which exist to
  defeat exactly this deep-merge. Recorded at the edit site too.
- **A chunk-mode device push has no fast path into project-folder filing.**
  `Maker::ProjectIntake`'s eager nudge (`ProjectFolderIntake`) covers only the three web
  upload doors — `Sync::Commit#finalize`, the device-sync write path, never calls it — so a
  file arriving through the mount waits for `Maker::ProjectIntakeJob`'s 15-minute schedule
  like everything else. Deliberate, not an oversight: `#finalize` runs once per file, so
  wiring the nudge into it would turn one 500-file device sync into 500 synchronous
  full-project sweeps.
- **A `projects:organize` dry run cannot see a name collision a real run would hit.**
  Collision detection lives inside `Maker::MoveNode.call`, which a dry run never reaches —
  it writes nothing, on purpose — so its "would file" answer is optimistic whenever the
  destination folder already holds a same-named file. Not a gap to close; it is what
  "writes nothing" costs.

---

## Latest (2026-08-03): secrets resolve from 1Password per destination, with a preflight (PR #122, branch `claude/1password-persistent-access-13fe8f`; vault split on `claude/1password-vault-scope`)

Deploys required `export CHUNK_SECRET_ACCESS_KEY=… KAMAL_REGISTRY_PASSWORD=…` before every run,
even though `docs/DEPLOY.md` already used `op read` for the sidecar builds. `bin/secret VAR
op://Vault/Item/field` is now the one definition of where a credential comes from — exported shell
value wins, else 1Password — used by every `.kamal/secrets*` and both sidecar builds. **PR #122
merged as `456f683` with all seven CI checks green.**

**Secrets are per-destination now.** Kamal reads `[secrets-common, secrets.<dest>]`, so
`.kamal/secrets` is the *base* file and is **not read under `-d`**; added `.kamal/secrets.s3`,
`.secrets.share`, `.secrets.ovh`. The split is required, not tidiness, for two measured reasons:
`CHUNK_SECRET_ACCESS_KEY` resolves to **42 bytes (SeaweedFS) on Unraid and 64 bytes (R2) on OVH** —
one variable name, two credentials, which `secrets-common` cannot tell apart; and
`InlineCommandSubstitution` runs every `$(…)` in a parsed file **eagerly**, so a credential parked
in `secrets-common` makes `-d share` shell out for something a share container never holds.

**Why `bin/secrets-preflight` exists — kamal cannot notice an unreadable secret.** It expands
`$(…)` through Ruby **backticks, which discard exit status**, so a locked vault yields `""` and
`Kamal::Secrets#[]` returns that empty string **without raising**. Verified against kamal 2.11: a
deliberately-failing substitution parsed to `{"EMPTY" => ""}`, `key?` said false while `[]` said
`""`, and kamal reads `[]`. A *missing* key raises; an *empty* one does not. That is the recorded
failure where an empty `KAMAL_REGISTRY_PASSWORD` reached `docker login` and was reported as exit 0.
The preflight resolves every key the merged config declares through the real `Kamal::Secrets` and
prints names + byte lengths only, never values.

**Three traps found by probing, each of which would have shipped as a green-but-wrong guard:**
1. **`${VAR:-default}` is broken in kamal's dotenv** — it renders `":-default}"` (and
   `"from_shell:-default}"` when set), because Dotenv's Variable substitution consumes `${VAR` and
   leaves the remainder literal. The shell-default idiom cannot be used in these files; hence a
   helper script.
2. **`Kamal::Configuration#raw_config` is an `ActiveSupport::InheritableOptions` with STRING keys.**
   `dig(:env, :secret)` returns nil while `dig("env","secret")` returns the list. The first version
   of the guard test used symbols, so it returned `[]` for every destination and **passed while
   asserting nothing** — caught only by minitest's "Test is missing assertions". Assertions went
   **27 → 53** on the fix.
3. **OVH could not load its config at all.** `CHUNK_ACCESS_KEY_ID` was `<%= ENV[…] %>`, and kamal
   secrets feed `env.secret` lookups — they are never exported into the ENV that ERB reads. Unset,
   the ERB rendered empty, YAML parsed `nil`, and the destination died with
   `env/clear/CHUNK_ACCESS_KEY_ID: should be a string`. It is an `env.secret` entry now, with
   `env.secret` re-declared in full (kamal replaces arrays on merge).

**Guards:** three tests in `test/deploy_hygiene_test.rb`, each **mutation-checked** (broken → seen
RED → restored byte-identical): required keys are defined in a file the destination actually reads;
`secrets-common` holds only universally-required keys; no secrets file holds a literal. All three
are **static** — they never execute a `$(…)`, so they need no vault and pass on a runner with no
1Password installed.

**The `tinkerex` vault split (2026-08-03, follow-up).** All references moved from
`op://Personal/…` to `op://tinkerex/…`. Forced by a constraint from 1Password's own CLI: **a
service account cannot be granted access to a Personal or Private vault**, so leaving the items in
`Personal` makes unattended runs impossible rather than merely broad. It also bounds what anything
running `op` on this machine — a coding agent included — can read, from the entire personal vault
down to five project items (`ghcr.io`, `seaweednew`, `R2`, `OVHcloud`, `tinkerex-origin`). Confirmed
by probe: every `op://Personal/…` reference now **fails** and every `op://tinkerex/…` one resolves.
`tinkerex-origin` (OVH's Cloudflare Origin cert, `{certificate, private key}`) is referenced by no
code — it is used by hand — but it moved too, because a service account cannot read `Personal` and
an unattended OVH TLS step would otherwise fail.
**Service accounts ARE available on a personal (Individual/Families) plan** — an earlier claim in
this session that they were Business/Teams-only was wrong; the published rate limits list
"1Password and 1Password Families" as its own tier at 1,000 reads/day, versus ~8 reads for a full
`bin/secrets-preflight --all`. Only the Private-vault restriction applies.

**Verified:** `bin/ci` green, three backend legs identical at **1924 runs, 6683 assertions, 0
failures, 0 errors, 11 skips**; system tests 22/132; style 485 files clean. All four destinations
resolved live against 1Password, before and after the vault move.
**Not verified: no deploy was run.** The preflight proves credentials *resolve*, not that one
reaches a running container — and the OVH fix is argued from the config error above, since OVH
deploys only on explicit request (CLAUDE.md §7). The three Unraid legs still run the pre-#122 image.

## 2026-08-02: an addon becomes a manifest + a bundle — the generic `/tools` host surface, and `generators`' migration off it (branch `claude/addons-runtime-bundles`)

**1905 runs / 6602 assertions / 0 failures / 0 errors / 11 skips — identical on chunk, share and
s3 — plus 22 system tests / 133 assertions.** Design: `docs/superpowers/specs/2026-08-02-addons-runtime-bundle-design.md`.
Plan: `docs/superpowers/plans/2026-08-02-addon-host-surface-and-generators.md` (now carrying its
own "Corrections found during execution" section). Invariants: CLAUDE.md §14c, §14e.

### What landed

An addon is now a **manifest + a plain-ESM bundle**, fetched at runtime and proxied same-origin by
one generic `Tools::AddonsController` (shell / asset proxy / save), instead of its own Rails
controller, views and Stimulus controller. `Maker::Addons::Registry` builds the gallery from
manifests `Maker::Addons::Source` fetches, cached 5 minutes, degrading to an empty gallery (never a
500) on a source outage. `generators` is the first migration: its Ruby is deleted, and it now ships
as `public/addons/generators/{manifests.json,generators.js,material_test_grid.js}` plus the five
vendored Maker.js deps, read by `Source::Local` in dev/test. `boxes` and `openscad` have **not**
migrated — they keep their own controllers, routes and sidecar clients unchanged, and the gallery
carries a **temporary** hand-written block for both (`app/views/tools/home/index.html.erb`) that
disappears the day each migrates.

**Phase B — the addons repo and its static container, the point at which independent deploy of an
addon actually turns on — has not started.** `public/addons` is explicitly transitional: bundles
still ship inside this repo's own image and deploy with the next Rails release, same as before.
`ADDON_SOURCE_URL` (the real, separate-host mode) is exercised only by `Source`'s own unit tests in
this phase.

### Task 0's spike: GO

The plan's one falsifiable question — can a page render an importmap merged from the host's own
pins plus an addon's, such that a proxied ES module resolves, including bare specifiers imported
*by* that module — came back GO. Confirmed two ways, not just asserted: the addon's pin
(`tools_addon_asset_path`, a route-helper-built **root-relative** path) renders into the page's
importmap **unchanged**, character for character
(`test/controllers/tools/addons_controller_test.rb`'s "pins are merged into the page importmap"),
and a real browser resolves the whole chain — `generators.js` importing `makerjs.js` importing its
own four bare-specifier deps (`bezier-js`, `clone`, `graham_scan`, `kdbush`) — end to end
(`test/system/addon_bundle_test.rb`). The spike itself was torn down per the plan (nothing from it
is committed); this is the mechanism it cleared working in the real Tasks 1-6 build.

### The self-fetch reentrancy finding

The plan's own baseline assumption — serve addon bundles over `ADDON_SOURCE_URL` pointed at this
same Rails app, since Phase B's separate static container doesn't exist yet — turned out to
deadlock. Pointing an `HTTP` `Source` at the process handling the outer request turns every asset
fetch into a **synchronous nested call competing for a thread in the same Puma pool the outer
request's own thread is already occupying**: reentrancy, not just extra load. Measured directly,
not theorized (commit `0ce6f7f`): against a stock 3-4-thread dev/Capybara Puma pool, the
`generators` bundle's own module graph (2 sequential fetches, then 4 of makerjs's bare-specifier
deps fetched at once by the browser) stalled most requests **14-24 seconds**, and several outright
**404'd** — `Net::HTTP`'s own read timeout firing before a thread ever freed. Fixed by adding a
second `Source` mode, `Source::Local` (`ADDON_SOURCE_PATH`), which reads `public/addons` straight
off disk — now the dev/test default (`config/environments/development.rb`). `ADDON_SOURCE_URL`
stays for Phase B's genuinely separate host, which has its own pool and is structurally immune.
Cost: the HTTP fetch path itself has no end-to-end coverage in this phase, only `Source`'s own unit
tests. A related, smaller finding from manual browser verification (`eb6dfcf`): even `Source::Local`
under a **real** `bin/rails server` intermittently 404'd concurrent asset fetches on Puma's stock
`threads 3, 3`, because `config.enable_reloading = true`'s per-request interlock adds overhead a
page firing several near-simultaneous requests can expose; `RAILS_MAX_THREADS=16` made it reliable.
Production (eager-loaded) and the test env (`enable_reloading = false`) don't carry that overhead.
Both findings are recorded at CLAUDE.md §14e as a general "don't point a synchronous HTTP client at
yourself" lesson — it isn't addon-specific.

### Three things that cost real time and would recur

- **`Object#stub` does not exist in this suite.** Minitest 6 dropped `minitest/mock`; `require
  "minitest/mock"` is a `LoadError`, verified directly. Task 1's first test draft used
  `source.stub(:get, ...)`, per the plan as written, and had to be rewritten with
  `define_singleton_method` instead. Already noted at `test/test_helper.rb:147` (a hand-rolled
  method-swap helper carries the same warning); now also here so the next plan doesn't rediscover
  it as a Rails/minitest-version mystery.
- **`MAX_FILE_BYTES` above Rack's own 4 MiB query-parser limit makes the app-level guard dead
  code.** The plan's Task 5 specified `5_000_000`; Rack's `QueryParser` (`Rack::Utils.default_query_parser`)
  hard-caps a url-encoded POST body at 4 MiB (`4_194_304`) and 400s in `QueryLimitError` before the
  action ever runs, so a cap set at or above that ceiling never fires for that request shape.
  Shipped at `4_000_000` — real headroom under the Rack ceiling, not just numerically less.
- **`:null_store` makes a cache-behavior guard unobservable, not merely untested.** The suite's
  default test cache (`config/environments/test.rb`) is `:null_store`, whose `#fetch` always calls
  the block and caches nothing — so `Registry`'s "a failed fetch is NOT cached" guard passed whether
  or not the underlying code was correct, until the test swapped in a real
  `ActiveSupport::Cache::MemoryStore` for just that file. Same shape as §14e's rate-limiting note;
  worth flagging on its own because it is now the second time this exact class of false-green has
  shown up.

### Left open by this arc

- **`boxes` and `openscad` are unmigrated.** Their own plans get written once this pattern has a
  second addon proving it, per the design doc's own migration order (spec §7).
- **The asset proxy is uncached, deliberately** (spec §8 risk 3: a stale cached bundle reads as "my
  fix didn't deploy," worse than a slow one). Caching gets designed against a working pipeline with
  a real content hash once Phase B exists.
- **`skip_forgery_protection only: :asset` leaves a residual login-state / addon-inventory oracle**
  (CLAUDE.md §14c) — a cross-origin `<script src>` can observe 200-vs-404 for a signed-in visitor
  via `onload`/`onerror`, no response bytes leak. Flagged for reviewer judgment on the PR, not
  closed here.

---

## 2026-08-02: a top view for the tray generators, drawn in the browser (branch `claude/tray-top-view`)

**1891 runs / 6612 assertions / 0 failures / 0 errors / 11 skips — identical on chunk, share and
s3 — plus 21 system tests.** Five new system tests, **all six guards mutation-checked**.

The Box Generator's only view of a tray was the cut sheet: parts nested for the laser, correct and
unreadable as a plan. `/tools/boxes` now draws a **top view** beside it — the compartments, their
sizes, and which ones a layout has merged.

### It costs no sidecar call, and that is the whole design

A tray's compartments are fully determined by `sx`/`sy` (or the layout art) plus `thickness`, and
all three are already in the DOM. So the view is built in the browser: it redraws on the keystroke
rather than on a debounce, needs no round trip, and **cannot drift from the cut sheet**, because it
reads the very values the generator is about to be handed. `topview_controller.js` is ~120 lines.

### Three things that are not what they look like

- **A `layout` param is NOT proof of a tray layout.** `FrontPanel` has one too, and it is a
  different DSL entirely — `outline`/`rect`/`circle`/`text`. Gating on "the field exists" ships a
  Top view panel that is **blank forever** on that generator. The gate is therefore whether the
  first read yields an actual grid, not whether the field is present.
- **`layout` beats `sx`/`sy` wherever both exist**, because that is the order boxes.py resolves them
  in — it reads the compartment sizes back out of the art, so once a layout is present the size
  fields no longer describe the tray. Drawing from `sx`/`sy` there shows a tray nobody is getting.
- **A merged compartment is WIDER than its cells added together.** The grid is rigid, so a removed
  wall does not move anything — it donates its own thickness to the opening. Two 50 mm cells at
  t=3 merge to **103 mm**, not 100.

### One vocabulary, not a third copy

`sections()` (boxes.py's `"50*3"` syntax) and the layout grammar now live once, in
`app/javascript/lib/tray_layout.js`, imported by the controller that **writes** the art
(`traylayout`) and the one that **reads** it (`topview`). A second copy of a parser is this repo's
recorded failure shape — `importer_controller.js`'s `roleFor` is a third copy of the extension
vocabulary and has drifted twice.

### Verified against the real generators, not only the fake

`FakeBoxes` is an approximation, so the shipped parser was also run against the **real** sidecar's
advertised defaults: it reads all **14** real tray generators (including `GridfinityTrayLayout`,
whose rows carry no space before `mm`) and rejects `FrontPanel` — the one it must. Rendering was
checked in a real browser, not just asserted.

### Left open by this arc

- **Trays only — 13 of 181 generators.** 49 have `x/y/h` and could get an approximate 3D assembly;
  120 have neither and no generic shape to draw. A general assembled view remains **not feasible**:
  boxes.py has no assembly graph at all (`rectangularWall`'s `move` positions a part *on the cutting
  sheet*), so it would mean re-deriving mating edges for 181 generators against a pinned upstream.
- **It draws the design, not the joinery** — no finger tabs, no half-lap slots. Deliberate for a
  plan view, but it means the view will happily draw a wall segment ending in mid-air, which is
  unsupported once a layout removes the floor. Flagging those is a natural next step; the region
  data already knows which walls touch what.
- **Not deployed.** Rails-side only, so it ships with the next app deploy — no sidecar rebuild.

---

## 2026-08-02: three generators 422'd, a fourth lied, and `dest` was never the flag (branch `claude/goofy-hodgkin-82e11d`)

**Sidecar suite: 18 passed** (`sidecar/boxes`, pytest, against the pinned
`florianfesti/boxes@836f5f72`) — 10 pre-existing, 8 new. Rails is untouched by this arc: the
whole fix is `sidecar/boxes/app.py`. **All six guards were mutation-checked** — each broken in
turn, confirmed RED, restored (§15).

**The handoff report named three failures and two causes. Both causes were wrong, and the count
was low.** Probing found ONE root cause behind all three 422s, plus a fourth generator that had
been returning **200 with the wrong drawing** the entire time.

### The root cause: a `dest` is not a flag

`_argv` built each argument as `"--" + dest`. That is right for every param across the 185
generators **except five**, where boxes.py declares an option string that differs from its dest:

| Generator | dest | actual flag |
|---|---|---|
| CompartmentBox | `margin_vertical`, `margin_side` | `--margin_t`, `--margin_s` |
| TypeTray | `gh`, `gw` | `--gripheight`, `--gripwidth` |
| FlexBox3 | `d` | `--c` |

That failed two ways, and **the quiet one is worse**:

- **No such option** → argparse `unrecognized arguments` → CompartmentBox and TypeTray 422'd on
  every render for every user.
- **The invented flag is a unique PREFIX of a real one** → argparse **abbreviation-matched it**.
  FlexBox3's `--d` resolved to `--debug`, so the user's `d` vanished into a plumbing flag and the
  box came back **200, drawn at the default**. No error, anywhere, ever. `--d 1.0` and `--d 6.0`
  produced byte-identical geometry (45429 bytes both), differing only in the CLI string boxes.py
  records into the SVG metadata — which is exactly why an `a.data != b.data` assertion **passes
  against this bug**. The test compares the drawing with that metadata stripped.

**The report's hypothesis — that `_param_groups_for` walks a different source than `parseArgs`
registers — is disproved:** `advertised - registered` is empty for all three. Nothing phantom was
ever advertised; the schema was right and the argv was wrong.

### The other three findings, none as reported

- **TrayLayoutFile** did not fail on a `label_file` FileType (it has none). `_argv` prepended
  `--format svg` **unconditionally**, and TrayLayoutFile is the one generator whose parser lacks it
  (`[-h] [--sx] [--sy] [--output]`). It also emits an **ASCII layout, not SVG** — it is step 1 of
  boxes.py's two-step CLI flow, and this sidecar **already runs it internally** to seed TrayLayout's
  textarea.
- **`label_file`'s default is `None`, not `""`.** So the report's "argparse type-converts its own
  default" is not what happened — omitting it parses fine. The empty string came from the **rendered
  form**. It is moot either way: the param is **upstream-broken**, `typetray.py:119` has argparse
  open it while `:247` does `Path(self.label_file).open()`, so any real path raises `TypeError`.
- **`Edges` answered 200 `image/svg+xml` with a ZERO-BYTE body** — nobody had noticed, because a
  status-plus-mimetype check passes it. Its `render()` only prints the edge catalogue to stdout and
  draws nothing. Saving it would have written an **empty `.svg` into the library**.

### What changed

- **`_actions`/`_flag`** — every argument is now built from the option string argparse **registered**.
  Neither failure mode can recur.
- **`_exposed`** — ONE definition of "which params we advertise AND accept", consumed by
  `/generators` and `/generate` alike. The entire bug lived in the gap between those two being
  derived separately. It drops FileType params **by rule, not by name** (they name a path on the
  sidecar's own filesystem, which a browser client can never place a file at — a field that cannot
  work, and a needless server-side `open()` primitive), mirroring how `_multiline` mirrors boxes.py's
  textarea rule.
- **`_offered`** — mirrors boxes.py's **own `webinterface = False`** flag instead of a hand-kept
  name list, so a boxes.py bump cannot silently outgrow it. It hides four: `Edges`, `TrayLayoutFile`,
  `JigsawPuzzle` ("Still alpha" upstream) and `Lamp` (no docstring, 484 KB render). Gated at the API
  boundary only — `_all_generators()` still returns them, which is what the textarea seeding needs.
- **`--format svg` only where the parser has it.**
- **An unknown param is refused BY NAME**; one we deliberately un-advertise is dropped quietly, so a
  state saved with `label_file: ""` still re-renders.
- **The 422 now carries argparse's own message.** `except SystemExit` discarded the one line naming
  the param and the reason. Captured by replacing the parser **instance's** `error` hook rather than
  redirecting the process's stderr (which swaps a global and would interleave on threaded workers),
  which also drops the usage dump and the program name — a gunicorn path — from the response.

**All 181 offered generators render a complete, non-empty SVG from their own advertised defaults**
— 185 exist, and the four upstream marks `webinterface = False` are not offered; the same holds
when every field is posted the way the form posts it, blanks included. **Confirmed against the
deployed sidecar** (see below), not only locally.

### Left open by this arc

- **NOTHING RUNS THE SIDECAR SUITE.** `sidecar/boxes/tests/` is not in `config/ci.rb`'s gates and no
  workflow invokes pytest — these 18 tests, including the 185-generator sweep, run only when someone
  runs them by hand. That is the "a guard that never runs is not a guard" shape this repo keeps
  recording; wiring it means Python plus a git install of boxes.py on the one registered (macOS)
  runner, which is a CI-infrastructure change and was not made here.
- **DEPLOYED to Unraid 2026-08-02.** `bin/build-boxes-sidecar` pushed
  `ghcr.io/chaim354/boxes-sidecar:latest` at `sha256:1a095650` (was `sha256:1f9d9eec`) and
  `kamal accessory reboot boxes` rolled the single shared accessory on 192.168.1.95 — **one accessory
  serves all three app legs, so there is no per-backend sidecar deploy.** It shipped from the branch
  *before* PR #112 merged, and the merge (`a3a8a03`) has since made main's `sidecar/boxes` tree
  byte-identical to the tree the running image was built from (both `3fd108a2`) — **the box and main
  now agree.** The hazard that created is worth keeping in mind for the next sidecar deploy:
  `bin/build-boxes-sidecar` pushes a **mutable `:latest` with no SHA in the tag**, so nothing about a
  running accessory tells you which source built it, and a rebuild from a tree missing the fix would
  revert it silently. Verified on the box, before → after: CompartmentBox
  422 → 200, TypeTray 422 → 200, the advertised list 185 → 181 with all four `webinterface = False`
  generators gone, and the 422 body `{"error":"invalid parameters"}` →
  `{"error":"argument --x: invalid float value: 'not-a-number'"}`. A full sweep run from inside an
  app container against the live sidecar renders **181/181**.
- **Still not browser-verified.** Everything above is API-level; nobody has driven `/tools/boxes` in
  a browser against the new sidecar.
- **A number in this entry was wrong before it was corrected.** It read "184 of 185 generators now
  render", written while only TrayLayoutFile was hidden and never updated when the rule moved to
  upstream's `webinterface` flag (four hidden). Recorded because the count is exactly the kind of
  claim that gets copied forward unchecked.

---

## 2026-08-02: the Box Generator folds up — collapsible sections, a section index, and a preview that starts itself (branch `claude/boxes-tool-ux-b871bf`)

**1891 runs / 6608 assertions / 0 failures / 0 errors / 11 skips — identical on chunk, share
and s3**, plus **16 system examples / 100 assertions** (was 11). Whole gate: `bin/ci` green in
~40 s. Baseline was taken by running the merge-base, not by reading the entry above.

**WHAT SHIPPED.** Three things, all UI, none of them touching the fields themselves.

- **The index is three columns**: a sticky section index (left), the generator gallery
  (middle), the saved-box rail (right). Every gallery section is a `<details>`; the rail nests
  `<details>` twice — section, then box type — and both levels ship closed. 185 generators
  across 10 `ui_group`s is what makes this worth doing: `Misc` alone is 56.
- **The editor previews the generator's defaults on `connect()`**, with nothing clicked, then
  re-renders on a 600 ms debounce after any `params[...]` field settles. Name, destination and
  both buttons moved into a sticky bar **above** the params — `TypeTray` is 95 fields across 14
  groups, so "Save" used to be a long scroll from whatever you were editing.
- **Every param group folds now, not just the advanced ones** (they were open `<fieldset>`s),
  with one collapse-all/expand-all control. The inputs inside are byte-for-byte unchanged.

**PERSISTENCE HANGS OFF A SUMMARY CLICK, NOT THE `toggle` EVENT — and that is the whole design.**
`boxfilter` opens matching sections by assigning `.open`, which fires `toggle` too, so storing on
`toggle` would let a search silently rewrite the layout you had arranged. A summary click can only
come from the user (keyboard activation dispatches one as well). It reads the state in a
`setTimeout`, **not** a microtask: the flip is the click's *default action* and has not happened
while listeners and microtasks run, so a microtask stores the OLD value.

**THE FIRST DRAFT OF THAT TEST PROVED NOTHING, AND ONLY THE MUTATION SHOWED IT.** Moving
persistence back onto `toggle` left the suite **green** — because `boxfilter` restores the prior
state when the query is cleared, so storage lands on the right value anyway. The bug only exists
for someone who **leaves the page mid-search**, so the test now reloads while the filter is still
applied. Recorded because it is this repo's dominant failure mode (§15) caught in the act: the
assertion was true, it just could not fail for the reason it existed.

**A SHARED-HELPER BUG THE NEW TESTS EXPOSED: the browser log buffer outlives a test.** Selenium
reuses one Chrome per file and `logs.get(:browser)` is a *drain*, so a test that never calls
`assert_no_console_errors` — or fails before reaching it — hands its entries to whichever test runs
next. Observed for real: `box_sections_test`'s deliberate sample-photo 404s failed
`importer_test`. `ApplicationSystemTestCase` now drains in `setup`, which makes the guard sharper,
not weaker. `assert_no_console_errors` also gained `ignoring:` for failures a page is *designed* to
produce (the sample-photo 404 that triggers `thumbfallback`).

**`container-wide` is a new, opt-in layout mechanism.** `<main class="container">` is a 920 px
reading measure; a nav rail on one side and a list on the other both come out of the middle column,
and at 920 px the gallery dropped to **one card per row** (measured: `172px 388px 264px`). Pages
opt in with `content_for :container_class, "container-wide"` (1360 px). Inert everywhere else.

**FOUND, NOT FIXED — 3 of 185 generators cannot render at all, and never could.** Auto-preview made
a pre-existing silent failure visible: the old controller did `if (!res.ok) return`. Measured by
posting every generator's own schema defaults to the sidecar — 182 render, 3 return 422, for **two
different reasons**. `CompartmentBox`: `app.py`'s `_param_groups_for` advertises `margin_vertical`
and `margin_side`, which the generator's argparse rejects as *unrecognized* — the schema and the
parser disagree. `TypeTray` / `TrayLayoutFile`: an argparse `FileType` whose default is `""`, so
argparse opens `''` and exits — **not fixable from Rails**, since omitting the param still
type-converts the default. Both live in the GPL sidecar (§9, §14c), so both are out of this
branch's reach. `app.py` also collapses every argparse failure into `{"error": "invalid
parameters"}`, discarding the stderr that names the offending param.

**VERIFIED IN A REAL BROWSER, against the real sidecar** — a local venv running the pinned
`florianfesti/boxes @ 836f5f7`, all 185 generators, not `FakeBoxes`. Confirmed live: the section
index jumps into a *collapsed* section; collapse-all flips its own label; filtering for `shelf`
leaves exactly the two sections that match (Box 1 card, Shelf 11), prunes the index to those two,
and clearing puts the previous open/closed state back unchanged; a no-match query shows the empty
line. Sticky action bar measured pinned at `top: 0` under scroll.

**MUTATION-CHECKED, 14 IN TOTAL** — 8 request-level, 6 browser-level, each reverted, watched go
red, restored. Named inline in `test/system/box_sections_test.rb` and in the request tests.

---

## 2026-07-31: a project folder that files itself, rebased onto main's own unique index (branch `claude/auto-add-project-files-050360`)

**1886 runs / 6565 assertions / 0 failures / 0 errors / 11 skips — identical on chunk,
share and s3, verified by running all three legs directly in the worktree** (`bin/rails
test`; `LIBRARY_PATH=$(mktemp -d) LIBRARY_BACKEND=share bin/rails test`; the
`LIBRARY_BACKEND=s3` leg with `config/ci.rb`'s five stub `LIBRARY_S3_*` knobs). **PR #110
shows no CI checks reported** — the one registered runner (`charless-MacBook-Pro-maker-mac`,
confirmed live via the runners API) is online and `ci.yml`'s jobs already target it, but
nothing has triggered a run against this branch, so the three local legs above are the only
verification this entry can claim.

**WHAT SHIPPED.** A file that lands anywhere under a project's `Projects/<slug>/` folder is
attached to that project; one sitting loose at the folder's root is filed into a
lazily-created category subfolder (`cnc`, `laser`, `design`, `models`, `cad`, `docs`,
`images`, `archives`, `other` — `Maker::ProjectFolders`, derived from the one file-type
vocabulary, not a second table). `Maker::ProjectIntake` is the sweep (`.for_project` /
`.for_user` / `.for_node`); the eager nudge (`ProjectFolderIntake`, a controller concern)
makes a web upload into a project folder attach and file itself in the SAME request instead
of waiting for the periodic sweep. Wired in three places: `Maker::ProjectIntakeJob` on a
15-minute schedule for chunk deployments, `Library::ScanJob` calling it inline right after
its own reconcile for share/s3, and `rake projects:organize` (`DRY_RUN=1` to preview) for an
operator running it by hand. The decisions most likely to get undone are recorded as
invariants at **CLAUDE.md §14f**, not narrated again here — root-as-inbox statelessness, the
sweep-not-hooks shape (seven doors, an eighth would silently skip the rule), the two
separately-capped entry points, and the `ScanJob` ordering constraint chief among them.

**THE REBASE MET MAIN'S OWN INDEX HEAD-ON, AND BOTH SIDES HAD BUILT THE SAME THING.** While
this branch was in flight, main's own audit arc (PR #108, previous entry below) landed
`AddUniqueIndexToMakerFileAttachments` (`20260730123853`) for the identical reason this
branch needed one: `Maker::ProjectIntake#attach`'s periodic, unserialized sweep turns an
ordinary concurrent attach into a race with no user on the other end to make it rare. Both
migrations built the SAME unique index on `(user_id, attachable_type, attachable_id,
node_id)`, deduping first and keeping the SAME lowest-id survivor (`MIN(id)` /
`order(:id).first`), in the SAME dedupe-then-constrain order. This branch's own migration
(`20260730170000`) was DROPPED on rebase rather than kept — keeping both would not have been
belt-and-braces, it would have been a second, redundant index: `if_not_exists:` checks the
NAME, and the two migrations named their index differently, so the second one to run would
have ADDED an index rather than no-opping.

**WHAT THIS BRANCH KEEPS IS THE HALF MAIN'S AUDIT DID NOT DO: auditing the table's OTHER
writers.** The index turns a bare `create!` into an uncaught `ActiveRecord::RecordNotUnique`
on an ordinary double-submit — a double-click, a retried `fetch()` — and main's migration
shipped with three such call sites still bare (verified directly against `origin/main`:
`Models::AttachmentsController`, `Projects::EntryPhotosController` and
`Projects::UploadsController` all still read a bare `.create!` there today). This branch's
own Task 9a found the same exposure independently — its risk profile is worse here, since a
periodic sweep has no user to serialize against — and fixed THREE real sites:
`Models::AttachmentsController#create`, `Projects::EntryPhotosController#create`, and
`CurrentProject#attach_addon_files_to_current_project` (the worst-shaped of the three — a
bare `create!` inside a loop wrapped in one transaction, so a race on ONE addon-output file
used to silently roll back and drop every OTHER file from the same tool save), all converted
to `create_or_find_by!`. **`Projects::UploadsController#create` is deliberately NOT among
them and still holds a bare `create!` on both main and this branch** — it was in the
original, broader writer count this task's review started from, and dropped once the
mechanism was understood: every call attaches a node_id freshly minted by that same
request's own `FileLayer.current.write`, so a double-submit cannot land the identical
`(attachable, node_id)` tuple twice the way it can for a door that attaches an existing,
caller-supplied node_id instead. No comment in the codebase states that reasoning
explicitly; it is recorded here because the omission from the fixed list is easy to misread
as unfinished work rather than a considered exclusion.

**A CORRECTION WORTH KEEPING: `find_or_create_by!` was never the 500 path it was first
reported to be.** The first pass through this exposure assumed it was the naive `find_by ||
create!` shape — no protection for the read-then-write gap — and flagged
`Maker::AttachToProject#call` (which uses it) as exposed the same way the bare `create!`
sites are. Driving the race test against the UNCHANGED method proved it already passed.
Verified directly against the installed gem (ActiveRecord 8.1.3,
`lib/active_record/relation.rb`): `find_or_create_by!(attributes, &block)` is
`find_by(attributes) || create_or_find_by!(attributes, &block)`, and `create_or_find_by!`
already wraps its own `create!` in `transaction(requires_new: true)` and rescues
`ActiveRecord::RecordNotUnique` with a `find_by!`. The fallback was never a raw `create!`.
`#call` now spells `create_or_find_by!` explicitly anyway — one fewer query in the common
case, and the safety no longer depends on unstated Rails-version behavior a future reader
would have no reason to check — but that is precision, not a bug fix.

**KNOWN LIMITS, CARRIED FORWARD** (also recorded under "Still open" above). A chunk-mode
device push through the mount (`Sync::Commit#finalize`) has no fast path at all — the eager
nudge covers only the three web upload doors, never the sync engine, so a device syncing a
large batch waits for the 15-minute sweep like everything else; wiring it in would turn a
500-file sync into 500 synchronous full-project sweeps, since `#finalize` runs once per
file. `EAGER_MAX_MOVES`'s default (25) is measured on chunk / local SQLite only — on S3,
`FileLayer::S3#move` is three sequential network calls (a HEAD, a COPY, a DELETE), so the
same default is 75 S3 calls inside one browser-facing request. A `projects:organize` dry run
cannot see a name collision a real run would hit — detecting one means attempting the move,
which is exactly what a dry run exists to refuse to do. And a same-named second upload into
a project is no longer refused, and where the result reaches a screen
(`FilesController#create`'s HTML branch, `Projects::UploadsController#create`) it is no
longer silent either — the flash now names where the second copy landed by reading the
`:conflict` entry out of `Result#skips` — but the two JSON-only branches (`#create`'s json
format, `#finalize_upload`) still run the intake and still file what they can without
surfacing the fact, because nothing downstream reads that response key today.

---

## 2026-07-30: the audit, and the two defects only a browser could see (branch `claude/todo-audit-tests-baf3f9`)

**Suite 1690 → 1777 runs / 6150 assertions / 0 failures / 0 errors / 11 skips — identical on
chunk, share and s3.** `bin/ci` green on all seven gates. rubocop clean. brakeman still 0
warnings.

Deliverables: `docs/AUDIT-2026-07-30.md` (16 findings, evidence per finding),
`docs/OPEN-WORK.md` (the remaining-work list), and
`docs/superpowers/plans/2026-07-30-audit-fixes-plan.md` (the fix sequence). **Thirteen of the
sixteen are closed**; the three that are not are a deploy, a browser pass, and one product
decision.

**THE HEADLINE IS NOT THE N+1 — IT IS THAT NOTHING MEASURED QUERY COUNTS.** `projects#show`
cost 14 queries at 3 build-log entries and 26 at 15: one `ActionText::RichText` load per entry,
because `has_rich_text :body` arrived with the project-page overhaul and `:rich_text_body` was
never added to the eager load. The fix is one line and the page is now **flat at 12** — fewer
than it cost at the *small* size before, since three per-entry queries collapse into one. What
matters is that **`models#show` loads the same shape of data and was flat at 11 the whole time**,
so the correct pattern was already in the codebase and this page silently diverged from it. The
guard came first and was committed red; six pages are now pinned constant-in-N.

**TWO CSP DEFECTS WERE CAUGHT BY THE SYSTEM TESTS' BROWSER CONSOLE, AND BOTH WERE IN THE POLICY
I HAD JUST WRITTEN.** This is the entry's most useful finding, because both would have passed
every integration test:
- **`frame-ancestors 'none'` contradicted a shipped feature.** The app embeds its own PDF
  previews in same-origin iframes, and Rails' default is already `X-Frame-Options: SAMEORIGIN` —
  so `'none'` was stricter than the app's own behaviour and, enforced, would have refused to let
  our page frame our blob endpoint. Every PDF preview blank. Now `'self'`.
- **The nonce was EMPTY for anonymous visitors.** `session.id` is nil until a session exists, so
  every sign-in / sign-up / reset page emitted `'nonce-'` — which Chrome calls an invalid source
  and answers by **discarding the whole `script-src` directive**. Enforced, the policy would have
  protected nothing on exactly the pages reachable without credentials, while the header looked
  present and correct to any test that read it. Now falls back to `SecureRandom`.

  **An integration test can confirm a header is well-formed by its own reading; only a browser
  will tell you the header is being ignored.** Both are now pinned in
  `content_security_policy_test.rb` so the next occurrence does not need a browser.

**`NullStore#increment` RETURNS NIL, WHICH MAKES A RATE LIMIT A SILENT NO-OP.**
`ActionController`'s `rate_limiting` is `count = store.increment(...)` then
`if count && count > to`. The test env's `cache_store` is `:null_store`, so a throttle added
there fires never — a throttle test would fail for the wrong reason and, worse, a "normal
requests still work" test would pass whether or not the throttle existed.
`config.action_controller.cache_store = :memory_store` is the precise knob: rate limiting gets a
real store, general caching stays off.

**AND THE THROTTLES ALONE PRODUCED 306 FAILURES / 20 ERRORS, none of which said "rate limited".**
Counters key on `request.remote_ip` and every integration test is 127.0.0.1, so one counter is
spent across a whole worker: the sign-in in each test's `setup` was throttled, and tests failed
as `302 to /users/sign_in` or a missing `<h1>` in code with nothing to do with auth. Cleared per
test in `test_helper.rb`. **The mutation check was then re-run**, because a global cache clear is
exactly how a throttle test becomes vacuous — removing the throttle still turns it red.

**SOLID CACHE WAS PROVISIONED AND ONE SCAFFOLD COMMENT SHORT OF BEING USED.** The gem,
`config/cache.yml`, the `cache` role in `database.yml`, `db/cache_schema.rb`, and a persistent
volume were all in place; `config.cache_store` was still `# :mem_cache_store`, so production
resolved to `[:file_store, "tmp/cache/"]` — container-local, wiped by every Kamal deploy.
Verified by *running* it, not by reading the file. Solid **Queue** and **Cable** were both wired
deliberately; the third was missed, while `CLAUDE.md` §4 claimed all three. Now wired, and §4
says what happened.

**`DELETE /users` NEEDED NO PASSWORD.** One request carrying only a session cookie took
`users=1 projects=1 nodes=1 tasks=1` to zero. The cascade is entirely correct — 31
`dependent: :destroy` associations — and that is precisely what made the missing confirmation
easy to miss. Now requires the current password, the same bar Devise already sets for merely
*changing* one.

**THE ENUMERATION FINDING WAS WRONG IN A USEFUL WAY.** The audit said login and reset both leaked.
Login does not: an unknown address and a wrong password both answer `422` with the identical
flash. Reset was the whole leak — **and not through the flash, which was already identical**.
Known address: `303` redirect. Unknown: `422` with "not found" in the body. **The oracle was the
status code**, so an audit that read only the flash copy would have called this fine.

**COVERAGE WAS MEASURED, NOT ESTIMATED: 72/85 → 85/85.** A temporary
`process_action.action_controller` subscriber recorded which `controller#action` each test
actually drives. Reading the controllers would not have produced the list of thirteen — it
included `registrations#destroy` (account deletion), `#update`, `confirmations#create`, and
`projects/entry_photos#destroy`. The instrumentation is deleted; re-measuring is four lines and
documented in the plan's Task 15.

**THE CROSS-USER SWEEP PASSED 32/32 ON ITS FIRST RUN, WHICH IS THE POINT.** Every web controller
already scopes through `current_user.*`, and only 8 of ~30 web test files asserted it — so
swapping `current_user.maker_projects.find` for `Maker::Project.find` would have gone green
across the whole suite. Mutation-checked on three controllers: dropping `current_user` turns 4
cases red on projects, 3 on sheets, 1 on notes.

**TWO OF MY OWN TESTS WERE VACUOUS AND THE MUTATION CHECK IS WHAT SAID SO.** (1) A "the delete
form carries the password field" test scanned the whole page for a name containing
`current_password` — the *update* form has one too, so it passed with the delete field renamed;
now scoped to `div.account-delete`. (2) I generated `app/views/devise/registrations/` and edited
that, because `app/views/devise/` did not exist — but this app has **scoped** views at
`app/views/users/registrations/`, which is what Rails renders. The generated copy was dead code
and the delete button would have kept posting no password. **Neither was visible by reading.**

**One existing test's premise was retired by the new constraint**, and it was kept rather than
deleted: `attach_model_bundle_test` had a case opening *"no uniqueness index, so a model CAN hold
two rows for one file"*, which built exactly that state. The unique index makes it impossible, so
the case now asserts the database refuses it and the still-reachable half — attach the bundle
twice, count stays right — is its own test.

**Also closed:** env-gated `force_ssl`/`assume_ssl` (`FORCE_SSL=1` in the OVH overlay, **not yet
deployed**); `config.paranoid`; the password floor 6 → 10 (existing short passwords still
authenticate — verified, since getting that wrong locks out every pre-existing account); a unique
index on `maker_file_attachments` across all four key columns, dedupe-then-constrain; and
`dev_blobs#show`, the last untested action.

## 2026-07-29: addon params live in the DB, not in a library file (branch `claude/boxes-sidecar-params-db-1c508f`)

**Suite 1660 → 1678 runs / 5862 assertions / 0 failures / 0 errors / 11 skips — identical on chunk,
share and s3.** rubocop clean on the touched files. +18 = 7 endpoint, 4 show-page, 7 migration.

**The baseline is 1660, and the plan's "1633" was wrong** — worth recording because the wrong number
came from *this file*. The previous entry's `1628 → 1633` was copied forward as the starting point,
but two entries further down claim `1633 → 1645` and `1645 → 1650`, so the figures in STATUS.md do not
form a chain and cannot be used as a baseline. Measured instead: a throwaway worktree at the
merge-base (`8dfbfde`) runs **1660**, and a static count of `test "` blocks is 1576 there vs 1594 here
— **+18, exactly the tests this branch adds**. Run count exceeds the static count because the shared
adapter contracts are included into several test classes. **Take a suite baseline by running the
merge-base, not by reading the last entry.**

**THE SHARE LEG'S DOCUMENTED COMMAND IS INCOMPLETE, AND IT FAILS LOUDLY ENOUGH TO LOOK LIKE A
CATASTROPHE.** `LIBRARY_BACKEND=share bin/rails test` — the form in CLAUDE.md §10 and the one this
branch's plan copied — reports **1 failure / 202 errors**, because `LibraryBackendCheck` refuses to
boot without `LIBRARY_PATH`. The correct invocation is CI's (`ci.yml`, `test-share-backend`):
`LIBRARY_PATH=$(mktemp -d) LIBRARY_BACKEND=share bin/rails test`. With it, the leg is green. **The
diagnosis that mattered was running the BASELINE the same wrong way** — 8dfbfde reports 202 errors
too, which is what separated "we broke the share backend" from "the command is wrong" in one step
rather than by reading 200 stack traces. The s3 leg needs its own five `LIBRARY_S3_*` stub knobs for
the same reason; they point at nothing real on purpose.

**The request was "store the boxes params in the DB instead of a separate file", and the params were
already in the DB.** `Maker::AddonState#data` is a `json` column holding `{ generator:, params: }`,
and every reader in the app already went there: the show pages' Generator/Source line, "Duplicate &
tweak", and the prior rail on boxes' `new`. **Nothing read the file.** It was write-only. So the work
was a removal plus a replacement for the one job the file did.

**All three addons, not just boxes** — the three `LibraryOutput.write` calls were identical, and
fixing one would have left three addons with different bundle shapes for no stated reason.

**The replacement is ONE surface, because `AddonState` is addon-agnostic and so is the replacement:**
`Tools::AddonParamsController#show` (one route, top-level to sidestep the two documented openscad
inflector traps) serves `JSON.pretty_generate(state.data)` as a download, and
`app/views/tools/shared/_params.html.erb` lists the params on all three show pages.

**The download serves the WHOLE `data` hash, while the list shows only `data["params"]`.** Deliberate
asymmetry: the download is byte-identical to the removed file, and `generator` is what made that file
self-describing — without it the download is an anonymous bag of numbers. In the *display* it is
redundant, since every show page prints it above the list.

**Param values can be MULTILINE** (boxes' TrayLayout/FrontPanel/NightLightBox section params are
newline-separated), so `.addon-params dd` carries `white-space: pre-wrap`. Worth knowing what the
tests can prove: the newline sits in the HTML either way, so **no integration test can verify that
CSS** — the test asserts the half that can be, that the view never squishes or truncates the value.

**Files already written were LEFT IN PLACE; only their `AddonFile` join rows were dropped**
(`20260730010000`, `def up` only, raw SQL so a migration does not depend on a model). They are
ordinary library files a user may have renamed, organized, or attached to a project. Three things
survive on purpose: a project attachment (a separate `Maker::FileAttachment` record) keeps the file
visible in the project panel; its `Maker::Preview` rows stay valid because the node still exists; and
the file name embeds the state id, so it is traceable by hand.

**"Rows go, bytes stay" is now PINNED, and it needed to be** — the plan specified only a manual
`bin/rails runner` check, missing that this repo already has a convention for testing data migrations
(four of them under `test/models/maker/*_migration_test.rb`, all `require Dir[...]` + `Migration.new.up`
against seeded rows). `delete_addon_parameters_file_rows_migration_test.rb` follows it. **The
load-bearing assertion is the negative one**: the library nodes must survive. It is invisible in the
SQL — which names only `maker_addon_files` and so looks harmless either way — so the thing most likely
to break it is a later "tidy up the orphaned files too" change, and nothing else would notice.
Mutation-checked rather than trusted for passing first try: dropping the `WHERE` clause fails 2 tests,
and adding a `DELETE FROM nodes` fails the node-survival test.

**One test's coverage MOVED rather than being deleted.** `openscad_controller_test`'s bundle test read
the params *file* back to assert `OpenscadParams` coercion round-trips (a form String becoming Integer
`6` / Float `2.5`). That is the reason `OpenscadParams` exists, and `data` is now the only place it is
recorded — so the assertion moved to `state.data`. Deleting it with the file it happened to live in
would have dropped the only proof of coercion in the suite.

## 2026-07-29: saving a file removed its preview, and the parser fixes were never the problem (branch `claude/lbrn2-mage-preview-save-bug-fe80d4`)

**Suite 1628 → 1633 runs / 5694 assertions / 0 failures / 0 errors / 11 skips — identical on chunk,
share and s3.** rubocop clean on the touched files.

**The report was "the lbrn2/mage preview fixes still don't work — check hex tiles and reference
card", and the parser was not involved at all.** Both files render correctly on demand: fed the
bytes the deployed share library holds right now, `Lbrn2` returns a 256×256 PNG and reports
`hex tiles.lbrn2` at 408.7 × 538.7 mm / 1494 shapes and `reference card.lbrn2` at 292.1 × 144.6 mm
/ 1254 shapes. **Nothing was ever asking it to.** Checked before proposing anything, which is what
kept this out of `Lbrn2`/`Mage`, where the two preceding arcs had been and where it would have
found nothing.

**ROOT CAUSE — `Library::Reconciler` enqueued a thumbnail for a file it had never seen, and only
for that.** The one `Maker::Previews::Enqueue` call sat in `#call`'s `leftovers` loop, which is
reached by step 3/4 — create-or-revive. A file whose bytes CHANGE under a path the catalog already
knows is claimed in step 1 by `#match_live_paths`, updated in place with
`update!(size:, mtime:, content_hash:)`, and **returned without an enqueue**. Previews are keyed by
`[node_id, content_token]` and share/s3 answer `content_token` with `content_hash`, so the instant a
file is saved its existing row points at content that no longer exists and **every surface that
resolves a preview by the current token — `FilesController#show` and `#thumbnails_for` — finds
none.** The file goes blank and stays blank.

**Not an lbrn2/mage bug: a SAVE bug, which is why it looked like one.** Format is irrelevant — what
matters is whether a file is ever rewritten in place, and in a library that is a mounted NAS that is
exactly LightBurn, MillMage and a slicer. Everything else in that library was written once and never
noticed. Measured on the deployed share library, the files with no preview for their current bytes
split cleanly: **10 per user carried a row for SUPERSEDED content** — `hex tiles.lbrn2`,
`reference card.lbrn2`, `piecies card.lbrn2`, four more `.mage`, and `Catan prints.3mf` — and the
rest (45, one user) had never had one at all and belong to the older `backfill_thumbnails` backlog.
Nine of ten are `.lbrn2`/`.mage`/`.3mf`.

**THE FINGERPRINT THAT NAMES THE MECHANISM: LightBurn's `_backup` twin had a preview and the real
file did not.** Saving writes `<name>_backup.lbrn2` beside the file. That path is NEW to the scan, so
it lands in `leftovers` and gets its thumbnail; the file the user actually opens takes the path-match
branch and gets nothing. `hex tiles_backup.lbrn2` (since tombstoned) held previews rendered at 18:30
and 19:00 on 2026-07-29 while `hex tiles.lbrn2`'s newest was from **07-28 03:19**, for content three
saves gone. A preview beside a file that has none is not a coincidence — it is the two branches,
photographed.

**`FilesController#backfill_thumbnails` was masking it, partially, which is why it read as
intermittent.** That pass DOES enqueue on a changed token, so browsing the folder listing healed
whatever it reached — capped at `BACKFILL_LIMIT = 100`, in display order, and **only on `#index`**.
Open the file's own page and nothing repairs it, ever.

**The fix is one enqueue at the update site, sharing a seam with the one that already existed.**
`#enqueue_thumbnail(node, hash)` carries the best-effort contract (a render enqueue must never fail a
scan that is tombstoning the whole library) and both branches call it. Enqueuing inside step 1, ahead
of `guard_mass_deletion!`, is safe on the guard's own stated terms: it writes only for paths this
pass positively OBSERVED, and the case the guard exists for — an unmounted NAS — hands step 1 an
empty list and enqueues nothing.

**A SCAN CANNOT HEAL THE BACKLOG, and that is not a gap in the fix — it is `unchanged?` working.**
Those files now record their current hash, mtime and size, so the next pass skips them WITHOUT
re-reading them, which is the behaviour that keeps a 2TB archive cheap. Hence
`Maker::Previews::MissingBackfill` (+ `rake previews:backfill_missing`), modelled on
`LbrnBackfill`: enqueue a thumbnail for every live file whose current `content_token` has no row.
Backend-neutral through `stat_all` — the port's bulk read, DB-only on all three — and idempotent,
since the rows it creates are what the next run finds. **Deliberately NOT the `unsupported`-row
sweep still open below:** a row saying `unsupported` for the current content is present and terminal,
and this only ever looks for content with NO row, so the two migrations keep separate correctness
arguments. Dry-run against the live share library: **65 enqueues across two users**, both named files
among them.

**Mutation-checked, and one of the checks came back wrong.** Reverting the Reconciler leaves the new
test RED for the stated reason ("No jobs were enqueued"); dropping the sweep's already-has-a-row
guard turns two of its four tests RED. But dropping the sweep's own `present` scope left the
tombstone test **GREEN** — `stat_all` omits a deleted node as an absent key, so the port was the
filter all along and the test never pinned the scope it appeared to. Said so at both sites rather
than leaving a test whose name claims more than it checks.

### Follow-up (same branch): a truncated setting, an unrendered photo, and a palette NOT shipped

**Suite 1633 → 1645, identical on all three legs. Prompted by "did you base it off
[jlucaso1/lbrn2-to-svg](https://github.com/jlucaso1/lbrn2-to-svg)?" — no, and reading it was still
worth it.** It is MIT (so §9 would have allowed borrowing) and it independently arrived at the same
dialect: `<XForm>` as a child element, `V<x> <y>c0x..` vert lists, `L`/`B` prims, `VertID`/`PrimID`
instancing, `<Children>` groups, and the Text `BackupPath` replacing rather than composing with its
Text. **Two implementations from different evidence agreeing is the strongest corroboration the
dialect reading has.** Cross-checked ours against its six fixtures: bounds match all six within our
1 dp rounding, and the drawn geometry is visually identical.

**`.to_i` IN THE RECIPE PANELS TRUNCATED EVERY FRACTIONAL SETTING.** A layer cut at 6.67 mm/s
rendered **"6 mm/s"** — not a rounding nit but a number the machine will not run, displayed as
though it were the setting, and the same class of error as reading a MillMage `ToolDef` instead of
its `Operation`. Live on `reference card.lbrn2`. **Invisible to the suite because every checked-in
`.lbrn2` fixture uses whole speeds and powers** — the value that exposed it came off a real file.
Now one `FilesHelper#recipe_num` for both panels: round (never truncate) to 3 dp — the precision
`MageMetadata#num` already stores at — then drop a trailing zero that carries no information, so
`50.0` prints `50` and `6.67` prints `6.67`. Mutation-checked: restoring truncation turns the new
page-driven test red.

**A placed photo previewed as an EMPTY BOX.** `emit_shape` routed `Bitmap` through the `Rect` arm —
four corners, `fill="none"` — so a `.lbrn2` built around a traced or engraved image drew its bounding
rectangle and nothing inside. Now emits `<image>` with the inlined PNG. Three refusals fall back to
the old outline, each for its own reason: **not axis-aligned** (an `<image>` is upright; drawing a
rotated one unrotated puts the photo where it is not — the call `Ellipse` already makes),
**not base64** (`Data` is bytes from an uploaded file about to enter an SVG attribute, and a `"`
would close it — the guard REQUIRES the alphabet rather than escaping after), and **not a PNG**
(checked on the first 16 characters, because this attribute is routinely megabytes — it is why
`parse_document` needs `huge`).

**ORIENTATION WAS MEASURED, NOT REASONED, AND THE FIXTURE COULD NOT HAVE SETTLED IT.** `apply`
negates y, so whether the raster needs flipping back is a real question — and the reference carries
`-0.252` in its own image matrix, so neither implementation answers it by inspection. The reference's
`image` fixture is a **symmetric grid**, which renders identically upside down. Pinned with an 8×8
red-over-blue PNG built by hand in the test, rasterized, and pixel-sampled: red must land on top.
Mutation-checked with the flip the reference's matrix form implies — it turns the test red.

**THE PALETTE IS DELIBERATELY NOT SHIPPED, and the corpus is why.** The reference colours layers
from a hard-coded 8-entry table indexed `cutIndex % 8`; `cut_colors`'s long-standing comment declines
to guess ~30 colours LightBurn never writes into the file. Tested the guess against the 58-file
corpus, using each file's embedded thumbnail — LightBurn's own render — as the oracle. On a tight
saturation filter the single-layer files read **0 → black, 1 → blue, 2 → red, 6 → cyan**, against the
reference's **1 → red, 2 → green**: **copying that table would have coloured two of the four
checkable indices WRONG.** Widening the filter then showed the oracle is contaminated anyway —
thumbnails carry placed photos and engraved raster, so one file yields several unrelated hues
(`idx 2` reads red, orange and yellow at once). **The corpus does not determine the palette, so the
existing decision stands** — and now rests on evidence rather than on caution.

**Fills were reported as a gap and are NOT one, which is a correction to this arc's own earlier
claim.** The filled `k.svg`/`crucifix.svg` in the reference's tree are **stale committed artifacts**;
its live `styleUtils.ts` emits `fill:none` on every path, exactly as we do. Doing fills properly
(mode-driven, `Scan`/Fill filled and `Cut` stroked) additionally needs one shape's subpaths emitted
as a single `fill-rule="evenodd"` path or a letter's counter paints over — a change to the yield
contract. **Measured payoff today: zero.** Only files with no embedded thumbnail reach this renderer
— **200 of 217** live `.lbrn2`/`.mage` previews use LightBurn's own — and of the three that do
fall back, two are `.mage` (operations, not Cut/Scan layers) and none contains a bitmap. Left alone
on purpose.

### Follow-up 2 (same branch): ONE PREVIEW ROW PER (node, kind) — the leak is gone at the source

**Suite 1645 → 1650, identical on all three legs.** The open item below said "every save leaks a
preview row and its blob" and proposed a reaper. **The reaper was the wrong answer, and the
question that produced the right one was "why aren't we just updating them when the new one is
created?"** — stop minting the rows rather than sweep them up.

**Measured first, because it decides the shape.** On the deployed share library: 1334 rows, 1174
current, **160 orphaned** (3.1 MB of blobs), growing **~17.6 rows/day** — and the orphans split
into two unequal kinds, **115 whose node is gone** and **45 superseded-content-with-a-live-node**.
Every web surface (`FilesController#show`, `#thumbnails_for`, `ThumbnailMap`) resolves by the
node's CURRENT content token, so **nothing can see an orphan** — they were pure dead weight.

**The mechanical fact that made it free:** attaching over a `has_one_attached` **enqueues
`ActiveStorage::PurgeJob` for the replaced blob by itself** — verified by driving it, not assumed
(the first probe showed the old blob row still present, which was only the test adapter not running
the job). So repointing a row reclaims its old bytes with no code of ours.

**The migration IS the cleanup.** The new unique index cannot be added while duplicates exist, so
the collapse has to happen in `20260730001500_one_preview_per_node_and_kind.rb` — which is why this
change removes a recurring job instead of adding one. It keeps the most recently updated row per
group (the last render, which is the current content in every ordinary case, and self-healing where
it is not, since `Enqueue` repoints any row whose version does not match). Self-contained per the
house style, with one deliberate exception: `ActiveStorage::Attachment#purge` is **framework** API,
and skipping it would have traded a database leak for a stored-file leak.

**THE HAZARD THIS INTRODUCES, AND THE GUARD THAT PAYS FOR IT.** With a row per VERSION, two quick
saves made two rows and each job wrote its own — **a wrong thumbnail was impossible by
construction, and that immunity was exactly what the extra rows were buying.** With one row, a slow
render of v1 finishing after a fast render of v2 attaches v1's bytes to a row that says v2 and marks
it ready: **a wrong image shown as current, silently** — strictly worse than the leak being removed.
`GeneratePreviewJob` now captures the version it is rendering and refuses to write if the row moved
on (`#commit_if_current`). Written as a failing test first, which reproduced the wrong-image write
exactly; mutation-checked by removing the guard.
**EVERY terminal write goes through it, not just the successful one** — the part most likely to be
trimmed later. A stale `unsupported` or `failed` is as wrong as a stale image, and worse in one way:
`Enqueue` treats `failed` as "retry me", so an old verdict would look repaired while describing
content nobody asked about. Losing the write is the CORRECT outcome — whoever repointed the row
already enqueued a job for the new content.

**The v1 API loses per-version previews, and says so rather than clobbering.** `POST
/v1/maker/previews` was idempotent per `(node, version, kind)`; it is now per `(node, kind)`, so
honouring a request for an old version would throw away the current render — and on share/s3, where
there is no history, point it at bytes that do not exist, so the render would then fail and leave
the node with **no** preview. It answers **422 `stale_version`** naming the current one. **Only when
the port can adjudicate:** a node the backend cannot resolve (never synced, deleted, unmounted
share) gives no basis to refuse, and rejecting anyway would break a client rendering a node it is
about to create — which is what every other test in that file relies on.

**Also deliberate:** a repoint sets `status = "pending"`, so the row still holds the previous render
but `_thumb.html.erb` shows an image only when `ready` — the user sees a spinner, not last week's
picture labelled as today's content. Identical to what they saw before, when the superseded row
simply was not found.

### Left open by this arc

**The SAVE leak is closed by construction; a SECOND orphan class is not, and the deploy is what
proved it.** An earlier revision of this line said "Nothing" — written after the code was green and
before the migration had run against real data, which is exactly the kind of claim this file exists
to stop. The migration's own output settled it:

| backend | collapsed | rows after | pointing at superseded content | **node is gone** |
|---|---|---|---|---|
| chunk | 3 | 570 | 0 | **3** |
| share | 71 | 1267 | 0 | **93** |
| s3 | 0 | 0 | 0 | 0 |

- **Superseded-content rows: gone, and cannot come back.** Zero on every backend, and the unique
  index on `(user_id, node_id, kind)` is what keeps it that way. share dropped 1338 → 1267 rows and
  36.3 → 33.2 MB of blobs.
- ~~**Rows whose NODE no longer exists: 93 on share, 3 on chunk.**~~ **CLOSED — `DeadNodeReaper`,
  below.** The migration only collapses DUPLICATES within a `(user, node, kind)` group; a dead
  node's row is the only row for that node, so the index has no opinion about it and nothing swept
  it. **This is why 71 were collapsed and not the 160 the pre-deploy measurement counted** — 115 of
  that 160 were dead-node rows, and only the ~45 live-node duplicates were ever in scope.

### The dead-node reaper — the second orphan class, closed

**Suite 1650 → 1660, identical on all three legs.** `Maker::Previews::DeadNodeReaper` +
`Maker::DeadNodeReaperJob`, weekly in `recurring.yml`, plus `rake previews:reap_dead_nodes`
(`DRY_RUN=1` to report only).

**A JOB RATHER THAN A CONSTRAINT, because this leak is shaped differently from the one the index
fixed.** It grows when files are DELETED, not when they are edited, so it tracks library churn
instead of editing activity — and it cannot be prevented at write time: a node is deleted long
after its preview was made, `Reconciler` **tombstones rather than destroys** (so no `dependent:`
callback would ever fire), and wiring an association from `Node` to `Maker::Preview` would point
the file layer at the maker layer, which is the coupling §12 step 10 exists to prevent.

**THE WHOLE DESIGN QUESTION IS REVIVABILITY, and the two cases genuinely differ** — collapsing them
is the mistake to avoid:
- **No node row at all → reaped immediately.** Both ways back need the tombstone: the share
  Reconciler's revive-by-path looks up `deleted: true` rows BY `storage_path`, and
  `undelete`/`Sync::Trash.restore` reconstruct from the row. With no row that `node_id` can never
  return, so there is nothing to protect.
- **A tombstone → spared until the grace window closes.** A tombstone is a deletion that can be
  TAKEN BACK, returning the same `node_id` — a file dragged out of a folder and back comes home with
  its content unchanged, at which point the row would have been live again. Reaping inside the
  window turns an undo into a re-render. **Dated from the NODE's `updated_at`** (when it was
  tombstoned), not the preview's, which records the last render and can be months older than the
  deletion.

**`grace` is 30 days and deliberately NOT read from `LIBRARY_TRASH_DAYS`**, despite matching its
default: that setting is share-only while this applies to all three backends, and it treats **0 as
"keep forever"** — a meaning that would invert dangerously here, where 0 reads naturally as "no
grace".

Mutation-checked on all three load-bearing decisions: reaping live nodes, ignoring the grace
window, and deleting the row without purging the blob each turn a test red.

**A guard came out of it that had been missing all along.** `config/recurring.yml` is read by the
Solid Queue **supervisor**, not by the Rails process the suite boots, so a typo in a class name or a
`command:` that does not parse is invisible to every other test and surfaces as a job that silently
never runs — in production, at 5am. `test/recurring_schedule_test.rb` now resolves every `class:` to
a real ActiveJob, compiles every `command:` and checks the constants it names, and asserts each
entry has exactly one of the two plus a schedule. Prompted by this being the first NAMESPACED entry
(`Maker::DeadNodeReaperJob`) — the shape most likely to be mistyped and least likely to be noticed —
and mutation-checked by misspelling it.

The **`unsupported`-row sweep** left open by the audit-fix arc is a third, separate migration and is
also still open — see that arc's own list below.

## 2026-07-29: the audit-fix arc — two security gates that ran zero, and a preview path that could not have worked (branch `claude/handoff-audit-fixes-plan-d0f8b3`)

**Suite 1628 runs / 5678 assertions / 0 failures / 0 errors / 11 skips — identical on chunk, share
and s3.** `bin/rails test:system` 6 runs / 28 assertions / 0 failures. rubocop **435 files, 0
offenses**. The three security gates green **by exit code**: `brakeman=0`, `audit=0`, `js=0`.
`client/` has a zero-line diff, and all three standing tripwires still answer what CLAUDE.md §12
step 10 says they should.

**11 skips, where this file has recorded 14 since the previews arc — and the difference IS item 3.**
F3D is installed on this build box now, so `Maker::Previews::Mesh`'s tests **run** instead of
skipping. Measured both ways on the same tree: `F3D_BIN=/nonexistent/f3d bin/rails test` gives
**1628 runs / 5667 assertions / 14 skips**. CI has no F3D and will see 14. A reader comparing skip
counts across entries has to know which of the two numbers they are holding; neither is wrong.

Plan: `docs/superpowers/plans/2026-07-29-handoff-audit-fixes.md`. Queue it came from:
`docs/HANDOFF-AUDIT-FIXES.md`.

### 1. `scan_ruby` was two gates running zero

`bin/brakeman` exited **3** on a false positive — an argv-array `Open3.capture3` in
`Maker::Previews::ImageThumb`, the same shell-free, no-shell-anywhere form already accepted at
length for the sibling `mesh.rb` renderer. `scan_ruby` runs brakeman as step 1 and
`bin/bundler-audit` as step 2, so **the audit gate had never executed**. The job looked like two
gates and was zero.

**The rule this arc exists to install: read a security gate by EXIT CODE, never by reading its
output.** A gate that aborts before it runs is, in a log skim, indistinguishable from a gate that
ran and found nothing — and because the two are chained, the *first* gate's false positive silently
disarmed the *second* gate's real findings. That is how five gems drifted behind published
advisories, one of them High, on a socket every device holds open. Both gates now exit 0, and the
"CI cannot run" section below states the exit-code rule at the place someone will actually be
standing when they need it.

### 2. Five gems, eighteen advisories, one High on the always-on `/cable` path

Measured against the pre-arc lockfile (`bin/bundler-audit check` on `4ed32fe`'s `Gemfile.lock`):
**18 distinct advisories across 5 gems** — nokogiri 9, crass 4, loofah 3, rails-html-sanitizer 1,
websocket-driver 1. One **High**, one Medium, one Low, 15 unrated by the DB.

- **websocket-driver 0.8.1 → 0.8.2** — **CVE-2026-61666 / GHSA-2x63-gw47-w4mm, High: denial of
  service via a malformed `Host` header.** This is `actioncable`'s own dependency, and §12 step 1
  put an ActionCable socket on the **continuously-open** path: every device subscribes to
  `LibraryChannel` for the `{head_seq}` nudge and holds it. The exposed surface is not an
  occasional request — it is the one connection the sync loop depends on existing.
- **loofah 2.25.1 → 2.25.2**, **rails-html-sanitizer 1.7.0 → 1.7.1**, **crass 1.0.6 → 1.0.7** — the
  Action Text sanitizer path, which since the project-page overhaul renders **user-authored notes
  and build-log entries**. Two of the loofah three are `allowed_uri?` failing to see a
  `javascript:` URI split by character references; the crass four are parser DoS.
- **nokogiri 1.19.3 → 1.19.4** — six of the nine are **use-after-free or out-of-bounds read in XML
  parsing**, and this app parses **untrusted uploaded XML** on exactly that path:
  `Maker::Previews::Lbrn2` reads user-supplied `.lbrn2`, and `Maker::Previews::ThreeMf` reads the
  XML inside an uploaded `.3mf` zip. **`lbrn2.rb:70` does `Nokogiri::XML(bytes) { |c| c.recover.huge }`
  — recover-past-malformed with libxml2's built-in limits LIFTED**. `huge` is **required, not a
  tuning knob** (the reason is recorded at the method: LightBurn inlines a placed photo as base64 in
  `Bitmap@Data`, libxml2 caps one attribute at 10 MB, and past that `recover` silently returns a
  TRUNCATED tree — 2 of the 58 real files hit it). Both halves are correct and neither is being
  undone here; the point is only that this parser is aimed at attacker-shaped input with its own
  guardrails deliberately off, which is why keeping it patched is not routine hygiene. **All 7 platform lines moved** (`aarch64-linux-gnu/musl`,
  `arm-linux-gnu/musl`, `arm64-darwin`, `x86_64-linux-gnu/musl`) — the deploy builds `linux/amd64`
  while this box is `arm64-darwin`, so bumping only the line you can see locally leaves the
  **shipped image** behind while the local suite goes green.

**Lockfile-only, and each gem named explicitly rather than a bare `bundle update`** — which would
have ridden in the deliberate exact `lexxy` pin along with everything else, turning a security fix
into an unreviewed dependency sweep.

**The count is a snapshot of a moving target, not a property of the code.** `bundler-audit` refreshes
`ruby-advisory-db` on each run, so re-measuring the same lockfile later can legitimately report more
advisories than it did an hour earlier — the plan for this arc recorded seven. Quote the exit code,
which is stable; treat the count as the date-stamped reading it is.

### 3. F3D installed — and installing it alone would have achieved NOTHING

`Mesh.available?` shelled out to `f3d --version` and matched the literal lowercase `"f3d"`. **F3D
3.x's banner is `F3D 3.5.0 / F3D - A fast and minimalist 3D viewer` — there is no lowercase spelling
anywhere in it** (verified against the 3.5.0 binary). So the gate reported a working, installed
binary as **absent**, and shipping the Dockerfile change without fixing the match would have added
~526 MB to the image and changed nothing observable — the install alone achieves exactly nothing.

**That dead gate is also why a second bug was invisible.** With `available?` permanently false the
Mesh render path never ran and its tests could only ever **skip** — hiding that
`render(kind: "model_glb")` returned **PNG bytes labelled `model/gltf-binary`**, attached as `.glb`
and marked `"ready"`. F3D's `--output` is a raster screenshot and writes PNG whatever the extension
says. `kind` is **client-supplied**, through `V1::Maker::PreviewsController`. Fixing `available?`
would have made that path live, so **it is refused in the same change** — the two are one commit on
purpose, and splitting them later would re-open the window.

**State it plainly so nobody tries again: F3D cannot emit a GLB by any CLI route.** `--help` has no
export option; `.glb` is an **input** format for F3D, not an output one. The refusal raises
`GeneratePreviewJob::Unsupported`, which maps to the terminal **`unsupported`** status — deliberately
not `failed`, which a re-POST re-enqueues, so a client asking for the impossible would retry forever.

**⚠ DEPLOYING THIS DOES NOT MAKE EXISTING CAD FILES SPROUT THUMBNAILS, and that will look like the
feature is broken.** `available?` going true is not retroactive. Every `.obj`/`.step`/`.stp`/`.iges`/
`.igs` already seen on the deployed boxes carries `status: "unsupported"`, written by the job's own
`renderer toolchain unavailable` gate — and **nothing re-enqueues an `unsupported` row**:
`Maker::Previews::Enqueue` returns early unless the row is new or `failed`;
`V1::Maker::PreviewsController` resets to `pending` on the same two conditions; and
`FilesController#backfill_thumbnails` skips any node that already has a row for the current
`content_token`, whatever that row's status. Driven, not read: calling `Enqueue.call` on an
`unsupported` row leaves it `unsupported` and enqueues nothing. Registry has mapped these extensions
to `Mesh` since 2026-07-20 and `backfill_thumbnails` walks every renderable file in a viewed folder,
so those rows almost certainly exist on all three deployed backends already. **Consequence: the
feature reaches only content that arrives after the deploy; every CAD file already in a library keeps
its static "unsupported" badge until its bytes change.** A one-off sweep clearing `unsupported` rows
whose extension now has an available renderer is what closes it — `app/services/maker/previews/lbrn_backfill.rb`
is the pattern, and it was written for exactly this shape of problem. **Not done here** (it is a
migration-shaped operation, not an audit fix) and left as an open item below.

**The image cost — SETTLED BY THE DEPLOY, after two local tools disagreed 4x.** On the Unraid box,
which is the only measurement that decides anything: **887 MB → 1.57 GB, +683 MB (+77 %)**. Per-layer
from `docker history` on the build host agrees: `COPY /opt/f3d` = **321 MB**, the Mesa/EGL apt layer =
**205 MB**. **296 MB of the 307 MB `/opt/f3d` tree is `lib/`** — bundled VTK/OCCT/GDAL/USD that ships
whether or not a deployment ever opens a STEP file.

**An earlier revision of this paragraph said "roughly tripling", against a locally-built "before"
image of 229.8 MB. That baseline was wrong** — the real predecessor on the box is 887 MB, so the local
before-image was not the same artifact and the ratio taken from it meant nothing.
**`docker image inspect --format '{{.Size}}'` reported 229.8 → 387.5 MB while `docker image ls`
reported 230 MB → 1.57 GB** — a 4x disagreement between two commands that agreed *exactly* on the
base, and **the deploy proved `ls` right**. The lesson is this arc's own in a new place: when two
instruments disagree, do not average them and do not pick the reassuring one — **find the instrument
that decides.** Here that was the machine the image actually lands on.

**This is also what filled the box, and it is worth budgeting for.** The first deploy attempt failed
with `mkdir: No space left on device` at 31 G / **100 %** full. Kamal aborted while acquiring its lock,
**before touching the running container**, so the old version stayed up and serving — the failure mode
is safe, and a retry costs nothing. Dangling images reclaimed only **144 MB** (they share layers with
tagged ones, so the `docker system df` "reclaimable" figure badly overstated them); the real reclaim
was **7.5 GB of Docker build cache**, which is pure dead weight on that host because images are
cross-built on the Mac and the box only ever pulls. 99 % → **80 %**. All three destinations pull the
same tag, so one image's growth is paid once — but two versions are retained for rollback, so the next
image growth costs roughly double its own size.

**The runtime package list is 4 packages and it is DERIVED, not guessed** —
`libx11-6 libegl1 libegl-mesa0 libgl1-mesa-dri`. `readelf -d` across the binary and every bundled
`.so` shows **libX11 as the only external NEEDED** beyond what `base` already has. The rest is the
GL stack, and **the Mesa EGL driver is `dlopen`ed — invisible to `ldd`**, so the honest-looking
minimal list (drop `libegl-mesa0`, since nothing links it) gives **SIGSEGV 139 at render time**.
Only a real render settles this; static inspection cannot. Verified by rendering both `tetra.obj`
and a real 4.7 MB STEP file to PNG inside the image.

### 4. The GPL-3.0 boxes sidecar ships its own licence text

`sidecar/boxes/Dockerfile` now does `COPY LICENSE README.md ./`, matching `sidecar/openscad`. We
build these images and push them to a registry, which is **redistribution** — so under §9 the
licence has to be **inside the image**, not merely committed beside the Dockerfile. The `LICENSE`
had been in the repo since the addon landed and had simply never been copied in.

**`test/deploy_hygiene_test.rb`'s new assertion is DIRECTORY-DRIVEN, so it closes the class rather
than the instance:** it globs `sidecar/*/Dockerfile` and requires a `COPY … LICENSE` line in each,
so a third sidecar is covered the day it appears rather than the day someone remembers. Every
sidecar here is GPL by construction — that is *why* they are HTTP sidecars instead of linked
libraries — so the glob needs no allow-list.

**The second assertion exists because the first version was mutation-tested and failed.** Discovery
originally filtered to sidecars that "have a LICENSE beside them", which conflates *"this licence
needs copying into the image"* with *"this licence was ever committed at all"* — and so **silently
skipped the worse case**: a future sidecar whose author never added a LICENSE passes with an
unchanged assertion count, because the missing file is precisely what excluded it. A missing
`LICENSE` is now checked **first and separately**, because the two failures want different fixes: no
`COPY` line means the text is in the repo one line from being fixed; no `LICENSE` at all means the
image is being built and pushed under GPL with nothing to point at anywhere. **Found by mutating the
test, not by reading it.**

### 5. Two findings documented rather than fixed, both deliberately

Neither is duplicated here — each already has its own home in this file, and a second copy is a
second thing to go stale:

- ~~**No Linux runner is registered, so all 7 `ci.yml` jobs queue forever.**~~ **CLOSED 2026-07-29**
  by the CI arc — `ci.yml` targets `macos` and every linux/windows job is gated so it cannot queue.
  See "CI runs again, on the runner that exists" below (this bullet pointed at "CI cannot run", which
  that section replaced). Still true and still worth knowing: **Linux and Windows coverage is skipped,
  not passing**, and the two steps to restore it are recorded there.
- **The OVH deployment inherits `ENABLE_TEST_SIGNUP`** through Kamal's `env.clear` deep-merge — see
  the bullet under "Still open after this arc". Left on knowingly, with the one-line fix recorded
  both there and at the edit site.

### 6. The Rust counts CLAUDE.md now defers to this file

CLAUDE.md carried **`53 tests`** for `fs-provider`. Measured: **192 passed across 20 test binaries,
0 failed** (`cd client/fs-provider && cargo test`). **The stale number was DELETED, not updated** —
that list's own header already defers per-suite counts here, so writing the number in two places is
writing a number that will be wrong in one of them, and this one already was by 3.6x. A second count
of the same class went with it: `sync-engine`'s **`14 tests`** for the server-backed integration
suite, in the same list, for the same reason.

**So the deferral has to land somewhere, and this is it:**

- `client/fs-provider` — **192 / 0**, 20 binaries, hermetic (no server). Re-measured this arc.
- `client/sync-engine` `tests/integration.rs` — **NOT re-measured here**; it needs a running server
  and skips cleanly without one. Last recorded figure in this file is **19/0** (2026-06-14 entry).
  Treat that as dated, not current.

**A count in a file that is not the one that produces it is a count that rots.** Both of these are
readings taken on a date, not properties of the code — which is the same lesson as the stale
brakeman line below, and the same lesson as the advisory count above.

### Left open by the audit-fix arc

*(Distinct from the older `## Still open after this arc` section further down, which belongs to the
project-page overhaul and is where the `ENABLE_TEST_SIGNUP` bullet referenced above lives.)*

- **Existing CAD previews stay `unsupported` after the F3D deploy — a backfill sweep is needed.**
  Detailed in item 3 above. Nothing re-enqueues an `unsupported` row, so every `.obj`/`.step`/`.iges`
  already in a deployed library keeps its badge until its bytes change, and the shipped feature will
  read as broken to anyone looking at files they already had. The fix is a one-off sweep clearing
  `unsupported` rows whose extension now resolves to an available renderer, modelled on
  `app/services/maker/previews/lbrn_backfill.rb`. Deliberately not done in an audit-fix branch: it is
  a data migration over deployed rows, and it wants its own verification against a real library.

- **`config/brakeman.ignore`'s line numbers went stale twice inside this arc, and are now CLOSED —
  but the lesson is the one worth keeping.** All four entries were verified against brakeman's own
  output at the end of the arc; two disagreed and were corrected (`mesh.rb` 74 → **88**,
  `files_controller.rb` 728 → **729**, the latter pre-existing and not caused here). Fingerprints
  byte-identical, `bin/brakeman` still exits 0.
  **Measuring it requires re-running brakeman against an EMPTY ignore config** — that is the only
  way to see the line of a warning you have already suppressed, and it is why the drift survived so
  long unnoticed.
  **The mechanism this arc established is confirmed:** brakeman reports the `Open3.capture3` **call**
  line, not the line the argv array is built on. An earlier revision of the plan claimed the
  opposite and was corrected.
  **The lesson is the arc's own rule turned on itself.** The entry was fixed once mid-arc (59 → 74),
  and then `72e4e3f` added the GLB refusal *above* the call, moving it to 88 — re-staling a number
  that had been correct for three commits. A line number in a hand-maintained file is a
  **measurement**, and it expires the moment anything above it moves. Re-measure in the same commit
  that edits the file, or do not record it. Nothing about this ever threatened the gate — the
  fingerprint does not hash the line — but that file's whole value is that a reader can check it
  against the code.
  **Considered and declined: a test asserting every recorded line matches brakeman's output.**
  Brakeman runs in ~1 s, so cost is not the objection; the objection is that it would make the
  default suite depend on the `brakeman` binary being installed, which no test does today, to guard
  a field that is documentation rather than behaviour. Re-run the comparison by hand when editing a
  file that has an entry — the two-line Python that does it is in this arc's history.
- **`sidecar/boxes`'s licence obligation is closed; the wider one is not audited.** The test proves
  each sidecar Dockerfile copies *a* LICENSE. It does not check that the text matches the licence
  the upstream project actually ships under — for boxes.py that is GPL-3.0 and was checked by hand
  here, but the guard would not catch a wrong file.

## 2026-07-29: the four open items are CLOSED (branch `claude/status-md-open-issues-92c847`)

**Suite 1625 runs / 5655 assertions / 0 failures / 0 errors / 14 skips — byte-identical on chunk,
share and s3.** `bin/rails test:system` 6 runs / 28 assertions / 0 failures. rubocop **435 files, 0
offenses** (the repo's one pre-existing offence was swept too). `client/` has a zero-line diff. Both
standing tripwire greps still answer what CLAUDE.md §12 step 10 says they should.

Design: `docs/superpowers/specs/2026-07-28-status-open-items-design.md`.
Plan: `docs/superpowers/plans/2026-07-28-status-open-items.md`.

### 1. `attachments="false"` — CLOSED, option (c): BOTH halves

- **Server-side strip.** `Maker::TextOnlyRichText`, included by `Maker::Note` and
  `Maker::BuildLogEntry`, removes every `<action-text-attachment>` element on `before_validation`.
  It removes the ELEMENT rather than scrubbing attributes, so the guarantee survives whatever
  attributes Action Text or Lexxy emit next. **Stronger than designed, verified by probe:** a Trix
  `<figure data-trix-attachment='{"sgid":…}'>` posted by hand is *also* stripped, because Action
  Text canonicalises it into `action-text-attachment` on assignment, before the hook reads the
  fragment. Both wire formats an attacker could post are covered.
- **The route is REMOVED, not authenticated.** `POST <ActiveStorage.routes_prefix>/direct_uploads`
  is shadowed by an app-drawn 404. Confirmed the hole was real first: an unauthenticated POST
  returned **200, minted a real `ActiveStorage::Blob`, and returned a signed upload URL**.

**Three things about this that cost a review cycle each — do not rediscover them:**

- **`recognize_path` IS THE WRONG INSTRUMENT and reports the opposite answer.** A `proc` route
  carries no controller/action, so `recognize_path` skips it and names the *engine's* route. Only
  driving a real request settles it. The app route wins because `Rails::Engine#add_routing_paths`
  `unshift`s railtie route files while the app's own initializers run last — app route at index 9,
  engine's at 232, stable across `reload_routes!` and `eager_load!`.
- **THE SHADOW PATH MUST BE DERIVED, NEVER LITERAL.** The engine wraps its routes in
  `scope ActiveStorage.routes_prefix`. A hard-coded `/rails/active_storage/...` silently stops
  shadowing anything the moment that prefix is configured — **demonstrated**: with
  `routes_prefix = "/attachments"` the live endpoint moved and an anonymous POST again returned 200
  with a blob minted, while the suite went red on the *wrong* assertion carrying a *false* message.
  Loud about the wrong thing is close to silent.
- **`draw_routes = false` is ruled out** and must stay ruled out: `Maker::Preview` uses
  `has_one_attached :asset` served via `url_for`, so the blob routes are load-bearing. Pinned by a
  test, and verified end-to-end (real preview → `url_for` → 302 → 200 → bytes).

**A caveat on the "deliberate consequence" this design recorded.** The claim was that stripping makes
an attachment-only body fail `presence`. True only for a **captioned** attachment. An attachment
whose `sgid` does not resolve has no plain-text representation, so `ActionText::RichText#blank?` is
*already* true and the body was *already* invalid — a test using the bare form passes with or
without the concern. The presence tests use `CAPTIONED_ATTACHMENT` for exactly this reason.

### 2. Sheet `data` — CLOSED, bounded at 1 MB

`Maker::Sheet::MAX_DATA_BYTES = 1_048_576`, validated on `data.to_json.bytesize`. Bytesize rather
than row/column caps: one number, and it is the quantity that hurts — `projects/sheets/show.html.erb`
embeds the whole blob into the page on every view, so the blob size IS the page size. Measured cost:
`to_json` runs **once** per save, ~0.27 ms against a 13.4 ms save on a 272 KB blob.

**THE PLAN'S PREMISE WAS WRONG, and the correction is worth keeping.** It said an unrescued
`RecordInvalid` yields a **500**. It does not: `ActionDispatch::ExceptionWrapper.rescue_responses`
maps `ActiveRecord::RecordInvalid` to `:unprocessable_content` **by Rails default**, in both
`test` (`show_exceptions = :rescuable`) and production (`:all`). So the 422 was already free. What
the rescue actually adds is the **JSON body** — without it the grid's `response.json()` rejects and
the user is told to "check your connection" about a file that will never save. That made the
originally-specified test vacuous (it asserted only the status), so it also asserts
`response.media_type`.

Two more the review caught, both demonstrated:

- **`number_to_human_size` rounds both sides identically** → *"Data is too large (1 MB; limit 1 MB)"*
  for the first ~5,242 bytes of overage. Since a sheet grows one keystroke at a time via debounced
  autosave, **the first rejection a user ever sees is always that self-contradicting message**. Now
  raw delimited bytes.
- **The JS fallback had regressed the one case it exists for.** Sniffing `error.message` for an
  `"HTTP "` prefix routed the server's refusals correctly but showed the *browser's* jargon
  ("Failed to fetch" / "Load failed") for an actual outage. `save()` now handles `!response.ok`
  inline and returns, so the `catch` means one thing: transport failure.

### 3. Nothing executed JavaScript — CLOSED

`test/system/sheet_grid_test.rb` — the repo's second system test and the first to cover the grid.
Types a formula, asserts the **computed value**, then asserts the **raw formula persisted**.

- **It reaches the page by a Turbo VISIT** (clicking through from the project page), never
  `visit sheet_path`. A direct `visit` is a hard load — the one path where the `data-turbo-track`
  bug does not reproduce. This is the single easiest line in the file to lose in a later edit.
- **The obvious mutation is a FALSE NEGATIVE.** Removing `data-turbo-track` from the
  `javascript_include_tag` alone leaves the test green, because the `stylesheet_link_tag` on the
  same page is *also* tracked and Turbo hashes all tracked elements into one signature — it still
  hard-reloads. The honest reproduction removes it from **both** tags, and then the test fails at
  the missing `<td>`. Recorded in the test's own header so the next reader running the one-tag
  version does not conclude the test is worthless. The async-workbook bug (bug #1) was also
  reintroduced and also fails.
- **Waits on the ROW, not the indicator.** `assert_text "Saved"` is **vacuous** here — the status
  span ships from the server already reading `Saved`, so it passes before any save. Asserting the
  intermediate `Saving…` only moves the race (it lives for one 1000 ms debounce window; a slow
  round-trip on a loaded runner misses it). The test polls the record instead, then asserts the
  indicator last, when it is deterministic. Five consecutive suite runs, no flake.
- **No CI change was needed.** `.github/workflows/ci.yml` already runs `test:system` on a
  self-hosted linux runner with failure-screenshot upload. `test/system` is simply excluded from
  `bin/rails test`, which is exactly why the 1587 count never covered it.

### 4. The two vocabularies — CLOSED, ONE vocabulary

`FilesHelper::EXT_FAMILIES` is now **derived** from `Maker::FileAttachment::ROLE_BY_EXT`, grouped by
role and labelled/ordered by `ROLE_LABELS`, with `other` dropping out on its own (it is the fallback
for unrecognised extensions, so nothing maps to it). A new **`document`** role covers `txt`, `md`,
`markdown`, `json`, `csv` — the union of what `Maker::Previews::Registry` already routed to
`TextThumb` and what `EXT_FAMILIES` already grouped as "Documents", so the set is derived rather than
invented. `pdf` **stays `instructions`**: `Models::AttachmentsController` dispatches
`ExtractPdfMetadataJob` on that exact value, and a tripwire test now says so.

Chip families went **5 → 8** (Models, Images, Instructions, Documents, Vector, CAD source, G-code,
Archives) and extensions **19 → 28** — a strict superset, nothing lost. `.svg` now reads "Vector" on
both pages, and the five `cad_source` extensions finally have a chip. `markdown` is exactly 8
characters, the bound of `FilesController::EXT_RE`; the EXT_RE warning now lives at `ROLE_BY_EXT`
itself, because that is where extensions get added and whoever adds a 9-character one has no reason
to look in `files_helper.rb` to learn it renders a dead chip.

**The chosen option's cost, accepted deliberately and recorded so it is not read later as an
oversight:** `document` is an API-visible enum value whose only consumer is display, and it required
a second data migration. The argued alternative — keep two vocabularies, since `role` is a persisted
classification driving cover-pick/job-dispatch/API while `EXT_FAMILIES` is a display grouping — was
raised and set aside.

**Deriving at class-body evaluation time is correct, and the one real risk was tested rather than
reasoned:** a frozen snapshot going stale across a development reload does **not** occur — Zeitwerk
unloads `FilesHelper` along with the model, so the constant recomputes. Verified live, plus a
production eager-load check.

**The migration carries the predecessor's drift guard**, which it originally lacked. That matters:
re-mapping `csv` in the model while leaving the migration's frozen copy alone was verified to leave
the **entire suite green**, because every other test derives its expectation from one side only.

## 2026-07-29: CI runs again, on the runner that exists

Design: `docs/superpowers/specs/2026-07-29-testing-and-ci-pipelines-design.md`.
Plan: `docs/superpowers/plans/2026-07-29-testing-and-ci-pipelines.md`.

**✅ VERIFIED GREEN — the first successful CI runs since 2026-06-24.**
[Run 30511303225](https://github.com/chaim354/tinkerex/actions/runs/30511303225) on PR #102, **against
this branch MERGED WITH main**: all 7 jobs `success`, none queued. `CI_RUNNERS` is set to `macos`.

**Read that "merged with" carefully — it is the distinction that nearly slipped through.** GitHub's
`pull_request` runs here execute the **branch tip**, not a merge commit (`head_sha` has one parent),
and `mergeStateStatus: CLEAN` only rules out a *textual* conflict. So the first green run
([30510860301](https://github.com/chaim354/tinkerex/actions/runs/30510860301), 7/7 in **90 s**) proved
the CI fix but said nothing about main's concurrent work — which by then included a migration changing
`Maker::Preview` uniqueness, while this branch adds system tests touching the preview path. main was
merged in and the gates re-run to close that: **1672 runs / 0 failures / 0 errors** on chunk, share
and s3, plus 11 system examples. If you take one habit from this: a green PR check is not a green
merge, and on this repo it never was.

Three things that run proves, beyond "it went green":

1. **The jobs are actually picked up**, not merely re-labelled — they started progressively (2/7 →
   3/7 → 6/7) and the whole set finished in 90 s, against the ~30 s of real work measured locally.
   The serialisation worry that kept these on `linux` is settled.
2. **The preflight's outputs are real, not empty.** Its log shows `macos=true`, `linux=false`,
   `windows=false`. That distinction matters: an empty output (a mistyped `steps.<id>.outputs`)
   would ALSO make every gated job skip, so "the jobs skipped" alone would not have proved the gate
   works. The emitted values do.
3. **A gated job SKIPS instead of queueing.**
   [Rust client run 30510860302](https://github.com/chaim354/tinkerex/actions/runs/30510860302) on the
   same PR also finished **`success`**: `preflight`, `changes` and **`mac-tests` all green, with all 7
   linux/windows jobs `skipped`** — the exact behaviour this arc exists to produce. `mac-tests`
   passing is the second fix landing, and the more satisfying one: the hermetic Rust suite
   (fs-provider, sync-client, fs-cfapi, fs-fskit, the windows-gnu FFI cross-check, the native macOS
   build) had been dark for five weeks **solely because its gate job sat on a runner that does not
   exist**, while the runner it needed was online and idle the whole time.

**Note for the next arc:** the three `ci.yml` changes that had **never executed once** before this
(the two backend legs, added 2026-07-16, and the resvg step, 2026-07-20) all passed on their first
real run. They were unverified YAML, not broken YAML.

**A trigger fact worth knowing, since it cost a cycle here:** `ci.yml` fires only on `pull_request`
and on pushes to `main`. **Pushing a feature branch triggers nothing** — the branch push produced no
run at all, and the green run above came from opening the PR. There is no `workflow_dispatch` on
`ci.yml`, so there is no way to exercise it on a branch without a PR.

### What was wrong, and why it went unnoticed for five weeks

All 7 `ci.yml` jobs declared `runs-on: [self-hosted, linux]` while the only registered runner is
`charless-MacBook-Pro-maker-mac` (macOS). **CI had produced no successful run since 2026-06-24** — of
the last 300 runs, `CI` was 10 success (all ≤ Jun 24), 106 **cancelled**, 8 queued.

The reason nobody noticed is a **second, separate bug**: a job whose labels match no online runner
**does not fail**. It queues for 24 h at **0 elapsed** and GitHub then auto-cancels it, so
`mergeStateStatus` stays UNSTABLE and the merge happens with `--admin` (PR #94 did exactly this).
**`timeout-minutes` cannot help** — it starts counting when a job *starts*. There is no queue timeout.
The only fix is to never schedule the job.

A third, compounding shape: `rust-client.yml`'s `changes` gate job was itself linux, and **every**
other job in that workflow `needs:` it — including `mac-tests`, which targets the runner that was
online the whole time. One linux label took down jobs that could have run.

### What now runs where

- **`ci.yml`: all 7 jobs on `[self-hosted, macos]`**, each invoking exactly one `bin/ci <gate>`.
  `scan_ruby`+`scan_js` collapsed into one `scan` job. **No `ruby/setup-ruby`** — it assumes the
  GitHub-hosted `/Users/runner` layout this box lacks (`nightly.yml`'s `e2e-macos` already worked
  around it); the runner's own service PATH carries mise **ruby 3.4.7**, exactly `.ruby-version`, so
  `bundle install --quiet` is all a job needs. `test/ci_hygiene_test.rb` fails if the action returns.
- **20 linux/windows jobs across all four automatic workflows are `if:`-gated** on a preflight, so
  none can queue against an absent runner. `rust-client.yml`'s `changes` and `cross-os-e2e.yml`'s
  `seed` moved to macos (neither has an OS dependency; both were blocking their whole workflow).
- **The schedules stay armed.** `nightly` (08:00 UTC) and `cross-OS` (08:30) now complete in seconds
  with a step-summary naming what they skipped, instead of queueing 24 h. Commenting out a cron would
  stop the noise by making the loss silent.

### Local verification is ONE command

```sh
bin/ci            # every gate;  bin/ci --list to see them;  bin/ci scan / test-share / … for one
```

`config/ci.rb` is the single definition of every gate and `ci.yml` invokes it **by name**, so the two
cannot drift; `test/ci_hygiene_test.rb` asserts both directions. **The hand-copied 8-command checklist
that used to live here is deleted** — it was a third list claiming to be "the gates", and a
hand-copied checklist is exactly the artifact that let a non-gate pass as a gate.

**Because it was one:** until 2026-07-29 `bin/brakeman` exited **3**, and because `scan_ruby` ran it
as step 1 and `bin/bundler-audit` as step 2, **the audit gate had never once executed** — the job
looked like two gates and was zero. That is how five gems drifted behind 18 published advisories, one
High on the always-on `/cable` path. Read a scanner by **exit code**, never by output.

**That failure is now structurally impossible, not merely fixed.** All three scanners sit in one gate
and `ActiveSupport::ContinuousIntegration#step` records a result and **continues**, so each runs
whatever the others do. Verified by breaking `bin/brakeman` deliberately and watching the other two
still report. Do not split them back into separate gates.

`config/ci.rb` also dropped the Rails scaffold's `Tests: Seeds` step: `db/seeds.rb` is comments only,
so it asserts nothing, and `ci.yml` never ran it — keeping it would re-open the same drift in the
other direction. If seeds ever gain content, add the gate **and** a job, together.

### The fleet is DECLARED, not queried — do not "fix" this into a `gh api` call

`ci/preflight.sh` reads the repo variable **`CI_RUNNERS`** (default, deliberately conservative:
`macos` only). It does **not** ask GitHub, because it cannot: listing self-hosted runners requires the
**`administration`** permission, which is **not among those a workflow `GITHUB_TOKEN` can be
granted**, so `gh api repos/:owner/:repo/actions/runners` **403s from inside Actions**. It works in
your shell only because a personal token carries admin scope — and `ci/runners/README.md` documents it
that way, which is the trap. A stale declaration's failure mode is bounded and printed on every run;
a 403 preflight is a broken gate.

### Linux and Windows coverage is SKIPPED, not passing

A green CI run today is green about **less** than a full run. Not running:

- the **Linux FUSE mount path** (`fs-fuse` build, `fuser-mount-smoke-linux`)
- **`engine-integration`** — the sync-engine HTTP wire contract against a real booted server
- **`mount-conformance`** — rclone⇄WebDAV, fsx⇄FUSE, pjdfstest
- the **two-device real-mount E2Es** on Linux and Windows
- **every CfAPI job** — `windows-build`, the live smoke, `cfapi-conformance`
- the **cross-OS convergence legs** (`win-push`, `linux-edit`, `win-pull-2`), and with them
  `mac-pull-1`/`mac-pull-2`, which correctly cascade to skipped because there is nothing to read

To restore Linux: register a runner on the **Unraid box** (`192.168.1.95` — up, SSH open, already a
Docker host, deploy user `kamal1`) **and** add the family to the variable. Registering alone does
nothing:

```sh
gh variable set CI_RUNNERS --body "macos,linux"
```

Note `ci/runners/setup-linux.sh` is Debian/apt-shaped and Unraid is not, so that path is a container
or a VM. **CHAIMDESK (Windows) is reachable on the LAN but unregistered** — same two steps.

### Two gaps left open deliberately

- **`build-app.yml` and `install-app-on-runners.yml` are NOT preflight-gated**, and each still has a
  linux `prepare` job. Both are `workflow_dispatch`-only and both take their runner from a dynamic
  matrix (`[self-hosted, "${{ matrix.runner }}"]`) that no static check can resolve. The silent-rot
  failure this arc fixed needs an *automatic* trigger; a human who pressed "Run workflow" is watching.
  **Consequence: a manual run of either will hang until a Linux runner exists.**
  `test/ci_hygiene_test.rb` allowlists them by name with that reason inline.
- **`runs-on`'s map form (`{ group:, labels: }`) is not analysed** by the hygiene guard —
  `Array(hash)` yields `[k,v]` pairs, so a map-form job always *fails* the check rather than passing.
  That is the safe direction, and a correct reading is genuinely ambiguous (an org-level **hosted**
  larger-runner group and a self-hosted group share the identical YAML shape). No workflow uses it.

### The browser tier now exists

`test/system` went from **2 files / 6 examples to 5 files / 11 examples**, with a harness
(`test/system/support/web_helpers.rb`) and a written admission policy (`test/system/README.md`).

The gap it addresses: 13 Stimulus controllers totalling **1,035 lines** had **3** covered, and all
three got coverage only *after* a bug shipped — `tray_layout_test.rb` exists because
`<input type=text>` silently strips newlines and broke five box generators, one of them silently. No
request-level test could see it, and none did. New coverage: **`uploader`** (the chunk two-phase
presigned upload — the main deployment's upload path, and the bytes really move, because
`MemoryChunkStore` presigns to `/dev/blobs/*key` and a browser follows those relative URLs even though
the Rust suites cannot), **`importer`** (in-browser JSZip unzip → upload → attach, closing a gap
`models_import_test.rb` names in its own comment), and the **file-menu / attach-and-relocate** flow.

**The policy is load-bearing:** a system example costs ~932 ms against ~3.2 ms for a unit test — a
factor of **294** — so the tier admits only what is observable *only* in a browser. Without that
rule it either stays at six tests or swallows the suite. Every test in it is **mutation-checked**, and
`README.md` records two traps that cost real time: stale `tmp/dev-chunks*` blobs outlive
`ChunkStore.reset!` and made one mutation read **green**, and a synthetic Selenium attach cannot read
a fixture under a macOS TCC-protected directory.

**Suite: 1672 runs / 0 failures / 0 errors / 11 skips** on all three backends, plus 11 system examples (`bin/ci system`) — measured on the merged state.

## 2026-07-28: project page overhaul (PR #91) — four features, one branch

**Suite 1587 runs / 5482 assertions / 0 failures / 0 errors / 14 skips, byte-identical on chunk,
share and s3.** `client/` has a zero-line diff.

1. **Status pipeline hidden, not removed.** Flat project list, `?archived=1` view with Unarchive.
   The column, `STATUSES`, the validation and the whole v1 API are **untouched on purpose**:
   `client/sync-client/src/maker.rs` declares `pub status: String` with no `serde(default)`, so
   dropping the field is a hard deserialize error for a shipped desktop client. Consequence: a
   project set to `paused` from the desktop reads as an ordinary live project on the web.
2. **Files grouped by type**, plus `vector` and `cad_source` roles and a self-contained migration
   re-deriving rows marked `other`. `.sldprt`/`.sldasm` were nearly missed — the migration copies
   its extension list rather than deriving it, so adding them later would have needed a *second*
   migration.
3. **Lexxy on build-log entries and file notes**, text-only. **Two irreversible migrations** —
   both raise `ActiveRecord::IrreversibleMigration` by design, because `has_rich_text` reads
   `rich_text_body || build_rich_text_body`: deleting the rich texts makes the model return a blank
   that **shadows** any restored column, silently blanking every body. A pre-migration DB snapshot
   is the only undo. v1 `body` still serves a plain `String`.
4. **`Maker::Sheet`** — grid page, debounced autosave, CSV export, working formulas.
   **The formula engine was swapped:** `jspreadsheet-ce` needs a second peer dep,
   `@jspreadsheet/formula`, which publishes with **no licence grant at all** (no `license` field,
   `/LICENSE` 404s, no banner) and whose README asks for a paid licence for redistribution/SaaS.
   Under §9 it cannot ship. Replaced with `hot-formula-parser` 4.0.0 (MIT, MIT bundled deps) behind
   the grid's own `window.formula` hook. The contract is documented in the design doc §9b.1 —
   the grid resolves refs itself, expands ranges, and hands over a token→value map with
   **strings double-quoted**, which is the trap.

## 2026-07-27: OpenSCAD addon (branch `claude/opus-5-model-8b8462`) — **MERGED (PR #87) + DEPLOYED**

> *Section header corrected 2026-07-28: it said "NOT deployed" while this file's own top line said
> deployed. The top line was right — verified against the running containers on 192.168.1.95.*

`/tools/openscad` — the **second server-sidecar addon** (after `sidecar/boxes`) and the **first that
renders 3D**. A user picks a bundled generator or points the tool at their own `.scad` in the
library, fills in a form derived from that file's **own** Customizer parameters, and gets a
`3mf` + `params.json` bundle written through `Maker::Addons::LibraryOutput` with a grid thumbnail.
Design/plan: `docs/superpowers/specs/2026-07-27-openscad-sidecar-addon-design.md`,
`docs/superpowers/plans/2026-07-27-openscad-sidecar-addon.md`.

**Spec §10 held**: nothing here touches `Sync::*`, the changelog, conflicts, locks or the mounts,
and `LibraryOutput` / `AddonState` / `AddonFile` absorbed a brand-new addon **untouched** — which
was §6's claim, now tested rather than asserted.

- **Sidecar:** `sidecar/openscad` (GPL-2.0, internal-only, `tinkerex-openscad:8000`). Extracts the
  official OpenSCAD **2026.07.26** AppImage, sha256-pinned. Content-addressed render cache on the
  `openscad-cache` volume. Runs **non-root** (uid 10001) and carries its own `LICENSE`, `README.md`
  and `catalog/NOTICE` **inside the image** — a GPL image we redistribute has to ship the licence
  text and the third-party notices with the binary, not only in the repo.
- **Env:** `OPENSCAD_SIDECAR_URL`. Unset or blank → `OpenscadClient.configured?` is false → the
  `/tools` tile greys out. Set on the **three Unraid deployments only** (`deploy.yml`);
  `deploy.ovh.yml` blanks it deliberately, because Kamal deep-merges `env.clear` and the overlay
  would otherwise inherit a hostname that does not resolve on that box — an addon that reports
  itself available and then fails every call, strictly worse than greying out.
- **Catalog: THREE generators, not the four the plan listed** — `hex_cell_holder` (Unlicense),
  `washer` (MIT), `probe_plate` (MIT, first-party). Vendored at pinned commits with
  `catalog/NOTICE`. See the licence finding below for where the other two went.
- **ONE render path, TWO sources** (spec §3.1): Rails resolves a catalog key to source text via the
  sidecar's `GET /source/<key>` and then posts it to `/render` exactly as it posts a
  bring-your-own file's bytes, so nothing downstream can tell them apart. Do **not** add a
  `generator_key` fast path — that is two caches, two error surfaces, and a catalog free to drift
  from BYO behaviour.

**Things that will bite a future editor** (all observed, not reasoned):

- **A GARBAGE PARAMETER VALUE RENDERS SUCCESSFULLY.** Observed against the real sidecar:
  `{"cols": "))("}` comes back **200 with the DEFAULT geometry**, because OpenSCAD's parameterSet
  silently ignores a value it cannot parse. So a user's typo would yield a default-sized model,
  saved into their library, with no feedback anywhere. That is why **`app/services/openscad_params.rb`
  exists** — a coercion layer the plan's file table does not have. It checks every submitted value
  against its declared type and **raises rather than forwarding**, including for the cases that look
  like over-engineering: a blank number field (falling back to the default is the failure mode, not
  the fix), `1e400` (reaches OpenSCAD as the text "Infinity" and is ignored), a forged
  `params[cols][]=1` array, and a one-element vector (which `render.py` only re-brackets when it
  sees a comma, so `10` would arrive as a scalar and be type-mismatched away). Do not "simplify" it
  back to a pass-through.
- **`--appimage-extract` FAILS on the build Mac** (`Exec format error`, exit 126) — the AppImage
  runtime is a static ELF and Docker Desktop's amd64 emulation refuses it. Since CLAUDE.md §13
  cross-builds every image on the Mac, the Dockerfile computes the squashfs offset
  (`e_shoff + e_shentsize*e_shnum`) and runs `unsquashfs`, **executing nothing**.
- **Both required OpenSCAD capabilities are compile-time optional and fail INVISIBLY.** 3MF export
  without lib3mf writes nothing and **exits 0**; a missing Manifold backend silently falls back to
  CGAL (~20× slower on exactly the grid-shaped models this addon renders). `assert-capabilities.sh`
  asserts **six** things at build time — and asserts them on *evidence*, not exit codes: non-empty
  output starting with the `PK` zip magic, the literal string `(manifold)` in stdout, and separately
  that a **bogus** `--backend` value is rejected (otherwise `--backend=manifold` proves nothing).
  **Verified both ways**: they pass on a good build, and a shadowed script simulating a CGAL
  fallback fails the build with a named error.
- **`--export-format=param` has FIVE sharp edges, each of which silently produces a wrong form** —
  they are numbered TRAP 1–5 in `sidecar/openscad/schema.py`, next to the code that handles them:
  (1) a file with no parameters **omits the `parameters` key entirely** (`{"title":"empty"}`, not
  `[]`), so `for p in data["parameters"]` raises; (2) every number is a **float** (`4.0`, never `4`),
  so an int must be recognised by *value* or every count renders as "4.0"; (3) an enum is
  `type: number/string` **plus** `options` — **branch on `options` before `type`**, and keep the
  values apart from the labels, since `// [10:S,20:M]` gives a *numeric* value a human label;
  (4) a vector reports `type: "number"` with a **list** `initial` — there is **no** `"vector"` type,
  so branch on `isinstance(initial, list)`, never on `type`; (5) `caption` is present only when a
  `//` comment precedes the assignment, so fall back to the name.
- **OpenSCAD's 3MF output is NOT byte-reproducible** (F16) — three renders of the same file with the
  same params gave 3096 / 3098 / 3099 bytes. **Never assert byte-equality across two fresh
  renders.** A cache *hit* is fine: it replays stored bytes, which is exactly what the cache-hit
  test asserts.
- **`resources :openscad` is wrong TWICE over**, which is why the routes are top-level and explicit.
  Rails derives the collection helper from `name.pluralize` and the member helper from
  `name.singularize`, so `resources` leaves **`tools_openscad_path` meaning SHOW** — needing an id
  the `/tools` gallery does not have. And `namespace :tools` **prefixes `as:`**, so `as: :new_openscad`
  inside it yields `tools_new_openscad_path`, not `new_tools_openscad_path`.
- **READ THE FILE HEADER, NOT JUST THE REPO LICENSE — this disqualified 50% of the audited set.**
  The plan listed four generators to bundle, each with a licence taken from the repo's `LICENSE`
  file (agreeing with GitHub's licence detector, which reads exactly that). On opening the actual
  `.scad` files, **two of the four declared a *more restrictive* licence in their own header**:
  `universal_stand` ships a stock MIT `LICENSE` while its header says **CC BY-NC-SA 4.0**
  (NonCommercial *and* ShareAlike — the precise pair spec §2 was written about), and `vase_box`'s
  `LICENSE.md` is the full CC BY 4.0 text while its header line 3 says **Attribution-ShareAlike**.
  Both dropped. A repo-level LICENSE is not the licence of every file under it, and where the two
  disagree the conflict is itself disqualifying for something we redistribute in a sold product.
  Every rejection is recorded **with its reason** in `sidecar/openscad/catalog/NOTICE` so the audit
  is not run twice.

**Verification (this branch, measured — not "green"):**

- Server suite **1311 runs / 4536 assertions / 0 failures / 0 errors / 14 skips**, **identical on
  all three legs** (`bin/rails test`, `LIBRARY_BACKEND=share` with `LIBRARY_PATH` set,
  `LIBRARY_BACKEND=s3` with the `LIBRARY_S3_*` knobs CI uses). The 14 skips are the usual
  environment-gated ones (live sidecars, Postgres-only, uninstalled preview binaries).
- In-image Python suite: **40 passed, 0 skipped** — 0 skipped is the point, since these run *inside*
  the built image where the real OpenSCAD binary is present.
- Live integration against a **real container**: **6 runs / 33 assertions / 0 failures**
  (`test/integration/tools/openscad_live_test.rb`, skips cleanly with no sidecar).
- `bin/rubocop`: 401 files, **1 offence — pre-existing on `main`** (`config/routes.rb:46`,
  `Layout/SpaceBeforeFirstArg`, on a `notes#create` line this branch never touched). Left alone.

**Open — read this before assuming the addon is finished:**

- ~~**NOTHING IS DEPLOYED.**~~ **DEPLOYED 2026-07-27 (DoD #2 CLOSED).** Merged as PR #87
  (`33bd2d4`), `ghcr.io/chaim354/openscad-sidecar:latest` pushed, `kamal accessory boot openscad`
  run, and all **three** Unraid legs deployed (`bin/kamal deploy`, `-d s3`, `-d share`). **NOT
  deployed to OVH** — and note `deploy.ovh.yml` deliberately blanks `OPENSCAD_SIDECAR_URL`, so if
  OVH is ever deployed the addon greys out there rather than failing every call.
  **Verified on the live stack, not assumed:** all three containers run image `33bd2d40c`;
  `OpenscadClient.configured?` is true on each; each reaches the accessory and lists the real
  catalog (`hex_cell_holder,washer,probe_plate`); and an end-to-end render of `washer` through the
  deployed app returned a real 3MF (`PK`, 32,899 bytes), a **cache hit returning identical bytes in
  53 ms** (DoD #6), and a thumbnail mesh that parsed to 128,084 STL bytes (DoD #4's preview path).
- **CI DID NOT RUN, AND CANNOT AS CONFIGURED.** Every job in `.github/workflows/ci.yml` is
  `runs-on: [self-hosted, linux]`, but the repo now has exactly **one** registered runner —
  `charless-MacBook-Pro-maker-mac`. The `flasher-maker-linux` runner CLAUDE.md §15 lists is gone, so
  all seven jobs queue forever. **This affects every PR, not just this one.** *(Historical: fixed
  2026-07-29 — see "CI runs again, on the runner that exists". Left as written because it is the dated
  record of this arc, and it is also the third arc in a row that merged on locally-run gates.)* Each job's actual
  command was therefore run locally before merge: the three `LIBRARY_BACKEND` legs (1478 runs / 0
  failures / identical), `bin/rubocop`, `bin/brakeman`, `bin/bundler-audit`, `bin/importmap audit`.
  Three have findings and **all three are pre-existing on `main`** — this branch touches neither
  `Gemfile.lock` nor `image_thumb.rb`, and brakeman reports 1 warning on both sides.
- **DoD #5 — a real Multiboard `.scad` driven end-to-end in a browser — is OPEN**, and stays open
  here by design: spec §2 forbids us obtaining or redistributing MultiBuild files. The BYO code
  path itself is covered by the controller suite on all three backends and was driven against a
  live sidecar with an equivalent `.scad`.
- **The browser walkthrough (DoD #3, #4, #6 seen with human eyes) was NOT done.** Each of those
  three is covered by an automated test — the tile greying out, the save-and-thumbnail on all three
  backends, and a *measured* cache hit — but nobody has looked at the page.
- **This branch is 26 commits behind `main`** (merge-base `efde37e`; the "file organization and
  views" arc, PR #86, landed on `main` afterwards). `git diff main` therefore reads as if this
  branch deletes that work — it does not; it simply predates it. Merge `main` in before the PR.
  Expect a small conflict at the top of this file and in `CLAUDE.md` §12 step 9, where both sides
  added text.

## 2026-07-27: file organization and views (branch `claude/file-organization-views-3d06f4`)

Six pieces on the web UI plus one new pair of maker services. Design/plan:
`docs/superpowers/specs/2026-07-26-file-organization-and-views-design.md`,
`docs/superpowers/plans/2026-07-26-file-organization-and-views.md`.

**Suite 1277 → 1444**, identical on all three legs (`bin/rails test`, `LIBRARY_BACKEND=share`,
`LIBRARY_BACKEND=s3`: each **1444 runs / 4939 assertions / 0 failures / 0 errors / 8 skips**). The
last three came from the final review below: one pinning the free-text filter field, two pinning the
symlink decision (its Type-sort grouping, and the flat filter's deliberate exclusion of it).
**§10 held throughout** — nothing here touches sync, the changelog, conflicts, locks or the mounts.
The controllers never reach into `Sync::` or the port; they call `Maker::MoveNode`, which owns the
branch, exactly as `Maker::LibraryFolder` already does for `mkdir`.

### `Maker::MoveNode` — the `port_writable` branch, written out once more, so it got a name

`port_writable?` → `FileLayer.current.move`; else `Sync::Mutation.apply(op: "move")` +
`LibraryChannel.broadcast_change`. **The node_id never changes**, which is the whole reason a move
is safe to perform on a user's behalf — every attachment, BOM link and tag keeps pointing at the
same file.

**IT IS THE FIFTH APPEARANCE OF THAT BRANCH, NOT THE THIRD.** This heading and CLAUDE.md §12 step 9
both said "the third" (after `Maker::LibraryFolder#mkdir` and `FilesController#destroy`) until a
final whole-branch review counted them. The five: `Maker::LibraryFolder#mkdir`,
`FilesController#destroy` (port `delete` vs `Sync::SubtreeDelete`), `TrashController#restore` (port
`undelete` vs `Sync::Trash.restore`), `Maker::Addons::LibraryOutput.write` (port `write` vs a
server-driven `Sync::Commit`), and this one. The undercount mattered because of what it was used to
say — *"a fourth hand-rolled copy of the branch is the thing to refuse"* — which would have sent the
next reader looking for a threshold that had already been passed twice. **Only two of the five are
services; the other three are inline in the action that needs them**, so the real rule is that a new
one needs an argument for being inline rather than named, and a verb more than one caller performs
does not have one. Not counted: the `require_capability!` gates and the views that pick an upload
*form* — those select a UI, which is `port_writable`'s stated one job.

- **Collision is detected in the `nodes` catalog, BEFORE either door**, and that is not
  belt-and-braces. `Share#move` refuses a taken name, but **chunk mode has no clobber guard of its
  own** — `Sync::Mutation` would happily create two live siblings with one name. Checking the
  catalog is the only check that is true on all three backends.
- **The input guards are there because only ONE door has any.** The port resolves its own arguments
  (`live_node!`, `parent_dir_rel!`), so share and s3 already refused a tombstoned source, a missing
  parent, a parent naming a *file*, and another user's node. The chunk door is handed the object and
  **succeeded at all four** — then broadcast a changelog `move` telling every device to reparent
  under a node it does not have. A class whose whole job is to hide the difference between the doors
  cannot let them disagree about what is valid.
- **`#leaf!` is three separate lessons, each a real bad write.** A **non-String bypassed the check
  entirely on chunk**: `new_name[]=a/b.stl` arrives as an Array, and `["a/b.stl"].include?("/")`
  asks whether some *element* equals `"/"` — false, so the chunk door committed and broadcast a node
  named `["a/b.stl"]`. `FileLayer::Share#leaf!` escaped only by calling `.to_s` first, so share and
  s3 were safe and **chunk — the main deployment — was not**. **Refusing beats copying that `.to_s`,
  and it was measured by mutating the line back**: the doors store the value they were *handed*, so
  coercing here validates a String and then writes an Array. A ~4 KB name renamed the file and
  appended the changelog entry **before** `CookieOverflow` 500'd the response → **`MAX_NAME_BYTES =
  255`, bytes not characters** (ext4/APFS/NTFS all cap a component there). And **backslash joins
  slash**, because the default Windows backend is CfAPI, where a name carrying `\` is a path.

### Attach: a dropdown, chips, and the file moves in

- **Attach dropdown + already-attached chips.** One `<select>` instead of a button per project, and
  the projects a file is already in are finally visible, with a detach `×`. A **non-nested `POST
  /attachments`** carries the project as a *body* param, because a `<select>` cannot set its form's
  `action` and the nested route needs the project in the path; `#set_project` reads
  `params[:project_id]`, which resolves a body param and a path segment identically, so this is the
  **same action** with no second create path and no JS rewriting `action` on change.
  **The explicit DOM id is load-bearing:** the layout's top-bar current-project switcher is *also*
  named `project_id`, so a default-id `f.select` put a second `id="project_id"` on the page whenever
  this control renders — i.e. whenever the user has a project. The label's `for` resolved to the
  FIRST match, the top bar's, whose `onchange` fires `requestSubmit()`: clicking the words "Attach
  to project:" focused the switcher, and one arrow key **silently changed the app's default save
  destination**. Pinned by a test that also asserts the id is unique in the document.
- **Attaching a file moves it into the project folder — on its FIRST project only.** A file another
  project already claims stays put; a file should not be yanked out of the folder that project put
  it in. **The attach is durable and the move is best-effort**: a collision or an unmounted NAS must
  never lose a reference the user asked for, and the reference is exactly as true with the bytes in
  the old folder. Every move outcome is a **symbol, not a raise**, because each one is an ordinary
  thing that happens to a library and the caller words a different sentence for each — an exception
  would make the happy path the only one written down.
  **`FileLayer::NotFound` is in the best-effort bucket on the attach path** (unlike the explicit
  relocate endpoint, where a caller error should 404): `#create` has already proved the node live and
  ours and ensured the folder, so a `NotFound` from the move is a race or an out-of-band store
  change — and **the attachment row is already committed**, so letting it escape would 500 a request
  whose durable half succeeded.

### A model's file brings the whole bundle — and moves NOTHING

An imported model is a bundle: STL plus instructions plus cover plus source archive, curated into
`Models/<slug>/` by the importer. Attaching any one of them attaches all of them and relocates
nothing.

- **The first instinct was to move the model's whole FOLDER into the project, and it is precluded.**
  `FileLayer::S3#move` refuses directories outright (`movable_file!`) — S3 has no directory and no
  rename, so a folder move is a **non-atomic cascade over every key with no undo for a half-finished
  one**. **A rule that relocates ZERO bytes is identical on chunk, share and s3 by construction**,
  rather than by three adapters happening to agree. That is why "moves nothing" is the rule and not
  a limitation.
- **Membership is the ATTACHMENT, not the folder.** A file can be moved out of `Models/<slug>/` and
  still belong to the model, and a stray file can be dropped in and not belong, so the
  `maker_file_attachments` row is what the rule asks. The lookup is **scoped to the user through
  that table** — it keys files by a bare `node_id` string with no FK, so an unscoped lookup would
  find another user's row pointing at the same id and attach that stranger's whole bundle.
  `order(:id)` is the rule, not decoration: a bare `find_by` is `LIMIT 1` over an unordered set,
  stable on SQLite by luck and plan-dependent on the managed Postgres.
- **The bundle write is two queries, constant in N** (one `pluck` for what exists, one `insert_all`
  for the rest). The loop it replaced cost 2 queries per file — **a 200-file model measured 407
  queries / 113 ms** — inside a write transaction, so on the SQLite self-host the write lock was
  taken at the first INSERT and held to COMMIT: **one bundle attach stalled every other writer in
  the app**. It is the shape `stat_all` and the Reconciler already had to adopt. One statement is
  also the whole atomicity story now, and a half-attached bundle is worse than none — it is the
  gutted-folder failure wearing the attachment table.

### `Maker::AttachToProject` — because the policy grew a second door

🔴 **`#create` enforced three rules; `#relocate` called the move directly, below all of them, and
inherited none.** Reproduced against a three-file model: `Models/widget/` was left holding two files
while the flash said "Moved widget.stl into Desk Lamp." The same door also yanked files out of other
projects' folders, and moved a file into a project it was **not attached to**, minting
`Projects/<slug>` as a side effect of the POST. **Copy-pasting the guards into the second door would
have left the trap set for the third**, so every rule is now a decision a door passes or opts out of
**in writing**: `:not_a_file`, `:model_bundle`, `:attached_elsewhere`, the `find_or_create_by`, and
the move all live in one object that both actions call.

**`#refusal_for` is PUBLIC** for the same reason: the collision prompt has to ask the same question
before *offering* a button. It was rendering a dialog wired to a move that gutted a folder.

### The collision prompt — and the three ways a prompt can lie

A name collision keeps the attachment and **asks**, instead of clobbering or silently doing nothing.
The attachment id rides back as `?move_conflict=<id>` to whichever page the attach came from, which
is why the resolution is a **concern** (`MoveConflicts`) and not two copies of an action.

- **Ask the predicate the code raises on, not a proxy for it.** The prompt asked
  `node.parent_node_id == project.folder_node_id` — *"did the move happen?"* — where its own sentence
  claims *"a file with that name is already in the folder"*. It now calls
  `Maker::MoveNode.collision?`, the exact predicate `#collision!` raises on, which **subsumes the old
  check and stops three false renders** (an empty project folder, a colliding sibling deleted out of
  band, a tombstoned project folder), **one of them reachable with no URL editing**.
- **The param outlives the conflict.** `#relocate` lands on the project page, so a browser Back
  re-GETs the file page with the id still in the URL — the prompt would then state something false
  ("it was left where it is") and offer to move the file in as `bracket (2) (2).stl`.
- **A resubmitted relocate is a no-op, not a second move.** The button is a POST, so a resubmit sends
  the name the first one already applied, and the short-circuit only knew the `new_name.nil?`
  spelling of "same name". The second submit was a **real move to where the file already was**,
  appending a redundant changelog `move` on chunk and broadcasting it to every device. *"Nothing to
  move — the sync engine must not be told otherwise"* is an invariant the suite already pinned for
  `#create`.
- **`#relocate` filters to `kind: "file"`, and that is a GUARD, not a filter.** Both ids come from
  the request there and `Maker::MoveNode` deliberately has **no cycle check**, so a crafted `node_id`
  naming a directory would move a dir under its own descendant — and a cycle in `nodes` makes
  `Sync::Search`'s `WITH RECURSIVE` walk spin unboundedly, **fatal on SQLite, which has no statement
  timeout**. A project folder only ever holds files, so refusing is cheaper than detecting.
- 🟠 **The rescue was wide enough to hide bugs, with a green suite.** `rescue ArgumentError` wrapped
  the whole method body, so arity drift in a port adapter's `#move`, a kwarg rename in `MoveNode`, or
  a nil reaching `File.extname` all became a 302 and a "couldn't move it" flash. Now
  `MoveNode::InvalidName` — an `ArgumentError` **subclass**, so existing rescues keep working — and
  bare `ArgumentError` is a programming error again and stays a 500. `ActiveRecord::RecordInvalid`
  was **dropped** from the list: no producer was found on the path, and an unjustified class there is
  the same bug-hiding shape. This matters most in the rename prompt, the first caller that routes a
  **user-typed name** through the mapping.

### Sortable Name / Type / Modified — two ordering authorities, one per mode

- **The folder view sorts in Ruby, and that is a decision (spec §5.2).** "Type" means the file's
  **extension**, and there is no expression for it portable across SQLite (self-host) and Postgres
  (managed) — `substr`/`instr` vs `substring`/`position`. The denormalized `ext` column that would
  fix it has to be **written by `Sync::Commit` and `Sync::Mutation`**: writing to the sync layer to
  serve a web view, **which is the §10 tripwire**. So all three keys sort the same way, uniformly,
  and none is more exact than another.
- **In FLAT mode the ORDER BY did move into SQL, and that is not a contradiction of §5.2.** There the
  ORDER BY is what the **LIMIT selects with**, so SQL has to be the authority. It is sound precisely
  because flat mode **already knows every extension a matching row can have** (at most `MAX_EXTS`),
  so ranking them is a `CASE` over the same LIKE patterns the WHERE already uses — ordinary ANSI SQL,
  no portable "extension" expression required. The folder view has no such list (its extensions are
  whatever is on disk), which is why it keeps `sort_nodes`. **A test asks for the same files both
  ways and compares the two orders**, which is the promise that actually has to hold. The tail is
  `name, node_id`: `name` so the two views break ties alike, `node_id` so the truncation boundary is
  total instead of the planner's choice.
- **There is no Size sort, and the reason is the port** (spec §5.3): size is the one column whose
  value is **not read from `nodes` on every backend** — `Chunk#stat_all` reads it from the `versions`
  row, `Share#stat_all` straight off the node. It would be the only inexact key, and an inexact sort
  in a column of exact-looking numbers is worse than no sort.
- **"Kind" became "Type" and now renders the extension.** Making the old column sortable without that
  would have left a header naming something it does not show: every value the word "file", while the
  rows around it reorder. A **symlink says "Symlink"** rather than borrowing the extension of
  whatever it is named after — and symlinks now group **with** files, where the `kind: :desc`
  ordering this replaced put them above every real file purely because "symlink" > "file"
  alphabetically.
- **The comparator negates instead of reversing.** `sort ascending then reverse!` flips the **ties**
  too, so "Type descending" reordered files *within* one extension for no reason the user asked for
  — and it made the folder view disagree with the flat view, whose SQL breaks ties ascending.

### A flat by-extension filter across the whole library

`?ext=stl,3mf` lists every matching file at any depth, with a **Folder column** so the result is
navigable and doubles as a way to find things. `?folder=` is **ignored outright** rather than
intersected: "show me every .stl" that quietly meant "in this folder" would be the wrong answer to
the only question the chips can ask. Extensions are whitelisted to `[a-z0-9]{1,8}`, which is what
bounds the OR-ed LIKE, and the chip row is a **fixed shelf, not real facet counts** — counting
"you have 214 .stl files" means plucking every filename in the library on every Files page load,
including plain folder browsing that never looks at the chips.

  *(Amended 2026-07-29: this said "**curated** shelf" and the curation half is no longer true.
  `EXT_FAMILIES` is now DERIVED from `Maker::FileAttachment::ROLE_BY_EXT` — see the 2026-07-29 entry
  at the top — so the row is whatever the role vocabulary contains, not a hand-picked list. The
  argument the sentence exists for is untouched: it is still a fixed shelf rather than counted
  facets, and the cost argument against real counts still stands.)*

- **`LOWER(name) LIKE`, not a bare LIKE:** SQLite's LIKE is ASCII-case-insensitive and Postgres' is
  **not**, so the bare form answers differently on self-host and managed. **No test leg can see that**
  — all three run SQLite — so it is pinned by reading the SQL. Same shape for **`ESCAPE '\'`**:
  Postgres treats backslash as LIKE's escape character by default and **SQLite has none at all**, so
  without it `sanitize_sql_like` is a **no-op on half the deployments** (verified on this repo's
  connection: `'x.st\l' LIKE '%.st\_'` → 1, with `ESCAPE '\'` → 0). `EXT_RE` makes both unreachable
  today, but "fails closed by accident on one database" is not defense in depth.
- **`FLAT_LIMIT = 2000` is the first bound this page has ever had.** The folder view is still
  **unbounded** — a folder is self-limiting, a whole-library type view is not — and the cut is
  **announced** ("Showing the first N of M matching files"), because a silent one reads as "that's
  all your STLs", the same class of lie as a paginated listing mistaken for a snapshot.
- 🔴 **And the first implementation of that bound showed the WRONG ROWS.** The page query was
  `.order(:name).limit(FLAT_LIMIT)` and `sort_nodes` then reordered the slice, so **selection was
  always alphabetical while display followed the user**. Measured: 30 `.stl` files, `FLAT_LIMIT` 5,
  `?ext=stl&sort=modified&dir=asc` rendered the five **newest** under a banner reading "the first 5".
  **That is the exact class of lie the announcement exists to prevent** — phase 3's partial-listing
  landmine wearing a web page. Found by measurement, not by reading.
- 🔴 **The flat view also turned the per-row thumbnail backfill into a library-sized burst.** The
  lazy backfill was written for a *folder*; in flat mode it walks the whole library. Measured on a
  2500-file library, chunk and share alike: one `GET /files?ext=stl` ran **6008 queries, inserted
  2000 `maker_previews` rows, enqueued 2000 jobs, ~1.4 s in one request**. Now `BACKFILL_LIMIT = 100`
  per request: **308 queries, ~0.4 s**. **A budget, not a correctness limit** — it walks in display
  order, so the budget is spent on what the user is most likely looking at, and the backlog still
  drains because each visit takes the next slice. **The cap is uniform, not flat-mode-only**: the
  hazard is not the mode, it is a page whose row count is not user-shaped, and a 2000-child folder is
  rarer but identical in shape once you are in it.
- 🟠 **The test that should have caught that burst could not see it.** "Does not add a query per row"
  had fixtures with **no content token**, so the backfill skipped every row and the assertion was
  measuring nothing. With production-shaped rows the same assertion read few=17, many=44.

### The intermittent — captured for the first time, and the explanation offered with it is WRONG

The undiagnosed `1 errors` recorded in the "Open, and shipped knowingly" section below (and in
`CLAUDE.md` §12 step 10) — seen once each by several sessions across hundreds of runs, **never
captured by anyone** — was **captured this session**:

```
Tools::GeneratorsControllerTest#test_create_rejects_an_over-cap_svg_with_422:
ActiveRecord::StatementTimeout: SQLite3::BusyException: database is locked
    test/controllers/tools/generators_controller_test.rb:9:in 'block in <class:GeneratorsControllerTest>'
```

Line 9 is the `User.create!` in `setup`, with a **hard-coded** `gen@example.com`.

**The cause offered alongside the capture was: "parallel workers share one SQLite file, so every
worker running this class contends on the same row." That is disproved, and recording the
disproof is the point.** It rested on the comment at `test/test_helper.rb:27` — *"Each parallel
worker shares one DB"* — **which is itself false**, and has now been corrected in place. `ls
storage/` shows `test.sqlite3_0` … `test.sqlite3_9`: Rails'
`parallelize(workers: :number_of_processors)` really does give each worker **its own SQLite file**,
exactly as the *other* comment in the same file (lines 16–20) already said. Two workers therefore
cannot contend on that row, the hard-coded email carries no cross-worker weight, and **the whole
cross-worker story cannot be the cause**.

**So: symptom captured for the first time; the offered cause disproved; the real cause OPEN but far
better scoped.** It is a `BusyException` on a **per-worker** database, which means whatever held the
write lock was **inside that worker** — a second connection out of that worker's own pool
(`max_connections` defaults to 5 in `config/database.yml`) or a background thread — not another
worker. The scale is worth stating: `timeout: 5000` in the same file, so the blocked statement
waited a **full five seconds** for a lock, in a suite whose entire run finishes in ~4.2 s.
The earlier data point fits the same shape: one sighting had exactly **12 fewer assertions** than a
steady run, i.e. the aborted test contributes 12 assertions and died at or very near its start —
which `setup` is.

*(The 12-assertion figure is carried forward from the earlier sighting's report, not re-measured
here.)*

### The final whole-branch review — no blocking issues, five cleanups applied

The review found the branch mergeable. Five cheap corrections landed on top of it, and the shape of
the set is worth reading before the items: **three of the five were comments alone** — the code was
right and the specification beside it was not, which in this repo is the same class of defect — **a
fourth was an invariant a comment STATED and the code two lines below it broke**, and **only one is
something a user would actually have hit.**

- 🟡 **THE ONLY ONE A USER WOULD HAVE HIT: the "or an extension…" field silently did nothing once
  eight types were active.** `resolve_exts` keeps `.first(MAX_EXTS)`, so
  `?ext=stl,3mf,obj,step,stp,svg,dxf,pdf&add_ext=lbrn2` came back with the same eight chips and no
  `.lbrn2` — **two inches from a `.lbrn2` CHIP correctly rendered inert** with "Turn one off first".
  That is verbatim the condition `ext_slots_left?` exists to prevent ("a control that renders, links,
  and silently does nothing"): **fixed for the chips, missed for the escape hatch beside them.** The
  field and its button now go `disabled` on the same predicate, carrying the same sentence from the
  same string (`ext_limit_title` — two controls answering one condition is exactly how they drifted).
  **Disabled before the submit rather than explained after it**: the only thing a user can do is turn
  one off, and saying so up front costs no round-trip. A hand-edited URL is still dropped silently,
  deliberately — that is `EXT_RE`'s standing rule for anything arriving in a URL, and this finding is
  about a control, not about input.
- 🟡 **SYMLINKS: three features disagreed, and the disagreement was silent.** `file_type_label`
  states an invariant — the Type column "MUST AGREE WITH WHAT THE 'Type' HEADER SORTS BY" — and then
  **contradicted it two lines below itself**, rendering `Symlink` while `sort_key` keyed the row on
  its extension. Reproduced with `aaa.stl`, `bbb.stl`, `ccc.3mf` and a symlink `mid.stl` under
  `?sort=type&dir=asc`: cells read `["3MF", "Symlink", "STL", "STL"]` — a row labelled Symlink
  sitting inside the STL block. Meanwhile the flat filter's `.where(kind: "file")` **excluded** a
  symlink named `alias.stl` that the folder view happily lists; the sorting task had reasoned
  symlinks "are usually symlinks TO files" and grouped them with files, and the filter task
  disagreed with no note. **The decision, now written down in all three places: a symlink is its own
  type, consistently.** `sort_key` answers the literal `"symlink"` — the column's own label,
  downcased, so the group lands where the word "Symlink" falls among the other labels rather than at
  an end somebody has to justify. The flat filter keeps excluding them, and now says why: a type
  filter asks "show me my STLs" and a symlink named `alias.stl` is not one — its content is a path.
  **The divergence from the folder view is deliberate and recorded as such** (a folder view shows
  what is really there; a type view shows what you asked for). Spec §6.3 argued only the *directory*
  case, which is why the symlink half had no sentence to inherit. **`sort_nodes`' partition is a
  separate question, still answered the same way** — a symlink is not a folder, so it stays in the
  file block; its type key decides where inside it. Pinned by a test using **two symlinks with
  different extensions** (one alone is trivially "grouped", two sharing an extension pass with the
  old key), asserted in both directions; mutation-checked by reverting the branch.
  **`files_sort_test.rb`'s existing symlink test structurally could not see this** — it asserts under
  the default *name* sort, where the type branch is never called.
- **The `MoveConflicts` writer audit named the wrong writers.** It enumerated every writer of
  `maker_file_attachments` and was last touched *before* the attach policy was extracted:
  `Projects::AttachmentsController` has written no row since (it only reads), and the list omitted
  **`Maker::AttachToProject`**, which is the writer for both doors and holds the only `insert_all` —
  the one place `user_id`/`attachable_*` are set as **columns** rather than through the association,
  which is precisely what an audit about scoping should name. The safety *claim* held throughout; the
  enumeration a future auditor would have trusted did not.
- **`attach_bundle`'s ordering claim was not enforced by the query, and could not be.** The line
  claimed `&` "keeps the MODEL's order, so the project lists the bundle the way the model does".
  `insert_all` omits `position`, so every row takes the default 0 — as does **every row this table
  has ever held**, since no writer anywhere sets it — and `has_many -> { order(:position) }`
  degenerates to a total tie that survives only as SQLite rowid order, the exact reliance
  `#model_owning` three methods above says must not be trusted on managed Postgres. **Setting
  `position` was rejected rather than skipped, and the reason is the source, not the destination:**
  `node_ids` is read from `model.file_attachments.pluck(:node_id)`, which is *the same* all-zero
  `ORDER BY position ASC` (verified), so stamping positions would faithfully preserve an order that
  was already a guess — while making this the one writer in the app with a position convention, so a
  later ordinary attach lands at 0 and leapfrogs the bundle. Enforcing bundle order is a change to
  the **column's meaning across all six writers**, not to this line. The claim is gone; the dedupe
  half, which is sound and load-bearing, stays.
- **The `port_writable` branch count was wrong in both documents** — see the `Maker::MoveNode`
  section above. Five, not three.

### Deferred deliberately — so none of these reads as an oversight

- **`folder_paths_for` recurses, and depth is unguarded.** Its `"…"` marker is a correct **cycle**
  guard (a corrupt parent chain returns the marker instead of descending again), but nothing bounds
  a legitimately deep chain: a probe of the same lambda shape overflowed between **8,187 and 8,218**
  nested directories in a bare Ruby process, so a library with ~8k levels of nesting would raise
  `SystemStackError`. Stack-size dependent, so treat it as an order of magnitude rather than a
  threshold — and it is only reachable in flat mode, which is the only view that builds paths.
- **The Folder column does not truncate.** A very deep path renders in full and will stretch the
  cell.
- **`maker_file_attachments` still has no uniqueness index** on `(user_id, node_id, attachable)` —
  `find_or_create_by` and the bundle path's `members = node_ids & names.keys` are the only guards. A
  unique index would need a backfill dedupe, and this service is the sole writer. **What bundle
  attach changed is the blast radius: N rows rather than 1.**

**Found by the final review, each one DEMONSTRATED, none fixed here.** They are follow-up material
rather than blockers, and the branch should not pretend they do not exist. Four of them are one
shape — **a rule the code enforces correctly and the UI never mentions** — and the remaining two are
navigational (a missing affordance, a redirect that drops the user's place).

- 🟠 **AN ARCHIVED PROJECT'S CLAIM BLOCKS THE AUTO-MOVE INVISIBLY, and this is the one worth doing
  first.** `AttachToProject#attached_elsewhere?` does not exclude archived projects, while **both**
  halves of the file page's attach control do (`FilesController#show` filters the chips on
  `status != "archived"` and the dropdown on `where.not(status: "archived")`). Driven end to end:
  attach `c.stl` to "Old Rig" → archive Old Rig → **the file page shows no mention of Old Rig
  anywhere** → attaching to "Desk Lamp" flashes "Attached c.stl." and the file stays in
  `Projects/old-rig/`. `#relocate` on the same file then says *"belongs to another project"*, naming
  a project the page refuses to show. Either the policy should skip archived claims or the page
  should keep showing them; it must not be both.
- **`#create` is silent where `#relocate` has a sentence** — one policy, two doors, two answers.
  `#relocate` words `:attached_elsewhere`, `:not_a_file` and `:model_bundle` individually; `#create`
  collapses the two it can reach to the bare "Attached bracket.stl." (measured: "Attached
  elsewhere.stl." and "Attached adir."). *One correction to the review's wording:* **`:model_bundle`
  never reaches `#create`'s refusal at all** — `#call` intercepts it before `#refusal_for` and takes
  the bundle path, which says "Attached 2 files from Widget." So it is two of the three, and the
  bundle case is the next item rather than this one.
- **A model-bundle file's attach control gives no warning.** The branch's most surprising rule — one
  file brings the whole bundle, and moves nothing — is invisible on the file page until the flash
  reads "Attached 3 files from Widget." (verified: nothing in `files/show.html.erb`'s attach control
  mentions models).
- **Detach is not the inverse of attach.** Attach moves the bytes into `Projects/<slug>/`; detach
  removes only the row and flashes "Detached.", leaving the file in the folder of a project it no
  longer belongs to (driven: parent unchanged after the DELETE). Deliberate as far as it goes — a
  move back has nowhere obvious to go — but it is unwritten and it surprises.
- **The flat GRID has no location affordance.** The flat *list* gained a Folder column because "a
  flat list of 200 STLs with no location is unnavigable"; `_grid.html.erb` renders the same flat set
  as bare tiles, so two `bracket.stl` in different folders are visually identical.
- **`FilesController#destroy` redirects to bare `files_path`**, so deleting a row from `?ext=stl`
  drops the user at the unfiltered root (driven: `302 → /files`). **The one in-page path
  `files_query_base` did not reach** — `#rescan` right below it already carries the filter through
  its redirect, which is the shape to copy.
- **Pre-existing, not this branch, but now known: CLAUDE.md §12 step 10's proof-grep no longer
  returns nothing.** That step calls
  `grep -rn "manifest_chunks\|ChunkStore" app/services/maker/ app/models/maker/ app/jobs/maker/ | grep -v ':[0-9]*: *#'`
  "the proof, not the test suite" that the maker layer no longer references chunks. Run today it
  returns one hit: `app/services/maker/addons/library_output.rb:47`
  (`Storage::ChunkStore.current.put`), from the addon framework's server-driven chunk write. The
  *code* is defensible — it is one of the five `port_writable` two-door branches, and the chunk door
  has to put the bytes somewhere — but **the CLAIM is now false**, and step 10's own argument is that
  a proof which cries wolf gets ignored. Recorded as a discrepancy in the claim; this branch neither
  introduced it nor is the place to resolve it.

### Housekeeping

Two entries in "Open, and shipped knowingly" (below) were amended rather than appended to, per the
phase 4 follow-up's own finding that **a stale open-list is worse than none**: the intermittent is no
longer "never captured", and `FilesController#index` is no longer unbounded in *every* mode.

## 2026-07-23: Current Project — session-scoped default for saves, attaches, and uploads (branch `claude/current-project-concept-efcbf6`)

- **Current Project (2026-07-23):** a session-scoped "current project" shown in the top-bar
  selector (set/clear there or from a project page). Tool saves (Box Generator, Generators) default
  their save-folder to the project's `Projects/<slug>` folder and attach both output files; the
  Files-page upload defaults into the project (folder + attach) reusing the existing project
  upload/attach control, with a "library root instead" override. Session-only, zero-regression when
  unset; no models/migrations/JS; reads metadata + creates FileAttachment references only (§10
  untouched). Green on all three backends.
  - **Follow-up (share/s3 redirect parity):** the Files-page upload-to-project now returns the user
    to Files (the current-project folder), not the project page, on **all** backends. Chunk already
    did this via `uploader_controller.js`; the share/s3 multipart branch now carries an optional
    hidden `redirect_url` on `projects/_upload_control`, and `Projects::UploadsController#create`
    honors it — `url_from`-guarded so a tampered value can only ever be a same-app relative path
    (otherwise it falls back to the project page). The project-page and build-log uploaders omit it
    and are unchanged. Still green on all three backends (1257 runs).

## 2026-07-23: Generators addon — Maker.js harness + Material Test Grid (branch `claude/addons-brainstorm-plan-04adb7`)

The **first client-only `/tools` addon** — a browser-side **generator harness** (Maker.js, Apache-2.0)
whose Rails side is **generator-agnostic**, shipping with the **Material Test Grid** as its first
generator. Proves the client half of the addon framework (only the boxes.py *sidecar* addon had shipped).
Design/plan: `docs/superpowers/specs/2026-07-22-makerjs-generator-harness-design.md`,
`docs/superpowers/plans/2026-07-22-makerjs-generator-harness.md`.

- **`Tools::GeneratorsController`** (`index`/`create`/`show`) — persists a `Maker::AddonState` and writes
  the `[svg, params.json]` bundle via the existing `Maker::Addons::LibraryOutput`. **No new server
  infrastructure, no sidecar, no GPL.** Contains **zero** generator-specific code — verified by grep;
  all generator schema + geometry live in JS.
- **The harness** (`app/javascript/controllers/generator_controller.js` + `app/javascript/generators/`)
  — a Stimulus form-builder that renders the form from a JS module's param schema, previews the module's
  SVG live (data-URL `<img>`, XSS-safe), and POSTs the bundle. **Adding a generator = one JS module +
  one registry line — no Ruby change.** First module: `material_test_grid.js` (speed × power sweep →
  labelled SVG grid; speed across the top, power down the left).
- **Maker.js vendored** via the **jspm ESM build** (`bin/importmap pin`, not the `dist/browser.maker.js`
  standalone build, which only exposes Browserify's `require` — no importable default). `clone`→`buffer`
  reuses the existing hand-patched `buffer.js` (shared with jszip); `config/importmap.rb` documents the
  re-pin hazard.
- **`Tools::LibraryFolders`** — the folder-picker helpers extracted from `BoxesController` into a shared
  concern (DRY; both addons include it).
- **Browser-verified end-to-end** (live dev server): gallery tile → form built from schema → **live
  preview updates on edit** → Save → `[svg, params.json]` bundle in the library, versioned → reopen
  **rehydrates** the saved grid. The browser smoke caught a real importmap specifier bug (`generators`,
  not `generators/index`).
- Suite **1224 runs**, **identical on all three legs** (chunk / `LIBRARY_BACKEND=share` / `=s3`: 0
  failures, 0 errors, 8 skips). *(Running the s3 leg locally needs `LIBRARY_S3_*` dummy env, as CI sets;
  the share leg needs `LIBRARY_PATH=$(mktemp -d)`.)*
- **v1 scope (deferred):** simple labelled grid only (no color-coded laser layers); each Save creates a
  new state (no in-place re-versioning); SVG output only (DXF is a near-free future add via
  `makerjs.exporter.toDXF`); no second generator (the harness exists to make them trivial).

## 2026-07-22: interactive 3D viewer (branch `claude/3d-viewer-models-18a424`)

Client-side WebGL viewer (rotate/zoom/pan) for the mesh formats a print library is made of —
`.stl`, `.3mf`, `.obj` — on the file detail page (`/files/:id`, the link target from every model's
file tree). STEP/IGES/DXF keep their static thumbnails. Design/plan:
`docs/superpowers/specs/2026-07-22-3d-model-viewer-design.md`,
`docs/superpowers/plans/2026-07-22-3d-model-viewer.md`.

- **New `:model3d` preview kind** (`FilesController#preview_kind`) routes stl/3mf/obj to a viewer
  container in `files/show.html.erb`; the server-rendered thumbnail stays as the fallback poster.
- **`modelviewer` Stimulus controller** — DYNAMIC-imports Three.js (so the payload ships only on
  3D-file pages), `fetch`es the raw bytes from `/files/:id/blob`, parses with the format's Three.js
  loader, renders an OrbitControls scene with a **dimensions readout** (X×Y×Z mm) + **reset** +
  **fullscreen**. Any failure (no WebGL, cross-origin fetch w/o bucket CORS, corrupt file) keeps the
  thumbnail poster — verified in-browser incl. the degradation path.
- **Three.js 0.185.1 + STL/3MF/OBJ loaders + fflate vendored** into `vendor/javascript/` (MIT,
  committed, offline-CI safe) from the official unpkg ES build (not jspm — it splits/chunks the
  core). Two relative imports repointed to bare pinned specifiers; no dangling import remains.
- **Byte delivery:** same-origin on the share backend + multi-chunk chunk files (works out of the
  box); cross-origin presigned on s3 / small chunk-over-S3 files needs a one-time **bucket CORS**
  rule (`docs/DEPLOY.md`), else those files degrade to the thumbnail.
- Suite **+3 tests**, identical on all three legs (chunk / `LIBRARY_BACKEND=share` / `=s3`), 0
  failures; production `assets:precompile` clean.

## 2026-07-20 PM: addon framework, Plan A (branch `addon-framework-plan-a`)

The reusable, backend-neutral **addon framework** + the **Box Generator addon UI** (against a
**stubbed** `BoxesClient` — the Python sidecar is **Plan B**). Design/plans:
`docs/superpowers/specs/2026-07-20-addon-framework-boxes-design.md`,
`docs/superpowers/plans/2026-07-20-addon-framework-plan-a-rails.md`.

- **`Maker::AddonState` + `Maker::AddonFile`** — one saved addon thing = structured `data` (for
  reload) + a **tied bundle of any number of files of any type**, each a library node with a role.
- **`Maker::Addons::LibraryOutput`** — the one generic write: hands a SET of files to the library
  through `FileLayer`, tying each to the state. Works on **all three backends** (share/s3 via
  `FileLayer#write`; chunk via a single-chunk `Sync::Commit` + new **`Storage::ChunkStore#put`**, a
  scoped server-side write for generated content — there is no client to presign for). Each written
  node auto-previews.
- **`Maker::Addons::Registry` + `/tools` gallery** — ext-registry pattern; adding an addon = a
  `Tools::` controller + one registry line. Nav link added.
- **`Tools::BoxesController`** — dynamic form from a generator's param schema, live preview
  (rasterized to PNG via resvg), save-the-bundle (svg output + params file tied together).
  `BoxesClient` (HTTP) + `FakeBoxes` stub; Boxes greys out when `BOXES_SIDECAR_URL` is unset.
- **v1 scope deviations (deferred):** no auto-created per-save folders (flat write, tied via the
  `AddonFile` join); no in-place regenerate/versioning (each save creates a bundle).
- Suite **1038 → 1050**, identical on all three legs (chunk / `LIBRARY_BACKEND=share` / `=s3`).

### Plan B — the Boxes Python sidecar — DONE + LIVE (2026-07-20 PM, PR #60, `sidecar/boxes`)

The Box Generator addon is **functional in production**. A forked `boxes.py` runs as a **GPL-isolated
Python sidecar** (Kamal `boxes` accessory, internal-only container `tinkerex-boxes`), and the Plan A
`BoxesClient` drives it.

- **`sidecar/boxes`** — a Flask app over the `boxes` library (pinned git ref, forkable): `GET
  /generators` (185 generators + typed param schemas, internal/advanced params filtered), `POST
  /generate` (→ SVG, 404/422 on bad input), `GET /up`. Own **GPL-3.0 LICENSE**; slim gunicorn image
  built/pushed **separately** from the Rails app (`bin/build-boxes-sidecar`). §9: never imported into
  `app/` — talked to over HTTP only.
- **Deploy live:** `BOXES_SIDECAR_URL=http://tinkerex-boxes:8000` on all three app legs; verified from
  the share app container — `configured? true`, 185 generators, a real `ABox` renders (14 KB SVG).
- A real-sidecar Rails smoke (`test/integration/tools/boxes_live_test.rb`) skips without a sidecar,
  passes against one. Suite **1050 → 1052**.
- **Both Plan A + Plan B are on `main` and deployed.** The addon framework is proven end-to-end.

## 2026-07-20: eager PNG thumbnails for STL/3MF/SVG/DXF/LightBurn, shown in the web UI

Branch `previews-server-side-thumbnails`. The existing `Maker::Previews` render engine (Registry →
renderer → `GeneratePreviewJob` → `Maker::Preview` asset, served off Rails) is now **completed,
hardened, and connected to the browser**:

- **All thumbnails are PNG.** New `Maker::Previews::SvgRasterizer` rasterizes SVG→PNG via the
  **resvg** CLI (Rust, MPL-2.0/Apache — permissive), so SVG/DXF/LightBurn stop emitting
  `image/svg+xml` (which the web layer refuses to inline as an XSS vector) and match STL/3MF.
- **Extensibility is mechanical.** A shared **renderer contract test** runs every registered
  renderer (interface, `EXTENSIONS` resolve back through the Registry, inline-safe raster output) —
  it caught a stale `Mesh::EXTENSIONS` entry (`stl`, which routes to the euc `Stl` renderer) on the
  way in. Adding a format = module + one Registry line + fixture. See `docs/adding-a-preview-format.md`.
- **Eager generation.** `Maker::Previews::Enqueue` (idempotent, supersede-on-new-version) fires from
  every "bytes landed" seam: web upload (chunk two-phase finalize + share/s3 `create`), v1 commit
  finalize (desktop/API sync), and the share/s3 scan `Reconciler`. Never fails the write or scan.
- **Web UI.** The file grid shows the current-version thumbnail (batched `stat_all`-style read, one
  query), with a spinner + poll-until-ready Stimulus controller (`GET /files/thumbnails`, session-
  authed) and a format-icon fallback. The detail view shows the PNG for 3D/CAD/vector files instead
  of "No inline preview."
- **Deploy.** `resvg` is added to the Dockerfile (build stage verified in `rust:1-slim`) and to CI's
  three test legs (idempotent, non-fatal). **STEP/OBJ/IGES stay `unsupported` in-deploy** — F3D is
  still not shipped in the image (deliberate; `Mesh` stays registered so a box with F3D renders them).
  *(Superseded 2026-07-29 — **F3D is installed**: STEP/IGES/OBJ now render on the deployed image, via
  the `Dockerfile`'s `f3d` stage. The more surprising half: `model_glb` is now refused outright, not
  rendered — F3D's `--output` renders a raster and cannot emit a GLB by any CLI route, so a GLB was
  never obtainable this way.)*
- Suite **978 → 1023** runs, **identical on all three backend legs** (`bin/rails test`,
  `LIBRARY_BACKEND=share`, `LIBRARY_BACKEND=s3`: 1023 / 3329 / 0 / 0 / 5). The preview layer touches
  no sync internals (§10 tripwire grep clean).

## 2026-07-17 PM: all three FileLayer backends deployed live, web UI usable

**The whole maker/file-layer split (phases 1–4 + follow-up) is on `main` and DEPLOYED.** Three
containers run on the Unraid VM `192.168.1.95` from one image, one per `LIBRARY_BACKEND`,
host-routed through one shared kamal-proxy — verified each booted into its own distinct backend:

| host | backend | scannable | syncable | port_writable |
|---|---|---|---|---|
| `chunk.tinkerex.local` | Chunk | false | true | false |
| `s3.tinkerex.local` | S3 (SeaweedFS `my-bucket`, prefix `library/`) | true | false | true |
| `share.tinkerex.local` | Share → **the real Unraid `3D Printing` SMB share** | true | false | true |

- **Deploy mechanics:** `config/deploy.{s3,share}.yml` overlays; each destination has its OWN
  SQLite volume (a shared one would put three apps on one DB); share/s3 set
  `STORAGE_BACKEND=memory` to neutralize the chunk env Kamal's `deep_merge` can't delete — inert
  only because the Phase 4 `syncable?` gate stops a share/s3 container ever building a chunk store
  (without it every v1 request 500s). Client `/etc/hosts` → `192.168.1.95 chunk./s3./share.tinkerex.local`.
- **The share is a real NAS mount:** a **Docker CIFS volume** (`tinkerex_library_3dprinting`,
  guest, `uid/gid=1000`) over `//192.168.1.146/3D Printing` — no host `sudo mount`, no cifs-utils;
  only the `cifs` kernel module is needed (persisted in `/etc/modules-load.d/cifs.conf`).
  **Do NOT `docker volume rm` it** — Kamal would recreate it as a plain EMPTY local volume and the
  library would silently go blank. Scanned live: **418 real files** indexed, `node_id`s stable.
- **Three web-UI features shipped this session** (all on `main`, all deployed, TDD + mutation-verified,
  all three legs green):
  - **Folder navigation** (`5c415ff`) — `#index` scopes to `params[:folder]` (validated: ownership
    + `kind: dir` + fallback-to-root), folder rows link, breadcrumb. Was a flat dump of every node.
  - **OS-clutter ignore-list** (`b047a11`) — `Library::OsClutter.ignore?` (`.DS_Store`/`__MACOSX`/`._*`
    + volume metadata) is ONE shared predicate feeding **both** the observer skips AND the
    `observable!` write guards, so skip-set == write-refuse-set by construction (skipping a name
    without refusing it on write is the skip-list wedge). Existing clutter tombstoned cleanly (2%).
  - **On-demand "Rescan library" button** (`3cb2617`) — `POST /files/rescan` enqueues `ScanJob`,
    gated on `scannable?` (absent + refused in chunk mode). Complements the 15-min recurring scan.
- **Suite: 1007 runs / 3213 assertions / 0F / 0E / 5 skips, identical on all three legs.**

**Operational gotchas for the next agent:** (1) **1Password re-locks mid-session** — `op read`/`op
item get` then HANG; the deploy secret-guard aborts cleanly *before* touching anything, so a failed
deploy is safe to retry once the vault is reopened. Registry token = 1Password item `ghcr.io`
field `password` (NOT the `gh` CLI token — no `packages` scope); chunk/s3-library secret =
`op://tinkerex/seaweednew/secret key` (**vault corrected 2026-08-03** — these items moved out of
`Personal`, which a service account cannot read; `op://Personal/…` now fails). (2) The **s3 library
is up but its `library/` prefix is
EMPTY** — nothing seeded yet. (3) Deploy: `bin/kamal deploy` (chunk builds+pushes), then
`-d s3`, `-d share` (reuse the image). See `docs/DEPLOY.md` + the `deploy-build-workflow` handoff.

## 2026-07-17: the phase 4 follow-up — three items closed

**Server suite 954 → 978, identical on all three legs** — `bin/rails test`,
`LIBRARY_BACKEND=share`, `LIBRARY_BACKEND=s3`, each **978 runs, 3029 assertions, 0 failures,
0 errors, 5 skips**. (Run the legs **sequentially**: three Rails suites contend on one SQLite
test DB and give a false red in parallel. The share/s3 legs do not run bare — the boot guard
refuses without their env.)

- **`stat_all` — a bulk read verb, in the shared read contract on all three adapters.** Phase 4's
  measured N+1 is closed. `GET /files` at 2000 nodes, **before → after**:

  | backend | page | queries |
  |---|---|---|
  | chunk | 676.4 ms → **159.3 ms** | 4002 → **4** |
  | share | 439.0 ms → **160.0 ms** | 2002 → **3** |
  | s3    | 444.0 ms → **162.0 ms** | 2002 → **3** |

  **`stat_all` and NOT pagination, and they were never alternatives**: `stat_all` removes the
  per-row query, pagination bounds the render. The port is the file layer's lane, and the evidence
  the verb was missing is that **`Chunk#trashed` had already hand-rolled its exact two-query shape
  privately** — `FilesController#index` could not, because it holds an *adapter*, not a `Chunk`. A
  second bulk caller would have re-invented that query a third time. See the open list above for
  why pagination is not deferred work this creates.
  **The contract pins three things, and only the third is load-bearing against a loop:** stat_all
  answers exactly what stat answers; a missing node is an **absent key, not a raise** (stat is
  asked about one node, so NotFound is its whole answer — a bulk caller holds a list, and one row
  tombstoned mid-page must not 404 the page, which is what looping stat did); and **the query
  count does not grow with the list**. Mutation-verified: reverting all three adapters to a loop
  is RED on the third test *only* — the other two stay green, because a loop is behaviorally
  identical. Nothing else could tell a bulk read from an N+1.

- **A clobber is `UnsupportedOperation`, not `NotFound`.** A duplicate-name upload told the user
  **"File not found."** about a file sitting in the list behind the alert. Not a new class: the
  port's taxonomy sorts on **who is wrong and when you can know**, not on "how unsupported", and
  on that axis a clobber is the same shape as the directory delete the class was written for
  (client, runtime, per-path, ungateable by a per-deployment capability). `FetchError` would have
  been worse — it is the *retryable* answer, and retrying a clobber fails identically forever.
  **All three verbs, both adapters**: `write`/`move`/`undelete` all meet "the destination is
  taken", and fixing only the `write` the review named would have left renaming onto a taken name
  saying "File not found." while uploading onto one got an honest 422 — one condition, two
  answers, inside one adapter. The write contract now pins the class **per-verb**.

- **The s3 web write path is covered — and the coverage found a 500 on its first run.**
  `s3_delivery_test.rb` was delivery-only; nothing drove `FilesController#create`/`#destroy` or
  `TrashController` in s3 mode, while share had all three. **`TrashController` rescues `NotFound`
  but not `UnsupportedOperation`**, so the clobber fix (one commit earlier) turned an
  occupied-destination restore into an uncaught 500 — while **the controller's own rescue comment
  already named that case** ("something is already at that path") as one of the four it exists to
  catch. The class moved out from under a sentence that still claimed it. **Reading the rescue
  would not have shown this; driving it did**, which is the whole argument for the coverage.
  Reachable on **share** by the same route, so both adapters now pin it. The gap was in the
  **controller**, not in either adapter — which is exactly why no adapter suite could have found
  it.

## 2026-07-17: phase 4 — the UI and the API stop lying

`LIBRARY_BACKEND=chunk|share|s3` all **boot, index, write, deliver, and tell the truth about
themselves**. The maker/file-layer split is **complete**. (Suite **871 → 954** at the time; the
current count is in the section above.)

**Hand-verified against a real folder** (2026-07-17, not only in the suite — the DoD required it):
a real `LIBRARY_BACKEND=share` server over a real directory, scanned, then driven through the real
login form with a real cookie jar. `GET /files` listed **70 Bytes** and **39.1 KB** (not
em-dashes); the show page reported a real size with **no "No content yet."**; both files
downloaded through `/files/:id/blob` **byte-for-byte identical to the bytes on disk** (`cmp`, 70 B
and 40000 B) with `content-disposition: attachment` and **no `x-sendfile` header** (nil knob → the
`Rack::Files` branch, as designed). `GET /v1/nodes/:id/versions` answered **501** with the
capability named; `/v1/tree` and `/v1/changes` **501**; `/v1/maker/projects` **200**, ungated. A
device **enrolled successfully in share mode** — the concrete proof of the `devices` non-gate.
Rebooted in chunk mode on the same code: `/v1/tree` and `/v1/changes` back to **200**, and the
upload form switched to `begin_upload`/`finalize_upload` (share mode had rendered `POST /files`).

> **That run originally needed `STORAGE_BACKEND=memory`, and the caveat was load-bearing enough to
> be a bug.** `V1::BaseController#stash_request_base_url` resolved `Storage::ChunkStore.current` on
> every v1 request, and `STORAGE_BACKEND` defaults to **`s3` outside the test env** → `KeyError:
> CHUNK_BUCKET`. So a share operator following **the env in the box below** — `LIBRARY_*` set,
> `CHUNK_*` unset, exactly as documented — got **500 on the entire v1 API**, including the
> endpoints this paragraph reports as 501: the gate was correct and unreachable. **Fixed
> 2026-07-17** (the stash is gated on the capability that names a chunk data plane) and pinned by
> `V1::CapabilityGatingTest::NoChunkStoreTest`, which sets `STORAGE_BACKEND` to production's
> default with `CHUNK_*` unset — the nine gating tests before it set `FileLayer.current` and never
> touched `STORAGE_BACKEND`, so none of them could fail for the reason they existed.
>
> **The paragraph above was then re-driven with NO `STORAGE_BACKEND` set at all** (2026-07-17):
> `/v1/devices/login` **201**, `/v1/maker/projects` **200**, `/v1/tree` **501**, `/v1/changes`
> **501**, `/v1/nodes/:id/versions` **501**, anonymous `/v1/share/:token` **404**. It is now true
> as written, on the env a share operator actually sets.

**A share or s3 deployment sets NO chunk-store env** — no `STORAGE_BACKEND`, no `CHUNK_*`. Those
configure the *sync engine's* chunk store, which such a deployment does not have (`syncable:
false`: no changelog, no chunks, no devices). The library backend is the only storage knob:

```sh
# share — a mounted SMB/NFS directory
LIBRARY_BACKEND=share LIBRARY_PATH=/mnt/nas/models

# s3 — the user's own bucket (REGION defaults to "auto"; ENDPOINT for R2/SeaweedFS/MinIO,
# PREFIX for a sub-root, both genuinely optional)
LIBRARY_BACKEND=s3 LIBRARY_S3_BUCKET=… LIBRARY_S3_ACCESS_KEY_ID=… LIBRARY_S3_SECRET_ACCESS_KEY=…
```

`LibraryBackendCheck` refuses the boot and names the missing knob, so a typo stops the deploy
rather than surfacing as a 500 later. `LIBRARY_BACKEND` is unset/`chunk` for the sync product,
which is where `STORAGE_BACKEND` + `CHUNK_*` belong (`docs/SYNC_SERVER.md`).

**What was actually broken.** A share- or s3-backed library rendered a Download button that
**404'd**, a Size column of em-dashes, and "No content yet." for a file with bytes on the user's
NAS — because the views resolved `node.current_version`, which those backends have no such thing
as. The v1 API was worse: `GET /v1/nodes/:id/versions` answered **`{versions: []}`, a 200** — an
empty list is indistinguishable from "no history yet", so the lie was silent.

**`FileLayer#download` answers a `Delivery`**, and `FilesController` consumes it **without ever
constructing a path**:

| variant | backend | why it is the only honest one |
|---|---|---|
| `Redirect(url)` | s3; chunk **when single-chunk AND the store is `S3ChunkStore`** | the store has a URL signer → bytes never touch Rails (**§15**) |
| `SendFile(path)` | share | a mounted directory has **nothing to presign**. Carries the **path**, not the bytes → a 2GB file stays off the heap |
| `Stream(enum)` | chunk, multi-chunk | lazily stitched presigned GETs; Rails never holds the whole file |

`download(user, node_id:, disposition:, content_type: nil)` — **`disposition:` is required, not
defaulted**, and that is a real bug avoided rather than pedantry: nil makes
`ContentDisposition.format` emit a header with **no disposition type**, which browsers resolve as
**inline**. It would have diverged **on S3 only** (where the value is signed into the URL), and
silently.

**`Chunk#download`'s `is_a?(S3ChunkStore)` is deliberately NOT `presignable?`.** All three chunk
stores implement `presign_get` — but memory and local presign to URLs **Rails itself serves**, so
redirecting to one sends the browser on a pointless round trip back through us. "Can this store
presign?" and "does its URL point off-box?" are different questions. §9a-3/§9a-4 stay open; this
is why Phase 4 does not force them. The `chunks.size == 1` half is load-bearing too: a redirect
names **one** object, so redirecting a multi-chunk file hands the browser its first chunk with a
200 and the right filename — **silent truncation, no error anywhere**.

### `port_writable`, and the one way it will be misread

**It is NOT "can this deployment accept uploads."** It answers one question for one caller — the
upload form: **which upload flow does the UI drive?** *true* → POST the bytes to the port (share,
s3); *false* → drive `Sync::Commit`'s two-phase presigned flow (chunk). **Chunk mode accepts
uploads all day** — that *is* `Sync::Commit`. Reading the name the other way **hides the upload
button in the product's main deployment**. The name is about the **port's** write path, not the
deployment's.

`begin_upload`/`finalize_upload` therefore gate on **`syncable`**, not on `!port_writable?`: they
need `Sync::Commit`, which is what `syncable` names, and which is the gate `V1::CommitsController`
already uses for the same machinery. A backend with **neither** flow would be told "yes, use the
two-phase flow" by the derived gate and 500 inside it; the stated capability tells it the truth.
Task 1 also made the **read contract pin every capability to what the adapter actually does** —
`Capabilities` is a hand-written `Data` literal per adapter, and nothing else stops a boolean
lying about its own backend.

### The 501 is a gate before the call — never a rescue

`rescue NotImplementedError` was **rejected on its merits**, and the reasoning is recorded at
`app/controllers/concerns/library_capabilities.rb` so nobody "adds a backstop":

1. **It is a `ScriptError`, not a `StandardError`.** `rescue => e` does not catch it and
   ActiveJob's `retry_on`/`discard_on` do not either. A rescue-based gate does not have a *gap* —
   it silently **does not work**, failing to exactly the 500 the spec forbids.
2. **It would be factually wrong.** `Chunk#write` raising does not mean the deployment cannot
   accept uploads. It means **the caller used the wrong door**. 501 answers a true-sounding lie
   and sends the caller away instead of fixing the bug.
3. **It catches from anywhere below.** `FileLayer.build` (an s3 **misconfiguration**) and
   `ChunkStore`'s abstract methods raise it too — dressing a boot-level misconfiguration as "this
   deployment can't do that" launders it into a routine-looking response.

So it **stays un-rescued, and that is a feature**: a programming error should be loud and reach
the error tracker. `grep -rn "rescue.*NotImplementedError" app lib` returns nothing.
`FetchError` → **503** and `UnsupportedOperation` → **422**, mapped once at `FilesController`. The
503 is the one that matters: an unmounted NAS must never read as the terminal "your file is gone".

### Gated, and pointedly not gated

**Gated:** `changes`, `tree`, `conflicts`, `locks`, `commits`, `chunks#download`, v1 `trash`,
`nodes`, `share_links`.

**Not gated, each for a reason worth recording:**
- **`devices` — the plan said to gate it, and the plan was wrong.** A device token is the **only**
  credential the v1 API accepts, `/v1/maker/*` included, so gating enrollment would have made a
  share deployment's **entire v1 API unauthenticatable**. Worse, **the plan's own "maker is NOT
  gated" test would have stayed green**: it minted a token in Ruby instead of calling the endpoint
  a real client must call. A test that skips the door it is supposed to be checking.
- **`V1::ShareController`** — the anonymous redeem side of **public file links**, unrelated to
  `FileLayer::Share` despite the name. A 501 would disclose the backend to any stranger holding
  any string; the existing 404 is honest and terminal.

**Two gates are not the capability they look like:**
- **`chunks#download` → `syncable`, NOT `presignable`.** S3 answers `presignable: true` while
  having **no chunk to hydrate**.
- **v1 `trash` → `syncable`.** It is the *chunk* trash (tombstone + retained version). Running its
  restore against a 2b share tombstone would revive a node with `storage_path` **NULLed** while
  its bytes sit in `.trash`.

**The web trash is backend-neutral; the v1 trash is 501-gated. Same word, two surfaces, two
answers, deliberately.** `trashed` is the port's **fifth verb** and a **read**, so every adapter
answers it — chunk **delegates to `Sync::Trash`** rather than minting a rival definition of "the
trash". `TrashController#restore` branches on `port_writable?` exactly as `#destroy` does, because
what "restore" *means* differs: a tombstone in chunk mode, moved bytes on share/s3. A 501 rendered
as an HTML page to a human would also have been an API decision leaking into a UI — and false,
since `undelete` was built in 2b.

### There is no nginx: `send_file` is the whole X-Accel story

Deployment is **Kamal + kamal-proxy** (a Go proxy), and `x_sendfile_header` is **nil** — so
`Rack::Sendfile` no-ops and the `Rack::Files` branch is **the only one that runs**. We call
`send_file` and let Rails' existing knob do it; **nothing hand-rolled**. The knob is documented
**commented** in `production.rb` on purpose: kamal-proxy does not implement x-sendfile, and
enabling it would replace the body with `[]` and Content-Length with 0 — **silently serving empty
bodies** for every share-mode download.

### Open, and shipped knowingly

~~Four of the five items that stood here are **CLOSED** (2026-07-17, the phase 4 follow-up —
see the section below).~~ Two of them — `Share#undelete`'s missing `observable!` and
`Share#absolute_path`'s `allow_root:` — had **already been fixed by phase 4's own whole-branch
review** and were left standing here anyway: this list was written before that review and never
retracted, so it claimed two holes the code did not have. Verified against the code rather than
the history (`allow_root` survives only in the comments that describe its removal). **A stale
open-list is worse than no open-list** — it spends the next reader's attention on work that is
already done, and it is exactly the failure mode of asserting a fact in prose that the code
answers.

- ~~**An unexplained intermittent.** Two different agents each saw a single `1 errors` run that
  **never reproduced** (~73 and ~15+ subsequent full runs respectively, including cold-bootsnap
  and targeted-seed loops). Neither captured the message.~~ **CAPTURED 2026-07-27** — see "The
  intermittent" at the top of this file. It is a `SQLite3::BusyException` in
  `Tools::GeneratorsControllerTest`'s `setup`. **Still unexplained, but no longer unobserved**, and
  the cross-worker explanation offered with the capture is **disproved**: each parallel worker has
  its own SQLite file, so the lock holder is inside the failing worker.
- **`FilesController#index`'s FOLDER view is still unpaginated / O(n) rows**, and that is a decision
  rather than a leftover: it has never paginated, and the N+1 fix below did not change it. What
  remains at 2000 nodes is **~160 ms of render**, now **identical on all three backends** — which is
  the evidence that the port's cost is gone and the residual is HTML. Pagination is a file-browser
  decision on its own merits; it is not this regression's fix and never was. *(Amended 2026-07-27:
  the **flat** `?ext=` mode added in the file-organization branch **is** bounded, at `FLAT_LIMIT =
  2000` with an announced truncation — the first bound this page has ever had. The folder view is
  unchanged.)*

## 2026-07-17: phase 3 — point it at your own S3 bucket

`LIBRARY_BACKEND=s3` + `LIBRARY_S3_*` boots, indexes an existing bucket, and reads/writes/
deletes/moves through the port. **The third adapter, and the one the port was shaped for:** it
inherits `FileLayerWritableContract` from Share, which was that contract's entire purpose.

**Server suite 698 → 871, identical on all three backends** — `bin/rails test`,
`LIBRARY_BACKEND=share`, `LIBRARY_BACKEND=s3`, each **871 runs, 2567 assertions, 0 failures,
0 errors, 5 skips**. (870/2564 until the real-bucket run below added the test pinning FakeS3's
copy-source decoder.) The s3 leg is new in `ci.yml` (`test-s3-backend`, self-hosted, **no external
service**): `test/support/fake_s3.rb` is a real `Aws::S3::Client` with stub lambdas, real error
classes, and real pagination at 2 keys/page.

**The real-bucket run happened (2026-07-17, SeaweedFS 4.39 on a local scratch instance)** — the
DoD's requirement, and the first time any of this met a store instead of a hand-written fake. Its
purpose was adversarial: `FakeS3` had already hidden one silent data-loss bug by being the exact
inverse of the code's misunderstanding, so the question was where else the two disagree.

**No fault was found in the adapter or the observer.** Confirmed by observation: `copy_object`
stamps a **new** `Last-Modified` (the trash-retention window's premise); the ETag arrives
**quoted** in put/head/list and the SDK does not strip it (so `ObjectIdentity`'s single strip
point is load-bearing, and `MD5_ETAG` does not match the raw 34-char form); `copy_source_if_match`
**is honored** (mismatch → `PreconditionFailed`); a multipart ETag really carries `-N`, takes
rung 3 and fires the warn; the real page size is **1000** and the observer saw all **1050** of a
>1000-object bucket; **head and list agree exactly**, so a written file does not churn and the
scan is idempotent; and the **headline E2E passes on a real store** — an out-of-band
reorganization through the S3 API, and the attachment still resolves with its `node_id` intact.
Delete → `.trash` → undelete round-trips, a deleted-today entry **survives** a 30-day window, and
an expired one is really purged.

**The one real divergence was in the fake**, on the same bug's home turf: `do_copy` decoded with
`CGI.unescape` (form decoding, `+` = space) where a real store percent-decodes (`+` = literal
plus — verified: SeaweedFS answers `InvalidArgument`). The adapter has been correct since the
`url_encode` fix, so this was the **missing regression guard**, not a live bug: reverting the
adapter to `CGI.escape` still passed against the fake. Fixed, and pinned by a mutation-checked
test of the fake itself. **The lesson is the phase's own, restated:** a round-trip through a
double proves only that the double and the code agree — assert the **wire**.

**Still unverified:** `copy_object`'s 5GB cap and its error class (cannot stage 5GB; the SDK mints
error classes via `const_missing`, so "the class exists" is not a check); **R2/MinIO/Ceph**
specifics — only SeaweedFS was exercised, and AWS may well be *stricter* where SeaweedFS is
lenient (it collapses `a//b`, refuses `./..` keys, has no checksum API, and returns
`copy_object_result.etag` unquoted where AWS quotes it — none of which production reads today).

**The Phase 3 trap is disarmed.** Both gates — `ScanJob.scan_all!` and `TrashPurgeJob.purge_all!`
— were `is_a?(FileLayer::Share)`, which would have answered **false** for the new adapter and
silently no-opped: the library never indexed, the purge simply stopped. They now key on a new
**`scannable`** capability, asking one question: *does this backend's catalog come from polling
the store?* Chunk **false** (its tree is the changelog — nothing to scan, nothing that changes
behind our back); share/s3 **true**.

**`scannable` is neither of the two things it looks like**, and both near-misses matter:
- **Not `!syncable?`.** They are equal today by *coincidence of having exactly three backends*.
  A notification-driven backend (S3 event notifications, a webhook) answers **false to both** —
  and a derived `scannable` would poll it every 15 minutes forever. Two questions that share an
  answer today are still two questions. **A coincidence was encoded once already** (`is_a?(Share)`)
  and silently became wrong the moment the second backend arrived; that is the whole reason this
  capability exists.
- **Not Phase 4's `port_writable`** — and this near-miss is the harder of the two, because the
  two capabilities **agree on every backend we have** (chunk false/false, share and s3 true/true).
  There is no observation to point at, so the distinction must be argued: `scannable` asks where
  the **catalog** comes from, `port_writable` asks which door **bytes** go in. The same
  notification-driven backend that splits `scannable` from `!syncable?` above splits this one too
  — push-notified (so `scannable` false) while its uploads still go through the port.
  *(This bullet originally read "chunk answers **true** there and **false** here — opposite
  answers for one backend is the proof". Both halves were false: chunk is `port_writable: false`,
  the two never disagree, and the `true` reading is the "accepts uploads" misreading Phase 4
  rejects. Corrected 2026-07-17 — the argument, not just the values.)*

### The identity ladder — an S3 object has no free content hash

The port asks **two different questions** of one value, and conflating them is a data-loss bug:
`content_token` need only be an opaque content-**state** token (an ETag is one), but
`content_hash` must be content-**determined** for move-pairing — and **a multipart ETag is not**
(same bytes, different part size, different ETag). So one namespaced value, a strength ladder:

| rung | value | content-determined? | cost |
|---|---|---|---|
| 1 | `sha256:<b64>` | yes — **FULL_OBJECT only** | a HEAD per object |
| 2 | `md5:<hex>` | yes — a single-part ETag **is** the md5 | free (in the listing) |
| 3 | `etag:<raw>` | **no** — moves degrade to delete+create | free |

A **COMPOSITE** sha256 is a checksum-of-checksums — the same defect as a multipart ETag wearing a
better name — so rung 1 requires the *type*, not the checksum alone. Rung 2 is **32 hex**, not
merely "dash-free": this backend points at S3-*compatible* stores (SeaweedFS/MinIO/Ceph) free to
emit any shape, and calling an unknown string `md5:` is the lie the namespacing exists to prevent.
Rung 3's failure direction is the safe one — a **missed** rename, never a **wrong** pairing (a
false positive would fuse two files into one identity and swap their attachments).

**The ladder is TOTAL by construction — it never returns nil — and that is the guard, not
tidiness.** `Reconciler#plan_moves` **drops** a nil-hash observation from `candidates`, and
candidates is what becomes the leftovers that get indexed. A nil hash means **the object is never
indexed at all**: no error, no log, no node. The Reconciler's comment reasons "the next pass
indexes it properly" — true for a share (a nil hash there is an EACCES blip) and **permanently
false** for S3. **Quotes come off in exactly one place**: S3 wraps every ETag in literal quotes in
list, head *and* put responses, so mixing the forms gives one object two identities → every object
reads as changed on every scan and move-pairing never pairs.

**Download-and-hash was rejected on the spec's own terms:** a full billed egress of the bucket to
index a library the user already has is precisely the cost the "point it at my existing storage"
on-ramp exists to avoid.

### `LIBRARY_S3_HEAD_FOR_CHECKSUM` is NOT implemented — and the plan's cost model was unachievable

The plan priced it at "one HEAD per object on every **first sight**". **That layer cannot deliver
it: an observer does not know which objects are new — the Reconciler does.** So a HEAD there is
per-object-per-**scan**: on a 2M-object bucket, **2M billed requests every 15 minutes**, not 2M
once. Costing an operator that under a flag advertised as costing 2M once is worse than not
offering the flag. **Consequence: the `sha256:` rung is unreachable from any production path
today** — `list_objects_v2` returns `checksum_type` but never the checksum *value*, and `write`
uses put_object's ETag. **Do not document the env var as working.**

### Landmine 3 — the tombstone goes after the DELETE, not just after the copy

Spec §6 says *"tombstone only after the copy confirms"*. **Correct and not sufficient**, and the
gap is only visible read against 2b's storage_path-nulling — a landmine settled in a *different
phase*:

- `copy → TOMBSTONE → delete`, **delete fails**: the object is still live at its key, but the node
  is tombstoned with `storage_path` NULL, so the next scan observes the key, finds no live node
  claiming it, and **cannot revive by path**. It mints a **new `node_id`** → **every attachment
  orphaned**, by a scan that did nothing wrong, with no error anywhere.
- `copy → delete → TOMBSTONE`, **delete fails**: no tombstone, node live, path matches, next scan
  is a no-op. The user retries. **Consistent.**

Proven end-to-end with a real attachment. `undelete` is the same landmine wearing another hat:
copy → revive → sweep the trash copy **best-effort, last**.

### The `CGI.escape` bug — the phase's sharpest find, and it is a lesson about testing

aws-sdk-s3 does **not** escape `copy_source` (verified by capturing `x-amz-copy-source` at the
`:sign` step). `CGI.escape` is the obvious reach and is **form** encoding, so
`"Bracket v2.stl"` → `"Bracket+v2.stl"`, and real S3 decodes per RFC 3986 where `+` is a **literal
plus**. In `delete` the user never sees an error: **the copy reads a nonexistent key, the delete
removes the right one, the tombstone follows** → the file is permanently gone with someone else's
bytes in its trash slot. A space in a filename is the most ordinary thing in a CAD library.

**`FakeS3` hid it by being the exact inverse** (`CGI.unescape`) — `CGI.escape`/`unescape` are
inverses, so the wrong encoder was **green across 79/80 tests** and broken against every real
store. Fixed with per-segment `ERB::Util.url_encode`, and asserted **at the wire** rather than
through the fake.

> **A hermetic fake built from the same misunderstanding as the code confirms the
> misunderstanding.** Assert the WIRE format, not the round-trip. Watch for this shape wherever a
> fake and the code under test share an assumption.

### The other decisions worth not undoing

- **S3 is the one backend where `presignable` is TRUE and `versioned` is FALSE**, and that
  combination is the point. Every other backend has the two agreeing (chunk true/true, share
  false/false), so a reader could infer they co-vary — S3 is the counterexample. **§15 (bytes out
  of Rails) SURVIVES here** (a bucket has a URL signer, exactly what a mounted directory lacks;
  Phase 4's `Redirect` is built on it) **while §5 (keep versions) does not**.
- **The boot guard does no network.** A boot that depends on a third party being up turns a blip
  into a crash loop. Config *presence* is what boot can honestly check; credential *validity*
  surfaces on first use as a retryable `FetchError`.
- **`key_for` rejects, never normalizes.** `expand_path` would turn `a/../b` into a *valid* key
  and silently read the wrong object. Not theoretical: we sign **path-style** URLs, so a `..`
  segment lands in the URL path and any normalizing proxy resolves it out of our bucket.
- **`write` has no temp-and-rename, and its ABSENCE is the thing to read carefully** — someone who
  knows `Share#write` will see a missing step and "restore" it. Share renames because a
  half-written file is *visible* the whole time it is written; **put_object is atomic**, so there
  is nothing to protect against, and a temp key would only add a second unobservable ghost.
  Clobber is **refused** (every backend here is current-state-only → a clobber is the user's file
  permanently gone from a name collision in an upload form) — but it is a `head`-then-`put`
  **check, not a lock**: TOCTOU, and S3 has no portable conditional put. It stops the ordinary
  case; it does not claim atomicity. **`put_object`'s response carries no `last_modified`**
  (verified) → **two billed HEADs per write**, stated rather than hidden.
- **Both `delete` and `move` refuse directories**, diverging from Share, which allows dir *moves*.
  Share's permission rests **entirely** on `rename()` being one atomic syscall that carries the
  bytes, leaving the children observable at the new path for the scan to re-home. Here there is
  **no directory and no rename**: a dir node's key does not exist, so unguarded the copy 404s → a
  `FetchError` telling the user to retry, forever, an operation that can never succeed. A cascade
  is N copies + N deletes with no atomicity and no undo for a half-finished one. **One fact, both
  verbs** — where Share needed two arguments to reach two different answers. A real capability
  regression against Share for `move`, and the honest one: we decline to *originate* it, not to
  survive it (a user renaming a folder in their own console is paired back by the observer).
- **The Reconciler is the reusable half; the Scanner is not.** The spec (§9.3) says Phase 3
  "reuses the scanner" — **it cannot**: a `Dir.children`/`lstat`/symlink walk is irreducibly
  filesystem-shaped. `Library::S3Observer` is its own observer over `list_objects_v2`, feeding the
  *same* (deliberately filesystem-free) Reconciler — which is what matters, because **every one of
  2a's bugs lived in the logic a second copy would have duplicated**.
- **Landmine 4 — a partial listing is indistinguishable from a mass deletion.** `list_objects_v2`
  paginates, and a failure on page 7 of 40 is a **well-formed lie** that looks exactly like the
  user deleting 82% of their library. It is **2a's `Pathname#find`/`EACCES` bug with a different
  spelling**, minus the escape hatch: `unreadable_dirs` scopes a gap to a *subtree*, and a page
  boundary is an arbitrary key range that scopes to nothing. **Complete-or-abort is the only
  honest answer** (`Scanner::UnsafeScan`).
- **Landmine 6 — dir-marker objects** (`cad/`, minted by the S3 console) would become a phantom
  *file* node beside the real dir node. And **`valid_encoding?` does NOT transfer from the
  Scanner**: it asks about the string's **tag**, and an ASCII-8BIT string is *always* valid
  (verified), so the naive port waves a `\xFF` key straight into `storage_path`.

### What is NOT verified — no real-bucket run happened

**Everything above is hermetic.** The DoD requires a real-bucket run; it has not been done. Still
unverified against a live store:

- `copy_object`'s **5GB cap and its error class**. The SDK mints error classes via
  `const_missing`, so `Aws::S3::Errors::TotallyMadeUpNonsenseError` resolves as readily as a real
  one — **"the class exists" is not a check**, the assertion is unfalsifiable. Hence the guard
  depends on **no name** and refuses from `node.size` instead, with the store's own refusal as a
  backstop landing in the same safe place (ServiceError → FetchError → **nothing tombstoned**).
- `copy_source_if_match` being honored, and quoted-vs-bare If-Match.
- Whether SeaweedFS/MinIO/R2 paginate as modeled.
- Real-world non-UTF-8 key frequency.

**Next: Phase 4 = capability gating + `Delivery`.** `download` is Phase 4 — share-mode `blob`
still 404s **by scope** (it resolves `node.current_version`, which a share/s3 node has no such
thing as). Phase 4 adds **`port_writable`**.
*(Superseded 2026-07-17 — **Phase 4 is DONE**: `download` answers a `Delivery`, share-mode `blob`
serves bytes, and `port_writable` exists. This paragraph is a snapshot of phase 3; see the top of
this file.)*

## 2026-07-16: the Reconciler scales, and its own comment was the problem

Both limitations 2a and 2b carried as "fix before a real 2TB NAS" are closed. They were fixed
**before Phase 3 deliberately**: S3 is where someone actually points 2M objects at this, so the
limitation stops being theoretical exactly when that adapter lands.

| | before | after |
|---|---|---|
| 20k no-op scan | 0.159s, 552k objects | **0.061s, 311k** |
| 50k no-op, RSS | +67 MB | **+23 MB** |
| 10k renames | **9.0s** | **3.5s** |
| 50k renames | ~4 min (extrapolated) | **18.6s** |

**The no-op scan is the common case** — every 15 minutes, forever, nothing changed — and it was
instantiating a live AR node per file to discover that. It now `pluck`s the four columns it
compares and materializes AR objects only in the two branches that *write*: zero of them in a
no-op scan. `best_pairing` buckets candidates by `[hash, size]` rather than scanning all of them
per vanished node.

**The lesson is the comment, not the code.** The old one read: *"O(n*m) by design: 10k renamed
files measures at ~2s of CPU, which is dwarfed by the hashing those same 10k files already
require. Not worth an index until that ceases to be true."* It was wrong twice — **10k measured
at 9s, 4.5x the claim** — and wrong in principle: hashing is **linear**, that scan was
**quadratic**, so "dwarfed by the hashing" had a crossover built into it, and the crossover is a
reorganization big enough to matter. A confident number nobody re-measured is why it survived
two phases. Both comments now carry measured figures.

**Behavior is byte-identical**, and that claim was attacked rather than asserted: two independent
seeded differential probes (100 seeds total, different op mixes — renames, edits, touch-only
rehashes, unreadable blips, kind collisions, pools of byte-identical files), each dumping every
node column *plus a log of which files were hashed*, digest-matched across before and after. The
read log mattered: the no-op skip is pure performance and leaves **no trace in the node table**,
so without it the probe would have been blind to half the change.

*Still inherent, documented:* an all-byte-identical bucket costs O(N) per probe. The
deterministic tie-break has to compare the old path against every identical candidate, and
removing it would trade the no-crash/no-lost-file guarantee for speed.

## 2026-07-16: phase 2b — the share library can now grow

Phase 2a made a NAS directory *readable*. **2b makes it writable**: `write`/`delete`/`move`/
`undelete` through the port, with a trash. **The write path is Share-only, and that is the
boundary, not a gap** — chunk-mode writes belong to the sync engine, so `Chunk` **refuses them
per-op, naming the real door each time**: `write` → `Sync::Commit`'s two-phase flow, `delete` →
**`Sync::SubtreeDelete.call`** (it cascades the tombstone to the subtree; `Sync::Mutation.apply,
op: "delete"` tombstones only the node given and orphans the descendants), `move` →
`Sync::Mutation.apply, op: "move"`. One *shared* refusal message is how an earlier draft told
delete/move callers to use `Sync::Commit`, which has neither path.

**Server suite 635 → 698, still identical on both backends** (`bin/rails test` and
`LIBRARY_BACKEND=share LIBRARY_PATH=$(mktemp -d) bin/rails test`). `FileLayerWritableContract`
(`test/services/file_layer/adapter_write_contract.rb`) is a **second** contract module beside the
read one: the read contract runs against *both* adapters, the write contract runs against `Share`
alone because `Chunk` doesn't implement it — and **S3 inherits it in Phase 3, which is its entire
purpose**. It has already earned its keep: it caught that Phase 3's plan was missing `write`'s
clobber guard.

**The structural finding — the most valuable thing 2b learned, and the root cause of BOTH
permanent wedges it found:** *the Scanner's skip-lists are also blind spots.* Wherever the app
moves bytes **into** a skipped region (`.trash`, `.maker-tmp-`) while leaving a live node pointing
at the old path, it creates ghosts the `Reconciler` **can never pair** — pairing needs an
*observation* as its partner, and a skipped path produces none. The tombstone then trips the
mass-deletion guard, **refusing that scan and every scan after it, permanently**. Both wedges were
reproduced:
- **The temp-file race:** a scan landing inside `write`'s `binwrite` window indexed the torn temp;
  the rename made it vanish; its hash could never pair. Fixed by `Scanner::TEMP_PREFIX`
  (`.maker-tmp-`, skipped **at any depth**; `.trash` is skipped root-anchored).
- **The directory delete:** it would strand the children's nodes at paths that no longer exist
  while their bytes sat in `.trash`. Hence `delete` **refuses directories**
  (`FileLayer::UnsupportedOperation` — a *client* condition; `NotImplementedError` is a
  `ScriptError` and means the deployment is mis-wired). The cheap cascade was tried and collapses
  both ways.

**The asymmetry is the point:** a **move** leaves the bytes *observable* at the new path, so
pairing rescues the children — which is why `move` **allows** directories and `delete` does not.
Opposite answers to what looks like the same question.

**And then the asymmetry itself was too confident.** "A move leaves the bytes observable" holds
only when the *destination* is observable — and `write`/`move` happily accepted `.trash` and
`.maker-tmp-x`, which are perfectly good leaf names. One ordinary upload named `.trash` wedged
the scan **and** turned `.trash` into a file, breaking **every delete in the library**,
permanently, unfixable by clearing the ghost. Found by the whole-branch review, after three
per-task reviews and the sentence above had each explained why it couldn't happen. Fixed by
`Share#observable!`. **The lesson is the meta one: every explanation of this bug class so far has
been the thing that hid the next instance of it.** Assume any path that writes is exposed until
checked.

**Decisions that must not be "simplified" away:**
- **THE TWO TOMBSTONE KINDS.** A **scan** tombstone **keeps** `storage_path` and is revivable by
  the scan's revive-by-path; a **trash** tombstone **NULLs** it (`deleted: true, storage_path:
  nil`) and is revivable only by `undelete`. Collapsing them hands a **new, unrelated file the
  trashed node's `node_id`** — and with it every attachment, BOM link and tag — while the old
  bytes wait in `.trash` for an undelete that then collides. Silent, and the likeliest future
  regression in this phase.
- **Trash layout `.trash/<node_id>/<name>`, keyed by `node_id`** — which is why two same-named
  deletes don't collide, and why `undelete` has one unambiguous place to look.
- **`undelete` is a FOURTH port verb**, diverging from spec §3.2's three. The spec's *"undelete is
  a move back"* is **precluded** by the Landmine 2 fix: `move` opens with `live_node!` (a tombstone
  isn't live) and resolves its source via `absolute_path` → `storage_path`, which is NULL — it
  would rename the library root.
- **Order, both ways:** `delete` is **move-then-tombstone** (the reverse fails *silently* — the
  next scan resurrects it); `undelete` is **move-then-revive**. `EXDEV` → `FetchError`, **never** a
  copy+delete fallback.
- **An unmounted share must never read as "your file is permanently gone":** `undelete` raises
  `FetchError`, not `NotFound`, when the library looks unmounted (`NotFound` is terminal).
- **`LIBRARY_TRASH_DAYS`** (default **30**; **`0` = keep forever, NOT purge everything** —
  `0.days.ago` is *now*, so the obvious implementation deletes the lot; the guard runs first).
  `TrashPurgeJob` purges by **entry-dir mtime**, **never** touches the row, and **empties `.trash`
  but never removes `.trash` itself** (an empty root reads as unmounted → would flip `undelete`'s
  `NotFound` to `FetchError`).
- **The boot guard touch-probes.** **`File.writable?` is not the check** — it tests POSIX mode bits
  rather than effective access, and is wrong under exactly the NFS/SMB ACLs this backend targets.
  The probe is named with `TEMP_PREFIX` so a leak can't be indexed. The initializer had to move to
  **`after_initialize`**: app constants aren't autoloadable while initializers run, so the naive
  version raised `uninitialized constant Library` and **took the boot down while every test stayed
  green** — the test env skips the initializer, so no test can catch it.
- **`Share#write`** stamps the node's mtime from **the file's own stat**, not the clock — the scan
  compares against it.

~~*Open, carried from 2a:* `Reconciler` loads every live node into memory; `best_pairing` is
O(n*m) (~2s/10k renames).~~ **Both FIXED 2026-07-16** — see the section at the top of this file.
The "~2s" was measured at **9s**.

~~**Still deferred:** Phase 3 = S3 (inherits the write contract). Phase 4 = capability gating +
`Delivery`.~~ **BOTH DONE** (2026-07-17) — see the top of this file; the split is complete.
`port_writable` landed with the definition this paragraph already gave it: *which upload flow the
UI drives*, **NOT** "accepts uploads" — chunk mode accepts uploads fine, via `Sync::Commit`, and
getting that wrong would hide upload in chunk mode. **Phase 3 trap, now in two places:** the
`is_a?(FileLayer::Share)` gate in `ScanJob.scan_all!` *and* `TrashPurgeJob.purge_all!` quietly
answers false the moment `FileLayer::S3` exists — the purge silently stops.
*(Superseded 2026-07-17 — the trap was real and is **disarmed**: both gates now key on the
`scannable` capability. This paragraph is a snapshot of 2b; see the top of this file.)*

## 2026-07-16: phase 2a — point it at a NAS and the attachments survive

`LIBRARY_BACKEND=share` + `LIBRARY_PATH=/mnt/nas/models` now **boots, indexes an existing
directory, and serves it to the maker layer** (browse via the synthesized dir tree, attach,
preview from real bytes on real disk). The headline promise holds end-to-end: **a user
reorganizing their NAS in Finder keeps every project attachment**, because `Library::Reconciler`
pairs a vanished path with its new one by `(content_hash, size)` and the node keeps its
`node_id`. Share libraries are **current-state only** — no versions, no history, no restore
(a Finder overwrite destroys the old bytes; that departure from §5 is deliberate and scoped to
storage we don't own). `download` is Phase 4.
*(Superseded 2026-07-17 — Phase 4 landed `download`; a share-backed file now downloads through
the web UI. See the top of this file.)*

**Server suite 523 → 635, green on BOTH backends** (`bin/rails test` and
`LIBRARY_BACKEND=share LIBRARY_PATH=$(mktemp -d) bin/rails test` are identical). The shared
adapter contract runs against `Chunk` *and* `Share` in the default suite — that, not the
`test-share-backend` CI leg, is what stops the adapters diverging; the leg catches tests that
silently depend on the ambient backend (it found 9 immediately).

**What execution actually cost, and why it's worth recording:** the plan was detailed and
precise, which made implementing it literally the main risk. Every task carried a real defect,
and the worst were *cross-task* and invisible to per-task review:
- The mass-deletion guard as designed counted a **rename as a deletion**, so it would have
  refused the phase's own headline scenario (Task 10's E2E would have died on `UnsafeScan`).
- The `nodes` unique index and the reconciler collided: a **deleted-then-restored file crashed
  the whole scan**. Fixed with a partial index (`WHERE deleted = false`) + tombstone-revive.
- `Pathname#find` **silently swallows `EACCES`**, so an unreadable folder was already
  tombstoning its entire subtree — data loss that shipped through two reviews and only
  surfaced when the guard was wired to `unreadable_dirs`.
- A filename that isn't valid UTF-8 (routine on a NAS with old Windows clients) **bricked
  every subsequent scan** — caught only by the final whole-branch review, because macOS
  cannot even create the fixture and the CI leg scans an empty tmpdir.

*Open, non-correctness, commented in-code:* `Reconciler` loads every live node into memory
(~1M AR objects) — **fix before a real 2TB NAS**; `best_pairing` is O(n²) (~2s/10k renames).
*(Superseded 2026-07-16 — both fixed; see the top of this file. The "~2s" measured at 9s.)*

## 2026-07-14: full-stack audit + the maker/file layer split begins

**1. A full-stack audit (server + all Rust crates) found 7 criticals + ~20 majors — all fixed,
merged (`217b5aa`), pushed.** Each with a regression test. The ones worth remembering:
- **A pull silently destroyed an unpushed local edit with no conflict recorded** —
  `apply_remote`'s pending-outbox guard only protected *other* nodes squatting the name, so an
  inbound upsert clobbered a node's own dirty manifest *and its base version*, making the later
  push a clean fast-forward. Reachable on a **single device** via an own-echo race during a slow
  upload. Fixed with `ApplyOutcome::dirty_local` + engine-side defer.
- **`pull_snapshot` never swept**, so a device that full-resynced kept every server-deleted file
  as a ghost that could **resurrect** on edit. The fault harness modeled a sweep the real code
  never did — the soak's "0 silent losses" validated the model, not production.
- **A bandwidth cap below ~4 MB/s livelocked the sync thread forever** (a chunk larger than the
  token bucket's burst can never be satisfied) and hung `Daemon::stop()`.
- **CfAPI: a remote folder rename deleted the folder's contents library-wide** (echo guard marked
  the dir but not the children its own `remove_dir_all` touched).
- **The desktop app kept the device token *and unpushed offline edits* in the OS temp dir**
  (tmpfs on Linux; macOS purges `$TMPDIR`), token world-readable.
- Server: client-supplied chunk hashes were unvalidated before becoming storage keys; `move` had
  no cycle guard (one call wedged every subsequent search); tiered retention could prune versions
  still referenced by **unresolved conflicts**.
- **verify-on-finalize is now ON by default** (`SYNC_VERIFY_FINALIZE=0` to opt out). The
  `SharedDirIO` engine suites opt out — that transport is the seam their fault tests wrap;
  `two_device_e2e` moved to `PresignedIO` and now exercises verify for real.

**2. The maker/file layer split — Phase 1 done, deployed, verified live.** See `CLAUDE.md` §12
step 10 for the full picture, the settled decisions, and the two deliberate invariant departures.
- `FileLayer` port + `Chunk` adapter + a shared adapter contract; `Maker::FileBytes` reduced from
  79 lines reaching into `version.manifest_chunks`/`ChunkStore` to a **19-line shim**. The maker
  layer no longer knows files are chunks — proven by grep, not by tests.
- Merged `f04ef61`, deployed to `192.168.1.95`, and verified with a **live 40k-byte presigned
  round-trip through SeaweedFS** (Mac → presigned PUT → SeaweedFS → presigned GET → fresh device,
  byte-for-byte). That run was also verify-on-finalize's first live exercise against real S3.
- **Next:** `docs/superpowers/plans/2026-07-14-file-layer-share-phase2a.md` (read-only
  share-backed library). `LIBRARY_BACKEND=share` currently raises `NotImplementedError` by design.
  *(Superseded 2026-07-16 — phase 2a is done and share now boots; see the top of this file.)*
- **A caution worth carrying:** the Phase 1 final reviewer proved by *mutation* that the branch
  had removed the only guard on multi-chunk ordered assembly — flipping `.order(:seq)` to
  `.order(seq: :desc)`, which corrupts every file over one chunk, passed the whole 522-test suite.
  A bigger suite is not a stronger one. Restored and re-proven.

**3. Infra:** SeaweedFS moved to **192.168.1.8:8333** (`.7` is retired; port closed). It is a
**fresh instance with new S3 credentials** — 1Password item **`seaweednew`**, not `seaweedfs`.
Open question: whether `my-bucket` on `.8` carries the old chunks, or only new writes work.

## 2026-06-16, later: file-layer hardening + prod-like infra

A large file-layer wave merged on top of the morning's G2/G4/G5 batch (full detail + the action
items in `docs/HANDOFF.md` "File-layer hardening + prod-like infra wave"):
- **Correctness:** POSIX conformance (#24), **symlinks end-to-end** client (#25) + **server** (#26),
  **verify-on-hydrate** integrity (#28), **N-way conflict** resolution (#29), and **both
  documented-reds fixed** (rename-cycle + apply_remote cyclic-reparent, #33) → `fs-provider` 170/0,
  **0 ignored**. Server suite 393+/0.
- **Offline:** `make-available-offline`/`offline_readiness`/pin + `maker-offline` CLI (#30).
- **Conformance (#34):** data plane **byte-perfect** (fsx 25k + rclone, 0 diffs); `docs/conformance-status.md`.
- **Infra:** shared **ghcr** registry + a live **OVH prod-like box** (`15.204.216.249`, `kamal deploy -d ovh`)
  on R2 — **11.2× parallel hydration measured over real WAN** (`r2-migration.md` §5). Cross-OS Tauri
  **build CI** (#32, `docs/building-the-app.md`).
- **Plans for the next arcs:** `docs/plan-sharing.md` (#35) + `docs/plan-encryption.md` (#36);
  self-host options (#31). Ordering: auth → sharing → encryption.
- **⚠️ Rotate** the exposed R2 token + ghcr PAT (see HANDOFF security action).

## 2026-06-16: git-on-mount investigation + symlink MVP

**Verdict:** a `git` repo **works inside the mounted sync filesystem** for the everyday loop
(`init`/`add`/`commit`/`status`/`log`/`diff`/`branch`/`checkout`) — the model already supported
the hard parts (atomic `index.lock`→`index` rename, `O_EXCL` lockfiles, exec-bit). The one real
break was **symlinks** (the tree modeled only `File`/`Dir` → `EPERM`), now **fixed**.

- `fs-provider`: new `Kind::Symlink` + `nodes.symlink_target` BLOB; `Provider::symlink`/`readlink`
  (trait methods, default `NotSupported`, `SqliteProvider` overrides; forwarded through the
  `Arc<P>` blanket impl). `SyncNode.symlink_target` round-trips through
  `export_tree`/`sync_node`/`apply_remote` → symlinks **replicate device→device byte-identical**.
- `fs-fuse`: real `symlink`/`readlink` callbacks (was an `EPERM` stub) + `Kind::Symlink →
  FileType::Symlink`.
- Tests: `client/fs-provider/tests/git_on_mount.rs` (symlink CRUD + sync round-trip + git-critical-op
  guards) — all green on macOS. **Gold-standard real `git` vs a real FUSE mount** in Linux/Docker:
  `client/test-conformance/git-on-fuse.sh` (+ `git-on-fuse-docker.sh`).
- **Open follow-up:** end-to-end **server** sync of symlinks (the Rails server doesn't model a
  symlink-kind node yet, so `sync-engine` push *skips* `Kind::Symlink`; Provider + in-process
  replication work). **Hardlinks remain a documented non-goal** (git degrades to copy on
  `clone --local`). Full writeup: `docs/git-on-mount.md`.


## 2026-06-16: managed-deploy hardening (G2/G4) + file-layer polish (G5/G8/G10) + R2 live (HEAD `94b7f02`)

Three PRs landed on `main` on top of the cross-OS E2E state, plus R2 was validated end-to-end
against a real bucket.

- **G2 — managed-Postgres hardening** (PR #11): a **boot-time statement-pooler safety guard**
  (`lib/postgres_pooler_check.rb` + `config/initializers/postgres_pooler_check.rb`) that refuses
  to boot behind a statement-mode pooler (it would silently break the transaction-spanning
  `User#next_seq!` `FOR UPDATE` row lock and corrupt the changelog with duplicate seqs);
  `sslmode` defaulting in `config/database.yml` (`require` off-localhost, `prefer` local);
  Solid Queue/Cache/Cable roles documented for managed Postgres. **Real concurrency deadlock
  fix:** `next_seq!` is now the *first* statement in `Sync::Commit#finalize`/`Mutation#apply`/
  `Restore`/`Conflicts`, so two concurrent commits can't deadlock on a `FOR KEY SHARE`→`FOR
  UPDATE` lock upgrade (`test/services/sync/concurrent_seq_test.rb`). `docs/SYNC_SERVER.md` +
  `docs/parity-roadmap.md` updated by that PR (authoritative).
- **G4 — storage-orphan chunk reaper** (PR #10): `Sync::ChunkReaper` + `ChunkReaperJob` (weekly
  via `config/recurring.yml`) + `Storage::ChunkStore#list` + `lib/tasks/chunks.rake`. Sweeps
  chunk **bytes** left in object storage by commits that uploaded but never finalized — objects
  with **no DB row**, which the refcount-based `version_retention` sweep cannot see. Closes the
  abandoned-upload storage leak (matters for managed R2 cost; weekly cadence because
  `list_objects_v2` is billed per request, with a 24 h grace window protecting in-flight
  uploads). `docs/torn-writes-and-batching.md` §5 marked resolved by that PR (authoritative).
- **G5/G8/G10 — file-layer polish** (PR #12, in `fs-provider`/`fs-fuse`/`sync-engine`): an
  **opt-in (default-OFF) outbox debounce** for big CAD autosaves; a **special-file `EPERM`
  guardrail** (FIFO/socket/device nodes rejected cleanly); and a **delta-on-wire audit**.
- **R2 validated LIVE** (2026-06-15, docs in PR #9): the `Storage::S3ChunkStore` presign path
  was exercised end-to-end against a real R2 bucket (`maker-chunks-prod`, ENAM) — compatibility
  confirmed (`presigned_roundtrip` OK, chunk byte-for-byte in the bucket) and per-chunk hydrate
  latency measured (**~85–205 ms**, invisible in the local-first UX — metadata is local, hydrate
  is background/on-demand). See `docs/r2-migration.md` §5. A **parallel/pipelined chunk-hydration**
  optimization (concurrent `io.get`/`io.put` across a bounded pool, `hydrate_concurrency` default 8,
  ~8× on a synthetic-latency bench) is **merged (PR #15)**.
- **Next:** the maker app layer (Projects→Inventory→BOM→preview); then the parity roadmap
  (OAuth/OIDC → sharing → encryption-last). See `docs/HANDOFF.md`.

## 2026-06-15: automated cross-OS real-mount E2E + web UI MVP + real auth (HEAD `bab90bb`)

A large batch landed on `main`, and a deep cross-OS debugging arc got **automated real-mount A↔B
end-to-end green on all three OSes** (Linux FUSE, Windows CfAPI, macOS WebDAV) in `nightly.yml`.

- **Cross-OS real-mount E2E green (all 3):** the saga surfaced + fixed real on-hardware bugs:
  Windows CfAPI **3 receive-side bugs** (empty-dir enum `0x8007017C`; create-materialization
  parent-placeholders; delete/rename removal + echo-guard); Linux FUSE **`fuser` 0.14→0.17 upgrade**
  + the actual bug (`run_until_unmounted` used `umount_and_join()` which unmounts immediately in 0.17,
  vs `join()` wait-only). Long chain of eliminated red herrings (AppArmor, /dev/fuse, fusermount3,
  module, privilege) — `bindfs` held while ours didn't → proved it was our code. Regression smokes kept.
- **Real auth (Rails 8 built-in):** signup/confirm/login/reset + `Session` + OmniAuth seam; replaced
  the web UI placeholder; device-token/pairing untouched. Security review: 1 HIGH (OAuth email-link
  takeover) fixed; rest sound; brakeman 0.
- **Web UI MVP:** server-rendered file browser (upload via presigned PUT + `Sync::Commit`, download,
  inline view, soft-delete) + **trash/undelete**. Bytes stay off Rails.
- **Sync features:** **selective sync** (subtree subscriptions + hydration gate), **progressive/range
  hydration** (`hydrate_range`), **client bandwidth controls** (`ThrottledChunkIO`).
- **Hardening + research:** stress/concurrency (≤50 devices) + 15-filetype conformance (no corruption);
  **torn-write safety confirmed** (finalize is one transaction); `STORAGE_BACKEND=local` test backend;
  `image_processing`→2.0; `SecureRandom` pairing codes. New docs: `parity-roadmap.md`,
  `torn-writes-and-batching.md`, `r2-migration.md` (config-only R2 plan + latency harness).
- **Server 144/0.** Cross-machine `cross-os-e2e.yml` wired (gated on mac→shared-server reachability).
- **Next:** the maker app layer (Projects→Inventory→BOM→preview); then parity roadmap
  (OAuth/OIDC → sharing → encryption-last). See `docs/HANDOFF.md`.

## 2026-06-14: `auth-caching-security` merged to main + file layer hardened to "rock-solid"

The big `auth-caching-security` arc landed on **`main`** (squash PR #8), and a hardening batch
on top closed the remaining file-layer gaps. The headline: an adversarial fault-injection
harness was built and **found two real changelog ordering bugs**, both now fixed and verified.

- **Postgres validated** (CLAUDE.md §12 step 8): the adapter-agnostic server runs green on
  Postgres (Docker), 56/0; switch is config-only via `DATABASE_URL` (a `postgres` profile in
  `database.yml`). `next_seq!` row-lock exercised on PG. Caveats for a real managed deploy (TLS
  `sslmode`, **session/transaction** pooling not statement pooling for `FOR UPDATE`, concurrent-
  commit load test, Solid Queue/Cache/Cable still on SQLite) noted.
- **GC/retention wired** (closes an unbounded-storage bug): `Sync::RetentionPolicy`
  (`keep_all` self-host / `tiered` managed, current + `pinned` versions never pruned),
  `RetentionJob` (nightly via `config/recurring.yml`), and the actual S3 `delete_object` in
  `sweep_orphans!` (row destroyed first, then best-effort idempotent storage delete).
- **CfAPI B6 polish**: pin/unpin ↔ hydrate/dehydrate, `CfUnregisterSyncRoot` remove-library
  lifecycle, streamed page-aligned `FETCH_DATA` (+cancel), O(1) ino→path index. Windows CI green.
  (pin/unpin + remove-library are code-complete; need interactive-Explorer verification.)
- **Two-device end-to-end suite** (`client/sync-engine/tests/two_device_e2e.rs`, 9 tests): the
  A→write→B→pull→edit→A→pull byte-for-byte roundtrip + nested-dir/delete/rename/dedup/restore/
  conflict/lock/offline — driving the same engine loop the Tauri app uses. Per-OS CI jobs
  (`e2e-linux`/`e2e-macos`/`e2e-windows`) green.
- **Adversarial fault-injection harness** (`client/sync-engine/tests/fault_injection.rs`,
  "Trinity"): injected PUT/GET faults, mid-pull/push crashes, randomized interleaving, concurrent
  edits; asserts no-data-loss + convergence + idempotency, seeded + soak-validated 1000×200.
- **Two real bugs found + fixed** (merged `ce72f25`): (1) **outbox drained child-before-parent**
  on a move into a newer dir → pull abort → `outbox_list_topo()` topological drain.
  (2) **a pull could hard-delete a locally-renamed-but-unpushed node** (collision/recursive-delete
  sweep) → silent convergence loss → defer-and-retry parentless upserts + a sticky `needs_resync`
  that triggers the `pull_snapshot` reconcile floor. Soak: **0 silent losses** (373/1000 self-heal
  via the floor). All suites green (fs-provider, integration 19/0, two_device_e2e 9/0, harness 10/0).
- **UI polish** (`client/maker-app`): accessible loading/empty/error states, closable conflict
  modal, restore confirmation, pairing copy-to-clipboard, per-OS backend label (CfAPI default).
- **Loose ends cleared**: pairing codes now from **SecureRandom** (not `Array#sample`);
  `image_processing` 1.x→**2.0.2** (Dependabot #5); GC retention tests made **deterministic**
  (frozen clock; `sweep_orphans!` uses `updated_at <= cutoff` so grace:0 = sweep-now). Server
  suite **75/0**.
- **New strategy docs**: `docs/research-sync-competitors.md` (vs Dropbox/Drive/Nextcloud/oCIS/
  OpenCloud/Seafile/Syncthing + ranked gaps) and `docs/feature-set-and-workflows.md` (supported
  today / gap workflows, FILE-LAYER vs MAKER-APP).

**Open file-layer items (non-correctness, shape the product):** selective sync (research #2) and
at-rest chunk encryption (#3). Both fit the existing chunk/manifest/changelog model. Next big
arc: the **maker app layer** (projects/inventory/BOM/preview — §12 step 9).

## 2026-06-12: Windows CfAPI mount — read+write loop live, offline-capable

Building on the verified-live populate+hydrate (below), the CfAPI mount now runs the full
read **and** write loop on real Windows 11, and behaves correctly offline. Detailed handoff
+ remaining plan: **`docs/plan-windows-cfapi-migration.md`**.
- **Remote-change invalidation** live: a file edited on another device refreshes on next open
  (`CfUpdatePlaceholder` + `CfDehydratePlaceholder` via the engine `Invalidate` seam; updates
  the new size+mtime, then dehydrates so the next read re-fetches).
- **Phase 2 (edits)** live: a local edit to an existing file is captured via
  `NOTIFY_FILE_CLOSE_COMPLETION` + a content-compare self-write filter →
  `Provider::ingest_bytes` → the sync loop pushes it. (New files / deletes / renames = Phase 2b.)
- **Offline availability** (cross-platform): hydrated files persist on unmount (CfAPI Drop now
  only disconnects — no unregister/delete), and because the content-addressed chunk cache
  persists and the engine only fetches *missing* chunks, a hydrated file reads with **no
  network** on macOS/Windows/Linux. Test `hydrated_file_stays_readable_offline` (dead server +
  erroring transport → still reads from cache).
- **Stale-DB guard:** `Provider::bind_library(hash(server, token))` wipes a *different*
  library's stale tree/cursor on mount (keeps the chunk cache) — wired into **all four** mounts
  (FUSE/WebDAV/WinFsp/CfAPI). Fixes the reused-DB "cursor ahead of head_seq → remote edits never
  apply" + duplicate-placeholder bug. Tested (`bind_library_wipes_a_different_librarys_stale_state`).
- Three live-bring-up bugs fixed (each caught by the doctor/log workflow): on-demand population
  (empty-tree-at-mount + missing FETCH_PLACEHOLDERS → hang), always-answer FETCH_DATA, and a
  null-`FileIdentity` `from_raw_parts` panic on root enumeration. See the plan's "gotchas".

## 2026-06-12: Windows CfAPI mount — **verified live** (populate + hydrate)

The driverless CfAPI mount **runs on real Windows 11 hardware**: a sync root registers, Explorer
enumerates it, and files hydrate on open (no GPL driver — the §9 win, on actual hardware). Three
runtime bugs from the first live run, each caught by the doctor/log diagnostics and fixed:
- `populate()` ran at mount against the *empty* local tree + there was no FETCH_PLACEHOLDERS
  handler → enumeration hung. Switched to **on-demand population** (PARTIAL policy +
  FETCH_PLACEHOLDERS reading the provider's live tree) + a **pre-mount snapshot pull**.
- `FETCH_DATA` could return without answering → reading app hung. Now **always answers**
  (error completion on failure).
- `slice::from_raw_parts` on the root's **null FileIdentity** → UB panic on the callback thread.
  Added `callback_node_id` (null → root).
Diagnostics added: `eprintln` in both callbacks + a layered **`doctor` example** (control plane +
storage reachability, no CfAPI) that isolated the failure to the CfAPI layer. Still to exercise
live: remote-change invalidation + clean teardown. **Phase 2** = local-edit capture.

## 2026-06-12: Windows CfAPI migration — Phase 1 (driverless mount)

`client/fs-cfapi` — the **driverless** Windows mount (Cloud Filter API; no GPL WinFsp driver,
the OneDrive model: a registered sync-root folder with on-demand hydration + native Explorer
integration). **Phase 1** = the download/read half: register the root, **populate** every node
as a dehydrated placeholder from the local `Provider` tree, **hydrate** on the FETCH_DATA
callback (presigned GET → chunk cache → `CfExecuteOperation(TRANSFER_DATA)`), and **invalidate**
on a remote content change (`CfUpdatePlaceholder` + dehydrate). Wired as
`sync_engine::CfApiMount` + the `maker-cfsyncd` bin. **Now the DEFAULT Windows backend**
(flipped 2026-06-14): Phase 2b complete (new-file/delete/rename capture), **live smoke +
byte-for-byte conformance green** against the deployed server; WinFsp behind the
`winfsp-backend` feature.
- Reuses the Option-B seams directly: the engine's `Invalidate` trait → `CfUpdatePlaceholder`
  (an `EngineCfInvalidate` newtype bridges them), and real nanos mtime → `FILETIME`.
- New `Provider::ingest_bytes` (the Phase-2 local-edit primitive: re-ingest an edited on-disk
  file as a node's new version) — tested.
- Pure logic (`FileIdentity` node_id↔blob, nanos↔FILETIME, placeholder-action decision) is
  **unit-tested cross-platform** (6 tests, green on macOS/CI). The Windows FFI is authored on
  macOS (like `fs-winfsp` was), compiled by the new `cfapi-windows` CI job, **runtime-UNVERIFIED**
  — smoke steps in `client/fs-cfapi/BUILD.md`.
- **Phase 2** (next): capture local edits/creates/deletes (CfAPI doesn't route writes through
  us) via a USN-journal / `ReadDirectoryChangesW` watcher → `ingest_bytes` → push →
  `CfSetInSyncState`. Plan: `docs/plan-windows-cfapi-migration.md`.

## 2026-06-12: real-mtime preservation + active cache invalidation (Option B)

Replaces the `mtime = now`-on-pull freshness hack (which destroyed the true modification
time — breaking `make`/`ninja`/`cargo` incremental builds) by splitting mtime's two jobs:
**preserve the real mtime** end-to-end, and **invalidate the OS cache explicitly** on a
content-changing pull instead of relying on an mtime bump. Plan:
`docs/plan-real-mtime-and-invalidation.md`.

- `fs-provider`: `mtime` is now real, **unix nanoseconds** (build-tool resolution; maps to
  FILETIME/NSDate for the CfAPI/File-Provider future). `flush` stamps the real local mod
  time; `apply_remote` writes the **source device's** mtime verbatim (no more `now`), and
  returns an `ApplyOutcome { ino, content_changed }` so the adapter knows when to drop its
  cache. New `set_mtime` (the kernel's `utimensat`/`cp -p`). `SyncNode.mtime` round-trips
  through export/sync_node/apply.
- `fs-fuse`: `setattr(mtime)` → `set_mtime`; `file_attr` reports nanos.
- `sync-engine`: an `Invalidate` seam (cross-platform) the pull path calls when a pull
  repoints an existing inode at new content. `EngineInvalidate` (FUSE-only) holds the
  session `Notifier` and calls `notify_inval_inode` (abi-7-12); shared by the sync loop +
  freshness adapter (whichever applies the change first invalidates), wired into the
  `Daemon` via deferred notifier injection (the construction-cycle break). WebDAV/WinFsp
  pass `None` (lean on short metadata timeouts until CfAPI/File-Provider land — the same
  two primitives slot in here). `push_node`/converters carry mtime.
- Server: `nodes.mtime` + `pending_commits.mtime` as **bigint** (nanos in 2026 overflow a
  32-bit int); `Commit`/mkdir store it; tree + changes serialize it; controllers permit it.
- Tests: fs-provider (`pulled_node_keeps_the_source_mtime_not_now`,
  `apply_remote_reports_content_change_for_cache_invalidation`, updated
  `remote_update_serves_fresh_content_and_carries_real_mtime`), server (commit stores +
  tree/changes expose the bigint mtime), integration `real_mtime_propagates_across_devices`
  (A's 2001 mtime visible verbatim on B). External: rclone⇄WebDAV re-run clean.
  **Invalidation itself can't be unit-tested** (needs a live FUSE kernel) — verified by the
  Linux CI `mount-conformance` path / manual smoke (edit on A, `cat` on B before/after).

## 2026-06-12: file mode / executable-bit preservation

The one POSIX-fidelity gap that actually bites makers (scripts/binaries losing `+x` after
sync — see the conformance dig): file mode is now preserved end-to-end.
- `fs-provider`: `mode` column (+ ALTER) defaulted 0644/0755; `Attr.mode`; `set_mode`
  (chmod, enqueues sync); `getattr` reports it; `SyncNode.mode` round-trips through
  `apply_remote`/export/sync_node. Persists across reopen.
- `fs-fuse`: `file_attr.perm` from mode; `setattr(mode)` → chmod; `create` captures the
  create-time mode.
- Server: `nodes.mode` (+ `pending_commits.mode`); `Commit`/mkdir store it;
  tree + changes serialize it; commit/mkdir params permit it.
- Client: `CommitBegin.mode`, `mkdir(mode)`, `NodeView`/`TreeNode.mode`; `push_node` sends
  it, the converters read it.
- Tests: fs-provider (mode set/sync/reopen), server (commit stores + tree exposes),
  integration `executable_bit_propagates_across_devices` (chmod +x on A → 0755 on B).

This is mode *preservation*, not enforcement (ownership/uid-gid deliberately not synced —
meaningless across devices). **Symlinks are now supported** (see the git-on-mount section
below). Remaining POSIX gaps (hardlinks/special files, ctime/atime) are intentional
non-goals for a personal sync drive.

## 2026-06-12: best-effort cross-device lock

Layered on the local locks + conflict detection: a **best-effort advisory edit lock**
across devices. On open-for-write the client (when connected) acquires a server lock so
other *connected* clients see the file is being edited; if it can't reach the server the
open just proceeds on the local cached copy, and conflict detection reconciles on
reconnect. Advisory + TTL-based (a disconnected holder's lock auto-frees), never blocking.

- Server: `FileLock` (TTL) + `Sync::Locks` (acquire/refresh/release/status/active — never
  steals a live lock; expired locks reclaimable). `POST /v1/nodes/:id/lock` + `/unlock`,
  `GET /v1/locks`. 6 tests (`locks_test.rb`): grant, no-steal, holder-refresh, expiry
  reclaim, release-only-by-holder, active/status reflect expiry.
- Client: `ServerClient::lock`/`unlock`/`locks` (2s timeout so offline never hangs the
  open). `fs-fuse` gains a `RemoteLock` hook; `sync-engine::EngineRemoteLock` acquires on
  open-for-write / releases on close **in a background thread** (non-blocking). Wired into
  the Daemon. Integration test `best_effort_lock_coordinates_connected_devices` (live).
- App: the file browser shows a 🔒 + holder name for files locked on another device.

## 2026-06-12: file locking + conflict detection & resolution

Local-first concurrency = local advisory locks + cross-device conflict detection (NOT
distributed locks — can't hold a WAN lock offline; the synchronous model we rejected).

- **Local advisory locking** — `fs-provider::LockManager` (POSIX byte-range advisory
  locks, owner-tracked, conflict = different owners + overlapping range + ≥1 exclusive,
  released per owner on close; 7 unit tests). Provider trait gains
  `set_lock`/`test_lock`/`unlock`/`release_locks`; `fs-fuse` wires `setlk`/`getlk`/release.
  Non-blocking (F_SETLKW retry-wait is a TODO).
- **Conflict detection** — each commit now sends `base_version_id` (the client tracks the
  server version each node reflects: a new `version_id` column in `fs-provider`, populated
  on pull, advanced after a push, sent on the next commit). When the base is no longer
  current (a divergent offline edit), `Sync::Commit` records a **conflict** (keeps both
  versions, emits a `conflict` changelog op) instead of last-writer-wins dropping an edit.
- **Resolution** — `Sync::Conflicts`: keep one side current, or **split** (the incoming
  side becomes a new sibling "foo (conflict from <device> <when>).ext", reusing its
  manifest → zero new blocks). `GET /v1/conflicts` returns both sides with device + time +
  size; the app shows a resolution **popup** (keep this / keep that / keep both).
- Tests: server 41→47 (`conflicts_test.rb`), sync-engine integration +2
  (`offline_divergent_edit_raises_a_conflict`, `sequential_edits_fast_forward_without_a_conflict`),
  fs-provider +7 lock tests. The old LWW integration test is replaced (concurrent edits now
  conflict by design).

## 2026-06-12: auth, security, caching, freshness-on-access, file browser

Branch `auth-caching-security`. Areas:

### Freshness-on-access (the on-open catch-up pull)
A file open now does a quick, **throttled** changelog catch-up pull before serving, so an
open never returns a copy another device already changed — closing the window between
background sync ticks. `fs-fuse` gained a `Freshness` hook in `open`; `sync-engine`
`EngineFreshness` implements it as `pull_changes` throttled to ≥750 ms (the loop + nudge
keep us mostly current, so this only matters in the sub-tick gap), wired into the `Daemon`.
Red-green integration test `freshness_check_on_access_serves_latest_after_remote_change`:
RED = stale read before catch-up, GREEN = latest after. Versioning/restore design sketched
in `docs/versioning.md` (near-delta-per-version via CDC + dedup; restore reuses a manifest
for zero new blocks; retention/GC policy to bound growth).



### Auth + cross-user security (server 30→41 tests)
Audited the client↔sync-engine and ↔bucket-storage auth. **Cross-user isolation was
structurally sound** — presigned URLs are SigV4-signed for a per-user key
(`chunks/<user_id>/<hash>`, untamperable), chunk storage/metadata + dedup are per-user,
and every node mutation scopes through `current_user.nodes`. **The one real hole was the
bootstrap:** `register` did `find_or_create_by!(email)` and handed out a device token for
*any* email → account takeover. Fixes:
- `register` creates a **new account only** (409 on an existing email).
- Additional devices join via a **single-use, 10-min pairing code** issued by an
  authenticated device (`DevicePairing`; `POST /v1/devices/pairing` → `POST /v1/auth/pair`).
  SHA256-digested, atomic single-use claim, generic error (no account enumeration). The
  Syncthing/Plex model — secure multi-device without external OAuth (the later
  email-verification upgrade, §12.5).
- Defense in depth: `/v1/chunks/download` only mints URLs for chunks the requester owns.
- Client: `create_pairing()`/`pair()` on `ServerClient`; **maker-app persists the device
  token** (register/pair once, reuse) instead of re-registering each start.
- Tests: `auth_test.rb`, expanded `tenant_isolation_test.rb`, live pairing integration.

### Client caching / freshness (fs-provider 50→53)
- **`mtime` was permanently 0** — never written on commit or pull, so a same-size edit on
  another device was invisible (open a minute later → stale cached copy). `flush` and
  `apply_remote` now stamp `mtime = now` → readers re-read + re-hydrate the new manifest.
- **Random writes could miss** (write seeds from committed content; only `read` had a
  hydrate-retry). `fs-fuse`/`fs-winfsp` `open` now hydrate the whole file on write-intent.
  WebDAV (whole-file PUT/GET) is unaffected. Tests in `tests/caching.rs`.

### App: file browser + versioning
`sync-client::versions()`; maker-app `browse`/`file_versions`/`restore_version` commands;
frontend rebuilt — status pill, "this is my device" vs "pair with a code" tabs, an
"add a device" pairing-code panel, and a file tree that expands per-file version history
with one-click restore.

## 2026-06-11: external conformance suites

Added independent, battle-tested external tools pointed at our real mount surfaces — the
same suites JuiceFS/CephFS gate on — so robustness isn't only self-authored tests.
`client/test-conformance/` + a `mount-conformance` CI job (`rust-client.yml`):

- **`webdav-rclone.sh`** (gating, cross-platform) — drives `fs-webdav` with **rclone**:
  `copy` a tree in, `check --download` every file byte-for-byte, then modify/append/delete
  + `sync` + re-check. **Verified locally on macOS** (0 differences, initial 8 files +
  post-delta 7 files). Exercises read+write through chunking + the content store with an
  independent client.
- **`fsx-fuse.sh`** (gating, Linux) — **fsx** (xfstests) against `fs-fuse`: a long
  randomized write/read/**truncate** stream verified against an in-memory model — the
  strongest adversarial check of the data plane. CI-verified on first run (no FUSE on the
  macOS build host, same as fs-winfsp).
- **`pjdfstest-fuse.sh`** (informational, Linux) — **pjdfstest** POSIX semantics for the
  ops we implement (rename/unlink/mkdir/rmdir/truncate/open); perms/owner/link tests are
  out of scope, so it's a conformance *map*, not a gate (`continue-on-error`).

These cover the **mount**; distributed-sync convergence stays the job of the
`fs-provider/tests/convergence.rs` FakeFolder harness (no external suite exists for that).

## 2026-06-11: offline/reconnect hardening (§12.6)

Hardened the path real usage hits but the demos never did — a device going offline and
reconnecting far behind. Found and fixed a concrete data-loss bug.

- **Changelog pagination data-loss bug — FIXED.** `pull_changes` made a *single*
  `changes(cursor)` call then advanced the cursor to the global `head_seq` — so a device
  more than one server page (500) behind applied only the first page yet jumped its cursor
  past everything, **silently dropping every entry beyond page 1**. The exact
  offline-reconnect failure. `pull_changes` now **loops**, advancing the cursor to the
  *last applied entry's seq* each round until caught up. Regression-tested
  (`pull_changes_pages_through_a_backlog_without_dropping_entries`, forces multi-page via a
  small page size).
- **Full-resync backstop.** The changes endpoint now reports `oldest_seq` (the lowest
  retained changelog seq); `Sync::Gc.prune_changelog!(user, keep_after:)` is the retention
  op that moves it. If a client's cursor falls below the retained floor (`oldest_seq >
  cursor + 1`), the entries it needs were pruned, so `pull_changes` falls back to a full
  `pull_snapshot` instead of skipping the hole. Server contract tested in
  `test/services/sync/changes_test.rb` (pagination order/limit, oldest_seq floor, the
  pruned-gap signal, snapshot stays complete after a full prune).
- **Offline reconcile + hydrate-after-conflict verified.** New integration tests: a device
  that queues writes offline while another pushes converges on reconnect (push-then-pull),
  and `hydrate` correctly follows a manifest swapped in by a conflict pull (reads the
  winning version's bytes — the path the LWW test had sidestepped).

Tests: server 26→**30**, sync-engine integration 6→**9**. (~90 → ~94 total.)

## 2026-06-11: comprehensive foundation test suite

Paused feature work to harden the file-sync foundation with a real test suite, modeled on
how production sync/chunking systems test: **rclone `fstests`** (one contract suite over a
backend), **restic/borg chunker** (round-trip + boundary-stability properties),
**ownCloud/Nextcloud `FakeFolder`** (model-based multi-replica convergence), **JuiceFS
pjdfstest** (POSIX semantics), and **Dropbox**-style randomized state-machine checks.
Added `proptest` (dev-only) for property tests with shrinking.

**~90 tests, up from ~40.** Tiers:
- **fs-provider (hermetic, no server) — 50 tests** in `client/fs-provider/tests/`:
  `chunking` (round-trip for every size, dedup, **block-delta boundary stability** — a
  front-insert keeps ≥half the chunks, an append keeps all but the last, a 1-byte edit
  perturbs few; size bounds; zeros/repetitive/random), `posix_semantics` (rename-over
  replace, dup/missing errors, unicode/long names, deep nesting, re-create-after-delete),
  `convergence` (3-replica random-op FakeFolder harness asserting byte-identical trees
  every step; durability across reopen; idempotent re-apply; placeholder truncate),
  `concurrency` (shared-`Arc` threads + the chunk-store same-hash race).
- **sync-engine (server-backed) — 6 integration tests** in `tests/integration.rs`:
  roundtrip (real bytes), delete/move delta, **last-writer-wins**, hydrate-only-missing +
  idempotent, push dedup/idempotency, cursor monotonicity. Skips cleanly with no server;
  CI boots `STORAGE_BACKEND=memory` Rails and runs it (new `engine-integration` job).
- **Rails — 26 tests, up from 10:** added GC (`prune_version!` refcounts, `sweep_orphans!`
  grace/keep-live), restore (reuse manifest, bump refcounts, undelete, chain), tree
  pagination (cover-once, exclude-tombstoned, carry manifest), and tenant isolation
  (one user's token can't see/mutate another's tree/changes/nodes).

**Two foundation bugs the suite caught and fixed (both in `fs-provider`):**
1. **`rename` over an existing name** hit the unique `(parent, name)` index and errored
   instead of POSIX-replacing — so **atomic saves (write `f.tmp` → rename over `f`), how
   nearly every app saves, were broken on the mount.** Now replaces atomically and
   tombstones the displaced node (so the deletion propagates; no cross-device duplicate).
2. **`truncate(ino, 0)` read the base content first**, so an `O_TRUNC` overwrite of a
   pulled-but-unhydrated placeholder failed with `ChunkMissing` — a routine mount op.
   Truncate-to-empty now short-circuits without touching the (absent) bytes.

## 2026-06-11: §12.4 truncate gap closed

The `Provider` trait had **no truncate**, so overwriting a file with fewer bytes than
before left the old manifest's trailing chunks past the new EOF — reads returned a stale
tail / wrong size (CLAUDE.md §12.4, a gap shared by all three mount adapters).

- **`Provider::truncate(ino, size)`** (impl on `SqliteProvider`): if the file is open for
  write, it resizes the in-memory staging buffer in place (the eventual `flush` commits
  the new length); otherwise it seeds from committed content, resizes, and commits
  immediately so a bare `truncate(2)` (and its outbox entry) is durable with no following
  write. Shrink drops the tail; grow zero-fills. Mirrored on `impl Provider for Arc<P>`.
- **Wired through every OS's truncate signal:** FUSE **`setattr(size)`** (`fs-fuse`),
  WinFsp **`set_file_size`** *and* the **`overwrite` disposition** (CREATE_ALWAYS /
  FILE_OVERWRITE — the common Windows "save a smaller file" path; both call
  `Provider::truncate`, `fs-winfsp`), and a **truncating WebDAV PUT open** (`fs-webdav`
  now honors `options.truncate`). The kernel issues `setattr(size=0)` on an `O_TRUNC`
  open before the shorter `write`, so the save-a-smaller-file path is now correct on
  macOS, Linux, and Windows. Caveat: `fs-winfsp` is `#![cfg(windows)]`, so the Windows
  legs compile only under the `windows-mount` CI job — unverified on the macOS build host.
- **Tests:** `overwrite_with_shorter_leaves_no_stale_tail` (reproduces the §12.4 bug —
  2000 bytes → truncate → 100 bytes → reads exactly 100) plus a grow/shrink test. The
  `convergence_under_random_ops` harness now overwrites via **truncate-then-write** (small
  length ceiling → shrink is the common case) and asserts the source committed exactly the
  new bytes (no stale tail); replica content convergence stays proven by the
  content-addressed `manifest_id` in the snapshot. fs-provider is now **15 tests** green.
- **Re-verified:** `(cd client/sync-engine && cargo run --example roundtrip)` against
  `STORAGE_BACKEND=memory` on `localhost:3001` — real bytes A→cloud→B, byte-for-byte.

## 2026-06-11: Live deployment — full stack on an Unraid VM via Kamal

The Rails sync server is **deployed and verified** on an Ubuntu 26.04 Unraid VM
(`192.168.1.95`) via Kamal 2.11, all-on-one-box: Docker + a local htpasswd registry on
`127.0.0.1:5000`, image built in the host dockerd (`builder.driver: docker`), app behind
kamal-proxy on `:80`, Solid Cache/Queue/Cable on SQLite on a persistent volume. Chunk
storage is **SeaweedFS** (`STORAGE_BACKEND=s3`). Runbook: `docs/DEPLOY.md`.

**All three cross-stack demos pass against the deployed server** (`SERVER_URL=http://192.168.1.95`):
`e2e` (control plane), `nudge` (ActionCable `{head_seq}` via deployed Solid Cable through
kamal-proxy, ~130 ms), and `presigned_roundtrip` (real 40 KB file pushed to SeaweedFS via
presigned PUT, hydrated on a fresh device byte-for-byte). Two fixes were needed and are
committed: `config.solid_queue.connects_to` (Solid Queue was hitting the primary DB and
crash-looping Puma) and the single-host Kamal registry/builder config (127.0.0.1 + auth +
`driver: docker` to avoid the localhost reverse-tunnel + isolated-buildkit traps).

## 2026-06-11, evening: §12 step 3 — delete/move propagation

Closed the correctness hole where the **delta pull dropped deletes** (`pull_changes`
had a literal `NOTE: 'delete' tombstones are not yet applied locally`): a file deleted on
device A was never removed on device B, and a move duplicated the file at both the old and
new path.

- **`fs_provider::apply_remote_delete(node_id)`** — removes the node and its whole subtree
  via a recursive CTE (a dir delete can't orphan children even if per-child deletes arrive
  out of order or not at all), idempotent (no-op on an already-gone or never-seen id), and
  does **not** touch the outbox (inbound change must never echo back to the server).
- **`SyncEngine::pull_changes`** now routes a change to `apply_remote_delete` when
  `op == "delete"` **or** the (soft-deleted) node carries `deleted: true`; everything else
  flows through `apply_remote`. **Moves needed no new code** — the server models a move as
  op `move`/`put` on the **same** stable `node_id` with a new parent/name, and
  `commit_begin` already carries parent/name, so `apply_remote` updates the row in place.
- **Verified end-to-end vs the live server**: `client/sync-engine/examples/delete_move.rs`
  — A deletes `trash.txt` and moves `note.txt` Inbox→Archive, B converges via a changelog
  **delta pull** (seq 4→6): deleted file gone, moved file at the new path only, trees
  identical. Passed against `STORAGE_BACKEND=memory` on `localhost:3001`.
- **Convergence harness** (`fs-provider` test `convergence_under_random_ops`): drives a
  deterministic pseudo-random stream of create/overwrite/delete/move ops on a source
  provider, replicates each step's outbox to a replica exactly as the daemon's pull does,
  and asserts the two trees stay byte-identical after **every** op. This is the mechanical
  backstop CLAUDE.md called for — it would have caught the dropped-delete/duplicated-move
  bugs. fs-provider is now **13 tests** green (15 after the truncate fix above).

## 2026-06-11, afternoon: §12 steps 1 & 2 landed

- **Continuous sync loop wired.** `fs-provider` gained an `outbox` + `sync_state`
  (cursor) table; FUSE mutations (`flush`/`mkdir`/`unlink`/`rmdir`/`rename`) enqueue the
  dirty `node_id` atomically with the tree change. `sync-engine` gained
  `push_outbox` (incremental, drains the outbox without holding the SQLite lock across
  WAN I/O), `sync_tick` (the loop body = push_outbox + pull_changes), and
  `EngineHydrator`. `fs-fuse` gained a `Hydrate` hook: a `read` on a chunk-cache miss
  hydrates + retries. Proven end-to-end vs the live server in
  `client/sync-engine/examples/daemon_loop.rs`.
- **`maker-syncd` binary** (`client/sync-engine/src/bin/`) mounts FUSE and runs the loop
  in a background thread sharing one `Arc<SqliteProvider>` (`impl Provider for Arc<P>`).
  Compiles + supervises the thread cleanly; the live kernel mount needs an interactive
  session (FUSE-T won't hold a mount from a detached process — same limitation as the
  existing `maker-mount`; verify in Finder).
- **Live SeaweedFS round-trip DONE.** Real bytes through presigned PUT/GET to
  `192.168.1.7:8333` (bucket `my-bucket`), byte-for-byte on a fresh device —
  `client/sync-engine/examples/presigned_roundtrip.rs` against the `STORAGE_BACKEND=s3`
  server. Presigning worked first try.
- **Bonus fix:** `LocalChunkStore::put` used a fixed temp filename → concurrent writers
  of the same chunk hash raced on the rename (loser hit ENOENT). Now uses a unique temp
  name + treats a lost race as the dedup win. Load-bearing once the daemon writes the
  store from multiple threads.
- **ActionCable nudge wired.** `ServerClient::watch_library` (blocking tungstenite WS)
  subscribes to `LibraryChannel`; the daemon runs it on its own thread and feeds an mpsc
  channel the sync loop waits on via `recv_timeout(poll)` — so a `{head_seq}` broadcast
  wakes the loop in ~39 ms while the 2 s poll stays as the correctness fallback. Verified
  in `client/sync-client/examples/nudge.rs`. Required `disable_request_forgery_protection`
  for ActionCable (a browser-CSRF defense; our cable auth is a query-string device token,
  not cookies, so it doesn't apply and would 404 the native client).
- **Supervised daemon + Tauri app.** `sync_engine::Daemon` (`src/daemon.rs`) mounts via
  `spawn_mount2` (non-blocking) and supervises the sync + nudge threads on one shared
  `Arc<SqliteProvider>`; `start`/`stop`/`is_running`/`run_until_unmounted`. `maker-syncd`
  is now a thin wrapper. `client/maker-app` (Tauri) drives it via `sync_start`/`sync_stop`/
  `sync_status` with a mount form — see `client/maker-app/SETUP.md`. The native-mount dep
  is `cfg(not(windows))`-gated (FUSE is Unix-only): the app builds + launches on Windows
  with the mount disabled until the winfsp-rs adapter (step 4).
- **Step 1 is functionally complete** (watch→push, nudge/poll→pull, read→hydrate,
  supervised, GUI-driven). The only unverified leg is the live kernel mount, which needs
  an interactive desktop session (FUSE-T won't hold a mount headless).
- **Windows mount adapter started (§12 step 4).** New `client/fs-winfsp` implements
  WinFsp's `FileSystemContext` over the same `Provider` (+ a `maker-mount-win` binary),
  written against winfsp 0.13. It is **unverified** — the build box is macOS, where
  `winfsp` can't compile; the non-Windows path is an inert empty crate (confirmed). A
  `winfsp-windows` CI job (`.github/workflows/rust-client.yml`) compiles it on Windows —
  that's the verification gate. See `client/fs-winfsp/BUILD.md`. Once it builds + mounts
  via `maker-mount-win`, wiring it into the `Daemon`/Tauri app is a small follow-up.

---

**Original overnight build:**

The local-first sync architecture (`docs/architecture-sync-engine.md` +
`docs/sync-protocol.md`) is now real, working code across all three tiers, with the
**multi-device convergence path verified end-to-end** (Rust client ⇄ live Rails
server). Below: what exists, what's proven, how to run it, what's next.

## What's built & verified

| Component | Path | State |
|---|---|---|
| **Local FS core** | `client/fs-provider` | ✅ SQLite tree + content-addressed FastCDC chunk store. 5 tests. |
| **FUSE mount** | `client/fs-fuse` | ✅ Mounts via FUSE-T; **verified in Finder**; persists across remount. |
| **Sync server** | Rails app (`app/`, `db/`) | ✅ Full protocol. 10 tests green on SQLite. |
| **Sync client** | `client/sync-client` | ✅ Typed API + chunk transfer + pull-apply. 5 tests. |
| **Sync daemon** | `client/sync-engine` | ✅ push / pull / hydrate / sync_once; pluggable `ChunkIO` (shared-dir + presigned). |
| **End-to-end** | `examples/e2e`, `multi_device`, `roundtrip` | ✅ **Run live against the Rails server, incl. real chunk bytes.** |
| **S3/SeaweedFS storage** | server `STORAGE_BACKEND=s3` | ✅ Wired (`aws-sdk-s3`); presign verified against the SeaweedFS creds. Not round-tripped live (SeaweedFS unreachable from build env). |

### Proven end-to-end (Rust client → live Rails server)
- **Single device** (`e2e`): register → mkdir → commit(begin/finalize) → changes →
  tree → restore.
- **Multi-device** (`multi_device`): device A builds a tree; device B (second device,
  same user) initial-syncs via the snapshot, then **converges on A's delete via a
  delta pull**.
- **Full daemon roundtrip with real bytes** (`roundtrip`): device A creates a 40 KB
  file → `SyncEngine::push` chunks it + uploads to a cloud store → device B
  `pull_snapshot` + `hydrate` + read → **byte-for-byte identical**. Data plane (chunks)
  *and* control plane (changelog) both proven. The cloud store is a shared local dir
  standing in for SeaweedFS/R2 (unreachable from the build env); the presigned
  transport (`PresignedIO`) is built and the server presigns correct SeaweedFS URLs.

## How to run it yourself

**The server + cross-stack demo:**
```sh
# from repo root
STORAGE_BACKEND=memory bin/rails server -p 3001        # terminal 1
# terminal 2:
cd client/sync-client
SERVER_URL=http://localhost:3001 cargo run --example e2e
SERVER_URL=http://localhost:3001 cargo run --example multi_device
```

**The FUSE mount (macOS/FUSE-T):** see `client/fs-fuse/BUILD.md`.

**Tests:**
```sh
bin/rails test                              # server: 10
(cd client/fs-provider   && cargo test)     # 5
(cd client/sync-client   && cargo test)     # 5
(cd client/maker-app-core && cargo test)    # 3 (Windows mount controller)
```

## Architecture in one line

Each device backs its filesystem with a **local SQLite tree** (instant ops) + a
**content-addressed chunk cache**; the **Rails server** is the source of truth (tree +
versions + per-user changelog); **chunks** live in R2/S3 and move **client ⇄ storage
directly via presigned URLs** (never through Rails). Devices stay consistent by
pulling the changelog (`seq > cursor`); changes propagate via ActionCable.

## Origin (2026-06-11): the first session's plan and decisions — HISTORICAL

> **Superseded. Do not read the two subsections below as current.** They record what the very
> first session planned and decided, kept because that reasoning is sometimes useful. Every
> numbered item in "What's NOT done yet" is **done** (daemon loop, live SeaweedFS bytes, the
> Windows adapter — now CfAPI, not WinFsp — and Postgres), and "last-writer-wins" in the
> decisions list was **reversed**: conflict detection with keep/split replaced it (CLAUDE.md §6).
> For what is actually open, see **Still open** at the top of this file and CLAUDE.md §12.

### What's NOT done yet (as of 2026-06-11 — ALL of this is now done)

1. **The running daemon loop.** `SyncEngine` (`push`/`pull_snapshot`/`pull_changes`/
   `hydrate`/`sync_once`) is **built and verified end-to-end with real bytes**
   (`roundtrip`). What's left is wiring it into a *continuous* loop on the client:
   (a) **watch the FUSE mount** (a write/flush → enqueue → push), (b) react to the
   **ActionCable** nudge (pull → apply), (c) hydrate on FUSE read (mount's `read`
   callback → `SyncEngine::hydrate`). Today push/pull are invoked explicitly; the
   loop + the mount↔engine wiring is the remaining integration.
2. **Real chunk bytes through S3/SeaweedFS.** The presigned transport (`PresignedIO`)
   is built, `aws-sdk-s3` is wired, and the server presigns correct SeaweedFS URLs
   (verified). Bytes were round-tripped end-to-end via a shared-dir stand-in, not live
   SeaweedFS (the box at `192.168.1.7:8333` was unreachable from the build env). To go
   live: start SeaweedFS, run the server with `STORAGE_BACKEND=s3
   CHUNK_ENDPOINT=http://192.168.1.7:8333 CHUNK_BUCKET=my-bucket
   CHUNK_ACCESS_KEY_ID=admin CHUNK_SECRET_ACCESS_KEY=secret`, and use `PresignedIO`
   in the daemon instead of `SharedDirIO`.
3. **Windows `winfsp-rs`** FUSE adapter (Linux + macOS work via `fuser`).
4. **Postgres deploy** — code is adapter-agnostic and tested on SQLite; switching is
   config only (see `docs/SYNC_SERVER.md`). No Postgres available in the build env.
5. **Writeback hardening** (atomic saves; FUSE-T defers `release`), real OAuth
   (placeholder device-token bootstrap today), N+1 preloading in `Sync::Changes`,
   chunk encryption, retention/GC policy job.

### Decisions locked on 2026-06-11 (one since reversed — see the warning above)

Tenant = user; full tree on every device; file-sync only; one protocol for managed
(Postgres + R2) and self-host (SQLite + their S3); last-writer-wins (conflict-copies
deferred). Server DB = Postgres for managed, SQLite for self-host — same code, adapter
per deployment (validated against the 37signals multi-tenancy writeup).
