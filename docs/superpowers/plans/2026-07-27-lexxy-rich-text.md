# Lexxy Rich Text Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the plain textareas on build-log entries and file notes with Basecamp's Lexxy editor, text-only, converting both `body` columns to Action Text without losing existing content.

**Architecture:** Lexxy is an Action Text editor, so each surface converts from a `text` column to an `action_text_rich_texts` row. `has_rich_text :body` shadows a same-named column, so each conversion is one migration that backfills then drops the column. Attachments are off (`attachments="false"`): Lexxy's attachment path runs through Active Storage into a store separate from the file library, and the build log's existing library-backed photo strip stays as the only way an image gets in. The v1 API keeps serving `body` as a plain `String` in both directions.

**Tech Stack:** Rails 8.1, `lexxy` gem (MIT), Action Text, importmap-rails, propshaft, Minitest.

**Spec:** `docs/superpowers/specs/2026-07-27-project-page-overhaul-design.md` §5.

---

## File Structure

| File | Change | Responsibility after this plan |
|---|---|---|
| `Gemfile` | Modify | Adds `lexxy`. |
| `config/importmap.rb` | Modify | Pins `lexxy`; the `trix` pin the installer adds is removed. |
| `app/javascript/application.js` | Modify | Imports `lexxy`; drops the `trix` import. |
| `app/views/layouts/application.html.erb` | Modify | Adds the Lexxy stylesheet. |
| `db/migrate/*_create_action_text_tables.*.rb` | Create (generated) | Action Text schema. |
| `db/migrate/*_move_build_log_body_to_action_text.rb` | Create | Backfill + drop `maker_build_log_entries.body`. |
| `db/migrate/*_move_note_body_to_action_text.rb` | Create | Backfill (through the markdown renderer) + drop `maker_notes.body`. |
| `app/models/maker/build_log_entry.rb` | Modify | `has_rich_text :body`. |
| `app/models/maker/note.rb` | Modify | `has_rich_text :body`. |
| `app/views/projects/_build_log.html.erb` | Modify | Lexxy editor in the entry form. |
| `app/views/projects/_log_entry.html.erb` | Modify | Renders rich body; `<p class="entry-body">` becomes a `<div>`. |
| `app/views/files/show.html.erb` | Modify | Lexxy editor in the note form; note bodies render rich. |
| `app/controllers/projects_controller.rb` | Modify | Exposes `@new_entry` for the form's model. |
| `app/controllers/files_controller.rb` | Modify | Exposes `@new_note` for the form's model. |
| `app/controllers/v1/maker/build_log_entries_controller.rb` | Modify | Serves `to_plain_text`. |
| `app/controllers/v1/maker/projects_controller.rb` | Modify | Serves `to_plain_text`. |

**Not touched:** `app/helpers/notes_helper.rb` and the `kramdown` gem both **stay** —
`app/views/models/show.html.erb:95` renders `Maker::Model#notes` (a different, still-plain column)
through `render_note`, and `test/helpers/notes_helper_test.rb` covers it.

---

## Task 1: Install Lexxy and Action Text

**Files:**
- Modify: `Gemfile`
- Modify: `config/importmap.rb`, `app/javascript/application.js`, `app/views/layouts/application.html.erb`
- Create: `db/migrate/*_create_action_text_tables.*.rb` (generated)

- [ ] **Step 1: Add the gem**

In `Gemfile`, next to the other web-layer gems (near `kramdown`, around line 91):

```ruby
# Lexxy — Basecamp's Action Text editor (MIT; CLAUDE.md §9 permissive-only). Used TEXT-ONLY:
# attachments are disabled because Lexxy's attachment path runs through Active Storage, a store
# separate from the file library, which §15 and the FileLayer port exist to avoid.
gem "lexxy", "~> 0.9.21"
```

```bash
bundle install
```

Expected: `lexxy` resolves and installs. If the resolver reports a conflict with Rails 8.1, stop —
the gem's Rails support is a stated assumption of this plan, not a detail to work around.

- [ ] **Step 2: Run the Action Text installer and inspect exactly what it changed**

```bash
bin/rails action_text:install && git status --short
```

