# Stage 3, S3-4: Publishing — implementation plan

> **For agentic workers:** execute per `.claude/commands/execute-plan.md` (batched by file, parallel
> where disjoint, one capped quality review per task). Steps use checkbox (`- [ ]`) syntax.

**Goal:** a project can be made unlisted or public and read at `/u/<handle>/<slug>` by anyone,
with its README, files (downloadable through the port), photos, build log, BOM, wiring, schematics
and repositories rendered read-only; `/u/<handle>` lists a maker's public projects and `/explore`
lists everyone's, filterable by tag. Handles are claimed under Settings → Account.

**Architecture:** spec `docs/superpowers/specs/2026-09-04-stage-3-publishable-project-design.md`
§2.2, §2.5, §2.6, §3, §6. A sessionless `Public::` namespace whose base controller stands on
`ActionController::Base` (NOT `ApplicationController`: `test/architecture_invariants_test.rb`'s
"every ApplicationController descendant requires a signed-in session" is the guard that makes this
the only honest shape — a `skip_before_action` there is what it exists to flag). One service,
`Maker::PublicProject`, answers every question the public pages ask, including "may this node be
delivered", so the page and the file route cannot disagree about what is public. Bytes leave
through the port's `Delivery` exactly as `FilesController#blob` does (§15).

**Tech:** Rails 8, Hotwire (no new JS; the `kicanvas` Stimulus controller is reused with a public
URL), kramdown via `Maker::Markdown`, the existing `Maker::ProjectFolderListing` / `LibraryTree` /
`RepoCard` / `ThumbnailMap`.

---

## Rounds

| round | tasks | why this split |
|---|---|---|
| 1 | **A** data + handle claim + project form, **B** README/Markdown services | disjoint paths; B needs nothing from A |
| 2 | **C** the public surface (routes, `Public::*`, `Maker::PublicProject`, views, CSS, its tests) | needs A's columns and B's `Maker::Readme` |
| 3 | **D** the guards and sweeps (architecture guard, query budgets, template hygiene, phone sweep, docs) | tests-only + docs, over C's pages |

Base branch: `claude/stage-3-publishing` (from `main` at `95ee71a`). Every task commits with a
pathspec (`git add <files> && git commit -- <files>`), restores mutations with `git checkout --`,
and reports each mutation's actual output.

Run the three backend legs' guards before the full gate, they are what a new table or column
trips: `test/schema_map_test.rb` (the checked-in map must be regenerated: `bin/rails schema:map`),
`test/models/structural_orphan_test.rb` (no new edge here, so no case), `test/models/tenant_cleanup_test.rb`
(no new table). Env for tests: `export LIBRARY_BACKEND=share LIBRARY_PATH=$(mktemp -d)`;
migrations need `RAILS_ENV=test bin/rails db:prepare`.

---

## Task A — data, the handle claim, the project form

**Files:**
- Create: `db/migrate/<ts>_add_publishing_to_users_and_projects.rb`
- Modify: `db/schema.rb` (by the migration), `docs/schema-map.html` (`bin/rails schema:map`)
- Modify: `app/models/user.rb`, `app/models/maker/project.rb`
- Create: `app/controllers/settings/handles_controller.rb`
- Modify: `config/routes.rb` (inside `namespace :settings`: `resource :handle, only: :update`)
- Modify: `app/views/users/registrations/edit.html.erb` (a Handle section, its own form)
- Modify: `app/views/projects/_form.html.erb` (Visibility + License), `app/controllers/projects_controller.rb` (`project_params` permits `:visibility, :license`), `app/views/projects/show.html.erb` (the head shows the public link when published)
- Create: `test/models/user_handle_test.rb`, `test/models/maker/project_publishing_test.rb`, `test/integration/web/settings_handle_test.rb`, `test/integration/web/project_publishing_form_test.rb`

### A.1 Migration

```ruby
class AddPublishingToUsersAndProjects < ActiveRecord::Migration[8.1]
  def change
    add_column :users, :handle, :string
    add_index  :users, :handle, unique: true

    add_column :maker_projects, :visibility, :string, null: false, default: "private"
    add_column :maker_projects, :unlisted_token, :string
    add_column :maker_projects, :license, :string
    add_index  :maker_projects, :unlisted_token, unique: true
    # /explore and /u/:handle read "public, newest first"; no existing index is a prefix of this
    # one and it is a prefix of none (test/architecture_invariants_test.rb's prefix guard).
    add_index  :maker_projects, %i[visibility updated_at]
  end
end
```

Then `RAILS_ENV=test bin/rails db:prepare && bin/rails db:migrate && bin/rails schema:map` and
run `bin/rails test test/schema_map_test.rb`.

### A.2 `User` — the handle

Add beside `normalizes :email` (app/models/user.rb:140):

```ruby
  # THE HANDLE IS THE FIRST SEGMENT OF EVERY PUBLIC URL (/u/<handle>/<slug>, spec §2.2), so it is
  # lowercase, URL-safe and unique, claimed once under Settings → Account, and LOCKED while any
  # project is unlisted or public -- a rename would break every link a maker has already handed out.
  # Nullable: an account that never publishes never needs one.
  HANDLE_RE = /\A[a-z0-9](?:[a-z0-9-]{0,30}[a-z0-9])?\z/
  # Segments that exist at the site root or are obvious impersonation targets. `u` itself is here
  # so /u/u/... cannot be minted; the rest are the app's own top-level paths (config/routes.rb).
  RESERVED_HANDLES = %w[
    u explore admin administrator api v1 assets rails up files projects models tools settings
    trash search tags inventory shelves suppliers locations repos library notes attachments
    build_log_entries users login logout sign_in sign_up signin signup register account
    tinkerex support help about root www mail
  ].freeze

  normalizes :handle, with: ->(h) { h.to_s.strip.downcase.presence }
  validates :handle, allow_nil: true, uniqueness: true,
            format: { with: HANDLE_RE, message: "is 2–32 characters of a–z, 0–9 and hyphens, starting and ending with a letter or digit" },
            exclusion: { in: RESERVED_HANDLES, message: "is reserved" }
  validate :handle_is_locked_while_published, on: :update

  def handle_locked? = maker_projects.published.exists?

  private

  def handle_is_locked_while_published
    return unless will_save_change_to_handle? && handle_in_database.present? && handle_locked?

    errors.add(:handle, "can't change while a project is unlisted or public")
  end
```

(`will_save_change_to_handle?` / `handle_in_database` are the Rails attribute-API names; do not
use `handle_changed?` + `handle_was`, which are the same thing but pre-`after_save` semantics
differ.)

### A.3 `Maker::Project` — visibility, token, license

Add after `STATUSES` (app/models/maker/project.rb:5):

