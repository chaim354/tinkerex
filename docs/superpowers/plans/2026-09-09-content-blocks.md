# Content Blocks Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: this repo's `.claude/commands/execute-plan.md`
> (batched by file, disjoint tasks in parallel, one capped full-depth review per task) overrides
> any generic subagent loop. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Text (Markdown), link and image blocks that sit in the page's order like panels, are
added from the editor's top bar and arranged by the same editor, travel with their content in the
YAML; the page intro (cover, description) editable in the same mode; and half-width panels that
pack with no gaps.

**Architecture:** A `maker_project_blocks` table; `block:<key>` keys join the layout's vocabulary
(`Maker::ProjectKind.layout_for(blocks:)`); `Maker::LayoutDocument` gains block entries, a `page`
section, image paths, id matching, and three outputs for Save (column, blocks, page). The panels
door's Save writes all of it in one transaction. One block partial per page; Markdown through the
existing `Maker::Markdown`. The editor gains an Add block menu, block editors in the slot body, a
page-intro card and a preview helper; a `masonry` controller closes the gaps on all three renders.

**Tech Stack:** Rails 8, Hotwire/Stimulus, kramdown via `Maker::Markdown`, SortableJS (already
vendored), Minitest, Capybara + headless Chrome.

**Spec:** `docs/superpowers/specs/2026-09-09-content-blocks-design.md`. Slice 1's plan
(`2026-09-09-page-editor.md`) is the reference for every convention reused here: fixture rules
(rows, never the port), the shared-worktree rules, mutation checks with recorded red output.

---

## Shared interface (every task codes against this)

**Model** (Task A) — `Maker::ProjectBlock`, table `maker_project_blocks`:
`user_id, project_id, key (12 hex, unique per project), kind (text|link|image), heading, body, url, line, caption, node_id`.
`KINDS`, `HEADING_MAX = 80`, `LINE_MAX = 200`, `BODY_MAX = 20 * 1024`, `CAP = 40`, `#layout_key` → `"block:<key>"`.
`Maker::Project#blocks` (ordered by id, `dependent: :destroy`), `User#maker_project_blocks`.

**Layout** (Task A) — `Maker::ProjectKind`:
```ruby
BLOCK_PREFIX = "block:"; def self.block_key(key); BLOCK_DEFAULT_WIDTHS = { "text" => "full", "link" => "half", "image" => "full" }
Layout = Data.define(:order, :hidden, :views, :widths, :titles, :intros, :repo_ids, :block_kinds)
  def block?(key); def block_kind(key)          # kind string or nil
def self.default_width(key, block_kind: nil)   # block keys answer by kind
def self.layout_for(kind:, overrides:, folders: [], blocks: [])   # blocks: [[key, kind], …] in row order
```
A block the stored order does not name lands FIRST. `offered_views` answers `[]` for a block key.
`Maker::Project#panel_layout(folders: [], blocks: [])` passes `blocks:` through.