Expected: a `create_action_text_tables` migration, Action Text view partials, and edits to
`config/importmap.rb` and `app/javascript/application.js`.

```bash
git diff config/importmap.rb app/javascript/application.js
```

Read this diff before the next step — the installer's exact output varies by Rails version, and
Step 3 removes specific lines from it.

- [ ] **Step 3: Remove Trix, add Lexxy**

In `config/importmap.rb`, delete the `pin "trix"` line the installer added and add:

```ruby
# Lexxy (MIT) — the Action Text editor, replacing Trix. Served from the gem's own asset path, so
# there is nothing vendored under vendor/javascript and no jspm shared-chunk patching (see the
# jszip/Maker.js notes above). Attachments are disabled at the element, so @rails/activestorage is
# not imported.
pin "lexxy", to: "lexxy.js"
```

In `app/javascript/application.js`, delete the `import "trix"` line and add:

```javascript
import "lexxy"
```

Leave any `@rails/actiontext` pin the installer added — it is unused with attachments off and
costs nothing, and removing a pin the installer owns invites it back on the next install.

- [ ] **Step 4: Add the stylesheet**

In `app/views/layouts/application.html.erb`, after the `models` stylesheet line (around line 26):

```erb
    <%= stylesheet_link_tag "lexxy", "data-turbo-track": "reload" %>
```

- [ ] **Step 5: Migrate and verify the app boots and serves the assets**

```bash
bin/rails db:migrate
```

```bash
bin/rails runner 'puts ActionText::RichText.table_name; puts Rails.application.assets.load_path.find("lexxy.js")&.path'
```

Expected: `action_text_rich_texts`, then a real path to the gem's `lexxy.js`. A `nil` on the second
line means propshaft cannot see the gem's assets — resolve that before continuing, because every
later task depends on it.

- [ ] **Step 6: Run the suite to confirm nothing regressed**

```bash
bin/rails test
```

Expected: 0 failures, 0 errors — no behavior has changed yet.

- [ ] **Step 7: Commit**

```bash
git add Gemfile Gemfile.lock config/importmap.rb app/javascript/application.js \
        app/views/layouts/application.html.erb app/views db/migrate db/schema.rb
git commit -m "feat: install Lexxy and Action Text, drop Trix"
```

---

## Task 2: Move build-log bodies to Action Text

**Files:**
- Create: `db/migrate/<timestamp>_move_build_log_body_to_action_text.rb`
- Create: `test/models/maker/build_log_body_migration_test.rb`
- Modify: `app/models/maker/build_log_entry.rb:14`

- [ ] **Step 1: Generate the migration**

```bash
bin/rails generate migration MoveBuildLogBodyToActionText
```

- [ ] **Step 2: Write the failing test**

Create `test/models/maker/build_log_body_migration_test.rb`:

```ruby
require "test_helper"
require Dir[Rails.root.join("db/migrate/*_move_build_log_body_to_action_text.rb")].first

# Drives the data migration directly. The assertions are about CONTENT, not row counts: the two
# ways this conversion can quietly ruin a build log are collapsing newlines and letting raw text
# through as markup, and neither shows up in a count.
class BuildLogBodyMigrationTest < ActiveSupport::TestCase
  Converter = MoveBuildLogBodyToActionText

  test "a single line becomes one paragraph" do
    assert_equal "<p>Cut the panels</p>", Converter.to_html("Cut the panels")
  end

  test "single newlines become line breaks inside one paragraph" do
    assert_equal "<p>Cut the panels<br>Sanded the edges</p>",
                 Converter.to_html("Cut the panels\nSanded the edges")
  end

  test "a blank line starts a new paragraph" do
    assert_equal "<p>Day one</p><p>Day two</p>", Converter.to_html("Day one\n\nDay two")
  end

  test "text that looks like markup is escaped, not interpreted" do
    html = Converter.to_html("tolerance a < b <script>alert(1)</script>")
    assert_includes html, "&lt;script&gt;"
    assert_not_includes html, "<script>"
    assert_includes html, "a &lt; b"
  end

  test "carriage returns do not leak into the output" do
    assert_equal "<p>one<br>two</p>", Converter.to_html("one\r\ntwo")
  end
end
```

