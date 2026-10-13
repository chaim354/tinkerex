# Invariants — addons and GPL sidecars (CLAUDE.md §14c)

> **This is CLAUDE.md's §14c, moved out of the always-loaded file on 2026-08-25.** It is *area*
> knowledge: it binds hard when you are in `app/services/maker/addons/`, `app/controllers/tools/`,
> `sidecar/`, or anything the addon SDK serves — and not at all otherwise. It was being paid for on
> every session and needed on few. **The rules did not change and nothing was dropped.**
>
> **The `§14c` anchor still exists in CLAUDE.md and code still cites it** — a citation resolves to
> the stub there, which points here. Same for every `§14c` in a code comment.
>
> Read this file *before* editing an addon, a sidecar, the SDK, or the save door. Every line below
> cost a real bug; `docs/STATUS.md` has the full story for any of them.

- **Two sidecars exist, both GPL invoked ONLY over HTTP, never linked** (§9): `sidecar/boxes`
  (GPL-3.0) and `sidecar/openscad` (GPL-2.0). **Three facts are guarded by
  `test/deploy_hygiene_test.rb` rather than memory** — the first two were real shipped bugs,
  and all three live in files the Rails process never loads, so no other test can see them:
  1. **`/sidecar/` is in `.dockerignore`** — the Rails `Dockerfile` does `COPY . .`, so
     without it the copyleft trees are baked into the **permissive** app image. Never
     imported or executed, but *shipped*, which is exactly what §9 exists to prevent.
  2. **Each sidecar's URL env var must be EXPLICITLY BLANKED in `deploy.ovh.yml`** — the
     accessories run on the Unraid host and Kamal **deep-merges** `env.clear`, so the OVH
     overlay otherwise inherits an Unraid-only hostname, the addon reports itself available,
     and every call fails — strictly worse than greying out.
  3. **Each GPL sidecar image must carry its own licence text INSIDE it** — we build and push
     these to a registry, which is redistribution.
  The guard is **directory-driven, not a hard-coded pair**, so a third sidecar is covered the
  day it appears — and it asserts *two* things, because a "has a LICENSE beside it" discovery
  filter silently skipped the **worse** case: a sidecar whose author never committed a
  `LICENSE` at all was invisible to the guard written to catch exactly that. Found by
  planting a synthetic sidecar and watching the test stay green, not by reading it.
- **A BUNDLED THIRD-PARTY `.scad` MUST CARRY ITS OWN LICENCE, AND THAT IS GUARDED IN RUBY BECAUSE
  `bin/ci` DOES NOT RUN pytest.** `sidecar/openscad/catalog/` redistributes other people's designs
  inside an image we push, so §9 binds per FILE, not per repo — and the catalog's own `NOTICE`
  records why: of four candidates, **two declared a different (more restrictive) licence in their
  own header than their repo's `LICENSE` file did**, one of them NonCommercial. *Read the file, not
  the repo.* `sidecar/openscad/tests/test_catalog.py` checks this thoroughly — and **none of
  `bin/ci`'s gates runs it** (seven when this was written, eight since `test-app` landed
  2026-08-19 — the count moves, the fact that none of them is pytest does not), so until
  2026-08-12 the only licence guard that actually
  EXECUTED was `openscad_controller_test.rb`'s per-tile assertion, which died with that controller.
  Its replacement is in **`test/deploy_hygiene_test.rb`** (directory-driven over
  `sidecar/*/catalog/catalog.json`): every entry has a licence, an attribution and a pinned commit;
  no forbidden term (NC/SA/GPL); every `.scad` on disk is listed; every listed file and ref appears
  in `NOTICE`. It guards the **DATA, upstream of every renderer** — a catalogued file with no
  licence makes the display correct and empty — and it is mutation-checked four ways, including the
  lowercased-needle bug the Python original shipped with (`"-NC" in "cc-by-nc-sa-4.0"` is false).
  **The DISPLAY half is now the bundles repo's obligation** (`chaim354/tinkerex-addons`): the
  OpenSCAD UI is a bundle, `GET /generators` hands it `license`/`attribution`/`source_url` per
  entry, and nothing in THIS repo can assert that a tile paints them. That was a deliberate choice
  over vendoring the bundle into `test/fixtures/addons/` — the vendored `boxes` copy has **no sync
  guard on this side**, so a licence assertion against a stale snapshot would go green while the
  live bundle dropped the line, which is the worst possible failure for a compliance check.
- **Addons are manifest-driven, not listed in this repo.** `Maker::Addons::Registry` builds
  `Addon`s from manifests fetched by `Maker::Addons::Source` and caches the index (`CACHE_KEY`,
  5-minute `TTL`) **when the source says it may — `Source#cacheable?`, the source's own answer and
  not a class check, exactly as the two asset paths ask it.** Over HTTP that is true, so
  republishing a bundle *is* the deploy and takes up to the TTL to be noticed; the dev/test
  `Source::Local` answers false and is re-read every time, so an author's manifest edit is visible
  immediately. Honouring it for assets only was the bug: bundle bytes went fresh against a manifest
  five minutes old, which is worse than uniform staleness, because the half that updates makes you
  believe the other half did. Three refusals matter: a manifest
  missing a `REQUIRED` key or declaring an `api_version` other than `Registry::API_VERSION` is
  **skipped, not raised on** — one bad addon must never take `/tools` down (the `api_version` arm
  is mutation-checked); and a source outage returns `[]` for **that request only**, because the
  `rescue` sits **outside** `Rails.cache.fetch` — inside, a two-second blip greys every addon out
  for the whole TTL (also mutation-checked, and only against a real `MemoryStore`: the suite's
  default `:null_store` can't observe caching at all — same shape as §14e's rate-limiting note).
- **ONE generic surface serves EVERY addon, with NO EXCEPTIONS LEFT** — `Tools::AddonsController`
  (shell / same-origin asset proxy / save), which is why a new addon needs no Rails redeploy.
  `generators`, `boxes` and — last, 2026-08-12 — `openscad` have all migrated:
  `Tools::OpenscadController`, its five views, its five hand-written routes, `OpenscadClient` and
  the hardcoded gallery card are **gone**. Any statement elsewhere that qualifies this rule
  ("except openscad", "the last bespoke addon surface") is stale — the gallery is now
  manifest-only, guarded by a CARD COUNT in `home_controller_test.rb`, which is the only assertion
  shape that can see a card the `@addons` loop did not produce.
  **Route order is still load-bearing, but its justification changed**: `tools/:key` matches any
  two-segment `/tools/*` path and shadows any such route declared after it. It no longer protects a
  live sibling — there are none — so the ordering is now kept for the NEXT two-segment `/tools/*`
  route somebody adds, and `config/routes.rb` says exactly that. The mutation check is kept as the
  evidence precisely because it can no longer be re-run here: moving `tools/:key` above
  `resources :boxes`, while boxes still had its own block, took `boxes_controller_test.rb` from
  green to 12 failures + 2 errors. It does **not** collide with `tools/addon_states/:id/params`
  (four segments; Rails requires a segment-count match) — an earlier draft of the routes comment
  claimed it did and was verified false via `Rails.application.routes.recognize_path`.
