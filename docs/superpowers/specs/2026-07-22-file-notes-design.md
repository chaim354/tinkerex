# Per-file notes (markdown, rendered)

**Date:** 2026-07-22
**Status:** approved (design)
**Scope:** attach short markdown notes to any file, add one quickly via a right-click menu in the
files browser, show a note-count badge on files that have them, and read/add/delete notes on the
file detail page. Web UI only (session auth), notes keyed by `node_id`, all `current_user`-scoped.
Independent of the project-folders feature (different files). Rendered via **kramdown** (added).

## Problem

Makers want to jot a note against a specific file ("this is the v2 with the fixed tab", "print at
0.2mm", "supplier discontinued") without leaving the browser. Nothing today attaches free text to a
file; build-log entries are project-scoped, not file-scoped.

## Model

- **`Maker::Note`** (`maker_notes` table): `user_id`, `node_id` (string — the file), `body` (text,
  markdown source), timestamps. `belongs_to :user`; `validates :node_id, :body, presence: true`.
  `User has_many :maker_notes`. A file (node_id) has many notes.
- Notes reference a file by `node_id` (a bare string, no FK — same as `maker_file_attachments`), so
  a note survives independent of which storage backend holds the bytes; it is orphaned (invisible)
  only if the file is truly gone, which is acceptable.

## Rendering (kramdown + sanitize)

- **`kramdown`** (2.5.x, pure-Ruby, MIT) added to the Gemfile. A `NotesHelper#render_note(body)`
  returns `sanitize(Kramdown::Document.new(body.to_s).to_html)` — kramdown → HTML, then Rails'
  built-in `sanitize` strips anything unsafe (scripts, `javascript:` hrefs, unknown tags), keeping
  the markdown subset (headings, bold/italic, lists, links, code, blockquote). **Sanitize is not
  optional** — the body is user input rendered as HTML.

## Surfaces

### 1. Note-count badge (files grid + list + detail)
`FilesController#index` loads counts in one query — `current_user.maker_notes.where(node_id: ids)
.group(:node_id).count` → `{node_id => n}` — and each file with `n > 0` renders a small **📝 n**
badge that links to the file detail page's Notes section. `#show` shows the same for the one file.

### 2. Right-click quick-add (grid + list)
A `filemenu` Stimulus controller on the grid/list container:
- `contextmenu` on a file cell → `preventDefault`, show a small menu at the cursor with **Add note**
  (and **Open**). Escape / outside-click closes it.
- **Add note** → a lightweight popover with a `<textarea>` + Save → `fetch` `POST /files/:node_id/
  notes` (JSON) → on success, bump/[show] the badge and close. No full navigation.
- Degrades safely: with no JS, right-click is the browser's own menu and notes are still fully
  usable from the file detail page (below). The menu is an accelerator, not the only path.

### 3. File detail Notes section (`files#show`)
A **Notes** section listing the file's notes newest-first, each **rendered** (markdown → sanitized
HTML) with a delete control; plus an add-note form (`<textarea>` → Save). This is the full,
JS-free CRUD surface. (Edit is a backlog nicety — v1 is add + delete; to change a note, delete +
re-add.)

## Routes + controller

```ruby
resources :files … do
  member { get "notes" }        # optional JSON list for the popover (or reuse show)
end
post   "files/:node_id/notes", to: "notes#create", as: :file_notes
resources :notes, only: %i[destroy]
```
`NotesController` (session auth): `create` (node_id from path; verifies the node is the user's via
`current_user.nodes`; `respond_to` HTML redirect + JSON for the popover), `destroy`
(`current_user.maker_notes.find`). All `current_user`-scoped — a foreign node or note → 404.

## Error handling
- Creating a note verifies the `node_id` belongs to `current_user` (`current_user.nodes.present
  .exists?(node_id:)`) — a DB fact, backend-independent (no file-layer call, so an unmounted
  backend never blocks noting a file the user owns). Blank body → validation error.
- Everything user-scoped; another user's file/note → 404.

## Testing
- `Maker::Note` model: validations, user scoping.
- `NotesHelper#render_note`: markdown renders (bold/list/link), and **script/`javascript:` are
  stripped** (the security assertion).
- Web integration (`files` grid/list + detail): a file with notes shows the badge with the count;
  the detail Notes section lists rendered notes + add + delete; `POST /files/:id/notes` (HTML +
  JSON) creates; foreign node/note → 404; blank body rejected.
- Backend-neutral (notes never touch the file layer for correctness — only the badge/detail page
  render alongside thumbnails), but the grid/list render pins chunk like the other web tests.

## Out of scope (backlog)
Editing a note in place (v1 = delete + re-add); note search; notes on folders; @-mentions/links
between notes; per-note pinning; rich-text (it's markdown source in, rendered HTML out).
