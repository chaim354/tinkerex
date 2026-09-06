# Stage 3, S3-5: Releases — implementation plan

> **For agentic workers:** execute per `.claude/commands/execute-plan.md` (batched by file, parallel
> where disjoint, one capped quality review per task). Steps use checkbox (`- [ ]`) syntax.

**Goal:** a maker creates a release from the project page — a version, an optional git tag from one
of the folder's repositories, the current BOM revision, every file's version at that moment, and a
changelog — and both the private and the public page list releases with downloads and a
"changed since this release" signal per file.

**Architecture:** spec `docs/superpowers/specs/2026-09-04-stage-3-publishable-project-design.md`
§2.3, §3, §4 (S3-5), §6. Two tables (`maker_releases`, `maker_release_files`). **A release never
copies bytes** (§3): it records each file's `content_token` from ONE `stat_all` over the folder's
rows, and a download delivers the CURRENT file through the existing blob / public file routes —
exact on `chunk_remote` (the token is the sync server's version id) and recorded on share/s3 (the
token is the content hash), where the page says "changed since this release" when the current token
differs. Old-version downloads are out of stage 3 (§6). The tag picker reads tags only where the
library is a local folder (`capabilities.local_worktree?`, the repo card's own rule in
`docs/invariants/git-editing.md`); elsewhere a tag is recorded as typed, unverified.