- **AN ADDON DECLARING A SERVICE THIS DEPLOYMENT HAS NO URL FOR GREYS OUT, NAMING THE SERVICE** (the
  maker's sentence; since F, 2026-10-13, the ENV VAR is named in Help's operator section and
  `docs/INSTALL.md`, not on the card). This is a REGRESSION the openscad retirement would otherwise have shipped: the
  hardcoded gallery card greyed itself out on `OpenscadClient.configured?` — an env check living in
  a view — so deleting the card deleted the only thing that asked before rendering, and a
  deployment without the accessory would show an ENABLED tile whose bundle 404s on its first
  `host.service.*` call. `boxes` already had the same latent hole, unobserved only because every
  leg serving addons happens to set `BOXES_SIDECAR_URL`. It is the second arm of
  `Addon#unavailable_reason`, after `min_host` — the host level wins when both are wrong, because
  on a host that cannot run the addon at all "go and set a sidecar URL" is advice that will not
  help. **`Maker::Addons::Services` owns the env-name derivation, once**, because
  `Tools::AddonsController#sidecar_url_for` needs the same answer and a second
  `"#{name.upcase}_SIDECAR_URL"` is a string that drifts silently — get it wrong and the lookup
  returns nil, which reads as "not deployed". The manifest-vs-ENV split (spec §4.1) is untouched:
  the **declaration** check stays in the controller because that is the per-addon SSRF guard, and
  only the deployment-wide lookup is shared. A **blank** counts as unconfigured — Kamal's
  `env.clear` blanks rather than removes, which is exactly the shape OVH has. Cosmetic only:
  `Tools::AddonsController` never gates on `available?`, so a greyed addon stays reachable by URL —
  do not read this as an access control.
- **Asset paths are REJECTED, never normalized** (§14a's `key_for` rule) — one guard,
  `Source.validate_asset_path!`, shared by the HTTP and local (`Source::Local`, dev/test)
  backends. The controller-level traversal test passed under mutation until the fake was seeded
  with a file the traversal would actually *reach*: asserting only a 404 proved nothing, because
  "refused" and "not found" both produce one. `Source::Local`'s own test had the same false-green
  shape one layer down — `Pathname#join` doesn't sanitize `..` the way a URL does, so a made-up
  escape target just happened not to exist on disk; the fix plants a real file outside the source
  root and proves it unreachable, not coincidentally missing.
- **`skip_forgery_protection only: :asset`** — needed because `verify_same_origin_request`
  (an `append_after_action`, not skipped by this) fires unconditionally on any non-XHR JS
  response, which is exactly what a `<script type="module" src>` load looks like; skipping the
  `verify_authenticity_token` before_action is what stops the request from ever being marked for
  that check, since marking only happens there. On a GET-only action the CSRF-token check itself
  was already a no-op (GET is exempt), so the skip's sole practical effect is disabling that
  cross-origin-JS guard. Residual, stated plainly: the endpoint stays behind `authenticate_user!`,
  so a cross-origin `<script src>` remains a login-state / addon-inventory oracle (200 vs 404 via
  `onload`/`onerror`, no response bytes leak). Whether to close that residual is a product
  decision, not one this comment makes.
- **Each save writes ONE file — its output.** The `.params.json` beside it is gone: it was
  **write-only** (`Maker::AddonState#data` already recorded the params and every reader went
  there). Params are now served by `Tools::AddonParamsController` — **one** route for all
  addons, because `AddonState` is addon-agnostic — and the download serves the whole `data`
  hash, not `data["params"]`, which is byte-identical to the removed file. Files already
  written were **left in place** (ordinary library files a user may have renamed or attached;
  a migration must not delete user bytes).
- **`Maker::Addons::LibraryOutput` is the ONE output path**, backend-neutral on
  `port_writable?`. It reaches chunk-family storage entirely through port verbs now —
  `begin_upload`/`put_chunk`/`finalize_upload` — so the phase-1 decoupling proof is **"no hits, full
  stop"**:
  `grep -rn "manifest_chunks\|ChunkStore" $(find app -type d -name maker) --include='*.rb' | grep -v ':[0-9]*: *#'`
  The `grep -v` is load-bearing, not noise — without it the check reports comments that
  *describe* the removed coupling. **A proof that cries wolf gets ignored.** So is the `find`:
  it must cover **every** `app/**/maker` directory (six today), not three, and **`grep -r` does
  not honour `**`** — spelling the set out named `services`/`models`/`jobs` and silently skipped
  `app/controllers/v1/maker` (14 files) and `app/models/concerns/maker` (1).
  **`test/architecture_invariants_test.rb` now RUNS this and DERIVES the directory set from the
  tree** (`%w[app/**/maker]`) rather than repeating the list, asserting the offending set is
  *empty* — so the claim can no longer drift the way it did before: it read "no hits" for months
  after the addon framework made the true answer one (`library_output.rb`'s own direct
  `Storage::ChunkStore#put` call, the one sanctioned exception between the phase-1 decoupling and
  Arc B), and it would have gone on reading "exactly one, and it is library_output.rb" indefinitely
  had Arc B Task 2 not driven the count back to zero by giving `put_chunk` a port-verb
  implementation on `FileLayer::ChunkRemote` (§14a; the embedded adapter had one too, and
  went with the engine). A NEW
  `app/<x>/maker/` is covered the day it is created. Change the code and the test tells you; if a
  new direct exception ever becomes genuinely unavoidable, update the test and this bullet
  together, deliberately.
- **IT NOW HAS ONE CALLER OUTSIDE THE ADDON SYSTEM, NAMED HERE RATHER THAN LEFT SILENT** — the
  editor's Save (`FilesController#update`, `tinkerex#178`) calls `LibraryOutput.write_bytes!`, the
  `port_writable?` branch extracted out of `#write` **in place**. It is still the ONE output path
  and §14d's count of that branch is still **exactly one**: `#write` calls `write_bytes!` too, so
  there is genuinely one copy, and an addon save and an editor save are the same operation seen
  twice — server-side bytes into a library file, replacing what is there, **reusing the node**. The
  only difference is that an addon save additionally records a `maker_addon_files` row, which is
  why `write_bytes!` takes no `state:` and returns a bare `node_id`. **A second copy of the branch
  was refused, and so was moving the class**: relocating it to suit a non-addon caller would put
  both this bullet's claim and §14d's count in question to save an awkward namespace. **An
  invariant that silently acquires an exception is worse than one that names it** — which is what
  this bullet is. `write_bytes!` is deliberately not called `write`: two methods of that name on
  one module, with different arities and different return types, is the drift this repo names
  services to end.
- **Addon bundles are served by the `addons` Kamal accessory** (`chaim354/tinkerex-addons`), not
  shipped inside the Rails image — **publishing the bundle image IS the addon deploy; Rails is
  never rebuilt.** `deploy.yml` sets `ADDON_SOURCE_URL: http://tinkerex-addons`. Read the
  precedence carefully, because the obvious story is backwards: `Source.current` gives
  **`ADDON_SOURCE_PATH` precedence over `ADDON_SOURCE_URL`** when both are set (the safer
  failure mode — a stray URL left in a dev/test env can never make a local run hit the network
  by surprise). What actually turns production onto the accessory is that **the PATH default
  itself is conditional**: both `production.rb` and `development.rb` only default
  `ADDON_SOURCE_PATH` `if ADDON_SOURCE_URL.blank?`, so PATH is never set alongside a real URL.
  An *unconditional* PATH default would leave PATH always set in production too — and since PATH
  wins whenever both are present, the accessory would run and answer requests while Rails
  silently never called it. That conditional default, not a URL-beats-PATH rule, is the whole
  cutover.
- **`ADDON_SOURCE_URL` MUST be blanked in `deploy.ovh.yml`** — same rule, same reason, as the two
  sidecar URLs above: Kamal deep-merges `env.clear`, so OVH would otherwise inherit the
  Unraid-only `tinkerex-addons` hostname, `Source.configured?` would read true, and every fetch
  would fail instead of the gallery merely greying out. It does **not** match the `_SIDECAR_URL`
  suffix the guard originally grepped for, and was silently unguarded until
  `test/deploy_hygiene_test.rb`'s pattern was widened to `/_SIDECAR_URL\z|\AADDON_SOURCE_URL\z/`
  — **any future accessory URL needs the same manual addition**, because the guard covers a
  naming convention, not a category. Consequence for OVH today: an **empty tools gallery**,
  degrading through `Registry`'s rescue rather than 500ing, until OVH gets its own addons
  accessory.
- **The addon system test is hermetic by fixture, deliberately.**
  `test/system/addon_bundle_test.rb` reads `test/fixtures/addons/`, never the real bundle —
  pointing it at the `tinkerex-addons` repo's working copy (the dev-default assumption: checked
  out as a sibling) would make CI depend on a repo a fresh clone never has. The fixture's entry
  module imports from a **pinned bare specifier** (`fixture-dep`, declared in its own manifest's
  `pins`) and renders that module's exported value into the DOM, so a pass proves the
  **merged importmap** actually resolved a bare specifier through the proxy — not merely that
  the entry module itself loaded. Mutation-checked: blanking `pins` in the fixture manifest
  turns it red.
