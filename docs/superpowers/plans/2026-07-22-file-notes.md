# Per-file Notes — Implementation Plan

> REQUIRED SUB-SKILL: superpowers:subagent-driven-development / executing-plans. Checkbox steps.

**Goal:** Markdown notes attached to any file — right-click quick-add, a note-count badge, and a rendered notes section on the file detail page.

**Architecture:** New `Maker::Note` (keyed by `node_id`). `kramdown` → sanitized HTML via `NotesHelper`. `NotesController` (session auth). Badge + right-click menu in the files grid/list; full CRUD on `files#show`. No file-layer coupling (notes are DB rows against a node_id).

**Branch:** `file-notes` (off `main`; kramdown already `bundle add`ed — commit Gemfile/Gemfile.lock in Task 2).

**Spec:** `docs/superpowers/specs/2026-07-22-file-notes-design.md`. Conventions: conventional commits + Co-Authored-By trailer; scoped `git add`.

---

## Task 1: `Maker::Note` model + migration
**Files:** migration; `app/models/maker/note.rb`; `app/models/user.rb` (has_many); `test/models/maker/note_test.rb`

- [ ] Generate: `bin/rails g migration CreateMakerNotes` → in `change`:
  ```ruby
  create_table :maker_notes do |t|
    t.integer :user_id, null: false
    t.string  :node_id, null: false
    t.text    :body,    null: false
    t.timestamps
  end
  add_index :maker_notes, [:user_id, :node_id]
  ```
  `bin/rails db:migrate`.
- [ ] Model `app/models/maker/note.rb`:
  ```ruby
  module Maker
    class Note < ApplicationRecord
      self.table_name = "maker_notes"
      belongs_to :user
      validates :node_id, presence: true
      validates :body, presence: true
    end
  end
  ```
- [ ] `User`: `has_many :maker_notes, class_name: "Maker::Note", dependent: :destroy`.
- [ ] Test: validations (node_id + body required); belongs_to user.
- [ ] Run `bin/rails test test/models/maker/note_test.rb` → green. Commit.

## Task 2: kramdown rendering — `NotesHelper#render_note`
**Files:** `Gemfile`/`Gemfile.lock` (kramdown, already added); `app/helpers/notes_helper.rb`; `test/helpers/notes_helper_test.rb`

- [ ] `app/helpers/notes_helper.rb`:
  ```ruby
  module NotesHelper
    # Markdown source -> sanitized HTML. sanitize is NOT optional: body is user input rendered as
    # HTML, so scripts / javascript: hrefs / unknown tags must be stripped (kramdown will happily
    # pass raw HTML through otherwise).
    def render_note(body)
      sanitize(Kramdown::Document.new(body.to_s).to_html)
    end
  end
  ```
- [ ] Test (`ActionView::TestCase`): `render_note("**b** [x](http://e.com)")` includes `<strong>` + an `<a`; `render_note("<script>alert(1)</script>")` and `render_note("[x](javascript:alert(1))")` produce **no** `<script>` and no `javascript:` href.
- [ ] Run → green. Commit (incl. Gemfile + Gemfile.lock).

## Task 3: `NotesController` + routes
**Files:** `config/routes.rb`; `app/controllers/notes_controller.rb`; `test/integration/web/notes_test.rb`

- [ ] Routes (after the `resources :files` block):
  ```ruby
  post   "files/:node_id/notes", to: "notes#create", as: :file_notes
  resources :notes, only: %i[destroy]
  ```
- [ ] `app/controllers/notes_controller.rb`:
  ```ruby
  class NotesController < ApplicationController
    before_action :authenticate_user!

    # POST /files/:node_id/notes  { note: { body } }  — HTML (detail form) + JSON (right-click popover)
    def create
      node_id = params.require(:node_id)
      unless current_user.nodes.present.exists?(node_id:)      # DB fact — no file-layer call
        return respond_to { |f| f.html { redirect_back_or_to(files_path, alert: "File not found.") }
                                f.json { render json: { error: "not_found" }, status: :not_found } }
      end
      note = current_user.maker_notes.new(node_id:, body: params.dig(:note, :body))
      if note.save
        respond_to do |f|
          f.html { redirect_to file_path(node_id), notice: "Note added." }
          f.json { render json: { id: note.id, count: current_user.maker_notes.where(node_id:).count }, status: :created }
        end
      else
        respond_to do |f|
          f.html { redirect_to file_path(node_id), alert: note.errors.full_messages.to_sentence }
          f.json { render json: { error: note.errors.full_messages.to_sentence }, status: :unprocessable_entity }
        end
      end
    end

    # DELETE /notes/:id
    def destroy
      note = current_user.maker_notes.find(params[:id])
      node_id = note.node_id
      note.destroy!
      redirect_to file_path(node_id), notice: "Note deleted."
    end
  end
  ```