**Tech:** Rails 8, Hotwire (plain forms + redirects, the wiring panel's pattern), Action Text with
`Maker::TextOnlyRichText` for the changelog, rugged through `Maker::Git::LocalRepo`,
`Maker::ProjectFolderListing`, `FileLayer.current.stat_all`, `Maker::PublicProject`.

---

## Rounds

| round | task | files |
|---|---|---|
| 1 | **A** data, models, `LocalRepo#tags`, `Maker::ReleaseSnapshot`, their tests and the three derived guards | migration, `db/schema.rb`, `docs/schema-map.html`, `lib/schema_map.rb`, models, `local_repo.rb`, `release_snapshot.rb`, `test/models/**`, `test/services/**`, `structural_orphan_test.rb`, `tenant_cleanup_test.rb` |
| 2 | **B** routes, `Projects::ReleasesController`, the private and public panels, `PublicProject#releases`, CSS, integration/public tests, budgets, template hygiene, the phone sweep, docs | everything under `app/controllers`, `app/views`, `app/assets`, `config/routes.rb`, `app/services/maker/public_project.rb`, `test/integration/**`, `test/system/**`, `CLAUDE.md`/docs |

Base branch: `claude/stage-3-releases` (from `main` at `bfab5ff`). Pathspec commits, `git checkout --`
restores, every mutation reported with actual output. Env: `export LIBRARY_BACKEND=share
LIBRARY_PATH=$(mktemp -d)`; migrations: `RAILS_ENV=test bin/rails db:prepare`.

**The four guards a new table trips** (memory `new-table-guard-checklist`): `test/schema_map_test.rb`
(LAYOUT + EDGES + `bin/rails schema:map`), `test/models/tenant_cleanup_test.rb` (a builder per
table, in `BUILD_ORDER`), `test/models/structural_orphan_test.rb` (a case per new edge),
`test/integration/web/template_hygiene_test.rb` (every new partial rendered by a page). Run those
four files before the full gate.

---

## Task A — data, models, tags, the snapshot

### A.1 Migration

```ruby
class CreateMakerReleases < ActiveRecord::Migration[8.1]
  def change
    create_table :maker_releases do |t|
      t.references :user, null: false, foreign_key: true, index: false
      t.references :project, null: false, index: false
      t.string   :version, null: false
      t.string   :git_tag
      t.string   :git_oid
      t.string   :repo_node_id
      t.references :bom, null: true, index: false
      t.integer  :bom_revision
      t.datetime :published_at, null: false
      t.timestamps
    end
    # One version per project; the panel and the public page read "newest first" by project.
    # Neither index is a prefix of the other (test/architecture_invariants_test.rb's prefix guard).
    add_index :maker_releases, %i[user_id project_id version], unique: true
    add_index :maker_releases, %i[project_id published_at]

    create_table :maker_release_files do |t|
      t.references :user, null: false, foreign_key: true, index: false
      t.references :release, null: false, index: false
      t.string  :node_id, null: false
      t.string  :name, null: false
      t.string  :path
      t.string  :content_token
      t.bigint  :size
      t.timestamps
    end
    add_index :maker_release_files, %i[release_id node_id], unique: true
    add_index :maker_release_files, %i[user_id node_id]
  end
end
```

`repo_node_id` and `path` are two columns beyond spec §3's list, and both are load-bearing: a
project folder may hold several repositories, so a tag is meaningless without the repo it came
from; and a file's folder-relative path at release time is what the panel shows after the file has
moved (its `node_id` survives a move, its path does not). `notes` is Action Text, so it is a rich
text row, not a column.

Then `bin/rails db:migrate && RAILS_ENV=test bin/rails db:prepare`, add both tables to
`lib/schema_map.rb`'s maker LAYOUT row (beside `maker_connections`) and three EDGES:

```ruby
    [ "maker_releases.project_id",       "maker_projects.id", "app", "released from" ],
    [ "maker_releases.bom_id",           "maker_boms.id",     "app", "BOM revision recorded" ],
    [ "maker_release_files.release_id",  "maker_releases.id", "app", "file of" ],
```

then `bin/rails schema:map` and `bin/rails test test/schema_map_test.rb`.

### A.2 Models

`app/models/maker/release.rb`:

```ruby
module Maker
  # A RELEASE IS A SNAPSHOT OF REFERENCES, NEVER OF BYTES (stage 3, S3-5; spec §2.3, §3): the
  # version the maker named, the git tag and the commit it pointed at, the BOM revision that was
  # current, and one row per file with the content token the port reported at that moment. The
  # bytes stay where they are; a download delivers the current file, and the page compares tokens.
  class Release < ApplicationRecord
    self.table_name = "maker_releases"

    VERSION_RE = /\A[A-Za-z0-9][A-Za-z0-9._-]{0,39}\z/

    belongs_to :user
    belongs_to :project, class_name: "Maker::Project"
    belongs_to :bom, class_name: "Maker::Bom", optional: true
    has_many :files, -> { order(:path, :name) }, class_name: "Maker::ReleaseFile",
             foreign_key: :release_id, dependent: :destroy
    has_rich_text :notes
    include Maker::TextOnlyRichText

    normalizes :version, with: ->(v) { v.to_s.strip }
    normalizes :git_tag, with: ->(t) { t.to_s.strip.presence }
    validates :version, presence: true, format: { with: VERSION_RE, message: "is letters, digits, dots, dashes and underscores, up to 40" },
              uniqueness: { scope: %i[user_id project_id], message: "is already a release of this project" }
    validates :published_at, presence: true
    validate :project_belongs_to_user

    def short_oid = git_oid.to_s[0, 8].presence

    private

    def project_belongs_to_user
      return if project_id.nil? || Maker::Project.exists?(id: project_id, user_id: user_id)

      errors.add(:project_id, "must reference your own project")
    end
  end
end
```

`app/models/maker/release_file.rb`: `belongs_to :user`, `belongs_to :release`, validates `node_id`
and `name` presence. `Maker::Project`: `has_many :releases, -> { order(published_at: :desc, id: :desc) }, class_name: "Maker::Release", foreign_key: :project_id, dependent: :destroy`.
`Maker::Bom`: `has_many :releases, class_name: "Maker::Release", foreign_key: :bom_id, dependent: :nullify`
(a release outlives its BOM's deletion; the recorded revision number stays). `User`:
`has_many :maker_releases, class_name: "Maker::Release", dependent: :destroy` and
`has_many :maker_release_files, class_name: "Maker::ReleaseFile", dependent: :destroy`.
Check how `Maker::TextOnlyRichText` expects to be included (read `app/models/maker/build_log_entry.rb`).

### A.3 `Maker::Git::LocalRepo#tags`

Beside `tags_at_head` (app/services/maker/git/local_repo.rb:175):

```ruby
      Tag = Data.define(:name, :oid)
      TAG_CAP = 200

      # Every tag with the COMMIT it resolves to (an annotated tag's target, a lightweight tag's own
      # target), newest name last by plain sort, CAPPED like every walk here (git-editing.md): a repo
      # with more tags than this lists the first TAG_CAP and the picker says so.
      def tags
        return [] if unborn?

        rugged.tags.first(TAG_CAP).map do |t|
          Tag.new(name: t.name, oid: t.annotated? ? t.annotation.target_id : t.target_id)
        end.sort_by(&:name)
      end
```

### A.4 `Maker::ReleaseSnapshot`

```ruby
module Maker
  # CREATES A RELEASE FROM WHAT THE PROJECT HOLDS RIGHT NOW. One folder listing, ONE stat_all over
  # its rows (never one stat per file — the same constancy rule the pages keep), the current BOM's
  # id and revision, and the tag resolved against the repository the maker picked. Refuses, rather
  # than records, a tag that does not exist in a repository it can read.
  class ReleaseSnapshot
    class TagNotFound < StandardError; end

    Result = Data.define(:release, :file_count, :tag_verified)

    def self.call(user:, project:, version:, notes: nil, git_tag: nil, repo_node_id: nil)
      new(user:, project:).call(version:, notes:, git_tag:, repo_node_id:)
    end

    def initialize(user:, project:)
      @user = user
      @project = project
      @listing = Maker::ProjectFolderListing.new(user, project)
    end

    def call(version:, notes:, git_tag:, repo_node_id:)
      git_oid, verified = resolve_tag(git_tag, repo_node_id)
      bom = @project.current_bom
      rows = @listing.all_rows.reject(&:backup?)
      info = rows.empty? ? {} : FileLayer.current.stat_all(@user, node_ids: rows.map(&:node_id))

      release = nil
      Maker::Release.transaction do
        release = @project.releases.create!(user: @user, version:, git_tag:, git_oid:,
                                            repo_node_id: (git_tag.presence && repo_node_id.presence),
                                            bom:, bom_revision: bom&.revision,
                                            published_at: Time.current, notes:)
        now = Time.current
        records = rows.filter_map do |row|
          stat = info[row.node_id] or next
          { user_id: @user.id, release_id: release.id, node_id: row.node_id, name: row.node.name,
            path: relative_path(row), content_token: stat.content_token, size: stat.size,
            created_at: now, updated_at: now }
        end
        Maker::ReleaseFile.insert_all(records) if records.any?
      end
      Result.new(release:, file_count: release.files.count, tag_verified: verified)
    end

    private

    # [oid, verified?]. Where the library is a local folder the tag must exist in the picked repo
    # (TagNotFound otherwise); elsewhere the tag is recorded as typed and verified is false.
    def resolve_tag(git_tag, repo_node_id)
      return [ nil, false ] if git_tag.blank?
      return [ nil, false ] unless FileLayer.current.capabilities.local_worktree? && repo_node_id.present?

      root = @user.nodes.present.find_by(node_id: repo_node_id, kind: "dir")
      raise TagNotFound, "no repository at #{repo_node_id}" if root.nil?

      local = Maker::Git::LocalRepo.open(@user, root)
      raise TagNotFound, local.refusal if local.refusal
      tag = local.tags.find { |t| t.name == git_tag }
      raise TagNotFound, "no tag #{git_tag} in #{root.name}" if tag.nil?

      [ tag.oid, true ]
    end

    def relative_path(row)
      full = @listing.path_for(row.node)
      full.to_s.delete_prefix("#{@listing.path}/").delete_prefix(@listing.path.to_s).delete_prefix("/")
    end
  end
end
```

Verify against the real code before writing: `Row#backup?`, `listing.path_for(node)` (returns the
PARENT dir's library path — confirm and join the name accordingly; the panel wants `models/base.stl`,
not `Projects/desk-lamp/models`), `FileInfo#content_token`/`#size`, `LocalRepo.open` + `#refusal`.
`stat_all` on chunk_remote answers from the mirror (§14a), so a token there is the version id.

### A.5 Tests

- `test/models/maker/release_test.rb`: version normalization/format (`"v0.1.0"`, `"1.0"`, `"2026-09-06"`
  ok; blank, 41 chars, `"v 1"`, `"../x"` refused), uniqueness per project (the same version on a
  second project is fine), `project_belongs_to_user`, `short_oid`, notes are text-only (a `<script>`
  in notes does not survive — see how `build_log_entry_test` pins `TextOnlyRichText`), destroying a
  BOM nullifies `bom_id` and keeps `bom_revision`, destroying a project destroys releases and files.
- `test/services/maker/git/local_repo_tags_test.rb` (under `use_fresh_share_library!` + `GitRepoFixture`):
  lightweight and annotated tags resolve to their commits; unborn → `[]`; the cap (create
  `TAG_CAP + 1` tags cheaply in a loop → `TAG_CAP` returned).
- `test/services/maker/release_snapshot_test.rb`: files captured with the port's tokens and sizes,
  backups excluded, `path` folder-relative (`models/base.stl`), the BOM id + revision recorded,
  ONE `stat_all` call (count with `replacing` around `FileLayer.current.stat_all`), a verified tag
  → `git_oid` and `tag_verified: true`, a missing tag → `TagNotFound` and NO release row (the
  transaction), no tag → nil oid, a repo the port cannot open → `TagNotFound`, a non-local
  library (replace `capabilities` with one answering `local_worktree?: false`) → recorded unverified.
- Guards: a `CASES` entry for each of the three edges in `structural_orphan_test.rb`; builders for
  both tables in `tenant_cleanup_test.rb`'s `BUILDERS` + `BUILD_ORDER` (a release needs a project;
  a release file needs a release).
- Mutations, each with actual output: drop the uniqueness scope → the per-project test; drop
  `dependent: :nullify` on `Bom#releases` → the orphan case; snapshot per-row `stat` instead of
  `stat_all` → the one-call test; drop the transaction → the missing-tag test finds a release row;
  `reject(&:backup?)` removed → the backups test.

Commit A. Run the five test files + `test/schema_map_test.rb test/architecture_invariants_test.rb`
+ rubocop.

---

## Task B — the panels, the doors, the guards

### B.1 Routes and controller

In the `resources :projects do` block: `resources :releases, only: %i[create destroy], module: :projects, shallow: true`.

```ruby
module Projects
  class ReleasesController < ApplicationController
    def create
      project = current_user.maker_projects.find_by!(slug: params[:project_id])
      attrs = params.require(:release).permit(:version, :git_tag, :repo_node_id, :notes)
      result = Maker::ReleaseSnapshot.call(user: current_user, project:, version: attrs[:version],
                                           notes: attrs[:notes], git_tag: attrs[:git_tag],
                                           repo_node_id: attrs[:repo_node_id])
      redirect_to project_path(project), notice: "Released #{result.release.version} with #{result.file_count} #{'file'.pluralize(result.file_count)}#{' (tag recorded, not verified)' unless result.tag_verified || attrs[:git_tag].blank?}."
    rescue ActiveRecord::RecordInvalid => e
      redirect_to project_path(project), alert: "Release not created: #{e.record.errors.full_messages.to_sentence}."
    rescue Maker::ReleaseSnapshot::TagNotFound => e
      redirect_to project_path(project), alert: "Release not created: #{e.message}."
    end

    def destroy
      release = current_user.maker_releases.find(params[:id])
      project = release.project
      release.destroy!
      redirect_to project_path(project), notice: "Removed release #{release.version}."
    end
  end
end
```

### B.2 The private panel — `app/views/projects/_releases.html.erb`

Rendered from `projects/show.html.erb` after the wiring panel (line 83), with
`render "releases", project: @project, releases: @releases, current_tokens: @release_tokens, repos: @release_repos, editable: true`.
`ProjectsController#show` adds:

```ruby
    @releases = @project.releases.includes(:files, :rich_text_notes).to_a
    # ONE stat_all over every file of every release shown, so "changed since" is constant in N.
    release_node_ids = @releases.flat_map { |r| r.files.map(&:node_id) }.uniq
    @release_tokens = release_node_ids.empty? ? {} : FileLayer.current.stat_all(current_user, node_ids: release_node_ids)
    # The tag picker: each repo's tags, only where git facts are readable (the repo card's rule).
    @release_repos = capabilities.local_worktree? ? release_repo_tags(repo_dirs, repo_roots) : []
```

where `release_repo_tags` opens each repo dir the page already collected (`repo_dirs`,
`repo_roots` exist in `#show`) and answers `[[dir_name, node_id, [tag names]]]`, rescuing
`Rugged::Error`/`FileLayer::*` per repo to `[]`. Check `includes(:rich_text_notes)` is the
association name Action Text gives `has_rich_text :notes`.

Panel markup (`section.panel.releases-panel`, `.panel-head` with `h2` "Releases" and the count):
- empty state `p.muted` "No releases yet."
- one `details.release` per release (`open` on the newest): `summary` holds `span.release-version.mono`,
  `time` (published_at date), `span.badge` tag + `span.mono.muted` short oid when present (a
  recorded-not-verified tag shows the tag with `title="recorded, not verified"` and no oid),
  `span.muted` "BOM rev N" when present, `span.muted` "N files", and `span.badge.changed`
  "N changed since" when any file's current token differs (nil current → counts as changed: the
  file is gone). Inside: `div.release-notes.markdown` → `release.notes` when present; a
  `table.table.release-files` of `td.col-path` path (or name), `td.col-size.num`
  `number_to_human_size`, `td.col-state` "changed" / "gone" / "" (`span.badge.changed`),
  `td.col-dl` `link_to "Download", blob_file_path(f.node_id, download: 1)` when the node is
  current (token present), else "no longer in the library"; and, when `editable`, a
  `button_to "Remove release", release_path(release), method: :delete, class: "linkbtn danger small", form: { data: { turbo_confirm: … } }`.