**Document** (Task B) — `Maker::LayoutDocument.new(layout, folder_names, blocks: [], images: {}, page: {})`:
`blocks` = the project's `Maker::ProjectBlock` rows; `images` = `{ node_id => "photos/side.jpg" }` for
the folder's image files (paths relative to the project folder); `page` = `{ "description" => …, "cover" => node_id_or_nil }`.
Draft shape:
```json
{ "layout": 1, "page": { "description": "…", "cover": "<node_id>|null" },
  "panels": [ { "key": "block:3f9a1b2c4d5e", "kind": "text", "hidden": false, "width": "full", "heading": "…", "body": "…" },
              { "key": "block:new-1", "kind": "link", "hidden": false, "width": "half", "url": "https://…", "title": "…", "line": "…" },
              { "key": "block:new-2", "kind": "image", "hidden": false, "width": "full", "file": "<node_id>", "caption": "…" },
              { "key": "attachments", "hidden": false, "width": "full", "view": "tiles" } ] }
```
New outputs: `#blocks_from(draft)` → `[ { "key" =>, "kind" =>, "heading" =>, "body" =>, "url" =>, "line" =>, "caption" =>, "node_id" => } ]`
(a link's `title` becomes `heading`); `#page_from(draft)` → `{ "description" => str_or_nil, "cover_node_id" => id_or_nil }` or nil when the draft has no `page`.
YAML: top-level `layout`, `page` (`description`, `cover` path), `panels`; block entries `block: <kind>` with optional `id:`.

**Routes** (Task C): `post :preview` beside `yaml`/`parse` → `preview_project_layout_path`.
**Markup contract** (Task C renders, Task D drives), additions to slice 1's:
```
div.layout-bar
  details.layout-add[data-layout-editor-target=addMenu] > summary "Add block ▾"
    button[data-action="layout-editor#addBlock"][data-kind=text|link|image]
template[data-layout-editor-target=blockTemplate][data-kind=…]   # one per kind: a complete slot with key block:new-__N__
div.page-intro[data-layout-editor-target=page][data-cover][data-description]        # edit mode only, above the grid
  textarea[data-action="input->layout-editor#description"]
  button.cover-pick[data-action="layout-editor#pickCover"][data-node-id]  (one per folder image)   button[data-action="layout-editor#removeCover"]
div.panel-slot[data-kind=…] (a block)  + data-heading data-body data-url data-link-title data-line data-file data-caption
  .panel-strip: handle, up/down, eye, width, button[data-action="layout-editor#deleteBlock"]; no pencil, no view switch
  .panel-slot-body > form.block-editor (edit mode):
    text:  input[data-action="input->layout-editor#field"][data-field=heading], textarea[data-field=body], button[data-action="layout-editor#previewMarkdown"], div.block-preview[data-layout-editor-target=preview]
    link:  input[data-field=url], input[data-field=linkTitle], input[data-field=line], a.block-link-card (live)
    image: button.image-pick[data-action="layout-editor#pickImage"][data-node-id] (one per folder image), input[data-field=caption], figure.block-figure (live)
div.project-panels[data-controller=masonry]   # all three renders; edit mode: data-controller="masonry" on the grid beside the layout-editor target
```

**Order:** A → B → C → D (each depends on the one before). Environment for every test command:
`export LIBRARY_BACKEND=share LIBRARY_PATH=$(mktemp -d)`. Full `bin/ci` needs
`TINKEREX_SYNC_DIR=/Users/charlesschwartz/Desktop/repos/tinkerex-sync`.

---

### Task A: the table, the model, and the layout vocabulary

**Files:**
- Create: `db/migrate/20260909200000_create_maker_project_blocks.rb`, `app/models/maker/project_block.rb`, `test/models/maker/project_block_test.rb`
- Modify: `app/models/maker/project.rb` (association, `panel_layout`), `app/models/user.rb` (association), `lib/schema_map.rb`, `db/schema.rb` (by migrating), `app/services/maker/project_kind.rb`, `test/services/maker/project_kind_test.rb`, `test/models/tenant_cleanup_test.rb`, `test/models/structural_orphan_test.rb`, and whatever `bin/rails schema:map` writes

- [ ] **Step 1: The migration**

```ruby
class CreateMakerProjectBlocks < ActiveRecord::Migration[8.1]
  def change
    create_table :maker_project_blocks do |t|
      t.references :user, null: false, foreign_key: true, index: false
      t.references :project, null: false, index: false
      t.string :key, null: false
      t.string :kind, null: false
      t.string :heading
      t.text :body
      t.string :url
      t.string :line
      t.string :caption
      t.string :node_id
      t.timestamps
    end
    add_index :maker_project_blocks, %i[project_id key], unique: true
    add_index :maker_project_blocks, %i[user_id project_id]
  end
end
```
Run `bin/rails db:migrate` (dev) and `RAILS_ENV=test bin/rails db:migrate`; `db/schema.rb` gains the table.

- [ ] **Step 2: The failing model tests** — `test/models/maker/project_block_test.rb`:

```ruby
require "test_helper"

module Maker
  # A CONTENT BLOCK (2026-09-09, content blocks; spec §4): one row per block, three kinds, the
  # fields checked against the kind so a link without a URL or an image without a file cannot be
  # saved by any door.
  class ProjectBlockTest < ActiveSupport::TestCase
    setup do
      @user = User.create!(email: "blocks-#{SecureRandom.hex(4)}@example.com", password: "correct horse battery staple", confirmed_at: Time.current)
      @project = @user.maker_projects.create!(name: "Lamp")
    end

    def block(**attrs) = @project.blocks.new(user: @user, **attrs)

    test "a key is minted when none is given, twelve hex characters, unique per project" do
      a = block(kind: "text", body: "hello")
      assert a.save, a.errors.full_messages.inspect
      assert_match(/\A[0-9a-f]{12}\z/, a.key)
      assert_equal "block:#{a.key}", a.layout_key
      b = block(kind: "text", body: "again", key: a.key)
      refute b.valid?
      assert_includes b.errors[:key], "has already been taken"
    end

    test "text needs a heading or a body, link needs a URL and a title, image needs a file" do
      refute block(kind: "text").valid?
      assert block(kind: "text", heading: "Why").valid?
      assert block(kind: "text", body: "Because.").valid?
      refute block(kind: "link", url: "https://example.com").valid?, "a link needs a title"
      refute block(kind: "link", heading: "Site").valid?, "a link needs a URL"
      assert block(kind: "link", url: "https://example.com", heading: "Site").valid?
      refute block(kind: "image").valid?
      assert block(kind: "image", node_id: SecureRandom.uuid).valid?
      refute block(kind: "video", body: "x").valid?
    end

    test "a link URL is http or https, nothing else" do
      %w[https://a.example/p?q=1 http://b.example].each { |u| assert block(kind: "link", url: u, heading: "t").valid?, u }
      [ "javascript:alert(1)", "ftp://x", "example.com", "https://", "https://x y" ].each do |u|
        refute block(kind: "link", url: u, heading: "t").valid?, u
      end
    end

    test "lengths are capped and whitespace is collapsed" do
      refute block(kind: "text", heading: "x" * 81).valid?
      assert block(kind: "text", heading: "x" * 80).valid?
      refute block(kind: "text", body: "x" * (20 * 1024 + 1)).valid?
      refute block(kind: "link", url: "https://a.example", heading: "t", line: "x" * 201).valid?
      refute block(kind: "image", node_id: "n", caption: "x" * 201).valid?
      b = block(kind: "text", heading: "  Why  a\n shade ")
      assert b.valid?
      assert_equal "Why a shade", b.heading
    end

    test "a block belongs to its project's owner" do
      other = User.create!(email: "o-#{SecureRandom.hex(4)}@example.com", password: "correct horse battery staple", confirmed_at: Time.current)
      b = @project.blocks.new(user: other, kind: "text", body: "x")
      refute b.valid?
      assert_includes b.errors[:project_id], "must reference your own project"
    end

    test "destroying the project destroys its blocks" do
      block(kind: "text", body: "x").save!
      assert_difference -> { Maker::ProjectBlock.count }, -1 do
        @project.destroy!
      end
    end
  end
end
```

- [ ] **Step 3: The model** — `app/models/maker/project_block.rb`:

```ruby
module Maker
  # A CONTENT BLOCK ON A PROJECT'S PAGE (2026-09-09, content blocks; spec §2, §4). Three kinds in
  # one table because they are arranged as one thing — a block sits in the page's order beside the
  # panels under `block:<key>` — and the kind decides which columns mean anything. The fields are
  # checked AGAINST the kind here, the second lock behind Maker::LayoutDocument's first, so no door
  # (Save, a console, the v1 API later) can store a link without a URL.
  #
  # `key` IS THE LAYOUT'S HANDLE, not `id`: it is minted here, it appears in the YAML as `id:` so a
  # pasted layout can name a block it came from, and a row id would leak ordinal facts about the
  # database into a shareable text.
  #
  # Markdown in `body` is rendered on every read through Maker::Markdown, which sanitises; nothing
  # here is trusted as HTML.
  class ProjectBlock < ApplicationRecord
    self.table_name = "maker_project_blocks"

    KINDS = %w[text link image].freeze
    HEADING_MAX = 80
    LINE_MAX = 200
    BODY_MAX = 20 * 1024
    CAP = 40
    KEY_FORMAT = /\A[0-9a-f]{12}\z/
    URL_FORMAT = %r{\Ahttps?://[^\s/]+\S*\z}

    belongs_to :user
    belongs_to :project, class_name: "Maker::Project"

    normalizes :heading, :url, :line, :caption, with: ->(s) { s.to_s.gsub(/\s+/, " ").strip.presence }

    before_validation { self.key = self.class.new_key if key.blank? }

    validates :kind, inclusion: { in: KINDS }
    validates :key, presence: true, format: { with: KEY_FORMAT }, uniqueness: { scope: :project_id }
    validates :heading, length: { maximum: HEADING_MAX }
    validates :line, :caption, length: { maximum: LINE_MAX }
    validates :body, length: { maximum: BODY_MAX }
    validate :fields_match_kind
    validate :project_belongs_to_user

    def self.new_key = SecureRandom.hex(6)

    def layout_key = Maker::ProjectKind.block_key(key)

    private

    def fields_match_kind
      case kind
      when "text"
        errors.add(:body, "or a heading is required for a text block") if body.blank? && heading.blank?
      when "link"
        errors.add(:url, "must be an http or https URL") unless url.to_s.match?(URL_FORMAT) && URI.parse(url).host.present?
        errors.add(:heading, "is required for a link") if heading.blank?
      when "image"
        errors.add(:node_id, "is required for an image") if node_id.blank?
      end
    rescue URI::InvalidURIError
      errors.add(:url, "must be an http or https URL")
    end

    def project_belongs_to_user
      unless Maker::Project.exists?(id: project_id, user_id: user_id)
        errors.add(:project_id, "must reference your own project")
      end
    end
  end
end
```
In `app/models/maker/project.rb`, beside `has_many :connections`:
```ruby
    # CONTENT BLOCKS (2026-09-09): text, link and image blocks the page editor arranges beside the
    # panels. Row order is creation order; the LAYOUT orders them on the page.
    has_many :blocks, -> { order(:id) }, class_name: "Maker::ProjectBlock", foreign_key: :project_id, dependent: :destroy
```
and change `panel_layout` to `def panel_layout(folders: [], blocks: []) = Maker::ProjectKind.layout_for(kind:, overrides: self[:panels], folders:, blocks:)`
(`visible_panels` passes `blocks:` through likewise). In `app/models/user.rb`, beside the
`maker_connections` association, add the same shape for `maker_project_blocks` (class
`Maker::ProjectBlock`, `dependent: :destroy`).

- [ ] **Step 4: The four guards** — read `lib/schema_map.rb`'s `LAYOUT` and `EDGES`,
`test/models/tenant_cleanup_test.rb`'s `BUILDERS`/`BUILD_ORDER`, `test/models/structural_orphan_test.rb`'s
`CASES`, and mirror `maker_connections` for the project edge:
  - `LAYOUT`: add `maker_project_blocks` to the maker group that holds `maker_connections`.
  - `EDGES`: `[ "maker_project_blocks.project_id", "maker_projects.id", "app", "placed on" ]` and
    `[ "maker_project_blocks.node_id", "nodes.node_id", "app", "pictures" ]`. Read how
    `maker_file_links.from_node_id` satisfies the orphan guard for a `nodes.node_id` edge (a node is
    tombstoned, never destroyed) and follow that precedent exactly; if the guard would demand a
    destroy we do not want (an image block whose file left keeps its row and renders nothing, spec
    §8), register the edge the way file_links does and say so in the report.
  - `tenant_cleanup_test.rb`: a builder `"maker_project_blocks" => ->(u) { project = …; u.maker_project_blocks.create!(project:, kind: "text", body: "x") }` and the `BUILD_ORDER` entry after `maker_connections`.
  - `structural_orphan_test.rb`: `CASES` entries for both edges.
  - Run `bin/rails schema:map` and commit what it writes.
  Run: `bin/rails test test/schema_map_test.rb test/models/tenant_cleanup_test.rb test/models/structural_orphan_test.rb test/models/maker/project_block_test.rb` — green.

- [ ] **Step 5: The layout's failing tests** — append to `test/services/maker/project_kind_test.rb`:

```ruby
    # --- blocks (2026-09-09, content blocks; spec §4) --------------------------------------------

    BLOCKS = [ [ "aaaaaaaaaaaa", "text" ], [ "bbbbbbbbbbbb", "link" ] ].freeze
    def bkey(id) = Maker::ProjectKind.block_key(id)

    test "block keys join the vocabulary, a block the stored order does not name lands FIRST, and kinds are kept" do
      layout = Maker::ProjectKind.layout_for(kind: "other", overrides: nil, folders: FOLDERS, blocks: BLOCKS)
      assert_equal [ bkey("aaaaaaaaaaaa"), bkey("bbbbbbbbbbbb"), "attachments" ], layout.order.first(3)
      assert layout.block?(bkey("aaaaaaaaaaaa"))
      refute layout.block?("attachments")
      assert_equal "text", layout.block_kind(bkey("aaaaaaaaaaaa"))
      assert_nil layout.block_kind("tasks")

      stored = [ "attachments", bkey("bbbbbbbbbbbb"), "photos" ]
      layout = Maker::ProjectKind.layout_for(kind: "other", overrides: { "order" => stored }, folders: FOLDERS, blocks: BLOCKS)
      assert_equal bkey("aaaaaaaaaaaa"), layout.order.first, "the unnamed block goes first"
      assert_equal [ "attachments", key(FIRMWARE), key(MODELS), bkey("bbbbbbbbbbbb"), "photos" ], layout.order[1, 5],
                   "the named block keeps its stored place; folders splice after Files as before"
    end

    test "a block key whose row is gone drops out of every map, and default widths follow the kind" do
      gone = bkey("cccccccccccc")
      layout = Maker::ProjectKind.layout_for(kind: "other",
                                             overrides: { "order" => [ gone, "attachments" ], "hidden" => [ gone ], "widths" => { gone => "half" } },
                                             folders: FOLDERS, blocks: BLOCKS)
      refute_includes layout.order, gone
      refute_includes layout.hidden, gone
      refute layout.widths.key?(gone)
      assert_equal "full", layout.width_for(bkey("aaaaaaaaaaaa")), "text defaults to full"
      assert_equal "half", layout.width_for(bkey("bbbbbbbbbbbb")), "link defaults to half"
      assert_equal "full", Maker::ProjectKind.default_width(bkey("x"), block_kind: "image")
      assert_equal [], Maker::ProjectKind.offered_views(bkey("aaaaaaaaaaaa"))
      assert layout.hidden?(bkey("aaaaaaaaaaaa")) == false
    end

    test "a block can be hidden and sized like a panel, and blocks default to an empty list" do
      layout = Maker::ProjectKind.layout_for(kind: "other",
                                             overrides: { "hidden" => [ bkey("aaaaaaaaaaaa") ], "widths" => { bkey("aaaaaaaaaaaa") => "half" } },
                                             folders: FOLDERS, blocks: BLOCKS)
      assert layout.hidden?(bkey("aaaaaaaaaaaa"))
      assert_equal "half", layout.width_for(bkey("aaaaaaaaaaaa"))
      assert_equal({}, Maker::ProjectKind.layout_for(kind: "other", overrides: nil).block_kinds)
    end
```
Run to see them fail (`unknown keyword: :blocks`).

- [ ] **Step 6: The layout** — in `app/services/maker/project_kind.rb`:

After `FOLDER_PREFIX = "folder:".freeze` add:
```ruby
    # `block:<key>` — a content block (2026-09-09, content blocks; spec §4). The key is the row's own
    # twelve-hex `key`, minted by Maker::ProjectBlock, never its id.
    BLOCK_PREFIX = "block:".freeze
    BLOCK_DEFAULT_WIDTHS = { "text" => "full", "link" => "half", "image" => "full" }.freeze
```
Change the struct to `Layout = Data.define(:order, :hidden, :views, :widths, :titles, :intros, :repo_ids, :block_kinds) do` and add inside it:
```ruby
      def block?(key) = key.to_s.start_with?(BLOCK_PREFIX)
      # The kind of a block key, nil for anything else — what `width_for` and the strip ask.
      def block_kind(key) = block_kinds[key.to_s]
```
and change `width_for` to `def width_for(key) = widths[key.to_s] || ProjectKind.default_width(key, block_kind: block_kinds[key.to_s])`.
Add `def self.block_key(key) = "#{BLOCK_PREFIX}#{key}"` beside `folder_key`. Change `default_width`:
```ruby
    def self.default_width(key, block_kind: nil)
      k = key.to_s
      return BLOCK_DEFAULT_WIDTHS.fetch(block_kind.to_s, "full") if k.start_with?(BLOCK_PREFIX)

      k.start_with?(FOLDER_PREFIX) || FULL_BY_DEFAULT.include?(k) ? "full" : "half"
    end
```
Change `layout_for`'s signature to `def self.layout_for(kind:, overrides:, folders: [], blocks: [])` and its body:
```ruby
      preset = PRESETS.fetch(kind.to_s, PRESETS.fetch(DEFAULT))
      over = overrides.is_a?(Hash) ? overrides : {}
      folder_keys = Array(folders).map { |id, _repo| folder_key(id) }
      repo_ids = Array(folders).filter_map { |id, repo| id.to_s if repo }
      block_keys = Array(blocks).map { |k, _kind| block_key(k) }
      block_kinds = Array(blocks).to_h { |k, kind| [ block_key(k), kind.to_s ] }
      vocabulary = Maker::Project::PANELS + folder_keys + block_keys

      order = stored_order(known(over["order"], vocabulary), folder_keys) + preset_order(preset, folder_keys)
      # A BLOCK THE STORED ORDER DOES NOT NAME LANDS FIRST (content blocks, spec §4): it is what
      # "Add block" did a moment ago, and first is where the editor puts a new one.
      order = (block_keys - order) + order
      hidden = (over.key?("hidden") ? known(over["hidden"], vocabulary) : preset[:hidden]) - ALWAYS
      ordered = ((order & vocabulary) - %w[publish]) + %w[publish]
      Layout.new(order: ordered, hidden:, views: stored_views(over["views"], vocabulary),
                 widths: stored_widths(over["widths"], vocabulary),
                 titles: stored_text(over["titles"], vocabulary, TITLE_MAX),
                 intros: stored_text(over["intros"], vocabulary, INTRO_MAX),
                 repo_ids:, block_kinds:)
```
(keep the existing PUBLISH comment above `ordered`). Add a header bullet: `* A BLOCK (`block:<key>`) IS THE THIRD KIND OF KEY (2026-09-09, content blocks): the caller supplies `blocks:` as [key, kind] pairs the way it supplies `folders:`; an unnamed block lands first; a key whose row is gone drops out.`

- [ ] **Step 7: Run and mutation-check**

```bash
bin/rails test test/services/maker/project_kind_test.rb test/models/maker/project_test.rb test/services/maker/public_project_test.rb test/services/maker/layout_document_test.rb
```
Expected: green (`layout_document_test.rb` still passes — its layouts have no blocks). Mutations (restore with Edit, clear `tmp/cache/bootsnap*`): (1) in `layout_for` delete `order = (block_keys - order) + order` → the first block test red; (2) in `default_width` swap `"full"` fallback for `"half"` and change `BLOCK_DEFAULT_WIDTHS["text"]` to `"half"` → the widths test red; (3) in `fields_match_kind` delete the `when "link"` URL check → the URL test red.

- [ ] **Step 8: Commit**
```
git add db/migrate/20260909200000_create_maker_project_blocks.rb db/schema.rb app/models/maker/project_block.rb app/models/maker/project.rb app/models/user.rb lib/schema_map.rb app/services/maker/project_kind.rb test/models/maker/project_block_test.rb test/services/maker/project_kind_test.rb test/models/tenant_cleanup_test.rb test/models/structural_orphan_test.rb <schema:map output>
```
Message: "Content blocks have a table and a place in the layout's vocabulary" with the body per the repo's style.

---

### Task B: the document learns blocks, images and the page

**Files:**
- Modify: `app/services/maker/layout_document.rb`, `test/services/maker/layout_document_test.rb`

- [ ] **Step 1: The failing tests** — add to `layout_document_test.rb` (inside the class; extend the helpers):

```ruby
    # --- blocks and the page (2026-09-09, content blocks; spec §5) -------------------------------

    BlockRow = Struct.new(:key, :kind, :heading, :body, :url, :line, :caption, :node_id, keyword_init: true)
    IMG_SIDE = "n-side".freeze
    IMG_FRONT = "n-front".freeze
    IMAGES = { IMG_SIDE => "photos/side.jpg", IMG_FRONT => "photos/lamp-front.jpg" }.freeze

    def rows
      [ BlockRow.new(key: "aaaaaaaaaaaa", kind: "text", heading: "Why a printed shade", body: "A paper shade yellows.\n\n- two walls"),
        BlockRow.new(key: "bbbbbbbbbbbb", kind: "link", heading: "Printables page", url: "https://www.printables.com/model/1", line: "Sliced files."),
        BlockRow.new(key: "cccccccccccc", kind: "image", node_id: IMG_SIDE, caption: "Side on.") ]
    end

    def bkey(id) = Maker::ProjectKind.block_key(id)

    def blocks_layout(overrides = nil)
      Maker::ProjectKind.layout_for(kind: "other", overrides:, folders: FOLDERS, blocks: rows.map { |r| [ r.key, r.kind ] })
    end

    def bdoc(overrides = nil, page: { "description" => "A desk lamp.", "cover" => IMG_FRONT })
      Maker::LayoutDocument.new(blocks_layout(overrides), NAMES, blocks: rows, images: IMAGES, page:)
    end

    test "the draft carries the page and each block's content, with a link's title and an image's file" do
      d = bdoc.draft
      assert_equal({ "description" => "A desk lamp.", "cover" => IMG_FRONT }, d["page"])
      text = d["panels"].find { |e| e["key"] == bkey("aaaaaaaaaaaa") }
      assert_equal({ "key" => bkey("aaaaaaaaaaaa"), "kind" => "text", "hidden" => false, "width" => "full",
                     "heading" => "Why a printed shade", "body" => "A paper shade yellows.\n\n- two walls" }, text)
      link = d["panels"].find { |e| e["key"] == bkey("bbbbbbbbbbbb") }
      assert_equal "Printables page", link["title"]
      assert_equal "https://www.printables.com/model/1", link["url"]
      assert_equal "half", link["width"]
      image = d["panels"].find { |e| e["key"] == bkey("cccccccccccc") }
      assert_equal IMG_SIDE, image["file"]
      assert_equal "Side on.", image["caption"]
      refute d["panels"].find { |e| e["key"] == "attachments" }.key?("kind")
    end

    test "to_yaml writes page and blocks with ids and paths, and a cover outside the folder becomes a comment" do
      text = bdoc.to_yaml(project_name: "Lamp")
      assert_includes text, "page:\n  description: A desk lamp.\n  cover: photos/lamp-front.jpg\n"
      assert_includes text, "- block: text\n  id: aaaaaaaaaaaa\n  heading: Why a printed shade\n  body: |-\n    A paper shade yellows.\n\n    - two walls\n  width: full\n"
      assert_includes text, "- block: link\n  id: bbbbbbbbbbbb\n  url: https://www.printables.com/model/1\n  title: Printables page\n  line: Sliced files.\n  width: half\n"
      assert_includes text, "- block: image\n  id: cccccccccccc\n  file: photos/side.jpg\n  caption: Side on.\n  width: full\n"
      refute_includes text, IMG_SIDE

      outside = bdoc(page: { "description" => nil, "cover" => "n-elsewhere" }).to_yaml(project_name: "Lamp")
      assert_includes outside, "# cover: set from a file outside the project folder; the picker cannot name it\n"
      refute_includes outside, "cover:"
      refute_includes outside, "description:"
    end

    test "export then parse is the identity with blocks and page" do
      d = bdoc({ "hidden" => [ bkey("bbbbbbbbbbbb") ], "widths" => { bkey("aaaaaaaaaaaa") => "half" } })
      result = d.parse(d.to_yaml(project_name: "Lamp"))
      assert result.ok?, result.errors.inspect
      assert_equal [], result.notes
      assert_equal d.draft, result.draft
    end

    test "parse: a known id updates, an unknown or missing id creates, unmentioned blocks keep their place" do
      yaml = <<~YAML
        layout: 1
        panels:
          - block: text
            id: aaaaaaaaaaaa
            heading: New heading
          - block: link
            id: zzzzzzzzzzzz
            url: https://example.com/x
            title: Elsewhere
          - block: image
            file: photos/lamp-front.jpg
            caption: Front.
      YAML
      result = bdoc.parse(yaml)
      assert result.ok?, result.errors.inspect
      updated = entry(result, bkey("aaaaaaaaaaaa"))
      assert_equal "New heading", updated["heading"]
      assert_equal "A paper shade yellows.\n\n- two walls", updated["body"], "an absent attribute keeps the block's body"
      new_link = result.draft["panels"].find { |e| e["kind"] == "link" && e["key"] != bkey("bbbbbbbbbbbb") }
      assert_match(/\Ablock:new-\d+\z/, new_link["key"])
      assert_equal "Elsewhere", new_link["title"]
      new_image = result.draft["panels"].find { |e| e["kind"] == "image" && e["file"] == IMG_FRONT }
      assert_match(/\Ablock:new-\d+\z/, new_image["key"])
      assert_equal "Front.", new_image["caption"]
      assert_includes result.draft["panels"].map { |e| e["key"] }, bkey("bbbbbbbbbbbb"), "the unmentioned link keeps its place"
      assert_equal 3 + 2, result.draft["panels"].count { |e| e["kind"] }
    end

    test "parse: new keys do not collide with the base draft's own new blocks" do
      base = bdoc.from_draft("layout" => 1, "panels" => [ { "key" => "block:new-1", "kind" => "text", "body" => "unsaved", "hidden" => false, "width" => "full" } ]).draft
      result = bdoc.parse("layout: 1\npanels:\n  - block: text\n    body: pasted\n", base: base)
      assert result.ok?, result.errors.inspect
      keys = result.draft["panels"].map { |e| e["key"] }
      assert_includes keys, "block:new-1"
      assert_includes keys, "block:new-2"
    end

    test "parse: the page section replaces what is given, keeps what is absent, and notes a cover it cannot find" do
      result = bdoc.parse("layout: 1\npage:\n  description: Rewritten.\npanels: []\n")
      assert result.ok?
      assert_equal({ "description" => "Rewritten.", "cover" => IMG_FRONT }, result.draft["page"])

      result = bdoc.parse("layout: 1\npage:\n  cover: photos/nope.jpg\npanels: []\n")
      assert result.ok?
      assert_equal IMG_FRONT, result.draft["page"]["cover"]
      assert_equal [ "No image at “photos/nope.jpg” in the project folder; the cover was left as it is." ], result.notes

      result = bdoc.parse("layout: 1\npage:\n  cover: ~\npanels: []\n")
      assert result.ok?
      assert_nil result.draft["page"]["cover"], "an explicit null clears the cover"
    end

    test "parse: block errors name their entry and block Apply" do
      cases = {
        "layout: 1\npanels:\n  - block: video\n    url: https://x\n"                    => /Entry 1: unknown block kind “video”/,
        "layout: 1\npanels:\n  - block: link\n    title: t\n    url: ftp://x\n"             => /Entry 1: url must be an http or https URL/,
        "layout: 1\npanels:\n  - block: link\n    url: https://x.example\n"                 => /Entry 1: a link needs a title/,
        "layout: 1\npanels:\n  - block: image\n    file: photos/nope.jpg\n"                => /Entry 1: no image at “photos\/nope.jpg”/,
        "layout: 1\npanels:\n  - block: text\n    heading: #{'x' * 81}\n"                  => /Entry 1: the heading is over 80 characters/,
        "layout: 1\npanels:\n  - block: text\n    body: #{'x' * (20 * 1024 + 1)}\n"        => /Entry 1: the body is over 20 KB/,
        "layout: 1\npanels:\n  - block: text\n    view: list\n"                            => /Entry 1: unknown attribute “view”/,
        "layout: 1\npanels:\n  - block: text\n    body: x\n    panel: tasks\n"             => /Entry 1 names more than one of `panel`, `folder` and `block`/,
        "layout: 1\npanels:\n  - block: text\n"                                             => /Entry 1: a text block needs a heading or a body/,
        "layout: 1\npage: nope\npanels: []\n"                                              => /`page` must be a mapping/,
        "layout: 1\npage:\n  look: dark\npanels: []\n"                                     => /Unknown key “look” under `page`/
      }
      cases.each do |text, message|
        result = bdoc.parse(text)
        refute result.ok?, "expected an error for #{text.inspect[0, 60]}"
        assert_match message, result.errors.join(" "), text.inspect[0, 60]
      end
    end

    test "parse: an existing image block whose file is not in the folder is a note, not an error" do
      result = bdoc.parse("layout: 1\npanels:\n  - block: image\n    id: cccccccccccc\n    file: photos/nope.jpg\n")
      assert result.ok?
      assert_equal IMG_SIDE, entry(result, bkey("cccccccccccc"))["file"]
      assert_equal [ "No image at “photos/nope.jpg” in the project folder; the block keeps its picture." ], result.notes
    end

    test "the cap: a text that would leave more than CAP blocks is an error" do
      many = (1..38).map { |i| "  - block: text\n    body: b#{i}\n" }.join
      result = bdoc.parse("layout: 1\npanels:\n#{many}")
      refute result.ok?
      assert_match(/more than #{Maker::ProjectBlock::CAP} blocks/, result.errors.join(" "))
    end

    test "from_draft accepts new-keyed blocks and validates them like YAML" do
      result = bdoc.from_draft("layout" => 1, "page" => { "description" => " Two  lines\nhere ", "cover" => nil },
                               "panels" => [ { "key" => "block:new-1", "kind" => "link", "url" => "https://a.example", "title" => "A", "hidden" => false, "width" => "half" } ])
      assert result.ok?, result.errors.inspect
      assert_equal "Two  lines\nhere", result.draft["page"]["description"], "stripped, never collapsed: a description keeps its lines"
      assert_nil result.draft["page"]["cover"]
      assert_equal "A", entry(result, "block:new-1")["title"]

      bad = bdoc.from_draft("layout" => 1, "panels" => [ { "key" => "block:new-1", "kind" => "link", "url" => "javascript:x", "title" => "A" } ])
      refute bad.ok?
      unknown = bdoc.from_draft("layout" => 1, "panels" => [ { "key" => "block:dddddddddddd", "kind" => "text", "body" => "x" } ])
      refute unknown.ok?, "a block key that is neither new nor a row of this project is refused"
    end

    test "blocks_from and page_from hand Save what it writes" do
      result = bdoc.parse(<<~YAML)
        layout: 1
        page:
          description: Rewritten.
          cover: photos/side.jpg
        panels:
          - block: link
            url: https://a.example
            title: A
            line: one
          - block: text
            id: aaaaaaaaaaaa
            body: changed
      YAML
      assert result.ok?, result.errors.inspect
      blocks = bdoc.blocks_from(result.draft)
      assert_equal 4, blocks.size
      new_link = blocks.find { |b| b["key"].start_with?("block:new-") }
      assert_equal({ "kind" => "link", "heading" => "A", "url" => "https://a.example", "line" => "one", "body" => nil, "caption" => nil, "node_id" => nil },
                   new_link.except("key"))
      assert_equal "changed", blocks.find { |b| b["key"] == bkey("aaaaaaaaaaaa") }["body"]
      assert_equal({ "description" => "Rewritten.", "cover_node_id" => IMG_SIDE }, bdoc.page_from(result.draft))
      assert_nil bdoc.page_from("layout" => 1, "panels" => []), "no page section, nothing to write"
    end

    test "the six-map column still ignores block content and keeps block keys in order, hidden and widths" do
      d = bdoc({ "hidden" => [ bkey("aaaaaaaaaaaa") ] })
      column = d.column(d.draft)
      assert_includes column["order"], bkey("aaaaaaaaaaaa")
      assert_equal [ bkey("aaaaaaaaaaaa") ], column["hidden"]
      assert_equal "half", column["widths"][bkey("bbbbbbbbbbbb")]
      refute column.key?("blocks")
    end
```

- [ ] **Step 2: Run to see them fail** — `unknown keyword: :blocks` on the constructor.

- [ ] **Step 3: Implement** — changes to `app/services/maker/layout_document.rb`:

Constants and constructor:
```ruby
    ATTRIBUTES = %w[title intro width view hidden].freeze
    BLOCK_COMMON = %w[width hidden].freeze
    BLOCK_FIELDS = { "text" => %w[heading body], "link" => %w[url title line], "image" => %w[file caption] }.freeze
    PAGE_KEYS = %w[description cover].freeze
    COVER_OUTSIDE_NOTE = "# cover: set from a file outside the project folder; the picker cannot name it".freeze

    # blocks: the project's Maker::ProjectBlock rows (anything answering key/kind/heading/body/url/
    # line/caption/node_id); images: { node_id => path relative to the project folder } for the
    # folder's image files — what an image block or the cover may name; page: the description and
    # the cover node id as the row holds them.
    def initialize(layout, folder_names, blocks: [], images: {}, page: {})
      @layout = layout
      @names = folder_names.to_h { |id, name| [ id.to_s, name.to_s ] }
      @blocks = blocks.to_h { |b| [ Maker::ProjectKind.block_key(b.key), b ] }
      @images = images.to_h { |id, path| [ id.to_s, path.to_s ] }
      @paths = @images.invert
      @page = { "description" => page["description"].presence, "cover" => page["cover"].presence }
    end
```
Draft:
```ruby
    def draft
      { "layout" => VERSION, "page" => @page.dup, "panels" => @layout.order.map { |key| entry(key) } }
    end

    def entry(key)
      e = { "key" => key, "hidden" => @layout.hidden?(key), "width" => @layout.width_for(key) }
      if @layout.block?(key)
        row = @blocks[key]
        e["kind"] = @layout.block_kind(key)
        case e["kind"]
        when "text"
          e["heading"] = row.heading if row&.heading.present?
          e["body"] = row.body if row&.body.present?
        when "link"
          e["url"] = row&.url
          e["title"] = row&.heading
          e["line"] = row.line if row&.line.present?
        when "image"
          e["file"] = row&.node_id
          e["caption"] = row.caption if row&.caption.present?
        end
        return e.compact
      end
      e["view"] = @layout.view_for(key) if Maker::ProjectKind.offered_views(key).any?
      e["title"] = @layout.titles[key] if @layout.titles[key]
      e["intro"] = @layout.intros[key] if @layout.intros[key]
      e
    end
```
Export — replace `to_yaml`:
```ruby
    def to_yaml(draft = self.draft, project_name:)
      panels = draft["panels"].filter_map do |e|
        out = {}
        if e["kind"]
          out["block"] = e["kind"]
          out["id"] = e["key"].delete_prefix(Maker::ProjectKind::BLOCK_PREFIX) unless new_key?(e["key"])
          case e["kind"]
          when "text"
            out["heading"] = e["heading"] if e["heading"]
            out["body"] = e["body"] if e["body"]
          when "link"
            out["url"] = e["url"]
            out["title"] = e["title"]
            out["line"] = e["line"] if e["line"]
          when "image"
            path = @images[e["file"].to_s]
            next unless path

            out["file"] = path
            out["caption"] = e["caption"] if e["caption"]
          end
        elsif @layout.folder?(e["key"])
          name = @names[@layout.folder_id(e["key"])]
          next unless name

          out["folder"] = name
        else
          out["panel"] = e["key"]
        end
        unless e["kind"]
          out["title"] = e["title"] if e["title"]
          out["intro"] = e["intro"] if e["intro"]
        end
        out["width"] = e["width"]
        out["view"] = e["view"] if e["view"]
        out["hidden"] = true if e["hidden"]
        out
      end
      page = {}
      page["description"] = draft.dig("page", "description") if draft.dig("page", "description").present?
      cover = draft.dig("page", "cover")
      cover_path = cover && @images[cover.to_s]
      page["cover"] = cover_path if cover_path
      doc = { "layout" => VERSION }
      doc["page"] = page if page.any?
      doc["panels"] = panels
      body = Psych.dump(doc, line_width: -1).delete_prefix("---\n")
      header = "# #{project_name.to_s.gsub(/\s+/, ' ').strip}, page layout. Paste into another project's editor to reuse it.\n"
      header += "#{COVER_OUTSIDE_NOTE}\n" if cover && !cover_path
      header + body
    end
```
(Keep the totality comment beside the folder branch.) Parse — the top-level checks become:
```ruby
      unknown = data.keys.map(&:to_s) - %w[layout page panels]
      return failure("Unknown key “#{unknown.first}” at the top level.") if unknown.any?
      return failure("`panels` must be a list.") unless data["panels"].is_a?(Array)
      if data.key?("page") && !data["page"].is_a?(Hash)
        return failure("`page` must be a mapping with `description` and `cover`.")
      end

      merge(data["panels"], :yaml, base, page: data["page"])
```
`from_draft` becomes `merge(hash["panels"], :draft, nil, page: hash["page"])` after also refusing a non-Hash `page` (`return failure("Not a layout draft.") if hash.key?("page") && !hash["page"].is_a?(Hash)`).

The merge — replace the method:
```ruby
    def merge(raw_entries, source, base = nil, page: nil)
      notes, errors = [], []
      base_draft = base || draft
      current = base_draft["panels"].to_h { |e| [ e["key"], e ] }
      listed = []
      next_new = next_new_index(current.keys)

      raw_entries.each_with_index do |raw, i|
        n = i + 1
        unless raw.is_a?(Hash)
          errors << "Entry #{n} is not a mapping."
          next
        end
        raw = raw.to_h { |k, v| [ k.to_s, v ] }
        key, kind = source == :yaml ? key_from_yaml(raw, n, notes, errors, current, -> { next_new += 1; next_new }) : key_from_draft(raw, n, notes, errors)
        next unless key

        if listed.any? { |k, _| k == key }
          errors << "Entry #{n} names #{label(key)} a second time."
          next
        end
        base_entry = current[key] || { "key" => key, "kind" => kind, "hidden" => false, "width" => Maker::ProjectKind.default_width(key, block_kind: kind) }
        if kind
          allowed = (source == :yaml ? %w[block id] : %w[key kind]) + BLOCK_COMMON + BLOCK_FIELDS.fetch(kind)
          unknown = raw.keys - allowed
          errors << "Entry #{n}: unknown attribute “#{unknown.first}”." if unknown.any?
          listed << [ key, apply_block(base_entry, raw, kind, n, notes, errors, new_block: current[key].nil?) ]
        else
          unknown = raw.keys - (source == :yaml ? %w[panel folder] : %w[key]) - ATTRIBUTES
          errors << "Entry #{n}: unknown attribute “#{unknown.first}”." if unknown.any?
          listed << [ key, apply(base_entry, raw, key, n, notes, errors) ]
        end
      end
      page_out = merge_page(base_draft["page"], page, notes, errors)
      return Result.new(draft: draft, notes: notes, errors: errors) if errors.any?

      ordered = listed.map(&:last) + (current.keys - listed.map(&:first)).map { |k| current[k] }
      if listed.any? { |k, _| k == "publish" } && ordered.last["key"] != "publish"
        publish = ordered.find { |e| e["key"] == "publish" }
        ordered = (ordered - [ publish ]) + [ publish ]
        notes << "Publish is always last; it was moved to the end."
      end
      if ordered.count { |e| e["kind"] } > Maker::ProjectBlock::CAP
        return Result.new(draft: draft, notes: notes, errors: [ "That would leave more than #{Maker::ProjectBlock::CAP} blocks on the page." ])
      end
      Result.new(draft: { "layout" => VERSION, "page" => page_out, "panels" => ordered }, notes: notes, errors: errors)
    end
```
Key resolution — `key_from_yaml` now returns `[key, kind]` (`kind` nil for panels/folders):
```ruby
    def key_from_yaml(raw, n, notes, errors, current, allocate)
      named = %w[panel folder block].select { |k| raw.key?(k) }
      if named.size > 1
        errors << "Entry #{n} names more than one of `panel`, `folder` and `block`; use one."
        return nil
      end
      if raw.key?("block")
        kind = raw["block"].to_s
        unless Maker::ProjectBlock::KINDS.include?(kind)
          errors << "Entry #{n}: unknown block kind “#{kind}”."
          return nil
        end
        id = raw["id"].to_s
        known = id.present? && current.key?(Maker::ProjectKind.block_key(id)) && current[Maker::ProjectKind.block_key(id)]["kind"] == kind
        return [ known ? Maker::ProjectKind.block_key(id) : Maker::ProjectKind.block_key("new-#{allocate.call}"), kind ]
      end
      if raw.key?("panel")
        key = raw["panel"].to_s
        return [ key, nil ] if Maker::Project::PANELS.include?(key)

        errors << "Entry #{n}: unknown panel “#{key}”."
        return nil
      end
      if raw.key?("folder")
        name = raw["folder"].to_s
        fid = @names.key(name)
        return [ Maker::ProjectKind.folder_key(fid), nil ] if fid && @layout.order.include?(Maker::ProjectKind.folder_key(fid))

        notes << "This project has no folder named “#{name}”; that entry was skipped."
        return nil
      end
      errors << "Entry #{n} names none of `panel`, `folder` or `block`."
      nil
    end

    def key_from_draft(raw, n, notes, errors)
      key = raw["key"].to_s
      if @layout.block?(key) || new_key?(key)
        kind = raw["kind"].to_s
        unless Maker::ProjectBlock::KINDS.include?(kind)
          errors << "Entry #{n}: unknown block kind “#{kind}”."
          return nil
        end
        return [ key, kind ] if new_key?(key) || @layout.block_kind(key) == kind

        errors << "Entry #{n}: unknown panel “#{key}”."
        return nil
      end
      return [ key, nil ] if @layout.order.include?(key)

      if @layout.folder?(key)
        notes << "A folder changed on disk while you were editing; its panel keeps its defaults."
      else
        errors << "Entry #{n}: unknown panel “#{key}”."
      end
      nil
    end

    def new_key?(key) = key.to_s.start_with?("#{Maker::ProjectKind::BLOCK_PREFIX}new-")

    def next_new_index(keys)
      keys.filter_map { |k| k[/\Ablock:new-(\d+)\z/, 1]&.to_i }.max || 0
    end
```
Block attributes:
```ruby
    def apply_block(base, raw, kind, n, notes, errors, new_block:)
      e = base.dup
      e["kind"] = kind
      if raw.key?("width")
        width = raw["width"].to_s
        if Maker::ProjectKind::WIDTHS.include?(width)
          e["width"] = width
        else
          errors << "Entry #{n}: width must be full or half."
        end
      end
      if raw.key?("hidden")
        if [ true, false ].include?(raw["hidden"])
          e["hidden"] = raw["hidden"]
        else
          errors << "Entry #{n}: hidden must be true or false."
        end
      end
      case kind
      when "text"
        set_text(e, raw, "heading", Maker::ProjectBlock::HEADING_MAX, n, errors, "the heading")
        if raw.key?("body")
          body = raw["body"].to_s.strip
          errors << "Entry #{n}: the body is over #{Maker::ProjectBlock::BODY_MAX / 1024} KB." if body.bytesize > Maker::ProjectBlock::BODY_MAX
          body.empty? ? e.delete("body") : e["body"] = body
        end
        errors << "Entry #{n}: a text block needs a heading or a body." if e["heading"].blank? && e["body"].blank?
      when "link"
        if raw.key?("url")
          url = text(raw["url"])
          if url.match?(Maker::ProjectBlock::URL_FORMAT)
            e["url"] = url
          else
            errors << "Entry #{n}: url must be an http or https URL."
          end
        end
        set_text(e, raw, "title", Maker::ProjectBlock::HEADING_MAX, n, errors, "the title")
        set_text(e, raw, "line", Maker::ProjectBlock::LINE_MAX, n, errors, "the line")
        errors << "Entry #{n}: url must be an http or https URL." if e["url"].blank? && !raw.key?("url")
        errors << "Entry #{n}: a link needs a title." if e["title"].blank?
      when "image"
        if raw.key?("file")
          given = raw["file"].to_s
          node_id = @images.key?(given) ? given : @paths[given]
          if node_id
            e["file"] = node_id
          elsif new_block
            errors << "Entry #{n}: no image at “#{given}” in the project folder."
          else
            notes << "No image at “#{given}” in the project folder; the block keeps its picture."
          end
        end
        set_text(e, raw, "caption", Maker::ProjectBlock::LINE_MAX, n, errors, "the caption")
        errors << "Entry #{n}: an image block needs a file." if e["file"].blank?
      end
      e
    end

    def set_text(e, raw, field, max, n, errors, name)
      return unless raw.key?(field)

      value = text(raw[field])
      errors << "Entry #{n}: #{name} is over #{max} characters." if value.length > max
      value.empty? ? e.delete(field) : e[field] = value
    end
```
In the draft source `file` arrives as a node id: `@images.key?(given)` accepts it; in YAML it arrives as a path: `@paths[given]` resolves it. Both are one line. The `url` guard after the `if raw.key?("url")` block covers a NEW link with no `url:` at all (the in-block branch covers a bad one).

The page:
```ruby
    def merge_page(base_page, raw, notes, errors)
      out = (base_page || @page).dup
      return out if raw.nil?
      raw = raw.to_h { |k, v| [ k.to_s, v ] }
      unknown = raw.keys - PAGE_KEYS
      errors << "Unknown key “#{unknown.first}” under `page`." if unknown.any?
      # STRIPPED, NOT COLLAPSED: the description keeps its line breaks (the page renders it pre-wrap).
      out["description"] = raw["description"].to_s.strip.presence if raw.key?("description")
      if raw.key?("cover")
        given = raw["cover"]
        if given.nil? || given.to_s.empty?
          out["cover"] = nil
        else
          node_id = @images.key?(given.to_s) ? given.to_s : @paths[given.to_s]
          if node_id
            out["cover"] = node_id
          else
            notes << "No image at “#{given}” in the project folder; the cover was left as it is."
          end
        end
      end
      out
    end
```
The description is stripped, never collapsed: the page renders it `pre-wrap`, so its line breaks are content.

The outputs:
```ruby
    def blocks_from(draft)
      draft["panels"].select { |e| e["kind"] }.map do |e|
        { "key" => e["key"], "kind" => e["kind"],
          "heading" => e["kind"] == "link" ? e["title"] : e["heading"],
          "body" => e["body"], "url" => e["url"], "line" => e["line"], "caption" => e["caption"], "node_id" => e["file"] }
      end
    end

    def page_from(draft)
      return nil unless draft["page"].is_a?(Hash)

      { "description" => draft["page"]["description"].presence, "cover_node_id" => draft["page"]["cover"].presence }
    end
```
`label(key)` gains a block arm: `return "the #{@layout.block_kind(key) || 'new'} block" if @layout.block?(key) || new_key?(key)`.
Update the class header: three kinds of entry; `page`; ids; Save's three outputs.

- [ ] **Step 4: Run green; fix the test's exact YAML strings to what Psych emits if they differ** (`body: |-` for a multi-line scalar without a trailing newline is Psych's spelling; report the actual output if not). Then run `test/services/maker/project_kind_test.rb` and slice 1's request tests that build documents:
```bash
bin/rails test test/services/maker/layout_document_test.rb test/integration/web/project_layout_editor_test.rb test/integration/web/project_panels_test.rb
```
(The controllers still call `LayoutDocument.new(layout, names)` — the new keyword arguments default, so they stay green.)