```ruby
    # PUBLISHING (stage 3, S3-4; spec §2.5). private is the default and the only state with no
    # public URL; unlisted needs the token; public is listed on /u/:handle and /explore.
    VISIBILITIES = %w[private unlisted public].freeze
    # SPDX ids → labels. Hardware-first: the three CERN OHL v2 flavours, then the usual suspects.
    LICENSES = {
      "CERN-OHL-P-2.0" => "CERN OHL v2 Permissive",
      "CERN-OHL-W-2.0" => "CERN OHL v2 Weakly Reciprocal",
      "CERN-OHL-S-2.0" => "CERN OHL v2 Strongly Reciprocal",
      "TAPR-OHL-1.0"   => "TAPR Open Hardware License",
      "CC-BY-4.0"      => "Creative Commons Attribution 4.0",
      "CC-BY-SA-4.0"   => "Creative Commons Attribution-ShareAlike 4.0",
      "CC0-1.0"        => "CC0 1.0 (public domain)",
      "MIT"            => "MIT",
      "Apache-2.0"     => "Apache 2.0",
      "GPL-3.0-or-later" => "GNU GPL v3 or later"
    }.freeze

    normalizes :license, with: ->(l) { l.to_s.strip.presence }
    validates :visibility, inclusion: { in: VISIBILITIES }
    validates :license, inclusion: { in: LICENSES.keys }, allow_nil: true
    validate :publishing_needs_a_handle
    before_validation :mint_unlisted_token

    scope :published,       -> { where.not(visibility: "private") }
    scope :publicly_listed, -> { where(visibility: "public") }

    def published?       = visibility != "private"
    def unlisted?        = visibility == "unlisted"
    def publicly_listed? = visibility == "public"
    def license_label    = LICENSES[license]
```

and in the private section:

```ruby
    # A HANDLE BEFORE A URL. The public URL is /u/<handle>/<slug>; with no handle there is no URL,
    # so the switch away from private refuses rather than minting a page nobody can reach.
    def publishing_needs_a_handle
      return unless published? && user&.handle.blank?

      errors.add(:visibility, "needs a handle first — choose one under Settings → Account")
    end

    # MINTED THE FIRST TIME A PROJECT LEAVES private AND NEVER CLEARED OR ROTATED: an unlisted link
    # someone was given keeps working across unlisted → public → unlisted. 32 hex = 128 bits.
    def mint_unlisted_token
      self.unlisted_token ||= SecureRandom.hex(16) if published?
    end
```

`to_param` stays `slug`. The `published` scope is what `User#handle_locked?` reads.

### A.4 The handle claim — `Settings::HandlesController`

Route, inside the existing `namespace :settings do` block (config/routes.rb:246):

```ruby
    # STAGE 3, S3-4: the handle is claimed on the Account page (users/registrations/edit) through
    # its own form, because Devise's update demands the current password and a handle is not a
    # credential.
    resource :handle, only: :update
```

```ruby
module Settings
  class HandlesController < ApplicationController
    def update
      current_user.handle = params.require(:user).permit(:handle)[:handle]
      if current_user.save
        redirect_to edit_user_registration_path, notice: "Your handle is @#{current_user.handle}."
      else
        redirect_to edit_user_registration_path, alert: "Handle #{current_user.errors[:handle].first}."
      end
    end
  end
end
```