- [ ] **Step 3: Run it to verify it fails**

```bash
bin/rails test test/models/maker/build_log_body_migration_test.rb
```

Expected: FAIL with `NoMethodError: undefined method 'to_html' for MoveBuildLogBodyToActionText`.

- [ ] **Step 4: Write the migration**

Replace the generated file's contents with:

```ruby
# Converts maker_build_log_entries.body (plain text) into Action Text, then drops the column.
#
# The column must GO, not stay alongside: `has_rich_text :body` defines a reader that shadows a
# same-named attribute, so leaving both means the model silently answers with a different object
# than the table holds, and `validates :body, presence:` starts validating that object instead.
#
# Self-contained (raw table classes, no app models) for the usual data-migration reason: this runs
# against whatever the code looks like months from now.
class MoveBuildLogBodyToActionText < ActiveRecord::Migration[8.1]
  class MigrationEntry < ActiveRecord::Base
    self.table_name = "maker_build_log_entries"
  end

  class MigrationRichText < ActiveRecord::Base
    self.table_name = "action_text_rich_texts"
  end

  RECORD_TYPE = "Maker::BuildLogEntry".freeze

  # Plain text -> an Action Text body. Escape FIRST, then add markup: the source is plain text a
  # user typed, so a stray `<` is a less-than sign and `<script>` is something they wrote about,
  # never markup to honour. Blank-line-separated blocks become paragraphs; single newlines become
  # <br>, which is what the old `white-space: pre-wrap` rendering showed.
  def self.to_html(text)
    ERB::Util.html_escape(text.to_s.delete("\r")).to_str
      .split(/\n{2,}/)
      .reject(&:empty?)
      .map { |para| "<p>#{para.gsub("\n", "<br>")}</p>" }
      .join
  end

  def up
    now = Time.current
    MigrationEntry.find_each do |entry|
      next if MigrationRichText.exists?(record_type: RECORD_TYPE, record_id: entry.id, name: "body")
      MigrationRichText.create!(
        name: "body", record_type: RECORD_TYPE, record_id: entry.id,
        body: self.class.to_html(entry.body), created_at: now, updated_at: now
      )
    end
    remove_column :maker_build_log_entries, :body
  end

  def down
    add_column :maker_build_log_entries, :body, :text
    MigrationRichText.where(record_type: RECORD_TYPE, name: "body").find_each do |rt|
      # Best-effort inverse: paragraphs and breaks back to newlines, tags stripped.
      text = rt.body.to_s.gsub(%r{</p>\s*<p>}, "\n\n").gsub(/<br\s*/?>/, "\n")
      text = ActionController::Base.helpers.strip_tags(text).to_s
      MigrationEntry.where(id: rt.record_id).update_all(body: CGI.unescapeHTML(text))
    end
    change_column_null :maker_build_log_entries, :body, false
    MigrationRichText.where(record_type: RECORD_TYPE, name: "body").delete_all
  end
end
```

- [ ] **Step 5: Run the test to verify it passes**

```bash
bin/rails test test/models/maker/build_log_body_migration_test.rb
```

Expected: PASS, 5 tests.

- [ ] **Step 6: Write a round-trip test over real records, and watch it fail**

Append to the same test file:

```ruby
  test "existing entries keep their content and their line breaks through the migration" do
    user = User.create!(email: "backfill@example.com")
    project = user.maker_projects.create!(name: "Lamp")
    entry = MoveBuildLogBodyToActionText::MigrationEntry.create!(
      user_id: user.id, project_id: project.id, entry_type: "note",
      logged_at: Time.current, body: "Cut the panels\nSanded the edges",
      created_at: Time.current, updated_at: Time.current
    )

    rich = MoveBuildLogBodyToActionText::MigrationRichText.create!(
      name: "body", record_type: "Maker::BuildLogEntry", record_id: entry.id,
      body: MoveBuildLogBodyToActionText.to_html(entry.body),
      created_at: Time.current, updated_at: Time.current
    )

    assert_includes rich.body, "Cut the panels<br>Sanded the edges"
  end
```

