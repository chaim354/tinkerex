# Build status — sync engine

**Updated:** 2026-08-12 (**two Stimulus controllers deleted out from under the views that declared them — a nine-day silent regression on `/tools/openscad`, plus the repo-wide guard that would have caught it**)

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

## Latest (2026-08-12): two Stimulus controllers deleted out from under the views that declared them (branch `claude/openscad-dead-controllers`)

A **live user-facing regression**, nine days old, plus the guard that would have caught it in the
commit that caused it. A bug fix, not an arc.

### What broke

`6095b87` (2026-08-03 — the *boxes* migration to a runtime bundle) deleted
`app/javascript/controllers/boxpreview_controller.js` (81 lines) and `boxfilter_controller.js` (52
lines). Both were the Box Generator's, and the Box Generator had indeed become an ESM bundle — but
**`/tools/openscad` also declared them**, at `index.html.erb:5` (`boxfilter`) and `new.html.erb:11`
(`boxpreview`), and nothing in that commit touched those views.

**Stimulus no-ops silently on an identifier it cannot resolve.** No throw, no console warning,
nothing in any log. So from 2026-08-03 to 2026-08-12:

- the OpenSCAD editor opened on an **empty grey preview panel**. `boxpreview` previews the
  generator's defaults **on connect** — its own comment says landing on an empty panel and having to
  press a button to find out what the generator even makes *was the thing it was written to fix* —
  re-renders on a debounce as params settle, and treats the Preview button as the manual retry. All
  three were gone; the button was inert too, since `data-action` only resolves for an attached
  controller.
- the generator filter on the index did nothing.

`thumbs_controller.js` survived, so prior-design thumbnails were unaffected — which is part of why
the page still looked healthy.

### Why the suite was green over it

`test/controllers/tools/openscad_controller_test.rb:218` POSTs the preview endpoint **directly**. It
proves the endpoint works and says nothing about whether anything calls it — so it stayed green
while the only button that issues that POST was inert. **This repo's recorded dominant failure
shape** (CLAUDE.md §15): a green suite over something that never runs.

### The guard — the valuable half

**`test/stimulus_hygiene_test.rb`** (new, 4 tests): every `data-controller` name declared anywhere in
`app/views/` must resolve to a real controller file. Repo-wide, not OpenSCAD-specific. **It fails in
`6095b87` itself.**

- **The mapping is DERIVED, not listed** — `identifier_for` replicates
  `registerControllerFromPath` in `@hotwired/stimulus-loading` verbatim, on the same input (the
  importmap pin name): `sub("_controller","")` — **`sub`, not `gsub`**, because JS's
  `String#replace` with a *string* argument replaces only the first occurrence, and it runs *before*
  the underscore pass — then `/` → `--`, then `_` → `-`. A new controller needs no edit here.
- **Both spellings are swept.** The literal attribute (which may carry **several space-separated
  names** — `data-controller="thumbs filemenu"` appears three times in `app/views/files` alone) and
  the Rails `data: { controller: … }` hash, which `app/views/shared/_folder_field.html.erb` uses.
  A literal-attribute grep silently misses that twelfth declaration; the task's own survey of
  "eleven declared names" is exactly what such a grep returns. The hash pattern is **anchored on
  `data:`** so a routing `url_for(controller: "files")` can never be mistaken for an identifier, and
  tolerates one level of nested braces so an interpolated sibling value does not end the scan early.
- **`data-controller` is the COMPLETE set**, not merely the greppable one: Stimulus binds
  `data-action="x->foo#bar"` and `data-foo-target` only when `foo` is attached through a
  `data-controller` on an ancestor, so sweeping that one attribute misses nothing.
- **The direction is deliberate.** Declared-but-missing fails; a controller file no view names does
  **not** — `hello_controller.js` is Rails' scaffold and `thumbfallback_controller.js` is reached
  from JS, so the converse would need an exception list, which is the thing this file avoids.
- **Non-vacuity is proved on a SYNTHETIC document**, not on whatever `app/views` contains today: a
  second test feeds the extractor all four cases (two names in one attribute, single quotes, the
  hash form after an interpolated sibling, and a routing option that must *not* be collected) and
  pins the reported `file:line` as well as the names. A regex that quietly stopped matching would
  otherwise leave the sweep passing because it finds nothing.
- **No real filename is pinned anywhere.** The transformation is asserted on invented paths, and the
  glob only on the SHAPE of what it returns (which is what would catch `Dir.glob`'s `base:` going
  wrong and turning every identifier into an absolute path). A guard that names a file goes red the
  day that file is legitimately renamed, which is how a guard gets deleted rather than fixed.

**MUTATION-CHECKED, three ways** — each time red, then restored green:

| removed | failure |
|---|---|
| `boxpreview_controller.js` (the original bug) | `["app/views/tools/openscad/new.html.erb:11 declares \`boxpreview\`"]` |
| `filechooser_controller.js` (the hash-form arm) | `["app/views/shared/_folder_field.html.erb:25 declares \`filechooser\`"]` |
| `thumbs_controller.js` (multi-name attribute) | 8 offenders across 8 views, including the three `thumbs filemenu` pairs |

### The behaviour test

**`test/system/openscad_preview_test.rb`** (new, 2 tests). The hygiene guard proves the controller
*exists*; this proves it does its job — loading `/tools/openscad/new` for a catalog generator renders
a preview with **nobody clicking Preview**. Asserts the `<img>` gets a `blob:` src *and*
`naturalWidth > 0`, because a blob holding a 404 page still yields a `blob:` URL; only a decode proves
a picture appeared. Plus `assert_no_console_errors`.

**Two seams are stubbed, for different reasons — and the second is the one worth reading.**

1. **The sidecar**, at `OpenscadClient.stub` — the seam `openscad_controller_test.rb` and
   `file_chooser_test.rb` already use. No Python sidecar in CI.
2. **The rasterizer**, at `Maker::Previews::ThreeMf.render`. Not a sidecar problem: a
   sidecar-produced 3MF carries no embedded slicer thumbnail, so `#rasterize` always falls through
   to the mesh path, which shells out to the **`stl-thumbnailer` binary** — absent on this box and on
   the runner. Unstubbed, the endpoint answers a perfectly correct 422 and "an image appeared" is a
   test that can never pass, for a reason having nothing to do with the bug.

Stubbing (2) costs no coverage: `openscad_controller_test.rb`'s "preview rasterizes the rendered 3MF
server-side, and says so when it cannot" drives the **real** `#rasterize` on both branches.
**Rejected alternative:** handing `FakeOpenscad` a 3MF that embeds a thumbnail would have needed no
second stub, but would quietly send the server down a branch production never takes — a fake
diverging from the real wire format is this repo's recorded way of *confirming* a bug (§14e).
Hand-rolled with `define_singleton_method` + an `ensure`, because **minitest 6 dropped
`minitest/mock`** and with it `Object#stub`; the separate gem is not in the Gemfile.

MUTATION-CHECKED: deleting `boxpreview_controller.js`, and separately removing just the
`this.preview()` at the end of `connect()`, each turn both tests red
(*"the editor never previewed the generator's defaults"*) with the rest of the suite green.

### Two things that had drifted in nine days

- **`new.html.erb` shipped no `status` target**, so the restored controller's `#status` would have
  returned early and swallowed every refusal — the panel would just stay blank, reading exactly like
  the missing controller did. Added, with the second system test as its guard (removing the element
  turns that test, and only that test, red). The endpoint's contract also moved under it in `#176`:
  a refused value now comes back **422 carrying the sidecar's own prose** (`code: "invalid_params"` →
  `OpenscadClient::InvalidParams` → `render plain: e.message`), so the restored `#refusal` surfaces
  that text rather than "Preview failed (422)" — branched on `text/plain`, so an unrescued 500's HTML
  error page is not emptied into the status line instead.
- **`boxfilter` was trimmed on restore.** Its deleted version also forced collapsed `<details>` open
  during a query and hid table-of-contents entries — both for the Box Generator's grouped index.
  `/tools/openscad` renders one flat `<div class="box-group">` and no TOC, and the `boxsections`
  controller those `<details>` belonged to went in the same commit. Restoring the `tocitem` target
  and the reveal pass verbatim would have been restoring dead code whose own comment pointed at a
  controller that no longer exists.

**Not renamed.** `box*` names now serving only OpenSCAD are misleading, but the addon is slated for
retirement within days and a rename touches both views plus both files for nothing a user can see.
A header comment on each says the name is historical and why.

### One knock-on, and it is evidence the fix works

Restoring the controller made `file_chooser_test` go red on all five of its tests — its host page is
`/tools/openscad/new`, which now actually fires a preview, which on a box with no `stl-thumbnailer`
answers a correct 422 that Chrome logs at SEVERE. Handled with an `ignoring: [PREVIEW_422]` pattern
and a comment, the same way `box_sections_test` handles its deliberate sample-photo 404s. It is not a
hole that widens with the environment: on a box that HAS the binary the preview succeeds and the
pattern matches nothing. **Between `6095b87` and this branch it also matched nothing — because no
preview was ever requested.** That silence is precisely what the new hygiene test refuses to allow.

`wait_until` moved from `box_sections_test`'s private section into `WebHelpers`, this being the
second file needing the same poll for the same reason (an `<img>` `src` is a property, not a DOM node
Capybara can wait on) — which is the point that file's own header says it moves.

### Verification

`bin/ci` **exit 0**, judged by exit code, all seven gates, 54.1 s. **2302 runs / 8315 assertions / 0
failures / 10 skips**, **identical on all three legs** (chunk, share, s3); system **88 runs / 529
assertions** (20.1 s). Baseline by **running the merge-base** `84632d0` with the two new files moved
aside: **2298 / 8278 / 10 skips**. So **+4 server tests / +37 assertions** and **+2 system tests**,
no new skips. (The assertion count is lopsided because one guard loops over every controller file.)

**Not deployed.** The fix is live-user-facing and the addon is deployed on all three Unraid legs, so
this wants a deploy once merged.

---

## 2026-08-12: the OpenSCAD coercion guard moved into the sidecar (branch `claude/openscad-coercion-to-sidecar`)

**Row 7's risky half, split off and shipped on its own** (`docs/superpowers/specs/2026-08-07-addon-api-v1-design.md`
§12). The row's Risk column said *"server-side param coercion moves into the sidecar"* — that
sentence, and not the bundle work, is what made it **high**. This is that sentence, done. **The
migration itself is not started**, and nothing here brings it closer than one prerequisite.

### The fact underneath it, which is the whole reason there is a guard at all

**A garbage parameter value renders SUCCESSFULLY, with the DEFAULT geometry.** `{"cols": "))("}`
comes back **200**, because OpenSCAD's `parameterSet` silently *ignores* a value it cannot parse.
Not reasoned — observed against a real render, and it is now **pinned by a test rather than by a
comment**: `test_OPENSCAD_REALLY_DOES_IGNORE_A_VALUE_IT_CANNOT_PARSE` calls `render.render`
*directly*, bypassing coercion, and asserts the garbage render is **byte-identical to the default
one** while a real value **does** move the geometry. (Both halves: without the second, a build that
had stopped honouring `cols` at all would pass the first.) OPENSCAD_BIN-gated, so it runs in the
image. If OpenSCAD ever starts refusing such a value, that test is what says so — and the
justification for all 200 lines below would need re-reading rather than being taken on trust.

Without a refusal, a typo yields a default-sized model, **saved into the user's library**, with no
feedback anywhere. That is the silent-wrong-output failure this codebase treats as worst.

### What moved, and why it could not simply be copied

`app/services/openscad_params.rb` (130 lines) is **deleted**. `sidecar/openscad/coerce.py` is the
one copy. A browser bundle cannot call a Rails service object, so the guard had to sit at the door
*every* caller goes through — and both Rails and a future bundle reach OpenSCAD only via
`POST /render`. Leaving a Ruby copy beside it would have been this repo's recorded failure shape
(the five `port_writable?` branches, the Scanner's skip-list, chunk's missing filename check): a
guard that runs on one caller's path and silently does not on another's.

Ported faithfully, including the four things easiest to "improve" into bugs:

- **`choices` beats `type`** (schema.py's TRAP 3). schema.py always labels an options-carrying param
  `"enum"` today, so that arm is not observable from its own output — which is exactly why it has a
  test of its own, built on a hand-made `{type: "int", choices: [10, 20]}` spec: read `type` first
  and a future derivation silently accepts `15` for a param whose only legal values are 10 and 20.
- **The bool mapping is an ALLOWLIST**, not a framework boolean cast. Rails'
  `ActiveModel::Type::Boolean` (and most equivalents) map everything outside a short false-list to
  **`true`**, so `"maybe"` would silently become a rounded plate nobody asked for — the same bug in
  a hat.
- **min/max are NOT enforced**, deliberately. OpenSCAD *honours* an out-of-range number rather than
  ignoring it, so an out-of-range value is not the silent-default failure this guard exists to stop;
  refusing it would only add false rejections to a check whose whole value is that it never fires on
  something that would have worked. The test asserts the fixture really does declare a range first,
  so it cannot pass vacuously.
- **Messages are truncated at 40 characters**, ActiveSupport's `String#truncate` semantics (the
  omission is *inside* the budget: 37 chars + `...`, never 43), so a 10 kB paste in a number field
  cannot become a 10 kB flash.

**Two Python-vs-Ruby divergences the port had to close by hand**, both silent if missed: `str(None)`
is `"None"` where Ruby's `to_s` gives `""` (a cleared field would stop reading as blank and start
reading as garbage — same refusal, wrong sentence), and `str(True)` is `"True"` where Ruby gives
`"true"` (a JSON `true` posted to an enum would stop matching a `"true"` choice). `coerce._text` is
Ruby's `to_s`, not Python's `str`, and says so. Going the other way, `float()` **accepts** `"inf"`
and `"nan"` where Ruby's `Float()` refused them outright — so the `math.isfinite` check that existed
only for `"1e400"` overflow now does both jobs.

### The discriminator: the sidecar answers 422 for two different things

A `.scad` the parser rejects and a *value* the coercer rejects are both client conditions and both
**422** — and Rails must react differently. A rejected value comes back as a **form error with the
user's own entries still in it** (`editor_again`, which is what stops a correctness guard from
costing someone their whole form); a broken source **bounces to the index**. So `/render` tags the
one it means:

```json
{"error": "“cols” must be a number (got “))(”)", "code": "invalid_params"}
```

`error` keeps the prose — it is the key this sidecar already answers errors in, and PR #169
deliberately preserved a sidecar's own words end to end into a bundle's `ServiceError`. `code` is
the machine half. `OpenscadClient` raises **`InvalidParams`, a SUBCLASS of `Error`** (§14a's rule:
a caller that must branch on WHY gets a subclass, so every existing `rescue Error` — `#preview`,
`#new`, `editor_again`'s own fallback — keeps working untouched), matching on the **code and never
the prose**, which a sidecar release can reword without ever rebuilding Rails.

**`OpenscadClient` needed one more fix while it was open.** `error_detail` did
`JSON.parse(body)["error"]` inside a rescue — which handles *unparseable* bodies but not bodies that
parse to a **non-object**. `[1,2,3]` is valid JSON and `["error"]` on an Array is a `TypeError`,
escaping as a 500 from inside the code whose only job is to describe a failure. "It parsed" and "it
is the shape we are about to index" are different questions; `parsed_body` now asks the second.

### The render cache: checked, and it is fine — because coercion runs BEFORE the key

The sidecar content-addresses renders over the params it is handed. Until now Rails coerced and the
sidecar hashed the **coerced** values; `_coerced` is therefore called **before `render.render`**, so
the key is still computed over those same values and **every entry already on the `/cache` volume
keeps hitting**. Hash the raw values instead and nothing is *wrong* — different raw spellings
produce different keys, never a collision — but the whole existing cache is orphaned on deploy: a
silent full re-render of every design anyone has ever made. Pinned directly:
`cache_key(src, coerce({"cols": "6", …})) == cache_key(src, {"cols": 6, …})`, the second literal
being what Rails used to send.

### The one behaviour that is deliberately different, and the assertion that changed with it

`Maker::AddonState#data["params"]` now records the values **as submitted** (`{"cols" => "6"}`)
rather than coerced (`{"cols" => 6}`). Rails no longer *has* the coerced values — `/render` answers
3MF bytes, not values — and echoing them back through a response header was rejected as inventing a
truncatable side channel. **Nothing downstream can tell**: the show page renders `6` either way, the
"duplicate & tweak" link emits `params[cols]=6` either way, and re-posting them re-coerces
identically, which is what "the design reproduces exactly" actually needs. One assertion in
`openscad_controller_test.rb` changed from `6`/`2.5` to `"6"`/`"2.5"` — **saying something
different, not something less**: it still pins the exact recorded value including its type, which is
what would catch a drift back.

### What the tests do now, and where the coverage went

The Ruby suite's three coercion tests are **two**, and they claim less on purpose. Every semantic —
each type, the enum trap, the bool allowlist, min/max, truncation, the six-case garbage loop — is in
`sidecar/openscad/tests/test_coerce.py`, against a `param_groups` derived from **real
`--export-format=param` output** (test_schema's captured dump, reused rather than re-invented: the
FakeS3 lesson). What Rails still owns, and all the two remaining tests assert, is the **reaction**:
the sidecar's own sentence reaches the user unreworded, and a refusal on save costs them neither
their form nor a half-written bundle. The fake raises `InvalidParams` because that is what the real
client raises for the sidecar's tagged 422 — **proved against the wire**, over a real socket, in
`openscad_client_test.rb`, rather than taken on trust from the fake.

`openscad_live_test.rb` gains the end-to-end leg (Rails posts raw → the sidecar refuses → the tagged
422 arrives back as `InvalidParams` and *not* as a plain `Error`), and its stale "`5 skips`" header
now reads 7 and matches the file.

### Mutation-checked, four ways

| Mutation | Result |
|---|---|
| `/render` restored to the pass-through (`params = body.get("params")`) | **3 red**, headline `assert 200 == 422` — the garbage value renders |
| `_boolean` falls through to `return True`, `_number` falls back to the default | **8 red** |
| `refusal` always raises `Error` (discriminator dropped) | **1 red** — the wire test; the controller tests *cannot* see it, which is why the wire test exists |
| `#create`'s two rescue arms swapped (superclass first) | **1 red** — `302` to the index instead of `422` with the form |

### Numbers

`bin/ci` **exit 0** — judged by exit code — all seven gates, 58.7 s. **2298 runs / 8278 assertions /
0 failures / 0 errors / 10 skips, identical on chunk, share and s3** (10.7 s / 9.6 s / 8.7 s);
system **86 runs / 519 assertions** (22.1 s). Baseline by **running the merge-base** `d23317b`:
2292 / 8290 / 9 skips. So **+6 server tests** and **+1 skip** (the new live test, which skips without
`OPENSCAD_SIDECAR_URL`); system unchanged.

**Assertions went DOWN by 12, and that is the honest shape of this change rather than a regression.**
The deleted six-case loop was assertion-dense (18 assertions in one test) and its coverage did not
vanish — it moved to Python, where minitest cannot count it. The sidecar suite went **29 → 66 passed
/ 11 → 13 skipped** on the host (`python -m pytest -q` in `sidecar/openscad`, with flask + pytest in
a venv), i.e. **+37 tests**; in the image, where the two new OPENSCAD_BIN-gated tests also run, the
README's expected total is **79 passed, nothing skipped**.

`test/deploy_hygiene_test.rb` passes unchanged — this adds Python to a GPL-2.0 sidecar and imports
nothing from it into Rails, so `/sidecar/` in `.dockerignore`, the blanked `OPENSCAD_SIDECAR_URL` in
`deploy.ovh.yml`, and the in-image `LICENSE` are all untouched (§9, §14c).

### What still stands between here and retiring the controller

Named plainly, because an optimistic list here is what makes the next reader stop looking:

1. **No bundle exists.** The manifest + editor UI live in `chaim354/tinkerex-addons`, a separate
   repo, and publishing that image *is* the deploy.
2. **A bundle cannot get a `.scad`'s parameter schema yet.** It must ask before it can render a
   form. `POST /params` is reachable through the service proxy, but **the sidecar's normalized
   schema shape is nobody's declared contract** — it is documented only as "what `OpenscadClient`
   speaks". Freezing it is real work, and it is the next prerequisite.
3. **Three pieces of the controller have no bundle-facing equivalent**: the server-side 3MF→PNG
   rasterization (`#rasterize` — a browser cannot display a 3MF, so this is not a "just do it
   client-side"), the folder-path label from `Tools::LibraryFolders`, and the "prior designs from
   this source" list (a `Maker::AddonState` query filtered in Ruby because `data->>'generator'` is
   Postgres-only).
4. **`state.data`'s shape is load-bearing for `show` and the prefill link**, and a bundle saving
   through the generic door writes a different shape. Migrating existing saved designs, or teaching
   `show` both shapes, is unplanned.
5. **The catalog's licence display** (`index` renders each generator's licence and attribution per
   tile, guarded by a test) has to survive the move — the catalog is redistributed inside a
   commercial image, so this is the §2 rule, not decoration.

## 2026-08-11: the addon file plane — binary out, one file in, and a picker that is the host's (branch `claude/addon-api-pr5-file-plane`)

**Row 5 of the addon API v1 arc** (`docs/superpowers/specs/2026-08-07-addon-api-v1-design.md` §6),
and the thing standing between the arc and row 7. Retiring the bespoke `Tools::OpenscadController`
needs two capabilities the generic surface did not have: it **reads** `.scad` out of the library via
`FileLayer#read`, and it **writes 3MF — binary**, while the generic save door required
`f["body"].is_a?(String)`. Both are now there.

### Binary save: two wire shapes, one ordered list

`POST /tools/:key` still takes today's JSON `files` array — every published bundle sends it and
Rails is never rebuilt when a bundle is (§14c) — and now also accepts **real multipart file parts**.
A JSON entry either carries its bytes inline (`body`, a String) or names a part (`part: "f0"`, posted
as `parts[f0]`). **The JSON array stays the manifest for both**, because order is load-bearing
(`AddonFile#position`; `placements[i]` pairs a file with the destination resolved for it) and two
collections in one request have no ordering rule that is not implicit.

**How a text file's content travels, and why.** A file's content never crosses the wire as a bare
multipart TEXT field — that is the rule, written into `#parse_files` and into the SDK. The two shapes
are safe for two different reasons and both have to be understood before anyone adds a third: a
string `body` is **JSON-escaped**, so a `\n` is the two characters `\` and `n` on the wire and the
browser's serializer has no newline to rewrite; a `parts[…]` entry is a **file** part, which the same
multipart algorithm transmits verbatim precisely because it is not a text entry. This is the CRLF
defect the previous entry records, one door over — and it would have been strictly worse here,
because the corruption lands in a file the user keeps rather than in one sidecar call. The SDK routes
by the body's TYPE (`Blob`/`File`/`ArrayBuffer`/TypedArray/`DataView` → a part; String → the JSON
field) and re-wraps a Blob so the part carries the author's declared `contentType`: **content type
comes from the part, never guessed**, so one value with one source.

Two more single-source rules, each with its own test: the **name** always comes from the JSON entry
and never from the part's `filename` (which is what lets `valid_leaf_name?` + `ReservedNames` cover
both shapes with no second copy), and a `part` is looked up **inside `parts[…]`** and must be an
`UploadedFile` — a client-supplied key indexing the top level of `params` would resolve `part: "name"`
to the state's own name, a String that answers `#size` in CHARACTERS and has no `#read`.

`ADDON_SAVE_MAX_FILES` / `ADDON_SAVE_MAX_BYTES` are explicit and read per request, defaulting to
today's **8** and **4,000,000** so no published bundle changes behaviour. Bytes is a **total across
the save**, deliberately not per-file — per-file would LOOSEN the rule (8 × 4 MB), and a cap that
grows when it is made explicit is not the same cap. Sources are **sized before any is read**, so an
oversized part is refused for the price of a `stat`. A garbage value falls back to the default, never
to 0.