- **The service proxy ALLOWLISTS content types, and `image/svg+xml` is deliberately NOT on it**
  — the entry most likely to be "restored", because SVG is the box generator's main output.
  `#service` used to echo the sidecar's `Content-Type` verbatim `inline`, a same-origin
  script-execution channel: the route is `via: %i[get post]` while boxes' `/generate` is
  POST-only, so a plain GET returns **Werkzeug's 405 page as `text/html`** under our origin.
  SVG is script-capable and `nosniff` does not help it. Excluding it costs the generator
  **nothing** — `preview.js` reads the render with `fetch()` + `res.text()` and re-encodes it as
  a `data:` URL, and neither header affects a `fetch()` body. Two entries are load-bearing the
  other way and must stay INLINE: **`image/jpeg`** (`gallery.js` points an `<img src>` straight
  at this proxy for sample photos) and **`application/json`** (`preview.js` branches on a JSON
  content-type to read a sidecar's error message). Unlisted types degrade to
  `octet-stream` + `attachment` rather than 415, so a sidecar upgrade can't become an outage. If
  a future bundle needs an SVG in an `<img src>`, add it back **with a
  `Content-Security-Policy: sandbox` response header**, not by relaxing the list.
- **An addon save validates its filenames AT THE DOOR, backend-neutrally** —
  `Maker::MoveNode.valid_leaf_name?` in `parse_files`, not inside any adapter. Share and S3 each
  refuse a traversing name in their own `leaf!`; **chunk has no name check anywhere** (
  the sync server's commit validates the manifest exhaustively and the name not at all, and `Node`
  validates `name` for **presence only**), so `"../../escape.txt"` created a live node on the
  main deployment, bound for the changelog and every device mount. A guard that exists on two
  backends and silently does not on the third is this repo's recorded failure shape — the fix is
  the door, never a third copy in the chunk adapter. **The same door asks a SECOND question beside
  it, `Library::ReservedNames.reserved?`** (§14b): the reserved-namespace half diverged identically,
  and unlike the traversal half one arm of it was never silent — it reached this controller's
  `rescue_from FileLayer::NotFound` on share/s3, which is the bullet at the end of this section.
  The save also pre-checks destination names
  (a CHECK, not a lock) so chunk stops creating two same-named siblings in one directory, and
  `Tools::AddonsController` maps `UnsupportedOperation`/`FetchError`/`NotFound` **once** via
  `rescue_from` — as JSON with a real status, NOT a redirect-with-flash, because the only caller
  is a `fetch()` that branches on `res.ok` and **fetch follows a 302**, so answering an error the
  way success is answered reports "Saved." over a save that never happened.
- **THE CTX BLOB IS AN ADDITION; THE NINE LEGACY DATA ATTRIBUTES STAY FOR THE LIFE OF
  `api_version: "1"`.** Publishing a bundle *is* the deploy and Rails is never rebuilt, so bundles
  written against **both** shapes are live against one host at the same time — the host may never
  assume they moved with it. Guarded by reading both representations out of **ONE** rendered
  response and comparing them to each other, not by recomputing an expectation each could drift
  away from independently; mutation-checked by deleting an attribute.
- **`@maker/addon-sdk` IS A HOST PIN, AND ITS SPECIFIER IS PUBLIC API.** `merged_importmap` draws
  every host pin before the addon's own, which is what lets a bundle import it having declared
  nothing in its manifest. The FILE behind the pin may move freely; the **SPECIFIER may not change
  while `api_version: "1"` lives** — every published bundle names it, and **Rails is never rebuilt
  when a bundle is**, so nothing in this repo would notice: the failure is an addon 404ing in a
  browser against a deployment whose suite is green.
- **`initHost(ctx)` RUNS BEFORE THE BUNDLE IS IMPORTED, AND THE ORDER IS THE CONTRACT** — a
  bundle's top-level code executes at import time, so `host` must already be bound by then. The
  corollary is the part that bit twice, and it is **silent rather than loud**: an ES module is
  evaluated **ONCE PER URL PER PAGE**, so on a Turbo re-mount `initHost` builds a NEW `Host` while
  the cached module's top level does **not** re-run — a reference captured at top level
  (`const { files } = host`) then goes on serving the PREVIOUS, torn-down host's context and CSRF
  token, with nothing thrown and nothing logged. **Read through `host` at call time; never capture
  it.**
- **THE CAPABILITY MAP IS SERVER-SIDE AND HAS ONE DEFINITION** (`Maker::Addons::Host`) — §14d's
  third extension→role table is what a second copy becomes. **Every value must be a real boolean**:
  a missing key reads as `undefined` in JS and a nil reads as `false`, and neither is
  distinguishable from a deliberate "off". A capability is **NAMED BEFORE IT IS BUILT, ANSWERED
  `false`** — that is the whole compatibility mechanism, and what lets an addon be authored against
  a host level it has not met.
- **BUMP `Host::LEVEL` IN THE SAME COMMIT THAT FLIPS A CAPABILITY TO TRUE.** A manifest's
  `min_host` is the only way an addon can say "I need this", and `api_version` **equality** cannot
  express it — flip without bumping and an addon requiring the new capability has no way to name
  the host that has it.
- **A 409 `would_replace` IS A QUESTION; A 422 `name_taken` IS NOT** — the SDK throws
  `WouldReplaceError` and `NameTakenError` as distinct classes for exactly this, the same
  distinction §14f draws server-side. Collapse them and a bundle offers an Overwrite button for a
  save that can never succeed on retry.
- **THE SHIPPED SAVE PATH IS THE SDK'S, AND ITS THREE 409 ANSWERS ARE PROVED BY
  `test/system/addon_sdk_test.rb` ALONE.** Accepting, DECLINING and passing no callback at all are
  three different outcomes — re-POST with `overwrite=1`, `{cancelled: true}`, throw
  `WouldReplaceError` — so the `sdk-fixture` takes its `onReplace` answer from a `decline=` query
  param, the way it already takes `parent` and `fname`, and a Ruby test drives each.
  `test/fixtures/addons/fixture/save.js` LOOKS LIKE THE SAME PROOF AND IS NOT: it is a raw-ctx
  duplicate of the helper the real bundles dropped when the SDK absorbed this dance, and it has
  already drifted (it reads only the FLAT `{error: "would_replace"}` body, where `errorFrom` reads
  the nested shape too). It stays because `fixture` deliberately holds the raw-ctx path so both
  halves of the compatibility rule are covered by something that runs (`manifests.json`'s
  `sdk-fixture` entry) — never as evidence about shipped code. **Neither file is the other's
  guard:** a decline asserted through save.js left the SDK's own decline branch with zero assertions
  anywhere, for the life of the SDK, while reading as covered.
- **A SAVE CARRYING `state_id` REVISES, AND THE OWN-FILE EXEMPTION COVERS BOTH COLLISION CHECKS, NOT
  ONE.** `Tools::AddonsController#create` resolves the target through `#addon_states` (404 if it does
  not, never a silent fallback to creating — that would file a revision of an existing design as an
  unrelated one, the pile-up the feature exists to end), and a collision with one of THAT item's own
  `AddonFile` nodes is an approved replace while every other collision keeps today's answer. Both
  halves are needed and they fail in OPPOSITE directions, which is why `owned` is a **required**
  parameter on each rather than a defaulted one: `refuse_taken_names!` (picked folder, terminal 422)
  is the only check a box in a plain library folder ever reaches, so exempting only
  `resolve_placements` leaves the mainline re-save the dead end this arc exists to close; exempting
  only `refuse_taken_names!` lets the write land as a **CREATE** — probed on chunk, a second live
  node with the same name in one directory, and on share/s3 the port's own clobber refusal turns the
  exemption straight back into the 422. An **absent OR empty** `state_id` creates, byte-identical to
  before: `present?`, never `!nil?`, because a bundle rendering an empty hidden field is the natural
  way to say "no target yet" and the whole suite stayed green over the `!nil?` spelling.
- **THAT EXEMPTION IS BY NODE IDENTITY, NOT BY `(parent, name)` — `except_node_id:`, the parameter
  `Maker::MoveNode.collision?` has always had for this and was being passed nil.** Skipping the query
  instead ("this state owns that (parent, name), so wave it through") is a DIFFERENT rule, and the
  difference is a live defect on chunk: two live siblings sharing one `(parent, name)` are reachable
  there, since the sync server validates a manifest exhaustively and the name not at all (§14a), so a
  device push can land one. With the check skipped that save answered **302, rewrote the node this
  state does NOT own, and ADOPTED it into `state.files`** — §14a's orphaning shape with the sign
  flipped, introduced by the very commit that added the exemption. `resolve_placements`' cheaper
  `.key?` arm is safe only because it runs AFTER this one; reorder the two and it stops being.
- **A REVISION ROW IS IMMUTABLE, AND `attr_readonly` IS WHAT REFUSES THE REWRITE — NOT THE MISSING
  `updated_at`.** `Maker::AddonStateRevision` marks `addon_state_id`/`revision`/`data` readonly, so
  assignment, `update!` AND `update_columns` all raise on a persisted row (the last with the parent
  class `ActiveRecordError`, not `ReadonlyAttributeError` — a `rescue` written for one will not catch
  the other). `update_all` and raw SQL bypass it entirely, the §14e refcount blind spot again; the
  migration's own backfill is the one legitimate writer that goes around it. **`created_at` is
  deliberately OUTSIDE the list**, so "immutable" means the snapshot — identity, number, params.
  There being no `updated_at` column stops nothing by itself; what it buys is that a rewrite forced
  through one of those doors has no timestamp to bump, so it cannot look like a sanctioned save.
- **`maker_addon_states.revision` IS THE CURRENT NUMBER AND THERE IS NO COUNT COLUMN**, because
  nothing deletes a revision, so the count equals the number. Add one with the deletion, not before —
  today it would be a second value to keep in step for no present reader.
- **`Host::LEVEL` 3 IS THE WHOLE FEATURE DETECT FOR REVISING, AND IT IS THE FIRST BUMP THAT FLIPPED
  NO CAPABILITY.** No name was added, for the same reason binary output has none at level 2: revising
  is the SAME `library:write` door growing an optional parameter, so a capability would answer `true`
  for exactly the hosts that answer `library:write` true and would carry no information. `min_host: 3`
  is how a bundle requires it. **`state:crud` stays reserved and false** and keeps its own meaning —
  the direct `PATCH`/`DELETE /tools/:key/states/:id` endpoints, which this is not; `host.state
  .revisions` therefore gates on **`state:list`**, the read side it actually belongs to, or it would
  throw on every host there is. The level is pinned in **two** places on purpose (`host_test.rb`'s
  ledger and the rendered-ctx literal), and both must move at level 4.
- **`GET /tools/:key/states` STAYS ONE ENTRY PER SAVED ITEM FOR THE LIFE OF `api_version: "1"`, AND
  `revision` IS AN ADDITIVE KEY ON IT — never a `revisions` array.** That is exactly what let every
  already-published bundle keep working across this change (§14c: publishing a bundle IS the deploy,
  Rails is never rebuilt), and a revision appearing as a second entry would turn one design back into
  the growing pile the feature ends. The history is served lazily by `#revisions`, **unbounded on
  purpose**: a cap without paging is §14b's silent truncation, and a bundle handed a history that
  quietly stops at N cannot tell that from a design saved N times. If human save frequency ever stops
  bounding it, the fix is **paging**, not a bare limit.
- **`?state=` IS A HINT AND ANSWERS nil; THE SAME ID AT `#create`/`#revisions` IS A 404. DO NOT
  HARMONISE THEM.** An unknown, foreign or other-addon id must never 404 the tool — a stale bookmark
  or a deleted box would take the page down — while a save or a history read naming one is a bundle
  bug that must not silently do something else. `#find_addon_state` decides nothing itself for
  exactly that reason. The SDK's `host.launch` getter answers `{stateId: null, ...ctx.launch}` so a
  bundle on a LEVEL-2 host (which sends no `launch` key at all) still reads an object rather than
  `undefined` — which means dropping `stateId` from inside the server's hash would NOT surface as a
  missing value. **Keep the key in `addon_ctx`.**
- **WHERE A SAVE STARTS IS `Tools::AddonsController#tool_destination_node_id`: FOUR STEPS, FIRST
  ANSWER WINS, AND NEVER SESSION OR USER STATE.** (1) `?in=` naming a live folder of the user's —
  New ▸ <tool> sets it to the folder the menu was opened from; (2) `?state=` naming one of this
  tool's saved states — the folder THAT state's output lives in now, so a reopen link (they all
  carry `state=` already) starts a revision where its file is, and `#resolve_placements`' owned arm
  replaces it in place there; (3) the folder of the tool's most recent LIVE output, **mapped up to
  its owning project's folder** when it sits inside one; (4) nil, the library root. The bundle's own
  "Save into" field shows this and changes it; the host decides only where that field begins, and
  there is no host destination bar (structural redesign spec §7, as slice 4 amended it). It replaced
  the global current project, whose names `test/architecture_invariants_test.rb` now forbids.
  **Step 3's mapping is not cosmetic: it decides which refusal a same-name save meets.** The eager
  intake nudge files `Projects/<slug>/x.svg` into `design/` (§14f), so the raw last-output folder
  is the CATEGORY folder, and a same-name save there is `#refuse_taken_names!`'s terminal 422
  `name_taken`. Mapped up to the project root, the same save reaches `#resolve_placements`' 409
  `would_replace` — the "save as revision 2" offer, a question rather than a dead end (the 409/422
  rule above). `test/system/box_revisions_test.rb`'s join test reaches that offer only through step
  3, which makes it the mapping's mutation check. Two spellings not to tidy: the "no output" test is
  `rows.empty?`, **never `any?`**, because `[nil]` is the answer "the newest output sits at the
  library root" and `[nil].any?` is false, which silently turns the root into a fall-through to an
  older output's folder; and the folder is a **LEFT** join, so an output at the root is still a row
  while a trashed folder disqualifies its output rather than answering a tombstone's id. Step 3 is
  one statement and the mapping walks the request's own `Maker::LibraryTree`, so
  `page_query_budget_test.rb` pins the page's query count constant in the number of saved states.
- **`?in=` IS A HINT EXACTLY AS `?state=` IS: A STRING ONLY, VALIDATED AS A LIVE FOLDER OF THIS
  USER'S, AND ANY MISS FALLS THROUGH TO THE NEXT STEP — NEVER AN ERROR.** A stale bookmark, a
  trashed folder, a file's id and another user's folder all fall through to step 2, because a link
  that outlived its folder must not take the tool down. The `is_a?(String)` check is load-bearing for
  `#find_addon_state`'s reason: `?in[]=a&in[]=b` arrives as an Array, and `find_by(node_id: [...])`
  is an IN lookup answering whichever row the planner meets first. `Tools::HomeController#new_menu`
  echoes its own `in=` into each tool link WITHOUT validating it, because the tool page does, so a
  bad value costs only a link to the tool's own default. There is no stricter door to harmonise it
  with: the save never reads `?in=`, since the bundle's field sends its choice as `folderNodeId`, and
  `Tools::LibraryFolders#chosen_parent_node_id` resolves that on its own.
- **THE FILE→STATE REVERSE LOOKUP CONSULTS THE REGISTRY ONLY WHEN THE NODE QUERY FOUND A HIT.**
  `Maker::AddonOrigin.for` makes no `Registry` call at all and `AddonOrigins#addon_origins_for` returns
  early when it is empty, so a library with no addon output never touches the addon source — a
  manifest fetch over HTTP behind a 5-minute cache. Collapse the two steps and an addon-source outage
  becomes a slow Files page for a user who has never opened `/tools`. Pinned with a **counting**
  double, not a raising one: `Registry.manifests` rescues `StandardError` and answers `[]`, so a
  raising stub is swallowed and the regression passes.
- **DO NOT COLLAPSE `Maker::AddonOrigin.for`'S TWO STATEMENTS INTO A JOIN.** The join never reaches
  the `node_id` index, so its cost grows with the user's SAVED-STATE COUNT — including on the
  all-miss path, which is the ordinary library that has never saved anything from an addon — and no
  query-count test can see it, because it is all inside one statement. Measurements are in the
  method's own comment and in `docs/STATUS.md`.
- **THE SDK REFUSES A NON-STRING/NON-INTEGER `stateId` RATHER THAN COERCING IT.** `String(...)` would
  launder the value straight past the server's own allowlist: `String([1, 2])` is `"1,2"`, a perfectly
  good String to `#find_addon_state`, and ActiveRecord's integer cast resolves `find_by(id: "15,16")`
  to state **15** — probed against real rows. So a save would have renamed a different design, bumped
  its revision and attached a file to it, silently, on the door that WRITES. It is deliberately not a
  validation of the string itself (`"1abc"` casts to 1 and opens state 1 — a bound parameter inside
  both the user and addon scopes, with nothing to reach); what is refused is only the shape JS itself
  would flatten.
- **`defaultFolder` NAMES TWO DIFFERENT SHAPES, DELIBERATELY.** The raw `ctx.defaultFolder` handed
  to `mount` is a **STRING node id**; the server's ctx blob carries `defaultFolder: {nodeId,
  label}`. Harmless only because the SDK never exposes its copy — so **never add a
  `host.defaultFolder` accessor**, which would silently hand an object to every bundle that expects
  a string.
- **`defaultFolder`'S VALUE CHANGED IN SLICE 4 AND ITS TWO SHAPES DID NOT, WHICH IS WHY NO BUNDLE
  HAD TO MOVE.** It used to carry the current project's folder. It now carries
  `#tool_destination_node_id`'s answer. The raw string, the blob's `{nodeId, label}` and
  `defaultFolderLabel` are filled exactly as before. The cross-repo check (structural redesign spec
  §9.1, against `chaim354/tinkerex-addons` @ `b0e6c0f`) found that the bundles read nothing else of
  the host's: no `.current-project select`, no `current_project`, no `project_id`, no host DOM. That
  is the whole reason a change to where every save starts shipped with a README correction in that
  repo and no bundle release. **Keep that discipline for any later change to the default**: change
  what fills the keys, never their names or shapes, for the life of `api_version: "1"`. Otherwise it
  becomes the coordinated two-repo move the check existed to rule out.
