# Stop Mentioning s3, Sync and the Desktop Client — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. In this repo `.claude/commands/execute-plan.md` overrides the generic loop. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Nothing a person reads names the `s3` backend, the sync server (`chunk_remote`), `chaim354/tinkerex-sync`, `chaim354/tinkerex-client` or the desktop client. No backend, deployment or CI leg changes.

**Architecture:** Wording edits in install docs, views, two controllers and two adapter messages. `docs/sync-protocol.md` moves to `tinkerex-sync`, with citations repointed in all three repos. Three guards back it: a doc test that INSTALL.md names none of the hidden variables or words, rendered-text assertions on the landing page, Help and Recent, and an exempt group in `install_docs_test`.

**Tech Stack:** Rails 8.1 views (ERB), Minitest integration tests, Markdown docs, `gh`.

**Spec:** `docs/superpowers/specs/2026-11-10-hide-s3-sync-and-desktop-design.md`. **Branch:** `claude/hide-s3-sync-client` (spec committed as `ea4c36e3`).

## Ground rules for every task

- **The hidden words** are case-insensitive `S3` (as a word), `bucket`, `chunk_remote`, `chunk-remote`, `sync server`, `sync-server`, `sync engine`, `tinkerex-sync`, `tinkerex-client`, `desktop app` and `desktop client`. Docker's product name "Docker Desktop" is not one of them.
- **Text that renders only under `capabilities.syncable?` stays.** It describes the author's own chunk_remote deployment. So do `docs/guides/DEPLOY.md`, `CLAUDE.md` (except Task 4's path edits), `docs/invariants/`, boot refusals, log lines, `bin/` output and code comments.
- **Never edit `db/migrate/`.**
- **Implementers write; the orchestrator commits** by pathspec (memory: parallel agents race on the git index).
- **Run Ruby edit scripts** with `LANG=en_US.UTF-8 ruby -Eutf-8:utf-8`, and use block-form `gsub`/`sub`.
- **A backend leg needs its env:** `LIBRARY_PATH=$(mktemp -d) bin/rails test <file>` for a single test file.

## File map

| task | files |
|---|---|
| 1 | `docs/INSTALL.md`, `test/install_docs_test.rb`, `.env.example`, `docker-compose.yml`, `docker-compose.chunk_remote.yml` (delete), `test/deploy_hygiene_test.rb` |
| 2 | `README.md`, `SECURITY.md`, `docs/addon-api-v1.md`, `docs/guides/mcp.md` |
| 3 | `app/views/landings/show.html.erb`, `app/views/help/show.html.erb`, `app/views/shared/_where_files_come_from.html.erb`, `app/views/layouts/_library_unreachable.html.erb`, `app/views/settings/show.html.erb`, `app/views/settings/devices/index.html.erb`, `app/views/settings/users/edit.html.erb`, `app/views/users/registrations/edit.html.erb`, `app/controllers/settings_controller.rb`, `app/controllers/concerns/library_capabilities.rb`, `app/services/file_layer/s3.rb`, `test/support/hidden_backend_words.rb` (new), `test/integration/web/{landing,help_page,where_files_come_from,library_unreachable,settings_devices,settings_devices_connect,settings_library}_test.rb` |
| 4 | `docs/sync-protocol.md` (move), `docs/README.md`, `CLAUDE.md`, `docs/reference/roads-not-taken.md`, `app/services/file_layer/chunk_remote/changelog_sync.rb`, `app/services/maker/addons/library_output.rb`, `test/integration/chunk_remote_journey_test.rb`, `test/integration/v1/sync_surface_absent_test.rb`, `test/services/file_layer/chunk_remote/changelog_sync_test.rb`; in `../tinkerex-sync`: `docs/sync-protocol.md`, `CLAUDE.md`, `README.md`, `conformance/README.md`; in `../tinkerex-client`: `README.md`, `CLAUDE.md`, `client/sync-client/src/lib.rs`, `client/sync-engine/tests/fault_injection.rs` |
| 5 | none: sweep, `bin/ci`, mutation checks, PRs, record |