This asserts the backfill's output shape against a real row without re-running `up` (which drops a
column and cannot run twice inside a transactional test).

```bash
bin/rails test test/models/maker/build_log_body_migration_test.rb
```

Expected: PASS.

- [ ] **Step 7: Switch the model to rich text**

In `app/models/maker/build_log_entry.rb`, add below the `belongs_to` lines:

```ruby
    has_rich_text :body
```

Leave `validates :body, presence: true` exactly as it is — `ActionText::RichText` answers `blank?`
from its content, so the validation keeps meaning what it meant.

- [ ] **Step 8: Migrate and verify the column is gone**

```bash
bin/rails db:migrate && grep -n "maker_build_log_entries" -A 10 db/schema.rb
```

Expected: no `t.text "body"` under `maker_build_log_entries`.

- [ ] **Step 9: Run the build-log tests**

```bash
bin/rails test test/models/maker/build_log_entry_test.rb test/integration/web/project_build_log_test.rb
```

Expected: FAIL — the web test asserts `.entry-body` text and the form still posts to a plain
textarea. Those are fixed in Task 4; note the failures and continue.

- [ ] **Step 10: Commit**

```bash
git add db/migrate db/schema.rb app/models/maker/build_log_entry.rb \
        test/models/maker/build_log_body_migration_test.rb
git commit -m "feat(build log): move entry bodies to Action Text"
```

---

## Task 3: Move note bodies to Action Text

**Files:**
- Create: `db/migrate/<timestamp>_move_note_body_to_action_text.rb`
- Create: `test/models/maker/note_body_migration_test.rb`
- Modify: `app/models/maker/note.rb`

- [ ] **Step 1: Generate the migration**

```bash
bin/rails generate migration MoveNoteBodyToActionText
```

- [ ] **Step 2: Write the failing test**

Create `test/models/maker/note_body_migration_test.rb`:

```ruby
require "test_helper"
require Dir[Rails.root.join("db/migrate/*_move_note_body_to_action_text.rb")].first

# Note bodies are MARKDOWN today. The failure this pins is a note that used to render as bold
# arriving in the editor as literal asterisks — a silent, unrecoverable downgrade of every
# existing note.
class NoteBodyMigrationTest < ActiveSupport::TestCase
  Converter = MoveNoteBodyToActionText

  test "markdown emphasis is rendered, not preserved literally" do
    html = Converter.to_html("**tight** fit")
    assert_includes html, "<strong>tight</strong>"
    assert_not_includes html, "**"
  end

  test "markdown lists become real lists" do
    html = Converter.to_html("- one\n- two")
    assert_includes html, "<li>one</li>"
  end

  test "links survive" do
    assert_includes Converter.to_html("[docs](http://example.com)"), 'href="http://example.com"'
  end

  test "the sanitizer still runs — this conversion must not become an XSS hole" do
    html = Converter.to_html("hi <script>alert('x')</script>")
    assert_not_includes html, "<script>"
  end

  test "a javascript: href is stripped" do
    assert_not_includes Converter.to_html("[x](javascript:alert(1))"), "javascript:"
  end
end
```

- [ ] **Step 3: Run it to verify it fails**

```bash
bin/rails test test/models/maker/note_body_migration_test.rb
```

Expected: FAIL with `NoMethodError: undefined method 'to_html'`.

- [ ] **Step 4: Write the migration**

Replace the generated file's contents with:

```ruby
# Converts maker_notes.body (markdown) into Action Text, then drops the column. Same column-shadow
# reasoning as MoveBuildLogBodyToActionText.
#
# UNLIKE the other data migrations here, this one deliberately CALLS APP CODE: fidelity means
# producing exactly what the page was already showing, and that is NotesHelper#render_note
# (kramdown -> sanitize). Reimplementing a markdown renderer inline to stay self-contained would
# trade the one property that matters for a principle. render_note is safe to depend on — it keeps
# a second caller after this migration (app/views/models/show.html.erb renders Maker::Model#notes
# through it), so it is not going away.
class MoveNoteBodyToActionText < ActiveRecord::Migration[8.1]
  class MigrationNote < ActiveRecord::Base
    self.table_name = "maker_notes"
  end

  class MigrationRichText < ActiveRecord::Base
    self.table_name = "action_text_rich_texts"
  end

  RECORD_TYPE = "Maker::Note".freeze

  def self.to_html(markdown)
    ApplicationController.helpers.render_note(markdown).to_str
  end

  def up
    now = Time.current
    MigrationNote.find_each do |note|
      next if MigrationRichText.exists?(record_type: RECORD_TYPE, record_id: note.id, name: "body")
      MigrationRichText.create!(
        name: "body", record_type: RECORD_TYPE, record_id: note.id,
        body: self.class.to_html(note.body), created_at: now, updated_at: now
      )
    end
    remove_column :maker_notes, :body
  end

  def down
    add_column :maker_notes, :body, :text
    MigrationRichText.where(record_type: RECORD_TYPE, name: "body").find_each do |rt|
      # Lossy by nature — markdown source cannot be recovered from rendered HTML. Keeps the words.
      text = ActionController::Base.helpers.strip_tags(rt.body.to_s).to_s
      MigrationNote.where(id: rt.record_id).update_all(body: CGI.unescapeHTML(text).strip)
    end
    change_column_null :maker_notes, :body, false
    MigrationRichText.where(record_type: RECORD_TYPE, name: "body").delete_all
  end
end
```

- [ ] **Step 5: Run the test to verify it passes**

```bash
bin/rails test test/models/maker/note_body_migration_test.rb
```

Expected: PASS, 5 tests.

- [ ] **Step 6: Switch the model to rich text**

Replace `app/models/maker/note.rb` in full:

```ruby
module Maker
  # A note attached to a file by node_id (a bare string, no FK — like Maker::FileAttachment).
  # User-scoped; a file has many notes. The body is Action Text (Lexxy in the browser); it was
  # markdown until 2026-07-27 and existing notes were converted through NotesHelper#render_note.
  class Note < ApplicationRecord
    self.table_name = "maker_notes"

    belongs_to :user

    has_rich_text :body

    validates :node_id, presence: true
    validates :body, presence: true
  end
end
```

- [ ] **Step 7: Migrate and verify**

```bash
bin/rails db:migrate && grep -n "maker_notes" -A 8 db/schema.rb
```

Expected: no `t.text "body"` under `maker_notes`.

- [ ] **Step 8: Confirm the markdown helper survived**

```bash
bin/rails test test/helpers/notes_helper_test.rb
```

Expected: PASS. `render_note` still has `app/views/models/show.html.erb:95` as a caller — if this
file was deleted as "dead code", the model detail page is now broken.

- [ ] **Step 9: Commit**

```bash
git add db/migrate db/schema.rb app/models/maker/note.rb \
        test/models/maker/note_body_migration_test.rb
git commit -m "feat(notes): move note bodies to Action Text, rendering existing markdown"
```

---

## Task 4: Wire the editor into the build log

**Files:**
- Modify: `app/controllers/projects_controller.rb` (`show`)
- Modify: `app/views/projects/_build_log.html.erb:4-9`
- Modify: `app/views/projects/_log_entry.html.erb:7`
- Test: `test/integration/web/project_build_log_test.rb`

- [ ] **Step 1: Write the failing test**

Append to `test/integration/web/project_build_log_test.rb`:

```ruby
    test "the entry form renders a Lexxy editor with attachments disabled" do
      user = sign_in
      project = user.maker_projects.create!(name: "Lamp")
      get project_path(project)
      assert_response :success
      assert_select "lexxy-editor[attachments=?]", "false"
      assert_select "textarea[name=?]", "build_log_entry[body]", count: 0
    end

    test "a rich entry body round-trips its formatting" do
      user = sign_in
      project = user.maker_projects.create!(name: "Lamp")
      post project_build_log_entries_path(project),
           params: { build_log_entry: { body: "<p>Cut the <strong>panels</strong></p>" } }
      follow_redirect!
      assert_select ".entry-body strong", text: "panels"
    end
```