- **AN EDGE PARAM'S OPTION READS `"{letter} — {description}"` AND CARRIES THE BARE LETTER AS ITS
  VALUE.** boxes.py's edge choices are single letters — `top_edge` offers sixteen — and a letter on
  its own is not a choice anyone can make; upstream's own web UI never showed them bare
  (`ArgparseEdgeType` carries `names = edges.getDescriptions()` and composes each option from it).
  `sidecar/boxes/app.py`'s `_choice_labels` advertises that map per param as **`choice_labels`** and
  `fields.js` composes the text. **Three things not to undo.** The label is **DISPLAY ONLY**:
  boxes.py parses the letter and `paramValues` reads `el.value`, so a label written into the VALUE
  looks right on screen and 422s every render. **`choices` stays the authority on the set and its
  ORDER**; the map only explains it. And **an absent map must fall through to the bare value** — it
  is absent for every ordinary enum (`FingerJoint_style`, `Lid_style`) and for any sidecar older
  than the key, so a bundle that assumes it renders `"rectangular — undefined"` right across a
  mid-rollout deployment. Keyed on the argparse TYPE carrying a `names` map, **never on a list of
  param names**: ten dests are edge-typed in the pinned boxes.py, not the two a user meets first.
- **A SIDECAR'S ERROR NEVER RUNS THROUGH THE HOST'S ERROR TABLE.** A sidecar answers **prose** in
  its `error` key, not a code, so `errorFrom` would put the message in `.code` and generic filler
  in `.message` — and a non-JSON body (Werkzeug's HTML 405, the proxy's own body-less 404) would be
  consumed by the failing `res.json()` and lost entirely. `service.*` raises `ServiceError`, built
  from the status and the raw text.
