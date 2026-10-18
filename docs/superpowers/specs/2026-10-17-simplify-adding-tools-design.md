# Simplify adding a tool — scaffold, loud manifest check, one-command publish

**Date:** 2026-10-17 · **Repos:** `chaim354/tinkerex` (host) then `chaim354/tinkerex-addons` (bundles)
**Scope:** sub-projects A (writing a browser tool) and B (publishing it). Sub-project C — adding a
server-side sidecar — is a separate, later spec.

## 1. The problem, measured against today's process

Adding a browser-only tool to `/tools` today:

1. Create `addons/<key>/<entry>.js` in `tinkerex-addons` and write the SDK boilerplate by hand —
   there is no template.
2. Hand-edit the shared `addons/manifests.json`. **Nothing checks it before it ships.**
   `Maker::Addons::Registry.build` returns `nil` — with no log line — for a manifest missing a
   `REQUIRED` key or declaring the wrong `api_version`, so the tool simply never appears. A typo'd
   `entry` or `pins` filename is not checked anywhere; it surfaces as a 404 when the bundle loads.
   A duplicate `key` is served by whichever entry sorts first; the other vanishes silently.
3. Publish: `KAMAL_REGISTRY_PASSWORD=… bin/build-push`, switch to the tinkerex repo,
   `kamal accessory reboot addons`, then wait up to `Registry::TTL` (5 minutes). Nothing verifies
   the accessory is serving what was pushed — and on 2026-10-07 a ghcr tag move silently reverted
   and a reboot redeployed the old image while reporting success.

## 2. Decisions

| Decision | Choice | Why |
|---|---|---|
| Index shape | **Keep the one `manifests.json`**; the scaffold inserts into it | Per-addon manifests need a build step (the repo is deliberately build-free) or a change to how the host reads the index. A one-maintainer repo does not hit the merge conflicts that would justify either. |
| Where "why was it skipped" is defined | **In `Registry`, once** | A validator in the addons repo would be a second definition of the manifest rules, drifting from the one the host enforces. |
| Production behaviour | **Unchanged** — still skip, never raise | §14c: one bad addon must never take `/tools` down. |
| Duplicate keys | **Reported, not skipped** | Skipping would change what production serves; reporting makes the shadowing visible without changing it. |
| Cache after publish | **Accept "live within 5 minutes"** | Busting three deployments' caches costs a `kamal app exec` each; the owner chose the wait. |

## 3. Host side (`tinkerex`, PR 1)

### 3.1 `Registry.problem_with(manifest) → String | nil`

The single-manifest reason, or `nil` when the manifest would build:

- not a JSON object → `"not a JSON object"`
- missing required keys → `"missing title, icon"` (every missing key, in `REQUIRED` order)
- wrong api version → `"api_version \"2\" — this host speaks \"1\""`

`build` begins `return if problem_with(manifest)`, so the rule exists exactly once. Every other
`build` behaviour (optional keys degrading, `min_host`/`service_timeouts` filtering) is untouched.

### 3.2 `Registry.problems(index = manifests) → [{key:, reason:}]`

The whole-index report. It contains every `problem_with` result plus the two problems that need
more than one manifest in scope:

- **unreciprocated `states_key`** — the condition `states_key_permitted?` already refuses (today it
  reaches only the log). `problems` reuses that predicate; it does not restate it.
- **duplicate `key`** — `"duplicate key — only one of N entries is reachable"`.

`key` is the manifest's `key` when it has one, else `"#<index position>"`, so a keyless entry is
still locatable. The report is ordered by index position.

`Registry.all` logs one `warn` per problem, matching the existing per-request `states_key` warn
(that line is replaced by this one, not duplicated).

### 3.3 `bin/rails addons:check [PATH]`

- `PATH` defaults to `ENV["ADDON_SOURCE_PATH"]` (dev already points it at
  `../tinkerex-addons/addons`). It refuses a missing or non-directory path with a message naming it.
- Reads the index through `Maker::Addons::Source::Local.new(PATH)`, never the configured source,
  so it cannot touch the network or a cache.
- Prints `Registry.problems`, plus three checks that only make sense on disk, for each manifest
  that would build:
  - `entry` file exists under `PATH/<key>/`
  - every `pins` value exists under `PATH/<key>/`
  - `PATH/<key>/` exists
  File paths go through `Source.validate_asset_path!` first, so a traversing `entry` is reported as
  a problem rather than resolved.
- Exit status: **0** clean (prints `N tools OK`), **1** with problems (one line per problem,
  `key: reason`). An unreadable or malformed `manifests.json` is exit 1 with the parse error.

### 3.4 The `/tools` notice, local environments only

When `Rails.env.local?`, `Tools::HomeController#index` renders a notice above the gallery when
`Registry.problems` is non-empty: *"2 tools weren't loaded"* followed by one `key — reason` line
each. Never in production: the cards are read by the maker, the rule the onboarding work applied
when it moved sidecar env-var names off them. File-existence checks are **not** in the notice —
they are `addons:check`'s, and a missing entry already announces itself on the tool page.

### 3.5 Docs