The existing tests in this file (`add a build-log entry`, `a blank entry body is rejected`,
`delete a build-log entry`, `entries render newest first`) must keep passing unchanged — a plain
string assigned to a rich text attribute is still a valid body.

- [ ] **Step 2: Run them to verify they fail**

```bash
bin/rails test test/integration/web/project_build_log_test.rb
```

Expected: FAIL — no `lexxy-editor` element; the plain textarea is still rendered.

- [ ] **Step 3: Give the form a model object**

In `app/controllers/projects_controller.rb`, inside `show`, add after the `@tasks` line:

```ruby
    # The entry form binds to a real object: `rich_text_area` reads its value from the form's
    # object, and Action Text's form helper is not built for the object-less `fields_for` the plain
    # textarea used.
    @new_entry = @project.build_log_entries.new
```

- [ ] **Step 4: Replace the form**

In `app/views/projects/_build_log.html.erb`, replace lines 4-9 (the `form_with` block) with:

```erb
  <%# scope: :build_log_entry — form_with on a NAMESPACED model (Maker::BuildLogEntry) derives
      `maker_build_log_entry[...]`, which the controller's params.require(:build_log_entry)
      rejects. Same trap as projects/_form.html.erb. %>
  <%= form_with model: @new_entry, scope: :build_log_entry,
                url: project_build_log_entries_path(@project), class: "log-form" do |f| %>
    <%= f.rich_text_area :body, placeholder: "What did you do?", attachments: "false" %>
    <%= f.submit "Add entry", class: "btn small" %>
  <% end %>
```

- [ ] **Step 5: Render the rich body**

In `app/views/projects/_log_entry.html.erb`, replace line 7:

```erb
  <p class="entry-body"><%= entry.body %></p>
```

with:

```erb
  <%# A div, not a p: Action Text emits block-level markup and a <p> cannot legally contain it. %>
  <div class="entry-body"><%= entry.body %></div>
```

- [ ] **Step 6: Run the tests**

```bash
bin/rails test test/integration/web/project_build_log_test.rb
```

Expected: PASS, whole file.

**If `assert_select "lexxy-editor[attachments=?]", "false"` fails** because the option was rendered
somewhere other than as an attribute on the element, inspect what was produced:

```bash
bin/rails test test/integration/web/project_build_log_test.rb -n "/attachments disabled/" -v
```

then adjust the call to whatever Lexxy actually accepts (its documented forms are the
`attachments` attribute and a named `preset`) and update the assertion to match. Do **not** delete
the assertion — attachments being off is spec decision #2, and this is the only test that proves
it.

- [ ] **Step 7: Commit**

```bash
git add app/controllers/projects_controller.rb app/views/projects/_build_log.html.erb \
        app/views/projects/_log_entry.html.erb test/integration/web/project_build_log_test.rb
git commit -m "feat(build log): Lexxy editor on entries, text-only"
```

---

## Task 5: Wire the editor into file notes

**Files:**
- Modify: `app/controllers/files_controller.rb` (`show`)
- Modify: `app/views/files/show.html.erb:152-155,162`
- Test: `test/integration/web/notes_test.rb`

- [ ] **Step 1: Write the failing test**

Append to `test/integration/web/notes_test.rb`, inside `module Web` / `class NotesTest`. That file
already defines the `sign_in` helper and the `pin_file_layer_backend("chunk")` setup — use them.

```ruby
    test "the note form renders a Lexxy editor with attachments disabled" do
      user = sign_in
      node = user.nodes.create!(node_id: "n-1", name: "bracket.stl", kind: "file")
      get file_path(node.node_id)
      assert_response :success
      assert_select "lexxy-editor[attachments=?]", "false"
      assert_select "textarea[name=?]", "note[body]", count: 0
    end

    test "a rich note body renders as markup" do
      user = sign_in
      node = user.nodes.create!(node_id: "n-2", name: "bracket.stl", kind: "file")
      post file_notes_path(node.node_id),
           params: { note: { body: "<p>Print at <strong>0.2mm</strong></p>" } }
      follow_redirect!
      assert_select ".note-body strong", text: "0.2mm"
    end
```