(`current_user.handle = nil` — an empty field — clears an unlocked handle; the lock validation
refuses it while published, which is right: a published project's URL must not evaporate.)

Account page section, before the "Delete my account" block in
`app/views/users/registrations/edit.html.erb`:

```erb
<section class="panel handle-panel">
  <h2>Your handle</h2>
  <p class="muted">Public projects live at <code>/u/&lt;handle&gt;/&lt;project&gt;</code>. Lowercase letters, digits and hyphens.</p>
  <%# scope: :user -- form_with url: with no model has a blank object_name, so the field would be
      named "handle" and the controller's require(:user) would reject it (CLAUDE.md §14d). %>
  <%= form_with url: settings_handle_path, method: :patch, scope: :user, class: "handle-form" do |f| %>
    <label class="field">
      <span>Handle</span>
      <%= f.text_field :handle, value: current_user.handle, placeholder: "e.g. chaim",
                       pattern: "[a-z0-9][a-z0-9-]{0,30}[a-z0-9]", autocomplete: "off",
                       disabled: current_user.handle_locked? %>
    </label>
    <% if current_user.handle_locked? %>
      <p class="muted">Locked while a project is unlisted or public.</p>
    <% else %>
      <%= f.submit current_user.handle ? "Change handle" : "Claim handle", class: "btn small" %>
    <% end %>
  <% end %>
</section>
```

### A.5 The project form and page

`app/views/projects/_form.html.erb` — after the tags field:

```erb
  <label class="field">
    <span>Visibility</span>
    <%= f.select :visibility,
                 options_for_select(Maker::Project::VISIBILITIES.map { |v| [ v.humanize, v ] }, project.visibility) %>
  </label>
  <% if project.user.handle.blank? %>
    <p class="muted field-hint">To publish, first <%= link_to "choose a handle", edit_user_registration_path %>.</p>
  <% end %>
  <label class="field">
    <span>License</span>
    <%= f.select :license,
                 options_for_select([ [ "None", "" ] ] + Maker::Project::LICENSES.map { |id, label| [ "#{label} (#{id})", id ] },
                                    project.license) %>
  </label>
```

`project_params` (app/controllers/projects_controller.rb:310) permits `:visibility, :license`.

`app/views/projects/show.html.erb` — in the `.page-head`, under the title (after the archived
badge): when `@project.published?`, a `span.badge.visibility-#{@project.visibility}` with the
visibility humanized, and `link_to "Public page", public_project_path(@project.user.handle, @project.slug, **(@project.unlisted? ? { k: @project.unlisted_token } : {})), class: "linkbtn small public-link"`.
**The route helper is Task C's** — in this task render the link only when
`respond_to?(:public_project_path)`; Task C removes that guard. (It is what lets A and C's tests
both be green on their own commits.)

### A.6 Tests

`test/models/user_handle_test.rb`:
- normalizes (`"  Chaim "` → `"chaim"`, `""` → nil), accepts `a1`, `desk-lamp-2`, 32 chars;
  refuses 1 char, 33 chars, leading/trailing hyphen, uppercase after normalize is fine, `_`,
  every `RESERVED_HANDLES` entry (loop), uniqueness (second user with same handle).
- the lock: a user with a public project cannot change or clear the handle
  (`assert_not user.update(handle: "other")`, error message includes "can't change"); the same
  user with every project private can.
- Mutations (report output): drop `exclusion:` → the reserved loop fails; drop the lock validation →
  the lock test fails.

`test/models/maker/project_publishing_test.rb`:
- default private, no token; `visibility: "unlisted"` with a handled user mints a 32-hex token,
  a second save keeps it, switching public keeps it, back to private keeps it.
- publishing without a handle: `assert_not project.update(visibility: "public")`, error on
  `:visibility` mentions "handle".
- license: nil ok, `"MIT"` ok, `"WTFPL"` refused, `""` normalizes to nil; `license_label`.
- Mutations: drop `publishing_needs_a_handle` → the handle test fails; make `mint_unlisted_token`
  mint on every save (`self.unlisted_token = …`) → the "keeps it" assertion fails.

`test/integration/web/settings_handle_test.rb` (sign in as the wiring test does):
- the Account page renders the form with `input[name="user[handle]"]` and
  `form[action="/settings/handle"]` (assert the RENDERED field name, §14d);
- `patch settings_handle_path, params: { user: { handle: "Chaim" } }` → redirect, handle `chaim`,
  flash notice; an invalid handle → alert names the error; another user's handle → alert
  "has already been taken"; a locked handle renders the field disabled and no submit button.

`test/integration/web/project_publishing_form_test.rb`:
- the edit form renders `select[name="project[visibility]"]` with three options and
  `select[name="project[license]"]`; without a handle the hint links to the account page;
- `patch project_path(project), params: { project: { visibility: "public", license: "MIT" } }` with
  a handle → 302 and the project is public with a token; without a handle → the form re-renders
  (422) with the handle error; the project page then shows `.badge.visibility-public`.
- Mutation: drop `:visibility` from `project_params` → the patch test fails (stays private).

Commit A with all its files. Run: the four test files, `test/schema_map_test.rb`,
`test/architecture_invariants_test.rb` (the index-prefix guard), `bin/rubocop` on the Ruby files.

---

## Task B — `Maker::Readme` and Markdown images

**Files:**
- Create: `app/services/maker/readme.rb`
- Modify: `app/services/maker/repo_card.rb` (delegate `readme_facts` to `Maker::Readme`; keep the
  `README_NAMES`/`README_CAP`/`README_READ_LIMIT` constants as aliases if any test names them —
  `grep -rn "README_CAP\|README_READ_LIMIT\|README_NAMES" test/`)
- Modify: `app/services/maker/markdown.rb`
- Create: `test/services/maker/readme_test.rb`; modify `test/services/maker/markdown_test.rb` (or
  wherever `Maker::Markdown` is tested today — `grep -rln "Maker::Markdown" test/`)

### B.1 `Maker::Readme`

The repo card's `readme_facts` (app/services/maker/repo_card.rb:78) is exactly what the public
page needs for the PROJECT's own README, with two parameters that differ: which rows to search
(the repo dir's files vs the folder's loose files) and where a resolved link points (`file_path`
vs the public file URL). Extract:

```ruby
module Maker
  # A README rendered for a card: the first README-named row among `rows`, read through the port
  # (never File.read), capped, Markdown-rendered with relative links resolved against `base_path`
  # through `listing.path_index`, and every resolved target turned into a URL by `link` -- the
  # caller's choice, because the repo card links into /files and the public page into /u/....
  Readme = Data.define(:html, :note) do
    NAMES = %w[README.md README.markdown README.txt README readme.md Readme.md].freeze
    CAP = 64 * 1024
    # The catalog's size gates the READ; a README past four times the cap is never read at all
    # (project_repo_card_test.rb pins this with a port whose read raises).
    READ_LIMIT = CAP * 4

    def self.for(user:, rows:, base_path:, listing:, link:)
      row = NAMES.filter_map { |name| rows.find { |r| r.node.name == name } }.first
      return nil if row.nil?
      if row.node.size.to_i > READ_LIMIT
        return new(html: nil, note: "README too large to show here (#{row.node.size.to_i / 1024} KB); open the file instead.")
      end

      bytes = FileLayer.current.read(user, node_id: row.node_id)
      truncated = bytes.bytesize > CAP
      text = (truncated ? bytes.byteslice(0, CAP) : bytes).dup.force_encoding(Encoding::UTF_8).scrub
      base = Pathname.new(base_path.to_s)
      index = listing.path_index
      html = Maker::Markdown.render(text) do |href|
        target_id = index[base.join(href).cleanpath.to_s]
        target_id && link.call(target_id)
      end
      new(html:, note: (truncated ? "Showing the first #{CAP / 1024} KB of this README." : nil))
    rescue FileLayer::NotFound, FileLayer::FetchError
      new(html: nil, note: "README unavailable.")
    end
  end
end
```

Note `base_path: ""` for the folder root: `Pathname.new("").join("models/x.stl").cleanpath.to_s`
is `"models/x.stl"` — assert that in the test, it is the case the public page relies on.

`RepoCard.for` becomes:

```ruby
      readme = Maker::Readme.for(user:, rows: dir.files, base_path: dir.path, listing:,
                                 link: ->(id) { Rails.application.routes.url_helpers.file_path(id) })
      new(dir:, head:, tags:, readme_html: readme&.html, readme_note: readme&.note, refusal:)
```

`project_repo_card_test.rb` must stay green unchanged (it is the behavioural pin for the move).

### B.2 Markdown: images resolve like links, and external images go

`Maker::Markdown.render(text) { |href| url_or_nil }` ALREADY rewrites relative `a[href]` AND
relative `img[src]` through the same resolver (markdown.rb:76–80: a resolved image gets the URL, an
unresolved one is removed outright), and `img` with `src`/`alt` is in `ALLOWED_TAGS`/`ALLOWED_ATTRS`.
Verify that by reading it, then add the ONE rule that is missing — the `next if absolute_href?(src)`
on line 78 keeps an absolute image as-is:

- an ABSOLUTE `img[src]` (`http:`, `https:`, `//`, `data:`) is replaced by its `alt` text (a text
  node; nothing when `alt` is blank). `img-src` is `'self' data: blob:`
  (config/initializers/content_security_policy.rb), so an external image is blocked by policy
  anyway once the CSP enforces, and a hotlinked image on a public page is a tracking pixel. Absolute
  `a[href]` links stay as they are — an outbound link is the user's prose.

Keep the existing order (executable elements removed with content → rewrite → sanitize); the rule
lives in the rewrite step beside the relative case.

Tests (`test/services/maker/markdown_test.rb`, which exists — add to it): `![alt](photos/a.jpg)`
with a resolver returning `/u/x/y/files/n?k=t` → `<img src="/u/x/y/files/n?k=t" alt="alt">`
(pin the already-working case, it is what the public README relies on); unresolved relative → no
`<img>`; `![pix](https://evil.example/p.gif)` → no `<img>`, the text `pix`; `![](//cdn.example/p.png)`
→ nothing; `<img src=x onerror=alert(1)>` as raw HTML → no `onerror` anywhere (probably already
pinned — keep whichever exists). Mutations: restore the `next if absolute_href?(src)` skip → the
external test fails; drop `img` from `ALLOWED_TAGS` → the resolved test fails.

`readme_test.rb`: a `Readme.for` over a fixture listing (use `project_folder_rows!` + `create_node!`
under `use_fresh_share_library!`, as `project_repo_card_test.rb` does): finds `README.md` among
`listing.loose`, resolves `[base](models/base.stl)` to the `link` lambda's URL with `base_path: ""`,
returns nil with no README, the `READ_LIMIT` gate never reads (replace the port's `read` with a
raise, the repo-card test's trick), a `FetchError` → note. Mutation: `base.join(href)` → `href`
alone still passes for the root case — so ALSO test `base_path: "firmware"` resolving
`docs/x.md` to `firmware/docs/x.md` (that is the mutation-bearing assertion).

Commit B. Run both test files + `project_repo_card_test.rb` + rubocop.

---

## Task C — the public surface

**Files:**
- Modify: `config/routes.rb` (the `Public` scope), `app/views/projects/show.html.erb` (drop A's
  `respond_to?` guard), `app/views/layouts/application.html.erb` (the signed-in shell branch +
  `pages/public` in the stylesheet list), `app/helpers/shell_helper.rb` (`shell_signed_in?`)
- Create: `app/controllers/public/base_controller.rb`, `app/controllers/public/projects_controller.rb`,
  `app/controllers/public/files_controller.rb`, `app/controllers/public/users_controller.rb`,
  `app/controllers/public/explore_controller.rb`, `app/controllers/concerns/file_delivery.rb`
- Modify: `app/controllers/files_controller.rb` (`#blob` uses `FileDelivery#deliver_file`)
- Create: `app/services/maker/public_project.rb`
- Create: `app/views/public/projects/show.html.erb`, `app/views/public/projects/_files.html.erb`,
  `_photos.html.erb`, `_build_log.html.erb`, `_bom.html.erb`, `_schematics.html.erb`,
  `_repo_card.html.erb`, `app/views/public/users/show.html.erb`, `app/views/public/explore/index.html.erb`,
  `app/views/public/_project_card.html.erb`
- Create: `app/assets/stylesheets/pages/public.css`; modify `test/css_hygiene_test.rb` (`OURS` and
  the layout-order list gain `pages/public`)
- Create: `test/services/maker/public_project_test.rb`, `test/integration/web/public_project_test.rb`,
  `test/integration/web/public_file_test.rb`, `test/integration/web/public_explore_test.rb`

### C.1 Routes

Below the projects block, top level:

```ruby
  # --- PUBLISHING (stage 3, S3-4). SESSIONLESS: every controller here stands on
  # Public::BaseController < ActionController::Base, never ApplicationController (the seam guard in
  # test/architecture_invariants_test.rb and CLAUDE.md §14d say why). `k` is an unlisted project's
  # token, carried as a query param by every link the page renders (Maker::PublicProject#link_params).
  # `format: false` on the file route: KiCanvas keys on the URL's extension, so the optional
  # `*filename` glob carries the real name and `.kicad_sch` must not be parsed as a format. ---
  scope module: :public, as: :public do
    get "explore",                                to: "explore#index",  as: :explore
    get "u/:handle",                              to: "users#show",     as: :user,    constraints: { handle: /[a-z0-9][a-z0-9-]*/i }
    get "u/:handle/:slug",                        to: "projects#show",  as: :project, constraints: { handle: /[a-z0-9][a-z0-9-]*/i }
    get "u/:handle/:slug/files/:id(/*filename)",  to: "files#show",     as: :file,    constraints: { handle: /[a-z0-9][a-z0-9-]*/i }, format: false
  end
```

Helpers: `public_explore_path`, `public_user_path(handle)`, `public_project_path(handle, slug)`,
`public_file_path(handle, slug, id)` and `public_file_path(handle, slug, id, filename: name)`.

### C.2 `Public::BaseController` and the shell

```ruby
module Public
  # THE SESSIONLESS BASE. ActionController::Base, not ApplicationController: a public page never
  # reads the session (spec §6), so it must not inherit `authenticate_user!`, `CurrentProject` or
  # anything that would let a template branch on who is looking. The architecture guard asserts
  # this superclass and greps app/controllers/public and app/views/public for session words.
  class BaseController < ActionController::Base
    layout "application"
    helper_method :public_surface?

    # The layout renders the anonymous shell for a public page EVEN FOR A SIGNED-IN OWNER: the
    # rail's current-project switcher needs CurrentProject, which this base deliberately lacks,
    # and "what a visitor sees" is the honest preview of a public page.
    def public_surface? = true

    private

    def owner!
      User.find_by!(handle: params[:handle].to_s.downcase)
    end

    # A private project is a 404 to EVERYONE, including its owner in another tab: the page does not
    # consult the session, so it cannot know. An unlisted one needs its token, compared in constant
    # time; a public one needs nothing.
    def public_project!
      owner = owner!
      project = owner.maker_projects.published.find_by!(slug: params[:slug])
      if project.unlisted? &&
         !ActiveSupport::SecurityUtils.secure_compare(project.unlisted_token.to_s, params[:k].to_s)
        raise ActiveRecord::RecordNotFound
      end
      Maker::PublicProject.new(project)
    end
  end
end
```

`ShellHelper` gains:

```ruby
  # The signed-in shell (rail, tab bar, current-project switcher) renders for a signed-in user on
  # every page EXCEPT a public one, which renders what a visitor sees (Public::BaseController).
  def shell_signed_in?
    respond_to?(:user_signed_in?) && user_signed_in? &&
      !(respond_to?(:public_surface?) && public_surface?)
  end
```

and `app/views/layouts/application.html.erb:29` becomes `<% if shell_signed_in? %>`. Check the
layout's other branches (`_tabbar`, `_flash`, the theme cookies) render with no session — the
sign-in page already proves the layout does; what is new is a signed-in user on the anonymous
branch, which `public_project_test.rb` drives ("the owner, signed in, sees the visitor's shell").

`stylesheet_link_tag` list gains `"pages/public"` after `"pages/search"`; `test/css_hygiene_test.rb`'s
`OURS` and the order array gain `pages/public.css` / `pages/public` in the same position.

### C.3 `FileDelivery` — one delivery switch, two doors

```ruby
# The port's Delivery consumed in ONE place: FilesController#blob (session, any live node of the
# user) and Public::FilesController#show (no session, a node Maker::PublicProject permits). Three
# mechanisms, never a constructed path (CLAUDE.md §14a); inline only for the browser-safe image
# types and PDF, attachment for everything else and for ?download=1.
module FileDelivery
  extend ActiveSupport::Concern

  SAFE_INLINE_TYPES = %w[
    image/png image/jpeg image/gif image/webp image/bmp
    image/x-icon image/vnd.microsoft.icon
  ].freeze

  private

  def deliver_file(user, node, download:)
    filename = node.name
    content_type = Marcel::MimeType.for(name: filename)
    inline_ok = !download && (SAFE_INLINE_TYPES.include?(content_type) || content_type == "application/pdf")
    disposition = inline_ok ? "inline" : "attachment"

    delivery = FileLayer.current.download(user, node_id: node.node_id, disposition:, content_type:)
    case delivery
    in FileLayer::Delivery::Redirect(url:)
      redirect_to url, allow_other_host: true
    in FileLayer::Delivery::SendFile(path:)
      response.headers["X-Content-Type-Options"] = "nosniff"
      send_file path, disposition:, type: content_type, filename:
    in FileLayer::Delivery::Stream(enum:)
      response.headers["X-Content-Type-Options"] = "nosniff"
      response.headers["Content-Type"] = content_type
      response.headers["Content-Disposition"] =
        ActionDispatch::Http::ContentDisposition.format(disposition:, filename:)
      self.response_body = enum
    end
  end
end
```

`FilesController#blob` becomes the `find_by!` plus `deliver_file(current_user, node, download: params[:download].present?)`;
`FilesController::SAFE_INLINE_TYPES` stays as an alias of the concern's constant if anything
names it (`grep -rn SAFE_INLINE_TYPES app/ test/`). `s3_delivery_test.rb` and `file_page_test.rb`
stay green unchanged — they are the pin for the move.

### C.4 `Maker::PublicProject`

```ruby
module Maker
  # EVERYTHING A PUBLIC PAGE MAY SHOW, DERIVED ONCE. The page and the file route both ask this object,
  # so "is this file public" has one answer. Permission is by ANCESTRY through the owner's LibraryTree
  # (a live file node whose ancestor chain reaches the project folder), or by ATTACHMENT (a
  # maker_file_attachments row on the project or one of its build-log entries -- a Linked file or an
  # entry photo living elsewhere in the library is still the project's). Never by the capped listing:
  # a file past FILE_CAP is not on the page, but its download link from a README must still work.
  class PublicProject
    attr_reader :project, :owner, :listing, :tree

    def initialize(project)
      @project = project
      @owner = project.user
      @tree = Maker::LibraryTree.new(@owner)
      @listing = Maker::ProjectFolderListing.new(@owner, project, tree: @tree)
    end

    def handle = owner.handle
    def link_params = project.unlisted? ? { k: project.unlisted_token } : {}

    # [[section_name, rows]] -- the folder's own loose files first (under the project's name), then
    # every subfolder in tree order by its path. Backups are left out (a public page is not a
    # recovery tool). Rows are Maker::ProjectFolderListing::Row.
    def sections
      @sections ||= begin
        out = []
        out << [ project.name, listing.loose ] if listing.loose.any?
        walk = lambda do |dirs|
          dirs.each do |dir|
            out << [ dir.path, dir.files ] if dir.files.any?
            walk.call(dir.children)
          end
        end
        walk.call(listing.tree)
        out
      end
    end

    def readme
      return @readme if defined?(@readme)
      # base_path IS THE FOLDER'S OWN LIBRARY PATH, NOT "": `listing.path_index` keys on full
      # library paths ("Projects/desk-lamp/models/base.stl"), so a README at the folder root
      # resolves `models/base.stl` against `listing.path` ("Projects/desk-lamp"). Found by Task B,
      # pinned in test/services/maker/readme_test.rb ("a base_path that is not the README's own
      # directory resolves nothing").
      @readme = Maker::Readme.for(user: owner, rows: listing.loose, base_path: listing.path, listing:,
                                  link: ->(id) { file_url_for(id) })
    end

    def entries
      @entries ||= project.build_log_entries.includes(:file_attachments, :rich_text_body)
                          .reorder(logged_at: :desc).to_a
    end

    def bom_lines
      @bom_lines ||= (bom = project.current_bom) ? bom.lines.includes(:inventory_item).to_a : []
    end

    def connections = @connections ||= project.connections.to_a

    def kicad_rows
      @kicad_rows ||= listing.all_rows.select { |row| FilesController::KICANVAS_EXTS.include?(File.extname(row.node.name).delete(".").downcase) }
                             .sort_by { |row| row.node.name }
    end

    # Repo cards for every working tree in the folder, keyed by dir node_id (the private page's
    # collect_repo_dirs shape). Links are the public partial's business, not the card's.
    def repo_cards
      @repo_cards ||= begin
        dirs = flatten_dirs(listing.tree).select(&:repo?)
        roots = owner.nodes.present.where(node_id: dirs.map(&:node_id), kind: "dir").index_by(&:node_id)
        dirs.index_by(&:node_id).transform_values do |dir|
          Maker::RepoCard.for(user: owner, dir:, root_node: roots[dir.node_id], listing:,
                              capabilities: FileLayer.current.capabilities)
        end
      end
    end

    # Photos: every image-role row in the folder plus every live entry photo, deduped, in name order.
    def photo_rows
      @photo_rows ||= (listing.all_rows.select { |r| r.role == "image" } +
                       entries.flat_map(&:file_attachments).filter_map { |a| page_nodes[a.node_id] }
                              .map { |node| Maker::ProjectFolderListing::Row.new(node:, attachment: nil, linked: true, section: nil) })
                      .uniq(&:node_id).sort_by { |r| r.node.name }
    end

    # Live nodes for everything the page shows that is not in the listing: entry photos and BOM
    # file targets. ONE query.
    def page_nodes
      @page_nodes ||= begin
        ids = entries.flat_map { |e| e.file_attachments.map(&:node_id) } + bom_lines.filter_map(&:node_id)
        ids.empty? ? {} : owner.nodes.present.where(node_id: ids.uniq).index_by(&:node_id)
      end
    end

    def thumbs
      @thumbs ||= Maker::Previews::ThumbnailMap.for(owner, listing.node_ids + page_nodes.keys)
    end

    # THE ONE PERMISSION CHECK. A live, visible FILE node that either descends from the project folder
    # or is attached to the project / one of its entries. Directories, tombstones, dot-files and OS
    # clutter never deliver.
    def permits?(node)
      return false unless node && node.kind == "file" && !node.deleted && listing.available?
      return false unless Node.visible_entries.where(node_id: node.node_id).exists?
      return true if node.parent_node_id == project.folder_node_id
      return true if tree.ancestors_of(node.parent_node_id).include?(project.folder_node_id)

      attached_ids.include?(node.node_id)
    end

    def deliverable!(node_id)
      node = owner.nodes.find_by(node_id:)
      raise ActiveRecord::RecordNotFound unless permits?(node)
      node
    end

    def file_url_for(node_id, filename: nil, download: false)
      params = link_params
      params = params.merge(download: 1) if download
      Rails.application.routes.url_helpers.public_file_path(handle, project.slug, node_id, filename:, **params)
    end

    private

    def attached_ids
      @attached_ids ||= (project.file_attachments.pluck(:node_id) +
                         Maker::FileAttachment.where(user: owner, attachable_type: "Maker::BuildLogEntry",
                                                     attachable_id: project.build_log_entries.select(:id)).pluck(:node_id)).to_set
    end

    def flatten_dirs(dirs) = dirs.flat_map { |d| [ d ] + flatten_dirs(d.children) }
  end
end
```

Verify the names this leans on before writing: `Maker::LibraryTree#ancestors_of(node_id)` (line
75 — confirm it answers a DIR id and returns node_ids), `Node.visible_entries` (S3-1's display
scope; if it is named differently, use that name), `Maker::ProjectFolderListing.new(user, project,
tree:)` (line 73 accepts `tree:`), `FilesController::KICANVAS_EXTS`, `Row#role`. `permits?` must
not raise for a nil `parent_node_id`.

### C.5 Controllers

```ruby
module Public
  class ProjectsController < BaseController
    def show
      @pub = public_project!
      @project = @pub.project
    end
  end

  class FilesController < BaseController
    def show
      pub = public_project!
      node = pub.deliverable!(params[:id])
      deliver_file(pub.owner, node, download: params[:download].present?)
    end
  end

  class UsersController < BaseController
    def show
      @owner = owner!
      @projects = @owner.maker_projects.publicly_listed.includes(:tags).order(updated_at: :desc).to_a
    end
  end

  class ExploreController < BaseController
    PAGE = 60
    def index
      @tag = params[:tag].to_s.strip.downcase.presence
      scope = Maker::Project.publicly_listed.includes(:user, :tags)
      scope = scope.tagged_with(@tag) if @tag
      @projects = scope.order(updated_at: :desc).limit(PAGE).to_a
      # Tag chips over PUBLIC projects only, most used first, capped -- one grouped query.
      @chips = Maker::Tag.joins(:taggings)
                         .where(maker_taggings: { taggable_type: "Maker::Project",
                                                  taggable_id: Maker::Project.publicly_listed.select(:id) })
                         .group(:name).order(Arel.sql("COUNT(*) DESC"), :name).limit(30).count
    end
  end
end
```

`Public::FilesController` includes `FileDelivery`. Read `Maker::Taggable`'s `tagged_with` scope
(app/models/concerns/maker/taggable.rb:21): if it joins `maker_tags` by name it works across
users as written; if it is user-scoped, write the join here instead. `@chips` is `{name => count}`.

### C.6 Views

All under `app/views/public/`. Panel markup follows the private page's shapes (`section.panel` with
a `.panel-head` holding the `h2` and a `span.mono.muted` count), so the design system's component
rules apply unchanged; page-specific rules go in `pages/public.css`.

`projects/show.html.erb`:
- `content_for :title, "#{@project.name} — @#{@pub.handle}"`; `content_for :crumbs`: `link_to "@handle", public_user_path` then the project name.
- `div.page-head.public-head`: `h1` name; `p.public-byline`: "by " + `link_to "@#{handle}", public_user_path(handle)`, `span.badge.status-#{status}` with the status humanized, `span.badge.license` with `license_label` when present, and for an unlisted project `span.badge.visibility-unlisted` "Unlisted link".
- description `p.project-description`; tags: `div.tag-chips` of `link_to name, public_explore_path(tag: name), class: "tag-chip"` (NOT `tag_chips(@project)`, which links into the private `/tags/:name`).
- README: when `@pub.readme&.html` → `section.panel.readme-panel` with `div.markdown` and the note; a note alone renders as `p.muted`.
- then `render "files", pub: @pub`, `render "photos", pub: @pub`, `render "build_log", pub: @pub`,
  `render "bom", pub: @pub`, `render "projects/wiring", project: @project, connections: @pub.connections, editable: false`
  (the S3-3 partial's read-only branch — its first real caller), `render "schematics", pub: @pub`,
  `render "repo_card", card:, pub: @pub` for each `@pub.repo_cards.values`.
- Empty panels (no files, no entries, no lines, no connections, no schematics) are OMITTED, not
  rendered as empty states: a visitor is not the person who would add something.

`_files.html.erb`: for each section `[name, rows]`: `h3.public-section` name, `table.table.public-files`
with `thead` (empty th `.col-thumb`, `th.col-name` File, `th.col-size` Size, `th.col-dl`) and rows:
`td.col-thumb` → `render "files/thumb", thumb: pub.thumbs.thumb(row.node_id), ext_label: File.extname(row.node.name).delete(".").upcase`
inside a `span.file-cell` (no `data-controller="thumbs"`: no poll, ready thumbs only — a
pending one shows the spinner markup the partial emits; wrap it so `.thumb-spinner` renders as the
static badge on public pages: `pages/public.css` sets `.public-files .thumb-spinner { animation: none }`);
`td.col-name` → `link_to row.node.name, pub.file_url_for(row.node_id)` (inline for images/PDF,
attachment otherwise — the concern decides); `td.col-size.num` → `number_to_human_size(row.node.size)`;
`td.col-dl` → `link_to "Download", pub.file_url_for(row.node_id, download: true), class: "linkbtn small"`.
Column drops: `.col-size` at 719px, `.col-thumb` at 479px.

`_photos.html.erb`: when `pub.photo_rows.any?`: `section.panel.photos-panel`, `div.public-photos`
grid of `link_to pub.file_url_for(node_id), class: "photo-cell file-cell"` each holding
`render "files/thumb", thumb: pub.thumbs.thumb(id), ext_label: "IMG"`.

`_build_log.html.erb`: `section.panel.build-log-panel` with `ol.log-timeline` of `li.log-entry`:
`time.entry-time.muted` (`strftime("%Y-%m-%d")`), `div.entry-body` → `entry.body` (Action Text
renders its own sanitized HTML), `div.entry-photos` of photo cells for
`entry.file_attachments.select { |a| pub.page_nodes.key?(a.node_id) }` linking to
`pub.file_url_for(a.node_id)`.

`_bom.html.erb`: `section.panel.bom-panel` + `table.table.public-bom` with columns Ref `.col-ref.mono`,
Part `.col-part`, Qty `.num.col-qty` — and NOTHING else: no Stock (the owner's inventory levels are
private), no Supplier (a private business relationship), no actions. Part cell: a stock line →
`line.inventory_item&.name || line.part_name`; a file line whose node is in `pub.page_nodes` and
`pub.permits?` → `link_to node.name, pub.file_url_for(node.node_id)`, else the name as text; a text
line → `line.part_name`. Qty as the private partial formats it.

`_schematics.html.erb`: the private partial's shape (`section.panel.schematics-panel`, `ul.schematics-list`
of name + badge — names as plain text or links to `pub.file_url_for(id, download: true)`), and the
`div.kicanvas-stage.schematics-preview` with `data-controller="kicanvas"` and
`data-kicanvas-url-value="<%= pub.file_url_for(preview.node_id, filename: preview.node.name) %>"`
— the PUBLIC named URL, extension last, token carried.

`_repo_card.html.erb`: `div.repo-card` with `.repo-facts`: head `short_oid` in `span.mono` (no link),
summary, author + age, tag badges or "no tag", or the refusal; then the README `details.readme[open]`
with `div.markdown` as the private partial. No Commits / History links (those pages are private).
The card's README links resolve to `/files/...` (RepoCard's `link:` is `file_path`) — for the
PUBLIC card pass a public resolver: `Maker::RepoCard.for` gains an optional `link:` kwarg defaulting
to the `file_path` lambda, and `PublicProject#repo_cards` passes `->(id) { file_url_for(id) }`.
Amend Task B's `RepoCard.for` signature accordingly (`link: ->(id) { ...file_path(id) }` default).

