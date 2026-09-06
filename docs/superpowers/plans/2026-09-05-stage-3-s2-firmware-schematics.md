# Stage 3, S3-2: firmware and schematics — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking. **In this repo `.claude/commands/execute-plan.md` overrides the generic loop:** batch by file, dispatch disjoint tasks in parallel, no spec-compliance stage, one capped quality review per task with its mutations run and their output reported.

**Goal:** Deliver S3-2 of `docs/superpowers/specs/2026-09-04-stage-3-publishable-project-design.md` (§4). A **repository card** in a repo's section of the project tree: the README rendered, the latest commit, the current tag, links to the commit and history pages. **KiCad previews** in the browser with KiCanvas: the file page for `.kicad_sch` / `.kicad_pcb`, and a **Schematics** section on the project page when the folder holds such files. No new tables; query counts constant in N.

**Architecture:** `Maker::Git::LocalRepo` grows `head_summary` (oid, message, author, time) and `tags_at_head`, read through rugged where the working tree is local (`capabilities.local_worktree?` — git-editing.md's rule: ask the capability, never the adapter class); the README is a catalog file read through the port (git-editing.md: bytes the catalog tracks go through the port) and rendered by `Maker::Markdown` (kramdown, already a dependency, with raw HTML stripped and relative links resolved against the repo's folder through the listing tree). KiCanvas is ONE vendored ES module built from a pinned commit by `bin/build-kicanvas` (committed with the scaffold: `vendor/javascript/kicanvas.js`, `LICENSE-kicanvas.md`, the importmap pin), loaded lazily by a `kicanvas` Stimulus controller that inserts `<kicanvas-embed>` pointing at the file's blob URL — the same door the 3D viewer's loaders fetch through.

**Tech Stack:** Rails 8, rugged, kramdown, one Stimulus controller, Minitest, one system test.

---

## Before you start

- Branch `claude/stage-3-firmware-schematics` from `main` at `b599e2b`; the scaffold commit carries `bin/build-kicanvas`, the vendored build, its licence notices and `pin "kicanvas"`. Worktree `/Users/charlesschwartz/Desktop/repos/tinkerex/.claude/worktrees/auto-model-folder-files-bug-112353`. Never push to `main`.
- Tests: `export LIBRARY_BACKEND=share LIBRARY_PATH=$(mktemp -d)`; style `bin/ci style`; one full-suite run at a time; commit with a pathspec.
- **Read `docs/invariants/git-editing.md` first** (binding for anything under `app/services/maker/git/`): ask `local_worktree?`; content against HEAD's blob never a stat; `Maker::Git::History.new` dereferences the port so `refusal` is checked first; the ancestor walk is `Library::WorkingTree`; no name `tinkerex#161` used. Read `docs/invariants/files-preview.md` (the file page's `preview_kind`, `EXT_RE`, why `kicad_sch`/`kicad_pcb` are DELIBERATELY absent from `ROLE_BY_EXT` — they fail `EXT_RE`, so a preview kind for them is a constant beside `MEASURABLE_EXTS`, never a `ROLE_BY_EXT` entry). Read `docs/invariants/design-system.md` and `test/system/README.md` (a Stimulus controller earns one mutation-checked system test).
- **KiCanvas facts** (checked 2026-09-04): MIT with permissive notices (ISC, CC0/MIT-like, OFL, Apache-2.0); `<kicanvas-embed src="…" controls="basic|full">` fetches `src` and renders on Canvas/WebGL; the module registers the custom element on import. The CSP (`config/initializers/content_security_policy.rb`) allows `script-src 'self'` (the vendored module), `img-src data: blob:`, `font-src data:`; `connect-src` is the default `'self'`, so on **s3** a presigned redirect is blocked for KiCanvas exactly as it is for the 3D viewer today — a shared, pre-existing limitation, out of scope here; say so in a comment where the embed is built.
- `git checkout -- <file>` cannot restore a new file: `git add` before a mutation check. Another agent shares the index.

## File structure

