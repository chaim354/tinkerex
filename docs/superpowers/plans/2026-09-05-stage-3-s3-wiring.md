# Stage 3, S3-3: wiring — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking. **In this repo `.claude/commands/execute-plan.md` overrides the generic loop:** batch by file, dispatch disjoint tasks in parallel, no spec-compliance stage, one capped quality review per task with its mutations run and their output reported.

**Goal:** Deliver S3-3 of `docs/superpowers/specs/2026-09-04-stage-3-publishable-project-design.md` (§4): a **Wiring** panel on the project page — a connections table (from, to, wire or pin, note) edited inline, in order — whose read-only rendering S3-4 will reuse on the public page. One new table; every page's query count constant in N.

**Architecture:** `Maker::Connection` (`maker_connections`: user, project, from_label, to_label, wire, note, position) with the `project_belongs_to_user` validation the other project children carry; `Projects::ConnectionsController` (create / update / destroy, shallow like tasks, redirect-back doors, no JS); one partial `projects/_wiring.html.erb` rendering a `table.table.wiring` whose rows are inline `form_with … scope: :connection` forms with Save and Remove when `editable`, plain cells otherwise, and an add form below; the routes are committed (`project_connections_path(project)`, `connection_path(c)`).

**Tech Stack:** Rails 8 (one migration), Hotwire, Minitest, `page_query_budget_test.rb`.

---

## Before you start

- Branch `claude/stage-3-wiring` from `main` at `a4cddfc`; the routes are committed (`14258b7`). Worktree `/Users/charlesschwartz/Desktop/repos/tinkerex/.claude/worktrees/auto-model-folder-files-bug-112353`. Never push to `main`.
- Tests: `export LIBRARY_BACKEND=share LIBRARY_PATH=$(mktemp -d)`; style `bin/ci style`; one full-suite run at a time. **The migration**: `bin/rails generate migration CreateMakerConnections`, then `bin/rails db:migrate` (development) and `RAILS_ENV=test bin/rails db:prepare`; commit `db/schema.rb`; add the table to `lib/schema_map.rb`'s "Models & projects" column and run `bin/rails schema:map` (the guard `test/schema_map_test.rb` refuses a table with no column — S3-1 learned this); add the table to `test/models/tenant_cleanup_test.rb`'s builder/`BUILD_ORDER` (its header says every `user_id` table must be there).
- Read `docs/invariants/design-system.md`; CLAUDE.md §14d's `form_with scope:` bullet (assert rendered field names) and the `*_belongs_to_user` bullet; `app/models/maker/bom.rb` (the `project_belongs_to_user` shape), `app/controllers/projects/tasks_controller.rb` and `bom_lines_controller.rb` (the door shape: `current_user.maker_projects.find_by!(slug:)`, `redirect_back_or_to`), `app/views/projects/_tasks.html.erb` and `_bom_lines.html.erb` (panel + composer shape), `app/views/settings/filing_rules/index.html.erb` (inline per-row edit forms from S3-1), `app/views/projects/show.html.erb` (panel order), `test/integration/web/project_bom_test.rb` (a recent panel test's shape), `page_query_budget_test.rb`'s `projects#show` seed, `template_hygiene_test.rb`'s project fixture, `test/system/shell_test.rb` (the project page is already in the sweep — the panel must not widen it).
- `git checkout -- <file>` cannot restore a new file: `git add` before a mutation check.

## The one task

- [ ] **Step 1: migration and model.**

```ruby
class CreateMakerConnections < ActiveRecord::Migration[8.1]
  def change
    create_table :maker_connections do |t|
      t.references :user, null: false, foreign_key: true, index: false
      t.references :project, null: false, index: false
      t.string :from_label, null: false
      t.string :to_label, null: false
      t.string :wire
      t.text :note
      t.integer :position, null: false, default: 0
      t.timestamps
    end
    add_index :maker_connections, %i[user_id project_id position]
  end
end
```