`users/show.html.erb`: `content_for :title, "@#{@owner.handle}"`; `div.page-head` with `h1` "@handle"
and `span.mono.muted` "N public projects"; `div.project-card-grid` of `render "public/project_card", project:`;
empty state `p.empty` "No public projects yet."

`explore/index.html.erb`: `h1` "Explore"; `div.explore-chips` of `link_to "#{name} (#{count})", public_explore_path(tag: name), class: "tag-chip#{' active' if name == @tag}"`
(+ a leading "All" chip when `@tag`); the grid of cards; empty state.

`_project_card.html.erb`: `article.grid-card.project-card`: `link_to project.name, public_project_path(project.user.handle, project.slug)`,
`span.muted` "by @handle" (link) — omit on the user's own page? keep it, it is harmless —,
`p.muted` description truncated to 160 chars, tag chips (explore links), `time` updated.

### C.7 CSS — `pages/public.css`

`@layer pages { … }` with at least these rules (the hygiene guard wants layered, qualified,
non-component selectors): `.public-head .public-byline`, `.public-section`,
`.public-files .col-thumb .thumb` (a 40px box, matching `table.files .thumb`), `.public-files .thumb-spinner { animation: none }`,
`.public-photos` (grid `repeat(auto-fill, minmax(120px, 1fr))`, gap 8px), `.public-photos .photo-cell .thumb`,
`.project-card-grid` (grid, `minmax(240px, 1fr)`), `.explore-chips` (flex-wrap, gap), `.explore-chips .tag-chip.active`,
`@media (max-width: 719px) { .public-files .col-size { display: none } }`,
`@media (max-width: 479px) { .public-files .col-thumb { display: none } }`.
Do not restyle `.markdown`, `.repo-card`, `.log-timeline`, `.tag-chip` — they are shared.