- [ ] **Step 5: Mutation-check** — (1) in `key_from_yaml`, make an unknown id an error instead of a new key → the "known id updates, unknown creates" test red; (2) in `merge`, delete the CAP check → the cap test red; (3) in `apply_block`'s image arm, treat a missing file as a note for a new block too → the error-cases test red on `photos/nope.jpg`; (4) in `to_yaml`, write `e["file"]` (the node id) instead of the path → the export test red (`refute_includes text, IMG_SIDE`); (5) in `merge_page`, drop the `given.nil?` arm → the explicit-null test red.

- [ ] **Step 6: Commit** — "Maker::LayoutDocument carries blocks, images and the page: ids match, unknown ids create, paths name pictures".

---

### Task C: the doors, both pages, and the editor's markup

**Files:**
- Modify: `config/routes.rb`, `app/controllers/concerns/projects/layout_scoped.rb`, `app/controllers/projects/layouts_controller.rb`, `app/controllers/projects/panels_controller.rb`, `app/controllers/projects_controller.rb`, `app/services/maker/public_project.rb`, `app/helpers/projects_helper.rb`
- Modify: `app/views/projects/show.html.erb`, `_panel_body.html.erb`, `_panel_slot.html.erb`, `_panel_strip.html.erb`, `_layout_bar.html.erb`; create `_block_panel.html.erb`, `_block_editor.html.erb`, `_block_templates.html.erb`, `_page_intro.html.erb`
- Modify: `app/views/public/projects/_page.html.erb`; create `app/views/public/projects/_block_panel.html.erb`
- Test: create `test/integration/web/project_blocks_test.rb`; modify `test/integration/web/project_layout_editor_test.rb`, `public_project_test.rb`, `page_query_budget_test.rb`, `template_hygiene_test.rb`