- [ ] Tests (pin chunk; sign_in helper like files_flow_test): create via HTML (a node the user owns) → note created + redirect; create via JSON → 201 + `count`; blank body → 422/redirect-with-alert; foreign node_id → 404/not_found; destroy removes it; another user's note → 404.
- [ ] Run → green. Commit.

## Task 4: Notes section on `files#show`
**Files:** `app/controllers/files_controller.rb#show` (load `@notes`); `app/views/files/show.html.erb`; `test/integration/web/files_flow_test.rb`

- [ ] `#show`: `@notes = current_user.maker_notes.where(node_id: @node.node_id).order(created_at: :desc).to_a`.
- [ ] In `show.html.erb`, add a Notes section (after the preview):
  ```erb
  <section class="notes-panel">
    <h2>Notes <span class="muted">(<%= @notes.size %>)</span></h2>
    <%= form_with url: file_notes_path(@node.node_id), method: :post, class: "note-form" do %>
      <textarea name="note[body]" rows="3" placeholder="Add a note (markdown)…" required></textarea>
      <%= submit_tag "Add note", class: "btn small" %>
    <% end %>
    <% @notes.each do |note| %>
      <article class="note">
        <div class="note-body"><%= render_note(note.body) %></div>
        <div class="note-meta muted">
          <time><%= note.created_at.strftime("%Y-%m-%d %H:%M") %></time>
          <%= button_to "Delete", note_path(note), method: :delete, class: "linkbtn danger small",
                        form: { data: { turbo_confirm: "Delete this note?" } } %>
        </div>
      </article>
    <% end %>
  </section>
  ```
- [ ] Tests: a file's detail page shows the Notes section, renders a note's markdown (a `<strong>`), add works, delete works.
- [ ] Run → green. Commit.

## Task 5: Note-count badge (index grid + list)
**Files:** `app/controllers/files_controller.rb#index` (load `@note_counts`); `app/views/files/_grid.html.erb`, `_list.html.erb`; `test/integration/web/files_flow_test.rb`

- [ ] `#index`: `@note_counts = current_user.maker_notes.where(node_id: @nodes.map(&:node_id)).group(:node_id).count`.
- [ ] Grid card + list Name cell: for a file with `@note_counts[node.node_id].to_i > 0`, render a small badge linking to the detail Notes section:
  ```erb
  <% if (n = @note_counts[node.node_id].to_i) > 0 %>
    <%= link_to "📝 #{n}", file_path(node.node_id), class: "note-badge", title: "#{n} note#{'s' unless n == 1}" %>
  <% end %>
  ```
- [ ] Tests: a file with 2 notes shows `.note-badge` with "2" in both grid and list; a file with none shows no badge.
- [ ] Run → green. Commit.

## Task 6: Right-click quick-add (filemenu Stimulus controller + popover + CSS)
**Files:** `app/javascript/controllers/filemenu_controller.js`; `app/views/files/_grid.html.erb` + `_list.html.erb` (contextmenu hooks + a shared popover partial `_note_popover.html.erb`); `app/assets/stylesheets/*` (menu/popover CSS); `test/integration/web/files_flow_test.rb` (structural)

- [ ] Add `data-controller="filemenu"` to the grid + list containers, `data-action="contextmenu->filemenu#open"` + `data-node-id` + `data-note-url` (the `file_notes_path`) on each **file** cell/row. Render one hidden popover (`_note_popover`) with a `<textarea>` + Save button, targeted by the controller.
- [ ] `filemenu_controller.js`: on `contextmenu` over a file cell → `preventDefault`, position + show a menu (`Add note` / `Open`) at the cursor; `Add note` → show the popover; Save → `fetch(POST note-url, { note: { body } })` with the CSRF token → on 201 bump the badge (or reload) + close; Escape/outside-click closes. No-JS degrades to the browser menu + the detail page (Task 4).
- [ ] CSS for `.file-menu`, `.note-popover`, `.note-badge`.
- [ ] Structural test: grid + list render `data-controller="filemenu"` and file cells carry `data-note-url`. (JS behavior itself is manual-smoke — integration tests don't run JS, matching how the uploader is covered.)
- [ ] Run → green. Commit.

## Task 7: Verify (3 backends)
- [ ] `bin/rails test` (chunk); `LIBRARY_BACKEND=share LIBRARY_PATH=$(mktemp -d) bin/rails test`; the s3 leg with `LIBRARY_S3_*` set. All green.
- [ ] Manual smoke: right-click a file → Add note → see the badge; open the file → read rendered note + delete.

## Self-review
- Coverage: model (T1), rendering+sanitize (T2), controller+routes (T3), detail CRUD (T4), badge (T5), right-click (T6), 3-backend verify (T7). Edit-in-place, search, folder-notes are Out of scope.
- Security: `render_note` sanitizes (pinned by a script/`javascript:` test); create verifies node ownership; all `current_user`-scoped.
