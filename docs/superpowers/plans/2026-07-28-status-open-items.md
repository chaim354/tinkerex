# STATUS.md Open Items Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Close the four open items recorded at the head of `docs/STATUS.md` (2026-07-28) — enforce
text-only rich text on the server, bound the sheet `data` blob, add the repo's first JS-executing
test for the grid, and merge the two file-type vocabularies into one.

**Architecture:** Four independent changes in the Rails app layer. Nothing touches sync, the
changelog, conflicts, locks, or the mounts, and `client/` keeps a zero-line diff. Item 1 adds a model
concern plus one route; item 2 adds a model validation plus a controller rescue; item 3 adds a system
test; item 4 adds one enum value, derives a helper constant from it, and ships a data migration.

**Tech Stack:** Rails 8.1, Action Text (+ Lexxy 0.9.27), Active Storage, Minitest, Capybara +
selenium/headless Chrome, Stimulus, SQLite (test) / Postgres (managed).

**Spec:** `docs/superpowers/specs/2026-07-28-status-open-items-design.md`

---

## Facts established by probe before this plan was written

These were run, not reasoned. Do not re-derive them; do not assume the opposite when something looks
surprising.

1. **The attachment element is `action-text-attachment`**, `ActionText::Content#to_html` round-trips
   it intact, and `#attachments` reports 1 for it.
2. **`ActionText::Content#fragment.source` is a Nokogiri fragment** supporting `.css(...)` and
   `.to_html`. Removing the nodes and reassigning the HTML yields `attachments == 0`.
3. **An attachment-only body strips to `""`** and then fails `validates :body, presence: true` with
   `"Body can't be blank"`. This is the deliberate consequence recorded in the spec §3.2.
4. **A route drawn in `config/routes.rb` DOES take precedence** over the Active Storage engine's
   `POST /rails/active_storage/direct_uploads`. Verified by driving a real request: the app route
   answered `404`, no blob created. Mechanism (i) in spec §3.3 is confirmed; the (ii)/(iii)
   fallbacks are NOT needed.
   **`Rails.application.routes.recognize_path` says the opposite and is wrong here** — a `proc`
   route carries no controller/action, so `recognize_path` skips it and reports the engine's route.
   Drive a request; do not use `recognize_path` to check this.
5. **The hole is real.** Without the fix, that same unauthenticated POST returns **200**, creates an
   `ActiveStorage::Blob`, and returns a signed `direct_upload` URL. This is the mutation check that
   makes Task 2's test non-vacuous.
6. **`EXT_RE = /\A[a-z0-9]{1,8}\z/`** accepts `markdown` (exactly 8 characters), so Task 6 does not
   drift from `FilesController`'s guard.
7. **Sign-in in tests** is `post user_session_path, params: { user: { email:, password: } }` with the
   user created `confirmed_at: Time.current`.
8. **`bin/rails runner` cannot exercise Action Text** — the dev DB has no `action_text_rich_texts`
   table. Probe inside a test.

---

## File Structure

**Item 1 — text-only enforcement**
- Create `app/models/concerns/maker/text_only_rich_text.rb` — the strip, included by both rich-text models
- Modify `app/models/maker/note.rb` — include it
- Modify `app/models/maker/build_log_entry.rb` — include it
- Modify `config/routes.rb` — intercept the direct-uploads path
- Create `test/models/maker/text_only_rich_text_test.rb`
- Create `test/integration/web/direct_uploads_gate_test.rb`

**Item 2 — sheet size bound**
- Modify `app/models/maker/sheet.rb` — `MAX_DATA_BYTES` + validation
- Modify `app/controllers/projects/sheets_controller.rb` — rescue → 422 JSON
- Modify `app/javascript/controllers/sheet_controller.js` — surface the server's message
- Modify `test/models/maker/sheet_test.rb` — limit tests
- Create `test/controllers/projects/sheets_controller_test.rb`

**Item 3 — first JS test**
- Create `test/system/sheet_grid_test.rb`

**Item 4 — one vocabulary**
- Modify `app/models/maker/file_attachment.rb` — `document` role + extensions
- Modify `app/helpers/files_helper.rb` — `EXT_FAMILIES` derived
- Create `db/migrate/<timestamp>_rederive_document_roles.rb`
- Modify `test/models/maker/file_attachment_test.rb` — two existing assertions must change
- Create `test/models/maker/rederive_document_roles_migration_test.rb`
- Modify `test/integration/web/files_type_filter_test.rb` if the chip count assertion needs it

**Docs**
- Modify `docs/STATUS.md` — rewrite the open-items section
- Modify `CLAUDE.md` — only if the architecture moved

---

## Task 1: The text-only rich text concern

**Files:**
- Create: `app/models/concerns/maker/text_only_rich_text.rb`
- Modify: `app/models/maker/note.rb`
- Modify: `app/models/maker/build_log_entry.rb`
- Test: `test/models/maker/text_only_rich_text_test.rb`

- [ ] **Step 1: Write the failing test**

Create `test/models/maker/text_only_rich_text_test.rb`:

```ruby
require "test_helper"

module Maker
  # The SERVER half of the text-only policy that `attachments="false"` states in the editor only.
  # Both models are exercised by the same cases: the guarantee has to hold per-model, and a concern
  # included in one place and forgotten in another is exactly the failure this file catches.
  class TextOnlyRichTextTest < ActiveSupport::TestCase
    ATTACHMENT = %q{<action-text-attachment sgid="abc" content-type="image/png" filename="x.png"></action-text-attachment>}.freeze

    setup do
      @user = User.create!(email: "tort-#{SecureRandom.hex(4)}@example.com")
      @project = @user.maker_projects.create!(name: "Lamp")
    end

    def build_note(body)  = Maker::Note.new(user: @user, node_id: "n-1", body: body)
    def build_entry(body) = Maker::BuildLogEntry.new(user: @user, project: @project, body: body, entry_type: "note")

    # The headline: markup that Action Text's own sanitizer PRESERVES does not survive a save.
    test "an attachment inside text is stripped on a note" do
      note = build_note("<div>hi #{ATTACHMENT} there</div>")
      note.save!
      note.reload
      assert_equal 0, note.body.body.attachments.size
      assert_not_includes note.body.body.to_html, "action-text-attachment"
    end

    test "an attachment inside text is stripped on a build log entry" do
      entry = build_entry("<div>hi #{ATTACHMENT} there</div>")
      entry.save!
      entry.reload
      assert_equal 0, entry.body.body.attachments.size
      assert_not_includes entry.body.body.to_html, "action-text-attachment"
    end

    # Deliberate consequence, pinned so it is never read later as a regression: both models
    # `validates :body, presence: true`, so a body that was ONLY an attachment strips to nothing
    # and is rejected. The user submitted only a thing this app does not accept.
    test "a body that is only an attachment fails presence validation on a note" do
      note = build_note(ATTACHMENT)
      assert_not note.valid?
      assert_includes note.errors.full_messages.join, "Body"
    end

    test "a body that is only an attachment fails presence validation on a build log entry" do
      entry = build_entry(ATTACHMENT)
      assert_not entry.valid?
      assert_includes entry.errors.full_messages.join, "Body"
    end

    # Guards against an over-broad strip. Without this, removing the whole body would pass every
    # test above while destroying every note in the library.
    test "ordinary formatting survives untouched on a note" do
      html = "<div><strong>bold</strong> <em>italic</em> <a href=\"https://example.com\">link</a><ul><li>one</li></ul></div>"
      note = build_note(html)
      note.save!
      note.reload
      stored = note.body.body.to_html
      assert_includes stored, "<strong>bold</strong>"
      assert_includes stored, "<em>italic</em>"
      assert_includes stored, "https://example.com"
      assert_includes stored, "<li>one</li>"
    end

    test "ordinary formatting survives untouched on a build log entry" do
      html = "<div><strong>bold</strong> <a href=\"https://example.com\">link</a></div>"
      entry = build_entry(html)
      entry.save!
      entry.reload
      stored = entry.body.body.to_html
      assert_includes stored, "<strong>bold</strong>"
      assert_includes stored, "https://example.com"
    end

    # A body with no attachment must not be rewritten at all — the strip returns early.
    test "a body with no attachment is left byte-identical" do
      note = build_note("<div>plain</div>")
      note.save!
      assert_equal "<div>plain</div>", note.body.body.to_html
    end
  end
end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bin/rails test test/models/maker/text_only_rich_text_test.rb`