**The Rack interaction, verified against rack 3.2.6 rather than assumed**, because the old comment on
`MAX_FILE_BYTES` only described half of it: a **url-encoded** body dies at
`RACK_QUERY_PARSER_BYTESIZE_LIMIT` (4 MiB) as a bare 400 in `each_query_pair`, before the action
runs — so raising the app cap buys that shape nothing. **Multipart is a different limit entirely**,
`RACK_MULTIPART_PARSER_BYTESIZE_LIMIT`, default 10 GiB — and that covers the JSON `files` field
*inside* a multipart body too, since multipart fields never reach the query parser. So a raised cap
means something to the SDK (always multipart) and nothing to a hand-rolled url-encoded POST. Pinned
by a test that saves 4.2 MB through a part with the cap raised to 5 MB.

### The read surface

`GET /tools/:key/file/:node_id`, gated on the manifest declaring `library:read`, scoped to
`current_user`'s own live **file** nodes, consuming `FileLayer::Delivery` exactly as
`FilesController#blob` does — all three variants, **no `else`**, so a fourth mechanism raises rather
than serving a blank 200.

**The gate is declaration consistency, not containment, and the code says so in those words**
(spec §8.1). A Ring 1 bundle is same-origin browser code in the signed-in session and can call
another addon's read endpoint directly. What it buys is that an addon which starts reading the
library must say so on the card the operator reads at publish time, in a deployment where publishing
a bundle IS the deploy.

**`NotFound` answers 404, rescued inside the action.** The class-level `rescue_from` answers 422 with
"Your library refused that write." — right for the save door, a lie on a read whose request was
well-formed and simply named something gone; and 422 ("your request was malformed") sends an addon
author looking at their own code for a file the user deleted. Same shape as `FilesController#geometry`
rescuing `RecordNotFound` locally (§14h). One 404 for four causes — unknown id, a stranger's node, a
tombstone, a directory — so the endpoint cannot report which node ids are real. `FetchError` keeps
the class-level 503: an unmounted share is retryable and must never read as "your file is gone"
(§14a).

**Always `application/octet-stream` + `attachment`, and therefore no byte-URL helper — and the
content-type half was a LIVE BUG found by probing rather than by reading.** The endpoint first served
Marcel's answer, the way `FilesController#blob` does. A `.js` file in the library is
`text/javascript`; `verify_same_origin_request` is an `append_after_action` that fires on any non-XHR
JavaScript response; and a `fetch` sets no `X-Requested-With`, so **every SDK read of a `.js` raised
`InvalidCrossOriginRequest` and the addon received a 422 HTML error page instead of its bytes.**
Probed with a throwaway integration test aimed at the endpoint, not derived from the code.