- **A GARBAGE OPENSCAD PARAMETER VALUE RENDERS SUCCESSFULLY, WITH THE DEFAULT GEOMETRY — SO THE
  SIDECAR REFUSES IT, AND THERE IS EXACTLY ONE COPY OF THAT CHECK.** Observed, not reasoned:
  `{"cols": "))("}` comes back **200** because OpenSCAD's `parameterSet` silently *ignores* a value
  it cannot parse, so a pass-through turns a typo into a default-sized model saved to the library
  with no feedback anywhere. `sidecar/openscad/coerce.py` checks every submitted value against the
  schema `schema.py` derived for that same source and **refuses** what will not coerce. It lived in
  Rails (`app/services/openscad_params.rb`) until 2026-08-12 and was **deleted, not duplicated**, on
  the way out — a browser bundle cannot call a Rails service object, and a guard that runs on one
  caller's path and silently does not on another's is this repo's recorded failure shape. Four
  things travel with it: **`choices` beats `type`** (schema.py's TRAP 3 — an enum's declared type is
  the type of its *values*); the bool mapping is an **ALLOWLIST**, never a framework boolean cast,
  which maps everything outside its false-list to **`true`** — garbage silently becoming `true` is
  the same bug wearing a hat; **min/max are NOT enforced**, deliberately, because OpenSCAD *honours*
  an out-of-range number rather than ignoring it, so refusing one adds false rejections and prevents
  nothing; and messages are **truncated** so a pasted value cannot become the message.