Expected: FAIL. The two "is stripped" tests fail on `assert_equal 0, ...attachments.size` (actual 1),
and the two "only an attachment" tests fail because the body is currently valid.

- [ ] **Step 3: Write the concern**

Create `app/models/concerns/maker/text_only_rich_text.rb`. (`app/models/concerns/` does not exist
yet — create the directory. It is already in Rails' default autoload paths; no config change.)

```ruby
module Maker
  # Enforces ON THE SERVER the text-only policy that `attachments="false"` states in the editor only.
  #
  # Lexxy is configured attachment-free so that Active Storage is never used for user content
  # (CLAUDE.md §15 — bytes stay out of Rails). That attribute governs the browser and NOTHING else:
  # Action Text's sanitizer PRESERVES <action-text-attachment>, so a body posted directly — curl,
  # devtools, a modified fetch — creates a real, rendering attachment with the editor never
  # involved. Demonstrated, not theorised; see docs/STATUS.md and the overhaul design's §9a.
  #
  # The element is removed rather than its attributes scrubbed, so the guarantee is "no attachment
  # survives a save" regardless of which attributes Action Text or Lexxy emit in a future version.
  #
  # CONSEQUENCE, DELIBERATE: both including models `validates :body, presence: true`, so a body that
  # was ONLY an attachment strips to empty and is REJECTED. That is correct — the submission
  # contained nothing this app accepts — and it is pinned by a test so it is not later read as a
  # regression.
  module TextOnlyRichText
    extend ActiveSupport::Concern

    ATTACHMENT_SELECTOR = "action-text-attachment".freeze

    included do
      before_validation :strip_rich_text_attachments
    end

    private

    # Returns early when there is nothing to strip, so an untouched body is never re-serialised
    # (a rewrite would churn the stored HTML on every save for no reason).
    def strip_rich_text_attachments
      content = body&.body
      return if content.nil?

      fragment = content.fragment.source
      nodes = fragment.css(ATTACHMENT_SELECTOR)
      return if nodes.empty?

      nodes.each(&:remove)
      self.body = fragment.to_html
    end
  end
end
```

- [ ] **Step 4: Include it in both models**

In `app/models/maker/note.rb`, add the include directly under `has_rich_text :body`:

```ruby
    has_rich_text :body
    include Maker::TextOnlyRichText
```

In `app/models/maker/build_log_entry.rb`, add the include directly under `has_rich_text :body`:

```ruby
    has_rich_text :body
    include Maker::TextOnlyRichText
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `bin/rails test test/models/maker/text_only_rich_text_test.rb`

Expected: PASS, 7 runs, 0 failures, 0 errors.

- [ ] **Step 6: Mutation-check the strip**

Temporarily comment out the `include Maker::TextOnlyRichText` line in `app/models/maker/note.rb`,
re-run the test, and confirm the note tests go RED while the build-log-entry tests stay GREEN. Then
restore the line. This proves the tests are per-model and not passing by accident.

Run: `bin/rails test test/models/maker/text_only_rich_text_test.rb`
Expected while commented out: 3 failures, all in the `note` tests.

- [ ] **Step 7: Run the surrounding suites**

Run: `bin/rails test test/models/maker/note_test.rb test/models/maker/build_log_entry_test.rb test/integration/web`

Expected: PASS. If a note/entry fixture used an attachment body it would surface here.

- [ ] **Step 8: Commit**

```bash
git add app/models/concerns/maker/text_only_rich_text.rb app/models/maker/note.rb app/models/maker/build_log_entry.rb test/models/maker/text_only_rich_text_test.rb
git commit -m "fix(security): strip attachment markup server-side, not only in the editor"
```

---

## Task 2: Gate the Active Storage direct-uploads route

**Files:**
- Modify: `config/routes.rb`
- Test: `test/integration/web/direct_uploads_gate_test.rb`

- [ ] **Step 1: Write the failing test**

Create `test/integration/web/direct_uploads_gate_test.rb`:

```ruby
require "test_helper"

# `POST /rails/active_storage/direct_uploads` was live and UNAUTHENTICATED: an anonymous request
# minted a real ActiveStorage::Blob and got a signed upload URL back — an anonymous write surface
# into storage through Rails, the exact shape CLAUDE.md §15 exists to prevent.
# ActiveStorage::DirectUploadsController descends from ActiveStorage::BaseController, not this app's
# ApplicationController, so no amount of app-level auth reaches it.
#
# The route is REMOVED, not authenticated. `direct_upload` appears nowhere in app/, config/ or lib/,
# and both editors run attachments-off, so nothing in this app calls it.
class DirectUploadsGateTest < ActionDispatch::IntegrationTest
  PASSWORD = "correct horse battery staple".freeze
  PATH = "/rails/active_storage/direct_uploads".freeze

  def blob_params
    { blob: { filename: "a.txt", byte_size: 3, checksum: "eB5eJF1ptWaXm4bijSPyxw==",
              content_type: "text/plain" } }
  end

  test "an anonymous direct upload is refused and mints no blob" do
    before = ActiveStorage::Blob.count
    post PATH, params: blob_params, as: :json
    assert_not response.successful?, "expected the direct-upload route to be gone, got #{response.status}"
    assert_equal before, ActiveStorage::Blob.count
  end

  # This is what pins REMOVED rather than AUTH-GATED. Without it, a future change to
  # "authenticate instead of remove" would leave this file green while reopening the write surface
  # to every signed-in user — which is not what was decided.
  test "a signed-in direct upload is refused too" do
    user = User.create!(email: "du-#{SecureRandom.hex(4)}@example.com",
                        password: PASSWORD, confirmed_at: Time.current)
    post user_session_path, params: { user: { email: user.email, password: PASSWORD } }

    before = ActiveStorage::Blob.count
    post PATH, params: blob_params, as: :json
    assert_not response.successful?, "expected the direct-upload route to be gone, got #{response.status}"
    assert_equal before, ActiveStorage::Blob.count
  end

  # The gate must be SURGICAL. Maker::Preview uses has_one_attached :asset and is served with
  # url_for(p.asset), so Active Storage's blob routes are load-bearing — this is why
  # `config.active_storage.draw_routes = false` was rejected in the design. If a future edit reaches
  # for the blunt instrument, this test is what fails.
  test "the rest of the Active Storage routes are intact" do
    assert Rails.application.routes.url_helpers.respond_to?(:rails_blob_path),
           "rails_blob_path is gone — the gate took more than the one route with it"
    assert Rails.application.routes.routes.any? { |r| r.path.spec.to_s.include?("active_storage/blobs") },
           "the blob routes are gone — previews will not resolve"
  end
end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bin/rails test test/integration/web/direct_uploads_gate_test.rb`

Expected: FAIL — the first two tests fail with `expected the direct-upload route to be gone, got 200`
and an off-by-one blob count. The third passes already (nothing has been removed yet).

- [ ] **Step 3: Draw the interception route**

In `config/routes.rb`, add immediately after the `get "up" => …` health-check line (line 2), so it is
drawn before the Active Storage engine appends its own:

```ruby
  # Active Storage's direct-upload endpoint, REMOVED. ActiveStorage::DirectUploadsController
  # descends from ActiveStorage::BaseController — not this app's ApplicationController — so it
  # shipped live and UNAUTHENTICATED: an anonymous POST minted a real Blob and returned a signed
  # upload URL. That is an anonymous write surface into storage through Rails (CLAUDE.md §15).
  #
  # REMOVED rather than authenticated: `direct_upload` appears nowhere in app/, config/ or lib/, and
  # both Lexxy editors run attachments-off, so nothing in this app calls it. Re-enabling it should
  # be a deliberate act.
  #
  # DRAWN HERE, NOT VIA draw_routes = false: Maker::Preview uses has_one_attached :asset served with
  # url_for, so the blob routes must survive. An app-drawn route DOES win over the engine's — this
  # was verified by driving a real request, because `recognize_path` reports the engine's route for
  # a proc endpoint (it carries no controller/action) and is the wrong instrument for the check.
  post "/rails/active_storage/direct_uploads", to: proc {
    [ 404, { "Content-Type" => "text/plain" }, [ "Not Found" ] ]
  }
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `bin/rails test test/integration/web/direct_uploads_gate_test.rb`

Expected: PASS, 3 runs, 0 failures, 0 errors.

- [ ] **Step 5: Verify previews and the pages that use them still work**

Run: `bin/rails test test/integration/web test/controllers`

Expected: PASS. Any preview asset URL that stopped resolving surfaces here.

- [ ] **Step 6: Commit**

```bash
git add config/routes.rb test/integration/web/direct_uploads_gate_test.rb
git commit -m "fix(security): remove the unauthenticated Active Storage direct-upload route"
```

---

## Task 3: Bound the sheet data blob (model)

**Files:**
- Modify: `app/models/maker/sheet.rb`
- Test: `test/models/maker/sheet_test.rb`

- [ ] **Step 1: Write the failing test**

Append inside `module Maker / class SheetTest` in `test/models/maker/sheet_test.rb`:

```ruby
    # `data` is user-controlled JSON written by the browser, permitted whole by the controller, and
    # embedded into the page HTML on EVERY view with no truncation — so the blob size IS the page
    # size. A buggy client or a genuinely huge sheet grew it without bound.
    test "a sheet at the size limit is valid" do
      sheet = @project.sheets.build(user: @user, name: "Big")
      # One long cell sized so the serialised blob lands just under the cap.
      filler = "x" * (Maker::Sheet::MAX_DATA_BYTES - 200)
      sheet.data = { "columns" => [ { "title" => "A", "width" => 120 } ], "cells" => [ [ filler ] ] }
      assert_operator sheet.data.to_json.bytesize, :<=, Maker::Sheet::MAX_DATA_BYTES
      assert sheet.valid?, sheet.errors.full_messages.join(", ")
    end

    test "a sheet over the size limit is rejected" do
      sheet = @project.sheets.build(user: @user, name: "Too big")
      filler = "x" * (Maker::Sheet::MAX_DATA_BYTES + 1000)
      sheet.data = { "columns" => [ { "title" => "A", "width" => 120 } ], "cells" => [ [ filler ] ] }
      assert_not sheet.valid?
      assert_match(/too large/i, sheet.errors.full_messages.join(", "))
    end

    test "a blank sheet is comfortably inside the limit" do
      sheet = @project.sheets.build(user: @user, name: "Blank", data: Maker::Sheet.blank_data)
      assert sheet.valid?
      assert_operator sheet.data.to_json.bytesize, :<, Maker::Sheet::MAX_DATA_BYTES / 100
    end

    # A malformed blob must still reach the DEFENSIVE READERS rather than being rejected here —
    # the readers exist so a half-written blob renders an empty grid instead of 500ing the page,
    # and a size validation that also rejected shape would defeat them.
    test "a malformed blob is not rejected by the size validation" do
      sheet = @project.sheets.build(user: @user, name: "Weird", data: { "cells" => "nonsense" })
      assert sheet.valid?, sheet.errors.full_messages.join(", ")
    end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bin/rails test test/models/maker/sheet_test.rb`

Expected: FAIL with `NameError: uninitialized constant Maker::Sheet::MAX_DATA_BYTES`.

- [ ] **Step 3: Add the constant and the validation**

In `app/models/maker/sheet.rb`, add below `DEFAULT_COLUMNS`:

```ruby
    # The blob is embedded into the page HTML on EVERY view with no truncation (see
    # projects/sheets/show.html.erb), so this bounds the PAGE, not just the row.
    #
    # The arithmetic, so the number is not mistaken for a guess: `blank_data` (20x6) is ~600 bytes;
    # a large but genuinely plausible sheet — 1000 rows x 20 columns, cells averaging 8 characters —
    # is ~220 KB. 1 MB is ~4.5x that.
    #
    # BYTESIZE, NOT ROW/COLUMN CAPS: one number, and it is the quantity that actually hurts. Row and
    # column caps reject legitimately-shaped sheets while still permitting an enormous one.
    MAX_DATA_BYTES = 1_048_576
```

And add the validation next to the existing ones:

```ruby
    validate  :data_within_size_limit
```

And the private method, below `project_belongs_to_user`:

```ruby
    # Deliberately says NOTHING about shape. `data` is permitted whole by the controller and
    # defended at render time by the `cells`/`columns` readers; a validation that also rejected a
    # malformed blob would turn a recoverable empty grid into a save the user cannot complete.
    def data_within_size_limit
      return if data.nil?
      size = data.to_json.bytesize
      return if size <= MAX_DATA_BYTES
      errors.add(:data, "is too large (#{ActiveSupport::NumberHelper.number_to_human_size(size)}; " \
                        "limit #{ActiveSupport::NumberHelper.number_to_human_size(MAX_DATA_BYTES)})")
    end
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `bin/rails test test/models/maker/sheet_test.rb`

Expected: PASS, all tests, 0 failures, 0 errors.

- [ ] **Step 5: Commit**

```bash
git add app/models/maker/sheet.rb test/models/maker/sheet_test.rb
git commit -m "fix(sheets): bound the data blob at 1 MB"
```

---

## Task 4: Make the over-limit autosave visible (controller + JS)

**Files:**
- Modify: `app/controllers/projects/sheets_controller.rb`
- Modify: `app/javascript/controllers/sheet_controller.js`
- Test: `test/controllers/projects/sheets_controller_test.rb`

**Why this task exists:** Task 3 alone turns an over-limit autosave into `RecordInvalid` → **500**,
which the debounced JSON autosave surfaces as nothing. That trades silent unbounded growth for a
silent failed save — no better, and arguably worse, since the user keeps typing into a grid that has
stopped persisting.

- [ ] **Step 1: Write the failing test**

Create `test/controllers/projects/sheets_controller_test.rb`:

```ruby
require "test_helper"

module Projects
  class SheetsControllerTest < ActionDispatch::IntegrationTest
    PASSWORD = "correct horse battery staple".freeze

    setup do
      @user = User.create!(email: "sc-#{SecureRandom.hex(4)}@example.com",
                           password: PASSWORD, confirmed_at: Time.current)
      post user_session_path, params: { user: { email: @user.email, password: PASSWORD } }
      @project = @user.maker_projects.create!(name: "Lamp")
      @sheet = @project.sheets.create!(user: @user, name: "Cut list", position: 0,
                                       data: Maker::Sheet.blank_data)
    end

    test "an ordinary autosave persists and answers 200" do
      payload = { "columns" => [ { "title" => "A", "width" => 120 } ], "cells" => [ [ "7" ] ] }
      patch sheet_path(@sheet), params: { sheet: { data: payload } }, as: :json
      assert_response :success
      assert_equal [ [ "7" ] ], @sheet.reload.data["cells"]
    end

    # The point of the task: an over-limit autosave must be REJECTED VISIBLY, not 500, and must not
    # partially write.
    test "an over-limit autosave answers 422 and leaves the stored blob untouched" do
      original = @sheet.data
      filler = "x" * (Maker::Sheet::MAX_DATA_BYTES + 1000)
      payload = { "columns" => [ { "title" => "A", "width" => 120 } ], "cells" => [ [ filler ] ] }

      patch sheet_path(@sheet), params: { sheet: { data: payload } }, as: :json

      assert_response :unprocessable_entity
      assert_equal original, @sheet.reload.data
    end

    # The indicator shows whatever the server says, so the server has to say something useful.
    test "the over-limit response carries a human error message" do
      filler = "x" * (Maker::Sheet::MAX_DATA_BYTES + 1000)
      patch sheet_path(@sheet), params: { sheet: { data: { "cells" => [ [ filler ] ] } } }, as: :json

      body = JSON.parse(response.body)
      assert body["error"].present?, "expected an error message in #{response.body.first(200)}"
      assert_match(/too large/i, body["error"])
    end

    # The rename form shares the action; a rescue that swallowed HTML would break it silently.
    test "the HTML rename path still redirects" do
      patch sheet_path(@sheet), params: { sheet: { name: "Renamed" } }
      assert_redirected_to sheet_path(@sheet)
      assert_equal "Renamed", @sheet.reload.name
    end
  end
end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bin/rails test test/controllers/projects/sheets_controller_test.rb`

Expected: FAIL — the over-limit tests error with `ActiveRecord::RecordInvalid` rather than answering
422.

- [ ] **Step 3: Rescue in the controller**

In `app/controllers/projects/sheets_controller.rb`, replace `#update` with:

```ruby
    # Two callers, one action: the grid's debounced JSON autosave (sends `data`) and the rename
    # form (sends `name`). Answering by format keeps them from needing separate routes.
    #
    # THE RESCUE IS NOT DECORATION. `update!` on an over-limit blob raises RecordInvalid, which for
    # the autosave means a 500 the debounced fetch shows as NOTHING — trading unbounded growth for a
    # save that fails silently while the user keeps typing. The JSON branch answers 422 with the
    # message so the status indicator's error state can say it.
    def update
      @sheet.update!(sheet_params)
      respond_to do |format|
        format.json { render json: { status: "ok", updated_at: @sheet.updated_at } }
        format.html { redirect_to sheet_path(@sheet) }
      end
    rescue ActiveRecord::RecordInvalid => e
      respond_to do |format|
        format.json { render json: { status: "error", error: e.record.errors.full_messages.to_sentence },
                             status: :unprocessable_entity }
        format.html { redirect_to sheet_path(@sheet), alert: e.record.errors.full_messages.to_sentence }
      end
    end
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `bin/rails test test/controllers/projects/sheets_controller_test.rb`

Expected: PASS, 4 runs, 0 failures, 0 errors.

- [ ] **Step 5: Surface the server's message in the grid**

In `app/javascript/controllers/sheet_controller.js`, replace the `try`/`catch` inside `save()` with:

```javascript
    try {
      const response = await fetch(this.urlValue, {
        method: "PATCH",
        headers: {
          "Content-Type": "application/json",
          Accept: "application/json",
          "X-CSRF-Token": token || ""
        },
        body: JSON.stringify({ sheet: { data: payload } })
      })
      if (!response.ok) {
        // A 422 carries a REASON the user can act on ("data is too large…"), and a connection
        // message would be an actively wrong diagnosis of it — the sheet is not going to save on
        // the next attempt either. Anything without a parseable body falls back below.
        const reason = await response.json().then((b) => b.error).catch(() => null)
        throw new Error(reason || `HTTP ${response.status}`)
      }
      this.setStatus("Saved")
    } catch (error) {
      // An autosave that fails silently is indistinguishable from one that worked, which is the
      // whole risk of choosing autosave over a Save button.
      const detail = error?.message && !error.message.startsWith("HTTP ")
        ? error.message
        : "check your connection"
      this.setStatus(`Not saved — ${detail}`, true)
    }
```

- [ ] **Step 6: Run the full sheet-related suites**

Run: `bin/rails test test/models/maker/sheet_test.rb test/controllers/projects/sheets_controller_test.rb test/integration/web`

Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add app/controllers/projects/sheets_controller.rb app/javascript/controllers/sheet_controller.js test/controllers/projects/sheets_controller_test.rb
git commit -m "fix(sheets): an over-limit autosave answers 422 and says why"
```

---

## Task 5: Add the `document` role

**Files:**
- Modify: `app/models/maker/file_attachment.rb`
- Test: `test/models/maker/file_attachment_test.rb:50-70`

- [ ] **Step 1: Update the two existing assertions that pin the old vocabulary**

These two currently pass and MUST change — they are the evidence the change is real.

In `test/models/maker/file_attachment_test.rb`, change line 55 from:

```ruby
      assert_equal "other", Maker::FileAttachment.role_for("readme.txt")
```

to:

```ruby
      assert_equal "document", Maker::FileAttachment.role_for("readme.txt")
```

And replace the "exactly these eight values" test with:

```ruby
    # Pinned independently of ROLE_LABELS on purpose. Asserting ROLES == ROLE_LABELS.keys is
    # tautological — ROLES is DEFINED as those keys — so it cannot catch a typo'd key like
    # "cad_soruce", which is exactly the failure a reader assumes it guards. This literal can.
    test "the role vocabulary is exactly these nine values" do
      assert_equal %w[cad_source document gcode image instructions model other source_archive vector],
                   Maker::FileAttachment::ROLES.sort
    end
```

- [ ] **Step 2: Add the new-role tests**

Append inside the same class:

```ruby
    # The extension set is DERIVED from what this app already believes, not invented here:
    # Maker::Previews::Registry already routes txt/md/markdown/json to TextThumb, and
    # FilesHelper::EXT_FAMILIES already grouped txt/md/csv as "Documents". This is the union.
    test "the document role covers the text formats the app already recognises" do
      %w[notes.txt readme.md readme.markdown data.json cutlist.csv].each do |name|
        assert_equal "document", Maker::FileAttachment.role_for(name), "expected #{name} to be a document"
      end
    end

    test "document is accepted by the validation" do
      att = @item.file_attachments.build(user: @user, node_id: "n", role: "document")
      assert att.valid?
    end

    # pdf STAYS `instructions`: Models::AttachmentsController dispatches ExtractPdfMetadataJob on
    # exactly that value, so folding pdf into `document` would silently stop PDF metadata
    # extraction. This test is the tripwire for that.
    test "pdf stays instructions, not document" do
      assert_equal "instructions", Maker::FileAttachment.role_for("manual.pdf")
    end
```

- [ ] **Step 3: Run the test to verify it fails**

Run: `bin/rails test test/models/maker/file_attachment_test.rb`

Expected: FAIL — `readme.txt` still returns `other`, `ROLES.sort` is still eight values, and
`document` is rejected by the inclusion validation.

- [ ] **Step 4: Add the role**

In `app/models/maker/file_attachment.rb`, add to `ROLE_LABELS` between `instructions` and `vector`
(placement sets the panel heading order):

```ruby
      "document"       => "Documents",
```

And add to `ROLE_BY_EXT`, after the `pdf`/`gcode`/`zip` line:

```ruby
      # Text formats. DERIVED, not chosen here: Maker::Previews::Registry already routes
      # txt/md/markdown/json to TextThumb, and FilesHelper::EXT_FAMILIES already grouped txt/md/csv
      # as "Documents" — this is the union of the two sets the app already had.
      #
      # `pdf` is NOT here on purpose: it stays `instructions` because
      # Models::AttachmentsController dispatches ExtractPdfMetadataJob on that exact value.
      "txt" => "document", "md" => "document", "markdown" => "document",
      "json" => "document", "csv" => "document",
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `bin/rails test test/models/maker/file_attachment_test.rb`

Expected: PASS, 0 failures, 0 errors.

- [ ] **Step 6: Commit**

```bash
git add app/models/maker/file_attachment.rb test/models/maker/file_attachment_test.rb
git commit -m "feat(files): add the document role for text formats"
```

---

## Task 6: Derive EXT_FAMILIES from the role vocabulary

**Files:**
- Modify: `app/helpers/files_helper.rb:69-75`
- Test: `test/helpers/files_helper_test.rb` (create)
- Test: `test/integration/web/files_type_filter_test.rb` (verify, likely unchanged)

- [ ] **Step 1: Write the failing test**

Create `test/helpers/files_helper_test.rb`:

```ruby
require "test_helper"

class FilesHelperTest < ActiveSupport::TestCase
  # THE TEST THAT MAKES "ONE VOCABULARY" A PROPERTY RATHER THAN A COINCIDENCE. Before this, the
  # chips and the project panel headings were two hand-written lists that named overlapping files
  # differently (.svg was "2D / laser" on one page and "Vector" on the other) and left the five
  # cad_source extensions with no chip at all. A hand-written family re-added later fails here.
  test "every chip extension comes from the role vocabulary" do
    assert_equal Maker::FileAttachment::ROLE_BY_EXT.keys.sort,
                 FilesHelper::EXT_FAMILIES.values.flatten.sort
  end

  test "every chip family is a role label" do
    assert_empty FilesHelper::EXT_FAMILIES.keys - Maker::FileAttachment::ROLE_LABELS.values
  end

  # `other` is a FALLBACK for unrecognised extensions, not an extension set — it has nothing to
  # render chips from, and a family with no extensions would render an empty labelled row.
  test "the other role contributes no family" do
    assert_not_includes FilesHelper::EXT_FAMILIES.keys, "Other"
    assert FilesHelper::EXT_FAMILIES.values.none?(&:empty?)
  end

  test "the families follow ROLE_LABELS order" do
    expected = Maker::FileAttachment::ROLE_LABELS.values & FilesHelper::EXT_FAMILIES.keys
    assert_equal expected, FilesHelper::EXT_FAMILIES.keys
  end

  # The complaint this item started from.
  test "cad_source extensions now have a chip" do
    assert_includes FilesHelper::EXT_FAMILIES["CAD source"], "scad"
    assert_includes FilesHelper::EXT_FAMILIES["CAD source"], "sldprt"
  end

  # Every chip extension must be one FilesController will actually accept, or the chip is a control
  # that renders, links and silently does nothing. `markdown` is exactly 8 characters — the bound.
  test "every chip extension satisfies the controller's EXT_RE" do
    FilesHelper::EXT_FAMILIES.values.flatten.each do |ext|
      assert_match FilesController::EXT_RE, ext, "#{ext} would be dropped by the controller"
    end
  end
end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bin/rails test test/helpers/files_helper_test.rb`

Expected: FAIL — the hand-written `EXT_FAMILIES` contains extensions absent from `ROLE_BY_EXT`
(none, after Task 5) but is MISSING `gif`, `bmp`, `gco`, and the five cad_source extensions, and its
keys ("3D models", "2D / laser", "Machine") are not role labels.

- [ ] **Step 3: Derive the constant**

In `app/helpers/files_helper.rb`, replace the `EXT_FAMILIES` literal (lines 69–75) with:

```ruby
  # DERIVED, not hand-written, and that is the point. These chips and the project Files panel's
  # headings were two independent lists that disagreed: `.svg`/`.dxf`/`.lbrn2` read "2D / laser"
  # here and "Vector" there, and the five cad_source extensions had no chip at all. One source of
  # truth now — Maker::FileAttachment's ROLE_BY_EXT for the grouping, ROLE_LABELS for the label and
  # the order — so they cannot drift again. Pinned by test/helpers/files_helper_test.rb.
  #
  # `other` drops out on its own: it is the fallback for UNRECOGNISED extensions, so no extension
  # maps to it and filter_map skips the empty family rather than rendering an empty labelled row.
  EXT_FAMILIES = Maker::FileAttachment::ROLE_LABELS.filter_map { |role, label|
    exts = Maker::FileAttachment::ROLE_BY_EXT.select { |_ext, r| r == role }.keys.freeze
    [ label, exts ] if exts.any?
  }.to_h.freeze
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `bin/rails test test/helpers/files_helper_test.rb`

Expected: PASS, 6 runs, 0 failures, 0 errors.

- [ ] **Step 5: Verify eager loading still resolves**

`FilesHelper` now references `Maker::FileAttachment` at class-body evaluation time. Confirm Zeitwerk
is happy in both directions:

Run: `bin/rails zeitwerk:check`
Expected: `All is good!`

Run: `RAILS_ENV=production SECRET_KEY_BASE=x bin/rails runner 'Rails.application.eager_load!; puts FilesHelper::EXT_FAMILIES.keys.inspect'`
Expected: the eight family labels, no `NameError`.

- [ ] **Step 6: Run the Files-page integration suite**

Run: `bin/rails test test/integration/web/files_type_filter_test.rb`

Expected: PASS. The chip-count assertion at line 266 is computed from `EXT_FAMILIES` itself, so it
self-adjusts from 18 to 28 extensions. If it fails, the cause is `ext_slots_left?` rendering some
chips inert — read the failure before changing the test.

- [ ] **Step 7: Prove both surfaces now use the same word**

The whole complaint was that one file read differently on two pages. Append inside
`module Web / class ProjectAttachmentsTest` in `test/integration/web/project_attachments_test.rb`,
using that file's own `sign_in` and `attach_node` helpers:

```ruby
    # THE COMPLAINT THIS ITEM STARTED FROM, asserted on both surfaces at once: a .csv is filed under
    # "Documents" in the project panel AND the Files page offers a chip in a family of that same
    # name. Before this the two pages named overlapping files differently, and .csv had no role at
    # all. This fails if either surface drifts, which is what "one vocabulary" has to mean.
    test "a document is filed under Documents and the chips agree" do
      user = sign_in
      project = user.maker_projects.create!(name: "Lamp")
      attach_node(user, project, name: "cutlist.csv", node_id: "n-doc",
                  role: Maker::FileAttachment.role_for("cutlist.csv"))

      get project_path(project)
      assert_response :success
      assert_select ".attachment-group-head", text: /Documents/

      assert_includes FilesHelper::EXT_FAMILIES.keys, "Documents"
      assert_includes FilesHelper::EXT_FAMILIES["Documents"], "csv"
    end
```

Run: `bin/rails test test/integration/web/project_attachments_test.rb`
Expected: PASS.

- [ ] **Step 8: Commit**

```bash
git add app/helpers/files_helper.rb test/helpers/files_helper_test.rb test/integration/web/project_attachments_test.rb
git commit -m "refactor(files): derive the chip families from the role vocabulary"
```

---

## Task 7: The document-role data migration

**Files:**
- Create: `db/migrate/<timestamp>_rederive_document_roles.rb`
- Test: `test/models/maker/rederive_document_roles_migration_test.rb`

- [ ] **Step 1: Read the predecessor first**

Read `db/migrate/20260728124303_rederive_vector_and_cad_source_roles.rb` and
`test/models/maker/rederive_roles_migration_test.rb` in full. This task is the same shape and must
match its house style: no app models, its own `MigrationAttachment`/`MigrationNode` classes, and its
own **copied** extension list.

- [ ] **Step 2: Generate the migration file**

Run: `bin/rails generate migration RederiveDocumentRoles`

- [ ] **Step 3: Write the failing test**

Create `test/models/maker/rederive_document_roles_migration_test.rb`:

Match `test/models/maker/rederive_roles_migration_test.rb`'s structure exactly — the `Dir[...].first`
require and the `suppress_messages` wrapper are its established pattern, not incidental style.

```ruby
require "test_helper"
require Dir[Rails.root.join("db/migrate/*_rederive_document_roles.rb")].first

# Drives the migration's `up` against real rows rather than trusting it by reading.
class RederiveDocumentRolesMigrationTest < ActiveSupport::TestCase
  setup do
    @user = User.create!(email: "rederive-doc@example.com")
    @project = @user.maker_projects.create!(name: "Lamp")
  end

  # node_id has no FK — the filename lives on the node, so the migration has to join to find it.
  def attach(name, role)
    @user.nodes.create!(node_id: "n-#{name}", name:, kind: "file")
    @project.file_attachments.create!(user: @user, node_id: "n-#{name}", role:)
  end

  def run_migration
    ActiveRecord::Migration.suppress_messages { RederiveDocumentRoles.new.up }
  end

  def run_rollback
    ActiveRecord::Migration.suppress_messages { RederiveDocumentRoles.new.down }
  end

  test "an other row pointing at a text file becomes a document" do
    att = attach("readme.txt", "other")
    run_migration
    assert_equal "document", att.reload.role
  end

  test "every document extension is re-derived" do
    atts = %w[a.txt b.md c.markdown d.json e.csv].map { |n| attach(n, "other") }
    run_migration
    atts.each { |a| assert_equal "document", a.reload.role, "#{a.node_id} was not re-derived" }
  end

  # The guard that keeps the migration from being a blunt instrument.
  test "an other row with no document extension is left alone" do
    att = attach("mystery.xyz", "other")
    run_migration
    assert_equal "other", att.reload.role
  end

  test "a row already in another role is untouched" do
    att = attach("bracket.stl", "model")
    run_migration
    assert_equal "model", att.reload.role
  end

  # An attachment whose node is gone has nothing to derive from and must not blow up the run.
  test "an attachment pointing at a missing node is skipped without raising" do
    att = @project.file_attachments.create!(user: @user, node_id: "n-missing", role: "other")
    assert_nothing_raised { run_migration }
    assert_equal "other", att.reload.role
  end

  test "down returns document rows to other" do
    att = attach("readme.txt", "other")
    run_migration
    run_rollback
    assert_equal "other", att.reload.role
  end
end
```

- [ ] **Step 4: Run the test to verify it fails**

Run: `bin/rails test test/models/maker/rederive_document_roles_migration_test.rb`

Expected: FAIL — the generated migration is empty, so `up` does nothing and the first test's
assertion of `"document"` fails.

- [ ] **Step 5: Write the migration**

Replace the generated `db/migrate/<timestamp>_rederive_document_roles.rb` with:

```ruby
# Moves attachments that were "other" only because ROLE_BY_EXT had no entry for their extension
# into the `document` role added alongside this migration.
#
# SELF-CONTAINED ON PURPOSE, exactly as its predecessor
# (20260728124303_rederive_vector_and_cad_source_roles.rb) is. It does not call
# Maker::FileAttachment.role_for and does not use the app's models: a data migration runs against
# whatever the schema and the code look like months from now, and app code keeps moving.
class RederiveDocumentRoles < ActiveRecord::Migration[8.1]
  # Must stay in step with the extensions ROLE_BY_EXT gained for `document`. This list is
  # deliberately a COPY rather than a reference, and the cost is the same one the predecessor
  # records — and this migration EXISTS because of it: an extension added to the model after a
  # migration runs never re-derives rows already sitting in `other`, so closing that gap needs
  # ANOTHER migration. That is the accepted price of the self-contained style, not a defect of it.
  NEW_ROLE_BY_EXT = {
    "txt" => "document", "md" => "document", "markdown" => "document",
    "json" => "document", "csv" => "document"
  }.freeze

  class MigrationAttachment < ActiveRecord::Base
    self.table_name = "maker_file_attachments"
  end

  class MigrationNode < ActiveRecord::Base
    self.table_name = "nodes"
  end

  def up
    moved = 0
    MigrationAttachment.where(role: "other").find_each do |att|
      node = MigrationNode.find_by(user_id: att.user_id, node_id: att.node_id)
      next if node.nil? # attachment to a deleted/missing node — nothing to derive from
      ext = File.extname(node.name.to_s).downcase.delete(".")
      new_role = NEW_ROLE_BY_EXT[ext]
      next if new_role.nil?
      att.update_columns(role: new_role)
      moved += 1
    end
    say "re-derived #{moved} attachment role#{"s" unless moved == 1}"
  end

  # Returns EVERY document row to "other", not only the rows `up` moved — it has no record of which
  # those were, and `role_for` is already live in four controllers, so organic `document` rows can
  # exist before `up` ever runs. Acceptable for the predecessor's reason: the pair is self-healing,
  # since the mapping is a pure function of the current filename.
  def down
    MigrationAttachment.where(role: NEW_ROLE_BY_EXT.values.uniq).update_all(role: "other")
  end
end
```

- [ ] **Step 6: Run the test to verify it passes**

Run: `bin/rails test test/models/maker/rederive_document_roles_migration_test.rb`

Expected: PASS, 6 runs, 0 failures, 0 errors.

- [ ] **Step 7: Run the migration against the dev schema**

Run: `bin/rails db:migrate`
Expected: `re-derived N attachment roles` and a clean `db/schema.rb` diff (this migration changes no
schema — if `schema.rb` moves, only its `define(version:)` line should).

- [ ] **Step 8: Commit**

```bash
git add db/migrate db/schema.rb test/models/maker/rederive_document_roles_migration_test.rb
git commit -m "feat(files): re-derive document roles from rows marked other"
```

---

## Task 8: The first JS-executing test — the sheet grid

**Files:**
- Create: `test/system/sheet_grid_test.rb`

**Why:** 1587 green tests across three backends caught neither grid bug, because both were
client-side only and structurally invisible to a server-side suite. `test/system` is excluded from
`bin/rails test` — which is exactly why — but a `system-test` CI job already runs
`bin/rails db:test:prepare test:system` on a self-hosted linux runner
(`.github/workflows/ci.yml:238`). No CI change is needed.

- [ ] **Step 1: Read the existing system test first**

Read `test/system/tray_layout_test.rb` in full. It is the repo's only system test and carries the
login pattern — including the `assert_current_path` wait, whose comment records that without it the
next `visit` races the Turbo redirect and 401s into the login page, "which reads exactly like the
editor failing to render."

- [ ] **Step 2: Write the test**

Create `test/system/sheet_grid_test.rb`:

```ruby
require "application_system_test_case"

# THE SECOND SYSTEM TEST IN THIS REPO, and the first to cover the grid.
#
# It exists because 1587 green tests across three backends caught NEITHER shipped grid bug — both
# were client-side only and therefore structurally invisible to a server-side suite:
#
#   1. jspreadsheet-ce v5's factory is an ASYNC WORKBOOK api. Called with a flat {data, columns} it
#      throws INSIDE an uncatchable promise, so the grid renders permanently empty with no error
#      anywhere — it looks like a blank sheet, not a broken one.
#   2. The classic <script> tags needed data-turbo-track="reload": every real path to this page is a
#      Turbo VISIT, which merges <head> rather than reparsing, so untracked tags load async and
#      Stimulus connected before window.jspreadsheet existed.
#
# Both fail this test at the typing step, because both leave nothing to type into.
class SheetGridTest < ApplicationSystemTestCase
  PASSWORD = "correct horse battery staple".freeze

  setup do
    @user = User.create!(email: "grid-#{SecureRandom.hex(4)}@example.com",
                         password: PASSWORD, confirmed_at: Time.current)
    @project = @user.maker_projects.create!(name: "Lamp")
    @sheet = @project.sheets.create!(user: @user, name: "Cut list", position: 0,
                                     data: Maker::Sheet.blank_data)

    visit new_user_session_path
    fill_in "user[email]", with: @user.email
    fill_in "user[password]", with: PASSWORD
    click_on "Log in"
    # Wait for Turbo to actually FOLLOW the login redirect before navigating (see
    # tray_layout_test.rb — without this the next visit races the redirect and 401s into the login
    # page, which reads exactly like the page failing to render).
    assert_current_path "/files"
  end

  test "a formula computes in the grid and persists as its raw text" do
    # REACHED BY A TURBO VISIT, NOT `visit sheet_path`. This is the single most important line in
    # the file and the easiest to lose in a later edit: a direct `visit` is a HARD LOAD, which is
    # the one path where the data-turbo-track bug does NOT reproduce. Clicking through from the
    # project page is what a real user does and what exercises the <head> merge.
    visit project_path(@project)
    click_on @sheet.name
    assert_current_path sheet_path(@sheet)

    # The grid is built asynchronously; wait for a real cell rather than for a fixed time.
    assert_selector "#{grid} td", wait: 10

    fill_cell(0, 0, "6")
    fill_cell(1, 0, "7")
    fill_cell(2, 0, "=A1*B1")

    # THE COMPUTED VALUE. An empty grid never gets here — this is what catches both bugs.
    assert_equal "42", cell_text(2, 0)

    # Autosave is debounced (1000 ms); wait for the indicator rather than sleeping.
    assert_text "Saved", wait: 10

    # THE RAW FORMULA, NOT THE RESULT. getData(false, false) reads the underlying data model, so
    # "=A1*B1" must come back as itself — persisting "42" instead would silently destroy every
    # formula in the sheet on the next load.
    visit current_path
    assert_selector "#{grid} td", wait: 10
    assert_equal "=A1*B1", stored_value(2, 0)
  end

  private

    def grid = "[data-controller='sheet'] [data-sheet-target='grid']"

    # Jspreadsheet renders a <td> per cell carrying data-x/data-y — VERIFIED in the vendored bundle
    # (`setAttribute("data-x",e)`), not assumed from docs.
    def cell(x, y) = find("#{grid} td[data-x='#{x}'][data-y='#{y}']")

    # Types into a cell WITHOUT naming the editor element. Double-click opens the editor and focuses
    # it; `:focus` is then whatever the library actually created. Deliberately class-name-independent
    # — the bundle builds the editor with a bare createElement("input") and its class names are
    # internal, so pinning one would make this test fail on a library upgrade for a reason that has
    # nothing to do with the behaviour under test.
    def fill_cell(x, y, value)
      cell(x, y).double_click
      editor = find(":focus")
      editor.set(value)
      editor.send_keys(:enter)
    end

    def cell_text(x, y) = cell(x, y).text.strip

    # Reads what was STORED, not what is displayed — the model's own data, straight from the DB.
    def stored_value(x, y)
      @sheet.reload.data["cells"][y][x]
    end
end
```

- [ ] **Step 3: Run the test**

Run: `bin/rails test:system TEST=test/system/sheet_grid_test.rb`

Expected: PASS.

**If it fails, do NOT loosen the assertions.** The `td[data-x][data-y]` selector is verified against
the vendored bundle and `fill_cell` deliberately names no editor class, so a failure is more likely
to be real than selector drift. Inspect `tmp/screenshots/` (the CI job already uploads these on
failure) and read the actual DOM before touching the test. The three assertions — computed value,
"Saved", raw formula after reload — must not change; they are the entire point of the file.

- [ ] **Step 4: Mutation-check the test**

Prove the test would have caught the real bugs. Temporarily edit
`app/views/projects/sheets/show.html.erb` to remove `"data-turbo-track": "reload"` from the
`javascript_include_tag`, and re-run.

Run: `bin/rails test:system TEST=test/system/sheet_grid_test.rb`
Expected: FAIL — no cell to type into.

Then restore the attribute and confirm the test goes green again. **A system test that passes with
the bug reintroduced is worthless**, and this repo has the scar to prove it (`fake-fidelity` — a
green suite that confirmed its own misunderstanding).

- [ ] **Step 5: Commit**

```bash
git add test/system/sheet_grid_test.rb
git commit -m "test(sheets): the repo's first grid test, in a real browser"
```

---

## Task 9: Full-suite verification across all three backends

**Files:** none — this is the standing bar for this repo.

- [ ] **Step 1: Default backend (chunk)**

Run: `bin/rails test`
Expected: 0 failures, 0 errors. Record the run/assertion counts.

- [ ] **Step 2: Share backend**

Run: `LIBRARY_BACKEND=share bin/rails test`
Expected: identical counts to Step 1.

- [ ] **Step 3: S3 backend**

Run: `LIBRARY_BACKEND=s3 bin/rails test`
Expected: identical counts to Step 1.

- [ ] **Step 4: System tests**

Run: `bin/rails db:test:prepare test:system`
Expected: 0 failures, 0 errors — `tray_layout_test.rb` and the new `sheet_grid_test.rb`.

- [ ] **Step 5: Confirm `client/` is untouched**

Run: `git diff --stat main -- client/`
Expected: no output.

- [ ] **Step 6: Confirm the standing tripwire greps still hold**

Run: `grep -rn "manifest_chunks\|ChunkStore" app/services/maker/ app/models/maker/ app/jobs/maker/ | grep -v ':[0-9]*: *#'`
Expected: exactly ONE line, `app/services/maker/addons/library_output.rb:47` (see CLAUDE.md §12
step 10 — the invariant is "one hit, and it is library_output.rb", not "no hits").

Run: `grep -rn "rescue.*NotImplementedError" app lib | grep -v ':[0-9]*: *#'`
Expected: no output.

---

## Task 10: Update the documentation

**Files:**
- Modify: `docs/STATUS.md`
- Modify: `CLAUDE.md` (only if warranted)

- [ ] **Step 1: Rewrite the open-items section**

`docs/STATUS.md` currently opens with "## OPEN ITEMS from the project-page overhaul (2026-07-28) —
read this first" and four numbered subsections. All four are now closed.

**A stale open-list is worse than none** — this is a lesson `docs/STATUS.md` already records about
itself (the phase 4 follow-up found two of its five open entries claimed holes the code did not
have). Replace the section with a "Latest" entry recording what was closed and how, and carry
forward only what is genuinely still open.

Record, at minimum:
- Item 1 closed as option (c): both halves. The route is **removed, not authenticated**, and the
  test pins that distinction.
- The probe result worth keeping: an app-drawn route beats the engine's, and `recognize_path` is the
  wrong instrument for checking it.
- Item 2 closed with `MAX_DATA_BYTES = 1_048_576` plus the 422 path — noting that the validation
  alone would have traded silent growth for a silent failed save.
- Item 3 closed: `test/system/sheet_grid_test.rb`, and the note that system tests run in their own
  CI job and are NOT in the `bin/rails test` count.
- Item 4 closed as one vocabulary. **Carry forward the accepted cost**, do not drop it: `document` is
  an API-visible enum value with no behavioural reader, and the migration's copied extension list
  means a *third* migration is needed if the document extension set ever grows.
- New suite counts from Task 9.

- [ ] **Step 2: Decide whether CLAUDE.md moved**

CLAUDE.md §15 says to update it when the architecture moves. Judge honestly:

- **Probably yes:** the §12 step 9 area, since `EXT_FAMILIES`/`ROLE_BY_EXT` are now one vocabulary,
  and the direct-uploads route is now gated — the latter is a §15 (bytes out of Rails) fact.
- **Probably no:** items 2 and 3 are a validation and a test; neither is architecture.

Keep any addition short. This file is already long, and its own §12 step 10 warns about paragraphs
that go stale without anyone updating them.

- [ ] **Step 3: Commit**

```bash
git add docs/STATUS.md CLAUDE.md
git commit -m "docs(status): close the four open items from the project-page overhaul"
```

---

## Definition of done

1. All four STATUS.md open items closed, and the open-items section rewritten to match reality.
2. `bin/rails test` green and identical on chunk, share and s3 (Task 9).
3. `bin/rails test:system` green, with `sheet_grid_test.rb` in it.
4. `client/` has a zero-line diff.
5. Both tripwire greps still return what CLAUDE.md says they should.
6. `docs/STATUS.md` updated; `CLAUDE.md` updated if the architecture moved.