- [ ] **Step 1: The failing tests** — `test/integration/web/project_blocks_test.rb`:

```ruby
require "test_helper"

module Web
  # CONTENT BLOCKS, SERVER HALF (2026-09-09; spec §5, §6): what both pages render for each kind,
  # what Save writes in one transaction, the preview helper, and the editor's markup. The browser's
  # half is test/system/page_blocks_test.rb.
  class ProjectBlocksTest < ActionDispatch::IntegrationTest
    PASSWORD = "correct horse battery staple".freeze

    setup do
      @user = User.create!(email: "blocks-#{SecureRandom.hex(4)}@example.com", password: PASSWORD, confirmed_at: Time.current)
      post user_session_path, params: { user: { email: @user.email, password: PASSWORD } }
      @project = @user.maker_projects.create!(name: "Desk Lamp", description: "A lamp.")
      @folder = project_folder_rows!(@user, @project)
      @photos = dir!("photos", @folder.node_id)
      @side = file!("side.jpg", @photos.node_id)
      @front = file!("front.png", @photos.node_id)
    end

    def dir!(name, parent) = @user.nodes.create!(node_id: SecureRandom.uuid, name:, kind: "dir", parent_node_id: parent, mtime: 1, size: 0)
    def file!(name, parent) = @user.nodes.create!(node_id: SecureRandom.uuid, name:, kind: "file", parent_node_id: parent, mtime: 1, size: 3)
    def block!(**attrs) = @project.blocks.create!(user: @user, **attrs)
    def bkey(block) = block.layout_key

    # --- rendering ---------------------------------------------------------------------------------

    test "each kind renders in its slot at its default width, Markdown sanitised" do
      text = block!(kind: "text", heading: "Why", body: "A **shade**.\n\n<script>alert(1)</script>\n\n[bom](#bom)")
      link = block!(kind: "link", heading: "Printables", url: "https://www.printables.com/model/1", line: "Sliced.")
      image = block!(kind: "image", node_id: @side.node_id, caption: "Side on.")

      get project_path(@project)

      assert_select "div.panel-slot.panel--full > section.block-panel.block--text[id=?]", bkey(text) do
        assert_select "h2", text: "Why"
        assert_select ".markdown strong", text: "shade"
        assert_select "script", count: 0
      end
      assert_select "div.panel-slot.panel--half > section.block-panel.block--link[id=?]", bkey(link) do
        assert_select "a.block-link-card[href=?][rel=noopener]", "https://www.printables.com/model/1"
        assert_select ".block-link-title", text: "Printables"
        assert_select ".block-link-line", text: "Sliced."
        assert_select ".block-link-host", text: "www.printables.com"
      end
      assert_select "div.panel-slot.panel--full > section.block-panel.block--image[id=?]", bkey(image) do
        assert_select "figure a[href=?] img[src=?]", file_path(@side.node_id), blob_file_path(@side.node_id)
        assert_select "figcaption", text: "Side on."
      end
      assert_select "div.panel-slot[data-key]", count: 0, "no chrome on the normal page"
    end

    test "a hidden block and an image block whose file is gone render no slot" do
      text = block!(kind: "text", body: "x")
      image = block!(kind: "image", node_id: SecureRandom.uuid)
      @project.update!(panels: { "hidden" => [ bkey(text) ] })

      get project_path(@project)
      assert_select "section.block-panel", count: 0
      assert_select "div.panel-slot:has(> section.block-panel)", count: 0
      # every slot holds a panel
      assert_equal css_select("div.project-panels > div.panel-slot").size, css_select("div.project-panels > div.panel-slot > section.panel").size
    end

    test "new blocks render first, in row order, when the layout does not name them" do
      a = block!(kind: "text", body: "a")
      b = block!(kind: "text", body: "b")
      get project_path(@project)
      ids = css_select("div.project-panels > div.panel-slot > section.panel").map { |s| s["id"] }
      assert_equal [ bkey(a), bkey(b), "attachments" ], ids.first(3)
    end

    # --- the edit page -------------------------------------------------------------------------------

    test "the edit page carries the Add block menu, one template per kind, the page intro and each block's editor" do
      text = block!(kind: "text", heading: "Why", body: "Because.")
      link = block!(kind: "link", heading: "P", url: "https://p.example/x", line: "l")
      image = block!(kind: "image", node_id: @side.node_id, caption: "c")

      get edit_layout_project_path(@project)

      assert_select "details.layout-add[data-layout-editor-target=addMenu]" do
        %w[text link image].each { |k| assert_select "button[data-action='layout-editor#addBlock'][data-kind=?]", k, 1 }
      end
      %w[text link image].each do |k|
        assert_select "template[data-layout-editor-target=blockTemplate][data-kind=?]", k, 1
      end
      assert_select "div.page-intro[data-layout-editor-target=page][data-description=?]", "A lamp." do
        assert_select "textarea[data-action='input->layout-editor#description']", text: "A lamp."
        assert_select "button.cover-pick[data-action='layout-editor#pickCover'][data-node-id=?]", @side.node_id, 1
        assert_select "button.cover-pick[data-node-id=?]", @front.node_id, 1
        assert_select "button[data-action='layout-editor#removeCover']", 1
      end
      assert_select "div.panel-slot[data-key=?][data-kind=text][data-heading=Why][data-body=Because.]", bkey(text) do
        assert_select ".panel-strip button[data-action='layout-editor#deleteBlock']", 1
        assert_select ".panel-strip details.panel-strip-edit", count: 0
        assert_select ".panel-strip button[data-action='layout-editor#view']", count: 0
        assert_select "form.block-editor input[data-field=heading][value=Why]", 1
        assert_select "form.block-editor textarea[data-field=body]", text: "Because."
        assert_select "form.block-editor button[data-action='layout-editor#previewMarkdown']", 1
        assert_select "div.block-preview[data-layout-editor-target=preview]", 1
      end
      assert_select "div.panel-slot[data-key=?][data-kind=link][data-url=?][data-link-title=P][data-line=l]", bkey(link), "https://p.example/x" do
        assert_select "form.block-editor input[data-field=url][value=?]", "https://p.example/x"
        assert_select "form.block-editor input[data-field=linkTitle][value=P]", 1
        assert_select "a.block-link-card .block-link-host", text: "p.example"
      end
      assert_select "div.panel-slot[data-key=?][data-kind=image][data-file=?][data-caption=c]", bkey(image), @side.node_id do
        assert_select "button.image-pick[data-action='layout-editor#pickImage'][data-node-id=?].active", @side.node_id, 1
        assert_select "button.image-pick[data-node-id=?]", @front.node_id, 1
        assert_select "form.block-editor input[data-field=caption][value=c]", 1
      end
    end

    test "Add block is disabled at the cap" do
      Maker::ProjectBlock::CAP.times { |i| block!(kind: "text", body: "b#{i}") }
      get edit_layout_project_path(@project)
      assert_select "details.layout-add button[data-action='layout-editor#addBlock'][disabled]", 3
      assert_select "details.layout-add .layout-add-cap", text: /#{Maker::ProjectBlock::CAP} blocks/
    end

    # --- the preview helper -----------------------------------------------------------------------------

    test "preview renders sanitised Markdown for the owner and nobody else" do
      post preview_project_layout_path(@project), params: { markdown: "**b** <img src=x onerror=alert(1)> [a](javascript:x)" }, as: :json
      assert_response :success
      assert_includes response.body, "<strong>b</strong>"
      refute_includes response.body, "onerror"
      refute_includes response.body, "javascript:"

      post preview_project_layout_path(@project), params: { markdown: "x" * (Maker::ProjectBlock::BODY_MAX + 1) }, as: :json
      assert_response :unprocessable_entity

      other = User.create!(email: "o-#{SecureRandom.hex(4)}@example.com", password: PASSWORD, confirmed_at: Time.current)
      theirs = other.maker_projects.create!(name: "Theirs")
      post preview_project_layout_path(theirs), params: { markdown: "x" }, as: :json
      assert_response :not_found
    end

    # --- Save --------------------------------------------------------------------------------------------

    def draft_with(*entries, page: nil)
      base = { layout: 1, panels: entries + [ { key: "attachments", hidden: false, width: "full", view: "tiles" } ] }
      base[:page] = page if page
      base
    end

    test "Save creates, updates and deletes block rows, rewrites new keys into the order, and sets the page" do
      keep = block!(kind: "text", heading: "Keep", body: "old body")
      gone = block!(kind: "link", heading: "Gone", url: "https://g.example")
      draft = draft_with(
        { key: "block:new-1", kind: "link", hidden: false, width: "half", url: "https://p.example/x", title: "P", line: "l" },
        { key: keep.layout_key, kind: "text", hidden: true, width: "half", heading: "Kept", body: "new body" },
        { key: "block:new-2", kind: "image", hidden: false, width: "full", file: @side.node_id, caption: "c" },
        page: { description: "Rewritten.", cover: @front.node_id }
      )

      assert_difference -> { @project.blocks.count }, +1 do
        patch project_panels_path(@project), params: { layout: draft.to_json }
      end
      assert_redirected_to project_path(@project)
      @project.reload
      assert_nil Maker::ProjectBlock.find_by(id: gone.id), "a block absent from the draft is destroyed"
      keep.reload
      assert_equal [ "Kept", "new body" ], [ keep.heading, keep.body ]
      new_link = @project.blocks.find_by(kind: "link")
      assert_equal [ "P", "https://p.example/x", "l" ], [ new_link.heading, new_link.url, new_link.line ]
      new_image = @project.blocks.find_by(kind: "image")
      assert_equal [ @side.node_id, "c" ], [ new_image.node_id, new_image.caption ]
      order = @project.panels["order"]
      assert_equal [ new_link.layout_key, keep.layout_key, new_image.layout_key, "attachments" ], order.first(4)
      refute order.any? { |k| k.include?("new-") }, "no placeholder key survives Save"
      assert_equal [ keep.layout_key ], @project.panels["hidden"]
      assert_equal "half", @project.panels["widths"][new_link.layout_key]
      assert_equal "Rewritten.", @project.description
      assert_equal @front.node_id, @project.cover_node_id
    end

    test "a bad block in the draft writes nothing at all" do
      keep = block!(kind: "text", body: "old")
      draft = draft_with(
        { key: keep.layout_key, kind: "text", hidden: false, width: "full", body: "changed" },
        { key: "block:new-1", kind: "link", hidden: false, width: "half", url: "javascript:x", title: "bad" },
        page: { description: "Changed.", cover: nil }
      )
      assert_no_difference -> { @project.blocks.count } do
        patch project_panels_path(@project), params: { layout: draft.to_json }
      end
      assert_redirected_to edit_layout_project_path(@project)
      assert_match(/not saved/, flash[:alert])
      assert_equal "old", keep.reload.body
      assert_equal "A lamp.", @project.reload.description
    end

    test "a draft without a page section leaves the description and cover alone, and Reset leaves blocks alone" do
      block!(kind: "text", body: "x")
      @project.update!(cover_node_id: @front.node_id)
      patch project_panels_path(@project), params: { layout: draft_with.to_json }
      assert_equal [ "A lamp.", @front.node_id ], [ @project.reload.description, @project.cover_node_id ]

      delete project_panels_path(@project)
      assert_equal 1, @project.blocks.count
      assert_equal "A lamp.", @project.reload.description
    end

    test "Save refuses a draft over the cap" do
      Maker::ProjectBlock::CAP.times { |i| block!(kind: "text", body: "b#{i}") }
      entries = @project.blocks.map { |b| { key: b.layout_key, kind: "text", hidden: false, width: "full", body: b.body } }
      entries << { key: "block:new-1", kind: "text", hidden: false, width: "full", body: "one more" }
      patch project_panels_path(@project), params: { layout: draft_with(*entries).to_json }
      assert_redirected_to edit_layout_project_path(@project)
      assert_equal Maker::ProjectBlock::CAP, @project.blocks.count
    end
  end
end
```