| path | responsibility | task |
|---|---|---|
| `app/services/maker/git/local_repo.rb` (`head_summary`, `tags_at_head`), `app/services/maker/markdown.rb` (new), `app/helpers/repo_card_helper.rb` (new, optional) | git facts and README rendering | A |
| `app/controllers/projects_controller.rb` (`#show`: `@repo_cards`), `app/views/projects/_repo_card.html.erb` (new), `app/views/projects/_file_tree_section.html.erb` (renders the card in a repo section), `app/assets/stylesheets/pages/projects.css` (`.repo-card`, `.markdown`) | the card | A |
| `test/services/maker/git/local_repo_test.rb` (or the existing git test file), `test/services/maker/markdown_test.rb` (new), `test/integration/web/project_repo_card_test.rb` (new), `page_query_budget_test.rb` (projects#show seed grows repos), `template_hygiene_test.rb`, `docs/invariants/git-editing.md` (one bullet) | A's tests and docs | A |
| `app/javascript/controllers/kicanvas_controller.js` (new), `app/controllers/files_controller.rb` (`KICANVAS_EXTS`, `preview_kind` → `:kicanvas`), `app/views/files/show.html.erb` (the `:kicanvas` branch), `app/views/projects/_schematics.html.erb` (new), `app/views/projects/show.html.erb` (render it after the Files panel), `app/assets/stylesheets/pages/preview.css` (`.kicanvas-stage`) | the previews | B |
| `test/integration/web/kicanvas_preview_test.rb` (new), `test/system/kicanvas_test.rb` (new), `test/system/shell_test.rb` (sweep gains a `.kicad_sch` file page), `template_hygiene_test.rb` (B's two templates — coordinate: A owns the file; B reports the lines), `docs/invariants/files-preview.md` (one bullet: the `:kicanvas` kind and why its extensions sit outside `ROLE_BY_EXT`) | B's tests and docs | B |

**Dependencies:** A and B are disjoint (A owns `_file_tree_section` and `projects_controller.rb`; B owns `projects/show.html.erb` and the files pages). Both run in parallel. C closes out.

---

### Task A: the repository card

- [ ] **Step 1: git facts.** In `Maker::Git::LocalRepo`:

```ruby
      Head = Data.define(:oid, :short_oid, :summary, :author, :time)

      # The commit HEAD points at, for a card — nil when unborn. Reads rugged only; a repo whose
      # `refusal` is set (not local, no .git, locked) must not reach here: the caller asks first.
      def head_summary
        return nil if unborn?
        c = rugged.head.target
        Head.new(oid: c.oid, short_oid: c.oid[0, 7], summary: c.message.lines.first.to_s.strip,
                 author: c.author[:name], time: c.time)
      end

      # Tag names whose target is HEAD (annotated tags peeled), sorted; [] when none.
      def tags_at_head
        return [] if unborn?
        head = rugged.head.target_id
        rugged.tags.select { |t| t.target_id == head || (t.annotated? && t.annotation.target_id == head) }.map(&:name).sort
      end
```

Tests beside the existing LocalRepo tests (find them: `grep -rln "LocalRepo" test/`), using the suite's git fixture (`test/support/git_repo_fixture.rb`): `head_summary` reads the last commit's oid/summary/author/time; an unborn repo answers nil; `tags_at_head` returns a lightweight tag and an annotated tag on HEAD, not a tag on an older commit, `[]` when none.

- [ ] **Step 2: Markdown.** `app/services/maker/markdown.rb`:

```ruby
module Maker
  # README rendering (stage 3): kramdown (a dependency already) with RAW HTML STRIPPED — a README is
  # the user's prose, never trusted markup — and relative links resolved by the caller's block, so a
  # `[base](models/base.stl)` becomes the file page when the path exists and plain text when it does
  # not. `render` returns an html_safe String that has been through Rails' sanitizer with an
  # allowlist of the elements kramdown emits for GFM prose.
  class Markdown
    ALLOWED_TAGS = %w[p br h1 h2 h3 h4 h5 h6 ul ol li strong em code pre blockquote a img table thead tbody tr th td hr del].freeze
    ALLOWED_ATTRS = %w[href src alt title].freeze

    # resolve: ->(href) { url-or-nil } for RELATIVE hrefs (no scheme, no leading slash); nil drops the link
    def self.render(text, &resolve)
      html = Kramdown::Document.new(text.to_s, input: "GFM", hard_wrap: false, syntax_highlighter: nil).to_html
      rewritten = rewrite_relative_links(html, &resolve)
      ActionController::Base.helpers.sanitize(rewritten, tags: ALLOWED_TAGS, attributes: ALLOWED_ATTRS)
    end
  end
end
```

(`kramdown-parser-gfm` is needed for `input: "GFM"`; check the Gemfile — if absent, add `gem "kramdown-parser-gfm", "~> 1.1"` (MIT) with a Gemfile comment naming why, and run `bundle install`; if adding a gem is undesirable, plain kramdown input is acceptable and the tests say so.) `rewrite_relative_links` walks `<a href>` and `<img src>` with Nokogiri (present via rails-html-sanitizer's dependency): absolute (`http(s):`, `mailto:`) kept; a leading `#` kept; a relative one replaced by `resolve.call(href)` or, when nil, the anchor unwrapped to its text (an image dropped). Tests: headings/lists/code render; `<script>` and `onclick` are stripped; a relative link resolves through the block; an unresolvable one becomes text; an absolute link survives; `javascript:` hrefs are dropped by the sanitizer.

- [ ] **Step 3: the card.** `ProjectsController#show`: for each repo `Dir` in the listing's tree (`@listing.tree` has `repo?` dirs at any depth — collect them), build `@repo_cards[dir.node_id] = Maker::RepoCard.new(...)`? Keep it a PORO in `app/services/maker/repo_card.rb` (A owns it): `RepoCard.for(user:, dir:, listing:, capabilities:)` → `Data(:dir, :head, :tags, :readme_html, :refusal)`. Facts: when `capabilities.local_worktree?`, `LocalRepo.open(user, root_node)` and, if `refusal.nil?`, `head_summary` + `tags_at_head` (rescue `Rugged::Error` → `refusal: "history unavailable"`); otherwise `head: nil` and a one-line reason ("history is available where the library is a local folder"). README: the first of `README.md`, `README`, `readme.md` among the dir's files in the listing (in memory, no query); read through the port (`FileLayer.current.read(user, node_id:)` — check the verb's signature; cap at 64 KB; `FetchError` → `readme_html: nil` and a "README unavailable" line); rendered with `Maker::Markdown.render(text) { |href| … }` resolving `href` against the dir's subtree in the listing (`Row#node.name` joined with `path_for`) to `file_path(node_id)`. Constant queries: the README read is one port call per repo, and repos per project are a fixture constant (the budget test's seed grows files, not repos — but DO add one repo to the seed so the card is under measurement; the read's cost is O(repos), say so in the test). `_repo_card.html.erb`: `div.repo-card` with a `.repo-facts` line (`short_oid` linking to `repo_commit_path(dir.node_id)`, the summary, the author, `time_ago_in_words`, the tags as `.badge`s or "no tag"), links "Commits" and "History" (`repo_history_path`), and `details.readme[open]` → `div.markdown` with the rendered README, or the reason line. `_file_tree_section.html.erb`: render the card at the top of a repo section, before its files. CSS in `pages/projects.css`'s layer: `.repo-card`, `.repo-facts`, `.markdown` (headings scaled, code blocks, `max-height: 360px; overflow: auto`).

- [ ] **Step 4: tests.** `project_repo_card_test.rb` (share library via `use_fresh_share_library!`, a real repo via the git fixture inside the project's folder, its files indexed with `create_node!`): the card shows the short oid linking to the commit page, the summary, the tag; a repo with no tag says "no tag"; the README renders (`h1`, a list) with raw HTML stripped and a relative link `[base](models/base.stl)` resolved to `file_path`; a README beyond the cap is truncated with a note; when `local_worktree?` is false (pin the s3 backend for one test, or `replacing` the capability) the card shows the reason and still renders the README. Budget: the `projects#show` seed gains one repo (with a `.git` marker AND a `README.md` node) at the first step only. Template hygiene: the fixture project gains a repo section whose card renders (a `.git`-marked dir + README node exist in its setup already? add the README). Docs: `git-editing.md` gains a bullet under "Ask local_worktree?" naming the card as a reader that asks the capability and reads the README through the port.

- [ ] **Step 5: mutation-check** (stage first; verbatim; restore): (a) `Maker::Markdown` without the sanitizer → the `<script>` test fails; (b) resolve relative links to the raw href → the resolved-link test fails; (c) `head_summary` reading `rugged.head.target` on an unborn repo (drop the guard) → the unborn test errors; (d) a README read per row (call `FileLayer.current.read` inside the tree loop for every file) → the budget fails.

- [ ] **Step 6: commit** with a pathspec: `A repository card: the README rendered, the latest commit, the current tag, from the working tree and the port`.

---

### Task B: KiCad previews with KiCanvas

- [ ] **Step 1: the controller and the module.** `app/javascript/controllers/kicanvas_controller.js`:

```js
import { Controller } from "@hotwired/stimulus"

// KiCad schematics and boards, rendered in the browser (stage 3, S3-2). The KiCanvas module is
// ONE vendored build (bin/build-kicanvas, importmap pin "kicanvas") and it is imported LAZILY here,
// on connect, so a page without a KiCad file never downloads it. The embed fetches `src` itself —
// the file's blob URL, the same door the 3D viewer's loaders use (on s3 a presigned redirect is
// blocked by connect-src 'self' for both; a shared, pre-existing limitation).
export default class extends Controller {
  static values = { url: String, controls: { type: String, default: "basic" } }
  static targets = ["stage", "status"]

  async connect() {
    try {
      await import("kicanvas")
      const embed = document.createElement("kicanvas-embed")
      embed.setAttribute("src", this.urlValue)
      embed.setAttribute("controls", this.controlsValue)
      this.stageTarget.replaceChildren(embed)
      this.element.dataset.kicanvasState = "ready"
    } catch (e) {
      this.element.dataset.kicanvasState = "failed"
      if (this.hasStatusTarget) this.statusTarget.textContent = "The viewer could not load."
    }
  }
}
```

`FilesController`: `KICANVAS_EXTS = %w[kicad_sch kicad_pcb].freeze` beside `MEASURABLE_EXTS`, with a comment that these deliberately live OUTSIDE `ROLE_BY_EXT` (they fail `EXT_RE`; files-preview.md) and so get no filter chip and no thumbnail; `preview_kind` returns `:kicanvas` for them BEFORE the text branch. `files/show.html.erb` gains `<% elsif @kind == :kicanvas %>` → `div.kicanvas-stage[data-controller="kicanvas"][data-kicanvas-url-value=blob_file_path(@node.node_id)][data-kicanvas-controls-value="full"]` with a `p.muted[data-kicanvas-target="status"]` "Loading the viewer…" and a `div[data-kicanvas-target="stage"]`. Read the page's header comment about `capabilities` before adding the branch. Also `blob`'s `SAFE_INLINE_TYPES`: a `.kicad_sch` is text (`Marcel` may answer `application/octet-stream`); the embed fetches it, so the disposition does not matter, but confirm the fetch gets the bytes with `nosniff` set (a system test will tell).

- [ ] **Step 2: the Schematics section.** `projects/_schematics.html.erb`: from `@listing.files` (any depth) pick rows whose name ends in `.kicad_sch` or `.kicad_pcb` (a helper `FilesHelper#kicad?(name)` or inline; keep the two-extension list in ONE place — `FilesController::KICANVAS_EXTS`); when any: `section.panel.schematics-panel` with `h2` Schematics, a list of the files (name linking to the file page, a `.badge` "schematic" / "board"), and ONE inline preview of the first schematic (the same `kicanvas` controller, `controls="basic"`, stage height 320px). `projects/show.html.erb` renders it after `attachments` when the rows exist (the partial itself decides). CSS in `pages/preview.css`'s layer: `.kicanvas-stage { min-height: 320px }` and `kicanvas-embed { display: block; width: 100%; height: 100% }`; the file page's stage `height: 70vh`.

- [ ] **Step 3: tests.** `kicanvas_preview_test.rb` (request): a `.kicad_sch` node's file page renders the `:kicanvas` branch with the controller and the blob url; a `.kicad_pcb` likewise; a `.txt` does not; the project page shows the Schematics panel with both files and one embed stage when the folder holds them, and no panel otherwise; the Files index still lists the file with its ext label (no thumbnail poll cell — `thumb_cell_data` only for renderable kinds; check `_grid`/`_list` do not treat it as a poll cell) and NO filter chip named `kicad_sch` (the chip row derives from `ROLE_BY_EXT`). `test/system/kicanvas_test.rb`: a real `.kicad_sch` fixture (write a minimal valid KiCad 8 schematic — `(kicad_sch (version 20231120) (generator "tinkerex") (uuid "…") (paper "A4") (lib_symbols) (symbol_instances))` — into a fresh share library with `create_node!`), visit the file page, and assert `data-kicanvas-state="ready"` within the wait, that a `kicanvas-embed` element exists with the blob src, and that a `canvas` rendered inside it; `assert_no_console_errors` (this is the CSP check that matters: the module, its fonts and the fetch). MUTATION (README): point the controller at a wrong module name (`import("kicanvas-x")`) → state `failed`, the assertion reds; name it in the comment with the verbatim failure. The phone sweep gains the `.kicad_sch` file page. `template_hygiene_test.rb`: `_schematics.html.erb` renders through "project detail" once the fixture holds a `.kicad_sch` node — report the exact fixture line and map entry for Task A to add (A owns the file), or add them if A has already committed.

- [ ] **Step 4: mutation-check** (stage first; verbatim; restore): (a) `preview_kind` returning `:text` for kicad → the request test fails; (b) the Schematics panel rendered regardless of files → the "no panel otherwise" test fails; (c) the system test's module-name mutation.

- [ ] **Step 5: commit** with a pathspec: `KiCad schematics and boards render in the browser: KiCanvas on the file page and a Schematics section on the project`.

---

### Task C: close-out (the orchestrator)

- [ ] Both landed; the template-hygiene lines; look at a repo card and a schematic on the dev server; `bin/ci`; `/finish-branch`; `bin/log arc --from-pr <n>`.