Tasks 1–4 touch disjoint files and can run in parallel. Task 5 runs last.

---

### Task 1: The install guide and its guard

**Files:** `docs/INSTALL.md`, `test/install_docs_test.rb`, `.env.example`, `docker-compose.yml`, delete `docker-compose.chunk_remote.yml`, `test/deploy_hygiene_test.rb`.

- [ ] **Step 1: Write the failing guard.** In `test/install_docs_test.rb`, add a constant after `NOT_FOR_INSTALLERS`'s comment block (after line 25):

```ruby
  # THE s3 AND chunk_remote BACKENDS STILL RUN (the author's Unraid destinations and the public OVH
  # box) BUT ARE NO LONGER OFFERED TO INSTALLERS (2026-11-10, docs/superpowers/specs/
  # 2026-11-10-hide-s3-sync-and-desktop-design.md), so their variables have no row and the page
  # must not name them. DERIVED from the boot guard's own required lists, so a knob the guard comes
  # to require is exempted with it; the optional ones are named here. A NEW variable read only by
  # those backends belongs in OPTIONAL; anything else still needs a row.
  HIDDEN_BACKEND_OPTIONAL = %w[
    LIBRARY_S3_ENDPOINT LIBRARY_S3_REGION LIBRARY_S3_PREFIX
    ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY ACTIVE_RECORD_ENCRYPTION_DETERMINISTIC_KEY
    ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT
  ].freeze
  HIDDEN_BACKEND_VARIABLES = (LibraryBackendCheck::S3_REQUIRED + LibraryBackendCheck::CHUNK_REMOTE_REQUIRED +
                              HIDDEN_BACKEND_OPTIONAL).uniq.freeze
  HIDDEN_WORDS = /\bS3\b|\bbuckets?\b|chunk[_-]remote|sync[ -]server|sync engine|tinkerex-sync|tinkerex-client|desktop (?:app|client)/i
```

Change the first test's `names` line to subtract the group:

```ruby
    names = names_read_by_the_code - NOT_FOR_INSTALLERS - HIDDEN_BACKEND_VARIABLES
```

Change the second test's file list to `%w[docker-compose.yml docker-compose.build.yml .env.example]`. Then add:

```ruby
  test "the install guide and the files it hands out name no hidden backend" do
    %w[docs/INSTALL.md docker-compose.yml docker-compose.build.yml .env.example].each do |file|
      text = Rails.root.join(file).read
      named = HIDDEN_BACKEND_VARIABLES.select { |v| text.include?(v) }
      assert_empty named, "#{file} names #{named.join(', ')}, a variable of a backend installers are not offered"
      hits = text.lines.each_with_index.filter_map { |l, i| "#{i + 1}: #{l.strip}" if l.match?(HIDDEN_WORDS) }
      assert_empty hits, "#{file} mentions a hidden backend:\n#{hits.join("\n")}"
    end
    refute Rails.root.join("docker-compose.chunk_remote.yml").exist?, "the sync-server overlay is not handed out"
  end
```

- [ ] **Step 2: Run it and see it fail.** Run `LIBRARY_PATH=$(mktemp -d) bin/rails test test/install_docs_test.rb`. Expected: the new test fails, listing INSTALL.md lines 15, 263, 271, 273, 275, 277, 279, 368, 377, 394, 407, 435 and §9, plus `.env.example` and `docker-compose.yml`.