Add to `public_project_test.rb` (its own project like Task E's public test in slice 1 — read `seed_public_project!`/`make_project_folder!`/`make_file!` first):
```ruby
    test "a visitor sees text and link blocks, an image block only when its file is public, and never a hidden one" do
      project = @user.maker_projects.create!(name: "Blocks Rig", visibility: "public")
      folder = make_project_folder!(@user, project)
      photos = make_dir!(@user, "photos", folder)
      side = make_file!(@user, "side.jpg", photos, body: "x")
      secret = make_dir!(@user, "secret", folder)
      hidden_img = make_file!(@user, "hidden.jpg", secret, body: "x")
      text = project.blocks.create!(user: @user, kind: "text", heading: "Why", body: "**shade**")
      link = project.blocks.create!(user: @user, kind: "link", heading: "P", url: "https://p.example", line: "l")
      shown = project.blocks.create!(user: @user, kind: "image", node_id: side.node_id, caption: "c")
      in_hidden = project.blocks.create!(user: @user, kind: "image", node_id: hidden_img.node_id)
      hidden_block = project.blocks.create!(user: @user, kind: "text", body: "hidden")
      project.update!(panels: { "hidden" => [ hidden_block.layout_key, Maker::ProjectKind.folder_key(secret.node_id) ] })

      get public_project_path(@user.handle, project.slug)

      assert_select "div.panel-slot.panel--full > section.block-panel.block--text h2", text: "Why"
      assert_select "section.block-panel.block--text .markdown strong", text: "shade"
      assert_select "section.block-panel.block--link a.block-link-card[href=?][rel='noopener nofollow']", "https://p.example"
      assert_select "section.block-panel.block--image[id=?] figure img", shown.layout_key, 1
      assert_select "section.block-panel.block--image[id=?]", in_hidden.layout_key, count: 0
      assert_select "section.block-panel[id=?]", hidden_block.layout_key, count: 0
      assert_equal css_select("div.project-panels > div.panel-slot").size, css_select("div.project-panels > div.panel-slot > section.panel").size
      assert_no_private_urls
    end
```
(`assert_no_private_urls` is `PublicFixture`'s guard; the image must come through `pub.file_url_for`.)

Add to `page_query_budget_test.rb` a test in the style of the edit-mode test: seed 1 block then 6 more of each kind (with image nodes) and assert the project page, the edit page and the public page each stay flat (`assert_equal small, large`). Add the edit page to `template_hygiene_test.rb`'s project fixture: give `@project` one block of each kind in `setup` (the sweep renders their partials on both project pages; `_block_templates` and `_page_intro` render on the edit page).

Extend `project_layout_editor_test.rb`'s "normal page carries no chrome" test with `assert_select "div.page-intro", count: 0` and the edit-page test with `assert_select "div.page-intro", 1`.

- [ ] **Step 2: Run to see them fail** — `preview_project_layout_path` undefined; `blocks` undefined on the project (Task A defines it — verify A is committed).

- [ ] **Step 3: Routes** — inside `resource :layout, only: [], module: :projects do` add `post :preview` with a one-line comment: `# THE TEXT BLOCK'S PREVIEW (content blocks): Markdown in, sanitised HTML out, read-only.`

- [ ] **Step 4: The scope and the doors**

`app/controllers/concerns/projects/layout_scoped.rb` — the listing now loads files (the images map needs them); replace the body:
```ruby
    def set_project
      @project = current_user.maker_projects.find_by!(slug: params[:project_id])
      # WITH FILES since content blocks: the document names an image by its path under the folder,
      # so the rows are needed. One files query; the page already pays it on every render.
      @listing = Maker::ProjectFolderListing.new(current_user, @project)
    end

    def blocks = @blocks ||= @project.blocks.to_a

    def current_layout = @project.panel_layout(folders: @listing.panel_folders, blocks: blocks.map { |b| [ b.key, b.kind ] })

    # IMAGE FILES INSIDE THE FOLDER, BY PATH RELATIVE TO IT — what an image block or the cover may
    # name in the YAML (spec decision 4). `Row#role` is the filing role; `path_for` the catalog's
    # full path, so the folder's own path is stripped off the front.
    def folder_images
      prefix = "#{@listing.path}/"
      @listing.all_rows.select { |row| row.role == "image" }
              .to_h { |row| [ row.node_id, "#{@listing.path_for(row.node)}/#{row.node.name}".delete_prefix(prefix) ] }
    end

    def document
      Maker::LayoutDocument.new(current_layout, @listing.tree.to_h { |dir| [ dir.node_id, dir.name ] },
                                blocks: blocks, images: folder_images,
                                page: { "description" => @project.description, "cover" => @project.cover_node_id })
    end

    def kind_label = Maker::ProjectKind.label(@project.kind)
```
`Projects::LayoutsController` gains:
```ruby
    # THE TEXT BLOCK'S PREVIEW (content blocks; spec §6): the same Maker::Markdown the page renders
    # with, so what the maker sees while typing is what the page will show. 422 over the body cap
    # rather than a truncated render, because a truncated preview would lie about the block.
    def preview
      markdown = params[:markdown].to_s
      return head :unprocessable_entity if markdown.bytesize > Maker::ProjectBlock::BODY_MAX

      render html: Maker::Markdown.render(markdown), content_type: "text/html"
    end
```
`Projects::PanelsController#replace` becomes:
```ruby
    def replace
      doc = document
      result = doc.from_draft(parsed_layout)
      return refuse(result.errors) unless result.ok?

      notes = result.notes.dup
      begin
        @project.transaction do
          keys = write_blocks(doc.blocks_from(result.draft))
          column = doc.column(result.draft).transform_values { |v| rekey(v, keys) }
          attrs = { panels: column }
          if (page = doc.page_from(result.draft))
            attrs[:description] = page["description"]
            attrs[:cover_node_id] = page["cover_node_id"]
          end
          @project.update!(attrs)
        end
      rescue ActiveRecord::RecordInvalid => e
        return refuse([ e.record.errors.full_messages.join(", ") ])
      end
      redirect_to project_path(@project), notice: [ "Page layout saved.", *notes ].join(" ")
    end

    def refuse(errors)
      redirect_to edit_layout_project_path(@project), alert: "The layout was not saved: #{errors.join(' ')}"
    end

    # THE DRAFT IS THE WHOLE TRUTH OF BLOCKS (spec §5): rows for new keys are created, rows for
    # existing keys updated, rows the draft does not list destroyed — inside the caller's
    # transaction, so a bad block anywhere writes nothing. Returns { "block:new-1" => "block:<key>" }
    # so the column's keys can be rewritten to the rows that now exist.
    def write_blocks(drafted)
      existing = blocks.index_by(&:layout_key)
      keys = {}
      drafted.each do |b|
        attrs = b.except("key", "kind").merge("kind" => b["kind"])
        if existing.key?(b["key"])
          existing.delete(b["key"]).update!(attrs)
        else
          row = @project.blocks.create!(attrs.merge("user" => current_user))
          keys[b["key"]] = row.layout_key
        end
      end
      existing.each_value(&:destroy!)
      raise ActiveRecord::RecordInvalid.new(@project.blocks.new(kind: "text")) if @project.blocks.count > Maker::ProjectBlock::CAP
      keys
    end

    def rekey(value, keys)
      case value
      when Array then value.map { |k| keys.fetch(k, k) }
      when Hash then value.to_h { |k, v| [ keys.fetch(k, k), v ] }
      else value
      end
    end
```
(The cap raise is belt-and-braces behind the document's own check; give it a real message by
building a block with an error: `row = @project.blocks.new(kind: "text"); row.errors.add(:base, "more than #{CAP} blocks"); raise ActiveRecord::RecordInvalid.new(row)`.)

- [ ] **Step 5: `ProjectsController#show`** — after `@listing = …` and before the layout:
```ruby
    # CONTENT BLOCKS (2026-09-09): one query, before the layout that orders them and the union that
    # answers their pictures' liveness.
    @blocks = @project.blocks.to_a
    @blocks_by_key = @blocks.index_by(&:layout_key)
```
Change `@panel_layout = @project.panel_layout(folders: @listing.panel_folders)` to pass `blocks: @blocks.map { |b| [ b.key, b.kind ] }`; extend `@panel_labels` with `.merge(@blocks.to_h { |b| [ b.layout_key, block_label(b) ] })` where `block_label` is a private controller method: `{ "text" => "Text block", "link" => "Link", "image" => "Image" }.fetch(b.kind)` plus `": #{b.heading}"` when a heading exists. Add `@blocks.filter_map(&:node_id)` to the `live_nodes_for(...)` union and `@blocks.filter_map(&:node_id).select { |id| @page_nodes.key?(id) }` to the `ThumbnailMap.for` ids. In edit mode only, `@folder_images = folder image rows` — build it the same way `LayoutScoped#folder_images` does but as rows: `@listing.all_rows.select { |r| r.role == "image" }` (the pickers render name + thumb from `@page_thumbs`; make sure those ids are in `@page_thumbs` when editing by adding them to the map's ids under `if @editing`).

- [ ] **Step 6: The maker's views**

`_panel_body.html.erb` — add a block branch before the fixed one:
```erb
<% if @panel_layout.block?(key) %>
  <% if @editing %>
    <%= render "projects/block_editor", key:, block: @blocks_by_key[key] %>
  <% else %>
    <%= render "projects/block_panel", key:, block: @blocks_by_key[key] %>
  <% end %>
<% elsif @panel_layout.folder?(key) %>
```
`_block_panel.html.erb` (maker, read mode):
```erb
<%#
  A CONTENT BLOCK, READ (2026-09-09, content blocks; spec §2, §6). Three kinds, one section. Markdown
  through Maker::Markdown, which sanitises — nothing in `body` is trusted. An image whose node is not
  live renders NOTHING (blank body, so no slot), the derived-content rule; the editor is where the
  maker learns the picture is gone. Locals: key, block (Maker::ProjectBlock).
%>
<% node = block.kind == "image" ? @page_nodes[block.node_id] : nil %>
<% unless block.kind == "image" && node.nil? %>
  <section class="panel block-panel block--<%= block.kind %>" id="<%= key %>">
    <% case block.kind %>
    <% when "text" %>
      <% if block.heading.present? %><h2><%= block.heading %></h2><% end %>
      <div class="markdown"><%= Maker::Markdown.render(block.body.to_s) %></div>
    <% when "link" %>
      <%= link_to block.url, class: "block-link-card", rel: "noopener", target: "_blank" do %>
        <span class="block-link-title"><%= block.heading %></span>
        <% if block.line.present? %><span class="block-link-line muted"><%= block.line %></span><% end %>
        <span class="block-link-host mono muted"><%= link_host(block.url) %></span>
      <% end %>
    <% when "image" %>
      <% ext = File.extname(node.name).delete(".").upcase.first(4) %>
      <figure class="block-figure">
        <% if Maker::FileAttachment.inline_image?(node.name) %>
          <%= link_to file_path(node.node_id) do %><%= image_tag blob_file_path(node.node_id), class: "block-image", alt: block.caption.presence || node.name %><% end %>
        <% else %>
          <%= link_to file_path(node.node_id), class: "file-cell block-thumb", data: thumb_cell_data(node.node_id, ext) do %>
            <%= render "files/thumb", thumb: @page_thumbs.thumb(node.node_id), ext_label: ext, url: preview_src(@page_thumbs.thumb(node.node_id)) %>
          <% end %>
        <% end %>
        <% if block.caption.present? %><figcaption class="muted"><%= block.caption %></figcaption><% end %>
      </figure>
    <% end %>
  </section>
<% end %>
```
`ProjectsHelper#link_host(url)`: `URI.parse(url).host.to_s.delete_prefix("www.")` rescuing `URI::Error` to `""` — hmm, the test expects `www.printables.com`; keep the host as is: `URI.parse(url).host.to_s` (rescue → "").

`_block_editor.html.erb` (edit mode):
```erb
<%#
  A BLOCK'S OWN EDITOR, IN THE SLOT BODY (spec §2). Every input writes the slot's data attributes
  through the layout_editor controller (`field`), which is where the draft lives; nothing here
  posts. Text gets a Preview that asks the server (Projects::LayoutsController#preview); the link
  card and the image figure are drawn live. `block` is nil for a slot minted from a template.
  Locals: key, block (Maker::ProjectBlock or nil), kind (defaults to block.kind).
%>
<% kind = local_assigns.fetch(:kind) { block.kind } %>
<form class="block-editor block-editor--<%= kind %>" onsubmit="return false">
  <% case kind %>
  <% when "text" %>
    <label class="field"><span>Heading</span>
      <input type="text" maxlength="<%= Maker::ProjectBlock::HEADING_MAX %>" value="<%= block&.heading %>" placeholder="Optional"
             data-field="heading" data-action="input->layout-editor#field"></label>
    <label class="field"><span>Text (Markdown)</span>
      <textarea rows="6" maxlength="<%= Maker::ProjectBlock::BODY_MAX %>" data-field="body" data-action="input->layout-editor#field"><%= block&.body %></textarea></label>
    <div class="block-editor-actions">
      <button type="button" class="btn small" data-action="layout-editor#previewMarkdown">Preview</button>
    </div>
    <div class="block-preview markdown" data-layout-editor-target="preview" hidden></div>
  <% when "link" %>
    <label class="field"><span>URL</span>
      <input type="url" value="<%= block&.url %>" placeholder="https://" data-field="url" data-action="input->layout-editor#field"></label>
    <label class="field"><span>Title</span>
      <input type="text" maxlength="<%= Maker::ProjectBlock::HEADING_MAX %>" value="<%= block&.heading %>" data-field="linkTitle" data-action="input->layout-editor#field"></label>
    <label class="field"><span>One line</span>
      <input type="text" maxlength="<%= Maker::ProjectBlock::LINE_MAX %>" value="<%= block&.line %>" placeholder="Optional" data-field="line" data-action="input->layout-editor#field"></label>
    <a class="block-link-card" href="<%= block&.url %>" rel="noopener" target="_blank" data-layout-editor-target="linkCard">
      <span class="block-link-title"><%= block&.heading.presence || "Title" %></span>
      <span class="block-link-line muted"><%= block&.line %></span>
      <span class="block-link-host mono muted"><%= block&.url.present? ? link_host(block.url) : "" %></span>
    </a>
  <% when "image" %>
    <div class="image-picker" role="group" aria-label="Pick an image from the project folder">
      <% if @folder_images.empty? %>
        <p class="muted">No images in the project folder yet.</p>
      <% end %>
      <% @folder_images.each do |row| %>
        <% ext = File.extname(row.node.name).delete(".").upcase.first(4) %>
        <button type="button" class="image-pick<%= " active" if block&.node_id == row.node_id %>" data-node-id="<%= row.node_id %>"
                data-action="layout-editor#pickImage" title="<%= row.node.name %>">
          <%= render "files/thumb", thumb: @page_thumbs.thumb(row.node_id), ext_label: ext, url: preview_src(@page_thumbs.thumb(row.node_id)) %>
          <span class="image-pick-name"><%= row.node.name %></span>
        </button>
      <% end %>
    </div>
    <% if block&.node_id.present? && @page_nodes[block.node_id].nil? %>
      <p class="muted block-missing">This block's picture is not in the folder any more; pick another.</p>
    <% end %>
    <label class="field"><span>Caption</span>
      <input type="text" maxlength="<%= Maker::ProjectBlock::LINE_MAX %>" value="<%= block&.caption %>" placeholder="Optional" data-field="caption" data-action="input->layout-editor#field"></label>
  <% end %>
</form>
```
`_panel_slot.html.erb` — in the editing branch add to the div: `data-kind="<%= @panel_layout.block_kind(key) %>"` only when `@panel_layout.block?(key)`, plus the block's fields:
```erb
       <% if (b = @panel_layout.block?(key) && @blocks_by_key[key]) %>
         data-kind="<%= b.kind %>" data-heading="<%= b.heading %>" data-body="<%= b.body %>" data-url="<%= b.url %>"
         data-link-title="<%= b.kind == 'link' ? b.heading : '' %>" data-line="<%= b.line %>" data-file="<%= b.node_id %>" data-caption="<%= b.caption %>"
       <% end %>
```
(A block's `data-title`/`data-intro` stay empty; the strip does not offer them.) The placeholder branch is unreachable for blocks in edit mode (the editor always renders); leave it.

`_panel_strip.html.erb` — block variant: `<% blockish = @panel_layout.block?(key) %>`; name = `label`; skip the pencil `details` and the view switch when `blockish`; after the width switch add:
```erb
    <% if blockish %>
      <button type="button" class="linkbtn small danger" data-action="layout-editor#deleteBlock" aria-label="Delete <%= label %>">Delete</button>
    <% end %>
```
`_layout_bar.html.erb` — before "Edit as YAML":
```erb
    <% at_cap = @blocks.size >= Maker::ProjectBlock::CAP %>
    <details class="menu layout-add" data-layout-editor-target="addMenu">
      <summary class="btn small">Add block ▾</summary>
      <div class="menu-items">
        <% { "text" => "Text", "link" => "Link", "image" => "Image" }.each do |kind, name| %>
          <button type="button" class="menu-item" data-action="layout-editor#addBlock" data-kind="<%= kind %>" <%= "disabled" if at_cap %>><%= name %></button>
        <% end %>
        <% if at_cap %><p class="muted layout-add-cap">This page has <%= Maker::ProjectBlock::CAP %> blocks, the most it can hold.</p><% end %>
      </div>
    </details>
```
(Check `details.menu`'s existing component styles in `components.css` — `.menu-items`/`.menu-item` may already exist; use their spellings.)

`_block_templates.html.erb` — one `<template>` per kind, rendering the same slot markup a new block would have: render `projects/panel_slot`-shaped markup directly here (the slot div with `data-key="block:new-__N__"`, `data-kind`, default width, the strip via `render "projects/panel_strip", key: "block:new-__N__", hidden: false, width: default, offered: []` and the editor via `render "projects/block_editor", key: nil, block: nil, kind:`). `@panel_labels` must answer the template key: pass a label local through — add an optional `label:` local to `_panel_strip` (`label = local_assigns.fetch(:label) { @panel_labels.fetch(key) }`) and make its block test `blockish = local_assigns.fetch(:blockish) { @panel_layout.block?(key) }`.

`_page_intro.html.erb`:
```erb
<%#
  THE PAGE INTRO IN EDIT MODE (spec §3): the cover and the description, drafted like everything
  else — the controller reads data-cover/data-description off this card into the draft's `page`.
  The picker lists the folder's images (spec decision 4); a cover set elsewhere keeps working but
  cannot be picked here.
%>
<% cover_id = @project.cover_node_id %>
<div class="page-intro panel" data-layout-editor-target="page" data-cover="<%= cover_id %>" data-description="<%= @project.description %>">
  <div class="page-intro-cover">
    <b>Cover</b>
    <div class="cover-current" data-layout-editor-target="coverName"><%= cover_id && @page_nodes[cover_id] ? @page_nodes[cover_id].name : "No cover" %></div>
    <div class="image-picker" role="group" aria-label="Pick a cover from the project folder">
      <% @folder_images.each do |row| %>
        <% ext = File.extname(row.node.name).delete(".").upcase.first(4) %>
        <button type="button" class="cover-pick image-pick<%= " active" if cover_id == row.node_id %>" data-node-id="<%= row.node_id %>"
                data-action="layout-editor#pickCover" title="<%= row.node.name %>">
          <%= render "files/thumb", thumb: @page_thumbs.thumb(row.node_id), ext_label: ext, url: preview_src(@page_thumbs.thumb(row.node_id)) %>
          <span class="image-pick-name"><%= row.node.name %></span>
        </button>
      <% end %>
    </div>
    <button type="button" class="linkbtn small" data-action="layout-editor#removeCover">Remove cover</button>
  </div>
  <label class="field page-intro-description"><span>Description</span>
    <textarea rows="4" data-action="input->layout-editor#description"><%= @project.description %></textarea></label>
</div>
```
`show.html.erb` — add `data-layout-editor-preview-url-value="<%= preview_project_layout_path(@project) %>"` to the `div.layout-editor` root; in the edit branch, render `projects/page_intro` between the bar and the grid, `projects/block_templates` after the drawer, and put `data-controller="masonry"` on both grids (`<div class="project-panels layout-editing" data-controller="masonry" data-layout-editor-target="grid">` and `<div class="project-panels" data-controller="masonry">`) — the controller lands in Task D; a name that resolves to nothing is a silent no-op until then, and `stimulus_hygiene_test.rb` will be red between this task and D exactly as slice 1's was (say so in the commit).

- [ ] **Step 7: The public page** — `Maker::PublicProject`:
```ruby
    def blocks = @blocks ||= project.blocks.to_a
    def blocks_by_key = @blocks_by_key ||= blocks.index_by(&:layout_key)
    # AN IMAGE BLOCK IS DERIVED CONTENT (spec §6): its picture must be live, permitted, and outside a
    # hidden folder, or the block renders nothing at all.
    def block_image_node(block)
      node = page_nodes[block.node_id]
      node if node && permits?(node) && !hidden_file_ids.include?(node.node_id)
    end
```
(`page_nodes` is the union the public page already builds — add `blocks.filter_map(&:node_id)` to it, and the same ids to `thumbs`; `layout` passes `blocks: blocks.map { |b| [ b.key, b.kind ] }`.) In `_page.html.erb`'s loop add `elsif pub.layout.block?(key)` → `render "public/projects/block_panel", pub:, key:, block: pub.blocks_by_key[key]` before the folder branch; put `data-controller="masonry"` on the public grid. Create `public/projects/_block_panel.html.erb` with the same structure as the maker's, but: the link anchor `rel="noopener nofollow"`; the image `node = pub.block_image_node(block)` and, when present, `link_to pub.view_url_for(node.node_id)` around `image_tag pub.file_url_for(node.node_id)` for an inline image, else `render "files/thumb", thumb: pub.thumbs.thumb(node.node_id), ext_label:, url: pub.preview_url_for(node.node_id)` — never `blob_file_path`/`preview_src` (the seam guard's third arm).

- [ ] **Step 8: Run everything named in Step 1, plus the sweeps**
```bash
bin/rails test test/integration/web/project_blocks_test.rb test/integration/web/project_layout_editor_test.rb test/integration/web/public_project_test.rb test/integration/web/page_query_budget_test.rb test/integration/web/template_hygiene_test.rb test/architecture_invariants_test.rb test/integration/web/project_page_test.rb test/integration/web/public_bundle_test.rb
```
Expected green except `stimulus_hygiene_test.rb` (masonry lands in D).

- [ ] **Step 9: Mutation-check** — (1) in `write_blocks`, delete `existing.each_value(&:destroy!)` → "creates, updates and deletes" red; (2) in `replace`, move `@project.update!` outside the transaction and make `write_blocks` raise after creating → "a bad block writes nothing" red (restore both); (3) in the public partial, render the image without `pub.block_image_node`'s check → the visitor test red on the hidden-folder image; (4) in `_block_panel`, drop the `Maker::Markdown.render` and print `block.body` raw → the sanitised test red; (5) in `_layout_bar`, drop `disabled` → the cap test red.

- [ ] **Step 10: Commit** — "Content blocks render on both pages, the editor carries their editors, and Save writes rows, order and page in one transaction".

---

### Task D: the client, the masonry, the browser suite, the docs

**Files:**
- Modify: `app/javascript/controllers/layout_editor_controller.js`, `app/assets/stylesheets/components.css`, `app/assets/stylesheets/pages/projects.css`, `test/css_hygiene_test.rb`
- Create: `app/javascript/controllers/masonry_controller.js`, `test/system/page_blocks_test.rb`
- Modify: `docs/superpowers/specs/2026-09-09-content-blocks-design.md`, `docs/user-stories.md`

- [ ] **Step 1: `layout_editor_controller.js`** — add targets `addMenu blockTemplate page coverName preview linkCard`, value `previewUrl`, and:

```js
  // --- the draft (extended) ---
  draft() {
    const page = this.hasPageTarget
      ? { description: this.pageTarget.dataset.description || null, cover: this.pageTarget.dataset.cover || null }
      : undefined
    const d = { layout: 1, panels: this.slotTargets.map((slot) => this.entry(slot)) }
    if (page) d.page = page
    return d
  }

  entry(slot) {
    const d = slot.dataset
    const e = { key: d.key, hidden: d.hidden === "true", width: d.width }
    if (d.kind) {
      e.kind = d.kind
      if (d.kind === "text") { if (d.heading) e.heading = d.heading; if (d.body) e.body = d.body }
      if (d.kind === "link") { e.url = d.url || ""; e.title = d.linkTitle || ""; if (d.line) e.line = d.line }
      if (d.kind === "image") { e.file = d.file || ""; if (d.caption) e.caption = d.caption }
      return e
    }
    if (d.view) e.view = d.view
    if (d.title) e.title = d.title
    if (d.intro) e.intro = d.intro
    return e
  }

  // --- blocks ---
  addBlock(event) {
    const kind = event.currentTarget.dataset.kind
    const count = this.slotTargets.filter((s) => s.dataset.kind).length
    if (count >= this.blockCapValue) return
    const tpl = this.blockTemplateTargets.find((t) => t.dataset.kind === kind)
    if (!tpl) return
    this.newCounter = (this.newCounter || this.highestNew()) + 1
    const html = tpl.innerHTML.replaceAll("__N__", String(this.newCounter))
    const wrapper = document.createElement("div")
    wrapper.innerHTML = html.trim()
    const slot = wrapper.firstElementChild
    this.gridTarget.prepend(slot)
    this.addMenuTarget.removeAttribute("open")
    slot.querySelector("input, textarea")?.focus()
    this.changed()
  }

  highestNew() {
    return Math.max(0, ...this.slotTargets.map((s) => Number((s.dataset.key.match(/^block:new-(\d+)$/) || [])[1] || 0)))
  }

  deleteBlock(event) {
    this.slotOf(event).remove()
    this.changed()
  }

  // Every block input names its field; the slot's data attribute is the draft.
  field(event) {
    const slot = this.slotOf(event)
    const name = event.currentTarget.dataset.field
    slot.dataset[name] = event.currentTarget.value
    if (slot.dataset.kind === "link") this.drawLinkCard(slot)
    this.changed()
  }

  drawLinkCard(slot) {
    const card = slot.querySelector("[data-layout-editor-target=linkCard]")
    if (!card) return
    const url = slot.dataset.url || ""
    card.href = /^https?:\/\//.test(url) ? url : "#"
    card.querySelector(".block-link-title").textContent = slot.dataset.linkTitle || "Title"
    card.querySelector(".block-link-line").textContent = slot.dataset.line || ""
    let host = ""
    try { host = new URL(url).host } catch (_e) { host = "" }
    card.querySelector(".block-link-host").textContent = host
  }

  pickImage(event) {
    const slot = this.slotOf(event)
    slot.dataset.file = event.currentTarget.dataset.nodeId
    slot.querySelectorAll(".image-pick").forEach((b) => b.classList.toggle("active", b === event.currentTarget))
    slot.querySelector(".block-missing")?.remove()
    this.changed()
  }

  async previewMarkdown(event) {
    const slot = this.slotOf(event)
    const box = slot.querySelector("[data-layout-editor-target=preview]")
    try {
      const res = await this.post(this.previewUrlValue, { markdown: slot.dataset.body || "" })
      box.innerHTML = await res.text()
      box.hidden = false
    } catch (_e) {
      this.toast("The preview did not render; the text is kept and applies on Save.")
    }
  }

  // --- the page intro ---
  description(event) {
    this.pageTarget.dataset.description = event.currentTarget.value
    this.changed()
  }

  pickCover(event) {
    this.pageTarget.dataset.cover = event.currentTarget.dataset.nodeId
    this.pageTarget.querySelectorAll(".cover-pick").forEach((b) => b.classList.toggle("active", b === event.currentTarget))
    this.coverNameTarget.textContent = event.currentTarget.title
    this.changed()
  }

  removeCover() {
    this.pageTarget.dataset.cover = ""
    this.pageTarget.querySelectorAll(".cover-pick").forEach((b) => b.classList.remove("active"))
    this.coverNameTarget.textContent = "No cover"
    this.changed()
  }
```
`post()` must send `Accept: "application/json, text/plain, text/html"` (the preview answers HTML).
`adopt(draft)` extends: for a block entry whose key has no slot, mint one from the kind's template
(the same code as `addBlock`, with the draft's `new-N` key substituted) and append it; then set the
block fields from the entry (`slot.dataset.heading = e.heading || ""`, …, `linkTitle` from
`e.title`, `file` from `e.file`), refill its inputs, redraw the link card, mark the picked image;
and set the page: `pageTarget.dataset.description/cover`, the textarea value, the cover name and the
active `.cover-pick`. Add `static values = { …, previewUrl: String, blockCap: { type: Number, default: 40 } }`; Task C renders `data-layout-editor-preview-url-value` on the editor's root.

- [ ] **Step 2: `masonry_controller.js`**

```js
import { Controller } from "@hotwired/stimulus"

// NO GAPS BETWEEN HALF-WIDTH PANELS (2026-09-09, content blocks; spec §7). A CSS grid aligns rows,
// so a short half-width panel leaves empty space under itself until its taller neighbour ends. On
// the two-column layout this turns the grid's rows into one-pixel units with no row gap and gives
// every direct child a row span of its measured height plus the gap, so the next child starts
// right under the shorter one. Below the breakpoint, and without JavaScript, the grid is the page
// as it was. One mechanism on all three renders: the maker's page, edit mode, the visitor's page.
//
// MEASURE THE CHILD, NOT ITS CONTENT, and only because `align-items: start` (components.css) stops
// a child stretching to its span — otherwise the span would feed the measurement and grow forever.
const GAP = 16
const MIN_WIDTH = 900

export default class extends Controller {
  connect() {
    this.media = window.matchMedia(`(min-width: ${MIN_WIDTH}px)`)
    this.relayout = () => this.layout()
    this.media.addEventListener("change", this.relayout)
    this.resizer = new ResizeObserver(this.relayout)
    this.mutations = new MutationObserver(() => { this.observe(); this.layout() })
    this.mutations.observe(this.element, { childList: true })
    this.observe()
    this.layout()
  }

  disconnect() {
    this.media.removeEventListener("change", this.relayout)
    this.resizer.disconnect()
    this.mutations.disconnect()
    this.clear()
  }

  observe() {
    this.resizer.disconnect()
    for (const child of this.element.children) this.resizer.observe(child)
  }

  layout() {
    if (!this.media.matches) { this.clear(); return }
    this.element.classList.add("masonry")
    for (const child of this.element.children) {
      const height = child.getBoundingClientRect().height
      child.style.gridRowEnd = `span ${Math.max(1, Math.ceil(height + GAP))}`
    }
  }

  clear() {
    this.element.classList.remove("masonry")
    for (const child of this.element.children) child.style.gridRowEnd = ""
  }
}
```
CSS in `pages/projects.css`, inside the existing `@media (min-width: 900px)` block:
`.project-panels.masonry { grid-auto-rows: 1px; row-gap: 0; align-items: start; }` — and nothing
else: the spans include the gap, and `align-items: start` is what keeps the measurement honest.

- [ ] **Step 3: Styles** in `components.css` (the editor block): `.block-panel .markdown`, `.block-link-card` (a bordered card: title bold, line muted, host mono small; hover border accent), `.block-figure` / `.block-image` (max-width 100%, contained, rounded), `.block-editor` (grid gap 8px), `.block-preview` (bordered, padded), `.image-picker` (flex-wrap grid of 96px cells), `.image-pick` (a bare button with the thumb + name; `.active` outlined in the accent), `.page-intro` (two columns at ≥900px: cover | description), `.layout-add .menu-items` (if `details.menu` needs it), `.block-missing`. All on tokens, inside `@layer components`. Add `.block-panel .block-link-card .page-intro .image-pick` to `COMPONENT_SELECTORS`.

- [ ] **Step 4: The browser suite** — `test/system/page_blocks_test.rb`:

```ruby
require "application_system_test_case"

# CONTENT BLOCKS, DRIVEN (2026-09-09; spec §9): add each kind from the menu, edit it, preview it,
# delete it, drag it, save it; the page intro; and the packing — the one thing no request test can
# measure, because a gap is a layout fact.
class PageBlocksTest < ApplicationSystemTestCase
  include WebHelpers

  setup do
    @user = sign_in_as("page-blocks@example.com")
    @project = @user.maker_projects.create!(name: "Lamp", description: "A lamp.")
    @folder = project_folder_rows!(@user, @project)
    @photos = dir!("photos", @folder.node_id)
    @side = file!("side.jpg", @photos.node_id)
    @front = file!("front.png", @photos.node_id)
  end

  def dir!(name, parent) = @user.nodes.create!(node_id: SecureRandom.uuid, name:, kind: "dir", parent_node_id: parent, mtime: 1, size: 0)
  def file!(name, parent) = @user.nodes.create!(node_id: SecureRandom.uuid, name:, kind: "file", parent_node_id: parent, mtime: 1, size: 3)
  def slot(k) = "div.panel-slot[data-key='#{k}']"
  def new_slot(kind) = "div.panel-slot[data-kind='#{kind}'][data-key^='block:new-']"

  # [top, bottom, left] of the SLOT around the block whose section carries id=<layout key>.
  def rect(key)
    page.evaluate_script("(() => { const r = document.getElementById(#{key.to_json}).closest('.panel-slot').getBoundingClientRect(); return [r.top, r.bottom, r.left]; })()")
  end

  def open_editor
    visit edit_layout_project_path(@project)
    assert_selector ".layout-bar", text: "Editing page layout"
  end

  def add(kind)
    find("details.layout-add > summary").click
    find("details.layout-add button[data-kind='#{kind}']").click
    assert_selector new_slot(kind)
  end

  test "a text block: add, type, preview, save, and it is first on the page" do
    open_editor
    add("text")
    within(new_slot("text")) do
      fill_in "Heading", with: "Why a printed shade"
      fill_in "Text (Markdown)", with: "A **paper** shade yellows."
      click_on "Preview"
      assert_selector ".block-preview strong", text: "paper"
    end
    assert_equal "block:new-1", all("div.panel-slot").first["data-key"]
    click_on "Save"
    assert_selector ".flash-notice", text: "Page layout saved."
    block = @project.blocks.sole
    assert_equal [ "text", "Why a printed shade", "A **paper** shade yellows." ], [ block.kind, block.heading, block.body ]
    assert_equal block.layout_key, @project.reload.panels["order"].first
    assert_selector "section.block--text h2", text: "Why a printed shade"
    assert_selector "section.block--text .markdown strong", text: "paper"
    assert_no_console_errors
  end

  test "a link block's card follows the inputs, and an image block picks a folder image" do
    open_editor
    add("link")
    within(new_slot("link")) do
      fill_in "URL", with: "https://www.printables.com/model/1"
      fill_in "Title", with: "Printables"
      fill_in "One line", with: "Sliced files."
      assert_selector ".block-link-card .block-link-title", text: "Printables"
      assert_selector ".block-link-card .block-link-host", text: "www.printables.com"
    end
    add("image")
    within(new_slot("image")) do
      find("button.image-pick[data-node-id='#{@side.node_id}']").click
      fill_in "Caption", with: "Side on."
      assert_selector "button.image-pick.active[data-node-id='#{@side.node_id}']"
    end
    click_on "Save"
    assert_selector ".flash-notice", text: "Page layout saved."
    link = @project.blocks.find_by(kind: "link")
    image = @project.blocks.find_by(kind: "image")
    assert_equal [ "Printables", "https://www.printables.com/model/1", "Sliced files." ], [ link.heading, link.url, link.line ]
    assert_equal [ @side.node_id, "Side on." ], [ image.node_id, image.caption ]
    assert_selector "section.block--link a.block-link-card[href='https://www.printables.com/model/1']"
    assert_selector "section.block--image figure img"
  end

  test "Delete removes a block and Save persists the removal; a dragged block lands where dropped" do
    gone = @project.blocks.create!(user: @user, kind: "text", body: "gone")
    kept = @project.blocks.create!(user: @user, kind: "text", body: "kept")
    open_editor
    within(slot(gone.layout_key)) { click_on "Delete" }
    assert_no_selector slot(gone.layout_key)
    handle = find("#{slot(kept.layout_key)} .panel-strip-handle")
    target = find("div.panel-slot[data-key='tasks']")
    page.driver.browser.action.click_and_hold(handle.native).move_by(0, 40).move_to(target.native).move_by(0, 10).release.perform
    order = all("div.panel-slot").map { |s| s["data-key"] }
    assert_operator order.index(kept.layout_key), :>, order.index("attachments")
    click_on "Save"
    assert_selector ".flash-notice", text: "Page layout saved."
    assert_nil Maker::ProjectBlock.find_by(id: gone.id)
    assert_operator @project.reload.panels["order"].index(kept.layout_key), :>, @project.panels["order"].index("attachments")
  end

  test "the page intro changes the description and the cover" do
    open_editor
    within(".page-intro") do
      fill_in "Description", with: "A lamp, rewritten."
      find("button.cover-pick[data-node-id='#{@front.node_id}']").click
      assert_selector ".cover-current", text: "front.png"
    end
    click_on "Save"
    assert_selector ".flash-notice", text: "Page layout saved."
    assert_equal [ "A lamp, rewritten.", @front.node_id ], [ @project.reload.description, @project.cover_node_id ]
    assert_selector "p.project-description", text: "A lamp, rewritten."
    assert_no_console_errors
  end

  test "half-width panels pack: the slot below a short half starts within one gap of its bottom" do
    tall = @project.blocks.create!(user: @user, kind: "text", body: (1..40).map { |i| "line #{i}" }.join("\n\n"))
    short = @project.blocks.create!(user: @user, kind: "text", body: "short")
    third = @project.blocks.create!(user: @user, kind: "text", body: "third")
    @project.update!(panels: { "order" => [ tall.layout_key, short.layout_key, third.layout_key ] + Maker::Project::PANELS,
                               "widths" => { tall.layout_key => "half", short.layout_key => "half", third.layout_key => "half" } })
    visit project_path(@project)
    assert_selector "div.project-panels.masonry"
    tall_r, short_r, third_r = rect(tall.layout_key), rect(short.layout_key), rect(third.layout_key)
    assert_in_delta short_r[2], third_r[2], 1, "the third half sits in the short one's column"
    assert_operator third_r[0] - short_r[1], :<=, 17, "no gap: the third starts within one gap of the short one's bottom"
    assert_operator tall_r[1], :>, third_r[0], "and that is above the tall neighbour's bottom, i.e. a gap was actually closed"
  end
end
```
If the tall block is not taller than two short ones at 1400px, make its body longer.

- [ ] **Step 5: Run** — `bin/rails test test/system/page_blocks_test.rb test/system/page_editor_test.rb test/system/shell_test.rb test/stimulus_hygiene_test.rb test/css_hygiene_test.rb` green.

- [ ] **Step 6: Mutation-check** — (1) in `masonry_controller.js` delete the `child.style.gridRowEnd = …` line → the packing test red; (2) in `addBlock` delete `this.gridTarget.prepend(slot)` → the text test red; (3) in `field`, delete the `slot.dataset[name] = …` line → the link/image test red on the saved values; (4) in `pickCover`, delete the dataset write → the page-intro test red.

- [ ] **Step 7: Docs** — spec §10 gains "Settled in execution" items for anything that moved; `docs/user-stories.md` gets a re-measure line: `Re-measured after content blocks (2026-09-09): 6.5 stays `works` with text, link and image blocks arranged by the editor, the page intro editable in place, and half-width panels packing without gaps.`

- [ ] **Step 8: Commit** — "Blocks are added, edited, previewed and saved in the browser, the page intro edits in place, and half-width panels pack".

---

### Close-out

- [ ] `rm -rf tmp/cache/bootsnap*; TINKEREX_SYNC_DIR=/Users/charlesschwartz/Desktop/repos/tinkerex-sync bin/ci` — every gate green, the three legs at identical run counts (the +7 / +~160 assertion and 32/33/8 skip deltas are the normal shape).
- [ ] Push, `gh pr create --base main` with a body carrying what this adds, the decisions (spec §10), the review findings, the verification table and the scope; `bin/log arc --from-pr <n>`; watch CI; stop — **merging needs the owner's go-ahead.**