### C.8 Tests

Fixtures: a helper in each test file (or `test/support/public_fixture.rb` + `require` in
`test_helper` beside the others) that builds an OWNER with a handle, a project with
`project_folder_rows!`, files via `create_node!` (under `use_fresh_share_library!` when bytes must
exist — the README, the download tests; the KiCad file via `write_kicad_schematic!(parent_node_id:)`),
a subfolder with a file, a `README.md` whose text links `[base](models/base.stl)` and images
`![pic](photos/pic.png)` and `![ext](https://x.example/p.gif)`, an entry with a photo attachment
living OUTSIDE the folder, a BOM with a stock, a file and a text line, two connections, one repo
dir (`make_repo!`-style fixture from `GitRepoFixture` if cheap; otherwise a dir named `firmware`
holding a `.git` dir node and a README, which is what `page_query_budget_test.rb` does).

`public_project_test.rb` (no session unless stated):
1. private → 404; the OWNER signed in (post `user_session_path`) → still 404.
2. unlisted: no `k` → 404; wrong `k` → 404; right `k` → 200 and every `a[href^="/u/"]` on the page
   carries `k=` (assert with `css_select("a[href*='/files/']")` all include `k=`).
3. public → 200; `h1` name; `.public-byline a[href="/u/<handle>"]`; `.tag-chips a[href="/explore?tag=lamp"]`;
   NO `a[href^="/files/"]`, NO `a[href^="/projects/"]`, NO `form`, NO `button` anywhere in `main`
   (the read-only proof); the visitor shell: `nav.rail` absent.