- **THE SIDECAR ANSWERS 422 FOR TWO DIFFERENT THINGS, AND ONLY `code: "invalid_params"` TELLS THEM
  APART — AND THE CONSUMER OF THAT DISTINCTION IS NOW A BUNDLE, NOT RAILS.** A `.scad` it cannot
  parse and a *value* it refuses are both client conditions and both 422, but they want different
  UI: a rejected value must come back as a form error with the user's own entries still in it, a
  broken source has to send the user back to the catalog. That branch used to be Rails' —
  `OpenscadClient::InvalidParams`, a subclass of `Error`, with `#create`'s two rescue arms ordered
  subclass-first — and **all of it went with `Tools::OpenscadController` on 2026-08-12**. The rule
  that survives is the one about the WIRE: **branch on the `code`, never on the prose**, because
  the prose is a human sentence a sidecar release can reword without anything downstream being
  rebuilt — which is now doubly true, since the downstream is a bundle published from another repo.
  Note the SDK does not do this branching for you: `service.*` raises `ServiceError` built from the
  status and the RAW TEXT, deliberately (see the sidecar-error bullet above), so a bundle that needs
  the distinction reads `code` out of the body itself.
- **THE SDK REJECTS A `.`, `..` OR EMPTY PATH SEGMENT RATHER THAN ENCODING IT** —
  `encodeURIComponent("..")` is `".."`, so the **browser** normalizes the path before the request
  is sent and it never reaches the route the server guards: it misroutes **silently** instead of
  being refused. Same rule as §14a's `key_for` and `validate_asset_path!` above: **reject, never
  normalize.** **THE SERVICE NAME IS THE SAME URL AND GETS THE SAME REFUSAL** — it went unguarded
  while the `path` beside it did, which made the invariant true of only part of one URL. It
  additionally rejects a `/` **outright rather than splitting it into segments**, because `:service`
  is one Rails segment matched VERBATIM against the manifest's `services` list, so `"a/b"` cannot
  name a service on any host; splitting would normalize a structural error, and would leave the
  contract incoherent (`"../.."` refused, `"a/b"` accepted) for a value that is one segment by
  definition. Only `.`, `..` and `""` survive `encodeURIComponent` — `\`, `#`, `?`, `%` need no
  clause. Proven in a **browser** (`addon_sdk_test.rb`), because the normalization is the URL
  parser's and no server-side test can observe it.
- **`service.post` SENDS A JSON BODY, AND A `FormData` IS NOT AN EQUIVALENT SPELLING OF IT.**
  multipart/form-data serialization **normalizes every text entry's newlines to CRLF** (the HTML
  standard's own encoding algorithm), and it happens INSIDE THE BROWSER, *after* `append` returns —
  so a `<textarea>` whose DOM value is LF-clean reached the sidecar as `"+-+-+-+\r\n…"` with no
  bundle-side fix possible and nothing anywhere reporting it. boxes.py's TrayLayout, whose entire
  input is that ASCII art, then rendered the wrong tray. `append` ALSO stringifies a nested value to
  the literal `"[object Object]"`, and `{generator, params: {…}}` is the shape of every real sidecar
  call. **The server end always wanted JSON** — `ServiceProxy#call` re-emits `params` as a JSON body
  because Flask's `request.get_json(force=True)` cannot read a form body — so the whole corruption
  was one-sided and the fix is one-sided. **A unit assertion cannot see this**: every layer this repo
  can call directly holds a clean string. Pinned in a real browser by `addon_sdk_test.rb`, asserting
  on **what the proxy RECEIVED** (`FakeServiceProxy#calls`), never on the SDK's intent.
- **`wrap_parameters format: []` ON `Tools::AddonsController` IS LOAD-BEARING FOR `#service`.** Rails
  8 defaults `wrap_parameters format: [:json]` in the FRAMEWORK — there is no initializer in this
  repo, so grepping `config/` finds nothing and the behaviour reads as absent. It is not:
  ParamsWrapper **merges a complete duplicate of the body** under a controller-derived key into
  `request.request_parameters`, which is verbatim what `#service` forwards to the sidecar. Probed: a
  `{generator, params}` body arrived as `{…, "addon" => {…the whole body again…}}`. Inert while the
  transport was multipart, live the moment it became JSON — a doubled request body on every
  debounced render, which boxes.py tolerates, which is exactly why nothing would have reported it.
- **`service.url` SHARES ONE URL BUILDER WITH `get`/`post`, WHICH IS THE WHOLE SAFETY ARGUMENT.** It
  hands a raw string to an attribute the **browser** dereferences, so there is no request for a
  server guard to inspect afterwards — a builder that skipped `encodeServiceName` /
  `encodePathSegments` would be the bullet above's traversal hole with a friendly name. Hence
  `_serviceUrl`, shared by all three, rather than three call sites that must agree. It exists
  because `get` PERFORMS the request and resolves a `Response`, which cannot feed an `<img src>`;
  fetch-and-objectURL defeats `loading="lazy"` across a tile grid and leaks a blob per card. The
  proxy's `image/jpeg` allowlist entry (above) is for exactly this call site.