`skip_forgery_protection only: :file` would have been the obvious fix and is the **worse** one:
`#asset` can afford that skip because its body is the same static bundle for every viewer, while this
body is a **user's own file** — skipped, a third-party page's `<script src>` would execute a library
file in the attacker's origin and read it out. Serving everything opaquely removes the condition
structurally, needs no list of script-capable types to keep current (§14b's skip-list blind spot),
and costs a bundle nothing: it picked the file and knows what it asked for. Two tests pin it, on the
type as well as the bytes — a bytes-only assertion would pass against a fix that corrected the status
and still leaked `text/javascript`. **`FilesController#blob` still serves Marcel's type and carries
the same latent shape**; out of scope here, recorded.

Forcing attachment also means such a URL could not back an `<img src>`, which is why
`host.files.blobUrl` does not exist. One operator caveat, in the docs rather than worked around: on
**s3** the `Delivery::Redirect` is cross-origin, so a bundle reading those bytes needs the bucket's
CORS to allow this origin — streaming through Rails instead is what §15 forbids.

### `pickFile`, and where the extension filter lives

`app/javascript/lib/file_chooser.js` already had `mode: "file"` and `library_browse#children` already
took `files=1`, so this was wiring: the shell hands the bundle a `chooseFile` function beside
`chooseFolder` (in the SDK ctx **and** in the raw `mount` ctx — additive, and the raw path stays
supported per §10.2), and the SDK exposes `host.files.pickFile({ extensions })`. Resolves
`{nodeId, kind, path}` or **`null` for cancel**, and in file mode `null` has exactly one meaning:
there is no "chose the root" answer, because a directory is never a valid selection.

**`extensions` filters client-side**, and the argument is the one §14d already makes about
vocabularies: `/library/children` answers one bounded folder the modal already holds, so a server-side
filter buys no round trips and costs a second definition of "which extensions count" on an endpoint
the form-field chooser shares. Folders are never filtered — that would hide the path TO a matching
file. A malformed `extensions` filters nothing rather than everything, so an addon's typo shows the
user their files instead of an empty picker. It is a convenience for the human, never a restriction:
a bundle can pass any node id to `read`.

### `Host::LEVEL` is 2

`library:read` and `pick:file` flipped to `true` and `LEVEL` bumped **in the same commit**, per
§14c's rule — a manifest's `min_host` is the only way an addon can say "I need this", and
`api_version` equality cannot express it. `host_test.rb` now pins the level against the *set* of true
capabilities as a relationship, so flipping a third without bumping goes red rather than shipping a
capability no manifest can require. **Binary output deliberately got no capability name of its own**:
it is the same `library:write` door growing a second body type, so a second name would be true
exactly when `library:write` is, and would carry no information. `min_host: 2` is how a bundle
requires it.

A `min_host: 1` manifest still works: `unavailable_reason` refuses only when `min_host > LEVEL`. The
`sdk-fixture` manifest now declares `min_host: 1` so that is proved by something that RUNS — through
a real mount, not by asserting `available?`, which is a weaker claim than the page rendering.

### What did NOT land, recorded because the spec promised it

Spec §6.2 says "`folders` therefore moves behind `pickFolder`", and §14 justifies it as removing a
per-load tree inflation. **`data-addon-folders-value` stays emitted**: §10.1 keeps every current data
attribute for the life of `api_version: "1"` and published bundles build their `<select>` from it, so
removing it is a decision for the bundles repo. The Ring-2 half of that sentence is true (an addon
using the pickers never enumerates the tree); **the perf half is not** — the shell still serializes
the user's folder list into every addon page. Corrected in the spec rather than left to read as done.

### Mutation checks — thirteen, each RED on its own test and restored (§15)

Two of them found that a test could not see the guard it was written for, which is the whole point of
doing this:

| # | Mutation | Result |
|---|---|---|
| 1 | `unless @addon.declares_permission?("library:read")` → `unless true` | RED — `Expected response to be a <403: forbidden>, but was a <200: OK>` |
| 2 | `current_user.nodes` → `Node` on `#file` | **GREEN at first** — every adapter re-scopes in its own `live_node!`, so a stranger's node still 404s, from the port. Test rewritten onto a port double that trusts its caller; then RED, `<404: missing>` vs `<200: OK>` |
| 3 | `kind: "file"` dropped from the lookup | **GREEN at first**, same reason (chunk answers NotFound for a dir with no `current_version`). Same fix; then RED, `<404> vs <200>` |
| 4 | file-count cap removed | RED — a 3-file save accepted with the cap at 2 |
| 5 | total-bytes cap removed | RED — two 6-byte files accepted with the cap at 10 |
| 6 | a part's `size` reported as 0 | RED — a 9-byte part accepted with the cap at 8 |
| 7 | `else head :ok` added to the Delivery match | RED — `NoMatchingPatternError expected but nothing was raised` |
| 8 | the `UploadedFile` type check on a part removed | RED — `NoMethodError: undefined method 'content_type' for an instance of String`, i.e. the 500 the guard exists to prevent |
| 9 | `params[:parts]` → `params` | RED — a real upload posted under an undeclared top-level key was written |
| 10 | content type taken from the JSON entry instead of the part | RED — `Expected: "application/vnd.custom"` |
| 11 | the name taken from the part's `original_filename` | RED — the file was written under the browser's name |
| 12 | the chooser's extension filter disabled | RED (browser) — `found 1 match: "📄 pick-other.svg"` |
| 13 | the read endpoint answering Marcel's content type again | RED on both — `Expected "image/svg+xml" to not include "svg"`, and the `.js` case reproducing `ActionController::InvalidCrossOriginRequest` as a 422 |

Two more in a real browser, on the transport itself: a string body pre-normalized to CRLF the way a
multipart text field would do it read
`txt=line one<CR><LF>line two<CR><LF>` against the expected `<LF>` — which is exactly why the fixture
renders the terminators rather than the text, since Capybara's whitespace normalization makes the two
identical to an ordinary assertion; and disabling the SDK's binary routing read
`AddonError:invalid_argument`.

### The browser proof

`test/fixtures/addons/sdk-fixture/` gained a **"Save and read back"** button that writes a binary
`.3mf` (a PNG signature plus a lone `0xFF 0xFE` — bytes no decode/re-encode could launder quietly) and
a multi-line `.txt` **in one save**, then reads both back through `host.files.read` and renders the
binary as hex and the text with its line endings spelled out. The save side cannot see any of this:
a save that mangled the bytes still redirects and still says "Saved."

Plus a **"Pick a file"** button covering both halves of the picker contract. Written first against a
project folder, and §14f's eager intake nudge did exactly its job — it filed the `.3mf` into `models/`
and the `.svg` into `design/` before the picker opened, so the two files were never in one column and
the `extensions` assertion was **vacuously true**. Rewritten against a folder no project owns.

One more found by the share leg rather than by reading: three new tests all wrote `cube.3mf` to the
library root, and the share leg's parallel workers share one `LIBRARY_PATH`, so the second worker hit
a real `Share#write` clobber. Unique names per test.

And one by the **s3** leg. The helper reading the delivered content type treated the whole presigned
URL as a haystack, which is fine for `attachment` and wrong for a type: the URL also carries the
FILENAME, so `assert_not_includes location, "svg"` failed on `drawing.svg` for a response whose
signed `response-content-type` was `application/octet-stream` — a true assertion failing on the wrong
string. Both helpers now parse the specific signed parameter.

### Numbers

`bin/ci` **exit 0** — judged by exit code — all seven gates, 55.0 s. **2292 runs / 8290 assertions /
0 failures / 0 errors / 9 skips, identical on chunk, share and s3** (9.8 s / 9.0 s / 10.4 s); system
**86 runs / 519 assertions** (19.5 s). Baseline taken by **running the merge-base** `9da27da`, not by
reading the entry below: 2265 / 8187 and 82 / 494. So **+27 server tests** (26 in
`addons_controller_test`, 1 in `host_test`) and **+4 system tests**, none removed.

### What this unblocks — row 7, and the honest state of it

Both of `Tools::OpenscadController`'s blockers are gone: a bring-your-own `.scad` is
`pickFile({extensions: [".scad"]})` + `files.read`, and a 3MF is `files.save` with a `Uint8Array`
body. Neither is theoretical — the fixture does the binary half and the picker half in a browser on
every CI run. What row 7 still owns is what the spec already flags as its risk and this PR does not
touch: **`OpenscadParams.coerce` runs server-side**, reading a `.scad`'s declared parameter groups to
coerce and refuse user input, and a bundle cannot call it. That coercion has to move into the sidecar
before the controller can go. *(Done the next day, on its own branch — see the Latest entry. Nothing
else in this paragraph changed; the migration is still not started.)*

## 2026-08-11: the addon service plane — a CRLF corruption nothing could see, and three more (branch `claude/addon-api-pr6-service-plane`)

**PR 6 of the Addon API v1 arc** (spec `docs/superpowers/specs/2026-08-07-addon-api-v1-design.md`
§12 row 6), and **only half of that row**: the *service* plane shipped, `integrity` and content-hash
asset URLs were split out — they are the *asset* plane, a different action, a different cache, and
they need a per-publish manifest version this contract still lacks. Recorded in the spec beside the
row rather than left to be re-derived.

**Three of the four changes were defects, not enhancements, and none was a hypothesis.** `generators`,
`boxes` and `boxes-next` are all live on `@maker/addon-sdk`; migrating `boxes` is what exposed them,
and each had a live workaround in a published bundle with a comment naming the gap.

### 1. `service.post` corrupted every multi-line value, silently

The SDK built a `FormData`. **multipart/form-data serialization normalizes every text entry's
newlines to CRLF** — the HTML standard's own encoding algorithm — and it happens *inside the
browser, after `append` returns*. So a `<textarea>` whose DOM value is LF-clean reached the sidecar
as `"+-+-+-+\r\n…"`. boxes.py's **TrayLayout**, whose entire input is that ASCII art parsed line by
line, rendered the wrong tray and reported nothing. There is no bundle-side fix: pre-normalizing
cannot help, because the mangling is downstream of the bundle. `preview.js` was still on a raw
`fetch` for exactly this.

**The server end already wanted JSON and this was verified rather than assumed.** `ServiceProxy#call`
re-emits `params` as a JSON body because Flask's `request.get_json(force=True)` cannot read a form
body. So the corruption was entirely browser-side and the fix is one-sided: `Content-Type:
application/json` + `JSON.stringify(params)`, CSRF header kept. The same line fixes a second defect —
`append` stringifies a nested value to the literal `"[object Object]"`, and `{generator, params: {…}}`
is the shape of *every* real sidecar call.

**Probing the whole path end to end found a defect nobody had reported.** Rails 8 defaults
`wrap_parameters format: [:json]` **in the framework** — there is no initializer in this repo, so
grepping `config/` finds nothing and the behaviour reads as absent. ParamsWrapper **merges a complete
duplicate of the body** under a controller-derived key into `request.request_parameters`, which is
verbatim what `#service` forwards. Measured, before the fix:

```
{"generator" => "TrayLayout", "params" => {…}, "addon" => {"generator" => "TrayLayout", "params" => {…}}}
```

Every sidecar call would have carried a second complete copy of itself under a key no sidecar has
heard of. **Inert while the transport was multipart** (ParamsWrapper does not touch it), live the
moment it became JSON — a doubled body on boxes' every debounced render, which boxes.py tolerates,
which is exactly why nothing would have reported it. Fixed with `wrap_parameters format: []` on
`Tools::AddonsController`.

### 2–4. `service.url`, `{ signal }`, and per-service timeouts

- **`host.service.url(name, path, params?)`** — synchronous, issues no request. `gallery.js` points
  an `<img src>` at the proxy for sample photos and `service.get` *performs* the request and resolves
  a `Response`, which cannot feed an attribute. Fetch-and-objectURL was rejected on measurement, not
  taste: it defeats `loading="lazy"` across a tile grid and leaks a blob per card. All three verbs now
  share **one** builder (`_serviceUrl`), which is what makes the traversal guards unforgeable — the
  builder is the one place where a `..` is never inspected by a server guard afterwards, because there
  is no request to inspect.
- **`{ signal }` on `get`/`post`**, forwarded to `fetch`. **An abort is rethrown verbatim, never
  wrapped in `ServiceUnavailableError`** — that class means "retry later, nothing to fix now", a lie
  about a request the bundle cancelled itself. The condition is **`init.signal?.aborted`, not
  `err.name === "AbortError"`**: `abort(reason)` makes fetch reject with *that reason* (a plain
  `Error`, name `"Error"`), so the name test works for the simple caller and **fails silently for the
  careful one**. Both directions mutation-checked.
- **Per-service timeouts** — the row's original scope, and what unblocks row 7. `ServiceProxy::READ_TIMEOUT`
  is a fixed 30 s while the OpenSCAD sidecar caps its **own** render at 60 s
  (`sidecar/openscad/render.py`'s `TIMEOUT_S`, confirmed in tree), so the proxy gave up before the
  sidecar finished — which is why the bespoke OpenSCAD controller could not retire. Recorded as
  `docs/AUDIT-2026-08-03.md` **§2.3 "Sidecar-proxy read timeout…"**, named rather than numbered
  because **that document has two sections numbered 2.3** and the other is the Content-Type
  allowlist. Manifest key `service_timeouts` (`{name: seconds}`), parsed by `Registry` **per entry** and
  degrading; the cap is applied at the **point of use** (`ServiceProxy.read_timeout_for`), not in
  `Registry`, so lowering `ADDON_SERVICE_MAX_TIMEOUT` (default 120) does not wait out the 5-minute
  manifest cache. **A manifest above the cap gets the cap, not an error** — refusing would take a
  working addon down on a deploy that merely lowered the ceiling.

**Why the cap exists, since it is the whole argument for having one:** the proxy is synchronous and
`#service` holds a Puma thread for the entire round trip. Production runs `RAILS_MAX_THREADS: 16` on
one worker (`config/deploy.yml`), so **16 concurrent renders at the cap occupy every thread for two
minutes** and queue everything behind them — the addon page itself included. The cap bounds
worst-case head-of-line blocking; the answer to a genuinely long render is an async job, which
`docs/addon-api-v1.md` §7 now names as **not reserved** — matching spec §13, so an addon author is
told there is no capability to feature-detect rather than left to guess one is coming.

Worth connecting, because it was already written down elsewhere: `config/deploy.yml`'s own
`RAILS_MAX_THREADS: 16` comment calls that thread bump "the cheapest of the three fixes the audit
lists", naming the other two as **per-endpoint proxy timeouts** and **moving renders to a job with a
polled result**. This PR ships the first of those two. The third stays open.

### The CRLF fix had to be proved in a browser, and the mutation is the evidence

**A unit assertion could not have caught this and still cannot** — every layer this repo can call
directly holds a clean string; the corruption lives in the browser's multipart serializer. The
original bug was found by `tray_layout_test.rb`, a real round trip, so the pin is one too: the
hermetic `sdk-fixture` bundle now `host.service.post`s a real `<textarea>`'s value, and the Ruby side
asserts **on what `FakeServiceProxy` received**, never on the SDK's intent. Reverting `post` to
`FormData` produces, verbatim:

```
-"+-+-+-+     +"+-+-+-+\r
-| | | |      +| | | |\r
-+-+-+-+      ++-+-+-+\r
```

and, in the sibling test, `"[object Object]"` where a nested hash belongs.

**Ten mutation checks, each RED on its own test and restored** (§15): `FormData` transport (2 RED,
above); `wrap_parameters` removed (the `"addon"` duplicate reappears); `read_timeout` dropped at the
controller (90 → 30, 120 → 30); the clamp removed (`9999` served); `.to_i` in `max_read_timeout`
(`"-10"` becomes the cap); `read_timeout` hard-coded at the socket (**40 s elapsed against a 1 s
argument**); `Registry` coercing instead of filtering (`"90"`, `0`, `-5`, `12.5` all honoured);
`service.url` bypassing the shared builder (`name=no-error path=no-error` — traversal accepted, and
the space left unencoded); the abort clause removed (`plain=ServiceUnavailableError`); the abort
clause keyed on `err.name` (`plain=AbortError reasoned=ServiceUnavailableError` — precisely the
careful-caller failure the `signal.aborted` reading exists to avoid); and the signal not forwarded at
all (`plain=no-error`).

### Numbers

`bin/ci` **exit 0** — judged by exit code, not by reading output — all seven gates, 1 m 3.9 s on the
committed tree. **2265 runs / 8187 assertions / 0 failures / 0 errors / 9 skips, identical on all
three backend legs** (chunk 9.8 s, share 9.4 s, s3 9.4 s); system **81 runs / 490 assertions**
(29.0 s). **+23 tests** over `origin/main` at `516b724` — 17 server
(6 `registry_test`, 6 `service_proxy_test`, 5 `addons_controller_test`) and 6 system
(`addon_sdk_test`), none removed.

### What this leaves for the bundles repo — not changed here

Three published workarounds can now go, and naming them is the point of having written them down:
`addons/boxes/preview.js`'s `generateSvg` raw `fetch` (its whole `STILL A RAW fetch` block, ~30 lines
of comment plus the `fetch`/CSRF/`ctx` threading) becomes `host.service.post(..., { signal })`; and
`addons/boxes/gallery.js`'s `img.src = \`${ctx.serviceUrl}boxes/sample/…\`` becomes
`host.service.url("boxes", \`sample/${generator.key}\`)`. Both bundles keep working unchanged in the
meantime — nothing here is a breaking change — so the migration is a follow-up PR in
`chaim354/tinkerex-addons`, not a coupled release. **Until it lands, no published bundle exercises
the JSON transport in production**; the hermetic fixture is what covers it.

### Follow-up, same arc: the workarounds retired, and a false green caught by mutating the test that found it (branch `claude/boxes-drop-workarounds`)

The follow-up above, landed as a **lockstep pair** — `chaim354/tinkerex-addons`
`claude/boxes-drop-workarounds` and this branch, which mirrors the finished bundle into
`test/fixtures/addons/boxes/`. Both workarounds are gone from `boxes` **and** `boxes-next` (the two
are byte-identical and stay so; `diff -rq` across all three trees is empty). Net **−9 lines** in the
bundle: a ~30-line gap comment and a hand-rolled `fetch` out, an SDK call and a small
`sidecarMessage` helper in. The `ctx` threading that existed only to feed them went too —
`mountPreview` and `mountGallery` now take no `ctx` at all, and `buildCard` no longer forwards one.

**`tray_layout_test.rb` was the point of the exercise and it is green.** It drives the real published
bundle through a real browser and asserts on **what the proxy received** — so with `preview.js` back
on `host.service.post`, the pass is the end-to-end proof that PR 6's JSON transport preserves an
LF-clean `<textarea>` through a **published bundle**, not only through the hermetic `sdk-fixture`.
That closes the caveat the paragraph above ends on. The other four boxes system tests
(`box_save_folder`, `box_sections`, `plan_export`, `tray_top_view`) stay green.

**One assertion in this repo went from missing to real, and the first version of it was a false
green.** Nothing anywhere asserted that a sidecar's own prose reaches the user — the whole reason
`ServiceError` carries RAW TEXT (§14c) — and the rewrite changed exactly how it is extracted: the old
code branched on the response's `Content-Type` header, the new one parses the text out of the thrown
`ServiceError`. Both spellings render an identical preview on the happy path. So
`box_sections_test.rb` gained "a sidecar's refusal reaches the user in the sidecar's own words",
stubbing `/generate` to a 422 carrying boxes.py's actual complaint. **Written with `text:`, it passed
with the JSON rung deleted** — Capybara's `text:` is a SUBSTRING match and the unparsed body
`{"error":"traylayout requires …"}` *contains* the sentence, so a bundle dumping the raw blob into
the panel satisfied it. `exact_text:` is what makes it an assertion; the mutation then failed with
the blob quoted verbatim. That is this repo's dominant failure mode caught inside the test written
to prevent it — recorded here because a substring matcher will look harmless to the next reader too.

Two mutation checks, each RED and restored: the JSON rung dropped from `sidecarMessage` (RED on the
new test, panel showing `{"error":"…"}`); and `gallery.js` calling
`host.service.url("boxes", generator.key)` without the `sample/` segment — RED across **ten**
assertions in `box_sections_test` and `tray_top_view_test`, via `assert_no_console_errors`, because
the mis-built URL 404s outside the `SAMPLE_404` ignore pattern. The second is worth knowing: the
gallery's `service.url` call site is covered, and covered by accident of the console guard rather
than by anything naming it.

`bin/ci` **exit 0** — judged by exit code — all seven gates, 51.3 s. **2265 runs / 8187 assertions /
0 failures / 0 errors / 9 skips, identical on chunk, share and s3** (8.6 s / 7.8 s / 8.4 s); system
**82 runs / 494 assertions** (20.2 s). **+1 test** over `origin/main` at `b19efeb`, none removed —
the server legs are unchanged, because a bundle that lives in `test/fixtures/` is only ever exercised
by a browser. `bin/check-fixture-drift` in the addons repo **fails until this PR merges**, by design:
it compares against the sibling checkout, which is on `main` and does not carry the new fixture. That
is the gate working, not something to route around, and `ALLOW_FIXTURE_DRIFT=1` is not the answer.

## 2026-08-10: the reserved-name guard three web doors never had (branch `claude/reserved-name-door-guard`)

**The ask** was one recorded divergence, carried over from PR #163 which was scoped to comments and
deliberately did not fix it: an addon save (`POST /tools/:key`) answered differently per
`LIBRARY_BACKEND` for reserved output filenames. Probed one save per name, through the real door,
before any change:

| name | chunk | share | s3 |
|---|---|---|---|
| `ok.txt` | 302 | 302 | 302 |
| `.DS_Store` `._x` `__MACOSX` `.Trashes` root `.trash` | **302** | 422 | 422 |
| `.maker-tmp-x` | **302** | 422 | **302** |

On share/s3 the port's `observable!` raises `FileLayer::NotFound` → the controller's `rescue_from` →
422. Chunk never calls the port at all (`Maker::Addons::LibraryOutput#write_chunk` drives
`Sync::Commit` directly), so there was no guard anywhere on the path and the file became a live node
bound for the changelog and every device mount. §14a's one-condition-two-answers, with the product's
**main** deployment on the wrong side.

### It was three doors, and the reported one was the least bad

Probing the sibling doors first — rather than fixing the reported one and moving on — turned up two
more instances and one that is strictly worse than the bug that started this:

- **`LibraryBrowseController#create_folder`** — same shape, `201` and a live **dir** node on chunk
  for every reserved name, including a `.trash` **directory at the library root**. That is the case
  `FileLayer::Share#observable!` documents as wedging *every delete in the library*, permanently,
  needing someone to remove the folder on the NAS by hand.
- **`FilesController#begin_upload`** — had **neither** guard. Not the reserved check, and not even
  the `valid_leaf_name?` traversal check that §14c records as closed at the addon door. Driven
  through the real two-phase flow: `begin=200`, `finalize=200`, and a live node named
  `"../../escape.txt"` in the changelog. It is `syncable`-gated, so it exists **only** on chunk —
  there is no share/s3 leg whose port `leaf!` would have refused it and made the divergence visible.
  Nothing cross-backend could ever have caught this one.

All three now ask the same two questions in the same breath: `Maker::MoveNode.valid_leaf_name?`
(syntax) then the new `Library::ReservedNames.reserved?` (the library's own namespace).

### The one real design choice: the union, not the intersection

`FileLayer::S3#observable!` deliberately omits `Scanner::TEMP_PREFIX` — that adapter writes no temp
keys, so a `.maker-tmp-x` object genuinely *is* observable in its store, and that comment stays true
and untouched. A door cannot know which backend is deployed, so it had two options: refuse everything
*any* adapter would refuse (union), or only what *all* would (intersection). The intersection leaves
`.maker-tmp-x` at chunk 302 / share 422 / s3 302 — the reported bug narrowed rather than closed, the
same divergence with the sign flipped. So: the union, and a name accepted at the door is accepted by
whichever adapter is actually deployed. The cost is that an addon may not name its output with this
app's own internal temp-file prefix.

### Deliberately NOT folded into `valid_leaf_name?`

Folding would have been one call per door instead of two, and it was the first instinct. It is wrong:
`valid_leaf_name?` is also called by `Maker::MoveNode#call`, which validates `new_name.presence ||
node.name` — a name that usually **already exists**. On chunk, `.DS_Store` nodes are a legitimate and
common artifact, because a real macOS device syncing its mount pushes them through
`Sync::Commit#finalize` (the sync protocol, §6, where the client is authoritative — not a web door).
Folding would therefore make a population the product creates *by design* permanently unmovable, in
order to close a hole about **minting** a new name. Renaming stays available either way.

### A wrong message that had been visible the whole time

One arm of this was never silent. A reserved name reached `Tools::AddonsController`'s
`rescue_from FileLayer::NotFound`, whose message at this branch point was **"That destination folder
no longer exists."** — asserted about a perfectly good folder, for a save refused on its *filename*.
That handler's own comment claimed the arm could only mean a missing destination folder; it was
incomplete, and is only now true. Corrected in place.

**Merge note (`main` @ `d0175d2`).** PR #163 reached the same handler independently from the other
side, and its correction is the stronger one: the "missing destination folder" cause it named cannot
happen *at all*, because `chosen_parent_node_id` resolves a stale or foreign id to `nil` = the library
root before any port call. Its rewritten message ("Your library refused that write. Rename the output
if it is named like a system file, or try again.") is what survives the merge — this branch changed
only the comment above it, so there was no behaviour to reconcile. Putting the two together: the
reserved-name cause is now refused at the door by `#parse_files`, and the arm's **one** remaining
cause is the TOCTOU — a destination folder tombstoned between `chosen_parent_node_id`'s lookup and
the port write. The message is left naming the reserved-name cause as well, deliberately wider than
the arm: trimming a user-facing sentence on the strength of an unreachability argument is what §14e
says to probe rather than trust.

### Verification

- **Measured on the merged tree**, `main` @ `d0175d2` merged in — those are the numbers below,
  because that is what ships. `bin/ci` bare, **all seven gates, exit 0** (54.22 s): style **519
  files / 0 offenses**, gem audit **no vulnerabilities**, importmap audit and Brakeman clean. The
  three backend legs are **identical** — **2248 runs, 8152 assertions, 0 failures, 0 errors, 9
  skips**, against `main`'s **2234 / 8016**: a delta of exactly the **+14** tests this branch adds
  and no other movement. System (real browser) **76 runs, 470 assertions, 0 failures**, unchanged
  from `main` — this branch adds no system test.
- At the branch point the same three legs read **2191 runs, 7947 assertions** (2177 before,
  +14 tests). Per this file's own header, those are not a chain: take a baseline by running the
  merge-base, not by subtracting entries.
- **`system-test` FLAKED ONCE ON THE RUNNER after this merge, and the card-click fix does not cover
  the shape it took** — reported rather than hidden, as that entry asks. Run 31458009152 (seed
  52317) failed `BoxSectionsTest#test_a_table-of-contents_entry_opens_the_section_it_points_at…`
  with **`expected to find css "#box-section-tray" but there were no matches`**; re-run of the same
  job on the same commit **passed**, and the suite passed twice locally on this tree (76/470, 0
  failures) both times. Note the failing selector: the section element was **absent**, not moved, so
  this is not the pointer race `settle_addon_cards` absorbs — it is the *other* flake that entry
  names, "~20 ESM modules and two fetches honestly take longer than 2s", hitting a test that never
  goes through `open_addon_card` because it clicks a `<summary>` rather than a card, and so gets
  Capybara's bare 2 s rather than `SETTLE_TIMEOUT`. The fix, if it recurs, is to give the
  section-level entry points the same waited helper the card-level ones got, not a longer sleep.
- **Every guard mutation-checked** (§15), and each mutation reverted after. Nine mutations: the five
  arms of `ReservedNames.reserved?` (drop trash / make it a prefix instead of exact / drop temp /
  drop clutter / drop the non-String guard) each turn exactly their own row red; dropping the
  predicate from each of the three doors reddens that door's case and no other; and at
  `begin_upload` the two guards were mutated **independently** to confirm they fail *different*
  tests — `valid_leaf_name?` the traversal case, `ReservedNames` the reserved case — so neither is
  riding on the other.
- The delegation to `Library::OsClutter` is asserted by **stubbing OsClutter false and watching
  `.DS_Store` become writable**, not by reading the implementation — a private copy of the names
  would pass a value-based test and then drift the day OsClutter grows an entry.
- Near-miss positive controls at every door (`.trashcan.svg`, `.trashcan`), so a guard widened from
  exact-match to prefix-match cannot pass. `begin_upload`'s runs the **whole** two-phase flow.

### Left open, on purpose

- **`Maker::MoveNode#call` still permits a move to a reserved name on chunk** while share/s3 refuse
  it in `port_move`. Same divergence, different verb — and the `.DS_Store`-from-the-mount argument
  above is exactly why it is not a copy-paste of this fix. Deciding it needs a product call on what
  should happen to the reserved-named nodes a device mount legitimately creates.
- **A device push (`Sync::Commit#finalize`) is untouched**, and should be: that is the sync protocol,
  where the client is authoritative, not a web door. It is also how `.DS_Store` nodes legitimately
  arrive.

### Found in review of this branch, PROBED not argued — four residuals it does not close

The three doors above are the three that MINT a name on chunk. A review pass drove the remaining
write doors with a reserved name and found four more answers to the same condition. None is a
regression from this branch; all four are pre-existing and none is fixed here. Recorded so the next
reader does not have to rediscover them, per §14e's *"a stale open-list is worse than none"*.

- **`Projects::UploadsController#create` is an uncaught 500 on share/s3.** It rescues
  `UnsupportedOperation` and `FetchError` but not `NotFound`, and `ApplicationController` has no
  `rescue_from` at all — so `observable!` raising for `Projects/<slug>/.DS_Store` propagates.
  Probed: `FileLayer::NotFound: "Projects/probe-p/.DS_Store" is a reserved path…`, uncaught. The
  door is `require_port_writable!`-gated, so it does not exist on chunk. **The cheapest fix is the
  missing `rescue_from`, not another `ReservedNames` call.**
- **`FilesController#create` still answers "File not found."** for a reserved filename on share/s3
  — `observable!` → `NotFound` → the class-level rescue → `302` + that flash. Probed: `status=302
  flash="File not found."`. That is the same wrong-message defect this branch fixed at the addon
  door, still live at the app's main upload door, and it means the *upload* verb still has two
  answers across deployments: chunk `begin_upload` now 422s with a real reason, share/s3 302 to a
  flash about a file the user never asked about.
- **`ModelsController#ensure_folders` holds a FOURTH private spelling of the rule** —
  `segs.any? { |s| s.start_with?(".") }` — which is exactly the second copy `Library::ReservedNames`
  exists to prevent, and it has a real gap: `__MACOSX` has no leading dot. Probed with a forged
  `dirs` param (nothing else validates it): **chunk `201` + a live `__MACOSX` dir node; share `422
  invalid_path`**. The same divergence, at a door this branch did not touch. Real macOS zips do not
  reach it — the importer skips dot-prefixed leaves client-side and every `__MACOSX` entry is a
  `._` file — so the trigger is a forged request, not the ordinary import.
- **The door is now STRICTER than either adapter for a nested `.trash`.** `reserved?` tests a LEAF
  name, but both adapters anchor `TRASH_PREFIX` at the library ROOT on purpose — *"a nested
  `cad/.trash` is the user's own folder, is indexed, and is none of our business"*
  (`Share#observable!`). Probed: `POST /library/folders {name: ".trash", parent: cad}` is now `422`,
  while `FileLayer.current.mkdir(user, parent: cad, name: ".trash")` is still **allowed** by the
  adapter underneath it. Uniform across all three backends, so it breaks no §14a rule and it fails
  safe — but it contradicts an explicit adapter comment and was not a stated goal. A door that knew
  its parent's rel path could ask the adapters' actual question.

---

## 2026-08-10: audit A-M4 — a deleted supplier locked every row that pointed at it (branch `claude/maker-referential-integrity`)

`Maker::Supplier` had no `has_many` at all and `Maker::Location` had one only for its own
`children`, so `DELETE /v1/maker/suppliers/:id`, `locations/:id` and `inventory_items/:id` left
dangling ids behind. The dangling id was not the harm. `InventoryItem` and `BomLine` run their
`*_belongs_to_user` validations `if: <fk>.present?`, and a dangling id **is** present — so the
check ran, found nothing, and refused **every** subsequent save of that row. Renaming an item,
adjusting a min quantity, fixing a typo in a BOM line's notes: all rejected, permanently, with an
error naming a field the form need not even show. Confirmed by probe before any fix, on all three
referring columns.

**Blast radius** — four referring columns, one more than the finding named:
`maker_inventory_items.supplier_id` and `.location_id`, `maker_bom_lines.inventory_item_id`, and
`maker_bom_lines.supplier_id` (that last one is not in A-M4's text). Everything else already had
an answer: `InventoryItem`→`transactions` is `dependent: :delete_all`, `Location`→`children` is
`dependent: :nullify`. Two dangling pointers were found and deliberately left alone because
neither locks anything: `maker_bom_lines.node_id` after a node is reaped, and
`maker_inventory_transactions.project_id` after a project is destroyed — the latter is an
append-only ledger that no code may update anyway.

**`dependent: :nullify` is right for three of the four and WRONG for the fourth.** Nullifying
`BomLine#inventory_item_id` leaves the line with no target, so `exactly_one_target` refuses it —
the identical permanent lock, wearing a different error message. Measured: with the nullify-only
implementation, the unlock test fails with `a line must link exactly one of: inventory item,
design file, or free-text part`. `dependent: :destroy` is worse — a BOM records what a project
needs, and deleting a stock row is a statement about the shelf, not about the design. So
`InventoryItem#release_bom_lines` **converts the line to a free-text part**, copying the item's
name into `part_name` before dropping the pointer: a valid, editable line still reading "4 × M3
bolt", in a shape `resolved_target` already renders. The whole method is scoped to the owning user,
unlike the *association-level* `dependent: :nullify` on `Supplier`/`Location`, because it *writes*
this user's data into a row rather than only clearing a pointer — clearing can at worst repair an
illegal cross-tenant reference, copying would disclose one.

**The conversion carries the supplier too, which the first round dropped.** `maker_bom_lines` has
its own `supplier_id` and `resolved_target`'s free-text shape already renders
`supplier_id`/`supplier_name`, so leaving it nil discarded half of what makes a line orderable into
a column that was sitting there waiting for it (measured through the roll-up: before the destroy a
line rendered `{name, part_number, unit, quantity_cached}`, after it `{part_name, supplier_id: nil,
supplier_name: nil}`). Three qualifiers on the carry, each with its own mutation check: only onto
lines actually being **converted** (a line keeping its own design-file target is not becoming a
free-text part, and nothing renders a supplier for that shape); never over a supplier the line
**already names** (that one is the user's annotation about this line; the item's is a fallback);
and only if that supplier **still resolves**, because an item stranded by the pre-fix bug can
itself hold a dangling `supplier_id` and copying it across would hand the line
`supplier_belongs_to_user` failing on every save — this method's own bug, reintroduced on the row
it just rescued. **`part_number` is not carried: `maker_bom_lines` has no column for it.** The line
also loses the item's live stock figures, which is honest — there is no stock row any more.

**No DB foreign keys, decided rather than forgotten — and the recorded reason was half wrong.**
The SQLite measurement stands: `add_foreign_key ... on_delete: :nullify` over data that already
violates it is **ACCEPTED** at migration time and the violating row survives (re-probed directly —
`pragma_foreign_key_check` lists it afterwards). The *consequence* first recorded here — "then
raises `ActiveRecord::InvalidForeignKey` on the next write to the bad row" — **does not hold for
the ordinary path**, and the sentence that followed it was therefore false. SQLite re-checks a
child row only when the statement names a child key column, and Rails' partial UPDATE does not name
`supplier_id`; the save is refused earlier and identically to today, by `*_belongs_to_user` →
`RecordInvalid` → **422**, not 500. `InvalidForeignKey` appears only on a write that names the FK
column while skipping validations — measured on the same probe, `UPDATE ... SET supplier_id = 999`
errors while `SET supplier_id = NULL` does not — and this app has no such write for these columns.

**What actually blocks the FKs is the other half:** Postgres validates existing rows on
`ADD CONSTRAINT` and errors, so one migration aborts the managed deploy (reasoned, not measured —
no local libpq). Two things the first pass did not mention, in fairness to whoever picks this up:
`NOT VALID` is the standard opt-out from that validation, and the violating rows could be cleared
by a two-line `UPDATE ... SET fk = NULL WHERE fk NOT IN (SELECT id FROM ...)` prelude **in the same
migration** rather than a separate pass. So the deferral is a judgement about cost and timing, not
an impossibility. **The decision still stands**: all three deletes go through Active Record
(`user.destroy` plus the three v1 controllers — no raw-SQL or `delete_all` path exists for these
models, independently re-verified), and the harm is an Active Record validation that no DB
constraint can lift, so the FKs are defence-in-depth rather than the fix. Tracked as ledger row 24
in `docs/AUDIT-2026-08-03.md` — and note a cleanup pass cannot restore a deleted item's name to a
BOM line, which is precisely why the conversion has to happen at destroy time.

**No backfill migration either — recoverable by the owner, but the cost differs by column.** On
`maker_inventory_items.supplier_id` and `.location_id` it is free: the validations are guarded on
the id being *present*, so `PATCH { supplier_id: null }` skips the check and saves. On
`maker_bom_lines.inventory_item_id` it is **not** — clearing the pointer alone leaves the line with
zero targets, so `PATCH { inventory_item_id: null }` is itself a 422 and the owner must supply a
replacement target in the same request, having remembered the deleted item's name themselves. That
is exactly the work `release_bom_lines` now does for them and cannot do retroactively. Both shapes
are pinned by tests that plant the pre-fix state with `update_columns` and drive the real PATCHes.

**Verification.** Bare `bin/ci` green by exit code, all seven gates; the three test legs report
identical counts — **2200 runs / 7883 assertions / 0 failures / 0 errors / 9 skips** on each of
chunk, share and s3, plus 71 system runs / 444 assertions. (Re-measured after `origin/main` was
merged in at `945d8b1`: the unit legs are unchanged, and the system count is 70/439 + the one
thumbnail-settling guard the entry below added.) **Twelve mutation checks** (§15),
every one RED. Seven from the first round: dropping each of the three `dependent: :nullify`s;
dropping `before_destroy :release_bom_lines`; reducing `release_bom_lines` to a plain nullify;
renaming every line instead of only the targetless ones; and dropping the per-user scope, which
needed a *planted* cross-tenant row to be catchable at all, since the validations make one
unreachable. Five more from the review round: narrowing the targetless filter to `nil`-only (RED on
both blank arms, with exactly the A-M4 message — `Validation failed: a line must link exactly one
of: inventory item, design file, or free-text part`); dropping the supplier carry; dropping its
no-clobber clause; swapping its `Supplier.exists?` guard for a bare `supplier_id.present?`; and
widening it from the converted lines to every line the item touched.

**One of those five started GREEN, which is the part worth recording.** The "widen it to every
line" mutation was invisible until the test that should have caught it grew a second, *convertible*
BOM line beside the design-file one — with nothing convertible, `converting.any?` is false and the
entire write block is skipped, so the mutated statement never executed. The qualifier was written,
commented and untested. Found by mutation-checking, not by reading: exactly the failure shape §15
names, in the round whose whole job was closing another instance of it.

---

## 2026-08-10: `system-test` was red on main because a gallery card moved out from under the click (branch `claude/system-test-card-click-race`)

**The symptom.** `system-test` had been red on main since PR #160 merged (run 31188332739, commit
096e581) — every other gate green on that run, so every new PR inherited a failure it did not cause.
PR #164 hit it too (run 31448985204) with *different* tests failing in the same cluster, which is the
signature of a flake rather than a break. Both runs failed in the boxes addon's tray top view:

| run | test | failure |
|---|---|---|
| 31188332739 (main) | `TrayTopViewTest#test_a_tray_generator_draws_its_compartments_without_being_asked` | no `.box-topview svg` |
| 31448985204 (#164) | `…#test_removing_a_wall_from_the_layout_merges_the_two_compartments_it_separated` | no `[data-topview="summary"]` |

Both suites passed locally, every time, on a quiet Mac.

**The screenshot was the whole diagnosis, and it took one look.** `gh run download 31188332739 -n
screenshots` shows the **gallery** — filter box, four cards, "No saved boxes yet." — not the editor
the test had clicked into. `mountEditor` replaces the DOM on its *first* line, synchronously, so a
click that reached `onOpenGenerator` could not possibly leave the gallery standing. **The click never
fired the handler.** Nothing raised, because a click that lands on nothing is not an error.

**Root cause: the cards collapse under the pointer.** Every card carries an
`<img class="addon-thumb">` fetching a sample photo through the sidecar proxy, and
`.addon-thumb.is-missing { display: none }` (`application.css:195`) removes a **120px** box plus its
6px flex gap the moment one fails. `FakeBoxesSidecar` registers a sample for ABox alone — and those
bytes are deliberately a truncated JPEG — so **all four** thumbs fire `error`, and every card below
each one jumps up ~126px. Measured in the browser rather than argued: **TrayLayout's top goes
1002px → 624px, a 378px shift**, because it is the last of the four and inherits all three collapses.

Chromedriver's click computes **one** coordinate and then dispatches pointerMove/pointerDown at it. A
thumbnail resolving inside that window moves the card away and the click lands in the dead space
below the shrunken grid. That is why the two failures were the tests opening the **last** card, why
ABox's and FrontPanel's tests never failed, why load made it appear (four real HTTP round-trips
through a 4-thread Puma pool), and why a quiet dev Mac never saw it: there, the thumbs 404 before the
click.

Reproduced deterministically before anything was changed — collapsing the thumbs on `pointermove`
*is* that window — and the probe printed `editor opened after the click? false`, `still on the
gallery? true`.

**The fix is one helper, not six.** `find(".addon-card", text: key).click` was hand-rolled in **six**
places across five files; all six now call `WebHelpers#open_addon_card`, which waits on
`settle_addon_cards` first — every thumbnail request **ended** (`complete` is true for a 404 and for
a decode failure, which is the point) *and* two consecutive reads of every card's position agreeing.
A polled condition, not a slept interval: the shift is caused by network responses whose timing is
exactly what nobody can guess.

Its budget is `SETTLE_TIMEOUT = 10`, not Capybara's 2s, because requiring the cards to exist also
absorbs the *other* flake this page produces under load — `Unable to find css '.addon-card'`,
observed locally in `PlanExportTest` — where ~20 ESM modules and two fetches honestly take longer
than 2s. It costs nothing on a quiet box; the loop returns on its second poll.

**Not fixed, on purpose:** the layout shift itself is real product jank — a fast user can miss a card
too. The bundle that renders the cards lives in `chaim354/tinkerex-addons` and the copy here is a
**verbatim snapshot** (see `box_sections_test.rb`'s header), so fixing it here would create exactly
the drift that file's trade-off is written about. The host-side alternative — reserving the 120px
instead of removing it — leaves a permanent blank in every card on a gallery where most generators
have no photo, which is a visual regression, not a fix. Flagged as a product decision.

### The guard, and why it asserts the contract rather than the race

`box_sections_test.rb`'s "the gallery is not clicked until its thumbnails have stopped moving" holds
the page in the state the failure needs — `SlowSamples`, a `FakeServiceProxy` subclass that delays
**only** `sample/*` by 0.3s, so the cards render and become clickable while the thumbs are still in
flight. `FakeBoxesSidecar.install!` grew a `proxy:` kwarg for this rather than a second copy of its
four registrations.

It asserts the **property that closes the window** (no thumbnail still loading; re-asserting the
collapse moves nothing), not the race's outcome. A test that clicked and hoped would be a coin flip
in *both* directions — green with the bug present often enough to prove nothing, which is this repo's
recorded failure shape (§15). An earlier draft did exactly that, arming the collapse on `pointermove`
*after* settling, and it would have passed with or without the fix: a fake guard. Discarded.

**Mutation-checked (§15):** dropped the `i.complete` clause from `settle_addon_cards`' probe → **red**
("4 thumbnails were still loading — the cards can still collapse under the click", `Expected: 0 /
Actual: 4`); restored → green.

### Verification

- `bin/ci` bare, **exit 0**: style 513 files/0 offenses, scan 0 errors, and the three test legs
  **identical** — `2191 runs, 7947 assertions, 0 failures, 0 errors, 9 skips` on `test`, `test-share`
  and `test-s3`. System: **71 runs, 444 assertions, 0 failures** (was 70/439 — one new guard, +5).
- **Stressed under real contention**, because a green suite on a quiet box is what was *already* true
  before the fix and proves nothing (§14e): with all 10 cores saturated, the four boxes system files
  ran 3× back to back, `38 runs, 205 assertions, 0 failures` every time.
- Not verified: that CI itself is green — only the macOS runner is registered, so this lands and the
  next run on `main` is the actual proof.

---

## 2026-08-07: the manifest learns to describe itself — and a `states_key` claim now needs the other addon's consent (branch `claude/addon-api-pr2-manifest-metadata`)

**PR 2 of the Addon API v1 arc**, stacked on PR 1 (`claude/todo-list-review-6beccc`) — row 2 of
`docs/superpowers/specs/2026-08-07-addon-api-v1-design.md` §12, amended in this branch per §15's
close-out rule. PR 1 gave the host a surface an addon can call; this one gives the **manifest** a
vocabulary for describing what it is and what it wants, and turns the one thing a manifest could
already grant itself into something the other side has to agree to.

**Shipped, in seven commits:**

- **`Maker::Addons::Permissions`** — the permission vocabulary with one definition. Four table
  entries (`library:read`, `library:write`, `state`, `project:read`), `service:<name>` by pattern,
  and **an unknown name falls back to its own raw spelling** rather than rendering blank: a card
  that silently understates what an addon asked for is worse than one showing a developer-facing
  string. Deliberately **not** the same vocabulary as `Host::CAPABILITIES` — a capability is what
  the host *can* do, a permission is what an addon *says* it wants, and they already diverge
  (`state` / `project:read` here against `state:list` / `state:crud` / `project:current` there).
- **Seven metadata keys parsed onto the `Addon`** — `version`, `author`, `license`, `homepage`,
  `permissions`, `min_host`, `shares_states_with` — all optional, all **degrading** rather than
  raising, which is the rule `layout` already followed: a manifest comes from a source this process
  does not control. Two degradations are worth knowing because they are silent: a `permissions`
  entry that is not a hash with a present `name` is **dropped** (the bare-string form
  `["library:write"]` renders nothing at all), and a non-integer `min_host` is **ignored, not
  coerced** — `"2".to_i` is 2, which would honour a value a JSON manifest should not contain, so
  refusing it leaves the addon *available*, the failure direction an operator can diagnose.
- **`min_host` makes `available?` a real answer.** It was hardcoded `true` for as long as
  "registered" meant "fetchable". A too-new addon is still **built** and still **listed**, greyed
  out, with `unavailable_reason` naming both levels — the gallery's old hardcoded "Not configured on
  this deployment" pointed an operator at env vars that were fine. Skipping it instead is the easy
  wrong answer: an addon that silently never appears reads as a broken deploy, not as a version
  floor.
- **The `states_key` mutual constraint — audit §2.1, closed.** `Registry.states_key_permitted?`
  refuses a `states_key` pointing at another addon unless that addon names the claimant back in
  `shares_states_with`. It lives in `Registry.all`, **not `build`**, because it is a question about a
  **pair** of manifests and `build` is handed one. Three refusals, all skipping the addon rather
  than raising: no reciprocation; a target **absent from the index** (the permissive "no target, no
  harm" reading would let a typo reserve a namespace and collide the day the real addon shipped);
  and — the reviewer's own counterexample — a target that is present but **itself rejected by
  `build`**, since an entry the host rejects outright would otherwise confer a grant nobody can
  audit.
- **Permission display** on the gallery card (names, `to_sentence`) and on the addon's own page
  (names plus each entry's optional `reasoning`).

**Why the refusal SKIPS rather than greying out — the opposite choice from `min_host`, one method
away.** `Tools::AddonsController` never gates on `available?` at all; its only consumers are three
lines in `app/views/tools/home/index.html.erb`. So a listed-but-unavailable addon is still
`Registry.find`-able, still resolves through `load_addon`, and still serves `@addon.states_key` from
`#states` and `#create` — greying an unreciprocated claim out would **look closed while leaving the
hole open**. The two decisions must not be harmonised, and both are now recorded in §14c saying so.

**What audit §2.1 closes, exactly, and what it does not.** A manifest can no longer, **by
declaration alone**, redirect its own saves and state reads into another addon's namespace. That is
the whole of it. `states_key` was never an inter-addon *runtime* boundary and this does not make it
one: a bundle runs same-origin in the authenticated session and can call
`/tools/<other-key>/states` directly — the controller resolves whatever key is in the URL, no
`states_key` involved. The audit's **other** §2.1 ("a malicious or compromised addon bundle owns the
account") states that same fact inside its own evidence and **remains open**. A pre-existing comment
in `#states` and its `routes.rb` counterpart claimed the `addon_key` scope was "the only thing
standing between one addon's saves and another's"; that was false when written, and is now corrected
to describe what it is — a data-scoping rule.

**Closing the constraint broke four pre-existing tests, and that is the evidence it has teeth.**
Three in `addons_controller_test.rb` and one in `registry_test.rb` were asserting the *old
permissive behaviour* — a manifest unilaterally claiming another addon's `states_key` with nothing
reciprocating — so `Registry.find` began returning nil and the three controller tests turned into
404s. A constraint that could be added without a single existing assertion noticing would be a
constraint over a case nothing exercised. The fix adds a **`RECIPROCATING_MANIFEST` beside**
`MANIFEST` rather than editing `MANIFEST` itself, so the "FIXTURE_KEY declares no `states_key`
anywhere in this suite" guarantee its comment makes stays true for that file's other 46 tests — and
it was made in **its own commit (`da75f34`)**, out of the states_key task's assigned file scope, so
the collateral stays isolated and revertible. The new constraint's own five tests were
mutation-checked: reverting only the `&& build(target)` clause turned **exactly one** of them red
while the other four stayed green.

**THE WHOLE-BRANCH REVIEW CAUGHT A FALSE CLAIM THIS BRANCH INTRODUCED — in a comment written to
*correct* something, which is the failure mode a correction is most prone to.** `0faffe1` justified
the `build(target)` clause with a transitive example: *"A claims B, B claims C unreciprocated, C is
malformed: A would still be admitted, pointed at a B that nobody agreed was legitimate."* Probed
against that exact index: **`a` IS admitted with `states_key="b"`, and `b` is absent from
`Registry.all`** — so the clause does not do what its own example said. The control case (target
*directly* malformed) is correctly refused, so the clause works; only the explanation was wrong. The
general principle stated alongside it was the wrong part: `build(target)` closes **one** of two ways
a target can be invisible, and the other — a target skipped by `states_key_permitted?` itself —
still confers a grant. **There is no functional consequence**, because that target still had to
write `shares_states_with`, so no addon ever gets a namespace whose owner did not consent. The claim
had propagated to **four** places (the comment, CLAUDE.md §14c, `docs/addon-api-v1.md` §2, this
entry); all four now state the residual plainly rather than deleting the sentence, because "this
closes the `build`-rejects case, and a target skipped by this same check still confers a grant,
harmlessly, because it consented" is more useful to the next reader than silence. **Consent, not
gallery visibility, is the property being enforced** — that sentence is the invariant the four
copies had drifted away from.

**The one non-documentation item: the branch shipped visible UI with no styling.** `.addon-card`,
`.addon-desc`, `.addon-icon` and `.addon-title` all had rules; `.addon-permissions` had none. So the
card's permission line rendered at body **15px — larger than the 13px description above it** — and
the addon page's list was a bare `<ul>` with UA bullets and a 40px indent. One class serves two
elements (a `<span>` on the card, a `<ul>` on the page), so the rule is `.addon-permissions {
font-size: 13px }` plus a `ul.addon-permissions` list reset. **Checked in a real browser rather than
assumed**, since the system suite covers neither page: computed `font-size` is now 13px on both and
matches `.addon-desc` exactly, `list-style-type: none`, `padding-left: 0px`. That check also
confirmed the raw-name fallback end to end — an unknown `totally:unknown` renders as itself — and
that `reasoning` appears on the page and not on the card. The temporary test was deleted after it
reported, so the suite counts below are unchanged.

**Two smaller corrections from the same review.** The warn line for a refused claim fires **once per
`Registry.all`, i.e. once per request** — only `manifests` is cached, `.all` re-filters on every
call — not once per deploy as its comment claimed (measured: 5 calls, 5 lines, index cached). With
the unreciprocated `boxes-next` below still live in production that is one line per request until
the bundles repo lands its fix; the comment is corrected and the behaviour deliberately left alone.
And `docs/addon-api-v1.md`'s permission table is a **hand-maintained second copy** of
`Permissions::LABELS` with nothing keeping them in sync — named in the doc, with the code marked
authoritative, which is worth stating out loud on a branch whose selling point is that the
vocabulary has one definition. The mitigation is that these labels are cosmetic: nothing measures,
gates or decides anything from them.

**Permissions are DISPLAYED, NOT ENFORCED — a deliberate scope decision, recorded because the spec
said otherwise.** Spec §8.1 describes permissions as "checked server-side on every request"; what
shipped is the display half, and §8.1 now carries an as-built marker pointing at §12 row 2's scope
correction. Three reasons: the vocabulary is unfinished (`data:read:<addon>/<collection>` does not
exist until PR 4, so a check written now is a check PR 4 redesigns); **`service:<name>` would be a
second spelling of a check that already exists and already works** — `sidecar_url_for` refuses any
service the manifest's `services` key does not name, and a `permissions` check over the same
condition is §14a's one-condition-two-answers drift unless the two keys are reconciled first; and
§8.1's own next paragraph already concedes the check is not a security boundary, since a Ring 1
bundle runs same-origin and can call any endpoint the user can. A gate that *looks* like a boundary
and is not is this repo's dominant failure shape. The honest interim is a card the operator reads at
publish time — which is worth real money in a deployment where **republishing a bundle IS the
deploy**, Rails is never rebuilt, and there is no review step in between: the card is the one place
an addon that quietly starts asking for more becomes visible. `docs/addon-api-v1.md` §2 and §4 now
say all of this in those words, twice, because §4 is where an author goes looking for the boundary.

**The `assert_select` trap, recorded so the next person does not spend the same round on it.**
`assert_select "[attr=?]", /regex/` **does not regex-match** — rails-dom-testing's
`SubstitutionContext#matcher_for` interpolates a Regexp straight into the selector, so `[title=?]`
with `/Needs a newer…/` compiles to `[title="(?-mix:Needs a newer…)"]`, an exact-equality CSS
selector that can never match real text. Regex matching on an **attribute** needs the gem's own
`:match('attr', ?)` pseudo-class; `[attr*=?]` with a plain String is the simpler alternative.
(`text: /…/` is a different code path and does match — this is attributes only.) Verified directly
against rails-dom-testing **2.3.0**: `[title=?]` finds 0 elements where `:match('title', ?)` finds
1. It fails as a test that **can never go green** rather than as a false green — the better
direction, but only once you know why. Now in §14e, beside the other testing lessons, because it is
not an addon fact.

**Measured.** `bin/ci` green, **all seven gates, exit 0**. The three backend legs report
**identical** counts — **2211 runs, 7944 assertions, 0 failures, 0 errors, 9 skips** on chunk, share
and s3 alike. System (real browser): **75 runs, 466 assertions, 0 failures**.

Those are the numbers **after** the base branch was merged back in (merge `6b95ec6`, 2026-08-10,
which picked up the revision-aware backfill fix, the `/deploy` secrets doc fix and the `system-test`
card-click fix). Measured alone, before that merge, this branch was **2206 runs / 7923 assertions**
with system **74 / 461** — and the merge adds exactly **5** Rails-leg `test` blocks and **1** system
`test` block, which is precisely the 2206 → 2211 and 74 → 75 observed: two independent counts that
cross-check rather than one being read off the other. The pre-merge figure is what carries this
arc's own evidence — against PR 1's measured 2181 runs / 7867 assertions this branch adds **25
Rails-leg tests** and 56 assertions, matching the **25** `test` blocks its diff adds and the **0** it
removes. This PR still adds **no browser test**; the +1 there is the merged-in card-click guard.
(Per this file's own header the per-entry counts do not form a chain — the card-click arc's own
recorded 2191/7947 was measured off `main`, a different baseline, and is not comparable to these.)

**The one semantic conflict worth looking for in that merge — a card that grew a line of text under
a click helper that computes a coordinate — DOES NOT EXIST, and the reason is that there are two
different galleries both using `.addon-card`.** `WebHelpers#open_addon_card`/`settle_addon_cards`
guard the **bundle's own generator gallery**, built in JS by `test/fixtures/addons/boxes/gallery.js`
and reached only at `tools_addon_path("boxes")` — all six call sites visit that path and **no system
test visits `/tools` at all**. The permission line this branch adds is on the **host** gallery
(`app/views/tools/home/index.html.erb`), a page the browser tier never loads. Belt and braces: both
the card `<span>` and the addon page's `<ul>` are gated on `permissions.any?`, `build` defaults
`permissions` to `[]`, and **none of the three fixture manifests declares `permissions`** — so the
markup renders nowhere in the system suite even on the page those tests do load — a property this
branch's own `home_controller_test.rb` already pins ("a card with no declared permissions renders no
permission list at all"). `min_host` (default `0`) and `states_key_permitted?` (fixtures declare
neither key) likewise leave every fixture addon built and listed.

**And it is robust rather than lucky**, which is the part worth checking rather than assuming: even
if a fixture manifest *did* declare permissions, the `<ul>` is server-rendered above the mount point,
so its height is in the layout **before** the bundle mounts and before any thumbnail resolves — it is
a constant offset, not the LATE shift `settle_addon_cards` exists to absorb. `box_sections_test.rb`'s
guard asserts read-to-read **equality** of card positions, never pixel literals, so a constant offset
cannot break it either. The residual to watch is a different one: `open_addon_card` matches with
Capybara's substring `text:`, so a permission label that happened to contain a generator's name would
make `find(".addon-card", text: key)` ambiguous the day a system test does visit `/tools`.

**A DEPLOY PREREQUISITE IN THE OTHER REPO, FOUND WHILE WRITING THIS ENTRY — `boxes-next` WILL
DISAPPEAR FROM `/tools` UNLESS THE BUNDLES REPO IS FIXED FIRST.** The close-out brief for this task
asserted that no published manifest declares any of the new keys, so nothing here is exercised
against a real bundle. That is true of the seven **new** keys and **false of the constraint**:
`chaim354/tinkerex-addons`, on `main` since `4862f48` (2026-08-03, *"boxes-next: declare
`states_key: "boxes"` so the trial shares the legacy saved-box rail"*), publishes three addons, and
`boxes-next` declares `states_key: "boxes"` while `boxes` declares **no `shares_states_with`**. That
is exactly the unreciprocated claim `states_key_permitted?` now refuses — so deploying this branch
**silently drops `boxes-next` from the gallery**, log line only, which is the failure mode §14c
records as the price of skipping rather than greying out. The fix is one line **in the bundles
repo** — `boxes` adds `"shares_states_with": ["boxes-next"]` — and it must land **before or with**
the Rails deploy, not after. Deliberately not made here: that is a different repo, a different
deploy, and publishing its image is its own release. **Do not deploy this branch until it is done.**

**What this does NOT prove, stated plainly.** **No published manifest declares any of the seven new
keys** (`version`, `author`, `license`, `homepage`, `permissions`, `min_host`,
`shares_states_with`) — verified by parsing `addons/manifests.json` on the bundles repo's `main` —
so the metadata half is exercised only by stubbed `Maker::Addons::Source` fixtures, never by a real
bundle. Permissions are displayed and not enforced; `states_key` is not an inter-addon runtime
boundary and this PR does not make it one. Nothing here has been deployed. The four purely
descriptive keys are parsed onto the `Addon` and **rendered on no page at all** — documented as such
rather than advertised.

**Invariants recorded** in CLAUDE.md — six in §14c (the mutual `states_key` declaration and its
valid-target requirement; skip-not-grey-out and why it is deliberately unlike `min_host`;
`available?` no longer hardcoded and the gallery showing a reason; non-integer `min_host` ignored not
coerced; displayed-not-enforced for permissions *and* for `states_key`; one definition for the
permission vocabulary with a raw-name fallback) and **one in §14e** for the `assert_select` attribute
trap, which belongs with the testing lessons rather than with the addons.

---

## 2026-08-07: the service name gets the guard its sibling already had, and a rescue comment stops lying (branch `claude/addon-sdk-service-name-guard`)

**The two follow-ups the SDK PR (the entry below) recorded as open and left out of scope.** Written as
a stack on `claude/todo-list-review-6beccc`; that branch merged as **PR #161** while this one was in
review, so **this PR now targets `main`** and carries a merge of it — which brings PR #165's
referential-integrity fixes and PR #162's manifest metadata along too, both having landed in the same
window.

**1. `serviceName` is now rejected the way `path` beside it already was.** `service.get`/`post` build
ONE URL out of TWO arguments and only the second was guarded, so `host.service.get("../../evil", "x")`
built `/tools/<key>/service/../../evil/x` — which the **browser's own URL parser normalizes to
`/tools/evil/x` before the request is sent** (verified against WHATWG normalization, not assumed), so
`sidecar_url_for`'s refusal was never asked and the call misrouted silently rather than failing.
`encodeServiceName` rejects `""`, `"."`, `".."` and **any `/`**, then encodes.

The `/` is the only real design choice, and it is **rejected outright rather than split into segments**:
`:service` is one Rails segment matched VERBATIM against the manifest's `services` list, so `"a/b"`
cannot name a service on any host; splitting would normalize a structural error (§14a's `key_for` rule)
and would leave the contract incoherent — `"../.."` refused while `"a/b"` is accepted, for a value that
is one segment by definition. Measured rather than assumed: `encodeURIComponent` already defuses `\`,
`#`, `?` and `%`, and only `.`, `..` and `""` survive it — which is exactly the clause list.

**Proven in a browser, because nothing else can see it.** The normalization is the URL parser's, so a
request test would be asserting about a URL the browser never sends. A fifth test in
`test/system/addon_sdk_test.rb` clicks a fixture button that calls both the bad name and the bad path
and renders `class:code` for each. **Mutation-checked:** reverting `encodeServiceName(serviceName)` to
`${serviceName}` at both call sites turns it red — *"expected … exact text
name=AddonError:invalid_argument path=AddonError:invalid_argument … Also found
`name=ServiceError:service_error path=AddonError:invalid_argument`"* — so the assertion isolates the
half that regressed instead of merely noticing that something did.

**2. The `rescue_from FileLayer::NotFound` comment described a condition that cannot happen.** It read
*"NotFound here means the save named a destination folder that no longer exists"*. It cannot:
`chosen_parent_node_id` resolves an unknown, stale or foreign `parent_node_id` to `nil` = the library
ROOT **before any port call**, so that save answers **302 and succeeds**, probed on all three backends
(the node lands with `parent_node_id: nil`). `docs/addon-api-v1.md` §5 was corrected for this same
false claim in the previous PR; the code comment was not.

**What actually reaches the arm** — found by probing every candidate through the real door, one save
per name, rather than by reading the adapters:

| output name | chunk | share | s3 |
|---|---|---|---|
| `ok.txt` | 302 | 302 | 302 |
| `.DS_Store`, `._x`, `__MACOSX`, `.Trashes`, root `.trash` | **302** | **422 `not_found`** | **422 `not_found`** |
| `.maker-tmp-x` | **302** | **422 `not_found`** | **302** |

It is `observable!`, §14b's skip-list rule. `#parse_files` vets names with
`Maker::MoveNode.valid_leaf_name?`, which refuses `/`, `\`, NUL, `.`, `..` and over-long names — but
every name above is a perfectly good *leaf*. The `.maker-tmp-x` split is deliberate and documented in
place: `S3#observable!` omits `TEMP_PREFIX` because that adapter writes no temp keys.

**So the arm is reachable from `#create`, on share/s3 only.** Chunk cannot reach it —
`LibraryOutput#write_chunk` never calls the port — and `#show`/`#asset`/`#service`/`#states` never
touch `FileLayer` at all, so the class-level arm covers those four vacuously. Every other `NotFound`
inside `#write` is closed upstream: `leaf!` by the stricter `valid_leaf_name?`, the path-escape guard
by `leaf!` in turn, `read_capped!` by `MAX_FILE_BYTES` (4 MB) sitting far under `FileLayer::MAX_BYTES`
(256 MB), and *"parent is not a live directory"* by `chosen_parent_node_id` having just resolved that
id — which leaves it reachable only as a **TOCTOU**, a folder tombstoned between the two lookups.
Nothing after the write reaches it either: `attach_addon_files_to_current_project` and
`intake_project_folder` both rescue `StandardError`, and `Maker::ProjectIntake#place` already rescues
`FileLayer::NotFound` into a `:not_found` skip.

**The one behaviour change, called out because the brief asked for none.** The response *message* was
false in the same way the comment was — *"That destination folder no longer exists."* for a file named
`.DS_Store` — so it now names both surviving causes and prescribes for each, since they want opposite
remedies (renaming fixes the name and does nothing for the race; retrying fixes the race and never the
name). Nothing asserted the old string. **The silent-write-to-root is untouched**, as instructed: that
is a product decision, and `docs/addon-api-v1.md` §5 already documents it for authors.

**Left open on purpose: `.DS_Store` is refused on share/s3 and accepted on chunk** — one condition with
two answers across backends, the shape §14a calls the port's whole job. Out of scope here (this branch
was scoped to make the guard and the comment true, not to change behaviour); recorded in CLAUDE.md §14c
so it is not rediscovered from scratch. **Closed by the `claude/reserved-name-door-guard` arc (the
Latest entry), which found the same divergence at two further doors** — `LibraryBrowseController
#create_folder` and `FilesController#begin_upload`.

**Measured on the merged tree**, `main` @ `a5838f3` merged in — the numbers below are that tree's, not
the branch point's, because that is what ships. `bin/ci` bare, **all seven gates, exit 0** (52.20 s):
style **517 files / 0 offenses**, scan **no vulnerabilities**, and the three backend legs **identical**
— **2234 runs, 8016 assertions, 0 failures, 0 errors, 9 skips**, the same as `main`, since this branch
adds no Rails-leg test. System (real browser): **76 runs, 470 assertions, 0 failures**, against main's
**75 / 466**. That delta is exactly one `test` block and four assertions — the whole of what this
branch adds — and cross-checks against the file on its own: `addon_sdk_test.rb` goes **4 runs / 22
assertions → 5 / 26**, measured by stashing the two test files rather than inferred from the total.

**The semantic conflict the merge invited, and did not produce.** `main` arrived carrying
`WebHelpers#open_addon_card` / `#settle_addon_cards` (the entry two above), which exist because a
gallery card collapsed out from under Chromedriver's click — and this branch adds a fifth browser test
plus a button to the SDK fixture bundle. They do not meet, and not by luck: the collapse is caused by
`img.addon-thumb`, which is created in exactly **one** place, the boxes bundle's own client-built
gallery (`test/fixtures/addons/boxes/gallery.js`), and `addon_sdk_test.rb` never opens it. Its new test
goes straight to `/tools/sdk-fixture`; the soft-navigation test's `click_link "SDK Fixture"` lands on
the HOST gallery (`app/views/tools/home/index.html.erb`), whose cards are three server-rendered spans
with no image and therefore nothing asynchronous to shift them. Checked by grepping for the class
rather than by reading the two tests side by side.

**Invariants recorded** in CLAUDE.md §14c: the reject-never-normalize bullet is **extended** to the
service name (carrying the argument for rejecting `/` rather than splitting it), and **one new bullet**
records the `rescue_from FileLayer::NotFound` reachability — a comment naming the wrong cause costs the
next reader exactly what a stale open-list does.

---

## 2026-08-07: an addon is written against a contract, not against another bundle's source — the host SDK (branch `claude/todo-list-review-6beccc`)

**PR 1 of the Addon API v1 arc** — row 1 of `docs/superpowers/specs/2026-08-07-addon-api-v1-design.md`
§12, amended in this branch per §15's close-out rule. Until now an addon author's reference *was*
another bundle: `save.js` gets copied verbatim out of `boxes` into every new generator, and each copy
reads only the HTTP status, so a save refused for a nameable reason reports **"Save failed."** This
PR gives the host a surface of its own.

**Shipped, in seven commits:**

- **`Maker::Addons::Host`** — a frozen server-side capability map (ten keys) plus `LEVEL = 1`. Six of
  the ten answer `false` today, **named before they are built**, which is the whole compatibility
  mechanism: an addon can be authored against `library:read` now and degrade until a host answers
  true. Every value is a real boolean, because a missing key reads as `undefined` in JS and a nil as
  `false`, and neither is distinguishable from a deliberate "off".
- **One `data-addon-ctx-value` JSON blob** in the addon shell, beside the **nine** legacy data
  attributes — an addition, never a replacement, because a bundle built against either shape may be
  running against this host. `addon_ctx` carries the host level and the capability map, which have no
  attribute of their own.
- **`app/javascript/maker/addon_sdk.js`, pinned as `@maker/addon-sdk`** — a **host** pin, so a bundle
  imports it having declared nothing. `capabilities()`, typed errors (`WouldReplaceError`,
  `NameTakenError`, `ServiceUnavailableError`, `UnsupportedCapabilityError`, `ServiceError`),
  `files.save` / `files.pickFolder` / `files.url`, `state.list`, `service.get` / `service.post`, and
  one `teardown` event. **One transport seam** (`_fetch`): Ring 2's null-origin iframe replaces that
  function, not every call site.
- **`addon_controller.js` calls `initHost(ctx)` before dynamic-importing the bundle** — the order is
  the contract, since a bundle's top-level code runs at import time — and `disconnect()` calls
  `teardownHost()`. A `this.disposed` guard (the idiom already used by `modelviewer_controller.js`
  and `measure_controller.js`) covers the disconnect-during-import race.
- **A second hermetic fixture, `sdk-fixture`,** that touches the host **only** through the SDK, plus
  four browser tests.
- **`docs/addon-api-v1.md`** — the author-facing normative reference, extracted from the spec so an
  author never reads the design document.

**The scope correction that shaped the whole PR.** The spec's row 1 said *"`generators` adopts it"*.
**`generators` is not in this repo** — bundles live in `chaim354/tinkerex-addons` and are deployed by
republishing the accessory image, so that migration spans two repos and is a follow-up PR **there**.
The in-repo proof is instead a **second** hermetic fixture using only the SDK, added beside the
existing `fixture` addon, **which deliberately stays on the raw-`ctx` path**: both halves of the
compatibility rule — old bundles keep working, new bundles need only the SDK — are then covered by
something that *runs*, rather than by an assertion about intent. Row 1 of the spec is amended to say
so.

**Two findings from reading the tree, both of which made PR 1 cheaper than the spec assumed.**
`ctx.chooseFolder` **already existed** as a host-supplied function (the Miller-columns picker), so
`files.pickFolder` is a wrapper and a capability name, not new work. And `saveWithOverwrite` — the
409 dance — is **copied verbatim into every real bundle**, which makes `files.save` absorbing it the
most concrete "the SDK deletes per-bundle code" win available in this PR, and the one the fixture's
third browser test exercises end to end.

**What review caught, which is the part worth reading.** The plan specified the SDK's surface; the
SDK's own *code* shipped four defects that reviewers found, all of them the quiet kind:

- **`files.url` pointed at the HTML file page while its comment promised an `<img src>`.**
  `/files/:id` is `resources :files`' detail page; the bytes are at `/files/:id/blob`. The method and
  path were kept — that is what shipped bundles use it for — and the comment fixed. No `blobUrl` yet:
  that is PR 5's, and it needs the SVG-forced-to-attachment caveat (§14c) stated properly rather than
  bolted on here.
- **`save`'s return was an untagged union whose arms were both truthy.** `#create` redirects on
  success and `fetch` **follows** redirects, so `res.ok` and a parsed body are truthy on every
  successful POST regardless of outcome — `if (await host.files.save(...))` reported success on a save
  the user had just **cancelled**. Now always `{cancelled: false, data}` or `{cancelled: true}`.
- **A cancelled `pickFolder` composed into a silent save to the library ROOT** —
  `folderNodeId: (await host.files.pickFolder())?.nodeId` yields `null` on Esc, and `save` defaulted a
  missing folder to `""`. That is exactly the null-vs-root conflation the neighbouring comment warned
  against, two members apart in the same object. `folderNodeId` is now **required**; pass `""` when the
  root really is the destination.
- **`ERROR_CLASSES[code]` reached `Object.prototype`.** `code` comes straight off a response body, so
  a body of `{error: "toString"}` resolved through the prototype chain to something that is not a class
  and `new Klass(...)` threw a bare `TypeError` **from inside `errorFrom`** — discarding the original
  HTTP failure the function exists to describe. Now `Object.hasOwn`.

Two more, from the same passes and both about coverage rather than code:

- **A mutation check proved the ctx blob's `defaultFolder` was entirely unguarded** — both values could
  be replaced with garbage and the whole file stayed green. The fix reads both representations out of
  **one** rendered response and compares them directly, rather than recomputing an expectation the
  duplicate could drift away from. The same shape recurred one commit later in the fixture's
  `onReplace` assertion, where a substring match was satisfied by the filename alone, so the
  **folder** half of the 409 payload — the part that lets a real prompt name a real destination — was
  never asserted; `sdk-dup.svg@undefined` would have passed.
- **The doc's own live-binding example was FALSE.** It claimed a top-level `const { files } = host`
  throws `host_not_initialized`. It does not: `initHost(ctx)` runs six lines before
  `await import(entry)`, so top-level code always sees a real host and the destructure **succeeds**.
  The real hazard is the opposite one and is **silent** — an ES module is evaluated once per URL per
  page, so on a Turbo re-mount `initHost` builds a new `Host` while the cached module's top level does
  not re-run, and the captured reference goes on serving the previous, **torn-down** host's context and
  CSRF token with nothing thrown. Traced to a **stale SDK comment that contradicted another comment
  eight lines above it in the same file**; both were corrected, and the rule ("read through `host` at
  call time; never capture it") now has the true reason attached to it.

**The final whole-branch review found no code defects — and three documentation ones, which is the
right ratio for a PR whose product IS a contract.** The reviewer drove the whole SDK out-of-tree
through node (**71 assertions, all passing**), checked the ctx→SDK seam in both directions and found
no key emitted-but-unread or read-but-unemitted, and re-ran both suites to the same numbers recorded
below. It also **closed the Turbo lifecycle hazard by reading Stimulus rather than reasoning about
it**: `stimulus.js:489-490` processes `removedNodes` before `addedNodes`, so
`disconnect()`→`teardownHost()` always precedes the next `connect()`→`initHost()` and the
interleaving that would have left a new host torn down by an old controller **cannot occur**. (The
`this.disposed` guard still earns its keep — it covers a *pending dynamic import* resolving after a
disconnect, a different window from the connect/disconnect ordering.) The three documentation
defects: an error row in `docs/addon-api-v1.md` whose trigger cannot fire and which **hid the real
behaviour** (a save naming a folder that no longer exists resolves to `nil` in
`Tools::LibraryFolders#chosen_parent_node_id` *before* any port call, so it answers **302 and writes
to the library ROOT** — verified on chunk and share, host behaviour that predates this branch and is
now described rather than changed); the spec still showing `host.ctx.defaultFolder` and
`Maker::Addons::HOST_LEVEL`, neither of which exists — the first being precisely what the new §14c
bullet forbids, sitting in the example an agent implementing PR 5 would copy; and two new bare
"spec §N" citations that are ambiguous because `source.rb`, one file over, uses the same shorthand
for the **2026-08-02** bundle design, which has a §4 of its own.

**Rejected on the way.** Publishing the raw context as `host.ctx`: the module's whole Ring-2 argument
is that a bundle talks only through `host`'s methods, and a public `ctx` hands back the raw
`csrfToken` and `chooseFolder` the SDK exists to wrap — the two claims cannot both be true, so it is
`_ctx`. Letting a sidecar's error through the host's error table: `boxes.py` answers **prose** in its
`error` key, so `errorFrom` would put the message in `.code` and filler in `.message`, and a non-JSON
body (Werkzeug's HTML 405, the proxy's own body-less 404) would be eaten by the failing `res.json()`
— `service.*` raises `ServiceError` from the status and the raw text instead. And *normalizing* a
`..` path segment: `encodeURIComponent("..")` is `".."`, so the **browser** normalizes the URL before
the request is sent and the server's guard never gets asked — it is now rejected, per §14a's `key_for`
rule, which this was the one spot in the tree departing from.

**Measured.** `bin/ci` green, **all seven gates, exit 0** (53.76 s). The three backend legs report
**identical** counts — **2181 runs, 7867 assertions, 0 failures, 0 errors, 9 skips** on chunk, share
and s3 alike. System (real browser): **74 runs, 461 assertions, 0 failures**. Against the merge-base
`de46dc2` (2172 runs / 7790 assertions; 70 system runs / 439 assertions, measured at `b3f4b78`) this
arc added **9 Rails-leg tests and 4 browser tests** — which matches the 13 `test` blocks the diff
adds, so the two counts cross-check rather than one being read off the other.

**What this does NOT prove, stated plainly.** No **real published bundle** runs against the SDK yet.
The four browser tests drive a fixture, and the `generators` migration — the thing that would delete
`saveWithOverwrite` from a bundle a user actually opens — is a follow-up PR in
`chaim354/tinkerex-addons`. Nothing here has been deployed.

Three more, recorded as known and deliberate so a later reader does not find them the hard way:

- **~~`serviceName` is neither validated nor encoded, while `path` beside it is rigorously
  rejected.~~ CLOSED by the entry above** (`claude/addon-sdk-service-name-guard`), which also
  replaced this controller's false `rescue_from FileLayer::NotFound` comment. Left here rather than
  deleted because the two entries are one arc and the follow-up is only legible beside what it
  followed.
- **Two-thirds of the SDK is unexercised by `bin/ci`.** The four browser tests cover the mount path,
  `capabilities()` and `files.save`. Nothing touches `state.list`, `service.*`, `files.pickFolder`,
  `files.url`, the uninitialised-host proxy, or the typed errors — and most pointedly
  **`host.on("teardown")`, the SDK's only lifecycle event, has never fired in this repo**: the Turbo
  test reaches `teardownHost()`, but the fixture registers no handler, so `_fireTeardown` iterates an
  empty list. The reviewer's node harness proves all of it works today; **nothing in CI would notice
  if it stopped** — this repo's dominant failure shape, recorded rather than closed.
- **`apiVersion` is emitted in the ctx blob and read by nothing** — no consumer today, and none named
  in any later PR.

**Invariants recorded** in CLAUDE.md §14c — nine, which is spec §15's items 1 and 5 (the two of its
five that PR 1 makes true) plus the seven this PR's own defects earned: the ctx blob is an addition
and the nine legacy attributes stay, the specifier-is-public-API rule for the host pin, the
init-before-import ordering and its module-cache corollary, the one-definition boolean capability map,
the bump-`LEVEL`-with-the-capability rule, 409-is-a-question / 422-is-not, the two `defaultFolder`
shapes, sidecar errors staying out of the host's error table, and reject-never-normalize for path
segments. Spec §15's items 2, 3 and 4 belong to PRs 3, 4 and 8 and are deliberately not recorded yet
— a rule for code that does not exist is a rule nobody can check.

---

## 2026-08-07: eight UI complaints, worked as one pass (branch `claude/overnight-ui-fixes-bdc67d`)

**The ask** was a list, verbatim: the Back button always returns to Files; STL thumbnails come out
wrong way up; a file deleted from the share stays in the Files view and its projects; the type filter
should be a dropdown of what is actually in storage; a project's main image should be choosable; the
project file sections should collapse and hide LightBurn/MillMage backups; adding a task should not
reload the page; files should be right-click downloadable.

All eight shipped. Two of them were not the bug the sentence described, and those are the two worth
reading.

### 1. "Back" was a link to `/files` wearing the label of a back button

`files/show.html.erb` hard-coded `link_to "Back", files_path`, so every route into a file page lost
its context: six folders deep it dumped you at the root, mid-filter it cleared the filter, and reached
from a project's Files panel it walked you out of the project.

`ApplicationHelper#back_target_path(default:)` derives the target from the **referer**, not from a
`?return_to=` param. That choice is about how many call sites have to be right: a file page is
reachable from the list, the grid, a project panel, a model bundle, the trash, an addon-save redirect
and any search — threading a param through all of them is seven edits that must agree plus an eighth
that gets forgotten. **It cannot become an open redirect**: the scheme/host/port are COMPARED and then
DISCARDED, so only a root-relative path ever reaches `href`; a cross-origin referer is dropped, not
sanitised. A referer equal to the current page falls back to the default — not exotic, since adding a
note, deleting a note and resolving a move conflict all redirect back to the same file page.

Mutation-checked both guards: spelling the origin test as `start_with?` reddens the lookalike-host
test; removing the self-reference guard reddens its own.

### 2. The STL camera orbited the wrong axis — and the fix is worthless without a revision bump

`client/stl-thumbnailer`'s `auto_frame` put the pitch on **Y** and passed `Vec3::unit_y()` as the up
vector. STL is **Z-up** by universal convention (every slicer puts the build plate at Z=0), and the
3MF core spec agrees — so every thumbnail in the library rendered **tipped onto its side**,
consistently enough to read as a house style. `modelviewer_controller.js` had the identical bug from
the other direction: Three.js's world is Y-up and **neither STLLoader nor ThreeMFLoader rotates what
it parses** (3MFLoader's own docblock tells the caller to do it, and we were not).

Measured, by restoring the old camera: an upright **4×4×16 column rendered 192×140** — wider than
tall. Nine Rust tests, seven of which stayed green under that mutation, because they all ask "is the
frame non-blank?" — a question a model lying down answers exactly as well as one standing up. The two
new ones are positional and both directions are pinned (a tall column must render tall, a flat slab
must render wide), so a fix that merely swapped which axis is wrong cannot pass.

**The viewer moves the CAMERA, not the model**, and that half matters: rotating the object is the
docblock's suggestion and is equivalent on screen, but `showDims` reads the bounding box *after*
parse, so a rotated 10×20×30 model would report "10 × 30 × 20 mm" — a measurement disagreeing with the
user's own slicer. `.obj` stays Y-up, which is Wavefront's convention.

**THE HALF THAT IS EASY TO SHIP WITHOUT.** `Stl` and `ThreeMf` declared no `payload_revision`, so they
sat at `BASE_REVISION`. A file's content never changes, so without a bump every STL already in a
library keeps serving the old picture **forever** — this is CLAUDE.md §14h's recorded lesson, and it
would have applied verbatim. Both now declare `THUMBNAIL_REVISION = 2`, and `ThreeMf` tracks `Stl`'s
number **as a relationship, not a literal**, because its mesh fallback renders THROUGH `Stl.render`:
bumping only `Stl` would leave every CAD-exported 3MF sideways with nothing to say so.

> **DEPLOY NOTE:** the Rust fix needs the `stl-thumbnailer` binary REBUILT into the Rails image. The
> revision bump makes Rails re-render; it cannot make an old binary draw a new picture. Ship both or
> the library re-renders itself sideways at revision 2.

### 3. A deleted file left the Files view but never left its projects

Half the complaint was already right: `FilesController#index` scopes on `nodes.present`, so a
tombstone never lists. The projects half was not — `Library::Reconciler` TOMBSTONES rather than
destroys (deliberately; it is what makes a NAS reorganisation survivable), so no `dependent:` callback
fires, and the panel rendered a "⚠️ (file unavailable)" tile with a Remove button, forever, once per
project.

**Split into an instant half and a graced half, because the two have opposite risk.**
`ProjectsController#show` stops rendering a tile whose node is gone — hiding is reversible, so it is
immediate. `Maker::AttachmentReaper` (daily) destroys the rows and NULLs a stale chosen cover — but
only once the tombstone's undo window has closed, because a tombstone is one undo away from returning
with the SAME node_id, and the attachment is keyed on it. Reaping inside the window would turn
"restore from Trash" into "restore, then re-file this into every project by hand".

The rule now has one home: `Maker::DeadNodes` owns `reapable?` and the 30-day window, shared with
`Maker::Previews::DeadNodeReaper`, which previously held a private copy. Mutation-checked: swapping
`user.nodes` for `user.nodes.present` in the shared index reddens **three** tests across both reapers
— a tombstone would look hard-gone and be reaped with no grace at all.

**Not silent.** The panel says "N attached files no longer in your library" with a link to the Trash,
and an "empty" project is a different sentence from one whose files were all deleted.

### 4. The type filter listed the vocabulary; now it lists the library

The chip row was derived from `ROLE_BY_EXT`, so it offered `.sldasm`, `.ngc` and `.fcstd` — ~35 chips
— to someone who owns none of them, while an extension they really did have appeared nowhere and had
to be typed into a free-text box beside it. `FilesController#ext_facets` tallies what the library
actually holds; `ext_facet_groups` uses `EXT_FAMILIES` **only for grouping and order**. Everything
offered exists, everything that exists is offered, with counts. The free-text escape hatch is gone
with the wall it stood beside — an unknown extension lands under "Other" and the user no longer has to
know it exists.

Measured (SQLite, 13 extensions): **20,000 files → 14.4 ms, of which 3.1 ms is the query; 100,000 →
86.2 ms, of which 11.3 ms**. The cost is the per-row `File.extname` in Ruby, ~7/8ths of it — so it is
NOT cached: a cache would add a second query and a staleness window to shave a tenth of what the same
page already spends rendering (175–278 ms of ERB at 2000 rows). One query whatever N is.

Three mutation checks: dropping the `kind: "file"` filter, keeping active types in the dropdown, and —
the one worth naming — spelling the disabled state as `disabled="[interpolation]"`. `disabled` is a
**boolean attribute**: any value at all turns it on, so that spelling renders `disabled="false"` and
disables the control permanently.

### 5–8, briefly

- **Project covers.** `cover_node_id` becomes a real column; the reader keeps the derived pick (first
  image, else first model, else first attachment) as its fallback, so **no existing project changed
  appearance**. The form uses the EXISTING `filechooser` in `mode: "file"` — supported since it was
  written, first caller now. The form pre-fills from `project[:cover_node_id]`, not the reader, or
  "nobody has chosen" would silently become an explicit choice on the next save.
- **Collapsible sections + backups.** Native `<details>`, no JS, matching `models/_file_tree`. LightBurn
  and MillMage write `<stem>_backup.<ext>` rescue copies (confirmed against the real corpus:
  `traymammon-1_backup.lbrn2`, `metal test 1_backup.lbrn2`); those move to a **closed** Backups
  section rather than being dropped — the file is really in the project's folder. Both halves of the
  rule are required, so a user's own `battery_backup.stl` is not filed as one.
- **Tasks without a reload.** `Projects::TasksController` answers `turbo_stream` by replacing
  `#project-tasks` only; the HTML redirect stays as the no-JS path. The error renders INSIDE the
  replaced element — a `redirect_to ... alert:` would set a flash no response ever draws. Verified in
  a real browser: a marker set on `window` before the add survived, `turbo:load` fired zero times, the
  panel element was swapped, the count went to "Todo (2)" and the input cleared. Found on the way: the
  partial's `render "task"` resolved only from `ProjectsController` — a second caller made it
  `MissingPartial` on every stream, now fully qualified.
- **Right-click download.** `filemenu_controller.js` gains a Download entry built from a
  `data-download-url` the server writes, on the list, the grid and project tiles. **No HTML `download`
  attribute**, deliberately: on chunk and s3 the blob endpoint 302s to a presigned cross-origin URL and
  browsers ignore `download` across origins — it would work on share and silently open-in-tab on the
  product's main deployment. `?download=1` and the server-set header is the one mechanism that holds on
  all three. The grid needed it most: a card has no row-actions cell.

### The finding that only a browser could produce

**An ERB comment that quotes a snippet containing `%>` terminates early and prints its own remaining
prose into the page.** One did, in `files/_ext_filter.html.erb`, and three lines of a code comment sat
in the middle of the Files page. **Every test in the suite stayed green** — `assert_select` asks about
ELEMENTS and this defect produces a TEXT NODE. It was found by opening the page, which is §15's
"probe over an argument" in one screenshot.

A static scan of the templates was written first and is the weaker guard: it has to guess whether the
text after a comment's terminator was meant to be markup or prose. `test/integration/web/template_hygiene_test.rb`
asserts on the RENDERED OUTPUT of eleven pages instead — no ERB delimiter, and no phrase that only
appears in this branch's code comments. Both halves are checked (`<%` AND `%>`, since an early
terminator leaks a CLOSER, not an opener), and mutation-checking it by reinstating the bad comment
reddens both.

### Verification

`bin/ci` green, all seven gates. **2172 runs, 7790 assertions, 0 failures on each of the three backend
legs — identical counts** (chunk / share / s3), plus 70 system tests and 9 Rust crate tests. Baseline
at the merge-base was 2107 runs, so this arc added 65 tests.

Driven in a real browser against a seeded library on `STORAGE_BACKEND=local`: the type dropdown's
optgroups and counts, the active-chip filter row, the project panel's six sections (Laser 1, Backups 2
closed) with the missing-file line, Back landing on `/projects/desk-lamp` from a project-opened file,
the right-click menu's three entries with the correct blob URL, a task added with zero `turbo:load`
events, `camera.up === [0,0,1]` with a 4×4×16 column standing upright and dims still reading
"4 × 4 × 16 mm", and the rebuilt thumbnailer's own PNG of the same column.

### Follow-up, same arc: the sweep that was supposed to fix the library reported zero

Shipping revision 2 corrects every STL/3MF thumbnail **rendered from then on**, and self-heals an
existing one the moment someone opens a page that draws it. A library nobody browses stays sideways.
The obvious remedy — `rake previews:backfill_missing` — **did not work, and said so in the most
misleading way available: "Enqueued 0."**

`MissingBackfill`'s `seen` set was keyed on the **(node_id, version_id) pair**. A row built by an
older renderer sits at the *current* content, so it satisfied that check and was skipped — while
`FilesController#thumbnails_for` and `#current_thumbnail`, which do compare `renderer_revision`,
treated the very same row as absent and re-enqueued it. **Two answers to one question, and the sweep
held the wrong one.** That is this repo's recorded failure shape (§14a's five `port_writable?`
copies, §14b's skip-list) in a new place: not a missing feature, a second implementation of a lookup
that had already been fixed elsewhere.

The fix is one column: `seen` now plucks and compares the **(node_id, version_id, renderer_revision)
triple**, the same one the read path resolves on. The revision is asked of the RENDERER per node
(`Enqueue.revision_for`), not held as a constant, because it depends on the file's own extension —
the same reason `thumbnails_for` filters in Ruby rather than SQL.

Two details that are not decoration:

- **A name nothing renders is skipped in the sweep, not left to `Enqueue`'s nil return.**
  `revision_for_name` answers `BASE_REVISION` for one, so leaving it would mark every `.xyzzy` in
  the library stale on every run — a dry-run number that never reaches zero on a library where
  nothing is wrong. Mutation-checked.
- **`dry_run:` was added because this sweep can now cost a full-library re-render.** Before the
  revision check it only ever found a backlog someone was already missing; after it, a bump makes
  every file of that format eligible at once. Deliberately **not** capped the way
  `ProjectIntake::MAX_MOVES` is — there a cap bounds unattended churn, here doing all of them IS the
  task, so a cap would guard against success. The report is asserted to equal what a real run
  enqueues, because a number that does not match is worse than no number when it is what an operator
  decides on.

Scope held: `kind` stays `thumbnail`. Geometry payloads carry their own revisions but are built on
demand by a polling client, so sweeping them would render measurement data for every measurable file
whether or not anyone measures it.

Mutation checks: restoring the pair key reddens the older-renderer and idempotence tests; dropping
the renderer skip reddens the non-renderable one. Suite **2177 runs / 7811 assertions**, identical on
all three legs.

### Left open

- **`Maker::AttachmentReaper` sweeps model attachments too** (it reads `user.maker_file_attachments`,
  which is all attachable types) **but only the PROJECT panel hides them.** The models page never had
  the bug — its file tree is built from live `nodes` and `@viewable_3d` already skips missing ones — so
  there was nothing to fix there; recorded because the reaper's scope is wider than the view fix's.
- **Section open/closed state is not persisted.** It survives the life of the page and resets on
  reload. Persisting it needs a cookie per section per project, and the default (everything open but
  Backups) is right for almost every visit.
- **`ext_facets` is unbounded in N**, by decision — the numbers and the argument are above.

---

## 2026-08-07: Measure stops being a LightBurn feature — .mage, .dxf and .svg too (branch `claude/measure-feature-mage-svg-dxf-0111cj`)

**The ask:** *"i want to add the measure feature we just did from lbrn2 to mage files and svg and
dxf."* The entry below shipped it for `.lbrn/.lbrn2`. This generalises it to the other three vector
formats the library already thumbnails.

**Shipped:** the **Measure** button now appears on `.mage`, `.dxf` and `.svg` file pages as well.
Same surface, same interactions, same readout — `80 × 40 mm`, or `⌀10 mm` when the contour is round.

**The seam turned out to be almost entirely server-side, and that is the result rather than a
convenience.** `FilesController#geometry`, the `geometry` preview kind, `Enqueue`'s revision check
and `measure_controller.js` were already format-agnostic: the client reads a wire contract — job
box, shapes, colours — and branches on nothing. **Not one line of JavaScript changed for the three
new formats.** What each needed was a traversal of its own file and a way to turn its numbers into
millimetres.

**`Maker::Previews::Geometry` — one payload definition, four traversals.** `LbrnGeometry` held the
schema, the RDP thinning, the circularity test and the job box; copying it three times would have
put four implementations of `simplify` and `diameter` in the tree, which is §14b's `LbrnMetadata`
second-copy bug with two extra copies. A ⌀ that means one thing on a LightBurn file and another on
a DXF is worse than no ⌀. Each format now supplies only a traversal and a colour policy.

- **`.mage` was nearly free — and the reason exposed a live bug.** `Mage` already renders through
  `Lbrn2`'s walker verbatim (the geometry dialect *is* LightBurn's), so the payload came for free.
  But **a MillMage `<Shape>` carries `OpIndex`, not `CutIndex`** — measured on `real-export.mage`:
  `CutIndex` uniq `[nil]`, `OpIndex` uniq `["0"]`. The thumbnail never noticed, because a MillMage
  file has no `<CutSetting>` either, so a nil index and a real one both fall through to
  `DEFAULT_STROKE` and draw the same black. The Measure view is where it surfaces: the layer key is
  what groups shapes and keys the colour map, so **every `.mage` contour landed in one nameless
  layer**. `Lbrn2.layer_index` now reads either.
- **MillMage gets no colours, deliberately.** `LAYER_PALETTE` is defensible only because its values
  were *recovered* from 58 real LightBurn exports. MillMage is a different application with its own
  layer bar and no colour field in `<Operation>`, so painting OpIndex 2 in LightBurn's red would be
  a claim nothing supports — the same mistake §14h names in the other direction. The client draws
  black, which claims nothing.
- **`.dxf` needed the traversal split out of the drawing.** `Dxf` built SVG strings straight from
  entities, so there was no geometry to reuse. It now has `each_geometry`, and **`to_svg` consumes
  it** — verified byte-identical to the previous implementation across four input shapes, which is
  the evidence the refactor moved plumbing and not the picture. `CIRCLE`/`ARC` still emit exact SVG
  primitives via a `curve` descriptor alongside the flattened points, the same "richer rendering of
  the same points" contract `Lbrn2.each_geometry` uses for ellipses and bitmaps.
- **`$INSUNITS` is where a DXF's numbers become physical**, and `0`/absent resolves to **mm** — a
  choice, not a reading. A DXF from a maker tool routinely has no `HEADER` at all (`sample.dxf`
  does not), and mm is the corpus. A file in inches with no header reads 25.4× small; nothing in
  the format lets us know that. Colours come from the **`LAYER` table**, not the entity — an
  entity's own code 62 is usually absent or `BYLAYER` — and a **negative table colour means the
  layer is off**, so its geometry is neither drawn nor folded into the measured extent.
- **`.svg` is the one leg with no shared traversal, and the entry says so rather than papering
  over it.** An SVG thumbnail is rasterized by **resvg**, which we do not reimplement, so this
  parser is necessarily a second independent reading of the file. The honest consequence: resvg
  understands the whole format and `SvgGeometry` understands its geometry subset, so a file using
  something outside it measures fewer shapes than the picture shows. `<text>` (needs font metrics),
  `<use>` (needs href resolution) and clip paths are **not** parsed — each named in the module with
  the reason. Refusing to measure SVG at all was the worse answer for the most common laser source
  there is.
- **`SvgPath` is its own module** because `d` is the densest part of the format and the part most
  likely to be wrong in a way nothing notices — a mis-parsed path still draws *something*. Full
  M/L/H/V/C/S/Q/T/A/Z, arc endpoint→centre conversion per SVG 1.1 F.6.5 including the
  radius-growth correction, and **adaptive flattening bounded by a tolerance rather than a fixed
  sample count** — a fixed count undersamples a large curve, whose bbox and diameter then both read
  small, silently. Units resolve from `width`/`height` over the `viewBox`, falling back to **CSS px
  at 96 dpi**, which is what makes a viewBox-only file measurable at all. `preserveAspectRatio`
  `meet` uses **min(sx, sy)**, because taking them per-axis reports a stretch the renderer never
  applies.

**Two bugs found on the way, neither in scope, both on this feature's own path.**

**`available?` gated the wrong thing.** It answers "is resvg on this box", because the *thumbnail*
is a rasterized SVG — but the measure payload is Nokogiri and arithmetic and needs nothing external.
A single gate marked a perfectly measurable `.svg`/`.dxf`/`.lbrn2` **`unsupported`**, while `.mage`
— whose `available?` is unconditionally true — measured fine, making the feature silently
format-dependent on exactly the boxes least likely to have the binary. `GeneratePreviewJob` now asks
`available_for?(kind)`, defaulting to `available?` for the ten renderers that only make thumbnails.
**This was observable, not theoretical: it is why two geometry tests failed on a rasterizer-less box
before the fix and pass after.**

**A 1-second regex timeout on every file with an embedded photo.** `BITMAP_DATA` validated the
base64 of an inlined image — the attribute that is the reason `parse_document` needs `huge`, and
routinely 10–25 MB — with `\A[A-Za-z0-9+/=\s]+\z`, against Rails' `Regexp.timeout` of **1.0 s**.
Measured here: **0.467 s standalone and over the limit through the real Nokogiri path**, so it fell
on either side depending on the machine. `Regexp::TimeoutError` *is* a `StandardError`, so
`LbrnMetadata.parse`'s blanket rescue swallowed it and returned nil metadata, while `to_svg` and the
Measure payload — which have no such rescue — would have failed the whole preview. Replaced with a
`String#count` set: same semantics, no engine to time out, **45× faster on the same 11 MB (0.0104 s)**.
Two pre-existing red tests went green.

**A dead skip-list, deleted rather than kept as decoration.** `SvgGeometry` started with a `SKIPPED`
list naming `defs`/`symbol`/`clipPath`/…; removing an entry from it left every test green, because
the walk only ever recursed into an **allowlist** of containers. §14b records the skip-list blind
spot as this repo's own recurring bug, four instances deep — an allowlist cannot have it, so the
allowlist stayed and the constant went. Caught by mutation-checking, not by reading.

**Measured.** Payload cost stays trivial on the new legs — `plate.dxf` 495 B gzipped for 2 shapes,
`plate.svg` 447 B, `real-export.mage` 292 B. The renaming sweep: `lbrnmeasure_controller.js` →
`measure_controller.js` and the `.lbrn-measure*`/`.lbrn-contour*` CSS → `.measure-*`, because the
surface is no longer LightBurn's. The LightBurn *settings panel* classes (`.lbrn-layers`,
`.lbrn-swatch`, …) are untouched — those really are LightBurn-specific.

**Verification.** All three backend legs identical: **2107 runs, 7445 assertions**. System:
**69 runs, 434 assertions, 0 failures**, run against a real headless Chrome. Style and Brakeman
clean. **21 guards mutation-checked** — each broken, confirmed RED, restored — including the two
that were false-greens on the first attempt: the `available_for?` test passed trivially on a box
that *has* resvg until the rasterizer was stubbed absent, and the `defs` test was passing for a
different reason than the guard it claimed to check. Both are the shape §15 names: an assertion that
holds whether or not the code is right.

**Not verified:** the 6 pre-existing failures in `Library::Scanner`'s unreadable-directory tests
are **environment, not this branch** — identical on the merge-base, and they `chmod 000` a directory
while the container runs as **root**, which reads it anyway. They pass on the macOS CI runner.

**Deployed 2026-08-06 — and the gap between "merged" and "live" is the part worth recording.**
This arc's PR (#156) merged *after* the previous deploy went out, so for a while all three Unraid
backends ran `9ab3930` — the merge of #154, the commit immediately before this work. At that commit
`MEASURABLE_EXTS` does not exist, `preview_kind` has no `:measure` branch and `_measure.html.erb`
is not in the tree, so `.svg` fell through to `:image` and `.dxf` to `:thumbnail`: **no Measure
button at all, which presents exactly like a broken feature** and was reported as one (*"i added the
measure feature to svgs and dxf but it doesnt seem to have worked"*). Nothing was wrong with the
code. **§15's close-out rule ends at "open the PR", so merged-but-never-built is the default state
of any freshly-merged feature** — the triage is one command, `docker ps` on the box, because the
container name *is* the git SHA. `docker images ghcr.io/chaim354/tinkerex` separates the two cases:
no image tagged with the feature's SHA means the build never ran, rather than a deploy that failed.

All three legs now run **`167d711`**, built once and rolled with `--skip-push`. Verified on the box
rather than from an exit code: three container SHAs, six `/up` checks (both `.local` and `.home`,
per the entry two below), and — because booting is compatible with having shipped the old code —
`MEASURABLE_EXTS`, `_measure.html.erb` and `measure_controller.js` confirmed present *inside each
running image*. Then the feature itself, executed in the production chunk container: an 80 × 40 mm
SVG measured `job 80.0 × 40.0` with the circle resolved as **⌀10.0 mm**, and
`Svg.available_for?("geometry")` / `Dxf.available_for?("geometry")` both true — the gate whose
mis-wiring is the first of the two bugs above. **No backfill is needed**: no `geometry` row ever
existed for these formats, so the first Measure click enqueues and the client's poll resolves it.

**Not verified:** no logged-in click-through of the live web UI — that needs a browser session. The
server-side payload is confirmed in production; the browser half rests on `measure_formats_test.rb`.

Invariants: **CLAUDE.md §14h**.

---

## 2026-08-06: a backup of the share deployment that has actually been restored (branch `claude/share-version-sqlite-98e3cc`)

**The question that started it:** *"right now the share version uses sqlite?"* — then *"i want to
backup that current db because i am actively using the share version while we develop and i dont
want to lose my data if something breaks."*

**Yes, and not only share.** `DATABASE_URL` is set nowhere in `config/deploy*.yml` or `.kamal/`, so
`database.yml`'s production block takes the self-host arm on all three Unraid backends: primary plus
the three Solid stores as separate SQLite files on each destination's own volume
(`tinkerex_storage{,_share,_s3}`). Postgres is the managed/SaaS profile (§7) and nothing on the box
uses it. `LIBRARY_BACKEND` and the DB adapter are independent knobs — "the share version" names the
CIFS-mounted *library*, not the database.

**What landed:** `ops/backup-db.sh` (the implementation, runs on the VM), `bin/backup-db` (ad-hoc,
pulls to the Mac), `bin/restore-db`, `bin/backup-cron-install`, `bin/backup-status`, plus
`docs/DEPLOY.md` §6. A **nightly at 03:30 America/New_York** covers all three deployments and keeps
14 each on the Unraid array. Nothing drives the app to do it, so a backup costs no deploy and no
downtime — and, deliberately, does not require the app container to be UP: a nightly whose whole
job is to run when things are broken must not depend on the thing that is broken.

**ONE IMPLEMENTATION, TWO CALLERS.** The nightly and the ad-hoc Mac command differ only in where
bytes land, so `bin/backup-db` scp's the current `ops/backup-db.sh` up on every run and calls it
with `--to-stdout`. A second copy would eventually be a second copy with different bugs — §14b's
Reconciler and §14d's file-type vocabulary are both in this file for that reason.

**`docker cp`/`cp`/a volume tarball all produce a TORN DATABASE, and it opens fine.** These run in
WAL mode (`PRAGMA journal_mode` → `wal`, verified live), so committed state is split between
`production.sqlite3` and its `-wal` while Puma and Solid Queue write throughout — on share the queue
was carrying a **5 MB WAL** at the moment of measurement. A non-atomic copy of the pair still opens
and mostly answers; the corruption surfaces later, on one row, with nothing to tie it back.
`sqlite3 .backup` (the online-backup API, defined against concurrent writers) is the whole reason
these are scripts rather than an `scp`.

**THE ARCHIVE MUST CARRY THE ACTIVE STORAGE BLOBS, AND THE REASON IS NOT SIZE.**
`config.active_storage.service = :local`, so preview assets sit on the *same* volume under
`/rails/storage/<xx>/<yy>/`. They are **not** rebuildable from a restored database:
`Maker::Previews::MissingBackfill` skips any node that already HAS a preview row, so a DB-only
restore leaves all 1383 rows at `ready` pointing at files that no longer exist — blank thumbnails on
every surface, no error, no job, nothing to notice. Same shape as the §14b staleness bug: the repair
sweep declines to look at exactly the rows that are broken.

**WHERE THE ARCHIVES GO — the VM was rejected on purpose.** `//192.168.1.146/backups/tinkerex-backups`,
mounted as the Docker CIFS volume `tinkerex_backups`, the same driverless mechanism
`deploy.share.yml` uses for the library (no host `sudo mount`, no fstab, no cifs-utils). The VM's own
disk is 31 GB with 12 GB free and is the **same virtual disk the live databases sit on**, so it would
protect against a bad migration and not against losing the VM — a backup sharing a failure domain
with its source is half a backup. Probing the host found `appdata` **read-only to guest** (the
conventional choice, and unusable), `system` off-limits, and `3D Printing` unusable for a different
reason: it *is* the share library, so tarballs there would be indexed as library files by the scan.
The user created a `backups` share for this. **`docker volume rm tinkerex_backups` must not happen** —
the next reference recreates it as a plain empty LOCAL volume and the nightly reports success while
writing into the disk this whole arrangement avoids.

**AND THE INSTALLER SHIPPED DEFAULTING TO `appdata` ANYWAY — the paragraph above and the code
contradicted each other in the same commit** (review of this PR, fixed here). `bin/backup-cron-install`
read `BACKUP_NAS:-//192.168.1.146/appdata` with a header still advertising appdata's "356 GB free",
while `docs/DEPLOY.md` §6 and this entry both already recorded appdata as read-only to guest and
unusable. **The default is the half nobody reads**, so the docs being right bought nothing.
Reproduced against a stubbed box, both branches:
- run as documented, no env override → it aborts at the bootstrap `mkdir` (exit 1), so *"re-run this
  after any change to `ops/backup-db.sh`"* silently stops being a working way to push a script change;
- counterfactually, with appdata writable → it reaches the volume check, sees the live volume pointing
  at the real `backups` path, and **advises `docker volume rm tinkerex_backups`** — the one act the
  line above and its own header both forbid, and the one most likely to be aimed at the *correct*
  volume, since a wrong `BACKUP_NAS` is the commonest way to land in that branch.
Fixed in three places: the default is now `//192.168.1.146/backups`, the header says so and says why
not appdata, and the advice is replaced with *inspect it, then either fix `BACKUP_NAS`/`BACKUP_SUBDIR`
to match what it already points at, or build a new one alongside with `BACKUP_VOLUME=`* — never
delete. `docs/DEPLOY.md` §6 carries the same remedy beside the rule the message cites.

**Four traps, all found by probing, none by reading.**
- **`tar --anchored` is load-bearing.** GNU tar matches `--exclude` patterns *unanchored* by default,
  against any trailing part of a member name. The exclude that drops the live, torn `.sqlite3` files
  therefore also matched the staged snapshot at `db-snapshot/production.sqlite3` — the archive would
  have contained every blob and **no database at all**, at full plausible size.
- **`ssh` FLATTENS its arguments into one command string the remote shell re-splits, and this bit
  three separate scripts.** An empty trailing argument does not arrive as an empty positional, it
  vanishes into whitespace — `set -u` then killed `bin/backup-status` on line 2. A share name
  containing a space (`//host/3D Printing`, which this box has) arrives as two arguments. And
  `"-v vol:/backups:ro"` passed as one argument becomes two, shifting every positional after it so
  the worker read the mount spec as the archive path. Pass space-free values, `${4:-}` for
  optionals, `printf %q` for anything that might contain a space.
- **`ssh bash -s` already owns stdin**, so the tarball cannot also travel down it; the two race and
  the script itself gets eaten. `bin/restore-db` `scp`s the archive over as a file first.
- **crontab treats a bare `%` as a newline.** The obvious `{ date -u +'%FT%TZ'; …; }` timestamp
  wrapper *in the cron line* does not fail loudly — it silently truncates the command at the first
  `%` and feeds the remainder to the job as stdin. The header/footer live inside
  `ops/backup-db.sh` instead.

**Verified by rehearsal, against real bytes.** `bin/restore-db share box:latest --into rehearsal`
restores into a throwaway volume and reads it back with the deployment's own image, while the live
container keeps serving: four databases `integrity_check ok` and owned `rails:rails`, **1326 blob
files** (matching `active_storage_blobs` exactly), **1872 nodes** readable, no `db-snapshot/` left
behind. Done from both sources — an archive on the Mac and one the nightly wrote to the array.
Scratch volumes dropped afterwards.

**The cron entry was watched firing, not merely installed.** Rescheduled two minutes out; it ran at
`01:11:01Z`, logged its own header/footer, wrote all three archives and exited `status=0`; the
03:30 schedule was then put back. Installing a crontab line and calling the nightly done is the
same class of claim as a green suite over something that never ran.

**Retention mutation-checked, because it DELETES.** Four successive `--keep 2` runs into a scratch
volume: 1 file, 2 files, then 2 with the oldest gone, then 2 again — so it neither prunes below the
floor nor accumulates. Then foreign files (`notes.txt`, an unrelated tarball, and *another
deployment's* archive, deliberately the oldest file present) were planted and a `--keep 1` run
pruned its own destination to one and **touched none of them**. Pruning happens only after a
verified write; a failed run skips it, because the one thing worse than a missing backup is a good
one aged out by a broken run.

**`--keep` WAS UNVALIDATED, AND `--keep 0` DELETED THE ENTIRE ARCHIVE SET AFTER PINGING SUCCESS**
(review of this PR, fixed here). The prune is `tail -n +$((keep + 1))`, so `0` selects **every**
archive — including the one written and integrity-checked seconds earlier — and it runs *after* that
destination's `up` ping has gone out, so Uptime Kuma records the run green over the loss. Measured in
the real app image (`/bin/sh` is dash, GNU coreutils 9.7) against four stub archives, with only the
CIFS volume swapped for a scratch bind mount:

| `--keep` | before | after |
|---|---|---|
| `0` | pruned **all four**, newest included, `exit 0` | refused, `exit 64`, **0 pings sent** |
| `-1` | `tail -n +0` → the same **all four** | refused, `exit 64` |
| `abc` | dash `Illegal number`, **nothing pruned, `exit 0`** | refused, `exit 64` |
| `14` | correct (4 < 14, nothing pruned) | unchanged — passes the guard and runs |

**The non-numeric case is quieter than the review that found it assumed, and the correction matters
for how it would have been noticed.** The arithmetic does abort — but inside a **pipeline element**,
which is a subshell, so the pipeline's status is the `while` loop's and `sh -eu -c` still exits **0**.
It therefore does *not* kill the run mid-loop: later destinations are backed up and pinged normally,
and the only symptom is that pruning silently never happens again — an unbounded leak reported as
success, with the one-line `Illegal number` buried in `backup.log`. Verified by exit code, not by
reading. The guard is a single `case` before any backup work and before any ping; proved so by
pointing `PING_SHARE` at a local listener and confirming a refused run sends **zero** requests while
a valid one sends exactly one.

**`0` is REFUSED, not reinterpreted, and that diverges from its sibling on purpose.** CLAUDE.md §14a
gives `LIBRARY_TRASH_DAYS=0` the meaning "keep forever" precisely because the obvious implementation
purges the lot — right for a **duration**, where "0 days of history" is coherent and the generous
reading is the safe one. It is wrong for a retention **count**: `--keep 0` plainly reads as "keep
zero", so silently keeping everything is the same surprise pointing the other way, and a count has no
safe reading of what is simply a typo. The comment in `ops/backup-db.sh` names §14a so the divergence
reads as a decision rather than an oversight.

**Measured:** chunk 11 MB / 2192 nodes, share 34 MB / 1872 nodes, s3 92 KB / 0 nodes (that
deployment's library is genuinely empty) — 44 MB a night, ~0.6 GB for the full 14-day history
against 5.8 TB free. Whole run: 11 seconds.

**Not in the archive, and not missing:** the library bytes (share's NAS at
`//192.168.1.146/3D Printing`; chunk's SeaweedFS). What this preserves is the **catalog** — the part
that exists only in that volume.

**MONITORING IS AN UPTIME KUMA PUSH MONITOR PER DEPLOYMENT — a DEAD-MAN'S SWITCH, which is the
point.** It alerts on the ABSENCE of a ping, so it catches cron unloaded, the VM powered off, and
the script killed before reaching its own error handler — none of which can send a message, and
all of which stop the heartbeat. Home Assistant was the other candidate (already running, already
the notification hub) and would have worked via a `timer` helper with `restore: true`, whose
`timer.finished` event is the same idea expressed natively; Uptime Kuma won on keeping backup
monitoring beside the monitoring for everything else rather than inside home automation.
**It must run on the UNRAID HOST, not the VM** — a monitor sharing a host with what it watches is
off exactly when the worst failures happen, and its silence then reads as health. Same argument as
the archives, one level up.

Four behaviours, each mutation-checked by breaking the thing it guards:

- **A failing run pings `status=down` immediately**, rather than waiting out the 25-hour window — a
  backup that runs and fails is knowable in seconds. Forcing the worker to `return 7` produced
  `status=down&msg=backup+failed…` and exit 1; pointing the container lookup at a nonexistent name
  produced `status=down&msg=no+container+matching+this+deployment`. **That second arm was missing
  until the test was written** — it set a failure status and pinged nothing.
- **A failed ping never fails the backup.** Pointed at a dead port, the run still wrote its archive,
  pruned, and exited 0 with a warning on stderr. Letting curl's status through would turn "Uptime
  Kuma is rebooting" into "the backup failed" and — since a nonzero exit skips the prune — into a
  slow disk leak.
- **`--to-stdout` (the ad-hoc Mac backup) deliberately does not ping.** Otherwise a nightly dead for
  a week reads healthy for as long as someone keeps rescuing it by hand. *(True of the success path
  only. The vanished-container arm in the first bullet sits ABOVE the `$TO_STDOUT` branch and pinged
  unconditionally — so these two bullets, written in the same commit, contradicted each other from
  the first day. Closed in the follow-up below.)*
- **`ping.env` is MERGED, never overwritten.** The installer is what you re-run to push a script
  change; dropping unmentioned keys would unwire every monitor the next time someone fixed a typo,
  and they would sit green until their windows lapsed. Tokens stay on the box, chmod 600.

**TWO BUGS LIVED IN THE URL UPTIME KUMA HANDS YOU, and both were found by wiring the real thing
rather than by reading.** Its UI shows the push URL as
`…/api/push/TOKEN?status=up&msg=OK&ping=`, so pasting it verbatim is the natural move:

- **That URL contains `&`, and `ping.env` was being SOURCED.** Bash read the `&` as a **job
  separator**: the assignment ran in a background subshell, the variable was never set in the
  calling shell, and the ping silently did not happen. Found because the stub received *nothing* on
  a test that had passed minutes earlier with a query-free URL. Now parsed with an explicit
  three-key whitelist, which also stops the file being executable shell.
- **`curl --get` would then append a SECOND `status`.** Express/qs parses duplicate keys into an
  **array**, and Kuma's `req.query.status === "down"` compares against an array and is false — so
  **every failure would have been recorded as UP**, a monitor staying green exactly when it must
  not, which is strictly worse than no monitor. `ping_kuma` strips any query string; mutation-checked
  by configuring the verbatim UI URL, forcing a failure, and asserting exactly one `status=down`
  reached the listener.

**Live.** Uptime Kuma is installed on the Unraid host with three push monitors (`chunk.tinkerex`,
`share.tinkerex`, `s3.tinkerex`), all three reachable from the VM (`{"ok":true}`) and pinged with
real data by the install run: chunk 11 MB / 2192 nodes, share 34 MB / 1872 nodes, s3 92 KB / 0
nodes. `ping.env` is chmod 600 on the box; the installed script is byte-identical to the repo.

### Six review findings from the merge, closed on `claude/backup-review-followups`

**The arc's CROSS-FILE rules now live in CLAUDE.md §14i** — they had no home in that file, so each was
only as durable as whoever last read `docs/DEPLOY.md` §6. `ops/` was also missing from §10's repo
layout entirely. **The single-site rules were deliberately left out of it**: `tar --anchored`,
`docker ps -a`, `--keep` ≥ 1, `ping.env` parsed-never-sourced and the blobs in the archive each carry
their whole argument inside `ops/backup-db.sh` itself — beside the line you must edit to break them,
or in that file's header — so hoisting them into a file loaded every session buys nothing that opening
the file does not, and CLAUDE.md's own header says length there is a tax on every future task. §14i's framing names them so the omission cannot be
misread as their having been dropped.

PR #155's Critical defect and the `--keep 0` guard were fixed before merge; six further findings were
deliberately left as separate decisions and are closed here. **`bin/ci` covers none of this code** —
it is shell, cron and docs — so each was reproduced *first* against a stubbed box: a scratch `$HOME`,
a container table, docker "volumes" as directories carrying a device marker, real `sqlite3`/`tar`
archives, and fake `ssh`/`scp`/`docker`/`curl`/`crontab`/`timedatectl`. Nothing touched the NAS or a
live volume. Baseline **12 passed / 17 failed**, after **38 / 0**, and every guard was then
mutation-checked by breaking the thing it guards — **7 of 7 went red**.

**One harness fact worth keeping:** `ops/backup-db.sh` resets `PATH` on its second line (deliberate,
cron's PATH is minimal), which wipes any stub directory. Exported bash **functions** survive a `PATH`
reset where a stub directory does not, so `docker` and `curl` are shimmed that way — a PATH-based
fake cannot test that file at all.

1. **An ad-hoc backup marked the NIGHTLY's monitor down.** The vanished-container arm pings and sits
   *above* the `$TO_STDOUT` branch, so `bin/backup-db` against a missing container pushed
   `status=down` at the nightly's own push monitor — including the pre-restore backup inside
   `bin/restore-db`, i.e. precisely mid-incident. Both `ops/backup-db.sh` and `docs/DEPLOY.md`
   asserted the opposite. One `$TO_STDOUT ||`; the failure is still reported by exit status to the
   person standing there.
2. **The nightly never checked it was writing to the array.** It mounted `$OUT_VOLUME` blind, and a
   volume name that does not resolve is not an error to Docker — `docker run -v name:/dst` **creates**
   it, as a plain local volume on the VM's own disk. So a `docker volume rm` (or any Kamal run
   re-ensuring the name) would have sent ~44 MB a night into the very disk the array was chosen to
   avoid, verified its own archives there, and pinged green — while `bin/backup-status` read the same
   recreated name and called it healthy. Now refuses unless the volume has a device option, pinging
   `down`. Handles both `""` and `<no value>`, which different Docker versions print for an
   options-less volume; dropping that normalisation is its own mutation check. The installer keeps
   the exact-path comparison (it knows `BACKUP_NAS`); the nightly asks the weaker sufficient question,
   because threading a path through a crontab line means a bare `%` is a newline and this box has a
   share whose name contains a space.
3. **The restore rehearsal proved less than it claimed.** `--into` advertised "extraction, file
   ownership and the app's own boot", but ran `sqlite3` with `--user 0` and booted nothing. Root reads
   a file whatever its mode, so **the check could not fail for the one reason a rehearsal exists**.
   Now runs as the container's own `Config.User`, which does go red on a broken `chown` (verified both
   directions). The boot half was **narrowed, not built**: a bare `docker run` of the image has no
   `RAILS_MASTER_KEY` (boot dies on `secret_key_base`) and no `LIBRARY_BACKEND`/`LIBRARY_PATH`, which
   `LibraryBackendCheck` refuses to start without (§14a) — a "boot" would fail for reasons unrelated
   to the archive and teach nothing.
4. **Any ad-hoc backup silently replaced the nightly's implementation.** `bin/backup-db` scp'd
   `ops/backup-db.sh` straight onto `~/tinkerex-ops/backup-db.sh` on every run, so whatever was in the
   last person's checkout became what cron executed that night. The "one implementation, two callers"
   intent is right; two unsynchronised writers to one remote file is not it. Now pushed to a per-run
   temp path and removed afterwards — **`bin/backup-cron-install` is the only writer of the installed
   copy.**
5. **The safety backup blocked the emergency it exists for.** `bin/restore-db` runs `bin/backup-db`
   first; when the database is corrupt or the container is gone — the usual reasons to restore — that
   fails and `set -e` aborted the restore with backup-db's error and no sign the restore had been
   abandoned. Added `--no-pre-backup`. **The default is unchanged** (a failed pre-backup is still
   fatal); what is new is that the refusal names the way past itself, and the confirmation prompt no
   longer promises a backup that was switched off.
6. **`CRON_TZ` was never set and the timezone was never asserted.** A crontab time is a *local* time,
   so "03:30 America/New_York" held only if the VM's clock happened to agree — and a stock Ubuntu
   server is `Etc/UTC`, firing the same line at 23:30 Eastern with nothing looking wrong.
   **Asserted rather than pinned, on purpose:** a cron that does not implement `CRON_TZ` (busybox; it
   is not POSIX) parses that line as an ordinary environment assignment and ignores it — a guard that
   silently does nothing, this repo's dominant failure shape. `bin/backup-cron-install` now reads the
   zone back and refuses *before* touching anything, `BACKUP_TZ` accepts a different one deliberately,
   and `bin/backup-status` re-reads it on every run so a zone changed after install cannot go on
   contradicting the doc. Adding that argument to `backup-status` also shifted its ssh positionals —
   the trap its own line 21 warns about — so a scenario drives it end to end.

**Recorded rather than fixed: the archives are unencrypted on a guest-writable CIFS share.** Anyone
on the LAN can read *and delete* 14 nights of every deployment's full production database. The
digests are the least of it — bcrypt is offline-crackable but slow, and the device/share-link
digests are SHA-256 of 256-bit randoms — while the **catalog and every preview blob are in the
clear**, and `dir_mode=0775` on a guest share means a stranger can delete the backups with nothing
reporting it until staleness trips 30 hours later. Accepted for a home LAN, now written down in
`docs/DEPLOY.md` §6 with what each alternative costs, because an unstated trade-off is
indistinguishable from one nobody noticed.

**Left open:** the 03:30 run has no interlock with a deploy landing the same minute. The snapshot is
WAL-safe regardless, so the worst case is a *correct* backup of a half-migrated schema. Nothing
verifies the notification channel out of Uptime Kuma itself — proving that end would mean flapping
a monitor and firing a real alert. **And these five scripts still have no gate.** The stubbed harness
that found all six findings was deliberately not committed: a gate in `config/ci.rb` requires a
matching job in `ci.yml` (`test/ci_hygiene_test.rb` asserts the two lists cannot drift), which means
a new job on the single registered self-hosted runner — and the harness leans on macOS/GNU
differences it papers over with a `date` shim, so it would not behave the same there. Committing it
*without* a gate is the worse option: an unrun fake rots into §14e's trap, where a fake that shares
the code's misunderstanding confirms it. Worth revisiting as one gate covering all of `ops/` if a
Linux runner is ever registered (§12.6).

---

## 2026-08-06: each Unraid backend gets a second hostname, because `.local` is unreachable from a phone (branch `claude/tailscale-unraid-share-access-7k4ae1`)

**The question that started it:** *"is there a way for me to access the unraid share version
website through my tailscale network?"* Yes — and the obstacle was never the network. All three
backends sit behind one kamal-proxy that routes on the **`Host` header** (`deploy.yml`'s `proxy:`),
so reaching the box by its Tailscale IP, or via a subnet router advertising `192.168.1.0/24`, gets
packets to the box and then **404s** — an unregistered Host, not a connection failure. Fix the
name and it works.

**Why a second name rather than a DNS rewrite for the existing one.** With AdGuard on the box the
obvious move is a rewrite for `share.tinkerex.local` → done. It does not work: **`.local` is
reserved for mDNS (RFC 6762)**, and macOS/iOS resolve it through Bonjour without ever consulting
the configured resolver — so the rewrite is silently ignored on exactly the devices that cannot
edit `/etc/hosts`. `.home` is not mDNS-hijacked, so an ordinary DNS server can answer for it.

**What changed — config only, no app code.** Each of the three destinations moves from
`proxy.host` (singular) to `proxy.hosts` (plural) and registers both names:

| destination | names registered |
|---|---|
| `deploy.yml` (chunk) | `chunk.tinkerex.local`, `chunk.tinkerex.home` |
| `deploy.share.yml` | `share.tinkerex.local`, `share.tinkerex.home` |
| `deploy.s3.yml` | `s3.tinkerex.local`, `s3.tinkerex.home` |

`.local` is **kept**, not replaced — every existing client reaches these through an `/etc/hosts`
entry, and dropping the old name would break them the moment the new one landed. `deploy.ovh.yml`
sets no `proxy` block at all and is untouched.

Plural `hosts` is the supported spelling on the pinned kamal (2.12.0), verified against the tag
rather than assumed: `def hosts; proxy_config["hosts"] || proxy_config["host"]&.split(","); end`.

**The verify probe was widened with it, and that is the load-bearing part.** `.claude/commands/
deploy.md` health-checked `-H 'Host: $h.tinkerex.local'` only. A missing or fat-fingered `.home`
entry deploys **perfectly green** under that probe and fails later, from a phone, as a bare 404 —
this repo's recorded failure shape (a green check over something that never worked). It now loops
both suffixes, six checks instead of three.

**Not done here, and deliberately.** The rest of the path is box-side configuration, not repo
state: the AdGuard rewrites, Tailscale split-DNS pointed at AdGuard, and the nginx/NPM proxy host
(forward to `192.168.1.95:80` — kamal-proxy; Puma's 3000 is not published on the VM). Two findings
recorded while tracing it:

- **`FORCE_SSL=1` would be safe behind NPM**, which is not the usual answer for a proxy in front of
  a proxy. The kamal config sets no `ssl:`, so kamal-proxy defaults `forward-headers` to
  `!TLSEnabled` — **on** — and it preserves an inbound `X-Forwarded-Proto` rather than overwriting
  it. NPM's `https` therefore reaches Rails intact and `assume_ssl` believes it, so no redirect
  loop. Left unset for now: nothing terminates TLS yet, and no public CA will sign a `.home` name.
- **`crypto.subtle` (`lib/chunk_upload.js:5`) is a secure-context API reached only from
  `uploadChunkFile`.** Share is `port_writable`, so its uploads go through `uploadPortFile` — a
  plain FormData POST — and are fully functional over plain HTTP. The same line implies browser
  uploads on the **chunk** deployment are broken at `http://chunk.tinkerex.local` today, on the
  LAN, independent of any of this. **Not verified in a browser** — recorded as a lead, not a fact.

---

## 2026-08-06: click a shape in a .lbrn2 and it tells you how big it is (branch `claude/lightburn-shape-dimensions`)

**The question that started it:** *"in the lightburn parser are you calculating the size of each
shape, and is there any way we can implement that if you click on a shape it tells you its
dimensions?"* Answer to the first half: **no.** `Lbrn2.each_geometry` yields every drawable
contour's points and `job_size` folds all of them into **one** `BBox` — the "Job size" row in the
Laser Settings panel. Per-shape extents were computed and thrown away.

The obstacle to the second half was never the parser. The file page shows LightBurn's **own
embedded PNG** (57 of 58 real exports carry one) and even the fallback rasterizes our SVG via resvg,
because `Maker::Previews::Svg` refuses to inline user SVG as an XSS rule. There was nothing on the
page to hit-test, and a raster's pixels have no mapping back to mm.

**Shipped:** a **Measure** button on `.lbrn/.lbrn2` file pages. It fetches a coordinate payload,
draws the outlines as an SVG built in the DOM, and reports the clicked contour's size — `40 × 20 mm`,
or `⌀6.2 mm` when it is round. Alt-click widens to the whole object. Scroll to zoom, drag to pan.

**Architecture:** a new `geometry` **preview kind** through the existing pipeline — `Enqueue` →
`GeneratePreviewJob` → `Lbrn2.render(kind: "geometry")` → `LbrnGeometry` → JSON attached as the
Preview's asset and served from its blob URL, off Rails. It is the **first kind to exercise that
seam end to end**: `model_glb` has been declared in `Preview::KINDS` all along but is refused by
`Mesh`, so nothing ever produced a second artifact from one file before this.

**Sized by measurement, not guesswork**, over the 58 real exports at `~/Documents/3d printing copy`
(gzipped): bounding boxes alone are **median 0.6 KB / worst 15 KB**; full outlines **12 KB / 734 KB**;
outlines thinned 3:1 **5 KB / 281 KB** — the scheme #145 deletes; RDP at 0.01 mm supersedes it at
**8 KB / 208 KB**, smaller AND correct. Server parse+walk: median 7 ms, worst 436 ms. Two findings
shaped the payload — **JSON beats shipping the SVG by up to ~4,000×** (`metal test 5.lbrn2` is
1.45 MB gzipped as SVG and 0.1 KB as geometry, because the SVG inlines the placed photo's base64),
and **the biggest files are the cheapest** (`pics.lbrn2` is 24 MB holding 2 shapes; its cost is
fetching bytes, not parsing them — which is why the work belongs in a job, not a request).
`rake lbrn:geometry_report[<dir>]` reproduces the table. Current reading: 58 files, no skips,
median 5.7 KB / 7.9 ms, worst 284.6 KB. (Superseded by #145 and #149 below — the shipped figures
are median 8.0 KB and a build ~32% faster on the box.)

**Nine guards on this branch could not fail for the reason they existed**, and every one was found
by mutation-checking rather than by reading. Recorded because the pattern is more useful than any
individual bug — the full list is in
`docs/superpowers/plans/2026-08-06-lightburn-shape-dimensions.md` under "Corrections made during
execution":

- The bezier-circle fixture was never asserted to be **round**. Its bbox is pinned by four on-axis
  vertices, so swapping the `c0`/`c1` handles yields a **four-lobed shape with radii 4.14–10.0**
  and all nine assertions stay green.
- A mutation that changed **which** object id was shared rather than **whether** — with one
  `<Shape>` in the fixture, both behaviours are indistinguishable.
- Fixing that opened a hole in the *other* mutation: ids `[1, 2, 2]` have the same unique count
  **and** the same density as the correct `[1, 1, 2]`. Only a positional comparison separates them.
- The union-to-`job_size` guard could not catch a measure-after-thinning bug, for a reason worth
  more than the gap: **`BEZIER_SAMPLES % DECIMATE_STRIDE == 0`**, so decimation drops only
  intermediate curve samples and never an original vertex. **That reasoning was wrong in general
  and #145 is the correction** — it holds only for an all-bezier contour, which
  `bezier-circle.lbrn2` happens to be.
- `CIRCLE_TOLERANCE` was settable to **1,000,000** with everything green.
- Four payload fields (`job`'s origin, `c`, `i`, `PRECISION`) were asserted with `key?` rather than
  by value — including `i`, the only thing standing behind the bitmap-exclusion promise.
- A "user does not own it" test used a node id existing **nowhere**, so it 404'd either way.
- Two bugs in the plan's own controller code, found by running it: calling `Enqueue` unconditionally
  on a poll makes the action's `"failed"` branch **dead code** and re-enqueues a doomed render on
  every poll; and a plain `get` defaults to `:html`, so `RecordNotFound` answered **302 to
  `files_path`** rather than 404.
- `perform_enqueued_jobs { get file_path(...) }` cannot make a thumbnail ready — the block form only
  runs jobs enqueued *during* the block, and `#show` enqueues nothing.

**The through-line: an aggregate assertion — count, uniq, density, sum, or a union over a whole
document — is the shape most likely to be green over a wrong answer.** Six of the nine were one.
Four were caught by an implementer reporting an honest *negative* result on a mutation the plan
predicted would fail, rather than adjusting the test until it went red.

### What followed, same day, and why (PRs #145, #147, #149, #150, #151, #152, #153)

The feature shipped and then took **seven more PRs**, every one started by the user looking at the
real thing. Recorded together because the pattern is the lesson: each round was found by a person
opening a page, and none by the suite.

**#145 — curves and text were being mangled.** The drawing payload thinned contours by a fixed
INDEX STRIDE, justified by `BEZIER_SAMPLES % DECIMATE_STRIDE == 0`. True — but only for an
all-bezier contour: `polylines` appends 12 points per `B` segment and exactly **one** per `L`, so a
single straight edge shifts every later index and the alignment collapses. For an `L` segment that
one point IS a vertex, so dropping it cuts the corner off. Measured: **1148 of 5259 thinned
contours displaced by >5% of their own size, worst case 58.7 mm.** Replaced with Ramer-Douglas-
Peucker at 0.01 mm — error-bounded by construction, corners kept by definition, and *smaller*
(208 KB worst case against the stride's 285). `bezier-circle.lbrn2` is all-bezier, which is exactly
why the guard asserting that coupling passed throughout.

**#147 — the fix didn't reach anyone.** Four already-measured files kept serving mangled curves
after the deploy and had to be destroyed by hand. A preview is stale on **two axes** and only
`version_id` (content) was checked; nothing asked whether the CODE had moved. Added
`maker_previews.renderer_revision`, `NOT NULL DEFAULT 1` so adding the column didn't itself trigger
a full-library rebuild, and per-KIND so a geometry fix doesn't re-render ~1400 thumbnails.

**#149 — first load was slow.** Profiled on the box rather than guessed: `build` was 2,763 ms of
which the WALK was 2,123 — the existing parser, not the Measure work. `GeometryIndex` parsed every
inline `<VertList>` up front and `geometry_for` then re-parsed each one at emit: 2.5 MB of text,
twice. Consulting the index first cut it to 1,878 ms (**-32%** on the box). The bigger user-facing
win was the poll schedule: `[400, 800, 1500, 2500]` checks CUMULATIVELY at 400/1200/2700/5200 ms,
so a 3.5 s render went unnoticed until 5.2 s. **Measured and dropped:** skipping the index for
documents that never instance paid +0% and was removed rather than carried.

**#150 — paint order, and the palette.** `nested-plate.lbrn2` (a plate and a hole on a SHARED
centre) finally made the hit-test rule testable; reversing the sort turns it red. And CLAUDE.md's
refusal to hard-code LightBurn's palette was relitigated deliberately — the Measure view now draws
OUR outlines, and the values are no longer guesses: 16 of 30 were RECOVERED from the embedded
thumbnails by mapping contours into pixel space and reading what LightBurn painted. The colour
ships in the payload (one definition) as an SVG PRESENTATION ATTRIBUTE, so `--selected` can still
outrank it.

**#151 — layers labelled by colour.** Three arms: a user's own name wins; else the colour's name;
else the file's label VERBATIM — reconstructing it as `C#{index}` loses LightBurn's zero padding
and turns `C00` into `C0`, which a pre-existing flow test caught.

**#152 — the revision check was unreachable.** `Enqueue` compared revisions correctly from day one,
but `thumbnails_for` matched on `(kind, node_id, version_id)` alone, so a stale row counted as
present and backfill skipped it; `#show` never enqueued at all. **172 of 174 LightBurn thumbnails
sat at revision 1 through two deploys that had bumped it.** Every test of the mechanism passed
throughout — they all called `Enqueue` directly and none opened a page.

**#153 — and that fix broke the preview.** Blanking a stale row to `pending` is right for a CONTENT
change (the artifact depicts a different file) and wrong for a RENDERER one (same file, older
code): the file page doesn't poll, so it stranded a spinner. Now only content blanks. A failing
test then caught that geometry needs the opposite — it is DATA the client measures from, and its
client DOES poll — so `#geometry` reports `pending` whenever it had to enqueue, without reading the
row's status. Same mechanism, opposite right answers.

**The through-line, and the reason this entry is long:** eleven guards across this arc could not
fail for the reason they existed, and the recurring shape is an assertion that holds whether or not
the code is right — an aggregate (count, uniq, density, a union over a document), a presence check
where a value was meant, an attribute where the computed style was meant, or a fixture whose two
cases are indistinguishable (a CutIndex 0 contour whose palette colour equals the fallback). The
last three rounds reached the user because **every verification was server-side**: `rails runner`
and headless Chrome, never a browser. Both #152 and #153 were invisible to that.

Invariants: **CLAUDE.md §14h**. Spec and plan:
`docs/superpowers/specs/2026-08-06-lightburn-shape-dimensions-design.md`,
`docs/superpowers/plans/2026-08-06-lightburn-shape-dimensions.md`.

---

## 2026-08-05: a re-save asks before it overwrites — the other half of the autosort bug (branch `claude/addon-save-overwrite`; bundles on `claude/save-overwrite-confirmation`)

Follow-up to the entry below, and the answer to the question it left open: **why did v3 and v5 sort
but not v4?** Because **v4 was saved twice.** Reproduced exactly —

```
[v3 saved once]       -> ["design"]
[v4 save #1]          -> ["design"]
[v4 save #2]          -> ["design", "harbor-signs"]   <- two copies
[after 3 more sweeps] -> ["design", "harbor-signs"]   <- stuck
```

The door's collision check and the sweep's look at **different folders**. `refuse_taken_names!` asks
about the folder the user picked — vacant, because copy #1 had already been filed into `design/` —
so the save was accepted, and the sweep then could not place it. CLAUDE.md §12 item 11 recorded that
as an open product question; this closes the half that bites.

**The decision was overwrite-after-confirmation** (not auto-rename: the user is iterating on one
drawing, not accumulating copies; not silent overwrite: it destroys work without asking).

### What landed, in six steps

1. **`FileLayer#write(replace:)`** on Share + S3 — the opt-in the clobber refusal is the default for.
   It **must reuse the existing node**; a delete-then-create passes any bytes-oriented test while
   orphaning every attachment (§14a's landmine). Cheap on both: Share's temp-then-rename is already
   atomic over an existing destination and `put_object` overwrites by definition, so a replace
   *skips* work. In the shared write contract, so the two adapters cannot answer differently.
2. **`LibraryOutput`** gains a per-file destination and `replace:`. Per-file because one save can
   collide on some outputs and not others — boxes emits `<base>.svg` and `<base>-plan.svg` together.
   Chunk's replace is simply a new **version** against the existing node (`base_version_id` = its
   current), so it touches the port not at all and the old bytes stay restorable.
3. **`ProjectIntake.destination_for`** — where a not-yet-written file will end up, and what is
   already there. Creates nothing; nil outside a project folder's own root.
4. **409 `would_replace` + `overwrite`** at `Tools::AddonsController#create`. Kept distinct from the
   existing 422: one never succeeds on retry, the other is a question.
5. **OpenSCAD needed no dialog** — the plan called for one, and reading the code first showed the
   door cannot collide (its filename embeds `state.id`). A guard on that property landed instead.
6. **`save.js` in all three bundles** (second repo) — reads the 409, asks `window.confirm`, re-POSTs
   with `overwrite=1`. Declining is reported separately from failing.

### Verification

Bare `bin/ci` green, exit 0 at every step; three legs identical at **1959 runs / 6807 assertions**,
system tests **46 / 260**. Every guard mutation-checked and restored: the port's node reuse, chunk's
node reuse, the kwarg default, the conflict list, the OpenSCAD filename, and the browser helper's
`overwrite` append.

**Proven in a real browser**, because the client half is observable nowhere else: the hermetic
fixture addon imports a verbatim copy of the shipped helper and drives save → re-save → accept →
one node with the original `node_id`, plus a dismiss path asserting the original bytes survive.

### Three findings that cost real time

- **A comment claimed a mutation it had not run.** It said narrowing the conflict list to `.first`
  turned the multi-file test red; with only ONE colliding file that mutation is a no-op and it
  stayed **green**. The test now uses two collisions plus a free name — the smallest shape where
  "all" and "the first" differ. The false sentence is recorded at the test rather than deleted.
- **A fixture that could not exist on share/s3.** The already-filed file was built with
  `nodes.create!`, leaving `storage_path` NULL — and that column is how the *port* addresses a file,
  so `Share#write(replace:)` missed it and created a second node: chunk green, share/s3 red. The two
  lookups are different **on purpose** (chunk nodes have no `storage_path`) and now say so.
- **A syntax check that checked nothing.** `node --check "$f" | head -2 && echo ok` reports `head`'s
  exit status, so ten JS files "passed" without being parsed. Re-run properly against `.mjs` copies.

### Left open

`:model_bundle` in the same position as `:attached_elsewhere` (weaker argument, no evidence it bit
this file); the eager cap's silent `Result`; and a project-wide name scan, §12.11's broader question,
which this deliberately does not attempt — it closes the destination the file is actually headed for,
without a library-wide scan on every save.

---

## 2026-08-05: an addon-saved file did not autosort — two defects on one path (branch `claude/file-mover-autosort-bug-c83346`)

Reported as "there is a bug in the file mover, `harbor-number-v4.svg` did not autosort", on a
**share** deployment, from a **`/tools` addon save**. The happy path was never broken — `.svg` at a
project root files into `design/`, and the 74 existing intake/folder tests were green throughout — so
this was a **conditional** skip. Probing (rather than reading) enumerated every condition that leaves
an `.svg` at a project root: `:attached_elsewhere`, `:model_bundle`, `:conflict`, and the eager cap,
the last of which returns `moved=0, skipped=0, skips=[], status=:ok` — **indistinguishable from
"nothing to do"**. Two of those turned out to be defects rather than policy, and both sit on the
door the report named.

### Defect A — the addon save doors never nudged

§14f names seven ways a file reaches `Projects/<slug>/`. The three web upload doors call
`ProjectFolderIntake#intake_project_folder` inline and a device push got one in 2b9ca85 — but
**neither addon save door did**, and the save dialog *defaults to the current project's folder*. So
the user watched the redirect land on a file that visibly had not sorted. The wait is up to 15
minutes on chunk; on **share/s3 there is no `project_folder_intake` schedule at all**
(`ProjectIntakeJob.sweep_all!` declines on a scannable backend), so it rides `Library::ScanJob`'s
poll — which is the deployment this was reported from.

Both doors now nudge (`Tools::AddonsController#create`, `Tools::OpenscadController#create`), with
the concern included on `Tools::BaseController` so a third inherits it. **One sweep per save, not one
per file** — every file in a save shares `parent_node_id` and `.for_node` sweeps the owning PROJECT,
so per-file calls would re-sweep the same project N times for one request — and **after** the attach,
per `ProjectFolderIntake`'s own call-site ordering rule.

Wiring the nudge in also made §14f's "a caller must READ the return value" reachable here:
`#project_intake_notice` was split so the conflict clause has one home
(`#project_intake_sentence`), with the LEAD-IN left to the caller — the doors genuinely differ there
("Uploaded grid.svg" vs "Saved “3mm birch test”") and must not differ on what follows. The upload
doors' strings are **byte-identical** to before the extraction, pinned by the two tests that assert
the full sentence. `#unfiled_by_conflict` is the plural form, because a save writes a SET and the
colliding output need not be the first.

### Defect B — `:attached_elsewhere` refused a move that never left the folder

`ProjectIntake#place` asks `AttachToProject#refusal_for`, whose `:attached_elsewhere` arm exists —
by its own stated reason — because "a file should not be yanked out of the folder that project put
it in". That is a fact about the move's **SOURCE**, and it was written for `#call`/`#relocate`, where
the destination is this project's folder and the source may well be another's. `#place`'s move is
`Projects/<slug>/x` → `Projects/<slug>/<cat>/x`: the file is already inside this project's own
folder, so the precondition cannot hold. `node_id` never changes across a move, so the other
project's attachment survives regardless.

Unscoped it was **silent and permanent** — the file sat at the root through every sweep forever,
recorded only in a `skips` entry nothing but `rake projects:organize` prints. And it is reachable
without doing anything unusual: `CurrentProject#attach_addon_files_to_current_project` attaches an
addon's output to whatever project is **current**, regardless of which folder the save dialog wrote
it into, so **one addon save into a second project's folder made that file permanently unsortable** —
which is how A and B compose into the reported symptom.

Scoped at `#refusal_for` via `within_own_folder:`, **not** by `#place` filtering the symbol it was
handed: the three rules have one home on purpose, and a caller that filters the ANSWER is a second
place that has to know what each symbol means. The caller states its situation; the policy decides.
`:not_a_file` and `:model_bundle` stay **unconditional** — the bundle rule is deliberately about the
ATTACHMENT rather than the folder ("MEMBERSHIP IS THE ATTACHMENT, NOT THE FOLDER"), so it makes no
claim about where the file currently sits and has no equivalent argument for relaxing.

### Mutation checks (§15)

Every guard was reverted and confirmed red, then restored:

- `within_own_folder: true` removed from `#place` → the intake test goes red (`moved` 0, not 1).
- The kwarg's default flipped to `true` → **4** failures, including a pre-existing
  `attach_to_project_test.rb` case — proof the other doors genuinely still get the rule.
- `#unfiled_by_conflict` narrowed to `Array(names).first` → the multi-file test goes red while the
  single-file one stays green.
- Both addon-door tests were watched red before the nudge existed (the file's parent read
  `harbor-signs`, the project root, instead of `design`/`models`).

### Not fixed, and deliberately

- **`:model_bundle`** in the same position — the argument for relaxing it is weaker (see above) and
  there is no evidence it bit this file (an addon-saved `.svg` is not a `Maker::Model` member).
- **The eager cap's silent Result.** `for_node` over the cap answers
  `moved=0, skipped=0, skips=[], status=:ok`, which no caller can tell from "nothing to file". It
  does log a WARN, and the periodic sweep still files the backlog, so this is a reporting gap rather
  than a stuck file — recorded here rather than widened into.
- **A genuine `:conflict`** — if `design/harbor-number-v4.svg` already existed, the file correctly
  stays at the root. What changed is that the addon door now *says so* instead of a bare "Saved".

---

## 2026-08-05: the tray plan comes off the screen to scale — print, PDF, SVG, library (branch `claude/box-layouts-export-print-e3a7ce`; bundle branch `claude/plan-print-to-scale`)

The top view added on 2026-08-02 already computed the tray in real millimetres and, by reading the
very params the generator is about to be handed, could not drift from the cut sheet. But its `<svg>`
carried only a `viewBox`, and `application.css` sized it `width: 100%; max-height: 320px` — so
nothing about it was to scale, and the addon had no download or print at all. Now it prints 1:1, so
you can set real parts into the drawn compartments before committing material. **The cut sheet is
deliberately not in scope** — it is flat panels, and cannot answer whether your screwdriver fits
compartment 4.

**Design** `docs/superpowers/specs/2026-08-05-boxes-plan-print-to-scale-design.md`,
**plan** `docs/superpowers/plans/2026-08-05-boxes-plan-print-to-scale.md`.

Four modules in the bundle repo, all client-side — so `bin/build-push` is the whole deploy and Rails
is never rebuilt:

| | |
|---|---|
| `plan.js` | the coordinate model, **extracted out of `top_view.js`'s private `svg()`** so the panel and every export read one geometry; plus the print marks |
| `sheet.js` | pagination: a 10 mm overlap band, trim crosshairs, a per-page 100 mm calibration bar, tile registration labels, a 40-sheet refusal |
| `pdf.js` | uncompressed PDF 1.4, base-14 Helvetica, no font embedding, no dependency (~120 lines) |
| `export.js` | the four sinks — print (hidden iframe), PDF, SVG, and the untiled library SVG |

**Three things that cost real thought, and one that was wrong in the spec until it was checked:**

- **No inset.** The spec said to inset opening outlines by `t/2` to reach "the wall's inner face".
  That is wrong: a wall is drawn at `colX(i) - t` with width `t`, so it occupies
  `[colX(c) - t, colX(c)]` and its inner face **already is** the cell boundary. Insetting would have
  made every opening `t` too small on both axes — the exact error a 1:1 fit-check exists to avoid.
  Caught while working out the geometry for the plan, and corrected in the spec before any code.
- **Outlines come off a slot lattice**, not from merging rectangles: `(2·nc+1) × (2·nr+1)` slots,
  each labelled with a compartment id or `WALL`, emitting a segment wherever adjacent labels differ.
  Absent walls take the id of the cells they join, so a merged run has **no internal seam** — which
  a per-rectangle stroke would have drawn straight down the middle of an opening that has none.
- **The PDF y-axis flips** (SVG top-left, PDF bottom-left) and **a flipped plan is invisible on a
  symmetric tray**. The test uses an asymmetric layout for that reason alone.
- **`/Page`'s `/Parent` must be predicted** before the Pages object exists. The writer asserts its
  own prediction rather than trusting it, so a mis-prediction fails loudly at build time instead of
  producing a subtly broken file.

**Saved to the library as `<base>-plan.svg`, untiled and full size** — tiling is a property of the
printer, not of the drawing. No host change: `MAX_FILES` is 8 and `parse_files` already refuses
duplicate names within a batch. **SVG rather than PDF** because `parse_files` requires a String body
over JSON, so binary cannot round-trip; a base64 path would have cost a Rails redeploy for something
the PDF download already gives. (§14c's *"each save writes ONE file"* recorded deleting the
write-only `.params.json`, which duplicated `AddonState#data`. A second genuine output is not that.)

**Verification.** 22 new system tests in `test/system/plan_export_test.rb`, importing the bundle
modules through the host's real asset proxy in a real browser — so what is under test is the shipped
artifact. They assert the **wire format** (`width="162mm"`, `/MediaBox [0 0 595.28 841.89]`, the
literal `\327` escape), never a round-trip through our own code, because a reader of our own PDF
sharing our own misunderstanding is `FakeS3`'s shape (§14e). Four guards mutation-checked, each
confirmed red then restored: the `mm` suffix (kills 4 tests, including the end-to-end print and
library ones), the PDF y-flip, the tile overlap, and the merged-cell seam. `bin/ci` green in 47.8 s;
the three backend legs report identical counts (**1912 runs / 6613 assertions** each), system 44.

**Checked against real software, not just our own assertions** (§14e's "prefer a probe over an
argument"): poppler's `pdfinfo` parses the output cleanly — 2 pages, A4 595.28 × 841.89 pt — and
`pdftoppm` renders it correctly at 1:1, with the `×` and the em dash both resolving through the
WinAnsi octal escapes, and the tiled sheet showing its overlap band.

**What is NOT verified, stated plainly: nothing automated can prove the paper is right.** The
browser's print dialog defaults to "Fit to printable area", rescales silently, and no page can
detect or prevent it. That is what the 100 mm calibration bar is for, and confirming it means
printing a sheet and measuring it with a ruler. The PDF download is the sink that is exact by
construction.

`boxes-next` carries the same change: it was byte-identical to `boxes` and
`bin/check-fixture-drift` does not cover it (no host fixture), so letting it lag would be silent.

**Declined on purpose:** a title block (page labels stay — those are registration for taping tiles,
not decoration) and cut marks on the compartment openings.

---

## 2026-08-05: the chunk-GC grace window was dead code — the audit's seven "do now" items (PR #132, branch `claude/opus-audit-list-c37ecf`)

Works through the **"Do now"** table in `docs/AUDIT-2026-08-03.md` §5. Two items are correctness,
one closes a security channel, four are robustness. Rules landed in **CLAUDE.md §14c/§14e**.

### A-H1 — the grace window did not exist, and the sweep raced every bumper

`Gc.sweep_orphans!` frees chunks at `refcount: ..0 AND updated_at <= cutoff`, promising in its own
contract never to free a *freshly-zeroed* chunk. Every refcount mutation was a raw `update_all`,
which does not maintain timestamps — so `updated_at` only ever held its `insert_all` value and the
filter measured **creation age, not zeroing age**. For any chunk older than the window (every real
chunk) there was no protection at all. The sweep additionally took no user lock and never
re-checked `refcount` at delete time, so a concurrent `Commit#finalize` deduping against a still-
present row (0 → 1, **uploading nothing**) could interleave with the delete and strand a live
version on a chunk with no row and no bytes. **Silent permanent data loss**, managed/tiered only —
`RETENTION_POLICY` defaults to `keep_all`, which never decrements.

Fixed at four sites via `Gc.touch_refcounts!`, plus compare-and-delete in the sweep and
claim-then-decrement in `prune_version!` (which also makes overlapping retention passes safe
independently of the new job limit).

**Why the suite was green:** every sweep test hand-set `updated_at` with `update_column` — the
first one says *"bypass the updated_at touch"* out loud — and the "keeps a recently-zeroed chunk"
test used a chunk **created** moments earlier under the same frozen clock, so it passed whether or
not the decrement moved the column. The replacement ages the chunk and zeroes it now.

### The other six

| Item | Was | Now |
|---|---|---|
| **2.2** addon save | Presence-only filename check; share/S3 refused traversal in their own `leaf!` (→ unrescued 500), **chunk had no name check anywhere** so `"../../escape.txt"` became a live node. No transaction; chunk made duplicate siblings. | Door-level `MoveNode.valid_leaf_name?`, one transaction, pre-flight name check, `rescue_from` → 422/503 |
| **2.3** service proxy | Echoed sidecar `Content-Type` verbatim inline, same-origin — reachable via boxes' POST-only `/generate` returning Werkzeug's `text/html` 405 | Allowlist + `octet-stream`/`attachment` fallback |
| **2.4** `URI::Error` | 500 for any authenticated user on an asset path with a space or non-ASCII byte | Rescued in both clients → 404 |
| **A-M1** job overlap | No `limits_concurrency` anywhere | Scan/intake per-user `:discard`; retention global `:block` |
| **P1** Puma | 3 web threads sharing the process with the job supervisor, vs 30–90 s sidecar calls | `RAILS_MAX_THREADS: 16` (**next deploy**) |
| **CVE-2026-66066** | `bin/ci scan` RED | `rails` 8.1.3 → 8.1.3.1 |

### The bump exposed a latent misconfiguration

activestorage 8.1.3.1 adds an eager `require "image_processing/vips"`, and the engine's own
`rescue LoadError` matches `/libvips/` and `/image_processing/` but **not** the real message
("ImageProcessing::**Vips** requires the ruby-vips gem") — so it re-raised and **took boot down**.
`load_defaults 8.1` had been asking for `:vips` all along while this app deliberately ships no
`ruby-vips` (its in-process pool deadlocks the fork-based parallel runner; thumbnails shell out to
the `vipsthumbnail` binary). Set `variant_processor = :disabled` — the engine's supported answer,
which also removes the CVE's path structurally. Rule in §14e.

### Verified

Bare `bin/ci` green, **exit 0** (by exit code, not output text). All ten gates; three backend legs
**identical** at **1912 runs / 6613 assertions**, system tests 22 / 143. The audit's baseline at
`6095b87` was 1893 / 6498 — the **+19 runs are exactly the tests added here** (3 GC, 4 concurrency,
2 source, 1 proxy, 9 addon controller). Remote CI: all 7 checks pass, no divergence from local.

Every guard mutation-checked per §15 — reverted, confirmed red on exactly its own test, restored.

**Two failures on the first full run were self-inflicted and are recorded because the shapes
recur:** Brakeman flagged SQL interpolation in the new helper (the refcount delta is now a bound
parameter, not a `"+ 1"` fragment), and the new duplicate-name test reused `grid.svg`, colliding on
the **share leg only** with a file a sibling test leaves on disk that a DB rollback cannot undo.

### Left open by this arc

Everything in the audit's **"before SaaS"**, **"before the inventory/BOM UI"** and **performance**
tiers: the addon trust model (2.1), CSP `report_uri` + enforcement, per-user storage accounting,
`prune_changelog!`, `manifest_chunks` reclamation, `/tools` rate limits, sidecar auth, referential
integrity, bare-FK indexes. `test/jobs/concurrency_limits_test.rb` asserts **declarations and
computed keys, not runtime blocking** — Solid Queue enforces the semaphore in its own backend,
which the test env does not run; the file says so in its header.

## 2026-08-03: secrets resolve from 1Password per destination, with a preflight (PR #122, branch `claude/1password-persistent-access-13fe8f`; vault split on `claude/1password-vault-scope`)

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

---

## 2026-08-03: Phase B — addon bundles move to their own repo, and republishing one now deploys an addon without redeploying Rails (branch `claude/addons-repo-phase-b`, PR #117; finishes the arc PR #116 started)

**1905 runs / 6604 assertions / 0 failures / 0 errors / 11 skips — identical on chunk, share and
s3 — plus 22 system tests / 132 assertions.** Design:
`docs/superpowers/specs/2026-08-02-addons-runtime-bundle-design.md`. Plan:
`docs/superpowers/plans/2026-08-03-addons-repo-phase-b.md`. Invariants: CLAUDE.md §14c.

### What landed

Two PRs finish the arc the design doc set out to reach: **an addon change ships without a Rails
redeploy.** **#116** (`3e2c07e`) built the generic addon host surface —
`Tools::AddonsController` (shell / same-origin asset proxy / save) reading manifests off
`Maker::Addons::Registry`/`Maker::Addons::Source` — and migrated `generators` onto it as the
first manifest + plain-ESM bundle; `boxes` and `openscad` stayed on their own controllers with a
temporary hand-written gallery block. **#117** (`00f8a34`) is Phase B: the bundles move out of
the Rails image entirely, into a new private repo, `chaim354/tinkerex-addons` — a `Dockerfile`, a
tiny `nginx.conf`, `bin/build-push`, an MIT `LICENSE`, a README, and
`test/no_gpl_in_bundle_image_test.sh` (a mutation-checked §9 guard that no GPL ever enters the
permissive bundle image, directory-driven so a future sidecar migration is covered automatically)
— served by a static nginx container. That container boots on the Unraid host as the Kamal
accessory `addons`, no `port:`, internal-only, reachable on the `kamal` network as
`tinkerex-addons`, exactly like the two GPL sidecars. `deploy.yml` sets
`ADDON_SOURCE_URL: http://tinkerex-addons`; `deploy.ovh.yml` blanks it. `public/addons` is gone
from both the Rails image and git.

Verified live on all three Unraid backends, running Rails image `00f8a34`:
```
["URL",    "http://tinkerex-addons"]
["PATH",   nil]
["source", "Maker::Addons::Source"]      # the HTTP backend, not Source::Local
["addons", ["generators"]]
```

### The acceptance proof

This is the headline the whole arc was chasing: **does republishing a bundle deploy an addon
change without touching Rails?** Measured, not asserted. In `tinkerex-addons`, the Generators
addon's `description` in `addons/manifests.json` was changed (commit `1964370`, "test: prove
independent deploy"), then `bin/build-push`, then `kamal accessory reboot addons` on the Unraid
host — **Rails was touched not at all.** Observed:

- The accessory served the new description over the `kamal` network.
- All three `tinkerex-web-*` containers stayed on image `00f8a34` throughout, with uptimes of
  2-4 minutes, while `tinkerex-addons` showed **9 seconds** — the web containers were never
  restarted; only the accessory was.
- After evicting `Maker::Addons::Registry::CACHE_KEY`, Rails returned the new description. The
  registry caches manifests for 5 minutes, so *without* that eviction the gallery would have
  lagged by up to the TTL — but the **served bytes** changed the instant the accessory rebooted;
  only the **cached gallery read** needed the manual nudge to catch up early.
- The change was then reverted (commit `9add63b`, "Revert 'test: prove independent deploy'") and
  republished the same way; the original description was live again, Rails still on `00f8a34`
  throughout.

### Consequence for OVH

`deploy.ovh.yml` blanks `ADDON_SOURCE_URL` for the identical deep-merge reason it already blanks
the two sidecar URLs (CLAUDE.md §14c) — `tinkerex-addons` doesn't resolve off the Unraid host.
Combined with `public/addons` no longer shipping in the image, **OVH renders an empty tools
gallery** until it gets its own addons accessory. That is `Registry`'s rescue-to-`[]` degrade
path, not a 500 — and OVH is not currently deployed, so this is a recorded consequence, not a
live outage.

### Three findings that cost real time

- **Pointing `ADDON_SOURCE_URL` at the app's own process deadlocks.** Already recorded at
  CLAUDE.md §14e ("an app must not point a synchronous HTTP client at itself") from the #116 arc
  — nested synchronous HTTP into the same Puma pool measured 14-24s stalls and outright 404s at
  3-4 threads. That finding is *why* `Source::Local`/`ADDON_SOURCE_PATH` exists at all, and it is
  what makes Phase B's genuinely separate container (its own pool) the actual fix rather than a
  bigger thread count.
- **`kamal config` does not serialize `env:`.** Verifying an accessory's env vars through its CLI
  output silently matches nothing — the keys are simply absent from what it prints, not merely
  hard to grep for. Build `Kamal::Configuration.create_from` directly and inspect the resulting
  object instead of parsing CLI text.
- **A guard keyed on a naming convention silently fails to cover a differently-named sibling.**
  `test/deploy_hygiene_test.rb`'s OVH-blank guard grepped `/_SIDECAR_URL\z/`; `ADDON_SOURCE_URL`
  doesn't match that suffix and was unguarded until the pattern was widened to
  `/_SIDECAR_URL\z|\AADDON_SOURCE_URL\z/` (recorded at CLAUDE.md §14c) — any future accessory URL
  needs the same manual addition, because the guard covers a naming convention, not a category.

### Left open by this arc

- **`boxes` and `openscad` are unmigrated.** They keep their own controllers, routes and sidecar
  clients unchanged, and the gallery still carries #116's temporary hand-written block for both.
  Their GPL sidecars stay in *this* repo (`sidecar/boxes`, `sidecar/openscad`) until those addons
  migrate to the bundle pipeline — the permissive `tinkerex-addons` image must never gain a GPL
  sidecar, guarded by that repo's own `test/no_gpl_in_bundle_image_test.sh`.
- **OVH has no addons accessory** — see above; the tools gallery there is empty until one is
  booted.
- **The asset proxy is still uncached**, carried forward from #116 — a stale cached bundle would
  read as "my fix didn't deploy," worse than a slow one. Unchanged by Phase B.

---

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