- [ ] **Step 2: Run them to verify they fail**

```bash
bin/rails test test/integration/web/notes_test.rb
```

Expected: FAIL — the raw `<textarea name="note[body]">` is still rendered.

- [ ] **Step 3: Give the note form a model object**

In `app/controllers/files_controller.rb`, in `show`, next to wherever `@notes` is assigned:

```ruby
    @new_note = current_user.maker_notes.new(node_id: @node.node_id)
```

- [ ] **Step 4: Replace the note form and the note body**

In `app/views/files/show.html.erb`, replace lines 152-155:

```erb
  <%= form_with url: file_notes_path(@node.node_id), method: :post, class: "note-form" do %>
    <textarea name="note[body]" rows="3" placeholder="Add a note (markdown supported)…" required></textarea>
    <%= submit_tag "Add note", class: "btn small" %>
  <% end %>
```

with:

```erb
  <%# scope: :note — Maker::Note is namespaced, so form_with would otherwise derive
      `maker_note[...]` and NotesController's params.dig(:note, :body) would read nil. %>
  <%= form_with model: @new_note, scope: :note, url: file_notes_path(@node.node_id),
                method: :post, class: "note-form" do |f| %>
    <%= f.rich_text_area :body, placeholder: "Add a note…", attachments: "false" %>
    <%= f.submit "Add note", class: "btn small" %>
  <% end %>
```

Then replace line 162:

```erb
        <div class="note-body"><%= render_note(note.body) %></div>
```

with:

```erb
        <div class="note-body"><%= note.body %></div>
```

`render_note` is no longer used **here** — but it is still used by
`app/views/models/show.html.erb:95` for `Maker::Model#notes`. Do not delete the helper.

- [ ] **Step 5: Run the tests**

```bash
bin/rails test test/integration/web/notes_test.rb
```

Expected: PASS, whole file. The JSON popover path (`NotesController#create` answering JSON) is
unaffected — it posts a plain string, which a rich text attribute accepts.

- [ ] **Step 6: Commit**

```bash
git add app/controllers/files_controller.rb app/views/files/show.html.erb \
        test/integration/web/notes_test.rb
git commit -m "feat(notes): Lexxy editor on file notes, text-only"
```

---

## Task 6: Keep the v1 API a plain String

**Files:**
- Modify: `app/controllers/v1/maker/build_log_entries_controller.rb:27-31`
- Modify: `app/controllers/v1/maker/projects_controller.rb:50-52`
- Test: `test/integration/v1/maker/build_log_plain_text_test.rb` (new)

- [ ] **Step 1: Write the failing test**

Create `test/integration/v1/maker/build_log_plain_text_test.rb`. The device-token helpers
(`bootstrap_token`, and the local `auth` shape) match `test/integration/v1/maker/`'s existing
files:

```ruby
require "test_helper"

module V1
  module Maker
    # Pins the wire contract the Action Text move must not break: client/sync-client's
    # BuildLogEntry declares `pub body: String` with NO serde(default), so a body that serializes
    # as anything but a plain string is a hard deserialize error for a shipped desktop client.
    class BuildLogPlainTextTest < ActionDispatch::IntegrationTest
      def auth(token) = { "Authorization" => "Bearer #{token}" }

      setup do
        @token = bootstrap_token(email: "bl-plain@example.com", device_name: "d")
        post "/v1/maker/projects", params: { project: { name: "Lamp" } }, as: :json,
             headers: auth(@token)
        @project = JSON.parse(response.body)["id"]
      end

      test "a rich body serializes as plain text on the entries index" do
        post "/v1/maker/projects/#{@project}/build_log_entries",
             params: { build_log_entry: { body: "<p>Cut the <strong>panels</strong></p>" } },
             as: :json, headers: auth(@token)
        assert_response :created

        get "/v1/maker/projects/#{@project}/build_log_entries", headers: auth(@token)
        assert_response :success

        body = JSON.parse(response.body)["build_log_entries"].first["body"]
        assert_kind_of String, body
        assert_includes body, "Cut the panels"
        assert_not_includes body, "<strong>"
      end

      test "the full project view serializes entry bodies as plain text too" do
        post "/v1/maker/projects/#{@project}/build_log_entries",
             params: { build_log_entry: { body: "<p>Sanded the <em>edges</em></p>" } },
             as: :json, headers: auth(@token)

        get "/v1/maker/projects/#{@project}", headers: auth(@token)
        assert_response :success

        body = JSON.parse(response.body)["build_log_entries"].first["body"]
        assert_kind_of String, body
        assert_includes body, "Sanded the edges"
        assert_not_includes body, "<em>"
      end

      test "a plain string on write is still accepted" do
        post "/v1/maker/projects/#{@project}/build_log_entries",
             params: { build_log_entry: { body: "Cut the panels" } },
             as: :json, headers: auth(@token)
        assert_response :created
        assert_equal "Cut the panels", JSON.parse(response.body)["body"]
      end
    end
  end
end
```