4. the README: `.readme-panel .markdown a[href="/u/h/s/files/<base-id>"]`, `img[src="/u/h/s/files/<pic-id>"]`,
   no `img[src^="http"]`.
5. files: `h3.public-section` for the project name and `models`; a row's Download href ends in
   `download=1`; the `.col-size` cell shows a size.
6. photos panel lists the entry photo (outside the folder) and the image in the folder.
7. BOM: `table.public-bom` has headers exactly `["Ref", "Part", "Qty"]`; the inventory item's NAME
   appears, the number on hand does NOT (seed an item with quantity 7 and assert `"7 on hand"`
   absent), the supplier's name does NOT.
8. wiring: `table.wiring` with 2 rows and no `input`.
9. schematics: `.kicanvas-stage[data-kicanvas-url-value]` equals `public_file_path(h, s, id, filename: "driver.kicad_sch")` (+`k` when unlisted).
10. repo card: `.repo-card .repo-facts` present, no `a[href^="/repos/"]`.
11. the owner signed in with the project PUBLIC → 200 and the page still has no `nav.rail` and no `.btn` "Edit".
12. handle case: `/u/CHAIM/desk-lamp` → 200 (downcased lookup); unknown handle → 404; another
    user's project under this handle → 404.
Mutations (report output): drop the `secure_compare` branch → test 2 passes a wrong `k` → red;
render `tag_chips(@project)` instead of explore links → test 3's `/tags/` assertion; add the stock
cell back → test 7; drop `editable: false` → test 8.