- when `editable`, the composer `details.composer.release-add` with
  `form_with url: project_releases_path(project), scope: :release` (§14d: scope names the params):
  `f.text_field :version` (required, placeholder "v0.1.0"), a repo+tag select when `repos.any?`:
  `f.select :git_tag, grouped_options_for_select(repos.map { |name, id, tags| [name, tags] })` plus
  a hidden/select `f.select :repo_node_id, repos.map { |name, id, _| [name, id] }` (one select per
  repo is simpler: render a `select[name="release[git_tag]"]` whose options carry
  `data-repo="<node_id>"`, and set `release[repo_node_id]` from the chosen option with a tiny
  Stimulus-free trick: encode `"<node_id>:<tag>"` as the option value and split in the controller.
  DECIDE ONE and assert the rendered field names), `f.text_field :git_tag` free text when
  `repos.empty?` (with `p.muted` "Tags can be verified where the library is a local folder."),
  `f.rich_text_area :notes, placeholder: "What changed?", attachments: "false"` (the build-log
  form's shape), `f.submit "Create release", class: "btn small primary"`.

If you pick the `"<node_id>:<tag>"` encoding, the controller splits `params[:release][:git_tag]`
on the FIRST colon when `repo_node_id` is blank; a node_id is a UUID (no colons). Say so in a
comment and pin it with a test that posts the encoded value.

### B.3 The public panel — `app/views/public/projects/_releases.html.erb`

`Maker::PublicProject#releases` (`project.releases.includes(:files, :rich_text_notes).to_a`) and
`#release_tokens` (one `stat_all` over the owner, same shape). Rendered from
`public/projects/show.html.erb` after the wiring panel, omitted when empty. Same markup as the
private panel minus the composer and the remove button; downloads are
`pub.file_url_for(f.node_id, download: true)` and ONLY when `pub.permits?(node)` for the node —
resolve the nodes through `pub.page_nodes`-style batching: add the release files' node ids to
`page_nodes`' id list so `permits?` stays batched (`visible_page_ids`). A file that no longer
permits (gone, moved out, tombstoned) renders "no longer available" with no link. Notes render
as Action Text HTML like entry bodies.

### B.4 CSS

`pages/projects.css` (private) and `pages/public.css` (public), both inside their `@layer pages`:
`.releases-panel details.release > summary` (flex, gap, wrap), `.release-version` (mono, 600),
`.release-files .col-size`, `.release-files .col-state`, `.badge.changed` → this is a COMPONENT
badge modifier and belongs in `components.css` beside `.badge.visibility-*` (accent-soft), column
drops: `.release-files .col-size` at 719px, `.col-state` at 479px (readability, say so).

### B.5 Tests

`test/integration/web/project_releases_test.rb` (sign in; fixture via `use_fresh_share_library!` +
`project_folder_rows!` + `create_node!` with real bytes, a repo through `GitRepoFixture` where a
tag is needed):
1. the panel's empty state; the composer's rendered field names (`release[version]`,
   `release[git_tag]` or the encoded select, `release[notes]`), `form[action=?]`.
2. create → 302, flash names the file count, a release row with N files and the BOM revision;
   the panel lists it newest first with `time`, version, "N files".
3. create with a tag from the fixture repo → `git_oid` set and the short oid rendered.
4. create with a missing tag → alert, no release.
5. duplicate version → alert naming the uniqueness error.
6. "changed since": `update_column(:content_hash, "h-changed")` on one file's node (share's
   `stat_all` reads the catalog) → `.badge.changed` "1 changed since" and the row's `col-state`.