- **AN ABORT IS RETHROWN VERBATIM AND MUST NEVER BECOME `ServiceUnavailableError`** — that class
  means "retry later, there is nothing to fix now", which is a lie about a request the bundle
  cancelled itself, and would make a superseded render paint an error banner. **The condition is
  `init.signal?.aborted`, NOT `err.name === "AbortError"`**: `abort(reason)` makes fetch reject with
  THAT reason (a plain `Error`, name `"Error"`), so the name test works for the simple caller and
  **silently fails for the careful one**. Mutation-checked in both directions.
- **A `service_timeouts` VALUE ABOVE `ADDON_SERVICE_MAX_TIMEOUT` GETS THE CAP, NOT AN ERROR** —
  the manifest is remote and versioned independently of this host, so refusing would take a working
  addon down on a deploy that merely lowered the ceiling. The cap is applied at the point of use
  (`ServiceProxy.read_timeout_for`), **not** in `Registry`, so lowering it does not wait out the
  5-minute manifest cache; `Registry` records what was ASKED FOR and filters to **positive Integers
  per entry** (a `"90"` string coerced would honour what a JSON manifest should not contain; a `0`
  is read by Net::HTTP as "give up immediately", so honouring it takes the sidecar down rather than
  degrading). **The ceiling exists because the proxy is SYNCHRONOUS**: `#service` holds a Puma
  thread for the whole round trip and production runs `RAILS_MAX_THREADS: 16` on one worker, so 16
  concurrent renders at the cap occupy every thread for two minutes and queue the addon page itself
  behind them. Raising it raises worst-case head-of-line blocking; the fix for a genuinely long
  render is an async job, which spec §13 lists as **not reserved** — no capability name, nothing to
  feature-detect — so a bigger number here is not a substitute for building one.
- **A `states_key` POINTING AT ANOTHER ADDON REQUIRES A MUTUAL DECLARATION** — the claimant names
  the target, the target names the claimant back in `shares_states_with`, **and the target must
  itself be a VALID addon** (`build` must succeed on it), or an entry `build` rejects confers a
  grant nobody can audit. Anything else is SKIPPED, **including a claim on an addon absent from the
  index** (the permissive "no target, no harm" reading lets a typo reserve a namespace and start
  colliding the day the real addon ships). Closes the 2026-08-03 audit's §2.1. The check lives in
  `Registry.all`, **not `build`**, because it is a question about a PAIR of manifests and `build` is
  handed one. **It is NOT recursive, and an earlier comment claiming otherwise was false:** a target
  skipped by this same check still confers a grant (probed — A admitted, B absent). Harmless, and
  the reason is the invariant: that target still wrote `shares_states_with` itself, so **consent**,
  not gallery visibility, is the property being enforced.
- **THAT REFUSAL MUST SKIP, NOT GREY OUT — AND IT IS THE OPPOSITE CHOICE FROM `min_host` ONE METHOD
  AWAY.** `Tools::AddonsController` never gates on `available?` — its ONE consumer is the gallery's
  `if addon.available?` in `app/views/tools/home/index.html.erb` (two further lines there render
  `unavailable_reason`), so a listed-but-unavailable addon is still
  `Registry.find`-able, still resolves through `load_addon`, and still serves `@addon.states_key`
  from `#states` and `#create`. Greying an unreciprocated claim out would **look closed while
  leaving the hole open**. Do not harmonise the two.
- **`Addon#available?` IS NO LONGER HARDCODED TRUE, AND THE GALLERY SHOWS A REASON RATHER THAN A
  FIXED SENTENCE.** It was true for as long as "registered" meant "fetchable"; `min_host` gives it a
  second real answer. A too-new addon is still **BUILT** and still **LISTED** — skipping it is the
  easy wrong answer, because an addon that silently never appears reads as a broken deploy rather
  than as a version floor, and the old hardcoded "Not configured on this deployment" would send an
  operator to check env vars that are fine.
- **A NON-INTEGER `min_host` IS IGNORED, NOT COERCED.** `"2".to_i` is 2, which would honour a value
  a JSON manifest should not contain. Ignoring it leaves the addon **AVAILABLE** — the failure
  direction an operator can diagnose, rather than one that makes an addon vanish.
- **EXACTLY ONE DECLARED PERMISSION IS CHECKED — `library:read`, BY `#file` — AND IT IS
  DECLARATION CONSISTENCY, NOT CONTAINMENT.** Every other name is displayed only. `states_key` is
  not an inter-addon boundary either: a bundle runs same-origin in the session and can call another
  addon's `/tools/<key>/states` — or another addon's `/tools/<key>/file/<id>`, whose manifest may
  well declare the permission — directly, so what the mutual declaration closes is only that a
  manifest can no longer redirect **its own saves** into another addon's namespace by declaration
  alone. Do not describe any of it as a boundary (spec §8.1 says so in those words; this repo's
  recorded failure shape is a guard everyone believed in that never worked). What the one check
  buys is that an addon which starts reading the library must SAY SO on the card the operator reads
  at publish time, in a deployment where publishing a bundle IS the deploy. **Do not add
  enforcement for the rest without the finished vocabulary:** `data:read:<addon>/<collection>` does
  not exist until PR 4, and `service:<name>` must reconcile with today's `services` key.
- **THE PERMISSION VOCABULARY HAS ONE DEFINITION** (`Maker::Addons::Permissions`), distinct from
  `Host::CAPABILITIES` — a capability is what the host CAN do, a permission is what an addon SAYS it
  wants, and they already diverge (`state` / `project:read` here against `state:list` /
  `state:crud` / `project:current` there). **An unknown name falls back to its own raw spelling**
  rather than rendering blank: a card that silently understates what an addon asked for is worse
  than one showing a developer-facing string.
- **`rescue_from FileLayer::NotFound` IN `Tools::AddonsController` IS REACHABLE ON SHARE/S3 ONLY,
  AND NOT FOR THE FOLDER REASON ITS COMMENT USED TO CLAIM.** A stale/foreign `parent_node_id`
  resolves to `nil` = the library ROOT in `chosen_parent_node_id` **before any port call**, so that
  save answers **302 and succeeds** (probed on all three; `docs/addon-api-v1.md` §5 carries the
  author-facing consequence). What used to reach it was an output NAME the scan can never observe —
  `observable!`, §14b's skip-list rule: `.DS_Store`, `._x`, `__MACOSX`, `.Trashes`, root `.trash`,
  and `.maker-tmp-*` **on share but not s3** (`S3#observable!` omits `TEMP_PREFIX` on purpose) —
  while **chunk accepted all of them**, because `write_chunk` never calls the port. That arm is
  **now closed one layer earlier**, by `Library::ReservedNames.reserved?` in `#parse_files` (§14b),
  which refuses those names at the door on every backend before a backend is even chosen. **So the
  arm's one remaining cause is the TOCTOU** — a destination folder tombstoned between
  `chosen_parent_node_id`'s lookup and the port write, a real window on share/s3 where
  `Library::ScanJob` tombstones a folder removed on the NAS. Its message still names the
  reserved-name cause too, deliberately wider than the arm: trimming a user-facing sentence on the
  strength of an unreachability argument is the move §14e says to probe rather than trust.