`docs/addon-api-v1.md` (the manifest section) and the skipping bullet in
`docs/invariants/addons.md` gain where the reason now surfaces: `addons:check`, the dev notice, the
log. The invariant itself is unchanged.

## 4. Addons side (`tinkerex-addons`, PR 2, after PR 1 merges)

### 4.1 `bin/new-addon <key> "<Title>" "<description>" [--icon <glyph>]`

- **Refuses** a key not matching `\A[a-z][a-z0-9-]*\z`, a key already in `manifests.json`, or an
  existing `addons/<key>/`. Refusal writes nothing.
- **Writes `addons/<key>/<key>.js`** — a minimal working SDK bundle (~50 lines): one text input, a
  "Save into" button calling `host.files.pickFolder()`, and a Save button calling
  `host.files.save({ name, folderNodeId, files: [{ name: "<input>.txt", contentType: "text/plain",
  body }], onReplace })`. It catches `NameTakenError` and `WouldReplaceError` separately (§14c's
  409-is-a-question rule) and reads through `host` at call time, never capturing it at top level.
- **Appends to `manifests.json`**: `key`, `title`, `icon` (default `🛠️`), `description`,
  `api_version: "1"`, `entry: "<key>.js"`, `min_host: 1` (everything the template uses is level 1),
  and `permissions: [{name: "library:write", reasoning: "Saves the file it makes into the library
  folder you pick."}]`. Written with `JSON.pretty_generate` + trailing newline — verified to
  round-trip today's file byte-identically, so sibling entries do not churn.
- If `../tinkerex` exists (or `TINKEREX_DIR`), runs `addons:check` against this checkout; otherwise
  says it skipped it.
- Prints the dev loop: start the tinkerex dev server, open `/tools/<key>` — dev reads this checkout
  directly through `Source::Local`, uncached.

Implemented in Ruby (the dev box has mise Ruby; the repo stays build-free — this is a tool, not a
step anything ships through).

### 4.2 `bin/publish`

Requires the tinkerex checkout (`TINKEREX_DIR`, default `../tinkerex`) — the Kamal config lives
there. Stops at the first failure, in order:

1. `addons:check` against `addons/` — refuse to publish a manifest the host would skip.
2. `bin/secrets-preflight` in tinkerex (base destination) — `kamal accessory reboot` expands
   secrets through Ruby backticks, so an unreadable one would otherwise become an empty one.
3. `bin/build-push`, unchanged (fixture-drift check, `-dirty` stamping, both tags), with
   `KAMAL_REGISTRY_PASSWORD` resolved by `bin/secret` in the README's single-command form when not
   already set. Never exported, never echoed, never in a pipeline.
4. `kamal accessory reboot addons` from tinkerex.
5. **Verify**: read `version.json` through `kamal accessory exec addons --reuse` and compare to the
   revision `build-push` pushed. A mismatch exits non-zero, saying the registry tag may not have
   persisted (the 2026-10-07 failure) and that re-running publish — a fresh push — is the fix.
6. Print: live on `/tools` within 5 minutes (the manifest cache).

**The revision has one definition: a new `bin/revision`** that prints the SHA, or `<SHA>-dirty` by
`build-push`'s existing `git status --porcelain -- addons nginx.conf Dockerfile` rule, moved there
verbatim with its comment. `build-push` and `publish` both call it. Publish does **not** parse
`build-push`'s output — capturing the stdout of a script that handles a registry password is the
shape the secret-leak record warns against, and a second copy of the dirty rule would drift.

### 4.3 README

"Adding or changing an addon" leads with `bin/new-addon` and the dev loop; "Deploying" becomes
`bin/publish`, with the manual steps kept below as what it runs.

## 5. Testing

**Host (PR 1)** — all run under every backend leg; none touches the port.
- `registry_test.rb`: each `problem_with` reason; `build` still returns nil for each; `problems`
  reports duplicates, unreciprocated `states_key`, and keyless entries by position; a clean index
  reports `[]`. Mutation-checked: drop the `problem_with` call from `build` → the existing
  skip tests go red; drop the duplicate arm → its test goes red.
- `addons:check` task test against temp directories: clean → exit 0; missing entry, missing pin,
  missing directory, traversing entry, malformed JSON → exit 1, each named.
- `home_controller_test.rb`: notice renders with a bad manifest in the fixture source; absent with
  a clean one; absent when `Rails.env` is production (stubbed). The existing card-count assertion
  stays green.

**Addons (PR 2)**
- `test/new_addon_test.sh` in a temp copy: files created, `manifests.json` valid JSON, existing
  entries byte-identical, refusals for a bad key, a taken key and an existing directory, and the
  generated entry passing `addons:check` when the sibling is present. Mutation-checked.
- `bin/publish` is orchestration over docker, ghcr and kamal: its proof is **one real publish** of
  the current bundles (no content change, so the gallery is unaffected), stated in the PR as the
  verification, including the version check passing.

## 6. Out of scope

- Sidecars (sub-project C, its own spec).
- Busting the manifest cache after publish.
- The three duplicated `folder_field.js` copies in the existing bundles — the template uses
  `pickFolder()` directly and does not add a fourth.
- Gating publish on a clean or pushed tree — `build-push`'s `-dirty` stamping is kept as is.