7. a file deleted after the release (`update!(deleted: true)`) → "no longer in the library", no link.
8. destroy → 302, gone; destroy of a foreign release → 404; create against a foreign slug → 404.
9. the public page (`public_project_path`) lists the release with public download links carrying
   the unlisted `k`, no composer, no Remove; the gone file has no link; notes render; a private
   project → 404 as before.
Mutations: drop the `includes(:files)` → the budget test below; drop `permits?` on the public
download → a moved-out file gets a link (test 9's gone case); `order(published_at: :desc)` dropped
→ the newest-first test; `scope: :release` dropped → the field-name test.

`page_query_budget_test.rb`: extend the `projects#show` seed with `add`-style releases (each with
files) and assert constancy; likewise the `public projects#show` budget. `template_hygiene_test.rb`:
seed one release with files and notes so both new partials render populated (the guard names an
unrendered template). `shell_test.rb`: seed a release with a long version and three files so the
summary wraps and the table drops at 375px; keep the KiCanvas ignore. `css_hygiene_test.rb`: no new
sheet, nothing to add. CLAUDE.md: no new bullet needed — the invariants are the spec's ("a release
never copies bytes") and belong in `docs/invariants/project-intake.md`? No: add ONE short bullet to
`docs/invariants/files-preview.md`? Neither fits; put a 4-line "Releases" note at the end of the
spec's §6 instead and leave CLAUDE.md alone (its ceiling is 1364 and full).

Commit B. Run the new files + `project_page_test.rb public_project_test.rb public_file_test.rb
page_query_budget_test.rb template_hygiene_test.rb css_hygiene_test.rb stimulus_hygiene_test.rb
test/system/shell_test.rb` + rubocop.

---

## Self-review against the spec

- §2.3 "a release is a full snapshot with a changelog: a git tag (or none), the BOM revision, every
  design file's version at that moment, and a changelog entry": A.4 records tag + oid, bom +
  revision, every non-backup file's token; notes are the changelog.
- §3 table columns: present (plus `repo_node_id`, `path`, argued in A.1). "exact on chunk_remote,
  recorded on share/s3, 'changed since this release' when the current hash differs, never copies
  bytes": B.2/B.3 compare tokens from one `stat_all`; downloads go through the existing routes.
- §4 S3-5 row: "create a release from the project page (pick a tag, records the BOM revision and
  every design file's version, takes a changelog); a Releases section on both pages with downloads":
  B.1–B.3.
- §6: public panel through `PublicProject`, `permits?` on every link, budgets + sweep + form scope +
  rendered field names, no new dependency.
- Deliberately out: old-version downloads, editing a release after creation (delete and recreate),
  a release detail page, notifying anyone (S3-6's feed reads releases).