- [ ] **Step 2: Run it to verify it fails**

```bash
bin/rails test test/integration/v1/maker/build_log_plain_text_test.rb
```

Expected: FAIL — `body` serializes as the rich text object's JSON, not a String.

- [ ] **Step 3: Serve plain text from both serializers**

In `app/controllers/v1/maker/build_log_entries_controller.rb`, replace `entry_json`:

```ruby
      # `body` stays a plain String on the wire in both directions. client/sync-client's
      # BuildLogEntry declares `pub body: String` with no serde(default), so anything else is a
      # hard deserialize error for a shipped desktop client. Rich formatting is web-only
      # (spec decision #4).
      def entry_json(entry)
        { id: entry.id, project_id: entry.project_id, body: entry.body.to_plain_text,
          entry_type: entry.entry_type, logged_at: entry.logged_at,
          created_at: entry.created_at, updated_at: entry.updated_at }
      end
```

In `app/controllers/v1/maker/projects_controller.rb`, replace `build_log_entry_json`:

```ruby
      # See V1::Maker::BuildLogEntriesController#entry_json — `body` is a plain String on the wire.
      def build_log_entry_json(entry)
        { id: entry.id, body: entry.body.to_plain_text, entry_type: entry.entry_type,
          logged_at: entry.logged_at }
      end
```

`entry_params` is unchanged — it permits `:body`, and assigning a String to a rich text attribute
is exactly what Action Text expects.

- [ ] **Step 4: Run the v1 suite**

```bash
bin/rails test test/integration/v1/
```

Expected: PASS. `test/integration/v1/maker/` also holds a projects-isolation test that creates
build-log entries — it must stay green, and it is the check that the serializer change did not
alter status codes or scoping.

- [ ] **Step 5: Commit**

```bash
git add app/controllers/v1/maker/ test/integration/v1/maker/build_log_plain_text_test.rb
git commit -m "feat(v1): serve build-log bodies as plain text after the Action Text move"
```

---

## Task 7: Full verification

**Files:** none — verification only.

- [ ] **Step 1: All three backend legs**

```bash
bin/rails test
```

```bash
LIBRARY_BACKEND=share bin/rails test
```

```bash
LIBRARY_BACKEND=s3 bin/rails test
```

Expected: 0 failures, 0 errors, identical counts on all three.

- [ ] **Step 2: Confirm the Rust client was not touched**

```bash
git diff --stat main -- client/
```

Expected: **empty output.** The v1 contract did not move, so no client change is warranted; a diff
here means Task 6 changed the wire format instead of preserving it.

- [ ] **Step 3: Browser-verify the editor**

Boot the app, open a project, and confirm by hand: the entry form shows a Lexxy toolbar; bold, a
bulleted list and a code block all apply and survive a save; the build-log photo strip still
uploads and attaches beneath the entry; **dragging an image into the editor does nothing** (that is
the intended behaviour, not a bug); and an existing pre-migration entry still shows its line
breaks. Repeat on a file detail page for notes, and confirm a pre-migration markdown note renders
as formatted HTML rather than literal asterisks.

```bash
bin/rails server -p 3001
```

- [ ] **Step 4: Commit any fixes**

```bash
git add -A && git commit -m "fix: Lexxy integration follow-ups from browser verification"
```