- [ ] **Step 3: Edit `docs/INSTALL.md`.** Make each of these replacements, matching the text exactly.
  1. Lines 15–17, the paragraph starting "The other ways to run it", become:
     `Postgres instead of SQLite is **a work in progress**, in section 9, Advanced; nothing before it depends on it.`
  2. Lines 262–264: delete the sentence `(Open sign-ups belong to the sync server, an advanced backend where each account has its own library — section 9.)`. The paragraph then ends `…hand any visitor your files.`
  3. `Every account on a folder or bucket library sees the same files` becomes `Every account sees the same files`.
  4. `signs it out of every browser and every desktop app), sign out one of its desktop apps, make it an admin` becomes `signs it out of every browser and every connected app), sign out one of its connected apps, make it an admin`. Delete the sentence `On a sync-server library, a desktop app that is signed out keeps its separate sync key, so its files keep syncing until that key is removed on the sync server.` Re-wrap the paragraph to ~100 columns.
  5. `**Your own desktop apps** are listed under **Settings → Devices**, where you can sign any of them out.` becomes `**The apps connected to your account** (an AI assistant over MCP, for one) are listed under **Settings → Devices**, where you can sign any of them out.`
  6. In §7's intro, `The advanced options' variables — the s3 backend's, the sync server's and Postgres's — are in section 9's own table; the two tables together name every variable the app reads.` becomes `Postgres's variables are in section 9's own table.`
  7. The `LIBRARY_BACKEND` row's last cell becomes: `Where the files live. \`share\` (a folder) is the default and what this page installs; leave it unset. Chosen per deployment, never per user. An explicit blank refuses the boot, and so does a misspelled value (\`Share\`, or a stray space).`
  8. The `REGISTRATION` row: delete ` Only the sync server (section 9) accepts it.`
  9. The `DEVICE_IDLE_DAYS` row's last cell becomes: `Days a connected app may go without using the API before its sign-in expires and it must sign in again. \`0\` keeps every device signed in until it is signed out under Settings → Devices or its account's password changes.`
  10. §8: delete `(and, on the sync server backend in section 9, the \`ACTIVE_RECORD_ENCRYPTION_*\` values from the environment)` and the space before it, so the sentence reads `…from the file generated into the volume on the first start.`
  11. §9: replace lines 443–533, from the intro paragraph through the end of "The sync server (chunk_remote)" and its **Backups** paragraph, with:

```markdown
Sections 1 to 8 are a complete install, and the `share` backend they set up is the one to use.
Postgres instead of SQLite is **still a work in progress**: it has no template, and the steps may
change from one release to the next.
```

  12. "Reference: the advanced variables": the intro becomes `The same columns as section 7.` Delete every row from `| **The s3 backend** | | | |` through the `CHUNK_PUBLIC_URL` row. Keep the Postgres group row and its four rows.

- [ ] **Step 4: Edit `.env.example`.** Delete the blank line before `# ---- Work in progress: the sync server …` and every line from that header through `# ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT=`. The file then ends with `# TINKEREX_ADDONS_PATH=../tinkerex-addons` and a newline.

- [ ] **Step 5: Edit `docker-compose.yml`.** Delete line 13: `# docker-compose.chunk_remote.yml adds the sync server, a work in progress (INSTALL.md section 9).`

- [ ] **Step 6: Delete the overlay.** `git rm -q docker-compose.chunk_remote.yml`.

- [ ] **Step 7: Edit `test/deploy_hygiene_test.rb`.** At line 111, `%w[docker-compose.build.yml docker-compose.chunk_remote.yml].each do |overlay|` becomes `%w[docker-compose.build.yml].each do |overlay|`. In the comment two lines above, `the build and sync overlays describe a clone's setup` becomes `the build overlay describes a clone's setup`. Then run `grep -n chunk_remote.yml test/deploy_hygiene_test.rb .dockerignore`. Any other line that names the deleted file goes the same way. `.dockerignore`'s `/docker-compose*.yml` glob needs no change.

- [ ] **Step 8: Run the guards.** Run `LIBRARY_PATH=$(mktemp -d) bin/rails test test/install_docs_test.rb test/deploy_hygiene_test.rb test/integration/web/compose_generator_test.rb test/lib/sidecars_test.rb`. Expected: all pass.
  - If the first install-docs test names a variable that is still missing, check where it is read with `git grep -n '<NAME>' app lib config`. If only `app/services/file_layer/s3*`, `app/services/library/s3_observer.rb` or `app/services/file_layer/chunk_remote*` read it, add it to `HIDDEN_BACKEND_OPTIONAL`. Otherwise give it a row in §7.

- [ ] **Step 9: Hand back** the list of files changed. The orchestrator commits:

```bash
git add docs/INSTALL.md test/install_docs_test.rb .env.example docker-compose.yml docker-compose.chunk_remote.yml test/deploy_hygiene_test.rb
git commit -F <msg file>   # subject: "The install guide offers the folder install only, and a test keeps s3 and sync out of it"
```

---

### Task 2: README, SECURITY and the two guides

**Files:** `README.md`, `SECURITY.md`, `docs/addon-api-v1.md`, `docs/guides/mcp.md`.

- [ ] **Step 1: `README.md`.**
  - The first paragraph ends at `…save their output straight into the library.` Delete the sentence about the desktop sync client and re-wrap.
  - Status: delete the sentence `Other ways to hold them (your own S3 bucket, or the sync server that adds per-account libraries and versions) are a work in progress, collected under Advanced in the guide.`
  - The repositories table: delete the `chaim354/tinkerex-sync` and `chaim354/tinkerex-client` rows.
  - Developing: `` `bin/ci` runs every gate, and `bin/ci --list` names them; the suite runs once per library backend — `test` (share), `test-s3` and `test-chunk-remote`, the last against a sibling checkout of `tinkerex-sync` — and the three must report identical run counts. `` becomes `` `bin/ci` runs every gate, and `bin/ci --list` names them. ``
  - Licence: `The sibling repositories are MIT (\`tinkerex-sync\`, \`tinkerex-addons\`) and Apache-2.0 (\`tinkerex-client\`).` becomes `The addon bundles (\`tinkerex-addons\`) are MIT.`
- [ ] **Step 2: `SECURITY.md`.**
  - `The same door exists on the sibling repositories, \`chaim354/tinkerex-sync\`, \`chaim354/tinkerex-client\` and \`chaim354/tinkerex-addons\`, so report against the repository that holds the code` becomes `The same door exists on \`chaim354/tinkerex-addons\`, so report against the repository that holds the code`.
  - `the addon bundles (\`tinkerex-addons\`), the sync server (\`tinkerex-sync\`) and the desktop client (\`tinkerex-client\`).` becomes `and the addon bundles (\`tinkerex-addons\`).` Fix the list's commas so it reads `…the images built from it (…), and the addon bundles (…).`
  - `on the \`share\` and \`s3\` backends every account on one server indexes the same library` becomes `every account on one server indexes the same library`.
- [ ] **Step 3: `docs/addon-api-v1.md`.**
  - Lines 625–626: `On a chunk-backed host the old bytes survive in the library's own version chain; on a share- or S3-backed host they do not.` becomes `Whether the old bytes survive depends on the host; do not count on it.`
  - The `not_found` row: delete `Raised only on a share/S3-backed host; a chunk-backed host accepts those names. `.
  - Line 1210: `Verified against a running host on both the chunk and share backends.` becomes `Verified against a running host.`
  - Line 1367: `The params are the history; on a chunk-backed host the old bytes also survive in the library's own version chain, but that is the host's storage backend and not something your bundle can require.` becomes `The params are the history; whether the old bytes also survive is up to the host, and not something your bundle can require.`
- [ ] **Step 4: `docs/guides/mcp.md`.** Line 31: `like a desktop app` becomes `like any other connected app`.
- [ ] **Step 5: Check.** Run `grep -nEi '\bS3\b|\bbuckets?\b|chunk[_-]remote|chunk-backed|sync[ -]server|sync engine|tinkerex-sync|tinkerex-client|desktop (app|client)' README.md SECURITY.md docs/addon-api-v1.md docs/guides/mcp.md`. Expected: no output.
- [ ] **Step 6: Hand back.** The orchestrator commits these four paths. Subject: `The README, security policy and guides name only the folder library and the addon repo`.

---

### Task 3: The text every deployment shows, and the s3-only text

**Files:** see the file map. New: `test/support/hidden_backend_words.rb`.

- [ ] **Step 1: The shared matcher.** Create `test/support/hidden_backend_words.rb`:

```ruby
# THE WORDS NO RENDERED PAGE SAYS (2026-11-10, docs/superpowers/specs/
# 2026-11-10-hide-s3-sync-and-desktop-design.md). s3 and the sync server still run, but nothing a
# person reads names them, the sibling repos or the desktop client -- except text that renders only
# when the library is syncable, which describes the author's own chunk_remote deployment.
module HiddenBackendWords
  PATTERN = /\bS3\b|\bbuckets?\b|chunk[_-]remote|sync[ -]server|sync engine|tinkerex-sync|tinkerex-client|desktop (?:app|client)s?/i

  def assert_no_hidden_backend_words(text, where)
    hits = text.scan(PATTERN)
    assert_empty hits, "#{where} says #{hits.uniq.join(', ')}"
  end
end
```

`test/test_helper.rb` does not load `test/support/` (checked; each test requires its own support file, as `where_files_come_from_test.rb` does with `require "support/public_fixture"`), so add `require "support/hidden_backend_words"` under `require "test_helper"` in `landing_test.rb`, `help_page_test.rb` and `where_files_come_from_test.rb`.

- [ ] **Step 2: Write the failing assertions.**
  - **`test/integration/web/landing_test.rb`.** `include HiddenBackendWords` in the class, then add:

```ruby
    test "the landing names no storage but a folder" do
      demo_on!
      get root_path
      assert_response :success
      assert_no_hidden_backend_words(css_select("main").text.squish, "the landing")
      assert_select "li", text: /Point it at a folder.*A folder or a NAS share/m
    end
```

  - **`test/integration/web/help_page_test.rb`**, in "the library section says where files come from on each kind of backend":
    - include `HiddenBackendWords`;
    - after the folder render, add `assert_no_hidden_backend_words(response.body.then { |b| Nokogiri::HTML(b).at("main").text.squish }, "Help on a folder library")`;
    - in the bucket block, `assert_match(/storage bucket/i, maker_text)` becomes `assert_match(/storage this server was set up with/i, maker_text)`, followed by `assert_no_hidden_backend_words(maker_text, "Help on an s3 library")`;
    - leave the sync block as it is.
  - **`test/integration/web/where_files_come_from_test.rb`**, in "a bucket-backed library names the bucket, not a folder":
    - rename the test `"an s3-backed library names its storage, not a folder"`;
    - `/storage bucket.*within 15 minutes.*Rescan library/` becomes `/storage this server uses.*within 15 minutes.*Rescan library/`;
    - include the module and add `assert_no_hidden_backend_words(sources, "Recent's sources on an s3 library")`;
    - in the synced test, `storage bucket` in the refute becomes `storage this server uses`.
  - **`test/integration/web/library_unreachable_test.rb`** line 92: `"the storage bucket isn't answering"` becomes `"the library storage isn't answering"`.
  - **`test/integration/web/settings_devices_test.rb`:**
    - line 38: `/Devices\s*2 desktop apps/` becomes `/Devices\s*2 connected apps/`;
    - line 186: `/\AThe desktop apps and assistants connected to your account/` becomes `/\AThe apps and assistants connected to your account/`;
    - line 197: `"No desktop app is signed in to #{@user.email}."` becomes `"No app is signed in to #{@user.email}."`.
  - **`test/integration/web/settings_devices_connect_test.rb`** line 34: `/desktop apps and assistants/` becomes `/apps and assistants connected/`.
  - **`test/integration/web/settings_library_test.rb`** line 452: `/storage bucket|sync server/` becomes `/server storage|sync server/`.

- [ ] **Step 3: Run them and see them fail.** Run `LIBRARY_PATH=$(mktemp -d) bin/rails test test/integration/web/{landing,help_page,where_files_come_from,library_unreachable,settings_devices,settings_devices_connect,settings_library}_test.rb`. Expected: the new and changed assertions fail on the old copy.

- [ ] **Step 4: Change the copy.**
  - **`app/views/landings/show.html.erb`** line 67: `<p>A NAS share, an S3 bucket or a sync server. Nothing is imported or copied.</p>` becomes `<p>A folder or a NAS share. Nothing is imported or copied.</p>`.
  - **`app/views/help/show.html.erb`:**
    - the `presignable?` paragraph's first sentence `Your library is a storage bucket.` becomes `Your library is the storage this server was set up with.`;
    - `covers installing, the three library backends, mail, accounts and backups.` becomes `covers installing, mail, accounts and backups.`;
    - replace the two lines `is accepted only on the sync-server backend, where every account has a library of its own.` with:

```erb
      <% if capabilities.syncable? %>is accepted only on the sync-server backend, where every account
        has a library of its own.<% else %>is refused at boot, because every account sees the same
        library.<% end %>
```

  - **`app/views/shared/_where_files_come_from.html.erb`:** `<p><strong>The storage bucket</strong> this server uses is your library. Files another program or a sync tool puts there appear here` becomes `<p><strong>The storage this server uses</strong> is your library. Files another program puts there appear here`. Keep the rest of the sentence.
  - **`app/views/layouts/_library_unreachable.html.erb`:** `"the storage bucket isn't answering"` becomes `"the library storage isn't answering"`.
  - **`app/controllers/settings_controller.rb`:** `capabilities.presignable? ? "storage bucket" : "sync server"` becomes `capabilities.presignable? ? "server storage" : "sync server"`.
  - **`app/views/settings/show.html.erb`:** `pluralize(@device_count, "desktop app")` becomes `pluralize(@device_count, "connected app")`.
  - **`app/views/settings/devices/index.html.erb`:** `The desktop apps and assistants connected to your account, most recently used first.` becomes `The apps and assistants connected to your account, most recently used first.`. The `syncable?` block stays.
  - **`app/views/settings/users/edit.html.erb`:**
    - `out of every browser and every desktop app.` becomes `out of every browser and every connected app.`;
    - `No desktop app is signed in to <%= @user.email %>.` becomes `No app is signed in to <%= @user.email %>.`;
    - the `syncable?` blocks stay.
  - **`app/views/users/registrations/edit.html.erb`:** `signs out every desktop app (Settings → Devices).` becomes `signs out every connected app (Settings → Devices).`
  - **`app/controllers/concerns/library_capabilities.rb`**, `CAPABILITY_ABSENT`:
    - `versioned:` becomes `"this deployment keeps no file history, so there is nothing to list or restore."`;
    - `syncable:` becomes `"this deployment does not sync files to devices."`;
    - keep ASCII.
  - **`app/services/file_layer/s3.rb`:**
    - `movable_file!`'s message becomes `"#{node.node_id.inspect} is a #{node.kind}: this library moves files only, one at a time, never a whole folder"`;
    - `copyable_size!`'s becomes `"#{node.node_id.inspect} is #{node.size} bytes: over the 5 GiB this library can move or delete in one step. Refusing rather than half-deleting it."`;
    - leave the comments above both methods as they are.

- [ ] **Step 5: Find any other test that pins the old strings.** Run `git grep -nE 'storage bucket|desktop apps? |keeps no file history|no sync engine|s3-mode move|copy cap|three library backends' -- test`. Update each hit that asserts the old copy. Comments in a `chunk_remote` journey or a `syncable` test are not assertions; leave them.

- [ ] **Step 6: Run them and see them pass.** Re-run Step 3's command, then `LIBRARY_PATH=$(mktemp -d) bin/rails test test/integration/web test/services/file_layer`. Expected: no failures.

- [ ] **Step 7: Hand back.** The orchestrator commits the Task 3 paths. Subject: `The landing, Help and Settings name no bucket, no sync server and no desktop app`.

---

### Task 4: `docs/sync-protocol.md` moves to `tinkerex-sync`

**Files:** see the file map. Uses scratchpad worktrees for both siblings; their main checkouts are never switched.

- [ ] **Step 1: The `tinkerex-sync` PR.**

```bash
S=<scratchpad>; git -C ../tinkerex-sync fetch -q origin
git -C ../tinkerex-sync worktree add -q -b claude/own-the-wire-spec "$S/sync-wire" origin/main
git -C . show origin/main:docs/sync-protocol.md > "$S/sync-wire/docs/sync-protocol.md"
```

  - Under the document's `# ` title, insert:

```markdown
> **Moved here from `chaim354/tinkerex` on 2026-11-10.** It specifies the wire between this server
> and its clients: the maker app's `FileLayer::ChunkRemote` and `chaim354/tinkerex-client`. Paths
> under `app/`, `lib/`, `test/` and `config/`, and `CLAUDE.md §` numbers, are the maker app's.
```

  - Repoint the citations:
    - `CLAUDE.md` line 102: `` Normative wire spec: `docs/sync-protocol.md` in the maker-app repo (`chaim354/tinkerex`) `` becomes `` Normative wire spec: `docs/sync-protocol.md`, in this repo since 2026-11-10 (it lived in `chaim354/tinkerex`) ``. Read the line first and keep the rest of the sentence.
    - `README.md` line 105: `The wire is specified in \`docs/sync-protocol.md\` in the maker repo.` becomes `The wire is specified in \`docs/sync-protocol.md\`.`
    - `conformance/README.md` lines 16–17: `read \`docs/sync-protocol.md\` in the sibling \`chaim354/tinkerex\` repository (\`../tinkerex/docs/sync-protocol.md\` from here, if you have it` becomes `read \`docs/sync-protocol.md\` (\`../docs/sync-protocol.md\` from here`. Read both lines and keep the closing of the parenthesis.
    - Then run `git -C "$S/sync-wire" grep -n 'tinkerex/docs/sync-protocol\|maker.*sync-protocol'`. Expected: no output.
  - Commit with subject `The wire spec lives with the server it specifies` and the body naming the source commit `203f7092` of `chaim354/tinkerex`. Push and open the PR. Its body says to merge it first.

- [ ] **Step 2: The `tinkerex-client` PR.** Make a worktree `"$S/client-wire"` on `claude/wire-spec-in-sync-repo` from `origin/main` the same way. Then:
  - `README.md` line 26: `in chaim354/tinkerex.` becomes `in chaim354/tinkerex-sync.`;
  - `CLAUDE.md` line 243: move the "Owns `docs/sync-protocol.md`, the normative wire spec" clause from the `chaim354/tinkerex` row to the `chaim354/tinkerex-sync` row. Read the table first and keep each row's other text;
  - `client/sync-client/src/lib.rs` line 1: `` (`docs/sync-protocol.md`) `` becomes `` (`docs/sync-protocol.md` in chaim354/tinkerex-sync) ``;
  - `client/sync-engine/tests/fault_injection.rs` line 21: `` mirroring `docs/sync-protocol.md` `` becomes `` mirroring tinkerex-sync's `docs/sync-protocol.md` ``;
  - commit with subject `The wire spec is cited where it now lives, in tinkerex-sync`, push and open the PR.

- [ ] **Step 3: This repo.**
  - `git rm -q docs/sync-protocol.md`.
  - `docs/README.md`: delete the `sync-protocol.md` row. The heading's table now lists `INSTALL.md` and `addon-api-v1.md`.
  - `CLAUDE.md`: run `grep -n 'sync-protocol' CLAUDE.md` and rewrite each hit by hand:
    - §2 and §6: `` `docs/sync-protocol.md` `` becomes `` `docs/sync-protocol.md` in `chaim354/tinkerex-sync` ``;
    - §10's `/docs` line: `INSTALL.md, sync-protocol.md, addon-api-v1.md (linked by URL or by sibling repos, so` becomes `INSTALL.md, addon-api-v1.md (linked by URL or by a sibling repo, so`.
  - Comments in `app/services/file_layer/chunk_remote/changelog_sync.rb`, `app/services/maker/addons/library_output.rb`, `test/integration/chunk_remote_journey_test.rb`, `test/integration/v1/sync_surface_absent_test.rb` (line 18 only) and `test/services/file_layer/chunk_remote/changelog_sync_test.rb`, plus `docs/reference/roads-not-taken.md`: every `docs/sync-protocol.md`, and every bare `sync-protocol.md` not already preceded by `docs/`, becomes `tinkerex-sync's docs/sync-protocol.md`. Leave the test name `"no sync-protocol endpoint is routed by this app"` and `db/migrate/` alone.
  - Run `git grep -n 'sync-protocol\.md' -- ':!db/migrate' ':!docs/superpowers'`. Expected: every hit reads `tinkerex-sync`.
- [ ] **Step 4: Run.** `LIBRARY_PATH=$(mktemp -d) bin/rails test test/docs_hygiene_test.rb test/integration/v1/sync_surface_absent_test.rb test/services/file_layer/chunk_remote/changelog_sync_test.rb`. Expected: pass (the chunk_remote tests skip or pass on share; that is their usual shape).
- [ ] **Step 5: Hand back.** Give the two PR URLs. The orchestrator commits this repo's paths. Subject: `The wire spec moves to tinkerex-sync; this repo cites it there`.

---

### Task 5: Sweep, gates, PRs, record

- [ ] **Step 1: The sweep.** Run:

```bash
grep -rnEi '\bS3\b|\bbuckets?\b|chunk[_-]remote|sync[ -]server|sync engine|tinkerex-sync|tinkerex-client|desktop (app|client)' README.md SECURITY.md .env.example docker-compose.yml docker-compose.build.yml docs/INSTALL.md docs/README.md docs/addon-api-v1.md docs/guides/mcp.md docs/guides/adding-a-preview-format.md
```

  - Expected: no output.
  - Then grep `app/views` and `app/controllers` with the same pattern, and read each hit. Every remaining hit must be in an ERB comment (`<%# … %>`), a Ruby comment, or inside an `if capabilities.syncable?` branch.
- [ ] **Step 2: Mutation checks.** Each must go red, then be restored with `git checkout -- <file>` followed by `rm -rf tmp/cache/bootsnap*`.
  1. Put `an S3 bucket or ` back into the landing line; `landing_test` goes red.
  2. Put `storage bucket` back into Help's s3 paragraph; `help_page_test` goes red.
  3. Add `# LIBRARY_S3_BUCKET=` to `.env.example`; `install_docs_test` goes red, with two messages.
  4. Remove `LIBRARY_S3_REGION` from `HIDDEN_BACKEND_OPTIONAL`; `install_docs_test`'s first test goes red, asking for a row.
- [ ] **Step 3: Full `bin/ci`** in the background. All gates must pass with identical RUN counts.
- [ ] **Step 4: Close out with `/finish-branch`.** Push, then `gh pr create` with a verification table. The PR names the merge order: tinkerex-sync first, then this one, then tinkerex-client. Then run `bin/log arc --from-pr <n>`.
