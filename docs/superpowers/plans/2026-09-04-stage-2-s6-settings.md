# Stage 2, S2-6: the settings hub — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking. **In this repo `.claude/commands/execute-plan.md` overrides the generic loop:** batch by file, dispatch disjoint tasks in parallel, no spec-compliance stage, one capped quality review per task with its mutations run and their output reported.

**Goal:** Deliver S2-6 of `docs/superpowers/specs/2026-09-04-stage-2-structure-design.md` (§9), the last slice of stage 2: `/settings` lists **Shelves, Suppliers, Locations, Tags, Account and Theme** — each row a link with a fact beside it (a count, the email, the current theme); **Tags** gets its settings list (`/settings/tags`: every tag with how many things wear it, and Remove); the **Theme** row is the same three-way choice the rail's button cycles through, as three buttons; the rail foot's Sign-out row gains a **Settings** link that lights on the hub and its children. Nothing moves in the database; query counts constant in N.

**Architecture:** `SettingsController#show` (the hub: four counts, the email, the theme), `Settings::TagsController` (index + destroy), one addition to the `theme` Stimulus controller (a `choose` action taking a `theme` param, sharing `cycle`'s write path), the rail foot link. Routes and the `settings` rail section are committed (`settings_path`, `settings_tags_path`, `settings_tag_path(tag)`; `ShellHelper::SECTIONS["settings"]`).

**Tech Stack:** Rails 8, Hotwire, one Stimulus action, Minitest request tests, one system test.

---

## Before you start

- Branch `claude/stage-2-settings` from `main` at `ce801a6` (PR #315 merged); the scaffold commit is on it. Worktree `/Users/charlesschwartz/Desktop/repos/tinkerex/.claude/worktrees/auto-model-folder-files-bug-112353`. Never push to `main`.
- Tests: `export LIBRARY_BACKEND=share LIBRARY_PATH=$(mktemp -d)`; style `bin/ci style`; one full-suite run at a time; commit with a pathspec.
- Read `docs/invariants/design-system.md` (§14m): **theme state is a cookie the client writes and the layout renders — never an inline script** (rule 7); a new `data-controller`/`data-action` must resolve (`test/stimulus_hygiene_test.rb`); component selectors live in `components.css` only. Read `test/system/README.md`: a Stimulus behaviour earns ONE system test, mutation-checked, with the mutation named in a comment.
- What exists: `ShelvesController#index` (`/settings/shelves`, seeds defaults on first visit — `Maker::Shelf.seed_once!`), `SuppliersController`/`LocationsController` (`/settings/suppliers`, `/settings/locations`, S2-3), the Devise account page (`edit_user_registration_path`, `app/views/users/registrations/edit.html.erb`, pinned by `test/integration/web/account_settings_test.rb`), the rail's theme button (`app/javascript/controllers/theme_controller.js`, `ShellHelper#ui_theme`, `THEMES = %w[dark light system]`), `TagsController#show` (`/tags/:name`, S2-5), `User has_many :maker_tags, :maker_taggings, :maker_shelves`, `pages/settings.css` (`.settings-list`, `.settings-name`, `.settings-fact`, `.settings-remove`).
- `git checkout -- <file>` cannot restore a new file: `git add` before a mutation check.

## File structure (one task; the orchestrator closes out)

| path | responsibility |
|---|---|
| `app/controllers/settings_controller.rb` (new), `app/views/settings/show.html.erb` (new) | the hub |
| `app/controllers/settings/tags_controller.rb` (new), `app/views/settings/tags/index.html.erb` (new) | the tags list |
| `app/javascript/controllers/theme_controller.js` (`choose`), `app/views/settings/_theme.html.erb` (new) | the three-way theme choice |
| `app/views/layouts/_rail.html.erb` (the foot's Settings link), `app/assets/stylesheets/shell.css` (the foot link's active state, if the rail-btn rules do not already cover `aria-current`) | the door |
| `app/assets/stylesheets/pages/settings.css` (`.settings-hub`, `.theme-choice` rules) | page rules |
| `test/integration/web/settings_hub_test.rb` (new), `shell_layout_test.rb` (the foot link + active state), `page_query_budget_test.rb` (`settings#show`, `settings/tags#index`), `template_hygiene_test.rb` (both pages), `test/system/shell_test.rb` (sweep gains both), `test/system/settings_theme_test.rb` (new) | tests |

---

### Task A: the hub, the tags list, the theme choice, the door

- [ ] **Step 1: tests first.** `settings_hub_test.rb` (sign in like `settings_reference_test.rb`):
  - **the hub lists six rows with facts and links** — seed 2 shelves beyond the seeded defaults? (`Maker::Shelf.seed_once!` runs on `/settings/shelves`, not here — the hub COUNTS `current_user.maker_shelves` as they are; do not seed from the hub), 3 suppliers, 2 locations, 4 tags → `ul.settings-list.settings-hub li` count 6; rows in order Shelves, Suppliers, Locations, Tags, Account, Theme; `a.settings-name[href=?]` for `shelves_path`, `suppliers_path`, `locations_path`, `settings_tags_path`, `edit_user_registration_path`; `.settings-fact` texts `/3 suppliers/`, `/2 locations/`, `/4 tags/`, the email, and the theme row's fact `/dark/` by default (`cookies[:theme]` unset).
  - **the theme row is a three-way choice** — `.theme-choice button[data-action='theme#choose'][data-theme-theme-param=?]` for `dark`, `light`, `system`, with `aria-pressed="true"` on the current one (read from `ui_theme`), and the whole row carries `data-controller="theme"`; with `cookies[:theme] = "light"` set in the test, the `light` button is pressed.
  - **requires a session** — `GET settings_path` signed out → redirect to sign-in.
  - **the rail foot links here on every page**, lit on the hub: `shell_layout_test.rb` gains `aside.rail .rail-foot a.rail-btn.rail-settings[href=?]` `settings_path` on `GET projects_path`, and `[aria-current='page']` on `GET settings_path` and `GET settings_tags_path` (and NOT on `GET suppliers_path`, which keeps lighting Inventory — assert that too).
  - **tags list** — tags `laser` (worn by a project and a model), `firmware` (by nothing) → `ul.settings-list li` 2, A→Z, `.settings-fact` `/2 things/` and `/unused/`; each row links `tag_path(name)`; Remove is `form[action=?] button` `settings_tag_path(tag)` with a confirm; `delete settings_tag_path(laser)` → the tag and both taggings gone, the project and model untouched, redirect back with a flash; a foreign tag 404s; an empty list renders `li.empty`.
  - **budgets** — `settings#show` (grow shelves, suppliers, locations, tags: constant), `settings/tags#index` (grow tags each worn by a project: constant — the count is ONE grouped query `current_user.maker_taggings.group(:tag_id).count`).
  - `template_hygiene_test.rb`: `"settings/show" => settings_path`, `"settings/tags/index" => settings_tags_path` (with a tag in the fixture). `test/system/shell_test.rb`: the sweep gains `settings_path` and `settings_tags_path`.
  - **system** — `test/system/settings_theme_test.rb`: sign in, visit `settings_path`, click the `light` button → `html[data-theme="light"]` immediately and the `theme` cookie reads `light`; reload → the rail's theme label reads "Theme: light" and `light` is `aria-pressed`; click `system` → `html[data-theme="system"]`. MUTATION-CHECKED (README): make `choose` skip the cookie write → the reload assertion fails; name it in the test's comment with the verbatim failure.

- [ ] **Step 2: the controllers.**

```ruby
# The settings hub (stage 2, S2-6): one door onto the reference pages, the account page and the
# theme. Session-authed (§14d). It READS four counts and writes nothing — the theme is a cookie the
# client writes (design-system.md rule 7), and the seeding of default shelves stays on the shelves
# page, where a visit means "show me my shelves", not here.
class SettingsController < ApplicationController
  def show
    @shelf_count = current_user.maker_shelves.count
    @supplier_count = current_user.maker_suppliers.count
    @location_count = current_user.maker_locations.count
    @tag_count = current_user.maker_tags.count
  end
end

module Settings
  # Every tag the user owns, with how many things wear it, and a Remove that takes the taggings
  # with the tag (Maker::Tag has_many :taggings, dependent: :destroy) and nothing else — the
  # project, model or item keeps everything but the chip.
  class TagsController < ApplicationController
    def index
      @tags = current_user.maker_tags.order(:name).to_a
      @counts = current_user.maker_taggings.group(:tag_id).count   # ONE query
    end

    def destroy
      tag = current_user.maker_tags.find(params[:id])
      tag.destroy!
      redirect_to settings_tags_path, notice: "Removed the tag “#{tag.name}”."
    end
  end
end
```

- [ ] **Step 3: the views and the controller action.** `settings/show.html.erb`: `content_for :title, "Settings — Tinkerex"`; `page-head` (h1 Settings); `ul.settings-list.settings-hub` with six `li`: `a.settings-name` + `span.settings-fact` — Shelves (`pluralize(@shelf_count, "shelf")`), Suppliers, Locations, Tags (`settings_tags_path`), Account (`edit_user_registration_path`, fact: `current_user.email`), Theme (no link — the row IS `render "theme"`: `span.settings-name` "Theme" + the choice + `span.settings-fact` "Theme: <%= ui_theme %>" driven by the controller's label target). `settings/_theme.html.erb`:

```erb
<%# The same three states the rail's button cycles through, laid out as a choice. ONE controller
    instance, the same `theme` controller the rail uses: `choose` shares `cycle`'s write path
    (html[data-theme], the cookie, the two metas), so the two controls can never disagree about
    what a theme change means. `aria-pressed` is rendered by the server from the cookie and moved
    by the controller after a click. %>
<div class="theme-choice" data-controller="theme" role="group" aria-label="Theme">
  <% ShellHelper::THEMES.each do |t| %>
    <button type="button" class="btn small theme-option" data-action="theme#choose" data-theme-theme-param="<%= t %>"
            data-theme-target="option" aria-pressed="<%= ui_theme == t %>"><%= t.capitalize %></button>
  <% end %>
  <span class="settings-fact" data-theme-target="label">Theme: <%= ui_theme %></span>
</div>
```

`theme_controller.js`: add `static targets = ["label", "option"]`, extract the write into `apply(next)` (called by `cycle` and by `choose`), `choose(event) { this.apply(event.params.theme) }` (guard: ignore a value not in ORDER), and in `render(theme)` also set `aria-pressed` on each `optionTarget` (`opt.dataset.themeThemeParam === theme`). Keep `cycle` byte-identical in behaviour. `_rail.html.erb`: in `.rail-foot`, before the Sign out button, `<%= link_to settings_path, class: "rail-btn rail-settings", "aria-current": (rail_section == "settings" ? "page" : nil) do %><%= rail_icon(:settings) %><span>Settings</span><% end %>` — add `ICON_PATHS[:settings]` (a gear: `"M8 5a3 3 0 1 0 0 6 3 3 0 0 0 0-6z M8 1.5v2 M8 12.5v2 M1.5 8h2 M12.5 8h2 M3.4 3.4l1.4 1.4 M11.2 11.2l1.4 1.4 M3.4 12.6l1.4-1.4 M11.2 4.8l1.4-1.4"`); check `shell.css` for how `.rail-btn` renders an `<a>` (it may style only `button`) and whether `[aria-current="page"]` on a foot link needs a rule (mirror `a.rail-link[aria-current=page]`'s colour, scoped `.rail-foot .rail-btn[aria-current="page"]`). Tags index view: `page-head` (h1 Tags, `link_to "Settings", settings_path, class: "btn ghost small"`), a `p.muted` line, `ul.settings-list` rows (`a.settings-name[href=tag_path]` the chip-styled name, `span.settings-fact` "N things" or "unused", `button_to "Remove", settings_tag_path(tag), method: :delete, class: "linkbtn danger small settings-remove", form: { data: { turbo_confirm: "Remove “#{name}” from everything wearing it?" } }`), `li.empty.muted` when none. CSS in `pages/settings.css`: `.settings-hub .settings-fact { margin-left: auto }`, `.theme-choice { display: flex; gap: 6px; align-items: center; flex-wrap: wrap }`, `.theme-choice .theme-option[aria-pressed="true"] { border-color: var(--accent); color: var(--accent) }`.

- [ ] **Step 4: run** `settings_hub_test.rb shell_layout_test.rb page_query_budget_test.rb template_hygiene_test.rb css_hygiene_test.rb stimulus_hygiene_test.rb account_settings_test.rb settings_reference_test.rb shelves_test.rb` + `bin/ci style`; then `bin/rails test test/system/settings_theme_test.rb test/system/shell_test.rb` once.

- [ ] **Step 5: mutation-check** (stage first; verbatim; restore): (a) `Settings::TagsController#destroy` via `Maker::Tag.find` → the foreign-404 test fails; (b) `@counts` computed per row (`tag.taggings.count` in the view) → the tags budget fails; (c) `choose` skipping the cookie write → the system test's reload assertion fails; (d) the foot link without `aria-current` → the shell_layout active-state test fails.

- [ ] **Step 6: commit** with a pathspec: `The settings hub: shelves, suppliers, locations, tags, account and theme behind one door in the rail's foot`.

### Task C: close-out (the orchestrator)

- [ ] Look at `/settings` and `/settings/tags` on the dev server; `bin/ci`; `/finish-branch`; `bin/log arc --from-pr <n>`.