- **A FILE'S CONTENT NEVER CROSSES THE WIRE AS A BARE MULTIPART TEXT FIELD, AND THE SAVE DOOR'S TWO
  SHAPES ARE SAFE FOR TWO DIFFERENT REASONS.** multipart serialization rewrites every TEXT entry's
  newlines to CRLF inside the browser, after `append` — the §14c defect above, one door over. A
  string `body` rides inside the JSON `files` field, where JSON ESCAPING means the serializer never
  sees a newline; a binary body rides as a `parts[fN]` FILE part, which the same algorithm
  transmits verbatim precisely because it is not text. Understand BOTH before adding a third shape:
  the obvious "just append the body" is neither, and would corrupt every G-code, CSV, `.scad` and
  SVG an addon writes — silently, since the file still saves and still opens. Pinned in a real
  browser (`addon_sdk_test.rb` renders `<LF>`/`<CR>` explicitly, because Capybara normalizes
  whitespace and the corruption is invisible to an ordinary text assertion).
- **THE JSON `files` ARRAY IS THE ORDERED MANIFEST FOR BOTH SHAPES; A PART IS REFERENCED, NEVER
  LISTED SEPARATELY.** Order is load-bearing (`AddonFile#position`, and `placements[i]` pairs a file
  with the destination resolved for it), and a request carrying two collections has no ordering rule
  that is not implicit. **The NAME always comes from the JSON entry and never from the part's own
  `filename`** — one source, which is what lets `valid_leaf_name?` + `ReservedNames` cover both
  shapes with no second copy. **The CONTENT TYPE is the opposite: from the PART, never guessed from
  the name** (spec §6.1).
- **A `part` IS LOOKED UP INSIDE `parts[…]` AND MUST BE AN `UploadedFile`.** The key is
  client-supplied and indexes a params hash: at the top level `part: "name"` resolves to the state's
  own name — a String, which answers `#size` in CHARACTERS (mis-measuring the cap) and has no
  `#read` (a 500). Both halves are needed and are separately mutation-checked; the namespace alone
  is what refuses a real upload posted under some *other* top-level key.
- **`ADDON_SAVE_MAX_FILES`/`ADDON_SAVE_MAX_BYTES` DEFAULT TO 8 AND 4_000_000 AND ARE PER-REQUEST.**
  Bytes is a TOTAL across the save, not a per-file allowance — making it per-file would LOOSEN
  today's rule, and a cap that grows when it is made explicit is not the same cap. Sources are SIZED
  before any is READ, so an oversized part never enters the heap. A garbage value falls back to the
  default, never to 0: `"four".to_i` is 0 and a 0 cap refuses every save in the deployment.
  **THE TWO WIRE SHAPES HIT DIFFERENT RACK LIMITS** (verified, rack 3.2.6): a url-encoded body dies
  at `RACK_QUERY_PARSER_BYTESIZE_LIMIT` (4 MiB) as a bare 400 before the action runs, while
  multipart is bound by `RACK_MULTIPART_PARSER_BYTESIZE_LIMIT` (10 GiB) — including the JSON `files`
  field inside it, which the multipart parser handles and `each_query_pair` never sees. So a raised
  cap means something to the SDK (always multipart) and nothing to a hand-rolled url-encoded POST.
- **`GET /tools/:key/file/:node_id` IS ALWAYS `application/octet-stream` + `attachment`, WHATEVER
  THE FILE IS, AND THERE IS DELIBERATELY NO BYTE-URL HELPER.** Its only caller is
  `host.files.read`, a `fetch` reading `.arrayBuffer()`, and neither header affects a fetch body —
  so this costs nothing and removes the inline case entirely, rather than re-deriving
  `FileDelivery::SAFE_INLINE_TYPES` (the allowlist `FilesController#blob` and the public file route
  share since stage 3, S3-4) for a caller that is not a browser tab.
  **Serving Marcel's type instead was a LIVE BUG, found by probing:** a `.js` in the library came
  back `text/javascript`, and `verify_same_origin_request` (an `append_after_action` firing on any
  non-XHR JavaScript response — and `fetch` sets no `X-Requested-With`) raised
  `InvalidCrossOriginRequest`, so the addon got a **422 HTML page** where its bytes belonged.
  **`skip_forgery_protection` would be the WORSE fix**, not an equivalent one: `#asset` can afford
  that skip because its body is the same static bundle for every viewer, while this body is a
  USER'S OWN FILE — skipped, a third-party `<script src>` would execute it in the attacker's origin
  and read it out. Octet-stream + `nosniff` makes that structurally impossible and needs no list of
  script-capable types to keep current (§14b's skip-list blind spot). `FilesController#blob` still
  serves Marcel's type and has the same latent shape; out of scope, recorded. A URL here also
  cannot back an `<img src>`, which is why `host.files.blobUrl` does not exist and must not be
  added. Delivery is consumed exactly as `FileDelivery#deliver_file` consumes it — all three
  variants, **no `else`** (§14a). This endpoint keeps its OWN copy of that `case` on purpose: it
  overrides both the type and the disposition unconditionally, which is the one thing the shared
  concern's policy must never do. On s3 the `Redirect` is cross-origin, so a bundle reading those bytes needs the bucket's
  CORS to allow this origin; streaming through Rails instead is what §15 forbids.
- **THAT ENDPOINT'S `NotFound` IS RESCUED IN THE ACTION, NOT LEFT TO THE CLASS-LEVEL ARM.** The
  class arm answers 422 "Your library refused that write." — right for the save door, a lie on a
  read. Same shape as `FilesController#geometry` rescuing `RecordNotFound` locally (§14h). One 404
  for four causes (unknown id, a stranger's, a tombstone, a directory) so the endpoint cannot report
  which node ids are real.
- **THE `current_user` SCOPE ON `#file` IS THE REAL GUARD, AND A TEST USING A REAL ADAPTER CANNOT
  SEE IT.** All three adapters re-scope inside `live_node!`, so deleting the controller's scope
  still answers 404 — from the port's `NotFound` — and the obvious test passes over a deleted guard.
  The port's contract is that the CALLER has already decided the request is legitimate, so an
  adapter may legitimately trust it. Pinned with a port double that does (`PermissiveDownloadPort`).
- **FILE-PICKER EXTENSION FILTERING IS CLIENT-SIDE, AND FOLDERS ARE NEVER FILTERED.**
  `/library/children` already answers one bounded folder, so a server-side filter buys no round
  trips and costs a second definition of the extension vocabulary on an endpoint the form-field
  chooser shares (§14d's one-vocabulary rule). Filtering folders would hide the path TO a matching
  file. A malformed `extensions` filters NOTHING rather than everything — an addon's typo must not
  present an empty picker. It is a convenience for the human, never a restriction on the addon: a
  bundle can pass any node id to `read`.
- **`pickFile` RESOLVES `null` FOR CANCEL, AND FILE MODE HAS NO "CHOSE THE ROOT" ANSWER** — a
  directory is never a valid selection there, so `null` has exactly one meaning, unlike
  `pickFolder`'s `{nodeId: ""}`. Both halves are driven in a browser, because a picker that simply
  hung also renders nothing.