`public_file_test.rb` (branching on `FileLayer.current.capabilities` like `s3_delivery_test.rb`):
1. a file in the folder → share: 200 with `Content-Disposition: attachment; filename="base.stl"`;
   s3: 302 to a signed URL; chunk_remote: 200 streamed (`assert_response :success`) — write the
   three arms explicitly with `presignable?` / `port_writable?`, never a class check.
2. a PNG in the folder → inline (`Content-Disposition` starts with `inline`, or the s3 URL carries
   `response-content-disposition=inline`); `?download=1` → attachment.
3. a deeper file (`models/deep/x.stl`) → delivered (ancestry, not the listing).
4. the entry photo OUTSIDE the folder → delivered (attachment permission).
5. a sibling file of the same owner outside the folder and unattached → 404.
6. another user's node id → 404. 7. a directory node → 404. 8. a tombstoned file → 404.
9. a dot-file in the folder (`.env`) → 404. 10. the private project's file → 404; the unlisted
   project's file without `k` → 404, with `k` → delivered.
11. the named form `/u/h/s/files/<id>/driver.kicad_sch` delivers the same node.
Mutations: `permits?` returns true for any live node → tests 5/6/9 fail; drop the ancestry line →
test 3 fails; drop `attached_ids` → test 4 fails.