`Maker::Connection`: `self.table_name = "maker_connections"`; `belongs_to :user`; `belongs_to :project, class_name: "Maker::Project"`; `normalizes :from_label, :to_label, :wire, with: ->(s) { s.to_s.strip }`; `validates :from_label, :to_label, presence: true, length: { maximum: 120 }`; `validates :wire, length: { maximum: 60 }`; `validates :note, length: { maximum: 500 }`; `validate :project_belongs_to_user` (Bom's shape). `Maker::Project has_many :connections, -> { order(:position, :id) }, class_name: "Maker::Connection", foreign_key: :project_id, dependent: :destroy`; `User has_many :maker_connections` (follow the neighbours). Model tests: presence, lengths, normalization, the cross-user refusal, the project's destroy cascades.

- [ ] **Step 2: the controller.** `Projects::ConnectionsController < ApplicationController`: `create` (`project = current_user.maker_projects.find_by!(slug: params[:project_id])`; `position` = max + 1; `connection_params` = `params.require(:connection).permit(:from_label, :to_label, :wire, :note)`; save → `redirect_back_or_to project_path(project), notice: "Added #{from} → #{to}."`, else alert with `errors.full_messages.to_sentence`), `update` (`current_user.maker_connections.find(params[:id])`, same params, notice "Saved."), `destroy` (find, destroy!, notice "Removed …"). Foreign ids 404 by construction.

- [ ] **Step 3: the panel.** `projects/_wiring.html.erb` (locals: `project`, `connections`, `editable`): `section.panel.wiring-panel` with `panel-head` (h2 Wiring, `span.mono.muted` "N connections"); when `connections.empty?` a `p.muted` "No connections yet."; else `table.table.wiring` — `thead` From | To | Wire | Note | (actions when editable) — and one `tr.wiring-row` per connection: when `editable`, the four cells hold `text_field`s inside ONE `form_with model: connection, scope: :connection, url: connection_path(connection), method: :patch, id: "connection-#{id}"` — since a form cannot span table cells, put the form OUTSIDE the table (before it, `form_with … id:` with no fields) and give each field `form: "connection-#{id}"`; the actions cell holds `f.submit "Save", class: "btn small"` (with `form:`) and a `button_to "Remove", connection_path(connection), method: :delete, class: "linkbtn danger small", form: { data: { turbo_confirm: } }`; when not editable, plain cells. Below the table, when editable, `details.composer.wiring-add` (summary "Add connection") with `form_with url: project_connections_path(project), scope: :connection` and the four fields + submit "Add" (`btn small primary`). `projects/show.html.erb`: render it after the BOM panel with `editable: true`; `ProjectsController#show` loads `@connections = @project.connections.to_a` (ONE query). CSS in `pages/projects.css`'s layer: `.wiring input { width: 100% }`, `.wiring .col-note` drop at 719px, `.wiring .col-wire` at 479px; a `→` between From and To on the phone is not needed.

- [ ] **Step 4: tests.** `test/integration/web/project_wiring_test.rb`: the panel lists connections in position order with their four cells; the empty state; the add form's rendered names (`input[name='connection[from_label]']` … four) and `create` appends with the next position and redirects back with a flash; a blank `to_label` is refused with the message; `update` changes a row (assert the per-row form's `form` attribute wiring: `input[form=?]` `"connection-#{id}"` and the hidden `_method=patch`); `destroy` removes one and renumbers nothing (positions may gap; say so); a foreign connection 404s on update and destroy; a connection posted against another user's project slug 404s. Budget: the `projects#show` seed gains one connection per iteration — constant. `template_hygiene_test.rb`: the project fixture gains one connection so the populated branch renders. `tenant_cleanup_test.rb`: the table. `schema_map_test.rb` green after `bin/rails schema:map`.

- [ ] **Step 5: mutation-check** (stage first; verbatim; restore): (a) `update` unscoped (`Maker::Connection.find`) → the foreign-404 test fails; (b) drop `project_belongs_to_user` → the cross-user model test fails; (c) render the rows without `form:` attributes → the `input[form=?]` assertion fails; (d) load connections per row in the view (`project.connections.find(...)`) → the budget fails.

- [ ] **Step 6: commit** with a pathspec: `Wiring: a connections table on the project page, edited inline`.

### Close-out (the orchestrator)

- [ ] Look at the panel on the dev server; `bin/ci`; `/finish-branch`; `bin/log arc --from-pr <n>`.
