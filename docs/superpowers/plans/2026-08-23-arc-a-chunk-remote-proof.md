# Arc A — the executable proof that `chunk_remote` works

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development
> (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use
> checkbox (`- [ ]`) syntax for tracking.

**Goal:** stand up a real standalone sync server, drive the maker app against it under
`LIBRARY_BACKEND=chunk_remote`, and turn "chunk_remote works" into a measured result — a
checked-in inventory of exactly what is broken, produced by running the thing rather than by
reading it.

**Architecture:** a `bin/sync-server` script boots a sibling `chaim354/tinkerex-sync` checkout's
`host/` app and mints a device token. A **journey suite** signs in to the maker app and drives the
real user flows (upload, list, download, mkdir, move, delete, trash, restore, addon save, project
intake, freshness) against that server. A separate workflow, `sync-contract.yml`, runs it on every
PR. The journey suite **skips cleanly when no server is configured**, so `bin/ci` stays green
while `sync-contract.yml` carries the red signal.

**Tech Stack:** Rails 8, Minitest / `ActionDispatch::IntegrationTest`, `Net::HTTP` (stdlib),
bash, GitHub Actions on the self-hosted macOS runner.

**Spec:** `docs/superpowers/specs/2026-08-23-stage-5-engine-leaves-the-process-design.md`, Arc A.

---

## Scope, and two corrections to the spec this plan makes

**This plan is Arc A Part 1 only — the executable proof, entirely in this repo.** Arc A's other
half (A2, the portable conformance corpus, and A3, the normative `sync-protocol.md` rewrite) is a
sibling plan whose tasks run in `../tinkerex-sync`. It shares nothing with this plan but the boot
recipe, so the two can be executed in either order or in parallel.

Two things the spec assumed that measurement contradicted. Both are recorded here rather than
worked around silently:

**1. `test-chunk-remote` cannot be a `bin/ci` gate yet, so this plan ships a separate workflow
instead.** `test/ci_hygiene_test.rb` asserts SET EQUALITY between `bin/ci --list-ci` and `ci.yml`'s
gate jobs, and a second test asserts `setup` is the only gate permitted in `LOCAL_ONLY_GATES`. So
a gate that is red is a `main` that is red, and there is no sanctioned parking spot. The precedent
for a cross-repo wire-contract check that is *not* a gate is already in the tree:
`.github/workflows/client-contract.yml`, which boots a real Rails server and runs the Rust
integration suite without ever invoking `bin/ci`. `test-chunk-remote` becomes a real gate at the
end of Arc B, when it can be green.

**2. The leg runs a focused journey suite, NOT the full maker suite.** Three measured reasons:

- **One shared remote library.** `ChunkRemote` resolves a single process-wide token
  (`chunk_remote.rb:327-328`), so every test's maker user maps to ONE sync-server user. The suite
  runs in parallel workers; they would all write into that one library.
- **No per-test isolation exists to fix it.** Rolling back the maker DB does not roll back the sync
  server, so a `mkdir "Projects"` in test A makes test B's identical mkdir a 409 — noise failures
  that say nothing about chunk_remote. Per-test library isolation needs a provisioning endpoint,
  which is **Arc C**. That is an ordering dependency the spec did not have: **the full-suite leg
  comes after Arc C, not in Arc A.**
- **63 of 218 test files build nodes with `user.nodes.create!`** (255 occurrences). Those read fine
  on chunk_remote — reads are local SQL against `user.nodes` — but any of them that then calls a
  write verb POSTs about a node the server has never heard of. That is a test-shape problem, not a
  chunk_remote defect, and it would dominate the inventory.

A journey suite is sequential, uses one library on purpose, creates every node through a real
door, and therefore reports only real defects.

---

## File Structure

| File | Responsibility |
|---|---|
| `bin/sync-server` (create) | Resolve a sibling `tinkerex-sync`, prepare its DB, mint a device token, boot it. Two subcommands so CI can background the boot. |
| `test/support/chunk_remote_journey.rb` (create) | The harness: skip logic, web sign-in, and an upload helper that PUTs bytes to a real remote URL over `Net::HTTP` rather than through the integration session. |
| `test/integration/chunk_remote_journey_test.rb` (create) | The journey itself, one test per flow. The only file that knows what "works" means. |
| `.github/workflows/sync-contract.yml` (create) | Boot the server on the macOS runner and run the journey suite. Not a `bin/ci` gate. |
| `test/bin_sync_server_test.rb` (create) | Guards `bin/sync-server`'s contract without needing a checkout: executable, fails loudly and names the clone command when the sibling is missing. |
| `docs/superpowers/plans/2026-08-23-arc-b-worklist.md` (create, Task 7) | The measured inventory. Generated from the run, not written from memory. |
| `docs/STATUS.md` (modify) | The arc entry, same branch, same PR (§15). |

---

## Task 1: `bin/sync-server`

**Files:**
- Create: `bin/sync-server`
- Test: `test/bin_sync_server_test.rb`

- [ ] **Step 1: Write the failing test**

Create `test/bin_sync_server_test.rb`:

```ruby
# frozen_string_literal: true

require "test_helper"
require "open3"

# GUARDS THE ONE THING THAT CAN BE GUARDED WITHOUT A CHECKOUT: that a missing sibling repo fails
# LOUDLY and names the fix. This is the shape scripts/r2-cutover/smoke.sh already uses for
# tinkerex-client, and the reason is the same -- nothing in bin/ci boots a sync server, so the
# script's failure message IS its error handling (CLAUDE.md §14i: some things cannot go red in CI,
# so the message has to carry the whole story).
class BinSyncServerTest < ActiveSupport::TestCase
  SCRIPT = Rails.root.join("bin/sync-server")

  test "the script is executable" do
    assert SCRIPT.exist?, "bin/sync-server is missing"
    assert SCRIPT.executable?, "bin/sync-server must be chmod +x or CI cannot invoke it"
  end

  test "a missing sibling checkout exits non-zero and names the clone command" do
    out, status = Open3.capture2e(
      { "TINKEREX_SYNC_DIR" => Dir.mktmpdir("absent") }, SCRIPT.to_s, "prepare"
    )

    assert_not status.success?, "a missing tinkerex-sync must fail, not fall through:\n#{out}"
    assert_includes out, "chaim354/tinkerex-sync",
                     "the failure must name the repo, not just the path it looked in"
    assert_includes out, "gh repo clone",
                     "the failure must name the command that fixes it"
  end

  test "an unknown subcommand is refused rather than silently doing nothing" do
    out, status = Open3.capture2e(SCRIPT.to_s, "frobnicate")

    assert_not status.success?
    assert_includes out, "prepare", "the usage message must name the real subcommands"
    assert_includes out, "start"
  end
end
```

- [ ] **Step 2: Run it to verify it fails**

```bash
bin/rails test test/bin_sync_server_test.rb
```

Expected: 3 failures, the first `bin/sync-server is missing`.

- [ ] **Step 3: Write the script**

Create `bin/sync-server`:

```bash
#!/usr/bin/env bash
# BOOT A STANDALONE tinkerex-sync HOST, for local chunk_remote work and for sync-contract.yml.
#
# WHY A SIBLING CHECKOUT RATHER THAN THE INSTALLED GEM. The gem currently ships host/, so
# `bundle show tinkerex-sync`/host would work today -- and stops working the moment Stage 5 Arc D
# removes the gem, which is the whole direction of travel. A sibling checkout is the durable
# answer and matches the ../tinkerex-client convention this repo already uses
# (scripts/r2-cutover/smoke.sh, .github/workflows/client-contract.yml).
#
# TWO SUBCOMMANDS, because CI has to background the boot and still know the token:
#   prepare  migrate the host DB, mint a device token, write tmp/sync-server.env, print it
#   start    run the server in the FOREGROUND on $SYNC_PORT (the caller backgrounds it)
#
# THERE IS NO /up ON THIS HOST -- its routes are the v1 namespace plus dev/blobs and nothing else
# (checked, not assumed). So readiness is probed with an authenticated GET /v1/devices/whoami,
# which has the side benefit of proving the token works rather than only that a port is open.
set -euo pipefail

PORT="${SYNC_PORT:-3002}"
EMAIL="${SYNC_EMAIL:-maker@example.com}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/.." && pwd)"
SYNC_DIR="${TINKEREX_SYNC_DIR:-$REPO_ROOT/../tinkerex-sync}"
HOST_DIR="$SYNC_DIR/host"
ENV_FILE="$REPO_ROOT/tmp/sync-server.env"

usage() {
  echo "usage: bin/sync-server {prepare|start}" >&2
  echo "  prepare  migrate the sync host DB, mint a device token, write tmp/sync-server.env" >&2
  echo "  start    boot the sync host in the foreground on \$SYNC_PORT (default $PORT)" >&2
}

require_checkout() {
  if [ ! -d "$HOST_DIR" ]; then
    echo "tinkerex-sync host app not found at $HOST_DIR" >&2
    echo "" >&2
    echo "The sync engine lives in chaim354/tinkerex-sync. Clone it as a sibling:" >&2
    echo "    gh repo clone chaim354/tinkerex-sync $SYNC_DIR" >&2
    echo "or point this script at an existing checkout:" >&2
    echo "    TINKEREX_SYNC_DIR=/path/to/tinkerex-sync $0 ${1:-prepare}" >&2
    exit 1
  fi
}

case "${1:-}" in
  prepare)
    require_checkout prepare
    mkdir -p "$REPO_ROOT/tmp"
    ( cd "$HOST_DIR" && bundle install --quiet && bin/rails db:prepare )
    # The token is printed ONCE by the task (only a SHA256 digest is stored), so capture it here.
    token="$(cd "$HOST_DIR" && EMAIL="$EMAIL" bin/rails sync:device:issue \
             | awk '/^device_token:/ { print $2 }')"
    if [ -z "$token" ]; then
      echo "sync:device:issue printed no device_token -- refusing to write a blank credential" >&2
      exit 1
    fi
    {
      echo "CHUNK_REMOTE_URL=http://127.0.0.1:$PORT"
      echo "CHUNK_REMOTE_TOKEN=$token"
    } > "$ENV_FILE"
    cat "$ENV_FILE"
    ;;
  start)
    require_checkout start
    cd "$HOST_DIR"
    exec env STORAGE_BACKEND=local bin/rails server -p "$PORT" -b 127.0.0.1
    ;;
  *)
    usage
    exit 64
    ;;
esac
```

- [ ] **Step 4: Make it executable and run the test**

```bash
chmod +x bin/sync-server && bin/rails test test/bin_sync_server_test.rb
```

Expected: `3 runs, 6 assertions, 0 failures, 0 errors`.

- [ ] **Step 5: Prove it against a real checkout**

```bash
gh repo clone chaim354/tinkerex-sync ../tinkerex-sync
bin/sync-server prepare
```

Expected: two `KEY=value` lines, and `CHUNK_REMOTE_TOKEN` is a 64-character hex string. If
`sync:device:issue` changes its output format this step is where you find out, not in CI.

- [ ] **Step 6: Commit**

```bash
git add bin/sync-server test/bin_sync_server_test.rb
git commit -m "Boot a standalone sync host from a sibling checkout"
```

---

## Task 2: the journey harness

**Files:**
- Create: `test/support/chunk_remote_journey.rb`
- Modify: `test/test_helper.rb` (add one `require`)

- [ ] **Step 1: Write the harness**

Create `test/support/chunk_remote_journey.rb`:

```ruby
# frozen_string_literal: true

require "net/http"

# THE RIG FOR DRIVING THE MAKER APP AGAINST A REAL SYNC SERVER.
#
# THE SKIP IS ON THE SERVER, NEVER ON THE CLAIM. §14j records a guard that skipped on
# `defined?(Sync)` -- the very thing it asserted -- so the mutation that broke it made every test
# skip and the suite report success. Here the skip is on whether a server was CONFIGURED, which is
# a precondition, and `test_the_journey_suite_does_not_skip_when_configured` below is the
# mutation-check that the precondition is not quietly always false.
module ChunkRemoteJourney
  PASSWORD = "correct horse battery staple"

  def self.configured? = ENV["CHUNK_REMOTE_URL"].present? && ENV["CHUNK_REMOTE_TOKEN"].present?

  def skip_unless_remote_server
    return if ChunkRemoteJourney.configured? && ENV["LIBRARY_BACKEND"] == "chunk_remote"

    skip "needs LIBRARY_BACKEND=chunk_remote plus CHUNK_REMOTE_URL/CHUNK_REMOTE_TOKEN " \
         "(bin/sync-server prepare && bin/sync-server start)"
  end

  # Real password auth against the maker app -- the web UI is session-authed, never the v1 token
  # (§14d), so a journey that skipped this would exercise a door no user goes through.
  def sign_in(email = "journey@example.com")
    user = User.find_by(email:) ||
           User.create!(email:, password: PASSWORD, confirmed_at: Time.current)
    post user_session_path, params: { user: { email:, password: PASSWORD } }
    assert_response :redirect
    user
  end

  # THE UPLOAD, AND THE ONE PLACE THIS DIFFERS STRUCTURALLY FROM Web::FilesFlowTest.
  #
  # That suite does `put url, params: bytes` -- an INTEGRATION-SESSION request, which works only
  # because embedded chunk presigns a RELATIVE path back into the same app. chunk_remote's
  # put_urls are ABSOLUTE and point at the sync server, which the integration session cannot
  # reach. Net::HTTP is not a stylistic choice here; it is the only thing that can perform this
  # request, and using the session instead would silently upload nothing and still assert 200.
  def upload_through_ui(name, bytes, parent_node_id: nil)
    hash = Digest::SHA256.hexdigest(bytes)
    manifest = [ { hash:, offset: 0, length: bytes.bytesize } ]

    post begin_upload_files_path,
         params: { name:, size: bytes.bytesize, manifest:, parent_node_id: }, as: :json
    assert_response :success, "begin_upload failed: #{response.body}"
    begun = JSON.parse(response.body)

    (begun["put_urls"] || {}).each_value { |url| put_bytes_to_storage(url, bytes) }

    post finalize_upload_files_path, params: { commit_id: begun["commit_id"] }, as: :json
    assert_response :success, "finalize_upload failed: #{response.body}"
    begun["node_id"]
  end

  def put_bytes_to_storage(url, bytes)
    uri = URI.parse(url)
    req = Net::HTTP::Put.new(uri)
    req["Content-Type"] = "application/octet-stream"
    req.body = bytes
    res = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https") { |h| h.request(req) }
    assert res.is_a?(Net::HTTPSuccess),
           "PUT #{uri} returned #{res.code}: #{res.body.to_s[0, 200]}"
  end

  # A UNIQUE PREFIX PER RUN, because one sync library is shared by every test in this suite (see
  # the plan's scope note) and the server does not roll back with the maker DB. Per-test isolation
  # needs Arc C's provisioning endpoint; until then, disjoint names are what keeps two runs of the
  # same test from colliding at 409.
  def journey_prefix = @journey_prefix ||= "j#{SecureRandom.hex(4)}"
end
```

- [ ] **Step 2: Require it from the test helper**

In `test/test_helper.rb`, beside the other `require_relative "support/..."` lines, add:

```ruby
require_relative "support/chunk_remote_journey"
```

If no such block exists, add the line immediately after the final existing `require` at the top
of the file.

- [ ] **Step 3: Verify the suite still loads and is unaffected**

```bash
bin/rails test test/bin_sync_server_test.rb
```

Expected: `3 runs, 6 assertions, 0 failures, 0 errors` — the harness loads without changing
anything.

- [ ] **Step 4: Commit**

```bash
git add test/support/chunk_remote_journey.rb test/test_helper.rb
git commit -m "Add the chunk_remote journey harness"
```

---

## Task 3: the journey — reads and byte round-trip

**Files:**
- Create: `test/integration/chunk_remote_journey_test.rb`

- [ ] **Step 1: Write the test**

Create `test/integration/chunk_remote_journey_test.rb`:

```ruby
# frozen_string_literal: true

require "test_helper"

# DRIVES THE MAKER APP AGAINST A REAL STANDALONE SYNC SERVER. Every node here is created through a
# real door -- never `user.nodes.create!` -- because a hand-built row exists only in the local
# mirror and the server has never heard of it, so a write verb against one would 404 for a reason
# that says nothing about chunk_remote.
#
# THIS SUITE IS EXPECTED TO BE RED WHEN IT LANDS. It is Arc A's instrument, not Arc A's product:
# the failures it reports are the measured work-list for Arc B. It is deliberately NOT a bin/ci
# gate -- test/ci_hygiene_test.rb asserts set equality between `bin/ci --list-ci` and ci.yml's gate
# jobs, so a red gate is a red main. .github/workflows/sync-contract.yml carries the signal.
class ChunkRemoteJourneyTest < ActionDispatch::IntegrationTest
  include ChunkRemoteJourney

  setup { skip_unless_remote_server }

  # THE MUTATION-CHECK ON THE SKIP ITSELF. §14j: a guard that skips on the thing it asserts is
  # vacuous, and it reported SUCCESS while asserting nothing. Break `skip_unless_remote_server` to
  # always skip and this test is the one that notices.
  test "the journey suite does not skip when a server is configured" do
    assert ChunkRemoteJourney.configured?,
           "setup should have skipped this test if no server were configured"
    assert_equal "chunk_remote", ENV["LIBRARY_BACKEND"]
    assert_kind_of FileLayer::ChunkRemote, FileLayer.current
  end

  test "an upload round-trips byte-for-byte through the sync server" do
    sign_in
    bytes = "solid journey\nendsolid\n".b
    node_id = upload_through_ui("#{journey_prefix}-bracket.stl", bytes)

    get blob_file_path(node_id)
    assert_response :success
    assert_equal bytes, response.body,
                 "the bytes that came back are not the bytes that went in"
  end

  test "an uploaded file appears on the files page" do
    user = sign_in
    name = "#{journey_prefix}-listed.stl"
    upload_through_ui(name, "listed".b)

    get files_path
    assert_response :success
    assert_includes response.body, name

    assert user.nodes.present.exists?(name:),
           "the local mirror should hold the node after finalize_upload refreshed it"
  end
end
```

- [ ] **Step 2: Run it with no server and verify it SKIPS rather than fails**

```bash
bin/rails test test/integration/chunk_remote_journey_test.rb
```

Expected: `3 runs, 0 assertions, 0 failures, 0 errors, 3 skips`. This is what keeps `bin/ci`
green while the journey is red.

- [ ] **Step 3: Run it against a real server**

In one terminal:

```bash
bin/sync-server prepare && bin/sync-server start
```

In another:

```bash
set -a; . tmp/sync-server.env; set +a
LIBRARY_BACKEND=chunk_remote bin/rails db:test:prepare test test/integration/chunk_remote_journey_test.rb
```

Expected: `3 runs`, 0 skips. Record whether they pass or fail **verbatim** — do not fix anything
yet. Arc A's product is the measurement; Arc B is where fixes go.

- [ ] **Step 4: Commit**

```bash
git add test/integration/chunk_remote_journey_test.rb
git commit -m "Journey: reads and the byte round-trip against a real sync server"
```

---

## Task 4: the journey — the four metadata mutations

**Files:**
- Modify: `test/integration/chunk_remote_journey_test.rb`

- [ ] **Step 1: Add the tests**

Append inside the class in `test/integration/chunk_remote_journey_test.rb`:

```ruby
  test "a folder can be created, and a file moved into it" do
    user = sign_in
    folder = "#{journey_prefix}-folder"
    node_id = upload_through_ui("#{journey_prefix}-moved.stl", "moved".b)

    post library_folders_path, params: { name: folder }, as: :json
    assert_response :success, "create_folder failed: #{response.body}"
    folder_node = user.nodes.present.find_by!(name: folder, kind: "dir")

    # THROUGH Maker::MoveNode, NOT a controller: verified against `bin/rails routes` -- FilesController
    # exposes GET/DELETE on /files/:id and no update action at all, so there is no PATCH door to
    # drive. MoveNode is the named service §14d says every web move goes through, which makes it the
    # real door here rather than a shortcut past one.
    Maker::MoveNode.call(user, node: user.nodes.present.find_by!(node_id:),
                         new_parent_node_id: folder_node.node_id)

    assert_equal folder_node.node_id, user.nodes.present.find_by!(node_id:).parent_node_id,
                 "the move did not reach the mirror -- refresh! after move is what puts it there"
  end

  test "a file can be deleted, listed in trash, and restored" do
    user = sign_in
    name = "#{journey_prefix}-doomed.stl"
    node_id = upload_through_ui(name, "doomed".b)

    delete file_path(node_id)
    assert_response :redirect
    assert_not user.nodes.present.exists?(node_id:), "delete did not tombstone the mirror row"

    get trash_index_path
    assert_response :success
    assert_includes response.body, name

    post restore_trash_path(node_id)
    assert_response :redirect
    assert user.nodes.present.exists?(node_id:), "restore did not revive the mirror row"
  end

  test "a directory delete cascades, because dir_deletable is true on chunk_remote" do
    user = sign_in
    folder = "#{journey_prefix}-cascade"

    post library_folders_path, params: { name: folder }, as: :json
    assert_response :success
    folder_node = user.nodes.present.find_by!(name: folder, kind: "dir")

    child = upload_through_ui("#{journey_prefix}-child.stl", "child".b,
                              parent_node_id: folder_node.node_id)

    delete file_path(folder_node.node_id)
    assert_response :redirect

    assert_not user.nodes.present.exists?(node_id: child),
               "SubtreeDelete must cascade to descendants -- an orphaned child is §14a's " \
               "recorded trap, and dir_deletable is true precisely because the server cascades"
  end
```

- [ ] **Step 2: Verify they skip with no server**

```bash
bin/rails test test/integration/chunk_remote_journey_test.rb
```

Expected: `6 runs, 0 assertions, 0 failures, 0 errors, 6 skips`.

- [ ] **Step 3: Run against the server and record the result verbatim**

```bash
set -a; . tmp/sync-server.env; set +a
LIBRARY_BACKEND=chunk_remote bin/rails db:test:prepare test test/integration/chunk_remote_journey_test.rb 2>&1 | tee tmp/journey-mutations.txt
```

Do not fix failures. Every route helper above was verified against `bin/rails routes` while this
plan was written (`library_folders`, `restore_trash`, `trash_index`, `file`, `blob_file`,
`begin_upload_files`, `finalize_upload_files`, `user_session`) — if one is missing, that is a real
change in the app and belongs in the work-list, not in a quick substitution here.

- [ ] **Step 4: Commit**

```bash
git add test/integration/chunk_remote_journey_test.rb
git commit -m "Journey: mkdir, move, delete, trash, restore, and the directory cascade"
```

---

## Task 5: the journey — the three known gaps

**Files:**
- Modify: `test/integration/chunk_remote_journey_test.rb`

These three tests assert what SHOULD happen. All three are expected to FAIL. Write them anyway
and do not weaken them — a test rewritten to match a defect is how a defect becomes a
specification.

- [ ] **Step 1: Add the freshness test**

Append inside the class:

```ruby
  # GAP (a). `refresh!` is called only from mkdir/move/delete/undelete/finalize_upload
  # (chunk_remote.rb:179,188,198,207,242) and ChangelogSync has no other caller in app/, lib/ or
  # config/. So a node another device pushed is invisible here until THIS app happens to write
  # something. Arc B's fix is a recurring per-user pull.
  test "a node created directly on the sync server becomes visible without a local write" do
    user = sign_in
    name = "#{journey_prefix}-from-elsewhere"
    transport = FileLayer::ChunkRemote::Transport.new(
      base_url: ENV.fetch("CHUNK_REMOTE_URL"), token: ENV.fetch("CHUNK_REMOTE_TOKEN")
    )
    node_id = SecureRandom.uuid
    transport.post("/v1/nodes", { node_id:, parent_node_id: nil, name:, mode: 0o755,
                                  mtime: (Time.current.to_f * 1e9).to_i })

    get files_path
    assert_response :success

    assert user.nodes.present.exists?(node_id:),
           "a node pushed by another device never reaches the mirror: there is no periodic pull " \
           "and no ActionCable subscription, so the maker UI cannot see it at all"
  end
```

- [ ] **Step 2: Add the addon-save test**

Append inside the class:

```ruby
  # GAP (b). port_writable is false on chunk_remote, so Maker::Addons::LibraryOutput#write takes
  # #write_chunk, which calls Sync::Storage::ChunkStore.current.put (library_output.rb:143) -- a
  # constant that does not exist in this process. Arc B's fix is a `put_chunk` port verb.
  test "an addon save writes its output into the library" do
    user = sign_in
    state = Maker::AddonState.create!(user:, addon_key: "journey", name: "j", data: {})

    files = [ { name: "#{journey_prefix}-out.svg", bytes: "<svg/>".b,
                content_type: "image/svg+xml", role: "output" } ]

    assert_nothing_raised do
      Maker::Addons::LibraryOutput.write(user:, state:, parent_node_id: nil, files:)
    end
    assert user.nodes.present.exists?(name: "#{journey_prefix}-out.svg"),
           "the addon's output never reached the library"
  end
```

`maker_addon_states` carries exactly `id, addon_key, created_at, data, name, revision,
updated_at, user_id` (checked while writing this plan), so those four attributes are sufficient. Do
not stub `LibraryOutput` — the call under test is the whole point.

- [ ] **Step 3: Add the batching test**

Append inside the class:

```ruby
  # GAP (c). LibraryBroadcast.batch degrades to a bare `yield` without the engine
  # (library_broadcast.rb:21), so N moves are N changelog pulls -- two WAN round-trips per file
  # inside a browser-facing request. Arc B's fix gives `batch` a real job on chunk_remote:
  # suppress the intermediate refresh! and pull once at the end.
  test "a batch of moves costs one changelog pull, not one per move" do
    user = sign_in
    folder = "#{journey_prefix}-batch"
    post library_folders_path, params: { name: folder }, as: :json
    assert_response :success
    dest = user.nodes.present.find_by!(name: folder, kind: "dir")

    ids = 3.times.map { |i| upload_through_ui("#{journey_prefix}-b#{i}.stl", "b#{i}".b) }

    pulls = 0
    original = FileLayer::ChunkRemote::ChangelogSync.method(:new)
    FileLayer::ChunkRemote::ChangelogSync.stub(:new, ->(*a, **k) { pulls += 1; original.call(*a, **k) }) do
      LibraryBroadcast.batch(user) do
        ids.each { |id| FileLayer.current.move(user, node_id: id, new_parent_node_id: dest.node_id) }
      end
    end

    assert_equal 1, pulls,
                 "a batch of 3 moves pulled the changelog #{pulls} times; batch must defer the " \
                 "refresh so an eager project-intake sweep is not 2 WAN round-trips per file"
  end
```

- [ ] **Step 4: Verify all nine skip with no server**

```bash
bin/rails test test/integration/chunk_remote_journey_test.rb
```

Expected: `9 runs, 0 assertions, 0 failures, 0 errors, 9 skips`.

- [ ] **Step 5: Confirm `bin/ci` is still green**

```bash
bin/ci
```

Expected: every gate passes, three legs identical. If this is red, stop — the journey suite must
never be able to red `bin/ci`, and something has leaked out of the skip.

- [ ] **Step 6: Commit**

```bash
git add test/integration/chunk_remote_journey_test.rb
git commit -m "Journey: the three known gaps, asserted as they should behave"
```

---

## Task 6: the `sync-contract.yml` workflow

**Files:**
- Create: `.github/workflows/sync-contract.yml`

- [ ] **Step 1: Write the workflow**

Create `.github/workflows/sync-contract.yml`:

```yaml
name: Sync contract

# THE PER-PR PROOF THAT THE MAKER APP STILL WORKS AGAINST A REAL STANDALONE SYNC SERVER.
# Stage 5 Arc A; design doc docs/superpowers/specs/2026-08-23-stage-5-engine-leaves-the-process-design.md.
#
# NOT A bin/ci GATE, AND THAT IS A CONSTRAINT RATHER THAN A PREFERENCE. test/ci_hygiene_test.rb
# asserts SET EQUALITY between `bin/ci --list-ci` and ci.yml's gate jobs, and a second test allows
# only `setup` in LOCAL_ONLY_GATES -- so a gate that is red is a main that is red, and this suite is
# EXPECTED to be red until Arc B closes the gaps it exists to measure. client-contract.yml is the
# precedent: a cross-repo wire-contract workflow that boots a real server and never invokes bin/ci.
# `test-chunk-remote` becomes a real gate at the end of Arc B, when it can be green.
#
# macos, NOT linux: only charless-MacBook-Pro-maker-mac is registered (CLAUDE.md §15), so a linux
# job here would queue for 24h at 0 elapsed and be auto-cancelled -- the five-week dark-CI failure
# ci/preflight.sh exists to prevent. macos jobs are exempt from the preflight gate because the
# preflight job itself runs on macos, and NO ruby/setup-ruby appears below: it assumes a hosted
# /Users/runner layout this box does not have, and ci_hygiene_test.rb fails if it reappears.
on:
  pull_request: {}
  push:
    branches: [ main ]
  workflow_dispatch: {}

concurrency:
  group: ${{ github.workflow }}-${{ github.ref }}
  cancel-in-progress: true

jobs:
  chunk-remote-journey:
    runs-on: [self-hosted, macos]
    steps:
      - uses: actions/checkout@v7

      # SECOND CHECKOUT: the sync engine is a separate private repo, and secrets.GITHUB_TOKEN is
      # scoped to THIS repo only. Operator action: create the TINKEREX_SYNC_TOKEN repo secret (a
      # fine-grained token scoped to chaim354/tinkerex-sync, contents:read) -- the same shape
      # client-contract.yml already needs for TINKEREX_CLIENT_TOKEN.
      - name: Check out tinkerex-sync
        uses: actions/checkout@v7
        with:
          repository: chaim354/tinkerex-sync
          token: ${{ secrets.TINKEREX_SYNC_TOKEN }}
          path: tinkerex-sync

      - name: Install gems (the runner's own Ruby — see ci/runners/README.md)
        run: bundle install --quiet

      # Boot + test in ONE step so the server stays alive for the whole suite -- the same reason
      # client-contract.yml's own comment gives. Readiness is an AUTHENTICATED whoami rather than a
      # port check: this host has no /up route, and a token that does not work would otherwise
      # surface as nine confusing 401s instead of one clear failure here.
      - name: Boot the sync server and run the chunk_remote journey
        env:
          TINKEREX_SYNC_DIR: ${{ github.workspace }}/tinkerex-sync
          SYNC_PORT: "3002"
        run: |
          bin/sync-server prepare
          set -a; . tmp/sync-server.env; set +a
          bin/sync-server start &
          SRV=$!
          for i in $(seq 1 60); do
            curl -sf -H "Authorization: Bearer $CHUNK_REMOTE_TOKEN" \
              "$CHUNK_REMOTE_URL/v1/devices/whoami" >/dev/null && { echo "sync server up"; break; }
            sleep 1
          done
          curl -sf -H "Authorization: Bearer $CHUNK_REMOTE_TOKEN" \
            "$CHUNK_REMOTE_URL/v1/devices/whoami" >/dev/null || {
              echo "sync server never became ready"; kill $SRV 2>/dev/null; exit 1; }
          set +e
          LIBRARY_BACKEND=chunk_remote bin/rails db:test:prepare \
            test test/integration/chunk_remote_journey_test.rb
          code=$?
          set -e
          kill $SRV 2>/dev/null || true
          exit $code
```

- [ ] **Step 2: Verify the hygiene guards accept it**

```bash
bin/rails test test/ci_hygiene_test.rb
```

Expected: all tests pass. Specifically `no workflow targets a GitHub-hosted runner`,
`no job running on macos uses ruby/setup-ruby`, and
`ci.yml's gate jobs are exactly the gates bin/ci says CI must run` must all stay green — the last
one only because this workflow adds no `bin/ci` gate.

- [ ] **Step 3: Mutation-check the hygiene guards against this file**

Temporarily change `runs-on: [self-hosted, macos]` to `runs-on: macos-latest` and re-run:

```bash
bin/rails test test/ci_hygiene_test.rb
```

Expected: RED, on `no workflow targets a GitHub-hosted runner`. **Restore the line and confirm
green again.** A guard that has never failed has not been shown to work (§15).

- [ ] **Step 4: Commit**

```bash
git add .github/workflows/sync-contract.yml
git commit -m "Run the chunk_remote journey against a real sync server on every PR"
```

---

## Task 7: the measured Arc B work-list

**Files:**
- Create: `docs/superpowers/plans/2026-08-23-arc-b-worklist.md`

This is the deliverable Arc A exists for. It is **generated from a run**, never written from
memory — that is the difference between this document and the three gaps the spec already lists.

- [ ] **Step 1: Capture a full run**

```bash
bin/sync-server prepare
set -a; . tmp/sync-server.env; set +a
bin/sync-server start &
SRV=$!
sleep 5
LIBRARY_BACKEND=chunk_remote bin/rails db:test:prepare \
  test test/integration/chunk_remote_journey_test.rb 2>&1 | tee tmp/journey-run.txt
kill $SRV
```

- [ ] **Step 2: Write the work-list from `tmp/journey-run.txt`**

Create `docs/superpowers/plans/2026-08-23-arc-b-worklist.md` with this structure, filling every
row from the captured output. Paste the real failure message for each — a paraphrase is a second
description that can drift from the first.

```markdown
# Arc B work-list — measured, not predicted

**Source:** `test/integration/chunk_remote_journey_test.rb` run under
`LIBRARY_BACKEND=chunk_remote` against a real `tinkerex-sync` host on <DATE>, commit <SHA>.
Raw output: <paste the summary line, e.g. "9 runs, N assertions, F failures, E errors, 0 skips">.

| # | Test | Verdict | Failure, verbatim | Predicted by the spec? |
|---|---|---|---|---|
| 1 | the journey suite does not skip when a server is configured | | | n/a — the skip guard's own check |
| 2 | an upload round-trips byte-for-byte | | | no |
| 3 | an uploaded file appears on the files page | | | no |
| 4 | a folder can be created, and a file moved into it | | | no |
| 5 | a file can be deleted, listed in trash, and restored | | | no |
| 6 | a directory delete cascades | | | no |
| 7 | a node created on the server becomes visible | | | YES — gap (a) |
| 8 | an addon save writes its output | | | YES — gap (b) |
| 9 | a batch of moves costs one changelog pull | | | YES — gap (c) |

## What the spec did not predict

<One section per failure whose "Predicted" column is "no". State the symptom, the file and line,
and what would fix it. If there are none, say so explicitly — that is a real result and it means
the spec's reading pass was, unusually, complete.>

## What this does NOT cover

The full maker suite. It cannot run against one shared remote library (see the Arc A plan's scope
note), so this work-list is bounded by what nine journeys touch. The full-suite leg is an Arc C
follow-on, once per-test library provisioning exists.
```

- [ ] **Step 3: Commit**

```bash
git add docs/superpowers/plans/2026-08-23-arc-b-worklist.md
git commit -m "Record the measured Arc B work-list"
```

---

## Task 8: STATUS.md, same branch, same PR

**Files:**
- Modify: `docs/STATUS.md`

- [ ] **Step 1: Write the entry**

Add an entry at the top of the "Latest" section of `docs/STATUS.md`, dated 2026-08-23, branch
`claude/stage-5-arc-a`, covering:

- What Arc A shipped: `bin/sync-server`, the journey harness, nine journey tests,
  `sync-contract.yml`, and the measured work-list.
- **The numbers**: `bin/ci` gate count and its run/assertion totals; the journey suite's
  runs/failures against a real server; how many failures the spec had predicted and how many it
  had not.
- **The two spec corrections this plan made and why**: `test-chunk-remote` cannot be a `bin/ci`
  gate while it is red (`ci_hygiene_test.rb` set equality), and the full-suite leg depends on Arc
  C's per-test library provisioning rather than being available in Arc A.
- That `sync-contract.yml` is **expected red** and what closes it.

Per §15 this is part of the work, not a tidy-up afterwards: amend this arc's entry on later PRs
rather than appending a new one per PR.

- [ ] **Step 2: Verify no doc claim names an unverified commit**

```bash
bin/verify-fix-log
```

Expected: no unresolved references.

- [ ] **Step 3: Final gate run**

```bash
bin/ci
```

Expected: all gates pass, the three test legs report identical counts. `sync-contract.yml` is
red in GitHub Actions and that is the intended state.

- [ ] **Step 4: Commit and open the PR**

```bash
git add docs/STATUS.md
git commit -m "STATUS: Arc A — the chunk_remote proof, and what it measured"
git push -u origin claude/stage-5-arc-a
gh pr create --fill
```

State plainly in the PR body that `sync-contract.yml` is expected to be red, that this is the
signal Arc A exists to produce, and that Arc B closes it.