`public_explore_test.rb`: explore lists public projects only (seed private + unlisted + public
across two users), newest first; `?tag=lamp` filters; chips carry counts over public projects only
(a private project's tag does not appear); `/u/:handle` lists that user's public projects only,
404 for an unknown handle, "No public projects yet." for a handle with none. Mutation: use
`published` instead of `publicly_listed` in explore → the unlisted project appears → red.

`test/services/maker/public_project_test.rb`: `sections` order (loose under the project name, then
`models`, then `models/deep`), `link_params`, `photo_rows` dedupe, `permits?` matrix (the 10 cases
above at the service level, cheap), `file_url_for` with `filename:`/`download:`.

Commit C. Run all four new files + `s3_delivery_test.rb` + `file_page_test.rb` + `project_page_test.rb`
+ `project_repo_card_test.rb` + `css_hygiene_test.rb` + `stimulus_hygiene_test.rb` + rubocop.

---

## Task D — guards, budgets, sweeps, docs

**Files:**
- Modify: `test/architecture_invariants_test.rb` (the Public seam guard), `test/integration/web/page_query_budget_test.rb`
  (two budgets), `test/integration/web/template_hygiene_test.rb` (five pages), `test/system/shell_test.rb`
  (three public pages at 375px; the KiCad fixture parented under the project folder)
- Modify: `CLAUDE.md` §14d (one bullet), `docs/superpowers/specs/2026-09-04-stage-3-publishable-project-design.md` (nothing unless C diverged)

### D.1 The seam guard (architecture_invariants_test.rb)

```ruby
  # A PUBLIC PAGE NEVER READS THE SESSION (spec §6). Two assertions, both non-vacuous: the base
  # class stands on ActionController::Base (an ApplicationController descendant would need a
  # skip_before_action, which the test above exists to flag), and no file under the Public
  # namespace names a session accessor.
  test "the Public namespace stands outside ApplicationController and names no session accessor" do
    Rails.application.eager_load!
    assert_equal ActionController::Base, Public::BaseController.superclass
    publics = ApplicationController.descendants.select { |k| k.name.to_s.start_with?("Public::") }
    assert_empty publics.map(&:name), "Public:: controllers must not descend from ApplicationController"

    files = Dir.glob(ROOT.join("app", "controllers", "public", "**", "*.rb")) +
            Dir.glob(ROOT.join("app", "views", "public", "**", "*.erb"))
    assert_operator files.size, :>=, 10, "the Public scan matched #{files.size} files — vacuous (§14e)"
    offenders = files.sort.flat_map do |file|
      File.readlines(file, chomp: true).each_with_index.filter_map do |line, idx|
        next if line.lstrip.start_with?("#")
        next unless line.match?(/\b(current_user|current_project|user_signed_in\?|web_device|session\b|cookies\b)/)
        "#{Pathname.new(file).relative_path_from(ROOT)}:#{idx + 1}"
      end
    end
    assert_empty offenders, "a public controller or view reads the session:\n  #{offenders.join("\n  ")}"
  end
```

Mutation: add `current_user` to a public view → red with the file:line.

### D.2 Budgets (page_query_budget_test.rb)

`public projects#show does not grow with files, entries, BOM lines or connections`: the
projects#show seed reused (the same `add` lambda shape: subfolders with files, entries, lines,
connections), the project made public on an owner with a handle, `assert_constant_queries(public_project_path(handle, slug), …)`.
The test signs nobody in. `explore#index does not grow with projects or tags`: seed N public
projects each with a distinct tag; assert constancy.

### D.3 Template hygiene pages

Add to `pages`: `"public project" => public_project_path(@user.handle, @project.slug)`,
`"public project (unlisted)" => public_project_path(@user.handle, @unlisted.slug, k: @unlisted.unlisted_token)`,
`"public user" => public_user_path(@user.handle)`, `"explore" => public_explore_path`,
`"explore (tag)" => public_explore_path(tag: "laser")`. The setup gives `@user` a handle, makes
`@project` public and creates `@unlisted`. Every new partial must be rendered by one of these
(the guard's own failure message names an unrendered template).

### D.4 The phone sweep (shell_test.rb)

Give `@user` a handle, make `project` public, parent `kicad` under the project folder
(`write_kicad_schematic!(name: "shell-sweep.kicad_sch", parent_node_id: project.folder_node_id)` —
the private page's Schematics panel and the public one both render it, and the public preview runs
KiCanvas for real under the final console check), and append
`public_project_path(@user.handle, project.slug), public_user_path(@user.handle), public_explore_path`
to the visited list. The sweep's per-page assertions (`nav.tabbar` visible, `form.topbar-project
select` visible, no rail switcher) are the SIGNED-IN shell's, and a public page renders the
visitor's shell even for the signed-in sweep user (`shell_signed_in?`). Split the loop: the
existing pages keep their three assertions; the three public pages assert
`assert_no_selector "nav.tabbar"` and `assert_no_selector "aside.rail"` (the visitor-shell proof,
which is also what proves `shell_signed_in?` took effect in a real browser) plus the same
`scrollWidth <= innerWidth` assertion. `assert_no_console_errors` at the end covers all of them,
which is where a KiCanvas fetch of the public named URL would fail loudly.

Two names Task C leans on, verified 2026-09-05: `Maker::LibraryTree#ancestors_of(node_id)` returns
the ancestor node_ids ending in `nil` for the root, or `nil` for a broken chain — wrap it in
`Array(...)` before `include?`. `Node.visible_entries` is a scope taking an optional
`show_hidden` argument; call it bare. `project_repo_card_test.rb` names `README_CAP` /
`README_READ_LIMIT` on `Maker::RepoCard`, and `s3_delivery_test.rb` names
`FilesController::SAFE_INLINE_TYPES` — keep both as aliases of the new homes.

### D.5 CLAUDE.md §14d, one bullet

> **`Public::` STANDS ON `ActionController::Base` AND NEVER READS THE SESSION.** A public page is a
> 404 to everyone for a private project, including its signed-in owner, because it cannot know who
> is looking; an unlisted one needs its token. `Maker::PublicProject#permits?` is the ONE answer to
> "may this node be delivered" — by ancestry through the owner's tree or by attachment, never by the
> capped listing. Guard: the seam test in `architecture_invariants_test.rb`.

Commit D. Then the orchestrator runs bare `bin/ci` (with `TINKEREX_SYNC_DIR`), reads the three
counts, and closes out per `/finish-branch`.

---

## Self-review against the spec

- §2.2 `/u/<handle>/<slug>`, handle claimed under Settings → Account, slugs unique per user: A + C.1.
- §2.5 README + everything under three visibilities: C.4/C.6 (README, files, photos, build log,
  BOM, wiring, schematics, repos), A.3 (visibilities), C.2 (token).
- §2.6 same app, sessionless `Public::`, reusing partials (`projects/wiring`, `files/thumb`) and the
  port's delivery (C.3): yes.
- §3 columns: `users.handle`, `maker_projects.visibility/unlisted_token/license`: A.1.
- §4 S3-4 row: handle claiming, visibility and license, the three routes, tag chips, README with
  relative links and inline images, downloads/BOM/build log/photos/wiring/schematics, unlisted
  links: all placed.
- §6: no session in `Public::` (D.1), bytes through the port (C.3), Markdown stripped (B.2),
  budgets + sweep + form scope + rendered field names (A.6, D.2–D.4), permissive licences (no new
  dependency).
- Out of scope, deliberately: covers on the list pages, search on /explore, rotating an unlisted
  token, `noindex` for unlisted pages (add `<meta name="robots" content="noindex">` for unlisted in
  C.6 — cheap and right; include it), rate limiting on public GETs, sitemaps.
